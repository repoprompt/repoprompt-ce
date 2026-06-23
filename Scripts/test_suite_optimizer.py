#!/usr/bin/env python3
"""Inventory and baseline tooling for RepoPrompt CE XCTest optimization."""

from __future__ import annotations

import argparse
import csv
import dataclasses
import datetime as dt
import hashlib
import json
import math
import re
import statistics
import subprocess
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable, Sequence

LEDGER_COLUMNS = [
    "method_id",
    "target",
    "file",
    "suite",
    "method",
    "domain",
    "primary_contract_id",
    "secondary_contract_tags",
    "validation_class",
    "layer",
    "scenario_count",
    "fixture_ids",
    "observable_oracle",
    "failure_risk",
    "runtime_seconds",
    "resource_cost_tags",
    "shared_state_tags",
    "lifecycle_owner",
    "current_disposition",
    "replacement_method_id",
    "preserved_scenario_delta",
    "notes",
]

LISTED_TEST_RE = re.compile(
    r"^(?P<suite>[A-Za-z_][A-Za-z0-9_.]*)/(?P<method>test[A-Za-z0-9_]+)$"
)
SOURCE_SUITE_RE = re.compile(
    r"\b(?:final\s+)?(?:class|extension)\s+(?P<suite>[A-Za-z_][A-Za-z0-9_]*)\b"
)
SOURCE_METHOD_RE = re.compile(
    r"\bfunc\s+(?P<method>test[A-Za-z0-9_]+)\s*(?:<[^>]+>\s*)?\("
)
XCTEST_CASE_RE = re.compile(
    r"^Test Case '(?:-\[(?P<objc_suite>[A-Za-z_][A-Za-z0-9_.]*)\s+"
    r"(?P<objc_method>test[A-Za-z0-9_]+)\]|(?P<dotted>[A-Za-z_][A-Za-z0-9_.]*))' "
    r"(?P<status>passed|failed|skipped)(?: \((?P<paren_seconds>[0-9.]+) seconds\)"
    r"| after (?P<after_seconds>[0-9.]+) seconds)?\.\s*$"
)


class OptimizerError(RuntimeError):
    """Raised when inventory or measurement evidence is inconsistent."""


@dataclasses.dataclass(frozen=True, order=True)
class ListedTest:
    target: str
    suite: str
    method: str

    @property
    def method_id(self) -> str:
        return f"{self.target}/{self.suite}/{self.method}"


@dataclasses.dataclass(frozen=True)
class SourceLocation:
    file: str
    line: int
    domain: str


@dataclasses.dataclass(frozen=True)
class TestCaseTiming:
    suite: str
    method: str
    status: str
    seconds: float


@dataclasses.dataclass
class ConductorRun:
    command: list[str]
    process_exit_code: int
    stdout: str
    stderr: str
    result: dict[str, Any]
    log_text: str


@dataclasses.dataclass
class Sample:
    index: int
    target: str
    command: list[str]
    process_exit_code: int
    state: str
    exit_code: int | None
    queue_wait_seconds: float | None
    execution_seconds: float | None
    timed_out: bool
    measurement_invalid: bool
    diagnostic_paths: list[str]
    log_path: str
    invalid_reasons: list[str]
    timings: list[TestCaseTiming]

    @property
    def valid(self) -> bool:
        return not self.invalid_reasons


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def parse_test_list(text: str, target: str) -> list[ListedTest]:
    tests: list[ListedTest] = []
    seen: set[str] = set()
    for raw_line in text.splitlines():
        line = raw_line.strip()
        match = LISTED_TEST_RE.fullmatch(line)
        if not match:
            continue
        test = ListedTest(target=target, suite=match.group("suite"), method=match.group("method"))
        if test.method_id in seen:
            raise OptimizerError(f"duplicate listed test identifier: {test.method_id}")
        seen.add(test.method_id)
        tests.append(test)
    if not tests:
        raise OptimizerError(f"no discoverable XCTest methods found in {target} test list")
    return sorted(tests)


