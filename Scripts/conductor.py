#!/usr/bin/env python3
"""RepoPrompt CE developer daemon.

Implements repo-internal daemon/job mechanics, fake sleep validation support,
and delegated build/package/test/debug-app/live-smoke/release operation
families. Synchronous jobs print concise summaries by default and preserve raw
logs under the daemon jobs directory.
"""

from __future__ import annotations

import argparse
import contextlib
import ctypes
import dataclasses
import errno
import fcntl
import hashlib
import json
import math
import os
import re
import signal
import shutil
import socket
import socketserver
import stat
import subprocess
import sys
import threading
import time
import uuid
from collections import deque
from pathlib import Path
from typing import Any, Deque, Dict, List, Optional, Sequence, Tuple

from debug_app_process import ProcessIdentityError, matching_processes, terminate_matching_processes

PROTOCOL_VERSION = 10
TERMINAL_STATES = {"completed", "failed", "canceled"}
LANE_NAMES = {"build", "debugArtifact", "liveApp", "release", "style"}
LOG_TAIL_LINES = 30
BUILD_CACHE_DIAGNOSTIC_MAX_ROWS = 12
SUMMARY_VERSION = 1
SUMMARY_SUCCESS_MAX_LINES = 25
SUMMARY_FAILURE_MAX_LINES = 100
SUMMARY_MAX_CHARS = 16000
SUMMARY_LINE_MAX_CHARS = 400
SUMMARY_CONTEXT_BEFORE = 2
SUMMARY_CONTEXT_AFTER = 4
PROGRESS_HEARTBEAT_SECONDS = 30.0
PROGRESS_MAX_LINES_PER_POLL = 6
MAX_TERMINAL_JOBS = 200
TERMINAL_RETENTION_SECONDS = 24 * 60 * 60
STARTUP_TIMEOUT_SECONDS = 10.0
WAIT_POLL_SECONDS = 1.0
TERMINATE_GRACE_SECONDS = 3.0
KILL_GRACE_SECONDS = 2.0
PROCESS_TREE_POLL_SECONDS = 0.05
XCTEST_WAKE_PROBE_PAUSE_SECONDS = 0.25
XCTEST_WAKE_PROGRESS_WAIT_SECONDS = 10.0
XCTEST_STALL_DIAGNOSTIC_MAX_PROCESSES = 64
XCTEST_STALL_SAMPLE_MAX_BYTES = 128 * 1024
XCTEST_STALL_FAILURE_EXIT_CODE = 70
XCTEST_WATCHDOG_JOIN_SECONDS = 25.0
FORCE_STOP_RPC_TIMEOUT_SECONDS = 30.0
APP_STOP_POLL_SECONDS = 0.2
APP_STOP_QUIET_SECONDS = 1.0
APP_STOP_DELAYED_LAUNCH_GUARD_SECONDS = 12.0
APP_STOP_CONFIRM_TIMEOUT_SECONDS = 8.0
APP_STOP_DELAYED_LAUNCH_CONFIRM_TIMEOUT_SECONDS = 25.0
GLOBAL_HEAVY_SLOT_POLL_SECONDS = 0.2
MACHINE_LOCK_POLL_SECONDS = 0.2
MAX_GLOBAL_HEAVY_SLOTS = 64
DEBUG_APP_PROVENANCE_RELATIVE_PATH = "Contents/Resources/RepoPromptDebugProvenance.json"

SHORT_TIMEOUT_SECONDS = 5 * 60
MEDIUM_TIMEOUT_SECONDS = 60 * 60
RELEASE_TIMEOUT_SECONDS = 2 * 60 * 60
SMOKE_AGENT_WAIT_SECONDS = 120.0

IMPLEMENTED_OPERATIONS = {
    "doctor",
    "guardrails",
    "format",
    "format-check",
    "lint",
    "format-tools-status",
    "check-format-tools",
    "install-format-tools",
    "swift-build",
    "build",
    "package",
    "test",
    "provider-test",
    "install-debug-cli",
    "debug-cli-status",
    "run",
    "app",
    "smoke",
    "diagnostics",
    "release",
}

HELP = f"""\
conductor — RepoPrompt CE developer daemon

Usage:
  ./conductor --help
  ./conductor status [--json]

Daemon lifecycle:
  ./conductor daemon start [--json]
  ./conductor daemon status [--json]
  ./conductor daemon stop [--force] [--json]

Job commands:
  ./conductor job list [--state queued|running|completed|failed|canceled] [--json]
  ./conductor job status <ticket> [--json] [--full-log]
  ./conductor job status --request-key <key> [--json] [--full-log]
  ./conductor job wait <ticket> [--timeout <seconds>] [--json] [--full-log]
  ./conductor job wait --request-key <key> [--timeout <seconds>] [--json] [--full-log]
  ./conductor job cancel <ticket> [--json]
  ./conductor job cancel --request-key <key> [--json]

Operation commands:
  ./conductor doctor
  ./conductor guardrails
  ./conductor format                 # mutates first-party Swift files
  ./conductor format-check           # non-mutating SwiftFormat check
  ./conductor lint                   # non-mutating format-check + SwiftLint strict
  ./conductor format-tools-status    # inspect SwiftFormat/SwiftLint availability
  ./conductor check-format-tools     # fail if style tools are missing
  ./conductor install-format-tools   # explicit Homebrew install of missing style tools
  ./conductor swift-build --product RepoPrompt|repoprompt-mcp|all
  ./conductor build
  ./conductor package debug|release
  ./conductor test [--list | --filter <filter>] [--test-product <product>] [--xctest-stall-seconds <seconds>] [--xctest-stall-wake-probe]
  ./conductor provider-test [--list | --filter <filter>] [--test-product <product>] [--xctest-stall-seconds <seconds>] [--xctest-stall-wake-probe]
  ./conductor install-debug-cli
  ./conductor debug-cli-status
  ./conductor run [-- <app args...>]                  # build/package, then FIFO coordinated launch
  ./conductor app status
  ./conductor app stop                                 # latest interactive stop intent
  ./conductor app launch-existing [-- <app args...>]   # launch existing DebugApps bundle without building
  ./conductor app relaunch [-- <app args...>]          # latest interactive relaunch intent
  ./conductor smoke [--launch | --packaged-app <path>] [--artifact-manifest <path>] [--workspace <name>] [--window-id <id>] [--agent-run]
    (without --launch/--packaged-app, requires the CE debug app to already be running and CLI installed)
  ./conductor diagnostics agent-mode-on [--log-file <path>]
  ./conductor diagnostics build-cache [--limit <n>]
  ./conductor release preflight|artifact|package|local-install

Foundation validation operation:
  ./conductor sleep <seconds> [--lane <lane>]... [--message <text>] [--exit-code <n>]
  ./conductor fake-sleep <seconds> [same options]
  valid lanes: build, debugArtifact, liveApp, release, style

Global operation flags:
  --async              enqueue and return a ticket immediately
  --request-key <key>  idempotent retry key for queued/running matching requests
  --json               machine-readable output
  --timeout <seconds>  override operation timeout
  --verbose            execution verbosity: pass VERBOSE=1 to delegated scripts where applicable
  --full-log           human output rendering: replay raw full job log at completion

Output:
  Synchronous jobs and job wait/status use concise human summaries by default and
  print the full log path. Raw logs are preserved under the daemon jobs directory.
  Use --full-log for raw terminal replay; --verbose only changes delegated script
  verbosity captured in the stored log and does not imply --full-log.

State paths:
  state dir default: ~/Library/Application Support/RepoPrompt CE/Conductor/<repo-root-hash>/
  socket default:    /tmp/conductor-<uid>/<repo-root-hash16>.sock (directory mode 0700)
  machine locks:     /tmp/repoprompt-ce-dev-locks-<uid>/ (directory mode 0700; independent of socket overrides)
  heavy slots:       REPOPROMPT_DEV_HEAVY_SLOTS=N (default 1)
  overrides: REPOPROMPT_DEV_DAEMON_STATE_DIR, REPOPROMPT_DEV_DAEMON_SOCKET (socket parent must be owned 0700)

Protocol version: {PROTOCOL_VERSION}
"""


class ConductorError(Exception):
    pass


XCTEST_PROGRESS_RE = re.compile(
    r"^Test Case '(.+)' (started|passed|failed|skipped)(?: \([^)]*\))?\.\s*$"
)
XCTEST_ANSI_SGR_RE = re.compile(r"\x1b\[[0-9:;]*m")


@dataclasses.dataclass(frozen=True)
class XCTestStallClaim:
    progress_transport: str
    progress_sequence: int
    last_progress_test: Optional[str]
    last_progress_action: Optional[str]
    last_progress_observed_at: Optional[float]
    threshold_seconds: float
    current_test: Optional[str]
    previous_test: Optional[str]
    wake_probe: bool
    triggered_at: float


@dataclasses.dataclass
class ProcessOutputTransport:
    kind: str
    master_fd: Optional[int] = None
    slave_fd: Optional[int] = None
    pipe_stream: Optional[Any] = None
    close_lock: threading.Lock = dataclasses.field(default_factory=threading.Lock, repr=False)

    @classmethod
    def create(cls, kind: str) -> "ProcessOutputTransport":
        if kind == "pipe":
            return cls(kind="pipe")
        if kind != "pty":
            raise ValueError(f"unsupported process output transport: {kind}")
        master_fd, slave_fd = os.openpty()
        return cls(kind="pty", master_fd=master_fd, slave_fd=slave_fd)

    @property
    def popen_stdout(self) -> Any:
        return self.slave_fd if self.kind == "pty" else subprocess.PIPE

    @property
    def popen_stderr(self) -> Any:
        return self.slave_fd if self.kind == "pty" else subprocess.STDOUT

    def attach_process(self, process: subprocess.Popen[bytes]) -> None:
        if self.kind == "pty":
            self.close_slave()
            return
        if process.stdout is None:
            raise ConductorError("pipe-backed process did not expose stdout")
        with self.close_lock:
            self.pipe_stream = process.stdout

    def read_chunk(self, process: subprocess.Popen[bytes]) -> bytes:
        with self.close_lock:
            master_fd = self.master_fd
            pipe_stream = self.pipe_stream
        if self.kind == "pipe":
            if pipe_stream is None:
                return b""
            return pipe_stream.readline()
        if master_fd is None:
            return b""
        try:
            return os.read(master_fd, 64 * 1024)
        except OSError as exc:
            if exc.errno == errno.EIO:
                return b""
            if exc.errno == errno.EBADF:
                with self.close_lock:
                    if self.master_fd is None:
                        return b""
            raise

    def close_slave(self) -> None:
        with self.close_lock:
            slave_fd = self.slave_fd
            self.slave_fd = None
        if slave_fd is not None:
            with contextlib.suppress(OSError):
                os.close(slave_fd)

    def close_reader(self) -> None:
        with self.close_lock:
            master_fd = self.master_fd
            pipe_stream = self.pipe_stream
            self.master_fd = None
            self.pipe_stream = None
        if master_fd is not None:
            with contextlib.suppress(OSError):
                os.close(master_fd)
        if pipe_stream is not None:
            with contextlib.suppress(OSError):
                pipe_stream.close()

    def close_all(self) -> None:
        self.close_slave()
        self.close_reader()


def is_xctest_process_command(command: str) -> bool:
    normalized = command.strip()
    executable = normalized.split(None, 1)[0] if normalized else ""
    return (
        ".xctest/" in executable
        or executable.endswith(".xctest")
        or Path(executable).name == "xctest"
    )


@dataclasses.dataclass(frozen=True)
class Paths:
    repo_root: Path
    repo_hash: str
    state_dir: Path
    socket_path: Path
    pid_path: Path
    lock_path: Path
    jobs_dir: Path
    daemon_log_path: Path
    daemon_meta_path: Path
    running_processes_path: Path


def resolve_repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def compute_paths(repo_root: Path) -> Paths:
    real_root = repo_root.resolve()
    repo_hash = hashlib.sha256(str(real_root).encode("utf-8")).hexdigest()
    state_override = os.environ.get("REPOPROMPT_DEV_DAEMON_STATE_DIR")
    socket_override = os.environ.get("REPOPROMPT_DEV_DAEMON_SOCKET")

    if state_override:
        state_dir = Path(state_override).expanduser().resolve()
    else:
        state_dir = (
            Path.home()
            / "Library"
            / "Application Support"
            / "RepoPrompt CE"
            / "Conductor"
            / repo_hash
        )
    uid = os.getuid() if hasattr(os, "getuid") else 0
    socket_path = (
        Path(socket_override).expanduser().resolve()
        if socket_override
        else Path("/tmp") / f"conductor-{uid}" / f"{repo_hash[:16]}.sock"
    )
    return Paths(
        repo_root=real_root,
        repo_hash=repo_hash,
        state_dir=state_dir,
        socket_path=socket_path,
        pid_path=state_dir / "daemon.pid",
        lock_path=state_dir / "daemon.start.lock",
        jobs_dir=state_dir / "jobs",
        daemon_log_path=state_dir / "daemon.log",
        daemon_meta_path=state_dir / "daemon.json",
        running_processes_path=state_dir / "running-processes.json",
    )


def ensure_private_dir(path: Path) -> None:
    try:
        existing = os.lstat(path)
    except FileNotFoundError:
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
    else:
        if stat.S_ISLNK(existing.st_mode):
            raise ConductorError(f"private directory {path} must not be a symlink")
        if not stat.S_ISDIR(existing.st_mode):
            raise ConductorError(f"private directory {path} is not a directory")
    try:
        stat_result = os.lstat(path)
    except OSError as exc:
        raise ConductorError(f"could not stat private directory {path}: {exc}")
    if stat.S_ISLNK(stat_result.st_mode):
        raise ConductorError(f"private directory {path} must not be a symlink")
    if not stat.S_ISDIR(stat_result.st_mode):
        raise ConductorError(f"private directory {path} is not a directory")
    if hasattr(os, "getuid") and stat_result.st_uid != os.getuid():
        raise ConductorError(f"private directory {path} is not owned by the current user")
    mode = stat_result.st_mode & 0o777
    if mode & 0o077:
        try:
            os.chmod(path, 0o700)
        except OSError as exc:
            raise ConductorError(f"could not restrict private directory {path} to 0700: {exc}")
        mode = os.lstat(path).st_mode & 0o777
        if mode & 0o077:
            raise ConductorError(f"private directory {path} is not credential-safe (mode {mode:o})")


def ensure_state_dirs(paths: Paths) -> None:
    ensure_private_dir(paths.state_dir)
    ensure_private_dir(paths.jobs_dir)
    ensure_private_dir(paths.socket_path.parent)
    ensure_private_dir(machine_lock_dir())


def machine_lock_dir() -> Path:
    uid = os.getuid() if hasattr(os, "getuid") else 0
    return Path("/tmp") / f"repoprompt-ce-dev-locks-{uid}"


def configured_global_heavy_slots(env: Optional[Dict[str, str]] = None) -> int:
    raw = (env or os.environ).get("REPOPROMPT_DEV_HEAVY_SLOTS")
    if raw is None or raw == "":
        return 1
    try:
        slots = int(raw)
    except ValueError as exc:
        raise ConductorError("REPOPROMPT_DEV_HEAVY_SLOTS must be a positive integer") from exc
    if slots < 1 or slots > MAX_GLOBAL_HEAVY_SLOTS:
        raise ConductorError(f"REPOPROMPT_DEV_HEAVY_SLOTS must be between 1 and {MAX_GLOBAL_HEAVY_SLOTS}")
    return slots


def global_heavy_slot_paths(env: Optional[Dict[str, str]] = None) -> List[Path]:
    root = machine_lock_dir()
    return [root / f"global-heavy-{index}.lock" for index in range(configured_global_heavy_slots(env))]


def live_app_lock_path() -> Path:
    return machine_lock_dir() / "live-app.lock"


def repo_worktree_name(repo_root: Path) -> str:
    return repo_root.name or str(repo_root)


def display_lock_metadata(
    *,
    lock_kind: str,
    ticket: Optional[str],
    operation: str,
    operation_label: str,
    repo_root: Path,
    repo_hash: Optional[str] = None,
) -> Dict[str, Any]:
    acquired_at = now()
    return {
        "version": 1,
        "displayOnly": True,
        "kind": lock_kind,
        "ticket": ticket,
        "operation": operation,
        "operationLabel": operation_label,
        "repoRoot": str(repo_root),
        "repoHash": repo_hash,
        "worktree": repo_worktree_name(repo_root),
        "pid": os.getpid(),
        "acquiredAt": acquired_at,
        "acquiredAtISO": iso_timestamp(acquired_at),
    }


def write_display_lock_metadata(lock_file: Any, metadata: Dict[str, Any]) -> None:
    try:
        lock_file.seek(0)
        lock_file.truncate()
        lock_file.write(json.dumps(metadata, indent=2, sort_keys=True))
        lock_file.write("\n")
        lock_file.flush()
    except OSError:
        pass


def read_display_lock_metadata(path: Path) -> Optional[Dict[str, Any]]:
    try:
        raw = path.read_text(encoding="utf-8", errors="replace")
        payload = json.loads(raw) if raw.strip() else None
    except (OSError, json.JSONDecodeError):
        return None
    return payload if isinstance(payload, dict) else None


def format_display_lock_holder(metadata: Optional[Dict[str, Any]]) -> str:
    if not metadata:
        return "holder unknown"
    label = metadata.get("operationLabel") or metadata.get("operation") or "unknown operation"
    ticket = metadata.get("ticket") or "no-ticket"
    repo = metadata.get("repoRoot") or "unknown repo"
    worktree = metadata.get("worktree") or Path(str(repo)).name
    acquired_at = metadata.get("acquiredAt")
    held_for = "unknown duration"
    if isinstance(acquired_at, (int, float)):
        held_for = format_duration(now() - float(acquired_at))
    return f"holder {label} ticket={ticket} repo={repo} worktree={worktree} held={held_for}"


@contextlib.contextmanager
def machine_exclusive_lock(lock_path: Path, metadata: Dict[str, Any], wait_label: str):
    ensure_private_dir(lock_path.parent)
    lock_file = lock_path.open("a+", encoding="utf-8")
    did_log_wait = False
    while True:
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if not did_log_wait:
                holder = format_display_lock_holder(read_display_lock_metadata(lock_path))
                print(f"waiting for {wait_label}: {lock_path} ({holder})", flush=True)
                did_log_wait = True
            time.sleep(MACHINE_LOCK_POLL_SECONDS)
        except OSError as exc:
            if exc.errno == errno.EINTR:
                continue
            lock_file.close()
            raise
    write_display_lock_metadata(lock_file, metadata)
    try:
        yield lock_file
    finally:
        with contextlib.suppress(OSError):
            lock_file.seek(0)
            lock_file.truncate()
            lock_file.flush()
        with contextlib.suppress(OSError):
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
        with contextlib.suppress(OSError):
            lock_file.close()


@contextlib.contextmanager
def machine_heavy_slot(metadata: Dict[str, Any], env: Optional[Dict[str, str]], wait_label: str):
    ensure_private_dir(machine_lock_dir())
    lock_files = [(path, path.open("a+", encoding="utf-8")) for path in global_heavy_slot_paths(env)]
    did_log_wait = False
    selected_file: Optional[Any] = None
    try:
        while True:
            for lock_path, lock_file in lock_files:
                try:
                    fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                    selected_file = lock_file
                    write_display_lock_metadata(lock_file, metadata)
                    print(f"acquired {wait_label}: {lock_path}", flush=True)
                    yield lock_file
                    return
                except BlockingIOError:
                    continue
                except OSError as exc:
                    if exc.errno == errno.EINTR:
                        continue
                    raise
            if not did_log_wait:
                holders = "; ".join(format_display_lock_holder(read_display_lock_metadata(path)) for path, _ in lock_files)
                paths = ",".join(str(path) for path, _ in lock_files)
                print(f"waiting for {wait_label} ({len(lock_files)} configured): {paths}; {holders}", flush=True)
                did_log_wait = True
            time.sleep(GLOBAL_HEAVY_SLOT_POLL_SECONDS)
    finally:
        for _path, lock_file in lock_files:
            if lock_file is selected_file:
                with contextlib.suppress(OSError):
                    lock_file.seek(0)
                    lock_file.truncate()
                    lock_file.flush()
                with contextlib.suppress(OSError):
                    fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
            with contextlib.suppress(OSError):
                lock_file.close()


def read_pid(path: Path) -> Optional[int]:
    try:
        raw = path.read_text(encoding="utf-8").strip()
        return int(raw) if raw else None
    except (FileNotFoundError, ValueError, OSError):
        return None


def pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False


def cleanup_stale_files(paths: Paths) -> None:
    pid = read_pid(paths.pid_path)
    if pid is not None and pid_alive(pid):
        return
    for path in (paths.pid_path, paths.socket_path, paths.daemon_meta_path, paths.running_processes_path):
        with contextlib.suppress(FileNotFoundError):
            path.unlink()


def process_start_token(pid: int) -> Optional[str]:
    try:
        completed = subprocess.run(
            ["ps", "-p", str(pid), "-o", "lstart="],
            text=True,
            capture_output=True,
            timeout=2.0,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if completed.returncode != 0:
        return None
    token = completed.stdout.strip()
    return token or None


def process_table_snapshot() -> Dict[int, Tuple[int, str]]:
    try:
        completed = subprocess.run(
            ["ps", "-axo", "pid=,ppid=,lstart="],
            text=True,
            capture_output=True,
            timeout=2.0,
        )
    except (OSError, subprocess.TimeoutExpired):
        return {}
    if completed.returncode != 0:
        return {}
    snapshot: Dict[int, Tuple[int, str]] = {}
    for line in completed.stdout.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) != 3:
            continue
        try:
            pid = int(parts[0])
            ppid = int(parts[1])
        except ValueError:
            continue
        if pid > 0 and parts[2]:
            snapshot[pid] = (ppid, parts[2])
    return snapshot


def process_command_snapshot(pids: Sequence[int]) -> Dict[int, str]:
    selected = sorted({pid for pid in pids if pid > 0})[:XCTEST_STALL_DIAGNOSTIC_MAX_PROCESSES]
    if not selected:
        return {}
    try:
        completed = subprocess.run(
            ["ps", "-ww", "-p", ",".join(str(pid) for pid in selected), "-o", "pid=,command="],
            text=True,
            capture_output=True,
            timeout=2.0,
        )
    except (OSError, subprocess.TimeoutExpired):
        return {}
    if completed.returncode != 0:
        return {}
    commands: Dict[int, str] = {}
    for line in completed.stdout.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        parts = stripped.split(None, 1)
        if len(parts) != 2:
            continue
        try:
            pid = int(parts[0])
        except ValueError:
            continue
        commands[pid] = parts[1]
    return commands


