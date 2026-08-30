-- query_version: 1; event_schema_version: 1
WITH eligible AS (
 SELECT * FROM events WHERE schema_version=1 AND environment=:environment
  AND timestamp_utc>=:window_start AND timestamp_utc<:window_end
  AND event_name IN ('workflow_completed','workflow_failed')
  AND latency_bucket_ms IS NOT NULL
), grouped AS (
 SELECT app_version,app_build,workflow,analysis_mode,provider_class,latency_bucket_ms,
  COUNT(*) event_count,SUM(CASE WHEN outcome='succeeded' THEN 1 ELSE 0 END) success_count
 FROM eligible GROUP BY app_version,app_build,workflow,analysis_mode,provider_class,latency_bucket_ms
)
SELECT *, 'requires-reconciliation' evidence_state FROM grouped
UNION ALL
SELECT NULL,NULL,NULL,NULL,NULL,NULL,0,0,'insufficient-data'
WHERE NOT EXISTS(SELECT 1 FROM grouped);
