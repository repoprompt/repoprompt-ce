#!/usr/bin/env python3
"""Unit tests for conductor job timing summaries."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import conductor_job_timings as timings  # noqa: E402

FOCUSED = (
    "acquired fair global heavy slot /tmp/x/global-heavy-0.lock after 2m 30s\n"
    "$ python3 Scripts/ci_app_test_runner.py --local\n"
    "Compiling RepoPromptApp Foo.swift\n"
    "\t Executed 4 tests, with 0 failures (0 unexpected) in 1.0 (1.0) seconds\n"
)


class ParseTests(unittest.TestCase):
    def test_parse_duration(self) -> None:
        self.assertEqual(timings.parse_duration("60ms"), 0.06)
        self.assertEqual(timings.parse_duration("8s"), 8)
        self.assertEqual(timings.parse_duration("27m 52s"), 27 * 60 + 52)
        self.assertEqual(timings.parse_duration("1h 2m 3s"), 3723)

    def test_classify(self) -> None:
        self.assertEqual(timings.classify(FOCUSED), "test focused: app recompiled")
        full = FOCUSED.replace("Compiling RepoPromptApp Foo.swift\n", "").replace("Executed 4", "Executed 3021")
        self.assertEqual(timings.classify(full), "test full-suite: nothing compiled")
        self.assertEqual(timings.classify("$ Scripts/package_app.sh debug\n"), "package: no app compile")
        self.assertIsNone(timings.classify("random"))

    def test_sample_subtracts_wait(self) -> None:
        sample = timings.sample_log(FOCUSED, elapsed_seconds=400)
        self.assertEqual(sample.wait_seconds, 150)
        self.assertEqual(sample.net_seconds, 250)


class CollectTests(unittest.TestCase):
    def test_verbose_log_footer_beyond_old_limit_is_classified(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            jobs = Path(tmp) / "repo-hash" / "jobs"
            jobs.mkdir(parents=True)
            (jobs / "a.log").write_text(
                "$ python3 Scripts/ci_app_test_runner.py --local\n" + "diagnostic\n" * 50000 +
                "Compiling RepoPromptApp Foo.swift\nExecuted 4 tests, with 0 failures\n"
            )
            (jobs / "a.timing.json").write_text(json.dumps({
                "schemaVersion": 1, "state": "completed", "exitCode": 0,
                "phaseTimings": {"segments": {"totalSeconds": 100.0}},
            }))
            samples = timings.collect(Path(tmp), 10)
        summary = timings.summarize(samples)
        self.assertEqual(summary["net test focused: app recompiled"]["n"], 1)
        self.assertEqual(summary["coverage"]["unclassified"], 0)
        self.assertEqual(summary["coverage"]["truncated"], 0)

    def test_collect_and_summarize(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            jobs = Path(tmp) / "repo-hash" / "jobs"
            jobs.mkdir(parents=True)
            (jobs / "a.log").write_text(FOCUSED)
            (jobs / "b.log").write_text("acquired fair global heavy slot /tmp/l after 10s\njob canceled\n")
            (jobs / "c.log").write_text("unrelated\n")
            samples = timings.collect(Path(tmp), limit=10, elapsed=lambda _: 300.0)
        summary = timings.summarize(samples)
        self.assertEqual(summary["heavy-slot wait"]["n"], 2)
        self.assertEqual(summary["net test focused: app recompiled"]["p50_s"], 150.0)

    def test_structured_record_is_preferred(self) -> None:
        segments = {
            "queueSeconds": 5.0,
            "heavySlotWaitSeconds": 60.0,
            "totalSeconds": 265.0,
            "preBuildSeconds": 2.0,
            "buildCompleteToFirstTestSeconds": 13.0,
        }
        with tempfile.TemporaryDirectory() as tmp:
            jobs = Path(tmp) / "repo-hash" / "jobs"
            jobs.mkdir(parents=True)
            (jobs / "a.log").write_text(FOCUSED)
            (jobs / "a.timing.json").write_text(json.dumps(
                {"schemaVersion": 1, "phaseTimings": {"segments": segments}}
            ))
            (jobs / "b.log").write_text(FOCUSED)
            (jobs / "b.timing.json").write_text(json.dumps({"schemaVersion": 99}))
            samples = timings.collect(Path(tmp), limit=10, elapsed=lambda _: 400.0)
        by_source = {sample.source: sample for sample in samples}
        structured = by_source["structured"]
        self.assertEqual(structured.wait_seconds, 60.0)
        self.assertEqual(structured.net_seconds, 200.0)
        self.assertEqual(structured.phases["buildCompleteToFirstTestSeconds"], 13.0)
        fallback = by_source["log"]
        self.assertEqual((fallback.wait_seconds, fallback.net_seconds), (150, 250))
        summary = timings.summarize(samples)
        self.assertEqual(summary["net test focused: app recompiled"]["n"], 2)
        row = summary["phase test focused: app recompiled: buildCompleteToFirstTestSeconds"]
        self.assertEqual((row["n"], row["p50_s"]), (1, 13.0))

    def test_structured_job_without_heavy_slot(self) -> None:
        sample = timings.sample_structured("$ Scripts/package_app.sh debug\n", {"totalSeconds": 30.0})
        self.assertEqual((sample.category, sample.wait_seconds, sample.net_seconds), ("package: no app compile", None, 30.0))
        self.assertIsNone(timings.sample_structured("unrelated\n", {"totalSeconds": 3.0}))

    def test_percentile(self) -> None:
        self.assertEqual(timings.percentile([], 0.5), 0.0)
        self.assertEqual(timings.percentile([1, 2, 3, 4, 5], 0.5), 3)


if __name__ == "__main__":
    unittest.main()