def parse_xctest_timings(text: str) -> list[TestCaseTiming]:
    timings: list[TestCaseTiming] = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        match = XCTEST_CASE_RE.fullmatch(line)
        if not match:
            continue
        if match.group("objc_suite"):
            suite = match.group("objc_suite")
            method = match.group("objc_method")
        else:
            dotted = match.group("dotted") or ""
            if "." not in dotted:
                continue
            suite, method = dotted.rsplit(".", 1)
        seconds_text = match.group("paren_seconds") or match.group("after_seconds") or "0"
        timings.append(
            TestCaseTiming(
                suite=suite,
                method=method,
                status=match.group("status"),
                seconds=float(seconds_text),
            )
        )
    return timings


def nearest_rank_p95(values: Sequence[float]) -> float:
    if not values:
        raise OptimizerError("cannot calculate p95 without values")
    ordered = sorted(values)
    rank = max(1, math.ceil(0.95 * len(ordered)))
    return ordered[rank - 1]


def relative_mad(values: Sequence[float]) -> float:
    if not values:
        raise OptimizerError("cannot calculate relative MAD without values")
    median = statistics.median(values)
    if median == 0:
        return 0.0 if all(value == 0 for value in values) else math.inf
    mad = statistics.median(abs(value - median) for value in values)
    return mad / median


def noise_classification(value: float) -> str:
    if value <= 0.05:
        return "stable"
    if value <= 0.10:
        return "noisy"
    return "unstable"


def repo_root_from_script() -> Path:
    return Path(__file__).resolve().parent.parent


