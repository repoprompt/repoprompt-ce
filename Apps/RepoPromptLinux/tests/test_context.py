import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from repoprompt_gui.context import MAX_CONTEXT_BYTES, compose_context, profile_directory, xdg_directory


class ContextTests(unittest.TestCase):
    def test_source_backticks_cannot_end_the_file_fence(self):
        result = compose_context("Review the change.", [("a\nfile.py", "```python\nhello\n```")])
        self.assertIn("### a\\nfile.py\n\n````\n```python\nhello\n```\n````", result)
        self.assertTrue(result.startswith("Review the change.\n\n"))

    def test_context_limit_counts_utf8_bytes_and_does_not_truncate(self):
        with self.assertRaisesRegex(ValueError, "2 MiB"):
            compose_context("", [("large.txt", "界" * (MAX_CONTEXT_BYTES // 2))])
        with self.assertRaisesRegex(ValueError, "100 files"):
            compose_context("", [(str(i), "x") for i in range(101)])

    def test_relative_xdg_values_are_ignored_and_profiles_isolate_engine_paths(self):
        with patch.dict(os.environ, {"XDG_DATA_HOME": "relative"}):
            self.assertEqual(xdg_directory("XDG_DATA_HOME", Path("/fallback")), Path("/fallback"))
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"XDG_DATA_HOME": "/tmp/gui-data"}):
            root = Path(directory)
            profile = profile_directory(root, root / "release/engine")
            self.assertEqual(profile, profile_directory(root, root / "release/engine"))
            self.assertNotEqual(profile, profile_directory(root, root / "debug/engine"))
            self.assertNotEqual(profile, profile_directory(root / "other", root / "release/engine"))
            self.assertTrue(str(profile).startswith("/tmp/gui-data/repoprompt-ce-linux-gui/profiles/"))
