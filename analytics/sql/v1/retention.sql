-- query_version: 1; event_schema_version: 1
WITH event_history AS (SELECT * FROM events WHERE schema_version=1 AND environment=:environment
 AND timestamp_utc<:window_end),
consent_anchors AS (SELECT installation_id,MIN(timestamp_utc) consent_started_at,COUNT(*) anchor_count
 FROM event_history WHERE event_name='telemetry_consent_changed' GROUP BY installation_id),
success_history AS (SELECT installation_id,timestamp_utc,date(timestamp_utc) day FROM event_history
 WHERE event_name='workflow_completed'),
observed_successes AS (SELECT * FROM success_history WHERE timestamp_utc>=:window_start),
cohorts AS (SELECT s.installation_id,MIN(s.day) cohort_day,
 CASE WHEN a.anchor_count=1 AND a.consent_started_at<=MIN(s.timestamp_utc) THEN 1 ELSE 0 END cohort_proven
 FROM success_history s LEFT JOIN consent_anchors a USING(installation_id)
 GROUP BY s.installation_id,a.anchor_count,a.consent_started_at),
cohort_observation AS (SELECT c.*,
 CASE WHEN julianday(:window_end)-julianday(c.cohort_day)>=14 AND datetime(:window_start)<=datetime(c.cohort_day,'+7 days') THEN 1 ELSE 0 END observable_7d_flag,
 CASE WHEN julianday(:window_end)-julianday(c.cohort_day)>=29 AND datetime(:window_start)<=datetime(c.cohort_day,'+28 days') THEN 1 ELSE 0 END observable_28d_flag
 FROM cohorts c)
SELECT SUM(CASE WHEN c.cohort_proven=1 THEN c.observable_7d_flag ELSE 0 END) mature_7d_cohort_installations,
 SUM(CASE WHEN c.cohort_proven=1 THEN c.observable_28d_flag ELSE 0 END) mature_28d_cohort_installations,
 SUM(CASE WHEN c.cohort_proven=1 AND c.observable_7d_flag=1 AND EXISTS(SELECT 1 FROM observed_successes s WHERE s.installation_id=c.installation_id AND julianday(s.day)-julianday(c.cohort_day) BETWEEN 7 AND 13) THEN 1 ELSE 0 END) retained_7d,
 SUM(CASE WHEN c.cohort_proven=1 AND c.observable_28d_flag=1 AND EXISTS(SELECT 1 FROM observed_successes s WHERE s.installation_id=c.installation_id AND julianday(s.day)-julianday(c.cohort_day)=28) THEN 1 ELSE 0 END) retained_28d,
 SUM(CASE WHEN c.cohort_proven=0 THEN 1 ELSE 0 END) unproven_cohort_installations,
 CASE WHEN SUM(CASE WHEN c.cohort_proven=0 THEN 1 ELSE 0 END)>0 OR COUNT(*)<2
   OR SUM(CASE WHEN c.cohort_proven=1 THEN c.observable_28d_flag ELSE 0 END)<2
  THEN 'insufficient-window/data' ELSE 'requires-reconciliation' END evidence_state
FROM cohort_observation c;
