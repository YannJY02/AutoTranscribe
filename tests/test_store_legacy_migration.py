import sqlite3
from unittest import mock

import pytest

from insightkit.data import store as store_module


@pytest.mark.parametrize("use_default_path", [True, False])
@pytest.mark.parametrize("ui_test_mode, should_migrate", [("1", False), (None, True), ("0", True)])
def test_legacy_migration_skips_ui_tests_only(tmp_path, monkeypatch, use_default_path, ui_test_mode, should_migrate):
    legacy_path = tmp_path / "synthetic-legacy.db"
    connection = sqlite3.connect(legacy_path)
    try:
        connection.execute("CREATE TABLE legacy_fixture (value TEXT NOT NULL)")
        connection.execute("INSERT INTO legacy_fixture VALUES (?)", ("synthetic source record",))
        connection.commit()
    finally:
        connection.close()

    legacy = mock.Mock(wraps=legacy_path)
    monkeypatch.setattr(store_module, "LEGACY_DB", legacy)
    destination = tmp_path / "fresh-destination" / "insightkit.db"
    monkeypatch.setattr(store_module, "DEFAULT_DB", destination)
    if ui_test_mode is None:
        monkeypatch.delenv("INSIGHTKIT_UI_TEST_MODE", raising=False)
    else:
        monkeypatch.setenv("INSIGHTKIT_UI_TEST_MODE", ui_test_mode)

    store = store_module.InsightStore() if use_default_path else store_module.InsightStore(db_path=destination)
    try:
        store.init_schema()
        copied = store.conn.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'legacy_fixture'"
        ).fetchone()
        assert bool(copied) is should_migrate
        if should_migrate:
            assert store.conn.execute("SELECT value FROM legacy_fixture").fetchone()[0] == "synthetic source record"
            legacy.read_bytes.assert_called_once_with()
        else:
            legacy.exists.assert_not_called()
            legacy.read_bytes.assert_not_called()
        store.upsert_meeting("synthetic-new", "Fresh session", "test", "ready")
        assert store.get_meeting("synthetic-new")["title"] == "Fresh session"
    finally:
        store.close()
