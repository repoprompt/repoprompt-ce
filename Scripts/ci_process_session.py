#!/usr/bin/env python3
"""Bounded cleanup for subprocesses launched in a private POSIX session."""
from __future__ import annotations

from contextlib import contextmanager
import os
import signal
import subprocess
import sys
import time


@contextmanager
def defer_cancellation_during_cleanup():
    """Drain owned processes before honoring cancellation, preserving an active failure."""
    incoming_exception = sys.exc_info()[1]
    deferred_signal = None
    previous_sigterm = signal.getsignal(signal.SIGTERM)
    previous_sigint = signal.getsignal(signal.SIGINT)

    def defer_cancellation(signum, _frame):
        nonlocal deferred_signal
        if deferred_signal is None:
            deferred_signal = signum

    cleanup_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM, signal.SIGINT})
    try:
        # A first cancellation during normal teardown still cancels; subsequent
        # signals must not interrupt the inventory or strand an owned child.
        signal.signal(signal.SIGTERM, defer_cancellation)
        signal.signal(signal.SIGINT, defer_cancellation)
        yield
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, cleanup_mask)
        signal.signal(signal.SIGINT, previous_sigint)
        signal.signal(signal.SIGTERM, previous_sigterm)
    if deferred_signal is not None and incoming_exception is None:
        raise SystemExit(128 + deferred_signal)


def session_process_groups(session_id: int) -> set[int]:
    try:
        listing = subprocess.run(
            ['ps', '-U', str(os.getuid()), '-o', 'pid=,stat='],
            check=True, capture_output=True, text=True, timeout=5,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise RuntimeError('Cannot inventory child processes; refusing to continue') from error
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


def signal_session(session_id: int, sig: int, *, groups: set[int] | None = None) -> None:
    for group in session_process_groups(session_id) if groups is None else groups:
        try:
            os.killpg(group, sig)
        except ProcessLookupError:
            pass
        except PermissionError:
            # Darwin may report EPERM for a group emptied since the inventory.
            if group in session_process_groups(session_id):
                raise


def terminate_session(
    process: subprocess.Popen,
    *,
    escalation: tuple[tuple[int, float], ...] = ((signal.SIGTERM, 5), (signal.SIGKILL, 1)),
) -> None:
    # Swift's Process creates new groups for children. The private session still
    # owns them after the launcher exits or their standard output closes.
    for sig, grace in escalation:
        deadline = None
        while True:
            process.poll()
            groups = session_process_groups(process.pid)
            if not groups:
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired as error:
                    raise RuntimeError('Process launcher has not exited; refusing to continue') from error
                return
            if deadline is not None and time.monotonic() >= deadline:
                break
            signal_session(process.pid, sig, groups=groups)
            if deadline is None:
                deadline = time.monotonic() + grace
            time.sleep(0.05)
    raise RuntimeError('Process session still has live processes; refusing to continue')
