#!/usr/bin/env python3
"""Focused tests for the local-first structured failure diagnostics surface."""

from __future__ import annotations

import contextlib
import json
import os
import tempfile
import threading
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from typing import Any
from unittest.mock import patch

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in __import__("sys").path:
    __import__("sys").path.insert(0, str(SCRIPT_DIR))

import failure_diagnostics  # noqa: E402
import conductor  # noqa: E402


class FakeJob:
    """Minimal stand-in for a conductor Job object."""

    def __init__(self, **kwargs: Any) -> None:
        defaults = {
            "ticket": "ticket-1",
            "request_key": None,
            "fingerprint": "fp",
            "operation": "build",
            "args": {},
            "lanes": ["build", "debugArtifact"],
            "timeout": None,
            "verbose": False,
            "env": {},
            "created_at": 1000.0,
            "log_path": Path("/tmp/jobs/ticket-1.log"),
            "state": "failed",
            "started_at": 1001.0,
            "finished_at": 1010.0,
            "process_started_at": 1002.0,
            "process_finished_at": 1009.0,
            "process_pid": None,
            "process_pgid": None,
            "process_start": None,
            "tracked_processes": {},
            "process_group_identity_confirmed": False,
            "global_heavy_slot_wait_seconds": None,
            "global_heavy_slot_path": None,
            "global_heavy_slot_holder": None,
            "exit_code": 1,
            "error": "",
            "result_summary": "",
            "cancel_requested": False,
            "superseded_by_ticket": None,
            "superseded_by_operation": None,
            "timed_out": False,
            "measurement_invalid": False,
            "progress_transport": None,
            "xctest_progress_sequence": 0,
            "xctest_progress_deadline": None,
            "xctest_current_test": None,
            "xctest_previous_test": None,
            "xctest_last_progress_test": None,
            "xctest_last_progress_action": None,
            "xctest_last_progress_observed_at": None,
            "xctest_watchdog_triggered": False,
            "xctest_process_finished": False,
            "diagnostics": [],
            "diagnostic_paths": [],
            "output_summary": None,
            "tail": [],
        }
        defaults.update(kwargs)
        for key, value in defaults.items():
            setattr(self, key, value)


