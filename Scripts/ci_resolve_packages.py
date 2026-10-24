#!/usr/bin/env python3
"""Retry dependency resolution/download only, never compiler or test failures."""
from __future__ import annotations

import argparse
from pathlib import Path
import os
import signal
import subprocess
import time


def session_process_groups(session_id: int) -> set[int]:
    try:
        listing = subprocess.run(
            ['ps', '-U', str(os.getuid()), '-o', 'pid=,stat='],
            check=True, capture_output=True, text=True, timeout=5,
        )
    except subprocess.SubprocessError as error:
        raise RuntimeError('Cannot inventory dependency attempt processes; refusing to retry') from error
    groups = set()
    for line in listing.stdout.splitlines():
        raw_pid, state = line.split(maxsplit=1)
        if state.startswith('Z'):
            continue
        pid = int(raw_pid)
        try:
            if os.getsid(pid) == session_id:
                groups.add(os.getpgid(pid))
        except ProcessLookupError:
            pass
    return groups


def terminate_resolution(process: subprocess.Popen) -> None:
    # Swift's Process creates a new process group for Git children. They remain
    # in this attempt's private session, even after their parent has exited.
    for sig, grace in ((signal.SIGTERM, 5), (signal.SIGKILL, 1)):
        deadline = None
        while True:
            process.poll()
            groups = session_process_groups(process.pid)
            if not groups:
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired as error:
                    raise RuntimeError('Dependency launcher has not exited; refusing to retry') from error
                return
            if deadline is not None and time.monotonic() >= deadline:
                break
            for group in groups:
                try:
                    os.killpg(group, sig)
                except ProcessLookupError:
                    pass
                except PermissionError:
                    # Darwin may report EPERM for a group emptied since the scan.
                    if group in session_process_groups(process.pid):
                        raise
            if deadline is None:
                # Inventory can take longer than the kill grace. Start the clock
                # after signaling, then always inventory again to confirm exit.
                deadline = time.monotonic() + grace
            time.sleep(0.05)
    raise RuntimeError('Dependency attempt still has live processes; refusing to retry')


def run_resolution(command, *, cwd, check, timeout):
    process = subprocess.Popen(command, cwd=cwd, start_new_session=True)
    try:
        status = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        terminate_resolution(process)
        raise
    if status:
        terminate_resolution(process)
    return subprocess.CompletedProcess(command, status)


def resolve(root: Path, scratch_path: str | None = None, *, attempts: int = 3,
            timeout: int = 300, run=run_resolution, sleep=time.sleep) -> int:
    if not 1 <= attempts <= 5 or not 1 <= timeout <= 600:
        raise ValueError('resolution retry bounds exceeded')
    command = ['swift', 'package']
    # The dependency-free provider package has no lockfile. Root/Sentry jobs
    # always have one: prohibit pin rewrites there while resolving downloads.
    if (root / 'Package.resolved').is_file():
        command.append('--force-resolved-versions')
    if scratch_path:
        command += ['--scratch-path', scratch_path]
    command += ['resolve']
    for attempt in range(1, attempts + 1):
        print(f'Dependency resolution attempt {attempt}/{attempts}: {command}', flush=True)
        try:
            status = run(command, cwd=root, check=False, timeout=timeout).returncode
        except subprocess.TimeoutExpired:
            print(f'::warning::Dependency resolution attempt {attempt} timed out after {timeout}s; '
                  'all attempt processes were stopped', flush=True)
            status = 124
        if status == 0:
            return 0
        if attempt < attempts:
            sleep(10 * attempt)
    print(f'::error::Dependency resolution/download failed after {attempts} attempts '
          f'(last exit {status}); INFRASTRUCTURE FAILURE, build/tests not started', flush=True)
    return status or 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path.cwd())
    parser.add_argument('--scratch-path')
    args = parser.parse_args()
    return resolve(args.root, args.scratch_path)


if __name__ == '__main__':
    raise SystemExit(main())
