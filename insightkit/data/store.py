"""SQLite data layer for InsightKit."""

from __future__ import annotations

import os
import sqlite3
from pathlib import Path
from typing import Any

DEFAULT_DB = Path(
    os.getenv(
        "INSIGHTKIT_DB_PATH",
        str(Path.home() / "Library" / "Application Support" / "InsightKit" / "data" / "insightkit.db"),
    )
).expanduser()
LEGACY_DB = Path(__file__).resolve().parent.parent.parent / "logs" / "insightkit.db"


class InsightStore:
    def __init__(self, db_path: Path | None = None):
        self.db_path = db_path or DEFAULT_DB
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._migrate_legacy_db_if_needed()
        self.conn = sqlite3.connect(str(self.db_path), check_same_thread=False, timeout=30.0)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA busy_timeout=8000;")
        self.conn.execute("PRAGMA journal_mode=WAL;")
        self.conn.execute("PRAGMA synchronous=NORMAL;")

    def close(self) -> None:
        self.conn.close()

    def init_schema(self) -> None:
        cur = self.conn.cursor()
        cur.executescript(
            """
            PRAGMA journal_mode=WAL;
            PRAGMA busy_timeout=8000;
            CREATE TABLE IF NOT EXISTS meetings (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                source TEXT NOT NULL,
                started_at TEXT,
                ended_at TEXT,
                status TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS segments (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                meeting_id TEXT NOT NULL,
                start_ms INTEGER NOT NULL,
                end_ms INTEGER NOT NULL,
                speaker TEXT,
                source TEXT DEFAULT '',
                text TEXT NOT NULL,
                confidence REAL DEFAULT 0,
                FOREIGN KEY(meeting_id) REFERENCES meetings(id)
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS segments_fts USING fts5(
                meeting_id,
                text,
                content='segments',
                content_rowid='id'
            );
            CREATE TABLE IF NOT EXISTS insight_packages (
                meeting_id TEXT PRIMARY KEY,
                payload_json TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                FOREIGN KEY(meeting_id) REFERENCES meetings(id)
            );
            CREATE TABLE IF NOT EXISTS exports (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                meeting_id TEXT NOT NULL,
                format TEXT NOT NULL,
                path TEXT NOT NULL,
                created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS transcription_jobs (
                id TEXT PRIMARY KEY,
                meeting_id TEXT NOT NULL,
                source_path TEXT NOT NULL,
                state TEXT NOT NULL,
                progress INTEGER NOT NULL DEFAULT 0,
                stage TEXT NOT NULL DEFAULT '',
                error TEXT NOT NULL DEFAULT '',
                reason TEXT NOT NULL DEFAULT '',
                started_at TEXT NOT NULL,
                ended_at TEXT NOT NULL DEFAULT ''
            );

            CREATE TRIGGER IF NOT EXISTS segments_ai AFTER INSERT ON segments BEGIN
                INSERT INTO segments_fts(rowid, meeting_id, text) VALUES (new.id, new.meeting_id, new.text);
            END;
            CREATE TRIGGER IF NOT EXISTS segments_ad AFTER DELETE ON segments BEGIN
                INSERT INTO segments_fts(segments_fts, rowid, meeting_id, text) VALUES('delete', old.id, old.meeting_id, old.text);
            END;
            CREATE TRIGGER IF NOT EXISTS segments_au AFTER UPDATE ON segments BEGIN
                INSERT INTO segments_fts(segments_fts, rowid, meeting_id, text) VALUES('delete', old.id, old.meeting_id, old.text);
                INSERT INTO segments_fts(rowid, meeting_id, text) VALUES (new.id, new.meeting_id, new.text);
            END;
            """
        )
        self._ensure_column("segments", "source", "TEXT DEFAULT ''")
        self.conn.commit()

    def _migrate_legacy_db_if_needed(self) -> None:
        if self.db_path.exists():
            return
        if not LEGACY_DB.exists():
            return
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            self.db_path.write_bytes(LEGACY_DB.read_bytes())
        except Exception:
            # Legacy migration failure should not block startup.
            return

    def _ensure_column(self, table: str, column: str, definition: str) -> None:
        cur = self.conn.execute(f"PRAGMA table_info({table})")
        columns = {row[1] for row in cur.fetchall()}
        if column in columns:
            return
        self.conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {definition}")
        self.conn.commit()

    def upsert_meeting(self, meeting_id: str, title: str, source: str, status: str) -> None:
        self.conn.execute(
            """
            INSERT INTO meetings(id, title, source, status)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET title=excluded.title, source=excluded.source, status=excluded.status
            """,
            (meeting_id, title, source, status),
        )
        self.conn.commit()

    def get_meeting(self, meeting_id: str) -> dict[str, Any] | None:
        cur = self.conn.execute(
            "SELECT id, title, source, status, started_at, ended_at FROM meetings WHERE id=?",
            (meeting_id,),
        )
        row = cur.fetchone()
        return dict(row) if row else None

    def update_meeting_status(self, meeting_id: str, status: str) -> None:
        self.conn.execute(
            "UPDATE meetings SET status=? WHERE id=?",
            (status, meeting_id),
        )
        self.conn.commit()

    def count_segments(self, meeting_id: str) -> int:
        cur = self.conn.execute(
            "SELECT COUNT(1) FROM segments WHERE meeting_id=?",
            (meeting_id,),
        )
        row = cur.fetchone()
        return int(row[0] if row else 0)

    def insert_segment(
        self,
        meeting_id: str,
        start_ms: int,
        end_ms: int,
        speaker: str,
        text: str,
        confidence: float = 0.0,
        source: str = "",
    ) -> None:
        self.conn.execute(
            """
            INSERT INTO segments(meeting_id, start_ms, end_ms, speaker, source, text, confidence)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (meeting_id, start_ms, end_ms, speaker, source, text, confidence),
        )
        self.conn.commit()

    def list_segments(self, meeting_id: str) -> list[dict[str, Any]]:
        cur = self.conn.execute(
            "SELECT start_ms, end_ms, COALESCE(speaker, '') AS speaker, COALESCE(source, '') AS source, text FROM segments WHERE meeting_id=? ORDER BY start_ms",
            (meeting_id,),
        )
        return [dict(row) for row in cur.fetchall()]

    def search_segments(self, meeting_id: str, query: str, limit: int = 20) -> list[dict[str, Any]]:
        cur = self.conn.execute(
            """
            SELECT s.start_ms, s.end_ms, COALESCE(s.speaker, '') AS speaker, COALESCE(s.source, '') AS source, s.text
            FROM segments_fts f
            JOIN segments s ON s.id = f.rowid
            WHERE f.meeting_id = ? AND segments_fts MATCH ?
            ORDER BY rank
            LIMIT ?
            """,
            (meeting_id, query, limit),
        )
        return [dict(row) for row in cur.fetchall()]

    def upsert_transcription_job(
        self,
        *,
        job_id: str,
        meeting_id: str,
        source_path: str,
        state: str,
        progress: int,
        stage: str,
        started_at: str,
        error: str = "",
        reason: str = "",
        ended_at: str = "",
    ) -> None:
        self.conn.execute(
            """
            INSERT INTO transcription_jobs(
                id, meeting_id, source_path, state, progress, stage, error, reason, started_at, ended_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                meeting_id=excluded.meeting_id,
                source_path=excluded.source_path,
                state=excluded.state,
                progress=excluded.progress,
                stage=excluded.stage,
                error=excluded.error,
                reason=excluded.reason,
                started_at=excluded.started_at,
                ended_at=excluded.ended_at
            """,
            (
                job_id,
                meeting_id,
                source_path,
                state,
                int(max(0, min(100, progress))),
                stage,
                error,
                reason,
                started_at,
                ended_at,
            ),
        )
        self.conn.commit()

    def get_transcription_job(self, job_id: str) -> dict[str, Any] | None:
        cur = self.conn.execute(
            """
            SELECT
                id,
                meeting_id,
                source_path,
                state,
                progress,
                stage,
                error,
                reason,
                started_at,
                ended_at
            FROM transcription_jobs
            WHERE id=?
            """,
            (job_id,),
        )
        row = cur.fetchone()
        return dict(row) if row else None

    def list_transcription_jobs(self, limit: int = 50) -> list[dict[str, Any]]:
        cur = self.conn.execute(
            """
            SELECT
                id,
                meeting_id,
                source_path,
                state,
                progress,
                stage,
                error,
                reason,
                started_at,
                ended_at
            FROM transcription_jobs
            ORDER BY started_at DESC
            LIMIT ?
            """,
            (limit,),
        )
        return [dict(row) for row in cur.fetchall()]
