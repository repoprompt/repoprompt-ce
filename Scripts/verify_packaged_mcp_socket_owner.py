#!/usr/bin/env python3
"""Fail-closed, non-connecting macOS ownership checks for packaged MCP release sockets."""

from __future__ import annotations

import argparse
import ctypes
import errno
import fcntl
import os
import re
import socket
import stat
import sys
import tempfile
from pathlib import Path

RELEASE_SOCKET_PATTERN = re.compile(r"^repoprompt-ce-[0-9]+\.sock$")
BOUND_IDENTITY_RECORD_PREFIX = "repoprompt-ce-socket-identity-v1"
BOUND_IDENTITY_RECORD_PATTERN = re.compile(
    re.escape(BOUND_IDENTITY_RECORD_PREFIX).encode() + rb" ([0-9]+) ([0-9]+)\n"
)
TEMPORARY_UNAVAILABLE = 75

# Values and layouts below come from macOS <sys/proc_info.h> and
# <sys/socket.h>. Both supported release architectures use the same LP64 ABI.
PROC_UID_ONLY = 4
PROC_PIDLISTFDS = 1
PROC_PIDFDVNODEINFO = 1
PROC_PIDFDSOCKETINFO = 3
PROX_FDTYPE_VNODE = 1
PROX_FDTYPE_SOCKET = 2
SOCKINFO_UN = 3
SO_ACCEPTCONN = 0x0002
UNIX_ADDRESS_OFFSET = 16
SOCKADDR_UN_PATH_OFFSET = 2
SOCKADDR_UN_MAX_SIZE = 106
TRANSIENT_PROCESS_ERRORS = {errno.ENOENT, errno.ESRCH}
TRANSIENT_DESCRIPTOR_ERRORS = TRANSIENT_PROCESS_ERRORS | {errno.EBADF}


class OwnershipError(RuntimeError):
    pass


class ProcFDInfo(ctypes.Structure):
    _fields_ = [("proc_fd", ctypes.c_int32), ("proc_fdtype", ctypes.c_uint32)]


class ProcFileInfo(ctypes.Structure):
    _fields_ = [
        ("fi_openflags", ctypes.c_uint32),
        ("fi_status", ctypes.c_uint32),
        ("fi_offset", ctypes.c_int64),
        ("fi_type", ctypes.c_int32),
        ("fi_guardflags", ctypes.c_uint32),
    ]


class VInfoStat(ctypes.Structure):
    _fields_ = [
        ("vst_dev", ctypes.c_uint32),
        ("vst_mode", ctypes.c_uint16),
        ("vst_nlink", ctypes.c_uint16),
        ("vst_ino", ctypes.c_uint64),
        ("vst_uid", ctypes.c_uint32),
        ("vst_gid", ctypes.c_uint32),
        ("vst_atime", ctypes.c_int64),
        ("vst_atimensec", ctypes.c_int64),
        ("vst_mtime", ctypes.c_int64),
        ("vst_mtimensec", ctypes.c_int64),
        ("vst_ctime", ctypes.c_int64),
        ("vst_ctimensec", ctypes.c_int64),
        ("vst_birthtime", ctypes.c_int64),
        ("vst_birthtimensec", ctypes.c_int64),
        ("vst_size", ctypes.c_int64),
        ("vst_blocks", ctypes.c_int64),
        ("vst_blksize", ctypes.c_int32),
        ("vst_flags", ctypes.c_uint32),
        ("vst_gen", ctypes.c_uint32),
        ("vst_rdev", ctypes.c_uint32),
        ("vst_qspare", ctypes.c_int64 * 2),
    ]


class VnodeInfo(ctypes.Structure):
    _fields_ = [
        ("vi_stat", VInfoStat),
        ("vi_type", ctypes.c_int32),
        ("vi_pad", ctypes.c_int32),
        ("vi_fsid", ctypes.c_int32 * 2),
    ]


class VnodeFDInfo(ctypes.Structure):
    _fields_ = [("pfi", ProcFileInfo), ("pvi", VnodeInfo)]


class SockbufInfo(ctypes.Structure):
    _fields_ = [
        ("sbi_cc", ctypes.c_uint32),
        ("sbi_hiwat", ctypes.c_uint32),
        ("sbi_mbcnt", ctypes.c_uint32),
        ("sbi_mbmax", ctypes.c_uint32),
        ("sbi_lowat", ctypes.c_uint32),
        ("sbi_flags", ctypes.c_int16),
        ("sbi_timeo", ctypes.c_int16),
    ]


