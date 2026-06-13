#!/usr/bin/env python3
"""Focused tests for conductor interactive app lifecycle intent."""

from __future__ import annotations

import contextlib
import io
import os
import shutil
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
        self.assertEqual(conductor.PROTOCOL_VERSION, 5)

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

    def test_app_relaunch_delegates_run_script_with_run_lanes_and_timeout(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = conductor.OperationRegistry(Path(tmp))
            argv, lanes, _cwd, _env, timeout = registry.prepare(
                {"operation": "app", "args": {"subcommand": "relaunch", "appArgs": ["--demo"]}}
            )
            _guarded_argv, _guarded_lanes, _guarded_cwd, guarded_env, _guarded_timeout = registry.prepare(
                {"operation": "app", "args": {"subcommand": "relaunch", "appArgs": [], "guardDelayedLaunch": True}}
            )

        self.assertEqual(Path(argv[-2]).name, "run.sh")
        self.assertEqual(Path(argv[-2]).parent.name, "Scripts")
        self.assertEqual(argv[-1], "--demo")
        self.assertEqual(lanes, ["build", "debugArtifact", "liveApp"])
        self.assertEqual(timeout, conductor.MEDIUM_TIMEOUT_SECONDS)
        self.assertEqual(guarded_env["REPOPROMPT_GUARD_DELAYED_LAUNCH"], "1")
        self.assertEqual(conductor.operation_display_name("app", {"subcommand": "relaunch"}), "app relaunch")

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

        with mock.patch.object(conductor.subprocess, "Popen", return_value=fake_process) as popen, mock.patch.object(
            state, "_schedule_locked"
        ), mock.patch.object(state, "_refresh_output_summary"):
            state._run_job(job.ticket)

        self.assertEqual(popen.call_args.kwargs["stdin"], subprocess.DEVNULL)
        self.assertEqual(popen.call_args.kwargs["stdout"], subprocess.PIPE)
        self.assertEqual(popen.call_args.kwargs["stderr"], subprocess.STDOUT)
        self.assertEqual(state.jobs[job.ticket].state, "completed")

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
            os.close(0)
            state._run_job(ticket)
            job = state.jobs[ticket]
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
        ) as kill, mock.patch.object(state, "_schedule_locked"), mock.patch.object(
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
                    ["/tmp/rpce-cli-debug", "-w", "7", "-c", "agent_manage", "-j", '{"op": "list_agents", "roles_only": true}'],
                ),
            ],
        )


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
            ) as fallback, mock.patch.object(conductor, "run_operation_command", side_effect=record_command):
                code = conductor.operation_smoke(Path(tmp), {"launch": True, "windowId": 1, "workspace": "fixture"})

        self.assertEqual(code, 0)
        fallback.assert_not_called()
        self.assertEqual(calls[0][0], "launch debug app")
        for name, argv in calls[1:]:
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
            run_script.chmod(0o755)
            package_script = scripts / "package_app.sh"
            package_script.write_text("#!/usr/bin/env bash\necho package failed\nexit 23\n", encoding="utf-8")
            package_script.chmod(0o755)
            marker = root / "process-helper-invoked"
            helper = scripts / "debug_app_process.py"
            helper.write_text(
                "from pathlib import Path\nimport os\nPath(os.environ['PROCESS_HELPER_MARKER']).write_text('invoked')\n",
                encoding="utf-8",
            )
            env = os.environ.copy()
            env.update(
                {
                    "PROCESS_HELPER_MARKER": str(marker),
                    "REPOPROMPT_GUARD_DELAYED_LAUNCH": "1",
                }
            )

            result = subprocess.run(["bash", str(run_script)], env=env, text=True, capture_output=True, timeout=2)
            helper_invoked = marker.exists()

        self.assertEqual(result.returncode, 23)
        self.assertIn("Packaging debug app", result.stdout)
        self.assertNotIn("Stopping existing RepoPrompt CE debug app instance", result.stdout)
        self.assertFalse(helper_invoked)

    def test_successful_relaunch_uses_debug_executable_for_stop_and_readiness(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            scripts = root / "Scripts"
            scripts.mkdir()
            run_script = scripts / "run.sh"
            shutil.copy2(SCRIPT_DIR / "run.sh", run_script)
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
                    echo package >> "$EVENT_LOG"
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
                    import sys
                    from pathlib import Path

                    operation = sys.argv[1]
                    executable = sys.argv[sys.argv.index("--executable") + 1]
                    state = "launched" if Path(os.environ["LAUNCHED_MARKER"]).exists() else "stopped"
                    with Path(os.environ["EVENT_LOG"]).open("a", encoding="utf-8") as handle:
                        handle.write(f"{operation}:{state}:{executable}\\n")
                    if operation == "list" and state == "launched":
                        print("4242")
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
                }
            )

            result = subprocess.run(["bash", str(run_script), "--demo"], env=env, text=True, capture_output=True, timeout=5)
            events = event_log.read_text(encoding="utf-8").splitlines()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        expected_suffix = f":{app_executable}"
        self.assertEqual(events[0], "package")
        self.assertEqual(events[1], f"terminate:stopped:{app_executable}")
        self.assertEqual(events[2], f"list:stopped:{app_executable}")
        self.assertEqual(events[3], "open")
        self.assertEqual(events[4], f"list:launched:{app_executable}")
        self.assertTrue(all(event.endswith(expected_suffix) for event in events if event.startswith(("list:", "terminate:"))))
        source = (SCRIPT_DIR / "run.sh").read_text(encoding="utf-8")
        self.assertIn("Observed launched RepoPrompt CE debug PID(s): 4242", result.stdout)
        self.assertNotIn("pgrep", source)
        self.assertNotIn("pkill", source)


class AppStatusIdentityTests(unittest.TestCase):
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
