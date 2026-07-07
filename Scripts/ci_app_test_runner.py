#!/usr/bin/env python3
"""Hosted CI app-test runner for RepoPrompt CE.

The GitHub macOS runner executes root XCTest suites one XCTest class at a time.
This keeps hosted CI bounded without changing stable local validation.
"""

from __future__ import annotations

import argparse
import os
import re
import signal
import subprocess
import sys
import threading
import time
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
        selected_entries, plan = plan_selected_suites(
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
        total = plan["shards"][shard_index - 1]["estimated_seconds"] if plan is not None else 0.0
        print(
            f"Selected app test shard {shard_index}/{shard_count}: "
            f"{len(selected_entries)} suites, estimated {total:.1f}s, {len(groups)} process groups",
            flush=True,
            file=output,
        )
    for group in groups:
        suite = group.label
        selected_bundle = test_bundle if test_bundle is not None else bundle_for_suite(group.suites[0], test_bundles)
        if test_bundles is not None and selected_bundle is None:
            print(
                f"::error::No XCTest bundle found for suite target {test_target_for_suite(group.suites[0])} "
                f"while routing {suite}; available bundles: {sorted(test_bundles)}",
                flush=True,
                file=output,
            )
            return 1
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
        )
        report_suite_result(result, output)
        print("::endgroup::", flush=True, file=output)
        if result.state != "passed":
            return result.exit_code
        passed_results.append(result)

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
    parser.add_argument("--ledger", type=Path, default=None)
    parser.add_argument("--shard-count", type=int, default=1)
    parser.add_argument("--shard-index", type=int, default=1)
    parser.add_argument("--strict-ledger", action="store_true", default=False)
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
