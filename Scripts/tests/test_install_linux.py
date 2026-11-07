import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "install_linux.sh"


@unittest.skipUnless(os.uname().sysname == "Linux", "Linux installer")
class InstallLinuxTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="rpce installer ")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = self.root / "source binary"
        self.source.write_text("#!/bin/sh\nprintf 'version one\\n'\n")
        self.source.chmod(0o755)
        self.prefix = self.root / "install prefix"
        self.destination = self.prefix / "bin" / "repoprompt-mcp"

    def install(self, *arguments):
        return subprocess.run(
            ["bash", str(SCRIPT), "--prefix", str(self.prefix), "--binary", str(self.source), *arguments],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )

    def test_installs_executable_at_prefix_containing_spaces(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.destination.read_bytes(), self.source.read_bytes())
        self.assertEqual(stat.S_IMODE(self.destination.stat().st_mode), 0o755)
        self.assertEqual(subprocess.check_output([self.destination], text=True), "version one\n")
        self.assertFalse(list(self.destination.parent.glob(".repoprompt-mcp.*")))

    def test_same_binary_is_idempotent(self):
        self.assertEqual(self.install().returncode, 0)
        inode = self.destination.stat().st_ino
        self.assertEqual(self.install().returncode, 0)
        self.assertEqual(self.destination.stat().st_ino, inode)

    def test_different_binary_requires_explicit_replace(self):
        self.assertEqual(self.install().returncode, 0)
        original = self.destination.read_bytes()
        self.source.write_text("#!/bin/sh\nprintf 'version two\\n'\n")
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.destination.read_bytes(), original)
        result = self.install("--replace")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.destination.read_bytes(), self.source.read_bytes())

    def test_symlink_target_is_never_replaced(self):
        self.destination.parent.mkdir(parents=True)
        other = self.root / "other binary"
        other.write_text("preserve me")
        self.destination.symlink_to(other)
        result = self.install("--replace")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.destination.is_symlink())
        self.assertEqual(other.read_text(), "preserve me")

    def test_dangling_symlink_is_never_replaced(self):
        self.destination.parent.mkdir(parents=True)
        self.destination.symlink_to(self.root / "absent")
        self.assertNotEqual(self.install("--replace").returncode, 0)
        self.assertTrue(self.destination.is_symlink())

    def test_directory_is_never_replaced(self):
        self.destination.mkdir(parents=True)
        self.assertNotEqual(self.install("--replace").returncode, 0)
        self.assertTrue(self.destination.is_dir())

    def test_missing_binary_does_not_create_install_directory(self):
        self.source.unlink()
        self.assertNotEqual(self.install().returncode, 0)
        self.assertFalse(self.prefix.exists())


if __name__ == "__main__":
    unittest.main()