class FailureClassificationTests(unittest.TestCase):
    def _classify(self, **kwargs: Any) -> tuple[str, str]:
        defaults = {
            "state": "failed",
            "exit_code": 1,
            "timed_out": False,
            "measurement_invalid": False,
            "error": "",
            "operation": "build",
            "output_summary": None,
            "global_heavy_slot_wait_seconds": None,
            "process_started_at": 1000.0,
            "superseded_by_operation": None,
        }
        defaults.update(kwargs)
        return failure_diagnostics.classify_failure(**defaults)

    def test_completed_success(self) -> None:
        failure_class, reason = self._classify(state="completed", exit_code=0)
        self.assertEqual(failure_class, "none")
        self.assertEqual(reason, "completed successfully")

    def test_cancellation(self) -> None:
        failure_class, reason = self._classify(state="canceled", exit_code=130)
        self.assertEqual(failure_class, "cancellation")
        self.assertEqual(reason, "canceled")

    def test_superseded_cancellation(self) -> None:
        failure_class, reason = self._classify(
            state="canceled", exit_code=130, superseded_by_operation="app relaunch"
        )
        self.assertEqual(failure_class, "cancellation")
        self.assertIn("superseded", reason)
        self.assertIn("app relaunch", reason)

    def test_timeout(self) -> None:
        failure_class, reason = self._classify(state="failed", exit_code=124, timed_out=True, error="timed out after 300.0s")
        self.assertEqual(failure_class, "timeout")
        self.assertIn("timed out", reason)

    def test_source_mutated_build(self) -> None:
        summary = {"launchLifecycle": {"sourceChangedDuringBuild": True}}
        failure_class, reason = self._classify(output_summary=summary)
        self.assertEqual(failure_class, "sourceMutatedBuild")
        self.assertIn("source files changed", reason)

    def test_compiler_failure(self) -> None:
        summary = {"sections": [{"title": "Swift compiler errors"}]}
        failure_class, reason = self._classify(output_summary=summary)
        self.assertEqual(failure_class, "compilerFailure")
        self.assertIn("Swift compiler errors", reason)

    def test_test_failure(self) -> None:
        summary = {"sections": [{"title": "Test failures"}]}
        failure_class, reason = self._classify(output_summary=summary)
        self.assertEqual(failure_class, "testFailure")
        self.assertIn("test failures", reason)

    def test_process_cleanup_failure(self) -> None:
        failure_class, reason = self._classify(
            error="timed out after 300.0s; root process did not exit after SIGKILL escalation"
        )
        self.assertEqual(failure_class, "processCleanupFailure")
        self.assertIn("SIGKILL", reason)

    def test_infrastructure_failure(self) -> None:
        failure_class, reason = self._classify(
            exit_code=70,
            measurement_invalid=True,
            error="XCTest progress stall watchdog invalidated this measurement",
        )
        self.assertEqual(failure_class, "infrastructureOrRPCFailure")

    def test_daemon_runner_error_class(self) -> None:
        failure_class, reason = self._classify(
            exit_code=1,
            error="daemon runner error: something broke",
        )
        self.assertEqual(failure_class, "infrastructureOrRPCFailure")
        self.assertIn("daemon runner error", reason)

    def test_heavy_lane_wait(self) -> None:
        failure_class, reason = self._classify(
            state="failed",
            exit_code=1,
            global_heavy_slot_wait_seconds=45.0,
            process_started_at=None,
        )
        self.assertEqual(failure_class, "heavyLaneWait")
        self.assertIn("45.0s", reason)

    def test_unknown_style_findings(self) -> None:
        summary = {"sections": [{"title": "Style findings"}]}
        failure_class, reason = self._classify(output_summary=summary)
        self.assertEqual(failure_class, "unknown")
        self.assertIn("style findings", reason)

    def test_unknown_no_evidence(self) -> None:
        failure_class, reason = self._classify(state="failed", exit_code=1, error="")
        self.assertEqual(failure_class, "unknown")
        self.assertIn("not recognized", reason)


class ExitClassTests(unittest.TestCase):
    def _classify(self, **kwargs: Any) -> str:
        defaults = {
            "state": "failed",
            "exit_code": 1,
            "timed_out": False,
            "measurement_invalid": False,
        }
        defaults.update(kwargs)
        return failure_diagnostics.classify_exit(**defaults)

    def test_completed(self) -> None:
        self.assertEqual(self._classify(state="completed", exit_code=0), "completed")

    def test_timeout(self) -> None:
        self.assertEqual(self._classify(state="failed", exit_code=124, timed_out=True), "timeout")

    def test_canceled(self) -> None:
        self.assertEqual(self._classify(state="canceled", exit_code=130), "canceled")

    def test_killed(self) -> None:
        self.assertEqual(self._classify(state="failed", exit_code=137), "killed")

    def test_infrastructure(self) -> None:
        self.assertEqual(self._classify(state="failed", exit_code=70, measurement_invalid=True), "infrastructure")

    def test_non_zero(self) -> None:
        self.assertEqual(self._classify(state="failed", exit_code=1), "nonZero")


