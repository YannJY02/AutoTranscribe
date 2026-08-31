import sqlite3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SQL_ROOT = ROOT / "analytics" / "sql" / "v1"
POSTHOG_SQL_ROOT = SQL_ROOT / "posthog"
QUERY_NAMES = [
    "activation", "maswr", "funnel", "recovery",
    "latency_guardrails", "retention", "data_quality", "reconciliation",
]
PARAMS = {
    "environment": "development",
    "window_start": "2026-01-01T00:00:00Z",
    "window_end": "2026-01-20T00:00:00Z",
}


def database() -> sqlite3.Connection:
    connection = sqlite3.connect(":memory:")
    connection.execute(
        """CREATE TABLE events(
        event_name TEXT, timestamp_utc TEXT, event_sequence INTEGER, schema_version INTEGER, environment TEXT,
        app_version TEXT, app_build TEXT, installation_id TEXT, app_session_id TEXT,
        workflow TEXT, attempt_sequence INTEGER, analysis_mode TEXT, provider_class TEXT, phase TEXT, outcome TEXT,
        error_code TEXT, recovery_action TEXT, duration_bucket_ms INTEGER,
        latency_bucket_ms INTEGER, retry_count INTEGER, result_count INTEGER, module_count INTEGER, quality_score REAL)"""
    )
    rows = [
        ("workflow_started", "2026-01-01T00:00:00Z", 1, "i1", "s1", "live", 1, "local", None, None),
        ("record_saved", "2026-01-01T00:01:00Z", 2, "i1", "s1", "live", 1, "local", None, None),
        ("smart_minutes_review_opened", "2026-01-01T00:02:00Z", 3, "i1", "s1", "live", 1, "local", None, None),
        ("export_completed", "2026-01-01T00:03:00Z", 4, "i1", "s1", "live", 1, "local", None, "succeeded"),
        ("workflow_completed", "2026-01-01T00:04:00Z", 5, "i1", "s1", "live", 1, "local", None, "succeeded"),
        ("workflow_started", "2026-01-02T00:00:00Z", 1, "i2", "s2", "import", 1, "cloud", None, None),
        ("workflow_failed", "2026-01-02T00:01:00Z", 2, "i2", "s2", "import", 1, "cloud", "retry", "failed"),
        ("recovery_completed", "2026-01-02T00:02:00Z", 3, "i2", "s2", "import", 1, "cloud", None, "succeeded"),
    ]
    connection.executemany(
        """INSERT INTO events(event_name,timestamp_utc,event_sequence,schema_version,environment,app_version,app_build,
        installation_id,app_session_id,workflow,attempt_sequence,analysis_mode,provider_class,phase,recovery_action,outcome,duration_bucket_ms,latency_bucket_ms)
        VALUES(?,?,?,1,'development','1.0','1',?,?,?,?,?,'none','analysis',?,?,300000,1000)""",
        rows,
    )
    return connection


def run(name: str):
    query = (SQL_ROOT / name).read_text()
    assert "query_version: 1" in query
    assert "event_schema_version: 1" in query
    connection = database()
    cursor = connection.execute(query, PARAMS)
    return [column[0] for column in cursor.description], cursor.fetchall()


def test_all_versioned_queries_execute_against_deterministic_fixture():
    for name in [
        "activation.sql", "maswr.sql", "funnel.sql", "recovery.sql",
        "latency_guardrails.sql", "retention.sql", "data_quality.sql", "reconciliation.sql",
    ]:
        columns, rows = run(name)
        assert columns
        assert rows


