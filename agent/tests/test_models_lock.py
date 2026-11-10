"""軽量検査で実行する単体テスト（標準ライブラリのみ。python -m unittest で実行）。"""
import tempfile
import unittest
from pathlib import Path

from capx_agent import models


class ModelsLockTest(unittest.TestCase):
    def test_repo_lock_is_valid(self):
        entries = models.load()
        self.assertGreaterEqual(len(entries), 1)
        for e in entries:
            self.assertTrue(e.path.startswith("/models/"))

    def test_rejects_short_revision(self):
        with tempfile.NamedTemporaryFile("w", suffix=".lock", delete=False) as f:
            f.write("org/model main /models/x\n")
        with self.assertRaises(ValueError):
            models.load(Path(f.name))


if __name__ == "__main__":
    unittest.main()
