-- query_version: 1; event_schema_version: 1
WITH segments(workflow, analysis_mode) AS (VALUES ('live','local'),('live','cloud'),('import','local'),('import','cloud')),
eligible AS (
 SELECT * FROM events WHERE schema_version=1 AND environment=:environment
  AND timestamp_utc>=:window_start AND timestamp_utc<:window_end
), started_attempts AS (
 SELECT DISTINCT app_session_id,workflow,attempt_sequence FROM eligible
 WHERE event_name='workflow_started' AND attempt_sequence>0
), ranked AS (
 SELECT e.*,ROW_NUMBER() OVER (
  PARTITION BY app_session_id,workflow,attempt_sequence ORDER BY
   CASE event_name WHEN 'workflow_completed' THEN 0 WHEN 'workflow_failed' THEN 1 WHEN 'workflow_started' THEN 2 ELSE 3 END,
   event_sequence DESC
 ) path_rank FROM eligible e JOIN started_attempts USING(app_session_id,workflow,attempt_sequence)
), attempts AS (
 SELECT app_session_id,workflow,attempt_sequence,
  MAX(CASE WHEN path_rank=1 THEN analysis_mode END) analysis_mode,
  SUM(event_name='workflow_started') starts,SUM(event_name='workflow_completed') completions
 FROM ranked GROUP BY app_session_id,workflow,attempt_sequence
), counts AS (
 SELECT workflow,analysis_mode,SUM(starts) starts,SUM(completions) completions
 FROM attempts GROUP BY workflow,analysis_mode
), quality AS (
 SELECT SUM(CASE WHEN schema_version<>1 THEN 1 ELSE 0 END) +
  SUM(CASE WHEN event_sequence IS NULL OR event_sequence<=0 THEN 1 ELSE 0 END) +
  SUM(CASE WHEN event_name IN ('workflow_started','workflow_completed')
    AND (attempt_sequence IS NULL OR attempt_sequence<=0) THEN 1 ELSE 0 END) +
  (SELECT COUNT(*) FROM attempts WHERE starts<>1 OR completions>1) +
  (SELECT COUNT(*) FROM eligible WHERE event_name='workflow_completed' AND (attempt_sequence IS NULL OR attempt_sequence<=0)) AS issues
 FROM events WHERE environment=:environment AND timestamp_utc>=:window_start AND timestamp_utc<:window_end
)
SELECT s.workflow, s.analysis_mode, COALESCE(c.starts,0) AS eligible_attempts,
 COALESCE(c.completions,0) AS successful_attempts,
 CASE WHEN COALESCE(c.starts,0)=0 THEN NULL ELSE 1.0*c.completions/c.starts END AS maswr,
 CASE WHEN quality.issues>0 THEN 'incomplete' WHEN COALESCE(c.starts,0)=0 THEN 'missing-segment' ELSE 'requires-reconciliation' END AS evidence_state
FROM segments s LEFT JOIN counts c USING(workflow,analysis_mode) CROSS JOIN quality
ORDER BY s.workflow, s.analysis_mode;
