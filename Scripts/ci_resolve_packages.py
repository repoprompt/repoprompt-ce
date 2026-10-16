#!/usr/bin/env python3
"""Retry dependency resolution/download only, never compiler or test failures."""
from __future__ import annotations

import argparse
from pathlib import Path
import os
import signal
import subprocess
import time


def run_resolution(command, *, cwd, check, timeout):
    # SwiftPM may spawn git/download children. Kill the whole attempt on timeout,
    # not just its launcher, before the next attempt touches the same scratch path.
    process = subprocess.Popen(command, cwd=cwd, start_new_session=True)
    try:
        status = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except PermissionError:
                # Darwin may report EPERM for an emptied group after TERM. Never
                # suppress a denied kill while the launcher is still alive.
                if process.poll() is None:
                    raise
            process.wait()
        raise
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
