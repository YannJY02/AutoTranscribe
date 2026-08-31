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
  ) terminal_index,
  SUM(CASE WHEN event_name IN ('workflow_started','record_reopened') THEN 1 ELSE 0 END) OVER (
   PARTITION BY app_session_id,workflow ORDER BY timestamp_utc,event_sequence
   ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) funnel_index
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
), sessions AS (
 SELECT app_session_id,workflow,funnel_index,
  MIN(CASE WHEN event_name='workflow_started' THEN printf('%s|%020d',timestamp_utc,event_sequence) END) started,
  MIN(CASE WHEN event_name='record_saved' THEN printf('%s|%020d',timestamp_utc,event_sequence) END) saved,
  MIN(CASE WHEN event_name='smart_minutes_review_opened' THEN printf('%s|%020d',timestamp_utc,event_sequence) END) reviewed,
  MIN(CASE WHEN event_name='export_completed' THEN printf('%s|%020d',timestamp_utc,event_sequence) END) exported
 FROM ordered WHERE attempt_index>0 AND NOT is_record_context_terminal AND NOT is_boundary_terminal
 GROUP BY app_session_id,workflow,funnel_index
 HAVING SUM(event_name='workflow_started')>0
), boundary_quality AS (
 SELECT
  COALESCE(SUM(event_name IN ('workflow_completed','workflow_failed') AND NOT is_record_context_terminal AND attempt_index=0 AND NOT is_boundary_terminal),0) orphan_boundary_terminals,
  COALESCE(SUM(event_name='workflow_started' AND terminal_index<pre_window_open_attempts),0) ambiguous_boundary_starts
 FROM classified
), quality AS (
 SELECT
  (SELECT COUNT(*) FROM ordered WHERE event_name='workflow_started' AND prior_starts>prior_terminals) overlapping_starts,
  (SELECT COUNT(*) FROM ordered WHERE event_name='record_reopened' AND prior_starts>prior_terminals) reopens_during_active_attempts,
  (SELECT orphan_boundary_terminals FROM boundary_quality) orphan_boundary_terminals,
  (SELECT ambiguous_boundary_starts FROM boundary_quality) ambiguous_boundary_starts
), funnel_counts AS (
 SELECT COUNT(CASE WHEN started IS NOT NULL THEN 1 END) started,
  COUNT(CASE WHEN saved>=started THEN 1 END) record_saved,
  COUNT(CASE WHEN reviewed>=saved AND saved>=started THEN 1 END) review_opened,
  COUNT(CASE WHEN exported>=reviewed AND reviewed>=saved AND saved>=started THEN 1 END) export_completed
 FROM sessions
)
SELECT funnel_counts.*,
 CASE WHEN quality.overlapping_starts+quality.reopens_during_active_attempts+quality.orphan_boundary_terminals+quality.ambiguous_boundary_starts>0 THEN 'incomplete'
  WHEN funnel_counts.started=0 THEN 'insufficient-data'
  ELSE 'requires-reconciliation' END evidence_state
FROM funnel_counts CROSS JOIN quality;