def test_posthog_queries_use_native_event_schema_and_sql_variables():
    for name in QUERY_NAMES:
        query = (POSTHOG_SQL_ROOT / f"{name}.hogql").read_text()
        assert "event AS event_name" in query
        assert "toTimeZone(timestamp, 'UTC') AS timestamp_utc" in query
        assert "toInt(properties.schema_version) AS schema_version" in query
        assert "{variables.environment}" in query
        assert "{variables.window_start}" in query
        assert "{variables.window_end}" in query
        assert ":environment" not in query
        assert ":window_start" not in query
        assert ":window_end" not in query
        assert "EXISTS(" not in query

        for field in {
            "event_sequence", "schema_version", "duration_bucket_ms",
            "latency_bucket_ms", "retry_count", "result_count", "module_count",
        }:
            if f"properties.{field}" in query:
                assert f"toInt(properties.{field}) AS {field}" in query
        if "properties.quality_score" in query:
            assert "toFloat(properties.quality_score) AS quality_score" in query
        assert "properties.attempt_sequence" not in query

    assert "minOrNullIf" in (POSTHOG_SQL_ROOT / "funnel.hogql").read_text()
    assert "overlapping_attempts" in (
        POSTHOG_SQL_ROOT / "data_quality.hogql"
    ).read_text()
    assert "if(started_installations=0,NULL,countIf(first_success" in (
        POSTHOG_SQL_ROOT / "activation.hogql"
    ).read_text()
    activation = (POSTHOG_SQL_ROOT / "activation.hogql").read_text()
    retention = (POSTHOG_SQL_ROOT / "retention.hogql").read_text()
    assert "timestamp >= toDateTime({variables.window_start})" not in activation
    assert "first_start >= toDateTime({variables.window_start})" in activation
    assert "timestamp >= toDateTime({variables.window_start})" not in retention
    assert "timestamp_utc >= toDateTime({variables.window_start})" in retention
    assert "observable_7d_flag" in retention
    assert "observable_28d_flag" in retention
    assert "addDays(toDateTime(c.cohort_day,'UTC'),7)" in retention
    assert "addDays(toDateTime(c.cohort_day,'UTC'),28)" in retention
    assert "dateDiff('millisecond',first_start,first_success)" in (
        POSTHOG_SQL_ROOT / "activation.hogql"
    ).read_text()
    assert "if(actionable_failures=0,NULL,countIf(is_recovered))" in (
        POSTHOG_SQL_ROOT / "recovery.hogql"
    ).read_text()
    assert "if(COUNT(*)=0,NULL,countIf(" in (
        POSTHOG_SQL_ROOT / "retention.hogql"
    ).read_text()
    assert "if(event_count=0,NULL,unknown_schema)" in (
        POSTHOG_SQL_ROOT / "data_quality.hogql"
    ).read_text()
    for name in ["maswr.hogql", "data_quality.hogql", "funnel.hogql"]:
        query = (POSTHOG_SQL_ROOT / name).read_text()
        assert "pre_window" in query
        assert "is_boundary_terminal" in query
        assert "is_record_context_terminal" in query
        assert "schema_version=1 AND event_name IN ('workflow_started','record_reopened')" in query
        assert "orphan_boundary_terminals" in query
    assert "funnel_index" in (POSTHOG_SQL_ROOT / "funnel.hogql").read_text()


def test_maswr_exposes_all_four_segments_and_missing_segments():
    columns, rows = run("maswr.sql")
    values = [dict(zip(columns, row)) for row in rows]
    assert {(row["workflow"], row["analysis_mode"]) for row in values} == {
        ("live", "local"), ("live", "cloud"), ("import", "local"), ("import", "cloud")
    }
    assert next(row for row in values if row["workflow"] == "live" and row["analysis_mode"] == "local")["maswr"] == 1
    assert next(row for row in values if row["workflow"] == "live" and row["analysis_mode"] == "cloud")["evidence_state"] == "missing-segment"


def test_retention_is_truthfully_insufficient_for_short_fixture_window():
    columns, rows = run("retention.sql")
    assert dict(zip(columns, rows[0]))["evidence_state"] == "insufficient-window/data"


def test_activation_reports_bucket_distribution_not_one_label():
    columns, rows = run("activation.sql")
    result = dict(zip(columns, rows[0]))
    assert result["success_1_to_5m"] == 1
    assert result["success_under_1m"] == 0


def test_activation_ignores_completion_before_first_start():
    connection = database()
    connection.executemany(
        "INSERT INTO events(event_name,timestamp_utc,schema_version,environment,installation_id,duration_bucket_ms) "
        "VALUES(?,?,1,'development','i3',300000)",
        [
            ("workflow_completed", "2026-01-03T00:00:00Z"),
            ("workflow_started", "2026-01-03T01:00:00Z"),
            ("workflow_completed", "2026-01-03T02:00:00Z"),
        ],
    )
    cursor = connection.execute((SQL_ROOT / "activation.sql").read_text(), PARAMS)
    result = dict(zip([item[0] for item in cursor.description], cursor.fetchone()))
    assert result["started_installations"] == 3
    assert result["activated_installations"] == 2
    assert result["success_1_to_5m"] == 1
    assert result["success_30m_plus"] == 1


def test_activation_derives_latency_even_when_the_completion_bucket_is_null():
    connection = database()
    connection.executemany(
        "INSERT INTO events(event_name,timestamp_utc,event_sequence,schema_version,environment,installation_id,duration_bucket_ms) "
        "VALUES(?,?,?,1,'development','i3',?)",
        [
            ("workflow_started", "2026-01-03T00:00:00Z", 1, None),
            ("workflow_completed", "2026-01-03T00:01:00Z", 2, None),
            ("workflow_completed", "2026-01-03T00:02:00Z", 3, 60_000),
        ],
    )
    cursor = connection.execute((SQL_ROOT / "activation.sql").read_text(), PARAMS)
    result = dict(zip([item[0] for item in cursor.description], cursor.fetchone()))
    assert result["activated_installations"] == 2
    assert result["success_under_1m"] == 1
    assert result["success_1_to_5m"] == 1


