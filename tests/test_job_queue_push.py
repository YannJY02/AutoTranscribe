"""Tests for JobQueue push event integration."""
import unittest
from unittest import mock

from insightkit.ipc.push_broker import PushBroker
from insightkit.ipc.job_queue import JobQueue


class TestJobQueuePush(unittest.TestCase):
    def test_update_progress_emits_event(self):
        """_update_progress calls push_broker.emit with transcription.progress."""
        broker = mock.create_autospec(PushBroker, instance=True)
        store = mock.MagicMock()
        store.upsert_transcription_job = mock.MagicMock()
        insight = mock.MagicMock()
        watch = mock.MagicMock()
        jq = JobQueue(store=store, insight_service=insight, watch_bridge=watch, push_broker=broker)

        jq._jobs["j1"] = {
            "id": "j1", "meeting_id": "m1", "source_path": "/tmp/f.mp4",
            "title": "test", "state": "running", "progress": 10,
            "stage": "transcribing", "error": "", "reason": "",
            "started_at": "", "ended_at": "",
        }
        jq._update_progress("j1", 50, "transcribing")

        broker.emit.assert_called_once_with(
            "transcription.progress",
            {"job_id": "j1", "progress": 50, "stage": "transcribing"},
        )

    def test_no_push_if_no_broker(self):
        """If push_broker is None, _update_progress still works."""
        store = mock.MagicMock()
        store.upsert_transcription_job = mock.MagicMock()
        insight = mock.MagicMock()
        watch = mock.MagicMock()
        jq = JobQueue(store=store, insight_service=insight, watch_bridge=watch, push_broker=None)

        jq._jobs["j1"] = {
            "id": "j1", "meeting_id": "m1", "source_path": "/tmp/f.mp4",
            "title": "test", "state": "running", "progress": 10,
            "stage": "transcribing", "error": "", "reason": "",
            "started_at": "", "ended_at": "",
        }
        jq._update_progress("j1", 50, "transcribing")  # Should not raise
        self.assertEqual(jq._jobs["j1"]["progress"], 50)