class SocketInfo(ctypes.Structure):
    _fields_ = [
        ("soi_stat", VInfoStat),
        ("soi_so", ctypes.c_uint64),
        ("soi_pcb", ctypes.c_uint64),
        ("soi_type", ctypes.c_int32),
        ("soi_protocol", ctypes.c_int32),
        ("soi_family", ctypes.c_int32),
        ("soi_options", ctypes.c_int16),
        ("soi_linger", ctypes.c_int16),
        ("soi_state", ctypes.c_int16),
        ("soi_qlen", ctypes.c_int16),
        ("soi_incqlen", ctypes.c_int16),
        ("soi_qlimit", ctypes.c_int16),
        ("soi_timeo", ctypes.c_int16),
        ("soi_error", ctypes.c_uint16),
        ("soi_oobmark", ctypes.c_uint32),
        ("soi_rcv", SockbufInfo),
        ("soi_snd", SockbufInfo),
        ("soi_kind", ctypes.c_int32),
        ("rfu_1", ctypes.c_uint32),
        ("soi_proto", ctypes.c_ubyte * 528),
    ]


class SocketFDInfo(ctypes.Structure):
    _fields_ = [("pfi", ProcFileInfo), ("psi", SocketInfo)]


ABI_LAYOUT = {
    "proc_fdinfo_size": ctypes.sizeof(ProcFDInfo),
    "vinfo_stat_size": ctypes.sizeof(VInfoStat),
    "vinfo_stat_inode_offset": VInfoStat.vst_ino.offset,
    "vnode_fdinfo_size": ctypes.sizeof(VnodeFDInfo),
    "vnode_fdinfo_vnode_offset": VnodeFDInfo.pvi.offset,
    "socket_info_type_offset": SocketInfo.soi_type.offset,
    "socket_info_options_offset": SocketInfo.soi_options.offset,
    "socket_info_kind_offset": SocketInfo.soi_kind.offset,
    "socket_info_protocol_offset": SocketInfo.soi_proto.offset,
    "socket_fdinfo_size": ctypes.sizeof(SocketFDInfo),
    "socket_fdinfo_socket_offset": SocketFDInfo.psi.offset,
}
EXPECTED_ABI_LAYOUT = {
    "proc_fdinfo_size": 8,
    "vinfo_stat_size": 136,
    "vinfo_stat_inode_offset": 8,
    "vnode_fdinfo_size": 176,
    "vnode_fdinfo_vnode_offset": 24,
    "socket_info_type_offset": 152,
    "socket_info_options_offset": 164,
    "socket_info_kind_offset": 232,
    "socket_info_protocol_offset": 240,
    "socket_fdinfo_size": 792,
    "socket_fdinfo_socket_offset": 24,
}
if ABI_LAYOUT != EXPECTED_ABI_LAYOUT:
    raise OwnershipError(f"unsupported macOS libproc ABI: expected {EXPECTED_ABI_LAYOUT}, got {ABI_LAYOUT}")


_LIBPROC: ctypes.CDLL | None = None


def libproc() -> ctypes.CDLL:
    global _LIBPROC
    if sys.platform != "darwin":
        raise OwnershipError("packaged MCP socket ownership checks require macOS")
    if _LIBPROC is None:
        result = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        result.proc_listpids.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int]
        result.proc_listpids.restype = ctypes.c_int
        result.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        result.proc_pidinfo.restype = ctypes.c_int
        result.proc_pidfdinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
        result.proc_pidfdinfo.restype = ctypes.c_int
        result.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        result.proc_pidpath.restype = ctypes.c_int
        _LIBPROC = result
    return _LIBPROC


def error_detail(default: str) -> tuple[int, str]:
    error = ctypes.get_errno()
    return error, os.strerror(error) if error else default


def process_path(pid: int) -> Path:
    buffer = ctypes.create_string_buffer(4096)
    ctypes.set_errno(0)
    length = libproc().proc_pidpath(pid, buffer, len(buffer))
    if length <= 0:
        _, detail = error_detail("process is unavailable")
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


def filesystem_identity(metadata: os.stat_result) -> tuple[int, int]:
    return metadata.st_dev, metadata.st_ino


