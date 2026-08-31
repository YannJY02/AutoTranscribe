-- query_version: 1; event_schema_version: 1
-- Compare these aggregate-only columns with the privacy-safe local evidence manifest.
SELECT 1 AS schema_version,:environment AS environment,:window_start AS window_start,:window_end AS window_end,
 event_name,workflow,analysis_mode,COUNT(*) AS remote_count,
 MIN(timestamp_utc) AS first_seen_utc,MAX(timestamp_utc) AS last_seen_utc
FROM events WHERE schema_version=1 AND environment=:environment
 AND timestamp_utc>=:window_start AND timestamp_utc<:window_end
GROUP BY event_name,workflow,analysis_mode ORDER BY event_name,workflow,analysis_mode;
