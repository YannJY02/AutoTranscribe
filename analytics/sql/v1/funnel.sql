-- query_version: 1; event_schema_version: 1
WITH eligible AS (SELECT * FROM events WHERE schema_version=1 AND environment=:environment AND timestamp_utc>=:window_start AND timestamp_utc<:window_end),
sessions AS (SELECT app_session_id,workflow,attempt_sequence,
 MIN(CASE WHEN event_name='workflow_started' THEN timestamp_utc END) started,
 MIN(CASE WHEN event_name='record_saved' THEN timestamp_utc END) saved,
 MIN(CASE WHEN event_name='smart_minutes_review_opened' THEN timestamp_utc END) reviewed,
 MIN(CASE WHEN event_name='export_completed' THEN timestamp_utc END) exported
 FROM eligible WHERE attempt_sequence>0 GROUP BY app_session_id,workflow,attempt_sequence)
SELECT COUNT(CASE WHEN started IS NOT NULL THEN 1 END) started,
 COUNT(CASE WHEN saved>=started THEN 1 END) record_saved,
 COUNT(CASE WHEN reviewed>=saved AND saved>=started THEN 1 END) review_opened,
 COUNT(CASE WHEN exported>=reviewed AND reviewed>=saved AND saved>=started THEN 1 END) export_completed,
 CASE WHEN COUNT(CASE WHEN started IS NOT NULL THEN 1 END)=0 THEN 'insufficient-data' ELSE 'requires-reconciliation' END evidence_state
FROM sessions;