def run_command(command: Sequence[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(command),
        cwd=str(cwd),
        capture_output=True,
        text=True,
        check=False,
    )


def parse_conductor_json(stdout: str) -> dict[str, Any]:
    try:
        payload = json.loads(stdout)
    except json.JSONDecodeError as exc:
        raise OptimizerError(f"conductor did not return valid JSON: {exc}: {stdout[-1000:]}") from exc
    if not isinstance(payload, dict) or not isinstance(payload.get("result"), dict):
        raise OptimizerError("conductor JSON is missing the terminal result payload")
    return payload


def run_conductor(repo_root: Path, target: str, list_mode: bool = False) -> ConductorRun:
    operation = "test" if target == "root" else "provider-test"
    command = [str(repo_root / "conductor"), operation]
    if list_mode:
        command.append("--list")
    command.append("--json")
    completed = run_command(command, repo_root)
    payload = parse_conductor_json(completed.stdout)
    result = payload["result"]
    log_path = Path(str(result.get("logPath") or ""))
    log_text = log_path.read_text(encoding="utf-8", errors="replace") if log_path.is_file() else ""
    return ConductorRun(
        command=command,
        process_exit_code=completed.returncode,
        stdout=completed.stdout,
        stderr=completed.stderr,
        result=result,
        log_text=log_text,
    )


def source_roots(repo_root: Path, target: str) -> list[Path]:
    if target == "root":
        return [repo_root / "Tests" / "RepoPromptTests"]
    return [
        repo_root
        / "Packages"
        / "RepoPromptAgentProviders"
        / "Tests"
        / "RepoPromptClaudeCompatibleProviderTests"
    ]


def source_files(repo_root: Path, target: str) -> list[Path]:
    files: list[Path] = []
    for root in source_roots(repo_root, target):
        files.extend(sorted(root.rglob("*.swift")))
    return files


def domain_for_file(repo_root: Path, target: str, path: Path) -> str:
    root = source_roots(repo_root, target)[0]
    relative = path.relative_to(root)
    if target == "provider":
        return f"Provider/{relative.parts[0] if len(relative.parts) > 1 else 'General'}"
    return relative.parts[0] if len(relative.parts) > 1 else "Root"


def build_source_index(
    repo_root: Path,
    target: str,
) -> tuple[dict[str, set[Path]], dict[str, set[Path]], dict[tuple[Path, str], int]]:
    suites: dict[str, set[Path]] = defaultdict(set)
    methods: dict[str, set[Path]] = defaultdict(set)
    method_lines: dict[tuple[Path, str], int] = {}
    for path in source_files(repo_root, target):
        text = path.read_text(encoding="utf-8", errors="replace")
        for match in SOURCE_SUITE_RE.finditer(text):
            suites[match.group("suite")].add(path)
        for match in SOURCE_METHOD_RE.finditer(text):
            method = match.group("method")
            methods[method].add(path)
            method_lines.setdefault((path, method), text.count("\n", 0, match.start()) + 1)
    return suites, methods, method_lines


def map_test_sources(
    repo_root: Path,
    tests: Sequence[ListedTest],
) -> dict[str, SourceLocation]:
    by_target: dict[str, list[ListedTest]] = defaultdict(list)
    for test in tests:
        by_target[test.target].append(test)
    result: dict[str, SourceLocation] = {}
    errors: list[str] = []
    for target, target_tests in sorted(by_target.items()):
        suites, methods, method_lines = build_source_index(repo_root, target)
        for test in target_tests:
            suite_name = test.suite.rsplit(".", 1)[-1]
            candidates = suites.get(suite_name, set()) & methods.get(test.method, set())
            if not candidates:
                method_candidates = methods.get(test.method, set())
                stem_candidates = {path for path in method_candidates if path.stem == suite_name}
                candidates = stem_candidates or method_candidates
            if len(candidates) != 1:
                display = ", ".join(sorted(str(path.relative_to(repo_root)) for path in candidates)) or "none"
                errors.append(f"{test.method_id}: expected one source file, found {display}")
                continue
            path = next(iter(candidates))
            result[test.method_id] = SourceLocation(
                file=str(path.relative_to(repo_root)),
                line=method_lines.get((path, test.method), 0),
                domain=domain_for_file(repo_root, target, path),
            )
    if errors:
        raise OptimizerError("source mapping failed:\n" + "\n".join(errors[:100]))
    return result


def ledger_rows(
    tests: Sequence[ListedTest],
    locations: dict[str, SourceLocation],
) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for test in sorted(tests):
        location = locations[test.method_id]
        rows.append(
            {
                "method_id": test.method_id,
                "target": test.target,
                "file": location.file,
                "suite": test.suite,
                "method": test.method,
                "domain": location.domain,
                "primary_contract_id": "unreviewed",
                "secondary_contract_tags": "",
                "validation_class": "unreviewed",
                "layer": "root_swiftpm" if test.target == "root" else "provider_package",
                "scenario_count": "1",
                "fixture_ids": "",
                "observable_oracle": "unreviewed",
                "failure_risk": "unreviewed",
                "runtime_seconds": "",
                "resource_cost_tags": "",
                "shared_state_tags": "",
                "lifecycle_owner": "unreviewed",
                "current_disposition": "retain_pending_review",
                "replacement_method_id": "",
                "preserved_scenario_delta": "0",
                "notes": f"initial census source line {location.line}",
            }
        )
    return rows


def write_tsv(path: Path, rows: Sequence[dict[str, str]], force: bool = False) -> None:
    if path.exists() and not force:
        raise OptimizerError(f"refusing to overwrite existing ledger: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=LEDGER_COLUMNS, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def read_ledger_ids(path: Path) -> list[str]:
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        if reader.fieldnames != LEDGER_COLUMNS:
            raise OptimizerError("ledger columns do not match the required schema")
        ids = [str(row.get("method_id") or "") for row in reader]
    if len(ids) != len(set(ids)):
        raise OptimizerError("ledger contains duplicate method_id rows")
    return ids


def git_metadata(repo_root: Path) -> dict[str, str]:
    commit = run_command(["git", "rev-parse", "HEAD"], repo_root)
    status = run_command(["git", "status", "--short"], repo_root)
    return {
        "commit": commit.stdout.strip() if commit.returncode == 0 else "unknown",
        "working_tree": status.stdout.rstrip(),
    }


def measurement_source_fingerprint(repo_root: Path) -> str:
    digest = hashlib.sha256()
    roots = [
        repo_root / "Package.swift",
        repo_root / "Sources",
        repo_root / "Tests",
        repo_root / "Packages" / "RepoPromptAgentProviders" / "Package.swift",
        repo_root / "Packages" / "RepoPromptAgentProviders" / "Sources",
        repo_root / "Packages" / "RepoPromptAgentProviders" / "Tests",
    ]
    files: list[Path] = []
    for root in roots:
        if root.is_file():
            files.append(root)
        elif root.is_dir():
            files.extend(path for path in root.rglob("*") if path.is_file() and path.suffix in {".swift", ".c", ".h"})
    for path in sorted(files):
        digest.update(str(path.relative_to(repo_root)).encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def sample_invalid_reasons(
    process_exit_code: int,
    result: dict[str, Any],
    source_changed: bool,
) -> list[str]:
    reasons: list[str] = []
    if process_exit_code != 0:
        reasons.append(f"conductor process exit {process_exit_code}")
    if result.get("state") != "completed":
        reasons.append(f"terminal state {result.get('state')}")
    if result.get("exitCode") != 0:
        reasons.append(f"test exit {result.get('exitCode')}")
    if result.get("timedOut"):
        reasons.append("timed out")
    if result.get("measurementInvalid"):
        reasons.append("conductor marked measurement invalid")
    if result.get("cancelRequested") or result.get("supersededByTicket"):
        reasons.append("canceled or lifecycle-superseded")
    if source_changed:
        reasons.append("measurement source changed during execution")
    if result.get("executionSeconds") is None:
        reasons.append("missing conductor execution timing")
    return reasons


def sample_from_run(
    index: int,
    target: str,
    run: ConductorRun,
    source_changed: bool,
) -> Sample:
    result = run.result
    return Sample(
        index=index,
        target=target,
        command=run.command,
        process_exit_code=run.process_exit_code,
        state=str(result.get("state") or "unknown"),
        exit_code=result.get("exitCode"),
        queue_wait_seconds=result.get("queueWaitSeconds"),
        execution_seconds=result.get("executionSeconds"),
        timed_out=bool(result.get("timedOut")),
        measurement_invalid=bool(result.get("measurementInvalid")),
        diagnostic_paths=[str(path) for path in result.get("diagnosticPaths") or []],
        log_path=str(result.get("logPath") or ""),
        invalid_reasons=sample_invalid_reasons(run.process_exit_code, result, source_changed),
        timings=parse_xctest_timings(run.log_text),
    )


def suite_ranking(samples: Sequence[Sample]) -> list[dict[str, Any]]:
    per_suite_totals: dict[str, list[float]] = defaultdict(list)
    methods: dict[str, set[str]] = defaultdict(set)
    maximums: dict[str, float] = defaultdict(float)
    failures: dict[str, int] = defaultdict(int)
    for sample in samples:
        sample_totals: dict[str, float] = defaultdict(float)
        for timing in sample.timings:
            sample_totals[timing.suite] += timing.seconds
            methods[timing.suite].add(timing.method)
            maximums[timing.suite] = max(maximums[timing.suite], timing.seconds)
            if timing.status != "passed":
                failures[timing.suite] += 1
        for suite, total in sample_totals.items():
            per_suite_totals[suite].append(total)
    ranking = [
        {
            "suite": suite,
            "method_count": len(methods[suite]),
            "median_aggregate_seconds": statistics.median(totals),
            "max_method_seconds": maximums[suite],
            "failure_or_skip_count": failures[suite],
        }
        for suite, totals in per_suite_totals.items()
    ]
    return sorted(
        ranking,
        key=lambda row: (row["median_aggregate_seconds"], row["max_method_seconds"], row["suite"]),
        reverse=True,
    )


def sample_to_dict(sample: Sample) -> dict[str, Any]:
    return {
        "index": sample.index,
        "target": sample.target,
        "command": sample.command,
        "process_exit_code": sample.process_exit_code,
        "state": sample.state,
        "exit_code": sample.exit_code,
        "queue_wait_seconds": sample.queue_wait_seconds,
        "execution_seconds": sample.execution_seconds,
        "timed_out": sample.timed_out,
        "measurement_invalid": sample.measurement_invalid,
        "diagnostic_paths": sample.diagnostic_paths,
        "log_path": sample.log_path,
        "valid": sample.valid,
        "invalid_reasons": sample.invalid_reasons,
        "parsed_test_case_timings": len(sample.timings),
    }


def baseline_summary(samples: Sequence[Sample]) -> dict[str, Any]:
    valid = [sample for sample in samples if sample.valid and sample.execution_seconds is not None]
    values = [float(sample.execution_seconds) for sample in valid]
    if not values:
        raise OptimizerError("baseline produced no valid samples")
    rel_mad = relative_mad(values)
    return {
        "valid_samples": len(valid),
        "invalid_samples": len(samples) - len(valid),
        "raw_execution_seconds": values,
        "median_seconds": statistics.median(values),
        "observed_p95_seconds": nearest_rank_p95(values),
        "relative_mad": rel_mad,
        "noise_classification": noise_classification(rel_mad),
    }


def scoreboard_scaffold() -> str:
    return """# RepoPrompt CE XCTest Optimization Runs

## Measurement contract

- Primary metric: warm local root `swift test` conductor execution seconds.
- Structural target: approximately 877 executable first-party XCTest methods.
- Count authority: coordinated root/provider `swift test list`.
- Root and provider timings remain separate.
- CI class-per-process timing is not summed as local root wall clock.
- Rows and corrections are append-only; corrections supersede rather than rewrite history.

## Baseline summary

| Date/commit | Topology | Samples | Root methods | Provider methods | Total | Median seconds | Observed p95 | Relative MAD | Notes |
|---|---|---:|---:|---:|---:|---:|---:|---:|---|

## Iteration ledger

| Iteration | Commit/range | Attributed change | Root methods | Provider methods | Total methods | Method delta | Contract delta | Scenario delta | Root median | Root p95 | Provider median | Slowest suites | Lifecycle defects fixed | Added | Removed | Consolidated | Validation and exit codes | Decision |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---:|---:|---:|---|---|

## Reverted attempts

| Date | Iteration | Attempt | Reason reverted | Count delta | Median delta | p95 delta | Correctness/lifecycle evidence | Artifact paths |
|---|---|---|---|---:|---:|---:|---|---|

## Baseline run records

"""


def ensure_scoreboard(path: Path) -> None:
    if path.exists():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(scoreboard_scaffold(), encoding="utf-8")


def format_seconds(value: float | None) -> str:
    return "" if value is None else f"{value:.3f}"


def append_baseline_scoreboard(
    path: Path,
    payload: dict[str, Any],
    method_counts: dict[str, int] | None,
) -> None:
    ensure_scoreboard(path)
    target = payload["target"]
    summary = payload["summary"]
    metadata = payload["git"]
    counts = method_counts or {}
    root_count = counts.get("root", 0)
    provider_count = counts.get("provider", 0)
    total_count = root_count + provider_count if counts else 0
    lines = [
        f"### {payload['timestamp']} — {target} — {payload['label']}",
        "",
        f"Command: `{' '.join(payload['command'])}`",
        "",
        "| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |",
        "|---:|---|---:|---:|---|---:|---|---|---|",
    ]
    for sample in payload["samples"]:
        reasons = "; ".join(sample["invalid_reasons"])
        lines.append(
            "| {index} | {valid} | {execution} | {queue} | {state} | {exit_code} | {invalid} | `{log}` | {reasons} |".format(
                index=sample["index"],
                valid="yes" if sample["valid"] else "no",
                execution=format_seconds(sample["execution_seconds"]),
                queue=format_seconds(sample["queue_wait_seconds"]),
                state=sample["state"],
                exit_code=sample["exit_code"],
                invalid="yes" if sample["measurement_invalid"] else "no",
                log=sample["log_path"],
                reasons=reasons,
            )
        )
    lines.extend(
        [
            "",
            "| Date/commit | Topology | Samples | Root methods | Provider methods | Total | Median seconds | Observed p95 | Relative MAD | Notes |",
            "|---|---|---:|---:|---:|---:|---:|---:|---:|---|",
            "| {date}/{commit} | warm local {target} one-process conductor run | {valid} valid + {invalid} invalid | {root} | {provider} | {total} | {median:.3f} | {p95:.3f} | {mad:.4f} | {noise}; build-lane coordinated |".format(
                date=payload["timestamp"],
                commit=metadata["commit"][:12],
                target=target,
                valid=summary["valid_samples"],
                invalid=summary["invalid_samples"],
                root=root_count or "",
                provider=provider_count or "",
                total=total_count or "",
                median=summary["median_seconds"],
                p95=summary["observed_p95_seconds"],
                mad=summary["relative_mad"],
                noise=summary["noise_classification"],
            ),
            "",
        ]
    )
    if target == "root":
        lines.extend(
            [
                "20 slowest suites by median aggregate XCTest case seconds across valid samples:",
                "",
                "| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |",
                "|---:|---|---:|---:|---:|---:|",
            ]
        )
        for index, row in enumerate(payload["slowest_suites"][:20], start=1):
            lines.append(
                f"| {index} | `{row['suite']}` | {row['method_count']} | "
                f"{row['median_aggregate_seconds']:.3f} | {row['max_method_seconds']:.3f} | "
                f"{row['failure_or_skip_count']} |"
            )
        lines.append("")
    with path.open("a", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


def write_json_new(path: Path, payload: dict[str, Any]) -> None:
    if path.exists():
        raise OptimizerError(f"refusing to overwrite existing artifact: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def inventory(repo_root: Path, ledger: Path, output: Path | None, force: bool) -> dict[str, Any]:
    runs = {target: run_conductor(repo_root, target, list_mode=True) for target in ("root", "provider")}
    tests: list[ListedTest] = []
    for target, run in runs.items():
        if run.process_exit_code != 0 or run.result.get("state") != "completed" or run.result.get("exitCode") != 0:
            raise OptimizerError(f"{target} test list failed; log: {run.result.get('logPath')}")
        tests.extend(parse_test_list(run.log_text, target))
    locations = map_test_sources(repo_root, tests)
    write_tsv(ledger, ledger_rows(tests, locations), force=force)
    counts = {
        "root": sum(test.target == "root" for test in tests),
        "provider": sum(test.target == "provider" for test in tests),
    }
    payload = {
        "timestamp": utc_now(),
        "git": git_metadata(repo_root),
        "counts": {**counts, "total": counts["root"] + counts["provider"]},
        "ledger": str(ledger),
        "list_runs": {
            target: {
                "command": run.command,
                "process_exit_code": run.process_exit_code,
                "state": run.result.get("state"),
                "exit_code": run.result.get("exitCode"),
                "queue_wait_seconds": run.result.get("queueWaitSeconds"),
                "execution_seconds": run.result.get("executionSeconds"),
                "log_path": run.result.get("logPath"),
            }
            for target, run in runs.items()
        },
    }
    if output:
        write_json_new(output, payload)
    return payload


def verify_ledger(repo_root: Path, ledger: Path) -> dict[str, Any]:
    listed: list[ListedTest] = []
    logs: dict[str, str] = {}
    for target in ("root", "provider"):
        run = run_conductor(repo_root, target, list_mode=True)
        if run.process_exit_code != 0 or run.result.get("exitCode") != 0:
            raise OptimizerError(f"{target} test list failed; log: {run.result.get('logPath')}")
        listed.extend(parse_test_list(run.log_text, target))
        logs[target] = str(run.result.get("logPath") or "")
    listed_ids = sorted(test.method_id for test in listed)
    ledger_ids = sorted(read_ledger_ids(ledger))
    missing = sorted(set(listed_ids) - set(ledger_ids))
    stale = sorted(set(ledger_ids) - set(listed_ids))
    if missing or stale:
        raise OptimizerError(
            f"ledger mismatch: missing={len(missing)} stale={len(stale)} "
            f"missing_examples={missing[:5]} stale_examples={stale[:5]}"
        )
    return {"count": len(listed_ids), "logs": logs, "ledger": str(ledger)}


def baseline(
    repo_root: Path,
    target: str,
    samples_requested: int,
    label: str,
    scoreboard: Path,
    output: Path,
    method_counts: dict[str, int] | None,
) -> dict[str, Any]:
    if samples_requested <= 0:
        raise OptimizerError("--samples must be greater than zero")
    samples: list[Sample] = []
    command = [str(repo_root / "conductor"), "test" if target == "root" else "provider-test", "--json"]
    for index in range(1, samples_requested + 1):
        before = measurement_source_fingerprint(repo_root)
        run = run_conductor(repo_root, target, list_mode=False)
        after = measurement_source_fingerprint(repo_root)
        samples.append(sample_from_run(index, target, run, source_changed=before != after))
    valid_samples = [sample for sample in samples if sample.valid]
    payload = {
        "timestamp": utc_now(),
        "target": target,
        "label": label,
        "command": command,
        "git": git_metadata(repo_root),
        "samples": [sample_to_dict(sample) for sample in samples],
        "summary": baseline_summary(samples),
        "slowest_suites": suite_ranking(valid_samples),
    }
    write_json_new(output, payload)
    append_baseline_scoreboard(scoreboard, payload, method_counts)
    return payload


def load_counts(path: Path | None) -> dict[str, int] | None:
    if path is None:
        return None
    payload = json.loads(path.read_text(encoding="utf-8"))
    counts = payload.get("counts") or {}
    return {"root": int(counts.get("root") or 0), "provider": int(counts.get("provider") or 0)}


def combine_baselines(paths: Sequence[Path], top: int = 20) -> dict[str, Any]:
    samples: list[dict[str, Any]] = []
    timing_samples: list[Sample] = []
    targets: set[str] = set()
    for path in paths:
        payload = json.loads(path.read_text(encoding="utf-8"))
        target = str(payload.get("target") or "")
        targets.add(target)
        for raw_sample in payload.get("samples") or []:
            sample = dict(raw_sample)
            sample["source_artifact"] = str(path)
            samples.append(sample)
            if sample.get("valid"):
                log_path = Path(str(sample.get("log_path") or ""))
                log_text = log_path.read_text(encoding="utf-8", errors="replace") if log_path.is_file() else ""
                timing_samples.append(
                    Sample(
                        index=len(timing_samples) + 1,
                        target=target,
                        command=list(sample.get("command") or []),
                        process_exit_code=int(sample.get("process_exit_code") or 0),
                        state=str(sample.get("state") or "completed"),
                        exit_code=sample.get("exit_code"),
                        queue_wait_seconds=sample.get("queue_wait_seconds"),
                        execution_seconds=sample.get("execution_seconds"),
                        timed_out=bool(sample.get("timed_out")),
                        measurement_invalid=bool(sample.get("measurement_invalid")),
                        diagnostic_paths=list(sample.get("diagnostic_paths") or []),
                        log_path=str(log_path),
                        invalid_reasons=list(sample.get("invalid_reasons") or []),
                        timings=parse_xctest_timings(log_text),
                    )
                )
    if len(targets) != 1:
        raise OptimizerError(f"combined baselines must have one target, found: {sorted(targets)}")
    values = [float(sample["execution_seconds"]) for sample in samples if sample.get("valid")]
    if not values:
        raise OptimizerError("combined baselines contain no valid samples")
    rel_mad = relative_mad(values)
    return {
        "timestamp": utc_now(),
        "target": next(iter(targets)),
        "source_artifacts": [str(path) for path in paths],
        "samples": samples,
        "summary": {
            "attempts": len(samples),
            "valid_samples": len(values),
            "invalid_samples": len(samples) - len(values),
            "raw_execution_seconds": values,
            "median_seconds": statistics.median(values),
            "observed_p95_seconds": nearest_rank_p95(values),
            "relative_mad": rel_mad,
            "noise_classification": noise_classification(rel_mad),
            "reliable": len(values) >= 3,
        },
        "slowest_suites": suite_ranking(timing_samples)[:top],
    }


def compare_baselines(before: Path, after: Path) -> dict[str, Any]:
    before_payload = json.loads(before.read_text(encoding="utf-8"))
    after_payload = json.loads(after.read_text(encoding="utf-8"))
    before_summary = before_payload.get("summary") or {}
    after_summary = after_payload.get("summary") or {}
    before_median = float(before_summary["median_seconds"])
    after_median = float(after_summary["median_seconds"])
    before_p95 = float(before_summary["observed_p95_seconds"])
    after_p95 = float(after_summary["observed_p95_seconds"])
    return {
        "before": str(before),
        "after": str(after),
        "median_delta_seconds": after_median - before_median,
        "median_delta_fraction": (after_median - before_median) / before_median if before_median else math.inf,
        "p95_delta_seconds": after_p95 - before_p95,
        "p95_delta_fraction": (after_p95 - before_p95) / before_p95 if before_p95 else math.inf,
    }


def rank_logs(paths: Sequence[Path], top: int) -> dict[str, Any]:
    samples = [
        Sample(
            index=index,
            target="root",
            command=[],
            process_exit_code=0,
            state="completed",
            exit_code=0,
            queue_wait_seconds=None,
            execution_seconds=0.0,
            timed_out=False,
            measurement_invalid=False,
            diagnostic_paths=[],
            log_path=str(path),
            invalid_reasons=[],
            timings=parse_xctest_timings(path.read_text(encoding="utf-8", errors="replace")),
        )
        for index, path in enumerate(paths, start=1)
    ]
    return {"logs": [str(path) for path in paths], "ranking": suite_ranking(samples)[:top]}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    inventory_parser = subparsers.add_parser("inventory", help="list tests and generate the ledger scaffold")
    inventory_parser.add_argument("--ledger", type=Path, required=True)
    inventory_parser.add_argument("--output", type=Path)
    inventory_parser.add_argument("--force", action="store_true")

    baseline_parser = subparsers.add_parser("baseline", help="collect coordinated warm timing samples")
    baseline_parser.add_argument("--target", choices=["root", "provider"], required=True)
    baseline_parser.add_argument("--samples", type=int, required=True)
    baseline_parser.add_argument("--label", default="warm-baseline")
    baseline_parser.add_argument("--scoreboard", type=Path, required=True)
    baseline_parser.add_argument("--output", type=Path, required=True)
    baseline_parser.add_argument("--inventory", type=Path)

    combine_parser = subparsers.add_parser("combine-baselines", help="combine append-only baseline artifacts")
    combine_parser.add_argument("--input", action="append", type=Path, required=True)
    combine_parser.add_argument("--output", type=Path, required=True)
    combine_parser.add_argument("--top", type=int, default=20)

    compare_parser = subparsers.add_parser("compare", help="compare two baseline summary artifacts")
    compare_parser.add_argument("--before", type=Path, required=True)
    compare_parser.add_argument("--after", type=Path, required=True)

    rank_parser = subparsers.add_parser("rank", help="rank suites from one or more XCTest logs")
    rank_parser.add_argument("--log", action="append", type=Path, required=True)
    rank_parser.add_argument("--top", type=int, default=20)

    verify_parser = subparsers.add_parser("verify-ledger", help="re-list tests and reconcile ledger rows")
    verify_parser.add_argument("--ledger", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    repo_root = repo_root_from_script()
    try:
        if args.command == "inventory":
            payload = inventory(repo_root, args.ledger, args.output, args.force)
        elif args.command == "baseline":
            payload = baseline(
                repo_root=repo_root,
                target=args.target,
                samples_requested=args.samples,
                label=args.label,
                scoreboard=args.scoreboard,
                output=args.output,
                method_counts=load_counts(args.inventory),
            )
        elif args.command == "combine-baselines":
            payload = combine_baselines(args.input, args.top)
            write_json_new(args.output, payload)
        elif args.command == "compare":
            payload = compare_baselines(args.before, args.after)
        elif args.command == "rank":
            payload = rank_logs(args.log, args.top)
        elif args.command == "verify-ledger":
            payload = verify_ledger(repo_root, args.ledger)
        else:
            raise OptimizerError(f"unsupported command: {args.command}")
    except (OSError, OptimizerError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
