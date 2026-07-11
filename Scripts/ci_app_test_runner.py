#!/usr/bin/env python3
"""Hosted CI app-test runner for RepoPrompt CE.

The GitHub macOS runner executes root XCTest suites one XCTest class at a time.
This keeps hosted CI bounded without changing stable local validation.
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
from collections import defaultdict
from concurrent.futures import FIRST_COMPLETED, Future, ThreadPoolExecutor, wait
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Iterable, Sequence, TextIO

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from test_suite_optimizer import OptimizerError, ci_suite_plan

DEFAULT_SUITE_TIMEOUT_SECONDS = 180.0
DEFAULT_SILENT_TIMEOUT_RETRIES = 1
DEFAULT_SILENT_STARTUP_SECONDS = 60.0
XCTEST_FAILURE_RE = re.compile(r"^.*:\d+(?::\d+)?:\s+error:\s+-\[[^\]]+\]\s+:")
XCTEST_STARTED_RE = re.compile(r"^Test Case '-\[(?P<test>[^\]]+)\]' started\.$")
TIMEOUT_EXIT_CODE = 124
XCTEST_BUNDLE_GLOB = "*.xctest"
REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LEDGER = REPO_ROOT / "Scripts" / "Fixtures" / "test-suite-contract-ledger.tsv"
DEFAULT_SERIAL_GROUP_POLICY = REPO_ROOT / "Scripts" / "Fixtures" / "ci-test-serial-groups.json"
SERIAL_GROUP_POLICY_VERSION = 1
HEAVY_EXECUTION_TIERS = frozenset({"codemap_e2e", "scale", "diagnostic", "live_smoke", "release"})
TAG_SPLIT_RE = re.compile(r"[,; ]+")


@dataclass(frozen=True)
class OutputSnapshot:
    output_seen: bool
    first_failure_line: str | None
    last_started_test: str | None


@dataclass
class OutputState:
    output_seen: threading.Event = field(default_factory=threading.Event)
    failure_seen: threading.Event = field(default_factory=threading.Event)
    lock: threading.Lock = field(default_factory=threading.Lock)
    first_failure_line: str | None = None
    last_started_test: str | None = None

    def observe(self, line: str) -> None:
        self.output_seen.set()
        started_test = parse_started_test(line)
        failure_line = line.rstrip("\n") if is_xctest_failure_line(line) else None
        if started_test is None and failure_line is None:
            return

        with self.lock:
            if started_test is not None:
                self.last_started_test = started_test
            if failure_line is not None and self.first_failure_line is None:
                self.first_failure_line = failure_line
                self.failure_seen.set()

    def snapshot(self) -> OutputSnapshot:
        with self.lock:
            return OutputSnapshot(
                output_seen=self.output_seen.is_set(),
                first_failure_line=self.first_failure_line,
                last_started_test=self.last_started_test,
            )


@dataclass(frozen=True)
class SuitePlanEntry:
    suite: str
    estimated_seconds: float
    batch_eligible: bool


@dataclass(frozen=True)
class SuiteGroup:
    suites: tuple[str, ...]
    estimated_seconds: float

    @property
    def label(self) -> str:
        return self.suites[0] if len(self.suites) == 1 else "+".join(self.suites)


@dataclass(frozen=True)
class SuiteRunResult:
    suite: str
    state: str
    exit_code: int
    elapsed_seconds: float
    output_seen: bool
    first_failure_line: str | None
    last_started_test: str | None
    timed_out_after_seconds: float | None
    attempts: int


@dataclass(frozen=True)
class SerialGroup:
    tag: str
    lane: str
    reason: str


@dataclass(frozen=True)
class LedgerSuite:
    suite: str
    shared_state_tags: frozenset[str]
    resource_cost_tags: frozenset[str]
    execution_tiers: tuple[str, ...]
    estimated_runtime_seconds: float
    method_count: int


@dataclass(frozen=True)
class PlannedSuite:
    suite: str
    classification: str
    serial_lanes: tuple[str, ...]
    matched_serial_tags: tuple[str, ...]
    shared_state_tags: tuple[str, ...]
    resource_cost_tags: tuple[str, ...]
    execution_tiers: tuple[str, ...]
    estimated_runtime_seconds: float
    method_count: int
    heavy_tier_present: bool


@dataclass(frozen=True)
class SuitePlan:
    suites: tuple[PlannedSuite, ...]

    @property
    def pinned_serial(self) -> list[PlannedSuite]:
        return [suite for suite in self.suites if suite.classification == "pinned_serial"]

    @property
    def parallel_eligible(self) -> list[PlannedSuite]:
        return [suite for suite in self.suites if suite.classification == "parallel_eligible"]

    def suite_names(self) -> list[str]:
        return [suite.suite for suite in self.suites]

    def to_json_payload(self) -> dict[str, object]:
        return {
            "counts": {
                "total": len(self.suites),
                "pinned_serial": len(self.pinned_serial),
                "parallel_eligible": len(self.parallel_eligible),
            },
            "pinned_serial": [planned_suite_payload(suite) for suite in self.pinned_serial],
            "parallel_eligible": [planned_suite_payload(suite) for suite in self.parallel_eligible],
        }


def is_xctest_failure_line(line: str) -> bool:
    return XCTEST_FAILURE_RE.match(line.rstrip("\n")) is not None


def parse_started_test(line: str) -> str | None:
    match = XCTEST_STARTED_RE.match(line.rstrip("\n"))
    if match is None:
        return None
    return match.group("test")


def parse_suites(list_output: str) -> list[str]:
    return sorted(
        {
            line.split("/", 1)[0]
            for line in list_output.splitlines()
            if "/" in line and line.split("/", 1)[0]
        }
    )


def split_tags(value: str) -> frozenset[str]:
    return frozenset(tag.strip() for tag in TAG_SPLIT_RE.split(value or "") if tag.strip())


def parse_runtime_seconds(value: str) -> float:
    if not value:
        return 0.0
    try:
        seconds = float(value)
    except ValueError as exc:
        raise ValueError(f"invalid runtime_seconds value: {value!r}") from exc
    if seconds < 0:
        raise ValueError(f"invalid runtime_seconds value: {value!r}")
    return seconds


def load_serial_group_policy(path: Path) -> dict[str, SerialGroup]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except FileNotFoundError as exc:
        raise ValueError(f"serial group policy file does not exist: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ValueError(f"serial group policy file is not valid JSON: {path}: {exc}") from exc

    if not isinstance(payload, dict):
        raise ValueError("serial group policy must be a JSON object")
    if payload.get("version") != SERIAL_GROUP_POLICY_VERSION:
        raise ValueError(
            f"unsupported serial group policy version {payload.get('version')!r}; "
            f"expected {SERIAL_GROUP_POLICY_VERSION}"
        )
    if payload.get("default_mode") != "parallel_eligible":
        raise ValueError("serial group policy default_mode must be 'parallel_eligible'")
    groups = payload.get("groups")
    if not isinstance(groups, dict) or not groups:
        raise ValueError("serial group policy groups must be a non-empty object")

    policy: dict[str, SerialGroup] = {}
    for tag, group in groups.items():
        if not isinstance(tag, str) or not tag:
            raise ValueError("serial group policy group tags must be non-empty strings")
        if not isinstance(group, dict):
            raise ValueError(f"serial group policy group {tag!r} must be an object")
        lane = group.get("lane")
        reason = group.get("reason")
        if not isinstance(lane, str) or not lane:
            raise ValueError(f"serial group policy group {tag!r} must define a non-empty lane")
        if not isinstance(reason, str) or not reason:
            raise ValueError(f"serial group policy group {tag!r} must define a non-empty reason")
        policy[tag] = SerialGroup(tag=tag, lane=lane, reason=reason)
    return policy


def read_ledger_suites(path: Path) -> dict[str, LedgerSuite]:
    try:
        handle = path.open("r", encoding="utf-8", newline="")
    except FileNotFoundError as exc:
        raise ValueError(f"ledger file does not exist: {path}") from exc

    with handle:
        reader = csv.DictReader(handle, delimiter="\t")
        required = {
            "suite",
            "runtime_seconds",
            "resource_cost_tags",
            "shared_state_tags",
            "execution_tier",
        }
        missing = sorted(required.difference(reader.fieldnames or []))
        if missing:
            raise ValueError(f"ledger file is missing required columns: {missing}")

        shared_state_tags: dict[str, set[str]] = defaultdict(set)
        resource_cost_tags: dict[str, set[str]] = defaultdict(set)
        execution_tiers: dict[str, set[str]] = defaultdict(set)
        estimated_runtime: dict[str, float] = defaultdict(float)
        method_counts: dict[str, int] = defaultdict(int)

        for row_number, row in enumerate(reader, start=2):
            suite = str(row.get("suite") or "")
            if not suite:
                raise ValueError(f"ledger row {row_number} is missing suite")
            shared_state_tags[suite].update(split_tags(str(row.get("shared_state_tags") or "")))
            resource_cost_tags[suite].update(split_tags(str(row.get("resource_cost_tags") or "")))
            tier = str(row.get("execution_tier") or "")
            if tier:
                execution_tiers[suite].add(tier)
            try:
                estimated_runtime[suite] += parse_runtime_seconds(
                    str(row.get("runtime_seconds") or "")
                )
            except ValueError as exc:
                raise ValueError(f"ledger row {row_number}: {exc}") from exc
            method_counts[suite] += 1

    return {
        suite: LedgerSuite(
            suite=suite,
            shared_state_tags=frozenset(shared_state_tags[suite]),
            resource_cost_tags=frozenset(resource_cost_tags[suite]),
            execution_tiers=tuple(sorted(execution_tiers[suite])),
            estimated_runtime_seconds=estimated_runtime[suite],
            method_count=method_counts[suite],
        )
        for suite in sorted(method_counts)
    }


def build_suite_plan(
    suites: Iterable[str],
    *,
    ledger_suites: dict[str, LedgerSuite],
    serial_policy: dict[str, SerialGroup],
) -> SuitePlan:
    planned: list[PlannedSuite] = []
    for suite in sorted(suites):
        ledger_suite = ledger_suites.get(
            suite,
            LedgerSuite(
                suite=suite,
                shared_state_tags=frozenset(),
                resource_cost_tags=frozenset(),
                execution_tiers=tuple(),
                estimated_runtime_seconds=0.0,
                method_count=0,
            ),
        )
        policy_tags = ledger_suite.shared_state_tags.union(ledger_suite.resource_cost_tags)
        matched = sorted(tag for tag in policy_tags if tag in serial_policy)
        lanes = tuple(sorted({serial_policy[tag].lane for tag in matched}))
        classification = "pinned_serial" if matched else "parallel_eligible"
        planned.append(
            PlannedSuite(
                suite=suite,
                classification=classification,
                serial_lanes=lanes,
                matched_serial_tags=tuple(matched),
                shared_state_tags=tuple(sorted(ledger_suite.shared_state_tags)),
                resource_cost_tags=tuple(sorted(ledger_suite.resource_cost_tags)),
                execution_tiers=ledger_suite.execution_tiers,
                estimated_runtime_seconds=ledger_suite.estimated_runtime_seconds,
                method_count=ledger_suite.method_count,
                heavy_tier_present=any(tier in HEAVY_EXECUTION_TIERS for tier in ledger_suite.execution_tiers),
            )
        )
    return SuitePlan(suites=tuple(planned))


def planned_suite_payload(suite: PlannedSuite) -> dict[str, object]:
    return {
        "suite": suite.suite,
        "classification": suite.classification,
        "serial_lanes": list(suite.serial_lanes),
        "matched_serial_tags": list(suite.matched_serial_tags),
        "shared_state_tags": list(suite.shared_state_tags),
        "resource_cost_tags": list(suite.resource_cost_tags),
        "execution_tiers": list(suite.execution_tiers),
        "estimated_runtime_seconds": suite.estimated_runtime_seconds,
        "method_count": suite.method_count,
        "heavy_tier_present": suite.heavy_tier_present,
    }


def list_suites(swift_binary: str, cwd: Path | None) -> list[str]:
    listed = subprocess.run(
        [swift_binary, "test", "list"],
        check=True,
        capture_output=True,
        cwd=cwd,
        text=True,
    )
    return parse_suites(listed.stdout)


def discover_test_bundle(
    swift_binary: str,
    cwd: Path | None,
    bundle_name: str | None = None,
) -> Path | None:
    """Find the built XCTest bundle so suites can run via ``xcrun xctest`` directly.

    ``swift test --skip-build --filter`` re-resolves the package and re-plans the
    build on every invocation. On hosted macOS runners that per-invocation
    overhead can wedge silently before XCTest prints anything, burning the silent
    startup budget. Running ``xcrun xctest -XCTest <suite> <bundle>`` directly
    skips swift's process management entirely and starts producing XCTest output
    immediately.

    Fails if multiple candidate bundles are found and no exact bundle name was
    requested, since silently picking the first sorted bundle could run suites
    against the wrong test target.
    """
    try:
        show_bin = subprocess.run(
            [swift_binary, "build", "--show-bin-path"],
            check=True,
            capture_output=True,
            text=True,
            cwd=cwd,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    bin_path = Path(show_bin.stdout.strip())
    if not bin_path.is_dir():
        return None
    candidates = sorted(bin_path.glob(XCTEST_BUNDLE_GLOB))
    if bundle_name:
        requested = bundle_name if bundle_name.endswith(".xctest") else f"{bundle_name}.xctest"
        candidates = [candidate for candidate in candidates if candidate.name == requested]
    if not candidates:
        return None
    if len(candidates) > 1:
        raise ValueError(
            f"Multiple XCTest bundles found under {bin_path}; refusing to pick one "
            f"ambiguously: {[str(c) for c in candidates]}"
        )
    return candidates[0]


def discover_test_bundles(swift_binary: str, cwd: Path | None) -> dict[str, Path]:
    """Return built XCTest bundles keyed by SwiftPM test target name."""
    try:
        show_bin = subprocess.run(
            [swift_binary, "build", "--show-bin-path"],
            check=True,
            capture_output=True,
            text=True,
            cwd=cwd,
        )
    except (OSError, subprocess.CalledProcessError):
        return {}
    bin_path = Path(show_bin.stdout.strip())
    if not bin_path.is_dir():
        return {}
    return {
        candidate.name.removesuffix(".xctest"): candidate
        for candidate in sorted(bin_path.glob(XCTEST_BUNDLE_GLOB))
    }


def package_test_bundle(discovered: dict[str, Path]) -> Path | None:
    """Return SwiftPM's combined package XCTest bundle when it is unambiguous."""
    package_bundles = [
        path
        for name, path in discovered.items()
        if name.endswith("PackageTests")
    ]
    if len(package_bundles) == 1:
        return package_bundles[0]
    return None


