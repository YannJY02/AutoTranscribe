-- query_version: 1; event_schema_version: 1
WITH eligible AS (
 SELECT * FROM events WHERE schema_version=1 AND environment=:environment
  AND timestamp_utc>=:window_start AND timestamp_utc<:window_end
), ordered AS (
 SELECT e.*,
  SUM(CASE WHEN event_name='workflow_started' THEN 1 ELSE 0 END) OVER (
   PARTITION BY app_session_id,workflow ORDER BY timestamp_utc,event_sequence
   ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) attempt_index,
  COALESCE(SUM(CASE WHEN event_name='workflow_started' THEN 1 ELSE 0 END) OVER (
   PARTITION BY app_session_id,workflow ORDER BY timestamp_utc,event_sequence
   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
  ),0) prior_starts,
  COALESCE(SUM(CASE WHEN event_name IN ('workflow_completed','workflow_failed') THEN 1 ELSE 0 END) OVER (
   PARTITION BY app_session_id,workflow ORDER BY timestamp_utc,event_sequence
   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
  ),0) prior_terminals
 FROM eligible e
), sessions AS (
 SELECT app_session_id,workflow,attempt_index,
  MIN(CASE WHEN event_name='workflow_started' THEN timestamp_utc END) started,
  MIN(CASE WHEN event_name='record_saved' THEN timestamp_utc END) saved,
  MIN(CASE WHEN event_name='smart_minutes_review_opened' THEN timestamp_utc END) reviewed,
  MIN(CASE WHEN event_name='export_completed' THEN timestamp_utc END) exported
 FROM ordered WHERE attempt_index>0 GROUP BY app_session_id,workflow,attempt_index
), quality AS (
 SELECT COUNT(*) AS overlapping_starts FROM ordered
 WHERE event_name='workflow_started' AND prior_starts>prior_terminals
)
SELECT COUNT(CASE WHEN started IS NOT NULL THEN 1 END) started,
 COUNT(CASE WHEN saved>=started THEN 1 END) record_saved,
 COUNT(CASE WHEN reviewed>=saved AND saved>=started THEN 1 END) review_opened,
 COUNT(CASE WHEN exported>=reviewed AND reviewed>=saved AND saved>=started THEN 1 END) export_completed,
 CASE WHEN quality.overlapping_starts>0 THEN 'incomplete'
  WHEN COUNT(CASE WHEN started IS NOT NULL THEN 1 END)=0 THEN 'insufficient-data'
  ELSE 'requires-reconciliation' END evidence_state
FROM sessions CROSS JOIN quality;