def test_activation_latency_starts_at_the_installations_first_attempt():
    connection = database()
    connection.executemany(
        "INSERT INTO events(event_name,timestamp_utc,event_sequence,schema_version,environment,installation_id,duration_bucket_ms) "
        "VALUES(?,?,?,1,'development','retrying',?)",
        [
            ("workflow_started", "2026-01-03T00:00:00Z", 1, None),
            ("workflow_failed", "2026-01-03T00:01:00Z", 2, None),
            ("workflow_started", "2026-01-03T01:00:00Z", 3, None),
            ("workflow_completed", "2026-01-03T01:01:00Z", 4, 60_000),
        ],
    )
    cursor = connection.execute((SQL_ROOT / "activation.sql").read_text(), PARAMS)
    result = dict(zip([item[0] for item in cursor.description], cursor.fetchone()))
    assert result["success_30m_plus"] == 1


def test_activation_excludes_installations_started_before_the_window():
    connection = database()
    connection.executemany(
        "INSERT INTO events(event_name,timestamp_utc,event_sequence,schema_version,environment,installation_id,duration_bucket_ms) "
        "VALUES(?,?,?,1,'development','returning',300000)",
        [
            ("workflow_started", "2025-12-31T00:00:00Z", 1),
            ("workflow_started", "2026-01-03T00:00:00Z", 2),
            ("workflow_completed", "2026-01-03T00:01:00Z", 3),
        ],
    )
    cursor = connection.execute((SQL_ROOT / "activation.sql").read_text(), PARAMS)
    result = dict(zip([item[0] for item in cursor.description], cursor.fetchone()))
    assert result["started_installations"] == 2
    assert result["activated_installations"] == 1


def test_retention_counts_only_cohorts_with_fully_observable_return_windows():
    connection = database()
    connection.execute(
        "INSERT INTO events(event_name,timestamp_utc,schema_version,environment,installation_id) "
        "VALUES('telemetry_consent_changed','2025-12-31T23:59:00Z',1,'development','i1')"
    )
    connection.executemany(
        "INSERT INTO events(event_name,timestamp_utc,schema_version,environment,installation_id) "
        "VALUES(?,?,1,'development',?)",
        [
            ("telemetry_consent_changed", "2025-12-26T23:59:00Z", "returning"),
            ("workflow_completed", "2025-12-27T00:00:00Z", "returning"),
            ("workflow_completed", "2026-01-03T00:00:00Z", "returning"),
            ("telemetry_consent_changed", "2025-11-30T23:59:00Z", "unobserved"),
            ("workflow_completed", "2025-12-01T00:00:00Z", "unobserved"),
            ("workflow_completed", "2025-12-08T00:00:00Z", "unobserved"),
        ],
    )
    cursor = connection.execute((SQL_ROOT / "retention.sql").read_text(), PARAMS)
    result = dict(zip([item[0] for item in cursor.description], cursor.fetchone()))
    assert result["mature_7d_cohort_installations"] == 2
    assert result["retained_7d"] == 1


def test_d28_retention_is_observable_inside_the_thirty_day_raw_window():
    connection = database()
    connection.execute("DELETE FROM events")
    connection.executemany(
        "INSERT INTO events(event_name,timestamp_utc,schema_version,environment,installation_id) "
        "VALUES(?,?,1,'development','d28')",
        [
            ("telemetry_consent_changed", "2026-01-01T00:00:00Z"),
            ("workflow_completed", "2026-01-01T00:01:00Z"),
            ("workflow_completed", "2026-01-29T00:01:00Z"),
        ],
    )
    cursor = connection.execute((SQL_ROOT / "retention.sql").read_text(), {
        **PARAMS,
        "window_start": "2026-01-01T00:00:00Z",
        "window_end": "2026-01-30T00:00:00Z",
    })
    result = dict(zip([item[0] for item in cursor.description], cursor.fetchone()))
    assert result["mature_28d_cohort_installations"] == 1
    assert result["retained_28d"] == 1


def test_retention_does_not_recohort_a_surviving_success_without_its_consent_anchor():
    connection = database()
    connection.execute("DELETE FROM events")
    connection.executemany(
        "INSERT INTO events(event_name,timestamp_utc,schema_version,environment,installation_id) "
        "VALUES('workflow_completed',?,1,'development','expired-cohort')",
        [("2026-01-02T00:00:00Z",), ("2026-01-10T00:00:00Z",)],
    )

    cursor = connection.execute((SQL_ROOT / "retention.sql").read_text(), PARAMS)
    result = dict(zip([item[0] for item in cursor.description], cursor.fetchone()))

    assert result["unproven_cohort_installations"] == 1
    assert result["mature_7d_cohort_installations"] == 0
    assert result["retained_7d"] == 0
    assert result["evidence_state"] == "insufficient-window/data"


