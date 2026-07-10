#!/usr/bin/env python3
"""Focused tests for conductor interactive app lifecycle intent."""

from __future__ import annotations

import contextlib
import errno
import fcntl
import io
import json
import os
import shutil
import signal
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


class LifecycleTestCase(unittest.TestCase):
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
        return tmp, conductor.DaemonState(paths)

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


class LifecycleQueueTests(LifecycleTestCase):
    def test_protocol_version_bump_replaces_older_daemons(self) -> None:
        self.assertEqual(conductor.PROTOCOL_VERSION, 10)

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

    def test_app_relaunch_delegates_split_internal_runner_with_live_lane_and_timeout(self) -> None:
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
        self.assertEqual(lanes, ["liveApp"])
        self.assertEqual(timeout, conductor.MEDIUM_TIMEOUT_SECONDS)
        self.assertIn("app_launch_existing", launch_existing_argv[-1])
        self.assertEqual(launch_existing_lanes, ["liveApp"])
        self.assertEqual(conductor.operation_display_name("app", {"subcommand": "relaunch"}), "app relaunch")

    def test_guardrails_delegates_aggregator_without_lanes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo_root = Path(tmp)
            registry = conductor.OperationRegistry(repo_root)
            argv, lanes, cwd, _env, _timeout = registry.prepare({"operation": "guardrails", "args": {}})

        self.assertEqual(Path(argv[0]).name, "guardrails.sh")
        self.assertEqual(Path(argv[0]).parent.name, "Scripts")
        self.assertEqual(lanes, [])
        self.assertEqual(cwd, repo_root)

    def test_release_artifact_delegates_release_script_with_release_lanes_and_timeout(self) -> None:
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
        fake_stdout = mock.Mock()
        fake_stdout.readline.side_effect = [b""]
        fake_process = mock.Mock()
        fake_process.pid = os.getpid()
        fake_process.stdout = fake_stdout
        fake_process.wait.return_value = 0

        with mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False), mock.patch.object(
            conductor.subprocess, "Popen", return_value=fake_process
        ) as popen, mock.patch.object(
            conductor, "process_table_snapshot", return_value={os.getpid(): (os.getppid(), "fixture-start")}
        ), mock.patch.object(state, "_schedule_locked"), mock.patch.object(state, "_refresh_output_summary"):
            state._run_job(job.ticket)

        job_launch = next(call for call in popen.call_args_list if call.kwargs.get("stdin") == subprocess.DEVNULL)
        self.assertEqual(job_launch.kwargs["stdout"], subprocess.PIPE)
        self.assertEqual(job_launch.kwargs["stderr"], subprocess.STDOUT)
        self.assertEqual(state.jobs[job.ticket].state, "completed")

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
        self.assertFalse(conductor.pid_alive(grandchild_pid))

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

        with mock.patch.object(state, "_terminate_process_group_locked") as terminate, mock.patch.object(
            state, "_schedule_locked"
        ), mock.patch.object(conductor.threading, "Thread"):
            payload = state.enqueue({"operation": "app", "args": {"subcommand": "stop"}})

        stop = state.jobs[payload["ticket"]]
        self.assertTrue(old_run.cancel_requested)
        self.assertEqual(old_run.state, "running")
        self.assertEqual(state.active_lanes["liveApp"], old_run.ticket)
        self.assertTrue(stop.args["guardDelayedLaunch"])
        terminate.assert_called_once()

    def test_superseded_job_without_pid_is_signaled_after_delayed_assignment_then_escalated(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        old_run = self.make_job(state, "delayed-pid-run", "run", {}, ["build", "debugArtifact", "liveApp"], "running")
        state.jobs[old_run.ticket] = old_run
        state.active_lanes = {lane: old_run.ticket for lane in old_run.lanes}
        real_thread = threading.Thread

        with mock.patch.object(state, "_terminate_process_group_locked") as terminate, mock.patch.object(
            state, "_kill_process_group_locked"
        ) as kill, mock.patch.object(
            state, "_wait_for_process_tree_exit_locked", side_effect=[True, False]
        ), mock.patch.object(state, "_schedule_locked"), mock.patch.object(
            conductor, "TERMINATE_GRACE_SECONDS", 0.01
        ), mock.patch.object(conductor.threading, "Thread") as thread_factory:
            state.enqueue({"operation": "app", "args": {"subcommand": "stop"}})
            terminate.assert_not_called()
            target = thread_factory.call_args.kwargs["target"]
            args = thread_factory.call_args.kwargs["args"]
            self.assertFalse(args[2])
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
                if job.state in conductor.TERMINAL_STATES:
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
        return conductor.DaemonState(paths)

    def test_global_heavy_slot_serializes_build_lane_jobs_across_daemons(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        shared_socket_parent = root / "shared"
        shared_socket_parent.mkdir()
        state_a = self.make_state_for_global_slot(root, "daemon-a", shared_socket_parent)
        state_b = self.make_state_for_global_slot(root, "daemon-b", shared_socket_parent)

        lock_root = root / "machine-locks"
        with mock.patch.object(conductor, "GLOBAL_HEAVY_SLOT_POLL_SECONDS", 0.01), mock.patch.object(
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
        with mock.patch.object(conductor, "GLOBAL_HEAVY_SLOT_POLL_SECONDS", 0.01), mock.patch.object(
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

    def test_output_transport_selection_is_pty_only_for_watchdog_non_list_tests(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        jobs = [
            ("build", {}, "pipe"),
            ("test", {}, "pipe"),
            ("provider-test", {}, "pipe"),
            ("test", {"list": True, "xctestStallSeconds": 5.0}, "pipe"),
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
        fds = [transport.master_fd, transport.slave_fd]
        self.assertTrue(all(isinstance(fd, int) for fd in fds))
        process = mock.Mock(stdout=None)

        transport.attach_process(process)
        transport.close_reader()
        transport.close_all()

        self.assert_fds_closed([int(fd) for fd in fds if fd is not None])

    def test_pty_eio_is_eof_without_waiting_for_popen_to_reap_child(self) -> None:
        transport = conductor.ProcessOutputTransport(kind="pty", master_fd=123)
        process = mock.Mock()

        with mock.patch.object(conductor.os, "read", side_effect=OSError(errno.EIO, "fixture EIO")):
            self.assertEqual(transport.read_chunk(process), b"")

        process.poll.assert_not_called()
        transport.master_fd = None

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
        transport = mock.Mock()
        transport.read_chunk.side_effect = chunks
        process = mock.Mock()
        log = io.BytesIO()

        state._read_process_output(job.ticket, process, log, transport)

        self.assertEqual(log.getvalue(), b"".join(chunks[:-1]))
        self.assertEqual(job.xctest_progress_sequence, 4)
        self.assertEqual(job.xctest_last_progress_test, second)
        self.assertEqual(job.xctest_last_progress_action, "skipped")
        self.assertIsNone(job.xctest_current_test)
        self.assertEqual(job.xctest_previous_test, second)
        self.assertEqual(len(job.tail), 4)
        self.assertTrue(job.tail[0].endswith("\r\n"))
        self.assertFalse(job.tail[-1].endswith("\n"))
        transport.close_reader.assert_called_once_with()

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
        real_openpty = os.openpty

        def tracking_openpty() -> tuple[int, int]:
            pair = real_openpty()
            opened_fds.extend(pair)
            return pair

        def prepare(_request: dict) -> tuple[list[str], list[str], Path, dict[str, str], float]:
            return argv, ["build"], root, os.environ.copy(), 5.0

        with mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False), mock.patch.object(
            state.registry, "prepare", side_effect=prepare
        ), mock.patch.object(
            conductor.os, "openpty", side_effect=tracking_openpty
        ), mock.patch.object(
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
        self.assert_fds_closed(opened_fds)

    def test_pty_descriptors_close_when_process_launch_fails(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_watchdog_job(state)
        opened_fds: list[int] = []
        real_openpty = os.openpty

        def tracking_openpty() -> tuple[int, int]:
            pair = real_openpty()
            opened_fds.extend(pair)
            return pair

        with mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False), mock.patch.object(
            conductor.os, "openpty", side_effect=tracking_openpty
        ), mock.patch.object(
            conductor.subprocess,
            "Popen",
            side_effect=OSError("fixture launch failure"),
        ), mock.patch.object(state, "_schedule_locked"), mock.patch.object(state, "_refresh_output_summary"):
            state._run_job(job.ticket)

        self.assertEqual(job.state, "failed")
        self.assertIn("fixture launch failure", job.error or "")
        self.assert_fds_closed(opened_fds)

    def test_output_transport_cleanup_runs_for_success_timeout_and_cancellation(self) -> None:
        for terminal_path in ["success", "timeout", "cancellation"]:
            with self.subTest(terminal_path=terminal_path):
                tmp, state = self.make_state()
                self.addCleanup(tmp.cleanup)
                job = self.make_watchdog_job(state)
                job.ticket = f"cleanup-{terminal_path}"
                job.log_path = state.paths.jobs_dir / f"{job.ticket}.log"
                state.jobs = {job.ticket: job}
                transport = mock.Mock()
                transport.kind = "pty"
                transport.popen_stdout = 101
                transport.popen_stderr = 101
                transport.read_chunk.return_value = b""
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

                transport.attach_process.assert_called_once_with(fake_process)
                transport.close_reader.assert_called()
                transport.close_all.assert_called_once_with()
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

    def test_test_list_cli_preserves_build_lane_and_package_roots(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        with mock.patch.object(conductor, "enqueue_and_maybe_wait", return_value=0) as enqueue:
            code = conductor.handle_real_operation(state.paths, "test", ["--list"])

        self.assertEqual(code, 0)
        self.assertEqual(enqueue.call_args.args[2], {"list": True})

        registry = conductor.OperationRegistry(state.paths.repo_root)
        root_argv, root_lanes, root_cwd, _env, _timeout = registry.prepare(
            {"operation": "test", "args": {"list": True}}
        )
        provider_argv, provider_lanes, provider_cwd, _env, _timeout = registry.prepare(
            {"operation": "provider-test", "args": {"list": True}}
        )

        self.assertEqual(root_argv, ["swift", "test", "list"])
        self.assertEqual(root_lanes, ["build"])
        self.assertEqual(root_cwd, state.paths.repo_root)
        self.assertEqual(provider_argv, ["swift", "test", "list"])
        self.assertEqual(provider_lanes, ["build"])
        self.assertEqual(
            provider_cwd,
            state.paths.repo_root / "Packages" / "RepoPromptAgentProviders",
        )

    def test_test_list_rejects_filters_and_stall_diagnostics(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            conductor.handle_real_operation(state.paths, "test", ["--list", "--filter", "ExampleTests"])
        with self.assertRaisesRegex(conductor.ConductorError, "cannot be combined"):
            conductor.handle_real_operation(
                state.paths,
                "provider-test",
                ["--list", "--xctest-stall-seconds", "10"],
            )
        with self.assertRaisesRegex(conductor.ConductorError, "cannot be combined"):
            conductor.handle_real_operation(
                state.paths,
                "test",
                ["--list", "--test-product", "RepoPromptWorkspaceTests"],
            )

        registry = conductor.OperationRegistry(state.paths.repo_root)
        with self.assertRaisesRegex(conductor.ConductorError, "cannot be combined with a filter"):
            registry.prepare(
                {
                    "operation": "test",
                    "args": {"list": True, "filter": "ExampleTests"},
                }
            )
        with self.assertRaisesRegex(conductor.ConductorError, "cannot be combined with --test-product"):
            registry.prepare(
                {
                    "operation": "test",
                    "args": {"list": True, "testProduct": "RepoPromptWorkspaceTests"},
                }
            )

    def test_test_gate_environment_survives_client_snapshot_and_job_prepare(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = conductor.OperationRegistry(Path(tmp))
            with mock.patch.dict(
                os.environ,
                {
                    "RPCE_ENABLE_BENCHMARK_TESTS": "1",
                    "RPCE_RUN_CODEMAP_E2E": "1",
                    "RPCE_RUN_SCALE_TESTS": "1",
                    "RPCE_UNRELATED_TEST_GATE": "1",
                },
                clear=False,
            ):
                snapshot = conductor.OperationRegistry.client_env_snapshot()

            self.assertEqual(snapshot["RPCE_ENABLE_BENCHMARK_TESTS"], "1")
            self.assertEqual(snapshot["RPCE_RUN_CODEMAP_E2E"], "1")
            self.assertEqual(snapshot["RPCE_RUN_SCALE_TESTS"], "1")
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
        record = conductor.process_table_snapshot().get(pid)
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
            marker.write_text(json.dumps({
                "pid": os.getpid(),
                "ppid": os.getppid(),
                "pgid": os.getpgid(0),
                "sid": os.getsid(0),
            }), encoding="utf-8")
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
            parent_marker.write_text(json.dumps({{
                "pid": os.getpid(),
                "ppid": os.getppid(),
                "pgid": os.getpgid(0),
                "sid": os.getsid(0),
                "childPID": child.pid,
            }}), encoding="utf-8")
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
