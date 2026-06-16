#!/usr/bin/env python3
"""Focused tests for conductor concise output summaries."""

from __future__ import annotations

import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Optional

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


if __name__ == "__main__":
    unittest.main()
