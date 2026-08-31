-- query_version: 1; event_schema_version: 1
WITH event_source AS (
 SELECT e.*,MAX(CASE WHEN event_name IN ('workflow_started','record_reopened')
  THEN printf('%s|%020d|%s',timestamp_utc,event_sequence,event_name) END) OVER (
   PARTITION BY app_session_id,workflow ORDER BY timestamp_utc,event_sequence
   ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) context_anchor
 FROM events e WHERE schema_version=1 AND environment=:environment AND timestamp_utc<:window_end
), contextualized AS (
 SELECT *,event_name='workflow_failed' AND COALESCE(context_anchor LIKE '%|record_reopened',0) is_record_context_terminal
 FROM event_source
), eligible AS (
 SELECT * FROM contextualized WHERE timestamp_utc>=:window_start
), pre_window AS (
 SELECT app_session_id,workflow,
  CASE WHEN SUM(CASE WHEN event_name='workflow_started' THEN 1
    WHEN event_name='workflow_completed' OR (event_name='workflow_failed' AND NOT is_record_context_terminal) THEN -1 ELSE 0 END)>0
   THEN SUM(CASE WHEN event_name='workflow_started' THEN 1
    WHEN event_name='workflow_completed' OR (event_name='workflow_failed' AND NOT is_record_context_terminal) THEN -1 ELSE 0 END) ELSE 0 END open_attempts
 FROM contextualized WHERE timestamp_utc<:window_start
 GROUP BY app_session_id,workflow
), indexed AS (
 SELECT e.*,
  SUM(CASE WHEN event_name='workflow_started' THEN 1 ELSE 0 END) OVER (
   PARTITION BY app_session_id,workflow ORDER BY timestamp_utc,event_sequence
   ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) attempt_index,
  SUM(CASE WHEN event_name='workflow_completed' OR (event_name='workflow_failed' AND NOT is_record_context_terminal) THEN 1 ELSE 0 END) OVER (
   PARTITION BY app_session_id,workflow ORDER BY timestamp_utc,event_sequence
   ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) terminal_index
 FROM eligible e
), classified AS (
 SELECT i.*,COALESCE(p.open_attempts,0) pre_window_open_attempts,
  NOT is_record_context_terminal AND event_name IN ('workflow_completed','workflow_failed')
   AND terminal_index<=COALESCE(p.open_attempts,0) is_boundary_terminal
 FROM indexed i LEFT JOIN pre_window p USING(app_session_id,workflow)
), ordered AS (
 SELECT c.*,
  COALESCE(SUM(CASE WHEN event_name='workflow_started' THEN 1 ELSE 0 END) OVER (
   PARTITION BY app_session_id,workflow ORDER BY timestamp_utc,event_sequence
   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
  ),0) prior_starts,
  COALESCE(SUM(CASE WHEN event_name IN ('workflow_completed','workflow_failed') AND NOT is_record_context_terminal AND NOT is_boundary_terminal THEN 1 ELSE 0 END) OVER (
   PARTITION BY app_session_id,workflow ORDER BY timestamp_utc,event_sequence
   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
  ),0) prior_terminals
 FROM classified c
), diagnostics AS (
 SELECT SUM(CASE WHEN schema_version<>1 THEN 1 ELSE 0 END) unknown_schema,
 SUM(CASE WHEN event_sequence IS NULL OR event_sequence<=0 THEN 1 ELSE 0 END) missing_event_sequence,
 SUM(CASE WHEN event_name NOT IN ('workflow_started','record_saved','record_reopened','transcript_search_completed','smart_minutes_review_opened','export_completed','workflow_completed','workflow_failed','recovery_attempted','recovery_completed','telemetry_consent_changed') THEN 1 ELSE 0 END) unknown_event,
 SUM(CASE WHEN workflow IS NOT NULL AND workflow NOT IN ('live','import') THEN 1 ELSE 0 END) unknown_workflow,
 SUM(CASE WHEN analysis_mode IS NOT NULL AND analysis_mode NOT IN ('local','cloud') THEN 1 ELSE 0 END) unknown_analysis_mode,
 SUM(CASE WHEN provider_class IS NOT NULL AND provider_class NOT IN ('local','byok','none') THEN 1 ELSE 0 END) unknown_provider_class,
 SUM(CASE WHEN phase IS NOT NULL AND phase NOT IN ('preparing','running','finalizing','analysis','reviewing','exporting') THEN 1 ELSE 0 END) unknown_phase,
 SUM(CASE WHEN outcome IS NOT NULL AND outcome NOT IN ('succeeded','failed','cancelled') THEN 1 ELSE 0 END) unknown_outcome,
 SUM(CASE WHEN error_code IS NOT NULL AND error_code NOT IN ('configuration','permission-denied','runtime-unavailable','provider-unavailable','storage','unknown') THEN 1 ELSE 0 END) unknown_error_code,
 SUM(CASE WHEN recovery_action IS NOT NULL AND recovery_action NOT IN ('retry','open-settings','restart','none') THEN 1 ELSE 0 END) unknown_recovery_action,
 SUM(CASE WHEN retry_count NOT BETWEEN 0 AND 10 OR result_count NOT BETWEEN 0 AND 10000 OR module_count NOT BETWEEN 0 AND 100 OR quality_score NOT BETWEEN 0 AND 1 THEN 1 ELSE 0 END) out_of_bounds,
 SUM(CASE WHEN duration_bucket_ms IS NOT NULL AND duration_bucket_ms NOT IN (1000,5000,15000,30000,60000,300000,900000,1800000,3600000) THEN 1 ELSE 0 END) unknown_duration_bucket,
 SUM(CASE WHEN latency_bucket_ms IS NOT NULL AND latency_bucket_ms NOT IN (100,250,500,1000,5000,15000,30000,60000,300000) THEN 1 ELSE 0 END) unknown_latency_bucket,
 SUM(CASE WHEN event_name IN ('workflow_completed','workflow_failed') AND provider_class IS NULL THEN 1
          WHEN event_name='workflow_completed' AND latency_bucket_ms IS NULL THEN 1 ELSE 0 END) missing_terminal_dimensions
 FROM events WHERE environment=:environment AND timestamp_utc>=:window_start AND timestamp_utc<:window_end
), attempts AS (
 SELECT app_session_id,workflow,attempt_index,
  SUM(event_name='workflow_started') starts,SUM(event_name='workflow_completed') completions
 FROM ordered WHERE attempt_index>0 AND NOT is_record_context_terminal AND NOT is_boundary_terminal GROUP BY app_session_id,workflow,attempt_index
), boundary_quality AS (
 SELECT
  COALESCE(SUM(event_name IN ('workflow_completed','workflow_failed') AND NOT is_record_context_terminal AND attempt_index=0 AND NOT is_boundary_terminal),0) orphan_boundary_terminals,
  COALESCE(SUM(event_name='workflow_started' AND terminal_index<pre_window_open_attempts),0) ambiguous_boundary_starts
 FROM classified
), quality AS (
 SELECT
  (SELECT COUNT(*) FROM ordered WHERE event_name='workflow_started' AND prior_starts>prior_terminals) overlapping_attempts,
  (SELECT COUNT(*) FROM attempts WHERE starts<>1 OR completions>1) duplicate_attempt_groups,
  (SELECT orphan_boundary_terminals FROM boundary_quality) orphan_boundary_terminals,
  (SELECT ambiguous_boundary_starts FROM boundary_quality) ambiguous_boundary_starts
)
SELECT diagnostics.*,quality.overlapping_attempts,quality.duplicate_attempt_groups,quality.orphan_boundary_terminals,quality.ambiguous_boundary_starts,
 CASE WHEN unknown_schema+missing_event_sequence+unknown_event+unknown_workflow+unknown_analysis_mode+unknown_provider_class+unknown_phase+unknown_outcome+unknown_error_code+unknown_recovery_action+out_of_bounds+unknown_duration_bucket+unknown_latency_bucket+missing_terminal_dimensions+overlapping_attempts+duplicate_attempt_groups+orphan_boundary_terminals+ambiguous_boundary_starts=0 THEN 'complete' ELSE 'incomplete' END evidence_state
FROM diagnostics CROSS JOIN quality;
