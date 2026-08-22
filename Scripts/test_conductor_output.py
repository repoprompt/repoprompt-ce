#!/usr/bin/env python3
"""Focused tests for conductor concise output summaries."""

from __future__ import annotations

import contextlib
import io
import json
import os
import socket
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from typing import Optional
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import conductor  # noqa: E402


def summarize(operation: str, state: str, exit_code: Optional[int], lines: list[str]) -> dict:
    return conductor.OutputSummarizer.summarize_lines(operation, {}, state, exit_code, False, lines)


def section(summary: dict, title: str) -> list[str]:
    for item in summary.get("sections", []):
        if item.get("title") == title:
            return item.get("lines") or []
    return []


def app_payload(subcommand: str, state: str, exit_code: int, lines: list[str], **extra: object) -> dict:
    payload = {
        "ticket": "ticket",
        "operation": "app",
        "operationLabel": f"app {subcommand}",
        "args": {"subcommand": subcommand},
        "state": state,
        "exitCode": exit_code,
        "timedOut": False,
        "logPath": "/tmp/job.log",
        "outputSummary": conductor.OutputSummarizer.summarize_lines(
            "app", {"subcommand": subcommand}, state, exit_code, False, lines
        ),
    }
    payload.update(extra)
    return payload


def rendered_terminal_output(payload: dict) -> str:
    with contextlib.redirect_stdout(io.StringIO()) as output:
        conductor.print_terminal_job_output(payload)
    return output.getvalue()


