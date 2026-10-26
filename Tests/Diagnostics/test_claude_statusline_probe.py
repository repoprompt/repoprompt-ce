import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "Scripts/diagnostics/claude_statusline_probe.py"
spec = importlib.util.spec_from_file_location("probe", SCRIPT)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class ProbeTests(unittest.TestCase):
    def test_whitelist_and_percentage_units(self):
        result = probe.sanitized({"session_id": "SECRET", "cwd": "SECRET", "version": "2.1.99",
                                  "rate_limits": {"five_hour": {"used_percentage": 1.0, "resets_at": 1800000000, "token": "SECRET"}}})
        self.assertEqual(result["windows"]["five_hour"]["used_percentage"], 1.0)
        self.assertNotIn("SECRET", json.dumps(result))
        self.assertNotIn("seven_day", result["windows"])

    def test_invalid_values_are_not_zero(self):
        result = probe.sanitized({"version": "SECRET", "rate_limits": {
            "five_hour": {"used_percentage": True, "resets_at": float("inf")},
            "seven_day": {"used_percentage": -1, "resets_at": "123"}}})
        self.assertEqual(result["windows"], {})
        self.assertIsNone(result["cliVersion"])

    def test_prepare_capture_privacy_and_bounds(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "space ' quoted"
            prepared = subprocess.run([sys.executable, str(SCRIPT), "prepare", str(root)], capture_output=True, check=True)
            settings = json.loads(Path(prepared.stdout.decode().strip()).read_text())
            self.assertEqual(set(settings), {"statusLine"})
            self.assertEqual(root.stat().st_mode & 0o777, 0o700)
            self.assertEqual((root / "settings.json").stat().st_mode & 0o777, 0o600)
            run = subprocess.run(settings["statusLine"]["command"], shell=True, input=b'{"session_id":"SECRET","rate_limits":{"five_hour":{"used_percentage":1}}}', capture_output=True, check=True)
            self.assertEqual(run.stdout.strip(), probe.SENTINEL.encode())
            log = root / "invocations.ndjson"
            self.assertNotIn("SECRET", log.read_text())
            self.assertEqual(log.stat().st_mode & 0o777, 0o600)
            before = log.read_bytes()
            for payload in (b"{", b"x" * 65537, b"[" * 60000):
                run = subprocess.run(settings["statusLine"]["command"], shell=True, input=payload, capture_output=True, check=True)
                self.assertEqual(run.stdout, b"")
                self.assertEqual(log.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
