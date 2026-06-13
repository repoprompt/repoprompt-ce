#!/usr/bin/env python3
"""Run SwiftPM XCTest methods serially, two methods per fresh process by default.

A single long-lived XCTest process can retain AppKit animations and asynchronous
service tasks created by earlier app tests. On lower-core CI runners that can
starve later XCTest invocations indefinitely. Method shards preserve the exact
``swift test list`` order while bounding process-wide test state.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
from collections.abc import Sequence


DEFAULT_TESTS_PER_SHARD = 2
DEFAULT_SHARD_TIMEOUT_SECONDS = 120
PROCESS_TERMINATION_GRACE_SECONDS = 5
PROCESS_SNAPSHOT_TIMEOUT_SECONDS = 5


class ShardTimeoutError(RuntimeError):
    pass


def parse_listed_test_ids(output: str) -> list[str]:
    test_ids: list[str] = []
    for raw_line in output.splitlines():
        test_id = raw_line.strip()
        suite_id, separator, method_id = test_id.partition("/")
        if (
            separator
            and "." in suite_id
            and method_id
            and "/" not in method_id
            and not any(character.isspace() for character in test_id)
        ):
            test_ids.append(test_id)
    return test_ids


def listed_test_ids() -> list[str]:
    result = subprocess.run(
        ["swift", "test", "list"],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    )
    test_ids = parse_listed_test_ids(result.stdout)
    if not test_ids:
        raise RuntimeError("swift test list returned no XCTest methods")
    return test_ids


def chunks(values: Sequence[str], size: int) -> list[list[str]]:
    return [list(values[offset : offset + size]) for offset in range(0, len(values), size)]


def exact_test_filter(test_ids: Sequence[str]) -> str:
    if not test_ids:
        raise ValueError("test shard must not be empty")
    alternatives = "|".join(re.escape(test_id) for test_id in test_ids)
    return rf"^(?:{alternatives})$"


def display_test_id(test_id: str) -> str:
    suite_id, method_id = test_id.rsplit("/", 1)
    return f"{suite_id.rsplit('.', 1)[-1]}/{method_id}"


def snapshot_descendant_pids(root_pid: int) -> list[int]:
    snapshot_process = subprocess.Popen(
        ["ps", "-axo", "pid=,ppid="],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        stdout, stderr = snapshot_process.communicate(
            timeout=PROCESS_SNAPSHOT_TIMEOUT_SECONDS
        )
    except subprocess.TimeoutExpired:
        snapshot_process.kill()
        snapshot_process.communicate()
        raise
    if snapshot_process.returncode != 0:
        raise subprocess.CalledProcessError(
            snapshot_process.returncode,
            snapshot_process.args,
            output=stdout,
            stderr=stderr,
        )

    children_by_parent: dict[int, list[int]] = {}
    for line in stdout.splitlines():
        fields = line.split()
        if len(fields) != 2:
            continue
        try:
            pid, parent_pid = (int(field) for field in fields)
        except ValueError:
            continue
        if pid != snapshot_process.pid:
            children_by_parent.setdefault(parent_pid, []).append(pid)

    descendants: list[int] = []
    visited = {root_pid}

    def append_descendants(parent_pid: int) -> None:
        for child_pid in children_by_parent.get(parent_pid, []):
            if child_pid in visited:
                continue
            visited.add(child_pid)
            append_descendants(child_pid)
            descendants.append(child_pid)

    append_descendants(root_pid)
    return descendants


def process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def process_group_exists(process_group_id: int) -> bool:
    try:
        os.killpg(process_group_id, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def signal_processes(pids: Sequence[int], signal_number: signal.Signals) -> None:
    for pid in pids:
        try:
            os.kill(pid, signal_number)
        except ProcessLookupError:
            pass


def wait_for_process_cleanup(
    process: subprocess.Popen[bytes],
    known_descendant_pids: Sequence[int],
    timeout_seconds: float,
) -> tuple[list[int], bool]:
    deadline = time.monotonic() + timeout_seconds
    while True:
        process.poll()
        surviving_pids = [pid for pid in known_descendant_pids if process_exists(pid)]
        group_survived = process_group_exists(process.pid)
        if not surviving_pids and not group_survived:
            return [], False
        if time.monotonic() >= deadline:
            return surviving_pids, group_survived
        time.sleep(0.05)


def terminate_process_tree(process: subprocess.Popen[bytes]) -> int:
    process_group_id = process.pid
    known_descendant_pids = snapshot_descendant_pids(process.pid)

    # Signal only PIDs proven to descend from this invocation, plus the process
    # group created specifically for it. Do not match or kill by executable name.
    signal_processes(known_descendant_pids, signal.SIGTERM)
    try:
        os.killpg(process_group_id, signal.SIGTERM)
    except ProcessLookupError:
        pass

    surviving_pids, group_survived = wait_for_process_cleanup(
        process,
        known_descendant_pids,
        PROCESS_TERMINATION_GRACE_SECONDS,
    )
    if surviving_pids:
        signal_processes(surviving_pids, signal.SIGKILL)
    if group_survived:
        try:
            os.killpg(process_group_id, signal.SIGKILL)
        except ProcessLookupError:
            pass

    try:
        process.wait(timeout=PROCESS_TERMINATION_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        try:
            os.kill(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()

    surviving_pids, group_survived = wait_for_process_cleanup(
        process,
        known_descendant_pids,
        PROCESS_TERMINATION_GRACE_SECONDS,
    )
    if surviving_pids or group_survived:
        details: list[str] = []
        if surviving_pids:
            details.append(
                "descendant PIDs " + ", ".join(str(pid) for pid in surviving_pids)
            )
        if group_survived:
            details.append(f"process group {process_group_id}")
        raise RuntimeError("timeout cleanup failed; still alive: " + "; ".join(details))

    return len(known_descendant_pids)


def run_command_with_timeout(command: Sequence[str], timeout_seconds: float) -> bool:
    process = subprocess.Popen(command, start_new_session=True)
    try:
        return_code = process.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        terminate_process_tree(process)
        return True
    except BaseException:
        terminate_process_tree(process)
        raise

    if return_code != 0:
        raise subprocess.CalledProcessError(return_code, command)
    return False


def run_shard_with_timeout_retry(
    command: Sequence[str],
    *,
    shard_description: str,
    timeout_seconds: float = DEFAULT_SHARD_TIMEOUT_SECONDS,
) -> int:
    for attempt in range(1, 3):
        timed_out = run_command_with_timeout(command, timeout_seconds)
        if not timed_out:
            return attempt - 1

        diagnostic = (
            f"{shard_description} timed out after {timeout_seconds:g}s on attempt "
            f"{attempt}/2; terminated and verified its process tree"
        )
        if attempt == 1:
            print(
                f"{diagnostic}; retrying once in a fresh process",
                file=sys.stderr,
                flush=True,
            )
        else:
            print(f"{diagnostic}; timeout retry exhausted", file=sys.stderr, flush=True)

    raise ShardTimeoutError(f"{shard_description} timed out twice")


def read_attempt_count(path: Path) -> int:
    return int(path.read_text()) if path.exists() else 0


def run_helper_simulation() -> int:
    timeout_helper = r'''
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

attempt_path = Path(sys.argv[1])
child_pid_path = Path(sys.argv[2])
attempt = int(attempt_path.read_text()) + 1 if attempt_path.exists() else 1
attempt_path.write_text(str(attempt))
if attempt > 1:
    raise SystemExit(0)

child_code = """
import signal
import time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
while True:
    time.sleep(1)