class FailureRecordTests(unittest.TestCase):
    def test_record_from_job_filters_env_dump(self) -> None:
        job = FakeJob(
            env={
                "PATH": "/usr/bin:/bin",
                "HOME": "/root",
                "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
                "TOOLCHAINS": "org.swift.512",
                "SWIFT_EXEC": "swiftc",
                "SIGN_IDENTITY": "Apple Development: <redacted>",
            }
        )
        record = failure_diagnostics.FailureRecord.from_job(job, output_summary=None)
        self.assertEqual(record.toolchain_known_metadata.get("DEVELOPER_DIR"), "/Applications/Xcode.app/Contents/Developer")
        self.assertEqual(record.toolchain_known_metadata.get("TOOLCHAINS"), "org.swift.512")
        self.assertEqual(record.toolchain_known_metadata.get("SWIFT_EXEC"), "swiftc")
        self.assertNotIn("PATH", record.toolchain_known_metadata)
        self.assertNotIn("HOME", record.toolchain_known_metadata)
        self.assertNotIn("SIGN_IDENTITY", record.toolchain_known_metadata)

    def test_record_summary_reference_no_raw_lines(self) -> None:
        summary = {
            "headline": "failed with exit code 1",
            "errorCount": 5,
            "warningCount": 2,
            "logLineCount": 1000,
            "truncated": True,
            "sections": [
                {
                    "title": "Swift compiler errors",
                    "lines": ["Sources/Foo.swift:10:5: error: cannot find 'x' in scope"],
                    "truncated": False,
                    "omittedLineCount": 0,
                }
            ],
        }
        with tempfile.TemporaryDirectory() as tmp:
            jobs_dir = Path(tmp)
            job = FakeJob(log_path=jobs_dir / "ticket-1.log")
            record = failure_diagnostics.FailureRecord.from_job(job, summary, jobs_dir=jobs_dir)

        self.assertEqual(record.resource_summary.get("headline"), "failed with exit code 1")
        self.assertEqual(record.resource_summary.get("summarySectionTitles"), ["Swift compiler errors"])
        self.assertEqual(record.resource_summary.get("errorCount"), 5)
        self.assertEqual(record.resource_summary.get("logLineCount"), 1000)
        self.assertEqual(record.resource_summary.get("summaryPath"), str(jobs_dir / "ticket-1.summary.json"))
        self.assertNotIn("lines", record.resource_summary)
        # Ensure the raw line from the summary did not leak into the record.
        record_json = json.dumps(record.to_dict())
        self.assertNotIn("cannot find 'x' in scope", record_json)

    def test_record_serialization_round_trip(self) -> None:
        record = failure_diagnostics.FailureRecord(
            ticket="abc",
            operation="test",
            terminal_state="failed",
            failure_class="testFailure",
        )
        data = record.to_dict()
        self.assertEqual(data["schemaVersion"], 1)
        self.assertEqual(data["schemaLineage"], "repoprompt-ce.failure-record")
        self.assertEqual(data["ticket"], "abc")
        self.assertEqual(data["failureClass"], "testFailure")
        restored = failure_diagnostics.FailureRecord.from_dict(data)
        self.assertEqual(restored.ticket, "abc")
        self.assertEqual(restored.failure_class, "testFailure")
        self.assertEqual(restored.schema_lineage, "repoprompt-ce.failure-record")

    def test_from_dict_missing_fields_use_defaults(self) -> None:
        data = {
            "schemaVersion": 1,
            "schemaLineage": "repoprompt-ce.failure-record",
            "ticket": "abc",
            "finishedAt": 123.0,
        }
        record = failure_diagnostics.FailureRecord.from_dict(data)
        self.assertEqual(record.ticket, "abc")
        self.assertEqual(record.operation, "")
        self.assertEqual(record.terminal_state, "")
        self.assertEqual(record.failure_class, "")
        self.assertEqual(record.recorded_at, None)
        self.assertEqual(record.finished_at, 123.0)
        self.assertEqual(record.args, {})
        self.assertEqual(record.lanes, [])
        self.assertEqual(record.toolchain_known_metadata, {})
        self.assertEqual(record.resource_summary, {})
        self.assertEqual(record.diagnostic_paths, [])
        self.assertFalse(record.timed_out)

    def test_from_dict_null_field_uses_default(self) -> None:
        data = {
            "schemaVersion": 1,
            "schemaLineage": "repoprompt-ce.failure-record",
            "ticket": None,
            "args": None,
            "resourceSummary": None,
            "lanes": None,
            "diagnosticPaths": None,
        }
        record = failure_diagnostics.FailureRecord.from_dict(data)
        self.assertEqual(record.ticket, "")
        self.assertEqual(record.args, {})
        self.assertEqual(record.resource_summary, {})
        self.assertEqual(record.lanes, [])
        self.assertEqual(record.diagnostic_paths, [])

    def test_aggregate_json_privacy_note(self) -> None:
        record = failure_diagnostics.FailureRecord(
            ticket="abc",
            operation="test",
            terminal_state="failed",
            failure_class="testFailure",
        )
        output = failure_diagnostics.format_recent_failures([record], json_mode=True)
        payload = json.loads(output)
        self.assertEqual(payload["privacy"], failure_diagnostics.AGGREGATE_JSON_PRIVACY_NOTE)
        self.assertEqual(payload["count"], 1)

    def test_record_from_job_filters_unbounded_args(self) -> None:
        job = FakeJob(
            args={
                "product": "RepoPrompt",
                "message": "secret user prompt",
                "logFile": "/tmp/secret.log",
                "filter": "ExampleTests",
            }
        )
        record = failure_diagnostics.FailureRecord.from_job(job, output_summary=None)
        self.assertEqual(record.args, {"product": "RepoPrompt", "filter": "ExampleTests"})
        self.assertNotIn("message", record.args)
        self.assertNotIn("logFile", record.args)

    def test_from_dict_filters_unbounded_args(self) -> None:
        data = {
            "schemaVersion": 1,
            "schemaLineage": "repoprompt-ce.failure-record",
            "ticket": "abc",
            "terminalState": "failed",
            "failureClass": "testFailure",
            "args": {
                "product": "RepoPrompt",
                "message": "secret user prompt",
                "logFile": "/tmp/secret.log",
            },
        }
        record = failure_diagnostics.FailureRecord.from_dict(data)
        self.assertEqual(record.args, {"product": "RepoPrompt"})
        self.assertNotIn("message", record.args)
        self.assertNotIn("logFile", record.args)

    def test_format_recent_failures_json_omits_redacted_args(self) -> None:
        data = {
            "schemaVersion": 1,
            "schemaLineage": "repoprompt-ce.failure-record",
            "ticket": "abc",
            "terminalState": "failed",
            "failureClass": "testFailure",
            "args": {
                "product": "RepoPrompt",
                "message": "secret user prompt",
                "logFile": "/tmp/secret.log",
            },
        }
        record = failure_diagnostics.FailureRecord.from_dict(data)
        output = failure_diagnostics.format_recent_failures([record], json_mode=True)
        payload = json.loads(output)
        args = payload["records"][0]["args"]
        self.assertEqual(args, {"product": "RepoPrompt"})
        self.assertNotIn("message", args)
        self.assertNotIn("logFile", args)


