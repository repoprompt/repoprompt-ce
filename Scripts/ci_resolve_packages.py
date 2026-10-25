#!/usr/bin/env python3
"""Retry dependency resolution/download only, never compiler or test failures."""
from __future__ import annotations

import argparse
from pathlib import Path
import signal
import subprocess
import time
from ci_process_session import defer_cancellation_during_cleanup, terminate_session


def terminate_resolution(process: subprocess.Popen) -> None:
    terminate_session(process)


def run_resolution(command, *, cwd, check, timeout):
    process = None
    pending_cancellation = None
    timeout_error = None

    def cancel_resolution(signum, _frame):
        nonlocal pending_cancellation
        if pending_cancellation is None:
            pending_cancellation = signum
        # Popen may already have launched the child without returning its handle.
        # Defer until ownership is recorded; masking here would also mask the child.
        if process is not None:
            if pending_cancellation == signal.SIGINT:
                raise KeyboardInterrupt
            raise SystemExit(128 + pending_cancellation)

    previous_sigterm = signal.getsignal(signal.SIGTERM)
    previous_sigint = signal.getsignal(signal.SIGINT)
    try:
        signal.signal(signal.SIGTERM, cancel_resolution)
        signal.signal(signal.SIGINT, cancel_resolution)
        process = subprocess.Popen(command, cwd=cwd, start_new_session=True)
        if pending_cancellation is not None:
            cancel_resolution(pending_cancellation, None)
        try:
            status = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired as error:
            # A timeout is retryable only after cleanup. A first cancellation
            # during that cleanup must abort instead of being hidden by this error.
            timeout_error = error
    finally:
        try:
            if process is not None:
                with defer_cancellation_during_cleanup():
                    terminate_resolution(process)
        finally:
            signal.signal(signal.SIGINT, previous_sigint)
            signal.signal(signal.SIGTERM, previous_sigterm)
    if timeout_error is not None:
        raise timeout_error
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
