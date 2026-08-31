-- query_version: 1; event_schema_version: 1
WITH success_history AS (SELECT installation_id, date(timestamp_utc) day FROM events WHERE schema_version=1 AND environment=:environment
 AND timestamp_utc<:window_end AND event_name='workflow_completed' GROUP BY installation_id,date(timestamp_utc)),
observed_successes AS (SELECT * FROM success_history WHERE day>=date(:window_start)),
cohorts AS (SELECT installation_id,MIN(day) cohort_day FROM success_history GROUP BY installation_id),
cohort_observation AS (SELECT c.*,
 CASE WHEN julianday(:window_end)-julianday(c.cohort_day)>=14 AND julianday(date(:window_start))-julianday(c.cohort_day)<=7 THEN 1 ELSE 0 END observable_7d_flag,
 CASE WHEN julianday(:window_end)-julianday(c.cohort_day)>=35 AND julianday(date(:window_start))-julianday(c.cohort_day)<=28 THEN 1 ELSE 0 END observable_28d_flag
 FROM cohorts c)
SELECT SUM(c.observable_7d_flag) mature_7d_cohort_installations,
 SUM(c.observable_28d_flag) mature_28d_cohort_installations,
 SUM(CASE WHEN c.observable_7d_flag=1 AND EXISTS(SELECT 1 FROM observed_successes s WHERE s.installation_id=c.installation_id AND julianday(s.day)-julianday(c.cohort_day) BETWEEN 7 AND 13) THEN 1 ELSE 0 END) retained_7d,
 SUM(CASE WHEN c.observable_28d_flag=1 AND EXISTS(SELECT 1 FROM observed_successes s WHERE s.installation_id=c.installation_id AND julianday(s.day)-julianday(c.cohort_day) BETWEEN 28 AND 34) THEN 1 ELSE 0 END) retained_28d,
 CASE WHEN COUNT(*)<2 OR SUM(c.observable_28d_flag)<2 THEN 'insufficient-window/data' ELSE 'requires-reconciliation' END evidence_state
FROM cohort_observation c;