class FailureRecordStoreTests(unittest.TestCase):
    def make_store(self, **kwargs: Any) -> failure_diagnostics.FailureRecordStore:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        defaults = {"max_age_seconds": 3600, "max_records": 10, "now": time.time}
        defaults.update(kwargs)
        return failure_diagnostics.FailureRecordStore(
            Path(tmp.name), **defaults
        )

    def test_write_and_load_round_trip(self) -> None:
        store = self.make_store()
        record = failure_diagnostics.FailureRecord(
            ticket="abc",
            operation="build",
            terminal_state="failed",
            failure_class="compilerFailure",
            recorded_at=time.time(),
        )
        summary = {"headline": "failed with exit code 1", "sections": []}
        store.write(record, summary)

        loaded = store.load_all()
        self.assertEqual(len(loaded), 1)
        self.assertEqual(loaded[0].ticket, "abc")
        self.assertEqual(loaded[0].failure_class, "compilerFailure")
        self.assertTrue((store._summary_path("abc")).exists())

    def test_retention_by_age(self) -> None:
        now = 1000000.0
        store = self.make_store(now=lambda: now, max_age_seconds=60, max_records=100)
        old = failure_diagnostics.FailureRecord(
            ticket="old",
            operation="build",
            terminal_state="failed",
            failure_class="unknown",
            recorded_at=now - 120,
        )
        new = failure_diagnostics.FailureRecord(
            ticket="new",
            operation="build",
            terminal_state="failed",
            failure_class="unknown",
            recorded_at=now - 10,
        )
        store.write(old, None)
        store.write(new, None)

        store.retention_pass()
        self.assertEqual({r.ticket for r in store.load_all()}, {"new"})

    def test_retention_by_count(self) -> None:
        now = 1000000.0
        store = self.make_store(now=lambda: now, max_age_seconds=3600, max_records=2)
        for index in range(5):
            record = failure_diagnostics.FailureRecord(
                ticket=f"ticket-{index}",
                operation="build",
                terminal_state="failed",
                failure_class="unknown",
                recorded_at=now - index,
                finished_at=now - index,
            )
            store.write(record, None)

        # Each write calls retention_pass, so only the newest two should remain.
        loaded = store.load_all()
        self.assertEqual({r.ticket for r in loaded}, {"ticket-0", "ticket-1"})

    def test_query_filters(self) -> None:
        now = 1000000.0
        store = self.make_store(now=lambda: now, max_age_seconds=3600, max_records=10)
        for ticket, operation, failure_class in [
            ("a", "test", "testFailure"),
            ("b", "test", "compilerFailure"),
            ("c", "build", "compilerFailure"),
        ]:
            record = failure_diagnostics.FailureRecord(
                ticket=ticket,
                operation=operation,
                terminal_state="failed",
                failure_class=failure_class,
                recorded_at=now,
                finished_at=now,
            )
            store.write(record, None)

        by_operation = store.query_recent(operation="test")
        self.assertEqual({r.ticket for r in by_operation}, {"a", "b"})

        by_class = store.query_recent(failure_class="compilerFailure")
        self.assertEqual({r.ticket for r in by_class}, {"b", "c"})

        by_both = store.query_recent(operation="test", failure_class="compilerFailure")
        self.assertEqual({r.ticket for r in by_both}, {"b"})

    def test_schema_compatibility_skips_future_version(self) -> None:
        store = self.make_store()
        future = {
            "schemaVersion": 99,
            "schemaLineage": "repoprompt-ce.failure-record",
            "ticket": "future",
            "operation": "build",
            "terminalState": "failed",
            "failureClass": "unknown",
            "recordedAt": time.time(),
        }
        store._record_path("future").write_text(json.dumps(future), encoding="utf-8")
        self.assertEqual(store.load_all(), [])

    def test_schema_compatibility_skips_foreign_lineage(self) -> None:
        store = self.make_store()
        foreign = {
            "schemaVersion": 1,
            "schemaLineage": "some-other-project.failure-record",
            "ticket": "foreign",
            "operation": "build",
            "terminalState": "failed",
            "failureClass": "unknown",
            "recordedAt": time.time(),
        }
        store._record_path("foreign").write_text(json.dumps(foreign), encoding="utf-8")
        self.assertEqual(store.load_all(), [])

    def test_orphaned_summary_cleanup(self) -> None:
        store = self.make_store()
        summary_path = store._summary_path("orphan")
        summary_path.write_text(json.dumps({"headline": "x"}), encoding="utf-8")
        store.retention_pass()
        self.assertFalse(summary_path.exists())

    def test_atomic_write_leaves_no_temp_files(self) -> None:
        store = self.make_store()
        record = failure_diagnostics.FailureRecord(
            ticket="abc",
            operation="build",
            terminal_state="failed",
            failure_class="compilerFailure",
            recorded_at=time.time(),
        )
        summary = {"headline": "failed", "sections": []}
        store.write(record, summary)

        record_path = store._record_path("abc")
        summary_path = store._summary_path("abc")
        self.assertTrue(record_path.exists())
        self.assertTrue(summary_path.exists())
        # No leftover temp files from the atomic write.
        self.assertEqual(list(store.jobs_dir.glob("*.tmp")), [])

    def test_write_cleanup_temp_on_record_failure(self) -> None:
        store = self.make_store()
        record = failure_diagnostics.FailureRecord(
            ticket="abc",
            operation="build",
            terminal_state="failed",
            failure_class="compilerFailure",
            recorded_at=time.time(),
        )
        # Create the final record path as a directory so os.replace cannot overwrite it.
        record_path = store._record_path("abc")
        record_path.mkdir()
        try:
            with self.assertRaises(failure_diagnostics.FailureDiagnosticsError):
                store.write(record, None)
            # Temp files created during the failed write should be removed.
            self.assertEqual(list(store.jobs_dir.glob("*.tmp")), [])
        finally:
            with contextlib.suppress(OSError):
                record_path.rmdir()

    def test_concurrent_writes_are_safe(self) -> None:
        now = 1000000.0
        store = self.make_store(now=lambda: now, max_age_seconds=3600, max_records=100)

        def write_record(index: int) -> None:
            record = failure_diagnostics.FailureRecord(
                ticket=f"ticket-{index}",
                operation="build",
                terminal_state="failed",
                failure_class="unknown",
                recorded_at=now,
                finished_at=now,
            )
            store.write(record, None)

        threads = [threading.Thread(target=write_record, args=(i,)) for i in range(20)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        loaded = store.load_all()
        self.assertEqual(len(loaded), 20)
        self.assertEqual({r.ticket for r in loaded}, {f"ticket-{i}" for i in range(20)})

    def test_retention_does_not_delete_temp_files(self) -> None:
        store = self.make_store()
        # Create a temp file that looks like an in-flight write.
        temp_path = store.jobs_dir / ".inflight.tmp"
        temp_path.write_text("partial", encoding="utf-8")

        old = failure_diagnostics.FailureRecord(
            ticket="old",
            operation="build",
            terminal_state="failed",
            failure_class="unknown",
            recorded_at=store.now() - 3600,
        )
        store.write(old, None)
        store.retention_pass()

        self.assertTrue(temp_path.exists())

    def test_write_suppresses_duplicate_per_ticket(self) -> None:
        store = self.make_store()
        record = failure_diagnostics.FailureRecord(
            ticket="abc",
            operation="test",
            terminal_state="failed",
            failure_class="testFailure",
            recorded_at=time.time(),
        )
        summary = {"headline": "first"}
        record_path = store.write(record, summary)
        record_text = record_path.read_text(encoding="utf-8")
        summary_text = store._summary_path("abc").read_text(encoding="utf-8")

        record2 = failure_diagnostics.FailureRecord(
            ticket="abc",
            operation="build",
            terminal_state="failed",
            failure_class="compilerFailure",
            recorded_at=time.time(),
        )
        summary2 = {"headline": "second"}
        record_path2 = store.write(record2, summary2)

        self.assertEqual(record_path, record_path2)
        self.assertEqual(record_path.read_text(encoding="utf-8"), record_text)
        self.assertEqual(store._summary_path("abc").read_text(encoding="utf-8"), summary_text)
        loaded = store.load_all()
        self.assertEqual(len(loaded), 1)
        self.assertEqual(loaded[0].operation, "test")
        self.assertEqual(loaded[0].failure_class, "testFailure")

    def test_concurrent_duplicate_writes_are_suppressed(self) -> None:
        now = 1000000.0
        store = self.make_store(now=lambda: now, max_age_seconds=3600, max_records=100)

        def write_record() -> None:
            record = failure_diagnostics.FailureRecord(
                ticket="dup",
                operation="test",
                terminal_state="failed",
                failure_class="testFailure",
                recorded_at=now,
                finished_at=now,
            )
            store.write(record, None)

        threads = [threading.Thread(target=write_record) for _ in range(10)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        loaded = store.load_all()
        self.assertEqual(len(loaded), 1)
        self.assertEqual(loaded[0].ticket, "dup")

    def test_write_rolls_back_summary_when_record_write_fails(self) -> None:
        store = self.make_store()
        record = failure_diagnostics.FailureRecord(
            ticket="abc",
            operation="test",
            terminal_state="failed",
            failure_class="testFailure",
            recorded_at=time.time(),
        )
        summary = {"headline": "first"}

        def fake_write_text_atomic(path: Path, text: str) -> None:
            if path.name.endswith(".summary.json"):
                path.write_text(text, encoding="utf-8")
            else:
                raise OSError("disk full")

        with patch.object(store, "_write_text_atomic", side_effect=fake_write_text_atomic):
            with self.assertRaises(failure_diagnostics.FailureDiagnosticsError):
                store.write(record, summary)

        self.assertFalse(store._summary_path("abc").exists())
        self.assertFalse(store._record_path("abc").exists())


class ConductorIntegrationTests(unittest.TestCase):
    def test_refresh_output_summary_writes_failure_record(self) -> None:
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
            log.write_text(
                "==> Building\nSources/Foo.swift:10:5: error: cannot find 'x' in scope\n",
                encoding="utf-8",
            )
            state = conductor.DaemonState(paths)
            job = conductor.Job(
                ticket="ticket",
                request_key=None,
                fingerprint="fp",
                operation="swift-build",
                args={},
                lanes=["build"],
                timeout=None,
                verbose=False,
                env={"DEVELOPER_DIR": "/x"},
                created_at=conductor.now(),
                log_path=log,
                state="failed",
                exit_code=1,
                finished_at=conductor.now(),
            )
            state.jobs["ticket"] = job
            state._refresh_output_summary(job)

            record_path = jobs_dir / "ticket.failure.json"
            self.assertTrue(record_path.exists())
            data = json.loads(record_path.read_text(encoding="utf-8"))
            self.assertEqual(data["ticket"], "ticket")
            self.assertEqual(data["operation"], "swift-build")
            self.assertEqual(data["failureClass"], "compilerFailure")
            self.assertEqual(data["toolchainKnownMetadata"], {"DEVELOPER_DIR": "/x"})

            summary_path = jobs_dir / "ticket.summary.json"
            self.assertTrue(summary_path.exists())

    def test_handle_recent_failures_query(self) -> None:
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
            store = failure_diagnostics.FailureRecordStore(jobs_dir, max_age_seconds=3600, max_records=10)
            store.write(
                failure_diagnostics.FailureRecord(
                    ticket="recent",
                    operation="test",
                    terminal_state="failed",
                    failure_class="testFailure",
                    recorded_at=time.time(),
                    finished_at=time.time(),
                ),
                None,
            )

            args = {"limit": 10, "operation": None, "failureClass": None, "hours": None}
            with contextlib.redirect_stdout(__import__("io").StringIO()) as output:
                code = conductor.handle_recent_failures_query(paths, args, json_mode=True)

            self.assertEqual(code, 0)
            payload = json.loads(output.getvalue())
            self.assertEqual(len(payload["records"]), 1)
            self.assertEqual(payload["records"][0]["ticket"], "recent")

    def test_recent_failures_command_line_filter(self) -> None:
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
            store = failure_diagnostics.FailureRecordStore(jobs_dir, max_age_seconds=3600, max_records=10)
            for op, cls in [("test", "testFailure"), ("build", "compilerFailure")]:
                store.write(
                    failure_diagnostics.FailureRecord(
                        ticket=f"{op}-1",
                        operation=op,
                        terminal_state="failed",
                        failure_class=cls,
                        recorded_at=time.time(),
                        finished_at=time.time(),
                    ),
                    None,
                )

            args = {"limit": 10, "operation": "test", "failureClass": None, "hours": None}
            with contextlib.redirect_stdout(__import__("io").StringIO()) as output:
                conductor.handle_recent_failures_query(paths, args, json_mode=True)
            payload = json.loads(output.getvalue())
            self.assertEqual([r["ticket"] for r in payload["records"]], ["test-1"])

    def test_handle_recent_failures_query_hours_filter(self) -> None:
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
            now = 1000000.0
            store = failure_diagnostics.FailureRecordStore(
                jobs_dir, max_age_seconds=3600, max_records=10, now=lambda: now
            )
            store.write(
                failure_diagnostics.FailureRecord(
                    ticket="old",
                    operation="test",
                    terminal_state="failed",
                    failure_class="testFailure",
                    recorded_at=now - 100.0,
                    finished_at=now - 100.0,
                ),
                None,
            )

            with patch("conductor.now", return_value=now):
                # 1 hour window should include the 100-second-old record.
                args = {"limit": 10, "operation": None, "failureClass": None, "hours": 1.0}
                with contextlib.redirect_stdout(__import__("io").StringIO()) as output:
                    conductor.handle_recent_failures_query(paths, args, json_mode=True)
                payload = json.loads(output.getvalue())
                self.assertEqual([r["ticket"] for r in payload["records"]], ["old"])

                # 0.01 hour (36 seconds) window should exclude the 100-second-old record.
                args = {"limit": 10, "operation": None, "failureClass": None, "hours": 0.01}
                with contextlib.redirect_stdout(__import__("io").StringIO()) as output:
                    conductor.handle_recent_failures_query(paths, args, json_mode=True)
                payload = json.loads(output.getvalue())
                self.assertEqual(payload["records"], [])


if __name__ == "__main__":
    unittest.main()