def capture_socket_snapshot(
    directory: Path, *, allow_missing: bool
) -> tuple[tuple[int, int] | None, dict[str, tuple[int, int]]]:
    paths = release_socket_paths(directory, allow_missing=allow_missing)
    if not paths and not directory.exists():
        return None, {}
    directory_identity = filesystem_identity(directory.lstat())
    sockets = {path.name: filesystem_identity(validate_socket_path(path)) for path in paths}
    return directory_identity, sockets


def verify_socket_snapshot(
    directory: Path,
    expected_directory: tuple[int, int] | None,
    expected_sockets: dict[str, tuple[int, int]],
) -> None:
    actual_directory, actual_sockets = capture_socket_snapshot(directory, allow_missing=expected_directory is None)
    if actual_directory != expected_directory:
        raise OwnershipError(f"release socket directory changed during ownership inspection: {directory}")
    if actual_sockets != expected_sockets:
        raise OwnershipError(f"release socket paths changed during ownership inspection: {directory}")


def ownership_lock_path(socket_path: Path) -> Path:
    return socket_path.with_name(f"{socket_path.name}.lock")


def capture_bound_identity_lock(socket_path: Path) -> tuple[tuple[int, int], tuple[int, int]]:
    lock_path = ownership_lock_path(socket_path)
    try:
        path_metadata = lock_path.lstat()
    except FileNotFoundError as error:
        raise OwnershipError(f"release socket ownership lock is missing: {lock_path}") from error
    if not stat.S_ISREG(path_metadata.st_mode):
        raise OwnershipError(f"release socket ownership lock is not a regular file: {lock_path}")
    if path_metadata.st_uid != os.getuid() or path_metadata.st_mode & 0o077:
        raise OwnershipError(f"release socket ownership lock is not owner-only: {lock_path}")

    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
    descriptor = os.open(lock_path, flags)
    try:
        descriptor_metadata = os.fstat(descriptor)
        lock_identity = filesystem_identity(descriptor_metadata)
        if (
            lock_identity != filesystem_identity(path_metadata)
            or not stat.S_ISREG(descriptor_metadata.st_mode)
            or descriptor_metadata.st_uid != os.getuid()
            or descriptor_metadata.st_mode & 0o077
        ):
            raise OwnershipError(f"release socket ownership lock changed while opening: {lock_path}")

        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            if error.errno not in (errno.EACCES, errno.EAGAIN, errno.EWOULDBLOCK):
                raise OwnershipError(f"could not inspect release socket ownership lock {lock_path}: {error}") from error
        else:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            raise OwnershipError(f"release socket ownership lock is not held: {lock_path}")

        record = os.read(descriptor, 257)
        if len(record) > 256:
            raise OwnershipError(f"release socket ownership record is too large: {lock_path}")
        final_descriptor_metadata = os.fstat(descriptor)
        final_path_metadata = lock_path.lstat()
        if (
            filesystem_identity(final_descriptor_metadata) != lock_identity
            or filesystem_identity(final_path_metadata) != lock_identity
        ):
            raise OwnershipError(f"release socket ownership lock changed while reading: {lock_path}")
    finally:
        os.close(descriptor)

    match = BOUND_IDENTITY_RECORD_PATTERN.fullmatch(record)
    if match is None:
        raise OwnershipError(f"release socket ownership record is invalid: {lock_path}")
    recorded_socket_identity = int(match.group(1)), int(match.group(2))
    return lock_identity, recorded_socket_identity


def validate_bound_identity_evidence(
    socket_path: Path,
    expected_pid: int,
    expected_socket_identity: tuple[int, int],
) -> None:
    before = capture_bound_identity_lock(socket_path)
    lock_identity, recorded_socket_identity = before
    if recorded_socket_identity != expected_socket_identity:
        raise OwnershipError(
            f"release socket {socket_path} identity does not match the launched listener's bound identity"
        )
    if not expected_process_holds_file(expected_pid, lock_identity):
        raise OwnershipError(
            f"launched pid {expected_pid} does not hold the release socket ownership lock: "
            f"{ownership_lock_path(socket_path)}"
        )
    after = capture_bound_identity_lock(socket_path)
    if after != before:
        raise OwnershipError(f"release socket ownership evidence changed during inspection: {socket_path}")


