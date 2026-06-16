#!/usr/bin/env python3
"""Identify and terminate only the configured RepoPrompt CE debug executable."""

from __future__ import annotations

import argparse
import ctypes
import errno
import os
import signal
import stat
import sys
from pathlib import Path
from typing import Callable, Protocol

PROC_ALL_PIDS = 1
PROC_PIDPATHINFO_MAXSIZE = 4096


class ProcessIdentityError(RuntimeError):
    pass


class TargetExecutableMissing(ProcessIdentityError):
    pass


class ProcessGone(ProcessIdentityError):
    pass


class ProcessInspector(Protocol):
    def list_pids(self) -> list[int]: ...

    def process_name(self, pid: int) -> str | None: ...

    def process_path(self, pid: int) -> Path: ...


class LibProcInspector:
    def __init__(self) -> None:
        if sys.platform != "darwin":
            raise ProcessIdentityError("debug app process checks require macOS")
        self.libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.libproc.proc_listpids.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int]
        self.libproc.proc_listpids.restype = ctypes.c_int
        self.libproc.proc_name.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.libproc.proc_name.restype = ctypes.c_int
        self.libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.libproc.proc_pidpath.restype = ctypes.c_int

    def list_pids(self) -> list[int]:
        capacity = 4096
        while capacity <= 1_048_576:
            buffer = (ctypes.c_int * capacity)()
            byte_count = self.libproc.proc_listpids(PROC_ALL_PIDS, 0, buffer, ctypes.sizeof(buffer))
            if byte_count <= 0:
                error = ctypes.get_errno()
                detail = os.strerror(error) if error else "process enumeration failed"
                raise ProcessIdentityError(f"could not enumerate processes: {detail}")
            count = byte_count // ctypes.sizeof(ctypes.c_int)
            if count < capacity:
                return [pid for pid in buffer[:count] if pid > 0]
            capacity *= 2
        raise ProcessIdentityError("process enumeration exceeded the supported capacity")

    def process_name(self, pid: int) -> str | None:
        buffer = ctypes.create_string_buffer(PROC_PIDPATHINFO_MAXSIZE)
        length = self.libproc.proc_name(pid, buffer, len(buffer))
        if length <= 0:
            return None
        return os.fsdecode(buffer.value)

    def process_path(self, pid: int) -> Path:
        buffer = ctypes.create_string_buffer(PROC_PIDPATHINFO_MAXSIZE)
        length = self.libproc.proc_pidpath(pid, buffer, len(buffer))
        if length <= 0:
            error = ctypes.get_errno()
            if error in {errno.ENOENT, errno.ESRCH}:
                raise ProcessGone(f"process {pid} exited before its executable could be resolved")
            detail = os.strerror(error) if error else "process is unavailable"
            raise ProcessIdentityError(f"could not resolve executable for pid {pid}: {detail}")
        try:
            return Path(os.fsdecode(buffer.value)).resolve(strict=True)
        except OSError as exc:
            raise ProcessIdentityError(f"could not resolve executable path for pid {pid}: {exc}") from exc


def expected_executable_path(path: Path) -> Path:
    try:
        resolved = path.expanduser().resolve(strict=True)
        metadata = resolved.stat()
    except FileNotFoundError as exc:
        raise TargetExecutableMissing(f"target debug app executable is not installed: {path}") from exc
    except OSError as exc:
        raise ProcessIdentityError(f"target debug app executable is unavailable: {path}: {exc}") from exc
    if not stat.S_ISREG(metadata.st_mode) or not metadata.st_mode & 0o111:
        raise ProcessIdentityError(f"target debug app executable is not executable: {resolved}")
    return resolved


def matching_processes(expected_executable: Path, inspector: ProcessInspector | None = None) -> list[int]:
    try:
        expected = expected_executable_path(expected_executable)
    except TargetExecutableMissing:
        return []
    active_inspector = inspector or LibProcInspector()
    matches: list[int] = []
    for pid in active_inspector.list_pids():
        if active_inspector.process_name(pid) != expected.name:
            continue
        try:
            actual = active_inspector.process_path(pid)
        except ProcessGone:
            continue
        if actual == expected:
            matches.append(pid)
    return matches


def terminate_matching_processes(
    expected_executable: Path,
    inspector: ProcessInspector | None = None,
    signaler: Callable[[int, int], None] = os.kill,
) -> list[int]:
    try:
        expected = expected_executable_path(expected_executable)
    except TargetExecutableMissing:
        return []
    active_inspector = inspector or LibProcInspector()
    signaled: list[int] = []
    for pid in matching_processes(expected, active_inspector):
        try:
            actual = active_inspector.process_path(pid)
        except ProcessGone:
            continue
        if actual != expected:
            raise ProcessIdentityError(
                f"refusing to signal pid {pid}: executable changed during identity revalidation "
                f"(expected {expected}, got {actual})"
            )
        try:
            signaler(pid, signal.SIGTERM)
        except ProcessLookupError:
            continue
        except OSError as exc:
            raise ProcessIdentityError(f"could not signal debug app pid {pid}: {exc}") from exc
        signaled.append(pid)
    return signaled


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["list", "terminate"])
    parser.add_argument("--executable", required=True, type=Path)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        if args.operation == "list":
            pids = matching_processes(args.executable)
        else:
            pids = terminate_matching_processes(args.executable)
    except ProcessIdentityError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    for pid in pids:
        print(pid)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
