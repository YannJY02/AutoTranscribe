-- query_version: 1; event_schema_version: 1
WITH eligible AS (
 SELECT * FROM events WHERE schema_version=1 AND environment=:environment
  AND timestamp_utc>=:window_start AND timestamp_utc<:window_end
), pre_window AS (
 SELECT app_session_id,workflow,
  CASE WHEN SUM(CASE WHEN event_name='workflow_started' THEN 1 WHEN event_name IN ('workflow_completed','workflow_failed') THEN -1 ELSE 0 END)>0
   THEN SUM(CASE WHEN event_name='workflow_started' THEN 1 WHEN event_name IN ('workflow_completed','workflow_failed') THEN -1 ELSE 0 END) ELSE 0 END open_attempts
 FROM events WHERE schema_version=1 AND environment=:environment AND timestamp_utc<:window_start
 GROUP BY app_session_id,workflow
), indexed AS (
 SELECT e.*,
  SUM(CASE WHEN event_name='workflow_started' THEN 1 ELSE 0 END) OVER (
   PARTITION BY app_session_id,workflow ORDER BY timestamp_utc,event_sequence
   ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) attempt_index,
  SUM(CASE WHEN event_name IN ('workflow_completed','workflow_failed') THEN 1 ELSE 0 END) OVER (
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
  event_name IN ('workflow_completed','workflow_failed')
   AND terminal_index<=COALESCE(p.open_attempts,0) is_boundary_terminal
 FROM indexed i LEFT JOIN pre_window p USING(app_session_id,workflow)
), ordered AS (
 SELECT c.*,
  COALESCE(SUM(CASE WHEN event_name='workflow_started' THEN 1 ELSE 0 END) OVER (
   PARTITION BY app_session_id,workflow ORDER BY timestamp_utc,event_sequence
   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
  ),0) prior_starts,
  COALESCE(SUM(CASE WHEN event_name IN ('workflow_completed','workflow_failed') AND NOT is_boundary_terminal THEN 1 ELSE 0 END) OVER (
   PARTITION BY app_session_id,workflow ORDER BY timestamp_utc,event_sequence
   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
  ),0) prior_terminals
 FROM classified c
), sessions AS (
 SELECT app_session_id,workflow,funnel_index,
  MIN(CASE WHEN event_name='workflow_started' THEN timestamp_utc END) started,
  MIN(CASE WHEN event_name='record_saved' THEN timestamp_utc END) saved,
  MIN(CASE WHEN event_name='smart_minutes_review_opened' THEN timestamp_utc END) reviewed,
 MIN(CASE WHEN event_name='export_completed' THEN timestamp_utc END) exported
 FROM ordered WHERE attempt_index>0 AND NOT is_boundary_terminal
 GROUP BY app_session_id,workflow,funnel_index
 HAVING SUM(event_name='workflow_started')>0
), boundary_quality AS (
 SELECT
  COALESCE(SUM(event_name IN ('workflow_completed','workflow_failed') AND attempt_index=0 AND NOT is_boundary_terminal),0) orphan_boundary_terminals,
  COALESCE(SUM(event_name='workflow_started' AND terminal_index<pre_window_open_attempts),0) ambiguous_boundary_starts
 FROM classified
), quality AS (
 SELECT
  (SELECT COUNT(*) FROM ordered WHERE event_name='workflow_started' AND prior_starts>prior_terminals) overlapping_starts,
  (SELECT orphan_boundary_terminals FROM boundary_quality) orphan_boundary_terminals,
  (SELECT ambiguous_boundary_starts FROM boundary_quality) ambiguous_boundary_starts
)
SELECT COUNT(CASE WHEN started IS NOT NULL THEN 1 END) started,
 COUNT(CASE WHEN saved>=started THEN 1 END) record_saved,
 COUNT(CASE WHEN reviewed>=saved AND saved>=started THEN 1 END) review_opened,
 COUNT(CASE WHEN exported>=reviewed AND reviewed>=saved AND saved>=started THEN 1 END) export_completed,
 CASE WHEN quality.overlapping_starts+quality.orphan_boundary_terminals+quality.ambiguous_boundary_starts>0 THEN 'incomplete'
  WHEN COUNT(CASE WHEN started IS NOT NULL THEN 1 END)=0 THEN 'insufficient-data'
  ELSE 'requires-reconciliation' END evidence_state
FROM sessions CROSS JOIN quality;
