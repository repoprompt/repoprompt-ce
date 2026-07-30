#!/usr/bin/env python3
"""Hermetic tests for RepoPrompt CE debug app process identity checks."""

from __future__ import annotations

import os
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import debug_app_process  # noqa: E402


class FakeInspector:
    def __init__(self, names: dict[int, str], paths: dict[int, Path | list[Path] | Exception]) -> None:
        self.names = names
        self.paths = paths

    def list_pids(self) -> list[int]:
        return list(self.names)

    def process_name(self, pid: int) -> str | None:
        return self.names.get(pid)

    def process_path(self, pid: int) -> Path:
        value = self.paths[pid]
        if isinstance(value, Exception):
            raise value
        if isinstance(value, list):
            current = value.pop(0) if len(value) > 1 else value[0]
            return current.resolve(strict=True)
        return value.resolve(strict=True)


class DebugAppProcessTests(unittest.TestCase):
    def make_executable(self, root: Path, relative_path: str) -> Path:
        executable = root / relative_path
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_text("binary", encoding="utf-8")
        executable.chmod(0o755)
        return executable.resolve(strict=True)

    def test_only_exact_debug_executable_is_included(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            debug = self.make_executable(root, "Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app/Contents/MacOS/RepoPrompt")
            production = self.make_executable(root, "Applications/RepoPrompt.app/Contents/MacOS/RepoPrompt")
            ce_release = self.make_executable(root, "Applications/RepoPrompt CE.app/Contents/MacOS/RepoPrompt")
            inspector = FakeInspector(
                {101: "RepoPrompt", 102: "RepoPrompt", 103: "RepoPrompt", 104: "Other"},
                {101: debug, 102: production, 103: ce_release, 104: debug},
            )

            matches = debug_app_process.matching_processes(debug, inspector)

        self.assertEqual(matches, [101])

    def test_termination_revalidates_identity_and_rejects_pid_reuse(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            debug = self.make_executable(root, "Debug/RepoPrompt.app/Contents/MacOS/RepoPrompt")
            production = self.make_executable(root, "Production/RepoPrompt.app/Contents/MacOS/RepoPrompt")
            inspector = FakeInspector({201: "RepoPrompt"}, {201: [debug, production]})
            signals: list[tuple[int, int]] = []

            with self.assertRaisesRegex(debug_app_process.ProcessIdentityError, "executable changed"):
                debug_app_process.terminate_matching_processes(
                    debug,
                    inspector,
                    signaler=lambda pid, sent_signal: signals.append((pid, sent_signal)),
                )

        self.assertEqual(signals, [])

    def test_matching_identity_is_revalidated_then_signaled(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            debug = self.make_executable(Path(tmp), "Debug/RepoPrompt.app/Contents/MacOS/RepoPrompt")
            inspector = FakeInspector({301: "RepoPrompt"}, {301: [debug, debug]})
            signals: list[tuple[int, int]] = []

            signaled = debug_app_process.terminate_matching_processes(
                debug,
                inspector,
                signaler=lambda pid, sent_signal: signals.append((pid, sent_signal)),
            )

        self.assertEqual(signaled, [301])
        self.assertEqual(signals, [(301, signal.SIGTERM)])

    def test_missing_target_is_normal_not_installed_state(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            missing = Path(tmp) / "DebugApps" / "RepoPrompt.app" / "Contents" / "MacOS" / "RepoPrompt"
            inspector = FakeInspector({101: "RepoPrompt"}, {})
            signals: list[tuple[int, int]] = []

            matches = debug_app_process.matching_processes(missing, inspector)
            signaled = debug_app_process.terminate_matching_processes(
                missing,
                inspector,
                signaler=lambda pid, sent_signal: signals.append((pid, sent_signal)),
            )

        self.assertEqual(matches, [])
        self.assertEqual(signaled, [])
        self.assertEqual(signals, [])

    def test_unresolvable_named_candidate_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            debug = self.make_executable(Path(tmp), "Debug/RepoPrompt.app/Contents/MacOS/RepoPrompt")
            inspector = FakeInspector(
                {401: "RepoPrompt"},
                {401: debug_app_process.ProcessIdentityError("identity unavailable")},
            )

            with self.assertRaisesRegex(debug_app_process.ProcessIdentityError, "identity unavailable"):
                debug_app_process.matching_processes(debug, inspector)


class LifecycleSurfaceTests(unittest.TestCase):
    @staticmethod
    def copy_finder_launcher(root: Path) -> Path:
        launcher = root / "Launch RepoPrompt CE.command"
        launcher.write_text((SCRIPT_DIR.parent / launcher.name).read_text(encoding="utf-8"), encoding="utf-8")
        return launcher

    def test_lifecycle_surfaces_have_no_process_name_kill_fallback(self) -> None:
        run_script = (SCRIPT_DIR / "run.sh").read_text(encoding="utf-8")
        conductor_script = (SCRIPT_DIR / "conductor.py").read_text(encoding="utf-8")
        finder_launcher = (SCRIPT_DIR.parent / "Launch RepoPrompt CE.command").read_text(encoding="utf-8")

        for source in [run_script, conductor_script, finder_launcher]:
            self.assertNotIn("pgrep -x RepoPrompt", source)
            self.assertNotIn("pkill -x RepoPrompt", source)
        self.assertIn('exec python3 -u "$ROOT_DIR/Scripts/conductor.py" __operation_runner "$PAYLOAD"', run_script)
        self.assertIn('"kind": "debug_app_build_then_launch"', run_script)
        self.assertIn("terminate_matching_processes(debug_app_executable_path())", conductor_script)
        self.assertIn("safe coordinated launcher requires Python 3", finder_launcher)
        self.assertIn("No uncoordinated fallback is provided", finder_launcher)
        self.assertNotIn("LAUNCH_MODE", finder_launcher)
        self.assertNotIn("direct mode", finder_launcher.lower())
        agents = (SCRIPT_DIR.parent / "AGENTS.md").read_text(encoding="utf-8")
        readme = (SCRIPT_DIR.parent / "README.md").read_text(encoding="utf-8")
        self.assertIn("does not provide an uncoordinated no-Python fallback", agents)
        self.assertIn("does not provide an", readme)
        self.assertIn("uncoordinated no-Python fallback", readme)

    def test_conductor_selftest_includes_process_helper_suite(self) -> None:
        makefile = (SCRIPT_DIR.parent / "Makefile").read_text(encoding="utf-8")
        target = makefile.split("conductor-selftest:", 1)[1].split("\n\n", 1)[0]
        self.assertIn("python3 Scripts/test_debug_app_process.py", target)

    def test_finder_launcher_without_python_exits_before_any_lifecycle_action(self) -> None:
        dirname = shutil.which("dirname")
        self.assertIsNotNone(dirname)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            launcher = self.copy_finder_launcher(root)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            (bin_dir / "dirname").symlink_to(dirname)
            env = os.environ.copy()
            env["PATH"] = str(bin_dir)

            result = subprocess.run(
                ["/bin/bash", str(launcher)],
                env=env,
                input="",
                text=True,
                capture_output=True,
                timeout=2,
            )

        self.assertEqual(result.returncode, 1)
        self.assertIn("safe coordinated launcher requires Python 3", result.stdout)
        self.assertIn("No uncoordinated fallback is provided", result.stdout)
        self.assertNotIn("Building and relaunching", result.stdout)

    def test_finder_launcher_exports_resolved_full_xcode_to_conductor(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            launcher = self.copy_finder_launcher(root)
            scripts = root / "Scripts"
            scripts.mkdir()
            developer_dir = root / "Xcode-beta.app" / "Contents" / "Developer"
            resolver = scripts / "resolve_full_xcode_developer_dir.sh"
            resolver.write_text(
                f"#!/usr/bin/env bash\nprintf '%s\\n' {str(developer_dir)!r}\n",
                encoding="utf-8",
            )
            resolver.chmod(0o755)
            capture = root / "capture.txt"
            conductor = root / "conductor"
            conductor.write_text(
                "#!/usr/bin/env bash\n"
                "printf '%s\\n' \"$DEVELOPER_DIR\" > \"$LAUNCHER_CAPTURE\"\n"
                "printf '%s\\n' \"$*\" >> \"$LAUNCHER_CAPTURE\"\n",
                encoding="utf-8",
            )
            conductor.chmod(0o755)
            env = os.environ.copy()
            env["LAUNCHER_CAPTURE"] = str(capture)
            env.pop("DEVELOPER_DIR", None)

            result = subprocess.run(
                ["/bin/bash", str(launcher)],
                env=env,
                input="q\n",
                text=True,
                capture_output=True,
                timeout=5,
            )
            captured_lines = capture.read_text(encoding="utf-8").splitlines()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(captured_lines, [str(developer_dir), "app relaunch"])
        self.assertIn(f"Xcode:   {developer_dir}", result.stdout)

    def test_finder_launcher_resolver_failure_precedes_lifecycle_action(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            launcher = self.copy_finder_launcher(root)
            scripts = root / "Scripts"
            scripts.mkdir()
            resolver = scripts / "resolve_full_xcode_developer_dir.sh"
            resolver.write_text("#!/usr/bin/env bash\necho 'no compatible Xcode' >&2\nexit 1\n", encoding="utf-8")
            resolver.chmod(0o755)
            lifecycle_marker = root / "lifecycle-invoked"
            conductor = root / "conductor"
            conductor.write_text(
                f"#!/usr/bin/env bash\nprintf 'invoked\\n' > {str(lifecycle_marker)!r}\n",
                encoding="utf-8",
            )
            conductor.chmod(0o755)

            result = subprocess.run(
                ["/bin/bash", str(launcher)],
                env=os.environ.copy(),
                input="\n",
                text=True,
                capture_output=True,
                timeout=5,
            )
            lifecycle_was_invoked = lifecycle_marker.exists()

        self.assertEqual(result.returncode, 1)
        self.assertIn("Couldn't select a compatible full Xcode installation", result.stdout)
        self.assertIn("no compatible Xcode", result.stderr)
        self.assertFalse(lifecycle_was_invoked)


if __name__ == "__main__":
    unittest.main()