def process_command(pid: int) -> str:
    try:
        completed = subprocess.run(
            ["ps", "-ww", "-p", str(pid), "-o", "command="],
            text=True,
            capture_output=True,
            timeout=2.0,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    if completed.returncode != 0:
        return ""
    return completed.stdout.strip()


def write_daemon_metadata(paths: Paths) -> None:
    payload = {
        "pid": os.getpid(),
        "repoRoot": str(paths.repo_root),
        "repoHash": paths.repo_hash,
        "script": str(Path(__file__).resolve()),
        "processStart": process_start_token(os.getpid()),
        "createdAt": now(),
    }
    paths.daemon_meta_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    with contextlib.suppress(OSError):
        os.chmod(paths.daemon_meta_path, 0o600)


def read_daemon_metadata(paths: Paths) -> Dict[str, Any]:
    try:
        raw = paths.daemon_meta_path.read_text(encoding="utf-8")
        payload = json.loads(raw)
        return payload if isinstance(payload, dict) else {}
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}


def verify_daemon_pid_identity(paths: Paths, pid: int) -> bool:
    metadata = read_daemon_metadata(paths)
    if metadata.get("pid") != pid:
        return False
    if metadata.get("repoRoot") != str(paths.repo_root) or metadata.get("repoHash") != paths.repo_hash:
        return False
    expected_start = metadata.get("processStart")
    if expected_start and process_start_token(pid) != expected_start:
        return False
    command = process_command(pid)
    return "conductor.py" in command and "__daemon" in command and str(paths.repo_root) in command


def json_dumps(obj: Any) -> str:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"))


def print_json(obj: Any) -> None:
    print(json.dumps(obj, indent=2, sort_keys=True))


def now() -> float:
    return time.time()


def iso_timestamp(ts: Optional[float]) -> Optional[str]:
    if ts is None:
        return None
    return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(ts))


def terminal_exit_code(payload: Dict[str, Any]) -> int:
    state = payload.get("state")
    exit_code = payload.get("exitCode")
    if state == "completed":
        return int(exit_code or 0)
    if state == "failed":
        return int(exit_code if exit_code is not None else 1)
    if state == "canceled":
        return 130
    return 1


ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")


def clean_summary_line(line: str) -> str:
    cleaned = ANSI_RE.sub("", line.rstrip("\r\n"))
    if len(cleaned) > SUMMARY_LINE_MAX_CHARS:
        return cleaned[: SUMMARY_LINE_MAX_CHARS - 1] + "…"
    return cleaned


class SummarySectionBuilder:
    def __init__(self, title: str, max_lines: int, keep_last: bool = False) -> None:
        self.title = title
        self.max_lines = max_lines
        self.keep_last = keep_last
        self.lines: List[str] = []
        self.seen: set[str] = set()
        self.omitted = 0

    def add(self, line: str) -> None:
        cleaned = clean_summary_line(line)
        if not cleaned or cleaned in self.seen:
            return
        self.seen.add(cleaned)
        if len(self.lines) < self.max_lines:
            self.lines.append(cleaned)
        elif self.keep_last:
            self.lines.pop(0)
            self.lines.append(cleaned)
            self.omitted += 1
        else:
            self.omitted += 1

    def extend(self, lines: Sequence[str]) -> None:
        for line in lines:
            self.add(line)

    def payload(self) -> Optional[Dict[str, Any]]:
        if not self.lines:
            return None
        return {
            "title": self.title,
            "lines": list(self.lines),
            "truncated": self.omitted > 0,
            "omittedLineCount": self.omitted,
        }