def test_recovery_does_not_cross_analysis_mode_or_window_end():
    connection = database()
    connection.execute("UPDATE events SET analysis_mode='local' WHERE event_name='recovery_completed'")
    cursor = connection.execute((SQL_ROOT / "recovery.sql").read_text(), PARAMS)
    result = dict(zip([item[0] for item in cursor.description], cursor.fetchone()))
    assert result["actionable_failures"] == 1
    assert result["recovered_failures"] == 0


def test_recovery_counts_only_successful_completion():
    connection = database()
    connection.execute("UPDATE events SET outcome='failed' WHERE event_name='recovery_completed'")
    cursor = connection.execute((SQL_ROOT / "recovery.sql").read_text(), PARAMS)
    result = dict(zip([item[0] for item in cursor.description], cursor.fetchone()))
    assert result["recovered_failures"] == 0
    assert result["recovery_rate"] == 0


def test_reopened_record_recovery_pairs_without_polluting_maswr_quality():
    connection = database()
    connection.executemany(
        """INSERT INTO events(event_name,timestamp_utc,event_sequence,schema_version,environment,
        app_version,app_build,installation_id,app_session_id,workflow,attempt_sequence,analysis_mode,
        provider_class,phase,outcome,error_code,recovery_action,duration_bucket_ms,latency_bucket_ms)
        VALUES(?,?,?,1,'development','1.0','1','reopened-only','reopened-only-session','live',1,'local','local','reviewing',?,?,?,300000,1000)""",
        [
            ("record_reopened", "2026-01-04T00:00:00Z", 6, None, None, None),
            ("workflow_failed", "2026-01-04T00:00:01Z", 7, "failed", "storage", "retry"),
            ("recovery_completed", "2026-01-04T00:00:02Z", 8, "succeeded", None, "retry"),
        ],
    )
    recovery = connection.execute((SQL_ROOT / "recovery.sql").read_text(), PARAMS)
    recovery_result = dict(zip([item[0] for item in recovery.description], recovery.fetchone()))
    assert (recovery_result["actionable_failures"], recovery_result["recovered_failures"]) == (2, 2)

    maswr = connection.execute((SQL_ROOT / "maswr.sql").read_text(), PARAMS)
    rows = [dict(zip([item[0] for item in maswr.description], row)) for row in maswr.fetchall()]
    assert all(row["evidence_state"] != "incomplete" for row in rows)

    quality = connection.execute((SQL_ROOT / "data_quality.sql").read_text(), PARAMS)
    quality_result = dict(zip([item[0] for item in quality.description], quality.fetchone()))
    assert quality_result["orphan_boundary_terminals"] == 0
    assert quality_result["evidence_state"] == "complete"

    funnel = connection.execute((SQL_ROOT / "funnel.sql").read_text(), PARAMS)
    funnel_result = dict(zip([item[0] for item in funnel.description], funnel.fetchone()))
    assert funnel_result["evidence_state"] != "incomplete"


def test_retention_excludes_returns_before_exact_window_start():
    connection = database()
    connection.executemany(
        """INSERT INTO events(event_name,timestamp_utc,event_sequence,schema_version,environment,
        app_version,app_build,installation_id,app_session_id,workflow,attempt_sequence,analysis_mode,
        provider_class,phase,outcome,recovery_action,duration_bucket_ms,latency_bucket_ms)
        VALUES(?,?,?,1,'development','1.0','1','exact-window','retention-session','live',1,'local',
        'local','finalizing','succeeded','none',300000,1000)""",
        [
            ("telemetry_consent_changed", "2025-12-25T00:00:00Z", 1),
            ("workflow_completed", "2025-12-25T00:01:00Z", 2),
            ("workflow_completed", "2026-01-01T09:00:00Z", 3),
        ],
    )
    params = {**PARAMS, "window_start": "2026-01-01T12:00:00Z"}

    cursor = connection.execute((SQL_ROOT / "retention.sql").read_text(), params)
    result = dict(zip([item[0] for item in cursor.description], cursor.fetchone()))

    assert result["mature_7d_cohort_installations"] == 0
    assert result["retained_7d"] == 0