def current_uid_pids() -> list[int]:
    required = libproc().proc_listpids(PROC_UID_ONLY, os.getuid(), None, 0)
    if required <= 0:
        _, detail = error_detail("no process table data returned")
        raise OwnershipError(f"could not enumerate uid {os.getuid()} processes: {detail}")
    capacity = max(required * 2, required + 4096, 4096)
    for _ in range(4):
        count = capacity // ctypes.sizeof(ctypes.c_int)
        entries = (ctypes.c_int * count)()
        ctypes.set_errno(0)
        returned = libproc().proc_listpids(PROC_UID_ONLY, os.getuid(), entries, ctypes.sizeof(entries))
        if returned < 0:
            _, detail = error_detail("process enumeration failed")
            raise OwnershipError(f"could not enumerate uid {os.getuid()} processes: {detail}")
        if returned % ctypes.sizeof(ctypes.c_int):
            raise OwnershipError(f"macOS libproc returned a malformed pid list of {returned} bytes")
        if returned < ctypes.sizeof(entries):
            return sorted({pid for pid in entries[: returned // ctypes.sizeof(ctypes.c_int)] if pid > 0})
        capacity *= 2
    raise OwnershipError("macOS process table changed too quickly to inspect safely")


def process_fd_entries(pid: int, *, expected_process: bool) -> list[ProcFDInfo] | None:
    ctypes.set_errno(0)
    required = libproc().proc_pidinfo(pid, PROC_PIDLISTFDS, 0, None, 0)
    if required <= 0:
        error, detail = error_detail("process has no inspectable descriptors")
        if not expected_process and (error == 0 or error in TRANSIENT_PROCESS_ERRORS):
            return None
        raise OwnershipError(f"could not enumerate file descriptors for pid {pid}: {detail}")
    capacity = max(required * 2, required + 4096, 4096)
    for _ in range(4):
        buffer = ctypes.create_string_buffer(capacity)
        ctypes.set_errno(0)
        returned = libproc().proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer, capacity)
        if returned <= 0:
            error, detail = error_detail("process became unavailable")
            if not expected_process and (error == 0 or error in TRANSIENT_PROCESS_ERRORS):
                return None
            raise OwnershipError(f"could not enumerate file descriptors for pid {pid}: {detail}")
        if returned % ctypes.sizeof(ProcFDInfo):
            raise OwnershipError(f"macOS libproc returned a malformed fd list for pid {pid}: {returned} bytes")
        if returned < capacity:
            entries = (ProcFDInfo * (returned // ctypes.sizeof(ProcFDInfo))).from_buffer_copy(buffer.raw[:returned])
            return list(entries)
        capacity *= 2
    raise OwnershipError(f"pid {pid} descriptor table changed too quickly to inspect safely")


def socket_fd_info(pid: int, descriptor: int, *, expected_process: bool) -> SocketFDInfo | None:
    result = SocketFDInfo()
    ctypes.set_errno(0)
    returned = libproc().proc_pidfdinfo(
        pid,
        descriptor,
        PROC_PIDFDSOCKETINFO,
        ctypes.byref(result),
        ctypes.sizeof(result),
    )
    if returned <= 0:
        error, detail = error_detail("descriptor became unavailable")
        if error == 0 or error in TRANSIENT_DESCRIPTOR_ERRORS:
            return None
        if not expected_process and error in (errno.EACCES, errno.EPERM):
            raise OwnershipError(f"could not safely inspect pid {pid} socket fd {descriptor}: {detail}")
        raise OwnershipError(f"could not inspect pid {pid} socket fd {descriptor}: {detail}")
    if returned != ctypes.sizeof(SocketFDInfo):
        raise OwnershipError(
            f"unsupported macOS socket_fdinfo result for pid {pid} fd {descriptor}: "
            f"expected {ctypes.sizeof(SocketFDInfo)} bytes, got {returned}"
        )
    return result


def vnode_fd_info(pid: int, descriptor: int) -> VnodeFDInfo | None:
    result = VnodeFDInfo()
    ctypes.set_errno(0)
    returned = libproc().proc_pidfdinfo(
        pid,
        descriptor,
        PROC_PIDFDVNODEINFO,
        ctypes.byref(result),
        ctypes.sizeof(result),
    )
    if returned <= 0:
        error, detail = error_detail("descriptor became unavailable")
        if error == 0 or error in TRANSIENT_DESCRIPTOR_ERRORS:
            return None
        raise OwnershipError(f"could not inspect pid {pid} vnode fd {descriptor}: {detail}")
    if returned != ctypes.sizeof(VnodeFDInfo):
        raise OwnershipError(
            f"unsupported macOS vnode_fdinfo result for pid {pid} fd {descriptor}: "
            f"expected {ctypes.sizeof(VnodeFDInfo)} bytes, got {returned}"
        )
    return result


def expected_process_holds_file(pid: int, expected_identity: tuple[int, int]) -> bool:
    # The app opens exactly one lock fd and either flocks it immediately or closes it.
    # Together with the separately verified held flock, an exact vnode match attributes
    # the bound-identity record to this process without connecting to its socket.
    entries = process_fd_entries(pid, expected_process=True)
    if entries is None:
        return False
    for entry in entries:
        if entry.proc_fdtype != PROX_FDTYPE_VNODE:
            continue
        info = vnode_fd_info(pid, entry.proc_fd)
        if info is None:
            continue
        metadata = info.pvi.vi_stat
        if (
            (metadata.vst_dev, metadata.vst_ino) == expected_identity
            and metadata.vst_uid == os.getuid()
            and stat.S_ISREG(metadata.vst_mode)
        ):
            return True
    return False


def listening_unix_path(info: SocketFDInfo) -> Path | None:
    socket_info = info.psi
    if (
        socket_info.soi_kind != SOCKINFO_UN
        or socket_info.soi_family != socket.AF_UNIX
        or socket_info.soi_type != socket.SOCK_STREAM
        or not socket_info.soi_options & SO_ACCEPTCONN
    ):
        return None

    protocol = bytes(socket_info.soi_proto)
    address_length = protocol[UNIX_ADDRESS_OFFSET]
    address_family = protocol[UNIX_ADDRESS_OFFSET + 1]
    if address_length == 0:
        return None
    if not SOCKADDR_UN_PATH_OFFSET < address_length <= SOCKADDR_UN_MAX_SIZE:
        raise OwnershipError(f"macOS libproc returned an invalid UNIX socket address length: {address_length}")
    if address_family != socket.AF_UNIX:
        raise OwnershipError(f"macOS libproc returned an invalid UNIX socket address family: {address_family}")

    address_end = UNIX_ADDRESS_OFFSET + address_length
    path_bytes = protocol[UNIX_ADDRESS_OFFSET + SOCKADDR_UN_PATH_OFFSET : address_end]
    path_bytes, separator, trailing = path_bytes.partition(b"\0")
    if separator and any(trailing):
        raise OwnershipError("macOS libproc returned a malformed NUL-padded UNIX socket path")
    if not path_bytes:
        return None
    path = Path(os.fsdecode(path_bytes))
    if not path.is_absolute():
        raise OwnershipError(f"macOS libproc returned a non-absolute UNIX socket path: {path}")
    return path


def release_claim_name(bound_path: Path, canonical_directory: Path) -> str | None:
    if not RELEASE_SOCKET_PATTERN.fullmatch(bound_path.name):
        return None
    if Path(os.path.realpath(bound_path.parent)) != canonical_directory:
        return None
    return bound_path.name


def listening_release_names(pid: int, canonical_directory: Path, *, expected_process: bool) -> set[str] | None:
    entries = process_fd_entries(pid, expected_process=expected_process)
    if entries is None:
        return None
    names: set[str] = set()
    for entry in entries:
        if entry.proc_fdtype != PROX_FDTYPE_SOCKET:
            continue
        info = socket_fd_info(pid, entry.proc_fd, expected_process=expected_process)
        if info is None:
            continue
        bound_path = listening_unix_path(info)
        if bound_path is None:
            continue
        name = release_claim_name(bound_path, canonical_directory)
        if name is not None:
            names.add(name)
    return names


def live_release_claims(directory: Path) -> dict[str, set[int]]:
    canonical_directory = Path(os.path.realpath(directory))
    claims: dict[str, set[int]] = {}
    for pid in current_uid_pids():
        names = listening_release_names(pid, canonical_directory, expected_process=False)
        if names is None:
            continue
        for name in names:
            claims.setdefault(name, set()).add(pid)
    return claims


def format_pids(pids: set[int]) -> str:
    return ", ".join(str(pid) for pid in sorted(pids))


def preflight(directory: Path) -> None:
    directory_identity, socket_identities = capture_socket_snapshot(directory, allow_missing=True)
    claims = live_release_claims(directory)
    verify_socket_snapshot(directory, directory_identity, socket_identities)
    if claims:
        name = sorted(claims)[0]
        path = directory / name
        raise OwnershipError(f"pre-existing live release socket {path} is owned by pid(s) {format_pids(claims[name])}")


def find_owner(directory: Path, expected_pid: int, expected_executable: Path) -> Path | None:
    validate_expected_process(expected_pid, expected_executable)
    directory_identity, socket_identities = capture_socket_snapshot(directory, allow_missing=True)
    claims = live_release_claims(directory)
    verify_socket_snapshot(directory, directory_identity, socket_identities)
    validate_expected_process(expected_pid, expected_executable)

    for name, pids in sorted(claims.items()):
        foreign = pids - {expected_pid}
        if foreign:
            raise OwnershipError(
                f"live release socket {directory / name} belongs to pid(s) {format_pids(foreign)}, "
                f"not exclusively launched pid {expected_pid}"
            )

    owned = sorted(name for name, pids in claims.items() if pids == {expected_pid})
    missing_paths = [name for name in owned if name not in socket_identities]
    if missing_paths:
        raise OwnershipError(
            f"launched pid {expected_pid} owns release socket(s) without matching paths: "
            f"{', '.join(str(directory / name) for name in missing_paths)}"
        )
    if not owned:
        return None
    if len(owned) != 1:
        raise OwnershipError(
            f"launched pid {expected_pid} owns multiple release sockets: "
            f"{', '.join(str(directory / name) for name in owned)}"
        )
    owned_path = directory / owned[0]
    validate_bound_identity_evidence(owned_path, expected_pid, socket_identities[owned[0]])
    verify_socket_snapshot(directory, directory_identity, socket_identities)
    validate_expected_process(expected_pid, expected_executable)
    return owned_path


def verify_owner(path: Path, expected_pid: int, expected_executable: Path) -> None:
    validate_expected_process(expected_pid, expected_executable)
    directory_identity, socket_identities = capture_socket_snapshot(path.parent, allow_missing=False)
    if path.name not in socket_identities:
        raise OwnershipError(f"release socket is not present: {path}")
    claims = live_release_claims(path.parent)
    verify_socket_snapshot(path.parent, directory_identity, socket_identities)
    validate_expected_process(expected_pid, expected_executable)

    path_claimants = claims.get(path.name, set())
    if not path_claimants:
        raise OwnershipError(f"release socket is not live: {path}")
    if path_claimants != {expected_pid}:
        raise OwnershipError(
            f"release socket {path} is owned by pid(s) {format_pids(path_claimants)}, "
            f"not exclusively launched pid {expected_pid}"
        )
    other_owned = sorted(name for name, pids in claims.items() if expected_pid in pids and name != path.name)
    if other_owned:
        raise OwnershipError(
            f"launched pid {expected_pid} also owns unexpected release socket(s): "
            f"{', '.join(str(path.parent / name) for name in other_owned)}"
        )
    validate_bound_identity_evidence(path, expected_pid, socket_identities[path.name])
    verify_socket_snapshot(path.parent, directory_identity, socket_identities)
    validate_expected_process(expected_pid, expected_executable)


def selftest() -> None:
    with tempfile.TemporaryDirectory(prefix="rp-mcp-owner.", dir="/tmp") as temporary:
        directory = Path(temporary)
        directory.chmod(0o700)
        listening_path = directory / "repoprompt-ce-1.sock"
        bound_path = directory / "repoprompt-ce-2.sock"
        listening = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        bound = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            listening.bind(os.fspath(listening_path))
            listening.listen(1)
            bound.bind(os.fspath(bound_path))
            names = listening_release_names(os.getpid(), directory.resolve(strict=True), expected_process=True)
            if names != {listening_path.name}:
                raise OwnershipError(
                    "macOS libproc UNIX listener self-test failed: "
                    f"expected {listening_path.name}, got {', '.join(sorted(names or set())) or 'none'}"
                )
        finally:
            bound.close()
            listening.close()


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
    subparsers.add_parser("selftest")
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
        elif arguments.command == "selftest":
            selftest()
        else:
            raise OwnershipError(f"unsupported command: {arguments.command}")
    except (OSError, OwnershipError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
