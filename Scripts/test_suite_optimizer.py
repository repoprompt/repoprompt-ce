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
from typing import Any, Callable, Iterable, Sequence

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
    "execution_tier",
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
TEST_EXECUTION_TIERS = {
    "fast",
    "routine",
    "integration",
    "codemap_e2e",
    "scale",
    "diagnostic",
    "live_smoke",
    "release",
}
HEAVY_TEST_EXECUTION_TIERS = {"codemap_e2e", "scale", "diagnostic", "live_smoke", "release"}
DEFAULT_SMOKE_FLOOR_SUITES = [
    "RepoPromptTests.CodeMapArtifactKeyTests",
    "RepoPromptTests.CodexIntegrationConfigurationTests",
    "RepoPromptTests.WorkspaceFileContextStoreTests",
]
BROAD_IMPACT_PATH_PREFIXES = (
    ".github/",
    "Package.swift",
    "Package.resolved",
    "Makefile",
    "Scripts/conductor.py",
    "Scripts/test_suite_optimizer.py",
    "Scripts/Fixtures/test-suite-contract-ledger.tsv",
)

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
MEASUREMENT_SOURCE_SUFFIXES = {".swift", ".c", ".h"}
SOURCE_GUARD_CONTENT = "content"
SOURCE_GUARD_METADATA = "metadata"
PROGRESS_PREFIX = "test_suite_optimizer.progress "
LIST_COMMAND_TIMEOUT_SECONDS = 1800
ProgressSink = Callable[[dict[str, Any]], None]


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


@dataclasses.dataclass(frozen=True)
class LedgerTest:
    method_id: str
    target: str
    file: str
    suite: str
    method: str
    domain: str
    layer: str
    execution_tier: str
    runtime_seconds: float | None
    resource_cost_tags: frozenset[str]
    shared_state_tags: frozenset[str]


@dataclasses.dataclass
class ConductorRun:
    command: list[str]
    process_exit_code: int
    stdout: str
    stderr: str
    result: dict[str, Any]
    log_text: str
    ticket: str | None = None


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
    source_guard_kind: str = SOURCE_GUARD_CONTENT
    source_changed: bool = False
    build: dict[str, Any] | None = None
    resource_usage: dict[str, Any] | None = None

    @property
    def valid(self) -> bool:
        return not self.invalid_reasons


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def progress_line(event: dict[str, Any]) -> str:
    return PROGRESS_PREFIX + json.dumps(event, sort_keys=True, separators=(",", ":"))


def emit_progress_event(event: dict[str, Any]) -> None:
    try:
        print(progress_line(event), file=sys.stderr, flush=True)
    except (BrokenPipeError, OSError):
        return


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


def run_command(
    command: Sequence[str],
    cwd: Path,
    timeout_seconds: int | None = None,
) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            list(command),
            cwd=str(cwd),
            capture_output=True,
            text=True,
            check=False,
            timeout=timeout_seconds,
        )
    except subprocess.TimeoutExpired as exc:
        raise OptimizerError(
            f"command timed out after {timeout_seconds}s: {' '.join(command)}"
        ) from exc


def parse_conductor_json(stdout: str) -> dict[str, Any]:
    try:
        payload = json.loads(stdout)
    except json.JSONDecodeError as exc:
        raise OptimizerError(f"conductor did not return valid JSON: {exc}: {stdout[-1000:]}") from exc
    if not isinstance(payload, dict) or not isinstance(payload.get("result"), dict):
        raise OptimizerError("conductor JSON is missing the terminal result payload")
    return payload


def conductor_ticket_from_payload(payload: dict[str, Any], result: dict[str, Any]) -> str | None:
    for source in (result, payload):
        value = source.get("ticket")
        if value is None:
            continue
        ticket = str(value)
        if ticket:
            return ticket
    return None


def conductor_command(
    repo_root: Path,
    target: str,
    list_mode: bool = False,
    filter_value: str | None = None,
    test_product: str | None = None,
) -> list[str]:
    if list_mode and filter_value:
        raise OptimizerError("--filter cannot be used with list mode")
    if list_mode and test_product:
        raise OptimizerError("--test-product cannot be used with list mode")
    operation = "test" if target == "root" else "provider-test"
    command = [str(repo_root / "conductor"), operation]
    if list_mode:
        command.append("--list")
    if test_product:
        command.extend(["--test-product", test_product])
    if filter_value:
        command.extend(["--filter", filter_value])
    command.append("--json")
    return command


def conductor_build_command(repo_root: Path, target: str) -> list[str]:
    if target != "root":
        raise OptimizerError("--build-before-samples currently supports only --target root")
    return [str(repo_root / "conductor"), "swift-build", "--product", "all", "--json"]


def run_conductor(
    repo_root: Path,
    target: str,
    list_mode: bool = False,
    filter_value: str | None = None,
    test_product: str | None = None,
    timeout_seconds: int | None = None,
) -> ConductorRun:
    command = conductor_command(
        repo_root,
        target,
        list_mode=list_mode,
        filter_value=filter_value,
        test_product=test_product,
    )
    completed = run_command(command, repo_root, timeout_seconds=timeout_seconds)
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
        ticket=conductor_ticket_from_payload(payload, result),
    )


def run_conductor_build(repo_root: Path, target: str) -> ConductorRun:
    command = conductor_build_command(repo_root, target)
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
        ticket=conductor_ticket_from_payload(payload, result),
    )


def source_roots(repo_root: Path, target: str) -> list[Path]:
    if target == "root":
        tests_root = repo_root / "Tests"
        if tests_root.is_dir():
            roots = [
                path
                for path in sorted(tests_root.iterdir())
                if path.is_dir() and any(path.rglob("*.swift"))
            ]
        else:
            roots = []
        return roots or [tests_root / "RepoPromptTests"]
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
    roots = source_roots(repo_root, target)
    root = next((candidate for candidate in roots if path.is_relative_to(candidate)), None)
    if root is None:
        raise OptimizerError(f"test source is outside known {target} roots: {path}")
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
                "execution_tier": "routine" if test.target == "root" else "fast",
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
    return [row.method_id for row in read_ledger_rows(path)]


def split_tags(value: str) -> frozenset[str]:
    return frozenset(tag.strip() for tag in re.split(r"[,; ]+", value or "") if tag.strip())


def parse_runtime_seconds(value: str) -> float | None:
    if not value:
        return None
    try:
        seconds = float(value)
    except ValueError as exc:
        raise OptimizerError(f"invalid runtime_seconds value: {value!r}") from exc
    if not math.isfinite(seconds) or seconds < 0:
        raise OptimizerError(f"invalid runtime_seconds value: {value!r}")
    return seconds


def read_ledger_rows(path: Path) -> list[LedgerTest]:
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        if reader.fieldnames != LEDGER_COLUMNS:
            raise OptimizerError("ledger columns do not match the required schema")
        rows = [
            LedgerTest(
                method_id=str(row.get("method_id") or ""),
                target=str(row.get("target") or ""),
                file=str(row.get("file") or ""),
                suite=str(row.get("suite") or ""),
                method=str(row.get("method") or ""),
                domain=str(row.get("domain") or ""),
                layer=str(row.get("layer") or ""),
                execution_tier=str(row.get("execution_tier") or ""),
                runtime_seconds=parse_runtime_seconds(str(row.get("runtime_seconds") or "")),
                resource_cost_tags=split_tags(str(row.get("resource_cost_tags") or "")),
                shared_state_tags=split_tags(str(row.get("shared_state_tags") or "")),
            )
            for row in reader
        ]
    ids = [row.method_id for row in rows]
    if len(ids) != len(set(ids)):
        raise OptimizerError("ledger contains duplicate method_id rows")
    invalid_tiers = sorted({row.execution_tier for row in rows if row.execution_tier not in TEST_EXECUTION_TIERS})
    if invalid_tiers:
        raise OptimizerError(f"ledger contains unsupported execution_tier values: {invalid_tiers}")
    return rows




