#!/usr/bin/env python3
"""Summarize conductor job logs into build/test/queue timing percentiles.

Phase 0.1 baseline for docs/migrations/build-modularization-2026-09-28.md.
When conductor wrote a structured `<ticket>.timing.json` record next to the job
log, durations and the heavy-slot wait come from its phase segments and per-phase
percentiles are reported. Otherwise durations are approximated from the log's
creation time to its last write, minus the parsed global heavy-slot wait.
The job category is classified by streaming the complete log.

Usage:
  conductor_job_timings.py [--state-root DIR] [--limit N] [--json]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Sequence

DEFAULT_STATE_ROOT = Path.home() / "Library" / "Application Support" / "RepoPrompt CE" / "Conductor"

_WAIT = re.compile(r"acquired fair global heavy slot \S+ after ([^\n]+)")
_EXECUTED = re.compile(r"Executed (\d+) tests?, with \d+ failures?")
_APP_COMPILE = re.compile(r"Compiling RepoPromptApp ")
_TEST_COMPILE = re.compile(r"Compiling RepoPromptTests ")

TIMING_RECORD_SUFFIX = ".timing.json"
TIMING_SCHEMA_VERSION = 1
# Structured segments summarized per category (seconds).
PHASE_SUMMARY_SEGMENTS = (
    "buildCachePrepareSeconds",
    "preBuildSeconds",
    "buildReportedSeconds",
    "buildCompleteToFirstTestSeconds",
    "testSeconds",
    "cachePublicationSeconds",
)


def parse_duration(text: str) -> float:
    """Parse conductor durations such as '60ms', '8.2s', '27m 52s', '1h 2m 3s'."""
    text = text.strip()
    milliseconds = re.fullmatch(r"(\d+(?:\.\d+)?)ms", text)
    if milliseconds:
        return float(milliseconds.group(1)) / 1000.0
    seconds = 0.0
    for value, unit in re.findall(r"(\d+(?:\.\d+)?)(h|m|s)\b", text):
        seconds += float(value) * {"h": 3600, "m": 60, "s": 1}[unit]
    return seconds


@dataclass(frozen=True)
class JobSample:
    category: str
    wait_seconds: Optional[float]
    net_seconds: Optional[float]
    source: str = "log"
    phases: Mapping[str, float] = field(default_factory=dict)
    failed: Optional[bool] = None


def classify(text: str) -> Optional[str]:
    executed = [int(n) for n in _EXECUTED.findall(text)]
    if "ci_app_test_runner" in text and executed:
        scope = "full-suite" if max(executed) >= 1000 else "focused"
        if _APP_COMPILE.search(text):
            return f"test {scope}: app recompiled"
        if _TEST_COMPILE.search(text):
            return f"test {scope}: tests recompiled"
        return f"test {scope}: nothing compiled"
    if "package_app" in text:
        return "package: app recompiled" if _APP_COMPILE.search(text) else "package: no app compile"
    return None


def classification_lines(path: Path) -> str:
    """Keep only classification and wait evidence while scanning the full log."""
    selected: Dict[str, str] = {}
    max_executed = 0
    with path.open("r", encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            match = _EXECUTED.search(line)
            if match:
                max_executed = max(max_executed, int(match.group(1)))
            for key, present in (
                ("runner", "ci_app_test_runner" in line),
                ("package", "package_app" in line),
                ("app_compile", bool(_APP_COMPILE.search(line))),
                ("test_compile", bool(_TEST_COMPILE.search(line))),
                ("wait", bool(_WAIT.search(line))),
            ):
                if present and key not in selected:
                    selected[key] = line
    if max_executed:
        selected["executed"] = f"Executed {max_executed} tests, with 0 failures\n"
    return "".join(selected.values())


def sample_log(text: str, elapsed_seconds: float) -> Optional[JobSample]:
    wait_match = _WAIT.search(text)
    wait = parse_duration(wait_match.group(1)) if wait_match else None
    category = classify(text)
    if category is None and wait is None:
        return None
    net = elapsed_seconds - (wait or 0.0) if wait is not None else None
    if net is not None and net < 0:
        net = None
    return JobSample(category or "other", wait, net)


def load_timing_record(log_path: Path) -> Optional[Dict[str, Any]]:
    """Return the structured segments conductor persisted for this job log, if valid."""
    try:
        record = json.loads(log_path.with_suffix(TIMING_RECORD_SUFFIX).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(record, dict) or record.get("schemaVersion") != TIMING_SCHEMA_VERSION:
        return None
    timings = record.get("phaseTimings")
    segments = timings.get("segments") if isinstance(timings, dict) else None
    if not isinstance(segments, dict):
        return None
    result = {key: float(value) for key, value in segments.items() if isinstance(value, (int, float))}
    if record.get("state") in ("completed", "failed", "canceled"):
        result["__failed"] = float(record["state"] != "completed" or record.get("exitCode") != 0)
    return result


def sample_structured(text: str, segments: Mapping[str, float]) -> Optional[JobSample]:
    """Sample from structured segments: net = lane admission to finish, minus heavy-slot wait."""
    wait = segments.get("heavySlotWaitSeconds")
    category = classify(text)
    if category is None and wait is None:
        return None
    net: Optional[float] = None
    total = segments.get("totalSeconds")
    if total is not None:
        net = max(0.0, total - segments.get("queueSeconds", 0.0) - (wait or 0.0))
    return JobSample(category or "other", wait, net, "structured",
                     {key: value for key, value in segments.items() if key != "__failed"},
                     bool(segments["__failed"]) if "__failed" in segments else None)


def file_elapsed(path: Path) -> float:
    stat = path.stat()
    born = getattr(stat, "st_birthtime", stat.st_ctime)
    return max(0.0, stat.st_mtime - born)


def iter_logs(state_root: Path, limit: int) -> List[Path]:
    logs = [p for p in state_root.glob("*/jobs/*.log") if p.is_file()]
    logs.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return logs[:limit]


def percentile(values: Sequence[float], fraction: float) -> float:
    ordered = sorted(values)
    if not ordered:
        return 0.0
    index = min(len(ordered) - 1, max(0, int(round(fraction * (len(ordered) - 1)))))
    return ordered[index]


def summarize(samples: Iterable[JobSample]) -> Dict[str, Dict[str, float]]:
    samples = list(samples)
    waits: List[float] = []
    by_category: Dict[str, List[float]] = {}
    by_phase: Dict[str, Dict[str, List[float]]] = {}
    for sample in samples:
        if sample.wait_seconds is not None:
            waits.append(sample.wait_seconds)
        if sample.category != "other" and sample.net_seconds is not None and sample.failed is not True:
            by_category.setdefault(sample.category, []).append(sample.net_seconds)
        if sample.category != "other" and sample.source == "structured" and sample.failed is not True:
            for segment in PHASE_SUMMARY_SEGMENTS:
                if segment in sample.phases:
                    by_phase.setdefault(sample.category, {}).setdefault(segment, []).append(sample.phases[segment])

    def stats(values: Sequence[float]) -> Dict[str, float]:
        return {
            "n": len(values),
            "p50_s": round(percentile(values, 0.5), 1),
            "p75_s": round(percentile(values, 0.75), 1),
            "p90_s": round(percentile(values, 0.9), 1),
        }

    summary = {"heavy-slot wait": stats(waits)}
    summary["coverage"] = {
        "n": len(samples),
        "unclassified": sum(sample.category == "other" for sample in samples),
        "without_duration": sum(sample.net_seconds is None for sample in samples),
        "truncated": 0,
        "failed_known": sum(sample.failed is True for sample in samples),
        "failure_status_unknown": sum(sample.failed is None for sample in samples),
    }
    for category in sorted(by_category):
        summary[f"net {category}"] = stats(by_category[category])
    for category in sorted(by_phase):
        for segment in PHASE_SUMMARY_SEGMENTS:
            values = by_phase[category].get(segment)
            if values:
                summary[f"phase {category}: {segment}"] = stats(values)
    return summary


def collect(state_root: Path, limit: int, elapsed: Callable[[Path], float] = file_elapsed) -> List[JobSample]:
    samples = []
    for path in iter_logs(state_root, limit):
        try:
            text = classification_lines(path)
            segments = load_timing_record(path)
            sample = sample_structured(text, segments) if segments is not None else sample_log(text, elapsed(path))
        except OSError:
            continue
        samples.append(sample or JobSample("other", None, None))
    return samples


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--state-root", type=Path, default=DEFAULT_STATE_ROOT)
    parser.add_argument("--limit", type=int, default=3000)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    if not args.state_root.is_dir():
        print(f"no conductor state at {args.state_root}", file=sys.stderr)
        return 1
    summary = summarize(collect(args.state_root, args.limit))
    if args.json:
        print(json.dumps(summary, indent=2))
    else:
        for name, row in summary.items():
            if name == "coverage":
                print(f"coverage: scanned={int(row['n'])} unclassified={int(row['unclassified'])} "
                      f"without_duration={int(row['without_duration'])} "
                      f"failed_known={int(row['failed_known'])} "
                      f"failure_status_unknown={int(row['failure_status_unknown'])} truncated=0")
                continue
            if name.startswith("phase "):
                print(f"{name:40} n={int(row['n']):5}  p50={row['p50_s']:6.1f}s  "
                      f"p75={row['p75_s']:6.1f}s  p90={row['p90_s']:6.1f}s")
                continue
            print(f"{name:40} n={int(row['n']):5}  p50={row['p50_s'] / 60:6.1f}m  "
                  f"p75={row['p75_s'] / 60:6.1f}m  p90={row['p90_s'] / 60:6.1f}m")
    return 0


if __name__ == "__main__":
    sys.exit(main())
