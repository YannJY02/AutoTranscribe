-- query_version: 1; event_schema_version: 1
WITH eligible AS (
  SELECT * FROM events WHERE schema_version = 1 AND environment = :environment
    AND timestamp_utc < :window_end
), consent_anchors AS (
  SELECT installation_id,MIN(timestamp_utc) consent_started_at,MIN(event_sequence) consent_started_sequence,
    COUNT(*) anchor_count
  FROM eligible WHERE event_name='telemetry_consent_changed' GROUP BY installation_id
), ranked_starts AS (
  SELECT installation_id,timestamp_utc,event_sequence,ROW_NUMBER() OVER (
    PARTITION BY installation_id ORDER BY timestamp_utc,event_sequence
  ) start_rank FROM eligible WHERE event_name='workflow_started'
), first_starts AS (
  SELECT installation_id,timestamp_utc AS first_start,event_sequence AS first_start_sequence
  FROM ranked_starts WHERE start_rank=1
), cohort_starts AS (
  SELECT s.*,CASE WHEN a.anchor_count=1 AND (a.consent_started_at<s.first_start
    OR (a.consent_started_at=s.first_start AND a.consent_started_sequence<s.first_start_sequence))
    THEN 1 ELSE 0 END start_proven
  FROM first_starts s LEFT JOIN consent_anchors a USING(installation_id)
  WHERE s.first_start>=:window_start
), starts AS (
  SELECT * FROM cohort_starts WHERE start_proven=1
), proof AS (
  SELECT SUM(CASE WHEN start_proven=0 THEN 1 ELSE 0 END) unproven_start_installations FROM cohort_starts
), installs AS (
  SELECT s.installation_id,s.first_start,
    (SELECT e.timestamp_utc FROM eligible e WHERE e.installation_id=s.installation_id
      AND e.event_name='workflow_completed' AND (e.timestamp_utc>s.first_start
        OR (e.timestamp_utc=s.first_start AND e.event_sequence>s.first_start_sequence))
      ORDER BY e.timestamp_utc,e.event_sequence LIMIT 1) AS first_success
  FROM starts s
), timed AS (
  SELECT *,ROUND((julianday(first_success)-julianday(first_start))*86400000) AS first_success_latency_ms
  FROM installs
), metrics AS (
  SELECT COUNT(CASE WHEN first_start IS NOT NULL THEN 1 END) AS started_installations,
    COUNT(CASE WHEN first_start IS NOT NULL AND first_success >= first_start THEN 1 END) AS activated_installations,
    CASE WHEN COUNT(CASE WHEN first_start IS NOT NULL THEN 1 END)=0 THEN NULL ELSE
      1.0*COUNT(CASE WHEN first_start IS NOT NULL AND first_success>=first_start THEN 1 END)/
      COUNT(CASE WHEN first_start IS NOT NULL THEN 1 END) END AS activation_rate,
    SUM(CASE WHEN first_success IS NOT NULL AND first_success_latency_ms<=60000 THEN 1 ELSE 0 END) AS success_under_1m,
    SUM(CASE WHEN first_success IS NOT NULL AND first_success_latency_ms>60000 AND first_success_latency_ms<=300000 THEN 1 ELSE 0 END) AS success_1_to_5m,
    SUM(CASE WHEN first_success IS NOT NULL AND first_success_latency_ms>300000 AND first_success_latency_ms<=1800000 THEN 1 ELSE 0 END) AS success_5_to_30m,
    SUM(CASE WHEN first_success IS NOT NULL AND first_success_latency_ms>1800000 THEN 1 ELSE 0 END) AS success_30m_plus
  FROM timed
)
SELECT metrics.started_installations,metrics.activated_installations,metrics.activation_rate,
  COALESCE(proof.unproven_start_installations,0) AS unproven_start_installations,
  CASE WHEN COALESCE(proof.unproven_start_installations,0)>0 OR metrics.started_installations=0
    THEN 'insufficient-data' ELSE 'requires-reconciliation' END AS evidence_state
  ,metrics.success_under_1m,metrics.success_1_to_5m,metrics.success_5_to_30m,metrics.success_30m_plus
FROM metrics CROSS JOIN proof;