"""
child = subprocess.Popen([sys.executable, "-c", child_code], start_new_session=True)
child_pid_path.write_text(str(child.pid))
signal.signal(signal.SIGTERM, signal.SIG_IGN)
while True:
    time.sleep(1)
'''
    failure_helper = r'''
from pathlib import Path
import sys
attempt_path = Path(sys.argv[1])
attempt = int(attempt_path.read_text()) + 1 if attempt_path.exists() else 1
attempt_path.write_text(str(attempt))
raise SystemExit(7)
'''

    with tempfile.TemporaryDirectory(prefix="swift-test-shard-cleanup-") as directory:
        temporary_directory = Path(directory)
        timeout_attempt_path = temporary_directory / "timeout-attempts"
        child_pid_path = temporary_directory / "term-resistant-child-pid"
        timeout_retries = run_shard_with_timeout_retry(
            [
                sys.executable,
                "-c",
                timeout_helper,
                str(timeout_attempt_path),
                str(child_pid_path),
            ],
            shard_description="Cleanup simulation",
            timeout_seconds=0.5,
        )
        if timeout_retries != 1 or read_attempt_count(timeout_attempt_path) != 2:
            raise RuntimeError("cleanup simulation did not perform exactly one timeout retry")
        if not child_pid_path.exists():
            raise RuntimeError("cleanup simulation did not record its detached child PID")
        detached_child_pid = int(child_pid_path.read_text())
        if process_exists(detached_child_pid):
            raise RuntimeError(
                f"cleanup simulation left detached child PID {detached_child_pid} alive"
            )

        failure_attempt_path = temporary_directory / "failure-attempts"
        try:
            run_shard_with_timeout_retry(
                [sys.executable, "-c", failure_helper, str(failure_attempt_path)],
                shard_description="Nonzero-exit simulation",
                timeout_seconds=5,
            )
        except subprocess.CalledProcessError as error:
            if error.returncode != 7:
                raise RuntimeError(
                    f"nonzero-exit simulation returned {error.returncode}, expected 7"
                ) from error
        else:
            raise RuntimeError("nonzero-exit simulation unexpectedly succeeded")
        if read_attempt_count(failure_attempt_path) != 1:
            raise RuntimeError("normal nonzero exit was retried")

    print(
        "Helper simulation passed: detached TERM-resistant descendant removed, "
        "one timeout retry preserved, normal nonzero exit not retried",
        flush=True,
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--tests-per-shard",
        type=int,
        default=DEFAULT_TESTS_PER_SHARD,
        help=(
            "Maximum ordered XCTest methods per fresh test process "
            f"(default: {DEFAULT_TESTS_PER_SHARD})"
        ),
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Run the timeout cleanup and retry helper simulation",
    )
    args = parser.parse_args()
    if args.tests_per_shard < 1:
        parser.error("--tests-per-shard must be positive")
    if args.self_test:
        return run_helper_simulation()

    test_ids = listed_test_ids()
    shards = chunks(test_ids, args.tests_per_shard)
    print(
        f"Running {len(test_ids)} XCTest methods in {len(shards)} serial shards "
        f"({args.tests_per_shard} maximum per process, "
        f"{DEFAULT_SHARD_TIMEOUT_SECONDS}s timeout with one retry)",
        flush=True,
    )

    started_at = time.monotonic()
    timeout_retries = 0
    for index, shard in enumerate(shards, start=1):
        shard_description = f"Shard {index}/{len(shards)}"
        print(
            f"{shard_description}: {display_test_id(shard[0])} ... "
            f"{display_test_id(shard[-1])} ({len(shard)} tests)",
            flush=True,
        )
        timeout_retries += run_shard_with_timeout_retry(
            ["swift", "test", "--skip-build", "--filter", exact_test_filter(shard)],
            shard_description=shard_description,
        )

    elapsed = time.monotonic() - started_at
    print(
        f"Completed {len(test_ids)} XCTest methods in {len(shards)} fresh processes "
        f"after {elapsed:.1f}s with {timeout_retries} timeout retries",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as error:
        print(f"test shard command failed with exit code {error.returncode}", file=sys.stderr)
        raise SystemExit(error.returncode)
    except ShardTimeoutError as error:
        print(error, file=sys.stderr)
        raise SystemExit(124)