class OutputSummarizer:
    FAILURE_RE = re.compile(
        r"(ERROR:|FAILED|failed with|process exited with status|fatal error|Traceback|Exception|Permission denied|No such file or directory|timed out|killing process (?:group|tree)|terminating process (?:group|tree))",
        re.IGNORECASE,
    )
    SWIFT_ERROR_RE = re.compile(r"(: error:|error: emit-module command failed|Command SwiftCompile failed|Command CompileSwift failed|fatal error:)")
    WARNING_RE = re.compile(r"(: warning:|^WARNING:)")
    TEST_FAILURE_RE = re.compile(
        r"(Test Case '.*' failed|XCTAssert|: error: .*Test|Executed .* tests?, with .* failures?|Failing tests:|error: Exited with unexpected signal|error: terminated)"
    )
    STYLE_FINDING_RE = re.compile(
        r"(SwiftFormat|SwiftLint|linting|Missing required tool|Run 'make install-format-tools'|ERROR: Missing required Swift style tools|[^\s:]+:\d+:\d+: (warning|error):)"
    )
    TIMEOUT_RE = re.compile(r"(timed out after|terminating process (?:group|tree)|killing process (?:group|tree)|canceled)", re.IGNORECASE)
    PHASE_RE = re.compile(r"^(==>|\$ |\+ )")
    ARTIFACT_RE = re.compile(
        r"^(Created:|APP_BUNDLE=|COMPAT_APP_BUNDLE=|CLI_PATH=|Output written to:|Agent Mode diagnostics enabled|Resolved rpce-cli-debug:|Build cache diagnostics|Current \.build:|Managed worktree container:|Worktree \.build total:|Top \.build directories:|\s+[0-9.]+ [KMGT]?i?B\s+)"
    )
    APP_LIFECYCLE_RE = re.compile(
        r"(Stopping existing RepoPrompt|Waiting for existing RepoPrompt|Launching .*RepoPrompt\.app|Confirming launched RepoPrompt|Observed launched RepoPrompt|Guarding against a delayed RepoPrompt|Delayed launch guard confirmed|RepoPrompt(?: CE debug app)? stop confirmed|RepoPrompt was (not running|already stopped))"
    )
    SOURCE_CHANGED_DURING_BUILD_RE = re.compile(r"input file .* was modified during the build", re.IGNORECASE)

    @classmethod
    def summarize_file(
        cls,
        operation: str,
        args: Dict[str, Any],
        state: str,
        exit_code: Optional[int],
        timed_out: bool,
        log_path: Path,
    ) -> Dict[str, Any]:
        try:
            with log_path.open("r", encoding="utf-8", errors="replace") as handle:
                return cls.summarize_lines(operation, args, state, exit_code, timed_out, handle)
        except OSError as exc:
            return cls._minimal_summary(operation, state, exit_code, f"could not read log for summary: {exc}")

    @classmethod
    def summarize_lines(
        cls,
        operation: str,
        args: Dict[str, Any],
        state: str,
        exit_code: Optional[int],
        timed_out: bool,
        lines_iterable: Any,
    ) -> Dict[str, Any]:
        del args
        failure = state in {"failed", "canceled"} or bool(timed_out) or (exit_code not in (None, 0))
        launch_lifecycle = {
            "transitionStarted": False,
            "launchRequested": False,
            "launchConfirmed": False,
            "sourceChangedDuringBuild": False,
        }
        section_limit = SUMMARY_FAILURE_MAX_LINES if failure else SUMMARY_SUCCESS_MAX_LINES
        per_section_limit = max(5, min(30, section_limit // 2))
        sections = {
            "App lifecycle": SummarySectionBuilder("App lifecycle", 12, keep_last=True),
            "Phases": SummarySectionBuilder("Phases", 20 if failure else 10, keep_last=True),
            "Failure highlights": SummarySectionBuilder("Failure highlights", per_section_limit),
            "Swift compiler errors": SummarySectionBuilder("Swift compiler errors", per_section_limit),
            "Test failures": SummarySectionBuilder("Test failures", per_section_limit),
            "Style findings": SummarySectionBuilder("Style findings", per_section_limit),
            "Warnings": SummarySectionBuilder("Warnings", 5 if not failure else 10),
            "Timeout or cancellation": SummarySectionBuilder("Timeout or cancellation", per_section_limit),
            "Artifacts": SummarySectionBuilder("Artifacts", 10),
            "Recent output": SummarySectionBuilder("Recent output", 20),
            "Summary notes": SummarySectionBuilder("Summary notes", 5),
        }
        line_count = 0
        warning_count = 0
        error_count = 0
        tail: Deque[str] = deque(maxlen=20)
        previous_context: Deque[str] = deque(maxlen=SUMMARY_CONTEXT_BEFORE)
        pending_context: List[Tuple[str, int]] = []
        style_operation = operation in {"format", "format-check", "lint", "check-format-tools", "install-format-tools", "format-tools-status"}

        for raw_line in lines_iterable:
            line_count += 1
            line = clean_summary_line(str(raw_line))
            tail.append(line)

            if "Stopping existing RepoPrompt" in line:
                launch_lifecycle["transitionStarted"] = True
            if "Launching " in line and "RepoPrompt.app" in line:
                launch_lifecycle["transitionStarted"] = True
                launch_lifecycle["launchRequested"] = True
            if "Observed launched RepoPrompt" in line:
                launch_lifecycle["launchConfirmed"] = True
            if cls.SOURCE_CHANGED_DURING_BUILD_RE.search(line):
                launch_lifecycle["sourceChangedDuringBuild"] = True

            if cls.WARNING_RE.search(line):
                warning_count += 1
                if failure or line.startswith("WARNING:"):
                    sections["Warnings"].add(line)
            if cls.SWIFT_ERROR_RE.search(line) or cls.FAILURE_RE.search(line):
                error_count += 1

            if pending_context:
                next_pending: List[Tuple[str, int]] = []
                for title, remaining in pending_context:
                    sections[title].add(line)
                    if remaining > 1:
                        next_pending.append((title, remaining - 1))
                pending_context = next_pending

            matched_titles: List[str] = []
            if cls.PHASE_RE.search(line):
                sections["Phases"].add(line)
            if cls.APP_LIFECYCLE_RE.search(line):
                sections["App lifecycle"].add(line)
            if cls.ARTIFACT_RE.search(line):
                sections["Artifacts"].add(line)
            if cls.TIMEOUT_RE.search(line):
                matched_titles.append("Timeout or cancellation")
            if cls.TEST_FAILURE_RE.search(line):
                matched_titles.append("Test failures")
            if cls.SWIFT_ERROR_RE.search(line):
                matched_titles.append("Swift compiler errors")
            if style_operation and cls.STYLE_FINDING_RE.search(line):
                matched_titles.append("Style findings")
            if cls.FAILURE_RE.search(line):
                matched_titles.append("Failure highlights")

            for title in matched_titles:
                sections[title].extend(list(previous_context))
                sections[title].add(line)
                pending_context.append((title, SUMMARY_CONTEXT_AFTER))

            previous_context.append(line)

        if failure:
            has_strong_failure_section = any(
                sections[title].lines
                for title in [
                    "Swift compiler errors",
                    "Test failures",
                    "Style findings",
                    "Timeout or cancellation",
                ]
            )
            if not has_strong_failure_section:
                sections["Recent output"].extend(list(tail))
        else:
            # Success summaries should stay artifact/phase focused and avoid raw build noise.
            sections["Recent output"].lines.clear()

        headline = cls._headline(state, exit_code, timed_out)
        ordered_titles = [
            "Failure highlights",
            "Swift compiler errors",
            "Test failures",
            "Style findings",
            "Timeout or cancellation",
            "Warnings",
            "Artifacts",
            "App lifecycle",
            "Phases",
            "Recent output",
            "Summary notes",
        ]
        payload_sections: List[Dict[str, Any]] = []
        rendered_line_count = 0
        rendered_chars = 0
        truncated = False
        for title in ordered_titles:
            section = sections[title].payload()
            if not section:
                continue
            remaining_lines = section_limit - rendered_line_count
            if remaining_lines <= 0:
                truncated = True
                break
            if len(section["lines"]) > remaining_lines:
                omitted = len(section["lines"]) - remaining_lines + int(section.get("omittedLineCount") or 0)
                section = dict(section)
                section["lines"] = section["lines"][:remaining_lines]
                section["truncated"] = True
                section["omittedLineCount"] = omitted
                truncated = True
            section_chars = sum(len(line) for line in section["lines"])
            if rendered_chars + section_chars > SUMMARY_MAX_CHARS:
                truncated = True
                break
            payload_sections.append(section)
            rendered_line_count += len(section["lines"])
            rendered_chars += section_chars
            if section.get("truncated"):
                truncated = True

        omitted_line_count = max(0, line_count - rendered_line_count)
        return {
            "version": SUMMARY_VERSION,
            "operation": operation,
            "state": state,
            "exitCode": exit_code,
            "headline": headline,
            "logLineCount": line_count,
            "omittedLineCount": omitted_line_count,
            "errorCount": error_count,
            "warningCount": warning_count,
            "launchLifecycle": launch_lifecycle,
            "sections": payload_sections,
            "truncated": truncated,
        }

    @classmethod
    def _headline(cls, state: str, exit_code: Optional[int], timed_out: bool) -> str:
        if state == "completed":
            return "completed successfully"
        if timed_out:
            return "failed after timeout"
        if state == "canceled":
            return "canceled"
        if exit_code is not None:
            return f"failed with exit code {exit_code}"
        return state or "unknown result"

    @classmethod
    def _minimal_summary(cls, operation: str, state: str, exit_code: Optional[int], note: str) -> Dict[str, Any]:
        return {
            "version": SUMMARY_VERSION,
            "operation": operation,
            "state": state,
            "exitCode": exit_code,
            "headline": cls._headline(state, exit_code, False),
            "logLineCount": 0,
            "omittedLineCount": 0,
            "errorCount": 0,
            "warningCount": 0,
            "sections": [
                {
                    "title": "Summary notes",
                    "lines": [clean_summary_line(note)],
                    "truncated": False,
                    "omittedLineCount": 0,
                }
            ],
            "truncated": False,
        }


def operation_display_name(operation: str, args: Dict[str, Any]) -> str:
    if operation == "app" and args.get("subcommand") in {"status", "stop", "launch-existing", "relaunch"}:
        return f"app {args['subcommand']}"
    return operation


def latest_lifecycle_intent(operation: str, args: Dict[str, Any]) -> Optional[str]:
    if operation == "app" and args.get("subcommand") in {"stop", "launch-existing", "relaunch"}:
        return operation_display_name(operation, args)
    return None


def is_launch_capable_job(operation: str, args: Dict[str, Any]) -> bool:
    return (
        operation == "run"
        or (operation == "app" and args.get("subcommand") in {"launch-existing", "relaunch"})
        or (operation == "smoke" and bool(args.get("launch") or args.get("packagedApp")))
    )


def operation_requires_global_heavy_slot(operation: str, args: Dict[str, Any]) -> bool:
    if operation in {"swift-build", "build", "package", "test", "provider-test", "install-debug-cli"}:
        return True
    if operation in {"sleep", "fake-sleep"} and "build" in set(args.get("lanes") or []):
        return True
    if operation == "release" and args.get("subcommand") in {"artifact", "package", "local-install"}:
        return True
    return False


def format_duration(seconds: Optional[float]) -> str:
    if seconds is None:
        return "n/a"
    seconds = max(0.0, float(seconds))
    if seconds < 1:
        return f"{seconds * 1000:.0f}ms"
    if seconds < 60:
        return f"{seconds:.1f}s"
    minutes, remainder = divmod(seconds, 60)
    if minutes < 60:
        return f"{int(minutes)}m {remainder:.0f}s"
    hours, minutes = divmod(minutes, 60)
    return f"{int(hours)}h {int(minutes)}m {remainder:.0f}s"


def format_bytes(byte_count: Optional[int]) -> str:
    if byte_count is None:
        return "n/a"
    value = float(max(0, int(byte_count)))
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    unit = units[0]
    for unit in units:
        if value < 1024 or unit == units[-1]:
            break
        value /= 1024
    if unit == "B":
        return f"{int(value)} B"
    return f"{value:.1f} {unit}"


@dataclasses.dataclass
class Job:
    ticket: str
    request_key: Optional[str]
    fingerprint: str
    operation: str
    args: Dict[str, Any]
    lanes: List[str]
    timeout: Optional[float]
    verbose: bool
    env: Dict[str, str]
    created_at: float
    log_path: Path
    state: str = "queued"
    started_at: Optional[float] = None
    finished_at: Optional[float] = None
    process_started_at: Optional[float] = None
    process_finished_at: Optional[float] = None
    process_pid: Optional[int] = None
    process_pgid: Optional[int] = None
    process_start: Optional[str] = None
    tracked_processes: Dict[int, str] = dataclasses.field(default_factory=dict, repr=False)
    process_group_identity_confirmed: bool = False
    global_heavy_slot_wait_seconds: Optional[float] = None
    global_heavy_slot_path: Optional[str] = None
    global_heavy_slot_holder: Optional[str] = None
    exit_code: Optional[int] = None
    error: Optional[str] = None
    result_summary: Optional[str] = None
    cancel_requested: bool = False
    superseded_by_ticket: Optional[str] = None
    superseded_by_operation: Optional[str] = None
    timed_out: bool = False
    measurement_invalid: bool = False
    progress_transport: Optional[str] = None
    xctest_progress_sequence: int = 0
    xctest_progress_deadline: Optional[float] = None
    xctest_current_test: Optional[str] = None
    xctest_previous_test: Optional[str] = None
    xctest_last_progress_test: Optional[str] = None
    xctest_last_progress_action: Optional[str] = None
    xctest_last_progress_observed_at: Optional[float] = None
    xctest_watchdog_triggered: bool = False
    xctest_process_finished: bool = False
    diagnostics: List[Dict[str, Any]] = dataclasses.field(default_factory=list)
    diagnostic_paths: List[Path] = dataclasses.field(default_factory=list, repr=False)
    output_summary: Optional[Dict[str, Any]] = None
    tail: Deque[str] = dataclasses.field(default_factory=lambda: deque(maxlen=LOG_TAIL_LINES))

    def to_payload(self, include_tail: bool = True, include_summary: bool = True) -> Dict[str, Any]:
        queue_wait_seconds = None
        if self.started_at is not None:
            queue_wait_seconds = max(0.0, self.started_at - self.created_at)
        execution_seconds = None
        if self.process_started_at is not None and self.process_finished_at is not None:
            execution_seconds = max(0.0, self.process_finished_at - self.process_started_at)
        payload: Dict[str, Any] = {
            "ticket": self.ticket,
            "requestKey": self.request_key,
            "fingerprint": self.fingerprint,
            "operation": self.operation,
            "operationLabel": operation_display_name(self.operation, self.args),
            "args": self.args,
            "lanes": self.lanes,
            "state": self.state,
            "createdAt": self.created_at,
            "createdAtISO": iso_timestamp(self.created_at),
            "startedAt": self.started_at,
            "startedAtISO": iso_timestamp(self.started_at),
            "finishedAt": self.finished_at,
            "finishedAtISO": iso_timestamp(self.finished_at),
            "queuedAt": self.created_at,
            "processStartedAt": self.process_started_at,
            "processStartedAtISO": iso_timestamp(self.process_started_at),
            "processFinishedAt": self.process_finished_at,
            "processFinishedAtISO": iso_timestamp(self.process_finished_at),
            "queueWaitSeconds": queue_wait_seconds,
            "executionSeconds": execution_seconds,
            "logPath": str(self.log_path),
            "processPID": self.process_pid,
            "processPGID": self.process_pgid,
            "globalHeavySlotWaitSeconds": self.global_heavy_slot_wait_seconds,
            "globalHeavySlotPath": self.global_heavy_slot_path,
            "globalHeavySlotHolder": self.global_heavy_slot_holder,
            "exitCode": self.exit_code,
            "error": self.error,
            "resultSummary": self.result_summary,
            "cancelRequested": self.cancel_requested,
            "supersededByTicket": self.superseded_by_ticket,
            "supersededByOperation": self.superseded_by_operation,
            "timedOut": self.timed_out,
            "measurementInvalid": self.measurement_invalid,
            "progressTransport": self.progress_transport,
            "progressSequence": self.xctest_progress_sequence,
            "lastProgressTest": self.xctest_last_progress_test,
            "lastProgressAction": self.xctest_last_progress_action,
            "lastProgressObservedAt": self.xctest_last_progress_observed_at,
            "diagnosticPaths": [str(path) for path in self.diagnostic_paths],
        }
        if self.diagnostics:
            payload["diagnostics"] = list(self.diagnostics)
        if include_summary and self.output_summary is not None:
            payload["outputSummary"] = self.output_summary
        if include_tail:
            payload["logTail"] = list(self.tail)
        return payload


class OperationRegistry:
    """Daemon-side operation registration and argv construction."""

    SIGNING_ENV_KEYS = [
        "SIGN_IDENTITY",
        "SIGNING_TEAM_ID",
        "ALLOW_ADHOC_SIGNING",
        "RELEASE_ALLOW_ADHOC_SIGNING",
        "CONFIRM_LOCAL_PRODUCTION_INSTALL",
        "LOCAL_CERTIFICATE_DAYS",
        "LOCAL_PRODUCTION_INSTALL_DIR",
        "LOCAL_SELF_SIGNED_RELEASE",
        "PREFER_STABLE_DEBUG_SIGNING",
        "DEBUG_SECURE_STORAGE_BACKEND",
        "REPOPROMPT_PROVISIONING_PROFILE",
        "APP_ENTITLEMENTS_TEMPLATE",
        "BUNDLE_ID",
    ]
    DEBUG_ENV_KEYS = [
        "REPOPROMPT_DEBUG_APP_ROOT",
        "REPOPROMPT_DEBUG_APP_BUNDLE",
        "REPOPROMPT_DEBUG_CLI_INSTALL_PATH",
    ]
    BUILD_ENV_KEYS = [
        "PATH",
        "DEVELOPER_DIR",
        "TOOLCHAINS",
        "SDKROOT",
        "SWIFT_EXEC",
        "CC",
        "CXX",
        "TMPDIR",
        "HOME",
        "USER",
        "LOGNAME",
        "SHELL",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
    ]
    STYLE_ENV_KEYS = [
        "GITHUB_ACTIONS",
        "CI",
        "HOMEBREW_NO_AUTO_UPDATE",
        "HOMEBREW_NO_INSTALL_CLEANUP",
        "HOMEBREW_CACHE",
    ]
    TEST_ENV_KEYS = [
        "RPCE_ENABLE_BENCHMARK_TESTS",
        "RPCE_RUN_CODEMAP_E2E",
        "RPCE_RUN_SCALE_TESTS",
    ]
    CONDUCTOR_ENV_KEYS = [
        "REPOPROMPT_DEV_HEAVY_SLOTS",
    ]
    TELEMETRY_ENV_KEYS = [
        "REPOPROMPT_ENABLE_SENTRY",
        "REPOPROMPT_SENTRY_DSN",
        "REPOPROMPT_UPLOAD_SENTRY_SYMBOLS",
        "REPOPROMPT_SENTRY_AUTH_TOKEN_FILE",
        "REPOPROMPT_SENTRY_ORG",
        "REPOPROMPT_SENTRY_PROJECT",
        "REPOPROMPT_SENTRY_UPLOAD_WAIT",
        "SENTRY_URL",
    ]
    PASSTHROUGH_ENV_KEYS = sorted(
        set(
            SIGNING_ENV_KEYS
            + DEBUG_ENV_KEYS
            + BUILD_ENV_KEYS
            + STYLE_ENV_KEYS
            + TEST_ENV_KEYS
            + CONDUCTOR_ENV_KEYS
            + TELEMETRY_ENV_KEYS
        )
    )

    def __init__(self, repo_root: Path) -> None:
        self.repo_root = repo_root
        self.script_path = Path(__file__).resolve()

    @classmethod
    def client_env_snapshot(cls) -> Dict[str, str]:
        snapshot: Dict[str, str] = {}
        for key in cls.PASSTHROUGH_ENV_KEYS:
            value = os.environ.get(key)
            if value is not None:
                snapshot[key] = value
        return snapshot

    @classmethod
    def _request_env_snapshot(cls, request: Dict[str, Any]) -> Dict[str, str]:
        raw = request.get("env") or {}
        if not isinstance(raw, dict):
            raise ConductorError("request env must be an object")
        snapshot: Dict[str, str] = {}
        allowed = set(cls.PASSTHROUGH_ENV_KEYS)
        for key, value in raw.items():
            if key not in allowed:
                continue
            if not isinstance(value, str):
                raise ConductorError(f"request env value for {key} must be a string")
            snapshot[key] = value
        return snapshot

    def prepare(self, request: Dict[str, Any]) -> Tuple[List[str], List[str], Path, Dict[str, str], Optional[float]]:
        operation = request.get("operation")
        args = request.get("args") or {}
        timeout = request.get("timeout")
        verbose = bool(request.get("verbose"))
        if timeout is not None and float(timeout) < 0:
            raise ConductorError("timeout must be non-negative")

        if operation in {"sleep", "fake-sleep"}:
            return self._prepare_sleep(operation, args, timeout, request)
        if operation not in IMPLEMENTED_OPERATIONS:
            raise ConductorError(f"operation '{operation}' is not implemented")

        if operation in {"test", "provider-test"}:
            self._validate_xctest_stall_options(args)

        env = self._base_env(verbose, request)
        effective_timeout = self._default_timeout(operation, args)
        if timeout is not None:
            effective_timeout = float(timeout)

        script = lambda name: str(self.repo_root / "Scripts" / name)
        lanes: List[str] = []
        cwd = self.repo_root

        if operation == "doctor":
            return [script("doctor.sh")], lanes, cwd, env, effective_timeout
        if operation == "guardrails":
            return [script("guardrails.sh")], lanes, cwd, env, effective_timeout
        if operation == "format":
            return [script("swift_style.sh"), "format"], ["style", "build"], cwd, env, effective_timeout
        if operation == "format-check":
            return [script("swift_style.sh"), "format-check"], ["style"], cwd, env, effective_timeout
        if operation == "lint":
            return [script("swift_style.sh"), "lint"], ["style"], cwd, env, effective_timeout
        if operation == "format-tools-status":
            return [script("install_format_tools.sh"), "status"], lanes, cwd, env, effective_timeout
        if operation == "check-format-tools":
            return [script("install_format_tools.sh"), "check"], ["style"], cwd, env, effective_timeout
        if operation == "install-format-tools":
            return [script("install_format_tools.sh"), "install"], ["style"], cwd, env, effective_timeout
        if operation == "swift-build":
            product = args.get("product")
            lanes = ["build"]
            if product == "all":
                return self._internal_argv("swift_build_all", {}), lanes, cwd, env, effective_timeout
            return ["swift", "build", "--product", str(product)], lanes, cwd, env, effective_timeout
        if operation == "build":
            return [script("package_app.sh"), "debug"], ["build", "debugArtifact"], cwd, env, effective_timeout
        if operation == "package":
            config = str(args.get("config"))
            lanes = ["build", "debugArtifact"] + (["release"] if config == "release" else [])
            return [script("package_app.sh"), config], lanes, cwd, env, effective_timeout
        if operation == "test":
            argv = ["swift", "test"]
            if args.get("testProduct"):
                argv.extend(["--test-product", str(args["testProduct"])])
            if args.get("list"):
                argv.append("list")
            elif args.get("filter"):
                argv.extend(["--filter", str(args["filter"])])
            return argv, ["build"], cwd, env, effective_timeout
        if operation == "provider-test":
            argv = ["swift", "test"]
            if args.get("testProduct"):
                argv.extend(["--test-product", str(args["testProduct"])])
            if args.get("list"):
                argv.append("list")
            elif args.get("filter"):
                argv.extend(["--filter", str(args["filter"])])
            return argv, ["build"], self.repo_root / "Packages" / "RepoPromptAgentProviders", env, effective_timeout
        if operation == "install-debug-cli":
            return [script("install_debug_cli.sh"), "install", "--build"], ["build", "debugArtifact"], cwd, env, effective_timeout
        if operation == "debug-cli-status":
            return [script("install_debug_cli.sh"), "status"], lanes, cwd, env, effective_timeout
        if operation == "run":
            return self._internal_argv("debug_app_build_then_launch", dict(args)), ["liveApp"], cwd, env, effective_timeout
        if operation == "app":
            subcommand = args.get("subcommand")
            if subcommand == "stop":
                internal_args = {"guardDelayedLaunch": bool(args.get("guardDelayedLaunch"))}
                return self._internal_argv("app_stop", internal_args), ["liveApp"], cwd, env, effective_timeout
            if subcommand == "status":
                return self._internal_argv("app_status", {}), lanes, cwd, env, effective_timeout
            if subcommand == "launch-existing":
                return self._internal_argv("app_launch_existing", dict(args)), ["liveApp"], cwd, env, effective_timeout
            if subcommand == "relaunch":
                return self._internal_argv("debug_app_build_then_launch", dict(args)), ["liveApp"], cwd, env, effective_timeout
        if operation == "smoke":
            lanes = ["debugArtifact", "liveApp"]
            if args.get("launch"):
                lanes = ["liveApp"]
            elif args.get("packagedApp"):
                lanes = ["liveApp"]
            smoke_args = dict(args)
            smoke_args["operationTimeout"] = effective_timeout
            return self._internal_argv("smoke", smoke_args), lanes, cwd, env, effective_timeout
        if operation == "diagnostics":
            subcommand = args.get("subcommand")
            if subcommand == "agent-mode-on":
                return self._internal_argv("diagnostics_agent_mode_on", dict(args)), ["debugArtifact", "liveApp"], cwd, env, effective_timeout
            if subcommand == "build-cache":
                return self._internal_argv("diagnostics_build_cache", dict(args)), lanes, cwd, env, effective_timeout
        if operation == "release":
            subcommand = args.get("subcommand")
            if subcommand == "package":
                return [script("package_app.sh"), "release"], ["build", "debugArtifact", "release"], cwd, env, effective_timeout
            if subcommand == "local-install":
                return [script("install_local_production.sh")], ["build", "debugArtifact", "release"], cwd, env, effective_timeout
            if subcommand == "artifact":
                return [script("release.sh"), "artifact"], ["build", "debugArtifact", "release"], cwd, env, effective_timeout
            if subcommand == "preflight":
                release_script = self.repo_root / "Scripts" / "release.sh"
                if release_script.exists():
                    return [str(release_script), "preflight"], ["release"], cwd, env, effective_timeout
                return self._internal_argv("release_preflight_missing", {}), ["release"], cwd, env, effective_timeout

        raise ConductorError(f"invalid arguments for operation '{operation}'")

    @staticmethod
    def _validate_xctest_stall_options(args: Dict[str, Any]) -> None:
        list_mode = bool(args.get("list"))
        raw_seconds = args.get("xctestStallSeconds")
        wake_probe = bool(args.get("xctestStallWakeProbe"))
        if list_mode and args.get("filter"):
            raise ConductorError("test list mode cannot be combined with a filter")
        if list_mode and (raw_seconds is not None or wake_probe):
            raise ConductorError("test list mode cannot be combined with XCTest stall diagnostics")
        if list_mode and args.get("testProduct"):
            raise ConductorError("test list mode cannot be combined with --test-product")
        if raw_seconds is None:
            if wake_probe:
                raise ConductorError("--xctest-stall-wake-probe requires --xctest-stall-seconds")
            return
        try:
            seconds = float(raw_seconds)
        except (TypeError, ValueError):
            raise ConductorError("--xctest-stall-seconds must be a positive number")
        if not math.isfinite(seconds) or seconds <= 0:
            raise ConductorError("--xctest-stall-seconds must be greater than zero")

    def _prepare_sleep(self, operation: Any, args: Dict[str, Any], timeout: Optional[Any], request: Dict[str, Any]) -> Tuple[List[str], List[str], Path, Dict[str, str], Optional[float]]:
        try:
            seconds = float(args.get("seconds"))
        except (TypeError, ValueError):
            raise ConductorError("sleep operation requires a numeric seconds value")
        if seconds < 0:
            raise ConductorError("sleep seconds must be non-negative")
        lanes = list(args.get("lanes") or [])
        invalid_lanes = [lane for lane in lanes if lane not in LANE_NAMES]
        if invalid_lanes:
            raise ConductorError(f"unknown lane(s): {', '.join(invalid_lanes)}")
        message = str(args.get("message") or "conductor sleep")
        exit_code = int(args.get("exitCode") or 0)
        child_code = (
            "import os,sys,time\n"
            "seconds=float(sys.argv[1]); message=sys.argv[2]; exit_code=int(sys.argv[3])\n"
            "print(f'{message}: start seconds={seconds} pid={os.getpid()}', flush=True)\n"
            "deadline=time.time()+seconds\n"
            "while True:\n"
            "    remaining=deadline-time.time()\n"
            "    if remaining <= 0: break\n"
            "    time.sleep(min(0.2, remaining))\n"
            "print(f'{message}: done exit_code={exit_code}', flush=True)\n"
            "sys.exit(exit_code)\n"
        )
        argv = [sys.executable, "-u", "-c", child_code, str(seconds), message, str(exit_code)]
        env = self._base_env(bool(request.get("verbose")), request)
        effective_timeout = float(timeout) if timeout is not None else max(30.0, seconds + 30.0)
        return argv, lanes, self.repo_root, env, effective_timeout

    def _base_env(self, verbose: bool, request: Dict[str, Any]) -> Dict[str, str]:
        env = self._request_env_snapshot(request)
        if verbose:
            env["VERBOSE"] = "1"
        return env

    def _internal_argv(self, kind: str, args: Dict[str, Any]) -> List[str]:
        payload = {"kind": kind, "args": args, "repoRoot": str(self.repo_root)}
        return [sys.executable, "-u", str(self.script_path), "__operation_runner", json_dumps(payload)]

    def _default_timeout(self, operation: Any, args: Dict[str, Any]) -> float:
        if operation in {"doctor", "guardrails", "debug-cli-status", "format-tools-status", "check-format-tools"}:
            return SHORT_TIMEOUT_SECONDS
        if operation == "app" and args.get("subcommand") in {"status", "stop"}:
            return SHORT_TIMEOUT_SECONDS
        if operation in {"package", "release"} and (args.get("config") == "release" or args.get("subcommand") in {"artifact", "package", "local-install"}):
            return RELEASE_TIMEOUT_SECONDS
        if operation == "smoke" and args.get("agentRun"):
            return MEDIUM_TIMEOUT_SECONDS
        if operation == "diagnostics":
            return SHORT_TIMEOUT_SECONDS
        return MEDIUM_TIMEOUT_SECONDS

    def fingerprint(self, request: Dict[str, Any]) -> str:
        operation = request.get("operation")
        snapshot = self._request_env_snapshot(request)
        material = {
            "operation": operation,
            "args": request.get("args") or {},
            "timeout": request.get("timeout"),
            "verbose": bool(request.get("verbose")),
            "env": {key: snapshot.get(key) for key in self.PASSTHROUGH_ENV_KEYS},
        }
        return hashlib.sha256(json_dumps(material).encode("utf-8")).hexdigest()


class DaemonState:
    def __init__(self, paths: Paths) -> None:
        self.paths = paths
        self.registry = OperationRegistry(paths.repo_root)
        self.lock = threading.RLock()
        self.condition = threading.Condition(self.lock)
        self.jobs: Dict[str, Job] = {}
        self.queue: List[str] = []
        self.request_keys: Dict[str, str] = {}
        self.active_lanes: Dict[str, str] = {}
        self.shutdown_requested = False
        self.server: Optional[socketserver.BaseServer] = None

    def _global_heavy_slot_paths(self, env: Optional[Dict[str, str]] = None) -> List[Path]:
        return global_heavy_slot_paths(env)

    def status_payload(self) -> Dict[str, Any]:
        with self.lock:
            active_by_lane = {
                lane: self._job_payload_locked(self.jobs[ticket], include_tail=False, include_summary=False)
                for lane, ticket in sorted(self.active_lanes.items())
                if ticket in self.jobs
            }
            running_jobs = [self._job_payload_locked(job, include_tail=False, include_summary=False) for job in self.jobs.values() if job.state == "running"]
            queued_jobs = [self._job_payload_locked(self.jobs[ticket], include_tail=False, include_summary=False) for ticket in self.queue if ticket in self.jobs]
            terminal_count = sum(1 for job in self.jobs.values() if job.state in TERMINAL_STATES)
            return {
                "protocolVersion": PROTOCOL_VERSION,
                "pid": os.getpid(),
                "repoRoot": str(self.paths.repo_root),
                "repoHash": self.paths.repo_hash,
                "socketPath": str(self.paths.socket_path),
                "stateDir": str(self.paths.state_dir),
                "globalHeavySlotPaths": [str(path) for path in self._global_heavy_slot_paths()],
                "globalHeavySlotCount": configured_global_heavy_slots(),
                "liveAppLockPath": str(live_app_lock_path()),
                "activeJobsByLane": active_by_lane,
                "runningJobs": running_jobs,
                "queuedJobs": queued_jobs,
                "queueDepth": len(self.queue),
                "retainedTerminalCount": terminal_count,
                "shutdownRequested": self.shutdown_requested,
            }

    def _job_payload_locked(self, job: Job, include_tail: bool = True, include_summary: bool = True) -> Dict[str, Any]:
        payload = job.to_payload(include_tail=include_tail, include_summary=include_summary)
        if job.state == "queued":
            payload["blockedBy"] = self._blocked_by_locked(job)
        return payload

    def _blocked_by_locked(self, job: Job) -> List[Dict[str, Any]]:
        blockers: List[Dict[str, Any]] = []
        seen: set[str] = set()
        job_lanes = set(job.lanes)
        for ticket in self.active_lanes.values():
            blocker = self.jobs.get(ticket)
            if not blocker or blocker.ticket in seen:
                continue
            conflicting = sorted(job_lanes & set(blocker.lanes))
            if conflicting:
                seen.add(blocker.ticket)
                blockers.append(
                    {
                        "ticket": blocker.ticket,
                        "operationLabel": operation_display_name(blocker.operation, blocker.args),
                        "state": blocker.state,
                        "conflictingLanes": conflicting,
                        "cancelRequested": blocker.cancel_requested,
                    }
                )
        for ticket in self.queue:
            if ticket == job.ticket:
                break
            blocker = self.jobs.get(ticket)
            if not blocker or blocker.state != "queued" or blocker.ticket in seen:
                continue
            conflicting = sorted(job_lanes & set(blocker.lanes))
            if conflicting:
                seen.add(blocker.ticket)
                blockers.append(
                    {
                        "ticket": blocker.ticket,
                        "operationLabel": operation_display_name(blocker.operation, blocker.args),
                        "state": blocker.state,
                        "conflictingLanes": conflicting,
                        "cancelRequested": blocker.cancel_requested,
                    }
                )
        return blockers

    def enqueue(self, request: Dict[str, Any]) -> Dict[str, Any]:
        raw_args = request.get("args") or {}
        if not isinstance(raw_args, dict):
            raise ConductorError("request args must be an object")
        args = dict(raw_args)
        operation = str(request.get("operation") or "")
        if operation == "app" and args.get("subcommand") in {"stop", "launch-existing", "relaunch"}:
            # Derived exclusively by supersession below, never accepted from a client.
            args.pop("guardDelayedLaunch", None)
        normalized_request = dict(request)
        normalized_request["args"] = args
        fingerprint = self.registry.fingerprint(normalized_request)
        request_key = request.get("requestKey")
        verbose = bool(request.get("verbose"))
        timeout_value = request.get("timeout")
        _argv, lanes, _cwd, _env, effective_timeout = self.registry.prepare(normalized_request)
        env_snapshot = self.registry._request_env_snapshot(normalized_request)

        with self.condition:
            if self.shutdown_requested:
                raise ConductorError("daemon is stopping; cannot enqueue new jobs")
            if request_key:
                existing_ticket = self.request_keys.get(request_key)
                existing = self.jobs.get(existing_ticket or "") if existing_ticket else None
                if existing and existing.state not in TERMINAL_STATES:
                    if existing.fingerprint != fingerprint:
                        raise ConductorError(
                            "request-key mismatch: an active job with this key has a different fingerprint "
                            f"(existing ticket {existing.ticket})"
                        )
                    reused = self._job_payload_locked(existing, include_tail=False, include_summary=False)
                    reused["reused"] = True
                    return reused

            ticket = str(uuid.uuid4())
            log_path = self.paths.jobs_dir / f"{ticket}.log"
            job = Job(
                ticket=ticket,
                request_key=request_key,
                fingerprint=fingerprint,
                operation=operation,
                args=args,
                lanes=lanes,
                timeout=effective_timeout if timeout_value is not None or effective_timeout is not None else None,
                verbose=verbose,
                env=env_snapshot,
                created_at=now(),
                log_path=log_path,
            )
            intent = latest_lifecycle_intent(job.operation, job.args)
            superseded_jobs: List[Dict[str, Any]] = []
            guard_delayed_launch = False
            if intent:
                superseded_jobs, guard_delayed_launch = self._supersede_live_app_jobs_locked(job, intent)
                if guard_delayed_launch:
                    job.args["guardDelayedLaunch"] = True
            self.jobs[ticket] = job
            self.queue.append(ticket)
            if request_key:
                self.request_keys[request_key] = ticket
            self._retention_pass_locked()
            self._schedule_locked()
            self.condition.notify_all()
            payload = self._job_payload_locked(job, include_tail=False, include_summary=False)
            payload["reused"] = False
            payload["supersededJobs"] = superseded_jobs
            return payload

    def _supersede_live_app_jobs_locked(self, new_job: Job, intent: str) -> Tuple[List[Dict[str, Any]], bool]:
        superseded: List[Dict[str, Any]] = []
        guard_delayed_launch = False
        for old_job in list(self.jobs.values()):
            if old_job.state not in {"queued", "running"} or "liveApp" not in old_job.lanes:
                continue
            prior_state = old_job.state
            old_job.cancel_requested = True
            old_job.superseded_by_ticket = new_job.ticket
            old_job.superseded_by_operation = intent
            guard_delayed_launch = guard_delayed_launch or bool(old_job.args.get("guardDelayedLaunch"))
            if prior_state == "queued":
                old_job.state = "canceled"
                old_job.finished_at = now()
                old_job.exit_code = 130
                old_job.result_summary = f"superseded before start by {intent}"
                with contextlib.suppress(ValueError):
                    self.queue.remove(old_job.ticket)
                self._append_system_line_locked(old_job, f"job superseded before start by {intent} {new_job.ticket}\n")
                cancellation_state = "canceled"
            else:
                guard_delayed_launch = guard_delayed_launch or is_launch_capable_job(old_job.operation, old_job.args)
                reason = f"superseded by {intent} {new_job.ticket}"
                termination_sent = bool(old_job.process_pid or old_job.process_pgid)
                if termination_sent:
                    self._terminate_process_group_locked(old_job, reason=reason)
                threading.Thread(
                    target=self._escalate_canceled_job_after_grace,
                    args=(old_job.ticket, reason, termination_sent),
                    daemon=True,
                ).start()
                cancellation_state = "cancellation-requested"
            superseded.append(
                {
                    "ticket": old_job.ticket,
                    "operationLabel": operation_display_name(old_job.operation, old_job.args),
                    "priorState": prior_state,
                    "cancellationState": cancellation_state,
                }
            )
        return superseded, guard_delayed_launch

    def _escalate_canceled_job_after_grace(self, ticket: str, reason: str, termination_sent: bool) -> None:
        with self.condition:
            job = self.jobs.get(ticket)
            while job and job.state == "running" and not job.process_pid:
                self.condition.wait(timeout=PROCESS_TREE_POLL_SECONDS)
                job = self.jobs.get(ticket)
            if not job or job.state != "running":
                return
            if not termination_sent:
                self._terminate_process_group_locked(job, reason=reason)
            descendants_alive = self._wait_for_process_tree_exit_locked(
                job,
                now() + TERMINATE_GRACE_SECONDS,
                signal_for_new=signal.SIGTERM,
            )
            if descendants_alive:
                self._kill_process_group_locked(job, reason=f"{reason}; SIGKILL after grace period")
                self._wait_for_process_tree_exit_locked(
                    job,
                    now() + KILL_GRACE_SECONDS,
                    signal_for_new=signal.SIGKILL,
                )
            self.condition.notify_all()

    def list_jobs(self, state_filter: Optional[str]) -> Dict[str, Any]:
        with self.lock:
            jobs = list(self.jobs.values())
            jobs.sort(key=lambda job: job.created_at)
            if state_filter:
                jobs = [job for job in jobs if job.state == state_filter]
            return {"jobs": [self._job_payload_locked(job, include_tail=False, include_summary=False) for job in jobs]}

    def resolve_job_locked(self, ticket: Optional[str], request_key: Optional[str]) -> Job:
        if request_key:
            ticket = self.request_keys.get(request_key)
            if not ticket:
                raise ConductorError(f"no job found for request key '{request_key}'")
        if not ticket:
            raise ConductorError("ticket or request key is required")
        job = self.jobs.get(ticket)
        if not job:
            raise ConductorError(f"unknown job '{ticket}'")
        return job

    def job_status(self, ticket: Optional[str], request_key: Optional[str]) -> Dict[str, Any]:
        with self.lock:
            job = self.resolve_job_locked(ticket, request_key)
            if job.state not in TERMINAL_STATES or job.output_summary is not None:
                return self._job_payload_locked(job, include_tail=True)
        self._refresh_output_summary(job)
        with self.lock:
            return self._job_payload_locked(self.resolve_job_locked(ticket, request_key), include_tail=True)


    def job_wait(self, ticket: Optional[str], request_key: Optional[str], timeout: Optional[float]) -> Dict[str, Any]:
        deadline = now() + timeout if timeout is not None else None
        with self.condition:
            job = self.resolve_job_locked(ticket, request_key)
            while job.state not in TERMINAL_STATES:
                remaining = None if deadline is None else deadline - now()
                if remaining is not None and remaining <= 0:
                    payload = self._job_payload_locked(job, include_tail=True)
                    payload["waitTimedOut"] = True
                    return payload
                self.condition.wait(timeout=remaining if remaining is not None else 30.0)
            if job.output_summary is not None:
                payload = self._job_payload_locked(job, include_tail=True)
                payload["waitTimedOut"] = False
                return payload
        self._refresh_output_summary(job)
        with self.condition:
            payload = self._job_payload_locked(self.resolve_job_locked(ticket, request_key), include_tail=True)
            payload["waitTimedOut"] = False
            return payload

    def job_cancel(self, ticket: Optional[str], request_key: Optional[str]) -> Dict[str, Any]:
        with self.condition:
            job = self.resolve_job_locked(ticket, request_key)
            if job.state == "queued":
                job.cancel_requested = True
                job.state = "canceled"
                job.finished_at = now()
                job.exit_code = 130
                job.result_summary = "canceled before start"
                with contextlib.suppress(ValueError):
                    self.queue.remove(job.ticket)
                self._append_system_line_locked(job, "job canceled before start\n")
                self._schedule_locked()
                self.condition.notify_all()
                self._retention_pass_locked()
                return self._job_payload_locked(job, include_tail=True)
            if job.state == "running":
                job.cancel_requested = True
                self._cancel_running_job_locked(job, reason="cancellation requested")
                return self._job_payload_locked(job, include_tail=True)
            return self._job_payload_locked(job, include_tail=True)

    def stop(self, force: bool) -> Dict[str, Any]:
        running_tickets: List[str] = []
        with self.condition:
            active_or_queued = [job for job in self.jobs.values() if job.state in {"queued", "running"}]
            if active_or_queued and not force:
                raise ConductorError(
                    "daemon has active or queued jobs; use 'daemon stop --force' to cancel them before stopping"
                )
            self.shutdown_requested = True
            if force:
                for job in list(active_or_queued):
                    job.cancel_requested = True
                    if job.state == "queued":
                        job.state = "canceled"
                        job.finished_at = now()
                        job.exit_code = 130
                        job.result_summary = "canceled by daemon stop --force"
                        with contextlib.suppress(ValueError):
                            self.queue.remove(job.ticket)
                        self._append_system_line_locked(job, "job canceled by daemon stop --force before start\n")
                    elif job.state == "running":
                        running_tickets.append(job.ticket)
                        self._terminate_process_group_locked(job, reason="daemon stop --force")
                self._write_running_processes_locked()
                self.condition.notify_all()
            payload = self.status_payload()
        if force and running_tickets:
            threading.Thread(target=self._force_shutdown_when_canceled, args=(running_tickets,), daemon=True).start()
        else:
            threading.Thread(target=self._shutdown_server_soon, daemon=True).start()
        return payload

    def _shutdown_server_soon(self) -> None:
        time.sleep(0.1)
        if self.server is not None:
            self.server.shutdown()

    def _force_shutdown_when_canceled(self, tickets: List[str]) -> None:
        with self.condition:
            for ticket in tickets:
                job = self.jobs.get(ticket)
                if not job or job.state != "running":
                    continue
                descendants_alive = self._wait_for_process_tree_exit_locked(
                    job,
                    now() + TERMINATE_GRACE_SECONDS,
                    signal_for_new=signal.SIGTERM,
                )
                if descendants_alive:
                    self._kill_process_group_locked(job, reason="daemon stop --force; SIGKILL after grace period")
                    self._wait_for_process_tree_exit_locked(
                        job,
                        now() + KILL_GRACE_SECONDS,
                        signal_for_new=signal.SIGKILL,
                    )
            self.condition.notify_all()
        time.sleep(0.2)
        if self.server is not None:
            self.server.shutdown()

    def _schedule_locked(self) -> None:
        blocked_lanes: set[str] = set()
        new_queue: List[str] = []
        to_start: List[Job] = []
        active_lane_set = set(self.active_lanes.keys())

        for ticket in self.queue:
            job = self.jobs.get(ticket)
            if not job or job.state != "queued":
                continue
            job_lanes = set(job.lanes)
            if job_lanes & active_lane_set or job_lanes & blocked_lanes:
                blocked_lanes.update(job_lanes)
                new_queue.append(ticket)
                continue
            to_start.append(job)
            active_lane_set.update(job_lanes)

        self.queue = new_queue
        for job in to_start:
            job.state = "running"
            job.started_at = now()
            for lane in job.lanes:
                self.active_lanes[lane] = job.ticket
            thread = threading.Thread(target=self._run_job, args=(job.ticket,), daemon=True)
            thread.start()
        if to_start:
            self.condition.notify_all()

    def _acquire_global_heavy_slot(self, ticket: str) -> Optional[Any]:
        wait_start = now()
        with self.condition:
            job = self.jobs.get(ticket)
            env = dict(job.env) if job else {}
        lock_paths = self._global_heavy_slot_paths(env)
        ensure_private_dir(machine_lock_dir())
        lock_files = [(path, path.open("a+", encoding="utf-8")) for path in lock_paths]
        did_log_wait = False
        selected_path: Optional[Path] = None
        selected_file: Optional[Any] = None
        try:
            while True:
                with self.condition:
                    job = self.jobs.get(ticket)
                    if not job or job.state != "running":
                        return None
                    if job.cancel_requested:
                        job.state = "canceled"
                        job.exit_code = 130
                        job.result_summary = "canceled before global heavy slot"
                        job.finished_at = now()
                        self._append_system_line_locked(job, "job canceled before global heavy slot\n")
                        self.condition.notify_all()
                        return None
                for lock_path, lock_file in lock_files:
                    try:
                        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                        selected_path = lock_path
                        selected_file = lock_file
                        break
                    except BlockingIOError:
                        continue
                    except OSError as exc:
                        if exc.errno == errno.EINTR:
                            continue
                        raise
                if selected_file is not None and selected_path is not None:
                    break
                holders = [format_display_lock_holder(read_display_lock_metadata(path)) for path, _file in lock_files]
                with self.condition:
                    job = self.jobs.get(ticket)
                    if job and job.state == "running":
                        job.global_heavy_slot_path = ",".join(str(path) for path, _file in lock_files)
                        job.global_heavy_slot_holder = "; ".join(holders)
                        if not did_log_wait:
                            self._append_system_line_locked(
                                job,
                                f"waiting for global heavy slot ({len(lock_files)} configured): {job.global_heavy_slot_path}; {job.global_heavy_slot_holder}\n",
                            )
                            self.condition.notify_all()
                            did_log_wait = True
                time.sleep(GLOBAL_HEAVY_SLOT_POLL_SECONDS)
            waited = now() - wait_start
            with self.condition:
                job = self.jobs.get(ticket)
                if job and job.state == "running":
                    metadata = display_lock_metadata(
                        lock_kind="global-heavy",
                        ticket=job.ticket,
                        operation=job.operation,
                        operation_label=operation_display_name(job.operation, job.args),
                        repo_root=self.paths.repo_root,
                        repo_hash=self.paths.repo_hash,
                    )
                    write_display_lock_metadata(selected_file, metadata)
                    job.global_heavy_slot_wait_seconds = waited
                    job.global_heavy_slot_path = str(selected_path)
                    job.global_heavy_slot_holder = None
                    self._append_system_line_locked(
                        job,
                        f"acquired global heavy slot {selected_path} after {format_duration(waited)}\n",
                    )
                    self.condition.notify_all()
            return selected_file
        finally:
            for _path, lock_file in lock_files:
                if lock_file is selected_file:
                    continue
                with contextlib.suppress(OSError):
                    lock_file.close()

    @staticmethod
    def _release_global_heavy_slot(lock_file: Optional[Any]) -> None:
        if lock_file is None:
            return
        with contextlib.suppress(OSError):
            lock_file.seek(0)
            lock_file.truncate()
            lock_file.flush()
        with contextlib.suppress(OSError):
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
        with contextlib.suppress(OSError):
            lock_file.close()

    def _run_job(self, ticket: str) -> None:
        job: Optional[Job] = None
        process: Optional[subprocess.Popen[bytes]] = None
        output_transport: Optional[ProcessOutputTransport] = None
        watchdog: Optional[threading.Thread] = None
        global_heavy_slot: Optional[Any] = None
        try:
            with self.lock:
                job = self.jobs[ticket]
                request = {
                    "operation": job.operation,
                    "args": job.args,
                    "timeout": job.timeout,
                    "verbose": job.verbose,
                    "env": job.env,
                }
                if job.cancel_requested:
                    job.state = "canceled"
                    job.exit_code = 130
                    job.result_summary = "canceled before process start"
                    job.finished_at = now()
                    self._append_system_line_locked(job, "job canceled before process start\n")
                    return
            argv, _lanes, cwd, env, effective_timeout = self.registry.prepare(request)
            env["REPOPROMPT_CONDUCTOR_JOB_TICKET"] = job.ticket
            if operation_requires_global_heavy_slot(job.operation, job.args):
                global_heavy_slot = self._acquire_global_heavy_slot(job.ticket)
                if global_heavy_slot is None:
                    return
            start_line = f"$ {format_argv(argv)}\n"
            with job.log_path.open("ab") as log_file:
                with self.lock:
                    self._append_tail_locked(job, start_line)
                log_file.write(start_line.encode("utf-8", errors="replace"))
                log_file.flush()
                output_transport = self._create_process_output_transport(job)
                job.progress_transport = output_transport.kind
                process = subprocess.Popen(
                    argv,
                    cwd=str(cwd),
                    env=env,
                    stdin=subprocess.DEVNULL,
                    stdout=output_transport.popen_stdout,
                    stderr=output_transport.popen_stderr,
                    start_new_session=True,
                )
                output_transport.attach_process(process)
                with self.condition:
                    job.process_started_at = now()
                    job.process_pid = process.pid
                    with contextlib.suppress(OSError):
                        job.process_pgid = os.getpgid(process.pid)
                    snapshot = process_table_snapshot()
                    process_record = snapshot.get(process.pid)
                    job.process_start = process_record[1] if process_record else process_start_token(process.pid)
                    if job.process_start:
                        job.tracked_processes[process.pid] = job.process_start
                    self._write_running_processes_locked()
                    if job.cancel_requested and job.superseded_by_ticket is None:
                        self._terminate_process_group_locked(job, reason="cancellation requested before PID assignment")
                    self.condition.notify_all()

                reader = threading.Thread(
                    target=self._read_process_output,
                    args=(job.ticket, process, log_file, output_transport),
                    daemon=True,
                )
                reader.start()
                if self._xctest_watchdog_enabled(job):
                    watchdog = threading.Thread(
                        target=self._monitor_xctest_stall,
                        args=(job.ticket,),
                        daemon=True,
                    )
                    watchdog.start()
                try:
                    exit_code = process.wait(timeout=effective_timeout)
                except subprocess.TimeoutExpired:
                    term_deadline = now() + TERMINATE_GRACE_SECONDS
                    with self.condition:
                        job.timed_out = True
                        job.error = f"timed out after {effective_timeout:.1f}s"
                        self._append_system_line_locked(job, job.error + "\n")
                        self._terminate_process_group_locked(job, reason=job.error)
                    root_alive = False
                    try:
                        exit_code = process.wait(timeout=TERMINATE_GRACE_SECONDS)
                    except subprocess.TimeoutExpired:
                        root_alive = True
                        exit_code = 124
                    with self.condition:
                        descendants_alive = self._wait_for_process_tree_exit_locked(
                            job,
                            term_deadline,
                            signal_for_new=signal.SIGTERM,
                        )
                        if root_alive or descendants_alive:
                            self._kill_process_group_locked(job, reason="SIGKILL after timeout grace period")
                    if root_alive:
                        try:
                            exit_code = process.wait(timeout=KILL_GRACE_SECONDS)
                        except subprocess.TimeoutExpired:
                            exit_code = 124
                            with self.condition:
                                job.error = (
                                    f"timed out after {effective_timeout:.1f}s; "
                                    "root process did not exit after SIGKILL escalation"
                                )
                                self._append_system_line_locked(job, job.error + "\n")
                    with self.condition:
                        descendants_alive = self._wait_for_process_tree_exit_locked(
                            job,
                            now() + KILL_GRACE_SECONDS,
                            signal_for_new=signal.SIGKILL,
                        )
                        if descendants_alive:
                            job.error = (
                                f"timed out after {effective_timeout:.1f}s; "
                                "job processes remained alive after SIGKILL escalation"
                            )
                            self._append_system_line_locked(job, job.error + "\n")
                    if exit_code == 0:
                        exit_code = 124
                with self.condition:
                    job.process_finished_at = now()
                if job.cancel_requested:
                    with self.condition:
                        if self._process_tree_alive_locked(job):
                            self._terminate_process_group_locked(job, reason="cancellation descendant cleanup")
                            term_deadline = now() + TERMINATE_GRACE_SECONDS
                            descendants_alive = self._wait_for_process_tree_exit_locked(
                                job, term_deadline, signal_for_new=signal.SIGTERM
                            )
                            if descendants_alive:
                                self._kill_process_group_locked(job, reason="cancellation descendant cleanup; SIGKILL after grace period")
                                descendants_alive = self._wait_for_process_tree_exit_locked(
                                    job, now() + KILL_GRACE_SECONDS, signal_for_new=signal.SIGKILL
                                )
                            if descendants_alive:
                                raise ConductorError("canceled job descendants remained alive after SIGKILL escalation")
                reader.join(timeout=2.0)
                if reader.is_alive():
                    output_transport.close_reader()
                    reader.join(timeout=2.0)
                else:
                    output_transport.close_reader()
                with self.condition:
                    job.xctest_process_finished = True
                    self.condition.notify_all()
                if watchdog is not None:
                    watchdog.join(timeout=XCTEST_WATCHDOG_JOIN_SECONDS)
                    if watchdog.is_alive():
                        with self.condition:
                            job.measurement_invalid = True
                            job.error = "XCTest progress stall watchdog did not finish bounded diagnostics"
                            self._append_system_line_locked(job, job.error + "\n")
                with self.condition:
                    self._finalize_process_exit_locked(job, exit_code)
                    job.finished_at = now()
        except Exception as exc:  # defensive: preserve daemon health
            if job is not None:
                with self.condition:
                    job.state = "failed"
                    job.exit_code = 1
                    job.error = str(exc)
                    job.result_summary = f"daemon runner error: {exc}"
                    job.finished_at = now()
                    self._append_system_line_locked(job, f"daemon runner error: {exc}\n")
        finally:
            self._release_global_heavy_slot(global_heavy_slot)
            if output_transport is not None:
                output_transport.close_all()
            refresh_after_release = False
            with self.condition:
                if job is not None:
                    refresh_after_release = job.state in TERMINAL_STATES and job.output_summary is None
                    for lane in list(job.lanes):
                        if self.active_lanes.get(lane) == job.ticket:
                            del self.active_lanes[lane]
                    self._write_running_processes_locked()
                    self._retention_pass_locked()
                self._schedule_locked()
                self.condition.notify_all()
            if job is not None and refresh_after_release:
                threading.Thread(target=self._refresh_output_summary, args=(job,), daemon=True).start()

    @staticmethod
    def _take_complete_output_lines(pending: bytearray, chunk: bytes) -> List[bytes]:
        pending.extend(chunk)
        lines: List[bytes] = []
        while True:
            newline = pending.find(b"\n")
            if newline < 0:
                return lines
            end = newline + 1
            lines.append(bytes(pending[:end]))
            del pending[:end]

    def _submit_process_output_line(self, ticket: str, line: bytes) -> None:
        text = line.decode("utf-8", errors="replace")
        with self.condition:
            job = self.jobs.get(ticket)
            if job:
                self._append_tail_locked(job, text)
                self._record_xctest_progress_locked(job, text)
                self.condition.notify_all()

    def _read_process_output(
        self,
        ticket: str,
        process: subprocess.Popen[bytes],
        log_file: Any,
        output_transport: ProcessOutputTransport,
    ) -> None:
        pending = bytearray()
        try:
            while True:
                chunk = output_transport.read_chunk(process)
                if not chunk:
                    break
                log_file.write(chunk)
                log_file.flush()
                for line in self._take_complete_output_lines(pending, chunk):
                    self._submit_process_output_line(ticket, line)
        finally:
            if pending:
                self._submit_process_output_line(ticket, bytes(pending))
            output_transport.close_reader()

    def _finalize_process_exit_locked(self, job: Job, exit_code: int) -> None:
        if job.cancel_requested:
            job.state = "canceled"
            job.exit_code = 130
            job.result_summary = "canceled"
        elif job.measurement_invalid:
            job.state = "failed"
            job.exit_code = XCTEST_STALL_FAILURE_EXIT_CODE
            job.error = job.error or "XCTest progress stall watchdog invalidated this measurement"
            job.result_summary = job.error
        elif job.timed_out:
            job.state = "failed"
            job.exit_code = 124
            job.result_summary = job.error or "timed out"
        elif exit_code == 0:
            job.state = "completed"
            job.exit_code = 0
            job.result_summary = "completed successfully"
        else:
            job.state = "failed"
            job.exit_code = int(exit_code)
            job.error = f"process exited with status {exit_code}"
            job.result_summary = job.error

    def _xctest_watchdog_enabled(self, job: Job) -> bool:
        return (
            job.operation in {"test", "provider-test"}
            and not bool(job.args.get("list"))
            and job.args.get("xctestStallSeconds") is not None
        )

    def _create_process_output_transport(self, job: Job) -> ProcessOutputTransport:
        kind = "pty" if self._xctest_watchdog_enabled(job) else "pipe"
        return ProcessOutputTransport.create(kind)

    def _record_xctest_progress_locked(
        self,
        job: Job,
        text: str,
        observed_at: Optional[float] = None,
    ) -> bool:
        if not self._xctest_watchdog_enabled(job):
            return False
        matched = False
        timestamp = time.monotonic() if observed_at is None else observed_at
        progress_observed_at = now() if observed_at is None else observed_at
        threshold = float(job.args["xctestStallSeconds"])
        for raw_line in text.splitlines():
            matchable_line = XCTEST_ANSI_SGR_RE.sub("", raw_line.rstrip("\r\n")).strip()
            marker = XCTEST_PROGRESS_RE.match(matchable_line)
            if marker is None:
                continue
            test_name, action = marker.groups()
            if action != "started" and job.xctest_progress_deadline is None:
                continue
            matched = True
            job.xctest_progress_sequence += 1
            job.xctest_progress_deadline = timestamp + threshold
            job.xctest_last_progress_test = test_name
            job.xctest_last_progress_action = action
            job.xctest_last_progress_observed_at = progress_observed_at
            if action == "started":
                if job.xctest_current_test and job.xctest_current_test != test_name:
                    job.xctest_previous_test = job.xctest_current_test
                job.xctest_current_test = test_name
            else:
                job.xctest_previous_test = test_name
                if job.xctest_current_test == test_name:
                    job.xctest_current_test = None
        return matched

    def _claim_xctest_stall_locked(
        self,
        job: Job,
        observed_at: Optional[float] = None,
    ) -> Optional[XCTestStallClaim]:
        if not self._xctest_watchdog_enabled(job) or job.xctest_watchdog_triggered:
            return None
        timestamp = time.monotonic() if observed_at is None else observed_at
        deadline = job.xctest_progress_deadline
        if deadline is None or timestamp < deadline:
            return None
        job.xctest_watchdog_triggered = True
        job.measurement_invalid = True
        job.error = "XCTest progress stall watchdog invalidated this measurement"
        return XCTestStallClaim(
            progress_transport=job.progress_transport or "pty",
            progress_sequence=job.xctest_progress_sequence,
            last_progress_test=job.xctest_last_progress_test,
            last_progress_action=job.xctest_last_progress_action,
            last_progress_observed_at=job.xctest_last_progress_observed_at,
            threshold_seconds=float(job.args["xctestStallSeconds"]),
            current_test=job.xctest_current_test,
            previous_test=job.xctest_previous_test,
            wake_probe=bool(job.args.get("xctestStallWakeProbe")),
            triggered_at=timestamp,
        )

    def _monitor_xctest_stall(self, ticket: str) -> None:
        while True:
            with self.condition:
                job = self.jobs.get(ticket)
                if (
                    job is None
                    or job.state != "running"
                    or job.xctest_watchdog_triggered
                    or job.xctest_process_finished
                ):
                    return
                deadline = job.xctest_progress_deadline
                if deadline is None:
                    self.condition.wait()
                    continue
                remaining = deadline - time.monotonic()
                if remaining > 0:
                    self.condition.wait(timeout=remaining)
                    continue
                claim = self._claim_xctest_stall_locked(job)
                if claim is None:
                    continue
            self._handle_xctest_stall(ticket, claim)
            return

    def _xctest_process_snapshot_locked(
        self,
        job: Job,
    ) -> Tuple[Optional[Tuple[int, str]], List[Dict[str, Any]]]:
        verified, depths = self._refresh_process_tree_locked(job)
        commands = process_command_snapshot(verified.keys())
        entries: List[Dict[str, Any]] = []
        matches: List[Tuple[int, int, str]] = []
        for pid in sorted(verified, key=lambda candidate: (depths.get(candidate, 0), candidate)):
            ppid, start_token = verified[pid]
            command = commands.get(pid, "")
            entry = {
                "pid": pid,
                "ppid": ppid,
                "depth": depths.get(pid, 0),
                "startToken": start_token,
                "command": command[:500],
            }
            if len(entries) < XCTEST_STALL_DIAGNOSTIC_MAX_PROCESSES:
                entries.append(entry)
            if is_xctest_process_command(command):
                matches.append((depths.get(pid, 0), pid, start_token))
        if not matches:
            return None, entries
        _depth, pid, start_token = max(matches)
        return (pid, start_token), entries

    def _signal_process_identity(self, pid: int, start_token: str, sig: signal.Signals) -> bool:
        confirmation = process_table_snapshot().get(pid)
        if confirmation is None or confirmation[1] != start_token:
            return False
        try:
            os.kill(pid, sig)
            return True
        except (ProcessLookupError, PermissionError, OSError):
            return False

    @staticmethod
    def _bound_diagnostic_file(path: Path, max_bytes: int = XCTEST_STALL_SAMPLE_MAX_BYTES) -> None:
        try:
            data = path.read_bytes()
        except OSError:
            return
        if len(data) <= max_bytes:
            return
        marker = b"\n... conductor truncated bounded XCTest stall diagnostic ...\n"
        payload_bytes = max(0, max_bytes - len(marker))
        head_bytes = payload_bytes // 2
        tail_bytes = payload_bytes - head_bytes
        path.write_bytes(data[:head_bytes] + marker + data[-tail_bytes:])

    def _capture_xctest_stall_diagnostics(
        self,
        job: Job,
        diagnostic: Dict[str, Any],
        xctest_identity: Optional[Tuple[int, str]],
    ) -> Dict[str, Any]:
        snapshot_path = self.paths.jobs_dir / f"{job.ticket}.xctest-stall.json"
        diagnostic["processSnapshotPath"] = str(snapshot_path)
        try:
            snapshot_path.write_text(json.dumps(diagnostic, indent=2, sort_keys=True), encoding="utf-8")
            self._bound_diagnostic_file(snapshot_path)
            job.diagnostic_paths.append(snapshot_path)
        except OSError as exc:
            diagnostic["processSnapshotError"] = str(exc)

        if xctest_identity is None:
            return diagnostic
        pid, _start_token = xctest_identity
        sample_path = self.paths.jobs_dir / f"{job.ticket}.xctest-stall.sample.txt"
        diagnostic["samplePath"] = str(sample_path)
        try:
            completed = subprocess.run(
                ["/usr/bin/sample", str(pid), "1", "10", "-file", str(sample_path)],
                text=True,
                capture_output=True,
                timeout=3.0,
            )
            diagnostic["sampleExitCode"] = completed.returncode
            if completed.stderr:
                diagnostic["sampleStderr"] = completed.stderr[-1000:]
            if sample_path.exists():
                self._bound_diagnostic_file(sample_path)
                job.diagnostic_paths.append(sample_path)
        except (OSError, subprocess.TimeoutExpired) as exc:
            diagnostic["sampleError"] = str(exc)
        return diagnostic

    def _wait_for_xctest_progress_after_probe(
        self,
        job: Job,
        progress_sequence: int,
        timeout: float = XCTEST_WAKE_PROGRESS_WAIT_SECONDS,
    ) -> bool:
        deadline = time.monotonic() + min(timeout, XCTEST_WAKE_PROGRESS_WAIT_SECONDS)
        with self.condition:
            while job.state == "running" and job.xctest_progress_sequence <= progress_sequence:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                self.condition.wait(timeout=remaining)
            return job.xctest_progress_sequence > progress_sequence

    def _terminate_xctest_stalled_job(self, job: Job) -> None:
        with self.condition:
            if job.state != "running":
                return
            self._terminate_process_group_locked(job, reason="XCTest progress stall measurement invalid")
            descendants_alive = self._wait_for_process_tree_exit_locked(
                job,
                now() + TERMINATE_GRACE_SECONDS,
                signal_for_new=signal.SIGTERM,
            )
            if descendants_alive:
                self._kill_process_group_locked(
                    job,
                    reason="XCTest progress stall cleanup; SIGKILL after grace period",
                )
                descendants_alive = self._wait_for_process_tree_exit_locked(
                    job,
                    now() + KILL_GRACE_SECONDS,
                    signal_for_new=signal.SIGKILL,
                )
            if descendants_alive:
                self._append_system_line_locked(
                    job,
                    "XCTest stall watchdog cleanup could not confirm descendant exit after SIGKILL\n",
                )
            self.condition.notify_all()

    def _handle_xctest_stall(self, ticket: str, claim: XCTestStallClaim) -> None:
        with self.condition:
            job = self.jobs.get(ticket)
            if job is None:
                return
            xctest_identity, process_tree = self._xctest_process_snapshot_locked(job)
            diagnostic: Dict[str, Any] = {
                "kind": "xctest-progress-stall",
                "capturedAt": now(),
                "thresholdSeconds": claim.threshold_seconds,
                "progressTransport": claim.progress_transport,
                "progressSequence": claim.progress_sequence,
                "lastProgressTest": claim.last_progress_test,
                "lastProgressAction": claim.last_progress_action,
                "lastProgressObservedAt": claim.last_progress_observed_at,
                "currentTest": claim.current_test,
                "previousTest": claim.previous_test,
                "wakeProbeRequested": claim.wake_probe,
                "processTree": process_tree,
            }
            if xctest_identity is not None:
                diagnostic["xctestPID"] = xctest_identity[0]
                diagnostic["xctestStartToken"] = xctest_identity[1]
            current = claim.current_test or "<between XCTest cases>"
            previous = claim.previous_test or "<none>"
            self._append_system_line_locked(
                job,
                f"XCTest progress stall watchdog triggered after {claim.threshold_seconds:.3f}s; "
                f"current={current}; previous={previous}\n",
            )
            self._append_system_line_locked(job, "XCTest descendant process tree:\n")
            for entry in process_tree:
                self._append_system_line_locked(
                    job,
                    "  pid={pid} ppid={ppid} depth={depth} start={startToken} command={command}\n".format(**entry),
                )

        diagnostic = self._capture_xctest_stall_diagnostics(job, diagnostic, xctest_identity)
        resumed = False
        stop_sent = False
        continue_sent = False
        if claim.wake_probe and xctest_identity is not None:
            pid, start_token = xctest_identity
            stop_sent = self._signal_process_identity(pid, start_token, signal.SIGSTOP)
            if stop_sent:
                time.sleep(XCTEST_WAKE_PROBE_PAUSE_SECONDS)
                continue_sent = self._signal_process_identity(pid, start_token, signal.SIGCONT)
                if continue_sent:
                    resumed = self._wait_for_xctest_progress_after_probe(job, claim.progress_sequence)
        diagnostic["stopSent"] = stop_sent
        diagnostic["continueSent"] = continue_sent
        diagnostic["progressResumed"] = resumed
        snapshot_path_value = diagnostic.get("processSnapshotPath")
        if isinstance(snapshot_path_value, str):
            try:
                snapshot_path = Path(snapshot_path_value)
                snapshot_path.write_text(json.dumps(diagnostic, indent=2, sort_keys=True), encoding="utf-8")
                self._bound_diagnostic_file(snapshot_path)
            except OSError as exc:
                diagnostic["processSnapshotFinalWriteError"] = str(exc)
        with self.condition:
            job.diagnostics.append(diagnostic)
            self._append_system_line_locked(
                job,
                "XCTest stall wake probe result: "
                f"stopSent={stop_sent} continueSent={continue_sent} progressResumed={resumed}; "
                "measurement remains invalid\n",
            )
        self._terminate_xctest_stalled_job(job)

    def _refresh_output_summary(self, job: Job) -> None:
        summary = OutputSummarizer.summarize_file(
            job.operation,
            job.args,
            job.state,
            job.exit_code,
            job.timed_out,
            job.log_path,
        )
        with self.condition:
            current = self.jobs.get(job.ticket)
            if current is job and current.output_summary is None:
                current.output_summary = summary
                self.condition.notify_all()

    def _append_tail_locked(self, job: Job, text: str) -> None:
        lines = text.splitlines(keepends=True)
        if not lines:
            return
        for line in lines:
            job.tail.append(line)

    def _append_system_line_locked(self, job: Job, text: str) -> None:
        self._append_tail_locked(job, text)
        try:
            with job.log_path.open("ab") as handle:
                handle.write(text.encode("utf-8", errors="replace"))
        except OSError:
            pass

    def _write_running_processes_locked(self) -> None:
        processes = []
        for job in self.jobs.values():
            if job.state == "running" and (job.process_pid or job.process_pgid):
                processes.append(
                    {
                        "ticket": job.ticket,
                        "operation": job.operation,
                        "pid": job.process_pid,
                        "pgid": job.process_pgid,
                        "processStart": job.process_start,
                    }
                )
        payload = {"updatedAt": now(), "processes": processes}
        try:
            self.paths.running_processes_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
            with contextlib.suppress(OSError):
                os.chmod(self.paths.running_processes_path, 0o600)
        except OSError:
            pass

    def _cancel_running_job_locked(self, job: Job, reason: str) -> None:
        pid_deadline = now() + 1.0
        while job.state == "running" and not job.process_pid and now() < pid_deadline:
            self.condition.wait(timeout=PROCESS_TREE_POLL_SECONDS)
        if job.state != "running":
            return
        self._terminate_process_group_locked(job, reason=reason)
        descendants_alive = self._wait_for_process_tree_exit_locked(
            job,
            now() + TERMINATE_GRACE_SECONDS,
            signal_for_new=signal.SIGTERM,
        )
        if descendants_alive:
            self._kill_process_group_locked(job, reason=f"{reason}; SIGKILL after grace period")
            self._wait_for_process_tree_exit_locked(
                job,
                now() + KILL_GRACE_SECONDS,
                signal_for_new=signal.SIGKILL,
            )
        completion_deadline = now() + KILL_GRACE_SECONDS
        while job.state == "running" and now() < completion_deadline:
            self.condition.wait(timeout=PROCESS_TREE_POLL_SECONDS)

    def _refresh_process_tree_locked(self, job: Job) -> Tuple[Dict[int, Tuple[int, str]], Dict[int, int]]:
        snapshot = process_table_snapshot()
        root_pid = job.process_pid
        if root_pid and root_pid not in job.tracked_processes:
            record = snapshot.get(root_pid)
            token = job.process_start or (record[1] if record else None)
            if token:
                job.process_start = token
                job.tracked_processes[root_pid] = token

        live_tracked = {
            pid
            for pid, token in job.tracked_processes.items()
            if snapshot.get(pid) is not None and snapshot[pid][1] == token
        }
        children_by_parent: Dict[int, List[int]] = {}
        for pid, (ppid, _token) in snapshot.items():
            children_by_parent.setdefault(ppid, []).append(pid)

        depths: Dict[int, int] = {pid: 0 for pid in live_tracked}
        queue: Deque[int] = deque(live_tracked)
        while queue:
            parent = queue.popleft()
            parent_depth = depths[parent]
            for child in children_by_parent.get(parent, []):
                child_record = snapshot.get(child)
                if child_record is None:
                    continue
                child_token = child_record[1]
                if job.tracked_processes.get(child) != child_token:
                    job.tracked_processes[child] = child_token
                next_depth = parent_depth + 1
                if next_depth > depths.get(child, -1):
                    depths[child] = next_depth
                    queue.append(child)

        verified = {
            pid: snapshot[pid]
            for pid, token in job.tracked_processes.items()
            if snapshot.get(pid) is not None and snapshot[pid][1] == token
        }
        for pid in verified:
            depths.setdefault(pid, 0)
        return verified, depths

    def _signal_verified_processes_locked(
        self,
        job: Job,
        sig: signal.Signals,
        verified: Dict[int, Tuple[int, str]],
        depths: Dict[int, int],
    ) -> int:
        confirmation = process_table_snapshot()
        signaled = 0
        for pid in sorted(verified, key=lambda candidate: (depths.get(candidate, 0), candidate), reverse=True):
            token = job.tracked_processes.get(pid)
            if not token or confirmation.get(pid) is None or confirmation[pid][1] != token:
                continue
            try:
                os.kill(pid, sig)
                signaled += 1
            except (ProcessLookupError, PermissionError, OSError):
                continue
        return signaled

    def _signal_process_tree_locked(self, job: Job, sig: signal.Signals) -> int:
        verified, depths = self._refresh_process_tree_locked(job)
        return self._signal_verified_processes_locked(job, sig, verified, depths)

    def _process_tree_alive_locked(self, job: Job) -> bool:
        verified, _depths = self._refresh_process_tree_locked(job)
        return bool(verified)

    def _process_group_id_alive_locked(self, job: Job) -> bool:
        if not job.process_group_identity_confirmed:
            return False
        try:
            pgid = int(job.process_pgid) if job.process_pgid is not None else 0
        except (TypeError, ValueError):
            return False
        if pgid <= 0:
            return False
        with contextlib.suppress(OSError):
            if pgid == os.getpgrp():
                return False
        try:
            os.killpg(pgid, 0)
            return True
        except (ProcessLookupError, PermissionError, OSError):
            return False

    def _wait_for_process_tree_exit_locked(
        self,
        job: Job,
        deadline: float,
        signal_for_new: signal.Signals,
    ) -> bool:
        while now() < deadline:
            verified, depths = self._refresh_process_tree_locked(job)
            if not verified:
                if not self._process_group_id_alive_locked(job):
                    return False
                self._signal_process_group_id_locked(job, signal_for_new)
                self.condition.wait(timeout=min(PROCESS_TREE_POLL_SECONDS, max(0.0, deadline - now())))
                continue
            self._signal_verified_processes_locked(job, signal_for_new, verified, depths)
            self.condition.wait(timeout=min(PROCESS_TREE_POLL_SECONDS, max(0.0, deadline - now())))
        return self._process_tree_alive_locked(job) or self._process_group_id_alive_locked(job)

    def _signal_process_group_id_locked(self, job: Job, sig: signal.Signals) -> bool:
        try:
            pgid = int(job.process_pgid) if job.process_pgid is not None else 0
        except (TypeError, ValueError):
            return False
        if pgid <= 0:
            return False
        with contextlib.suppress(OSError):
            if pgid == os.getpgrp():
                return False

        # Once a start-token-verified job process is observed in the job PGID, keep
        # trusting that PGID for this job's short TERM -> KILL cleanup window. This
        # lets escalation reach same-PGID descendants that reparent after the root
        # exits and are no longer discoverable by PPID tree walking.
        group_identity_confirmed = job.process_group_identity_confirmed
        if not group_identity_confirmed:
            verified, _depths = self._refresh_process_tree_locked(job)
            for pid, (_ppid, _start_token) in verified.items():
                with contextlib.suppress(ProcessLookupError, PermissionError, OSError):
                    if os.getpgid(pid) == pgid:
                        group_identity_confirmed = True
                        break
            if group_identity_confirmed:
                job.process_group_identity_confirmed = True

        if not group_identity_confirmed:
            return False

        try:
            os.killpg(pgid, sig)
            return True
        except (ProcessLookupError, PermissionError, OSError):
            return False

    def _terminate_process_group_locked(self, job: Job, reason: str) -> None:
        if self._signal_process_group_id_locked(job, signal.SIGTERM):
            self._append_system_line_locked(job, f"terminating process group: {reason}\n")
        self._append_system_line_locked(job, f"terminating process tree: {reason}\n")
        self._signal_process_tree_locked(job, signal.SIGTERM)

    def _kill_process_group_locked(self, job: Job, reason: str) -> None:
        if self._signal_process_group_id_locked(job, signal.SIGKILL):
            self._append_system_line_locked(job, f"killing process group: {reason}\n")
        self._append_system_line_locked(job, f"killing process tree: {reason}\n")
        self._signal_process_tree_locked(job, signal.SIGKILL)

    def _retention_pass_locked(self) -> None:
        cutoff = now() - TERMINAL_RETENTION_SECONDS
        terminal = [job for job in self.jobs.values() if job.state in TERMINAL_STATES]
        prune: set[str] = set()
        for job in terminal:
            if job.finished_at is not None and job.finished_at < cutoff:
                prune.add(job.ticket)
        terminal_sorted = sorted(terminal, key=lambda job: job.finished_at or job.created_at)
        excess = max(0, len(terminal_sorted) - MAX_TERMINAL_JOBS)
        for job in terminal_sorted[:excess]:
            prune.add(job.ticket)
        for ticket in prune:
            job = self.jobs.pop(ticket, None)
            if not job:
                continue
            with contextlib.suppress(FileNotFoundError):
                job.log_path.unlink()
            for diagnostic_path in job.diagnostic_paths:
                with contextlib.suppress(FileNotFoundError):
                    diagnostic_path.unlink()
            for key, mapped_ticket in list(self.request_keys.items()):
                if mapped_ticket == ticket:
                    del self.request_keys[key]

        retained_logs = {job.log_path.name for job in self.jobs.values()}
        with contextlib.suppress(FileNotFoundError):
            for log_path in self.paths.jobs_dir.glob("*.log"):
                if log_path.name not in retained_logs:
                    try:
                        age = now() - log_path.stat().st_mtime
                    except OSError:
                        continue
                    if age > TERMINAL_RETENTION_SECONDS:
                        with contextlib.suppress(FileNotFoundError):
                            log_path.unlink()

        retained_diagnostics = {
            diagnostic_path.name
            for job in self.jobs.values()
            for diagnostic_path in job.diagnostic_paths
        }
        with contextlib.suppress(FileNotFoundError):
            for diagnostic_path in self.paths.jobs_dir.glob("*.xctest-stall.*"):
                if diagnostic_path.name in retained_diagnostics:
                    continue
                try:
                    age = now() - diagnostic_path.stat().st_mtime
                except OSError:
                    continue
                if age > TERMINAL_RETENTION_SECONDS:
                    with contextlib.suppress(FileNotFoundError):
                        diagnostic_path.unlink()


class ThreadedUnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, server_address: str, handler_cls: Any, state: DaemonState) -> None:
        self.state = state
        super().__init__(server_address, handler_cls)


class RequestHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        state: DaemonState = self.server.state  # type: ignore[attr-defined]
        request_id = "unknown"
        try:
            raw = self.rfile.readline(10 * 1024 * 1024)
            if not raw:
                return
            request = json.loads(raw.decode("utf-8"))
            request_id = str(request.get("id") or "unknown")
            payload = handle_request(state, request)
            response = {"id": request_id, "ok": True, "payload": payload}
        except Exception as exc:
            response = {"id": request_id, "ok": False, "error": str(exc)}
        self.wfile.write((json.dumps(response) + "\n").encode("utf-8"))
        self.wfile.flush()


def handle_request(state: DaemonState, request: Dict[str, Any]) -> Dict[str, Any]:
    req_type = request.get("type")
    if req_type == "status":
        return state.status_payload()
    if req_type == "stop":
        return state.stop(force=bool(request.get("force")))
    if req_type == "enqueue":
        return state.enqueue(request)
    if req_type == "job-list":
        return state.list_jobs(request.get("state"))
    if req_type == "job-status":
        return state.job_status(request.get("ticket"), request.get("requestKey"))
    if req_type == "job-wait":
        timeout = request.get("timeout")
        if timeout is not None and float(timeout) < 0:
            raise ConductorError("wait timeout must be non-negative")
        return state.job_wait(
            request.get("ticket"),
            request.get("requestKey"),
            float(timeout) if timeout is not None else None,
        )
    if req_type == "job-cancel":
        return state.job_cancel(request.get("ticket"), request.get("requestKey"))
    raise ConductorError(f"unknown protocol request type '{req_type}'")


def run_daemon(paths: Paths) -> int:
    ensure_state_dirs(paths)
    with contextlib.suppress(FileNotFoundError):
        paths.socket_path.unlink()
    paths.pid_path.write_text(f"{os.getpid()}\n", encoding="utf-8")
    with contextlib.suppress(OSError):
        os.chmod(paths.pid_path, 0o600)
    write_daemon_metadata(paths)
    paths.running_processes_path.write_text(json.dumps({"updatedAt": now(), "processes": []}, indent=2), encoding="utf-8")
    with contextlib.suppress(OSError):
        os.chmod(paths.running_processes_path, 0o600)
    state = DaemonState(paths)
    server = ThreadedUnixServer(str(paths.socket_path), RequestHandler, state)
    with contextlib.suppress(OSError):
        os.chmod(paths.socket_path, 0o600)
    state.server = server

    def _signal_stop(signum: int, _frame: Any) -> None:
        with state.condition:
            state.shutdown_requested = True
            for job in state.jobs.values():
                if job.state == "running":
                    job.cancel_requested = True
                    state._terminate_process_group_locked(job, reason=f"signal {signum}")
            state.condition.notify_all()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _signal_stop)
    signal.signal(signal.SIGINT, _signal_stop)
    try:
        server.serve_forever(poll_interval=0.2)
    finally:
        server.server_close()
        metadata = read_daemon_metadata(paths)
        owns_daemon_files = read_pid(paths.pid_path) == os.getpid() and metadata.get("pid") == os.getpid()
        if owns_daemon_files:
            for path in (paths.socket_path, paths.pid_path, paths.daemon_meta_path, paths.running_processes_path):
                with contextlib.suppress(FileNotFoundError):
                    path.unlink()
    return 0


