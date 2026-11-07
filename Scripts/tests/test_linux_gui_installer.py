import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("linux_gui_installer", ROOT / "Scripts/install_linux_gui.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class GUIInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="rpce-gui-install-")
        self.base = Path(self.temporary.name)
        self.prefix = self.base / "desktop 'quoted' $with spaces %p"
        self.engine = self.base / "engine"
        self.engine.write_text("#!/bin/sh\nexit 0\n")
        self.engine.chmod(0o755)

    def tearDown(self):
        self.temporary.cleanup()

    def fake_pip(self, command, **kwargs):
        target = Path(command[command.index("--target") + 1])
        shutil.copytree(installer.PACKAGE / "src/repoprompt_gui", target / "repoprompt_gui")
        self.assertTrue(kwargs["check"])
        return subprocess.CompletedProcess(command, 0)

    def install(self, **options):
        with patch.object(installer.subprocess, "run", side_effect=self.fake_pip):
            return installer.install(self.prefix, self.engine, Path(sys.executable), **options)

    def test_relocated_launcher_handles_spaces_quotes_and_shell_metacharacters(self):
        launcher, desktop = self.install(no_deps=True)
        result = subprocess.run([str(launcher), "--help"], capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("native Linux context workspace", result.stdout)
        self.assertIn("%%p", desktop.read_text())
        self.assertIn("Terminal=false", desktop.read_text())
        self.assertFalse((self.base / "with").exists())
        validator = shutil.which("desktop-file-validate")
        if validator:
            validation = subprocess.run([validator, str(desktop)], capture_output=True, text=True, timeout=10)
            self.assertEqual(validation.returncode, 0, validation.stdout + validation.stderr)

    def test_existing_install_requires_replace_and_failed_download_preserves_it(self):
        launcher, _ = self.install()
        before = launcher.read_bytes()
        with self.assertRaisesRegex(ValueError, "use --replace"):
            self.install()
        with patch.object(installer.subprocess, "run", side_effect=subprocess.CalledProcessError(1, ["pip"])):
            with self.assertRaises(subprocess.CalledProcessError):
                installer.install(self.prefix, self.engine, Path(sys.executable), replace=True)
        self.assertEqual(launcher.read_bytes(), before)
        self.assertTrue((self.prefix / "share/repoprompt-ce/linux-gui" / installer.MARKER).is_file())
        self.install(replace=True)

    def test_symlink_and_unrelated_installation_are_preserved_even_with_replace(self):
        path = self.prefix / "bin/repoprompt-gui"
        path.parent.mkdir(parents=True)
        path.symlink_to(self.engine)
        with self.assertRaisesRegex(ValueError, "symbolic link"):
            self.install(replace=True)
        self.assertTrue(path.is_symlink())
        path.unlink()
        unrelated = self.prefix / "share/repoprompt-ce/linux-gui"
        unrelated.mkdir(parents=True)
        (unrelated / "important").write_text("preserve")
        with self.assertRaisesRegex(ValueError, "unrelated"):
            self.install(replace=True)
        self.assertEqual((unrelated / "important").read_text(), "preserve")

    def test_missing_engine_fails_before_downloading_dependencies(self):
        with patch.object(installer.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "engine first"):
                installer.install(self.prefix, self.base / "missing", Path(sys.executable))
            run.assert_not_called()