def target_bundles_for_suites(discovered: dict[str, Path], suites: Sequence[str]) -> dict[str, Path] | None:
    """Return exact target bundles when every selected suite target is covered.

    Stale bundles from restored SwiftPM caches are ignored; only bundle names
    matching the currently selected suite targets are routed per-target.
    """
    targets = {test_target_for_suite(suite) for suite in suites}
    matching = {target: discovered[target] for target in sorted(targets) if target in discovered}
    if targets and set(matching) == targets:
        return matching
    return None


def test_target_for_suite(suite: str) -> str:
    return suite.split(".", 1)[0]


def bundle_for_suite(suite: str, test_bundles: dict[str, Path] | None) -> Path | None:
    if not test_bundles:
        return None
    return test_bundles.get(test_target_for_suite(suite))


def xctest_binary_path() -> list[str]:
    """Return a command prefix for invoking xctest.

    Prefers the resolved path from ``xcrun --find xctest``. If that fails,
    falls back to ``["xcrun", "xctest"]`` so the invocation is still
    ``xcrun xctest -XCTest <suite> <bundle>`` rather than the invalid
    ``xcrun -XCTest ...``.
    """
    try:
        result = subprocess.run(
            ["xcrun", "--find", "xctest"],
            check=True,
            capture_output=True,
            text=True,
        )
        path = result.stdout.strip()
        if path:
            return [path]
    except (OSError, subprocess.CalledProcessError):
        pass
    return ["xcrun", "xctest"]