def format_argv(argv: Sequence[str]) -> str:
    import shlex

    return " ".join(shlex.quote(part) for part in argv)


def request_daemon(paths: Paths, payload: Dict[str, Any], timeout: Optional[float] = None) -> Dict[str, Any]:
    request = dict(payload)
    request.setdefault("id", str(uuid.uuid4()))
    data = (json.dumps(request) + "\n").encode("utf-8")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(timeout or 30.0)
        sock.connect(str(paths.socket_path))
        sock.sendall(data)
        file = sock.makefile("rb")
        line = file.readline()
        if not line:
            raise ConductorError("daemon closed connection without a response")
        response = json.loads(line.decode("utf-8"))
    except (FileNotFoundError, ConnectionRefusedError, socket.timeout, OSError) as exc:
        raise ConductorError(f"could not contact daemon at {paths.socket_path}: {exc}")
    finally:
        sock.close()
    if not response.get("ok"):
        raise ConductorError(response.get("error") or "daemon request failed")
    return response.get("payload") or {}


def compatible_daemon_status_or_stop_idle_mismatch(paths: Paths) -> Tuple[Optional[Dict[str, Any]], Optional[ConductorError]]:
    try:
        payload = request_daemon(paths, {"type": "status"}, timeout=1.0)
    except ConductorError as exc:
        return None, exc

    protocol = payload.get("protocolVersion")
    if protocol == PROTOCOL_VERSION:
        return payload, None

    active = payload.get("runningJobs") or []
    queued = payload.get("queuedJobs") or []
    if active or queued:
        raise ConductorError(
            f"daemon protocol mismatch (daemon={protocol}, client={PROTOCOL_VERSION}) and jobs are active; "
            "run './conductor daemon stop --force' after deciding it is safe"
        )
    try:
        request_daemon(paths, {"type": "stop", "force": False}, timeout=FORCE_STOP_RPC_TIMEOUT_SECONDS)
    except ConductorError as exc:
        raise ConductorError(
            f"daemon protocol mismatch (daemon={protocol}, client={PROTOCOL_VERSION}) could not stop without force; "
            "jobs may have become active. Run './conductor daemon stop --force' after deciding it is safe"
        ) from exc
    if not wait_until_stopped(paths, timeout=TERMINATE_GRACE_SECONDS + 5.0):
        raise ConductorError(
            f"daemon protocol mismatch (daemon={protocol}, client={PROTOCOL_VERSION}) did not stop cleanly; "
            "run './conductor daemon stop --force' after deciding it is safe"
        )
    return None, None


