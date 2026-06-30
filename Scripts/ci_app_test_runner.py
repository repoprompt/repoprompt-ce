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
from typing import Callable, Iterable, TextIO

DEFAULT_SUITE_TIMEOUT_SECONDS = 180.0
DEFAULT_SILENT_TIMEOUT_RETRIES = 1
XCTEST_FAILURE_RE = re.compile(r"^.*:\d+(?::\d+)?:\s+error:\s+-\[[^\]]+\]\s+:")
XCTEST_STARTED_RE = re.compile(r"^Test Case '-\[(?P<test>[^\]]+)\]' started\.$")
TIMEOUT_EXIT_CODE = 124


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


def create_suite_process(suite: str, *, swift_binary: str, cwd: Path | None) -> subprocess.Popen[str]:
    return subprocess.Popen(
        [swift_binary, "test", "--skip-build", "--filter", suite],
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
) -> SuiteRunResult:
    start = time.monotonic()
    deadline = start + timeout_seconds
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

        if time.monotonic() >= deadline:
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
        )
        if result.state == "timed_out" and not result.output_seen and attempt < max_attempts:
            print(
                f"::warning::{suite} produced no output for {timeout_seconds:g}s; "
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


def run_all_suites(
    suites: Iterable[str],
    *,
    timeout_seconds: float,
    silent_timeout_retries: int,
    swift_binary: str,
    cwd: Path | None,
    output: TextIO = sys.stdout,
) -> int:
    passed_results: list[SuiteRunResult] = []
    for suite in suites:
        print(f"::group::{suite}", flush=True, file=output)
        process_factory = lambda selected_suite: create_suite_process(  # noqa: E731
            selected_suite,
            swift_binary=swift_binary,
            cwd=cwd,
        )
        result = run_suite(
            suite,
            timeout_seconds=timeout_seconds,
            silent_timeout_retries=silent_timeout_retries,
            process_factory=process_factory,
            output=output,
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
    parser.add_argument("--swift-binary", default="swift")
    parser.add_argument("--cwd", type=Path, default=None)
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

    return run_all_suites(
        suites,
        timeout_seconds=args.suite_timeout_seconds,
        silent_timeout_retries=args.silent_timeout_retries,
        swift_binary=args.swift_binary,
        cwd=args.cwd,
    )


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
