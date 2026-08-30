-- query_version: 1; event_schema_version: 1
WITH successes AS (SELECT installation_id, date(timestamp_utc) day FROM events WHERE schema_version=1 AND environment=:environment
 AND timestamp_utc>=:window_start AND timestamp_utc<:window_end AND event_name='workflow_completed' GROUP BY installation_id,date(timestamp_utc)),
cohorts AS (SELECT installation_id,MIN(day) cohort_day FROM successes GROUP BY installation_id)
SELECT SUM(CASE WHEN julianday(:window_end)-julianday(c.cohort_day)>=14 THEN 1 ELSE 0 END) mature_7d_cohort_installations,
 SUM(CASE WHEN julianday(:window_end)-julianday(c.cohort_day)>=35 THEN 1 ELSE 0 END) mature_28d_cohort_installations,
 SUM(CASE WHEN julianday(:window_end)-julianday(c.cohort_day)>=14 AND EXISTS(SELECT 1 FROM successes s WHERE s.installation_id=c.installation_id AND julianday(s.day)-julianday(c.cohort_day) BETWEEN 7 AND 13) THEN 1 ELSE 0 END) retained_7d,
 SUM(CASE WHEN julianday(:window_end)-julianday(c.cohort_day)>=35 AND EXISTS(SELECT 1 FROM successes s WHERE s.installation_id=c.installation_id AND julianday(s.day)-julianday(c.cohort_day) BETWEEN 28 AND 34) THEN 1 ELSE 0 END) retained_28d,
 CASE WHEN COUNT(*)<2 OR SUM(CASE WHEN julianday(:window_end)-julianday(c.cohort_day)>=35 THEN 1 ELSE 0 END)<2 THEN 'insufficient-window/data' ELSE 'requires-reconciliation' END evidence_state
FROM cohorts c;
