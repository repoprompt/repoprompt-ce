#!/usr/bin/env python3
"""Focused tests for conductor interactive app lifecycle intent."""

from __future__ import annotations

import contextlib
import errno
import fcntl
import io
import json
import os
import queue
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import conductor  # noqa: E402


def pid_is_executing(pid: int) -> bool:
    completed = subprocess.run(
        ["ps", "-p", str(pid), "-o", "stat="],
        text=True,
        capture_output=True,
        timeout=2.0,
    )
    state = completed.stdout.strip()
    return completed.returncode == 0 and bool(state) and not state.startswith("Z")


class LifecycleTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self._states: list[conductor.DaemonState] = []

    def tearDown(self) -> None:
        for state in self._states:
            with state.condition:
                workers = list(state._worker_threads)
            for worker in workers:
                worker.join(timeout=2.0)
            state._io_worker.join()
            state._output_pump.close()

    def make_state(self) -> tuple[tempfile.TemporaryDirectory[str], conductor.DaemonState]:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        jobs_dir = root / "jobs"
        jobs_dir.mkdir()
        paths = conductor.Paths(
            repo_root=root,
            repo_hash="test",
            state_dir=root,
            socket_path=root / "conductor.sock",
            pid_path=root / "conductor.pid",
            lock_path=root / "conductor.lock",
            jobs_dir=jobs_dir,
            daemon_log_path=root / "daemon.log",
            daemon_meta_path=root / "daemon.json",
            running_processes_path=root / "running.json",
        )
        state = conductor.DaemonState(paths)
        self._states.append(state)
        return tmp, state

    def make_job(
        self,
        state: conductor.DaemonState,
        ticket: str,
        operation: str,
        args: dict,
        lanes: list[str],
        job_state: str = "queued",
        request_key: str | None = None,
        fingerprint: str = "fingerprint",
    ) -> conductor.Job:
        return conductor.Job(
            ticket=ticket,
            request_key=request_key,
            fingerprint=fingerprint,
            operation=operation,
            args=args,
            lanes=lanes,
            timeout=None,
            verbose=False,
            env={},
            created_at=conductor.now(),
            log_path=state.paths.jobs_dir / f"{ticket}.log",
            state=job_state,
        )


