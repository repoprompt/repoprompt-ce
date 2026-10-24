#!/usr/bin/env python3
"""Unit tests for conductor's structured per-job phase timing (build-modularization P0.1)."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import conductor  # noqa: E402


class ProtocolCompatibilityTests(unittest.TestCase):
    def test_new_client_rejects_active_protocol_17_daemon(self) -> None:
        self.assertGreater(conductor.PROTOCOL_VERSION, 17)
        old_status = {"protocolVersion": 17, "runningJobs": [{"ticket": "old"}], "queuedJobs": []}
        with mock.patch.object(conductor, "request_daemon", return_value=old_status) as request:
            with self.assertRaisesRegex(conductor.ConductorError, "protocol mismatch.*jobs are active"):
                conductor.compatible_daemon_status_or_stop_idle_mismatch(mock.Mock())
        request.assert_called_once()

    def test_idle_protocol_17_daemon_is_restarted_before_new_request(self) -> None:
        old_status = {"protocolVersion": 17, "runningJobs": [], "queuedJobs": []}
        with mock.patch.object(conductor, "request_daemon", side_effect=[old_status, {}]) as request, \
                mock.patch.object(conductor, "wait_until_stopped", return_value=True):
            self.assertEqual(conductor.compatible_daemon_status_or_stop_idle_mismatch(mock.Mock()), (None, None))
        self.assertEqual(request.call_args_list[1].args[1], {"type": "stop", "force": False})


def make_job(log_path: Path = Path("/tmp/ticket-1.log"), **overrides: object) -> conductor.Job:
    fields = dict(
        ticket="ticket-1",
        request_key=None,
        fingerprint="fp",
        operation="test",
        args={"filter": "RepoPromptRegexCoreTests"},
        lanes=["build"],
        timeout=None,
        verbose=False,
        env={},
        created_at=1000.0,
        log_path=log_path,
    )
    fields.update(overrides)
    return conductor.Job(**fields)


class MarkTests(unittest.TestCase):
    def test_first_mark_wins(self) -> None:
        job = make_job()
        job.mark_phase("heavySlotWaitStarted", 10.0)
        job.mark_phase("heavySlotWaitStarted", 20.0)
        self.assertEqual(job.phase_marks["heavySlotWaitStarted"], 10.0)

    def test_unknown_mark_rejected(self) -> None:
        with self.assertRaises(conductor.ConductorError):
            make_job().mark_phase("compiling", 1.0)


class OutputObservationTests(unittest.TestCase):
    def test_build_complete_and_first_xctest(self) -> None:
        job = make_job()
        job.observe_output_timing("[12/12] Linking RepoPromptCEPackageTests\n", at=5.0)
        job.observe_output_timing("\x1b[1mBuild complete!\x1b[0m (66.90s)\n", at=10.0)
        job.observe_output_timing("Test Suite 'Selected tests' started at 2026-09-28 17:49:46.046.\n", at=40.0)
        self.assertEqual(job.phase_marks["buildCompleted"], 10.0)
        self.assertEqual(job.build_reported_seconds, 66.9)
        self.assertEqual(job.phase_marks["firstTestStarted"], 40.0)

    def test_last_build_before_first_test_is_kept(self) -> None:
        job = make_job()
        job.observe_output_timing("Build complete! (3.00s)\n", at=10.0)
        job.observe_output_timing(conductor.TIMING_COLD_RETRY_TEXT + "\n", at=11.0)
        job.observe_output_timing("Build complete! (90.50s)\n", at=100.0)
        job.observe_output_timing("Test Suite 'All tests' started at x.\n", at=110.0)
        job.observe_output_timing("Build complete! (1.00s)\n", at=200.0)
        self.assertEqual(job.phase_marks["cacheColdRetryStarted"], 11.0)
        self.assertEqual(job.phase_marks["buildCompleted"], 100.0)
        self.assertEqual(job.build_reported_seconds, 90.5)
        self.assertEqual(job.build_complete_count, 2)

    def test_swift_testing_start_counts_as_first_test(self) -> None:
        job = make_job()
        job.observe_output_timing("◇ Test run started.\n", at=7.0)
        self.assertEqual(job.phase_marks["firstTestStarted"], 7.0)

    def test_unrelated_started_lines_are_ignored(self) -> None:
        job = make_job()
        job.observe_output_timing("Test Case '-[A.B testC]' started.\ncompile started\n", at=7.0)
        self.assertNotIn("firstTestStarted", job.phase_marks)
        self.assertNotIn("buildCompleted", job.phase_marks)


class PayloadTests(unittest.TestCase):
    def full_job(self) -> conductor.Job:
        job = make_job(started_at=1002.0, process_started_at=1030.0, process_finished_at=1200.0, finished_at=1260.0)
        job.state = "completed"
        job.exit_code = 0
        job.mark_phase("buildCachePrepareStarted", 1002.0)
        job.mark_phase("buildCachePrepareFinished", 1004.0)
        job.mark_phase("heavySlotWaitStarted", 1004.0)
        job.mark_phase("heavySlotAcquired", 1029.0)
        job.observe_output_timing("Build complete! (100.00s)\n", at=1140.0)
        job.observe_output_timing("Test Suite 'Selected tests' started at x.\n", at=1180.0)
        job.mark_phase("cachePublicationStarted", 1201.0)
        job.mark_phase("cachePublicationFinished", 1259.0)
        job.build_cache = {"state": "warmLocal", "seeded": False, "key": "k", "publication": {"state": "published"}}
        return job

    def test_segments(self) -> None:
        timings = self.full_job().phase_timings()
        self.assertEqual(timings["schemaVersion"], conductor.JOB_TIMING_SCHEMA_VERSION)
        self.assertEqual(list(timings["marks"]), [
            "queued", "laneAdmitted", "buildCachePrepareStarted", "buildCachePrepareFinished",
            "heavySlotWaitStarted", "heavySlotAcquired", "processStarted", "buildCompleted",
            "firstTestStarted", "processFinished", "cachePublicationStarted", "cachePublicationFinished",
            "finished",
        ])
        self.assertEqual(timings["segments"], {
            "queueSeconds": 2.0,
            "buildCachePrepareSeconds": 2.0,
            "heavySlotWaitSeconds": 25.0,
            "launchSeconds": 1.0,
            "processToBuildCompleteSeconds": 110.0,
            "buildReportedSeconds": 100.0,
            "preBuildSeconds": 10.0,
            "buildCompleteToFirstTestSeconds": 40.0,
            "processToFirstTestSeconds": 150.0,
            "testSeconds": 20.0,
            "processSeconds": 170.0,
            "finalizeSeconds": 1.0,
            "cachePublicationSeconds": 58.0,
            "totalSeconds": 260.0,
        })

    def test_partial_job_omits_open_segments(self) -> None:
        segments = make_job(started_at=1005.0).phase_timings()["segments"]
        self.assertEqual(segments, {"queueSeconds": 5.0})

    def test_payload_is_additive(self) -> None:
        payload = self.full_job().to_payload(include_tail=False)
        self.assertEqual(payload["executionSeconds"], 170.0)
        self.assertEqual(payload["queueWaitSeconds"], 2.0)
        self.assertEqual(payload["phaseTimings"]["segments"]["processSeconds"], payload["executionSeconds"])
        json.dumps(payload)

    def test_timing_record(self) -> None:
        record = self.full_job().timing_record()
        self.assertEqual(record["ticket"], "ticket-1")
        self.assertEqual(record["state"], "completed")
        self.assertEqual(record["buildCache"], {"state": "warmLocal", "seeded": False, "publicationState": "published"})
        self.assertIn("segments", record["phaseTimings"])

    def test_record_names(self) -> None:
        self.assertEqual(conductor.job_timing_record_path(Path("/j/abc.log")), Path("/j/abc.timing.json"))
        self.assertEqual(conductor.job_timing_record_log_name("abc.timing.json"), "abc.log")
        self.assertIsNone(conductor.job_timing_record_log_name("abc.log"))


class DaemonStateTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        state_dir = root / "state"
        jobs_dir = state_dir / "jobs"
        jobs_dir.mkdir(parents=True)
        self.paths = conductor.Paths(
            repo_root=root,
            repo_hash="0" * 64,
            state_dir=state_dir,
            socket_path=root / "d.sock",
            pid_path=state_dir / "daemon.pid",
            lock_path=state_dir / "daemon.start.lock",
            jobs_dir=jobs_dir,
            daemon_log_path=state_dir / "daemon.log",
            daemon_meta_path=state_dir / "daemon.json",
            running_processes_path=state_dir / "running-processes.json",
        )
        self.state = conductor.DaemonState(self.paths)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_output_lines_feed_timing_marks(self) -> None:
        job = make_job(log_path=self.paths.jobs_dir / "ticket-1.log")
        self.state.jobs[job.ticket] = job
        self.state._submit_process_output_line(job.ticket, b"Build complete! (2.50s)\n")
        self.assertIn("buildCompleted", job.phase_marks)
        self.assertEqual(job.build_reported_seconds, 2.5)

    def test_terminal_job_persists_timing_record(self) -> None:
        job = make_job(log_path=self.paths.jobs_dir / "ticket-1.log", started_at=1001.0, finished_at=1010.0)
        job.state = "completed"
        self.state._submit_job_timing_record(job)
        self.state._io_worker.join()
        record = json.loads((self.paths.jobs_dir / "ticket-1.timing.json").read_text())
        self.assertEqual(record["phaseTimings"]["segments"]["totalSeconds"], 10.0)

    def test_running_job_does_not_persist_timing_record(self) -> None:
        job = make_job(log_path=self.paths.jobs_dir / "ticket-1.log")
        job.state = "running"
        self.state._submit_job_timing_record(job)
        self.state._io_worker.join()
        self.assertFalse((self.paths.jobs_dir / "ticket-1.timing.json").exists())

    def test_retention_expires_timing_records_with_their_logs(self) -> None:
        stale = time.time() - conductor.TERMINAL_RETENTION_SECONDS - 60
        names = ("old.log", "old.timing.json", "kept.log", "kept.timing.json")
        for name in names:
            path = self.paths.jobs_dir / name
            path.write_text("{}")
            os.utime(path, (stale, stale))
        self.state.jobs["kept"] = make_job(log_path=self.paths.jobs_dir / "kept.log", ticket="kept")
        self.state._retention_external(
            self.state._retention_generation, (), frozenset({"kept.log"}), frozenset()
        )
        remaining = sorted(path.name for path in self.paths.jobs_dir.iterdir())
        self.assertEqual(remaining, ["kept.log", "kept.timing.json"])


class PeakRssTests(unittest.TestCase):
    PS_OUTPUT = "\n".join([
        "  100     1  2048 /usr/bin/python3",
        "  200   100  1024 /usr/bin/swift-build",
        "  300   200  4096 /Applications/Xcode.app/usr/bin/swift-frontend",
        "  400     1  9999 /Applications/Other App.app/Contents/MacOS/Other App",
        "  500   300     0 ld",
        "  600   200   512 (swift-frontend)",
        "garbage line",
    ])

    def test_parse_reads_pid_ppid_rss_and_name(self) -> None:
        table = conductor.parse_process_rss_table(self.PS_OUTPUT)
        self.assertEqual(table[300], (200, 4096 * 1024, "swift-frontend"))
        self.assertEqual(table[400], (1, 9999 * 1024, "Other App"))
        self.assertEqual(table[600], (200, 512 * 1024, "swift-frontend"))
        self.assertNotIn("garbage", str(table))

    def test_tree_sums_descendants_only(self) -> None:
        table = conductor.parse_process_rss_table(self.PS_OUTPUT)
        sample = conductor.process_tree_rss(table, 100)
        self.assertEqual(sample, {
            "treeBytes": (2048 + 1024 + 4096 + 512) * 1024, "processes": 5,
            "largestBytes": 4096 * 1024, "largestName": "swift-frontend",
        })
        self.assertIsNone(conductor.process_tree_rss(table, 999))
        self.assertIsNone(conductor.process_tree_rss(table, 500))  # zombie: RSS 0

    def test_sampler_stops_when_root_exits_or_process_is_reaped(self) -> None:
        tables = [
            conductor.parse_process_rss_table(self.PS_OUTPUT),
            None,
            conductor.parse_process_rss_table("  100 1 0 python3"),
        ]
        records = []
        waits = []
        conductor.run_process_tree_rss_sampler(
            100, lambda: True, records.append,
            snapshot=lambda: tables.pop(0), wait=waits.append, interval=0.5,
        )
        self.assertEqual(len(records), 1)
        self.assertEqual(waits, [0.5, 0.5])
        records.clear()
        conductor.run_process_tree_rss_sampler(100, lambda: False, records.append, snapshot=lambda: {}, wait=waits.append)
        self.assertEqual(records, [])

    def test_peaks_fold_into_phase_timings_and_record(self) -> None:
        job = make_job()
        self.assertNotIn("peakRss", job.phase_timings())
        job.observe_rss_sample({"treeBytes": 10, "processes": 3, "largestBytes": 6, "largestName": "ld"})
        job.observe_rss_sample({"treeBytes": 8, "processes": 5, "largestBytes": 7, "largestName": "dsymutil"})
        expected = {
            "samples": 2, "sampleIntervalSeconds": conductor.JOB_RSS_SAMPLE_INTERVAL_SECONDS,
            "treeBytes": 10, "treeProcesses": 3, "largestProcessBytes": 7, "largestProcessName": "dsymutil",
        }
        self.assertEqual(job.phase_timings()["peakRss"], expected)
        self.assertEqual(job.timing_record()["phaseTimings"]["peakRss"], expected)
        json.dumps(job.timing_record())


if __name__ == "__main__":
    unittest.main()