class OutputSummarizerTests(unittest.TestCase):
    def test_success_package_summary_omits_raw_build_noise(self) -> None:
        lines = ["==> Building RepoPrompt\n"]
        lines.extend(f"CompileSwift noisy file {index}\n" for index in range(200))
        lines.append("Created: /tmp/RepoPrompt.app\n")

        summary = summarize("build", "completed", 0, lines)

        self.assertIn("Created: /tmp/RepoPrompt.app", section(summary, "Artifacts"))
        rendered = "\n".join(line for item in summary["sections"] for line in item["lines"])
        self.assertNotIn("CompileSwift noisy file", rendered)

    def test_swift_compiler_failure_extracts_file_error_and_context(self) -> None:
        lines = [
            "==> Building\n",
            "previous context one\n",
            "previous context two\n",
            "Sources/Foo.swift:10:5: error: cannot find 'x' in scope\n",
            "let y = x\n",
            "    ^\n",
        ]

        summary = summarize("swift-build", "failed", 1, lines)
        swift_errors = section(summary, "Swift compiler errors")

        self.assertTrue(any("Sources/Foo.swift:10:5: error" in line for line in swift_errors))
        self.assertIn("previous context two", swift_errors)
        self.assertIn("let y = x", swift_errors)

    def test_xctest_failure_extracts_failing_test(self) -> None:
        summary = summarize(
            "test",
            "failed",
            1,
            [
                "Test Case 'RepoPromptTests.FooTests.testBar' failed (0.1 seconds)\n",
                "Executed 1 test, with 1 failure (0 unexpected) in 0.1 seconds\n",
            ],
        )

        test_failures = section(summary, "Test failures")
        self.assertTrue(any("FooTests.testBar" in line for line in test_failures))
        self.assertTrue(any("Executed 1 test" in line for line in test_failures))

    def test_style_findings_extract_swiftlint_lines(self) -> None:
        summary = summarize(
            "lint",
            "failed",
            1,
            [
                "Running SwiftLint\n",
                "Sources/Foo.swift:12:3: warning: Todo Violation: TODOs should be resolved\n",
                "ERROR: Missing required Swift style tools\n",
            ],
        )

        findings = section(summary, "Style findings")
        self.assertTrue(any("SwiftLint" in line for line in findings))
        self.assertTrue(any("Sources/Foo.swift:12:3: warning" in line for line in findings))

    def test_timeout_lines_are_prioritized(self) -> None:
        summary = summarize(
            "test",
            "failed",
            124,
            ["timed out after 300.0s\n", "terminating process group: timed out after 300.0s\n"],
        )

        timeout_lines = section(summary, "Timeout or cancellation")
        self.assertTrue(any("timed out after 300.0s" in line for line in timeout_lines))
        self.assertTrue(any("terminating process group" in line for line in timeout_lines))

    def test_progress_line_selection_filters_noise_and_caps_output(self) -> None:
        lines = ["CompileSwift noisy file\n", "==> Build\n"]
        lines.extend(f"Created: /tmp/artifact-{index}\n" for index in range(20))
        lines.append("plain final noise\n")

        selected = conductor.select_progress_lines("build", lines)

        self.assertLessEqual(len(selected), conductor.PROGRESS_MAX_LINES_PER_POLL)
        self.assertIn("==> Build", selected)
        self.assertTrue(any("Created: /tmp/artifact-" in line for line in selected))
        self.assertFalse(any("CompileSwift noisy file" in line for line in selected))
        self.assertFalse(any("plain final noise" in line for line in selected))

    def test_app_lifecycle_summary_and_progress_prioritize_confirmed_transition(self) -> None:
        lines = [
            "==> Stopping existing RepoPrompt CE debug app instance\n",
            "==> Waiting for existing RepoPrompt CE debug app process to exit\n",
            "RepoPrompt CE debug app stop confirmed.\n",
            "==> Launching /tmp/RepoPrompt.app\n",
            "==> Confirming launched RepoPrompt CE debug app process\n",
            "Observed launched RepoPrompt CE debug PID(s): 123\n",
        ]

        summary = summarize("run", "completed", 0, lines)
        lifecycle = section(summary, "App lifecycle")
        titles = [item["title"] for item in summary["sections"]]
        progress = conductor.select_progress_lines(
            "run",
            ["RepoPrompt CE debug app stop confirmed.\n", "Observed launched RepoPrompt CE debug PID(s): 123\n"],
        )

        self.assertIn("RepoPrompt CE debug app stop confirmed.", lifecycle)
        self.assertIn("Observed launched RepoPrompt CE debug PID(s): 123", lifecycle)
        self.assertTrue(summary["launchLifecycle"]["transitionStarted"])
        self.assertTrue(summary["launchLifecycle"]["launchRequested"])
        self.assertTrue(summary["launchLifecycle"]["launchConfirmed"])
        self.assertLess(titles.index("App lifecycle"), titles.index("Phases"))
        self.assertIn("RepoPrompt CE debug app stop confirmed.", progress)
        self.assertIn("Observed launched RepoPrompt CE debug PID(s): 123", progress)

    def test_app_operation_display_name_is_precise(self) -> None:
        self.assertEqual(conductor.operation_display_name("app", {"subcommand": "stop"}), "app stop")
        self.assertEqual(conductor.operation_display_name("app", {"subcommand": "relaunch"}), "app relaunch")

    def test_failed_relaunch_before_transition_reports_safe_rebuild_failure_and_source_edit_guidance(self) -> None:
        payload = app_payload(
            "relaunch",
            "failed",
            1,
            [
                "==> Packaging debug app\n",
                "error: input file '/tmp/Sources/Foo.swift' was modified during the build\n",
            ],
        )

        summary = payload["outputSummary"]
        rendered = rendered_terminal_output(payload)

        self.assertFalse(summary["launchLifecycle"]["transitionStarted"])
        self.assertTrue(summary["launchLifecycle"]["sourceChangedDuringBuild"])
        self.assertIn("Rebuild/package failed before this relaunch ticket reached app stop/open.", rendered)
        self.assertIn("This ticket did not stop or reopen RepoPrompt.", rendered)
        self.assertIn("source files changed during the build", rendered)
        self.assertIn("retry after edits settle", rendered)
        self.assertNotIn("superseded", rendered)

    def test_failed_relaunch_after_transition_advises_status_instead_of_preservation(self) -> None:
        payload = app_payload(
            "relaunch",
            "failed",
            1,
            [
                "==> Packaging debug app\n",
                "==> Stopping existing RepoPrompt CE debug app instance\n",
                "ERROR: open failed\n",
            ],
        )

        rendered = rendered_terminal_output(payload)

        self.assertTrue(payload["outputSummary"]["launchLifecycle"]["transitionStarted"])
        self.assertIn("failed after this ticket began app stop/open lifecycle work", rendered)
        self.assertIn("Check app status before retrying.", rendered)
        self.assertNotIn("did not stop or reopen", rendered)

    def test_canceled_lifecycle_output_distinguishes_supersession_from_cancellation(self) -> None:
        superseded = rendered_terminal_output(
            app_payload(
                "relaunch",
                "canceled",
                130,
                ["terminating process group: superseded by app stop replacement\n"],
                supersededByOperation="app stop",
                supersededByTicket="replacement",
            )
        )
        superseded_stop = rendered_terminal_output(
            app_payload(
                "stop",
                "canceled",
                130,
                ["job superseded before start by app relaunch replacement\n"],
                supersededByOperation="app relaunch",
                supersededByTicket="replacement",
            )
        )
        canceled = rendered_terminal_output(app_payload("stop", "canceled", 130, ["job canceled before start\n"]))

        self.assertIn("superseded by newer app stop intent (ticket replacement)", superseded)
        self.assertIn("superseded by newer app relaunch intent (ticket replacement)", superseded_stop)
        self.assertIn("This app stop ticket was canceled before completion.", canceled)
        self.assertNotIn("superseded", canceled)

    def test_failed_relaunch_recomputes_legacy_summary_for_lifecycle_classification(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "job.log"
            log.write_text(
                "==> Packaging debug app\nerror: input file '/tmp/Foo.swift' was modified during the build\n",
                encoding="utf-8",
            )
            payload = {
                "ticket": "ticket",
                "operation": "app",
                "operationLabel": "app relaunch",
                "args": {"subcommand": "relaunch"},
                "state": "failed",
                "exitCode": 1,
                "timedOut": False,
                "logPath": str(log),
                "outputSummary": {"headline": "failed with exit code 1", "sections": []},
            }

            summary = conductor.output_summary_for_payload(payload)
            enriched = conductor.payload_with_output_summary(payload)

        self.assertTrue(summary["launchLifecycle"]["sourceChangedDuringBuild"])
        self.assertFalse(summary["launchLifecycle"]["transitionStarted"])
        self.assertTrue(enriched["outputSummary"]["launchLifecycle"]["sourceChangedDuringBuild"])
        self.assertFalse(enriched["outputSummary"]["launchLifecycle"]["transitionStarted"])

    def test_huge_log_is_capped(self) -> None:
        lines = [f"Sources/Foo.swift:{index}:1: error: boom {index}\n" for index in range(500)]
        summary = summarize("swift-build", "failed", 1, lines)

        rendered_lines = [line for item in summary["sections"] for line in item["lines"]]
        rendered_chars = sum(len(line) for line in rendered_lines)
        self.assertLessEqual(len(rendered_lines), conductor.SUMMARY_FAILURE_MAX_LINES)
        self.assertLessEqual(rendered_chars, conductor.SUMMARY_MAX_CHARS)
        self.assertTrue(summary["truncated"] or summary["omittedLineCount"] > 0)

    def test_lowercase_warning_at_start_is_counted_and_shown(self) -> None:
        summary = summarize(
            "swift-build",
            "completed",
            0,
            [
                "warning: cannot find user version number for module 'Dependency'\n",
                "Sources/Foo.swift:10:5: warning: unused variable\n",
            ],
        )

        self.assertEqual(summary["warningCount"], 2)
        warnings = section(summary, "Warnings")
        self.assertEqual(len(warnings), 1)
        self.assertIn("cannot find user version number", warnings[0])

    def test_summary_version_and_duration_are_included(self) -> None:
        summary = summarize("build", "completed", 0, ["==> Build\n"])

        self.assertEqual(summary["version"], conductor.SUMMARY_VERSION)
        self.assertIn("summaryDurationSeconds", summary)
        self.assertIsInstance(summary["summaryDurationSeconds"], float)
        self.assertGreaterEqual(summary["summaryDurationSeconds"], 0.0)

    def test_minimal_summary_version_and_duration_are_included(self) -> None:
        summary = conductor.OutputSummarizer._minimal_summary("build", "failed", 1, "note")

        self.assertEqual(summary["version"], conductor.SUMMARY_VERSION)
        self.assertIn("summaryDurationSeconds", summary)
        self.assertEqual(summary["summaryDurationSeconds"], 0.0)

    def test_ansi_and_long_lines_are_cleaned(self) -> None:
        long_error = "\x1b[31mERROR: " + ("x" * 1000) + "\x1b[0m\n"
        summary = summarize("build", "failed", 1, [long_error])
        highlights = section(summary, "Failure highlights")

        self.assertEqual(len(highlights), 1)
        self.assertNotIn("\x1b", highlights[0])
        self.assertLessEqual(len(highlights[0]), conductor.SUMMARY_LINE_MAX_CHARS)

    def test_summarize_file_preserves_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "job.log"
            log.write_text("==> Package\nCreated: /tmp/App.app\n", encoding="utf-8")
            summary = conductor.OutputSummarizer.summarize_file(
                "build", {}, "completed", 0, False, log
            )
        self.assertIn("Created: /tmp/App.app", section(summary, "Artifacts"))

    def test_phase_summary_keeps_recent_phases(self) -> None:
        lines = [f"==> Phase {index}\n" for index in range(25)]
        summary = summarize("build", "failed", 1, lines)
        phases = section(summary, "Phases")

        self.assertNotIn("==> Phase 0", phases)
        self.assertIn("==> Phase 24", phases)
        self.assertLessEqual(len(phases), 20)

    def test_generic_failure_includes_recent_output(self) -> None:
        summary = summarize(
            "build",
            "failed",
            1,
            ["setup\n", "ERROR: command failed\n", "tail detail one\n", "tail detail two\n"],
        )

        self.assertIn("ERROR: command failed", section(summary, "Failure highlights"))
        self.assertIn("tail detail two", section(summary, "Recent output"))

    def test_payload_with_output_summary_adds_client_side_json_fallback_without_log_tail(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "job.log"
            log.write_text("==> Package\nCreated: /tmp/App.app\n", encoding="utf-8")
            payload = {
                "ticket": "ticket",
                "operation": "build",
                "args": {},
                "state": "completed",
                "exitCode": 0,
                "timedOut": False,
                "logPath": str(log),
                "logTail": [f"line {index}\n" for index in range(40)],
            }

            enriched = conductor.payload_with_output_summary(payload)

        self.assertIsNot(enriched, payload)
        self.assertIn("outputSummary", enriched)
        self.assertIn("Created: /tmp/App.app", section(enriched["outputSummary"], "Artifacts"))
        self.assertNotIn("logTail", enriched)
        self.assertEqual(str(log), enriched["logPath"])

    def test_payload_with_output_summary_can_preserve_trimmed_log_tail_for_compatibility(self) -> None:
        payload = {
            "ticket": "ticket",
            "operation": "build",
            "args": {},
            "state": "completed",
            "exitCode": 0,
            "timedOut": False,
            "outputSummary": {"headline": "completed successfully", "sections": []},
            "logTail": [f"line {index}\n" for index in range(40)],
        }

        enriched = conductor.payload_with_output_summary(payload, include_log_tail=True)

        self.assertEqual(len(enriched["logTail"]), conductor.LOG_TAIL_LINES)
        self.assertEqual(enriched["logTail"][0], "line 10\n")

    def test_payload_with_output_summary_drops_existing_tail_when_summary_is_present(self) -> None:
        payload = {
            "ticket": "ticket",
            "operation": "build",
            "state": "completed",
            "exitCode": 0,
            "outputSummary": {"headline": "completed successfully", "sections": []},
            "logTail": ["redundant raw tail\n"],
        }

        enriched = conductor.payload_with_output_summary(payload)

        self.assertIn("outputSummary", enriched)
        self.assertNotIn("logTail", enriched)

    def test_job_payload_exposes_additive_process_timing_and_lifecycle_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            diagnostic = root / "stall.sample.txt"
            job = conductor.Job(
                ticket="ticket",
                request_key=None,
                fingerprint="fingerprint",
                operation="test",
                args={},
                lanes=["build"],
                timeout=None,
                verbose=False,
                env={},
                created_at=10.0,
                started_at=12.5,
                finished_at=20.0,
                process_started_at=13.0,
                process_finished_at=19.25,
                progress_transport="pty",
                xctest_progress_sequence=17,
                xctest_last_progress_test="RepoPromptTests.ExampleTests.testProgress",
                xctest_last_progress_action="started",
                xctest_last_progress_observed_at=18.75,
                log_path=root / "ticket.log",
                state="completed",
                exit_code=0,
                diagnostic_paths=[diagnostic],
            )

            payload = job.to_payload()

        self.assertEqual(payload["queuedAt"], 10.0)
        self.assertEqual(payload["processStartedAt"], 13.0)
        self.assertEqual(payload["processFinishedAt"], 19.25)
        self.assertEqual(payload["queueWaitSeconds"], 2.5)
        self.assertEqual(payload["executionSeconds"], 6.25)
        self.assertFalse(payload["measurementInvalid"])
        self.assertEqual(payload["progressTransport"], "pty")
        self.assertEqual(payload["progressSequence"], 17)
        self.assertEqual(payload["lastProgressTest"], "RepoPromptTests.ExampleTests.testProgress")
        self.assertEqual(payload["lastProgressAction"], "started")
        self.assertEqual(payload["lastProgressObservedAt"], 18.75)
        self.assertEqual(payload["diagnosticPaths"], [str(diagnostic)])

    def test_terminal_job_status_attaches_missing_output_summary(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
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
            log = jobs_dir / "ticket.log"
            log.write_text("==> Package\nCreated: /tmp/App.app\n", encoding="utf-8")
            state = conductor.DaemonState(paths)
            state.jobs["ticket"] = conductor.Job(
                ticket="ticket",
                request_key=None,
                fingerprint="fingerprint",
                operation="build",
                args={},
                lanes=[],
                timeout=None,
                verbose=False,
                env={},
                created_at=conductor.now(),
                log_path=log,
                state="completed",
                finished_at=conductor.now(),
                exit_code=0,
                result_summary="completed successfully",
            )

            payload = state.job_status("ticket", None)

        self.assertIn("outputSummary", payload)
        self.assertIn("Created: /tmp/App.app", section(payload["outputSummary"], "Artifacts"))

    def test_json_full_log_is_rejected(self) -> None:
        with self.assertRaises(conductor.ConductorError):
            conductor.split_operation_flags(["--json", "--full-log"])

    def test_async_full_log_is_rejected(self) -> None:
        with self.assertRaises(conductor.ConductorError):
            conductor.split_operation_flags(["--async", "--full-log"])

    def test_job_list_omits_output_summary(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
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
            state.jobs["ticket"] = conductor.Job(
                ticket="ticket",
                request_key=None,
                fingerprint="fingerprint",
                operation="build",
                args={},
                lanes=[],
                timeout=None,
                verbose=False,
                env={},
                created_at=conductor.now(),
                log_path=jobs_dir / "ticket.log",
                state="completed",
                output_summary={"headline": "completed successfully", "sections": []},
            )

            payload = state.list_jobs(None)

        self.assertNotIn("outputSummary", payload["jobs"][0])
        state._output_pump.close()

    def test_repeated_findings_coalesce_without_unbounded_seen_state(self) -> None:
        summary = summarize("build", "failed", 1, ["ERROR: repeated failure\n"] * 50)

        failures = section(summary, "Failure highlights")
        self.assertEqual(len(failures), 1)
        self.assertIn("repeated", failures[0])

    def test_summary_line_limit_does_not_overconsume_iterator(self) -> None:
        consumed = 0

        def lines():
            nonlocal consumed
            while True:
                consumed += 1
                yield f"WARNING: item {consumed}\n"

        with mock.patch.object(conductor, "SUMMARY_INPUT_MAX_LINES", 5):
            summary = summarize("build", "failed", 1, lines())

        self.assertEqual(consumed, 5)
        self.assertTrue(summary["inputTruncated"])
        self.assertTrue(summary["inputLineLimitReached"])
        self.assertFalse(summary["inputByteLimitReached"])

    def test_safe_file_sampling_reports_omitted_middle_and_rejects_nonregular_paths(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            log = root / "job.log"
            log.write_bytes(b"head-one\nhead-two\nmiddle\ntail-one\ntail-two\n")
            sample = conductor.read_safe_regular_file_sample(log, 18, 18)
            symlink = root / "link.log"
            symlink.symlink_to(log)
            fifo = root / "fifo.log"
            os.mkfifo(fifo)

            self.assertGreater(sample.omitted_bytes, 0)
            self.assertIn(b"conductor omitted", sample.content)
            with self.assertRaises((OSError, conductor.ConductorError)):
                conductor.read_safe_regular_file_sample(root, 10, 10)
            with self.assertRaises((OSError, conductor.ConductorError)):
                conductor.read_safe_regular_file_sample(symlink, 10, 10)
            with self.assertRaises((OSError, conductor.ConductorError)):
                conductor.read_safe_regular_file_sample(fifo, 10, 10)

    def test_full_log_rendering_is_bounded_and_explicit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "large.log"
            log.write_bytes(b"0123456789\n" * 20)
            with mock.patch.object(conductor, "FULL_LOG_HEAD_BYTES", 24), mock.patch.object(
                conductor, "FULL_LOG_TAIL_BYTES", 24
            ), contextlib.redirect_stdout(io.StringIO()) as output:
                conductor.print_full_log({"logPath": str(log), "logTail": []})

        rendered = output.getvalue()
        self.assertIn("raw log rendering bounded", rendered)
        self.assertIn("conductor omitted", rendered)
        self.assertLess(len(rendered), 1000)

    def test_request_shape_bounds_nesting_collections_and_strings(self) -> None:
        nested: object = "leaf"
        for _ in range(conductor.MAX_JSON_DEPTH + 1):
            nested = [nested]
        with self.assertRaises(conductor.ConductorError):
            conductor.validate_json_shape(nested)
        with self.assertRaises(conductor.ConductorError):
            conductor.validate_json_shape(list(range(conductor.MAX_JSON_COLLECTION_ENTRIES + 1)))
        with self.assertRaises(conductor.ConductorError):
            conductor.validate_json_shape("x" * (conductor.MAX_JSON_STRING_BYTES + 1))

    def test_client_rejects_incomplete_oversized_and_mismatched_responses(self) -> None:
        def run_response(response_factory, response_limit: int = 128) -> None:
            with tempfile.TemporaryDirectory() as tmp:
                socket_path = Path(tmp) / "server.sock"
                listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                listener.bind(str(socket_path))
                listener.listen(1)
                done = threading.Event()

                def serve() -> None:
                    connection, _address = listener.accept()
                    with connection:
                        with connection.makefile("rb") as request_file:
                            request = json.loads(request_file.readline().decode("utf-8"))
                        connection.sendall(response_factory(request))
                    listener.close()
                    done.set()

                server = threading.Thread(target=serve)
                server.start()
                paths = mock.Mock(socket_path=socket_path)
                with mock.patch.object(conductor, "MAX_RESPONSE_BYTES", response_limit), self.assertRaises(
                    conductor.ConductorError
                ):
                    conductor.request_daemon(paths, {"type": "status"}, timeout=1.0)
                self.assertTrue(done.wait(1.0))
                server.join(timeout=1.0)

        run_response(lambda request: json.dumps({"id": request["id"], "ok": True, "payload": {}}).encode("utf-8"))
        run_response(lambda _request: b"x" * 129)
        run_response(lambda _request: b'{"id":"different","ok":true,"payload":{}}\n')

    def test_server_rejects_oversized_and_nonterminated_requests(self) -> None:
        for raw in [
            b"x" * 65 + b"\n",
            b'{"id":"x","type":"status"}',
            b'{"id":"x","type":"status"}\ntrailing',
        ]:
            with self.subTest(raw=raw[:10]):
                state = mock.Mock()
                server = mock.Mock()
                server.state = state
                server.wait_permits = threading.BoundedSemaphore(1)
                server_side, client_side = socket.socketpair()
                with mock.patch.object(conductor, "MAX_REQUEST_BYTES", 64):
                    handler = threading.Thread(
                        target=conductor.RequestHandler,
                        args=(server_side, ("local", 0), server),
                    )
                    handler.start()
                    client_side.sendall(raw)
                    client_side.shutdown(socket.SHUT_WR)
                    with client_side.makefile("rb") as response_file:
                        response = json.loads(response_file.readline().decode("utf-8"))
                    handler.join(timeout=1.0)
                client_side.close()
                server_side.close()

                self.assertFalse(response["ok"])
                state.status_payload.assert_not_called()

    def test_server_caps_total_handlers_and_clamps_wait_duration(self) -> None:
        server = conductor.ThreadedUnixServer.__new__(conductor.ThreadedUnixServer)
        server.handler_permits = threading.BoundedSemaphore(1)
        self.assertTrue(server.handler_permits.acquire(blocking=False))
        request = mock.Mock()
        with mock.patch.object(server, "shutdown_request") as shutdown:
            server.process_request(request, ("local", 0))
        shutdown.assert_called_once_with(request)

        state = mock.Mock()
        state.job_wait.return_value = {"state": "running"}
        conductor.handle_request(
            state,
            {"type": "job-wait", "ticket": "ticket", "timeout": 60},
        )
        self.assertEqual(state.job_wait.call_args.args[2], conductor.MAX_SERVER_WAIT_SECONDS)

    def test_disconnected_wait_releases_wait_permit_without_mutating_job(self) -> None:
        entered = threading.Event()
        release = threading.Event()
        job_state = {"state": "running"}
        state = mock.Mock()

        def wait(*_args: object) -> dict:
            entered.set()
            self.assertTrue(release.wait(1.0))
            return dict(job_state)

        state.job_wait.side_effect = wait
        server = mock.Mock()
        server.state = state
        server.wait_permits = threading.BoundedSemaphore(1)
        server_side, client_side = socket.socketpair()
        handler = threading.Thread(
            target=conductor.RequestHandler,
            args=(server_side, ("local", 0), server),
        )
        handler.start()
        request = {"id": "wait", "type": "job-wait", "ticket": "ticket", "timeout": 60}
        client_side.sendall((json.dumps(request) + "\n").encode("utf-8"))
        self.assertTrue(entered.wait(1.0))
        client_side.close()
        release.set()
        handler.join(timeout=1.0)
        server_side.close()

        self.assertFalse(handler.is_alive())
        self.assertEqual(job_state, {"state": "running"})
        self.assertTrue(server.wait_permits.acquire(blocking=False))
        server.wait_permits.release()


if __name__ == "__main__":
    unittest.main()