def descendant_process_groups(root_pid: int) -> set[int]:
    try:
        process_list = subprocess.run(
            ["ps", "-axo", "pid=,ppid="],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return set()

    children: dict[int, list[int]] = {}
    for line in process_list.stdout.splitlines():
        parts = line.split()
        if len(parts) != 2:
            continue
        try:
            pid = int(parts[0])
            parent = int(parts[1])
        except ValueError:
            continue
        children.setdefault(parent, []).append(pid)

    pending = [root_pid]
    process_ids: set[int] = set()
    while pending:
        process_id = pending.pop()
        if process_id in process_ids:
            continue
        process_ids.add(process_id)
        pending.extend(children.get(process_id, []))

    groups: set[int] = set()
    for process_id in process_ids:
        try:
            groups.add(os.getpgid(process_id))
        except (OSError, PermissionError, ProcessLookupError):
            pass
    groups.discard(os.getpgrp())
    return groups


def signal_process_groups(groups: Iterable[int], sent_signal: signal.Signals) -> None:
    for group in groups:
        try:
            os.killpg(group, sent_signal)
        except (OSError, PermissionError, ProcessLookupError):
            pass


def live_process_groups(groups: Iterable[int]) -> set[int]:
    live: set[int] = set()
    for group in groups:
        try:
            os.killpg(group, 0)
        except (OSError, PermissionError, ProcessLookupError):
            continue
        live.add(group)
    return live


def process_groups_for_cleanup(root_pid: int, descendant_groups: Iterable[int]) -> set[int]:
    own_group = os.getpgrp()
    groups = set(descendant_groups)
    try:
        root_group = os.getpgid(root_pid)
        if root_group != own_group:
            groups.add(root_group)
    except (OSError, PermissionError, ProcessLookupError):
        pass
    groups.discard(own_group)
    return groups


def stop_process_tree(process: subprocess.Popen[str]) -> None:
    groups = process_groups_for_cleanup(process.pid, descendant_process_groups(process.pid))
    signal_process_groups(groups, signal.SIGTERM)

    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        process.poll()
        if process.returncode is not None:
            break
        groups = live_process_groups(groups)
        if not groups:
            break
        time.sleep(0.1)

    process.poll()
    if process.returncode is None:
        signal_process_groups(groups, signal.SIGKILL)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def create_suite_process(
    suite: str,
    *,
    swift_binary: str,
    cwd: Path | None,
    test_bundle: Path | None = None,
    xctest_binary: list[str] | None = None,
) -> subprocess.Popen[str]:
    if test_bundle is not None:
        xctest_prefix = xctest_binary if xctest_binary is not None else ["xcrun", "xctest"]
        return subprocess.Popen(
            [*xctest_prefix, "-XCTest", suite, str(test_bundle)],
            cwd=cwd,
            start_new_session=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
    return subprocess.Popen(
        [swift_binary, "test", "--skip-build", "--filter", suite],
        cwd=cwd,
        start_new_session=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )


def suite_filter_regex(suites: Sequence[str]) -> str:
    if not suites:
        raise ValueError("cannot build a suite filter without suites")
    if len(suites) == 1:
        return suites[0]
    return "^(?:" + "|".join(re.escape(suite) for suite in suites) + r")(/|$)"


def create_suite_group_process(
    suites: Sequence[str],
    *,
    swift_binary: str,
    cwd: Path | None,
    test_bundle: Path | None = None,
    xctest_binary: list[str] | None = None,
) -> subprocess.Popen[str]:
    if not suites:
        raise ValueError("cannot run an empty suite group")
    if len(suites) == 1:
        return create_suite_process(
            suites[0],
            swift_binary=swift_binary,
            cwd=cwd,
            test_bundle=test_bundle,
            xctest_binary=xctest_binary,
        )
    if test_bundle is not None:
        xctest_prefix = xctest_binary if xctest_binary is not None else ["xcrun", "xctest"]
        filter_list = ",".join(suites)
        return subprocess.Popen(
            [*xctest_prefix, "-XCTest", filter_list, str(test_bundle)],
            cwd=cwd,
            start_new_session=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
    return subprocess.Popen(
        [swift_binary, "test", "--skip-build", "--filter", suite_filter_regex(suites)],
        cwd=cwd,
        start_new_session=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )



def relay_output(process: subprocess.Popen[str], state: OutputState, output: TextIO) -> None:
    stream = process.stdout
    if stream is None:
        return
    for line in stream:
        state.observe(line)
        output.write(line)
        output.flush()


def run_suite_attempt(
    suite: str,
    *,
    timeout_seconds: float,
    attempt: int,
    process_factory: Callable[[str], subprocess.Popen[str]],
    stop_process_tree_func: Callable[[subprocess.Popen[str]], None] = stop_process_tree,
    output: TextIO = sys.stdout,
    poll_interval_seconds: float = 0.1,
    silent_startup_seconds: float | None = None,
    cancellation_event: threading.Event | None = None,
) -> SuiteRunResult:
    start = time.monotonic()
    deadline = start + timeout_seconds
    silent_deadline = start + silent_startup_seconds if silent_startup_seconds is not None else None
    state = OutputState()
    process = process_factory(suite)
    relay = threading.Thread(target=relay_output, args=(process, state, output), daemon=True)
    relay.start()

    while True:
        return_code = process.poll()
        if return_code is not None:
            relay.join(timeout=10)
            snapshot = state.snapshot()
            elapsed = time.monotonic() - start
            if return_code != 0 or snapshot.first_failure_line is not None:
                return SuiteRunResult(
                    suite=suite,
                    state="failed",
                    exit_code=return_code if return_code != 0 else 1,
                    elapsed_seconds=elapsed,
                    output_seen=snapshot.output_seen,
                    first_failure_line=snapshot.first_failure_line,
                    last_started_test=snapshot.last_started_test,
                    timed_out_after_seconds=None,
                    attempts=attempt,
                )
            return SuiteRunResult(
                suite=suite,
                state="passed",
                exit_code=0,
                elapsed_seconds=elapsed,
                output_seen=snapshot.output_seen,
                first_failure_line=None,
                last_started_test=snapshot.last_started_test,
                timed_out_after_seconds=None,
                attempts=attempt,
            )

        if state.failure_seen.is_set():
            stop_process_tree_func(process)
            relay.join(timeout=10)
            snapshot = state.snapshot()
            return SuiteRunResult(
                suite=suite,
                state="failed",
                exit_code=1,
                elapsed_seconds=time.monotonic() - start,
                output_seen=snapshot.output_seen,
                first_failure_line=snapshot.first_failure_line,
                last_started_test=snapshot.last_started_test,
                timed_out_after_seconds=None,
                attempts=attempt,
            )

        if cancellation_event is not None and cancellation_event.is_set():
            stop_process_tree_func(process)
            relay.join(timeout=10)
            snapshot = state.snapshot()
            return SuiteRunResult(
                suite=suite,
                state="cancelled",
                exit_code=130,
                elapsed_seconds=time.monotonic() - start,
                output_seen=snapshot.output_seen,
                first_failure_line=snapshot.first_failure_line,
                last_started_test=snapshot.last_started_test,
                timed_out_after_seconds=None,
                attempts=attempt,
            )

        now = time.monotonic()
        # A hosted runner can wedge Swift's cooperative executor before XCTest prints
        # anything. Kill the silent process early (before the full suite timeout) so the
        # retry fires sooner instead of burning the whole suite budget on a hung startup.
        if (
            silent_deadline is not None
            and now >= silent_deadline
            and not state.output_seen.is_set()
        ):
            stop_process_tree_func(process)
            relay.join(timeout=10)
            snapshot = state.snapshot()
            elapsed = now - start
            return SuiteRunResult(
                suite=suite,
                state="timed_out",
                exit_code=TIMEOUT_EXIT_CODE,
                elapsed_seconds=elapsed,
                output_seen=snapshot.output_seen,
                first_failure_line=snapshot.first_failure_line,
                last_started_test=snapshot.last_started_test,
                timed_out_after_seconds=elapsed,
                attempts=attempt,
            )

        if now >= deadline:
            stop_process_tree_func(process)
            relay.join(timeout=10)
            snapshot = state.snapshot()
            return SuiteRunResult(
                suite=suite,
                state="timed_out",
                exit_code=TIMEOUT_EXIT_CODE,
                elapsed_seconds=time.monotonic() - start,
                output_seen=snapshot.output_seen,
                first_failure_line=snapshot.first_failure_line,
                last_started_test=snapshot.last_started_test,
                timed_out_after_seconds=timeout_seconds,
                attempts=attempt,
            )

        time.sleep(min(poll_interval_seconds, max(deadline - time.monotonic(), 0.0)))


def run_suite(
    suite: str,
    *,
    timeout_seconds: float,
    silent_timeout_retries: int,
    process_factory: Callable[[str], subprocess.Popen[str]],
    stop_process_tree_func: Callable[[subprocess.Popen[str]], None] = stop_process_tree,
    output: TextIO = sys.stdout,
    poll_interval_seconds: float = 0.1,
    silent_startup_seconds: float | None = None,
    cancellation_event: threading.Event | None = None,
) -> SuiteRunResult:
    max_attempts = silent_timeout_retries + 1
    for attempt in range(1, max_attempts + 1):
        result = run_suite_attempt(
            suite,
            timeout_seconds=timeout_seconds,
            attempt=attempt,
            process_factory=process_factory,
            stop_process_tree_func=stop_process_tree_func,
            output=output,
            poll_interval_seconds=poll_interval_seconds,
            silent_startup_seconds=silent_startup_seconds,
            cancellation_event=cancellation_event,
        )
        if result.state == "timed_out" and not result.output_seen and attempt < max_attempts:
            silent_seconds = (
                silent_startup_seconds if silent_startup_seconds is not None else timeout_seconds
            )
            print(
                f"::warning::{suite} produced no output for {silent_seconds:g}s; "
                f"retrying once (attempt {attempt + 1}/{max_attempts})",
                flush=True,
                file=output,
            )
            continue
        return result

    raise AssertionError("unreachable: suite retry loop did not return")


def format_last_started(last_started_test: str | None) -> str:
    return last_started_test if last_started_test is not None else "unknown"


def report_suite_result(result: SuiteRunResult, output: TextIO) -> None:
    if result.state == "passed":
        retry_note = f" after {result.attempts} attempts" if result.attempts > 1 else ""
        print(f"{result.suite} passed in {result.elapsed_seconds:.1f}s{retry_note}", flush=True, file=output)
        return

    if result.state == "timed_out":
        print(
            f"::error::{result.suite} timed out after {result.timed_out_after_seconds:g}s; "
            f"elapsed={result.elapsed_seconds:.1f}s; "
            f"last_started_test={format_last_started(result.last_started_test)}; "
            f"output_seen={str(result.output_seen).lower()}",
            flush=True,
            file=output,
        )
        return

    if result.state == "cancelled":
        print(
            f"::warning::{result.suite} cancelled after another suite failed; "
            f"elapsed={result.elapsed_seconds:.1f}s; "
            f"last_started_test={format_last_started(result.last_started_test)}",
            flush=True,
            file=output,
        )
        return

    if result.first_failure_line is not None:
        print(
            f"::error::{result.suite} failed; stopping after first XCTest issue. "
            f"elapsed={result.elapsed_seconds:.1f}s; "
            f"last_started_test={format_last_started(result.last_started_test)}",
            flush=True,
            file=output,
        )
        print(f"First XCTest issue: {result.first_failure_line}", flush=True, file=output)
        return

    print(
        f"::error::{result.suite} exited with status {result.exit_code}; "
        f"elapsed={result.elapsed_seconds:.1f}s; "
        f"last_started_test={format_last_started(result.last_started_test)}",
        flush=True,
        file=output,
    )


def print_suite_plan_summary(plan: SuitePlan, workers: int, output: TextIO) -> None:
    print(
        "Suite plan: "
        f"{len(plan.pinned_serial)} pinned serial, "
        f"{len(plan.parallel_eligible)} parallel eligible, "
        f"workers={workers}",
        flush=True,
        file=output,
    )


def run_suite_group_and_report(
    group: SuiteGroup,
    *,
    timeout_seconds: float,
    silent_timeout_retries: int,
    swift_binary: str,
    cwd: Path | None,
    output: TextIO,
    silent_startup_seconds: float | None,
    test_bundle: Path | None,
    test_bundles: dict[str, Path] | None,
    xctest_binary: list[str] | None,
    cancellation_event: threading.Event | None = None,
) -> SuiteRunResult:
    suite = group.label
    selected_bundle = test_bundle if test_bundle is not None else bundle_for_suite(group.suites[0], test_bundles)
    if test_bundles is not None and selected_bundle is None:
        print(
            f"::error::No XCTest bundle found for suite target {test_target_for_suite(group.suites[0])} "
            f"while routing {suite}; available bundles: {sorted(test_bundles)}",
            flush=True,
            file=output,
        )
        return SuiteRunResult(
            suite=suite,
            state="failed",
            exit_code=1,
            elapsed_seconds=0.0,
            output_seen=False,
            first_failure_line=None,
            last_started_test=None,
            timed_out_after_seconds=None,
            attempts=0,
        )
    print(f"::group::{suite}", flush=True, file=output)
    process_factory = lambda _selected_suite: create_suite_group_process(  # noqa: E731
        group.suites,
        swift_binary=swift_binary,
        cwd=cwd,
        test_bundle=selected_bundle,
        xctest_binary=xctest_binary,
    )
    result = run_suite(
        suite,
        timeout_seconds=timeout_seconds,
        silent_timeout_retries=silent_timeout_retries,
        process_factory=process_factory,
        output=output,
        silent_startup_seconds=silent_startup_seconds,
        cancellation_event=cancellation_event,
    )
    report_suite_result(result, output)
    print("::endgroup::", flush=True, file=output)
    return result


def run_and_report_single_suite(
    suite: str,
    *,
    timeout_seconds: float,
    silent_timeout_retries: int,
    swift_binary: str,
    cwd: Path | None,
    output: TextIO,
    silent_startup_seconds: float | None,
    test_bundle: Path | None,
    test_bundles: dict[str, Path] | None,
    xctest_binary: list[str] | None,
    cancellation_event: threading.Event | None = None,
) -> SuiteRunResult:
    return run_suite_group_and_report(
        SuiteGroup((suite,), 0.0),
        timeout_seconds=timeout_seconds,
        silent_timeout_retries=silent_timeout_retries,
        swift_binary=swift_binary,
        cwd=cwd,
        output=output,
        silent_startup_seconds=silent_startup_seconds,
        test_bundle=test_bundle,
        test_bundles=test_bundles,
        xctest_binary=xctest_binary,
        cancellation_event=cancellation_event,
    )


def run_suite_buffered(
    group: SuiteGroup,
    *,
    timeout_seconds: float,
    silent_timeout_retries: int,
    swift_binary: str,
    cwd: Path | None,
    silent_startup_seconds: float | None,
    test_bundle: Path | None,
    test_bundles: dict[str, Path] | None,
    xctest_binary: list[str] | None,
    cancellation_event: threading.Event | None = None,
) -> tuple[SuiteRunResult, str]:
    output = io.StringIO()
    result = run_suite_group_and_report(
        group,
        timeout_seconds=timeout_seconds,
        silent_timeout_retries=silent_timeout_retries,
        swift_binary=swift_binary,
        cwd=cwd,
        output=output,
        silent_startup_seconds=silent_startup_seconds,
        test_bundle=test_bundle,
        test_bundles=test_bundles,
        xctest_binary=xctest_binary,
        cancellation_event=cancellation_event,
    )
    if (
        cancellation_event is not None
        and result.state not in {"passed", "cancelled"}
    ):
        cancellation_event.set()
    return result, output.getvalue()


def validate_shard_args(shard_count: int, shard_index: int) -> None:
    if shard_count <= 0:
        raise ValueError("--shard-count must be greater than zero")
    if shard_index < 1 or shard_index > shard_count:
        raise ValueError("--shard-index must be between 1 and --shard-count")


def plan_selected_suites(
    suites: Sequence[str],
    *,
    ledger: Path | None,
    shard_count: int,
    shard_index: int,
    strict_ledger: bool,
    slow_first: bool,
    batch_max_seconds: float,
    require_runtime_for_batching: bool,
) -> tuple[list[SuitePlanEntry], dict[str, Any] | None]:
    validate_shard_args(shard_count, shard_index)
    if ledger is None:
        ordered = sorted(suites)
        return [
            SuitePlanEntry(suite=suite, estimated_seconds=1.0, batch_eligible=False)
            for suite in ordered
        ], None
    plan = ci_suite_plan(
        ledger,
        shard_count,
        suites=suites,
        batch_max_seconds=batch_max_seconds,
        require_runtime_for_batching=require_runtime_for_batching,
    )
    missing = list(plan.get("missing_suites") or [])
    if strict_ledger and missing:
        raise ValueError(f"ledger is missing discovered suites: {missing[:10]}")
    if missing:
        for suite in missing:
            entry = {
                "suite": suite,
                "estimated_seconds": 1.0,
                "method_count": 0,
                "missing_runtime_count": 1,
                "execution_tiers": [],
                "resource_cost_tags": [],
                "shared_state_tags": [],
                "batch_eligible": False,
            }
            shard = min(plan["shards"], key=lambda item: (item["estimated_seconds"], item["index"]))
            shard["estimated_seconds"] += entry["estimated_seconds"]
            shard["suites"].append(entry)
            shard["suite_count"] = len(shard["suites"])
    entries_by_suite: dict[str, SuitePlanEntry] = {}
    for shard in plan["shards"]:
        for entry in shard["suites"]:
            entries_by_suite[str(entry["suite"])] = SuitePlanEntry(
                suite=str(entry["suite"]),
                estimated_seconds=float(entry["estimated_seconds"]),
                batch_eligible=bool(entry["batch_eligible"]),
            )
    selected_shard = plan["shards"][shard_index - 1]
    selected = [entries_by_suite[str(entry["suite"])] for entry in selected_shard["suites"]]
    if slow_first:
        selected.sort(key=lambda entry: (-entry.estimated_seconds, entry.suite))
    else:
        selected.sort(key=lambda entry: entry.suite)
    return selected, plan


def batch_suite_entries(
    entries: Sequence[SuitePlanEntry],
    *,
    batch_fast_suites: bool,
    batch_max_suites: int,
    batch_max_seconds: float,
    bundle_selector: Callable[[str], Path | None],
) -> list[SuiteGroup]:
    if batch_max_suites <= 0:
        raise ValueError("--batch-max-suites must be greater than zero")
    if batch_max_seconds <= 0:
        raise ValueError("--batch-max-seconds must be greater than zero")
    groups: list[SuiteGroup] = []
    pending: list[SuitePlanEntry] = []
    pending_bundle: Path | None = None

    def flush() -> None:
        nonlocal pending, pending_bundle
        if pending:
            groups.append(
                SuiteGroup(
                    tuple(entry.suite for entry in pending),
                    sum(entry.estimated_seconds for entry in pending),
                )
            )
            pending = []
            pending_bundle = None

    for entry in entries:
        selected_bundle = bundle_selector(entry.suite)
        if not batch_fast_suites or not entry.batch_eligible:
            flush()
            groups.append(SuiteGroup((entry.suite,), entry.estimated_seconds))
            continue
        if (
            pending
            and (
                len(pending) >= batch_max_suites
                or sum(item.estimated_seconds for item in pending) + entry.estimated_seconds > batch_max_seconds
                or selected_bundle != pending_bundle
            )
        ):
            flush()
        pending.append(entry)
        pending_bundle = selected_bundle
    flush()
    return groups


def run_all_suites(
    suites: Iterable[str],
    *,
    timeout_seconds: float,
    silent_timeout_retries: int,
    swift_binary: str,
    cwd: Path | None,
    output: TextIO = sys.stdout,
    silent_startup_seconds: float | None = None,
    test_bundle: Path | None = None,
    test_bundles: dict[str, Path] | None = None,
    xctest_binary: list[str] | None = None,
    suite_plan: SuitePlan | None = None,
    workers: int = 1,
    ledger: Path | None = None,
    shard_count: int = 1,
    shard_index: int = 1,
    strict_ledger: bool = False,
    slow_first: bool = False,
    batch_fast_suites: bool = False,
    batch_max_suites: int = 4,
    batch_max_seconds: float = 5.0,
    require_runtime_for_batching: bool = True,
) -> int:
    suite_list = list(suites)
    passed_results: list[SuiteRunResult] = []
    first_failure: SuiteRunResult | None = None
    if workers <= 0:
        print("::error::--workers must be greater than zero", flush=True, file=output)
        return 1
    # Parallel canaries must not invent parallel_eligible defaults for suites
    # absent from the ledger; force the strict classification contract.
    if workers > 1 and not strict_ledger:
        print(
            "::warning::--workers > 1 enables --strict-ledger so missing ledger "
            "suites cannot default to parallel_eligible",
            flush=True,
            file=output,
        )
        strict_ledger = True
    serial_plan = suite_plan or build_suite_plan(suite_list, ledger_suites={}, serial_policy={})
    if test_bundle is not None:
        print(
            f"Using xcrun xctest bundle: {test_bundle}",
            flush=True,
            file=output,
        )
    elif test_bundles:
        names = ", ".join(sorted(test_bundles))
        print(
            f"Using xcrun xctest bundles by suite target: {names}",
            flush=True,
            file=output,
        )
    try:
        selected_entries, shard_plan = plan_selected_suites(
            suite_list,
            ledger=ledger,
            shard_count=shard_count,
            shard_index=shard_index,
            strict_ledger=strict_ledger,
            slow_first=slow_first,
            batch_max_seconds=batch_max_seconds,
            require_runtime_for_batching=require_runtime_for_batching,
        )
        groups = batch_suite_entries(
            selected_entries,
            batch_fast_suites=batch_fast_suites,
            batch_max_suites=batch_max_suites,
            batch_max_seconds=batch_max_seconds,
            bundle_selector=lambda suite: (
                test_bundle if test_bundle is not None else bundle_for_suite(suite, test_bundles)
            ),
        )
    except (OptimizerError, ValueError) as error:
        print(f"::error::{error}", flush=True, file=output)
        return 1
    if ledger is not None:
        total = shard_plan["shards"][shard_index - 1]["estimated_seconds"] if shard_plan is not None else 0.0
        print(
            f"Selected app test shard {shard_index}/{shard_count}: "
            f"{len(selected_entries)} suites, estimated {total:.1f}s, {len(groups)} process groups",
            flush=True,
            file=output,
        )
    selected_names = {entry.suite for entry in selected_entries}
    selected_serial_plan = SuitePlan(
        suites=tuple(planned for planned in serial_plan.suites if planned.suite in selected_names)
    )
    print_suite_plan_summary(selected_serial_plan, workers, output)
    pinned_names = {suite.suite for suite in selected_serial_plan.pinned_serial}

    if workers == 1:
        for group in groups:
            result = run_suite_group_and_report(
                group,
                timeout_seconds=timeout_seconds,
                silent_timeout_retries=silent_timeout_retries,
                swift_binary=swift_binary,
                cwd=cwd,
                output=output,
                silent_startup_seconds=silent_startup_seconds,
                test_bundle=test_bundle,
                test_bundles=test_bundles,
                xctest_binary=xctest_binary,
            )
            if result.state != "passed":
                return result.exit_code
            passed_results.append(result)
    else:
        pinned_groups = [group for group in groups if any(suite in pinned_names for suite in group.suites)]
        eligible_groups = [group for group in groups if not any(suite in pinned_names for suite in group.suites)]
        pending_eligible = iter(eligible_groups)
        cancellation_event = threading.Event()
        futures: dict[Future[tuple[SuiteRunResult, str]], str] = {}

        def submit_next(executor: ThreadPoolExecutor) -> bool:
            try:
                group = next(pending_eligible)
            except StopIteration:
                return False
            futures[
                executor.submit(
                    run_suite_buffered,
                    group,
                    timeout_seconds=timeout_seconds,
                    silent_timeout_retries=silent_timeout_retries,
                    swift_binary=swift_binary,
                    cwd=cwd,
                    silent_startup_seconds=silent_startup_seconds,
                    test_bundle=test_bundle,
                    test_bundles=test_bundles,
                    xctest_binary=xctest_binary,
                    cancellation_event=cancellation_event,
                )
            ] = group.label
            return True

        # Pinned groups run on this coordinator thread while the pool runs up to
        # `workers` parallel-eligible groups, so peak concurrency is workers + 1
        # when a pinned suite overlaps in-flight eligible work. That is intentional:
        # lane tags must fully partition shared-state conflicts before a canary.
        with ThreadPoolExecutor(max_workers=workers) as executor:
            for _ in range(workers):
                if not submit_next(executor):
                    break

            pinned_index = 0
            while futures or (pinned_index < len(pinned_groups) and first_failure is None):
                if first_failure is None and pinned_index < len(pinned_groups):
                    result = run_suite_group_and_report(
                        pinned_groups[pinned_index],
                        timeout_seconds=timeout_seconds,
                        silent_timeout_retries=silent_timeout_retries,
                        swift_binary=swift_binary,
                        cwd=cwd,
                        output=output,
                        silent_startup_seconds=silent_startup_seconds,
                        test_bundle=test_bundle,
                        test_bundles=test_bundles,
                        xctest_binary=xctest_binary,
                        cancellation_event=cancellation_event,
                    )
                    pinned_index += 1
                    if result.state == "passed":
                        passed_results.append(result)
                    elif result.state == "cancelled":
                        continue
                    else:
                        first_failure = result
                        cancellation_event.set()
                        for future in futures:
                            future.cancel()
                        continue

                if not futures:
                    continue
                done, _ = wait(set(futures), timeout=0.0, return_when=FIRST_COMPLETED)
                if not done:
                    done, _ = wait(set(futures), return_when=FIRST_COMPLETED)
                for future in sorted(done, key=lambda item: futures[item]):
                    futures.pop(future)
                    if future.cancelled():
                        continue
                    result, buffered_output = future.result()
                    print(buffered_output, end="", flush=True, file=output)
                    if result.state == "passed":
                        passed_results.append(result)
                        if first_failure is None:
                            submit_next(executor)
                    elif result.state == "cancelled":
                        # Cancelled peers are fail-fast side effects of a real failure
                        # already observed (or about to be observed) on another future.
                        # Mirror the pinned-serial branch so exit codes and first_failure
                        # attribution stay tied to the actual failing suite.
                        continue
                    elif first_failure is None:
                        first_failure = result
                        cancellation_event.set()
                        for pending in futures:
                            pending.cancel()

        if first_failure is not None:
            return first_failure.exit_code

    if passed_results:
        print("Slowest app test suites:", flush=True, file=output)
        for result in sorted(passed_results, key=lambda candidate: candidate.elapsed_seconds, reverse=True)[:10]:
            print(f"  {result.elapsed_seconds:6.1f}s  {result.suite}", flush=True, file=output)
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run RepoPrompt CE app XCTest suites for hosted CI.")
    parser.add_argument("--suite-timeout-seconds", type=float, default=DEFAULT_SUITE_TIMEOUT_SECONDS)
    parser.add_argument("--silent-timeout-retries", type=int, default=DEFAULT_SILENT_TIMEOUT_RETRIES)
    parser.add_argument(
        "--silent-startup-seconds",
        type=float,
        default=DEFAULT_SILENT_STARTUP_SECONDS,
        help="Kill and retry a suite that produces no output within this many seconds, "
        "instead of waiting the full suite timeout.",
    )
    parser.add_argument("--swift-binary", default="swift")
    parser.add_argument("--cwd", type=Path, default=None)
    parser.add_argument(
        "--test-bundle",
        type=Path,
        default=None,
        help="Path to the built .xctest bundle. When provided, suites run via "
        "xcrun xctest directly instead of swift test --skip-build --filter, "
        "avoiding swift's per-invocation package resolution overhead.",
    )
    parser.add_argument(
        "--test-bundle-name",
        default=None,
        help="Exact built .xctest bundle name to auto-select when multiple bundles exist, "
        "for example RepoPromptTests.xctest.",
    )
    parser.add_argument("--shard-count", type=int, default=1)
    parser.add_argument("--shard-index", type=int, default=1)
    parser.add_argument(
        "--strict-ledger",
        action="store_true",
        default=False,
        help=(
            "Fail when discovered suites are missing from the ledger instead of "
            "defaulting them to parallel_eligible. Implied when --workers > 1."
        ),
    )
    parser.add_argument("--slow-first", action="store_true", default=False)
    parser.add_argument("--batch-fast-suites", action="store_true", default=False)
    parser.add_argument("--batch-max-suites", type=int, default=4)
    parser.add_argument("--batch-max-seconds", type=float, default=5.0)
    parser.add_argument("--require-runtime-for-batching", action="store_true", default=False)
    parser.add_argument(
        "--no-xctest-bundle",
        action="store_true",
        default=False,
        help="Disable automatic test bundle discovery and force swift test --filter.",
    )
    parser.add_argument(
        "--ledger",
        type=Path,
        default=DEFAULT_LEDGER,
        help="Test-suite contract ledger used to classify shared-state suites.",
    )
    parser.add_argument(
        "--serial-group-policy",
        type=Path,
        default=DEFAULT_SERIAL_GROUP_POLICY,
        help="JSON policy mapping shared-state tags to serial execution lanes.",
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=1,
        help=(
            "Number of optional parallel workers for parallel-eligible suites. "
            "Default 1 preserves serial execution. Values > 1 imply --strict-ledger."
        ),
    )
    parser.add_argument(
        "--print-suite-plan-json",
        action="store_true",
        default=False,
        help="Print the discovered suite execution plan as JSON and exit without running tests.",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        suites = list_suites(args.swift_binary, args.cwd)
    except subprocess.CalledProcessError as error:
        print(f"::error::swift test list failed with status {error.returncode}", flush=True)
        if error.stdout:
            print(error.stdout, end="")
        if error.stderr:
            print(error.stderr, end="", file=sys.stderr)
        return error.returncode
    try:
        ledger_suites = read_ledger_suites(args.ledger)
        serial_policy = load_serial_group_policy(args.serial_group_policy)
        suite_plan = build_suite_plan(suites, ledger_suites=ledger_suites, serial_policy=serial_policy)
    except ValueError as error:
        print(f"::error::{error}", flush=True)
        return 1

    if args.print_suite_plan_json:
        print(json.dumps(suite_plan.to_json_payload(), indent=2, sort_keys=True), flush=True)
        return 0

    test_bundle = args.test_bundle
    test_bundles: dict[str, Path] | None = None
    if test_bundle is None and not args.no_xctest_bundle:
        if args.test_bundle_name:
            requested_target = args.test_bundle_name.removesuffix(".xctest")
            mismatched = [suite for suite in suites if test_target_for_suite(suite) != requested_target]
            if mismatched:
                print(
                    f"::error::--test-bundle-name {args.test_bundle_name} cannot run suites "
                    f"from other targets: {mismatched[:5]}",
                    flush=True,
                )
                return 1
            test_bundle = discover_test_bundle(args.swift_binary, args.cwd, args.test_bundle_name)
            if test_bundle is None:
                print(
                    f"::error::--test-bundle-name {args.test_bundle_name} did not match any built XCTest bundle",
                    flush=True,
                )
                return 1
        else:
            discovered = discover_test_bundles(args.swift_binary, args.cwd)
            if len(discovered) == 1:
                # SwiftPM emits a single combined XCTest bundle named
                # ``<PackageName>PackageTests.xctest`` that contains every test
                # target's compiled tests, so the bundle filename does not match
                # any individual test target name. Use the single bundle for all
                # suites directly; per-target routing only matters when multiple
                # bundles are discovered.
                test_bundle = next(iter(discovered.values()))
            elif discovered:
                test_bundle = package_test_bundle(discovered)
                if test_bundle is None:
                    test_bundles = target_bundles_for_suites(discovered, suites)
                if test_bundle is None and test_bundles is None:
                    test_bundles = discovered
    xctest_binary = xctest_binary_path() if test_bundle is not None or test_bundles else None

    return run_all_suites(
        suites,
        timeout_seconds=args.suite_timeout_seconds,
        silent_timeout_retries=args.silent_timeout_retries,
        swift_binary=args.swift_binary,
        cwd=args.cwd,
        output=sys.stdout,
        silent_startup_seconds=args.silent_startup_seconds,
        test_bundle=test_bundle,
        test_bundles=test_bundles,
        xctest_binary=xctest_binary,
        suite_plan=suite_plan,
        workers=args.workers,
        ledger=args.ledger,
        shard_count=args.shard_count,
        shard_index=args.shard_index,
        strict_ledger=args.strict_ledger,
        slow_first=args.slow_first,
        batch_fast_suites=args.batch_fast_suites,
        batch_max_suites=args.batch_max_suites,
        batch_max_seconds=args.batch_max_seconds,
        require_runtime_for_batching=args.require_runtime_for_batching or args.batch_fast_suites,
    )


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