def test_failure_without_any_context_fails_closed():
    connection = database()
    connection.execute(
        """INSERT INTO events(event_name,timestamp_utc,event_sequence,schema_version,environment,
        app_version,app_build,installation_id,app_session_id,workflow,analysis_mode,provider_class,
        phase,outcome,error_code,recovery_action,duration_bucket_ms,latency_bucket_ms)
        VALUES('workflow_failed','2026-01-06T00:00:00Z',1,1,'development','1.0','1',
        'orphan-failure','orphan-failure-session','live','local','local','analysis','failed','unknown','retry',300000,1000)"""
    )

    quality = connection.execute((SQL_ROOT / "data_quality.sql").read_text(), PARAMS)
    quality_result = dict(zip([item[0] for item in quality.description], quality.fetchone()))
    assert quality_result["orphan_boundary_terminals"] == 1
    assert quality_result["evidence_state"] == "incomplete"

    for query_name in ["maswr.sql", "funnel.sql"]:
        cursor = connection.execute((SQL_ROOT / query_name).read_text(), PARAMS)
        rows = [dict(zip([item[0] for item in cursor.description], row)) for row in cursor.fetchall()]
        assert all(row["evidence_state"] == "incomplete" for row in rows)


def test_funnel_does_not_join_different_workflows_in_one_session():
    connection = database()
    connection.execute(
        "UPDATE events SET workflow='import' WHERE app_session_id='s1' AND event_name IN "
        "('record_saved','smart_minutes_review_opened','export_completed')"
    )
    cursor = connection.execute((SQL_ROOT / "funnel.sql").read_text(), PARAMS)
    result = dict(zip([item[0] for item in cursor.description], cursor.fetchone()))
    assert result["started"] == 2
    assert result["record_saved"] == 0


def test_funnel_orders_same_second_stages_by_event_sequence():
    connection = database()
    connection.executemany(
        """INSERT INTO events(event_name,timestamp_utc,event_sequence,schema_version,environment,
        app_version,app_build,installation_id,app_session_id,workflow,analysis_mode,provider_class,phase,outcome)
        VALUES(?,?,?,1,'development','1.0','1','same-second','same-second-session','live','local','local','reviewing',?)""",
        [
            ("workflow_started", "2026-01-03T00:00:00Z", 1, None),
            ("record_saved", "2026-01-03T00:01:00Z", 2, None),
            ("export_completed", "2026-01-03T00:02:00Z", 3, "succeeded"),
            ("smart_minutes_review_opened", "2026-01-03T00:02:00Z", 4, None),
        ],
    )

    cursor = connection.execute((SQL_ROOT / "funnel.sql").read_text(), PARAMS)
    result = dict(zip([item[0] for item in cursor.description], cursor.fetchone()))

    assert result["started"] == 3
    assert result["review_opened"] == 2
    assert result["export_completed"] == 1


def test_empty_funnel_recovery_and_latency_are_insufficient_data():
    connection = database()
    connection.execute("DELETE FROM events")
    for name in ["funnel.sql", "recovery.sql", "latency_guardrails.sql"]:
        cursor = connection.execute((SQL_ROOT / name).read_text(), PARAMS)
        result = dict(zip([item[0] for item in cursor.description], cursor.fetchone()))
        assert result["evidence_state"] == "insufficient-data"


def test_orphan_only_funnel_preserves_incomplete_quality_state():
    connection = database()
    connection.execute("DELETE FROM events")
    connection.execute(
        """INSERT INTO events(event_name,timestamp_utc,event_sequence,schema_version,environment,
        app_session_id,workflow,analysis_mode,provider_class,phase,outcome)
        VALUES('workflow_completed','2026-01-03T00:00:00Z',1,1,'development',
        'orphan-only','live','local','local','finalizing','succeeded')"""
    )

    cursor = connection.execute((SQL_ROOT / "funnel.sql").read_text(), PARAMS)
    result = dict(zip([item[0] for item in cursor.description], cursor.fetchone()))

    assert result["started"] == 0
    assert result["evidence_state"] == "incomplete"


def test_data_quality_reports_duplicate_and_unknown_schema_as_incomplete():
    connection = database()
    connection.execute("INSERT INTO events(event_name,timestamp_utc,schema_version,environment) VALUES('workflow_started','2026-01-03',99,'development')")
    connection.execute("INSERT INTO events SELECT * FROM events WHERE event_name='workflow_completed' LIMIT 1")
    query = (SQL_ROOT / "data_quality.sql").read_text()
    cursor = connection.execute(query, PARAMS)
    result = dict(zip([item[0] for item in cursor.description], cursor.fetchone()))
    assert result["unknown_schema"] == 1
    assert result["duplicate_attempt_groups"] == 1
    assert result["evidence_state"] == "incomplete"