def ensure_daemon(paths: Paths, start_if_needed: bool = True) -> Dict[str, Any]:
    ensure_state_dirs(paths)
    cleanup_stale_files(paths)
    contact_error: Optional[ConductorError] = None
    payload, contact_error = compatible_daemon_status_or_stop_idle_mismatch(paths)
    if payload is not None:
        return payload

    live_pid = read_pid(paths.pid_path)
    if contact_error and live_pid and pid_alive(live_pid):
        raise ConductorError(
            f"daemon pid {live_pid} is alive but the socket is unresponsive; "
            "run './conductor daemon stop --force' before starting a replacement"
        )

    if not start_if_needed:
        if contact_error:
            raise contact_error
        raise ConductorError("daemon is not running")

    with paths.lock_path.open("a+") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        cleanup_stale_files(paths)
        payload, locked_contact_error = compatible_daemon_status_or_stop_idle_mismatch(paths)
        if payload is not None:
            return payload
        locked_live_pid = read_pid(paths.pid_path)
        if locked_contact_error and locked_live_pid and pid_alive(locked_live_pid):
            raise ConductorError(
                f"daemon pid {locked_live_pid} is alive but the socket is unresponsive; "
                "run './conductor daemon stop --force' before starting a replacement"
            )
        script = Path(__file__).resolve()
        with paths.daemon_log_path.open("ab") as daemon_log:
            proc = subprocess.Popen(
                [sys.executable, str(script), "__daemon", "--repo-root", str(paths.repo_root)],
                cwd=str(paths.repo_root),
                stdin=subprocess.DEVNULL,
                stdout=daemon_log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
        deadline = now() + STARTUP_TIMEOUT_SECONDS
        last_error: Optional[Exception] = None
        while now() < deadline:
            if proc.poll() is not None:
                break
            try:
                return request_daemon(paths, {"type": "status"}, timeout=0.5)
            except Exception as exc:  # wait until socket accepts
                last_error = exc
                time.sleep(0.1)
        raise ConductorError(
            f"daemon did not start within {STARTUP_TIMEOUT_SECONDS:.1f}s; "
            f"see {paths.daemon_log_path}" + (f" ({last_error})" if last_error else "")
        )


def wait_until_stopped(paths: Paths, timeout: float) -> bool:
    deadline = now() + timeout
    while now() < deadline:
        cleanup_stale_files(paths)
        if not paths.socket_path.exists() and not paths.pid_path.exists():
            return True
        time.sleep(0.1)
    return False


def read_running_processes(paths: Paths) -> List[Dict[str, Any]]:
    try:
        payload = json.loads(paths.running_processes_path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return []
    processes = payload.get("processes") if isinstance(payload, dict) else None
    return [item for item in processes if isinstance(item, dict)] if isinstance(processes, list) else []


def signal_running_process_groups(paths: Paths, sig: signal.Signals) -> None:
    for item in read_running_processes(paths):
        pgid = item.get("pgid") or item.get("pid")
        try:
            pgid_int = int(pgid)
        except (TypeError, ValueError):
            continue
        if pgid_int <= 0:
            continue
        with contextlib.suppress(ProcessLookupError, PermissionError, OSError):
            os.killpg(pgid_int, sig)


def force_stop_unresponsive_daemon(paths: Paths) -> Dict[str, Any]:
    pid = read_pid(paths.pid_path)
    if not pid or not pid_alive(pid):
        cleanup_stale_files(paths)
        return {"stopped": True, "pid": pid, "forced": True, "message": "no live daemon pid"}
    if not verify_daemon_pid_identity(paths, pid):
        raise ConductorError(
            f"refusing to force-stop pid {pid}: daemon identity could not be verified; "
            f"inspect {paths.pid_path} and {paths.daemon_meta_path} before removing stale files manually"
        )
    signal_running_process_groups(paths, signal.SIGTERM)
    with contextlib.suppress(ProcessLookupError, PermissionError, OSError):
        os.kill(pid, signal.SIGTERM)
    deadline = now() + TERMINATE_GRACE_SECONDS
    while pid_alive(pid) and now() < deadline:
        time.sleep(0.1)
    if pid_alive(pid):
        signal_running_process_groups(paths, signal.SIGKILL)
        with contextlib.suppress(ProcessLookupError, PermissionError, OSError):
            os.kill(pid, signal.SIGKILL)
        deadline = now() + 2.0
        while pid_alive(pid) and now() < deadline:
            time.sleep(0.1)
    if pid_alive(pid):
        raise ConductorError(f"force-stop signaled verified daemon pid {pid}, but it is still alive; leaving pid/socket files intact")
    cleanup_stale_files(paths)
    with contextlib.suppress(FileNotFoundError):
        paths.socket_path.unlink()
    with contextlib.suppress(FileNotFoundError):
        paths.pid_path.unlink()
    with contextlib.suppress(FileNotFoundError):
        paths.daemon_meta_path.unlink()
    with contextlib.suppress(FileNotFoundError):
        paths.running_processes_path.unlink()
    return {"stopped": True, "pid": pid, "forced": True, "socketPath": str(paths.socket_path), "stateDir": str(paths.state_dir)}


def parse_json_flag(argv: List[str]) -> Tuple[bool, List[str]]:
    json_mode = False
    remaining: List[str] = []
    for arg in argv:
        if arg == "--json":
            json_mode = True
        else:
            remaining.append(arg)
    return json_mode, remaining


def render_daemon_status(payload: Dict[str, Any], shorthand: bool = False) -> None:
    print(f"conductor daemon running (pid {payload.get('pid')})")
    print(f"protocol: {payload.get('protocolVersion')}")
    print(f"socket:   {payload.get('socketPath')}")
    print(f"state:    {payload.get('stateDir')}")
    active = payload.get("activeJobsByLane") or {}
    if active:
        print("active lanes:")
        for lane, job in active.items():
            run_for = None
            if job.get("startedAt"):
                run_for = max(0.0, now() - float(job.get("startedAt")))
            timing = f" run={format_duration(run_for)}" if run_for is not None else ""
            global_wait = job.get("globalHeavySlotWaitSeconds")
            if global_wait is not None:
                timing += f" global-wait={format_duration(float(global_wait))}"
            print(f"  {lane}: {job.get('ticket')} {job.get('operationLabel') or job.get('operation')} [{job.get('state')}]{timing}")
    else:
        print("active lanes: none")
    print(f"queued:   {payload.get('queueDepth', 0)}")
    print(f"retained terminal jobs: {payload.get('retainedTerminalCount', 0)}")
    if shorthand and payload.get("queuedJobs"):
        print("queued jobs:")
        for job in payload.get("queuedJobs") or []:
            queued_for = None
            if job.get("createdAt"):
                queued_for = max(0.0, now() - float(job.get("createdAt")))
            timing = f" queued={format_duration(queued_for)}" if queued_for is not None else ""
            print(f"  {job.get('ticket')} {job.get('operationLabel') or job.get('operation')} lanes={','.join(job.get('lanes') or [])}{timing}")


def render_superseded_jobs(payload: Dict[str, Any]) -> None:
    for job in payload.get("supersededJobs") or []:
        action = "Canceled" if job.get("cancellationState") == "canceled" else "Canceling"
        print(
            f"{action} older live-app work: {job.get('operationLabel')} {job.get('ticket')} "
            f"({job.get('priorState')})."
        )


def select_progress_lines(operation: str, lines: Sequence[str]) -> List[str]:
    selected: List[str] = []
    style_operation = operation in {"format", "format-check", "lint", "check-format-tools", "install-format-tools", "format-tools-status"}
    for raw_line in lines:
        line = clean_summary_line(str(raw_line))
        if not line:
            continue
        allowed = False
        if OutputSummarizer.PHASE_RE.search(line) or OutputSummarizer.ARTIFACT_RE.search(line) or OutputSummarizer.APP_LIFECYCLE_RE.search(line):
            allowed = True
        elif OutputSummarizer.TIMEOUT_RE.search(line) or OutputSummarizer.FAILURE_RE.search(line):
            allowed = True
        elif OutputSummarizer.TEST_FAILURE_RE.search(line) or OutputSummarizer.SWIFT_ERROR_RE.search(line):
            allowed = True
        elif style_operation and OutputSummarizer.STYLE_FINDING_RE.search(line):
            allowed = True
        if allowed:
            selected.append(line)
        if len(selected) >= PROGRESS_MAX_LINES_PER_POLL:
            break
    return selected


def output_summary_for_payload(payload: Dict[str, Any]) -> Dict[str, Any]:
    summary = payload.get("outputSummary")
    label = payload.get("operationLabel") or operation_display_name(str(payload.get("operation") or ""), payload.get("args") or {})
    requires_lifecycle_classification = label == "app relaunch" and payload.get("state") == "failed"
    if isinstance(summary, dict) and (not requires_lifecycle_classification or isinstance(summary.get("launchLifecycle"), dict)):
        return summary
    log_path = payload.get("logPath")
    if log_path:
        return OutputSummarizer.summarize_file(
            str(payload.get("operation") or ""),
            payload.get("args") or {},
            str(payload.get("state") or ""),
            payload.get("exitCode"),
            bool(payload.get("timedOut")),
            Path(str(log_path)),
        )
    return OutputSummarizer._minimal_summary(
        str(payload.get("operation") or ""),
        str(payload.get("state") or ""),
        payload.get("exitCode"),
        "no log path available for summary",
    )


def payload_with_output_summary(payload: Dict[str, Any], include_log_tail: bool = False) -> Dict[str, Any]:
    if payload.get("state") not in TERMINAL_STATES:
        return payload
    existing_summary = payload.get("outputSummary")
    label = payload.get("operationLabel") or operation_display_name(str(payload.get("operation") or ""), payload.get("args") or {})
    needs_lifecycle_classification = label == "app relaunch" and payload.get("state") == "failed"
    needs_summary = not isinstance(existing_summary, dict) or (
        needs_lifecycle_classification and not isinstance(existing_summary.get("launchLifecycle"), dict)
    )
    tail = payload.get("logTail")
    needs_tail_trim = include_log_tail and isinstance(tail, list) and len(tail) > LOG_TAIL_LINES
    has_tail = "logTail" in payload
    should_drop_tail = has_tail and not include_log_tail
    if not needs_summary and not needs_tail_trim and not should_drop_tail:
        return payload
    enriched = dict(payload)
    if needs_summary:
        enriched["outputSummary"] = output_summary_for_payload(enriched)
    if include_log_tail:
        if needs_tail_trim:
            enriched["logTail"] = tail[-LOG_TAIL_LINES:]
    elif isinstance(enriched.get("outputSummary"), dict):
        enriched.pop("logTail", None)
    return enriched


def print_job_result_header(payload: Dict[str, Any], summary: Optional[Dict[str, Any]] = None) -> None:
    summary = summary or output_summary_for_payload(payload)
    print(f"Result:   {summary.get('headline') or payload.get('resultSummary') or payload.get('state')}")
    print(f"Ticket:   {payload.get('ticket')}")
    if payload.get("requestKey"):
        print(f"Request:  {payload.get('requestKey')}")
    label = payload.get("operationLabel") or operation_display_name(str(payload.get("operation") or ""), payload.get("args") or {})
    print(f"Operation:{' ' if label else ''}{label}")
    print(f"State:    {payload.get('state')}")
    if payload.get("exitCode") is not None:
        print(f"Exit:     {payload.get('exitCode')}")
    print(f"Log:      {payload.get('logPath')}")
    timing_parts: List[str] = []
    if payload.get("queueWaitSeconds") is not None:
        timing_parts.append(f"queue={format_duration(float(payload.get('queueWaitSeconds')))}")
    if payload.get("executionSeconds") is not None:
        timing_parts.append(f"exec={format_duration(float(payload.get('executionSeconds')))}")
    if payload.get("globalHeavySlotWaitSeconds") is not None:
        timing_parts.append(f"global-wait={format_duration(float(payload.get('globalHeavySlotWaitSeconds')))}")
    if timing_parts:
        print(f"Timing:   {', '.join(timing_parts)}")
    if payload.get("error"):
        print(f"Error:    {payload.get('error')}")


def render_output_summary(summary: Dict[str, Any]) -> None:
    sections = summary.get("sections") or []
    for section in sections:
        title = section.get("title") or "Summary"
        lines = section.get("lines") or []
        if not lines:
            continue
        print()
        print(f"{title}:")
        for line in lines:
            print(f"  {line}")
        if section.get("truncated"):
            omitted = int(section.get("omittedLineCount") or 0)
            print(f"  ... omitted {omitted} matching line(s); see full log path above")
    if summary.get("truncated"):
        print()
        print("Summary truncated; see full log for complete output.")


def lifecycle_outcome_lines(payload: Dict[str, Any], summary: Dict[str, Any]) -> List[str]:
    label = payload.get("operationLabel") or operation_display_name(str(payload.get("operation") or ""), payload.get("args") or {})
    state = payload.get("state")
    if label not in {"app relaunch", "app stop"}:
        return []
    if state == "canceled":
        replacement = payload.get("supersededByOperation")
        replacement_ticket = payload.get("supersededByTicket")
        subject = "relaunch" if label == "app relaunch" else "stop"
        if replacement:
            ticket_detail = f" (ticket {replacement_ticket})" if replacement_ticket else ""
            return [f"This app {subject} ticket was superseded by newer {replacement} intent{ticket_detail}."]
        return [f"This app {subject} ticket was canceled before completion."]
    if label != "app relaunch" or state != "failed":
        return []
    lifecycle = summary.get("launchLifecycle")
    if not isinstance(lifecycle, dict):
        return [
            "Relaunch failed, but lifecycle phase information is unavailable from this job log.",
            "Check app status before retrying.",
        ]
    if lifecycle.get("transitionStarted"):
        return [
            "Relaunch failed after this ticket began app stop/open lifecycle work; app state may have changed.",
            "Check app status before retrying.",
        ]
    lines = [
        "Rebuild/package failed before this relaunch ticket reached app stop/open.",
        "This ticket did not stop or reopen RepoPrompt.",
    ]
    if lifecycle.get("sourceChangedDuringBuild"):
        lines.extend(
            [
                "The compiler reported that source files changed during the build.",
                "Daemon lanes do not prevent external/direct source edits; retry after edits settle.",
            ]
        )
    return lines


def render_lifecycle_outcome(payload: Dict[str, Any], summary: Dict[str, Any]) -> None:
    lines = lifecycle_outcome_lines(payload, summary)
    if not lines:
        return
    print()
    print("Outcome:")
    for line in lines:
        print(f"  {line}")


def print_full_log(payload: Dict[str, Any]) -> None:
    log_path = payload.get("logPath")
    if not log_path:
        return
    print()
    print(f"--- raw log: {log_path} ---")
    try:
        with open(log_path, "r", encoding="utf-8", errors="replace") as handle:
            content = handle.read()
            print(content, end="")
            if content and not content.endswith("\n"):
                print()
    except OSError as exc:
        print(f"(could not read log: {exc})")
        tail = payload.get("logTail") or []
        if tail:
            print("--- log tail fallback ---")
            print("".join(tail), end="")
            if not str(tail[-1]).endswith("\n"):
                print()


def print_terminal_job_output(payload: Dict[str, Any], output_mode: str = "summary") -> None:
    summary = output_summary_for_payload(payload)
    print_job_result_header(payload, summary=summary)
    render_lifecycle_outcome(payload, summary)
    if output_mode == "full":
        print_full_log(payload)
        return
    render_output_summary(summary)


def render_job(job: Dict[str, Any], output_mode: str = "summary", include_tail: bool = True) -> None:
    if job.get("state") in TERMINAL_STATES:
        print_terminal_job_output(job, output_mode=output_mode)
        return
    print(f"ticket:    {job.get('ticket')}")
    if job.get("requestKey"):
        print(f"request:   {job.get('requestKey')}")
    print(f"operation: {job.get('operationLabel') or job.get('operation')}")
    print(f"state:     {job.get('state')}")
    print(f"lanes:     {', '.join(job.get('lanes') or []) or 'none'}")
    timing_parts: List[str] = []
    if job.get("createdAt"):
        timing_parts.append(f"queued={format_duration(max(0.0, now() - float(job.get('createdAt'))))}")
    if job.get("startedAt"):
        timing_parts.append(f"running={format_duration(max(0.0, now() - float(job.get('startedAt'))))}")
    if job.get("globalHeavySlotWaitSeconds") is not None:
        timing_parts.append(f"global-wait={format_duration(float(job.get('globalHeavySlotWaitSeconds')))}")
    if timing_parts:
        print(f"timing:    {', '.join(timing_parts)}")
    if job.get("globalHeavySlotPath") and job.get("state") == "running":
        print(f"heavy:     {job.get('globalHeavySlotPath')}")
    if job.get("globalHeavySlotHolder") and job.get("state") == "running":
        print(f"holder:    {job.get('globalHeavySlotHolder')}")
    print(f"log:       {job.get('logPath')}")
    if job.get("startedAtISO"):
        print(f"started:   {job.get('startedAtISO')}")
    if job.get("resultSummary"):
        print(f"result:    {job.get('resultSummary')}")
    if job.get("error"):
        print(f"error:     {job.get('error')}")
    if include_tail and job.get("logTail"):
        if output_mode == "full":
            print("--- log tail ---")
            print("".join(job.get("logTail") or []), end="")
            if not str(job.get("logTail")[-1]).endswith("\n"):
                print()
        else:
            noteworthy = select_progress_lines(str(job.get("operation") or ""), job.get("logTail") or [])
            if noteworthy:
                print("--- noteworthy recent output ---")
                for line in noteworthy:
                    print(line)


def handle_daemon_command(paths: Paths, argv: List[str]) -> int:
    if not argv or argv[0] in {"-h", "--help"}:
        print("Usage: ./conductor daemon start|status|stop [--force] [--json]")
        return 0
    sub = argv[0]
    json_mode, rest = parse_json_flag(argv[1:])
    if sub == "start":
        payload = ensure_daemon(paths, start_if_needed=True)
        if json_mode:
            print_json(payload)
        else:
            print("daemon running")
            render_daemon_status(payload)
        return 0
    if sub == "status":
        try:
            payload = ensure_daemon(paths, start_if_needed=False)
        except ConductorError as exc:
            if json_mode:
                print_json({"running": False, "error": str(exc), "socketPath": str(paths.socket_path), "stateDir": str(paths.state_dir)})
            else:
                print(f"daemon not running: {exc}")
            return 1
        if json_mode:
            print_json(payload)
        else:
            render_daemon_status(payload)
        return 0
    if sub == "stop":
        force = False
        for arg in rest:
            if arg == "--force":
                force = True
            else:
                raise ConductorError(f"unknown daemon stop option '{arg}'")
        try:
            payload = request_daemon(
                paths,
                {"type": "stop", "force": force},
                timeout=FORCE_STOP_RPC_TIMEOUT_SECONDS if force else 5.0,
            )
            stopped = wait_until_stopped(paths, timeout=(TERMINATE_GRACE_SECONDS + 5.0) if force else 5.0)
            if force and not stopped:
                payload = force_stop_unresponsive_daemon(paths)
        except ConductorError:
            if not force:
                raise
            payload = force_stop_unresponsive_daemon(paths)
        if json_mode:
            print_json(payload)
        else:
            print("daemon stopping" if not payload.get("forced") else "daemon force-stopped")
        return 0
    raise ConductorError(f"unknown daemon command '{sub}'")


def handle_status_command(paths: Paths, argv: List[str]) -> int:
    json_mode, rest = parse_json_flag(argv)
    if rest:
        raise ConductorError(f"unknown status option(s): {' '.join(rest)}")
    try:
        payload = ensure_daemon(paths, start_if_needed=False)
    except ConductorError as exc:
        if json_mode:
            print_json({"running": False, "error": str(exc), "socketPath": str(paths.socket_path), "stateDir": str(paths.state_dir)})
        else:
            print("conductor daemon not running")
            print(f"socket: {paths.socket_path}")
            print("start with: ./conductor daemon start")
        return 1
    if json_mode:
        print_json(payload)
    else:
        render_daemon_status(payload, shorthand=True)
    return 0


def handle_job_command(paths: Paths, argv: List[str]) -> int:
    if not argv or argv[0] in {"-h", "--help"}:
        print("Usage: ./conductor job list|status|wait|cancel ...")
        return 0
    ensure_daemon(paths, start_if_needed=False)
    sub = argv[0]
    parser = argparse.ArgumentParser(prog=f"conductor job {sub}", add_help=True)
    parser.add_argument("--json", action="store_true", help="machine-readable output; includes logPath, not raw full logs")
    if sub in {"status", "wait"}:
        parser.add_argument(
            "--full-log",
            action="store_true",
            help="human output only: render the raw full job log instead of the concise summary",
        )

    if sub == "list":
        parser.add_argument("--state", choices=sorted(["queued", "running", "completed", "failed", "canceled"]))
        ns = parser.parse_args(argv[1:])
        payload = request_daemon(paths, {"type": "job-list", "state": ns.state}, timeout=5.0)
        if ns.json:
            print_json(payload)
        else:
            jobs = payload.get("jobs") or []
            if not jobs:
                print("no retained jobs")
            for job in jobs:
                print(f"{job.get('ticket')} {job.get('state')} {job.get('operationLabel') or job.get('operation')} lanes={','.join(job.get('lanes') or []) or 'none'}")
        return 0

    if sub in {"status", "wait", "cancel"}:
        parser.add_argument("ticket", nargs="?")
        parser.add_argument("--request-key")
        if sub == "wait":
            parser.add_argument("--timeout", type=float)
        ns = parser.parse_args(argv[1:])
        if getattr(ns, "json", False) and getattr(ns, "full_log", False):
            raise ConductorError("--full-log is only supported for human output; JSON output includes logPath instead")
        if bool(ns.ticket) == bool(ns.request_key):
            raise ConductorError("provide exactly one of <ticket> or --request-key <key>")
        req: Dict[str, Any] = {
            "type": {"status": "job-status", "wait": "job-wait", "cancel": "job-cancel"}[sub],
            "ticket": ns.ticket,
            "requestKey": ns.request_key,
        }
        if sub == "wait":
            if ns.timeout is not None and ns.timeout < 0:
                raise ConductorError("wait timeout must be non-negative")
            if ns.timeout is None:
                output_mode = "full" if getattr(ns, "full_log", False) else "summary"
                payload = wait_for_terminal(paths, ns.ticket, ns.request_key, json_mode=ns.json, output_mode=output_mode)
            else:
                req["timeout"] = ns.timeout
                payload = request_daemon(paths, req, timeout=ns.timeout + 5.0)
        else:
            payload = request_daemon(paths, req, timeout=10.0)
        if ns.json:
            print_json(payload_with_output_summary(payload))
        else:
            render_job(payload, output_mode="full" if getattr(ns, "full_log", False) else "summary")
            if payload.get("waitTimedOut"):
                print("wait timed out before job reached a terminal state")
        if sub == "wait" and payload.get("waitTimedOut"):
            return 124
        return terminal_exit_code(payload) if sub == "wait" and payload.get("state") in TERMINAL_STATES else 0

    raise ConductorError(f"unknown job command '{sub}'")


def split_operation_flags(argv: List[str]) -> Tuple[argparse.Namespace, List[str]]:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--async", dest="async_mode", action="store_true")
    parser.add_argument("--request-key")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--timeout", type=float)
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--full-log", action="store_true")
    known, rest = parser.parse_known_args(argv)
    if known.json and known.full_log:
        raise ConductorError("--full-log is only supported for human output; JSON output includes logPath instead")
    if known.async_mode and known.full_log:
        raise ConductorError("--full-log requires synchronous human output; use './conductor job wait <ticket> --full-log' for async jobs")
    return known, rest


def handle_sleep_operation(paths: Paths, operation: str, argv: List[str]) -> int:
    global_flags, rest = split_operation_flags(argv)
    parser = argparse.ArgumentParser(prog=f"conductor {operation}")
    parser.add_argument("seconds", type=float)
    parser.add_argument("--lane", action="append", default=[])
    parser.add_argument("--message", default="conductor sleep")
    parser.add_argument("--exit-code", type=int, default=0)
    ns = parser.parse_args(rest)
    if global_flags.timeout is not None and global_flags.timeout < 0:
        raise ConductorError("timeout must be non-negative")

    lanes: List[str] = []
    for lane_arg in ns.lane:
        lanes.extend([part for part in lane_arg.split(",") if part])
    invalid_lanes = [lane for lane in lanes if lane not in LANE_NAMES]
    if invalid_lanes:
        raise ConductorError(f"unknown lane(s): {', '.join(invalid_lanes)}")

    ensure_daemon(paths, start_if_needed=True)
    request = {
        "type": "enqueue",
        "operation": operation,
        "args": {
            "seconds": ns.seconds,
            "lanes": lanes,
            "message": ns.message,
            "exitCode": ns.exit_code,
        },
        "requestKey": global_flags.request_key,
        "timeout": global_flags.timeout,
        "verbose": global_flags.verbose,
        "env": OperationRegistry.client_env_snapshot(),
    }
    enqueue_payload = request_daemon(paths, request, timeout=10.0)
    if global_flags.async_mode:
        if global_flags.json:
            print_json(enqueue_payload)
        else:
            print(f"ticket: {enqueue_payload.get('ticket')}")
            print(f"state:  {enqueue_payload.get('state')}")
            print(f"lanes:  {', '.join(enqueue_payload.get('lanes') or []) or 'none'}")
            print(f"log:    {enqueue_payload.get('logPath')}")
            if enqueue_payload.get("reused"):
                print("reused existing queued/running job for request key")
            render_superseded_jobs(enqueue_payload)
            print(f"wait:   ./conductor job wait {enqueue_payload.get('ticket')}")
        return 0

    ticket = enqueue_payload.get("ticket")
    if global_flags.json:
        final = payload_with_output_summary(wait_for_terminal(paths, ticket, request_key=None, json_mode=True))
        print_json({"enqueue": enqueue_payload, "result": final})
        return terminal_exit_code(final)

    print(f"ticket: {ticket}")
    print(f"log:    {enqueue_payload.get('logPath')}")
    print(f"reconnect: ./conductor job wait {ticket}")
    render_superseded_jobs(enqueue_payload)
    output_mode = "full" if global_flags.full_log else "summary"
    final_payload = wait_for_terminal(paths, ticket, request_key=None, json_mode=False, output_mode=output_mode)
    print_terminal_job_output(final_payload, output_mode=output_mode)
    return terminal_exit_code(final_payload)


def wait_for_terminal(
    paths: Paths,
    ticket: Optional[str],
    request_key: Optional[str],
    json_mode: bool,
    output_mode: str = "summary",
) -> Dict[str, Any]:
    last_state: Optional[str] = None
    last_tail: List[str] = []
    last_blockers: Optional[Tuple[Tuple[str, ...], ...]] = None
    printed_progress: Deque[str] = deque(maxlen=200)
    printed_progress_set: set[str] = set()
    last_progress_at = now()
    while True:
        payload = request_daemon(
            paths,
            {"type": "job-wait", "ticket": ticket, "requestKey": request_key, "timeout": WAIT_POLL_SECONDS},
            timeout=WAIT_POLL_SECONDS + 5.0,
        )
        if not json_mode:
            state = payload.get("state")
            tail = payload.get("logTail") or []
            if state != last_state:
                print(f"[{time.strftime('%H:%M:%S')}] state: {state}")
                last_state = state
            blockers = payload.get("blockedBy") or [] if state == "queued" else []
            blocker_signature = tuple(
                (str(item.get("ticket")), str(item.get("operationLabel")), ",".join(item.get("conflictingLanes") or []), str(item.get("cancelRequested")))
                for item in blockers
            )
            if state == "queued" and blockers and blocker_signature != last_blockers:
                for blocker in blockers:
                    lanes = ",".join(blocker.get("conflictingLanes") or [])
                    cancellation = " (cancellation requested)" if blocker.get("cancelRequested") else ""
                    print(
                        f"Waiting to begin {payload.get('operationLabel') or payload.get('operation')}; "
                        f"blocked by {blocker.get('operationLabel')} {blocker.get('ticket')} on {lanes}{cancellation}."
                    )
                last_blockers = blocker_signature
            if tail != last_tail and state not in TERMINAL_STATES:
                new_lines = tail[len(last_tail) :] if len(tail) >= len(last_tail) and tail[: len(last_tail)] == last_tail else tail[-5:]
                if output_mode == "full":
                    for line in new_lines:
                        print(line, end="")
                    if new_lines:
                        last_progress_at = now()
                else:
                    for line in select_progress_lines(str(payload.get("operation") or ""), new_lines):
                        if line in printed_progress_set:
                            continue
                        print(line)
                        printed_progress.append(line)
                        printed_progress_set.add(line)
                        while len(printed_progress_set) > len(printed_progress):
                            printed_progress_set = set(printed_progress)
                        last_progress_at = now()
                last_tail = tail
            if state not in TERMINAL_STATES and output_mode != "full" and now() - last_progress_at >= PROGRESS_HEARTBEAT_SECONDS:
                print(f"[{time.strftime('%H:%M:%S')}] still running; log: {payload.get('logPath')}")
                last_progress_at = now()
        if payload.get("state") in TERMINAL_STATES:
            return payload


def run_operation_command(
    name: str,
    argv: Sequence[str],
    cwd: Path,
    env: Optional[Dict[str, str]] = None,
    allow_exit_codes: Optional[set[int]] = None,
    timeout: Optional[float] = None,
) -> Tuple[int, str, str]:
    allowed = allow_exit_codes if allow_exit_codes is not None else {0}
    print(f"\n==> {name}", flush=True)
    print(f"$ {format_argv(argv)}", flush=True)
    try:
        completed = subprocess.run(
            list(argv),
            cwd=str(cwd),
            env=env,
            stdin=subprocess.DEVNULL,
            text=True,
            capture_output=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout or ""
        stderr = exc.stderr or ""
        if isinstance(stdout, bytes):
            stdout = stdout.decode("utf-8", errors="replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode("utf-8", errors="replace")
        print(f"status: timed out after {timeout}s", flush=True)
        _print_captured(stdout, stderr)
        return 124, stdout, stderr
    stdout = completed.stdout or ""
    stderr = completed.stderr or ""
    print(f"status: {completed.returncode}", flush=True)
    _print_captured(stdout, stderr)
    if completed.returncode not in allowed:
        print(f"FAILED stage '{name}' with status {completed.returncode}", flush=True)
    return int(completed.returncode), stdout, stderr


def _print_captured(stdout: str, stderr: str) -> None:
    print("--- stdout ---", flush=True)
    if stdout:
        print(stdout, end="" if stdout.endswith("\n") else "\n", flush=True)
    print("--- stderr ---", flush=True)
    if stderr:
        print(stderr, end="" if stderr.endswith("\n") else "\n", flush=True)


def is_already_on_workspace(stderr: str, workspace: str) -> bool:
    lines = [line.strip() for line in stderr.splitlines() if line.strip()]
    expected = f'Already on workspace "{workspace}"'
    return expected in lines or f"Error: [-32600] Invalid Request: {expected}." in lines


def routed_structured_cli_argv(cli: str, window_id: int, command: str, payload: Dict[str, Any]) -> List[str]:
    routed_payload = dict(payload)
    routed_payload["_windowID"] = window_id
    return [cli, "-w", str(window_id), "-c", command, "-j", json.dumps(routed_payload)]


def resolve_debug_cli() -> Optional[str]:
    install_override = os.environ.get("REPOPROMPT_DEBUG_CLI_INSTALL_PATH")
    if install_override:
        override_path = Path(install_override).expanduser()
        if override_path.is_file() and os.access(override_path, os.X_OK):
            return str(override_path)
    path_cli = shutil.which("rpce-cli-debug")
    if path_cli and os.access(path_cli, os.X_OK):
        return path_cli
    fallback = Path.home() / "Library" / "Application Support" / "RepoPrompt CE" / "repoprompt_ce_cli_debug"
    if fallback.is_file() and os.access(fallback, os.X_OK):
        return str(fallback)
    bundled = debug_app_bundle_path() / "Contents" / "MacOS" / "repoprompt-mcp"
    if bundled.is_file() and os.access(bundled, os.X_OK):
        return str(bundled)
    return None


def resolve_embedded_helper(app_bundle: Path) -> str:
    app = app_bundle.expanduser().resolve(strict=True)
    candidate = app / "Contents" / "MacOS" / "repoprompt-mcp"
    if candidate.is_symlink():
        raise ConductorError(f"embedded MCP helper must not be a symlink: {candidate}")
    helper = candidate.resolve(strict=True)
    try:
        helper.relative_to(app)
    except ValueError as exc:
        raise ConductorError(f"embedded MCP helper escapes launched app bundle: {helper}") from exc
    if not helper.is_file() or not os.access(helper, os.X_OK):
        raise ConductorError(f"embedded MCP helper is not an executable regular file: {helper}")
    return str(helper)


def require_debug_cli() -> Optional[str]:
    cli = resolve_debug_cli()
    if cli:
        print(f"Resolved rpce-cli-debug: {cli}", flush=True)
        return cli
    print("ERROR: rpce-cli-debug was not found via REPOPROMPT_DEBUG_CLI_INSTALL_PATH, PATH, user-space fallback, or the debug app bundle.", flush=True)
    print("Install it with:", flush=True)
    print("  make install-debug-cli", flush=True)
    print("  # or", flush=True)
    print("  ./conductor install-debug-cli", flush=True)
    return None


def find_session_id(obj: Any) -> Optional[str]:
    if isinstance(obj, dict):
        value = obj.get("session_id") or obj.get("sessionId")
        if isinstance(value, str) and value:
            return value
        for child in obj.values():
            found = find_session_id(child)
            if found:
                return found
    elif isinstance(obj, list):
        for child in obj:
            found = find_session_id(child)
            if found:
                return found
    return None


def find_session_id_in_text(text: str) -> Optional[str]:
    match = re.search(r"(?im)^\s*-?\s*Session ID:\s*`?([A-F0-9-]+)`?\s*$", text)
    return match.group(1) if match else None


def debug_app_bundle_path() -> Path:
    # Mirrors Scripts/run.sh path resolution so app status reports the same bundle that run delegates launch.
    root = os.environ.get(
        "REPOPROMPT_DEBUG_APP_ROOT",
        str(Path.home() / "Library" / "Application Support" / "RepoPrompt CE" / "DebugApps"),
    )
    return Path(os.environ.get("REPOPROMPT_DEBUG_APP_BUNDLE", str(Path(root) / "RepoPrompt.app")))


def debug_app_executable_path() -> Path:
    return debug_app_bundle_path() / "Contents" / "MacOS" / "RepoPrompt"


def find_debug_app_pids() -> List[str]:
    return [str(pid) for pid in matching_processes(debug_app_executable_path())]


def terminate_debug_app_processes() -> List[str]:
    return [str(pid) for pid in terminate_matching_processes(debug_app_executable_path())]


def debug_app_provenance_path(bundle: Path) -> Path:
    return bundle / DEBUG_APP_PROVENANCE_RELATIVE_PATH


def read_debug_app_provenance(bundle: Path) -> Optional[Dict[str, Any]]:
    path = debug_app_provenance_path(bundle)
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return None
    return payload if isinstance(payload, dict) else None


def git_metadata_value(repo_root: Path, args: Sequence[str]) -> Optional[str]:
    try:
        completed = subprocess.run(
            ["git", "-C", str(repo_root), *args],
            text=True,
            capture_output=True,
            timeout=2.0,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if completed.returncode != 0:
        return None
    value = completed.stdout.strip()
    return value or None


def current_repo_commit(repo_root: Path) -> Optional[str]:
    return git_metadata_value(repo_root, ["rev-parse", "HEAD"])


def provenance_report_lines(repo_root: Path, bundle: Path) -> List[str]:
    provenance = read_debug_app_provenance(bundle)
    if not provenance:
        return ["  Bundle provenance: <missing>"]
    lines = ["  Bundle provenance:"]
    repo = str(provenance.get("repoRoot") or "<unknown>")
    worktree = str(provenance.get("worktreePath") or repo)
    branch = str(provenance.get("branch") or "<unknown>")
    commit = str(provenance.get("commit") or "<unknown>")
    dirty = provenance.get("dirty")
    built_at = str(provenance.get("buildTimeISO") or "<unknown>")
    lines.append(f"    repo: {repo}")
    lines.append(f"    worktree: {worktree}")
    lines.append(f"    branch: {branch}")
    lines.append(f"    commit: {commit[:12] if commit != '<unknown>' else commit}")
    lines.append(f"    dirty at build: {dirty if isinstance(dirty, bool) else '<unknown>'}")
    lines.append(f"    built: {built_at}")
    flags: List[str] = []
    try:
        current_root = str(repo_root.resolve())
        built_root = str(Path(repo).resolve(strict=False))
        if built_root != current_root:
            flags.append("foreign worktree")
    except OSError:
        flags.append("foreign worktree unknown")
    current_commit = current_repo_commit(repo_root)
    if current_commit and commit not in {"<unknown>", current_commit}:
        flags.append("stale commit")
    if flags:
        lines.append(f"    WARNING: {'; '.join(flags)}")
    return lines


def print_debug_app_provenance(repo_root: Path, bundle: Path) -> None:
    for line in provenance_report_lines(repo_root, bundle):
        print(line, flush=True)


def report_launch_bundle_details(repo_root: Path, bundle: Path) -> int:
    print(f"Launch app path: {bundle}", flush=True)
    print_debug_app_provenance(repo_root, bundle)
    codesign = subprocess.run(["codesign", "-dv", str(bundle)], text=True, capture_output=True)
    details = (codesign.stdout or "") + (codesign.stderr or "")
    team = "<missing>"
    authorities: List[str] = []
    for line in details.splitlines():
        if line.startswith("TeamIdentifier="):
            team = line.split("=", 1)[1] or "<missing>"
        elif line.startswith("Authority="):
            authorities.append(line.split("=", 1)[1])
    marker = subprocess.run(
        ["plutil", "-extract", "RepoPromptDebugSecureStorageBackend", "raw", "-o", "-", str(bundle / "Contents" / "Info.plist")],
        text=True,
        capture_output=True,
    )
    storage = marker.stdout.strip() if marker.returncode == 0 and marker.stdout.strip() else "<missing>"
    print(f"Launch app team: {team}", flush=True)
    print(f"Launch app signing authorities: {', '.join(authorities) if authorities else '<none/ad-hoc>'}", flush=True)
    print(f"Launch app debug secure storage marker: {storage}", flush=True)
    if storage != "keychain":
        print("WARNING: Debug secure storage is in-memory this run; secrets and permission changes won't persist.", flush=True)
    elif not team or team in {"<missing>", "not set"}:
        print("WARNING: Launching a keychain-marked debug app without a team identifier; runtime will fall back to in-memory secure storage.", flush=True)
    return 0


def wait_for_no_debug_app_process(timeout: float = 5.0) -> bool:
    deadline = now() + timeout
    while now() <= deadline:
        pids = find_debug_app_pids()
        if not pids:
            return True
        time.sleep(APP_STOP_POLL_SECONDS)
    return False


def wait_for_debug_app_process(timeout: float = STARTUP_TIMEOUT_SECONDS) -> List[str]:
    deadline = now() + timeout
    while now() <= deadline:
        pids = find_debug_app_pids()
        if pids:
            return pids
        time.sleep(APP_STOP_POLL_SECONDS)
    return []


def guard_delayed_debug_app_launch() -> int:
    print("Guarding against a delayed RepoPrompt CE debug app launch from superseded app work.", flush=True)
    return _operation_app_stop_unlocked(Path.cwd(), {"guardDelayedLaunch": True})


def _operation_app_stop_unlocked(_repo_root: Path, args: Dict[str, Any]) -> int:
    guard_delayed_launch = bool(args.get("guardDelayedLaunch"))
    required_quiet = APP_STOP_DELAYED_LAUNCH_GUARD_SECONDS if guard_delayed_launch else APP_STOP_QUIET_SECONDS
    confirmation_timeout = APP_STOP_DELAYED_LAUNCH_CONFIRM_TIMEOUT_SECONDS if guard_delayed_launch else APP_STOP_CONFIRM_TIMEOUT_SECONDS
    deadline = now() + confirmation_timeout
    quiet_since: Optional[float] = None
    observed_process = False
    if guard_delayed_launch:
        print("Guarding against a delayed RepoPrompt CE debug app launch from superseded app work.", flush=True)
    while True:
        try:
            pids = find_debug_app_pids()
        except ProcessIdentityError as exc:
            print(f"ERROR: could not safely identify the debug app process: {exc}", flush=True)
            return 1
        if pids:
            observed_process = True
            quiet_since = None
            print(f"Observed running RepoPrompt CE debug PID(s): {', '.join(pids)}", flush=True)
            try:
                terminate_debug_app_processes()
            except ProcessIdentityError as exc:
                print(f"ERROR: refused to signal a process without validated debug app identity: {exc}", flush=True)
                return 1
        else:
            if quiet_since is None:
                quiet_since = now()
            if now() - quiet_since >= required_quiet:
                if observed_process:
                    print("RepoPrompt stop confirmed.", flush=True)
                else:
                    print("RepoPrompt was already stopped; stop confirmed.", flush=True)
                return 0
        if now() >= deadline:
            print("ERROR: timed out confirming that RepoPrompt remained stopped.", flush=True)
            return 1
        time.sleep(APP_STOP_POLL_SECONDS)


def staged_debug_app_parent(live_bundle: Optional[Path] = None) -> Path:
    bundle = live_bundle or debug_app_bundle_path()
    token = f"{int(now() * 1000)}-{os.getpid()}-{uuid.uuid4().hex[:8]}"
    return bundle.parent / ".staging" / token


def cleanup_staged_debug_bundle(staged_bundle: Optional[Path]) -> None:
    if staged_bundle is None:
        return
    parent = staged_bundle.parent
    with contextlib.suppress(FileNotFoundError):
        shutil.rmtree(parent)


def package_debug_app_under_heavy(repo_root: Path, operation_label: str) -> Tuple[int, Optional[Path]]:
    live_bundle = debug_app_bundle_path()
    staging_parent = staged_debug_app_parent(live_bundle)
    staged_bundle = staging_parent / live_bundle.name
    metadata = display_lock_metadata(
        lock_kind="global-heavy",
        ticket=os.environ.get("REPOPROMPT_CONDUCTOR_JOB_TICKET"),
        operation=operation_label,
        operation_label=operation_label,
        repo_root=repo_root,
        repo_hash=None,
    )
    env = os.environ.copy()
    env["REPOPROMPT_DEBUG_APP_BUNDLE"] = str(staged_bundle)
    try:
        with machine_heavy_slot(metadata, env, "global heavy slot for debug package"):
            code, _stdout, _stderr = run_operation_command(
                "package staged debug app",
                [str(repo_root / "Scripts" / "package_app.sh"), "debug"],
                repo_root,
                env=env,
            )
        if code != 0:
            cleanup_staged_debug_bundle(staged_bundle)
            return code, None
        executable = staged_bundle / "Contents" / "MacOS" / "RepoPrompt"
        if not executable.is_file() or not os.access(executable, os.X_OK):
            print(f"ERROR: staged debug app is not launchable: {staged_bundle}", flush=True)
            cleanup_staged_debug_bundle(staged_bundle)
            return 1, None
        print(f"Staged debug app bundle: {staged_bundle}", flush=True)
        return 0, staged_bundle
    except BaseException:
        cleanup_staged_debug_bundle(staged_bundle)
        raise


def swap_staged_debug_bundle_into_place(staged_bundle: Path, live_bundle: Path) -> bool:
    if not live_bundle.exists():
        staged_bundle.rename(live_bundle)
        return True
    if sys.platform != "darwin":
        return False
    try:
        renamex_np = ctypes.CDLL(None, use_errno=True).renamex_np
    except AttributeError:
        return False
    renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    renamex_np.restype = ctypes.c_int
    rename_swap = 0x00000002
    result = renamex_np(os.fsencode(staged_bundle), os.fsencode(live_bundle), rename_swap)
    if result == 0:
        return True
    return False


def activate_staged_debug_bundle(staged_bundle: Path, live_bundle: Optional[Path] = None) -> None:
    live = live_bundle or debug_app_bundle_path()
    if not staged_bundle.exists():
        raise ConductorError(f"staged debug app bundle is missing: {staged_bundle}")
    executable = staged_bundle / "Contents" / "MacOS" / "RepoPrompt"
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ConductorError(f"staged debug app bundle is not launchable: {staged_bundle}")
    live.parent.mkdir(parents=True, exist_ok=True)
    backup = live.parent / f".{live.name}.previous.{os.getpid()}.{uuid.uuid4().hex[:8]}"
    moved_existing = False
    try:
        if not swap_staged_debug_bundle_into_place(staged_bundle, live):
            if live.exists():
                live.rename(backup)
                moved_existing = True
            staged_bundle.rename(live)
    except BaseException:
        if moved_existing and not live.exists() and backup.exists():
            with contextlib.suppress(OSError):
                backup.rename(live)
        raise
    finally:
        if backup.exists():
            shutil.rmtree(backup, ignore_errors=True)
        staging_parent = staged_bundle.parent
        if staging_parent.exists():
            shutil.rmtree(staging_parent, ignore_errors=True)
    print(f"Activated staged debug app bundle: {live}", flush=True)


def operation_app_launch_existing(repo_root: Path, args: Dict[str, Any]) -> int:
    bundle = debug_app_bundle_path()
    staged_value = args.get("stagedBundle")
    staged_bundle = Path(str(staged_value)) if staged_value else None
    activated = False
    executable = bundle / "Contents" / "MacOS" / "RepoPrompt"
    if staged_bundle is None and (not bundle.exists() or not executable.is_file() or not os.access(executable, os.X_OK)):
        print(f"ERROR: existing debug app bundle is not launchable: {bundle}", flush=True)
        print("Build it first with './conductor build' or './conductor run'.", flush=True)
        return 1
    metadata = display_lock_metadata(
        lock_kind="live-app",
        ticket=os.environ.get("REPOPROMPT_CONDUCTOR_JOB_TICKET"),
        operation="app launch-existing" if staged_bundle is None else "app activate-staged-and-launch",
        operation_label="app launch-existing" if staged_bundle is None else "app activate staged and launch",
        repo_root=repo_root,
        repo_hash=None,
    )
    try:
        with machine_exclusive_lock(live_app_lock_path(), metadata, "live-app lock"):
            if staged_bundle is None:
                report_launch_bundle_details(repo_root, bundle)
            print("Stopping existing RepoPrompt CE debug app instance", flush=True)
            stop_code = _operation_app_stop_unlocked(repo_root, {"guardDelayedLaunch": bool(args.get("guardDelayedLaunch"))})
            if stop_code != 0:
                return stop_code
            if staged_bundle is not None:
                activate_staged_debug_bundle(staged_bundle, bundle)
                activated = True
                report_launch_bundle_details(repo_root, bundle)
            app_args = [str(arg) for arg in args.get("appArgs") or []]
            argv = ["open", "-n", str(bundle)]
            if app_args:
                argv.extend(["--args", *app_args])
            code, _stdout, _stderr = run_operation_command("launch existing debug app", argv, repo_root)
            if code != 0:
                return code
            try:
                launched_pids = wait_for_debug_app_process()
            except ProcessIdentityError as exc:
                print(f"ERROR: could not safely identify the launched RepoPrompt CE debug app process: {exc}", flush=True)
                return 1
            if not launched_pids:
                print("ERROR: launch request returned, but no matching RepoPrompt CE debug app process appeared within 10 seconds.", flush=True)
                _operation_app_stop_unlocked(repo_root, {"guardDelayedLaunch": True})
                return 1
            print(f"Observed launched RepoPrompt CE debug PID(s): {', '.join(launched_pids)}", flush=True)
        return 0
    finally:
        if staged_bundle is not None and not activated:
            cleanup_staged_debug_bundle(staged_bundle)


def operation_debug_app_build_then_launch(repo_root: Path, args: Dict[str, Any]) -> int:
    package_code, staged_bundle = package_debug_app_under_heavy(repo_root, "debug app build/package")
    if package_code != 0 or staged_bundle is None:
        print("Package failed; no live bundle or stop/launch lifecycle action was performed.", flush=True)
        return package_code or 1
    launch_args = dict(args)
    launch_args.setdefault("appArgs", [])
    launch_args["stagedBundle"] = str(staged_bundle)
    return operation_app_launch_existing(repo_root, launch_args)


def operation_app_status(repo_root: Path) -> int:
    bundle = debug_app_bundle_path()
    print("RepoPrompt CE debug app status")
    print(f"  Debug app bundle: {bundle}")
    print("  Running matching debug app PIDs: ", end="")
    try:
        pids = find_debug_app_pids()
    except ProcessIdentityError as exc:
        print("unknown")
        print(f"ERROR: could not safely identify the debug app process: {exc}")
        return 1
    print(", ".join(pids) if pids else "none")
    print(f"  Bundle exists: {'yes' if bundle.exists() else 'no'}")
    if bundle.exists():
        # Keep the signing/storage probes aligned with Scripts/run.sh launch diagnostics.
        codesign = subprocess.run(["codesign", "-dv", str(bundle)], text=True, capture_output=True)
        details = (codesign.stdout or "") + (codesign.stderr or "")
        team = "<missing>"
        authorities: List[str] = []
        for line in details.splitlines():
            if line.startswith("TeamIdentifier="):
                team = line.split("=", 1)[1] or "<missing>"
            elif line.startswith("Authority="):
                authorities.append(line.split("=", 1)[1])
        print(f"  Signing team: {team}")
        print(f"  Signing authorities: {', '.join(authorities) if authorities else '<none/ad-hoc>'}")
        plist = bundle / "Contents" / "Info.plist"
        marker = subprocess.run(
            ["plutil", "-extract", "RepoPromptDebugSecureStorageBackend", "raw", "-o", "-", str(plist)],
            text=True,
            capture_output=True,
        )
        print(f"  Debug secure storage marker: {marker.stdout.strip() if marker.returncode == 0 and marker.stdout.strip() else '<missing>'}")
        for line in provenance_report_lines(repo_root, bundle):
            print(line)
    status_script = repo_root / "Scripts" / "install_debug_cli.sh"
    code, _stdout, _stderr = run_operation_command("debug CLI status", [str(status_script), "status"], repo_root, allow_exit_codes={0, 1})
    return 0 if code in {0, 1} else code


def operation_app_stop(repo_root: Path, args: Dict[str, Any]) -> int:
    metadata = display_lock_metadata(
        lock_kind="live-app",
        ticket=os.environ.get("REPOPROMPT_CONDUCTOR_JOB_TICKET"),
        operation="app stop",
        operation_label="app stop",
        repo_root=repo_root,
        repo_hash=None,
    )
    with machine_exclusive_lock(live_app_lock_path(), metadata, "live-app lock"):
        return _operation_app_stop_unlocked(repo_root, args)


def operation_swift_build_all(repo_root: Path) -> int:
    for product in ["RepoPrompt", "repoprompt-mcp"]:
        code, _stdout, _stderr = run_operation_command(f"swift build --product {product}", ["swift", "build", "--product", product], repo_root)
        if code != 0:
            return code
    return 0


def operation_release_preflight_missing(_repo_root: Path) -> int:
    print("ERROR: Scripts/release.sh does not exist, so release preflight is not available yet.", flush=True)
    print("See docs/open-source-readiness.md for release-readiness notes.", flush=True)
    return 1


def operation_smoke(repo_root: Path, args: Dict[str, Any]) -> int:
    env = os.environ.copy()
    packaged_app = args.get("packagedApp")
    if packaged_app:
        argv = [
            str(repo_root / "Scripts" / "smoke_packaged_mcp_roundtrip.sh"),
            str(packaged_app),
            "Conductor packaged app",
        ]
        if args.get("artifactManifest"):
            argv.append(str(args["artifactManifest"]))
        code, _stdout, _stderr = run_operation_command(
            "packaged app MCP roundtrip",
            argv,
            repo_root,
            env=env,
        )
        return code

    window_id = int(args.get("windowId") or 1)
    workspace = str(args.get("workspace") or "repoprompt-ce")
    operation_timeout = float(args.get("operationTimeout") or MEDIUM_TIMEOUT_SECONDS)
    deadline = now() + operation_timeout

    launched = bool(args.get("launch"))
    if launched:
        code = operation_debug_app_build_then_launch(repo_root, {"appArgs": []})
        if code != 0:
            return code

    if launched:
        try:
            cli = resolve_embedded_helper(debug_app_bundle_path())
        except (ConductorError, FileNotFoundError, OSError) as exc:
            print(f"ERROR: could not resolve exact helper from launched app: {exc}", flush=True)
            return 1
        print(f"Resolved launched app embedded helper: {cli}", flush=True)
    else:
        cli = require_debug_cli()
        if not cli:
            return 1

    if launched:
        print("Polling rpce-cli-debug windows until the app is ready...", flush=True)
        while True:
            code, stdout, stderr = run_operation_command("windows readiness", [cli, "-e", "windows"], repo_root, env=env, allow_exit_codes={0, 1})
            if code == 0:
                break
            if now() >= deadline:
                print("ERROR: timed out waiting for rpce-cli-debug windows after launch", flush=True)
                return code or 1
            time.sleep(2.0)

    stages = [
        ("windows", [cli, "-e", "windows"]),
        ("workspace switch", [cli, "-w", str(window_id), "-e", f"workspace switch {workspace}"]),
        ("tree roots", [cli, "-w", str(window_id), "-e", "tree --type roots"]),
        ("manage_worktree list", [cli, "-w", str(window_id), "-e", "manage_worktree op=list"]),
        (
            "agent_manage roles",
            routed_structured_cli_argv(cli, window_id, "agent_manage", {"op": "list_agents", "roles_only": True}),
        ),
    ]
    for name, argv in stages:
        allow_exit_codes = {0, 1} if name == "workspace switch" else None
        code, _stdout, stderr = run_operation_command(name, argv, repo_root, env=env, allow_exit_codes=allow_exit_codes)
        if name == "workspace switch" and code == 1 and is_already_on_workspace(stderr, workspace):
            print(f'Already on workspace "{workspace}"; continuing smoke flow.', flush=True)
            continue
        if code != 0:
            if name == "workspace switch" and code == 1:
                print(f"FAILED stage '{name}' with status {code}", flush=True)
            return code

    if args.get("agentRun"):
        agent_timeout = float(args.get("agentTimeout") or SMOKE_AGENT_WAIT_SECONDS)
        start_payload = {
            "op": "start",
            "model_id": "explore",
            "session_name": "CE debug CLI smoke",
            "message": "Reply exactly with CE_AGENT_RUN_SMOKE_OK and stop. Do not edit files.",
            "detach": True,
        }
        code, stdout, _stderr = run_operation_command(
            "agent_run start",
            routed_structured_cli_argv(cli, window_id, "agent_run", start_payload),
            repo_root,
            env=env,
        )
        if code != 0:
            return code
        session_id = None
        try:
            session_id = find_session_id(json.loads(stdout))
        except json.JSONDecodeError:
            session_id = find_session_id_in_text(stdout)
        if not session_id:
            print("ERROR: Could not parse session_id from agent_run start output.", flush=True)
            print("Manual wait hint: rpce-cli-debug -w 1 -c agent_run -j '{\"op\":\"wait\",\"session_id\":\"<session_id>\",\"timeout\":120}'", flush=True)
            return 1
        wait_payload = {"op": "wait", "session_id": session_id, "timeout": agent_timeout}
        code, _stdout, _stderr = run_operation_command(
            "agent_run wait",
            routed_structured_cli_argv(cli, window_id, "agent_run", wait_payload),
            repo_root,
            env=env,
            timeout=agent_timeout + 10.0,
        )
        if code != 0:
            return code
    return 0


def directory_size_bytes(path: Path) -> Optional[int]:
    try:
        if not path.exists():
            return None
        if path.is_symlink():
            path = path.resolve(strict=True)
    except OSError:
        return None

    # Prefer the platform disk-usage tool for explicit cache diagnostics. It is
    # read-only and much faster than Python-level recursive stat walks for large
    # SwiftPM scratch directories. Fall back to a Python walk for small tests or
    # unusual environments where `du` is unavailable.
    try:
        result = subprocess.run(
            ["du", "-sk", str(path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=120,
            check=False,
        )
        if result.returncode == 0:
            first = result.stdout.strip().split()[0]
            return int(first) * 1024
    except (OSError, subprocess.SubprocessError, ValueError, IndexError):
        pass

    total = 0
    stack = [path]
    while stack:
        current = stack.pop()
        try:
            with os.scandir(current) as entries:
                for entry in entries:
                    try:
                        stat_result = entry.stat(follow_symlinks=False)
                    except OSError:
                        continue
                    if entry.is_dir(follow_symlinks=False):
                        stack.append(Path(entry.path))
                    else:
                        total += stat_result.st_size
        except NotADirectoryError:
            try:
                total += current.stat(follow_symlinks=False).st_size
            except OSError:
                pass
        except OSError:
            continue
    return total


def latest_mtime(path: Path) -> Optional[float]:
    try:
        return path.stat(follow_symlinks=False).st_mtime
    except OSError:
        return None


def managed_worktree_container(repo_root: Path) -> Optional[Path]:
    parent = repo_root.parent
    try:
        if parent.parent.name == ".repoprompt-worktrees":
            return parent
    except IndexError:
        return None
    return None


def operation_diagnostics_build_cache(repo_root: Path, args: Dict[str, Any]) -> int:
    limit = int(args.get("limit") or BUILD_CACHE_DIAGNOSTIC_MAX_ROWS)
    limit = max(1, min(limit, 100))
    current_build = repo_root / ".build"

    print("Build cache diagnostics", flush=True)
    if current_build.exists():
        symlink_note = ""
        if current_build.is_symlink():
            with contextlib.suppress(OSError):
                symlink_note = f" -> {current_build.resolve(strict=True)}"
        print(f"Current .build: {format_bytes(directory_size_bytes(current_build))}{symlink_note}", flush=True)
    else:
        print("Current .build: missing", flush=True)

    container = managed_worktree_container(repo_root)
    if container is None or not container.exists():
        print("Managed worktree container: not detected", flush=True)
        return 0

    rows: List[Tuple[int, Optional[float], str]] = []
    for child in sorted(container.iterdir(), key=lambda item: item.name):
        if not child.is_dir():
            continue
        build_dir = child / ".build"
        size = directory_size_bytes(build_dir)
        if size is None:
            continue
        rows.append((size, latest_mtime(build_dir), child.name))

    total = sum(size for size, _mtime, _name in rows)
    print(f"Managed worktree container: {container}", flush=True)
    print(f"Worktree .build total: {format_bytes(total)} across {len(rows)} build director{'y' if len(rows) == 1 else 'ies'}", flush=True)
    if not rows:
        return 0

    print("Top .build directories:", flush=True)
    for size, mtime, name in sorted(rows, key=lambda row: row[0], reverse=True)[:limit]:
        mtime_text = "unknown" if mtime is None else time.strftime("%Y-%m-%d %H:%M", time.localtime(mtime))
        print(f"  {format_bytes(size):>9}  {name}  modified={mtime_text}", flush=True)
    return 0


def operation_diagnostics_agent_mode_on(repo_root: Path, args: Dict[str, Any]) -> int:
    cli = require_debug_cli()
    if not cli:
        return 1
    window_id = int(args.get("windowId") or 1)
    log_file = str(args.get("logFile") or "/tmp/repoprompt-ce-claude-raw-events")
    settings = [
        {"op": "list", "group": "agent_mode", "detailed": True},
        {"op": "set", "key": "agent_mode.claude_raw_event_logging_enabled", "value": True},
        {"op": "set", "key": "agent_mode.claude_raw_event_log_file_path", "value": log_file},
        {"op": "set", "key": "agent_mode.perf_diagnostics_enabled", "value": True},
    ]
    for payload in settings:
        code, _stdout, _stderr = run_operation_command(
            f"app_settings {payload.get('op')} {payload.get('key') or payload.get('group')}",
            routed_structured_cli_argv(cli, window_id, "app_settings", payload),
            repo_root,
        )
        if code != 0:
            return code
    print(f"Agent Mode diagnostics enabled. Raw Claude events log: {log_file}", flush=True)
    return 0


def run_operation_runner(payload_json: str) -> int:
    payload = json.loads(payload_json)
    kind = payload.get("kind")
    args = payload.get("args") or {}
    repo_root = Path(payload.get("repoRoot") or resolve_repo_root()).resolve()
    if kind == "swift_build_all":
        return operation_swift_build_all(repo_root)
    if kind == "app_stop":
        return operation_app_stop(repo_root, args)
    if kind == "app_status":
        return operation_app_status(repo_root)
    if kind == "app_launch_existing":
        return operation_app_launch_existing(repo_root, args)
    if kind == "debug_app_build_then_launch":
        return operation_debug_app_build_then_launch(repo_root, args)
    if kind == "smoke":
        return operation_smoke(repo_root, args)
    if kind == "diagnostics_agent_mode_on":
        return operation_diagnostics_agent_mode_on(repo_root, args)
    if kind == "diagnostics_build_cache":
        return operation_diagnostics_build_cache(repo_root, args)
    if kind == "release_preflight_missing":
        return operation_release_preflight_missing(repo_root)
    print(f"unknown internal operation runner kind: {kind}", file=sys.stderr)
    return 2


def enqueue_and_maybe_wait(
    paths: Paths,
    operation: str,
    args: Dict[str, Any],
    global_flags: argparse.Namespace,
) -> int:
    ensure_daemon(paths, start_if_needed=True)
    request = {
        "type": "enqueue",
        "operation": operation,
        "args": args,
        "requestKey": global_flags.request_key,
        "timeout": global_flags.timeout,
        "verbose": global_flags.verbose,
        "env": OperationRegistry.client_env_snapshot(),
    }
    enqueue_payload = request_daemon(paths, request, timeout=10.0)
    if global_flags.async_mode:
        if global_flags.json:
            print_json(enqueue_payload)
        else:
            print(f"ticket: {enqueue_payload.get('ticket')}")
            print(f"state:  {enqueue_payload.get('state')}")
            print(f"lanes:  {', '.join(enqueue_payload.get('lanes') or []) or 'none'}")
            print(f"log:    {enqueue_payload.get('logPath')}")
            if enqueue_payload.get("reused"):
                print("reused existing queued/running job for request key")
            render_superseded_jobs(enqueue_payload)
            print(f"wait:   ./conductor job wait {enqueue_payload.get('ticket')}")
        return 0

    ticket = enqueue_payload.get("ticket")
    if global_flags.json:
        final = payload_with_output_summary(wait_for_terminal(paths, ticket, request_key=None, json_mode=True))
        print_json({"enqueue": enqueue_payload, "result": final})
        return terminal_exit_code(final)

    print(f"ticket: {ticket}")
    print(f"log:    {enqueue_payload.get('logPath')}")
    print(f"reconnect: ./conductor job wait {ticket}")
    render_superseded_jobs(enqueue_payload)
    output_mode = "full" if global_flags.full_log else "summary"
    final_payload = wait_for_terminal(paths, ticket, request_key=None, json_mode=False, output_mode=output_mode)
    print_terminal_job_output(final_payload, output_mode=output_mode)
    return terminal_exit_code(final_payload)


def parse_no_args(prog: str, argv: List[str]) -> None:
    parser = argparse.ArgumentParser(prog=prog)
    parser.parse_args(argv)


def handle_real_operation(paths: Paths, operation: str, argv: List[str]) -> int:
    global_flags, rest = split_operation_flags(argv)
    if global_flags.timeout is not None and global_flags.timeout < 0:
        raise ConductorError("timeout must be non-negative")

    args: Dict[str, Any] = {}
    if operation in {
        "doctor",
        "guardrails",
        "build",
        "install-debug-cli",
        "debug-cli-status",
        "format",
        "format-check",
        "lint",
        "format-tools-status",
        "check-format-tools",
        "install-format-tools",
    }:
        parse_no_args(f"conductor {operation}", rest)
    elif operation == "swift-build":
        parser = argparse.ArgumentParser(prog="conductor swift-build")
        parser.add_argument("--product", required=True, choices=["RepoPrompt", "repoprompt-mcp", "all"])
        ns = parser.parse_args(rest)
        args["product"] = ns.product
    elif operation == "package":
        parser = argparse.ArgumentParser(prog="conductor package")
        parser.add_argument("config", choices=["debug", "release"])
        ns = parser.parse_args(rest)
        args["config"] = ns.config
    elif operation in {"test", "provider-test"}:
        parser = argparse.ArgumentParser(prog=f"conductor {operation}")
        mode = parser.add_mutually_exclusive_group()
        mode.add_argument("--list", action="store_true")
        mode.add_argument("--filter")
        parser.add_argument("--test-product")
        parser.add_argument("--xctest-stall-seconds", type=float)
        parser.add_argument("--xctest-stall-wake-probe", action="store_true")
        ns = parser.parse_args(rest)
        if ns.xctest_stall_seconds is not None and (
            not math.isfinite(ns.xctest_stall_seconds) or ns.xctest_stall_seconds <= 0
        ):
            raise ConductorError("--xctest-stall-seconds must be greater than zero")
        if ns.xctest_stall_wake_probe and ns.xctest_stall_seconds is None:
            raise ConductorError("--xctest-stall-wake-probe requires --xctest-stall-seconds")
        if ns.list and (ns.xctest_stall_seconds is not None or ns.xctest_stall_wake_probe):
            raise ConductorError("--list cannot be combined with XCTest stall diagnostics")
        if ns.list and ns.test_product:
            raise ConductorError("--list cannot be combined with --test-product")
        if ns.list:
            args["list"] = True
        if ns.filter:
            args["filter"] = ns.filter
        if ns.test_product:
            args["testProduct"] = ns.test_product
        if ns.xctest_stall_seconds is not None:
            args["xctestStallSeconds"] = ns.xctest_stall_seconds
        if ns.xctest_stall_wake_probe:
            args["xctestStallWakeProbe"] = True
    elif operation == "run":
        app_args = rest[1:] if rest and rest[0] == "--" else rest
        args["appArgs"] = app_args
    elif operation == "app":
        if not rest or rest[0] not in {"status", "stop", "launch-existing", "relaunch"}:
            raise ConductorError("usage: ./conductor app status|stop|launch-existing|relaunch [-- <app args...>]")
        args["subcommand"] = rest[0]
        trailing = rest[1:]
        if args["subcommand"] in {"status", "stop"} and trailing:
            raise ConductorError(f"app {args['subcommand']} does not accept application arguments")
        if args["subcommand"] in {"launch-existing", "relaunch"}:
            if trailing and trailing[0] != "--":
                raise ConductorError(f"app {args['subcommand']} application arguments must follow '--'")
            args["appArgs"] = trailing[1:] if trailing else []
    elif operation == "smoke":
        parser = argparse.ArgumentParser(prog="conductor smoke")
        launch_group = parser.add_mutually_exclusive_group()
        launch_group.add_argument("--launch", action="store_true")
        launch_group.add_argument("--packaged-app")
        parser.add_argument("--artifact-manifest")
        parser.add_argument("--workspace", default="repoprompt-ce")
        parser.add_argument("--window-id", type=int, default=1)
        parser.add_argument("--agent-run", action="store_true")
        parser.add_argument("--agent-timeout", type=float, default=SMOKE_AGENT_WAIT_SECONDS)
        ns = parser.parse_args(rest)
        if ns.agent_timeout < 0:
            raise ConductorError("--agent-timeout must be non-negative")
        if ns.artifact_manifest and not ns.packaged_app:
            raise ConductorError("--artifact-manifest requires --packaged-app")
        if ns.packaged_app and ns.agent_run:
            raise ConductorError("--agent-run is not supported with --packaged-app")
        args.update(
            {
                "launch": ns.launch,
                "packagedApp": ns.packaged_app,
                "artifactManifest": ns.artifact_manifest,
                "workspace": ns.workspace,
                "windowId": ns.window_id,
                "agentRun": ns.agent_run,
                "agentTimeout": ns.agent_timeout,
            }
        )
    elif operation == "diagnostics":
        parser = argparse.ArgumentParser(prog="conductor diagnostics")
        subparsers = parser.add_subparsers(dest="subcommand", required=True)

        agent_mode = subparsers.add_parser("agent-mode-on")
        agent_mode.add_argument("--log-file", default="/tmp/repoprompt-ce-claude-raw-events")
        agent_mode.add_argument("--window-id", type=int, default=1)

        build_cache = subparsers.add_parser("build-cache")
        build_cache.add_argument("--limit", type=int, default=BUILD_CACHE_DIAGNOSTIC_MAX_ROWS)

        ns = parser.parse_args(rest)
        args["subcommand"] = ns.subcommand
        if ns.subcommand == "agent-mode-on":
            args.update({"logFile": ns.log_file, "windowId": ns.window_id})
        elif ns.subcommand == "build-cache":
            if ns.limit <= 0:
                raise ConductorError("diagnostics build-cache --limit must be greater than zero")
            args["limit"] = ns.limit
    elif operation == "release":
        parser = argparse.ArgumentParser(prog="conductor release")
        parser.add_argument("subcommand", choices=["preflight", "artifact", "package", "local-install"])
        ns = parser.parse_args(rest)
        args["subcommand"] = ns.subcommand
    else:
        raise ConductorError(f"unknown operation '{operation}'")

    return enqueue_and_maybe_wait(paths, operation, args, global_flags)


def main(argv: List[str]) -> int:
    repo_root = resolve_repo_root()

    if argv and argv[0] == "__operation_runner":
        if len(argv) != 2:
            raise ConductorError("__operation_runner requires one JSON payload argument")
        return run_operation_runner(argv[1])
    if argv and argv[0] == "__daemon":
        parser = argparse.ArgumentParser(prog="conductor.py __daemon")
        parser.add_argument("--repo-root", required=True)
        ns = parser.parse_args(argv[1:])
        daemon_paths = compute_paths(Path(ns.repo_root))
        ensure_state_dirs(daemon_paths)
        return run_daemon(daemon_paths)

    paths = compute_paths(repo_root)
    ensure_state_dirs(paths)

    if not argv or argv[0] in {"-h", "--help"}:
        print(HELP)
        return 0

    command = argv[0]
    if command == "daemon":
        return handle_daemon_command(paths, argv[1:])
    if command == "status":
        return handle_status_command(paths, argv[1:])
    if command == "job":
        return handle_job_command(paths, argv[1:])
    if command in {"sleep", "fake-sleep"}:
        return handle_sleep_operation(paths, command, argv[1:])
    if command in IMPLEMENTED_OPERATIONS:
        return handle_real_operation(paths, command, argv[1:])
    raise ConductorError(f"unknown command '{command}'. Run './conductor --help' for usage.")


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        raise SystemExit(130)
    except ConductorError as exc:
        print(f"conductor: {exc}", file=sys.stderr)
        raise SystemExit(1)
    except BrokenPipeError:
        raise SystemExit(1)
