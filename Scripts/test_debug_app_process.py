#!/usr/bin/env python3
"""Hermetic tests for RepoPrompt CE debug app process identity checks."""

from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import debug_app_process  # noqa: E402
import conductor  # noqa: E402


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
            debug = self.make_executable(root, "Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app/Contents/MacOS/RepoPromptDebug")
            production = self.make_executable(root, "Applications/RepoPrompt.app/Contents/MacOS/RepoPrompt")
            ce_release = self.make_executable(root, "Applications/RepoPrompt CE.app/Contents/MacOS/RepoPrompt")
            inspector = FakeInspector(
                {101: "RepoPromptDebug", 102: "RepoPrompt", 103: "RepoPrompt", 104: "Other"},
                {101: debug, 102: production, 103: ce_release, 104: debug},
            )

            matches = debug_app_process.matching_processes(debug, inspector)

        self.assertEqual(matches, [101])

    def test_termination_revalidates_identity_and_rejects_pid_reuse(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            debug = self.make_executable(root, "Debug/RepoPrompt.app/Contents/MacOS/RepoPromptDebug")
            production = self.make_executable(root, "Production/RepoPrompt.app/Contents/MacOS/RepoPrompt")
            inspector = FakeInspector({201: "RepoPromptDebug"}, {201: [debug, production]})
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
            debug = self.make_executable(Path(tmp), "Debug/RepoPrompt.app/Contents/MacOS/RepoPromptDebug")
            inspector = FakeInspector({301: "RepoPromptDebug"}, {301: [debug, debug]})
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
            missing = Path(tmp) / "DebugApps" / "RepoPrompt.app" / "Contents" / "MacOS" / "RepoPromptDebug"
            inspector = FakeInspector({101: "RepoPromptDebug"}, {})
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
            debug = self.make_executable(Path(tmp), "Debug/RepoPrompt.app/Contents/MacOS/RepoPromptDebug")
            inspector = FakeInspector(
                {401: "RepoPromptDebug"},
                {401: debug_app_process.ProcessIdentityError("identity unavailable")},
            )

            with self.assertRaisesRegex(debug_app_process.ProcessIdentityError, "identity unavailable"):
                debug_app_process.matching_processes(debug, inspector)


class LifecycleSurfaceTests(unittest.TestCase):
    def test_conductor_tracks_new_and_legacy_debug_executables(self) -> None:
        bundle = Path("/tmp/RepoPrompt.app")
        observed: list[str] = []

        def matching(path: Path) -> list[int]:
            observed.append(path.name)
            return [101] if path.name == "RepoPromptDebug" else [102]

        with patch.object(conductor, "debug_app_bundle_path", return_value=bundle), patch.object(
            conductor, "matching_processes", side_effect=matching
        ):
            self.assertEqual(conductor.find_debug_app_pids(), ["101", "102"])

        self.assertEqual(observed, ["RepoPromptDebug", "RepoPrompt"])

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
        self.assertIn("terminate_matching_processes(path)", conductor_script)
        self.assertIn("legacy_debug_app_executable_path()", conductor_script)
        self.assertIn("safe coordinated launcher requires Python 3", finder_launcher)
        self.assertIn("No uncoordinated fallback is provided", finder_launcher)
        self.assertNotIn("LAUNCH_MODE", finder_launcher)
        self.assertNotIn("direct mode", finder_launcher.lower())
        agents = (SCRIPT_DIR.parent / "AGENTS.md").read_text(encoding="utf-8")
        readme = (SCRIPT_DIR.parent / "README.md").read_text(encoding="utf-8")
        self.assertIn("does not provide an uncoordinated no-Python fallback", agents)
        self.assertIn("does not provide an", readme)
        self.assertIn("uncoordinated no-Python fallback", readme)

    def test_cached_artifact_admission_requires_checkout_capability_and_commit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            valid = {"version": 1, "debugProfileReuse": True, "repoRoot": str(root), "worktreePath": str(root), "commit": "abc"}
            self.assertEqual(conductor.launch_bundle_currency_problems(root, valid, "abc"), [])
            for payload in [None, {}, {**valid, "version": 2}, {**valid, "debugProfileReuse": False},
                            {**valid, "repoRoot": str(root / "other")}, {**valid, "worktreePath": "relative"},
                            {**valid, "commit": "old"}, {**valid, "commit": None}]:
                with self.subTest(payload=payload):
                    self.assertTrue(conductor.launch_bundle_currency_problems(root, payload, "abc"))
            self.assertTrue(conductor.launch_bundle_currency_problems(root, valid, None))
            alias = root / "alias"
            alias.symlink_to(root, target_is_directory=True)
            self.assertEqual(conductor.launch_bundle_currency_problems(alias, valid, "abc"), [])

    def test_strict_rejection_precedes_stop_and_open(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bundle = root / "RepoPrompt.app"
            executable = bundle / "Contents/MacOS/RepoPromptDebug"
            executable.parent.mkdir(parents=True)
            executable.write_text("fake")
            executable.chmod(0o755)
            with patch.object(conductor, "debug_app_bundle_path", return_value=bundle), \
                 patch.object(conductor, "machine_exclusive_lock", return_value=contextlib.nullcontext()), \
                 patch.object(conductor, "_operation_app_stop_unlocked") as stop, \
                 patch.object(conductor, "run_operation_command") as run, \
                 patch.object(conductor, "current_repo_commit", return_value="abc"), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(conductor.operation_app_launch_existing(root, {"requireCurrent": True}), 1)
                stop.assert_not_called()
                run.assert_not_called()

    def test_reuse_launch_never_packages_and_forwards_profile_flag(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bundle = root / "RepoPrompt.app"
            executable = bundle / "Contents/MacOS/RepoPromptDebug"
            executable.parent.mkdir(parents=True)
            executable.write_text("fake")
            executable.chmod(0o755)
            args = {"requireCurrent": True, "appArgs": ["--fresh-profile", "argument with spaces"]}
            with patch.object(conductor, "debug_app_bundle_path", return_value=bundle), \
                 patch.object(conductor, "machine_exclusive_lock", return_value=contextlib.nullcontext()), \
                 patch.object(conductor, "launch_bundle_currency_problems", return_value=[]), \
                 patch.object(conductor, "report_launch_bundle_details", return_value=0), \
                 patch.object(conductor, "_operation_app_stop_unlocked", return_value=0), \
                 patch.object(conductor, "wait_for_debug_app_process", return_value=["123"]), \
                 patch.object(conductor, "current_repo_commit", return_value="abc"), \
                 patch.object(conductor, "package_debug_app_under_heavy") as package, \
                 patch.object(conductor, "run_operation_command", return_value=(0, "", "")) as run, \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(conductor.operation_app_launch_existing(root, args), 0)
                package.assert_not_called()
                self.assertEqual(run.call_args.args[1], ["open", "-n", str(bundle), "--args", *args["appArgs"]])

    def test_require_current_and_app_arguments_parse_without_enqueuing(self) -> None:
        with patch.object(conductor, "enqueue_and_maybe_wait", return_value=0) as enqueue:
            self.assertEqual(conductor.handle_real_operation(None, "app", ["launch-existing", "--require-current", "--", "--fresh-profile"]), 0)
            self.assertEqual(enqueue.call_args.args[2], {"subcommand": "launch-existing", "requireCurrent": True, "appArgs": ["--fresh-profile"]})
            with self.assertRaises(conductor.ConductorError):
                conductor.handle_real_operation(None, "app", ["relaunch", "--require-current"])

    def test_oversized_or_malformed_provenance_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            bundle = Path(tmp)
            path = conductor.debug_app_provenance_path(bundle)
            path.parent.mkdir(parents=True)
            for data in [b"not JSON", b"\xff", b"x" * (64 * 1024 + 1), json.dumps([]).encode()]:
                path.write_bytes(data)
                self.assertIsNone(conductor.read_debug_app_provenance(bundle))

    def test_finder_reuses_by_default_and_refresh_is_explicit(self) -> None:
        launcher = (SCRIPT_DIR.parent / "Launch RepoPrompt CE.command").read_text()
        self.assertIn('cd "$ROOT_DIR" || exit 1\nlaunch_cached_app', launcher)
        self.assertIn("app launch-existing --require-current", launcher)
        self.assertIn("app relaunch", launcher)
        self.assertIn("--fresh-profile", launcher)
        self.assertIn("debugProfileReuse", (SCRIPT_DIR / "package_app.sh").read_text())

    def test_finder_commands_reuse_refresh_and_rebuild_with_empty_or_spaced_arguments(self) -> None:
        for app_args in ([], ["argument with spaces"]):
            with self.subTest(app_args=app_args), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                launcher = self.copy_finder_launcher(root)
                scripts = root / "Scripts"
                scripts.mkdir()
                resolver = scripts / "resolve_full_xcode_developer_dir.sh"
                resolver.write_text('#!/bin/sh\nprintf "%s\\n" /fake/Xcode/Contents/Developer\n')
                resolver.chmod(0o755)
                mock = root / "conductor"
                mock.write_text('#!/usr/bin/env python3\nimport json,os,sys\nwith open(os.environ["CALLS_LOG"], "a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")\n')
                mock.chmod(0o755)
                log = root / "calls.jsonl"
                result = subprocess.run(["/bin/bash", str(launcher), *app_args], input="frq", text=True,
                                        capture_output=True, timeout=10, env={**os.environ, "CALLS_LOG": str(log), "TERM": "dumb"})
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                self.assertEqual(calls[0], ["app", "launch-existing", "--require-current", *(["--", *app_args] if app_args else [])])
                self.assertEqual(calls[1], ["app", "launch-existing", "--require-current", "--", "--fresh-profile", *app_args])
                self.assertEqual(calls[2], ["app", "relaunch", *(["--", *app_args] if app_args else [])])

    def test_conductor_selftest_includes_process_helper_suite(self) -> None:
        makefile = (SCRIPT_DIR.parent / "Makefile").read_text(encoding="utf-8")
        target = makefile.split("conductor-selftest:", 1)[1].split("\n\n", 1)[0]
        self.assertIn("python3 Scripts/test_debug_app_process.py", target)





if __name__ == "__main__":
    unittest.main()