def test_data_quality_rejects_unknown_enums_and_numeric_bounds():
    connection = database()
    connection.execute("UPDATE events SET provider_class='secret-provider', retry_count=99, latency_bucket_ms=123 WHERE event_name='workflow_failed'")
    cursor = connection.execute((SQL_ROOT / "data_quality.sql").read_text(), PARAMS)
    result = dict(zip([item[0] for item in cursor.description], cursor.fetchone()))
    assert result["unknown_provider_class"] == 1
    assert result["out_of_bounds"] == 1
    assert result["unknown_latency_bucket"] == 1
    assert result["evidence_state"] == "incomplete"


def test_data_quality_rejects_terminal_events_without_guardrail_dimensions():
    connection = database()
    connection.execute(
        "UPDATE events SET provider_class=NULL,latency_bucket_ms=NULL WHERE event_name='workflow_failed'"
    )
    cursor = connection.execute((SQL_ROOT / "data_quality.sql").read_text(), PARAMS)
    result = dict(zip([item[0] for item in cursor.description], cursor.fetchone()))
    assert result["missing_terminal_dimensions"] == 1
    assert result["evidence_state"] == "incomplete"


def test_maswr_propagates_duplicate_terminal_evidence_as_incomplete():
    connection = database()
    connection.execute("INSERT INTO events SELECT * FROM events WHERE event_name='workflow_completed' LIMIT 1")
    cursor = connection.execute((SQL_ROOT / "maswr.sql").read_text(), PARAMS)
    rows = [dict(zip([item[0] for item in cursor.description], row)) for row in cursor.fetchall()]
    assert all(row["evidence_state"] == "incomplete" for row in rows)


def test_attempt_started_before_window_is_excluded_without_poisoning_quality():
    connection = database()
    connection.executemany(
        """INSERT INTO events(event_name,timestamp_utc,event_sequence,schema_version,environment,
        app_version,app_build,installation_id,app_session_id,workflow,attempt_sequence,analysis_mode,
        provider_class,phase,outcome,recovery_action,duration_bucket_ms,latency_bucket_ms)
        VALUES(?,?,?,1,'development','1.0','1','boundary','boundary-session','live',1,'local',
        'local',?,?, 'none',300000,1000)""",
        [
            ("workflow_started", "2025-12-31T23:59:00Z", 1, "preparing", None),
            ("workflow_completed", "2026-01-01T00:00:30Z", 2, "finalizing", "succeeded"),
        ],
    )

    quality = connection.execute((SQL_ROOT / "data_quality.sql").read_text(), PARAMS)
    quality_result = dict(zip([item[0] for item in quality.description], quality.fetchone()))
    assert quality_result["duplicate_attempt_groups"] == 0
    assert quality_result["evidence_state"] == "complete"

    cursor = connection.execute((SQL_ROOT / "maswr.sql").read_text(), PARAMS)
    rows = [dict(zip([item[0] for item in cursor.description], row)) for row in cursor.fetchall()]
    assert all(row["evidence_state"] != "incomplete" for row in rows)


def test_terminal_without_retained_start_fails_closed():
    connection = database()
    connection.execute(
        """INSERT INTO events(event_name,timestamp_utc,event_sequence,schema_version,environment,
        app_version,app_build,installation_id,app_session_id,workflow,attempt_sequence,analysis_mode,
        provider_class,phase,outcome,recovery_action,duration_bucket_ms,latency_bucket_ms)
        VALUES('workflow_completed','2026-01-01T00:00:30Z',1,1,'development','1.0','1',
        'orphan','orphan-session','live',1,'local','local','finalizing','succeeded','none',300000,1000)"""
    )

    quality = connection.execute((SQL_ROOT / "data_quality.sql").read_text(), PARAMS)
    quality_result = dict(zip([item[0] for item in quality.description], quality.fetchone()))
    assert quality_result["orphan_boundary_terminals"] == 1
    assert quality_result["evidence_state"] == "incomplete"

    cursor = connection.execute((SQL_ROOT / "maswr.sql").read_text(), PARAMS)
    rows = [dict(zip([item[0] for item in cursor.description], row)) for row in cursor.fetchall()]
    assert all(row["evidence_state"] == "incomplete" for row in rows)

    funnel = connection.execute((SQL_ROOT / "funnel.sql").read_text(), PARAMS)
    assert dict(zip([item[0] for item in funnel.description], funnel.fetchone()))["evidence_state"] == "incomplete"


