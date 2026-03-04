import tempfile
import unittest
from pathlib import Path

from insightkit.data.store import InsightStore


class TestStoreDBBusyTimeout(unittest.TestCase):
    def test_busy_timeout_is_applied(self):
        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "insightkit.db"
            store = InsightStore(db_path=db_path)
            store.init_schema()
            row = store.conn.execute("PRAGMA busy_timeout;").fetchone()
            self.assertIsNotNone(row)
            self.assertGreaterEqual(int(row[0]), 8000)
            store.close()


if __name__ == "__main__":
    unittest.main()
