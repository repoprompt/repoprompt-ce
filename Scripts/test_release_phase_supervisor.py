#!/usr/bin/env python3
"""Regression tests for the generic release-phase process supervisor."""

from __future__ import annotations

import errno
import json
import os
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from typing import Any

SCRIPTS_DIR = Path(__file__).resolve().parent
SUPERVISOR = SCRIPTS_DIR / "supervise_release_phase.py"
PHASE = "transition component package construction"
APP_SIZE = 321_000_000
PAYLOAD_SIZE = 322_000_000


class ReleasePhaseSupervisorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.temp = Path(self.temporary_directory.name)
        self.app_path = self.temp / "RepoPrompt CE.app"
        self.payload_path = self.temp / "payload-root"
        self.owned_groups: set[int] = set()
        self.capture_index = 0

    def tearDown(self) -> None:
        for process_group in self.owned_groups:
            try:
                os.killpg(process_group, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
        self.temporary_directory.cleanup()

    def capture_path(self) -> Path:
        self.capture_index += 1
        return self.temp / f"capture-{self.capture_index}.log"

    def supervisor_argv(
        self,
        command: list[str],
        *,
        capture_path: Path,
        timeout: float = 5.0,
        extra: list[str] | None = None,
        cleanup_overrides: tuple[float, float] | None = (0.25, 1.5),
    ) -> list[str]:
        cleanup_arguments: list[str] = []
        if cleanup_overrides is not None:
            cleanup_arguments = [
                "--term-grace-seconds",
                str(cleanup_overrides[0]),
                "--kill-wait-seconds",
                str(cleanup_overrides[1]),
            ]
        return [
            sys.executable,
            str(SUPERVISOR),
            "--phase",
            PHASE,
            "--timeout-seconds",
            str(timeout),
            "--heartbeat-seconds",
            "0.2",
            *cleanup_arguments,
            "--capture-file",
            str(capture_path),
            "--app-path",
            str(self.app_path),
            "--app-size-bytes",
            str(APP_SIZE),
            "--payload-path",
            str(self.payload_path),
            "--payload-size-bytes",
            str(PAYLOAD_SIZE),
            *(extra or []),
            "--",
            *command,
        ]

    def run_supervisor(
        self,
        command: list[str],
        *,
        timeout: float = 5.0,
        extra: list[str] | None = None,
        environment: dict[str, str] | None = None,
        cleanup_overrides: tuple[float, float] | None = (0.25, 1.5),
    ) -> tuple[subprocess.CompletedProcess[str], Path, list[dict[str, Any]]]:
        capture_path = self.capture_path()
        cleanup_budget = sum(cleanup_overrides or (2.0, 2.0))
        result = subprocess.run(
            self.supervisor_argv(
                command,
                capture_path=capture_path,
                timeout=timeout,
                extra=extra,
                cleanup_overrides=cleanup_overrides,
            ),
            cwd=SCRIPTS_DIR.parent,
            env=environment,
            text=True,
            capture_output=True,
            timeout=timeout + cleanup_budget + 4,
            check=False,
        )
        self.assertFalse(capture_path.exists(), "supervisor left its raw capture path")
        return result, capture_path, self.parse_events(result.stderr)

    def start_supervisor(
        self,
        command: list[str],
        *,
        capture_path: Path,
        timeout: float,
        extra: list[str] | None = None,
        environment: dict[str, str] | None = None,
        cleanup_overrides: tuple[float, float] | None = (0.25, 1.5),
        shell_exec: bool = False,
    ) -> subprocess.Popen[str]:
        argv = self.supervisor_argv(
            command,
            capture_path=capture_path,
            timeout=timeout,
            extra=extra,
            cleanup_overrides=cleanup_overrides,
        )
        if shell_exec:
            argv = ["/bin/sh", "-c", 'exec "$@"', "release-supervisor", *argv]
        return subprocess.Popen(
            argv,
            cwd=SCRIPTS_DIR.parent,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    @staticmethod
    def parse_events(output: str) -> list[dict[str, Any]]:
        events: list[dict[str, Any]] = []
        for line in output.splitlines():
            if line.startswith("{"):
                events.append(json.loads(line))
        return events

    @staticmethod
    def wait_for_json(path: Path, timeout: float = 4.0) -> dict[str, Any]:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                return json.loads(path.read_text(encoding="utf-8"))
            except (FileNotFoundError, json.JSONDecodeError):
                time.sleep(0.02)
        raise AssertionError(f"timed out waiting for process record: {path}")

    @staticmethod
    def process_group_is_live(process_group: int) -> bool:
        try:
            os.killpg(process_group, 0)
        except ProcessLookupError:
            return False
        except OSError as error:
            if error.errno == errno.ESRCH:
                return False
            return True
        return True

    def assert_process_group_gone(self, process_group: int) -> None:
        self.owned_groups.add(process_group)
        deadline = time.monotonic() + 2.0
        while time.monotonic() < deadline:
            if not self.process_group_is_live(process_group):
                self.owned_groups.discard(process_group)
                return
            time.sleep(0.02)
        self.fail(f"orphaned process group remains live: {process_group}")

    @staticmethod
    def python_command(source: str, *arguments: str) -> list[str]:
        return [sys.executable, "-c", source, *arguments]

    def assert_mandatory_tail(self, event: dict[str, Any], limit: int) -> None:
        self.assertTrue(event["output_tail_included"])
        self.assertEqual(event["output_tail_limit_bytes"], limit)
        encoded_length = len(event["output_tail"].encode("utf-8"))
        self.assertEqual(event["output_tail_utf8_bytes"], encoded_length)
        self.assertLessEqual(encoded_length, limit)

    def test_success_uses_supplied_metadata_and_reports_ordered_completion(self) -> None:
        capture_path = self.capture_path()
        self.assertFalse(self.app_path.exists())
        self.assertFalse(self.payload_path.exists())

        result = subprocess.run(
            self.supervisor_argv(
                self.python_command("print('command-ok', flush=True)"),
                capture_path=capture_path,
            ),
            cwd=SCRIPTS_DIR.parent,
            text=True,
            capture_output=True,
            timeout=8,
            check=False,
        )
        events = self.parse_events(result.stderr)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(capture_path.exists())
        event_names = [event["event"] for event in events]
        self.assertEqual(event_names[:2], ["phase_start", "launched"])
        self.assertEqual(event_names[-1], "completion")
        self.assertTrue(
            all(event_name == "heartbeat" for event_name in event_names[2:-1]),
            event_names,
        )
        self.assertFalse(
            {"failure", "timeout", "cancellation"}.intersection(event_names),
            event_names,
        )
        self.assertEqual(
            [event["timestamp"] for event in events],
            sorted(event["timestamp"] for event in events),
        )
        self.assertEqual(
            [event["elapsed_seconds"] for event in events],
            sorted(event["elapsed_seconds"] for event in events),
        )
        for event in events:
            self.assertEqual(event["phase"], PHASE)
            self.assertEqual(event["command"], Path(sys.executable).name)
            self.assertEqual(event["capture_path"], str(capture_path))
            self.assertEqual(event["timeout_seconds"], 5.0)
            self.assertIn("supervisor unlinks", event["capture_disposition"])
            self.assertIn("never upload", event["capture_disposition"])
        completion = events[-1]
        self.assertEqual(completion["app_path"], str(self.app_path))
        self.assertEqual(completion["app_size_bytes"], APP_SIZE)
        self.assertEqual(completion["payload_path"], str(self.payload_path))
        self.assertEqual(completion["payload_size_bytes"], PAYLOAD_SIZE)
        self.assertFalse(completion["output_tail_included"])
        self.assertTrue(completion["timestamp"].endswith("Z"))

    def test_notary_success_emits_only_allowlisted_evidence_and_removes_capture(self) -> None:
        submission_id = "f48ef37d-db7d-4d7a-a171-ae035b7fe57d"
        secret_message = "secret-looking diagnostic must stay in anonymous capture"
        command = self.python_command(
            "import json,sys; print(json.dumps({'id': sys.argv[1], "
            "'status': 'Accepted', 'message': sys.argv[2]}), flush=True)",
            submission_id,
            secret_message,
        )
        result, capture_path, events = self.run_supervisor(
            command, extra=["--notarytool-json-evidence"]
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(capture_path.exists())
        evidence = next(event for event in events if event["event"] == "notarization_evidence")
        self.assertEqual(evidence["submission_id"], submission_id)
        self.assertEqual(evidence["status"], "Accepted")
        self.assertNotIn("message", evidence)
        self.assertNotIn(secret_message, result.stderr)

        rejected, rejected_capture, rejected_events = self.run_supervisor(
            self.python_command(
                "import json,sys; print(json.dumps({'id': sys.argv[1], "
                "'status': sys.argv[2], 'message': sys.argv[2]}), flush=True)",
                submission_id,
                secret_message,
            ),
            extra=["--notarytool-json-evidence"],
        )
        self.assertEqual(rejected.returncode, 126, rejected.stderr)
        self.assertFalse(rejected_capture.exists())
        failure = rejected_events[-1]
        self.assertEqual(failure["failure_kind"], "notary_evidence_failure")
        self.assertFalse(failure["output_tail_included"])
        self.assertNotIn(secret_message, rejected.stderr)

        conflicting, conflicting_capture, conflicting_events = self.run_supervisor(
            command,
            extra=["--notarytool-json-evidence", "--emit-output-tail"],
        )
        self.assertEqual(conflicting.returncode, 2)
        self.assertFalse(conflicting_capture.exists())
        self.assertEqual(conflicting_events, [])
        self.assertIn(
            "--notarytool-json-evidence cannot be combined with --emit-output-tail",
            conflicting.stderr,
        )

    def test_required_size_and_path_metadata_is_enforced_before_capture(self) -> None:
        capture_path = self.capture_path()
        result = subprocess.run(
            [
                sys.executable,
                str(SUPERVISOR),
                "--phase",
                PHASE,
                "--timeout-seconds",
                "2",
                "--capture-file",
                str(capture_path),
                "--",
                sys.executable,
                "-c",
                "raise SystemExit('must not run')",
            ],
            cwd=SCRIPTS_DIR.parent,
            text=True,
            capture_output=True,
            timeout=3,
            check=False,
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("--app-path", result.stderr)
        self.assertFalse(capture_path.exists())

    def test_capture_rejects_existing_regular_symlink_and_fifo_without_blocking(self) -> None:
        command_marker = self.temp / "command-ran"
        command = self.python_command(
            "import pathlib, sys; pathlib.Path(sys.argv[1]).write_text('ran')",
            str(command_marker),
        )

        regular = self.temp / "existing.log"
        regular.write_text("do-not-read-or-truncate", encoding="utf-8")
        victim = self.temp / "victim.log"
        victim.write_text("victim-preserved", encoding="utf-8")
        symlink = self.temp / "capture-symlink.log"
        symlink.symlink_to(victim)
        fifo = self.temp / "capture.fifo"
        os.mkfifo(fifo, 0o600)

        for capture_path in (regular, symlink, fifo):
            with self.subTest(capture_path=capture_path.name):
                started = time.monotonic()
                result = subprocess.run(
                    self.supervisor_argv(command, capture_path=capture_path),
                    cwd=SCRIPTS_DIR.parent,
                    text=True,
                    capture_output=True,
                    timeout=3,
                    check=False,
                )
                elapsed = time.monotonic() - started
                events = self.parse_events(result.stderr)

                self.assertLess(elapsed, 2.0)
                self.assertEqual(result.returncode, 126, result.stderr)
                self.assertEqual(events[0]["event"], "phase_start")
                self.assertEqual(events[-1]["failure_kind"], "capture_setup_failure")
                self.assert_mandatory_tail(events[-1], 8192)
                self.assertEqual(events[-1]["output_tail"], "")
                self.assertFalse(command_marker.exists())
                self.assertNotIn("do-not-read-or-truncate", result.stderr)
                self.assertNotIn("victim-preserved", result.stderr)

        self.assertEqual(regular.read_text(encoding="utf-8"), "do-not-read-or-truncate")
        self.assertTrue(symlink.is_symlink())
        self.assertEqual(victim.read_text(encoding="utf-8"), "victim-preserved")
        self.assertTrue(stat.S_ISFIFO(fifo.lstat().st_mode))

    def test_nonzero_exit_always_reports_tail_and_preserves_status(self) -> None:
        result, capture_path, events = self.run_supervisor(
            self.python_command("print('failed-command'); raise SystemExit(7)")
        )

        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertFalse(capture_path.exists())
        failure = events[-1]
        self.assertEqual(failure["event"], "failure")
        self.assertEqual(failure["failure_kind"], "command_failure")
        self.assertEqual(failure["child_return_code"], 7)
        self.assert_mandatory_tail(failure, 8192)
        self.assertIn("failed-command", failure["output_tail"])

    def test_nonfinite_timeout_is_rejected_instead_of_becoming_unbounded(self) -> None:
        capture_path = self.capture_path()
        result = subprocess.run(
            self.supervisor_argv(
                self.python_command("raise SystemExit('must not run')"),
                capture_path=capture_path,
                timeout=float("nan"),
            ),
            cwd=SCRIPTS_DIR.parent,
            text=True,
            capture_output=True,
            timeout=3,
            check=False,
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("finite number greater than zero", result.stderr)
        self.assertFalse(capture_path.exists())

    def test_all_time_controls_reject_nonfinite_and_impractical_values(self) -> None:
        cases = (
            ("--timeout-seconds", "inf", "finite"),
            ("--timeout-seconds", "3600.1", "must not exceed 3600"),
            ("--heartbeat-seconds", "nan", "finite"),
            ("--heartbeat-seconds", "600.1", "must not exceed 600"),
            ("--term-grace-seconds", "inf", "finite"),
            ("--term-grace-seconds", "60.1", "must not exceed 60"),
            ("--kill-wait-seconds", "nan", "finite"),
            ("--kill-wait-seconds", "60.1", "must not exceed 60"),
        )
        for position, (flag, value, message) in enumerate(cases, start=1):
            with self.subTest(flag=flag, value=value):
                capture_path = self.temp / f"invalid-time-{position}.capture"
                argv = self.supervisor_argv(
                    self.python_command("raise SystemExit('must not run')"),
                    capture_path=capture_path,
                )
                value_index = argv.index(flag) + 1
                argv[value_index] = value
                result = subprocess.run(
                    argv,
                    cwd=SCRIPTS_DIR.parent,
                    text=True,
                    capture_output=True,
                    timeout=3,
                    check=False,
                )
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)
                self.assertFalse(capture_path.exists())

    def test_timeout_reports_redacted_exact_utf8_tail_and_leaves_no_group(self) -> None:
        record = self.temp / "timeout-process.json"
        capture_path = self.capture_path()
        secret = "super-secret-timeout-value"
        environment = dict(os.environ)
        environment["RELEASE_SUPERVISOR_TEST_SECRET"] = secret
        source = """
import json, os, pathlib, sys, time
pathlib.Path(sys.argv[1]).write_text(json.dumps({"pid": os.getpid(), "pgid": os.getpgrp()}))
print(("😀" * 100) + os.environ["RELEASE_SUPERVISOR_TEST_SECRET"] + " final-marker", flush=True)
time.sleep(60)
"""
        started = time.monotonic()
        supervisor = self.start_supervisor(
            self.python_command(source, str(record)),
            capture_path=capture_path,
            timeout=2.5,
            extra=["--output-tail-bytes", "96"],
            environment=environment,
        )
        process_record = self.wait_for_json(record)
        process_group = int(process_record["pgid"])
        self.owned_groups.add(process_group)
        stdout, stderr = supervisor.communicate(timeout=6)
        elapsed = time.monotonic() - started
        events = self.parse_events(stderr)

        self.assertEqual(stdout, "")
        self.assertLess(elapsed, 5.5)
        self.assertEqual(supervisor.returncode, 124, stderr)
        timeout_event = events[-1]
        self.assertEqual(timeout_event["event"], "timeout")
        self.assertTrue(timeout_event["cleanup_succeeded"])
        self.assertTrue(timeout_event["term_sent"])
        self.assertTrue(timeout_event["process_group_gone"])
        self.assert_mandatory_tail(timeout_event, 96)
        self.assertIn("final-marker", timeout_event["output_tail"])
        self.assertIn("[REDACTED]", timeout_event["output_tail"])
        self.assertNotIn(secret, stderr)
        self.assertFalse(capture_path.exists())
        self.assertTrue(any(event["event"] == "heartbeat" for event in events))
        self.assert_process_group_gone(process_group)

    def test_timeout_kills_term_ignoring_descendant_and_reaps_group(self) -> None:
        record = self.temp / "ignoring-descendant.json"
        capture_path = self.capture_path()
        child_source = """
import json, os, pathlib, signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
pathlib.Path(sys.argv[1]).write_text(json.dumps({"pid": os.getpid(), "pgid": os.getpgrp()}))
print("descendant-ready", flush=True)
time.sleep(60)
"""
        parent_source = """
import pathlib, subprocess, sys, time
record = pathlib.Path(sys.argv[1])
subprocess.Popen([sys.executable, "-c", sys.argv[2], str(record)])
deadline = time.monotonic() + 4
while not record.exists():
    if time.monotonic() >= deadline:
        raise SystemExit("descendant did not become ready")
    time.sleep(0.01)
print("parent-ready", flush=True)
time.sleep(60)
"""
        started = time.monotonic()
        supervisor = self.start_supervisor(
            self.python_command(parent_source, str(record), child_source),
            capture_path=capture_path,
            timeout=2.5,
        )
        process_record = self.wait_for_json(record)
        process_group = int(process_record["pgid"])
        self.owned_groups.add(process_group)
        _stdout, stderr = supervisor.communicate(timeout=6)
        elapsed = time.monotonic() - started
        events = self.parse_events(stderr)

        self.assertLess(elapsed, 5.5)
        self.assertEqual(supervisor.returncode, 124, stderr)
        timeout_event = events[-1]
        self.assertEqual(timeout_event["event"], "timeout")
        self.assertTrue(timeout_event["term_sent"])
        self.assertTrue(timeout_event["kill_sent"])
        self.assertTrue(timeout_event["child_reaped"])
        self.assertTrue(timeout_event["process_group_gone"])
        self.assert_mandatory_tail(timeout_event, 8192)
        self.assertIn("parent-ready", timeout_event["output_tail"])
        self.assert_process_group_gone(process_group)

    def test_leader_exit_with_live_descendant_is_cleaned_and_rejected(self) -> None:
        record = self.temp / "leader-exit-descendant.json"
        child_source = """
import json, os, pathlib, signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
pathlib.Path(sys.argv[1]).write_text(json.dumps({"pid": os.getpid(), "pgid": os.getpgrp()}))
time.sleep(60)
"""
        leader_source = """
import pathlib, subprocess, sys, time
record = pathlib.Path(sys.argv[1])
subprocess.Popen([sys.executable, "-c", sys.argv[2], str(record)])
deadline = time.monotonic() + 4
while not record.exists():
    if time.monotonic() >= deadline:
        raise SystemExit("descendant did not become ready")
    time.sleep(0.01)
print("leader-exiting", flush=True)
"""

        result, _capture_path, events = self.run_supervisor(
            self.python_command(leader_source, str(record), child_source),
            timeout=5,
        )
        process_record = json.loads(record.read_text(encoding="utf-8"))
        process_group = int(process_record["pgid"])

        self.assertEqual(result.returncode, 125, result.stderr)
        failure = events[-1]
        self.assertEqual(failure["event"], "failure")
        self.assertEqual(failure["failure_kind"], "process_group_leak")
        self.assertTrue(failure["cleanup_succeeded"])
        self.assertTrue(failure["kill_sent"])
        self.assertTrue(failure["process_group_gone"])
        self.assert_mandatory_tail(failure, 8192)
        self.assertIn("leader-exiting", failure["output_tail"])
        self.assert_process_group_gone(process_group)

    def test_sigterm_cancellation_always_reports_tail_and_cleans_group(self) -> None:
        record = self.temp / "cancelled-process.json"
        capture_path = self.capture_path()
        source = """
import json, os, pathlib, sys, time
pathlib.Path(sys.argv[1]).write_text(json.dumps({"pid": os.getpid(), "pgid": os.getpgrp()}))
print("waiting-for-cancellation", flush=True)
time.sleep(60)
"""
        supervisor = self.start_supervisor(
            self.python_command(source, str(record)),
            capture_path=capture_path,
            timeout=10,
        )
        process_record = self.wait_for_json(record)
        process_group = int(process_record["pgid"])
        self.owned_groups.add(process_group)

        os.kill(supervisor.pid, signal.SIGTERM)
        stdout, stderr = supervisor.communicate(timeout=6)
        events = self.parse_events(stderr)

        self.assertEqual(stdout, "")
        self.assertEqual(supervisor.returncode, 128 + signal.SIGTERM, stderr)
        cancellation = events[-1]
        self.assertEqual(cancellation["event"], "cancellation")
        self.assertEqual(cancellation["cancellation_signal"], "SIGTERM")
        self.assertTrue(cancellation["cleanup_succeeded"])
        self.assertTrue(cancellation["process_group_gone"])
        self.assert_mandatory_tail(cancellation, 8192)
        self.assertIn("waiting-for-cancellation", cancellation["output_tail"])
        self.assert_process_group_gone(process_group)

    def test_shell_exec_forwards_sigint_within_github_escalation_window(self) -> None:
        record = self.temp / "shell-exec-process.json"
        capture_path = self.capture_path()
        source = """
import json, os, pathlib, signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
pathlib.Path(sys.argv[1]).write_text(json.dumps({"pid": os.getpid(), "pgid": os.getpgrp()}))
print("shell-exec-ready", flush=True)
time.sleep(60)
"""
        supervisor = self.start_supervisor(
            self.python_command(source, str(record)),
            capture_path=capture_path,
            timeout=30,
            cleanup_overrides=None,
            shell_exec=True,
        )
        process_record = self.wait_for_json(record)
        process_group = int(process_record["pgid"])
        self.owned_groups.add(process_group)

        cancellation_started = time.monotonic()
        os.kill(supervisor.pid, signal.SIGINT)
        stdout, stderr = supervisor.communicate(timeout=7)
        cancellation_elapsed = time.monotonic() - cancellation_started
        events = self.parse_events(stderr)

        self.assertEqual(stdout, "")
        self.assertLess(cancellation_elapsed, 6.0)
        self.assertEqual(supervisor.returncode, 128 + signal.SIGINT, stderr)
        cancellation = events[-1]
        self.assertEqual(cancellation["event"], "cancellation")
        self.assertEqual(cancellation["cancellation_signal"], "SIGINT")
        self.assertTrue(cancellation["cleanup_succeeded"])
        self.assertTrue(cancellation["term_sent"])
        self.assertTrue(cancellation["kill_sent"])
        self.assertTrue(cancellation["process_group_gone"])
        self.assert_mandatory_tail(cancellation, 8192)
        self.assertIn("shell-exec-ready", cancellation["output_tail"])
        self.assert_process_group_gone(process_group)

    def test_failure_tail_redacts_credentials_and_obeys_exact_utf8_byte_bound(self) -> None:
        token = "github_pat_" + ("z" * 96)
        source = (
            "import os; "
            "print('😀' * 100); "
            "print('authorization: Bearer raw-bearer-token'); "
            "print(os.environ['RELEASE_SUPERVISOR_TEST_TOKEN']); "
            "raise SystemExit(3)"
        )
        environment = dict(os.environ)
        environment["RELEASE_SUPERVISOR_TEST_TOKEN"] = token

        result, capture_path, events = self.run_supervisor(
            self.python_command(source),
            extra=["--output-tail-bytes", "64"],
            environment=environment,
        )
        emitted = json.dumps(events, ensure_ascii=False)

        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertFalse(capture_path.exists())
        self.assertNotIn(token, emitted)
        self.assertNotIn("raw-bearer-token", emitted)
        self.assert_mandatory_tail(events[-1], 64)
        self.assertIn("[REDACTED]", events[-1]["output_tail"])

    def test_failure_tail_preserves_unlabeled_git_and_sha256_digests(self) -> None:
        main_sha = "0c1aa28f8179ff98c11f6dbb420101eeba944a26"
        manifest_digest = (
            "3c69703fa7582105633b36e8874fe2a28"
            "e1832aabb776351e68dbf3367e122db"
        )
        explicit_secret = "a" * 40
        source = """
import os
print(os.environ["EXPECTED_MAIN_SHA"])
print(os.environ["EXPECTED_MANIFEST_DIGEST"])
print("token=" + os.environ["EXPECTED_MAIN_SHA"])
print(os.environ["RELEASE_SUPERVISOR_TEST_SECRET"])
raise SystemExit(9)
"""
        environment = dict(os.environ)
        environment["EXPECTED_MAIN_SHA"] = main_sha
        environment["EXPECTED_MANIFEST_DIGEST"] = manifest_digest
        environment["RELEASE_SUPERVISOR_TEST_SECRET"] = explicit_secret

        result, _capture_path, events = self.run_supervisor(
            self.python_command(source),
            environment=environment,
        )
        failure = events[-1]
        tail = failure["output_tail"]

        self.assertEqual(result.returncode, 9, result.stderr)
        self.assertEqual(failure["failure_kind"], "command_failure")
        self.assert_mandatory_tail(failure, 8192)
        self.assertEqual(tail.count(main_sha), 1)
        self.assertIn(manifest_digest, tail)
        self.assertNotIn(explicit_secret, tail)
        self.assertGreaterEqual(tail.count("[REDACTED]"), 2)

    def test_help_documents_exec_and_ephemeral_capture_contract(self) -> None:
        result = subprocess.run(
            [sys.executable, str(SUPERVISOR), "--help"],
            cwd=SCRIPTS_DIR.parent,
            text=True,
            capture_output=True,
            timeout=3,
            check=False,
        )

        self.assertEqual(result.returncode, 0)
        self.assertIn("use exec", result.stdout)
        self.assertIn("makes its raw mode-0600 capture anonymous", result.stdout)
        self.assertIn("never upload", result.stdout)


if __name__ == "__main__":
    unittest.main()
