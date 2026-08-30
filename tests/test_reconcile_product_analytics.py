from scripts.reconcile_product_analytics import reconcile


def manifest(**overrides):
    value = {
        "schema_version": 1, "environment": "development", "window_start": "2026-01-01",
        "window_end": "2026-01-02", "event_counts": {"workflow_started|live|local": 2},
    }
    value.update(overrides)
    return value


def remote(**overrides):
    value = manifest()
    value.update(overrides)
    return value


def test_aggregate_reconciliation_is_complete_only_for_exact_counts():
    result = reconcile(manifest(), remote())
    assert result["evidence_state"] == "complete"
    assert "attempt" not in str(result).lower()


def test_reconciliation_preserves_explicit_incomplete_states():
    assert reconcile(manifest(), remote(event_counts={}))["evidence_state"] == "partial-ingestion"
    assert reconcile(manifest(offline_pending=1), remote(event_counts={}))["evidence_state"] == "late-offline-delivery"
    assert reconcile(manifest(opted_out=True), remote())["evidence_state"] == "opt-out"
    assert reconcile(manifest(deletion_pending=True), remote())["evidence_state"] == "deletion-pending"
    assert reconcile(manifest(), remote(query_error="timeout"))["evidence_state"] == "query-failure"


def test_reconciliation_rejects_wrong_environment_window_or_schema():
    for mismatch in [
        {"schema_version": 2}, {"environment": "release"},
        {"window_start": "2025-01-01"}, {"window_end": "2027-01-01"},
    ]:
        assert reconcile(manifest(), remote(**mismatch))["evidence_state"] == "readback-contract-mismatch"


def test_reconciliation_rejects_missing_contract_and_adapts_sql_rows():
    assert reconcile({}, {})["evidence_state"] == "readback-contract-mismatch"
    rows = [{
        "schema_version": 1, "environment": "development", "window_start": "2026-01-01",
        "window_end": "2026-01-02", "event_name": "workflow_started", "workflow": "live",
        "analysis_mode": "local", "remote_count": 2,
    }]
    assert reconcile(manifest(), rows)["evidence_state"] == "complete"
