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
  ) attempt_index
 FROM eligible e
), ordered AS (
 SELECT i.*,
  COALESCE(SUM(CASE WHEN event_name='workflow_started' THEN 1 ELSE 0 END) OVER (
   PARTITION BY app_session_id,workflow ORDER BY timestamp_utc,event_sequence
   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
  ),0) prior_starts,
  COALESCE(SUM(CASE WHEN event_name IN ('workflow_completed','workflow_failed') AND attempt_index>0 THEN 1 ELSE 0 END) OVER (
   PARTITION BY app_session_id,workflow ORDER BY timestamp_utc,event_sequence
   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
  ),0) prior_terminals
 FROM indexed i
), sessions AS (
 SELECT app_session_id,workflow,attempt_index,
  MIN(CASE WHEN event_name='workflow_started' THEN timestamp_utc END) started,
  MIN(CASE WHEN event_name='record_saved' THEN timestamp_utc END) saved,
  MIN(CASE WHEN event_name='smart_minutes_review_opened' THEN timestamp_utc END) reviewed,
 MIN(CASE WHEN event_name='export_completed' THEN timestamp_utc END) exported
 FROM ordered WHERE attempt_index>0 GROUP BY app_session_id,workflow,attempt_index
), boundary_terminals AS (
 SELECT app_session_id,workflow,COUNT(*) terminals
 FROM ordered WHERE attempt_index=0 AND event_name IN ('workflow_completed','workflow_failed')
 GROUP BY app_session_id,workflow
), boundary_quality AS (
 SELECT COALESCE(SUM(MAX(b.terminals-COALESCE(p.open_attempts,0),0)),0) orphan_boundary_terminals
 FROM boundary_terminals b LEFT JOIN pre_window p USING(app_session_id,workflow)
), quality AS (
 SELECT
  (SELECT COUNT(*) FROM ordered WHERE event_name='workflow_started' AND prior_starts>prior_terminals) overlapping_starts,
  (SELECT orphan_boundary_terminals FROM boundary_quality) orphan_boundary_terminals
)
SELECT COUNT(CASE WHEN started IS NOT NULL THEN 1 END) started,
 COUNT(CASE WHEN saved>=started THEN 1 END) record_saved,
 COUNT(CASE WHEN reviewed>=saved AND saved>=started THEN 1 END) review_opened,
 COUNT(CASE WHEN exported>=reviewed AND reviewed>=saved AND saved>=started THEN 1 END) export_completed,
 CASE WHEN quality.overlapping_starts+quality.orphan_boundary_terminals>0 THEN 'incomplete'
  WHEN COUNT(CASE WHEN started IS NOT NULL THEN 1 END)=0 THEN 'insufficient-data'
  ELSE 'requires-reconciliation' END evidence_state
FROM sessions CROSS JOIN quality;
