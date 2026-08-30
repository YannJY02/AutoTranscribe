-- query_version: 1; event_schema_version: 1
WITH eligible AS (
 SELECT * FROM events WHERE schema_version=1 AND environment=:environment
 AND timestamp_utc>=:window_start AND timestamp_utc<:window_end
), failures AS (
 SELECT app_session_id,workflow,analysis_mode,phase,timestamp_utc,event_sequence,attempt_sequence FROM eligible
 WHERE event_name='workflow_failed' AND recovery_action<>'none' AND attempt_sequence>0
)
SELECT COUNT(*) actionable_failures,
 SUM(CASE WHEN EXISTS(SELECT 1 FROM eligible r WHERE r.event_name='recovery_completed'
  AND r.app_session_id=f.app_session_id AND r.workflow=f.workflow AND r.attempt_sequence=f.attempt_sequence AND r.analysis_mode=f.analysis_mode AND r.phase=f.phase AND r.outcome='succeeded'
  AND (r.timestamp_utc>f.timestamp_utc OR (r.timestamp_utc=f.timestamp_utc AND r.event_sequence>f.event_sequence))) THEN 1 ELSE 0 END) recovered_failures,
 CASE WHEN COUNT(*)=0 THEN NULL ELSE 1.0*SUM(CASE WHEN EXISTS(SELECT 1 FROM eligible r WHERE r.event_name='recovery_completed'
  AND r.app_session_id=f.app_session_id AND r.workflow=f.workflow AND r.attempt_sequence=f.attempt_sequence AND r.analysis_mode=f.analysis_mode AND r.phase=f.phase AND r.outcome='succeeded'
  AND (r.timestamp_utc>f.timestamp_utc OR (r.timestamp_utc=f.timestamp_utc AND r.event_sequence>f.event_sequence))) THEN 1 ELSE 0 END)/COUNT(*) END recovery_rate,
 CASE WHEN COUNT(*)=0 THEN 'insufficient-data' ELSE 'requires-reconciliation' END evidence_state
FROM failures f;
