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
    def test_guarded_failed_relaunch_does_not_stop_existing_app_before_packaging_succeeds(self) -> None:
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
            bin_dir = root / "bin"
            bin_dir.mkdir()
            (bin_dir / "pgrep").write_text("#!/usr/bin/env bash\necho 4242\n", encoding="utf-8")
            (bin_dir / "pkill").write_text("#!/usr/bin/env bash\necho invoked > \"$PKILL_MARKER\"\n", encoding="utf-8")
            (bin_dir / "pgrep").chmod(0o755)
            (bin_dir / "pkill").chmod(0o755)
            marker = root / "pkill-invoked"
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{bin_dir}:{env.get('PATH', '')}",
                    "PKILL_MARKER": str(marker),
                    "REPOPROMPT_GUARD_DELAYED_LAUNCH": "1",
                }
            )

            result = subprocess.run(["bash", str(run_script)], env=env, text=True, capture_output=True, timeout=2)
            pkill_invoked = marker.exists()

        self.assertEqual(result.returncode, 23)
        self.assertIn("Packaging debug app", result.stdout)
        self.assertNotIn("Stopping existing RepoPrompt instance", result.stdout)
        self.assertFalse(pkill_invoked)


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

    def test_already_stopped_is_confirmed_without_termination(self) -> None:
        with self.patched_timing(), mock.patch.object(conductor, "find_repoprompt_pids", return_value=[]), mock.patch.object(
            conductor, "run_operation_command"
        ) as terminate, contextlib.redirect_stdout(io.StringIO()):
            code = conductor.operation_app_stop(Path.cwd(), {})

        self.assertEqual(code, 0)
        terminate.assert_not_called()

    def test_running_process_is_terminated_then_confirmed_absent(self) -> None:
        probes = iter([["101"], [], [], [], []])
        with self.patched_timing(), mock.patch.object(conductor, "find_repoprompt_pids", side_effect=lambda: next(probes, [])), mock.patch.object(
            conductor, "run_operation_command", return_value=(0, "", "")
        ) as terminate, contextlib.redirect_stdout(io.StringIO()):
            code = conductor.operation_app_stop(Path.cwd(), {})

        self.assertEqual(code, 0)
        terminate.assert_called_once()

    def test_guarded_stop_terminates_delayed_process_appearance(self) -> None:
        calls = 0

        def probe() -> list[str]:
            nonlocal calls
            calls += 1
            return ["202"] if calls == 2 else []

        with self.patched_timing(), mock.patch.object(conductor, "find_repoprompt_pids", side_effect=probe), mock.patch.object(
            conductor, "run_operation_command", return_value=(0, "", "")
        ) as terminate, contextlib.redirect_stdout(io.StringIO()):
            code = conductor.operation_app_stop(Path.cwd(), {"guardDelayedLaunch": True})

        self.assertEqual(code, 0)
        terminate.assert_called_once()

    def test_persistent_process_fails_confirmation_without_force_kill(self) -> None:
        with self.patched_timing(), mock.patch.object(conductor, "find_repoprompt_pids", return_value=["303"]), mock.patch.object(
            conductor, "run_operation_command", return_value=(0, "", "")
        ) as terminate, contextlib.redirect_stdout(io.StringIO()):
            code = conductor.operation_app_stop(Path.cwd(), {})

        self.assertEqual(code, 1)
        self.assertGreater(terminate.call_count, 0)


if __name__ == "__main__":
    unittest.main()