class ConductorControlPlaneIsolationTests(LifecycleTestCase):
    def test_gated_log_write_does_not_block_status_snapshot(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(state, "gated-log", "build", {}, ["build"], job_state="running")
        state.jobs[job.ticket] = job
        entered = threading.Event()
        release = threading.Event()
        finished = threading.Event()

        def gated_write(*_args: object) -> None:
            entered.set()
            self.assertTrue(release.wait(1.0))

        with mock.patch.object(state, "_write_job_log_record", side_effect=gated_write):
            with state.condition:
                state._append_system_line_locked(job, "gated\n")
            self.assertTrue(entered.wait(1.0))

            def snapshot() -> None:
                state.status_payload()
                finished.set()

            reader = threading.Thread(target=snapshot)
            reader.start()
            self.assertTrue(finished.wait(1.0), "status waited on external log I/O")
            release.set()
            reader.join(timeout=1.0)

        self.assertFalse(reader.is_alive())

    def test_gated_process_discovery_releases_central_condition_and_discards_stale_result(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(state, "gated-ps", "build", {}, ["build"], job_state="running")
        job.job_generation = 4
        job.process_generation = 7
        job.process_pid = 123
        job.process_start = "old"
        job.tracked_processes = {123: "old"}
        state.jobs[job.ticket] = job
        entered = threading.Event()
        release = threading.Event()
        completed = threading.Event()

        def gated_snapshot() -> dict[int, tuple[int, str]]:
            entered.set()
            self.assertTrue(release.wait(1.0))
            return {123: (1, "old"), 456: (123, "child")}

        def discover() -> None:
            with state.condition:
                state._refresh_process_tree_locked(job)
            completed.set()

        with mock.patch.object(conductor, "process_table_snapshot", side_effect=gated_snapshot):
            worker = threading.Thread(target=discover)
            worker.start()
            self.assertTrue(entered.wait(1.0))
            payload = state.status_payload()
            self.assertEqual(payload["runningJobs"][0]["ticket"], job.ticket)
            with state.condition:
                job.process_generation += 1
            release.set()
            self.assertTrue(completed.wait(1.0))
            worker.join(timeout=1.0)

        self.assertFalse(worker.is_alive())
        self.assertNotIn(456, job.tracked_processes)

    def test_running_registry_rejects_older_generation_after_newer_publication(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        state._running_registry_generation = 2
        newer = {"version": 2, "generation": 2, "processes": [{"ticket": "new"}]}
        older = {"version": 2, "generation": 1, "processes": [{"ticket": "old"}]}

        state._publish_running_processes(2, newer)
        state._publish_running_processes(1, older)

        persisted = json.loads(state.paths.running_processes_path.read_text(encoding="utf-8"))
        self.assertEqual(persisted["generation"], 2)
        self.assertEqual(persisted["processes"][0]["ticket"], "new")

    def test_phase_generation_and_heavy_admission_are_additive_payload_fields(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(state, "phase", "build", {}, ["build"], job_state="running")
        job.job_generation = 9
        job.process_generation = 3
        job.phase = "waitingGlobalHeavy"
        job.global_heavy_admission_state = "waiting"

        payload = job.to_payload()

        self.assertEqual(payload["phase"], "waitingGlobalHeavy")
        self.assertEqual(payload["jobGeneration"], 9)
        self.assertEqual(payload["processGeneration"], 3)
        self.assertTrue(payload["globalHeavyAdmission"]["displayOnly"])
        self.assertEqual(payload["globalHeavyAdmission"]["state"], "waiting")

    def test_daemon_contact_health_distinguishes_unresponsive_ambiguous_and_stopped(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        error = socket.timeout("gated")

        with mock.patch.object(conductor, "read_pid", return_value=42), mock.patch.object(
            conductor, "pid_alive", return_value=True
        ), mock.patch.object(conductor, "verify_daemon_pid_identity", return_value=True), mock.patch.object(
            Path, "exists", return_value=True
        ):
            unresponsive = conductor.daemon_contact_health(state.paths, error)
        with mock.patch.object(conductor, "read_pid", return_value=42), mock.patch.object(
            conductor, "pid_alive", return_value=True
        ), mock.patch.object(conductor, "verify_daemon_pid_identity", return_value=False), mock.patch.object(
            Path, "exists", return_value=True
        ):
            ambiguous = conductor.daemon_contact_health(state.paths, error)
        with mock.patch.object(conductor, "read_pid", return_value=None), mock.patch.object(
            Path, "exists", return_value=False
        ):
            stopped = conductor.daemon_contact_health(state.paths, error)

        self.assertIs(unresponsive["running"], True)
        self.assertEqual(unresponsive["health"]["state"], "unresponsive")
        self.assertIs(ambiguous["running"], None)
        self.assertEqual(ambiguous["health"]["state"], "ambiguous")
        self.assertIs(stopped["running"], False)
        self.assertEqual(stopped["health"]["state"], "stopped")


class ConductorCheckpointThreeTests(LifecycleTestCase):
    def write_stale_metadata(self, state: conductor.DaemonState, pid: int = 999_999) -> None:
        state.paths.pid_path.write_text(f"{pid}\n", encoding="utf-8")
        state.paths.daemon_meta_path.write_text(
            json.dumps(
                {
                    "pid": pid,
                    "repoRoot": str(state.paths.repo_root),
                    "repoHash": state.paths.repo_hash,
                    "script": str(Path(conductor.__file__).resolve()),
                    "processStart": "stale-start",
                }
            ),
            encoding="utf-8",
        )
        os.chmod(state.paths.daemon_meta_path, 0o600)

    def test_ambiguous_live_socket_is_preserved_and_blocks_replacement(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        self.write_stale_metadata(state)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(state.paths.socket_path))
        listener.listen(1)
        self.addCleanup(listener.close)

        result = conductor.cleanup_stale_files(state.paths)

        self.assertEqual(result.state, "ambiguous")
        self.assertTrue(state.paths.pid_path.exists())
        self.assertTrue(state.paths.socket_path.exists())
        self.assertTrue(state.paths.daemon_meta_path.exists())
        with mock.patch.object(conductor, "cleanup_stale_files", return_value=result), mock.patch.object(
            conductor,
            "compatible_daemon_status_or_stop_idle_mismatch",
            return_value=(None, conductor.ConductorError("unresponsive fixture")),
        ), self.assertRaises(conductor.DaemonContactError):
            conductor.ensure_daemon(state.paths)

    def test_proven_reused_pid_with_absent_socket_is_recovered(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        self.write_stale_metadata(state, pid=4242)

        with mock.patch.object(conductor, "pid_alive", return_value=True), mock.patch.object(
            conductor, "process_start_token", return_value="different-process"
        ):
            result = conductor.cleanup_stale_files(state.paths)

        self.assertEqual(result.state, "cleaned")
        self.assertIn("proven pid reuse", result.reason)
        self.assertFalse(state.paths.pid_path.exists())
        self.assertFalse(state.paths.daemon_meta_path.exists())

    def test_proven_reused_pid_with_live_socket_preserves_ambiguous_evidence(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        self.write_stale_metadata(state, pid=4242)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(state.paths.socket_path))
        listener.listen(1)
        self.addCleanup(listener.close)

        with mock.patch.object(conductor, "pid_alive", return_value=True), mock.patch.object(
            conductor, "process_start_token", return_value="different-process"
        ):
            result = conductor.cleanup_stale_files(state.paths)

        self.assertEqual(result.state, "ambiguous")
        self.assertTrue(state.paths.pid_path.exists())
        self.assertTrue(state.paths.daemon_meta_path.exists())

    def test_refused_stale_socket_is_removed_with_unchanged_exact_evidence(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        self.write_stale_metadata(state)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(state.paths.socket_path))
        listener.close()
        state.paths.running_processes_path.write_text('{"version":2,"processes":[]}', encoding="utf-8")

        result = conductor.cleanup_stale_files(state.paths)

        self.assertEqual(result.state, "cleaned")
        self.assertTrue(result.cleaned)
        self.assertFalse(state.paths.pid_path.exists())
        self.assertFalse(state.paths.socket_path.exists())
        self.assertFalse(state.paths.daemon_meta_path.exists())
        self.assertFalse(state.paths.running_processes_path.exists())

    def test_worker_cleanup_preserves_registry_identity_for_final_stale_evidence_check(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        conductor._atomic_write_json(
            state.paths.running_processes_path,
            {"version": 3, "generation": 1, "processes": []},
        )
        registry_identity = conductor._path_identity(state.paths.running_processes_path)

        cleanup = conductor.cleanup_running_process_groups(state.paths)

        self.assertTrue(cleanup["safeToForget"])
        self.assertEqual(conductor._path_identity(state.paths.running_processes_path), registry_identity)

    def test_stale_cleanup_rejects_registry_replacement_during_worker_cleanup(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        self.write_stale_metadata(state)
        conductor._atomic_write_json(
            state.paths.running_processes_path,
            {"version": 3, "generation": 1, "processes": []},
        )

        def replace_registry(_paths: conductor.Paths) -> dict[str, object]:
            conductor._atomic_write_json(
                state.paths.running_processes_path,
                {"version": 3, "generation": 2, "processes": []},
            )
            return {"safeToForget": True}

        with mock.patch.object(conductor, "cleanup_running_process_groups", side_effect=replace_registry):
            result = conductor.cleanup_stale_files(state.paths)

        self.assertEqual(result.state, "ambiguous")
        self.assertFalse(result.cleaned)
        self.assertIn("evidence changed before cleanup", result.reason)
        self.assertTrue(state.paths.pid_path.exists())
        self.assertTrue(state.paths.daemon_meta_path.exists())
        self.assertTrue(state.paths.running_processes_path.exists())

    def test_stale_cleanup_start_lock_cannot_unlink_replacement_registry(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        self.write_stale_metadata(state)
        conductor._atomic_write_json(
            state.paths.running_processes_path,
            {"version": 3, "generation": 1, "processes": []},
        )
        ready_path = state.paths.state_dir / "replacement-ready"
        acquired_path = state.paths.state_dir / "replacement-acquired"
        child: subprocess.Popen[str] | None = None
        original_unlink = Path.unlink

        def unlink_with_waiting_replacement(path: Path, *args: object, **kwargs: object) -> None:
            nonlocal child
            if path == state.paths.pid_path and child is None:
                child = subprocess.Popen(
                    [
                        sys.executable,
                        "-c",
                        textwrap.dedent(
                            """
                            import fcntl
                            import json
                            import os
                            import sys
                            from pathlib import Path

                            lock_path, registry_path, ready_path, acquired_path = map(Path, sys.argv[1:])
                            ready_path.write_text("ready", encoding="utf-8")
                            with lock_path.open("a+") as lock_file:
                                fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
                                acquired_path.write_text("acquired", encoding="utf-8")
                                temporary = registry_path.with_suffix(".replacement")
                                temporary.write_text(
                                    json.dumps({"version": 3, "generation": 2, "processes": []}),
                                    encoding="utf-8",
                                )
                                os.replace(temporary, registry_path)
                            """
                        ),
                        str(state.paths.lock_path),
                        str(state.paths.running_processes_path),
                        str(ready_path),
                        str(acquired_path),
                    ],
                    text=True,
                )
                deadline = time.monotonic() + 2.0
                while not ready_path.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(ready_path.exists(), "replacement process did not reach the start-lock barrier")
                # With the cleanup transaction holding daemon.start.lock, the
                # replacement cannot acquire or publish before stale evidence
                # unlinking finishes. Without that lock this wait observes the
                # replacement and the following pathname unlink deletes it.
                deadline = time.monotonic() + 0.2
                while not acquired_path.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertFalse(acquired_path.exists())
            original_unlink(path, *args, **kwargs)

        with mock.patch.object(Path, "unlink", new=unlink_with_waiting_replacement):
            result = conductor.cleanup_stale_files(state.paths)

        assert child is not None
        self.assertEqual(child.wait(timeout=2.0), 0)
        self.assertEqual(result.state, "cleaned")
        self.assertFalse(state.paths.pid_path.exists())
        self.assertFalse(state.paths.daemon_meta_path.exists())
        replacement = json.loads(state.paths.running_processes_path.read_text(encoding="utf-8"))
        self.assertEqual(replacement["generation"], 2)

    def test_recovery_signals_only_exact_pid_start_and_pgid_anchor(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        state.paths.running_processes_path.write_text(
            json.dumps(
                {
                    "version": 2,
                    "processes": [
                        {"pid": 101, "pgid": 201, "processStart": "exact"},
                        {"pid": 102, "pgid": 202, "processStart": "reused"},
                    ],
                }
            ),
            encoding="utf-8",
        )

        with mock.patch.object(
            conductor,
            "process_table_snapshot",
            return_value={101: (1, "exact"), 102: (1, "different")},
        ), mock.patch.object(conductor.os, "getpgrp", return_value=999), mock.patch.object(
            conductor.os, "getpgid", side_effect=lambda pid: {101: 201, 102: 202}[pid]
        ), mock.patch.object(conductor.os, "killpg") as killpg:
            report = conductor.signal_running_process_groups(state.paths, signal.SIGTERM)

        killpg.assert_called_once_with(201, signal.SIGTERM)
        self.assertEqual(report["verified"], [101])
        self.assertEqual(report["skipped"], [102])

    def test_stale_daemon_cleanup_terminates_wrapper_and_detached_cache_attempt_group(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        self.write_stale_metadata(state)
        ticket = "11111111-1111-1111-1111-111111111111"
        attempt_record = state.paths.jobs_dir / f"{ticket}.cache-attempt.json"
        state.paths.running_processes_path.write_text(
            json.dumps(
                {
                    "version": 3,
                    "processes": [
                        {
                            "ticket": ticket,
                            "pid": 101,
                            "pgid": 101,
                            "processStart": "wrapper-start",
                            "cacheAttemptRecord": attempt_record.name,
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        conductor._atomic_write_json(
            attempt_record,
            {
                "version": 1,
                "state": "active",
                "ticket": ticket,
                "wrapperPID": 101,
                "wrapperStartToken": "wrapper-start",
                "attemptPID": 202,
                "attemptPGID": 202,
                "attemptStartToken": "attempt-start",
            },
        )
        snapshot = {
            101: (1, "wrapper-start"),
            202: (101, "attempt-start"),
            # This descendant shares attempt pgid 202; killpg(202) covers both.
            303: (202, "descendant-start"),
        }

        def signal_group(pgid: int, _sig: signal.Signals) -> None:
            if pgid == 101:
                snapshot.pop(101, None)
            elif pgid == 202:
                snapshot.pop(202, None)
                snapshot.pop(303, None)

        with mock.patch.object(conductor, "process_table_snapshot", side_effect=lambda: dict(snapshot)), mock.patch.object(
            conductor.os, "getpgrp", return_value=999
        ), mock.patch.object(
            conductor.os, "getpgid", side_effect=lambda pid: {101: 101, 202: 202}[pid]
        ), mock.patch.object(conductor.os, "killpg", side_effect=signal_group) as killpg, mock.patch.object(
            conductor, "_wait_for_recovery_targets_exit", return_value=[]
        ):
            result = conductor.cleanup_stale_files(state.paths)

        self.assertEqual(result.state, "cleaned")
        self.assertEqual(
            killpg.call_args_list,
            [mock.call(101, signal.SIGTERM), mock.call(202, signal.SIGTERM)],
        )
        self.assertFalse(attempt_record.exists())
        self.assertFalse(state.paths.running_processes_path.exists())
        self.assertFalse(state.paths.pid_path.exists())
        self.assertFalse(state.paths.daemon_meta_path.exists())

    def assert_attempt_rollover_is_recovered(self, *, initial_record_present: bool) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        self.write_stale_metadata(state)
        ticket = "44444444-4444-4444-4444-444444444444"
        attempt_record = state.paths.jobs_dir / f"{ticket}.cache-attempt.json"
        state.paths.running_processes_path.write_text(
            json.dumps(
                {
                    "version": 3,
                    "processes": [
                        {
                            "ticket": ticket,
                            "pid": 101,
                            "pgid": 101,
                            "processStart": "wrapper-start",
                            "cacheAttemptRecord": attempt_record.name,
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        snapshot = {101: (1, "wrapper-start")}
        if initial_record_present:
            conductor._atomic_write_json(
                attempt_record,
                {
                    "version": 1,
                    "state": "active",
                    "ticket": ticket,
                    "wrapperPID": 101,
                    "wrapperStartToken": "wrapper-start",
                    "attemptPID": 202,
                    "attemptPGID": 202,
                    "attemptStartToken": "attempt-a",
                },
            )
            snapshot[202] = (101, "attempt-a")

        def signal_group(pgid: int, _sig: signal.Signals) -> None:
            if pgid == 101:
                # Simulate the cache wrapper committing attempt B immediately
                # before TERM takes effect. Recovery must re-read after wrapper
                # exit instead of unlinking the newly replaced sidecar.
                conductor._atomic_write_json(
                    attempt_record,
                    {
                        "version": 1,
                        "state": "active",
                        "ticket": ticket,
                        "wrapperPID": 101,
                        "wrapperStartToken": "wrapper-start",
                        "attemptPID": 404,
                        "attemptPGID": 404,
                        "attemptStartToken": "attempt-b",
                    },
                )
                snapshot.pop(101, None)
                snapshot.pop(202, None)
                snapshot[404] = (1, "attempt-b")
            elif pgid == 404:
                snapshot.pop(404, None)

        with mock.patch.object(conductor, "process_table_snapshot", side_effect=lambda: dict(snapshot)), mock.patch.object(
            conductor.os, "getpgrp", return_value=999
        ), mock.patch.object(
            conductor.os, "getpgid", side_effect=lambda pid: {101: 101, 202: 202, 404: 404}[pid]
        ), mock.patch.object(conductor.os, "killpg", side_effect=signal_group) as killpg, mock.patch.object(
            conductor, "_wait_for_recovery_targets_exit", return_value=[]
        ):
            result = conductor.cleanup_stale_files(state.paths)

        self.assertEqual(result.state, "cleaned")
        self.assertEqual(
            killpg.call_args_list,
            [mock.call(101, signal.SIGTERM), mock.call(404, signal.SIGTERM)],
        )
        self.assertFalse(attempt_record.exists())
        self.assertFalse(state.paths.running_processes_path.exists())

    def test_stale_cleanup_recovers_attempt_a_to_b_rollover(self) -> None:
        self.assert_attempt_rollover_is_recovered(initial_record_present=True)

    def test_stale_cleanup_recovers_missing_to_published_attempt_transition(self) -> None:
        self.assert_attempt_rollover_is_recovered(initial_record_present=False)

    def test_reused_cache_attempt_identity_is_not_signaled(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        ticket = "22222222-2222-2222-2222-222222222222"
        attempt_record = state.paths.jobs_dir / f"{ticket}.cache-attempt.json"
        state.paths.running_processes_path.write_text(
            json.dumps(
                {
                    "version": 3,
                    "processes": [
                        {
                            "ticket": ticket,
                            "pid": 101,
                            "pgid": 101,
                            "processStart": "wrapper-start",
                            "cacheAttemptRecord": attempt_record.name,
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        conductor._atomic_write_json(
            attempt_record,
            {
                "version": 1,
                "state": "active",
                "ticket": ticket,
                "wrapperPID": 101,
                "wrapperStartToken": "wrapper-start",
                "attemptPID": 202,
                "attemptPGID": 202,
                "attemptStartToken": "old-attempt-start",
            },
        )
        snapshot = {101: (1, "wrapper-start"), 202: (1, "reused-attempt-start")}

        with mock.patch.object(conductor, "process_table_snapshot", return_value=snapshot), mock.patch.object(
            conductor.os, "getpgrp", return_value=999
        ), mock.patch.object(conductor.os, "getpgid", return_value=101), mock.patch.object(
            conductor.os, "killpg"
        ) as killpg:
            report = conductor.signal_running_process_groups(state.paths, signal.SIGTERM)

        killpg.assert_called_once_with(101, signal.SIGTERM)
        self.assertEqual(report["verified"], [101])
        self.assertEqual(report["skipped"], [202])
        attempt_group = next(group for group in report["groups"] if group["kind"] == "cacheAttempt")
        self.assertEqual(attempt_group["state"], "stale")
        self.assertTrue(report["identityComplete"])

    def test_ambiguous_cache_attempt_record_preserves_stale_daemon_evidence(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        self.write_stale_metadata(state)
        ticket = "33333333-3333-3333-3333-333333333333"
        attempt_record = state.paths.jobs_dir / f"{ticket}.cache-attempt.json"
        state.paths.running_processes_path.write_text(
            json.dumps(
                {
                    "version": 3,
                    "processes": [
                        {
                            "ticket": ticket,
                            "pid": 101,
                            "pgid": 101,
                            "processStart": "wrapper-start",
                            "cacheAttemptRecord": attempt_record.name,
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        conductor._atomic_write_json(
            attempt_record,
            {
                "version": 1,
                "state": "active",
                "ticket": ticket,
                "wrapperPID": 101,
                "wrapperStartToken": "mismatched-wrapper",
                "attemptPID": 202,
                "attemptPGID": 202,
                "attemptStartToken": "attempt-start",
            },
        )

        with mock.patch.object(
            conductor, "process_table_snapshot", return_value={101: (1, "wrapper-start")}
        ), mock.patch.object(conductor.os, "getpgrp", return_value=999), mock.patch.object(
            conductor.os, "getpgid", return_value=101
        ), mock.patch.object(conductor.os, "killpg"):
            result = conductor.cleanup_stale_files(state.paths)

        self.assertEqual(result.state, "ambiguous")
        self.assertFalse(result.cleaned)
        self.assertTrue(attempt_record.exists())
        self.assertTrue(state.paths.running_processes_path.exists())
        self.assertTrue(state.paths.pid_path.exists())
        self.assertTrue(state.paths.daemon_meta_path.exists())

    def test_force_stop_waits_for_nonabortable_cache_publication_and_reports_policy(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(state, "publishing", "build", {}, ["build"], job_state="running")
        job.phase = "publishingCache"
        state.jobs[job.ticket] = job
        state.active_lanes["build"] = job.ticket
        deferred: list[tuple[object, tuple[object, ...]]] = []

        class DeferredThread:
            def __init__(self, *, target: object, args: tuple[object, ...] = (), **_kwargs: object) -> None:
                deferred.append((target, args))

            def start(self) -> None:
                return None

        with mock.patch.object(conductor.threading, "Thread", DeferredThread):
            payload = state.stop(force=True)

        self.assertFalse(job.cancel_requested)
        self.assertIn("non-abortable", job.cancellation_ignored_reason or "")
        self.assertEqual(
            payload["forceStop"],
            {
                "requested": True,
                "publicationPolicy": "waitForNonAbortableAtomicPublication",
                "publicationWaitTickets": [job.ticket],
                "publicationWaitTimeoutSeconds": conductor.BUILD_CACHE_FORCE_STOP_WAIT_SECONDS,
                "cancellationIgnored": True,
            },
        )
        self.assertEqual(len(deferred), 1)
        server = mock.Mock()
        state.server = server

        def complete_publication(*_args: object, **_kwargs: object) -> None:
            self.assertFalse(server.shutdown.called)
            job.state = "completed"
            job.phase = "terminal"

        with mock.patch.object(state.condition, "wait", side_effect=complete_publication) as wait, mock.patch.object(
            conductor.time, "sleep"
        ):
            state._force_shutdown_when_canceled([job.ticket])

        wait.assert_called_once_with(timeout=conductor.PROCESS_TREE_POLL_SECONDS)
        server.shutdown.assert_called_once_with()

    def test_force_stop_publication_wait_expiry_keeps_daemon_and_publication_intact(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(state, "publishing-timeout", "build", {}, ["build"], job_state="running")
        job.phase = "publishingCache"
        job.cancellation_ignored_reason = "immutable cache publication is non-abortable"
        state.jobs[job.ticket] = job
        state.shutdown_requested = True
        state.server = mock.Mock()

        with mock.patch.object(conductor, "BUILD_CACHE_FORCE_STOP_WAIT_SECONDS", 0.0), mock.patch.object(
            state, "_warn_job_locked"
        ) as warn, mock.patch.object(conductor.time, "sleep"):
            state._force_shutdown_when_canceled([job.ticket])

        self.assertFalse(state.shutdown_requested)
        self.assertEqual(job.state, "running")
        self.assertEqual(job.phase, "publishingCache")
        state.server.shutdown.assert_not_called()
        warn.assert_called_once_with(
            job,
            "buildCachePublicationStopWaitExpired",
            "daemon stop --force left non-abortable cache publication running after bounded wait",
        )

    def test_concurrent_terminal_waiters_coalesce_summary_and_both_receive_result(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(state, "summary", "build", {}, ["build"], job_state="completed")
        job.exit_code = 0
        job.log_path.write_text("Created: /tmp/App.app\n", encoding="utf-8")
        state.jobs[job.ticket] = job
        summarize_entered = threading.Event()
        second_refresh_entered = threading.Event()
        release_summary = threading.Event()
        calls = 0
        refresh_calls = 0
        refresh_lock = threading.Lock()
        results: dict[str, dict] = {}
        original_refresh = state._refresh_output_summary
        synchronization_timeout = conductor.LOG_FLUSH_WAIT_SECONDS

        def summarize(*_args: object, **_kwargs: object) -> dict:
            nonlocal calls
            calls += 1
            summarize_entered.set()
            self.assertTrue(release_summary.wait(synchronization_timeout))
            return {"headline": "completed successfully", "sections": []}

        def refresh(actual_job: conductor.Job) -> None:
            nonlocal refresh_calls
            with refresh_lock:
                refresh_calls += 1
                if refresh_calls == 2:
                    second_refresh_entered.set()
            original_refresh(actual_job)

        def wait(name: str) -> None:
            results[name] = state.job_wait(job.ticket, None, timeout=synchronization_timeout)

        with mock.patch.object(conductor.OutputSummarizer, "summarize_file", side_effect=summarize), mock.patch.object(
            state, "_refresh_output_summary", side_effect=refresh
        ):
            first = threading.Thread(target=wait, args=("first",))
            second = threading.Thread(target=wait, args=("second",))
            first.start()
            self.assertTrue(summarize_entered.wait(synchronization_timeout))
            second.start()
            self.assertTrue(second_refresh_entered.wait(synchronization_timeout))
            release_summary.set()
            first.join(timeout=synchronization_timeout)
            second.join(timeout=synchronization_timeout)

        self.assertFalse(first.is_alive())
        self.assertFalse(second.is_alive())
        self.assertEqual(calls, 1)
        self.assertEqual(results["first"]["outputSummary"]["headline"], "completed successfully")
        self.assertEqual(results["second"]["outputSummary"]["headline"], "completed successfully")
        self.assertEqual(job.phase, "terminal")

    def test_tail_fragments_and_total_bytes_are_bounded(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(state, "tail", "build", {}, [], job_state="running")

        with state.condition:
            for index in range(100):
                state._append_tail_locked(job, f"{index}:" + "x" * 8_000 + "\n")

        self.assertLessEqual(len(job.tail), conductor.LOG_TAIL_LINES)
        self.assertLessEqual(
            sum(len(line.encode("utf-8")) for line in job.tail),
            conductor.LOG_TAIL_MAX_BYTES,
        )
        self.assertTrue(all(len(line.encode("utf-8")) <= conductor.LOG_TAIL_FRAGMENT_MAX_BYTES for line in job.tail))
        self.assertEqual(job.tail_bytes, sum(len(line.encode("utf-8")) for line in job.tail))

    def test_tail_multibyte_truncation_accounts_reencoded_fragment_exactly(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(state, "tail-utf8", "build", {}, [], job_state="running")

        with state.condition:
            state._append_tail_locked(job, "é" * conductor.LOG_TAIL_FRAGMENT_MAX_BYTES + "\n")

        self.assertEqual(job.tail_bytes, sum(len(line.encode("utf-8")) for line in job.tail))
        self.assertLessEqual(job.tail_bytes, conductor.LOG_TAIL_MAX_BYTES)

    def test_log_flush_frontier_does_not_skip_earlier_unsettled_sequence(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(state, "log-frontier", "build", {}, [], job_state="running")
        job.log_sequence = 2

        with state.condition:
            state._settle_job_log_sequence_locked(job, 2)
            self.assertEqual(job.log_flushed_sequence, 0)
            self.assertEqual(job.log_settled_sequences, {2})
            state._settle_job_log_sequence_locked(job, 1)

        self.assertEqual(job.log_flushed_sequence, 2)
        self.assertEqual(job.log_settled_sequences, set())

    def test_force_stop_ignores_corrupt_legacy_worker_registry_after_exact_daemon_verification(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        state.paths.running_processes_path.write_text("{corrupt", encoding="utf-8")
        alive = iter([True, False, False, False])

        with mock.patch.object(conductor, "read_pid", return_value=4242), mock.patch.object(
            conductor, "pid_alive", side_effect=lambda _pid: next(alive)
        ), mock.patch.object(conductor, "verify_daemon_pid_identity", return_value=True), mock.patch.object(
            conductor, "process_table_snapshot", return_value={}
        ), mock.patch.object(conductor.os, "kill"), mock.patch.object(
            conductor, "cleanup_stale_files", return_value=conductor.DaemonRecoveryResult("cleaned", True, "fixture")
        ):
            payload = conductor.force_stop_unresponsive_daemon(state.paths)

        self.assertTrue(payload["stopped"])
        self.assertIn("registry:", payload["workerSignals"]["term"]["invalid"][0])

    def test_protocol_11_registry_skips_identityless_entry_and_signals_exact_entry(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        state.paths.running_processes_path.write_text(
            json.dumps(
                {
                    "version": 1,
                    "processes": [
                        {"pid": 101, "pgid": 201},
                        {"pid": 102, "pgid": 202, "processStart": "exact"},
                    ],
                }
            ),
            encoding="utf-8",
        )

        with mock.patch.object(conductor, "process_table_snapshot", return_value={102: (1, "exact")}), mock.patch.object(
            conductor.os, "getpgrp", return_value=999
        ), mock.patch.object(conductor.os, "getpgid", return_value=202), mock.patch.object(conductor.os, "killpg") as killpg:
            report = conductor.signal_running_process_groups(state.paths, signal.SIGTERM)

        killpg.assert_called_once_with(202, signal.SIGTERM)
        self.assertEqual(report["verified"], [102])
        self.assertEqual(report["invalid"], ["entry 0: missing exact identity evidence"])

    def test_summary_does_not_wait_for_unrelated_io_backlog_after_own_log_is_flushed(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(state, "independent-flush", "build", {}, ["build"], job_state="completed")
        job.exit_code = 0
        job.log_sequence = 4
        job.log_flushed_sequence = 4
        job.log_path.write_text("Created: /tmp/App.app\n", encoding="utf-8")
        state.jobs[job.ticket] = job
        backlog_entered = threading.Event()
        backlog_release = threading.Event()
        summary_complete = threading.Event()

        def gated_unrelated_io() -> None:
            backlog_entered.set()
            backlog_release.wait()

        self.assertTrue(state._io_worker.submit(gated_unrelated_io))
        self.assertTrue(backlog_entered.wait(1.0))
        refresher = threading.Thread(target=lambda: (state._refresh_output_summary(job), summary_complete.set()))
        refresher.start()
        self.assertTrue(summary_complete.wait(1.0), "summary waited for unrelated global I/O backlog")
        backlog_release.set()
        refresher.join(timeout=1.0)
        self.assertFalse(refresher.is_alive())
        self.assertEqual(job.output_summary["headline"], "completed successfully")

    def test_cancel_cleanup_wait_returns_pending_at_bounded_deadline(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(state, "cancel-bounded", "build", {}, ["build"], job_state="running")
        job.cleanup_in_flight = True
        state.jobs[job.ticket] = job

        with mock.patch.object(state, "_request_process_cleanup_locked"), mock.patch.object(
            conductor.time, "monotonic", side_effect=[100.0, 100.0 + conductor.CANCEL_CLEANUP_WAIT_SECONDS]
        ):
            payload = state.job_cancel(job.ticket, None)

        self.assertTrue(payload["cancellationPending"])
        self.assertTrue(job.cancel_requested)
        self.assertEqual(job.phase, "canceling")

    def test_output_registration_transfers_ownership_without_waiting_for_pump_thread(self) -> None:
        pump = conductor.ProcessOutputPump.__new__(conductor.ProcessOutputPump)
        submitted: list[tuple[str, conductor.ProcessOutputChannel]] = []
        pump._submit = lambda command, channel: submitted.append((command, channel))

        channel = pump.register("ticket", 42, "pipe")

        self.assertEqual(submitted, [("register", channel)])
        self.assertFalse(channel.registered.is_set())

    def test_output_completion_wait_starts_after_pump_acknowledges_finalization(self) -> None:
        channel = conductor.ProcessOutputChannel("ticket", 42, "pipe")
        order: list[str] = []
        channel.result = conductor.ProcessOutputResult(False, None, 17)
        channel.completion = mock.Mock()
        channel.completion.is_set.return_value = False
        channel.completion.wait.side_effect = lambda timeout: order.append(f"completion:{timeout}") or True
        channel.finalization_started = mock.Mock()
        channel.finalization_started.wait.side_effect = lambda timeout: order.append(f"started:{timeout}") or True

        result = conductor.ProcessOutputPump.wait_for_completion(channel)

        self.assertEqual(
            order,
            [
                f"started:{conductor.OUTPUT_FINALIZATION_WAIT_SECONDS}",
                f"completion:{conductor.OUTPUT_FINALIZATION_WAIT_SECONDS}",
            ],
        )
        self.assertEqual(result, channel.result)

    def test_output_pump_shutdown_closes_queued_reader_and_rejects_new_transfer(self) -> None:
        pump = conductor.ProcessOutputPump.__new__(conductor.ProcessOutputPump)
        pump._submission_lock = threading.Lock()
        pump._stopping = True
        pump._commands = queue.Queue()
        pump._channels = {}
        pump._selector = mock.Mock()
        closed: list[int] = []
        pump._close_fd = closed.append
        pump._on_line = lambda _ticket, _line: None
        channel = conductor.ProcessOutputChannel("ticket", 43, "pipe")
        pump._commands.put_nowait(("register", channel))

        pump._finish_queued_channels("pumpShutdown")

        self.assertEqual(closed, [43])
        self.assertEqual(channel.result.reason, "pumpShutdown")
        with self.assertRaisesRegex(conductor.ConductorError, "output pump is stopped"):
            pump._submit("register", conductor.ProcessOutputChannel("new", 44, "pipe"))

    def test_output_finalization_deadline_drain_is_bounded_for_active_inherited_writer(self) -> None:
        pump = conductor.ProcessOutputPump.__new__(conductor.ProcessOutputPump)
        pump._clock = lambda: 10.0
        pump._selector = mock.Mock()
        pump._close_fd = lambda _fd: None
        pump._on_line = lambda _ticket, _line: None
        channel = conductor.ProcessOutputChannel("ticket", 42, "pipe", finalization_deadline=9.0)
        pump._channels = {42: channel}
        reads = 0

        def endless_read(active: conductor.ProcessOutputChannel) -> None:
            nonlocal reads
            reads += 1
            active.bytes_read += 128 * 1024

        pump._read_available = endless_read
        pump._finish_expired_channels()

        self.assertEqual(reads, conductor.OUTPUT_FINALIZATION_DRAIN_MAX_BYTES // (128 * 1024))
        self.assertIsNotNone(channel.result)
        assert channel.result is not None
        self.assertTrue(channel.result.truncated)
        self.assertEqual(channel.result.reason, "inheritedWriterDeadline")

    def test_health_warning_expires_and_daemon_returns_to_healthy(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        state._daemon_infrastructure_warnings.append(
            {"kind": "old", "message": "old warning", "observedAt": 100.0}
        )
        with mock.patch.object(conductor, "now", return_value=100.0 + conductor.INFRASTRUCTURE_WARNING_TTL_SECONDS + 1.0):
            payload = state.status_payload()

        self.assertEqual(payload["health"]["state"], "healthy")
        self.assertEqual(payload["health"]["issues"], [])

    def make_fair_metadata(self, label: str) -> dict[str, object]:
        return {
            "lockKind": "global-heavy",
            "ticket": label,
            "operation": "build",
            "operationLabel": label,
            "repoRoot": "/fixture",
            "repoHash": "fixture",
            "worktree": "fixture",
            "acquiredAt": conductor.now(),
        }

    def test_fair_queue_writer_retries_short_writes_before_atomic_replace(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            conductor, "machine_lock_dir", return_value=Path(tmp)
        ), mock.patch.object(conductor, "process_start_token", return_value="owner"):
            coordinator = conductor.FairHeavyAdmission(self.make_fair_metadata("writer"), {})
            self.addCleanup(coordinator.close)
            with coordinator._queue_lock():
                payload = coordinator._load_queue()
                payload["generation"] += 1
                real_write = os.write
                writes: list[int] = []

                def short_write(fd: int, data: object) -> int:
                    chunk = bytes(data)[:7]
                    writes.append(len(chunk))
                    return real_write(fd, chunk)

                with mock.patch.object(conductor.os, "write", side_effect=short_write):
                    coordinator._write_queue(payload)
                persisted = coordinator._load_queue()

            self.assertGreater(len(writes), 1)
            self.assertEqual(persisted, payload)
            coordinator._remove_own_waiter()

    def test_fair_wait_exception_abandons_only_own_waiter(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            conductor, "machine_lock_dir", return_value=Path(tmp)
        ), mock.patch.object(conductor, "process_start_token", return_value="owner"):
            first = conductor.FairHeavyAdmission(self.make_fair_metadata("first"), {})
            second = conductor.FairHeavyAdmission(self.make_fair_metadata("second"), {})
            self.addCleanup(first.close)
            self.addCleanup(second.close)

            with mock.patch.object(first, "_wait_until_acquired", side_effect=RuntimeError("fixture")), self.assertRaises(
                RuntimeError
            ):
                first.wait()
            with second._queue_lock():
                waiter_ids = {item["waiterID"] for item in second._load_queue()["waiters"]}

            self.assertNotIn(first.waiter_id, waiter_ids)
            self.assertIn(second.waiter_id, waiter_ids)
            lease = second.wait()
            self.assertIsNotNone(lease)
            assert lease is not None
            lease.release()

    def test_corrupt_fair_queue_is_quarantined_and_kernel_admission_continues(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            conductor, "machine_lock_dir", return_value=Path(tmp)
        ), mock.patch.object(conductor, "process_start_token", return_value="owner"):
            queue_path = Path(tmp) / "global-heavy-queue.json"
            queue_path.write_text("{not-json", encoding="utf-8")
            os.chmod(queue_path, 0o600)
            warnings: list[tuple[str, str]] = []

            coordinator = conductor.FairHeavyAdmission(
                self.make_fair_metadata("local"), {}, on_warning=lambda kind, message: warnings.append((kind, message))
            )
            self.addCleanup(coordinator.close)
            lease = coordinator.wait()

            self.assertIsNotNone(lease)
            self.assertEqual(warnings[0][0], "fairQueueQuarantined")
            self.assertEqual(len(list(Path(tmp).glob("global-heavy-queue.corrupt-*.json"))), 1)
            assert lease is not None
            lease.release()

    def test_crashed_acquired_fair_holder_is_pruned_and_next_waiter_acquires(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            conductor, "machine_lock_dir", return_value=Path(tmp)
        ), mock.patch.object(conductor, "process_start_token", return_value="owner"):
            coordinator = conductor.FairHeavyAdmission(self.make_fair_metadata("next"), {})
            self.addCleanup(coordinator.close)
            dead_notify_path = coordinator.waiters_dir / "dead.sock"
            dead_notify = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            dead_notify.bind(str(dead_notify_path))
            self.addCleanup(dead_notify.close)
            self.addCleanup(lambda: dead_notify_path.unlink(missing_ok=True))
            with coordinator._queue_lock():
                payload = coordinator._load_queue()
                payload["waiters"].insert(
                    0,
                    {
                        "waiterID": "dead-holder",
                        "sequence": 0,
                        "state": "acquired",
                        "ownerPID": 222,
                        "ownerStartToken": "dead",
                        "notifySocketPath": str(dead_notify_path),
                        "acquiredSlotPath": str(Path(tmp) / "global-heavy-0.lock"),
                    },
                )
                payload["generation"] += 1
                coordinator._write_queue(payload)

            with mock.patch.object(conductor, "process_table_snapshot", return_value={}):
                lease = coordinator.wait()

            self.assertIsNotNone(lease)
            assert lease is not None
            lease.release()

    def test_head_waiter_competes_faster_and_surfaces_non_authoritative_legacy_holder(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            conductor, "machine_lock_dir", return_value=Path(tmp)
        ), mock.patch.object(conductor, "process_start_token", return_value="owner"):
            coordinator = conductor.FairHeavyAdmission(self.make_fair_metadata("head"), {})
            original_notify = coordinator.notify_socket
            original_notify.close()
            slot_path = Path(tmp) / "global-heavy-0.lock"
            holder = slot_path.open("a+", encoding="utf-8")
            fcntl.flock(holder.fileno(), fcntl.LOCK_EX)
            conductor.write_display_lock_metadata(holder, self.make_fair_metadata("legacy"))
            self.addCleanup(holder.close)
            timeouts: list[float] = []

            class FakeNotify:
                timeout = conductor.FAIR_HEAVY_RESCAN_SECONDS

                def settimeout(self, value: float) -> None:
                    self.timeout = value

                def gettimeout(self) -> float:
                    return self.timeout

                def recv(self, _size: int) -> bytes:
                    timeouts.append(self.timeout)
                    raise socket.timeout

                def close(self) -> None:
                    pass

            coordinator.notify_socket = FakeNotify()
            updates: list[dict | None] = []
            lease = coordinator.wait(
                cancel_check=lambda: len(timeouts) >= 2,
                update=lambda _position, _earlier: updates.append(coordinator.legacy_slot_holder),
            )

            self.assertIsNone(lease)
            self.assertEqual(timeouts, [conductor.FAIR_HEAVY_HEAD_RESCAN_SECONDS] * 2)
            observed = [item for item in updates if item is not None]
            self.assertTrue(observed)
            assert observed[-1] is not None
            self.assertFalse(observed[-1]["authoritative"])
            self.assertTrue(observed[-1]["displayOnly"])
            self.assertEqual(observed[-1]["classification"], "legacyOrUnregistered")
            self.assertEqual(observed[-1]["metadata"]["ticket"], "legacy")
            with coordinator._queue_lock():
                self.assertEqual(coordinator._load_queue()["waiters"], [])
            fcntl.flock(holder.fileno(), fcntl.LOCK_UN)

    def test_head_waiter_fast_competition_decays_to_bounded_low_cost_cadence(self) -> None:
        clock_value = [0.0]
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            conductor, "machine_lock_dir", return_value=Path(tmp)
        ), mock.patch.object(conductor, "process_start_token", return_value="owner"):
            coordinator = conductor.FairHeavyAdmission(
                self.make_fair_metadata("head-decay"), {}, clock=lambda: clock_value[0]
            )
            original_notify = coordinator.notify_socket
            original_notify.close()
            slot_path = Path(tmp) / "global-heavy-0.lock"
            holder = slot_path.open("a+", encoding="utf-8")
            fcntl.flock(holder.fileno(), fcntl.LOCK_EX)
            self.addCleanup(holder.close)
            timeouts: list[float] = []
            observed_cadences: list[float] = []

            class FakeNotify:
                timeout = conductor.FAIR_HEAVY_RESCAN_SECONDS

                def settimeout(self, value: float) -> None:
                    self.timeout = value

                def recv(self, _size: int) -> bytes:
                    timeouts.append(self.timeout)
                    if len(timeouts) == 1:
                        clock_value[0] = conductor.FAIR_HEAVY_HEAD_COMPETITION_SECONDS + 0.001
                    raise socket.timeout

                def close(self) -> None:
                    pass

            coordinator.notify_socket = FakeNotify()
            lease = coordinator.wait(
                cancel_check=lambda: len(timeouts) >= 2,
                update=lambda _position, _earlier: observed_cadences.append(coordinator.current_rescan_seconds),
            )

            self.assertIsNone(lease)
            self.assertEqual(
                timeouts,
                [conductor.FAIR_HEAVY_HEAD_RESCAN_SECONDS, conductor.FAIR_HEAVY_HEAD_DECAY_RESCAN_SECONDS],
            )
            self.assertIn(conductor.FAIR_HEAVY_HEAD_RESCAN_SECONDS, observed_cadences)
            self.assertIn(conductor.FAIR_HEAVY_HEAD_DECAY_RESCAN_SECONDS, observed_cadences)
            self.assertLess(conductor.FAIR_HEAVY_HEAD_DECAY_RESCAN_SECONDS, conductor.FAIR_HEAVY_RESCAN_SECONDS)
            with coordinator._queue_lock():
                self.assertEqual(coordinator._load_queue()["waiters"], [])
            fcntl.flock(holder.fileno(), fcntl.LOCK_UN)

    def test_non_head_waiter_remains_low_cost_and_cancel_removes_only_itself(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            conductor, "machine_lock_dir", return_value=Path(tmp)
        ), mock.patch.object(conductor, "process_start_token", return_value="owner"):
            first = conductor.FairHeavyAdmission(self.make_fair_metadata("first"), {})
            second = conductor.FairHeavyAdmission(self.make_fair_metadata("second"), {})
            self.addCleanup(first.close)
            original_notify = second.notify_socket
            original_notify.close()
            timeouts: list[float] = []

            class FakeNotify:
                timeout = conductor.FAIR_HEAVY_RESCAN_SECONDS

                def settimeout(self, value: float) -> None:
                    self.timeout = value

                def recv(self, _size: int) -> bytes:
                    timeouts.append(self.timeout)
                    raise socket.timeout

                def close(self) -> None:
                    pass

            second.notify_socket = FakeNotify()
            lease = second.wait(cancel_check=lambda: bool(timeouts))

            self.assertIsNone(lease)
            self.assertEqual(timeouts, [conductor.FAIR_HEAVY_RESCAN_SECONDS])
            self.assertIsNone(second.legacy_slot_holder)
            with first._queue_lock():
                waiter_ids = {item["waiterID"] for item in first._load_queue()["waiters"]}
            self.assertEqual(waiter_ids, {first.waiter_id})
            first.abandon()

    def test_global_wait_payload_labels_legacy_holder_non_authoritative(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(state, "legacy-holder", "build", {}, ["build"], job_state="running")
        observation = {
            "displayOnly": True,
            "authoritative": False,
            "classification": "legacyOrUnregistered",
            "slotPath": "/tmp/global-heavy-0.lock",
            "metadata": {"pid": 61641, "ticket": "legacy-ticket"},
        }
        job.global_heavy_admission_state = "waiting"
        job.global_heavy_slot_holder = "non-authoritative legacy slot holder"
        job.global_heavy_legacy_slot_holder = observation
        job.global_heavy_rescan_seconds = conductor.FAIR_HEAVY_HEAD_DECAY_RESCAN_SECONDS

        payload = job.to_payload()["globalHeavyAdmission"]

        self.assertEqual(payload["state"], "waiting")
        self.assertEqual(payload["legacySlotHolder"], observation)
        self.assertFalse(payload["legacySlotHolder"]["authoritative"])
        self.assertTrue(payload["legacySlotHolder"]["displayOnly"])
        self.assertEqual(payload["rescanSeconds"], conductor.FAIR_HEAVY_HEAD_DECAY_RESCAN_SECONDS)
        self.assertEqual(payload["headCompetitionSeconds"], conductor.FAIR_HEAVY_HEAD_COMPETITION_SECONDS)

    def test_process_table_snapshot_distinguishes_failure_from_authoritative_empty(self) -> None:
        with mock.patch.object(
            conductor.subprocess,
            "run",
            side_effect=subprocess.TimeoutExpired(["ps"], 2.0),
        ):
            self.assertIsNone(conductor.process_table_snapshot())

        completed = subprocess.CompletedProcess(["ps"], 0, stdout="", stderr="")
        with mock.patch.object(conductor.subprocess, "run", return_value=completed):
            self.assertEqual(conductor.process_table_snapshot(), {})

    def test_fair_pruning_retains_all_remote_waiters_after_inconclusive_forced_refresh(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            conductor, "machine_lock_dir", return_value=Path(tmp)
        ), mock.patch.object(conductor, "process_start_token", return_value="owner"):
            coordinator = conductor.FairHeavyAdmission(self.make_fair_metadata("local"), {})
            self.addCleanup(coordinator.close)
            remotes: list[socket.socket] = []
            remote_paths: list[Path] = []
            for index in range(2):
                remote_path = coordinator.waiters_dir / f"remote-inconclusive-{index}.sock"
                remote = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
                remote.bind(str(remote_path))
                remotes.append(remote)
                remote_paths.append(remote_path)
                self.addCleanup(remote.close)
                self.addCleanup(remote_path.unlink, missing_ok=True)
            with coordinator._queue_lock():
                payload = coordinator._load_queue()
                for index, remote_path in enumerate(remote_paths):
                    payload["waiters"].append(
                        {
                            "waiterID": f"remote-inconclusive-{index}",
                            "sequence": 100 + index,
                            "state": "waiting",
                            "ownerPID": 222 + index,
                            "ownerStartToken": "exact",
                            "notifySocketPath": str(remote_path),
                        }
                    )
                payload["generation"] += 1
                coordinator._write_queue(payload)

            coordinator._remote_process_snapshot = {}
            coordinator._remote_process_snapshot_at = coordinator._clock()
            with mock.patch.object(conductor, "process_table_snapshot", return_value=None) as snapshot:
                _payload, _waiter, _position, ordered = coordinator._queue_snapshot()
            self.assertEqual(snapshot.call_count, 1)
            self.assertTrue(
                {"remote-inconclusive-0", "remote-inconclusive-1"}.issubset(
                    {item["waiterID"] for item in ordered}
                )
            )

            with mock.patch.object(conductor, "process_table_snapshot", return_value={}) as snapshot:
                _payload, _waiter, _position, ordered = coordinator._queue_snapshot()
            self.assertEqual(snapshot.call_count, 1)
            self.assertTrue(
                {"remote-inconclusive-0", "remote-inconclusive-1"}.isdisjoint(
                    {item["waiterID"] for item in ordered}
                )
            )
            coordinator._remove_own_waiter()

    def test_fair_remote_process_discovery_is_cached_for_one_second(self) -> None:
        clock_value = [10.0]
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            conductor, "machine_lock_dir", return_value=Path(tmp)
        ), mock.patch.object(conductor, "process_start_token", return_value="owner"):
            coordinator = conductor.FairHeavyAdmission(
                self.make_fair_metadata("local"), {}, clock=lambda: clock_value[0]
            )
            self.addCleanup(coordinator.close)
            remote_path = coordinator.waiters_dir / "remote.sock"
            remote = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            remote.bind(str(remote_path))
            self.addCleanup(remote.close)
            self.addCleanup(lambda: remote_path.unlink(missing_ok=True))
            with coordinator._queue_lock():
                payload = coordinator._load_queue()
                payload["waiters"].append(
                    {
                        "waiterID": "remote",
                        "sequence": 100,
                        "state": "waiting",
                        "ownerPID": 222,
                        "ownerStartToken": "exact",
                        "notifySocketPath": str(remote_path),
                    }
                )
                payload["generation"] += 1
                coordinator._write_queue(payload)

            with mock.patch.object(conductor, "process_table_snapshot", return_value={222: (1, "exact")}) as snapshot:
                coordinator._queue_snapshot()
                clock_value[0] += 0.5
                coordinator._queue_snapshot()
                clock_value[0] += conductor.FAIR_PROCESS_SNAPSHOT_TTL_SECONDS
                coordinator._queue_snapshot()

            self.assertEqual(snapshot.call_count, 2)
            self.assertEqual(coordinator.notify_socket.gettimeout(), conductor.FAIR_HEAVY_RESCAN_SECONDS)
            with coordinator._queue_lock():
                payload = coordinator._load_queue()
                payload["waiters"] = [item for item in payload["waiters"] if item["waiterID"] != "remote"]
                payload["generation"] += 1
                coordinator._write_queue(payload)
            coordinator._remove_own_waiter()

    def test_cached_negative_process_snapshot_is_refreshed_before_pruning_new_waiter(self) -> None:
        clock_value = [20.0]
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            conductor, "machine_lock_dir", return_value=Path(tmp)
        ), mock.patch.object(conductor, "process_start_token", return_value="owner"):
            coordinator = conductor.FairHeavyAdmission(
                self.make_fair_metadata("local"), {}, clock=lambda: clock_value[0]
            )
            self.addCleanup(coordinator.close)
            coordinator._remote_process_snapshot = {}
            coordinator._remote_process_snapshot_at = clock_value[0]
            remote_path = coordinator.waiters_dir / "newborn.sock"
            remote = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            remote.bind(str(remote_path))
            self.addCleanup(remote.close)
            self.addCleanup(lambda: remote_path.unlink(missing_ok=True))
            with coordinator._queue_lock():
                payload = coordinator._load_queue()
                payload["waiters"].append(
                    {
                        "waiterID": "newborn",
                        "sequence": 100,
                        "state": "waiting",
                        "ownerPID": 222,
                        "ownerStartToken": "newborn-start",
                        "notifySocketPath": str(remote_path),
                    }
                )
                payload["generation"] += 1
                coordinator._write_queue(payload)

            with mock.patch.object(
                conductor, "process_table_snapshot", return_value={222: (1, "newborn-start")}
            ) as snapshot:
                coordinator._queue_snapshot()
            with coordinator._queue_lock():
                waiter_ids = {item["waiterID"] for item in coordinator._load_queue()["waiters"]}

            self.assertEqual(snapshot.call_count, 1)
            self.assertIn("newborn", waiter_ids)
            with coordinator._queue_lock():
                payload = coordinator._load_queue()
                payload["waiters"] = [item for item in payload["waiters"] if item["waiterID"] != "newborn"]
                payload["generation"] += 1
                coordinator._write_queue(payload)
            coordinator._remove_own_waiter()

    def test_malformed_fair_waiter_record_quarantines_entire_advisory_queue(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            conductor, "machine_lock_dir", return_value=Path(tmp)
        ), mock.patch.object(conductor, "process_start_token", return_value="owner"):
            first = conductor.FairHeavyAdmission(self.make_fair_metadata("first"), {})
            with first._queue_lock():
                payload = first._load_queue()
                payload["waiters"].append(
                    {
                        "waiterID": "malformed",
                        "sequence": "not-an-integer",
                        "state": "waiting",
                        "ownerPID": 222,
                        "ownerStartToken": "remote",
                        "notifySocketPath": str(first.waiters_dir / "missing.sock"),
                    }
                )
                payload["generation"] += 1
                first._write_queue(payload)
            with self.assertRaisesRegex(conductor.ConductorError, "identity disappeared"):
                first._queue_snapshot()
            first.close()

            second = conductor.FairHeavyAdmission(self.make_fair_metadata("second"), {})
            lease = second.wait()
            self.assertEqual(len(list(Path(tmp).glob("global-heavy-queue.corrupt-*.json"))), 1)
            self.assertIsNotNone(lease)
            assert lease is not None
            lease.release()

    def test_fair_waiter_cancel_removes_only_middle_and_preserves_fifo(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            conductor, "machine_lock_dir", return_value=Path(tmp)
        ), mock.patch.object(conductor, "process_start_token", return_value="owner"):
            first = conductor.FairHeavyAdmission(self.make_fair_metadata("first"), {})
            middle = conductor.FairHeavyAdmission(self.make_fair_metadata("middle"), {})
            last = conductor.FairHeavyAdmission(self.make_fair_metadata("last"), {})
            self.addCleanup(first.close)
            self.addCleanup(middle.close)
            self.addCleanup(last.close)

            self.assertEqual(middle._queue_snapshot()[2], 2)
            self.assertEqual(last._queue_snapshot()[2], 3)
            middle._remove_own_waiter()
            middle.close()

            self.assertEqual(first._queue_snapshot()[2], 1)
            self.assertEqual(last._queue_snapshot()[2], 2)
            first._remove_own_waiter()
            last._remove_own_waiter()

    def test_fair_release_notifies_next_and_kernel_flock_remains_authority(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            conductor, "machine_lock_dir", return_value=Path(tmp)
        ), mock.patch.object(conductor, "process_start_token", return_value="owner"):
            external = (Path(tmp) / "global-heavy-0.lock").open("a+", encoding="utf-8")
            fcntl.flock(external.fileno(), fcntl.LOCK_EX)
            first = conductor.FairHeavyAdmission(self.make_fair_metadata("first"), {})
            self.addCleanup(first.close)
            attempted = threading.Event()
            acquired: list[conductor.FairHeavyLease | None] = []

            def wait_for_slot() -> None:
                acquired.append(first.wait(update=lambda _position, _earlier: attempted.set()))

            waiter = threading.Thread(target=wait_for_slot)
            waiter.start()
            self.assertTrue(attempted.wait(1.0))
            self.assertEqual(acquired, [], "queue metadata granted admission without kernel flock")
            fcntl.flock(external.fileno(), fcntl.LOCK_UN)
            external.close()
            conductor.FairHeavyAdmission._notify([str(first.notify_path)])
            waiter.join(timeout=1.0)

            self.assertFalse(waiter.is_alive())
            lease = acquired[0]
            self.assertIsNotNone(lease)
            assert lease is not None
            lease.release()

    def test_fair_release_hands_eligibility_to_next_waiter(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            conductor, "machine_lock_dir", return_value=Path(tmp)
        ), mock.patch.object(conductor, "process_start_token", return_value="owner"):
            first = conductor.FairHeavyAdmission(self.make_fair_metadata("first"), {})
            first_lease = first.wait()
            self.assertIsNotNone(first_lease)
            second = conductor.FairHeavyAdmission(self.make_fair_metadata("second"), {})
            waiting = threading.Event()
            acquired: list[conductor.FairHeavyLease | None] = []

            def acquire_second() -> None:
                acquired.append(second.wait(update=lambda position, _earlier: waiting.set() if position == 2 else None))

            thread = threading.Thread(target=acquire_second)
            thread.start()
            self.assertTrue(waiting.wait(1.0))
            self.assertEqual(acquired, [])
            assert first_lease is not None
            first_lease.release()
            thread.join(timeout=1.0)

            self.assertFalse(thread.is_alive())
            self.assertIsNotNone(acquired[0])
            assert acquired[0] is not None
            acquired[0].release()

    def test_fair_pruning_removes_reused_pid_waiter_but_retains_exact_remote_owner(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            conductor, "machine_lock_dir", return_value=Path(tmp)
        ), mock.patch.object(conductor, "process_start_token", return_value="owner"):
            coordinator = conductor.FairHeavyAdmission(self.make_fair_metadata("local"), {})
            self.addCleanup(coordinator.close)
            exact_notify_path = coordinator.waiters_dir / "remote-exact.sock"
            reused_notify_path = coordinator.waiters_dir / "remote-reused.sock"
            exact_notify = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            reused_notify = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            exact_notify.bind(str(exact_notify_path))
            reused_notify.bind(str(reused_notify_path))
            self.addCleanup(exact_notify.close)
            self.addCleanup(reused_notify.close)
            self.addCleanup(lambda: exact_notify_path.unlink(missing_ok=True))
            self.addCleanup(lambda: reused_notify_path.unlink(missing_ok=True))
            with coordinator._queue_lock():
                payload = coordinator._load_queue()
                payload["waiters"].extend(
                    [
                        {
                            "waiterID": "remote-exact",
                            "sequence": 100,
                            "state": "waiting",
                            "ownerPID": 222,
                            "ownerStartToken": "exact",
                            "notifySocketPath": str(exact_notify_path),
                        },
                        {
                            "waiterID": "remote-reused",
                            "sequence": 101,
                            "state": "waiting",
                            "ownerPID": 333,
                            "ownerStartToken": "old",
                            "notifySocketPath": str(reused_notify_path),
                        },
                    ]
                )
                coordinator._write_queue(payload)

            with mock.patch.object(
                conductor,
                "process_table_snapshot",
                return_value={222: (1, "exact"), 333: (1, "new")},
            ):
                coordinator._queue_snapshot()
            with coordinator._queue_lock():
                waiter_ids = {item["waiterID"] for item in coordinator._load_queue()["waiters"]}

            self.assertIn(coordinator.waiter_id, waiter_ids)
            self.assertIn("remote-exact", waiter_ids)
            self.assertNotIn("remote-reused", waiter_ids)
            with coordinator._queue_lock():
                payload = coordinator._load_queue()
                payload["waiters"] = [item for item in payload["waiters"] if item["waiterID"] != "remote-exact"]
                payload["generation"] += 1
                coordinator._write_queue(payload)
            coordinator._remove_own_waiter()

    def test_two_fair_slots_admit_first_two_and_hold_third_in_fifo(self) -> None:
        env = {"REPOPROMPT_DEV_HEAVY_SLOTS": "2"}
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            conductor, "machine_lock_dir", return_value=Path(tmp)
        ), mock.patch.object(conductor, "process_start_token", return_value="owner"):
            first = conductor.FairHeavyAdmission(self.make_fair_metadata("first"), env)
            second = conductor.FairHeavyAdmission(self.make_fair_metadata("second"), env)
            third = conductor.FairHeavyAdmission(self.make_fair_metadata("third"), env)
            first_lease = first.wait()
            second_lease = second.wait()

            self.assertIsNotNone(first_lease)
            self.assertIsNotNone(second_lease)
            assert first_lease is not None and second_lease is not None
            self.assertNotEqual(first_lease.lock_path, second_lease.lock_path)
            self.assertEqual(third._queue_snapshot()[2], 3)
            third._remove_own_waiter()
            third.close()
            first_lease.release()
            second_lease.release()

    def test_unlaned_capacity_releases_after_launch_failure(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(state, "unlaned-failure", "guardrails", {}, [], job_state="running")
        state.jobs[job.ticket] = job
        state.active_unlaned.add(job.ticket)

        with mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False), mock.patch.object(
            conductor.subprocess, "Popen", side_effect=OSError("fixture launch failure")
        ), mock.patch.object(state, "_schedule_locked"), mock.patch.object(state, "_refresh_output_summary"):
            state._run_job(job.ticket)

        self.assertEqual(job.state, "failed")
        self.assertNotIn(job.ticket, state.active_unlaned)

    def test_unlaned_capacity_bounds_resource_jobs_but_exempts_cheap_status_tool(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        tickets = [f"unlaned-{index}" for index in range(conductor.MAX_UNLANED_JOBS + 1)]
        for ticket in tickets:
            state.jobs[ticket] = self.make_job(state, ticket, "guardrails", {}, [], job_state="queued")
        exempt = self.make_job(state, "format-tools-status", "format-tools-status", {}, [], job_state="queued")
        state.jobs[exempt.ticket] = exempt
        state.queue = tickets + [exempt.ticket]
        started: list[str] = []

        class FakeThread:
            def __init__(self, target, args, **_kwargs):
                self.target = target
                self.args = args

            def start(self) -> None:
                started.append(self.args[0])

            def join(self, timeout=None) -> None:
                del timeout

        with mock.patch.object(conductor.threading, "Thread", FakeThread):
            with state.condition:
                state._schedule_locked()
                payload = state.status_payload()

        self.assertEqual(set(started), set(tickets[: conductor.MAX_UNLANED_JOBS] + [exempt.ticket]))
        self.assertEqual(state.jobs[tickets[-1]].state, "queued")
        self.assertEqual(state.jobs[exempt.ticket].state, "running")
        blocker = state._job_payload_locked(state.jobs[tickets[-1]])["blockedBy"][-1]
        self.assertEqual(blocker["kind"], "unlanedCapacity")
        self.assertEqual(blocker["activeCount"], conductor.MAX_UNLANED_JOBS)
        self.assertEqual(payload["unlanedCapacity"]["activeCount"], conductor.MAX_UNLANED_JOBS)


class LifecycleQueueTests(LifecycleTestCase):
    def test_protocol_version_bump_replaces_older_daemons(self) -> None:
        self.assertEqual(conductor.PROTOCOL_VERSION, 16)

    def test_server_listen_backlog_matches_bounded_handler_capacity(self) -> None:
        self.assertEqual(conductor.ThreadedUnixServer.request_queue_size, conductor.MAX_ACTIVE_REQUEST_HANDLERS)

    def test_explicit_wait_timeout_survives_repeated_server_clamps(self) -> None:
        clock_value = [0.0]
        wait_durations: list[float] = []

        def fake_request(_paths: conductor.Paths, request: dict, timeout: float = 1.0) -> dict:
            del timeout
            self.assertEqual(request["type"], "job-wait")
            duration = float(request["timeout"])
            wait_durations.append(duration)
            clock_value[0] += duration
            state = "completed" if len(wait_durations) == 3 else "running"
            return {"ticket": "ticket", "state": state, "operation": "build", "logTail": []}

        with mock.patch.object(conductor, "request_daemon", side_effect=fake_request):
            payload = conductor.wait_for_terminal(
                mock.Mock(),
                "ticket",
                None,
                json_mode=True,
                user_timeout=5.0,
                clock=lambda: clock_value[0],
                poll_wait=lambda _seconds: None,
            )

        self.assertEqual(payload["state"], "completed")
        self.assertEqual(sum(wait_durations), 3.0)
        self.assertTrue(all(duration <= conductor.MAX_SERVER_WAIT_SECONDS for duration in wait_durations))

    def test_explicit_wait_timeout_expires_only_at_client_deadline(self) -> None:
        clock_value = [0.0]
        wait_durations: list[float] = []

        def fake_request(_paths: conductor.Paths, request: dict, timeout: float = 1.0) -> dict:
            del timeout
            duration = float(request["timeout"])
            wait_durations.append(duration)
            clock_value[0] += duration
            return {"ticket": "ticket", "state": "running", "operation": "build", "logTail": []}

        with mock.patch.object(conductor, "request_daemon", side_effect=fake_request):
            payload = conductor.wait_for_terminal(
                mock.Mock(),
                "ticket",
                None,
                json_mode=True,
                user_timeout=5.0,
                clock=lambda: clock_value[0],
                poll_wait=lambda _seconds: None,
            )

        self.assertTrue(payload["waitTimedOut"])
        self.assertEqual(sum(wait_durations), 5.0)
        self.assertGreater(len(wait_durations), 1)

    def test_wait_rejects_terminal_response_observed_after_client_deadline(self) -> None:
        clock_value = [0.0]
        transport_timeouts: list[float] = []

        def fake_request(_paths: conductor.Paths, _request: dict, timeout: float = 1.0) -> dict:
            transport_timeouts.append(timeout)
            clock_value[0] = 6.0
            return {"ticket": "ticket", "state": "completed", "operation": "build", "logTail": []}

        with mock.patch.object(conductor, "request_daemon", side_effect=fake_request):
            payload = conductor.wait_for_terminal(
                mock.Mock(),
                "ticket",
                None,
                json_mode=True,
                user_timeout=5.0,
                clock=lambda: clock_value[0],
                poll_wait=lambda _seconds: None,
            )

        self.assertTrue(payload["waitTimedOut"])
        self.assertLessEqual(transport_timeouts[0], 5.0)

    def test_zero_and_near_deadline_waits_keep_meaningful_rpc_contact_window(self) -> None:
        for user_timeout in (0.0, 0.02):
            with self.subTest(user_timeout=user_timeout):
                clock_value = [100.0]
                requests: list[dict] = []
                transport_timeouts: list[float] = []

                def fake_request(_paths: conductor.Paths, request: dict, timeout: float = 1.0) -> dict:
                    requests.append(dict(request))
                    transport_timeouts.append(timeout)
                    clock_value[0] += max(0.001, user_timeout + 0.001)
                    return {"ticket": "ticket", "state": "running", "operation": "build", "logTail": []}

                with mock.patch.object(conductor, "request_daemon", side_effect=fake_request):
                    payload = conductor.wait_for_terminal(
                        mock.Mock(),
                        "ticket",
                        None,
                        json_mode=True,
                        user_timeout=user_timeout,
                        clock=lambda: clock_value[0],
                        poll_wait=lambda _seconds: None,
                    )

                self.assertTrue(payload["waitTimedOut"])
                self.assertEqual(len(requests), 1)
                self.assertAlmostEqual(requests[0]["timeout"], user_timeout)
                self.assertEqual(transport_timeouts, [conductor.WAIT_RPC_CONTACT_SECONDS])

    def test_wait_capacity_errors_and_handler_drops_degrade_to_bounded_status_polling(self) -> None:
        for initial_error in (
            "server wait-handler capacity exhausted; poll job status and retry",
            "daemon closed connection without a response",
        ):
            with self.subTest(initial_error=initial_error):
                requests: list[str] = []
                pauses: list[float] = []

                def fake_request(_paths: conductor.Paths, request: dict, timeout: float = 1.0) -> dict:
                    del timeout
                    requests.append(request["type"])
                    if len(requests) == 1:
                        raise conductor.ConductorError(initial_error)
                    state = "completed" if requests.count("job-status") == 2 else "running"
                    return {"ticket": "ticket", "state": state, "operation": "build", "logTail": []}

                with mock.patch.object(conductor, "request_daemon", side_effect=fake_request):
                    payload = conductor.wait_for_terminal(
                        mock.Mock(),
                        "ticket",
                        None,
                        json_mode=True,
                        clock=lambda: 0.0,
                        poll_wait=pauses.append,
                    )

                self.assertEqual(payload["state"], "completed")
                self.assertEqual(requests, ["job-wait", "job-status", "job-status"])
                self.assertEqual(pauses, [conductor.WAIT_STATUS_POLL_SECONDS])

    def test_degraded_wait_tolerates_dropped_status_poll_without_spinning(self) -> None:
        requests: list[str] = []
        pauses: list[float] = []

        def fake_request(_paths: conductor.Paths, request: dict, timeout: float = 1.0) -> dict:
            del timeout
            requests.append(request["type"])
            if len(requests) == 1:
                raise conductor.ConductorError("server wait-handler capacity exhausted; poll job status and retry")
            if len(requests) == 2:
                raise conductor.ConductorError("daemon closed connection without a response")
            return {"ticket": "ticket", "state": "completed", "operation": "build", "logTail": []}

        with mock.patch.object(conductor, "request_daemon", side_effect=fake_request):
            payload = conductor.wait_for_terminal(
                mock.Mock(),
                "ticket",
                None,
                json_mode=True,
                clock=lambda: 0.0,
                poll_wait=pauses.append,
            )

        self.assertEqual(payload["state"], "completed")
        self.assertEqual(requests, ["job-wait", "job-status", "job-status"])
        self.assertEqual(pauses, [conductor.WAIT_STATUS_POLL_SECONDS])

    def test_identity_verified_wait_timeout_degrades_until_terminal_summary_is_ready(self) -> None:
        requests: list[str] = []
        pauses: list[float] = []
        contact_error = conductor.DaemonContactError(
            "could not contact daemon: timed out",
            {
                "running": True,
                "health": {"state": "unresponsive", "processIdentityVerified": True},
            },
        )

        def fake_request(_paths: conductor.Paths, request: dict, timeout: float = 1.0) -> dict:
            del timeout
            requests.append(request["type"])
            if len(requests) <= 2:
                raise contact_error
            return {"ticket": "ticket", "state": "completed", "operation": "build", "logTail": []}

        with mock.patch.object(conductor, "request_daemon", side_effect=fake_request):
            payload = conductor.wait_for_terminal(
                mock.Mock(),
                "ticket",
                None,
                json_mode=True,
                clock=lambda: 0.0,
                poll_wait=pauses.append,
            )

        self.assertEqual(payload["state"], "completed")
        self.assertEqual(requests, ["job-wait", "job-status", "job-status"])
        self.assertEqual(pauses, [conductor.WAIT_STATUS_POLL_SECONDS])

    def test_identity_verified_wait_timeout_retries_are_bounded(self) -> None:
        requests: list[str] = []
        pauses: list[float] = []
        contact_error = conductor.DaemonContactError(
            "could not contact daemon: timed out",
            {
                "running": True,
                "health": {"state": "unresponsive", "processIdentityVerified": True},
            },
        )

        def fake_request(_paths: conductor.Paths, request: dict, timeout: float = 1.0) -> dict:
            del timeout
            requests.append(request["type"])
            raise contact_error

        with mock.patch.object(conductor, "request_daemon", side_effect=fake_request):
            with self.assertRaises(conductor.DaemonContactError):
                conductor.wait_for_terminal(
                    mock.Mock(),
                    "ticket",
                    None,
                    json_mode=True,
                    clock=lambda: 0.0,
                    poll_wait=pauses.append,
                )

        self.assertEqual(len(requests), conductor.MAX_CONSECUTIVE_WAIT_CONTACT_FAILURES + 1)
        self.assertEqual(requests[0], "job-wait")
        self.assertTrue(all(request == "job-status" for request in requests[1:]))
        self.assertEqual(
            pauses,
            [conductor.WAIT_STATUS_POLL_SECONDS] * (conductor.MAX_CONSECUTIVE_WAIT_CONTACT_FAILURES - 1),
        )

    def test_ambiguous_wait_contact_failure_does_not_poll(self) -> None:
        requests: list[str] = []
        contact_error = conductor.DaemonContactError(
            "could not contact daemon: timed out",
            {
                "running": None,
                "health": {"state": "ambiguous", "processIdentityVerified": False},
            },
        )

        def fake_request(_paths: conductor.Paths, request: dict, timeout: float = 1.0) -> dict:
            del timeout
            requests.append(request["type"])
            raise contact_error

        with mock.patch.object(conductor, "request_daemon", side_effect=fake_request):
            with self.assertRaises(conductor.DaemonContactError):
                conductor.wait_for_terminal(
                    mock.Mock(),
                    "ticket",
                    None,
                    json_mode=True,
                    clock=lambda: 0.0,
                    poll_wait=lambda _seconds: None,
                )

        self.assertEqual(requests, ["job-wait"])

    def test_ensure_daemon_stops_and_replaces_idle_protocol_3_daemon(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        fake_proc = mock.Mock()
        fake_proc.poll.return_value = None
        old_payload = {
            "protocolVersion": 3,
            "runningJobs": [],
            "queuedJobs": [],
        }
        new_payload = {"protocolVersion": conductor.PROTOCOL_VERSION}
        requests: list[dict] = []

        def fake_request(_paths: conductor.Paths, message: dict, timeout: float = 1.0) -> dict:
            requests.append(message)
            if message["type"] == "status" and len(requests) == 1:
                return old_payload
            if message["type"] == "stop":
                return {}
            if message["type"] == "status" and len(requests) == 3:
                raise conductor.ConductorError("old daemon is stopped")
            if message["type"] == "status":
                return new_payload
            raise AssertionError(f"unexpected daemon request: {message}")

        with mock.patch.object(conductor, "request_daemon", side_effect=fake_request), mock.patch.object(
            conductor, "wait_until_stopped", return_value=True
        ) as wait, mock.patch.object(conductor.subprocess, "Popen", return_value=fake_proc) as popen:
            payload = conductor.ensure_daemon(state.paths)

        self.assertEqual(payload, new_payload)
        self.assertEqual(requests[0], {"type": "status"})
        self.assertEqual(requests[1], {"type": "stop", "force": False})
        wait.assert_called_once_with(state.paths, timeout=conductor.TERMINATE_GRACE_SECONDS + 5.0)
        self.assertEqual(popen.call_args.kwargs["stdin"], subprocess.DEVNULL)

    def test_ensure_daemon_refuses_mismatched_replacement_when_work_appears_before_stop(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        requests: list[dict] = []

        def fake_request(_paths: conductor.Paths, message: dict, timeout: float = 1.0) -> dict:
            requests.append(message)
            if message["type"] == "status":
                return {
                    "protocolVersion": 3,
                    "runningJobs": [],
                    "queuedJobs": [],
                }
            if message["type"] == "stop":
                raise conductor.ConductorError("daemon has active or queued jobs")
            raise AssertionError(f"unexpected daemon request: {message}")

        with mock.patch.object(conductor, "request_daemon", side_effect=fake_request), mock.patch.object(
            conductor, "wait_until_stopped"
        ) as wait, mock.patch.object(conductor.subprocess, "Popen") as popen:
            with self.assertRaisesRegex(conductor.ConductorError, "jobs may have become active"):
                conductor.ensure_daemon(state.paths)

        self.assertEqual(
            requests,
            [
                {"type": "status"},
                {"type": "stop", "force": False},
            ],
        )
        wait.assert_not_called()
        popen.assert_not_called()

    def test_ensure_daemon_raises_for_locked_protocol_mismatch_with_active_jobs(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        requests: list[dict] = []

        def fake_request(_paths: conductor.Paths, message: dict, timeout: float = 1.0) -> dict:
            requests.append(message)
            if len(requests) == 1:
                raise conductor.ConductorError("down before start lock")
            return {
                "protocolVersion": 3,
                "runningJobs": [{"ticket": "active"}],
                "queuedJobs": [],
            }

        with mock.patch.object(conductor, "request_daemon", side_effect=fake_request), mock.patch.object(
            conductor, "wait_until_stopped"
        ) as wait, mock.patch.object(conductor.subprocess, "Popen") as popen:
            with self.assertRaisesRegex(conductor.ConductorError, "protocol mismatch"):
                conductor.ensure_daemon(state.paths)

        self.assertEqual(requests, [{"type": "status"}, {"type": "status"}])
        wait.assert_not_called()
        popen.assert_not_called()

    def test_app_relaunch_cli_requires_delimiter_and_forwards_arguments(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        with mock.patch.object(conductor, "enqueue_and_maybe_wait", return_value=0) as enqueue:
            code = conductor.handle_real_operation(state.paths, "app", ["relaunch", "--", "--demo"])

        self.assertEqual(code, 0)
        self.assertEqual(enqueue.call_args.args[1], "app")
        self.assertEqual(enqueue.call_args.args[2], {"subcommand": "relaunch", "appArgs": ["--demo"]})
        with self.assertRaises(conductor.ConductorError):
            conductor.handle_real_operation(state.paths, "app", ["relaunch", "--demo"])
        with mock.patch.object(conductor, "enqueue_and_maybe_wait", return_value=0) as enqueue_launch:
            code = conductor.handle_real_operation(state.paths, "app", ["launch-existing", "--", "--demo"])
        self.assertEqual(code, 0)
        self.assertEqual(enqueue_launch.call_args.args[2], {"subcommand": "launch-existing", "appArgs": ["--demo"]})

    def test_app_relaunch_delegates_split_internal_runner_with_build_live_lanes_and_timeout(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = conductor.OperationRegistry(Path(tmp))
            argv, lanes, _cwd, _env, timeout = registry.prepare(
                {"operation": "app", "args": {"subcommand": "relaunch", "appArgs": ["--demo"]}}
            )
            launch_existing_argv, launch_existing_lanes, _cwd, _env, _timeout = registry.prepare(
                {"operation": "app", "args": {"subcommand": "launch-existing", "appArgs": ["--demo"]}}
            )

        self.assertIn("__operation_runner", argv)
        self.assertIn("debug_app_build_then_launch", argv[-1])
        self.assertEqual(lanes, ["build", "liveApp"])
        self.assertEqual(timeout, conductor.MEDIUM_TIMEOUT_SECONDS)
        self.assertIn("app_launch_existing", launch_existing_argv[-1])
        self.assertEqual(launch_existing_lanes, ["liveApp"])
        self.assertEqual(conductor.operation_display_name("app", {"subcommand": "relaunch"}), "app relaunch")

    def test_building_live_operations_share_build_lane_without_expanding_nonbuilding_lifecycle(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = conductor.OperationRegistry(Path(tmp))
            mutators = (
                {"operation": "run", "args": {}},
                {"operation": "app", "args": {"subcommand": "relaunch"}},
                {"operation": "smoke", "args": {"launch": True}},
            )
            nonmutators = (
                {"operation": "app", "args": {"subcommand": "stop"}},
                {"operation": "app", "args": {"subcommand": "launch-existing"}},
                {"operation": "smoke", "args": {"packagedApp": "/tmp/RepoPrompt CE.app"}},
            )
            mutator_lanes = [registry.prepare(request)[1] for request in mutators]
            nonmutator_lanes = [registry.prepare(request)[1] for request in nonmutators]

        self.assertTrue(all("build" in lanes for lanes in mutator_lanes))
        self.assertTrue(all("build" not in lanes for lanes in nonmutator_lanes))

    def test_guardrails_delegates_aggregator_without_lanes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo_root = Path(tmp)
            registry = conductor.OperationRegistry(repo_root)
            argv, lanes, cwd, _env, _timeout = registry.prepare({"operation": "guardrails", "args": {}})

        self.assertEqual(Path(argv[0]).name, "guardrails.sh")
        self.assertEqual(Path(argv[0]).parent.name, "Scripts")
        self.assertEqual(lanes, [])
        self.assertEqual(cwd, repo_root)

    def test_codex_schema_check_delegates_bounded_gate_without_lanes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo_root = Path(tmp)
            registry = conductor.OperationRegistry(repo_root)
            argv, lanes, cwd, _env, timeout = registry.prepare(
                {"operation": "codex-schema-check", "args": {}}
            )

        self.assertEqual(Path(argv[0]).name, Path(sys.executable).name)
        self.assertEqual(Path(argv[1]).name, "check_codex_app_server_schema.py")
        self.assertEqual(lanes, [])
        self.assertEqual(cwd, repo_root)
        self.assertEqual(timeout, conductor.SHORT_TIMEOUT_SECONDS)

    def test_release_artifact_delegates_release_script_with_release_lanes_and_extended_timeout(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        with mock.patch.object(conductor, "enqueue_and_maybe_wait", return_value=0) as enqueue:
            code = conductor.handle_real_operation(state.paths, "release", ["artifact"])

        registry = conductor.OperationRegistry(state.paths.repo_root)
        argv, lanes, _cwd, _env, timeout = registry.prepare({"operation": "release", "args": {"subcommand": "artifact"}})

        self.assertEqual(code, 0)
        self.assertEqual(enqueue.call_args.args[2], {"subcommand": "artifact"})
        self.assertEqual(Path(argv[0]).name, "release.sh")
        self.assertEqual(argv[1], "artifact")
        self.assertEqual(lanes, ["build", "debugArtifact", "release"])
        self.assertEqual(timeout, conductor.RELEASE_ARTIFACT_TIMEOUT_SECONDS)

    def test_release_artifact_timeout_is_distinct_from_other_release_packaging(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = conductor.OperationRegistry(Path(tmp))
            _argv, _lanes, _cwd, _env, artifact_timeout = registry.prepare(
                {"operation": "release", "args": {"subcommand": "artifact"}}
            )
            normal_release_requests = {
                "package release": {"operation": "package", "args": {"config": "release"}},
                "release package": {"operation": "release", "args": {"subcommand": "package"}},
                "release local-install": {"operation": "release", "args": {"subcommand": "local-install"}},
            }
            normal_timeouts = {
                label: registry.prepare(request)[4]
                for label, request in normal_release_requests.items()
            }

        self.assertEqual(conductor.RELEASE_ARTIFACT_TIMEOUT_SECONDS, 4 * 60 * 60)
        self.assertEqual(artifact_timeout, conductor.RELEASE_ARTIFACT_TIMEOUT_SECONDS)
        self.assertEqual(conductor.RELEASE_TIMEOUT_SECONDS, 2 * 60 * 60)
        for label, timeout in normal_timeouts.items():
            with self.subTest(operation=label):
                self.assertEqual(timeout, conductor.RELEASE_TIMEOUT_SECONDS)

    def test_packaged_smoke_uses_only_live_app_lane(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = conductor.OperationRegistry(Path(tmp))
            argv, lanes, _cwd, _env, _timeout = registry.prepare(
                {"operation": "smoke", "args": {"packagedApp": "/tmp/RepoPrompt CE.app"}}
            )

        self.assertEqual(lanes, ["liveApp"])
        self.assertTrue(Path(argv[0]).name.startswith("python3"))
        self.assertIn('"kind":"smoke"', argv[-1].replace(" ", ""))

    def test_diagnostics_build_cache_delegates_read_only_without_lanes(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        with mock.patch.object(conductor, "enqueue_and_maybe_wait", return_value=0) as enqueue:
            code = conductor.handle_real_operation(state.paths, "diagnostics", ["build-cache", "--limit", "3"])

        registry = conductor.OperationRegistry(state.paths.repo_root)
        argv, lanes, cwd, _env, timeout = registry.prepare(
            {"operation": "diagnostics", "args": {"subcommand": "build-cache", "limit": 3}}
        )

        self.assertEqual(code, 0)
        self.assertEqual(enqueue.call_args.args[1], "diagnostics")
        self.assertEqual(enqueue.call_args.args[2], {"subcommand": "build-cache", "limit": 3})
        self.assertEqual(lanes, [])
        self.assertEqual(cwd, state.paths.repo_root)
        self.assertEqual(timeout, conductor.SHORT_TIMEOUT_SECONDS)
        self.assertTrue(Path(argv[0]).name.startswith("python3"))
        self.assertIn('"kind":"diagnostics_build_cache"', argv[-1].replace(" ", ""))

    def test_diagnostics_build_cache_reports_managed_worktree_build_sizes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            container = Path(tmp) / ".repoprompt-worktrees" / "repoprompt-ce-upstream"
            repo_root = container / "wt-a"
            sibling = container / "wt-b"
            (repo_root / ".build").mkdir(parents=True)
            (sibling / ".build").mkdir(parents=True)
            (repo_root / ".build" / "a.bin").write_bytes(b"a" * 1024)
            (sibling / ".build" / "b.bin").write_bytes(b"b" * 2 * 1024 * 1024)

            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                code = conductor.operation_diagnostics_build_cache(repo_root, {"limit": 1})

        text = output.getvalue()
        self.assertEqual(code, 0)
        self.assertIn("Build cache diagnostics", text)
        self.assertIn("Current .build:", text)
        self.assertIn("Worktree .build total:", text)
        self.assertIn("across 2 build directories", text)
        self.assertIn("Top .build directories:", text)
        self.assertIn("wt-b", text)

    def test_release_local_install_delegates_installer_with_release_lanes_and_confirmation(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = conductor.OperationRegistry(Path(tmp))
            argv, lanes, _cwd, env, timeout = registry.prepare(
                {
                    "operation": "release",
                    "args": {"subcommand": "local-install"},
                    "env": {
                        "CONFIRM_LOCAL_PRODUCTION_INSTALL": "1",
                        "LOCAL_SELF_SIGNED_CERTIFICATE_NAME": "divergent override",
                    },
                }
            )

        self.assertEqual(Path(argv[0]).name, "install_local_production.sh")
        self.assertEqual(lanes, ["build", "debugArtifact", "release"])
        self.assertEqual(env["CONFIRM_LOCAL_PRODUCTION_INSTALL"], "1")
        self.assertNotIn("LOCAL_SELF_SIGNED_CERTIFICATE_NAME", env)
        self.assertEqual(timeout, conductor.RELEASE_TIMEOUT_SECONDS)

    def test_ensure_daemon_starts_daemon_with_devnull_stdin(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        fake_proc = mock.Mock()
        fake_proc.poll.return_value = None
        down_before_start = conductor.ConductorError("down before start")
        down_before_spawn = conductor.ConductorError("down before spawn")

        with mock.patch.object(
            conductor,
            "request_daemon",
            side_effect=[down_before_start, down_before_spawn, {"protocolVersion": conductor.PROTOCOL_VERSION}],
        ), mock.patch.object(conductor.subprocess, "Popen", return_value=fake_proc) as popen:
            payload = conductor.ensure_daemon(state.paths)

        self.assertEqual(payload["protocolVersion"], conductor.PROTOCOL_VERSION)
        self.assertEqual(popen.call_args.kwargs["stdin"], subprocess.DEVNULL)
        self.assertEqual(popen.call_args.kwargs["stdout"].name, str(state.paths.daemon_log_path))
        self.assertEqual(popen.call_args.kwargs["stderr"], subprocess.STDOUT)

    def test_daemon_run_job_launches_process_with_devnull_stdin(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(state, "job-devnull", "build", {}, ["build"], job_state="running")
        state.jobs[job.ticket] = job
        fake_process = mock.Mock()
        fake_process.pid = os.getpid()
        fake_process.wait.return_value = 0

        with mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False), mock.patch.object(
            conductor.subprocess, "Popen", return_value=fake_process
        ) as popen, mock.patch.object(
            conductor, "process_table_snapshot", return_value={os.getpid(): (os.getppid(), "fixture-start")}
        ), mock.patch.object(state, "_schedule_locked"), mock.patch.object(state, "_refresh_output_summary"):
            state._run_job(job.ticket)

        job_launch = next(call for call in popen.call_args_list if call.kwargs.get("stdin") == subprocess.DEVNULL)
        self.assertIsInstance(job_launch.kwargs["stdout"], int)
        self.assertEqual(job_launch.kwargs["stderr"], subprocess.STDOUT)
        self.assertEqual(state.jobs[job.ticket].state, "completed")

    def test_output_pump_registration_failure_cleans_process_group_when_snapshot_is_inconclusive(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(state, "registration-failure", "fixture", {}, [], job_state="running")
        state.jobs[job.ticket] = job
        real_popen = subprocess.Popen
        spawned: list[subprocess.Popen[bytes]] = []
        descendant_pids: list[int] = []
        ready_path = state.paths.state_dir / "registration-descendant.pid"
        fixture_script = """
import os
import sys
import time

child_pid = os.fork()
if child_pid == 0:
    time.sleep(60)
    os._exit(0)
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(str(child_pid))
    handle.flush()
time.sleep(60)
"""

        def spawn(*args: object, **kwargs: object) -> subprocess.Popen[bytes]:
            process = real_popen(*args, **kwargs)
            argv = args[0] if args else kwargs.get("args")
            if isinstance(argv, (list, tuple)) and fixture_script in argv:
                spawned.append(process)
            return process

        def fail_registration(*_args: object, **_kwargs: object) -> None:
            deadline = time.monotonic() + conductor.LOG_FLUSH_WAIT_SECONDS
            ready = threading.Event()
            while not ready_path.exists() and time.monotonic() < deadline:
                ready.wait(0.01)
            self.assertTrue(ready_path.exists(), "fixture descendant did not publish readiness")
            descendant_pids.append(int(ready_path.read_text(encoding="utf-8")))
            raise conductor.ConductorError("fixture registration failure")

        def cleanup_spawned() -> None:
            for process in spawned:
                if process.poll() is None:
                    process.terminate()
                    with contextlib.suppress(subprocess.TimeoutExpired):
                        process.wait(timeout=1.0)
            for pid in descendant_pids:
                if pid_is_executing(pid):
                    with contextlib.suppress(ProcessLookupError, PermissionError, OSError):
                        os.kill(pid, signal.SIGKILL)

        self.addCleanup(cleanup_spawned)
        prepared = (
            [sys.executable, "-c", fixture_script, str(ready_path)],
            [],
            state.paths.repo_root,
            dict(os.environ),
            60.0,
        )
        with mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False), mock.patch.object(
            state.registry, "prepare", return_value=prepared
        ), mock.patch.object(conductor.subprocess, "Popen", side_effect=spawn), mock.patch.object(
            state._output_pump, "register", side_effect=fail_registration
        ), mock.patch.object(conductor, "process_table_snapshot", return_value=None), mock.patch.object(
            state, "_schedule_locked"
        ), mock.patch.object(
            state, "_refresh_output_summary"
        ):
            state._run_job(job.ticket)

        self.assertEqual(len(spawned), 1)
        self.assertEqual(len(descendant_pids), 1)
        self.assertIsNotNone(job.process_start)
        self.assertTrue(job.process_group_identity_confirmed)
        self.assertEqual(job.state, "failed")
        self.assertIn("fixture registration failure", job.result_summary or "")
        self.assertIsNotNone(spawned[0].poll(), "registration failure leaked its root child")
        self.assertFalse(
            pid_is_executing(descendant_pids[0]),
            "registration failure leaked a descendant while process discovery was inconclusive",
        )

    def test_daemon_timeout_preserves_timeout_result_when_root_resists_sigkill(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(state, "job-timeout-sigkill", "build", {}, ["build"], job_state="running")
        state.jobs[job.ticket] = job
        fake_stdout = mock.Mock()
        fake_stdout.readline.side_effect = [b""]
        fake_process = mock.Mock()
        fake_process.pid = os.getpid()
        fake_process.stdout = fake_stdout
        fake_process.wait.side_effect = [
            subprocess.TimeoutExpired(["fixture"], 1.0),
            subprocess.TimeoutExpired(["fixture"], conductor.TERMINATE_GRACE_SECONDS),
            subprocess.TimeoutExpired(["fixture"], conductor.KILL_GRACE_SECONDS),
        ]

        with mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False), mock.patch.object(
            conductor.subprocess, "Popen", return_value=fake_process
        ), mock.patch.object(
            conductor, "process_table_snapshot", return_value={os.getpid(): (os.getppid(), "fixture-start")}
        ), mock.patch.object(state, "_terminate_process_group_locked"), mock.patch.object(
            state, "_kill_process_group_locked"
        ), mock.patch.object(
            state, "_wait_for_process_tree_exit_locked", side_effect=[False, True]
        ), mock.patch.object(
            state, "_schedule_locked"
        ), mock.patch.object(
            state, "_refresh_output_summary"
        ):
            state._run_job(job.ticket)

        self.assertEqual(job.state, "failed")
        self.assertEqual(job.exit_code, 124)
        self.assertTrue(job.timed_out)
        self.assertIn("job processes remained alive after SIGKILL escalation", job.error or "")
        self.assertNotIn("daemon runner error", job.result_summary or "")

    def test_termination_snapshots_verified_tree_before_root_group_signal(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(state, "ordered-signal", "fixture", {}, ["build"], job_state="running")
        verified = {101: (1, "root"), 202: (101, "child")}
        depths = {101: 0, 202: 1}
        order: list[str] = []

        with mock.patch.object(
            state,
            "_refresh_process_tree_locked",
            side_effect=lambda _job: (order.append("discover") or (verified, depths, True)),
        ), mock.patch.object(
            state,
            "_signal_process_group_id_locked",
            side_effect=lambda _job, _signal: (order.append("group") or True),
        ), mock.patch.object(
            state,
            "_signal_verified_processes_locked",
            side_effect=lambda _job, _signal, actual, actual_depths: (
                order.append("tree")
                or self.assertEqual(actual, verified)
                or self.assertEqual(actual_depths, depths)
                or 2
            ),
        ):
            with state.condition:
                state._terminate_process_group_locked(job, "fixture")

        self.assertEqual(order, ["discover", "group", "tree"])

    def test_process_group_signal_requires_verified_job_identity(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(state, "job-pgid-unverified", "fixture", {}, ["build"], job_state="running")
        job.process_pgid = 123456
        state.jobs[job.ticket] = job

        with mock.patch.object(conductor.os, "killpg") as killpg:
            with state.condition:
                state._terminate_process_group_locked(job, reason="unverified group")

        killpg.assert_not_called()
        self.assertFalse(job.process_group_identity_confirmed)
        self.assertIn("terminating process tree: unverified group", "".join(job.tail))
        self.assertNotIn("terminating process group: unverified group", "".join(job.tail))

    def test_cancel_signals_process_group_for_reparented_descendant(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        grandchild_pid_path = root / "grandchild.pid"
        grandchild_ready_path = root / "grandchild.ready"
        job = self.make_job(state, "job-pgid-orphan", "fixture", {}, ["build"], job_state="running")
        state.jobs[job.ticket] = job
        state.active_lanes = {"build": job.ticket}

        grandchild_code = textwrap.dedent(
            """
            import os
            import signal
            import sys
            import time

            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            pid_path = sys.argv[1]
            ready_path = sys.argv[2]
            with open(pid_path, "w", encoding="utf-8") as handle:
                handle.write(str(os.getpid()))
            with open(ready_path, "w", encoding="utf-8") as handle:
                handle.write(f"{os.getpid()} {os.getppid()} {os.getpgid(0)}")
            while True:
                time.sleep(1)
            """
        )
        intermediate_code = textwrap.dedent(
            """
            import subprocess
            import sys

            subprocess.Popen(
                [sys.executable, "-u", "-c", sys.argv[1], sys.argv[2], sys.argv[3]],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=False,
            )
            """
        )
        root_code = textwrap.dedent(
            """
            import os
            import subprocess
            import sys
            import time

            grandchild_code = sys.argv[1]
            pid_path = sys.argv[2]
            ready_path = sys.argv[3]
            subprocess.run(
                [sys.executable, "-u", "-c", sys.argv[4], grandchild_code, pid_path, ready_path],
                check=True,
            )
            deadline = time.time() + 5.0
            while not os.path.exists(ready_path) and time.time() < deadline:
                time.sleep(0.05)
            print("ROOT_READY", flush=True)
            while True:
                time.sleep(1)
            """
        )
        argv = [
            sys.executable,
            "-u",
            "-c",
            root_code,
            grandchild_code,
            str(grandchild_pid_path),
            str(grandchild_ready_path),
            intermediate_code,
        ]
        state.registry.prepare = lambda _request: (argv, ["build"], root, os.environ.copy(), 30.0)  # type: ignore[method-assign]

        def cleanup_grandchild() -> None:
            if not grandchild_pid_path.exists() or not grandchild_ready_path.exists():
                return
            with contextlib.suppress(ValueError, ProcessLookupError, PermissionError, OSError):
                grandchild_pid = int(grandchild_pid_path.read_text(encoding="utf-8"))
                grandchild_pgid = int(grandchild_ready_path.read_text(encoding="utf-8").split()[2])
                if os.getpgid(grandchild_pid) == grandchild_pgid:
                    os.kill(grandchild_pid, signal.SIGKILL)

        self.addCleanup(cleanup_grandchild)
        with mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False):
            worker = threading.Thread(target=state._run_job, args=(job.ticket,), daemon=True)
            worker.start()
            deadline = time.time() + 5.0
            while time.time() < deadline:
                with state.condition:
                    process_pgid = job.process_pgid
                if grandchild_ready_path.exists() and process_pgid:
                    break
                time.sleep(0.05)
            self.assertTrue(grandchild_ready_path.exists())
            grandchild_pid = int(grandchild_pid_path.read_text(encoding="utf-8"))
            with state.condition:
                self.assertEqual(os.getpgid(grandchild_pid), job.process_pgid)

            with mock.patch.multiple(
                conductor,
                TERMINATE_GRACE_SECONDS=0.2,
                KILL_GRACE_SECONDS=1.0,
                PROCESS_TREE_POLL_SECONDS=0.02,
            ):
                state.job_cancel(job.ticket, None)
            worker.join(timeout=5.0)

        self.assertFalse(worker.is_alive())
        self.assertEqual(job.state, "canceled")
        deadline = time.time() + 3.0
        while time.time() < deadline and conductor.pid_alive(grandchild_pid):
            time.sleep(0.05)
        self.assertFalse(pid_is_executing(grandchild_pid))

    def test_run_operation_command_uses_devnull_stdin(self) -> None:
        completed = subprocess.CompletedProcess(["echo", "ok"], 0, "ok\n", "")
        with mock.patch.object(conductor.subprocess, "run", return_value=completed) as run, contextlib.redirect_stdout(io.StringIO()):
            code, stdout, stderr = conductor.run_operation_command("fixture", ["echo", "ok"], Path.cwd())

        self.assertEqual((code, stdout, stderr), (0, "ok\n", ""))
        self.assertEqual(run.call_args.kwargs["stdin"], subprocess.DEVNULL)
        self.assertTrue(run.call_args.kwargs["capture_output"])
        self.assertTrue(run.call_args.kwargs["text"])

    def test_release_local_install_job_succeeds_with_closed_parent_fd0(self) -> None:
        child_code = textwrap.dedent(
            f"""
            import os
            import sys
            import tempfile
            from pathlib import Path

            sys.path.insert(0, {str(SCRIPT_DIR)!r})
            import conductor

            tmp = tempfile.TemporaryDirectory()
            root = Path(tmp.name)
            conductor.machine_lock_dir = lambda: root / "machine-locks"
            jobs_dir = root / "jobs"
            scripts_dir = root / "Scripts"
            jobs_dir.mkdir()
            scripts_dir.mkdir()
            installer = scripts_dir / "install_local_production.sh"
            installer.write_text(
                "#!" + {sys.executable!r} + "\\n"
                "import os, sys\\n"
                "fd_stat = os.fstat(0)\\n"
                "devnull_stat = os.stat(os.devnull)\\n"
                "if (fd_stat.st_dev, fd_stat.st_ino) != (devnull_stat.st_dev, devnull_stat.st_ino):\\n"
                "    print('STDIN_NOT_DEVNULL')\\n"
                "    sys.exit(44)\\n"
                "print('STDIN_DEVNULL_OK')\\n",
                encoding="utf-8",
            )
            installer.chmod(0o755)
            paths = conductor.Paths(
                repo_root=root,
                repo_hash="test",
                state_dir=root,
                socket_path=root / "conductor.sock",
                pid_path=root / "conductor.pid",
                lock_path=root / "conductor.lock",
                jobs_dir=jobs_dir,
                daemon_log_path=root / "daemon.log",
                daemon_meta_path=root / "daemon.json",
                running_processes_path=root / "running.json",
            )
            state = conductor.DaemonState(paths)
            state._schedule_locked = lambda: None
            payload = state.enqueue(
                {{
                    "operation": "release",
                    "args": {{"subcommand": "local-install"}},
                    "env": {{"CONFIRM_LOCAL_PRODUCTION_INSTALL": "1"}},
                }}
            )
            ticket = payload["ticket"]
            job = state.jobs[ticket]
            job.state = "running"
            job.started_at = conductor.now()
            for lane in job.lanes:
                state.active_lanes[lane] = ticket
            os.close(0)
            state._run_job(ticket)
            log = job.log_path.read_text(encoding="utf-8")
            if job.state != "completed" or "STDIN_DEVNULL_OK" not in log:
                print(f"job_state={{job.state}} exit={{job.exit_code}}")
                print(log)
                sys.exit(1)
            print("CLOSED_FD_REGRESSION_OK")
            state._io_worker.join()
            tmp.cleanup()
            """
        )

        result = subprocess.run(
            [sys.executable, "-c", child_code],
            stdin=subprocess.DEVNULL,
            text=True,
            capture_output=True,
            timeout=10,
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("CLOSED_FD_REGRESSION_OK", result.stdout)

    def test_app_stop_supersedes_queued_live_app_but_not_build_only_work(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        old_run = self.make_job(state, "old-run", "run", {}, ["build", "debugArtifact", "liveApp"])
        build = self.make_job(state, "build", "build", {}, ["build"])
        state.jobs = {old_run.ticket: old_run, build.ticket: build}
        state.queue = [old_run.ticket, build.ticket]

        with mock.patch.object(state, "_schedule_locked"):
            payload = state.enqueue({"operation": "app", "args": {"subcommand": "stop"}})

        self.assertEqual(old_run.state, "canceled")
        self.assertEqual(old_run.exit_code, 130)
        self.assertEqual(old_run.superseded_by_operation, "app stop")
        self.assertEqual(build.state, "queued")
        self.assertEqual(payload["supersededJobs"][0]["ticket"], old_run.ticket)

    def test_app_relaunch_supersedes_queued_run(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        old_run = self.make_job(state, "old-run", "run", {}, ["build", "debugArtifact", "liveApp"])
        state.jobs[old_run.ticket] = old_run
        state.queue.append(old_run.ticket)

        with mock.patch.object(state, "_schedule_locked"):
            payload = state.enqueue({"operation": "app", "args": {"subcommand": "relaunch", "appArgs": []}})

        self.assertEqual(old_run.state, "canceled")
        self.assertEqual(old_run.superseded_by_operation, "app relaunch")
        self.assertEqual(payload["operationLabel"], "app relaunch")

    def test_running_launch_is_cancellation_requested_and_retains_lane_for_stop(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        old_run = self.make_job(state, "running-run", "run", {}, ["build", "debugArtifact", "liveApp"], "running")
        old_run.process_pid = 123
        state.jobs[old_run.ticket] = old_run
        state.active_lanes = {lane: old_run.ticket for lane in old_run.lanes}

        with mock.patch.object(state, "_request_process_cleanup_locked") as request_cleanup, mock.patch.object(
            state, "_schedule_locked"
        ):
            payload = state.enqueue({"operation": "app", "args": {"subcommand": "stop"}})

        stop = state.jobs[payload["ticket"]]
        self.assertTrue(old_run.cancel_requested)
        self.assertEqual(old_run.state, "running")
        self.assertEqual(state.active_lanes["liveApp"], old_run.ticket)
        self.assertTrue(stop.args["guardDelayedLaunch"])
        request_cleanup.assert_called_once_with(
            old_run,
            reason=f"superseded by app stop {payload['ticket']}",
        )

    def test_superseded_job_without_pid_is_signaled_after_delayed_assignment_then_escalated(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        old_run = self.make_job(state, "delayed-pid-run", "run", {}, ["build", "debugArtifact", "liveApp"], "running")
        state.jobs[old_run.ticket] = old_run
        state.active_lanes = {lane: old_run.ticket for lane in old_run.lanes}
        real_thread = threading.Thread

        def wait_for_exit(*_args: object, **_kwargs: object) -> bool:
            if not hasattr(wait_for_exit, "called"):
                wait_for_exit.called = True  # type: ignore[attr-defined]
                return True
            old_run.state = "canceled"
            return False

        with mock.patch.object(state, "_terminate_process_group_locked") as terminate, mock.patch.object(
            state, "_kill_process_group_locked"
        ) as kill, mock.patch.object(
            state, "_wait_for_process_tree_exit_locked", side_effect=wait_for_exit
        ), mock.patch.object(state, "_schedule_locked"), mock.patch.object(
            conductor, "TERMINATE_GRACE_SECONDS", 0.01
        ), mock.patch.object(conductor.threading, "Thread") as thread_factory:
            state.enqueue({"operation": "app", "args": {"subcommand": "stop"}})
            terminate.assert_not_called()
            target = thread_factory.call_args.kwargs["target"]
            args = thread_factory.call_args.kwargs["args"]
            self.assertIsInstance(args[0], conductor.JobLease)
            self.assertEqual(args[0].ticket, old_run.ticket)
            worker = real_thread(target=target, args=args)
            worker.start()
            time.sleep(0.03)
            terminate.assert_not_called()
            kill.assert_not_called()
            with state.condition:
                old_run.process_pid = 456
                state.condition.notify_all()
            worker.join(timeout=1.0)

        self.assertFalse(worker.is_alive())
        terminate.assert_called_once()
        self.assertIs(terminate.call_args.args[0], old_run)
        kill.assert_called_once()
        self.assertIs(kill.call_args.args[0], old_run)

    def test_outstanding_launch_guard_propagates_to_newer_lifecycle_intents(self) -> None:
        for subcommand in ["stop", "relaunch"]:
            with self.subTest(subcommand=subcommand):
                tmp, state = self.make_state()
                self.addCleanup(tmp.cleanup)
                guarded = self.make_job(
                    state,
                    "guarded-stop",
                    "app",
                    {"subcommand": "stop", "guardDelayedLaunch": True},
                    ["liveApp"],
                )
                state.jobs[guarded.ticket] = guarded
                state.queue.append(guarded.ticket)
                args = {"subcommand": subcommand}
                if subcommand == "relaunch":
                    args["appArgs"] = []

                with mock.patch.object(state, "_schedule_locked"):
                    payload = state.enqueue({"operation": "app", "args": args})

                self.assertTrue(state.jobs[payload["ticket"]].args["guardDelayedLaunch"])

    def test_ordinary_run_remains_fifo_and_does_not_supersede(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        prior = self.make_job(state, "prior", "run", {}, ["build", "debugArtifact", "liveApp"])
        state.jobs[prior.ticket] = prior
        state.queue.append(prior.ticket)

        with mock.patch.object(state, "_schedule_locked"):
            payload = state.enqueue({"operation": "run", "args": {"appArgs": []}})

        self.assertEqual(prior.state, "queued")
        self.assertFalse(prior.cancel_requested)
        self.assertEqual(payload.get("supersededJobs"), [])

    def test_request_key_reuse_is_checked_before_supersession(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        request = {"operation": "app", "args": {"subcommand": "relaunch", "appArgs": []}, "requestKey": "interactive"}
        fingerprint = state.registry.fingerprint(request)
        existing = self.make_job(
            state,
            "existing",
            "app",
            {"subcommand": "relaunch", "appArgs": []},
            ["build", "debugArtifact", "liveApp"],
            request_key="interactive",
            fingerprint=fingerprint,
        )
        victim = self.make_job(state, "victim", "run", {}, ["build", "debugArtifact", "liveApp"])
        state.jobs = {existing.ticket: existing, victim.ticket: victim}
        state.queue = [existing.ticket, victim.ticket]
        state.request_keys["interactive"] = existing.ticket

        payload = state.enqueue(request)

        self.assertTrue(payload["reused"])
        self.assertFalse(victim.cancel_requested)

    def test_request_key_mismatch_has_no_supersession_side_effect(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        existing = self.make_job(state, "keyed", "build", {}, ["build"], request_key="interactive", fingerprint="other")
        victim = self.make_job(state, "victim", "run", {}, ["build", "debugArtifact", "liveApp"])
        state.jobs = {existing.ticket: existing, victim.ticket: victim}
        state.queue = [existing.ticket, victim.ticket]
        state.request_keys["interactive"] = existing.ticket

        with self.assertRaises(conductor.ConductorError):
            state.enqueue({"operation": "app", "args": {"subcommand": "stop"}, "requestKey": "interactive"})

        self.assertFalse(victim.cancel_requested)
        self.assertEqual(victim.state, "queued")

    def test_queued_payload_identifies_active_lane_blocker(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        active = self.make_job(state, "build-active", "build", {}, ["build"], "running")
        waiting = self.make_job(state, "relaunch", "app", {"subcommand": "relaunch"}, ["build", "debugArtifact", "liveApp"])
        state.jobs = {active.ticket: active, waiting.ticket: waiting}
        state.active_lanes = {"build": active.ticket}
        state.queue = [waiting.ticket]

        payload = state.job_status(waiting.ticket, None)

        self.assertEqual(payload["blockedBy"][0]["ticket"], active.ticket)
        self.assertEqual(payload["blockedBy"][0]["conflictingLanes"], ["build"])

    def wait_for_terminal_job(self, state: conductor.DaemonState, ticket: str, timeout: float = 5.0) -> conductor.Job:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with state.condition:
                job = state.jobs[ticket]
                # A job becomes terminal before the runner's final persistence
                # and lane-release work is complete. Wait for that finalizer so
                # TemporaryDirectory cleanup cannot race its record write.
                if job.state in conductor.TERMINAL_STATES and ticket not in state.active_lanes.values():
                    return job
            time.sleep(0.01)
        with state.condition:
            return state.jobs[ticket]

    def make_state_for_global_slot(
        self,
        root: Path,
        name: str,
        shared_socket_parent: Path,
    ) -> conductor.DaemonState:
        state_dir = root / name
        jobs_dir = state_dir / "jobs"
        jobs_dir.mkdir(parents=True)
        paths = conductor.Paths(
            repo_root=state_dir,
            repo_hash=name,
            state_dir=state_dir,
            socket_path=shared_socket_parent / f"{name}.sock",
            pid_path=state_dir / "conductor.pid",
            lock_path=state_dir / "conductor.lock",
            jobs_dir=jobs_dir,
            daemon_log_path=state_dir / "daemon.log",
            daemon_meta_path=state_dir / "daemon.json",
            running_processes_path=state_dir / "running.json",
        )
        state = conductor.DaemonState(paths)
        self._states.append(state)
        return state

    def test_global_heavy_slot_serializes_build_lane_jobs_across_daemons(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        shared_socket_parent = root / "shared"
        shared_socket_parent.mkdir()
        state_a = self.make_state_for_global_slot(root, "daemon-a", shared_socket_parent)
        state_b = self.make_state_for_global_slot(root, "daemon-b", shared_socket_parent)

        lock_root = root / "machine-locks"
        with mock.patch.object(conductor, "FAIR_HEAVY_RESCAN_SECONDS", 0.01), mock.patch.object(
            conductor, "machine_lock_dir", return_value=lock_root
        ):
            payload_a = state_a.enqueue(
                {
                    "operation": "fake-sleep",
                    "args": {"seconds": 0.25, "lanes": ["build"], "message": "daemon-a"},
                }
            )
            payload_b = state_b.enqueue(
                {
                    "operation": "fake-sleep",
                    "args": {"seconds": 0.25, "lanes": ["build"], "message": "daemon-b"},
                }
            )
            job_a = self.wait_for_terminal_job(state_a, payload_a["ticket"])
            job_b = self.wait_for_terminal_job(state_b, payload_b["ticket"])

        self.assertEqual(job_a.state, "completed", job_a.result_summary)
        self.assertEqual(job_b.state, "completed", job_b.result_summary)
        self.assertEqual(job_a.global_heavy_slot_path, str(lock_root / "global-heavy-0.lock"))
        self.assertEqual(job_b.global_heavy_slot_path, str(lock_root / "global-heavy-0.lock"))
        self.assertIsNotNone(job_a.process_started_at)
        self.assertIsNotNone(job_a.process_finished_at)
        self.assertIsNotNone(job_b.process_started_at)
        self.assertIsNotNone(job_b.process_finished_at)

        first, second = sorted([job_a, job_b], key=lambda job: job.process_started_at or 0)
        self.assertGreaterEqual(second.process_started_at or 0, first.process_finished_at or 0)
        self.assertGreater(max(job_a.global_heavy_slot_wait_seconds or 0, job_b.global_heavy_slot_wait_seconds or 0), 0.05)

    def test_cancel_waiting_for_global_heavy_slot_does_not_spawn_process(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        shared_socket_parent = root / "shared"
        shared_socket_parent.mkdir()
        state = self.make_state_for_global_slot(root, "daemon", shared_socket_parent)
        lock_root = root / "machine-locks"
        with mock.patch.object(conductor, "FAIR_HEAVY_RESCAN_SECONDS", 0.01), mock.patch.object(
            conductor, "machine_lock_dir", return_value=lock_root
        ):
            lock_path = lock_root / "global-heavy-0.lock"
            lock_root.mkdir(mode=0o700, parents=True, exist_ok=True)
            lock_file = lock_path.open("a+", encoding="utf-8")
            self.addCleanup(lock_file.close)
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
            self.addCleanup(lambda: fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN))
            payload = state.enqueue(
                {
                    "operation": "fake-sleep",
                    "args": {"seconds": 0.5, "lanes": ["build"], "message": "blocked"},
                }
            )
            ticket = payload["ticket"]
            deadline = time.monotonic() + 2.0
            while time.monotonic() < deadline:
                with state.condition:
                    job = state.jobs[ticket]
                    if job.global_heavy_slot_path and job.process_started_at is None:
                        break
                time.sleep(0.01)
            with state.condition:
                self.assertEqual(state.jobs[ticket].state, "running")
                self.assertIsNone(state.jobs[ticket].process_started_at)
            state.job_cancel(ticket, None)
            job = self.wait_for_terminal_job(state, ticket)

        self.assertEqual(job.state, "canceled")
        self.assertEqual(job.exit_code, 130)
        self.assertEqual(job.result_summary, "canceled before global heavy slot")
        self.assertIsNone(job.process_pid)
        self.assertIsNone(job.process_started_at)
        self.assertIn("job canceled before global heavy slot", "".join(job.tail))

    def test_cancel_after_global_heavy_acquisition_terminalizes_job_before_releasing_stale_lease(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(state, "late-heavy-cancel", "build", {}, ["build"], job_state="running")
        state.jobs[job.ticket] = job
        released = threading.Event()

        class AcquiredLease:
            lock_path = state.paths.state_dir / "global-heavy-0.lock"

            def release(self) -> None:
                released.set()

        acquired = AcquiredLease()
        assert_false = self.assertFalse

        class Coordinator:
            waiter_id = "waiter"
            current_rescan_seconds = conductor.FAIR_HEAVY_HEAD_RESCAN_SECONDS
            legacy_slot_holder = None

            def __init__(self, *_args: object, **_kwargs: object) -> None:
                pass

            def wait(self, cancel_check: object, update: object) -> AcquiredLease:
                assert_false(cancel_check())
                with state.condition:
                    job.cancel_requested = True
                return acquired

        with mock.patch.object(conductor, "FairHeavyAdmission", Coordinator):
            lease = state._acquire_global_heavy_slot(job.ticket)

        self.assertIsNone(lease)
        self.assertTrue(released.is_set())
        self.assertEqual(job.state, "canceled")
        self.assertEqual(job.phase, "terminal")
        self.assertEqual(job.exit_code, 130)
        self.assertEqual(job.result_summary, "canceled before global heavy slot")
        self.assertEqual(job.global_heavy_admission_state, "released")
        self.assertIn("job canceled before global heavy slot", "".join(job.tail))

    def test_socket_parent_does_not_shard_global_heavy_slots(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        state_a = self.make_state_for_global_slot(root, "daemon-a", root / "socket-a")
        state_b = self.make_state_for_global_slot(root, "daemon-b", root / "socket-b")
        lock_root = root / "machine-locks"

        with mock.patch.object(conductor, "machine_lock_dir", return_value=lock_root):
            self.assertEqual(state_a._global_heavy_slot_paths(), [lock_root / "global-heavy-0.lock"])
            self.assertEqual(state_b._global_heavy_slot_paths(), [lock_root / "global-heavy-0.lock"])

    def test_configured_global_heavy_slots_allow_two_cross_daemon_builds(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        state_a = self.make_state_for_global_slot(root, "daemon-a", root / "socket-a")
        state_b = self.make_state_for_global_slot(root, "daemon-b", root / "socket-b")
        lock_root = root / "machine-locks"

        with mock.patch.object(conductor, "machine_lock_dir", return_value=lock_root), mock.patch.dict(
            os.environ,
            {"REPOPROMPT_DEV_HEAVY_SLOTS": "2"},
        ):
            payload_a = state_a.enqueue(
                {
                    "operation": "fake-sleep",
                    "args": {"seconds": 0.25, "lanes": ["build"], "message": "daemon-a"},
                    "env": {"REPOPROMPT_DEV_HEAVY_SLOTS": "2"},
                }
            )
            payload_b = state_b.enqueue(
                {
                    "operation": "fake-sleep",
                    "args": {"seconds": 0.25, "lanes": ["build"], "message": "daemon-b"},
                    "env": {"REPOPROMPT_DEV_HEAVY_SLOTS": "2"},
                }
            )
            job_a = self.wait_for_terminal_job(state_a, payload_a["ticket"])
            job_b = self.wait_for_terminal_job(state_b, payload_b["ticket"])

        self.assertEqual(job_a.state, "completed", job_a.result_summary)
        self.assertEqual(job_b.state, "completed", job_b.result_summary)
        self.assertNotEqual(job_a.global_heavy_slot_path, job_b.global_heavy_slot_path)
        latest_start = max(job_a.process_started_at or 0, job_b.process_started_at or 0)
        earliest_finish = min(job_a.process_finished_at or 0, job_b.process_finished_at or 0)
        self.assertLess(latest_start, earliest_finish)

    def test_live_app_lock_serializes_across_processes_without_gui_launch(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            lock_root = root / "machine-locks"
            events = root / "events.log"
            ready = root / "ready-a"
            child = textwrap.dedent(
                """\
                import sys, time
                from pathlib import Path
                sys.path.insert(0, sys.argv[1])
                import conductor
                conductor.MACHINE_LOCK_POLL_SECONDS = 0.01
                conductor.machine_lock_dir = lambda: Path(sys.argv[2])
                label = sys.argv[3]
                events = Path(sys.argv[4])
                ready = Path(sys.argv[5]) if sys.argv[5] != '-' else None
                metadata = conductor.display_lock_metadata(
                    lock_kind='live-app',
                    ticket=label,
                    operation='test-live-app',
                    operation_label='test live app',
                    repo_root=Path(sys.argv[2]),
                )
                with conductor.machine_exclusive_lock(conductor.live_app_lock_path(), metadata, 'live-app lock'):
                    with events.open('a', encoding='utf-8') as handle:
                        handle.write(f'start {label} {time.time()}\\n')
                    if ready is not None:
                        ready.write_text('ready', encoding='utf-8')
                    time.sleep(0.25)
                    with events.open('a', encoding='utf-8') as handle:
                        handle.write(f'end {label} {time.time()}\\n')
                """
            )
            proc_a = subprocess.Popen(
                [sys.executable, "-c", child, str(SCRIPT_DIR), str(lock_root), "a", str(events), str(ready)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            deadline = time.monotonic() + 2.0
            while time.monotonic() < deadline and not ready.exists():
                time.sleep(0.01)
            self.assertTrue(ready.exists())
            proc_b = subprocess.Popen(
                [sys.executable, "-c", child, str(SCRIPT_DIR), str(lock_root), "b", str(events), "-"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            stdout_a, stderr_a = proc_a.communicate(timeout=5)
            stdout_b, stderr_b = proc_b.communicate(timeout=5)
            self.assertEqual(proc_a.returncode, 0, stdout_a + stderr_a)
            self.assertEqual(proc_b.returncode, 0, stdout_b + stderr_b)
            rows = events.read_text(encoding="utf-8").splitlines()

        self.assertEqual([row.split()[0:2] for row in rows], [["start", "a"], ["end", "a"], ["start", "b"], ["end", "b"]])


class XCTestStallWatchdogTests(LifecycleTestCase):
    def make_watchdog_job(
        self,
        state: conductor.DaemonState,
        *,
        wake_probe: bool = False,
    ) -> conductor.Job:
        args: dict[str, object] = {"xctestStallSeconds": 5.0}
        if wake_probe:
            args["xctestStallWakeProbe"] = True
        job = self.make_job(state, "xctest-watchdog", "test", args, ["build"], job_state="running")
        state.jobs[job.ticket] = job
        return job

    def assert_fds_closed(self, fds: list[int]) -> None:
        for fd in fds:
            with self.assertRaises(OSError):
                os.fstat(fd)

    def test_output_transport_selection_is_pty_only_for_watchdog_tests(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        jobs = [
            ("build", {}, "pipe"),
            ("test", {}, "pipe"),
            ("provider-test", {}, "pipe"),
            ("test", {"xctestStallSeconds": 5.0}, "pty"),
            ("provider-test", {"xctestStallSeconds": 5.0}, "pty"),
            ("test", {"xctestStallSeconds": 5.0, "xctestStallWakeProbe": True}, "pty"),
        ]

        for index, (operation, args, expected) in enumerate(jobs):
            with self.subTest(operation=operation, args=args):
                job = self.make_job(state, f"transport-{index}", operation, args, ["build"], "running")
                transport = state._create_process_output_transport(job)
                try:
                    self.assertEqual(transport.kind, expected)
                finally:
                    transport.close_all()

    def test_process_output_transport_closes_native_pty_descriptors_idempotently(self) -> None:
        transport = conductor.ProcessOutputTransport.create("pty")
        fds = [transport.reader_fd, transport.writer_fd]
        self.assertTrue(all(isinstance(fd, int) for fd in fds))

        transport.close_all()
        transport.close_all()

        self.assert_fds_closed([int(fd) for fd in fds if fd is not None])

    def test_process_output_transport_transfers_reader_without_runner_close(self) -> None:
        transport = conductor.ProcessOutputTransport.create("pipe")
        reader_fd = transport.transfer_reader()
        writer_fd = transport.writer_fd

        transport.close_all()

        os.fstat(reader_fd)
        self.assert_fds_closed([int(writer_fd)])
        os.close(reader_fd)

    def test_output_pump_owns_reader_close_and_flushes_unterminated_eof(self) -> None:
        chunks: list[bytes] = []
        lines: list[bytes] = []
        close_threads: list[str] = []

        def close_fd(fd: int) -> None:
            close_threads.append(threading.current_thread().name)
            os.close(fd)

        pump = conductor.ProcessOutputPump(
            lambda _ticket, chunk: chunks.append(chunk),
            lambda _ticket, line: lines.append(line),
            close_fd=close_fd,
        )
        self.addCleanup(pump.close)
        reader_fd, writer_fd = os.pipe()
        os.set_blocking(reader_fd, False)
        channel = pump.register("normal-eof", reader_fd, "pipe")

        os.write(writer_fd, b"complete\nunterminated")
        os.close(writer_fd)

        self.assertTrue(channel.completion.wait(1.0))
        self.assertEqual(channel.result, conductor.ProcessOutputResult(False, None, 21))
        self.assertEqual(b"".join(chunks), b"complete\nunterminated")
        self.assertEqual(lines, [b"complete\n", b"unterminated"])
        self.assertEqual(close_threads, ["conductor-output-pump"])
        self.assert_fds_closed([reader_fd])

    def test_output_pump_finalization_bounds_inherited_writer_and_marks_truncation(self) -> None:
        clock_value = 100.0
        closed = threading.Event()

        def clock() -> float:
            return clock_value

        def close_fd(fd: int) -> None:
            os.close(fd)
            closed.set()

        pump = conductor.ProcessOutputPump(
            lambda *_args: None,
            lambda *_args: None,
            clock=clock,
            close_fd=close_fd,
        )
        self.addCleanup(pump.close)
        reader_fd, inherited_writer_fd = os.pipe()
        os.set_blocking(reader_fd, False)
        channel = pump.register("inherited-writer", reader_fd, "pipe")

        pump.request_finalization(channel)
        self.assertTrue(channel.finalization_started.wait(1.0))
        clock_value += conductor.OUTPUT_FINALIZATION_SECONDS
        pump._wake_writer.send(b"x")

        self.assertTrue(channel.completion.wait(1.0))
        self.assertEqual(
            channel.result,
            conductor.ProcessOutputResult(True, "inheritedWriterDeadline", 0),
        )
        self.assertTrue(closed.is_set())
        self.assert_fds_closed([reader_fd])
        os.close(inherited_writer_fd)

    def test_pty_eio_is_eof_without_waiting_for_popen_to_reap_child(self) -> None:
        closed: list[int] = []
        pump = conductor.ProcessOutputPump(lambda *_args: None, lambda *_args: None, close_fd=closed.append)
        self.addCleanup(pump.close)
        channel = conductor.ProcessOutputChannel(ticket="pty-eio", read_fd=123, kind="pty")

        with mock.patch.object(conductor.os, "read", side_effect=OSError(errno.EIO, "fixture EIO")):
            pump._read_available(channel)

        self.assertEqual(channel.result, conductor.ProcessOutputResult(False, None, 0))
        self.assertEqual(closed, [123])

    def test_output_relay_frames_split_multiple_crlf_unterminated_and_sgr_markers(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_watchdog_job(state)
        job.progress_transport = "pty"
        first = "-[RepoPromptTests.ExampleTests testOne]"
        second = "-[RepoPromptTests.ExampleTests testTwo]"
        chunks = [
            b"\x1b[32mTest Ca",
            (
                f"se '{first}' started.\x1b[0m\r\n"
                f"Test Case '{first}' passed (0.001 seconds).\n"
                "Test Case '-[RepoPromptTests.ExampleTests test"
            ).encode(),
            (
                "Two]' started.\n"
                f"Test Case '{second}' skipped (0.001 seconds)."
            ).encode(),
            b"",
        ]
        log = io.BytesIO()
        pump = conductor.ProcessOutputPump(
            lambda _ticket, chunk: log.write(chunk),
            state._submit_process_output_line,
        )
        self.addCleanup(pump.close)
        reader_fd, writer_fd = os.pipe()
        os.set_blocking(reader_fd, False)
        channel = pump.register(job.ticket, reader_fd, "pipe")
        for chunk in chunks[:-1]:
            os.write(writer_fd, chunk)
        os.close(writer_fd)
        self.assertTrue(channel.completion.wait(1.0))

        self.assertEqual(log.getvalue(), b"".join(chunks[:-1]))
        self.assertEqual(job.xctest_progress_sequence, 4)
        self.assertEqual(job.xctest_last_progress_test, second)
        self.assertEqual(job.xctest_last_progress_action, "skipped")
        self.assertIsNone(job.xctest_current_test)
        self.assertEqual(job.xctest_previous_test, second)
        self.assertEqual(len(job.tail), 4)
        self.assertTrue(job.tail[0].endswith("\r\n"))
        self.assertFalse(job.tail[-1].endswith("\n"))

    def test_watchdog_trigger_snapshot_is_immutable_after_later_progress(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_watchdog_job(state)
        job.progress_transport = "pty"
        test_name = "-[RepoPromptTests.ExampleTests testSnapshot]"
        state._record_xctest_progress_locked(
            job,
            f"Test Case '{test_name}' started.\n",
            observed_at=10.0,
        )
        claim = state._claim_xctest_stall_locked(job, observed_at=15.0)
        self.assertIsNotNone(claim)
        state._record_xctest_progress_locked(
            job,
            f"Test Case '{test_name}' passed (0.001 seconds).\n",
            observed_at=16.0,
        )

        with mock.patch.object(state, "_xctest_process_snapshot_locked", return_value=(None, [])), mock.patch.object(
            state,
            "_capture_xctest_stall_diagnostics",
            side_effect=lambda _job, diagnostic, _identity: diagnostic,
        ), mock.patch.object(state, "_terminate_xctest_stalled_job"):
            state._handle_xctest_stall(job.ticket, claim)

        diagnostic = job.diagnostics[-1]
        self.assertEqual(diagnostic["progressTransport"], "pty")
        self.assertEqual(diagnostic["progressSequence"], 1)
        self.assertEqual(diagnostic["lastProgressTest"], test_name)
        self.assertEqual(diagnostic["lastProgressAction"], "started")
        self.assertEqual(diagnostic["lastProgressObservedAt"], 10.0)
        self.assertEqual(diagnostic["currentTest"], test_name)
        self.assertIsNone(diagnostic["previousTest"])
        self.assertEqual(job.xctest_progress_sequence, 2)
        self.assertEqual(job.xctest_last_progress_action, "passed")
        self.assertIsNone(job.xctest_current_test)

    def test_buffered_xctest_marker_streams_on_pty_before_watchdog_capture(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        root = state.paths.repo_root
        test_name = "-[RepoPromptTests.BufferedTests testStreamsBeforeStall]"
        child_code = textwrap.dedent(
            f"""\
            import time
            print("Test Case {test_name!r} started.")
            time.sleep(30)
            """
        )
        argv = [sys.executable, "-c", child_code]
        job = self.make_job(
            state,
            "buffered-xctest-pty",
            "test",
            {"xctestStallSeconds": 0.1},
            ["build"],
            job_state="running",
        )
        job.timeout = 5.0
        state.jobs[job.ticket] = job
        state.active_lanes = {"build": job.ticket}
        opened_fds: list[int] = []
        closed_fds: list[int] = []
        real_openpty = os.openpty
        real_close = os.close

        def tracking_openpty() -> tuple[int, int]:
            pair = real_openpty()
            opened_fds.extend(pair)
            return pair

        def tracking_close(fd: int) -> None:
            closed_fds.append(fd)
            real_close(fd)

        state._output_pump._close_fd = tracking_close

        def prepare(_request: dict) -> tuple[list[str], list[str], Path, dict[str, str], float]:
            return argv, ["build"], root, os.environ.copy(), 5.0

        with mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False), mock.patch.object(
            state.registry, "prepare", side_effect=prepare
        ), mock.patch.object(
            conductor.os, "openpty", side_effect=tracking_openpty
        ), mock.patch.object(conductor.os, "close", side_effect=tracking_close), mock.patch.object(
            state,
            "_xctest_process_snapshot_locked",
            return_value=(None, []),
        ), mock.patch.object(
            state,
            "_capture_xctest_stall_diagnostics",
            side_effect=lambda _job, diagnostic, _identity: diagnostic,
        ):
            state._run_job(job.ticket)

        log = job.log_path.read_text(encoding="utf-8")
        marker = f"Test Case '{test_name}' started."
        watchdog_line = "XCTest progress stall watchdog triggered"
        self.assertEqual(job.state, "failed")
        self.assertEqual(job.exit_code, conductor.XCTEST_STALL_FAILURE_EXIT_CODE)
        self.assertEqual(job.progress_transport, "pty")
        self.assertGreater(job.xctest_progress_sequence, 0)
        self.assertEqual(job.diagnostics[0]["lastProgressTest"], test_name)
        self.assertEqual(job.diagnostics[0]["lastProgressAction"], "started")
        self.assertEqual(job.diagnostics[0]["currentTest"], test_name)
        self.assertLess(log.index(marker), log.index(watchdog_line))
        self.assertFalse(state._process_tree_alive_locked(job))
        self.assertTrue(set(opened_fds).issubset(closed_fds))

    def test_pty_descriptors_close_when_process_launch_fails(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_watchdog_job(state)
        opened_fds: list[int] = []
        closed_fds: list[int] = []
        real_openpty = os.openpty
        real_close = os.close

        def tracking_openpty() -> tuple[int, int]:
            pair = real_openpty()
            opened_fds.extend(pair)
            return pair

        def tracking_close(fd: int) -> None:
            closed_fds.append(fd)
            real_close(fd)

        with mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False), mock.patch.object(
            conductor.os, "openpty", side_effect=tracking_openpty
        ), mock.patch.object(conductor.os, "close", side_effect=tracking_close), mock.patch.object(
            conductor.subprocess,
            "Popen",
            side_effect=OSError("fixture launch failure"),
        ), mock.patch.object(state, "_schedule_locked"), mock.patch.object(state, "_refresh_output_summary"):
            state._run_job(job.ticket)

        self.assertEqual(job.state, "failed")
        self.assertIn("fixture launch failure", job.error or "")
        self.assertTrue(set(opened_fds).issubset(closed_fds))

    def test_output_transport_cleanup_runs_for_success_timeout_and_cancellation(self) -> None:
        for terminal_path in ["success", "timeout", "cancellation"]:
            with self.subTest(terminal_path=terminal_path):
                tmp, state = self.make_state()
                self.addCleanup(tmp.cleanup)
                job = self.make_watchdog_job(state)
                job.ticket = f"cleanup-{terminal_path}"
                job.log_path = state.paths.jobs_dir / f"{job.ticket}.log"
                state.jobs = {job.ticket: job}
                transport = conductor.ProcessOutputTransport.create("pty")
                fake_process = mock.Mock(stdout=None)
                fake_process.pid = os.getpid()
                fake_process.poll.return_value = 0
                if terminal_path == "success":
                    fake_process.wait.return_value = 0
                elif terminal_path == "timeout":
                    fake_process.wait.side_effect = [
                        subprocess.TimeoutExpired(["fixture"], 1.0),
                        0,
                    ]
                else:
                    def cancel_then_exit(*_args: object, **_kwargs: object) -> int:
                        job.cancel_requested = True
                        return 0

                    fake_process.wait.side_effect = cancel_then_exit

                with mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False), mock.patch.object(
                    state, "_create_process_output_transport", return_value=transport
                ), mock.patch.object(
                    conductor.subprocess,
                    "Popen",
                    return_value=fake_process,
                ), mock.patch.object(
                    conductor,
                    "process_table_snapshot",
                    return_value={os.getpid(): (os.getppid(), "fixture-start")},
                ), mock.patch.object(
                    state,
                    "_terminate_process_group_locked",
                ), mock.patch.object(
                    state,
                    "_kill_process_group_locked",
                ), mock.patch.object(
                    state,
                    "_process_tree_alive_locked",
                    return_value=False,
                ), mock.patch.object(
                    state,
                    "_wait_for_process_tree_exit_locked",
                    return_value=False,
                ), mock.patch.object(state, "_schedule_locked"), mock.patch.object(
                    state,
                    "_refresh_output_summary",
                ):
                    state._run_job(job.ticket)

                self.assertIsNone(transport.reader_fd)
                self.assertIsNone(transport.writer_fd)
                self.assertTrue(transport.reader_transferred)
                if terminal_path == "success":
                    self.assertEqual(job.state, "completed")
                elif terminal_path == "timeout":
                    self.assertTrue(job.timed_out)
                    self.assertEqual(job.exit_code, 124)
                else:
                    self.assertEqual(job.state, "canceled")

    def test_watchdog_triggers_at_most_once_after_started_marker(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_watchdog_job(state)

        matched = state._record_xctest_progress_locked(
            job,
            "Test Case '-[RepoPromptTests.ExampleTests testStall]' started.\n",
            observed_at=10.0,
        )
        first = state._claim_xctest_stall_locked(job, observed_at=15.0)
        second = state._claim_xctest_stall_locked(job, observed_at=50.0)

        self.assertTrue(matched)
        self.assertIsNotNone(first)
        self.assertIsNone(second)
        self.assertTrue(job.xctest_watchdog_triggered)
        self.assertTrue(job.measurement_invalid)

    def test_watchdog_does_not_signal_or_trigger_before_threshold(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_watchdog_job(state, wake_probe=True)
        state._record_xctest_progress_locked(
            job,
            "Test Case '-[RepoPromptTests.ExampleTests testStillRunning]' started.\n",
            observed_at=20.0,
        )

        with mock.patch.object(conductor.os, "kill") as kill:
            claim = state._claim_xctest_stall_locked(job, observed_at=24.999)

        self.assertIsNone(claim)
        self.assertFalse(job.measurement_invalid)
        kill.assert_not_called()

    def test_only_xctest_progress_markers_reset_after_first_started_marker(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_watchdog_job(state)

        ignored = state._record_xctest_progress_locked(
            job,
            "Test Case '-[RepoPromptTests.ExampleTests testBeforeStart]' passed (0.001 seconds).\n",
            observed_at=1.0,
        )
        self.assertFalse(ignored)
        self.assertIsNone(job.xctest_progress_deadline)

        markers = [
            ("started", "", 2.0),
            ("passed", " (0.001 seconds)", 3.0),
            ("failed", " (0.001 seconds)", 4.0),
            ("skipped", " (0.001 seconds)", 5.0),
        ]
        for action, suffix, observed_at in markers:
            with self.subTest(action=action):
                matched = state._record_xctest_progress_locked(
                    job,
                    f"Test Case '-[RepoPromptTests.ExampleTests testProgress]' {action}{suffix}.\n",
                    observed_at=observed_at,
                )
                self.assertTrue(matched)
                self.assertEqual(job.xctest_progress_deadline, observed_at + 5.0)

    def test_unrelated_output_does_not_reset_xctest_progress_deadline(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_watchdog_job(state)
        state._record_xctest_progress_locked(
            job,
            "Test Case '-[RepoPromptTests.ExampleTests testOutput]' started.\n",
            observed_at=30.0,
        )
        original_deadline = job.xctest_progress_deadline

        matched = state._record_xctest_progress_locked(
            job,
            "arbitrary compiler or test diagnostic output\n",
            observed_at=34.0,
        )
        claim = state._claim_xctest_stall_locked(job, observed_at=35.0)

        self.assertFalse(matched)
        self.assertEqual(job.xctest_progress_deadline, original_deadline)
        self.assertIsNotNone(claim)

    def test_wake_probe_rejects_pid_start_token_mismatch(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_watchdog_job(state, wake_probe=True)
        state._record_xctest_progress_locked(
            job,
            "Test Case '-[RepoPromptTests.ExampleTests testIdentity]' started.\n",
            observed_at=1.0,
        )
        claim = state._claim_xctest_stall_locked(job, observed_at=6.0)
        self.assertIsNotNone(claim)

        with mock.patch.object(
            state,
            "_xctest_process_snapshot_locked",
            return_value=((4321, "expected-token"), []),
        ), mock.patch.object(
            state,
            "_capture_xctest_stall_diagnostics",
            side_effect=lambda _job, diagnostic, _identity: diagnostic,
        ), mock.patch.object(
            conductor,
            "process_table_snapshot",
            return_value={4321: (1, "reused-pid-token")},
        ), mock.patch.object(conductor.os, "kill") as kill, mock.patch.object(
            state,
            "_terminate_xctest_stalled_job",
        ) as terminate:
            state._handle_xctest_stall(job.ticket, claim)

        kill.assert_not_called()
        terminate.assert_called_once_with(job)
        self.assertFalse(job.diagnostics[-1]["stopSent"])
        self.assertFalse(job.diagnostics[-1]["continueSent"])

    def test_resumed_progress_after_wake_probe_still_fails_measurement(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_watchdog_job(state, wake_probe=True)
        state._record_xctest_progress_locked(
            job,
            "Test Case '-[RepoPromptTests.ExampleTests testRecovered]' started.\n",
            observed_at=1.0,
        )
        claim = state._claim_xctest_stall_locked(job, observed_at=6.0)
        self.assertIsNotNone(claim)

        with mock.patch.object(
            state,
            "_xctest_process_snapshot_locked",
            return_value=((5432, "stable-token"), []),
        ), mock.patch.object(
            state,
            "_capture_xctest_stall_diagnostics",
            side_effect=lambda _job, diagnostic, _identity: diagnostic,
        ), mock.patch.object(
            state,
            "_signal_process_identity",
            side_effect=[True, True],
        ) as signal_identity, mock.patch.object(
            state,
            "_wait_for_xctest_progress_after_probe",
            return_value=True,
        ), mock.patch.object(state, "_terminate_xctest_stalled_job") as terminate, mock.patch.object(
            conductor.time,
            "sleep",
        ):
            state._handle_xctest_stall(job.ticket, claim)

        state._finalize_process_exit_locked(job, 0)
        self.assertEqual(signal_identity.call_args_list[0].args[2], conductor.signal.SIGSTOP)
        self.assertEqual(signal_identity.call_args_list[1].args[2], conductor.signal.SIGCONT)
        self.assertEqual(signal_identity.call_count, 2)
        terminate.assert_called_once_with(job)
        self.assertTrue(job.diagnostics[-1]["progressResumed"])
        self.assertEqual(job.state, "failed")
        self.assertEqual(job.exit_code, conductor.XCTEST_STALL_FAILURE_EXIT_CODE)
        self.assertTrue(job.measurement_invalid)

    def test_controlled_wake_probe_progress_still_fails_live_job(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        root = state.paths.repo_root
        fake_xctest = root / "ControlledTests.xctest"
        fake_xctest.symlink_to(sys.executable)
        child_code = textwrap.dedent(
            """\
            import time

            test_name = "-[RepoPromptTests.ControlledTests testWakeProbe]"
            print(f"Test Case '{test_name}' started.", flush=True)
            time.sleep(1)
            print(f"Test Case '{test_name}' passed (0.001 seconds).", flush=True)
            """
        )
        parent_code = textwrap.dedent(
            f"""\
            import subprocess
            import sys
            child = subprocess.Popen(
                [{str(fake_xctest)!r}, "-u", "-c", {child_code!r}],
                stdin=subprocess.DEVNULL,
                stdout=sys.stdout,
                stderr=sys.stderr,
            )
            sys.exit(child.wait())
            """
        )
        argv = [sys.executable, "-u", "-c", parent_code]
        job = self.make_job(
            state,
            "controlled-xctest-watchdog",
            "test",
            {"xctestStallSeconds": 0.05, "xctestStallWakeProbe": True},
            ["build"],
            job_state="running",
        )
        job.timeout = 5.0
        state.jobs[job.ticket] = job
        state.active_lanes = {"build": job.ticket}

        def prepare(_request: dict) -> tuple[list[str], list[str], Path, dict[str, str], float]:
            return argv, ["build"], root, os.environ.copy(), 5.0

        def controlled_commands(pids: object) -> dict[int, str]:
            candidates = sorted(int(pid) for pid in pids)
            return {
                pid: (str(fake_xctest) if pid == candidates[-1] else sys.executable)
                for pid in candidates
            }

        fake_tree = [
            {
                "pid": os.getpid(),
                "ppid": os.getppid(),
                "depth": 0,
                "startToken": "fixture-start",
                "command": str(fake_xctest),
            }
        ]
        with mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False), mock.patch.object(
            state.registry, "prepare", side_effect=prepare
        ), mock.patch.object(
            state,
            "_capture_xctest_stall_diagnostics",
            side_effect=lambda _job, diagnostic, _identity: diagnostic,
        ), mock.patch.object(
            state,
            "_xctest_process_snapshot_locked",
            return_value=((os.getpid(), "fixture-start"), fake_tree),
        ), mock.patch.object(state, "_signal_process_identity", return_value=True), mock.patch.object(
            state, "_wait_for_xctest_progress_after_probe", return_value=True
        ), mock.patch.object(conductor, "process_command_snapshot", side_effect=controlled_commands):
            state._run_job(job.ticket)

        self.assertEqual(job.state, "failed")
        self.assertEqual(job.exit_code, conductor.XCTEST_STALL_FAILURE_EXIT_CODE)
        self.assertTrue(job.measurement_invalid)
        self.assertEqual(len(job.diagnostics), 1)
        self.assertTrue(job.diagnostics[0]["stopSent"], job.diagnostics)
        self.assertTrue(job.diagnostics[0]["continueSent"], job.diagnostics)
        self.assertTrue(job.diagnostics[0]["progressResumed"], job.diagnostics)
        self.assertFalse(state._process_tree_alive_locked(job))

    def test_nonresponsive_watchdog_cleanup_escalates_once(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_watchdog_job(state)

        with mock.patch.object(state, "_terminate_process_group_locked") as terminate, mock.patch.object(
            state,
            "_wait_for_process_tree_exit_locked",
            side_effect=[True, True],
        ) as wait_for_exit, mock.patch.object(state, "_kill_process_group_locked") as kill:
            state._terminate_xctest_stalled_job(job)

        terminate.assert_called_once_with(job, reason="XCTest progress stall measurement invalid")
        kill.assert_called_once()
        self.assertEqual(wait_for_exit.call_count, 2)
        state._io_worker.join()
        self.assertIn("could not confirm descendant exit", job.log_path.read_text(encoding="utf-8"))

    def test_stall_diagnostic_file_is_bounded(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        path = state.paths.jobs_dir / "bounded.sample.txt"
        path.write_bytes(b"a" * 200)

        state._bound_diagnostic_file(path, max_bytes=80)

        data = path.read_bytes()
        self.assertLessEqual(len(data), 80)
        self.assertIn(b"conductor truncated", data)

    def test_default_test_cli_and_jobs_leave_watchdog_disabled(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        with mock.patch.object(conductor, "enqueue_and_maybe_wait", return_value=0) as enqueue:
            code = conductor.handle_real_operation(state.paths, "test", ["--filter", "ExampleTests"])

        self.assertEqual(code, 0)
        self.assertEqual(enqueue.call_args.args[2], {"filter": "ExampleTests"})
        job = self.make_job(state, "default-test", "test", {}, ["build"], job_state="running")
        self.assertFalse(state._xctest_watchdog_enabled(job))
        self.assertFalse(
            state._record_xctest_progress_locked(
                job,
                "Test Case '-[RepoPromptTests.ExampleTests testDefault]' started.\n",
                observed_at=1.0,
            )
        )
        self.assertIsNone(job.xctest_progress_deadline)

    def test_test_cli_forwards_test_product_for_focused_split_targets(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        with mock.patch.object(conductor, "enqueue_and_maybe_wait", return_value=0) as enqueue:
            code = conductor.handle_real_operation(
                state.paths,
                "test",
                ["--test-product", "RepoPromptWorkspaceTests", "--filter", "WorkspaceTests"],
            )

        self.assertEqual(code, 0)
        self.assertEqual(
            enqueue.call_args.args[2],
            {"filter": "WorkspaceTests", "testProduct": "RepoPromptWorkspaceTests"},
        )

        registry = conductor.OperationRegistry(state.paths.repo_root)
        root_argv, root_lanes, root_cwd, _env, _timeout = registry.prepare(
            {
                "operation": "test",
                "args": {"filter": "WorkspaceTests", "testProduct": "RepoPromptWorkspaceTests"},
            }
        )

        self.assertEqual(
            root_argv,
            ["swift", "test", "--test-product", "RepoPromptWorkspaceTests", "--filter", "WorkspaceTests"],
        )
        self.assertEqual(root_lanes, ["build"])
        self.assertEqual(root_cwd, state.paths.repo_root)

    def test_codex_packaging_environment_survives_client_snapshot_and_build_prepare(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = conductor.OperationRegistry(Path(tmp))
            with mock.patch.dict(
                os.environ,
                {
                    "REPOPROMPT_CODEX_ARCH": "all",
                    "REPOPROMPT_CODEX_CACHE_ROOT": "/tmp/repoprompt-codex-cache",
                    "REPOPROMPT_UNRELATED_BUILD_SETTING": "discard-me",
                },
                clear=False,
            ):
                snapshot = conductor.OperationRegistry.client_env_snapshot()

            self.assertEqual(snapshot["REPOPROMPT_CODEX_ARCH"], "all")
            self.assertEqual(
                snapshot["REPOPROMPT_CODEX_CACHE_ROOT"],
                "/tmp/repoprompt-codex-cache",
            )
            self.assertNotIn("REPOPROMPT_UNRELATED_BUILD_SETTING", snapshot)

            _argv, _lanes, _cwd, env, _timeout = registry.prepare(
                {
                    "operation": "build",
                    "args": {},
                    "env": snapshot,
                }
            )

        self.assertEqual(env["REPOPROMPT_CODEX_ARCH"], "all")
        self.assertEqual(
            env["REPOPROMPT_CODEX_CACHE_ROOT"],
            "/tmp/repoprompt-codex-cache",
        )
        self.assertNotIn("REPOPROMPT_UNRELATED_BUILD_SETTING", env)

    def test_codex_packaging_environment_reaches_release_package_prepare(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = conductor.OperationRegistry(Path(tmp))
            argv, lanes, _cwd, env, _timeout = registry.prepare(
                {
                    "operation": "release",
                    "args": {"subcommand": "package"},
                    "env": {
                        "REPOPROMPT_CODEX_ARCH": "all",
                        "REPOPROMPT_CODEX_CACHE_ROOT": "/tmp/release-codex-cache",
                    },
                }
            )

        self.assertEqual(Path(argv[0]).name, "package_app.sh")
        self.assertEqual(argv[1], "release")
        self.assertEqual(lanes, ["build", "debugArtifact", "release"])
        self.assertEqual(env["REPOPROMPT_CODEX_ARCH"], "all")
        self.assertEqual(env["REPOPROMPT_CODEX_CACHE_ROOT"], "/tmp/release-codex-cache")

    def test_test_gate_environment_survives_client_snapshot_and_job_prepare(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = conductor.OperationRegistry(Path(tmp))
            with mock.patch.dict(
                os.environ,
                {
                    "RPCE_ENABLE_BENCHMARK_TESTS": "1",
                    "RPCE_RUN_CODEMAP_E2E": "1",
                    "RPCE_RUN_SCALE_TESTS": "1",
                    "RP_RUN_SWIFT_CODEMAP_PIPELINE_BENCHMARK": "1",
                    "RP_RUN_TYPESCRIPT_CODEMAP_REFERENCE": "1",
                    "RP_TYPESCRIPT_CODEMAP_REFERENCE_MODE": "compare",
                    "RP_TYPESCRIPT_CODEMAP_TS_REFERENCE_PATH": "/tmp/typescript-reference.json",
                    "RP_TYPESCRIPT_CODEMAP_TSX_REFERENCE_PATH": "/tmp/tsx-reference.json",
                    "RP_SWIFT_CODEMAP_ALLOWED_REMOVED_CAPTURES": "type.class",
                    "RP_SWIFT_CODEMAP_REFERENCE_MODE": "compare",
                    "RP_SWIFT_CODEMAP_REFERENCE_PATH": "/tmp/reference.json",
                    "RPCE_UNRELATED_TEST_GATE": "1",
                },
                clear=False,
            ):
                snapshot = conductor.OperationRegistry.client_env_snapshot()

            self.assertEqual(snapshot["RPCE_ENABLE_BENCHMARK_TESTS"], "1")
            self.assertEqual(snapshot["RPCE_RUN_CODEMAP_E2E"], "1")
            self.assertEqual(snapshot["RPCE_RUN_SCALE_TESTS"], "1")
            self.assertEqual(snapshot["RP_RUN_SWIFT_CODEMAP_PIPELINE_BENCHMARK"], "1")
            self.assertEqual(snapshot["RP_RUN_TYPESCRIPT_CODEMAP_REFERENCE"], "1")
            self.assertEqual(snapshot["RP_TYPESCRIPT_CODEMAP_REFERENCE_MODE"], "compare")
            self.assertEqual(snapshot["RP_TYPESCRIPT_CODEMAP_TS_REFERENCE_PATH"], "/tmp/typescript-reference.json")
            self.assertEqual(snapshot["RP_TYPESCRIPT_CODEMAP_TSX_REFERENCE_PATH"], "/tmp/tsx-reference.json")
            self.assertEqual(snapshot["RP_SWIFT_CODEMAP_ALLOWED_REMOVED_CAPTURES"], "type.class")
            self.assertEqual(snapshot["RP_SWIFT_CODEMAP_REFERENCE_MODE"], "compare")
            self.assertEqual(snapshot["RP_SWIFT_CODEMAP_REFERENCE_PATH"], "/tmp/reference.json")
            self.assertNotIn("RPCE_UNRELATED_TEST_GATE", snapshot)

            _argv, _lanes, _cwd, env, _timeout = registry.prepare(
                {
                    "operation": "test",
                    "args": {"filter": "CodemapBindingEngineProjectionTests"},
                    "env": snapshot,
                }
            )

        self.assertEqual(env["RPCE_ENABLE_BENCHMARK_TESTS"], "1")
        self.assertEqual(env["RPCE_RUN_CODEMAP_E2E"], "1")
        self.assertEqual(env["RPCE_RUN_SCALE_TESTS"], "1")
        self.assertEqual(env["RP_RUN_SWIFT_CODEMAP_PIPELINE_BENCHMARK"], "1")
        self.assertEqual(env["RP_RUN_TYPESCRIPT_CODEMAP_REFERENCE"], "1")
        self.assertEqual(env["RP_TYPESCRIPT_CODEMAP_REFERENCE_MODE"], "compare")
        self.assertEqual(env["RP_TYPESCRIPT_CODEMAP_TS_REFERENCE_PATH"], "/tmp/typescript-reference.json")
        self.assertEqual(env["RP_TYPESCRIPT_CODEMAP_TSX_REFERENCE_PATH"], "/tmp/tsx-reference.json")
        self.assertEqual(env["RP_SWIFT_CODEMAP_ALLOWED_REMOVED_CAPTURES"], "type.class")
        self.assertEqual(env["RP_SWIFT_CODEMAP_REFERENCE_MODE"], "compare")
        self.assertEqual(env["RP_SWIFT_CODEMAP_REFERENCE_PATH"], "/tmp/reference.json")
        self.assertNotIn("RPCE_UNRELATED_TEST_GATE", env)

    def test_test_cli_forwards_watchdog_options_and_requires_threshold(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        with mock.patch.object(conductor, "enqueue_and_maybe_wait", return_value=0) as enqueue:
            code = conductor.handle_real_operation(
                state.paths,
                "test",
                [
                    "--filter",
                    "ExampleTests",
                    "--xctest-stall-seconds",
                    "12.5",
                    "--xctest-stall-wake-probe",
                ],
            )

        self.assertEqual(code, 0)
        self.assertEqual(
            enqueue.call_args.args[2],
            {
                "filter": "ExampleTests",
                "xctestStallSeconds": 12.5,
                "xctestStallWakeProbe": True,
            },
        )
        with self.assertRaisesRegex(conductor.ConductorError, "requires --xctest-stall-seconds"):
            conductor.handle_real_operation(state.paths, "test", ["--xctest-stall-wake-probe"])


class ProcessTreeCancellationTests(LifecycleTestCase):
    def wait_until(self, predicate, timeout: float = 5.0) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return True
            time.sleep(0.01)
        return bool(predicate())

    def process_identity_alive(self, pid: int, start_token: str) -> bool:
        snapshot = conductor.process_table_snapshot()
        if snapshot is None:
            return True
        record = snapshot.get(pid)
        return record is not None and record[1] == start_token

    def run_detached_descendant_fixture(self, termination: str) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        root = state.paths.repo_root
        parent_path = root / f"{termination}-parent.json"
        child_path = root / f"{termination}-child.json"
        child_code = textwrap.dedent(
            """\
            import json
            import os
            import signal
            import sys
            import time
            from pathlib import Path

            marker = Path(sys.argv[1])
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            temporary = marker.with_suffix(".tmp")
            temporary.write_text(json.dumps({
                "pid": os.getpid(),
                "ppid": os.getppid(),
                "pgid": os.getpgid(0),
                "sid": os.getsid(0),
            }), encoding="utf-8")
            temporary.replace(marker)
            while True:
                time.sleep(0.1)
            """
        )
        parent_code = textwrap.dedent(
            f"""\
            import json
            import os
            import subprocess
            import sys
            import time
            from pathlib import Path

            parent_marker = Path(sys.argv[1])
            child_marker = Path(sys.argv[2])
            child = subprocess.Popen(
                [sys.executable, "-u", "-c", {child_code!r}, str(child_marker)],
                stdin=subprocess.DEVNULL,
                stdout=sys.stdout,
                stderr=sys.stderr,
                start_new_session=True,
            )
            temporary = parent_marker.with_suffix(".tmp")
            temporary.write_text(json.dumps({{
                "pid": os.getpid(),
                "ppid": os.getppid(),
                "pgid": os.getpgid(0),
                "sid": os.getsid(0),
                "childPID": child.pid,
            }}), encoding="utf-8")
            temporary.replace(parent_marker)
            while True:
                time.sleep(0.1)
            """
        )
        argv = [sys.executable, "-u", "-c", parent_code, str(parent_path), str(child_path)]
        job = self.make_job(state, f"tree-{termination}", "test", {}, ["build"], job_state="running")
        job.timeout = 0.25 if termination == "timeout" else 30.0
        state.jobs[job.ticket] = job
        state.active_lanes = {"build": job.ticket}
        unrelated = subprocess.Popen(
            [sys.executable, "-u", "-c", "import time; time.sleep(30)"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )

        def cleanup_unrelated() -> None:
            if unrelated.poll() is None:
                unrelated.terminate()
                try:
                    unrelated.wait(timeout=1.0)
                except subprocess.TimeoutExpired:
                    unrelated.kill()
                    unrelated.wait(timeout=1.0)

        self.addCleanup(cleanup_unrelated)

        def prepare(_request: dict) -> tuple[list[str], list[str], Path, dict[str, str], float]:
            return argv, ["build"], root, os.environ.copy(), float(job.timeout or 30.0)

        with mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False), mock.patch.object(
            state.registry, "prepare", side_effect=prepare
        ), mock.patch.multiple(
            conductor,
            TERMINATE_GRACE_SECONDS=0.2,
            KILL_GRACE_SECONDS=1.0,
            PROCESS_TREE_POLL_SECONDS=0.02,
        ):
            runner = threading.Thread(target=state._run_job, args=(job.ticket,))
            runner.start()
            self.assertTrue(self.wait_until(lambda: parent_path.exists() and child_path.exists()), "fixture did not publish process identities")
            parent = json.loads(parent_path.read_text(encoding="utf-8"))
            child = json.loads(child_path.read_text(encoding="utf-8"))
            parent_pid = int(parent["pid"])
            child_pid = int(child["pid"])
            self.assertEqual(int(parent["childPID"]), child_pid)
            self.assertEqual(int(child["ppid"]), parent_pid)
            self.assertEqual(int(child["pgid"]), child_pid)
            self.assertNotEqual(int(parent["pgid"]), int(child["pgid"]))
            parent_start = conductor.process_start_token(parent_pid)
            child_start = conductor.process_start_token(child_pid)
            self.assertIsNotNone(parent_start)
            self.assertIsNotNone(child_start)

            if termination == "cancel":
                payload = state.job_cancel(job.ticket, None)
                self.assertTrue(payload["cancelRequested"])
            runner.join(timeout=5.0)

        self.assertFalse(runner.is_alive(), "job runner did not finish after bounded escalation")
        self.assertTrue(self.wait_until(lambda: not self.process_identity_alive(parent_pid, str(parent_start))))
        self.assertTrue(self.wait_until(lambda: not self.process_identity_alive(child_pid, str(child_start))))
        final_snapshot = conductor.process_table_snapshot()
        child_record = final_snapshot.get(child_pid)
        self.assertFalse(child_record is not None and child_record[1] == child_start and child_record[0] == 1, "descendant survived orphaned under PID 1")
        self.assertIsNone(unrelated.poll(), "unrelated process was signaled")
        self.assertNotIn(unrelated.pid, job.tracked_processes)
        registry = json.loads(state.paths.running_processes_path.read_text(encoding="utf-8"))
        self.assertEqual(registry["processes"], [])
        self.assertNotIn("build", state.active_lanes)
        if termination == "cancel":
            self.assertEqual(job.state, "canceled")
            self.assertEqual(job.exit_code, 130)
        else:
            self.assertEqual(job.state, "failed")
            self.assertEqual(job.exit_code, 124)
            self.assertTrue(job.timed_out)

    def test_cancel_terminates_descendant_that_created_a_new_session(self) -> None:
        self.run_detached_descendant_fixture("cancel")

    def test_timeout_uses_same_descendant_tree_cleanup(self) -> None:
        self.run_detached_descendant_fixture("timeout")


class SmokeOperationTests(unittest.TestCase):
    def test_execution_location_ui_smoke_resolves_process_by_numeric_pid_without_name_fallback(self) -> None:
        source = (SCRIPT_DIR / "smoke_agent_execution_location_popover.sh").read_text(encoding="utf-8")

        self.assertIn("repeat with candidateProcess in application processes", source)
        self.assertIn("set candidatePID to (unix id of candidateProcess) as integer", source)
        self.assertIn("if candidatePID is targetPID then", source)
        self.assertIn("if ((unix id of candidateProcess) as integer) is targetPID then return", source)
        self.assertIn("set frontmost to true", source)
        self.assertIn("key code 53", source)
        self.assertIn("entire contents of window windowIndex whose value of attribute", source)
        self.assertIn("repeat with windowIndex from 1 to 1", source)
        self.assertNotIn("first application process whose unix id is targetPID", source)
        self.assertNotIn("process appProcessName", source)
        self.assertNotIn("contents of candidateProcess", source)
        self.assertNotIn("my targetPID", source)
        self.assertNotIn("on firstElementWithIdentifier", source)

    def test_manage_worktree_list_stage_runs_after_tree_roots_before_agent_manage(self) -> None:
        calls: list[tuple[str, list[str]]] = []

        def record_command(name: str, argv: list[str], *_args: object, **_kwargs: object) -> tuple[int, str, str]:
            calls.append((name, argv))
            return 0, "", ""

        with mock.patch.object(conductor, "require_debug_cli", return_value="/tmp/rpce-cli-debug"), mock.patch.object(
            conductor, "run_operation_command", side_effect=record_command
        ):
            code = conductor.operation_smoke(Path.cwd(), {"windowId": "7", "workspace": "test-workspace"})

        self.assertEqual(code, 0)
        self.assertEqual(
            calls,
            [
                ("windows", ["/tmp/rpce-cli-debug", "-e", "windows"]),
                ("workspace switch", ["/tmp/rpce-cli-debug", "-w", "7", "-e", "workspace switch test-workspace"]),
                ("tree roots", ["/tmp/rpce-cli-debug", "-w", "7", "-e", "tree --type roots"]),
                ("manage_worktree list", ["/tmp/rpce-cli-debug", "-w", "7", "-e", "manage_worktree op=list"]),
                (
                    "agent_manage roles",
                    [
                        "/tmp/rpce-cli-debug",
                        "-w",
                        "7",
                        "-c",
                        "agent_manage",
                        "-j",
                        '{"op": "list_agents", "roles_only": true, "_windowID": 7}',
                    ],
                ),
            ],
        )

    def test_execution_location_ui_smoke_runs_after_worktree_readiness_stages(self) -> None:
        calls: list[tuple[str, list[str], dict[str, object]]] = []

        def record_command(name: str, argv: list[str], *_args: object, **kwargs: object) -> tuple[int, str, str]:
            calls.append((name, argv, kwargs))
            return 0, "", ""

        with mock.patch.object(conductor, "require_debug_cli", return_value="/tmp/rpce-cli-debug"), mock.patch.object(
            conductor, "find_debug_app_pids", return_value=["4242"]
        ), mock.patch.dict(
            os.environ,
            {
                "REPOPROMPT_EXECUTION_LOCATION_UI_SMOKE_WAIT": "2",
                "REPOPROMPT_EXECUTION_LOCATION_UI_SMOKE_CYCLES": "2",
            },
            clear=False,
        ), mock.patch.object(
            conductor, "run_operation_command", side_effect=record_command
        ):
            code = conductor.operation_smoke(
                Path("/tmp/repo"),
                {"windowId": "7", "workspace": "test-workspace", "executionLocationUI": True},
            )

        self.assertEqual(code, 0)
        self.assertEqual(
            [name for name, _argv, _kwargs in calls],
            [
                "windows",
                "workspace switch",
                "tree roots",
                "manage_worktree list",
                "agent_manage roles",
                "execution location UI smoke",
            ],
        )
        self.assertEqual(
            calls[-1][1],
            ["/tmp/repo/Scripts/smoke_agent_execution_location_popover.sh", "4242"],
        )
        self.assertEqual(calls[-1][2]["timeout"], 184.0)

    def test_execution_location_ui_smoke_requires_one_exact_debug_app(self) -> None:
        with mock.patch.object(conductor, "require_debug_cli", return_value="/tmp/rpce-cli-debug"), mock.patch.object(
            conductor, "find_debug_app_pids", return_value=[]
        ), mock.patch.object(conductor, "run_operation_command", return_value=(0, "", "")) as run_command, contextlib.redirect_stdout(
            io.StringIO()
        ) as output:
            code = conductor.operation_smoke(
                Path("/tmp/repo"),
                {"windowId": "7", "workspace": "test-workspace", "executionLocationUI": True},
            )

        self.assertEqual(code, 1)
        self.assertEqual(run_command.call_count, 5)
        self.assertIn("requires exactly one running RepoPrompt debug app", output.getvalue())

    def test_structured_smoke_calls_route_to_requested_window_with_fake_cli(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            log_path = root / "cli-calls.jsonl"
            fake_cli = root / "rpce-cli-debug"
            fake_cli.write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env python3
                    import json
                    import os
                    import sys

                    args = sys.argv[1:]
                    with open(os.environ["FAKE_CLI_LOG"], "a", encoding="utf-8") as log:
                        log.write(json.dumps(args) + "\\n")
                    if "-c" in args and args[args.index("-c") + 1] == "agent_run":
                        payload = json.loads(args[args.index("-j") + 1])
                        if payload["op"] == "start":
                            print(json.dumps({"session_id": "smoke-session"}))
                    """
                ),
                encoding="utf-8",
            )
            fake_cli.chmod(0o755)

            with mock.patch.dict(os.environ, {"FAKE_CLI_LOG": str(log_path)}), mock.patch.object(
                conductor, "require_debug_cli", return_value=str(fake_cli)
            ):
                code = conductor.operation_smoke(
                    root,
                    {"windowId": 7, "workspace": "test-workspace", "agentRun": True, "agentTimeout": 5},
                )

            calls = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]

        self.assertEqual(code, 0)
        self.assertEqual(
            calls[:4],
            [
                ["-e", "windows"],
                ["-w", "7", "-e", "workspace switch test-workspace"],
                ["-w", "7", "-e", "tree --type roots"],
                ["-w", "7", "-e", "manage_worktree op=list"],
            ],
        )
        structured_calls = calls[4:]
        self.assertEqual(
            [(call[call.index("-c") + 1], json.loads(call[call.index("-j") + 1])["op"]) for call in structured_calls],
            [("agent_manage", "list_agents"), ("agent_run", "start"), ("agent_run", "wait")],
        )
        for call in structured_calls:
            self.assertEqual(call[:3], ["-w", "7", "-c"])
            payload = json.loads(call[call.index("-j") + 1])
            self.assertEqual(payload["_windowID"], 7)

    def test_launch_smoke_uses_exact_embedded_helper_and_ignores_other_resolvers(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "RepoPrompt.app"
            helper = app / "Contents" / "MacOS" / "repoprompt-mcp"
            helper.parent.mkdir(parents=True)
            helper.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
            helper.chmod(0o755)
            calls: list[tuple[str, list[str]]] = []

            def record_command(name: str, argv: list[str], *_args: object, **_kwargs: object) -> tuple[int, str, str]:
                calls.append((name, argv))
                return 0, "", ""

            with mock.patch.object(conductor, "debug_app_bundle_path", return_value=app), mock.patch.object(
                conductor, "require_debug_cli"
            ) as fallback, mock.patch.object(
                conductor, "operation_debug_app_build_then_launch", return_value=0
            ) as launch, mock.patch.object(conductor, "run_operation_command", side_effect=record_command):
                code = conductor.operation_smoke(Path(tmp), {"launch": True, "windowId": 1, "workspace": "fixture"})

        self.assertEqual(code, 0)
        fallback.assert_not_called()
        launch.assert_called_once_with(Path(tmp), {"appArgs": []})
        for name, argv in calls:
            self.assertEqual(argv[0], str(helper.resolve()), name)

    def test_embedded_helper_resolution_rejects_symlink_escape(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app = root / "RepoPrompt.app"
            helper = app / "Contents" / "MacOS" / "repoprompt-mcp"
            helper.parent.mkdir(parents=True)
            outside = root / "outside-helper"
            outside.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
            outside.chmod(0o755)
            helper.symlink_to(outside)

            with self.assertRaises(conductor.ConductorError):
                conductor.resolve_embedded_helper(app)

    def test_packaged_app_smoke_delegates_to_roundtrip_script_without_launch_resolution(self) -> None:
        with mock.patch.object(conductor, "run_operation_command", return_value=(0, "", "")) as run, mock.patch.object(
            conductor, "require_debug_cli"
        ) as fallback:
            code = conductor.operation_smoke(
                Path("/tmp/repo"),
                {"packagedApp": "/tmp/App.app", "artifactManifest": "/tmp/manifest.json"},
            )

        self.assertEqual(code, 0)
        fallback.assert_not_called()
        argv = run.call_args.args[1]
        self.assertEqual(Path(argv[0]).name, "smoke_packaged_mcp_roundtrip.sh")
        self.assertEqual(argv[-2:], ["Conductor packaged app", "/tmp/manifest.json"])


class RunScriptTransitionTests(unittest.TestCase):
    def test_guarded_failed_relaunch_does_not_inspect_or_stop_before_packaging_succeeds(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            scripts = root / "Scripts"
            scripts.mkdir()
            run_script = scripts / "run.sh"
            shutil.copy2(SCRIPT_DIR / "run.sh", run_script)
            shutil.copy2(SCRIPT_DIR / "conductor.py", scripts / "conductor.py")
            run_script.chmod(0o755)
            package_script = scripts / "package_app.sh"
            package_script.write_text("#!/usr/bin/env bash\necho package failed\nexit 23\n", encoding="utf-8")
            package_script.chmod(0o755)
            marker = root / "process-helper-invoked"
            helper = scripts / "debug_app_process.py"
            helper.write_text(
                textwrap.dedent(
                    """\
                    from pathlib import Path
                    import os

                    class ProcessIdentityError(Exception):
                        pass

                    def matching_processes(_executable):
                        Path(os.environ['PROCESS_HELPER_MARKER']).write_text('invoked')
                        return []

                    def terminate_matching_processes(_executable):
                        Path(os.environ['PROCESS_HELPER_MARKER']).write_text('invoked')
                        return []
                    """
                ),
                encoding="utf-8",
            )
            env = os.environ.copy()
            env.update(
                {
                    "PROCESS_HELPER_MARKER": str(marker),
                    "REPOPROMPT_GUARD_DELAYED_LAUNCH": "1",
                    "REPOPROMPT_DEV_HEAVY_SLOTS": "8",
                }
            )

            result = subprocess.run(["bash", str(run_script)], env=env, text=True, capture_output=True, timeout=10)
            helper_invoked = marker.exists()

        self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
        self.assertIn("package staged debug app", result.stdout)
        self.assertNotIn("Stopping existing RepoPrompt CE debug app instance", result.stdout)
        self.assertFalse(helper_invoked)

    def test_direct_run_packages_before_waiting_for_live_lock_then_activates(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            scripts = root / "Scripts"
            scripts.mkdir()
            run_script = scripts / "run.sh"
            shutil.copy2(SCRIPT_DIR / "run.sh", run_script)
            shutil.copy2(SCRIPT_DIR / "conductor.py", scripts / "conductor.py")
            run_script.chmod(0o755)
            event_log = root / "events.log"
            launched_marker = root / "launched"
            app_bundle = root / "DebugApps" / "RepoPrompt.app"
            package_script = scripts / "package_app.sh"
            package_script.write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env bash
                    set -e
                    echo package:$REPOPROMPT_DEBUG_APP_BUNDLE >> "$EVENT_LOG"
                    mkdir -p "$REPOPROMPT_DEBUG_APP_BUNDLE/Contents/MacOS"
                    printf binary > "$REPOPROMPT_DEBUG_APP_BUNDLE/Contents/MacOS/RepoPrompt"
                    chmod +x "$REPOPROMPT_DEBUG_APP_BUNDLE/Contents/MacOS/RepoPrompt"
                    """
                ),
                encoding="utf-8",
            )
            package_script.chmod(0o755)
            helper = scripts / "debug_app_process.py"
            helper.write_text(
                textwrap.dedent(
                    """\
                    import os
                    from pathlib import Path

                    class ProcessIdentityError(Exception):
                        pass

                    def _state():
                        return "launched" if Path(os.environ["LAUNCHED_MARKER"]).exists() else "stopped"

                    def _log(operation, executable):
                        with Path(os.environ["EVENT_LOG"]).open("a", encoding="utf-8") as handle:
                            handle.write(f"{operation}:{_state()}:{executable}\\n")

                    def matching_processes(executable):
                        _log("list", executable)
                        return [4242] if _state() == "launched" else []

                    def terminate_matching_processes(executable):
                        _log("terminate", executable)
                        return []
                    """
                ),
                encoding="utf-8",
            )
            bin_dir = root / "bin"
            bin_dir.mkdir()
            (bin_dir / "codesign").write_text("#!/usr/bin/env bash\necho TeamIdentifier=TEST >&2\n", encoding="utf-8")
            (bin_dir / "plutil").write_text("#!/usr/bin/env bash\necho memory\n", encoding="utf-8")
            (bin_dir / "open").write_text(
                "#!/usr/bin/env bash\necho open >> \"$EVENT_LOG\"\ntouch \"$LAUNCHED_MARKER\"\n",
                encoding="utf-8",
            )
            for command in ["codesign", "plutil", "open"]:
                (bin_dir / command).chmod(0o755)
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{bin_dir}:{env.get('PATH', '')}",
                    "EVENT_LOG": str(event_log),
                    "LAUNCHED_MARKER": str(launched_marker),
                    "REPOPROMPT_DEBUG_APP_BUNDLE": str(app_bundle),
                    "REPOPROMPT_DEV_HEAVY_SLOTS": "8",
                }
            )
            lock_ready = threading.Event()
            release_lock = threading.Event()

            def hold_live_lock() -> None:
                metadata = conductor.display_lock_metadata(
                    lock_kind="live-app",
                    ticket="direct-run-test",
                    operation="test-live-lock",
                    operation_label="test live lock",
                    repo_root=root,
                )
                with conductor.machine_exclusive_lock(conductor.live_app_lock_path(), metadata, "live-app lock"):
                    with event_log.open("a", encoding="utf-8") as handle:
                        handle.write("lock-start\n")
                    lock_ready.set()
                    release_lock.wait(timeout=5.0)
                    with event_log.open("a", encoding="utf-8") as handle:
                        handle.write("lock-release\n")

            holder = threading.Thread(target=hold_live_lock, daemon=True)
            holder.start()
            self.assertTrue(lock_ready.wait(timeout=2.0))
            proc = subprocess.Popen(["bash", str(run_script)], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            deadline = time.monotonic() + 5.0
            while time.monotonic() < deadline:
                rows = event_log.read_text(encoding="utf-8").splitlines() if event_log.exists() else []
                if any(row.startswith("package:") for row in rows):
                    break
                time.sleep(0.02)
            rows_before_release = event_log.read_text(encoding="utf-8").splitlines()
            self.assertTrue(any(row.startswith("package:") for row in rows_before_release), rows_before_release)
            self.assertFalse(any(row.startswith(("list:", "terminate:")) for row in rows_before_release), rows_before_release)
            release_lock.set()
            stdout, stderr = proc.communicate(timeout=10)
            holder.join(timeout=2.0)
            rows = event_log.read_text(encoding="utf-8").splitlines()

        self.assertEqual(proc.returncode, 0, stdout + stderr)
        self.assertLess(
            rows.index("lock-release"),
            next(index for index, row in enumerate(rows) if row.startswith(("list:", "terminate:"))),
        )
        self.assertIn("Activated staged debug app bundle", stdout)

    def test_successful_relaunch_uses_debug_executable_for_stop_and_readiness(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            scripts = root / "Scripts"
            scripts.mkdir()
            run_script = scripts / "run.sh"
            shutil.copy2(SCRIPT_DIR / "run.sh", run_script)
            shutil.copy2(SCRIPT_DIR / "conductor.py", scripts / "conductor.py")
            run_script.chmod(0o755)
            event_log = root / "events.log"
            launched_marker = root / "launched"
            app_bundle = root / "DebugApps" / "RepoPrompt.app"
            app_executable = app_bundle / "Contents" / "MacOS" / "RepoPrompt"
            package_script = scripts / "package_app.sh"
            package_script.write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env bash
                    set -e
                    echo package:$REPOPROMPT_DEBUG_APP_BUNDLE >> "$EVENT_LOG"
                    mkdir -p "$REPOPROMPT_DEBUG_APP_BUNDLE/Contents/MacOS"
                    printf binary > "$REPOPROMPT_DEBUG_APP_BUNDLE/Contents/MacOS/RepoPrompt"
                    chmod +x "$REPOPROMPT_DEBUG_APP_BUNDLE/Contents/MacOS/RepoPrompt"
                    """
                ),
                encoding="utf-8",
            )
            package_script.chmod(0o755)
            helper = scripts / "debug_app_process.py"
            helper.write_text(
                textwrap.dedent(
                    """\
                    import os
                    from pathlib import Path

                    class ProcessIdentityError(Exception):
                        pass

                    def _state():
                        return "launched" if Path(os.environ["LAUNCHED_MARKER"]).exists() else "stopped"

                    def _log(operation, executable):
                        with Path(os.environ["EVENT_LOG"]).open("a", encoding="utf-8") as handle:
                            handle.write(f"{operation}:{_state()}:{executable}\\n")

                    def matching_processes(executable):
                        _log("list", executable)
                        return [4242] if _state() == "launched" else []

                    def terminate_matching_processes(executable):
                        _log("terminate", executable)
                        return []
                    """
                ),
                encoding="utf-8",
            )
            bin_dir = root / "bin"
            bin_dir.mkdir()
            (bin_dir / "codesign").write_text("#!/usr/bin/env bash\necho TeamIdentifier=TEST >&2\n", encoding="utf-8")
            (bin_dir / "plutil").write_text("#!/usr/bin/env bash\necho memory\n", encoding="utf-8")
            (bin_dir / "open").write_text(
                "#!/usr/bin/env bash\necho open >> \"$EVENT_LOG\"\ntouch \"$LAUNCHED_MARKER\"\n",
                encoding="utf-8",
            )
            for command in ["codesign", "plutil", "open"]:
                (bin_dir / command).chmod(0o755)
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{bin_dir}:{env.get('PATH', '')}",
                    "EVENT_LOG": str(event_log),
                    "LAUNCHED_MARKER": str(launched_marker),
                    "REPOPROMPT_DEBUG_APP_BUNDLE": str(app_bundle),
                    "REPOPROMPT_DEV_HEAVY_SLOTS": "8",
                }
            )

            result = subprocess.run(["bash", str(run_script), "--demo"], env=env, text=True, capture_output=True, timeout=20)
            events = event_log.read_text(encoding="utf-8").splitlines()
            activated_executable_exists = app_executable.exists()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        expected_suffix = f":{app_executable}"
        self.assertTrue(events[0].startswith("package:"), events)
        self.assertIn("/.staging/", events[0])
        self.assertNotIn(str(app_bundle), events[0])
        open_index = events.index("open")
        self.assertGreater(open_index, 1, events)
        self.assertTrue(all(event == f"list:stopped:{app_executable}" for event in events[1:open_index]), events)
        self.assertEqual(events[open_index + 1], f"list:launched:{app_executable}")
        self.assertTrue(all(event.endswith(expected_suffix) for event in events if event.startswith(("list:", "terminate:"))))
        source = (SCRIPT_DIR / "run.sh").read_text(encoding="utf-8")
        self.assertTrue(activated_executable_exists)
        self.assertIn("Activated staged debug app bundle", result.stdout)
        self.assertIn("Observed launched RepoPrompt CE debug PID(s): 4242", result.stdout)
        self.assertNotIn("pgrep", source)
        self.assertNotIn("pkill", source)


class AppStatusIdentityTests(unittest.TestCase):
    def make_bundle(self, bundle: Path, marker: str = "binary") -> None:
        executable = bundle / "Contents" / "MacOS" / "RepoPrompt"
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_text(marker, encoding="utf-8")
        executable.chmod(0o755)

    def test_activate_staged_debug_bundle_replaces_live_and_cleans_staging(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            live = root / "DebugApps" / "RepoPrompt.app"
            staged = root / "DebugApps" / ".staging" / "token" / "RepoPrompt.app"
            self.make_bundle(live, "old")
            self.make_bundle(staged, "new")

            conductor.activate_staged_debug_bundle(staged, live)

            self.assertEqual((live / "Contents" / "MacOS" / "RepoPrompt").read_text(encoding="utf-8"), "new")
            self.assertFalse(staged.parent.exists())
            self.assertFalse(any(live.parent.glob(".RepoPrompt.app.previous.*")))

    def test_staged_launch_stop_failure_preserves_live_and_cleans_staging(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            live = root / "DebugApps" / "RepoPrompt.app"
            staged = root / "DebugApps" / ".staging" / "token" / "RepoPrompt.app"
            self.make_bundle(live, "old")
            self.make_bundle(staged, "new")
            with mock.patch.dict(os.environ, {"REPOPROMPT_DEBUG_APP_BUNDLE": str(live)}), mock.patch.object(
                conductor, "_operation_app_stop_unlocked", return_value=7
            ), mock.patch.object(conductor, "run_operation_command") as run, contextlib.redirect_stdout(io.StringIO()):
                code = conductor.operation_app_launch_existing(root, {"stagedBundle": str(staged), "appArgs": []})

            self.assertEqual(code, 7)
            self.assertEqual((live / "Contents" / "MacOS" / "RepoPrompt").read_text(encoding="utf-8"), "old")
            self.assertFalse(staged.parent.exists())
            run.assert_not_called()

    def test_launch_existing_requires_bundle_and_does_not_build(self) -> None:
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(
            os.environ,
            {"REPOPROMPT_DEBUG_APP_BUNDLE": str(Path(tmp) / "missing" / "RepoPrompt.app")},
        ), mock.patch.object(conductor, "package_debug_app_under_heavy") as package, contextlib.redirect_stdout(output):
            code = conductor.operation_app_launch_existing(Path(tmp), {"appArgs": []})

        self.assertEqual(code, 1)
        package.assert_not_called()
        self.assertIn("existing debug app bundle is not launchable", output.getvalue())

    def test_split_build_failure_performs_no_lifecycle_action(self) -> None:
        with mock.patch.object(conductor, "package_debug_app_under_heavy", return_value=(23, None)) as package, mock.patch.object(
            conductor, "operation_app_launch_existing"
        ) as launch, contextlib.redirect_stdout(io.StringIO()) as output:
            code = conductor.operation_debug_app_build_then_launch(Path("/tmp/repo"), {"appArgs": []})

        self.assertEqual(code, 23)
        package.assert_called_once()
        launch.assert_not_called()
        self.assertIn("no live bundle or stop/launch lifecycle action", output.getvalue())

    def test_status_treats_missing_debug_executable_as_not_installed(self) -> None:
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(
            os.environ,
            {"REPOPROMPT_DEBUG_APP_BUNDLE": str(Path(tmp) / "missing" / "RepoPrompt.app")},
        ), mock.patch.object(conductor, "run_operation_command", return_value=(0, "", "")), contextlib.redirect_stdout(output):
            code = conductor.operation_app_status(Path("/tmp/repo"))

        self.assertEqual(code, 0)
        self.assertIn("Running matching debug app PIDs: none", output.getvalue())
        self.assertIn("Bundle exists: no", output.getvalue())

    def test_status_reports_only_path_validated_debug_pids(self) -> None:
        output = io.StringIO()
        with mock.patch.object(conductor, "find_debug_app_pids", return_value=["501"]), mock.patch.object(
            conductor, "run_operation_command", return_value=(0, "", "")
        ), mock.patch.dict(os.environ, {"REPOPROMPT_DEBUG_APP_BUNDLE": "/tmp/missing-debug/RepoPrompt.app"}), contextlib.redirect_stdout(
            output
        ):
            code = conductor.operation_app_status(Path("/tmp/repo"))

        self.assertEqual(code, 0)
        self.assertIn("Running matching debug app PIDs: 501", output.getvalue())

    def test_status_identity_failure_is_reported_as_unknown(self) -> None:
        output = io.StringIO()
        with mock.patch.object(
            conductor,
            "find_debug_app_pids",
            side_effect=conductor.ProcessIdentityError("identity unavailable"),
        ), mock.patch.object(conductor, "run_operation_command") as cli_status, contextlib.redirect_stdout(output):
            code = conductor.operation_app_status(Path("/tmp/repo"))

        self.assertEqual(code, 1)
        self.assertIn("Running matching debug app PIDs: unknown", output.getvalue())
        cli_status.assert_not_called()


class StopConfirmationTests(unittest.TestCase):
    def test_delayed_guard_exceeds_run_launch_observation_window(self) -> None:
        self.assertGreater(conductor.APP_STOP_DELAYED_LAUNCH_GUARD_SECONDS, 10.0)
        self.assertGreater(conductor.APP_STOP_DELAYED_LAUNCH_CONFIRM_TIMEOUT_SECONDS, conductor.APP_STOP_DELAYED_LAUNCH_GUARD_SECONDS)

    @contextlib.contextmanager
    def patched_timing(self):
        current_time = 0.0

        def fake_now() -> float:
            return current_time

        def fake_sleep(seconds: float) -> None:
            nonlocal current_time
            current_time += seconds

        with mock.patch.multiple(
            conductor,
            APP_STOP_POLL_SECONDS=0.001,
            APP_STOP_QUIET_SECONDS=0.002,
            APP_STOP_DELAYED_LAUNCH_GUARD_SECONDS=0.004,
            APP_STOP_CONFIRM_TIMEOUT_SECONDS=0.02,
            APP_STOP_DELAYED_LAUNCH_CONFIRM_TIMEOUT_SECONDS=0.02,
            now=fake_now,
        ), mock.patch.object(conductor.time, "sleep", side_effect=fake_sleep):
            yield

    def test_missing_debug_executable_is_confirmed_already_stopped(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, self.patched_timing(), mock.patch.dict(
            os.environ,
            {"REPOPROMPT_DEBUG_APP_BUNDLE": str(Path(tmp) / "missing" / "RepoPrompt.app")},
        ), contextlib.redirect_stdout(io.StringIO()) as output:
            code = conductor.operation_app_stop(Path.cwd(), {})

        self.assertEqual(code, 0)
        self.assertIn("already stopped", output.getvalue())

    def test_already_stopped_is_confirmed_without_termination(self) -> None:
        with self.patched_timing(), mock.patch.object(conductor, "find_debug_app_pids", return_value=[]), mock.patch.object(
            conductor, "terminate_debug_app_processes"
        ) as terminate, contextlib.redirect_stdout(io.StringIO()):
            code = conductor.operation_app_stop(Path.cwd(), {})

        self.assertEqual(code, 0)
        terminate.assert_not_called()

    def test_running_process_is_terminated_then_confirmed_absent(self) -> None:
        probes = iter([["101"], [], [], [], []])
        with self.patched_timing(), mock.patch.object(conductor, "find_debug_app_pids", side_effect=lambda: next(probes, [])), mock.patch.object(
            conductor, "terminate_debug_app_processes", return_value=["101"]
        ) as terminate, contextlib.redirect_stdout(io.StringIO()):
            code = conductor.operation_app_stop(Path.cwd(), {})

        self.assertEqual(code, 0)
        terminate.assert_called_once_with()

    def test_guarded_stop_terminates_delayed_process_appearance(self) -> None:
        calls = 0

        def probe() -> list[str]:
            nonlocal calls
            calls += 1
            return ["202"] if calls == 2 else []

        with self.patched_timing(), mock.patch.object(conductor, "find_debug_app_pids", side_effect=probe), mock.patch.object(
            conductor, "terminate_debug_app_processes", return_value=["202"]
        ) as terminate, contextlib.redirect_stdout(io.StringIO()):
            code = conductor.operation_app_stop(Path.cwd(), {"guardDelayedLaunch": True})

        self.assertEqual(code, 0)
        terminate.assert_called_once_with()

    def test_identity_failure_aborts_without_name_based_fallback(self) -> None:
        with self.patched_timing(), mock.patch.object(
            conductor,
            "find_debug_app_pids",
            side_effect=conductor.ProcessIdentityError("identity unavailable"),
        ), mock.patch.object(conductor, "terminate_debug_app_processes") as terminate, contextlib.redirect_stdout(io.StringIO()):
            code = conductor.operation_app_stop(Path.cwd(), {})

        self.assertEqual(code, 1)
        terminate.assert_not_called()

    def test_persistent_process_fails_confirmation_without_force_kill(self) -> None:
        with self.patched_timing(), mock.patch.object(conductor, "find_debug_app_pids", return_value=["303"]), mock.patch.object(
            conductor, "terminate_debug_app_processes", return_value=["303"]
        ) as terminate, contextlib.redirect_stdout(io.StringIO()):
            code = conductor.operation_app_stop(Path.cwd(), {})

        self.assertEqual(code, 1)
        self.assertGreater(terminate.call_count, 0)


if __name__ == "__main__":
    unittest.main()
