#!/usr/bin/env python3
"""Fail-closed macOS ownership checks for packaged MCP release sockets."""

from __future__ import annotations

import argparse
import ctypes
import errno
import os
import re
import socket
import stat
import sys
from pathlib import Path

RELEASE_SOCKET_PATTERN = re.compile(r"^repoprompt-ce-[0-9]+\.sock$")
SOL_LOCAL = 0
LOCAL_PEERPID = 0x002
TEMPORARY_UNAVAILABLE = 75


class OwnershipError(RuntimeError):
    pass


def process_path(pid: int) -> Path:
    if sys.platform != "darwin":
        raise OwnershipError("packaged MCP socket ownership checks require macOS")
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    libproc.proc_pidpath.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)
    length = libproc.proc_pidpath(pid, buffer, len(buffer))
    if length <= 0:
        error = ctypes.get_errno()
        detail = os.strerror(error) if error else "process is unavailable"
        raise OwnershipError(f"could not resolve executable for pid {pid}: {detail}")
    return Path(os.fsdecode(buffer.value)).resolve(strict=True)


def validate_expected_process(pid: int, expected_executable: Path) -> None:
    if pid <= 0:
        raise OwnershipError(f"invalid expected app pid: {pid}")
    expected = expected_executable.resolve(strict=True)
    metadata = expected.stat()
    if not stat.S_ISREG(metadata.st_mode) or not metadata.st_mode & 0o111:
        raise OwnershipError(f"expected app executable is not an executable regular file: {expected}")
    actual = process_path(pid)
    if actual != expected:
        raise OwnershipError(f"pid {pid} executable mismatch: expected {expected}, got {actual}")


def validate_socket_directory(directory: Path, *, allow_missing: bool) -> bool:
    try:
        metadata = directory.lstat()
    except FileNotFoundError:
        if allow_missing:
            return False
        raise OwnershipError(f"release socket directory does not exist: {directory}")
    if not stat.S_ISDIR(metadata.st_mode):
        raise OwnershipError(f"release socket directory is not a real directory: {directory}")
    if metadata.st_uid != os.getuid():
        raise OwnershipError(f"release socket directory is not owned by uid {os.getuid()}: {directory}")
    if metadata.st_mode & 0o077:
        raise OwnershipError(f"release socket directory is not owner-only: {directory}")
    return True


def release_socket_paths(directory: Path, *, allow_missing: bool) -> list[Path]:
    if not validate_socket_directory(directory, allow_missing=allow_missing):
        return []
    return sorted(
        (Path(entry.path) for entry in os.scandir(directory) if RELEASE_SOCKET_PATTERN.fullmatch(entry.name)),
        key=lambda path: path.name,
    )


def validate_socket_path(path: Path) -> os.stat_result:
    if not RELEASE_SOCKET_PATTERN.fullmatch(path.name):
        raise OwnershipError(f"unexpected release socket name: {path}")
    metadata = path.lstat()
    if not stat.S_ISSOCK(metadata.st_mode):
        raise OwnershipError(f"release socket path is not a UNIX socket: {path}")
    if metadata.st_uid != os.getuid():
        raise OwnershipError(f"release socket is not owned by uid {os.getuid()}: {path}")
    return metadata


def connected_peer_pid(path: Path) -> int | None:
    try:
        before = validate_socket_path(path)
    except FileNotFoundError:
        return None

    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(1.0)
    try:
        try:
            client.connect(os.fspath(path))
        except OSError as error:
            if error.errno in (errno.ENOENT, errno.ECONNREFUSED):
                return None
            raise OwnershipError(f"could not safely probe release socket {path}: {error}") from error
        peer_pid = client.getsockopt(SOL_LOCAL, LOCAL_PEERPID)
        after = validate_socket_path(path)
    finally:
        client.close()

    if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
        raise OwnershipError(f"release socket path changed during ownership probe: {path}")
    if not isinstance(peer_pid, int) or peer_pid <= 0:
        raise OwnershipError(f"release socket did not expose a valid peer pid: {path}")
    return peer_pid


def preflight(directory: Path) -> None:
    for path in release_socket_paths(directory, allow_missing=True):
        peer_pid = connected_peer_pid(path)
        if peer_pid is not None:
            raise OwnershipError(f"pre-existing live release socket {path} is owned by pid {peer_pid}")


def find_owner(directory: Path, expected_pid: int, expected_executable: Path) -> Path | None:
    validate_expected_process(expected_pid, expected_executable)
    owned: list[Path] = []
    for path in release_socket_paths(directory, allow_missing=True):
        peer_pid = connected_peer_pid(path)
        if peer_pid is None:
            continue
        if peer_pid != expected_pid:
            raise OwnershipError(f"live release socket {path} belongs to pid {peer_pid}, not launched pid {expected_pid}")
        owned.append(path)
    if not owned:
        return None
    if len(owned) != 1:
        raise OwnershipError(f"launched pid {expected_pid} owns multiple release sockets: {', '.join(map(str, owned))}")
    return owned[0]


def verify_owner(path: Path, expected_pid: int, expected_executable: Path) -> None:
    validate_expected_process(expected_pid, expected_executable)
    validate_socket_directory(path.parent, allow_missing=False)
    peer_pid = connected_peer_pid(path)
    if peer_pid is None:
        raise OwnershipError(f"release socket is not live: {path}")
    if peer_pid != expected_pid:
        raise OwnershipError(f"release socket {path} belongs to pid {peer_pid}, not launched pid {expected_pid}")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subparsers = result.add_subparsers(dest="command", required=True)
    preflight_parser = subparsers.add_parser("preflight")
    preflight_parser.add_argument("directory", type=Path)
    find_parser = subparsers.add_parser("find-owner")
    find_parser.add_argument("directory", type=Path)
    find_parser.add_argument("pid", type=int)
    find_parser.add_argument("expected_executable", type=Path)
    verify_parser = subparsers.add_parser("verify-owner")
    verify_parser.add_argument("socket_path", type=Path)
    verify_parser.add_argument("pid", type=int)
    verify_parser.add_argument("expected_executable", type=Path)
    path_parser = subparsers.add_parser("process-path")
    path_parser.add_argument("pid", type=int)
    return result


def main() -> int:
    arguments = parser().parse_args()
    try:
        if arguments.command == "preflight":
            preflight(arguments.directory)
        elif arguments.command == "find-owner":
            path = find_owner(arguments.directory, arguments.pid, arguments.expected_executable)
            if path is None:
                return TEMPORARY_UNAVAILABLE
            print(path)
        elif arguments.command == "verify-owner":
            verify_owner(arguments.socket_path, arguments.pid, arguments.expected_executable)
        elif arguments.command == "process-path":
            print(process_path(arguments.pid))
        else:
            raise OwnershipError(f"unsupported command: {arguments.command}")
    except (OSError, OwnershipError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
