#!/usr/bin/env python3
"""Synthetic high-output conductor integration diagnostic.

Starts a real conductor daemon in a disposable temporary directory, enqueues a
`diagnostics high-output` job, and verifies:

* status / job-wait / cancel RPC phase latency
* daemon versus child process resources
* raw-log completeness vs terminal summary counts
* summary duration instrumentation
* verified process-tree exit after completion and after cancellation
"""

from __future__ import annotations

import contextlib
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from typing import Any, Dict, Optional

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import conductor  # noqa: E402
import conductor_diagnostics  # noqa: E402


class HighOutputDiagnosticTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.state_dir = self.root / "state"
        self.state_dir.mkdir()
        self.socket_path = self.root / "conductor.sock"
        self.env = os.environ.copy()
        self.env["REPOPROMPT_DEV_DAEMON_STATE_DIR"] = str(self.state_dir)
        self.env["REPOPROMPT_DEV_DAEMON_SOCKET"] = str(self.socket_path)

        self.paths = conductor.Paths(
            repo_root=self.root,
            repo_hash="test",
            state_dir=self.state_dir,
            socket_path=self.socket_path,
            pid_path=self.state_dir / "conductor.pid",
            lock_path=self.state_dir / "conductor.lock",
            jobs_dir=self.state_dir / "jobs",
            daemon_log_path=self.state_dir / "daemon.log",
            daemon_meta_path=self.state_dir / "daemon.json",
            running_processes_path=self.state_dir / "running-processes.json",
        )
        self.daemon: Optional[subprocess.Popen[str]] = None
        self._start_daemon()

    def _start_daemon(self) -> None:
        self.daemon = subprocess.Popen(
            [sys.executable, str(SCRIPT_DIR / "conductor.py"), "__daemon", "--repo-root", str(self.root)],
            env=self.env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
        )
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            with contextlib.suppress(OSError, conductor.ConductorError):
                payload = conductor.request_daemon(self.paths, {"type": "status"}, timeout=0.5)
                if payload.get("pid"):
                    return
            time.sleep(0.05)
        self.fail("daemon did not become ready")

    def tearDown(self) -> None:
        if self.daemon is not None and self.daemon.poll() is None:
            with contextlib.suppress(OSError, conductor.ConductorError):
                conductor.request_daemon(self.paths, {"type": "stop", "force": True}, timeout=5.0)
            try:
                self.daemon.wait(timeout=5.0)
            except subprocess.TimeoutExpired:
                self.daemon.terminate()
                try:
                    self.daemon.wait(timeout=2.0)
                except subprocess.TimeoutExpired:
                    self.daemon.kill()
                    self.daemon.wait()

    def _request(self, payload: Dict[str, Any], socket_timeout: float = 5.0) -> Dict[str, Any]:
        return conductor.request_daemon(self.paths, payload, timeout=socket_timeout)

    def _enqueue(self, args: Dict[str, Any]) -> str:
        payload = self._request(
            {
                "type": "enqueue",
                "operation": "diagnostics",
                "args": args,
                "timeout": 30.0,
            },
            socket_timeout=10.0,
        )
        self.assertIn("ticket", payload)
        return str(payload["ticket"])

    def _wait_for_running(self, ticket: str, timeout: float = 5.0) -> Dict[str, Any]:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            payload = self._request({"type": "job-status", "ticket": ticket}, socket_timeout=2.0)
            if payload.get("state") == "running" and payload.get("processPID"):
                return payload
            time.sleep(0.05)
        self.fail("job did not reach running state with a process PID")

    def _wait_for_terminal(self, ticket: str, timeout: float = 30.0) -> Dict[str, Any]:
        return self._request(
            {"type": "job-wait", "ticket": ticket, "timeout": timeout},
            socket_timeout=timeout + 5.0,
        )

    def _pid(self, payload: Dict[str, Any]) -> int:
        return int(payload.get("processPID") or 0)

    def _sample_resources(self, daemon_pid: int, child_pid: int) -> Dict[str, int]:
        daemon_rss = 0
        child_rss = 0
        snapshot = conductor_diagnostics.process_resource_snapshot()
        if daemon_pid in snapshot:
            daemon_rss = snapshot[daemon_pid][1]
        if child_pid in snapshot:
            child_rss, _, _, _ = conductor_diagnostics.process_tree_resources(child_pid, snapshot)
        return {"daemon_rss_kb": daemon_rss, "child_tree_rss_kb": child_rss}

    def test_high_output_completes_and_summary_matches_raw_log(self) -> None:
        lines = 1000
        warnings = 10
        start = time.monotonic()
        ticket = self._enqueue({"subcommand": "high-output", "lines": lines, "warnings": warnings, "exitCode": 0})
        enqueue_latency = time.monotonic() - start

        start = time.monotonic()
        payload = self._wait_for_terminal(ticket)
        wait_latency = time.monotonic() - start

        self.assertIn(payload.get("state"), {"completed", "failed"})
        self.assertEqual(payload.get("exitCode"), 0)

        log_path = Path(str(payload.get("logPath") or ""))
        self.assertTrue(log_path.exists(), f"raw log missing: {log_path}")
        log_text = log_path.read_text(encoding="utf-8", errors="replace")
        log_lines = log_text.splitlines()
        # Expected: $ python3 ... start line + start marker + lines + warnings + done marker
        expected_lines = 1 + 2 + lines + warnings
        self.assertEqual(len(log_lines), expected_lines)
        self.assertIn("high-output diagnostic start", log_text)
        self.assertIn("high-output diagnostic done", log_text)
        self.assertIn("synthetic warning 0", log_text)
        self.assertIn("synthetic warning 9", log_text)

        summary = payload.get("outputSummary") or {}
        self.assertEqual(summary.get("logLineCount"), expected_lines)
        self.assertEqual(summary.get("warningCount"), warnings)
        self.assertEqual(summary.get("errorCount"), 0)
        self.assertIn("summaryDurationSeconds", summary)
        self.assertIsInstance(summary.get("summaryDurationSeconds"), float)
        self.assertGreaterEqual(summary.get("summaryDurationSeconds", 0), 0)

        status_payload = self._request({"type": "job-status", "ticket": ticket}, socket_timeout=2.0)
        self.assertIn("outputSummary", status_payload)

        # Status RPC latency.
        start = time.monotonic()
        self._request({"type": "job-status", "ticket": ticket}, socket_timeout=2.0)
        status_latency = time.monotonic() - start

        # Verified process-tree exit.
        process_pid = self._pid(payload)
        self.assertGreater(process_pid, 0)
        self.assertFalse(conductor_diagnostics.pid_alive(process_pid), "child process still alive after completion")
        daemon_status = self._request({"type": "status"}, socket_timeout=2.0)
        resources = self._sample_resources(int(daemon_status.get("pid") or 0), process_pid)

        report: Dict[str, Any] = {
            "enqueue_latency_seconds": round(enqueue_latency, 4),
            "wait_latency_seconds": round(wait_latency, 4),
            "status_latency_seconds": round(status_latency, 4),
            "log_lines": len(log_lines),
            "summary_warning_count": summary.get("warningCount"),
            "summary_log_line_count": summary.get("logLineCount"),
            "summary_duration_seconds": summary.get("summaryDurationSeconds"),
            "daemon_rss_kb": resources["daemon_rss_kb"],
            "child_tree_rss_kb": resources["child_tree_rss_kb"],
        }
        # Surface the evidence for the human runner.
        print(f"HIGH_OUTPUT_EVIDENCE: {report}")

    def test_cancel_terminates_process_tree(self) -> None:
        ticket = self._enqueue({"subcommand": "high-output", "lines": 0, "linger": 30, "exitCode": 0})
        running_payload = self._wait_for_running(ticket)
        process_pid = self._pid(running_payload)
        self.assertGreater(process_pid, 0)

        start = time.monotonic()
        cancel_payload = self._request({"type": "job-cancel", "ticket": ticket}, socket_timeout=2.0)
        cancel_latency = time.monotonic() - start

        self.assertTrue(cancel_payload.get("cancelRequested") or cancel_payload.get("state") in {"canceled", "running"})

        start = time.monotonic()
        terminal = self._wait_for_terminal(ticket)
        wait_after_cancel_latency = time.monotonic() - start

        self.assertEqual(terminal.get("state"), "canceled")
        self.assertFalse(
            conductor_diagnostics.pid_alive(process_pid),
            "child process still alive after cancellation",
        )
        self.assertEqual(
            conductor_diagnostics.process_tree_resources(process_pid)[0],
            0,
            "process tree still resident after cancellation",
        )

        report = {
            "cancel_latency_seconds": round(cancel_latency, 4),
            "wait_after_cancel_latency_seconds": round(wait_after_cancel_latency, 4),
            "process_pid": process_pid,
        }
        print(f"CANCEL_EVIDENCE: {report}")

    def test_daemon_versus_child_resources(self) -> None:
        ticket = self._enqueue({"subcommand": "high-output", "lines": 500, "linger": 2, "exitCode": 0})
        running_payload = self._wait_for_running(ticket)
        process_pid = self._pid(running_payload)
        daemon_status = self._request({"type": "status"}, socket_timeout=2.0)
        daemon_pid = int(daemon_status.get("pid") or 0)
        self.assertGreater(process_pid, 0)
        self.assertGreater(daemon_pid, 0)

        peak_child = 0
        peak_daemon = 0
        samples = 0
        deadline = time.monotonic() + 30.0
        while True:
            snapshot = conductor_diagnostics.process_resource_snapshot()
            if daemon_pid in snapshot:
                peak_daemon = max(peak_daemon, snapshot[daemon_pid][1])
            if process_pid in snapshot:
                child_total, _, _, _ = conductor_diagnostics.process_tree_resources(process_pid, snapshot)
                peak_child = max(peak_child, child_total)
            samples += 1
            status = self._request({"type": "job-status", "ticket": ticket}, socket_timeout=2.0)
            if status.get("state") in {"completed", "failed", "canceled"}:
                break
            if time.monotonic() > deadline:
                self.fail("resource polling exceeded deadline")
            time.sleep(0.1)

        self._wait_for_terminal(ticket)

        report = {
            "samples": samples,
            "peak_daemon_rss_kb": peak_daemon,
            "peak_child_tree_rss_kb": peak_child,
        }
        print(f"RESOURCE_EVIDENCE: {report}")

        # The child is a tiny Python process; the daemon should be larger but not
        # by orders of magnitude.  Sanity check that the child is observable.
        self.assertGreater(peak_child, 0)
        self.assertGreater(peak_daemon, 0)


if __name__ == "__main__":
    unittest.main()
