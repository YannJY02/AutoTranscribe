from __future__ import annotations

from datetime import datetime, timezone
from hashlib import sha256

from insightkit.data.store import InsightStore
from scripts.run_real_import_e2e import evaluate_database_oracle, fts_index_is_consistent


def seed_completed_import(tmp_path):
    db_path = tmp_path / "insightkit.db"
    store = InsightStore(db_path)
    store.init_schema()
    now = datetime.now(timezone.utc).isoformat()
    store.upsert_meeting("meeting-1", "Fixture", "file", status="stopped")
    store.insert_segment("meeting-1", 0, 1_000, "A", "hello world", source="file")
    store.insert_segment("meeting-1", 1_000, 2_000, "B", "second segment", source="file")
    store.upsert_insight_package("meeting-1", {"session_overview": {}}, now)
    store.upsert_transcription_job(
        job_id="job-1",
        meeting_id="meeting-1",
        source_path=str(tmp_path / "fixture.m4a"),
        state="completed",
        progress=100,
        stage="completed",
        started_at=now,
        ended_at=now,
    )
    store.close()
    return db_path


def test_database_oracle_passes_for_completed_import(tmp_path):
    db_path = seed_completed_import(tmp_path)

    result = evaluate_database_oracle(
        db_path,
        meeting_id="meeting-1",
        job_id="job-1",
        expected_source_path=tmp_path / "fixture.m4a",
        expected_segment_count=2,
    )

    assert result["passed"] is True
    assert all(check["passed"] for check in result["assertions"].values())


def test_database_oracle_reports_invalid_job_and_timeline(tmp_path):
    db_path = seed_completed_import(tmp_path)
    store = InsightStore(db_path)
    store.conn.execute(
        "UPDATE transcription_jobs SET state='running', progress=60, ended_at='' WHERE id='job-1'"
    )
    store.conn.execute("UPDATE segments SET end_ms=start_ms WHERE meeting_id='meeting-1'")
    store.conn.commit()
    store.close()

    result = evaluate_database_oracle(
        db_path,
        meeting_id="meeting-1",
        job_id="job-1",
        expected_source_path=tmp_path / "fixture.m4a",
        expected_segment_count=2,
    )

    assert result["passed"] is False
    assert result["assertions"]["job_completed"]["passed"] is False
    assert result["assertions"]["job_progress_complete"]["passed"] is False
    assert result["assertions"]["job_has_end_time"]["passed"] is False
    assert result["assertions"]["segment_timeline_valid"]["passed"] is False


def test_database_oracle_detects_segment_missing_from_fts_index(tmp_path):
    db_path = seed_completed_import(tmp_path)
    store = InsightStore(db_path)
    segment = store.conn.execute(
        "SELECT id, meeting_id, text FROM segments ORDER BY id LIMIT 1"
    ).fetchone()
    store.conn.execute(
        """
        INSERT INTO segments_fts(segments_fts, rowid, meeting_id, text)
        VALUES('delete', ?, ?, ?)
        """,
        (segment["id"], segment["meeting_id"], segment["text"]),
    )
    store.conn.commit()
    store.close()

    result = evaluate_database_oracle(
        db_path,
        meeting_id="meeting-1",
        job_id="job-1",
        expected_source_path=tmp_path / "fixture.m4a",
        expected_segment_count=2,
    )

    assert result["passed"] is False
    assert result["assertions"]["fts_index_complete"]["passed"] is False


def test_fts_integrity_check_uses_snapshot_without_mutating_source(tmp_path):
    db_path = seed_completed_import(tmp_path)
    store = InsightStore(db_path)
    segment = store.conn.execute(
        "SELECT id, meeting_id, text FROM segments ORDER BY id LIMIT 1"
    ).fetchone()
    store.conn.execute(
        """
        INSERT INTO segments_fts(segments_fts, rowid, meeting_id, text)
        VALUES('delete', ?, ?, ?)
        """,
        (segment["id"], segment["meeting_id"], segment["text"]),
    )
    store.conn.commit()
    store.close()
    source_digest = sha256(db_path.read_bytes()).hexdigest()

    assert fts_index_is_consistent(db_path) is False
    assert sha256(db_path.read_bytes()).hexdigest() == source_digest