def test_pre_window_terminal_does_not_mask_overlapping_in_window_starts():
    connection = database()
    connection.executemany(
        """INSERT INTO events(event_name,timestamp_utc,event_sequence,schema_version,environment,
        app_version,app_build,installation_id,app_session_id,workflow,attempt_sequence,analysis_mode,
        provider_class,phase,outcome,recovery_action,duration_bucket_ms,latency_bucket_ms)
        VALUES(?,?,?,1,'development','1.0','1','masked-overlap','masked-overlap-session','live',1,'local',
        'local',?,?, 'none',300000,1000)""",
        [
            ("workflow_started", "2025-12-31T23:59:00Z", 1, "preparing", None),
            ("workflow_started", "2026-01-01T00:01:00Z", 2, "preparing", None),
            ("workflow_completed", "2026-01-01T00:01:30Z", 3, "finalizing", "succeeded"),
            ("workflow_started", "2026-01-01T00:02:00Z", 4, "preparing", None),
            ("workflow_completed", "2026-01-01T00:03:00Z", 5, "finalizing", "succeeded"),
        ],
    )

    quality = connection.execute((SQL_ROOT / "data_quality.sql").read_text(), PARAMS)
    quality_result = dict(zip([item[0] for item in quality.description], quality.fetchone()))
    assert quality_result["overlapping_attempts"] == 1
    assert quality_result["orphan_boundary_terminals"] == 0
    assert quality_result["ambiguous_boundary_starts"] == 1
    assert quality_result["evidence_state"] == "incomplete"

    cursor = connection.execute((SQL_ROOT / "maswr.sql").read_text(), PARAMS)
    rows = [dict(zip([item[0] for item in cursor.description], row)) for row in cursor.fetchall()]
    assert all(row["evidence_state"] == "incomplete" for row in rows)

    funnel = connection.execute((SQL_ROOT / "funnel.sql").read_text(), PARAMS)
    assert dict(zip([item[0] for item in funnel.description], funnel.fetchone()))["evidence_state"] == "incomplete"


def test_reopened_record_stages_do_not_complete_an_older_funnel_attempt():
    connection = database()
    connection.executemany(
        """INSERT INTO events(event_name,timestamp_utc,event_sequence,schema_version,environment,
        app_version,app_build,installation_id,app_session_id,workflow,attempt_sequence,analysis_mode,
        provider_class,phase,outcome,recovery_action,duration_bucket_ms,latency_bucket_ms)
        VALUES(?,?,?,1,'development','1.0','1','reopen','reopen-session','live',1,'local',
        'local','reviewing',?,'none',300000,1000)""",
        [
            ("workflow_started", "2026-01-05T00:00:00Z", 1, None),
            ("record_saved", "2026-01-05T00:01:00Z", 2, None),
            ("smart_minutes_review_opened", "2026-01-05T00:02:00Z", 3, None),
            ("record_reopened", "2026-01-05T00:03:00Z", 4, None),
            ("export_completed", "2026-01-05T00:04:00Z", 5, "succeeded"),
        ],
    )

    funnel = connection.execute((SQL_ROOT / "funnel.sql").read_text(), PARAMS)
    result = dict(zip([item[0] for item in funnel.description], funnel.fetchone()))
    assert result["started"] == 3
    assert result["record_saved"] == 2
    assert result["review_opened"] == 2
    assert result["export_completed"] == 1
    assert result["evidence_state"] == "incomplete"


def test_sequential_live_attempts_in_one_app_session_are_not_duplicates():
    connection = database()
    connection.execute(
        "INSERT INTO events SELECT event_name,REPLACE(timestamp_utc,'2026-01-01','2026-01-03'),event_sequence,"
        "schema_version,environment,app_version,app_build,installation_id,app_session_id,workflow,attempt_sequence+1,"
        "analysis_mode,provider_class,phase,outcome,error_code,recovery_action,duration_bucket_ms,"
        "latency_bucket_ms,retry_count,result_count,module_count,quality_score FROM events WHERE app_session_id='s1'"
    )
    quality = connection.execute((SQL_ROOT / "data_quality.sql").read_text(), PARAMS)
    quality_result = dict(zip([item[0] for item in quality.description], quality.fetchone()))
    assert quality_result["duplicate_attempt_groups"] == 0

    cursor = connection.execute((SQL_ROOT / "maswr.sql").read_text(), PARAMS)
    rows = [dict(zip([item[0] for item in cursor.description], row)) for row in cursor.fetchall()]
    live_local = next(row for row in rows if row["workflow"] == "live" and row["analysis_mode"] == "local")
    assert live_local["eligible_attempts"] == 2
    assert live_local["successful_attempts"] == 2
    assert live_local["evidence_state"] == "requires-reconciliation"

    funnel = connection.execute((SQL_ROOT / "funnel.sql").read_text(), PARAMS)
    funnel_result = dict(zip([item[0] for item in funnel.description], funnel.fetchone()))
    assert funnel_result["started"] == 3
    assert funnel_result["export_completed"] == 2


