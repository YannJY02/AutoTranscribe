-- query_version: 1; event_schema_version: 1
WITH eligible AS (
  SELECT * FROM events WHERE schema_version = 1 AND environment = :environment
    AND timestamp_utc >= :window_start AND timestamp_utc < :window_end
), ranked_starts AS (
  SELECT installation_id,timestamp_utc,event_sequence,ROW_NUMBER() OVER (
    PARTITION BY installation_id ORDER BY timestamp_utc,event_sequence
  ) start_rank FROM eligible WHERE event_name='workflow_started'
), starts AS (
  SELECT installation_id,timestamp_utc AS first_start,event_sequence AS first_start_sequence
  FROM ranked_starts WHERE start_rank=1
), installs AS (
  SELECT s.installation_id,s.first_start,
    (SELECT e.timestamp_utc FROM eligible e WHERE e.installation_id=s.installation_id
      AND e.event_name='workflow_completed' AND (e.timestamp_utc>s.first_start
        OR (e.timestamp_utc=s.first_start AND e.event_sequence>s.first_start_sequence))
      ORDER BY e.timestamp_utc,e.event_sequence LIMIT 1) AS first_success,
    (SELECT e.duration_bucket_ms FROM eligible e WHERE e.installation_id=s.installation_id
      AND e.event_name='workflow_completed' AND (e.timestamp_utc>s.first_start
        OR (e.timestamp_utc=s.first_start AND e.event_sequence>s.first_start_sequence))
      ORDER BY e.timestamp_utc,e.event_sequence LIMIT 1) AS first_success_duration_bucket
  FROM starts s
)
SELECT COUNT(CASE WHEN first_start IS NOT NULL THEN 1 END) AS started_installations,
  COUNT(CASE WHEN first_start IS NOT NULL AND first_success >= first_start THEN 1 END) AS activated_installations,
  CASE WHEN COUNT(CASE WHEN first_start IS NOT NULL THEN 1 END) = 0 THEN NULL ELSE
    1.0 * COUNT(CASE WHEN first_start IS NOT NULL AND first_success >= first_start THEN 1 END) /
    COUNT(CASE WHEN first_start IS NOT NULL THEN 1 END) END AS activation_rate,
  CASE WHEN COUNT(CASE WHEN first_start IS NOT NULL THEN 1 END) = 0 THEN 'insufficient-data' ELSE 'requires-reconciliation' END AS evidence_state
  ,SUM(CASE WHEN first_success IS NOT NULL AND first_success_duration_bucket<=60000 THEN 1 ELSE 0 END) AS success_under_1m
  ,SUM(CASE WHEN first_success IS NOT NULL AND first_success_duration_bucket>60000 AND first_success_duration_bucket<=300000 THEN 1 ELSE 0 END) AS success_1_to_5m
  ,SUM(CASE WHEN first_success IS NOT NULL AND first_success_duration_bucket>300000 AND first_success_duration_bucket<=1800000 THEN 1 ELSE 0 END) AS success_5_to_30m
  ,SUM(CASE WHEN first_success IS NOT NULL AND first_success_duration_bucket>1800000 THEN 1 ELSE 0 END) AS success_30m_plus
FROM installs;