def read_ledger_dict_rows(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        if reader.fieldnames != LEDGER_COLUMNS:
            raise OptimizerError("ledger columns do not match the required schema")
        rows = [dict(row) for row in reader]
    ids = [str(row.get("method_id") or "") for row in rows]
    if len(ids) != len(set(ids)):
        raise OptimizerError("ledger contains duplicate method_id rows")
    # Reuse typed validation for runtime_seconds and execution_tier checks.
    read_ledger_rows(path)
    return rows


def baseline_runtime_timings(path: Path) -> dict[tuple[str, str, str], float]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    target = str(payload.get("target") or "root")
    rows = payload.get("slowest_tests")
    if not isinstance(rows, list):
        raise OptimizerError("baseline artifact is missing slowest_tests")
    timings: dict[tuple[str, str, str], float] = {}
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            raise OptimizerError(f"slowest_tests[{index}] is not an object")
        suite = str(row.get("suite") or "")
        method = str(row.get("method") or "")
        if not suite or not method:
            raise OptimizerError(f"slowest_tests[{index}] is missing suite or method")
        seconds_value = row.get("median_seconds")
        if seconds_value is None:
            seconds_value = row.get("observed_p95_seconds")
        if seconds_value is None:
            raise OptimizerError(f"slowest_tests[{index}] is missing median_seconds")
        try:
            seconds = float(seconds_value)
        except (TypeError, ValueError) as exc:
            raise OptimizerError(f"invalid baseline runtime for {target}/{suite}/{method}") from exc
        if not math.isfinite(seconds) or seconds < 0:
            raise OptimizerError(f"invalid baseline runtime for {target}/{suite}/{method}")
        timings[(target, suite, method)] = seconds
    return timings


def runtime_import(ledger: Path, baseline_path: Path, output: Path) -> dict[str, Any]:
    if output.exists():
        raise OptimizerError(f"refusing to overwrite existing ledger: {output}")
    rows = read_ledger_dict_rows(ledger)
    timings = baseline_runtime_timings(baseline_path)
    timing_keys = set(timings)
    ledger_keys = {(row["target"], row["suite"], row["method"]) for row in rows}
    updated = 0
    unchanged = 0
    for row in rows:
        key = (row["target"], row["suite"], row["method"])
        seconds = timings.get(key)
        if seconds is None:
            unchanged += 1
            continue
        formatted = f"{seconds:.6f}"
        if row.get("runtime_seconds") == formatted:
            unchanged += 1
            continue
        row["runtime_seconds"] = formatted
        updated += 1
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=LEDGER_COLUMNS, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
    return {
        "rows_updated": updated,
        "rows_unchanged": unchanged,
        "artifact_methods_missing_from_ledger": [
            f"{target}/{suite}/{method}" for target, suite, method in sorted(timing_keys - ledger_keys)
        ],
        "ledger_methods_missing_from_artifact": [
            f"{target}/{suite}/{method}" for target, suite, method in sorted(ledger_keys - timing_keys)
        ],
        "output": str(output),
    }


def ci_suite_plan(
    ledger: Path,
    shard_count: int,
    suites: Sequence[str] | None = None,
    default_runtime_seconds: float = 1.0,
    batch_max_seconds: float = 5.0,
    require_runtime_for_batching: bool = True,
) -> dict[str, Any]:
    if shard_count <= 0:
        raise OptimizerError("--shards must be greater than zero")
    if default_runtime_seconds <= 0:
        raise OptimizerError("default runtime seconds must be greater than zero")
    rows = [row for row in read_ledger_rows(ledger) if row.target == "root"]
    suite_filter = set(suites or [])
    if suite_filter:
        rows = [row for row in rows if row.suite in suite_filter]
    grouped: dict[str, list[LedgerTest]] = defaultdict(list)
    for row in rows:
        grouped[row.suite].append(row)
    missing_suites = sorted(suite_filter - set(grouped))
    suite_entries: list[dict[str, Any]] = []
    for suite, suite_rows in sorted(grouped.items()):
        runtime_values = [row.runtime_seconds for row in suite_rows]
        missing_runtime_count = sum(value is None for value in runtime_values)
        estimated = sum(value if value is not None else default_runtime_seconds for value in runtime_values)
        execution_tiers = sorted({row.execution_tier for row in suite_rows})
        resource_tags = sorted({tag for row in suite_rows for tag in row.resource_cost_tags})
        shared_tags = sorted({tag for row in suite_rows for tag in row.shared_state_tags})
        batch_eligible = (
            (not require_runtime_for_batching or missing_runtime_count == 0)
            and not shared_tags
            and not resource_tags
            and not (set(execution_tiers) & HEAVY_TEST_EXECUTION_TIERS)
            and estimated <= batch_max_seconds
        )
        suite_entries.append({
            "suite": suite,
            "estimated_seconds": estimated,
            "method_count": len(suite_rows),
            "missing_runtime_count": missing_runtime_count,
            "execution_tiers": execution_tiers,
            "resource_cost_tags": resource_tags,
            "shared_state_tags": shared_tags,
            "batch_eligible": batch_eligible,
        })
    shards = [{"index": index + 1, "estimated_seconds": 0.0, "suites": []} for index in range(shard_count)]
    for entry in sorted(suite_entries, key=lambda item: (-float(item["estimated_seconds"]), str(item["suite"]))):
        shard = min(shards, key=lambda item: (item["estimated_seconds"], item["index"]))
        shard["estimated_seconds"] += float(entry["estimated_seconds"])
        shard["suites"].append(entry)
    for shard in shards:
        shard["suite_count"] = len(shard["suites"])
    return {
        "target": "root",
        "shard_count": shard_count,
        "default_runtime_seconds": default_runtime_seconds,
        "missing_suites": missing_suites,
        "shards": shards,
    }

def source_domains_for_changed_path(path: str) -> set[str]:
    parts = Path(path).parts
    if len(parts) >= 4 and parts[0] == "Sources" and parts[1] == "RepoPrompt":
        if parts[2] == "Features":
            feature = parts[3]
            if feature == "AgentMode":
                return {"AgentMode", "MCP", "ContextBuilder"}
            if feature == "CodeMap":
                return {"CodeMap", "WorkspaceContext/CodeMap", "WorkspaceContext"}
            if feature == "ContextBuilder":
                return {"ContextBuilder", "AgentMode", "MCP"}
            if feature == "WorkspaceFiles":
                return {"WorkspaceContext", "FileSystem", "Services"}
            if feature == "Workspaces":
                return {"Workspaces", "WorkspaceContext"}
            return {feature}
        if parts[2] == "Infrastructure" and len(parts) >= 4:
            area = parts[3]
            if area == "MCP":
                return {"MCP", "AgentMode"}
            if area == "VCS":
                return {"VCS", "Services/VCS", "MCP"}
            if area == "FileSystem":
                return {"FileSystem", "Services", "WorkspaceContext"}
            if area == "WorkspaceContext":
                return {"WorkspaceContext", "WorkspaceContext/CodeMap", "CodeMap"}
            return {area, "Services"}
        if parts[2] == "App":
            return {"App", "Root"}
    if len(parts) >= 2 and parts[0] == "Sources" and parts[1] in {"RepoPromptMCP", "RepoPromptShared"}:
        return {"MCP"}
    if len(parts) >= 2 and parts[0] == "Sources" and parts[1] == "TreeSitterScannerSupport":
        return {"CodeMap", "WorkspaceContext/CodeMap"}
    if len(parts) >= 3 and parts[0] == "Packages" and parts[1] == "RepoPromptAgentProviders":
        return {"Provider/Runtime", "Provider/SDK"}
    return set()


DEFAULT_IMPACTED_RANGE = "default"
DEFAULT_IMPACTED_BRANCH_RANGE = "origin/main...HEAD"


def changed_files_for_git_diff(repo_root: Path, args: Sequence[str], label: str) -> list[str]:
    completed = run_command(
        ["git", "diff", "--name-only", "--diff-filter=ACMRT", *args, "--"],
        repo_root,
    )
    if completed.returncode != 0:
        raise OptimizerError(f"git diff failed for {label}: {completed.stderr.strip()}")
    return [path for path in completed.stdout.splitlines() if path]


def changed_files_for_range(repo_root: Path, range_spec: str) -> list[str]:
    if range_spec == DEFAULT_IMPACTED_RANGE:
        branch_changed = changed_files_for_git_diff(
            repo_root,
            [DEFAULT_IMPACTED_BRANCH_RANGE],
            DEFAULT_IMPACTED_BRANCH_RANGE,
        )
        # Diff against HEAD so staged-but-uncommitted changes (index-vs-HEAD)
        # are captured alongside unstaged worktree changes. A plain worktree-vs-
        # index diff would hide staged changes, which breaks the usual
        # stage-intended-changes-then-validate pre-commit flow. Untracked files
        # are intentionally excluded; they include scratch artifacts and local
        # investigation docs that will never be committed.
        worktree_changed = changed_files_for_git_diff(repo_root, ["HEAD"], "worktree")
        return sorted(set(branch_changed).union(worktree_changed))
    return sorted(set(changed_files_for_git_diff(repo_root, [range_spec], range_spec)))


def listed_root_test_ids(repo_root: Path) -> tuple[set[str], str]:
    run = run_conductor(repo_root, "root", list_mode=True)
    if (
        run.process_exit_code != 0
        or run.result.get("state") != "completed"
        or run.result.get("exitCode") != 0
    ):
        raise OptimizerError(
            f"root test list failed: process_exit={run.process_exit_code} "
            f"state={run.result.get('state')} exit={run.result.get('exitCode')} "
            f"ticket={run.ticket} log={run.result.get('logPath')} stderr={run.stderr[-500:]}"
        )
    if not run.log_text:
        raise OptimizerError(f"root test list log missing or empty: {run.result.get('logPath')}")
    return {test.method_id for test in parse_test_list(run.log_text, "root")}, str(run.result.get("logPath") or "")


def exact_xctest_filter(method_ids: Sequence[str]) -> str:
    if not method_ids:
        raise OptimizerError("cannot build an XCTest filter without selected methods")
    # Builds a single anchored alternation regex passed to conductor via --filter.
    # Current ledger scale keeps this well under macOS ARG_MAX, but very large
    # impacted/shard selections could approach shell argv limits in the future;
    # consider a guard or chunked invocation if selected_count grows past ~1k.
    return "^(?:" + "|".join(re.escape(method_id.split("/", 1)[1]) for method_id in sorted(method_ids)) + ")$"


def impacted_tests(
    repo_root: Path,
    ledger: Path,
    range_spec: str,
    include_heavy: bool = False,
    smoke_floor_suites: Sequence[str] = DEFAULT_SMOKE_FLOOR_SUITES,
    run_selected: bool = False,
    validate_live_list: bool = True,
) -> dict[str, Any]:
    rows = [row for row in read_ledger_rows(ledger) if row.target == "root"]
    live_ids: set[str] | None = None
    list_log_path: str | None = None
    if validate_live_list:
        live_ids, list_log_path = listed_root_test_ids(repo_root)
        ledger_ids = {row.method_id for row in rows}
        missing = sorted(live_ids - ledger_ids)
        stale = sorted(ledger_ids - live_ids)
        if missing or stale:
            raise OptimizerError(
                f"ledger mismatch against live dev-test-list: missing={len(missing)} stale={len(stale)} "
                f"missing_examples={missing[:5]} stale_examples={stale[:5]} list_log={list_log_path}"
            )
    changed = changed_files_for_range(repo_root, range_spec)
    selected: dict[str, set[str]] = defaultdict(set)
    skipped: dict[str, set[str]] = defaultdict(set)
    broad_reasons: list[str] = []
    domains: set[str] = set()
    files = set(changed)
    for path in changed:
        if path.startswith(BROAD_IMPACT_PATH_PREFIXES):
            broad_reasons.append(f"{path}: broad test/build/tooling boundary")
        for domain in source_domains_for_changed_path(path):
            domains.add(domain)
    if broad_reasons:
        full_count = len(rows)
        if run_selected:
            raise OptimizerError(
                "impacted selection requires the full root suite; rerun as "
                "`make dev-test` (or `conductor test`). broad boundaries: "
                + ", ".join(broad_reasons)
            )
        return {
            "range": range_spec,
            "changed_files": changed,
            "list_log_path": list_log_path,
            "live_root_test_count": len(live_ids) if live_ids is not None else None,
            "selection_mode": "full_root_required",
            "full_root_required": True,
            "full_root_reasons": broad_reasons,
            "selected": [],
            "selected_count": 0,
            "full_root_total_count": full_count,
            "filter": None,
            "smoke_floor_suites": list(smoke_floor_suites),
            "skipped_heavy_or_opt_in": [],
            "command": [str(repo_root / "conductor"), "test"],
            "run": None,
        }
    for row in rows:
        if row.suite in smoke_floor_suites:
            selected[row.method_id].add(f"smoke floor suite {row.suite}")
        if row.domain in domains or any(row.domain.startswith(f"{domain}/") for domain in domains):
            selected[row.method_id].add(f"domain impacted by changed sources: {row.domain}")
        if row.file in files:
            selected[row.method_id].add(f"{row.file}: changed test file")
    selected_rows = {row.method_id: row for row in rows if row.method_id in selected}
    for method_id, row in list(selected_rows.items()):
        if row.execution_tier in HEAVY_TEST_EXECUTION_TIERS and not include_heavy:
            skipped[method_id].update(selected.pop(method_id))
            skipped[method_id].add(f"execution_tier={row.execution_tier} requires explicit opt-in")
    selected_ids = sorted(selected)
    filter_value = exact_xctest_filter(selected_ids) if selected_ids else None
    run_payload: dict[str, Any] | None = None
    if run_selected and filter_value:
        run = run_conductor(repo_root, "root", filter_value=filter_value)
        run_payload = {
            "command": run.command,
            "process_exit_code": run.process_exit_code,
            "state": run.result.get("state"),
            "exit_code": run.result.get("exitCode"),
            "ticket": run.ticket,
            "log_path": run.result.get("logPath"),
        }
        if (
            run.process_exit_code != 0
            or run.result.get("state") != "completed"
            or run.result.get("exitCode") != 0
        ):
            raise OptimizerError(
                "impacted test run failed: "
                f"process_exit={run.process_exit_code} "
                f"state={run.result.get('state')} "
                f"exit={run.result.get('exitCode')} "
                f"ticket={run.ticket} log={run.result.get('logPath')}"
            )
    return {
        "range": range_spec,
        "changed_files": changed,
        "list_log_path": list_log_path,
        "live_root_test_count": len(live_ids) if live_ids is not None else None,
        "selection_mode": "impacted",
        "full_root_required": False,
        "impacted_domains": sorted(domains),
        "smoke_floor_suites": list(smoke_floor_suites),
        "selected_count": len(selected_ids),
        "selected": [
            {
                "method_id": method_id,
                "suite": selected_rows[method_id].suite,
                "execution_tier": selected_rows[method_id].execution_tier,
                "reasons": sorted(selected[method_id]),
            }
            for method_id in selected_ids
        ],
        "filter": filter_value,
        "command": conductor_command(repo_root, "root", filter_value=filter_value) if filter_value else None,
        "skipped_heavy_or_opt_in": [
            {
                "method_id": method_id,
                "suite": next(row.suite for row in rows if row.method_id == method_id),
                "execution_tier": next(row.execution_tier for row in rows if row.method_id == method_id),
                "reasons": sorted(reasons),
            }
            for method_id, reasons in sorted(skipped.items())
        ],
        "run": run_payload,
    }


def shard_root_tests(ledger: Path, shard_count: int, include_heavy: bool = False) -> dict[str, Any]:
    if shard_count <= 0:
        raise OptimizerError("--shards must be greater than zero")
    rows = [row for row in read_ledger_rows(ledger) if row.target == "root"]
    if not include_heavy:
        rows = [row for row in rows if row.execution_tier not in HEAVY_TEST_EXECUTION_TIERS]
    shards: list[dict[str, Any]] = [
        {"index": index + 1, "estimated_seconds": 0.0, "method_ids": []}
        for index in range(shard_count)
    ]
    for row in sorted(rows, key=lambda item: (-(item.runtime_seconds or 1.0), item.method_id)):
        shard = min(shards, key=lambda item: (item["estimated_seconds"], item["index"]))
        weight = row.runtime_seconds or 1.0
        shard["estimated_seconds"] += weight
        shard["method_ids"].append(row.method_id)
    for shard in shards:
        shard["method_count"] = len(shard["method_ids"])
        shard["filter"] = exact_xctest_filter(shard["method_ids"]) if shard["method_ids"] else None
        shard["command"] = (
            conductor_command(repo_root_from_script(), "root", filter_value=shard["filter"])
            if shard["filter"]
            else None
        )
        shard_rows = [row for row in rows if row.method_id in set(shard["method_ids"])]
        shared_tags: dict[str, int] = defaultdict(int)
        for row in shard_rows:
            for tag in row.shared_state_tags:
                shared_tags[tag] += 1
        shard["shared_state_tag_counts"] = dict(sorted(shared_tags.items()))
    return {
        "target": "root",
        "shard_count": shard_count,
        "include_heavy": include_heavy,
        "excluded_heavy_tiers": sorted(HEAVY_TEST_EXECUTION_TIERS if not include_heavy else []),
        "parallelization_warning": (
            "Shard filters are weighted by historical runtime; review shared_state_tag_counts "
            "before running shards concurrently."
        ),
        "shards": shards,
    }


def git_metadata(repo_root: Path) -> dict[str, str]:
    commit = run_command(["git", "rev-parse", "HEAD"], repo_root)
    status = run_command(["git", "status", "--short"], repo_root)
    return {
        "commit": commit.stdout.strip() if commit.returncode == 0 else "unknown",
        "working_tree": status.stdout.rstrip(),
    }


def measurement_source_paths(repo_root: Path) -> list[Path]:
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
            files.extend(
                path
                for path in root.rglob("*")
                if path.is_file() and path.suffix in MEASUREMENT_SOURCE_SUFFIXES
            )
    return sorted(files)


def measurement_source_fingerprint(repo_root: Path) -> str:
    digest = hashlib.sha256()
    digest.update(b"content-v1\0")
    for path in measurement_source_paths(repo_root):
        digest.update(str(path.relative_to(repo_root)).encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def measurement_source_metadata_fingerprint(repo_root: Path) -> str:
    digest = hashlib.sha256()
    digest.update(b"metadata-v1\0")
    for path in measurement_source_paths(repo_root):
        stat = path.stat()
        mtime_ns = getattr(stat, "st_mtime_ns", int(stat.st_mtime * 1_000_000_000))
        digest.update(str(path.relative_to(repo_root)).encode("utf-8"))
        digest.update(b"\0file\0")
        digest.update(str(stat.st_size).encode("ascii"))
        digest.update(b"\0")
        digest.update(str(mtime_ns).encode("ascii"))
        digest.update(b"\0")
    return digest.hexdigest()


def measurement_source_guard_fingerprint(repo_root: Path, kind: str) -> str:
    if kind == SOURCE_GUARD_CONTENT:
        return measurement_source_fingerprint(repo_root)
    if kind == SOURCE_GUARD_METADATA:
        return measurement_source_metadata_fingerprint(repo_root)
    raise OptimizerError(f"unsupported source change guard: {kind}")


def sample_invalid_reasons(
    process_exit_code: int,
    result: dict[str, Any],
    source_changed: bool,
    filtered_without_timings: bool = False,
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
    if filtered_without_timings:
        reasons.append("filtered baseline produced no parsed XCTest timings")
    return reasons


def result_resource_usage(result: dict[str, Any]) -> dict[str, Any]:
    keys = (
        "maxRSSBytes",
        "maxRssBytes",
        "maxRSS",
        "maxRss",
        "rssBytes",
        "peakRSSBytes",
        "peakRssBytes",
        "memoryBytes",
        "resourceUsage",
    )
    usage = {key: result.get(key) for key in keys if key in result}
    return usage


def build_result_dict(run: ConductorRun) -> dict[str, Any]:
    result = run.result
    return {
        "command": run.command,
        "process_exit_code": run.process_exit_code,
        "state": result.get("state"),
        "exit_code": result.get("exitCode"),
        "queue_wait_seconds": result.get("queueWaitSeconds"),
        "execution_seconds": result.get("executionSeconds"),
        "measurement_invalid": result.get("measurementInvalid"),
        "log_path": result.get("logPath"),
        "ticket": run.ticket,
        "resource_usage": result_resource_usage(result),
    }


def sample_from_run(
    index: int,
    target: str,
    run: ConductorRun,
    source_changed: bool,
    source_guard_kind: str = SOURCE_GUARD_CONTENT,
    require_timings: bool = False,
    build: dict[str, Any] | None = None,
) -> Sample:
    result = run.result
    timings = parse_xctest_timings(run.log_text)
    resource_usage = result_resource_usage(result)
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
        invalid_reasons=sample_invalid_reasons(
            run.process_exit_code,
            result,
            source_changed,
            filtered_without_timings=require_timings and not timings,
        ),
        timings=timings,
        source_guard_kind=source_guard_kind,
        source_changed=source_changed,
        build=build,
        resource_usage=resource_usage,
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


def test_ranking(samples: Sequence[Sample]) -> list[dict[str, Any]]:
    per_test_seconds: dict[tuple[str, str], list[float]] = defaultdict(list)
    maximums: dict[tuple[str, str], float] = defaultdict(float)
    failures: dict[tuple[str, str], int] = defaultdict(int)
    for sample in samples:
        for timing in sample.timings:
            key = (timing.suite, timing.method)
            per_test_seconds[key].append(timing.seconds)
            maximums[key] = max(maximums[key], timing.seconds)
            if timing.status != "passed":
                failures[key] += 1
    rows: list[dict[str, Any]] = []
    for (suite, method), values in per_test_seconds.items():
        rows.append(
            {
                "suite": suite,
                "method": method,
                "observations": len(values),
                "median_seconds": statistics.median(values),
                "observed_p95_seconds": nearest_rank_p95(values),
                "max_seconds": maximums[(suite, method)],
                "failure_or_skip_count": failures[(suite, method)],
            }
        )
    return sorted(
        rows,
        key=lambda row: (
            -float(row["median_seconds"]),
            -float(row["observed_p95_seconds"]),
            str(row["suite"]),
            str(row["method"]),
        ),
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
        "source_guard_kind": sample.source_guard_kind,
        "source_changed": sample.source_changed,
        "build": sample.build,
        "resource_usage": sample.resource_usage or {},
    }


def parsed_xctest_seconds(sample: Sample) -> float | None:
    if not sample.timings:
        return None
    return sum(timing.seconds for timing in sample.timings)


def inferred_overhead_seconds(sample: Sample) -> float | None:
    parsed_seconds = parsed_xctest_seconds(sample)
    if sample.execution_seconds is None or parsed_seconds is None:
        return None
    return max(0.0, float(sample.execution_seconds) - parsed_seconds)


def rss_bytes_from_value(value: Any, key: str) -> int | None:
    if isinstance(value, bool) or value is None:
        return None
    try:
        numeric = float(value)
    except (TypeError, ValueError):
        return None
    if numeric < 0:
        return None
    normalized = key.lower().replace("-", "_")
    if normalized.endswith("_kb") or normalized.endswith("kb"):
        numeric *= 1024
    elif normalized.endswith("_mb") or normalized.endswith("mb"):
        numeric *= 1024 * 1024
    return int(numeric)


def extract_max_rss_bytes(value: Any) -> int | None:
    candidates: list[int] = []

    def visit(node: Any, key: str = "") -> None:
        if isinstance(node, dict):
            for child_key, child_value in node.items():
                visit(child_value, str(child_key))
            return
        if isinstance(node, list):
            for child in node:
                visit(child, key)
            return
        normalized = key.lower().replace("-", "_")
        if "rss" not in normalized:
            return
        candidate = rss_bytes_from_value(node, normalized)
        if candidate is not None:
            candidates.append(candidate)

    visit(value)
    return max(candidates) if candidates else None


def focused_cost_sample_to_dict(sample: Sample, run_result: dict[str, Any]) -> dict[str, Any]:
    parsed_seconds = parsed_xctest_seconds(sample)
    return {
        "index": sample.index,
        "target": sample.target,
        "command": sample.command,
        "process_exit_code": sample.process_exit_code,
        "state": sample.state,
        "exit_code": sample.exit_code,
        "queue_wait_seconds": sample.queue_wait_seconds,
        "total_execution_seconds": sample.execution_seconds,
        "parsed_xctest_seconds": parsed_seconds,
        "parsed_test_case_timings": len(sample.timings),
        "inferred_overhead_seconds": inferred_overhead_seconds(sample),
        "max_rss_bytes": extract_max_rss_bytes(run_result),
        "timed_out": sample.timed_out,
        "measurement_invalid": sample.measurement_invalid,
        "diagnostic_paths": sample.diagnostic_paths,
        "log_path": sample.log_path,
        "valid": sample.valid,
        "invalid_reasons": sample.invalid_reasons,
        "source_guard_kind": sample.source_guard_kind,
        "source_changed": sample.source_changed,
    }


def focused_cost_zero_valid_message(samples: Sequence[dict[str, Any]]) -> str:
    details: list[str] = []
    for sample in samples:
        reasons = "; ".join(str(reason) for reason in sample.get("invalid_reasons") or [])
        log_path = str(sample.get("log_path") or "")
        detail = f"sample {sample.get('index')}: {reasons or 'invalid'}"
        if log_path:
            detail += f"; log={log_path}"
        details.append(detail)
    suffix = "; ".join(details[:5])
    if len(details) > 5:
        suffix += f"; ... {len(details) - 5} more"
    return f"focused-cost produced no valid samples{': ' + suffix if suffix else ''}"


def focused_cost_summary(samples: Sequence[dict[str, Any]]) -> dict[str, Any]:
    valid = [sample for sample in samples if sample.get("valid")]
    total_values = [float(sample["total_execution_seconds"]) for sample in valid if sample.get("total_execution_seconds") is not None]
    if not total_values:
        raise OptimizerError(focused_cost_zero_valid_message(samples))
    parsed_values = [float(sample["parsed_xctest_seconds"]) for sample in valid if sample.get("parsed_xctest_seconds") is not None]
    overhead_values = [
        float(sample["inferred_overhead_seconds"])
        for sample in valid
        if sample.get("inferred_overhead_seconds") is not None
    ]
    rss_values = [int(sample["max_rss_bytes"]) for sample in valid if sample.get("max_rss_bytes") is not None]
    rel_mad = relative_mad(total_values)
    return {
        "attempts": len(samples),
        "valid_samples": len(valid),
        "invalid_samples": len(samples) - len(valid),
        "raw_total_execution_seconds": total_values,
        "median_total_execution_seconds": statistics.median(total_values),
        "observed_p95_total_execution_seconds": nearest_rank_p95(total_values),
        "relative_mad_total_execution_seconds": rel_mad,
        "noise_classification": noise_classification(rel_mad),
        "raw_parsed_xctest_seconds": parsed_values,
        "median_parsed_xctest_seconds": statistics.median(parsed_values) if parsed_values else None,
        "raw_inferred_overhead_seconds": overhead_values,
        "median_inferred_overhead_seconds": statistics.median(overhead_values) if overhead_values else None,
        "max_rss_bytes": max(rss_values) if rss_values else None,
        "reliable": False,
        "diagnostic_only": True,
    }


def baseline_summary(samples: Sequence[Sample]) -> dict[str, Any]:
    valid = [sample for sample in samples if sample.valid and sample.execution_seconds is not None]
    values = [float(sample.execution_seconds) for sample in valid]
    if not values:
        raise OptimizerError("baseline produced no valid samples")
    rel_mad = relative_mad(values)
    valid_builds = [
        float((sample.build or {}).get("execution_seconds"))
        for sample in valid
        if (sample.build or {}).get("execution_seconds") is not None
    ]
    summary: dict[str, Any] = {
        "attempts": len(samples),
        "valid_samples": len(valid),
        "invalid_samples": len(samples) - len(valid),
        "raw_execution_seconds": values,
        "median_seconds": statistics.median(values),
        "observed_p95_seconds": nearest_rank_p95(values),
        "relative_mad": rel_mad,
        "noise_classification": noise_classification(rel_mad),
    }
    if valid_builds:
        summary["raw_build_execution_seconds"] = valid_builds
        summary["median_build_execution_seconds"] = statistics.median(valid_builds)
        summary["observed_p95_build_execution_seconds"] = nearest_rank_p95(valid_builds)
        summary["median_total_build_plus_test_seconds"] = (
            summary["median_build_execution_seconds"] + summary["median_seconds"]
        )
    return summary


def scoreboard_scaffold() -> str:
    return """# RepoPrompt CE XCTest Optimization Runs

## Measurement contract

- Primary metric: warm local root `Scripts/test_suite_optimizer.py baseline --target root` using conductor JSON `executionSeconds` from `./conductor test --json`.
- Build/link cost is separate from warm XCTest execution cost. Use `baseline --build-before-samples`
  only when an iteration needs paired build+test evidence; primary root timing remains test
  `executionSeconds`.
- Focused tiny-test latency is a different metric from full-suite runtime. Diagnose it with
  paired build/test artifacts and, for hosted per-suite CI, prefer the built `.xctest` bundle
  path through `Scripts/ci_app_test_runner.py` over repeated `swift test --skip-build --filter`
  invocations.
- Runtime-heavy Workspace/Codemap suites are optimized only from parsed XCTest method/suite
  timings in complete or focused baseline artifacts. Do not claim a Workspace/Codemap runtime
  win from build/link, process-startup, or package-resolution overhead changes.
- Provider package timing is measured separately with `Scripts/test_suite_optimizer.py baseline --target provider`.
- A root+provider number may be reported only as a derived secondary serial estimate, not as an observed single-process wallclock.
- Normal timing samples must not enable XCTest stall diagnostics or wake probes.
- Comparable baseline series use 3–5 valid samples; iteration-0 and release-gate series prefer five valid samples.
- Invalid samples are excluded only by optimizer-recorded invalid reasons.
- Noise classes use relative MAD: stable `<= 0.05`, noisy `<= 0.10`, unstable `> 0.10`.
- The curated ledger `Scripts/Fixtures/test-suite-contract-ledger.tsv` is never regenerated or overwritten. Executable add, rename, consolidation, or removal requires surgical exact-ID ledger updates in the same patch.
- Rows are append-only. Corrections are appended and supersede earlier rows; earlier artifacts and rows are not edited.

## Baseline summary

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|

## Derived complete-suite secondary

| Date/commit | Label | Root artifact | Provider artifact | Root median | Provider median | Derived serial median | Root p95 | Provider p95 | Conservative serial p95 sum | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|

## Iteration ledger

| Iteration | Commit/range | Attributed change | Primary/secondary scope | Root methods | Provider methods | Total methods | Method delta | Contract delta | Scenario delta | Exact old→new/removed mappings | Focused artifacts | Full-root artifacts | Provider artifacts | Root median delta | Root p95 delta | Provider median delta | Provider p95 delta | Derived secondary delta | Slowest suites/tests after change | Validation and exit codes | Decision |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---|---|---|---:|---:|---:|---:|---:|---|---|---|

## Candidate queue

| Rank | Candidate | Metric scope | Expected effect | Risk | Entry criteria | Required evidence | Status |
|---:|---|---|---|---|---|---|---|
| 1 | Optimizer source-change guard, focused baseline support, and per-method ranking | Tooling only | Reduces campaign overhead and improves targeting; no primary suite-speed claim | Low | Always first setup step | Python optimizer tests, append-only scaffold, zero method/contract/scenario delta | Planned |
| 2 | ACP mode-config fake ACP server fixture setup reduction | Root primary, conditional | Reduces repeated test fixture IO/setup if ACP suite ranks high | Low to medium | Initial root slow-suite/method ranking implicates `ACPAgentSessionControllerModeConfigTests` | Focused before/after artifact, focused XCTest, full-root after artifact, ledger verify | Waiting for baseline |
| 3 | Hosted CI class-per-process batching | CI-only secondary | Reduces hosted CI subprocess overhead; no local root primary improvement | Medium/high | CI elapsed becomes explicit target after local baseline | CI runner self-tests and GitHub Build and Test evidence | Waiting for CI prioritization |
| 4 | Root test-target split by domain boundary (`Workspace/Codemap`, `MCP`, root/unit) | Focused overhead secondary | Reduces fixed compile/link/load cost for tiny focused runs by shrinking the test target dependency graph; does not claim runtime-heavy suite improvement | Medium/high | Paired evidence shows focused total time dominated by fixed overhead, e.g. tiny suite total seconds greatly exceed parsed XCTest seconds; provider package remains a cheap control lane | Before/after focused tiny-suite artifact, complete root artifact, provider artifact, authoritative lists, exact ledger reconciliation, no contract/scenario loss | Evidence needed |
| 5 | Workspace/Codemap fixture scale reduction and reuse | Root primary | Reduces parsed XCTest time in Workspace/Codemap suites where test body dominates total time | Medium | Slow-suite/method ranking implicates Workspace/Codemap runtime and the protected contract can be proven with smaller synthetic fixtures, such as crossing paging thresholds without thousands of files | Focused before/after artifact for affected suites, full-root artifact, contract/oracle review, ledger verify, scenario totals preserved | Evidence needed |
| 6 | Workspace/Codemap async determinism pass | Root primary/reliability | Removes sleeps, uncontrolled timing, and process/file dependency variance from expensive async/worktree/context-builder tests | Medium | Invalid samples or slow methods correlate with waits, retries, real timing, worktree/process setup, or codemap readiness polling | Focused reliability repetitions, focused runtime artifact, full-root artifact, no diagnostics counted as timing samples | Evidence needed |

## Optimization lanes

- **Fixed overhead lane:** Tiny focused suites with near-zero parsed XCTest time but high total elapsed are package/build/link/test-launch problems. Use paired build/test artifacts, hosted `.xctest` bundle execution through `Scripts/ci_app_test_runner.py`, and domain target-split experiments. Do not count these as Workspace/Codemap runtime wins.
- **Runtime-heavy lane:** Suites whose parsed XCTest seconds nearly equal total suite seconds need fixture, async, filesystem, worktree, codemap catalog, or scenario redesign. Target splitting may improve developer ergonomics but is not the primary speed lever.
- **Memory/RSS lane:** RSS claims require explicit `resource_usage` evidence in optimizer artifacts or a separate diagnostic. Existing memory snapshots are insufficient for a strong compiler/test-run RSS conclusion.
- **Ledger/trust lane:** `verify-ledger` depends on conductor list jobs. A conductor/list shell hang or missing Swift toolchain blocks trust restoration but is separate from XCTest runtime.

## Reverted attempts

| Date | Iteration | Attempt | Reason reverted | Method delta | Scenario delta | Median delta | p95 delta | Correctness/lifecycle evidence | Artifact paths |
|---|---|---|---|---:|---:|---:|---:|---|---|

## Baseline run records

Append complete root/provider baseline records here. Include raw sample values, invalid reasons, slowest suites/tests, inventory path, and conductor log paths.

## Focused run records

Append focused before/after records here. Focused records are not primary metric results unless explicitly promoted through a complete root baseline.

## Handoff checklist per iteration

- Protected contract, plausible defect, chosen layer, and observable oracle.
- Exact executable IDs added, renamed, consolidated, or removed.
- Complete old→new/removed mapping when IDs change.
- Scenario-count rationale and before/after affected-suite plus repository totals for consolidations.
- Surgical ledger update confirmed; curated ledger was not regenerated.
- Focused command results and full-root/provider baseline artifact paths.
- Median, observed p95, relative MAD, and noise class for comparable series.
- Validation commands and exit codes.
- Any deliberately omitted or moved coverage with justification.

"""


def ensure_scoreboard(path: Path) -> None:
    if path.exists():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(scoreboard_scaffold(), encoding="utf-8")


def format_seconds(value: float | None) -> str:
    return "" if value is None else f"{value:.3f}"


def append_focused_cost_scoreboard(path: Path, payload: dict[str, Any]) -> None:
    ensure_scoreboard(path)
    source_guard = (payload.get("source_guard") or {}).get("kind") or SOURCE_GUARD_CONTENT
    lines = [
        f"### Focused cost diagnostic: {payload['timestamp']} — {payload['target']} — {payload['label']}",
        "",
        f"Command: `{' '.join(payload['command'])}`",
        f"Artifact: `{payload.get('artifact') or ''}`",
        f"Filter: `{payload.get('filter') or ''}`",
        f"Source-change guard: `{source_guard}`",
        "Primary metric eligible: no",
        "",
        "| Sample | Valid | Total execution seconds | Parsed XCTest seconds | Inferred overhead seconds | Queue wait | Max RSS bytes | State | Exit | Log | Invalid reason |",
        "|---:|---|---:|---:|---:|---:|---:|---|---:|---|---|",
    ]
    for sample in payload["samples"]:
        reasons = "; ".join(sample["invalid_reasons"])
        lines.append(
            "| {index} | {valid} | {total} | {parsed} | {overhead} | {queue} | {rss} | {state} | {exit_code} | `{log}` | {reasons} |".format(
                index=sample["index"],
                valid="yes" if sample["valid"] else "no",
                total=format_seconds(sample["total_execution_seconds"]),
                parsed=format_seconds(sample["parsed_xctest_seconds"]),
                overhead=format_seconds(sample["inferred_overhead_seconds"]),
                queue=format_seconds(sample["queue_wait_seconds"]),
                rss=sample["max_rss_bytes"] if sample["max_rss_bytes"] is not None else "",
                state=sample["state"],
                exit_code=sample["exit_code"],
                log=sample["log_path"],
                reasons=reasons,
            )
        )
    summary = payload["summary"]
    lines.extend(
        [
            "",
            "Summary:",
            "",
            "| Valid | Invalid | Median total execution seconds | Observed p95 total execution seconds | Relative MAD | Noise | Median parsed XCTest seconds | Median inferred overhead seconds | Max RSS bytes | Diagnostic only | Primary metric eligible |",
            "|---:|---:|---:|---:|---:|---|---:|---:|---:|---|---|",
            "| {valid} | {invalid} | {median_total} | {p95_total} | {mad} | {noise} | {median_parsed} | {median_overhead} | {rss} | {diagnostic} | {primary} |".format(
                valid=summary["valid_samples"],
                invalid=summary["invalid_samples"],
                median_total=format_seconds(summary["median_total_execution_seconds"]),
                p95_total=format_seconds(summary["observed_p95_total_execution_seconds"]),
                mad="" if summary["relative_mad_total_execution_seconds"] is None else f"{summary['relative_mad_total_execution_seconds']:.4f}",
                noise=summary["noise_classification"],
                median_parsed=format_seconds(summary["median_parsed_xctest_seconds"]),
                median_overhead=format_seconds(summary["median_inferred_overhead_seconds"]),
                rss=summary["max_rss_bytes"] if summary["max_rss_bytes"] is not None else "",
                diagnostic="yes" if summary.get("diagnostic_only") else "no",
                primary="yes" if payload.get("primary_metric_eligible") else "no",
            ),
            "",
        ]
    )
    with path.open("a", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")



def append_baseline_scoreboard(
    path: Path,
    payload: dict[str, Any],
    method_counts: dict[str, int] | None,
) -> None:
    ensure_scoreboard(path)
    target = payload["target"]
    scope = str(payload.get("scope") or "complete")
    filter_value = payload.get("filter")
    test_product = payload.get("test_product")
    scope_filter = scope if not filter_value else f"{scope}: `{filter_value}`"
    source_guard = (payload.get("source_guard") or {}).get("kind") or SOURCE_GUARD_CONTENT
    summary = payload["summary"]
    metadata = payload["git"]
    counts = method_counts or {}
    root_count = counts.get("root", 0)
    provider_count = counts.get("provider", 0)
    total_count = root_count + provider_count if counts else 0
    record_heading = "Focused" if scope in {"filtered", "test-product"} else "Baseline"
    lines = [
        f"### {record_heading}: {payload['timestamp']} — {target} — {payload['label']}",
        "",
        f"Command: `{' '.join(payload['command'])}`",
        f"Artifact: `{payload.get('artifact') or ''}`",
        f"Inventory: `{payload.get('inventory') or ''}`",
        f"Scope/filter: {scope_filter}",
        f"Test product: `{test_product or ''}`",
        f"Source-change guard: `{source_guard}`",
        f"Build before samples: {'yes' if payload.get('build_before_samples') else 'no'}",
        f"Primary metric eligible: {'yes' if payload.get('primary_metric_eligible') else 'no'}",
        "",
        "| Sample | Valid | Build seconds | Test execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |",
        "|---:|---|---:|---:|---:|---|---:|---|---|---|",
    ]
    for sample in payload["samples"]:
        reasons = "; ".join(sample["invalid_reasons"])
        build = sample.get("build") or {}
        lines.append(
            "| {index} | {valid} | {build_seconds} | {execution} | {queue} | {state} | {exit_code} | {invalid} | `{log}` | {reasons} |".format(
                index=sample["index"],
                valid="yes" if sample["valid"] else "no",
                build_seconds=format_seconds(build.get("execution_seconds")),
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
            "| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |",
            "|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|",
            "| {date}/{commit} | {label} | {target} | {scope_filter} | {valid} valid + {invalid} invalid | {root} | {provider} | {total} | {median:.3f} | {p95:.3f} | {mad:.4f} | {noise} | `{artifact}` | source guard `{guard}`; build-lane coordinated |".format(
                date=payload["timestamp"],
                commit=metadata["commit"][:12],
                label=payload["label"],
                target=target,
                scope_filter=scope_filter,
                valid=summary["valid_samples"],
                invalid=summary["invalid_samples"],
                root=root_count or "",
                provider=provider_count or "",
                total=total_count or "",
                median=summary["median_seconds"],
                p95=summary["observed_p95_seconds"],
                mad=summary["relative_mad"],
                noise=summary["noise_classification"],
                artifact=payload.get("artifact") or "",
                guard=source_guard,
            ),
            "",
        ]
    )
    if summary.get("median_build_execution_seconds") is not None:
        lines.extend(
            [
                "Build/test cost split:",
                "",
                "| Median build seconds | Observed p95 build seconds | Median test seconds | Median build+test seconds |",
                "|---:|---:|---:|---:|",
                "| {build:.3f} | {build_p95:.3f} | {test:.3f} | {total:.3f} |".format(
                    build=summary["median_build_execution_seconds"],
                    build_p95=summary["observed_p95_build_execution_seconds"],
                    test=summary["median_seconds"],
                    total=summary["median_total_build_plus_test_seconds"],
                ),
                "",
            ]
        )
    if payload.get("slowest_suites"):
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
    if payload.get("slowest_tests"):
        lines.extend(
            [
                "20 slowest tests by median XCTest case seconds across valid samples:",
                "",
                "| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |",
                "|---:|---|---|---:|---:|---:|---:|---:|",
            ]
        )
        for index, row in enumerate(payload["slowest_tests"][:20], start=1):
            lines.append(
                f"| {index} | `{row['suite']}` | `{row['method']}` | {row['observations']} | "
                f"{row['median_seconds']:.3f} | {row['observed_p95_seconds']:.3f} | "
                f"{row['max_seconds']:.3f} | {row['failure_or_skip_count']} |"
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


def verify_ledger(
    repo_root: Path,
    ledger: Path,
    list_timeout_seconds: int = LIST_COMMAND_TIMEOUT_SECONDS,
) -> dict[str, Any]:
    return verify_ledger_with_progress(repo_root, ledger, emit_progress_event, list_timeout_seconds)


def verify_ledger_with_progress(
    repo_root: Path,
    ledger: Path,
    progress_sink: ProgressSink | None,
    list_timeout_seconds: int = LIST_COMMAND_TIMEOUT_SECONDS,
) -> dict[str, Any]:
    if list_timeout_seconds <= 0:
        raise OptimizerError("--list-timeout-seconds must be greater than zero")
    listed: list[ListedTest] = []
    logs: dict[str, str] = {}
    for target in ("root", "provider"):
        if progress_sink is not None:
            progress_sink({
                "event": "verify_ledger_list_start",
                "timestamp": utc_now(),
                "target": target,
                "timeout_seconds": list_timeout_seconds,
            })
        run = run_conductor(
            repo_root,
            target,
            list_mode=True,
            timeout_seconds=list_timeout_seconds,
        )
        if progress_sink is not None:
            progress_sink({
                "event": "verify_ledger_list_end",
                "timestamp": utc_now(),
                "target": target,
                "ticket": run.ticket,
                "process_exit_code": run.process_exit_code,
                "state": run.result.get("state"),
                "exit_code": run.result.get("exitCode"),
                "log_path": run.result.get("logPath"),
            })
        if (
            run.process_exit_code != 0
            or run.result.get("state") != "completed"
            or run.result.get("exitCode") != 0
        ):
            raise OptimizerError(
                f"{target} test list failed: process_exit={run.process_exit_code} "
                f"state={run.result.get('state')} exit={run.result.get('exitCode')} "
                f"ticket={run.ticket} log={run.result.get('logPath')} stderr={run.stderr[-500:]}"
            )
        if not run.log_text:
            raise OptimizerError(f"{target} test list log missing or empty: {run.result.get('logPath')}")
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
    inventory_path: Path | None = None,
    source_change_guard: str = SOURCE_GUARD_CONTENT,
    filter_value: str | None = None,
    test_product: str | None = None,
    build_before_samples: bool = False,
    progress_sink: ProgressSink | None = emit_progress_event,
) -> dict[str, Any]:
    if samples_requested <= 0:
        raise OptimizerError("--samples must be greater than zero")
    if build_before_samples and target != "root":
        raise OptimizerError("--build-before-samples currently supports only --target root")
    if build_before_samples and test_product:
        raise OptimizerError("--build-before-samples cannot be combined with --test-product")
    samples: list[Sample] = []
    command = conductor_command(repo_root, target, filter_value=filter_value, test_product=test_product)
    scope = "filtered" if filter_value else "test-product" if test_product else "complete"
    for index in range(1, samples_requested + 1):
        if progress_sink is not None:
            progress_sink(
                {
                    "event": "baseline_sample_start",
                    "timestamp": utc_now(),
                    "target": target,
                    "scope": scope,
                    "filter": filter_value,
                    "test_product": test_product,
                    "source_guard": source_change_guard,
                    "sample_index": index,
                    "sample_count": samples_requested,
                    "command": command,
                    "ticket": None,
                    "log_path": None,
                }
            )
        before = measurement_source_guard_fingerprint(repo_root, source_change_guard)
        build: dict[str, Any] | None = None
        if build_before_samples:
            if progress_sink is not None:
                progress_sink(
                    {
                        "event": "baseline_build_start",
                        "timestamp": utc_now(),
                        "target": target,
                        "scope": scope,
                        "filter": filter_value,
                        "test_product": test_product,
                        "sample_index": index,
                        "sample_count": samples_requested,
                    }
                )
            build_run = run_conductor_build(repo_root, target)
            build = build_result_dict(build_run)
            if progress_sink is not None:
                progress_sink(
                    {
                        "event": "baseline_build_end",
                        "timestamp": utc_now(),
                        "target": target,
                        "scope": scope,
                        "filter": filter_value,
                        "test_product": test_product,
                        "sample_index": index,
                        "sample_count": samples_requested,
                        "ticket": build_run.ticket,
                        "log_path": build.get("log_path"),
                        "process_exit_code": build.get("process_exit_code"),
                        "state": build.get("state"),
                        "exit_code": build.get("exit_code"),
                        "execution_seconds": build.get("execution_seconds"),
                    }
                )
        run = run_conductor(
            repo_root,
            target,
            list_mode=False,
            filter_value=filter_value,
            test_product=test_product,
        )
        after = measurement_source_guard_fingerprint(repo_root, source_change_guard)
        sample = sample_from_run(
            index,
            target,
            run,
            source_changed=before != after,
            source_guard_kind=source_change_guard,
            require_timings=filter_value is not None,
            build=build,
        )
        if build is not None and (
            build.get("process_exit_code") != 0
            or build.get("state") != "completed"
            or build.get("exit_code") != 0
        ):
            sample.invalid_reasons.append("paired build failed")
        samples.append(sample)
        if progress_sink is not None:
            progress_sink(
                {
                    "event": "baseline_sample_end",
                    "timestamp": utc_now(),
                    "target": target,
                    "scope": scope,
                    "filter": filter_value,
                    "test_product": test_product,
                    "source_guard": source_change_guard,
                    "sample_index": index,
                    "sample_count": samples_requested,
                    "ticket": run.ticket,
                    "log_path": sample.log_path or None,
                    "process_exit_code": sample.process_exit_code,
                    "state": sample.state,
                    "exit_code": sample.exit_code,
                    "execution_seconds": sample.execution_seconds,
                    "measurement_invalid": sample.measurement_invalid,
                    "source_changed": sample.source_changed,
                    "valid": sample.valid,
                    "invalid_reasons": sample.invalid_reasons,
                }
            )
    valid_samples = [sample for sample in samples if sample.valid]
    payload = {
        "timestamp": utc_now(),
        "target": target,
        "label": label,
        "artifact": str(output),
        "inventory": str(inventory_path) if inventory_path else None,
        "scope": scope,
        "filter": filter_value,
        "test_product": test_product,
        "build_before_samples": build_before_samples,
        "primary_metric_eligible": target == "root" and filter_value is None and test_product is None,
        "source_guard": {"kind": source_change_guard},
        "command": command,
        "git": git_metadata(repo_root),
        "samples": [sample_to_dict(sample) for sample in samples],
        "summary": baseline_summary(samples),
        "slowest_suites": suite_ranking(valid_samples),
        "slowest_tests": test_ranking(valid_samples),
    }
    write_json_new(output, payload)
    append_baseline_scoreboard(scoreboard, payload, method_counts)
    return payload


def focused_cost(
    repo_root: Path,
    target: str,
    filter_value: str,
    samples_requested: int,
    label: str,
    scoreboard: Path,
    output: Path,
    source_change_guard: str = SOURCE_GUARD_CONTENT,
    progress_sink: ProgressSink | None = emit_progress_event,
) -> dict[str, Any]:
    if samples_requested <= 0:
        raise OptimizerError("--samples must be greater than zero")
    if not filter_value:
        raise OptimizerError("--filter is required for focused-cost diagnostics")
    samples: list[dict[str, Any]] = []
    command = conductor_command(repo_root, target, filter_value=filter_value)
    for index in range(1, samples_requested + 1):
        if progress_sink is not None:
            progress_sink(
                {
                    "event": "focused_cost_sample_start",
                    "timestamp": utc_now(),
                    "target": target,
                    "filter": filter_value,
                    "source_guard": source_change_guard,
                    "sample_index": index,
                    "sample_count": samples_requested,
                    "command": command,
                    "ticket": None,
                    "log_path": None,
                }
            )
        before = measurement_source_guard_fingerprint(repo_root, source_change_guard)
        run = run_conductor(repo_root, target, list_mode=False, filter_value=filter_value)
        after = measurement_source_guard_fingerprint(repo_root, source_change_guard)
        sample = sample_from_run(
            index,
            target,
            run,
            source_changed=before != after,
            source_guard_kind=source_change_guard,
            require_timings=True,
        )
        sample_payload = focused_cost_sample_to_dict(sample, run.result)
        samples.append(sample_payload)
        if progress_sink is not None:
            progress_sink(
                {
                    "event": "focused_cost_sample_end",
                    "timestamp": utc_now(),
                    "target": target,
                    "filter": filter_value,
                    "source_guard": source_change_guard,
                    "sample_index": index,
                    "sample_count": samples_requested,
                    "ticket": run.ticket,
                    "log_path": sample.log_path or None,
                    "process_exit_code": sample.process_exit_code,
                    "state": sample.state,
                    "exit_code": sample.exit_code,
                    "total_execution_seconds": sample.execution_seconds,
                    "parsed_xctest_seconds": sample_payload["parsed_xctest_seconds"],
                    "inferred_overhead_seconds": sample_payload["inferred_overhead_seconds"],
                    "max_rss_bytes": sample_payload["max_rss_bytes"],
                    "measurement_invalid": sample.measurement_invalid,
                    "source_changed": sample.source_changed,
                    "valid": sample.valid,
                    "invalid_reasons": sample.invalid_reasons,
                }
            )
    payload = {
        "timestamp": utc_now(),
        "diagnostic_kind": "focused-cost",
        "target": target,
        "label": label,
        "artifact": str(output),
        "scope": "filtered",
        "filter": filter_value,
        "primary_metric_eligible": False,
        "source_guard": {"kind": source_change_guard},
        "command": command,
        "git": git_metadata(repo_root),
        "samples": samples,
        "summary": focused_cost_summary(samples),
    }
    write_json_new(output, payload)
    append_focused_cost_scoreboard(scoreboard, payload)
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
    scopes: set[str] = set()
    filters: set[str | None] = set()
    test_products: set[str | None] = set()
    source_guards: set[str] = set()
    for path in paths:
        payload = json.loads(path.read_text(encoding="utf-8"))
        target = str(payload.get("target") or "")
        scope = str(payload.get("scope") or "complete")
        filter_value = payload.get("filter")
        test_product = payload.get("test_product")
        source_guard = str((payload.get("source_guard") or {}).get("kind") or SOURCE_GUARD_CONTENT)
        targets.add(target)
        scopes.add(scope)
        filters.add(str(filter_value) if filter_value is not None else None)
        test_products.add(str(test_product) if test_product is not None else None)
        source_guards.add(source_guard)
        for raw_sample in payload.get("samples") or []:
            sample = dict(raw_sample)
            sample["source_artifact"] = str(path)
            sample.setdefault("source_guard_kind", source_guard)
            sample.setdefault("source_changed", False)
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
                        source_guard_kind=str(sample.get("source_guard_kind") or source_guard),
                        source_changed=bool(sample.get("source_changed")),
                    )
                )
    if len(targets) != 1:
        raise OptimizerError(f"combined baselines must have one target, found: {sorted(targets)}")
    if len(scopes) != 1:
        raise OptimizerError(f"combined baselines must have one scope, found: {sorted(scopes)}")
    if len(filters) != 1:
        raise OptimizerError(f"combined baselines must have one filter, found: {sorted(filters, key=str)}")
    if len(test_products) != 1:
        raise OptimizerError(
            f"combined baselines must have one test product, found: {sorted(test_products, key=str)}"
        )
    if len(source_guards) != 1:
        raise OptimizerError(
            f"combined baselines must have one source change guard, found: {sorted(source_guards)}"
        )
    values = [float(sample["execution_seconds"]) for sample in samples if sample.get("valid")]
    if not values:
        raise OptimizerError("combined baselines contain no valid samples")
    rel_mad = relative_mad(values)
    target = next(iter(targets))
    scope = next(iter(scopes))
    filter_value = next(iter(filters))
    test_product = next(iter(test_products))
    source_guard = next(iter(source_guards))
    return {
        "timestamp": utc_now(),
        "target": target,
        "scope": scope,
        "filter": filter_value,
        "test_product": test_product,
        "primary_metric_eligible": target == "root" and filter_value is None and test_product is None,
        "source_guard": {"kind": source_guard},
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
        "slowest_tests": test_ranking(timing_samples)[:top],
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
    return {
        "logs": [str(path) for path in paths],
        "ranking": suite_ranking(samples)[:top],
        "suite_ranking": suite_ranking(samples)[:top],
        "test_ranking": test_ranking(samples)[:top],
    }


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
    baseline_parser.add_argument("--filter", help="optional XCTest filter for focused baseline artifacts")
    baseline_parser.add_argument(
        "--test-product",
        help="optional SwiftPM test product for focused split-target baseline artifacts",
    )
    baseline_parser.add_argument(
        "--source-change-guard",
        choices=[SOURCE_GUARD_CONTENT, SOURCE_GUARD_METADATA],
        default=SOURCE_GUARD_CONTENT,
        help="source mutation guard used before/after each sample",
    )
    baseline_parser.add_argument(
        "--build-before-samples",
        action="store_true",
        help="run a coordinated build before each test sample and record build/test cost separately",
    )

    focused_cost_parser = subparsers.add_parser(
        "focused-cost",
        help="collect filtered compile/link/runtime overhead diagnostics without primary metric eligibility",
    )
    focused_cost_parser.add_argument("--target", choices=["root", "provider"], required=True)
    focused_cost_parser.add_argument("--filter", required=True, help="XCTest filter for the focused diagnostic run")
    focused_cost_parser.add_argument("--samples", type=int, required=True)
    focused_cost_parser.add_argument("--label", required=True)
    focused_cost_parser.add_argument("--scoreboard", type=Path, required=True)
    focused_cost_parser.add_argument("--output", type=Path, required=True)
    focused_cost_parser.add_argument(
        "--source-change-guard",
        choices=[SOURCE_GUARD_CONTENT, SOURCE_GUARD_METADATA],
        default=SOURCE_GUARD_CONTENT,
        help="source mutation guard used before/after each sample",
    )

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

    impacted_parser = subparsers.add_parser(
        "impacted",
        help="select and optionally run impacted root XCTest methods from git diff and the contract ledger",
    )
    impacted_parser.add_argument("--ledger", type=Path, required=True)
    impacted_parser.add_argument(
        "--range",
        dest="range_spec",
        default=DEFAULT_IMPACTED_RANGE,
        help="git diff range/spec; default unions origin/main...HEAD with working-tree changes",
    )
    impacted_parser.add_argument(
        "--include-heavy",
        action="store_true",
        help="include codemap_e2e/scale/diagnostic/live/release tiers when selected",
    )
    impacted_parser.add_argument(
        "--smoke-suite",
        action="append",
        default=[],
        help="suite to always include; defaults to the repository smoke floor",
    )
    impacted_parser.add_argument(
        "--run",
        action="store_true",
        help="run the selected exact filters through conductor after printing the plan",
    )
    impacted_parser.add_argument(
        "--skip-live-list-validation",
        action="store_true",
        help="do not run conductor test --list before selecting impacted rows",
    )

    shard_parser = subparsers.add_parser(
        "shard-plan",
        help="partition root XCTest methods into weighted conductor filters",
    )
    shard_parser.add_argument("--ledger", type=Path, required=True)
    shard_parser.add_argument("--shards", type=int, required=True)
    shard_parser.add_argument("--include-heavy", action="store_true")

    runtime_import_parser = subparsers.add_parser("runtime-import", help="write a candidate ledger with runtime_seconds from a baseline artifact")
    runtime_import_parser.add_argument("--ledger", type=Path, required=True)
    runtime_import_parser.add_argument("--baseline", type=Path, required=True)
    runtime_import_parser.add_argument("--output", type=Path, required=True)

    ci_suite_plan_parser = subparsers.add_parser("ci-suite-plan", help="partition root XCTest suites for hosted CI planning")
    ci_suite_plan_parser.add_argument("--ledger", type=Path, required=True)
    ci_suite_plan_parser.add_argument("--shards", type=int, required=True)
    ci_suite_plan_parser.add_argument("--suite", action="append", default=[])
    ci_suite_plan_parser.add_argument("--default-runtime-seconds", type=float, default=1.0)
    ci_suite_plan_parser.add_argument("--batch-max-seconds", type=float, default=5.0)
    ci_suite_plan_parser.add_argument("--allow-missing-runtime-for-batching", action="store_true")

    verify_parser = subparsers.add_parser("verify-ledger", help="re-list tests and reconcile ledger rows")
    verify_parser.add_argument("--ledger", type=Path, required=True)
    verify_parser.add_argument(
        "--list-timeout-seconds",
        type=int,
        default=LIST_COMMAND_TIMEOUT_SECONDS,
        help="client-side timeout for each conductor list job",
    )
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
                inventory_path=args.inventory,
                source_change_guard=args.source_change_guard,
                filter_value=args.filter,
                test_product=args.test_product,
                build_before_samples=args.build_before_samples,
            )
        elif args.command == "focused-cost":
            payload = focused_cost(
                repo_root=repo_root,
                target=args.target,
                filter_value=args.filter,
                samples_requested=args.samples,
                label=args.label,
                scoreboard=args.scoreboard,
                output=args.output,
                source_change_guard=args.source_change_guard,
            )
        elif args.command == "combine-baselines":
            payload = combine_baselines(args.input, args.top)
            write_json_new(args.output, payload)
        elif args.command == "compare":
            payload = compare_baselines(args.before, args.after)
        elif args.command == "rank":
            payload = rank_logs(args.log, args.top)
        elif args.command == "impacted":
            smoke_floor = args.smoke_suite or DEFAULT_SMOKE_FLOOR_SUITES
            payload = impacted_tests(
                repo_root=repo_root,
                ledger=args.ledger,
                range_spec=args.range_spec,
                include_heavy=args.include_heavy,
                smoke_floor_suites=smoke_floor,
                run_selected=args.run,
                validate_live_list=not args.skip_live_list_validation,
            )
        elif args.command == "shard-plan":
            payload = shard_root_tests(args.ledger, args.shards, include_heavy=args.include_heavy)
        elif args.command == "runtime-import":
            payload = runtime_import(args.ledger, args.baseline, args.output)
        elif args.command == "ci-suite-plan":
            payload = ci_suite_plan(
                args.ledger,
                args.shards,
                suites=args.suite,
                default_runtime_seconds=args.default_runtime_seconds,
                batch_max_seconds=args.batch_max_seconds,
                require_runtime_for_batching=not args.allow_missing_runtime_for_batching,
            )
        elif args.command == "verify-ledger":
            payload = verify_ledger(repo_root, args.ledger, args.list_timeout_seconds)
        else:
            raise OptimizerError(f"unsupported command: {args.command}")
    except (OSError, OptimizerError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
