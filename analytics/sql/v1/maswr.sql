-- query_version: 1; event_schema_version: 1
WITH segments(workflow, analysis_mode) AS (VALUES ('live','local'),('live','cloud'),('import','local'),('import','cloud')),
event_source AS (
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
), ranked AS (
 SELECT o.*,ROW_NUMBER() OVER (
  PARTITION BY app_session_id,workflow,attempt_index ORDER BY
   CASE event_name WHEN 'workflow_completed' THEN 0 WHEN 'workflow_failed' THEN 1 WHEN 'workflow_started' THEN 2 ELSE 3 END,
   event_sequence DESC
  ) path_rank FROM ordered o WHERE attempt_index>0 AND NOT is_record_context_terminal AND NOT is_boundary_terminal
), attempts AS (
 SELECT app_session_id,workflow,attempt_index,
  MAX(CASE WHEN path_rank=1 THEN analysis_mode END) analysis_mode,
  SUM(event_name='workflow_started') starts,SUM(event_name='workflow_completed') completions
 FROM ranked GROUP BY app_session_id,workflow,attempt_index
), boundary_quality AS (
 SELECT
  COALESCE(SUM(event_name IN ('workflow_completed','workflow_failed') AND NOT is_record_context_terminal AND attempt_index=0 AND NOT is_boundary_terminal),0) orphan_boundary_terminals,
  COALESCE(SUM(event_name='workflow_started' AND terminal_index<pre_window_open_attempts),0) ambiguous_boundary_starts
 FROM classified
), counts AS (
 SELECT workflow,analysis_mode,SUM(starts) starts,SUM(completions) completions
 FROM attempts GROUP BY workflow,analysis_mode
), quality AS (
 SELECT SUM(CASE WHEN schema_version<>1 THEN 1 ELSE 0 END) +
  SUM(CASE WHEN event_sequence IS NULL OR event_sequence<=0 THEN 1 ELSE 0 END) +
  (SELECT COUNT(*) FROM attempts WHERE starts<>1 OR completions>1) +
  (SELECT orphan_boundary_terminals+ambiguous_boundary_starts FROM boundary_quality) +
  (SELECT COUNT(*) FROM ordered WHERE event_name='workflow_started' AND prior_starts>prior_terminals) AS issues
 FROM events WHERE environment=:environment AND timestamp_utc>=:window_start AND timestamp_utc<:window_end
)
SELECT s.workflow, s.analysis_mode, COALESCE(c.starts,0) AS eligible_attempts,
 COALESCE(c.completions,0) AS successful_attempts,
 CASE WHEN COALESCE(c.starts,0)=0 THEN NULL ELSE 1.0*c.completions/c.starts END AS maswr,
 CASE WHEN quality.issues>0 THEN 'incomplete' WHEN COALESCE(c.starts,0)=0 THEN 'missing-segment' ELSE 'requires-reconciliation' END AS evidence_state
FROM segments s LEFT JOIN counts c USING(workflow,analysis_mode) CROSS JOIN quality
ORDER BY s.workflow, s.analysis_mode;