def test_terminal_actual_path_owns_attempt_segment_after_local_fallback():
    connection = database()
    connection.execute(
        "UPDATE events SET analysis_mode='cloud',provider_class='byok' "
        "WHERE app_session_id='s1' AND event_name='workflow_started'"
    )
    quality = connection.execute((SQL_ROOT / "data_quality.sql").read_text(), PARAMS)
    quality_result = dict(zip([item[0] for item in quality.description], quality.fetchone()))
    assert quality_result["duplicate_attempt_groups"] == 0

    cursor = connection.execute((SQL_ROOT / "maswr.sql").read_text(), PARAMS)
    rows = [dict(zip([item[0] for item in cursor.description], row)) for row in cursor.fetchall()]
    live_local = next(row for row in rows if row["workflow"] == "live" and row["analysis_mode"] == "local")
    live_cloud = next(row for row in rows if row["workflow"] == "live" and row["analysis_mode"] == "cloud")
    assert (live_local["eligible_attempts"], live_local["successful_attempts"]) == (1, 1)
    assert live_local["evidence_state"] == "requires-reconciliation"
    assert (live_cloud["eligible_attempts"], live_cloud["successful_attempts"]) == (0, 0)


def test_overlapping_attempts_fail_closed_without_remote_attempt_correlation():
    connection = database()
    connection.execute(
        "UPDATE events SET analysis_mode='cloud',provider_class='byok' WHERE app_session_id='s1'"
    )
    connection.executemany(
        """INSERT INTO events(event_name,timestamp_utc,event_sequence,schema_version,environment,
        app_version,app_build,installation_id,app_session_id,workflow,attempt_sequence,analysis_mode,provider_class,
        phase,outcome,error_code,recovery_action,duration_bucket_ms,latency_bucket_ms)
        VALUES(?,?,?,1,'development','1.0','1','i1','s1','live',2,?,?,'running',?,?,'none',300000,1000)""",
        [
            ("workflow_started", "2026-01-01T00:03:30Z", 6, "local", "local", None, None),
            ("workflow_failed", "2026-01-01T00:04:00Z", 7, "local", "local", "failed", "unknown"),
        ],
    )
    quality = connection.execute((SQL_ROOT / "data_quality.sql").read_text(), PARAMS)
    quality_result = dict(zip([item[0] for item in quality.description], quality.fetchone()))
    assert quality_result["overlapping_attempts"] == 1
    assert quality_result["evidence_state"] == "incomplete"

    cursor = connection.execute((SQL_ROOT / "maswr.sql").read_text(), PARAMS)
    rows = [dict(zip([item[0] for item in cursor.description], row)) for row in cursor.fetchall()]
    assert all(row["evidence_state"] == "incomplete" for row in rows)


def test_recovered_pre_window_attempt_counts_as_one_closed_attempt():
    connection = database()
    connection.executemany(
        """INSERT INTO events(event_name,timestamp_utc,event_sequence,schema_version,environment,
        app_version,app_build,installation_id,app_session_id,workflow,attempt_sequence,analysis_mode,provider_class,
        phase,outcome,error_code,recovery_action,duration_bucket_ms,latency_bucket_ms)
        VALUES(?,?,?,1,'development','1.0','1','boundary-recovery','boundary-recovery-session','live',?,
        'local','local','running',?,?,?,300000,1000)""",
        [
            ("workflow_started", "2025-12-30T00:00:00Z", 1, 1, None, None, "none"),
            ("workflow_failed", "2025-12-30T00:01:00Z", 2, 1, "failed", "unknown", "retry"),
            ("workflow_completed", "2025-12-30T00:02:00Z", 3, 1, "succeeded", None, "none"),
            ("workflow_started", "2025-12-31T00:00:00Z", 4, 2, None, None, "none"),
            ("workflow_failed", "2026-01-01T00:01:00Z", 5, 2, "failed", "unknown", "none"),
        ],
    )

    quality = connection.execute((SQL_ROOT / "data_quality.sql").read_text(), PARAMS)
    quality_result = dict(zip([item[0] for item in quality.description], quality.fetchone()))
    assert quality_result["orphan_boundary_terminals"] == 0
    assert quality_result["evidence_state"] == "complete"

    for query_name in ["maswr.sql", "funnel.sql"]:
        cursor = connection.execute((SQL_ROOT / query_name).read_text(), PARAMS)
        rows = [dict(zip([item[0] for item in cursor.description], row)) for row in cursor.fetchall()]
        assert all(row["evidence_state"] != "incomplete" for row in rows)

    for query_name in ["maswr.hogql", "data_quality.hogql", "funnel.hogql"]:
        assert "pre_window_attempts" in (POSTHOG_SQL_ROOT / query_name).read_text()
