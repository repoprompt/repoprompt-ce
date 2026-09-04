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
import itertools
import json
import math
import os
import queue
import re
import selectors
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

PROTOCOL_VERSION = 16
TERMINAL_STATES = {"completed", "failed", "canceled"}
JOB_PHASES = {
    "queued",
    "waitingGlobalHeavy",
    "startingProcess",
    "runningProcess",
    "canceling",
    "finalizingOutput",
    "publishingCache",
    "summarizing",
    "terminal",
}
LANE_NAMES = {"build", "debugArtifact", "liveApp", "release", "style"}
LOG_TAIL_LINES = 30
LOG_TAIL_MAX_BYTES = 64 * 1024
LOG_TAIL_FRAGMENT_MAX_BYTES = 4 * 1024
BUILD_CACHE_DIAGNOSTIC_MAX_ROWS = 12
BUILD_CACHE_SCHEMA_VERSION = 1
BUILD_CACHE_DEFAULT_LIMIT_BYTES = 40 * 1024 * 1024 * 1024
BUILD_CACHE_PUBLISH_THROTTLE_SECONDS = 60 * 60.0
BUILD_CACHE_CLONE_MIN_SECONDS = 60.0
BUILD_CACHE_CLONE_MAX_SECONDS = 10 * 60.0
BUILD_CACHE_CLONE_SECONDS_PER_ENTRY = 0.005
BUILD_CACHE_CLONE_SECONDS_PER_GIB = 5.0
BUILD_CACHE_RETRY_OVERHEAD_SECONDS = 30.0
BUILD_CACHE_FORCE_STOP_WAIT_SECONDS = 4 * BUILD_CACHE_CLONE_MAX_SECONDS + BUILD_CACHE_RETRY_OVERHEAD_SECONDS
BUILD_CACHE_ELIGIBLE_OPERATIONS = {"swift-build", "build", "package", "test", "install-debug-cli"}
BUILD_CACHE_ENV_KEYS = (
    "ARCHS",
    "CC",
    "CXX",
    "DEVELOPER_DIR",
    "ONLY_ACTIVE_ARCH",
    "OTHER_SWIFT_FLAGS",
    "REPOPROMPT_ENABLE_SENTRY",
    "SDKROOT",
    "SWIFT_EXEC",
    "SWIFTFLAGS",
)
SUMMARY_VERSION = 2
SUMMARY_SUCCESS_MAX_LINES = 25
SUMMARY_FAILURE_MAX_LINES = 100
SUMMARY_MAX_CHARS = 16000
SUMMARY_LINE_MAX_CHARS = 400
SUMMARY_CONTEXT_BEFORE = 2
SUMMARY_CONTEXT_AFTER = 4
SUMMARY_INPUT_MAX_LINES = 100_000
SUMMARY_INPUT_MAX_BYTES = 8 * 1024 * 1024
SUMMARY_FILE_HEAD_BYTES = 4 * 1024 * 1024
SUMMARY_FILE_TAIL_BYTES = 4 * 1024 * 1024
FULL_LOG_HEAD_BYTES = 8 * 1024 * 1024
FULL_LOG_TAIL_BYTES = 8 * 1024 * 1024
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
EXTERNAL_IO_QUEUE_DEPTH = 4096
MAX_INFRASTRUCTURE_WARNINGS = 16
INFRASTRUCTURE_WARNING_TTL_SECONDS = 5 * 60.0
OUTPUT_FINALIZATION_SECONDS = 2.0
OUTPUT_FINALIZATION_WAIT_SECONDS = 2.5
OUTPUT_FINALIZATION_DRAIN_MAX_READS = 64
OUTPUT_FINALIZATION_DRAIN_MAX_BYTES = 4 * 1024 * 1024
OUTPUT_LINE_BUFFER_BYTES = 64 * 1024
OUTPUT_PUMP_COMMAND_DEPTH = 1024
LOG_FLUSH_WAIT_SECONDS = 5.0
CANCEL_CLEANUP_WAIT_SECONDS = 15.0
CANCEL_RPC_TIMEOUT_SECONDS = CANCEL_CLEANUP_WAIT_SECONDS + 5.0
FAIR_HEAVY_RESCAN_SECONDS = 2.0
FAIR_HEAVY_HEAD_RESCAN_SECONDS = 0.05
FAIR_HEAVY_HEAD_DECAY_RESCAN_SECONDS = 0.25
FAIR_HEAVY_HEAD_COMPETITION_SECONDS = 3.0
FAIR_PROCESS_SNAPSHOT_TTL_SECONDS = 1.0
WAIT_STATUS_POLL_SECONDS = 0.5
WAIT_RPC_CONTACT_SECONDS = 5.0
MAX_CONSECUTIVE_WAIT_CONTACT_FAILURES = 3
MAX_REQUEST_BYTES = 256 * 1024
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
REQUEST_READ_TIMEOUT_SECONDS = 2.0
MAX_ACTIVE_REQUEST_HANDLERS = 32
MAX_ACTIVE_WAIT_HANDLERS = 8
MAX_SERVER_WAIT_SECONDS = 2.0
MAX_JSON_DEPTH = 16
MAX_JSON_COLLECTION_ENTRIES = 1024
MAX_JSON_STRING_BYTES = 64 * 1024
MAX_UNLANED_JOBS = 4
DEBUG_APP_PROVENANCE_RELATIVE_PATH = "Contents/Resources/RepoPromptDebugProvenance.json"

SHORT_TIMEOUT_SECONDS = 5 * 60
MEDIUM_TIMEOUT_SECONDS = 60 * 60
RELEASE_TIMEOUT_SECONDS = 2 * 60 * 60
RELEASE_ARTIFACT_TIMEOUT_SECONDS = 4 * 60 * 60
SMOKE_AGENT_WAIT_SECONDS = 120.0

IMPLEMENTED_OPERATIONS = {
    "doctor",
    "guardrails",
    "codex-schema-check",
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
  ./conductor codex-schema-check      # validate bounded RPCE assumptions against generated Codex schemas
  ./conductor format                 # mutates first-party Swift files
  ./conductor format-check           # non-mutating SwiftFormat check
  ./conductor lint                   # non-mutating format-check + SwiftLint strict
  ./conductor format-tools-status    # inspect SwiftFormat/SwiftLint availability
  ./conductor check-format-tools     # fail if style tools are missing
  ./conductor install-format-tools   # explicit Homebrew install of missing style tools
  ./conductor swift-build --product RepoPrompt|repoprompt-mcp|all
  ./conductor build
  ./conductor package debug|release
  ./conductor test [--filter <filter>] [--test-product <product>] [--xctest-stall-seconds <seconds>] [--xctest-stall-wake-probe]
  ./conductor provider-test [--filter <filter>] [--test-product <product>] [--xctest-stall-seconds <seconds>] [--xctest-stall-wake-probe]
  ./conductor install-debug-cli
  ./conductor debug-cli-status
  ./conductor run [-- <app args...>]                  # build/package, then FIFO coordinated launch
  ./conductor app status
  ./conductor app stop                                 # latest interactive stop intent
  ./conductor app launch-existing [-- <app args...>]   # launch existing DebugApps bundle without building
  ./conductor app relaunch [-- <app args...>]          # latest interactive relaunch intent
  ./conductor smoke [--launch | --packaged-app <path>] [--artifact-manifest <path>] [--workspace <name>] [--window-id <id>] [--agent-run] [--execution-location-ui]
    --execution-location-ui uses REPOPROMPT_EXECUTION_LOCATION_UI_SMOKE_WAIT (default 3s) and _CYCLES (default 3); Accessibility permission is required.
    (without --launch/--packaged-app, requires the CE debug app to already be running and CLI installed)
  ./conductor diagnostics agent-mode-on [--log-file <path>]
  ./conductor diagnostics build-cache [--limit <n>]
  ./conductor cache status [--limit <n>] [--json]  # read-only; performs no repair or cleanup
  ./conductor cache drop <compatibility-key> [--json]
  ./conductor diagnostics focused-build [--product <name>] [--test] [--filter <filter>]
  ./conductor diagnostics high-output [--lines <n>] [--warnings <n>] [--exit-code <n>] [--linger <s>]
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


class DaemonContactError(ConductorError):
    """A contact failure that preserves daemon process and health truth."""

    def __init__(self, message: str, health_payload: Dict[str, Any]) -> None:
        super().__init__(message)
        self.health_payload = health_payload


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
    reader_fd: Optional[int]
    writer_fd: Optional[int]
    close_lock: threading.Lock = dataclasses.field(default_factory=threading.Lock, repr=False)
    reader_transferred: bool = False

    @classmethod
    def create(cls, kind: str) -> "ProcessOutputTransport":
        if kind == "pipe":
            reader_fd, writer_fd = os.pipe()
        elif kind == "pty":
            reader_fd, writer_fd = os.openpty()
        else:
            raise ValueError(f"unsupported process output transport: {kind}")
        os.set_blocking(reader_fd, False)
        return cls(kind=kind, reader_fd=reader_fd, writer_fd=writer_fd)

    @property
    def popen_stdout(self) -> Any:
        return self.writer_fd

    @property
    def popen_stderr(self) -> Any:
        return self.writer_fd if self.kind == "pty" else subprocess.STDOUT

    def attach_process(self, _process: subprocess.Popen[bytes]) -> None:
        self.close_writer()

    def transfer_reader(self) -> int:
        with self.close_lock:
            if self.reader_transferred or self.reader_fd is None:
                raise ConductorError("process output reader ownership is unavailable")
            reader_fd = self.reader_fd
            self.reader_fd = None
            self.reader_transferred = True
            return reader_fd

    def close_writer(self) -> None:
        with self.close_lock:
            writer_fd = self.writer_fd
            self.writer_fd = None
        if writer_fd is not None:
            with contextlib.suppress(OSError):
                os.close(writer_fd)

    def close_reader(self) -> None:
        with self.close_lock:
            if self.reader_transferred:
                return
            reader_fd = self.reader_fd
            self.reader_fd = None
        if reader_fd is not None:
            with contextlib.suppress(OSError):
                os.close(reader_fd)

    def close_all(self) -> None:
        self.close_writer()
        self.close_reader()


@dataclasses.dataclass(frozen=True)
class ProcessOutputResult:
    truncated: bool
    reason: Optional[str]
    bytes_read: int


@dataclasses.dataclass
class ProcessOutputChannel:
    ticket: str
    read_fd: int
    kind: str
    registered: threading.Event = dataclasses.field(default_factory=threading.Event, repr=False)
    finalization_started: threading.Event = dataclasses.field(default_factory=threading.Event, repr=False)
    completion: threading.Event = dataclasses.field(default_factory=threading.Event, repr=False)
    pending: bytearray = dataclasses.field(default_factory=bytearray, repr=False)
    finalization_deadline: Optional[float] = None
    bytes_read: int = 0
    result: Optional[ProcessOutputResult] = None


class ProcessOutputPump:
    """Owns every registered output FD through EOF or bounded finalization."""

    def __init__(
        self,
        on_chunk: Any,
        on_line: Any,
        clock: Any = time.monotonic,
        close_fd: Any = os.close,
    ) -> None:
        self._on_chunk = on_chunk
        self._on_line = on_line
        self._clock = clock
        self._close_fd = close_fd
        self._commands: "queue.Queue[Tuple[str, Optional[ProcessOutputChannel]]]" = queue.Queue(
            maxsize=OUTPUT_PUMP_COMMAND_DEPTH
        )
        self._submission_lock = threading.Lock()
        self._stopping = False
        self._wake_reader, self._wake_writer = socket.socketpair()
        self._wake_reader.setblocking(False)
        self._wake_writer.setblocking(False)
        self._selector = selectors.DefaultSelector()
        self._selector.register(self._wake_reader, selectors.EVENT_READ, None)
        self._channels: Dict[int, ProcessOutputChannel] = {}
        self._thread = threading.Thread(target=self._run, name="conductor-output-pump", daemon=True)
        self._thread.start()

    def register(self, ticket: str, read_fd: int, kind: str) -> ProcessOutputChannel:
        channel = ProcessOutputChannel(ticket=ticket, read_fd=read_fd, kind=kind)
        # Queue submission transfers reader ownership. Registration and finalization
        # commands are FIFO, so job startup does not depend on pump-thread latency.
        self._submit("register", channel)
        return channel

    def request_finalization(self, channel: ProcessOutputChannel) -> None:
        self._submit("finalize", channel)

    def close(self) -> None:
        with self._submission_lock:
            if self._stopping:
                return
            try:
                self._commands.put_nowait(("stop", None))
            except queue.Full:
                self._stopping = True
        with contextlib.suppress(BlockingIOError, OSError):
            self._wake_writer.send(b"x")
        self._thread.join(timeout=OUTPUT_FINALIZATION_WAIT_SECONDS)

    @staticmethod
    def wait_for_completion(channel: ProcessOutputChannel) -> ProcessOutputResult:
        if channel.completion.is_set():
            return channel.result or ProcessOutputResult(True, "pumpFailure", channel.bytes_read)
        if not channel.finalization_started.wait(OUTPUT_FINALIZATION_WAIT_SECONDS):
            if channel.completion.is_set():
                return channel.result or ProcessOutputResult(True, "pumpFailure", channel.bytes_read)
            return ProcessOutputResult(True, "pumpCompletionDeadline", channel.bytes_read)
        if not channel.completion.wait(OUTPUT_FINALIZATION_WAIT_SECONDS):
            return ProcessOutputResult(True, "pumpCompletionDeadline", channel.bytes_read)
        return channel.result or ProcessOutputResult(True, "pumpFailure", channel.bytes_read)

    def _submit(self, command: str, channel: ProcessOutputChannel) -> None:
        with self._submission_lock:
            if self._stopping:
                raise ConductorError("output pump is stopped")
            try:
                self._commands.put_nowait((command, channel))
            except queue.Full as exc:
                raise ConductorError("output pump command queue is full") from exc
        with contextlib.suppress(BlockingIOError, OSError):
            self._wake_writer.send(b"x")

    def _run(self) -> None:
        failure_reason = "pumpShutdown"
        try:
            while not self._stopping:
                timeout = self._next_timeout()
                for key, _mask in self._selector.select(timeout):
                    if key.data is None:
                        self._drain_wakeup()
                        self._drain_commands()
                    else:
                        self._read_available(key.data)
                self._finish_expired_channels()
        except Exception:
            failure_reason = "pumpFailure"
        finally:
            with self._submission_lock:
                self._stopping = True
                for channel in list(self._channels.values()):
                    self._finish(channel, ProcessOutputResult(True, failure_reason, channel.bytes_read))
                self._finish_queued_channels(failure_reason)
            with contextlib.suppress(Exception):
                self._selector.close()
            self._wake_reader.close()
            self._wake_writer.close()

    def _next_timeout(self) -> Optional[float]:
        deadlines = [
            channel.finalization_deadline
            for channel in self._channels.values()
            if channel.finalization_deadline is not None
        ]
        if not deadlines:
            return None
        return max(0.0, min(deadlines) - self._clock())

    def _drain_wakeup(self) -> None:
        with contextlib.suppress(BlockingIOError, OSError):
            while self._wake_reader.recv(4096):
                pass

    def _drain_commands(self) -> None:
        while True:
            try:
                command, channel = self._commands.get_nowait()
            except queue.Empty:
                return
            try:
                if command == "stop":
                    with self._submission_lock:
                        self._stopping = True
                elif channel is None:
                    raise ConductorError(f"output pump command {command} is missing a channel")
                elif command == "register":
                    self._selector.register(channel.read_fd, selectors.EVENT_READ, channel)
                    self._channels[channel.read_fd] = channel
                    channel.registered.set()
                elif command == "finalize" and channel.read_fd in self._channels:
                    channel.finalization_deadline = self._clock() + OUTPUT_FINALIZATION_SECONDS
                    channel.finalization_started.set()
                elif command == "finalize" and channel.result is None:
                    channel.finalization_started.set()
                    self._finish(channel, ProcessOutputResult(False, None, channel.bytes_read))
            except Exception:
                if channel is not None:
                    self._finish(channel, ProcessOutputResult(True, "pumpFailure", channel.bytes_read))
                    channel.registered.set()
            finally:
                self._commands.task_done()

    def _finish_queued_channels(self, reason: str) -> None:
        while True:
            try:
                _command, channel = self._commands.get_nowait()
            except queue.Empty:
                return
            try:
                if channel is not None:
                    self._finish(channel, ProcessOutputResult(True, reason, channel.bytes_read))
            finally:
                self._commands.task_done()

    def _read_available(self, channel: ProcessOutputChannel) -> None:
        try:
            chunk = os.read(channel.read_fd, 64 * 1024)
        except BlockingIOError:
            return
        except OSError as exc:
            if channel.kind == "pty" and exc.errno == errno.EIO:
                chunk = b""
            else:
                self._finish(channel, ProcessOutputResult(True, "outputReadFailed", channel.bytes_read))
                return
        if not chunk:
            self._finish(channel, ProcessOutputResult(False, None, channel.bytes_read))
            return
        channel.bytes_read += len(chunk)
        self._on_chunk(channel.ticket, chunk)
        channel.pending.extend(chunk)
        while True:
            newline = channel.pending.find(b"\n")
            if newline < 0:
                break
            end = newline + 1
            self._on_line(channel.ticket, bytes(channel.pending[:end]))
            del channel.pending[:end]
        if len(channel.pending) > OUTPUT_LINE_BUFFER_BYTES:
            fragment = bytes(channel.pending[:OUTPUT_LINE_BUFFER_BYTES]) + b"... [line truncated by conductor]\n"
            del channel.pending[:OUTPUT_LINE_BUFFER_BYTES]
            self._on_line(channel.ticket, fragment)

    def _finish_expired_channels(self) -> None:
        timestamp = self._clock()
        for channel in list(self._channels.values()):
            deadline = channel.finalization_deadline
            if deadline is None or timestamp < deadline:
                continue
            drained_bytes = 0
            drain_reads = 0
            while (
                channel.read_fd in self._channels
                and drain_reads < OUTPUT_FINALIZATION_DRAIN_MAX_READS
                and drained_bytes < OUTPUT_FINALIZATION_DRAIN_MAX_BYTES
            ):
                before = channel.bytes_read
                self._read_available(channel)
                drain_reads += 1
                drained_bytes += max(0, channel.bytes_read - before)
                if channel.result is not None or channel.bytes_read == before:
                    break
            if channel.result is None:
                self._finish(
                    channel,
                    ProcessOutputResult(True, "inheritedWriterDeadline", channel.bytes_read),
                )

    def _finish(self, channel: ProcessOutputChannel, result: ProcessOutputResult) -> None:
        if channel.result is not None:
            return
        if channel.pending:
            self._on_line(channel.ticket, bytes(channel.pending))
            channel.pending.clear()
        if channel.read_fd in self._channels:
            with contextlib.suppress(Exception):
                self._selector.unregister(channel.read_fd)
            del self._channels[channel.read_fd]
        with contextlib.suppress(OSError):
            self._close_fd(channel.read_fd)
        channel.result = result
        channel.registered.set()
        channel.completion.set()


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


@dataclasses.dataclass(frozen=True)
class BuildCacheSnapshot:
    key: str
    payload: Dict[str, Any]
    toolchain_signature: str


@dataclasses.dataclass
class BuildCacheContext:
    snapshot: BuildCacheSnapshot
    observed_generation: int
    seeded: bool
    status: Dict[str, Any]
    outcome_path: Optional[Path] = None


def _durable_unlink(path: Path) -> None:
    try:
        path.unlink()
    except FileNotFoundError:
        return
    directory_descriptor = -1
    try:
        directory_descriptor = os.open(path.parent, os.O_RDONLY)
        with contextlib.suppress(OSError):
            os.fsync(directory_descriptor)
    except OSError:
        # The unlink already committed. Directory fsync is a durability
        # enhancement and must not turn successful cleanup into a failure.
        pass
    finally:
        if directory_descriptor >= 0:
            os.close(directory_descriptor)


def _atomic_write_json(path: Path, payload: Dict[str, Any]) -> None:
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    replaced = False
    try:
        encoded = json.dumps(payload, indent=2, sort_keys=True).encode("utf-8")
        remaining = memoryview(encoded)
        while remaining:
            written = os.write(descriptor, remaining)
            if written <= 0:
                raise OSError(errno.EIO, f"short write for {path}")
            remaining = remaining[written:]
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        os.replace(temporary, path)
        replaced = True
        directory_descriptor = -1
        try:
            directory_descriptor = os.open(path.parent, os.O_RDONLY)
            with contextlib.suppress(OSError):
                os.fsync(directory_descriptor)
        except OSError:
            # The atomic replace already committed. Directory fsync is a
            # durability enhancement and must not make callers roll back
            # successfully published state.
            pass
        finally:
            if directory_descriptor >= 0:
                os.close(directory_descriptor)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if not replaced:
            with contextlib.suppress(FileNotFoundError):
                temporary.unlink()


class BuildCacheManager:
    """Private immutable SwiftPM seed store; kernel locks serialize every key mutation."""

    def __init__(
        self,
        repo_root: Path,
        *,
        store_root: Optional[Path] = None,
        probe_provider: Any = None,
        clone_runner: Any = None,
        clock: Any = time.time,
        monotonic: Any = time.monotonic,
        env: Optional[Dict[str, str]] = None,
        startup_hygiene: bool = True,
    ) -> None:
        self.repo_root = repo_root.resolve()
        self.env = dict(os.environ if env is None else env)
        override = self.env.get("REPOPROMPT_DEV_BUILD_CACHE_DIR")
        self.store_root = (store_root or (Path(override).expanduser() if override else Path.home() / "Library" / "Application Support" / "RepoPrompt CE" / "Conductor" / "BuildCache")).resolve()
        self.locks_dir = self.store_root / "locks"
        self._probe_provider = probe_provider or self._probe_toolchain
        self._clone_runner = clone_runner or self._clone_cow
        self._clock = clock
        self._monotonic = monotonic
        self._startup_advisory_error: Optional[str] = None
        if startup_hygiene:
            try:
                self._ensure_store_dirs()
                self._sweep_stranded_store_temporaries()
                self._sweep_repo_build_temporaries(nonblocking=True)
            except Exception as exc:
                self._startup_advisory_error = str(exc)[:500]

    def _ensure_store_dirs(self) -> None:
        ensure_private_dir(self.store_root.parent)
        ensure_private_dir(self.store_root)
        ensure_private_dir(self.locks_dir)

    @staticmethod
    def _remove_owned_temporary(path: Path) -> None:
        try:
            info = path.lstat()
        except FileNotFoundError:
            return
        if stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode):
            shutil.rmtree(path)
        else:
            path.unlink()

    @staticmethod
    def _is_store_temporary_name(name: str) -> bool:
        return re.fullmatch(r"seed\.(?:tmp|previous)-[0-9a-f]{32}", name) is not None

    @staticmethod
    def _is_repo_temporary_name(name: str) -> bool:
        return re.fullmatch(r"\.build\.seed-tmp-[0-9a-f]{32}", name) is not None

    @contextlib.contextmanager
    def _repo_prepare_lock(self, *, nonblocking: bool = False):
        digest = hashlib.sha256(str(self.repo_root).encode("utf-8")).hexdigest()
        lock_path = self.locks_dir / f"repo-{digest}.lock"
        lock_file = lock_path.open("a+", encoding="utf-8")
        os.chmod(lock_path, 0o600)
        flags = fcntl.LOCK_EX | (fcntl.LOCK_NB if nonblocking else 0)
        try:
            fcntl.flock(lock_file.fileno(), flags)
            yield
        finally:
            with contextlib.suppress(OSError):
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
            lock_file.close()

    def _remove_repo_build_temporaries_locked(self) -> int:
        removed = 0
        for child in self.repo_root.iterdir():
            if self._is_repo_temporary_name(child.name):
                self._remove_owned_temporary(child)
                removed += 1
        return removed

    def _sweep_repo_build_temporaries(self, *, nonblocking: bool) -> int:
        try:
            with self._repo_prepare_lock(nonblocking=nonblocking):
                return self._remove_repo_build_temporaries_locked()
        except BlockingIOError:
            return 0

    def _sweep_stranded_store_temporaries(self) -> Dict[str, int]:
        removed = 0
        restored_previous = 0
        skipped_locked = 0
        for key_dir in self.store_root.iterdir():
            if not key_dir.is_dir() or key_dir.is_symlink() or not re.fullmatch(r"[0-9a-f]{64}", key_dir.name):
                continue
            try:
                with self.key_lock(key_dir.name, exclusive=True, nonblocking=True):
                    candidates = [child for child in key_dir.iterdir() if self._is_store_temporary_name(child.name)]
                    seed = key_dir / "seed"
                    meta = self._meta(key_dir.name) or {}
                    seed_valid = bool(meta and self._validate_seed_at(key_dir.name, meta, seed))
                    if not seed_valid and meta:
                        for previous in sorted(
                            (child for child in candidates if child.name.startswith("seed.previous-")),
                            key=lambda child: child.name,
                        ):
                            if self._validate_seed_at(key_dir.name, meta, previous):
                                if seed.exists() or seed.is_symlink():
                                    self._remove_owned_temporary(seed)
                                os.replace(previous, seed)
                                candidates.remove(previous)
                                restored_previous += 1
                                break
                    for child in candidates:
                        self._remove_owned_temporary(child)
                        removed += 1
            except BlockingIOError:
                skipped_locked += 1
        return {
            "removed": removed,
            "restoredPrevious": restored_previous,
            "skippedLockedKeys": skipped_locked,
        }

    @staticmethod
    def configuration_for(operation: str, args: Dict[str, Any]) -> str:
        if operation == "package":
            return str(args.get("config") or "debug")
        return "debug"

    @staticmethod
    def eligible(operation: str, args: Dict[str, Any]) -> bool:
        del args
        return operation in BUILD_CACHE_ELIGIBLE_OPERATIONS

    @staticmethod
    def retry_job_timeout(
        attempt_timeout: Optional[float],
        cleanup_timeout: float,
    ) -> Optional[float]:
        if attempt_timeout is None:
            return None
        return (
            max(0.0, attempt_timeout) * 2
            + max(0.0, cleanup_timeout)
            + BUILD_CACHE_RETRY_OVERHEAD_SECONDS
        )

    def _run_probe(self, argv: Sequence[str]) -> str:
        completed = subprocess.run(
            list(argv),
            cwd=str(self.repo_root),
            stdin=subprocess.DEVNULL,
            text=True,
            capture_output=True,
            timeout=10.0,
        )
        if completed.returncode != 0:
            raise ConductorError(f"build-cache probe failed: {format_argv(argv)}: {completed.stderr.strip()[:500]}")
        return completed.stdout.strip()

    def _probe_toolchain(self) -> Dict[str, Any]:
        target_payload = json.loads(self._run_probe(["swift", "-print-target-info"]))
        target = target_payload.get("target") or {}
        return {
            "swiftVersion": self._run_probe(["swift", "--version"]),
            "sdkBuild": self._run_probe(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-build-version"]),
            "developerDir": self._run_probe(["/usr/bin/xcode-select", "-p"]),
            "architecture": os.uname().machine,
            "destinationTriple": target.get("unversionedTriple") or target.get("triple"),
        }

    def _manifest_hashes(self) -> List[Dict[str, str]]:
        candidates = {self.repo_root / "Package.swift", self.repo_root / "Package.resolved"}
        for base in (self.repo_root / "Packages", self.repo_root / "Vendor"):
            if base.exists():
                candidates.update(path for path in base.rglob("Package.swift") if ".build" not in path.parts)
        rows: List[Dict[str, str]] = []
        for path in sorted(candidates, key=lambda candidate: str(candidate.relative_to(self.repo_root))):
            relative = str(path.relative_to(self.repo_root))
            if not path.is_file():
                rows.append({"path": relative, "sha256": "missing"})
                continue
            rows.append({"path": relative, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
        return rows

    def snapshot(self, configuration: str, job_env: Dict[str, str]) -> BuildCacheSnapshot:
        toolchain = self._probe_provider()
        if not isinstance(toolchain, dict):
            raise ConductorError("build-cache toolchain probe returned invalid data")
        payload: Dict[str, Any] = {
            "schemaVersion": BUILD_CACHE_SCHEMA_VERSION,
            "toolchain": toolchain,
            "configuration": configuration,
            "environment": {key: job_env.get(key) for key in BUILD_CACHE_ENV_KEYS},
            "manifests": self._manifest_hashes(),
        }
        encoded = json_dumps(payload).encode("utf-8")
        toolchain_signature = hashlib.sha256(json_dumps(toolchain).encode("utf-8")).hexdigest()
        return BuildCacheSnapshot(hashlib.sha256(encoded).hexdigest(), payload, toolchain_signature)

    def _key_dir(self, key: str) -> Path:
        if not re.fullmatch(r"[0-9a-f]{64}", key):
            raise ConductorError("invalid build-cache key")
        return self.store_root / key

    @contextlib.contextmanager
    def key_lock(self, key: str, *, exclusive: bool, nonblocking: bool = False):
        self._key_dir(key)
        # The persistent per-key inode is the cross-process flock authority.
        # Unlinking a seemingly idle lock can split exclusion when a waiter has
        # already opened the old inode, so zero-byte lock files are retained.
        lock_path = self.locks_dir / f"{key}.lock"
        lock_file = lock_path.open("a+", encoding="utf-8")
        os.chmod(lock_path, 0o600)
        flags = fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH
        if nonblocking:
            flags |= fcntl.LOCK_NB
        try:
            fcntl.flock(lock_file.fileno(), flags)
            yield lock_file
        finally:
            with contextlib.suppress(OSError):
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
            lock_file.close()

    @staticmethod
    def _read_json_file(path: Path) -> Optional[Dict[str, Any]]:
        try:
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode) or (hasattr(os, "getuid") and info.st_uid != os.getuid()):
                return None
            payload = json.loads(path.read_text(encoding="utf-8"))
            return payload if isinstance(payload, dict) else None
        except (FileNotFoundError, OSError, json.JSONDecodeError):
            return None

    def _meta(self, key: str) -> Optional[Dict[str, Any]]:
        return self._read_json_file(self._key_dir(key) / "meta.json")

    @staticmethod
    def _tree_deadline_for_work(entries: int, size_bytes: int) -> float:
        scaled = (
            BUILD_CACHE_CLONE_MIN_SECONDS
            + max(0, entries) * BUILD_CACHE_CLONE_SECONDS_PER_ENTRY
            + (max(0, size_bytes) / float(1024**3)) * BUILD_CACHE_CLONE_SECONDS_PER_GIB
        )
        return min(BUILD_CACHE_CLONE_MAX_SECONDS, max(BUILD_CACHE_CLONE_MIN_SECONDS, scaled))

    @staticmethod
    def _tree_deadline_seconds(source: Path) -> float:
        max_entries = int(
            (BUILD_CACHE_CLONE_MAX_SECONDS - BUILD_CACHE_CLONE_MIN_SECONDS)
            / BUILD_CACHE_CLONE_SECONDS_PER_ENTRY
        )
        entries = 0
        size_bytes = 0
        pending = [source]
        while pending and entries < max_entries:
            directory = pending.pop()
            try:
                children = os.scandir(directory)
            except OSError:
                return BUILD_CACHE_CLONE_MAX_SECONDS
            with children:
                for child in children:
                    entries += 1
                    if entries >= max_entries:
                        return BUILD_CACHE_CLONE_MAX_SECONDS
                    try:
                        if child.is_dir(follow_symlinks=False):
                            pending.append(Path(child.path))
                        else:
                            size_bytes += child.stat(follow_symlinks=False).st_size
                    except OSError:
                        return BUILD_CACHE_CLONE_MAX_SECONDS
        return BuildCacheManager._tree_deadline_for_work(entries, size_bytes)

    @staticmethod
    def _clone_deadline_seconds(source: Path) -> float:
        return BuildCacheManager._tree_deadline_seconds(source)

    @staticmethod
    def _clone_cow(source: Path, destination: Path) -> bool:
        try:
            completed = subprocess.run(
                [
                    "/usr/bin/ditto",
                    "--clone",
                    "--norsrc",
                    "--noextattr",
                    "--noqtn",
                    "--noacl",
                    str(source),
                    str(destination),
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=BuildCacheManager._clone_deadline_seconds(source),
            )
            return completed.returncode == 0 and destination.is_dir() and not destination.is_symlink()
        except (OSError, subprocess.TimeoutExpired):
            return False

    @staticmethod
    def _source_head(repo_root: Path) -> Optional[str]:
        try:
            completed = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=str(repo_root),
                stdin=subprocess.DEVNULL,
                text=True,
                capture_output=True,
                timeout=5.0,
            )
            value = completed.stdout.strip()
            return value if completed.returncode == 0 and re.fullmatch(r"[0-9a-f]{40,64}", value) else None
        except (OSError, subprocess.TimeoutExpired):
            return None

    def _validate_seed_at(self, key: str, meta: Dict[str, Any], seed: Path) -> bool:
        marker = self._read_json_file(seed / ".generation.json")
        build = seed / ".build"
        return bool(
            marker
            and marker.get("key") == key
            and marker.get("generation") == meta.get("generation")
            and build.is_dir()
            and not build.is_symlink()
        )

    def _validate_seed(self, key: str, meta: Dict[str, Any]) -> bool:
        return self._validate_seed_at(key, meta, self._key_dir(key) / "seed")

    def _quarantine_seed(self, key: str, reason: str) -> None:
        with self.key_lock(key, exclusive=True):
            key_dir = self._key_dir(key)
            meta = self._meta(key) or {"key": key, "generation": 0}
            seed = key_dir / "seed"
            if seed.exists() and not seed.is_symlink():
                quarantine = key_dir / f"suspect-{int(self._clock())}-{uuid.uuid4().hex[:8]}"
                os.replace(seed, quarantine)
                shutil.rmtree(quarantine, ignore_errors=True)
            meta["corruptionReason"] = reason[:500]
            meta["quarantinedAt"] = self._clock()
            ensure_private_dir(key_dir)
            _atomic_write_json(key_dir / "meta.json", meta)

    def _advisory_prepare_context(
        self,
        configuration: str,
        error: BaseException,
        snapshot: Optional[BuildCacheSnapshot] = None,
        generation: int = 0,
    ) -> BuildCacheContext:
        build_dir = self.repo_root / ".build"
        if build_dir.exists() or build_dir.is_symlink():
            state = "warmLocalAdvisory" if build_dir.is_dir() and not build_dir.is_symlink() else "unsafeLocalBuildAdvisory"
        else:
            state = "cacheAdvisoryCold"
        effective_snapshot = snapshot or BuildCacheSnapshot("0" * 64, {}, "")
        status: Dict[str, Any] = {
            "key": effective_snapshot.key,
            "configuration": configuration,
            "storePath": str(self.store_root),
            "generation": generation,
            "state": state,
            "seeded": False,
            "advisoryFailure": str(error)[:500],
        }
        return BuildCacheContext(effective_snapshot, generation, False, status)

    def prepare(self, operation: str, args: Dict[str, Any], job_env: Dict[str, str]) -> Optional[BuildCacheContext]:
        if (
            not self.eligible(operation, args)
            or self.env.get("REPOPROMPT_DEV_BUILD_CACHE_DISABLE") == "1"
            or not (self.repo_root / "Package.swift").is_file()
        ):
            return None
        configuration = self.configuration_for(operation, args)
        try:
            snapshot = self.snapshot(configuration, job_env)
        except Exception as exc:
            return self._advisory_prepare_context(configuration, exc)
        build_dir = self.repo_root / ".build"
        generation = 0
        context = BuildCacheContext(
            snapshot,
            generation,
            False,
            {
                "key": snapshot.key,
                "configuration": configuration,
                "storePath": str(self.store_root),
                "generation": generation,
                "state": "coldMiss",
                "seeded": False,
            },
        )
        startup_advisory_error = self._startup_advisory_error
        temporary: Optional[Path] = None
        try:
            self._ensure_store_dirs()
            self._startup_advisory_error = None
            self._sweep_stranded_store_temporaries()
            with self._repo_prepare_lock():
                self._remove_repo_build_temporaries_locked()
                with self.key_lock(snapshot.key, exclusive=False):
                    meta = self._meta(snapshot.key) or {}
                    generation = int(meta.get("generation") or 0)
                    valid_seed = self._validate_seed(snapshot.key, meta) if meta else False
                context.observed_generation = generation
                context.status["generation"] = generation
                if startup_advisory_error:
                    context.status["startupAdvisoryFailure"] = startup_advisory_error
                if build_dir.exists() or build_dir.is_symlink():
                    context.status["state"] = (
                        "warmLocal" if build_dir.is_dir() and not build_dir.is_symlink() else "unsafeLocalBuild"
                    )
                    return context
                if meta and not valid_seed:
                    self._quarantine_seed(snapshot.key, "seed generation or shape did not match metadata")
                    context.status["state"] = "corruptSeedCold"
                    return context
                if not valid_seed:
                    return context
                temporary = self.repo_root / f".build.seed-tmp-{uuid.uuid4().hex}"
                started = self._monotonic()
                with self.key_lock(snapshot.key, exclusive=False):
                    refreshed_meta = self._meta(snapshot.key) or {}
                    if int(refreshed_meta.get("generation") or 0) != generation or not self._validate_seed(snapshot.key, refreshed_meta):
                        context.status["state"] = "generationChangedCold"
                        return context
                    cloned = self._clone_runner(self._key_dir(snapshot.key) / "seed" / ".build", temporary)
                if not cloned:
                    context.status["state"] = "cloneFailedCold"
                    return context
                if build_dir.exists() or build_dir.is_symlink():
                    context.status["state"] = "localBuildAppeared"
                    return context
                provenance = {
                    "schemaVersion": BUILD_CACHE_SCHEMA_VERSION,
                    "key": snapshot.key,
                    "generation": generation,
                    "sourceHead": meta.get("sourceHead"),
                    "seedPath": str(self._key_dir(snapshot.key) / "seed"),
                    "clonedAt": self._clock(),
                }
                _atomic_write_json(temporary / ".conductor-cache-provenance.json", provenance)
                os.replace(temporary, build_dir)
                temporary = None
                duration = max(0.0, self._monotonic() - started)
                context.status.update(
                    {
                        "state": "seeded",
                        "seeded": True,
                        "cloneSeconds": duration,
                        "sourceHead": meta.get("sourceHead"),
                    }
                )
                context.seeded = True
                try:
                    with self.key_lock(snapshot.key, exclusive=True):
                        touched = self._meta(snapshot.key) or {}
                        if int(touched.get("generation") or 0) == generation:
                            touched["lastUsedAt"] = self._clock()
                            _atomic_write_json(self._key_dir(snapshot.key) / "meta.json", touched)
                except Exception as exc:
                    context.status["advisoryFailure"] = str(exc)[:500]
                return context
        except Exception as exc:
            return self._advisory_prepare_context(configuration, exc, snapshot, generation)
        finally:
            if temporary is not None and temporary.exists() and not temporary.is_symlink():
                shutil.rmtree(temporary, ignore_errors=True)

    @staticmethod
    def _sanitize_seed(build_dir: Path) -> None:
        deadline = BuildCacheManager._tree_deadline_seconds(build_dir)
        for relative in ("xcode", "xcode-custom", ".conductor-cache-provenance.json"):
            target = build_dir / relative
            if target.is_dir() and not target.is_symlink():
                shutil.rmtree(target, ignore_errors=True)
            else:
                with contextlib.suppress(FileNotFoundError):
                    target.unlink()
        for command, failure in (
            (
                [
                    "/usr/bin/find",
                    str(build_dir),
                    "-type",
                    "d",
                    "-name",
                    "ModuleCache",
                    "-prune",
                    "-exec",
                    "/bin/rm",
                    "-rf",
                    "{}",
                    "+",
                ],
                "could not exclude path-bound module caches from immutable build-cache seed",
            ),
            (
                ["/usr/bin/find", str(build_dir), "-type", "f", "-name", "*.log", "-delete"],
                "could not exclude logs from immutable build-cache seed",
            ),
        ):
            completed = subprocess.run(
                command,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=deadline,
            )
            if completed.returncode != 0:
                raise ConductorError(failure)

    @staticmethod
    def _disk_usage_bytes(path: Path) -> int:
        completed = subprocess.run(
            ["/usr/bin/du", "-sk", str(path)],
            stdin=subprocess.DEVNULL,
            text=True,
            capture_output=True,
            timeout=BuildCacheManager._tree_deadline_seconds(path),
        )
        if completed.returncode != 0:
            raise ConductorError("could not measure immutable build-cache seed")
        try:
            return int(completed.stdout.split()[0]) * 1024
        except (IndexError, ValueError) as exc:
            raise ConductorError("invalid immutable build-cache disk-usage result") from exc

    def publish(self, context: BuildCacheContext) -> Dict[str, Any]:
        if not context.snapshot.payload:
            return {"state": "publicationSkipped", "reason": "compatibility key unavailable"}
        current = self.snapshot(str(context.snapshot.payload["configuration"]), context.snapshot.payload.get("environment") or {})
        if current.key != context.snapshot.key:
            return {"state": "publicationSkipped", "reason": "compatibility key changed during build"}
        build_dir = self.repo_root / ".build"
        if not build_dir.is_dir() or build_dir.is_symlink():
            return {"state": "publicationSkipped", "reason": "successful build directory unavailable"}
        self._ensure_store_dirs()
        self._sweep_stranded_store_temporaries()
        key = context.snapshot.key
        next_generation = 0
        size = 0
        with self.key_lock(key, exclusive=True):
            key_dir = self._key_dir(key)
            ensure_private_dir(key_dir)
            existing = self._meta(key) or {}
            generation = int(existing.get("generation") or 0)
            if generation != context.observed_generation:
                return {"state": "publicationSkipped", "reason": "newer generation already published", "generation": generation}
            if (
                existing.get("publishedAt")
                and self._validate_seed(key, existing)
                and self._clock() - float(existing["publishedAt"]) < BUILD_CACHE_PUBLISH_THROTTLE_SECONDS
            ):
                return {"state": "publicationSkipped", "reason": "publication throttled", "generation": generation}
            next_generation = generation + 1
            temporary = key_dir / f"seed.tmp-{uuid.uuid4().hex}"
            previous = key_dir / f"seed.previous-{uuid.uuid4().hex}"
            seed = key_dir / "seed"
            swapped = False
            publication_committed = False
            try:
                ensure_private_dir(temporary)
                cloned = self._clone_runner(build_dir, temporary / ".build")
                if not cloned:
                    return {"state": "publicationSkipped", "reason": "COW publication clone failed"}
                self._sanitize_seed(temporary / ".build")
                _atomic_write_json(temporary / ".generation.json", {"key": key, "generation": next_generation})
                size = self._disk_usage_bytes(temporary / ".build")
                source_head = self._source_head(self.repo_root)
                meta = {
                    "schemaVersion": BUILD_CACHE_SCHEMA_VERSION,
                    "key": key,
                    "generation": next_generation,
                    "toolchainSignature": context.snapshot.toolchain_signature,
                    "compatibility": context.snapshot.payload,
                    "sourceHead": source_head,
                    "publishedAt": self._clock(),
                    "lastUsedAt": self._clock(),
                    "sizeBytes": size,
                    "suspectCount": 0,
                }
                if seed.exists():
                    os.replace(seed, previous)
                os.replace(temporary, seed)
                swapped = True
                _atomic_write_json(key_dir / "meta.json", meta)
                publication_committed = True
            except Exception:
                if swapped:
                    if previous.exists():
                        try:
                            self._remove_owned_temporary(seed)
                            os.replace(previous, seed)
                        except Exception:
                            # Preserve the recoverable previous generation for the next
                            # locked maintenance sweep rather than deleting it blindly.
                            pass
                    else:
                        with contextlib.suppress(OSError):
                            self._remove_owned_temporary(seed)
                elif previous.exists() and not seed.exists():
                    with contextlib.suppress(OSError):
                        os.replace(previous, seed)
                raise
            finally:
                if temporary.exists():
                    with contextlib.suppress(OSError):
                        self._remove_owned_temporary(temporary)
                if publication_committed and previous.exists():
                    with contextlib.suppress(OSError):
                        self._remove_owned_temporary(previous)
        retention = self.enforce_retention(context.snapshot.toolchain_signature)
        return {"state": "published", "key": key, "generation": next_generation, "sizeBytes": size, "retention": retention}

    def confirm_seeded_failure(self, key: str) -> Dict[str, Any]:
        with self.key_lock(key, exclusive=True):
            key_dir = self._key_dir(key)
            meta = self._meta(key) or {"key": key, "generation": 0}
            count = int(meta.get("suspectCount") or 0) + 1
            meta["suspectCount"] = count
            meta["lastSuspectAt"] = self._clock()
            quarantined = False
            seed = key_dir / "seed"
            if count >= 2 and seed.exists() and not seed.is_symlink():
                quarantine = key_dir / f"suspect-{int(self._clock())}-{uuid.uuid4().hex[:8]}"
                os.replace(seed, quarantine)
                shutil.rmtree(quarantine, ignore_errors=True)
                meta["quarantinedAt"] = self._clock()
                quarantined = True
            ensure_private_dir(key_dir)
            _atomic_write_json(key_dir / "meta.json", meta)
            return {"suspectCount": count, "quarantined": quarantined}

    def enforce_retention(self, current_toolchain_signature: str) -> Dict[str, Any]:
        self._ensure_store_dirs()
        hygiene = self._sweep_stranded_store_temporaries()
        try:
            limit = int(self.env.get("REPOPROMPT_DEV_BUILD_CACHE_LIMIT_BYTES") or BUILD_CACHE_DEFAULT_LIMIT_BYTES)
        except ValueError:
            limit = BUILD_CACHE_DEFAULT_LIMIT_BYTES
        rows: List[Tuple[bool, float, int, str]] = []
        for child in self.store_root.iterdir():
            if not child.is_dir() or not re.fullmatch(r"[0-9a-f]{64}", child.name):
                continue
            meta = self._meta(child.name) or {}
            rows.append((meta.get("toolchainSignature") == current_toolchain_signature, float(meta.get("lastUsedAt") or 0.0), int(meta.get("sizeBytes") or 0), child.name))
        total = sum(row[2] for row in rows)
        evicted: List[str] = []
        for _same_toolchain, _used, size, key in sorted(rows):
            if total <= max(0, limit):
                break
            try:
                with self.key_lock(key, exclusive=True, nonblocking=True):
                    key_dir = self._key_dir(key)
                    if key_dir.exists() and not key_dir.is_symlink():
                        shutil.rmtree(key_dir)
                        total -= size
                        evicted.append(key)
            except BlockingIOError:
                continue
        return {"limitBytes": limit, "remainingBytes": total, "evictedKeys": evicted, "hygiene": hygiene}

    def status(self, limit: int = BUILD_CACHE_DIAGNOSTIC_MAX_ROWS) -> Dict[str, Any]:
        entries: List[Dict[str, Any]] = []
        try:
            children = list(self.store_root.iterdir())
        except (FileNotFoundError, NotADirectoryError, PermissionError):
            children = []
        for child in children:
            if child.is_dir() and not child.is_symlink() and re.fullmatch(r"[0-9a-f]{64}", child.name):
                meta = self._meta(child.name) or {"key": child.name, "state": "invalidMetadata"}
                entries.append(meta)
        entries.sort(key=lambda item: float(item.get("lastUsedAt") or item.get("publishedAt") or 0.0), reverse=True)
        return {
            "storePath": str(self.store_root),
            "readOnly": True,
            "entryCount": len(entries),
            "entries": entries[: max(1, min(limit, 100))],
        }

    def drop(self, key: str) -> bool:
        with self.key_lock(key, exclusive=True):
            key_dir = self._key_dir(key)
            if not key_dir.exists():
                return False
            if key_dir.is_symlink():
                raise ConductorError("refusing symlink build-cache entry")
            shutil.rmtree(key_dir)
            return True


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


@dataclasses.dataclass
class FairHeavyLease:
    coordinator: "FairHeavyAdmission"
    lock_file: Any
    lock_path: Path
    waiter_id: str

    def release(self) -> None:
        self.coordinator.release(self)


class FairHeavyAdmission:
    """Persistent FIFO ordering around kernel-authoritative heavy slot flocks."""

    def __init__(
        self,
        metadata: Dict[str, Any],
        env: Optional[Dict[str, str]],
        *,
        identity_provider: Any = None,
        clock: Any = time.monotonic,
        on_warning: Any = None,
    ) -> None:
        self.metadata = dict(metadata)
        self.env = dict(env or {})
        self._clock = clock
        self._on_warning = on_warning or (lambda _kind, _message: None)
        self._remote_process_snapshot: Optional[Dict[int, Tuple[int, str]]] = None
        self._remote_process_snapshot_at: Optional[float] = None
        self.legacy_slot_holder: Optional[Dict[str, Any]] = None
        self._legacy_slot_holder_observed_at: Optional[float] = None
        self.current_rescan_seconds = FAIR_HEAVY_RESCAN_SECONDS
        self._eligible_since: Optional[float] = None
        self.owner_pid = os.getpid()
        identity = identity_provider or process_start_token
        self.owner_start = identity(self.owner_pid)
        if not self.owner_start:
            raise ConductorError("global-heavy admission requires an exact owner process start token")
        self.waiter_id = uuid.uuid4().hex[:12]
        self.root = machine_lock_dir()
        self.queue_lock_path = self.root / "global-heavy-queue.lock"
        self.queue_path = self.root / "global-heavy-queue.json"
        self.waiters_dir = self.root / "heavy-waiters"
        ensure_private_dir(self.root)
        ensure_private_dir(self.waiters_dir)
        self.notify_path = self.waiters_dir / f"{self.waiter_id}.sock"
        if len(os.fsencode(self.notify_path)) >= 100:
            self.notify_path = self.root / f"w-{self.waiter_id}.sock"
        self.notify_socket = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        self._closed = False
        try:
            self.notify_socket.bind(str(self.notify_path))
            os.chmod(self.notify_path, 0o600)
            self.notify_socket.settimeout(FAIR_HEAVY_RESCAN_SECONDS)
            self._enqueue()
        except Exception:
            self.close()
            raise

    @contextlib.contextmanager
    def _queue_lock(self):
        lock_file = self.queue_lock_path.open("a+", encoding="utf-8")
        os.chmod(self.queue_lock_path, 0o600)
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
            lock_file.close()

    @staticmethod
    def _empty_queue() -> Dict[str, Any]:
        return {"version": 1, "generation": 0, "nextSequence": 1, "waiters": []}

    def _quarantine_invalid_queue(self, reason: str) -> Dict[str, Any]:
        quarantine = self.queue_path.with_name(
            f"global-heavy-queue.corrupt-{int(self._clock() * 1_000_000)}-{uuid.uuid4().hex[:8]}.json"
        )
        try:
            os.replace(self.queue_path, quarantine)
        except FileNotFoundError:
            return self._empty_queue()
        self._on_warning("fairQueueQuarantined", f"quarantined invalid fair queue at {quarantine}: {reason}")
        return self._empty_queue()

    def _load_queue(self) -> Dict[str, Any]:
        try:
            info = self.queue_path.lstat()
        except FileNotFoundError:
            return self._empty_queue()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ConductorError(f"unsafe global-heavy queue state preserved at {self.queue_path}")
        try:
            payload = json.loads(self.queue_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            return self._quarantine_invalid_queue(str(exc))
        except OSError as exc:
            raise ConductorError(f"could not read global-heavy queue state at {self.queue_path}: {exc}") from exc
        if not isinstance(payload, dict) or payload.get("version") != 1 or not isinstance(payload.get("waiters"), list):
            return self._quarantine_invalid_queue("unsupported queue schema")
        if not isinstance(payload.get("generation"), int) or not isinstance(payload.get("nextSequence"), int):
            return self._quarantine_invalid_queue("invalid queue counters")
        for waiter in payload["waiters"]:
            if not (
                isinstance(waiter, dict)
                and isinstance(waiter.get("waiterID"), str)
                and waiter.get("waiterID")
                and type(waiter.get("sequence")) is int
                and int(waiter["sequence"]) >= 0
                and waiter.get("state") in {"waiting", "acquired"}
                and type(waiter.get("ownerPID")) is int
                and int(waiter["ownerPID"]) > 0
                and isinstance(waiter.get("ownerStartToken"), str)
                and waiter.get("ownerStartToken")
                and isinstance(waiter.get("notifySocketPath"), str)
                and waiter.get("notifySocketPath")
            ):
                return self._quarantine_invalid_queue("invalid waiter record")
        return payload

    def _write_queue(self, payload: Dict[str, Any]) -> None:
        temporary = self.queue_path.with_name(f".{self.queue_path.name}.{uuid.uuid4().hex}.tmp")
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        replaced = False
        try:
            encoded = json.dumps(payload, indent=2, sort_keys=True).encode("utf-8")
            remaining = memoryview(encoded)
            while remaining:
                written = os.write(fd, remaining)
                if written <= 0:
                    raise OSError(errno.EIO, "short write while persisting global-heavy queue")
                remaining = remaining[written:]
            os.fsync(fd)
            os.close(fd)
            fd = -1
            os.replace(temporary, self.queue_path)
            replaced = True
            directory_fd = os.open(self.queue_path.parent, os.O_RDONLY)
            try:
                with contextlib.suppress(OSError):
                    os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            if fd >= 0:
                os.close(fd)
            if not replaced:
                with contextlib.suppress(FileNotFoundError):
                    temporary.unlink()

    def _notify_path_is_live(self, waiter: Dict[str, Any]) -> bool:
        raw_path = waiter.get("notifySocketPath")
        if not isinstance(raw_path, str) or not raw_path:
            return False
        path = Path(raw_path)
        allowed_parents = {self.waiters_dir, self.root}
        if path.parent not in allowed_parents:
            return False
        try:
            info = path.lstat()
        except OSError:
            return False
        return stat.S_ISSOCK(info.st_mode) and info.st_uid == os.getuid()

    def _cached_remote_process_snapshot(self, *, force: bool = False) -> Optional[Dict[int, Tuple[int, str]]]:
        timestamp = self._clock()
        if (
            force
            or self._remote_process_snapshot is None
            or self._remote_process_snapshot_at is None
            or timestamp - self._remote_process_snapshot_at >= FAIR_PROCESS_SNAPSHOT_TTL_SECONDS
        ):
            snapshot = process_table_snapshot()
            if snapshot is None:
                return None
            self._remote_process_snapshot = snapshot
            self._remote_process_snapshot_at = timestamp
        return self._remote_process_snapshot

    def _prune_stale(self, payload: Dict[str, Any]) -> List[Dict[str, Any]]:
        retained: List[Dict[str, Any]] = []
        remote_snapshot: Optional[Dict[int, Tuple[int, str]]] = None
        remote_snapshot_was_cached = False
        remote_snapshot_refreshed_for_negative = False
        remote_snapshot_inconclusive = False
        for waiter in payload["waiters"]:
            if not isinstance(waiter, dict) or not self._notify_path_is_live(waiter):
                continue
            try:
                pid = int(waiter.get("ownerPID"))
            except (TypeError, ValueError):
                continue
            token = waiter.get("ownerStartToken")
            if not isinstance(token, str) or not token or pid <= 0:
                continue
            if pid == self.owner_pid and token == self.owner_start:
                retained.append(waiter)
                continue
            if remote_snapshot_inconclusive:
                retained.append(waiter)
                continue
            if remote_snapshot is None:
                timestamp = self._clock()
                remote_snapshot_was_cached = bool(
                    self._remote_process_snapshot is not None
                    and self._remote_process_snapshot_at is not None
                    and timestamp - self._remote_process_snapshot_at < FAIR_PROCESS_SNAPSHOT_TTL_SECONDS
                )
                remote_snapshot = self._cached_remote_process_snapshot()
            if remote_snapshot is None:
                remote_snapshot_inconclusive = True
                retained.append(waiter)
                continue
            record = remote_snapshot.get(pid)
            if (
                (record is None or record[1] != token)
                and remote_snapshot_was_cached
                and not remote_snapshot_refreshed_for_negative
            ):
                remote_snapshot = self._cached_remote_process_snapshot(force=True)
                remote_snapshot_refreshed_for_negative = True
                if remote_snapshot is None:
                    remote_snapshot_inconclusive = True
                    retained.append(waiter)
                    continue
                record = remote_snapshot.get(pid)
            if record is not None and record[1] == token:
                retained.append(waiter)
        if len(retained) != len(payload["waiters"]):
            payload["waiters"] = retained
            payload["generation"] += 1
        return retained

    def _enqueue(self) -> None:
        with self._queue_lock():
            payload = self._load_queue()
            self._prune_stale(payload)
            sequence = int(payload["nextSequence"])
            payload["nextSequence"] = sequence + 1
            payload["generation"] += 1
            payload["waiters"].append(
                {
                    "waiterID": self.waiter_id,
                    "sequence": sequence,
                    "state": "waiting",
                    "ownerPID": self.owner_pid,
                    "ownerStartToken": self.owner_start,
                    "ticket": self.metadata.get("ticket"),
                    "operation": self.metadata.get("operation"),
                    "operationLabel": self.metadata.get("operationLabel"),
                    "repoRoot": self.metadata.get("repoRoot"),
                    "repoHash": self.metadata.get("repoHash"),
                    "worktree": self.metadata.get("worktree"),
                    "enqueuedAt": now(),
                    "acquiredSlotPath": None,
                    "notifySocketPath": str(self.notify_path),
                }
            )
            self._write_queue(payload)

    def _queue_snapshot(self) -> Tuple[Dict[str, Any], Dict[str, Any], int, List[Dict[str, Any]]]:
        with self._queue_lock():
            payload = self._load_queue()
            before_generation = payload["generation"]
            waiters = self._prune_stale(payload)
            if payload["generation"] != before_generation:
                self._write_queue(payload)
            ordered = sorted(waiters, key=lambda item: int(item.get("sequence", 0)))
            for index, waiter in enumerate(ordered):
                if (
                    waiter.get("waiterID") == self.waiter_id
                    and waiter.get("ownerPID") == self.owner_pid
                    and waiter.get("ownerStartToken") == self.owner_start
                ):
                    return payload, waiter, index + 1, ordered
        raise ConductorError("global-heavy waiter identity disappeared before admission")

    def _remove_own_waiter(self) -> None:
        notify_paths: List[str] = []
        with self._queue_lock():
            payload = self._load_queue()
            original = list(payload["waiters"])
            payload["waiters"] = [
                waiter
                for waiter in original
                if not (
                    isinstance(waiter, dict)
                    and waiter.get("waiterID") == self.waiter_id
                    and waiter.get("ownerPID") == self.owner_pid
                    and waiter.get("ownerStartToken") == self.owner_start
                )
            ]
            if len(payload["waiters"]) != len(original):
                payload["generation"] += 1
                self._write_queue(payload)
            notify_paths = [
                str(waiter.get("notifySocketPath"))
                for waiter in payload["waiters"]
                if isinstance(waiter, dict) and waiter.get("state") == "waiting" and waiter.get("notifySocketPath")
            ]
        self._notify(notify_paths)

    @staticmethod
    def _notify(paths: Sequence[str]) -> None:
        sender = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        try:
            for path in paths:
                with contextlib.suppress(OSError):
                    sender.sendto(b"rescan", path)
        finally:
            sender.close()

    def wait(
        self,
        cancel_check: Any = lambda: False,
        update: Any = lambda _position, _earlier: None,
    ) -> Optional[FairHeavyLease]:
        try:
            return self._wait_until_acquired(cancel_check=cancel_check, update=update)
        except BaseException:
            self.abandon()
            raise

    def _observe_legacy_slot_holder(self, slot_path: Path) -> None:
        observed_at = self._clock()
        if (
            self.legacy_slot_holder is not None
            and self.legacy_slot_holder.get("slotPath") == str(slot_path)
            and self._legacy_slot_holder_observed_at is not None
            and observed_at - self._legacy_slot_holder_observed_at < FAIR_PROCESS_SNAPSHOT_TTL_SECONDS
        ):
            return
        metadata = read_display_lock_metadata(slot_path)
        self._legacy_slot_holder_observed_at = observed_at
        self.legacy_slot_holder = (
            {
                "displayOnly": True,
                "authoritative": False,
                "classification": "legacyOrUnregistered",
                "slotPath": str(slot_path),
                "metadata": metadata,
            }
            if metadata
            else None
        )

    def _wait_until_acquired(
        self,
        cancel_check: Any,
        update: Any,
    ) -> Optional[FairHeavyLease]:
        slot_paths = global_heavy_slot_paths(self.env)
        while True:
            if cancel_check():
                self._remove_own_waiter()
                self.close()
                return None
            _payload, _waiter, position, ordered = self._queue_snapshot()
            earlier = [
                {
                    "ticket": item.get("ticket"),
                    "operationLabel": item.get("operationLabel"),
                    "state": item.get("state"),
                    "slotPath": item.get("acquiredSlotPath"),
                }
                for item in ordered[: max(0, position - 1)]
            ]
            eligible = position <= configured_global_heavy_slots(self.env)
            if eligible:
                observed_at = self._clock()
                if self._eligible_since is None:
                    self._eligible_since = observed_at
                competition_age = max(0.0, observed_at - self._eligible_since)
                self.current_rescan_seconds = (
                    FAIR_HEAVY_HEAD_RESCAN_SECONDS
                    if competition_age < FAIR_HEAVY_HEAD_COMPETITION_SECONDS
                    else FAIR_HEAVY_HEAD_DECAY_RESCAN_SECONDS
                )
            else:
                self._eligible_since = None
                self.current_rescan_seconds = FAIR_HEAVY_RESCAN_SECONDS
                self.legacy_slot_holder = None
                self._legacy_slot_holder_observed_at = None
            update(position, earlier)
            if eligible:
                explained_slots = {
                    str(item.get("acquiredSlotPath"))
                    for item in ordered[: max(0, position - 1)]
                    if item.get("state") == "acquired" and item.get("acquiredSlotPath")
                }
                observed_unexplained_holder = False
                for slot_path in slot_paths:
                    lock_file = slot_path.open("a+", encoding="utf-8")
                    try:
                        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        lock_file.close()
                        if str(slot_path) not in explained_slots and not observed_unexplained_holder:
                            self._observe_legacy_slot_holder(slot_path)
                            observed_unexplained_holder = True
                        continue
                    except OSError as exc:
                        lock_file.close()
                        if exc.errno == errno.EINTR:
                            continue
                        raise
                    with self._queue_lock():
                        payload = self._load_queue()
                        ordered_now = sorted(payload["waiters"], key=lambda item: int(item.get("sequence", 0)))
                        matching = [item for item in ordered_now if item.get("waiterID") == self.waiter_id]
                        eligible = bool(
                            matching
                            and matching[0].get("ownerPID") == self.owner_pid
                            and matching[0].get("ownerStartToken") == self.owner_start
                            and ordered_now.index(matching[0]) < configured_global_heavy_slots(self.env)
                        )
                        if eligible:
                            matching[0]["state"] = "acquired"
                            matching[0]["acquiredSlotPath"] = str(slot_path)
                            payload["generation"] += 1
                            self._write_queue(payload)
                            write_display_lock_metadata(lock_file, self.metadata)
                            self.legacy_slot_holder = None
                            self._legacy_slot_holder_observed_at = None
                            return FairHeavyLease(self, lock_file, slot_path, self.waiter_id)
                    fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
                    lock_file.close()
                if observed_unexplained_holder:
                    update(position, earlier)
            self.notify_socket.settimeout(self.current_rescan_seconds)
            with contextlib.suppress(socket.timeout, BlockingIOError, OSError):
                self.notify_socket.recv(64)

    def abandon(self) -> None:
        try:
            self._remove_own_waiter()
        except Exception:
            # Closing removes the private notify socket. Any later queue scan then
            # has durable proof that this waiter is abandoned, even if its removal
            # could not be persisted during the original failure.
            pass
        finally:
            self.close()

    def release(self, lease: FairHeavyLease) -> None:
        if lease.waiter_id != self.waiter_id:
            raise ConductorError("refusing to release a different global-heavy waiter")
        with contextlib.suppress(OSError):
            lease.lock_file.seek(0)
            lease.lock_file.truncate()
            lease.lock_file.flush()
        with contextlib.suppress(OSError):
            fcntl.flock(lease.lock_file.fileno(), fcntl.LOCK_UN)
        with contextlib.suppress(OSError):
            lease.lock_file.close()
        try:
            self._remove_own_waiter()
        finally:
            self.close()

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        self.notify_socket.close()
        with contextlib.suppress(FileNotFoundError):
            self.notify_path.unlink()


@contextlib.contextmanager
def machine_heavy_slot(metadata: Dict[str, Any], env: Optional[Dict[str, str]], wait_label: str):
    coordinator = FairHeavyAdmission(metadata, env)
    did_log_wait = False

    def update(position: int, earlier: List[Dict[str, Any]]) -> None:
        nonlocal did_log_wait
        if not did_log_wait and position > configured_global_heavy_slots(env):
            holder = earlier[0] if earlier else {}
            print(
                f"waiting for {wait_label}: fair queue position {position}; "
                f"earlier={holder.get('operationLabel') or 'unknown'} ticket={holder.get('ticket') or 'unknown'}",
                flush=True,
            )
            did_log_wait = True

    lease = coordinator.wait(update=update)
    if lease is None:
        raise ConductorError(f"{wait_label} admission canceled")
    try:
        print(f"acquired {wait_label}: {lease.lock_path}", flush=True)
        yield lease.lock_file
    finally:
        lease.release()


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


@dataclasses.dataclass(frozen=True)
class DaemonRecoveryResult:
    state: str
    cleaned: bool
    reason: str


def _path_identity(path: Path) -> Optional[Tuple[int, int, int]]:
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    return (int(info.st_dev), int(info.st_ino), int(info.st_mode))


def _read_valid_daemon_metadata(paths: Paths, pid: int) -> Optional[Dict[str, Any]]:
    try:
        info = paths.daemon_meta_path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            return None
        metadata = json.loads(paths.daemon_meta_path.read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return None
    if not (
        isinstance(metadata, dict)
        and metadata.get("pid") == pid
        and metadata.get("repoRoot") == str(paths.repo_root)
        and metadata.get("repoHash") == paths.repo_hash
        and metadata.get("script") == str(Path(__file__).resolve())
        and isinstance(metadata.get("processStart"), str)
        and metadata.get("processStart")
    ):
        return None
    return metadata


def _classify_socket_for_recovery(paths: Paths) -> str:
    try:
        socket_info = paths.socket_path.lstat()
    except FileNotFoundError:
        return "absent"
    try:
        parent_info = paths.socket_path.parent.stat()
    except OSError:
        return "ambiguous"
    if (
        not stat.S_ISSOCK(socket_info.st_mode)
        or socket_info.st_uid != os.getuid()
        or parent_info.st_uid != os.getuid()
        or parent_info.st_mode & 0o077
    ):
        return "ambiguous"
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        probe.settimeout(REQUEST_READ_TIMEOUT_SECONDS)
        probe.connect(str(paths.socket_path))
        return "responsive"
    except FileNotFoundError:
        return "absent"
    except ConnectionRefusedError:
        return "refused"
    except (socket.timeout, PermissionError, OSError):
        return "ambiguous"
    finally:
        probe.close()


def cleanup_stale_files(paths: Paths, *, startup_lock_held: bool = False) -> DaemonRecoveryResult:
    evidence_paths = (paths.pid_path, paths.socket_path, paths.daemon_meta_path)
    identities = {path: _path_identity(path) for path in evidence_paths}
    if all(identity is None for identity in identities.values()):
        return DaemonRecoveryResult("stopped", False, "no daemon evidence")

    pid = read_pid(paths.pid_path)
    if pid is None:
        return DaemonRecoveryResult("ambiguous", False, "daemon pid evidence is missing or unsafe")
    metadata = _read_valid_daemon_metadata(paths, pid)
    if metadata is None:
        return DaemonRecoveryResult("ambiguous", False, "daemon metadata is missing or unsafe")
    reused_pid_proven = False
    if pid_alive(pid):
        current_start = process_start_token(pid)
        if current_start is None:
            return DaemonRecoveryResult("ambiguous", False, "live recorded daemon pid lacks current start-token proof")
        if current_start == metadata["processStart"]:
            return DaemonRecoveryResult("live", False, "recorded daemon identity is alive")
        reused_pid_proven = True

    socket_state = _classify_socket_for_recovery(paths)
    if socket_state not in {"absent", "refused"}:
        reason = "recorded daemon pid was reused" if reused_pid_proven else "recorded daemon is dead"
        return DaemonRecoveryResult("ambiguous", False, f"{reason}, but daemon socket is {socket_state}")

    for path, identity in identities.items():
        if identity is not None and _path_identity(path) != identity:
            return DaemonRecoveryResult("ambiguous", False, f"daemon evidence changed during recovery: {path}")
    registry_identity = _path_identity(paths.running_processes_path)
    if registry_identity is not None:
        # Keep the pre-cleanup inode as a concurrency fence. Worker cleanup may
        # remove registry-bound attempt sidecars, but it must not replace or
        # unlink the registry itself. Refreshing this identity afterward would
        # incorrectly bless a replacement daemon's concurrently written state.
        worker_cleanup = cleanup_running_process_groups(paths)
        if not worker_cleanup.get("safeToForget"):
            return DaemonRecoveryResult(
                "ambiguous",
                False,
                "recorded daemon is stale, but worker process-group cleanup lacks exact bounded completion evidence",
            )
    final_identities = (*identities.items(), (paths.running_processes_path, registry_identity))

    def finalize_locked() -> DaemonRecoveryResult:
        for path, identity in final_identities:
            if identity is None:
                continue
            if _path_identity(path) != identity:
                return DaemonRecoveryResult("ambiguous", False, f"daemon evidence changed before cleanup: {path}")
        for path, identity in final_identities:
            if identity is None:
                continue
            with contextlib.suppress(FileNotFoundError):
                path.unlink()
        cleanup_reason = "proven pid reuse" if reused_pid_proven else "dead recorded daemon"
        return DaemonRecoveryResult(
            "cleaned",
            True,
            f"removed stale daemon evidence after {cleanup_reason} and {socket_state} socket proof",
        )

    if startup_lock_held:
        return finalize_locked()
    with paths.lock_path.open("a+") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        try:
            return finalize_locked()
        finally:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


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


def process_table_snapshot() -> Optional[Dict[int, Tuple[int, str]]]:
    try:
        completed = subprocess.run(
            ["ps", "-axo", "pid=,ppid=,lstart="],
            text=True,
            capture_output=True,
            timeout=2.0,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if completed.returncode != 0:
        return None
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


@dataclasses.dataclass(frozen=True)
class SafeFileSample:
    content: bytes
    file_size: int
    sampled_bytes: int
    omitted_bytes: int


def read_safe_regular_file_sample(path: Path, head_bytes: int, tail_bytes: int) -> SafeFileSample:
    flags = os.O_RDONLY | os.O_NONBLOCK
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise ConductorError(f"refusing non-regular file {path}")
        if info.st_uid != os.getuid():
            raise ConductorError(f"refusing file not owned by current user {path}")
        file_size = max(0, int(info.st_size))
        limit = max(0, head_bytes) + max(0, tail_bytes)
        if file_size <= limit:
            content = os.pread(fd, file_size, 0)
            return SafeFileSample(content, file_size, len(content), max(0, file_size - len(content)))

        head = os.pread(fd, max(0, head_bytes), 0)
        tail_offset = max(0, file_size - max(0, tail_bytes))
        tail = os.pread(fd, max(0, tail_bytes), tail_offset)
        head_boundary = head.rfind(b"\n")
        if head_boundary >= 0:
            head = head[: head_boundary + 1]
        tail_boundary = tail.find(b"\n")
        if tail_boundary >= 0:
            tail = tail[tail_boundary + 1 :]
        sampled = len(head) + len(tail)
        omitted = max(0, file_size - sampled)
        marker = f"\n... [conductor omitted {omitted} middle log bytes] ...\n".encode("utf-8")
        return SafeFileSample(head + marker + tail, file_size, sampled, omitted)
    finally:
        os.close(fd)


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
        self._entries: List[str] = []
        self._counts: Dict[str, int] = {}
        self.omitted = 0

    @property
    def lines(self) -> List[str]:
        return [
            line if self._counts.get(line, 1) == 1 else f"{line} (repeated {self._counts[line]} times)"
            for line in self._entries
        ]

    def clear(self) -> None:
        self._entries.clear()
        self._counts.clear()
        self.omitted = 0

    def add(self, line: str) -> None:
        cleaned = clean_summary_line(line)
        if not cleaned:
            return
        if cleaned in self._counts:
            self._counts[cleaned] += 1
            return
        if len(self._entries) < self.max_lines:
            self._entries.append(cleaned)
            self._counts[cleaned] = 1
        elif self.keep_last:
            removed = self._entries.pop(0)
            del self._counts[removed]
            self._entries.append(cleaned)
            self._counts[cleaned] = 1
            self.omitted += 1
        else:
            self.omitted += 1

    def extend(self, lines: Sequence[str]) -> None:
        for line in lines:
            self.add(line)

    def payload(self) -> Optional[Dict[str, Any]]:
        lines = self.lines
        if not lines:
            return None
        return {
            "title": self.title,
            "lines": lines,
            "truncated": self.omitted > 0,
            "omittedLineCount": self.omitted,
        }


class OutputSummarizer:
    FAILURE_RE = re.compile(
        r"(ERROR:|FAILED|failed with|process exited with status|fatal error|Traceback|Exception|Permission denied|No such file or directory|timed out|killing process (?:group|tree)|terminating process (?:group|tree))",
        re.IGNORECASE,
    )
    SWIFT_ERROR_RE = re.compile(r"(: error:|error: emit-module command failed|Command SwiftCompile failed|Command CompileSwift failed|fatal error:)")
    WARNING_RE = re.compile(r"(: warning:|^WARNING:)", re.IGNORECASE)
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
            sample = read_safe_regular_file_sample(
                log_path,
                SUMMARY_FILE_HEAD_BYTES,
                SUMMARY_FILE_TAIL_BYTES,
            )
            summary = cls.summarize_lines(
                operation,
                args,
                state,
                exit_code,
                timed_out,
                sample.content.decode("utf-8", errors="replace").splitlines(keepends=True),
            )
            summary["sampledBytes"] = sample.sampled_bytes
            summary["omittedInputBytes"] = sample.omitted_bytes
            if sample.omitted_bytes:
                summary["inputTruncated"] = True
                summary["truncated"] = True
            return summary
        except (OSError, ConductorError) as exc:
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
        summary_start = now()
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
        input_bytes = 0
        input_line_limit_reached = False
        input_byte_limit_reached = False
        warning_count = 0
        error_count = 0
        tail: Deque[str] = deque(maxlen=20)
        previous_context: Deque[str] = deque(maxlen=SUMMARY_CONTEXT_BEFORE)
        pending_context: List[Tuple[str, int]] = []
        style_operation = operation in {"format", "format-check", "lint", "check-format-tools", "install-format-tools", "format-tools-status"}

        for raw_line in itertools.islice(lines_iterable, SUMMARY_INPUT_MAX_LINES):
            raw_text = str(raw_line)
            raw_bytes = len(raw_text.encode("utf-8", errors="replace"))
            if input_bytes + raw_bytes > SUMMARY_INPUT_MAX_BYTES:
                input_byte_limit_reached = True
                break
            line_count += 1
            input_bytes += raw_bytes
            line = clean_summary_line(raw_text)
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
                if failure or cls.WARNING_RE.match(line):
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

        if line_count >= SUMMARY_INPUT_MAX_LINES:
            input_line_limit_reached = True
        input_truncated = input_line_limit_reached or input_byte_limit_reached
        if input_truncated:
            reached = []
            if input_line_limit_reached:
                reached.append(f"{SUMMARY_INPUT_MAX_LINES} line limit")
            if input_byte_limit_reached:
                reached.append(f"{SUMMARY_INPUT_MAX_BYTES} byte limit")
            sections["Summary notes"].add(
                f"Summary input bounded after reaching {' and '.join(reached)}; see the full log path."
            )

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
            sections["Recent output"].clear()

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
            "inputBytes": input_bytes,
            "inputTruncated": input_truncated,
            "inputLineLimitReached": input_line_limit_reached,
            "inputByteLimitReached": input_byte_limit_reached,
            "omittedLineCount": omitted_line_count,
            "errorCount": error_count,
            "warningCount": warning_count,
            "summaryDurationSeconds": round(now() - summary_start, 6),
            "launchLifecycle": launch_lifecycle,
            "sections": payload_sections,
            "truncated": truncated or input_truncated,
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
            "summaryDurationSeconds": 0.0,
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


def job_consumes_unlaned_capacity(operation: str, lanes: Sequence[str]) -> bool:
    return not lanes and operation != "format-tools-status"


def operation_requires_global_heavy_slot(operation: str, args: Dict[str, Any]) -> bool:
    if operation in {"swift-build", "build", "package", "test", "provider-test", "install-debug-cli"}:
        return True
    if operation in {"sleep", "fake-sleep"} and "build" in set(args.get("lanes") or []):
        return True
    if operation == "release" and args.get("subcommand") in {"artifact", "package", "local-install"}:
        return True
    if operation == "diagnostics" and args.get("subcommand") == "focused-build":
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


@dataclasses.dataclass(frozen=True)
class JobLease:
    ticket: str
    job_generation: int


@dataclasses.dataclass(frozen=True)
class ProcessWorkLease:
    ticket: str
    job_generation: int
    process_generation: int
    pid: Optional[int]
    pgid: Optional[int]
    process_start: Optional[str]
    process_group_identity_confirmed: bool
    tracked_processes: Dict[int, str]


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
    job_generation: int = 0
    process_generation: int = 0
    phase: str = "queued"
    phase_changed_at: float = dataclasses.field(default_factory=now)
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
    global_heavy_legacy_slot_holder: Optional[Dict[str, Any]] = None
    global_heavy_admission_state: str = "notRequired"
    global_heavy_queue_position: Optional[int] = None
    global_heavy_waiter_id: Optional[str] = None
    global_heavy_rescan_seconds: Optional[float] = None
    exit_code: Optional[int] = None
    error: Optional[str] = None
    result_summary: Optional[str] = None
    cancel_requested: bool = False
    cancellation_ignored_reason: Optional[str] = None
    cache_attempt_record_path: Optional[Path] = dataclasses.field(default=None, repr=False)
    cleanup_in_flight: bool = False
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
    summary_generation: int = 0
    summary_in_flight: bool = False
    infrastructure_warnings: List[Dict[str, Any]] = dataclasses.field(default_factory=list)
    log_sequence: int = 0
    log_flushed_sequence: int = 0
    log_settled_sequences: set[int] = dataclasses.field(default_factory=set, repr=False)
    log_truncated: bool = False
    log_truncation_reason: Optional[str] = None
    output_truncated: bool = False
    output_truncation_reason: Optional[str] = None
    output_bytes_read: int = 0
    tail_bytes: int = 0
    build_cache: Dict[str, Any] = dataclasses.field(default_factory=dict)
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
            "phase": self.phase,
            "phaseChangedAt": self.phase_changed_at,
            "phaseChangedAtISO": iso_timestamp(self.phase_changed_at),
            "jobGeneration": self.job_generation,
            "processGeneration": self.process_generation,
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
            "globalHeavyAdmission": {
                "displayOnly": True,
                "state": self.global_heavy_admission_state,
                "configuredSlots": configured_global_heavy_slots(self.env),
                "queuePosition": self.global_heavy_queue_position,
                "waiterID": self.global_heavy_waiter_id,
                "rescanSeconds": self.global_heavy_rescan_seconds,
                "headCompetitionSeconds": FAIR_HEAVY_HEAD_COMPETITION_SECONDS,
                "slotPath": self.global_heavy_slot_path,
                "waitSeconds": self.global_heavy_slot_wait_seconds,
                "holder": self.global_heavy_slot_holder,
                "legacySlotHolder": self.global_heavy_legacy_slot_holder,
            },
            "logTruncated": self.log_truncated,
            "logTruncationReason": self.log_truncation_reason,
            "outputTruncated": self.output_truncated,
            "outputTruncationReason": self.output_truncation_reason,
            "outputBytesRead": self.output_bytes_read,
            "exitCode": self.exit_code,
            "error": self.error,
            "resultSummary": self.result_summary,
            "cancelRequested": self.cancel_requested,
            "cancellationIgnored": self.cancellation_ignored_reason is not None,
            "cancellationIgnoredReason": self.cancellation_ignored_reason,
            "cacheAttemptRecoveryRecord": (
                str(self.cache_attempt_record_path) if self.cache_attempt_record_path is not None else None
            ),
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
            "buildCache": dict(self.build_cache),
        }
        if self.diagnostics:
            payload["diagnostics"] = list(self.diagnostics)
        if self.infrastructure_warnings:
            payload["infrastructureWarnings"] = list(self.infrastructure_warnings)
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
        "ARCHS",
        "ONLY_ACTIVE_ARCH",
        "OTHER_SWIFT_FLAGS",
        "SWIFTFLAGS",
        "TMPDIR",
        "HOME",
        "USER",
        "LOGNAME",
        "SHELL",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "REPOPROMPT_CODEX_ARCH",
        "REPOPROMPT_CODEX_CACHE_ROOT",
    ]
    STYLE_ENV_KEYS = [
        "GITHUB_ACTIONS",
        "CI",
        "HOMEBREW_NO_AUTO_UPDATE",
        "HOMEBREW_NO_INSTALL_CLEANUP",
        "HOMEBREW_CACHE",
    ]
    TEST_ENV_KEYS = [
        "RPCE_RUN_CODEMAP_E2E",
        "RPCE_RUN_SCALE_TESTS",
    ]
    CONDUCTOR_ENV_KEYS = [
        "REPOPROMPT_DEV_HEAVY_SLOTS",
        "REPOPROMPT_DEV_BUILD_CACHE_DIR",
        "REPOPROMPT_DEV_BUILD_CACHE_DISABLE",
        "REPOPROMPT_DEV_BUILD_CACHE_LIMIT_BYTES",
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
        if operation == "codex-schema-check":
            return [sys.executable, script("check_codex_app_server_schema.py")], lanes, cwd, env, effective_timeout
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
            if args.get("filter"):
                argv.extend(["--filter", str(args["filter"])])
            return argv, ["build"], cwd, env, effective_timeout
        if operation == "provider-test":
            argv = ["swift", "test"]
            if args.get("testProduct"):
                argv.extend(["--test-product", str(args["testProduct"])])
            if args.get("filter"):
                argv.extend(["--filter", str(args["filter"])])
            return argv, ["build"], self.repo_root / "Packages" / "RepoPromptAgentProviders", env, effective_timeout
        if operation == "install-debug-cli":
            return [script("install_debug_cli.sh"), "install", "--build"], ["build", "debugArtifact"], cwd, env, effective_timeout
        if operation == "debug-cli-status":
            return [script("install_debug_cli.sh"), "status"], lanes, cwd, env, effective_timeout
        if operation == "run":
            return self._internal_argv("debug_app_build_then_launch", dict(args)), ["build", "liveApp"], cwd, env, effective_timeout
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
                return self._internal_argv("debug_app_build_then_launch", dict(args)), ["build", "liveApp"], cwd, env, effective_timeout
        if operation == "smoke":
            lanes = ["debugArtifact", "liveApp"]
            if args.get("launch"):
                lanes = ["build", "liveApp"]
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
            if subcommand == "focused-build":
                return self._internal_argv("diagnostics_focused_build", dict(args)), ["build"], cwd, env, effective_timeout
            if subcommand == "high-output":
                return self._internal_argv("diagnostics_high_output", dict(args)), lanes, cwd, env, effective_timeout
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
        raw_seconds = args.get("xctestStallSeconds")
        wake_probe = bool(args.get("xctestStallWakeProbe"))
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
        if operation in {
            "doctor",
            "guardrails",
            "codex-schema-check",
            "debug-cli-status",
            "format-tools-status",
            "check-format-tools",
        }:
            return SHORT_TIMEOUT_SECONDS
        if operation == "app" and args.get("subcommand") in {"status", "stop"}:
            return SHORT_TIMEOUT_SECONDS
        if operation == "release" and args.get("subcommand") == "artifact":
            return RELEASE_ARTIFACT_TIMEOUT_SECONDS
        if operation in {"package", "release"} and (args.get("config") == "release" or args.get("subcommand") in {"package", "local-install"}):
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


class ExternalIOWorker:
    """Bounded daemon-owned queue for best-effort filesystem work."""

    def __init__(self, on_error: Any) -> None:
        self._on_error = on_error
        self._tasks: "queue.Queue[Tuple[Any, Tuple[Any, ...]]]" = queue.Queue(maxsize=EXTERNAL_IO_QUEUE_DEPTH)
        self._thread = threading.Thread(target=self._run, name="conductor-state-io", daemon=True)
        self._thread.start()

    def submit(self, function: Any, *args: Any) -> bool:
        try:
            self._tasks.put_nowait((function, args))
            return True
        except queue.Full:
            return False

    def join(self) -> None:
        self._tasks.join()

    def _run(self) -> None:
        while True:
            function, args = self._tasks.get()
            try:
                function(*args)
            except Exception as exc:
                self._on_error(str(exc))
            finally:
                self._tasks.task_done()


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
        self.active_unlaned: set[str] = set()
        self._worker_threads: set[threading.Thread] = set()
        self.shutdown_requested = False
        self.server: Optional[socketserver.BaseServer] = None
        self._next_job_generation = 1
        self._daemon_start_token = read_daemon_metadata(paths).get("processStart")
        self._running_registry_generation = 0
        self._retention_generation = 0
        self._registry_publish_lock = threading.Lock()
        self._cache_write_lock = threading.Lock()
        self._cache_write_active_ticket: Optional[str] = None
        self.build_cache: Optional[BuildCacheManager] = None
        self._daemon_infrastructure_warnings: Deque[Dict[str, Any]] = deque(maxlen=MAX_INFRASTRUCTURE_WARNINGS)
        self._io_worker = ExternalIOWorker(self._record_io_worker_error)
        self._output_pump = ProcessOutputPump(
            self._submit_process_output_chunk,
            self._submit_process_output_line,
        )

    def _build_cache_manager(self, env: Optional[Dict[str, str]] = None) -> BuildCacheManager:
        desired_env = dict(os.environ if env is None else env)
        override = desired_env.get("REPOPROMPT_DEV_BUILD_CACHE_DIR")
        desired_root = (
            Path(override).expanduser().resolve()
            if override
            else (Path.home() / "Library" / "Application Support" / "RepoPrompt CE" / "Conductor" / "BuildCache").resolve()
        )
        if self.build_cache is None or self.build_cache.store_root != desired_root:
            self.build_cache = BuildCacheManager(self.paths.repo_root, env=desired_env)
        return self.build_cache

    def _record_io_worker_error(self, message: str) -> None:
        with self.condition:
            self._daemon_infrastructure_warnings.append(
                {"kind": "externalIO", "message": message[:500], "observedAt": now()}
            )
            self.condition.notify_all()

    def _warn_job_locked(self, job: Job, kind: str, message: str) -> None:
        job.infrastructure_warnings.append(
            {"kind": kind, "message": message[:500], "observedAt": now()}
        )
        if len(job.infrastructure_warnings) > MAX_INFRASTRUCTURE_WARNINGS:
            del job.infrastructure_warnings[:-MAX_INFRASTRUCTURE_WARNINGS]

    @staticmethod
    def _set_phase_locked(job: Job, phase: str) -> None:
        if phase not in JOB_PHASES:
            raise ConductorError(f"invalid job phase '{phase}'")
        if job.phase != phase:
            job.phase = phase
            job.phase_changed_at = now()

    @staticmethod
    def _job_lease(job: Job) -> JobLease:
        return JobLease(job.ticket, job.job_generation)

    @staticmethod
    def _process_lease(job: Job) -> ProcessWorkLease:
        return ProcessWorkLease(
            ticket=job.ticket,
            job_generation=job.job_generation,
            process_generation=job.process_generation,
            pid=job.process_pid,
            pgid=job.process_pgid,
            process_start=job.process_start,
            process_group_identity_confirmed=job.process_group_identity_confirmed,
            tracked_processes=dict(job.tracked_processes),
        )

    def _job_matches_lease_locked(self, lease: JobLease) -> Optional[Job]:
        job = self.jobs.get(lease.ticket)
        if job is None or job.job_generation != lease.job_generation:
            return None
        return job

    def _job_matches_process_lease_locked(self, lease: ProcessWorkLease) -> Optional[Job]:
        job = self.jobs.get(lease.ticket)
        if (
            job is None
            or job.job_generation != lease.job_generation
            or job.process_generation != lease.process_generation
        ):
            return None
        return job

    def _external_call_while_locked(self, function: Any, *args: Any) -> Any:
        """Run external work with all recursive holds on the central RLock released."""
        # RepoPrompt's conductor is macOS-CPython-only. These private RLock hooks
        # are required to restore the exact recursive hold count around external work.
        if not self.lock._is_owned():  # type: ignore[attr-defined]
            return function(*args)
        release_state = self.lock._release_save()  # type: ignore[attr-defined]
        try:
            return function(*args)
        finally:
            self.lock._acquire_restore(release_state)  # type: ignore[attr-defined]

    def _global_heavy_slot_paths(self, env: Optional[Dict[str, str]] = None) -> List[Path]:
        return global_heavy_slot_paths(env)

    def _active_daemon_warnings_locked(self) -> List[Dict[str, Any]]:
        cutoff = now() - INFRASTRUCTURE_WARNING_TTL_SECONDS
        retained = [
            warning
            for warning in self._daemon_infrastructure_warnings
            if float(warning.get("observedAt") or 0.0) >= cutoff
        ]
        if len(retained) != len(self._daemon_infrastructure_warnings):
            self._daemon_infrastructure_warnings = deque(retained, maxlen=MAX_INFRASTRUCTURE_WARNINGS)
        return retained

    def status_payload(self) -> Dict[str, Any]:
        with self.lock:
            active_warnings = self._active_daemon_warnings_locked()
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
                "running": True,
                "pid": os.getpid(),
                "repoRoot": str(self.paths.repo_root),
                "repoHash": self.paths.repo_hash,
                "socketPath": str(self.paths.socket_path),
                "stateDir": str(self.paths.state_dir),
                "globalHeavySlotPaths": [str(path) for path in self._global_heavy_slot_paths()],
                "globalHeavySlotCount": configured_global_heavy_slots(),
                "liveAppLockPath": str(live_app_lock_path()),
                "activeJobsByLane": active_by_lane,
                "activeUnlanedJobs": [
                    self._job_payload_locked(self.jobs[ticket], include_tail=False, include_summary=False)
                    for ticket in sorted(self.active_unlaned)
                    if ticket in self.jobs
                ],
                "unlanedCapacity": {"limit": MAX_UNLANED_JOBS, "activeCount": len(self.active_unlaned)},
                "cacheWriteLane": {"activeTicket": self._cache_write_active_ticket},
                "runningJobs": running_jobs,
                "queuedJobs": queued_jobs,
                "queueDepth": len(self.queue),
                "retainedTerminalCount": terminal_count,
                "shutdownRequested": self.shutdown_requested,
                "health": {
                    "state": "stopping" if self.shutdown_requested else ("degraded" if active_warnings else "healthy"),
                    "rpcResponsive": True,
                    "processIdentityVerified": True,
                    "issues": active_warnings,
                },
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
        if job_consumes_unlaned_capacity(job.operation, job.lanes):
            earlier_unlaned = any(
                ticket != job.ticket
                and (candidate := self.jobs.get(ticket)) is not None
                and candidate.state == "queued"
                and job_consumes_unlaned_capacity(candidate.operation, candidate.lanes)
                for ticket in self.queue[: self.queue.index(job.ticket)]
            ) if job.ticket in self.queue else False
            if len(self.active_unlaned) >= MAX_UNLANED_JOBS or earlier_unlaned:
                blockers.append(
                    {
                        "kind": "unlanedCapacity",
                        "limit": MAX_UNLANED_JOBS,
                        "activeCount": len(self.active_unlaned),
                        "activeJobs": [
                            {
                                "ticket": ticket,
                                "operationLabel": operation_display_name(self.jobs[ticket].operation, self.jobs[ticket].args),
                            }
                            for ticket in sorted(self.active_unlaned)
                            if ticket in self.jobs
                        ],
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
            job_generation = self._next_job_generation
            self._next_job_generation += 1
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
                job_generation=job_generation,
                phase="queued",
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
                self._set_phase_locked(old_job, "terminal")
                old_job.finished_at = now()
                old_job.exit_code = 130
                old_job.result_summary = f"superseded before start by {intent}"
                with contextlib.suppress(ValueError):
                    self.queue.remove(old_job.ticket)
                self._append_system_line_locked(old_job, f"job superseded before start by {intent} {new_job.ticket}\n")
                cancellation_state = "canceled"
            else:
                self._set_phase_locked(old_job, "canceling")
                guard_delayed_launch = guard_delayed_launch or is_launch_capable_job(old_job.operation, old_job.args)
                reason = f"superseded by {intent} {new_job.ticket}"
                self._request_process_cleanup_locked(old_job, reason=reason)
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
                self._set_phase_locked(job, "terminal")
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
                if job.phase == "publishingCache":
                    job.cancellation_ignored_reason = (
                        "build process already succeeded; immutable cache publication is non-abortable"
                    )
                    self._append_system_line_locked(
                        job,
                        f"cancellation ignored: {job.cancellation_ignored_reason}\n",
                    )
                    payload = self._job_payload_locked(job, include_tail=True)
                    payload["cancellationPending"] = False
                    self.condition.notify_all()
                    return payload
                job.cancel_requested = True
                self._set_phase_locked(job, "canceling")
                self._request_process_cleanup_locked(job, reason="cancellation requested")
                deadline = time.monotonic() + CANCEL_CLEANUP_WAIT_SECONDS
                while job.cleanup_in_flight:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        payload = self._job_payload_locked(job, include_tail=True)
                        payload["cancellationPending"] = True
                        return payload
                    self.condition.wait(timeout=remaining)
                payload = self._job_payload_locked(job, include_tail=True)
                payload["cancellationPending"] = False
                return payload
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
                    if job.state == "running" and job.phase == "publishingCache":
                        # Atomic seed replacement must not be interrupted after a
                        # successful build. Force-stop waits for the publication's
                        # already bounded filesystem operations instead of
                        # signaling or corrupting the committed build result.
                        job.cancellation_ignored_reason = (
                            "build process already succeeded; immutable cache publication is non-abortable"
                        )
                        self._append_system_line_locked(
                            job,
                            f"daemon stop cancellation ignored: {job.cancellation_ignored_reason}\n",
                        )
                        running_tickets.append(job.ticket)
                        continue
                    job.cancel_requested = True
                    if job.state == "queued":
                        job.state = "canceled"
                        self._set_phase_locked(job, "terminal")
                        job.finished_at = now()
                        job.exit_code = 130
                        job.result_summary = "canceled by daemon stop --force"
                        with contextlib.suppress(ValueError):
                            self.queue.remove(job.ticket)
                        self._append_system_line_locked(job, "job canceled by daemon stop --force before start\n")
                    elif job.state == "running":
                        running_tickets.append(job.ticket)
                        self._set_phase_locked(job, "canceling")
                        self._request_process_cleanup_locked(job, reason="daemon stop --force")
                self._write_running_processes_locked()
                self.condition.notify_all()
            payload = self.status_payload()
            if force:
                publication_wait_tickets = [
                    job.ticket
                    for job in active_or_queued
                    if job.state == "running" and job.phase == "publishingCache"
                ]
                payload["forceStop"] = {
                    "requested": True,
                    "publicationPolicy": "waitForNonAbortableAtomicPublication",
                    "publicationWaitTickets": publication_wait_tickets,
                    "publicationWaitTimeoutSeconds": BUILD_CACHE_FORCE_STOP_WAIT_SECONDS,
                    "cancellationIgnored": bool(publication_wait_tickets),
                }
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
                if job.phase == "publishingCache" and job.cancellation_ignored_reason:
                    # Do not create a second cancellation authority inside the
                    # atomic publication path. Wait only for the advertised
                    # bounded allowance; on expiry, keep the daemon available
                    # and leave the publication worker and build result intact.
                    publication_deadline = time.monotonic() + BUILD_CACHE_FORCE_STOP_WAIT_SECONDS
                    while job.state == "running" and job.phase == "publishingCache":
                        remaining = publication_deadline - time.monotonic()
                        if remaining <= 0:
                            self.shutdown_requested = False
                            self._warn_job_locked(
                                job,
                                "buildCachePublicationStopWaitExpired",
                                "daemon stop --force left non-abortable cache publication running after bounded wait",
                            )
                            return
                        self.condition.wait(timeout=min(PROCESS_TREE_POLL_SECONDS, remaining))
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
        active_unlaned_count = len(self.active_unlaned)
        earlier_unlaned_blocked = False

        for ticket in self.queue:
            job = self.jobs.get(ticket)
            if not job or job.state != "queued":
                continue
            job_lanes = set(job.lanes)
            if job_lanes & active_lane_set or job_lanes & blocked_lanes:
                blocked_lanes.update(job_lanes)
                new_queue.append(ticket)
                continue
            consumes_unlaned = job_consumes_unlaned_capacity(job.operation, job.lanes)
            if consumes_unlaned and (earlier_unlaned_blocked or active_unlaned_count >= MAX_UNLANED_JOBS):
                earlier_unlaned_blocked = True
                new_queue.append(ticket)
                continue
            to_start.append(job)
            active_lane_set.update(job_lanes)
            if consumes_unlaned:
                active_unlaned_count += 1

        self.queue = new_queue
        for job in to_start:
            job.state = "running"
            job.started_at = now()
            if operation_requires_global_heavy_slot(job.operation, job.args):
                self._set_phase_locked(job, "waitingGlobalHeavy")
                job.global_heavy_admission_state = "waiting"
            else:
                self._set_phase_locked(job, "startingProcess")
            for lane in job.lanes:
                self.active_lanes[lane] = job.ticket
            if job_consumes_unlaned_capacity(job.operation, job.lanes):
                self.active_unlaned.add(job.ticket)
            thread = threading.Thread(target=self._run_job, args=(job.ticket,), daemon=True)
            self._worker_threads.add(thread)
            thread.start()
        if to_start:
            self.condition.notify_all()

    def _terminalize_canceled_global_heavy_wait_locked(self, job: Job) -> None:
        job.state = "canceled"
        self._set_phase_locked(job, "terminal")
        job.global_heavy_admission_state = "released"
        job.exit_code = 130
        job.result_summary = "canceled before global heavy slot"
        job.finished_at = now()
        self._append_system_line_locked(job, "job canceled before global heavy slot\n")
        self.condition.notify_all()

    def _acquire_global_heavy_slot(self, ticket: str) -> Optional[FairHeavyLease]:
        wait_start = now()
        with self.condition:
            job = self.jobs.get(ticket)
            if job is None:
                return None
            env = dict(job.env)
            lease = self._job_lease(job)
            metadata = display_lock_metadata(
                lock_kind="global-heavy",
                ticket=job.ticket,
                operation=job.operation,
                operation_label=operation_display_name(job.operation, job.args),
                repo_root=self.paths.repo_root,
                repo_hash=self.paths.repo_hash,
            )
        def admission_warning(kind: str, message: str) -> None:
            with self.condition:
                current = self._job_matches_lease_locked(lease)
                if current is not None:
                    self._warn_job_locked(current, kind, message)
                self._daemon_infrastructure_warnings.append(
                    {"kind": kind, "message": message[:500], "observedAt": now()}
                )
                self.condition.notify_all()

        coordinator = FairHeavyAdmission(metadata, env, on_warning=admission_warning)
        with self.condition:
            current = self._job_matches_lease_locked(lease)
            if current is not None:
                current.global_heavy_waiter_id = coordinator.waiter_id

        def cancel_check() -> bool:
            with self.condition:
                current = self._job_matches_lease_locked(lease)
                return current is None or current.state != "running" or current.cancel_requested

        def update(position: int, earlier: List[Dict[str, Any]]) -> None:
            with self.condition:
                current = self._job_matches_lease_locked(lease)
                if current is None or current.state != "running":
                    return
                current.global_heavy_queue_position = position
                current.global_heavy_rescan_seconds = coordinator.current_rescan_seconds
                current.global_heavy_slot_path = ",".join(str(path) for path in global_heavy_slot_paths(env))
                fair_holders = earlier[: configured_global_heavy_slots(env)]
                current.global_heavy_legacy_slot_holder = coordinator.legacy_slot_holder
                if fair_holders:
                    current.global_heavy_slot_holder = json.dumps(fair_holders, sort_keys=True)
                elif coordinator.legacy_slot_holder:
                    current.global_heavy_slot_holder = "non-authoritative legacy slot holder: " + json.dumps(
                        coordinator.legacy_slot_holder.get("metadata"), sort_keys=True
                    )
                else:
                    current.global_heavy_slot_holder = None
                self.condition.notify_all()

        acquired = coordinator.wait(cancel_check=cancel_check, update=update)
        if acquired is None:
            with self.condition:
                current = self._job_matches_lease_locked(lease)
                if current is not None and current.state == "running":
                    self._terminalize_canceled_global_heavy_wait_locked(current)
            return None
        waited = now() - wait_start
        release_stale_acquisition = False
        with self.condition:
            current = self._job_matches_lease_locked(lease)
            if current is None or current.state != "running":
                release_stale_acquisition = True
            elif current.cancel_requested:
                release_stale_acquisition = True
                self._terminalize_canceled_global_heavy_wait_locked(current)
            else:
                current.global_heavy_slot_wait_seconds = waited
                current.global_heavy_slot_path = str(acquired.lock_path)
                current.global_heavy_slot_holder = None
                current.global_heavy_legacy_slot_holder = None
                current.global_heavy_admission_state = "acquired"
                current.global_heavy_queue_position = 1
                self._set_phase_locked(current, "startingProcess")
                self._append_system_line_locked(
                    current,
                    f"acquired fair global heavy slot {acquired.lock_path} after {format_duration(waited)}\n",
                )
                self.condition.notify_all()
        if release_stale_acquisition:
            acquired.release()
            return None
        return acquired

    def _publish_started_process_identity(
        self,
        job: Job,
        process: subprocess.Popen[bytes],
        *,
        durable_registry: bool = False,
    ) -> bool:
        process_pgid: Optional[int] = None
        with contextlib.suppress(OSError):
            process_pgid = os.getpgid(process.pid)
        snapshot = process_table_snapshot() or {}
        process_record = snapshot.get(process.pid)
        observed_process_start = process_record[1] if process_record else process_start_token(process.pid)
        with self.condition:
            job.process_started_at = now()
            job.process_generation += 1
            job.process_pid = process.pid
            job.process_pgid = process_pgid
            job.process_start = observed_process_start
            job.process_group_identity_confirmed = bool(
                observed_process_start and process_pgid == process.pid
            )
            if observed_process_start:
                job.tracked_processes[process.pid] = observed_process_start
            self._set_phase_locked(job, "runningProcess")
            if not durable_registry:
                self._write_running_processes_locked()
            cancel_after_publish = job.cancel_requested and job.superseded_by_ticket is None
            self.condition.notify_all()
        if durable_registry:
            self._write_running_processes_durable()
        return cancel_after_publish

    def _cleanup_failed_output_registration(self, job: Job, process: subprocess.Popen[bytes]) -> None:
        reason = "output pump registration failed"
        with self.condition:
            self._terminate_process_group_locked(job, reason=reason)
        with contextlib.suppress(ProcessLookupError, PermissionError, OSError):
            process.terminate()
        root_alive = False
        try:
            process.wait(timeout=TERMINATE_GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            root_alive = True
        with self.condition:
            descendants_alive = self._wait_for_process_tree_exit_locked(
                job,
                now() + TERMINATE_GRACE_SECONDS,
                signal_for_new=signal.SIGTERM,
            )
            if root_alive or descendants_alive:
                self._kill_process_group_locked(job, reason=f"{reason}; SIGKILL after grace period")
        if root_alive:
            with contextlib.suppress(ProcessLookupError, PermissionError, OSError):
                process.kill()
            with contextlib.suppress(subprocess.TimeoutExpired):
                process.wait(timeout=KILL_GRACE_SECONDS)
        with self.condition:
            self._wait_for_process_tree_exit_locked(
                job,
                now() + KILL_GRACE_SECONDS,
                signal_for_new=signal.SIGKILL,
            )

    @staticmethod
    def _release_global_heavy_slot(lock_file: Optional[Any]) -> None:
        if lock_file is None:
            return
        if isinstance(lock_file, FairHeavyLease):
            lock_file.release()
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
        output_channel: Optional[ProcessOutputChannel] = None
        watchdog: Optional[threading.Thread] = None
        global_heavy_slot: Optional[Any] = None
        cache_manager: Optional[BuildCacheManager] = None
        cache_context: Optional[BuildCacheContext] = None
        cache_publish_after_success = False
        cache_wrapper_gate_read = -1
        cache_wrapper_gate_write = -1
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
                    self._set_phase_locked(job, "terminal")
                    job.exit_code = 130
                    job.result_summary = "canceled before process start"
                    job.finished_at = now()
                    self._append_system_line_locked(job, "job canceled before process start\n")
                    return
            argv, _lanes, cwd, env, effective_timeout = self.registry.prepare(request)
            env["REPOPROMPT_CONDUCTOR_JOB_TICKET"] = job.ticket
            if BuildCacheManager.eligible(job.operation, job.args) and (self.paths.repo_root / "Package.swift").is_file():
                with self._cache_write_lock:
                    cache_manager = self._build_cache_manager(env)
                cache_context = cache_manager.prepare(job.operation, job.args, env)
                if cache_context is not None:
                    cache_context.outcome_path = job.log_path.with_suffix(".cache-outcome.json")
                    with self.condition:
                        job.build_cache = dict(cache_context.status)
                        self._append_system_line_locked(
                            job,
                            f"build cache {cache_context.status.get('state')}: key={cache_context.status.get('key', 'unavailable')}\n",
                        )
                    if cache_context.seeded:
                        attempt_timeout = effective_timeout
                        cache_attempt_record_path = job.log_path.with_suffix(".cache-attempt.json")
                        with self.condition:
                            job.cache_attempt_record_path = cache_attempt_record_path
                        cleanup_timeout = BuildCacheManager._tree_deadline_seconds(
                            self.paths.repo_root / ".build"
                        )
                        argv = self.registry._internal_argv(
                            "cache_retry",
                            {
                                "argv": argv,
                                "key": cache_context.snapshot.key,
                                "outcomePath": str(cache_context.outcome_path),
                                "attemptTimeout": attempt_timeout,
                                "cleanupTimeout": cleanup_timeout,
                                "attemptRecordPath": str(cache_attempt_record_path),
                                "ticket": job.ticket,
                            },
                        )
                        effective_timeout = BuildCacheManager.retry_job_timeout(
                            attempt_timeout,
                            cleanup_timeout,
                        )
                        with self.condition:
                            job.build_cache["attemptTimeoutSeconds"] = attempt_timeout
                            job.build_cache["cleanupTimeoutSeconds"] = cleanup_timeout
                            job.build_cache["retryEnvelopeTimeoutSeconds"] = effective_timeout
            if operation_requires_global_heavy_slot(job.operation, job.args):
                global_heavy_slot = self._acquire_global_heavy_slot(job.ticket)
                if global_heavy_slot is None:
                    return
            start_line = f"$ {format_argv(argv)}\n"
            with self.condition:
                self._append_system_line_locked(job, start_line)
            output_transport = self._create_process_output_transport(job)
            with self.condition:
                job.progress_transport = output_transport.kind
            process_pass_fds: Tuple[int, ...] = ()
            if cache_context is not None and cache_context.seeded:
                cache_wrapper_gate_read, cache_wrapper_gate_write = os.pipe()
                env["REPOPROMPT_CONDUCTOR_CACHE_WRAPPER_GATE_FD"] = str(cache_wrapper_gate_read)
                process_pass_fds = (cache_wrapper_gate_read,)
            process = subprocess.Popen(
                argv,
                cwd=str(cwd),
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=output_transport.popen_stdout,
                stderr=output_transport.popen_stderr,
                pass_fds=process_pass_fds,
                start_new_session=True,
            )
            if cache_wrapper_gate_read >= 0:
                os.close(cache_wrapper_gate_read)
                cache_wrapper_gate_read = -1
            output_transport.attach_process(process)
            reader_fd = output_transport.transfer_reader()
            try:
                output_channel = self._output_pump.register(job.ticket, reader_fd, output_transport.kind)
            except Exception:
                with contextlib.suppress(OSError):
                    os.close(reader_fd)
                self._publish_started_process_identity(job, process)
                self._cleanup_failed_output_registration(job, process)
                raise

            try:
                cancel_after_publish = self._publish_started_process_identity(
                    job,
                    process,
                    durable_registry=cache_wrapper_gate_write >= 0,
                )
                if cache_wrapper_gate_write >= 0:
                    if os.write(cache_wrapper_gate_write, b"1") != 1:
                        raise ConductorError("cache retry wrapper gate release was incomplete")
                    os.close(cache_wrapper_gate_write)
                    cache_wrapper_gate_write = -1
            except Exception:
                if cache_wrapper_gate_write >= 0:
                    with contextlib.suppress(OSError):
                        os.close(cache_wrapper_gate_write)
                    cache_wrapper_gate_write = -1
                with contextlib.suppress(subprocess.TimeoutExpired):
                    process.wait(timeout=KILL_GRACE_SECONDS)
                raise
            if cancel_after_publish:
                with self.condition:
                    current = self.jobs.get(job.ticket)
                    if current is job:
                        self._request_process_cleanup_locked(job, "cancellation requested before PID assignment")

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
                self._set_phase_locked(job, "finalizingOutput")
            if job.cancel_requested:
                with self.condition:
                    process_tree_alive = self._process_tree_alive_locked(job)
                    if process_tree_alive is not False:
                        self._terminate_process_group_locked(job, reason="cancellation descendant cleanup")
                        descendants_alive = self._wait_for_process_tree_exit_locked(
                            job,
                            now() + TERMINATE_GRACE_SECONDS,
                            signal_for_new=signal.SIGTERM,
                        )
                        if descendants_alive:
                            self._kill_process_group_locked(
                                job,
                                reason="cancellation descendant cleanup; SIGKILL after grace period",
                            )
                            descendants_alive = self._wait_for_process_tree_exit_locked(
                                job,
                                now() + KILL_GRACE_SECONDS,
                                signal_for_new=signal.SIGKILL,
                            )
                        if descendants_alive:
                            raise ConductorError(
                                "canceled job descendants remained alive after SIGKILL escalation"
                            )

            self._output_pump.request_finalization(output_channel)
            output_result = self._output_pump.wait_for_completion(output_channel)
            with self.condition:
                job.output_truncated = output_result.truncated
                job.output_truncation_reason = output_result.reason
                job.output_bytes_read = output_result.bytes_read
                if output_result.truncated:
                    job.log_truncated = True
                    job.log_truncation_reason = output_result.reason
                    self._append_system_line_locked(
                        job,
                        f"process output truncated during bounded finalization: {output_result.reason}\n",
                    )
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
                cache_publish_after_success = bool(
                    job.state == "completed" and cache_context is not None and cache_manager is not None
                )
                if cache_publish_after_success:
                    job.state = "running"
                    job.result_summary = "build succeeded; publishing immutable cache seed"
                    self._set_phase_locked(job, "publishingCache")
                else:
                    self._set_phase_locked(job, "summarizing")
                    job.finished_at = now()
        except Exception as exc:
            if job is not None:
                with self.condition:
                    job.state = "failed"
                    self._set_phase_locked(job, "summarizing")
                    job.exit_code = 1
                    job.error = str(exc)
                    job.result_summary = f"daemon runner error: {exc}"
                    job.finished_at = now()
                    self._append_system_line_locked(job, f"daemon runner error: {exc}\n")
        finally:
            if cache_wrapper_gate_read >= 0:
                with contextlib.suppress(OSError):
                    os.close(cache_wrapper_gate_read)
            if cache_wrapper_gate_write >= 0:
                with contextlib.suppress(OSError):
                    os.close(cache_wrapper_gate_write)
            if output_channel is not None and output_channel.result is None:
                with contextlib.suppress(ConductorError):
                    self._output_pump.request_finalization(output_channel)
                output_result = self._output_pump.wait_for_completion(output_channel)
                if job is not None:
                    with self.condition:
                        job.output_truncated = output_result.truncated
                        job.output_truncation_reason = output_result.reason
                        job.output_bytes_read = output_result.bytes_read
            # Deliberate ordering: cache publication no longer consumes scarce
            # machine-wide heavy capacity, while the job retains its per-daemon
            # build lane through immutable publication. Coordinated mutators of
            # this checkout's .build remain blocked without stalling unrelated
            # worktrees behind the global heavy slot.
            self._release_global_heavy_slot(global_heavy_slot)
            released_heavy_slot = global_heavy_slot is not None
            global_heavy_slot = None
            if job is not None and released_heavy_slot:
                with self.condition:
                    if self.jobs.get(job.ticket) is job:
                        job.global_heavy_admission_state = "released"
            if job is not None and cache_context is not None and cache_context.outcome_path is not None:
                outcome = BuildCacheManager._read_json_file(cache_context.outcome_path)
                if outcome:
                    with self.condition:
                        job.build_cache["retry"] = outcome
                        self._apply_cache_retry_outcome_locked(job, outcome)
                with contextlib.suppress(FileNotFoundError):
                    cache_context.outcome_path.unlink()
            if job is not None and cache_publish_after_success and cache_context is not None and cache_manager is not None:
                try:
                    with self._cache_write_lock:
                        with self.condition:
                            self._cache_write_active_ticket = job.ticket
                        try:
                            publication = cache_manager.publish(cache_context)
                        finally:
                            with self.condition:
                                self._cache_write_active_ticket = None
                                self.condition.notify_all()
                    with self.condition:
                        job.build_cache["publication"] = publication
                        self._append_system_line_locked(
                            job,
                            f"build cache publication {publication.get('state')}: {publication.get('reason') or publication.get('generation', '')}\n",
                        )
                except Exception as exc:
                    with self.condition:
                        job.build_cache["publication"] = {"state": "publicationFailed", "error": str(exc)[:500]}
                        self._warn_job_locked(job, "buildCachePublicationFailed", str(exc))
                finally:
                    with self.condition:
                        job.state = "completed"
                        job.exit_code = 0
                        job.result_summary = (
                            "completed successfully; cancellation ignored during non-abortable cache publication"
                            if job.cancellation_ignored_reason
                            else "completed successfully"
                        )
                        self._set_phase_locked(job, "summarizing")
                        job.finished_at = now()
                        self.condition.notify_all()
            if output_transport is not None:
                output_transport.close_all()
            refresh_after_release = False
            with self.condition:
                if job is not None:
                    refresh_after_release = job.state in TERMINAL_STATES and job.output_summary is None
                    if job.state in TERMINAL_STATES and not job.cleanup_in_flight:
                        job.process_generation += 1
                        job.tracked_processes.clear()
                    for lane in list(job.lanes):
                        if self.active_lanes.get(lane) == job.ticket:
                            del self.active_lanes[lane]
                    self.active_unlaned.discard(job.ticket)
                    self._write_running_processes_locked()
                    self._retention_pass_locked()
                self._worker_threads.discard(threading.current_thread())
                self._schedule_locked()
                self.condition.notify_all()
            if job is not None and refresh_after_release:
                threading.Thread(target=self._refresh_output_summary, args=(job,), daemon=True).start()

    def _submit_process_output_chunk(self, ticket: str, chunk: bytes) -> None:
        with self.condition:
            job = self.jobs.get(ticket)
            if job is not None:
                self._queue_job_log_bytes_locked(job, chunk)

    def _submit_process_output_line(self, ticket: str, line: bytes) -> None:
        text = line.decode("utf-8", errors="replace")
        with self.condition:
            job = self.jobs.get(ticket)
            if job:
                self._append_tail_locked(job, text)
                self._record_xctest_progress_locked(job, text)
                self.condition.notify_all()

    @staticmethod
    def _apply_cache_retry_outcome_locked(job: Job, outcome: Dict[str, Any]) -> None:
        cold_attempted = bool(outcome.get("coldRetryAttempted"))
        terminal_timed_out = bool(
            outcome.get("coldTimedOut") if cold_attempted else outcome.get("seededTimedOut")
        )
        if not terminal_timed_out:
            return
        attempt = "cold recovery" if cold_attempted else "seeded"
        timeout = outcome.get("attemptTimeoutSeconds")
        suffix = f" after {float(timeout):.1f}s" if isinstance(timeout, (int, float)) else ""
        job.timed_out = True
        job.state = "failed"
        job.exit_code = 124
        job.error = f"{attempt} cache build attempt timed out{suffix}"
        job.result_summary = job.error

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
        verified, depths, conclusive = self._refresh_process_tree_locked(job)
        if not conclusive:
            return None, []
        lease = self._process_lease(job)
        commands = self._external_call_while_locked(process_command_snapshot, list(verified.keys()))
        if self._job_matches_process_lease_locked(lease) is None:
            return None, []
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
        snapshot = process_table_snapshot()
        confirmation = snapshot.get(pid) if snapshot is not None else None
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
        coalesced_deadline = time.monotonic() + LOG_FLUSH_WAIT_SECONDS
        with self.condition:
            current = self.jobs.get(job.ticket)
            if current is not job or current.output_summary is not None:
                return
            if current.summary_in_flight:
                summary_generation = current.summary_generation
                while True:
                    remaining = coalesced_deadline - time.monotonic()
                    if remaining <= 0:
                        return
                    self.condition.wait(timeout=remaining)
                    current = self.jobs.get(job.ticket)
                    if current is not job or current.output_summary is not None:
                        return
                    if not current.summary_in_flight or current.summary_generation != summary_generation:
                        return
            current.summary_in_flight = True
            current.summary_generation += 1
            summary_generation = current.summary_generation
            lease = self._job_lease(current)
            operation = current.operation
            args = dict(current.args)
            state = current.state
            exit_code = current.exit_code
            timed_out = current.timed_out
            log_path = current.log_path
            target_log_sequence = current.log_sequence
        flush_complete = self._wait_for_job_log_flush(lease, target_sequence=target_log_sequence)
        if not flush_complete:
            with self.condition:
                current = self._job_matches_lease_locked(lease)
                if current is not None:
                    self._warn_job_locked(
                        current,
                        "logFlushIncomplete",
                        f"log flush did not reach sequence {target_log_sequence} before summary deadline",
                    )
        summary = OutputSummarizer.summarize_file(
            operation,
            args,
            state,
            exit_code,
            timed_out,
            log_path,
        )
        with self.condition:
            current = self._job_matches_lease_locked(lease)
            if current is not None and current.summary_generation == summary_generation:
                current.summary_in_flight = False
                if current.output_summary is None:
                    current.output_summary = summary
                    self._set_phase_locked(current, "terminal")
                self.condition.notify_all()

    def _wait_for_job_log_flush(self, lease: JobLease, target_sequence: int) -> bool:
        deadline = time.monotonic() + LOG_FLUSH_WAIT_SECONDS
        with self.condition:
            while True:
                current = self._job_matches_lease_locked(lease)
                if current is None:
                    return False
                if current.log_flushed_sequence >= target_sequence:
                    return True
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return False
                self.condition.wait(timeout=remaining)

    def _append_tail_locked(self, job: Job, text: str) -> None:
        lines = text.splitlines(keepends=True)
        if not lines:
            return
        for line in lines:
            encoded = line.encode("utf-8", errors="replace")
            if len(encoded) > LOG_TAIL_FRAGMENT_MAX_BYTES:
                marker = b"... [tail fragment truncated]\n"
                encoded = encoded[: LOG_TAIL_FRAGMENT_MAX_BYTES - len(marker)] + marker
                line = encoded.decode("utf-8", errors="replace")
                encoded = line.encode("utf-8", errors="replace")
            if job.tail.maxlen is not None and len(job.tail) >= job.tail.maxlen:
                removed = job.tail.popleft()
                job.tail_bytes -= len(removed.encode("utf-8", errors="replace"))
            job.tail.append(line)
            job.tail_bytes += len(encoded)
            while job.tail_bytes > LOG_TAIL_MAX_BYTES and job.tail:
                removed = job.tail.popleft()
                job.tail_bytes -= len(removed.encode("utf-8", errors="replace"))

    def _queue_job_log_bytes_locked(self, job: Job, payload: bytes) -> None:
        job.log_sequence += 1
        lease = self._job_lease(job)
        submitted = self._io_worker.submit(
            self._write_job_log_record,
            lease,
            job.log_path,
            job.log_sequence,
            payload,
        )
        if not submitted:
            self._settle_job_log_sequence_locked(job, job.log_sequence)
            job.log_truncated = True
            job.log_truncation_reason = "stateIOQueueFull"
            self._warn_job_locked(
                job,
                "logQueueFull",
                "log record dropped because the bounded state-I/O queue is full",
            )

    def _append_system_line_locked(self, job: Job, text: str) -> None:
        self._append_tail_locked(job, text)
        self._queue_job_log_bytes_locked(job, text.encode("utf-8", errors="replace"))

    def _settle_job_log_sequence_locked(self, job: Job, sequence: int) -> None:
        if sequence <= job.log_flushed_sequence:
            return
        job.log_settled_sequences.add(sequence)
        while job.log_flushed_sequence + 1 in job.log_settled_sequences:
            job.log_flushed_sequence += 1
            job.log_settled_sequences.remove(job.log_flushed_sequence)
        self.condition.notify_all()

    def _write_job_log_record(
        self,
        lease: JobLease,
        log_path: Path,
        sequence: int,
        payload: bytes,
    ) -> None:
        with self.condition:
            job = self._job_matches_lease_locked(lease)
            if job is None or sequence > job.log_sequence:
                return
        try:
            descriptor = os.open(
                log_path,
                os.O_WRONLY | os.O_CREAT | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0),
                0o600,
            )
            try:
                if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                    raise ConductorError(f"refusing non-regular job log {log_path}")
                remaining = memoryview(payload)
                while remaining:
                    written = os.write(descriptor, remaining)
                    if written <= 0:
                        raise OSError(errno.EIO, "short write while appending job log")
                    remaining = remaining[written:]
            finally:
                os.close(descriptor)
        except (OSError, ConductorError) as exc:
            with self.condition:
                current = self._job_matches_lease_locked(lease)
                if current is not None:
                    current.log_truncated = True
                    current.log_truncation_reason = "logWriteFailed"
                    self._warn_job_locked(current, "logWriteFailed", str(exc))
        finally:
            with self.condition:
                current = self._job_matches_lease_locked(lease)
                if current is not None:
                    self._settle_job_log_sequence_locked(current, sequence)

    def _running_processes_payload_locked(self) -> Tuple[int, Dict[str, Any]]:
        self._running_registry_generation += 1
        generation = self._running_registry_generation
        processes = []
        for job in self.jobs.values():
            if (
                job.state == "running"
                and job.process_pid
                and job.process_pgid
                and job.process_start
            ):
                processes.append(
                    {
                        "ticket": job.ticket,
                        "jobGeneration": job.job_generation,
                        "processGeneration": job.process_generation,
                        "operation": job.operation,
                        "pid": job.process_pid,
                        "pgid": job.process_pgid,
                        "processStart": job.process_start,
                        "processGroupIdentityConfirmed": job.process_group_identity_confirmed,
                        "cacheAttemptRecord": (
                            job.cache_attempt_record_path.name
                            if job.cache_attempt_record_path is not None
                            else None
                        ),
                    }
                )
        payload = {
            "version": 3,
            "generation": generation,
            "updatedAt": now(),
            "daemon": {"pid": os.getpid(), "processStart": self._daemon_start_token},
            "processes": processes,
        }
        return generation, payload

    def _write_running_processes_locked(self) -> None:
        generation, payload = self._running_processes_payload_locked()
        if not self._io_worker.submit(self._publish_running_processes, generation, payload):
            self._daemon_infrastructure_warnings.append(
                {
                    "kind": "registryQueueFull",
                    "message": "running-process registry publication dropped",
                    "observedAt": now(),
                }
            )

    def _write_running_processes_durable(self) -> None:
        with self._registry_publish_lock:
            with self.condition:
                generation, payload = self._running_processes_payload_locked()
            _atomic_write_json(self.paths.running_processes_path, payload)

    def _publish_running_processes(self, generation: int, payload: Dict[str, Any]) -> None:
        with self._registry_publish_lock:
            with self.condition:
                if generation != self._running_registry_generation:
                    return
            # The registry is the sole enumeration authority for crash recovery.
            # Publish it with file and directory fsync before any supplemental
            # cache-attempt record may be trusted.
            _atomic_write_json(self.paths.running_processes_path, payload)

    def _request_process_cleanup_locked(self, job: Job, reason: str) -> None:
        if job.state != "running" or job.cleanup_in_flight:
            return
        job.cleanup_in_flight = True
        self._set_phase_locked(job, "canceling")
        lease = self._job_lease(job)
        threading.Thread(
            target=self._perform_requested_process_cleanup,
            args=(lease, reason),
            name=f"conductor-cleanup-{job.ticket[:8]}",
            daemon=True,
        ).start()

    def _perform_requested_process_cleanup(self, lease: JobLease, reason: str) -> None:
        with self.condition:
            job = self._job_matches_lease_locked(lease)
            if job is None:
                return
            try:
                self._cancel_running_job_locked(job, reason)
            finally:
                current = self._job_matches_lease_locked(lease)
                if current is not None:
                    current.cleanup_in_flight = False
                    if current.state in TERMINAL_STATES:
                        current.process_generation += 1
                        current.tracked_processes.clear()
                self.condition.notify_all()

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

    @staticmethod
    def _discover_verified_processes(
        lease: ProcessWorkLease,
        snapshot: Dict[int, Tuple[int, str]],
    ) -> Tuple[Dict[int, Tuple[int, str]], Dict[int, int], Dict[int, str], Optional[str]]:
        tracked = dict(lease.tracked_processes)
        root_start = lease.process_start
        if lease.pid and lease.pid not in tracked:
            record = snapshot.get(lease.pid)
            token = root_start or (record[1] if record else None)
            if token:
                root_start = token
                tracked[lease.pid] = token

        live_tracked = {
            pid
            for pid, token in tracked.items()
            if snapshot.get(pid) is not None and snapshot[pid][1] == token
        }
        children_by_parent: Dict[int, List[int]] = {}
        for pid, (ppid, _token) in snapshot.items():
            children_by_parent.setdefault(ppid, []).append(pid)

        depths: Dict[int, int] = {pid: 0 for pid in live_tracked}
        pending: Deque[int] = deque(live_tracked)
        while pending:
            parent = pending.popleft()
            parent_depth = depths[parent]
            for child in children_by_parent.get(parent, []):
                record = snapshot.get(child)
                if record is None:
                    continue
                tracked[child] = record[1]
                next_depth = parent_depth + 1
                if next_depth > depths.get(child, -1):
                    depths[child] = next_depth
                    pending.append(child)

        verified = {
            pid: snapshot[pid]
            for pid, token in tracked.items()
            if snapshot.get(pid) is not None and snapshot[pid][1] == token
        }
        for pid in verified:
            depths.setdefault(pid, 0)
        return verified, depths, tracked, root_start

    def _refresh_process_tree_locked(
        self,
        job: Job,
    ) -> Tuple[Dict[int, Tuple[int, str]], Dict[int, int], bool]:
        lease = self._process_lease(job)
        snapshot = self._external_call_while_locked(process_table_snapshot)
        if snapshot is None:
            return {}, {}, False
        verified, depths, tracked, root_start = self._discover_verified_processes(lease, snapshot)
        current = self._job_matches_process_lease_locked(lease)
        if current is None:
            return {}, {}, False
        current.tracked_processes = tracked
        if root_start:
            current.process_start = root_start
        return verified, depths, True

    @staticmethod
    def _signal_verified_processes_external(
        tracked: Dict[int, str],
        sig: signal.Signals,
        verified: Dict[int, Tuple[int, str]],
        depths: Dict[int, int],
    ) -> int:
        confirmation = process_table_snapshot()
        if confirmation is None:
            return 0
        signaled = 0
        for pid in sorted(verified, key=lambda candidate: (depths.get(candidate, 0), candidate), reverse=True):
            token = tracked.get(pid)
            if not token or confirmation.get(pid) is None or confirmation[pid][1] != token:
                continue
            try:
                os.kill(pid, sig)
                signaled += 1
            except (ProcessLookupError, PermissionError, OSError):
                continue
        return signaled

    def _signal_verified_processes_locked(
        self,
        job: Job,
        sig: signal.Signals,
        verified: Dict[int, Tuple[int, str]],
        depths: Dict[int, int],
    ) -> int:
        lease = self._process_lease(job)
        signaled = self._external_call_while_locked(
            self._signal_verified_processes_external,
            dict(lease.tracked_processes),
            sig,
            dict(verified),
            dict(depths),
        )
        return signaled if self._job_matches_process_lease_locked(lease) is not None else 0

    def _signal_process_tree_locked(self, job: Job, sig: signal.Signals) -> int:
        verified, depths, conclusive = self._refresh_process_tree_locked(job)
        if not conclusive:
            return 0
        return self._signal_verified_processes_locked(job, sig, verified, depths)

    def _process_tree_alive_locked(self, job: Job) -> Optional[bool]:
        verified, _depths, conclusive = self._refresh_process_tree_locked(job)
        return bool(verified) if conclusive else None

    @staticmethod
    def _process_group_alive_external(pgid: int) -> bool:
        with contextlib.suppress(OSError):
            if pgid == os.getpgrp():
                return False
        try:
            os.killpg(pgid, 0)
            return True
        except (ProcessLookupError, PermissionError, OSError):
            return False

    def _process_group_id_alive_locked(self, job: Job) -> bool:
        lease = self._process_lease(job)
        if not lease.process_group_identity_confirmed:
            return False
        try:
            pgid = int(lease.pgid) if lease.pgid is not None else 0
        except (TypeError, ValueError):
            return False
        if pgid <= 0:
            return False
        alive = self._external_call_while_locked(self._process_group_alive_external, pgid)
        return bool(alive and self._job_matches_process_lease_locked(lease) is not None)

    def _wait_for_process_tree_exit_locked(
        self,
        job: Job,
        deadline: float,
        signal_for_new: signal.Signals,
    ) -> bool:
        while now() < deadline:
            verified, depths, conclusive = self._refresh_process_tree_locked(job)
            group_alive = self._process_group_id_alive_locked(job)
            if not conclusive:
                if group_alive:
                    self._signal_process_group_id_locked(job, signal_for_new)
                self.condition.wait(timeout=min(PROCESS_TREE_POLL_SECONDS, max(0.0, deadline - now())))
                continue
            if not verified:
                if not group_alive:
                    return False
                self._signal_process_group_id_locked(job, signal_for_new)
                self.condition.wait(timeout=min(PROCESS_TREE_POLL_SECONDS, max(0.0, deadline - now())))
                continue
            self._signal_verified_processes_locked(job, signal_for_new, verified, depths)
            self.condition.wait(timeout=min(PROCESS_TREE_POLL_SECONDS, max(0.0, deadline - now())))
        tree_alive = self._process_tree_alive_locked(job)
        if tree_alive is None:
            return True
        return tree_alive or self._process_group_id_alive_locked(job)

    @staticmethod
    def _signal_process_group_external(lease: ProcessWorkLease, sig: signal.Signals) -> Tuple[bool, bool]:
        try:
            pgid = int(lease.pgid) if lease.pgid is not None else 0
        except (TypeError, ValueError):
            return False, False
        if pgid <= 0:
            return False, False
        with contextlib.suppress(OSError):
            if pgid == os.getpgrp():
                return False, False

        confirmed = lease.process_group_identity_confirmed
        if not confirmed:
            snapshot = process_table_snapshot()
            if snapshot is None:
                return False, False
            for pid, token in lease.tracked_processes.items():
                record = snapshot.get(pid)
                if record is None or record[1] != token:
                    continue
                with contextlib.suppress(ProcessLookupError, PermissionError, OSError):
                    if os.getpgid(pid) == pgid:
                        confirmed = True
                        break
        if not confirmed:
            return False, False
        try:
            os.killpg(pgid, sig)
            return True, True
        except (ProcessLookupError, PermissionError, OSError):
            return False, True

    def _signal_process_group_id_locked(self, job: Job, sig: signal.Signals) -> bool:
        lease = self._process_lease(job)
        signaled, confirmed = self._external_call_while_locked(
            self._signal_process_group_external,
            lease,
            sig,
        )
        current = self._job_matches_process_lease_locked(lease)
        if current is None:
            return False
        if confirmed:
            current.process_group_identity_confirmed = True
        return bool(signaled)

    def _terminate_process_group_locked(self, job: Job, reason: str) -> None:
        verified, depths, conclusive = self._refresh_process_tree_locked(job)
        if self._signal_process_group_id_locked(job, signal.SIGTERM):
            self._append_system_line_locked(job, f"terminating process group: {reason}\n")
        self._append_system_line_locked(job, f"terminating process tree: {reason}\n")
        if conclusive:
            self._signal_verified_processes_locked(job, signal.SIGTERM, verified, depths)

    def _kill_process_group_locked(self, job: Job, reason: str) -> None:
        verified, depths, conclusive = self._refresh_process_tree_locked(job)
        if self._signal_process_group_id_locked(job, signal.SIGKILL):
            self._append_system_line_locked(job, f"killing process group: {reason}\n")
        self._append_system_line_locked(job, f"killing process tree: {reason}\n")
        if conclusive:
            self._signal_verified_processes_locked(job, signal.SIGKILL, verified, depths)

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

        detached_paths: List[Path] = []
        for ticket in prune:
            job = self.jobs.pop(ticket, None)
            if not job:
                continue
            detached_paths.append(job.log_path)
            detached_paths.extend(job.diagnostic_paths)
            for key, mapped_ticket in list(self.request_keys.items()):
                if mapped_ticket == ticket:
                    del self.request_keys[key]

        self._retention_generation += 1
        generation = self._retention_generation
        retained_logs = {job.log_path.name for job in self.jobs.values()}
        retained_diagnostics = {
            diagnostic_path.name
            for job in self.jobs.values()
            for diagnostic_path in job.diagnostic_paths
        }
        submitted = self._io_worker.submit(
            self._retention_external,
            generation,
            tuple(detached_paths),
            frozenset(retained_logs),
            frozenset(retained_diagnostics),
        )
        if not submitted:
            self._daemon_infrastructure_warnings.append(
                {
                    "kind": "retentionQueueFull",
                    "message": "retention cleanup deferred because the state-I/O queue is full",
                    "observedAt": now(),
                }
            )

    def _retention_external(
        self,
        generation: int,
        detached_paths: Sequence[Path],
        retained_logs: frozenset[str],
        retained_diagnostics: frozenset[str],
    ) -> None:
        for path in detached_paths:
            with contextlib.suppress(FileNotFoundError):
                path.unlink()

        cutoff = now() - TERMINAL_RETENTION_SECONDS
        candidates: List[Path] = []
        with contextlib.suppress(FileNotFoundError):
            candidates.extend(
                path for path in self.paths.jobs_dir.glob("*.log") if path.name not in retained_logs
            )
            candidates.extend(
                path
                for path in self.paths.jobs_dir.glob("*.xctest-stall.*")
                if path.name not in retained_diagnostics
            )
        for path in candidates:
            try:
                stale = path.stat().st_mtime < cutoff
            except OSError:
                continue
            if not stale:
                continue
            with self.condition:
                if generation != self._retention_generation:
                    return
                current_names = {job.log_path.name for job in self.jobs.values()}
                current_names.update(
                    diagnostic_path.name
                    for job in self.jobs.values()
                    for diagnostic_path in job.diagnostic_paths
                )
                if path.name in current_names:
                    continue
            with contextlib.suppress(FileNotFoundError):
                path.unlink()


def validate_json_shape(value: Any, depth: int = 0) -> None:
    if depth > MAX_JSON_DEPTH:
        raise ConductorError(f"request JSON nesting exceeds {MAX_JSON_DEPTH}")
    if isinstance(value, str):
        if len(value.encode("utf-8", errors="replace")) > MAX_JSON_STRING_BYTES:
            raise ConductorError(f"request string exceeds {MAX_JSON_STRING_BYTES} bytes")
        return
    if isinstance(value, dict):
        if len(value) > MAX_JSON_COLLECTION_ENTRIES:
            raise ConductorError(f"request object exceeds {MAX_JSON_COLLECTION_ENTRIES} entries")
        for key, item in value.items():
            if not isinstance(key, str):
                raise ConductorError("request object keys must be strings")
            validate_json_shape(key, depth + 1)
            validate_json_shape(item, depth + 1)
        return
    if isinstance(value, list):
        if len(value) > MAX_JSON_COLLECTION_ENTRIES:
            raise ConductorError(f"request array exceeds {MAX_JSON_COLLECTION_ENTRIES} entries")
        for item in value:
            validate_json_shape(item, depth + 1)


class ThreadedUnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = MAX_ACTIVE_REQUEST_HANDLERS

    def __init__(self, server_address: str, handler_cls: Any, state: DaemonState) -> None:
        self.state = state
        self.handler_permits = threading.BoundedSemaphore(MAX_ACTIVE_REQUEST_HANDLERS)
        self.wait_permits = threading.BoundedSemaphore(MAX_ACTIVE_WAIT_HANDLERS)
        super().__init__(server_address, handler_cls)

    def process_request(self, request: Any, client_address: Any) -> None:
        if not self.handler_permits.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.handler_permits.release()
            raise

    def process_request_thread(self, request: Any, client_address: Any) -> None:
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.handler_permits.release()


class RequestHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        state: DaemonState = self.server.state  # type: ignore[attr-defined]
        request_id = "unknown"
        wait_acquired = False
        response: Dict[str, Any]
        try:
            self.connection.settimeout(REQUEST_READ_TIMEOUT_SECONDS)
            request_bytes = bytearray()
            while b"\n" not in request_bytes and len(request_bytes) <= MAX_REQUEST_BYTES:
                chunk = self.connection.recv(min(64 * 1024, MAX_REQUEST_BYTES + 1 - len(request_bytes)))
                if not chunk:
                    break
                request_bytes.extend(chunk)
            if not request_bytes:
                return
            if len(request_bytes) > MAX_REQUEST_BYTES:
                raise ConductorError(f"request exceeds {MAX_REQUEST_BYTES} bytes")
            newline = request_bytes.find(b"\n")
            if newline < 0:
                raise ConductorError("request must be one newline-terminated JSON object")
            if newline != len(request_bytes) - 1:
                raise ConductorError("request contains trailing data after its JSON object")
            raw = bytes(request_bytes)
            request = json.loads(raw.decode("utf-8"))
            if not isinstance(request, dict):
                raise ConductorError("request must be a JSON object")
            validate_json_shape(request)
            request_id = str(request.get("id") or "unknown")
            if request.get("type") == "job-wait":
                wait_acquired = self.server.wait_permits.acquire(blocking=False)  # type: ignore[attr-defined]
                if not wait_acquired:
                    raise ConductorError("server wait-handler capacity exhausted; poll job status and retry")
            payload = handle_request(state, request)
            response = {"id": request_id, "ok": True, "payload": payload}
        except Exception as exc:
            response = {"id": request_id, "ok": False, "error": str(exc)[:4096]}
        finally:
            if wait_acquired:
                self.server.wait_permits.release()  # type: ignore[attr-defined]
        encoded = (json.dumps(response) + "\n").encode("utf-8")
        if len(encoded) > MAX_RESPONSE_BYTES:
            encoded = (json.dumps({
                "id": request_id,
                "ok": False,
                "error": f"response exceeds {MAX_RESPONSE_BYTES} bytes",
            }) + "\n").encode("utf-8")
        try:
            self.wfile.write(encoded)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, socket.timeout, OSError):
            return


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
        requested_timeout = float(timeout) if timeout is not None else MAX_SERVER_WAIT_SECONDS
        return state.job_wait(
            request.get("ticket"),
            request.get("requestKey"),
            min(requested_timeout, MAX_SERVER_WAIT_SECONDS),
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
                    state._set_phase_locked(job, "canceling")
                    state._request_process_cleanup_locked(job, reason=f"signal {signum}")
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


def daemon_contact_health(paths: Paths, error: BaseException) -> Dict[str, Any]:
    pid = read_pid(paths.pid_path)
    socket_exists = paths.socket_path.exists()
    if pid is not None and pid_alive(pid):
        verified = verify_daemon_pid_identity(paths, pid)
        state = "unresponsive" if verified else "ambiguous"
        return {
            "running": True if verified else None,
            "pid": pid,
            "socketPath": str(paths.socket_path),
            "stateDir": str(paths.state_dir),
            "health": {
                "state": state,
                "rpcResponsive": False,
                "processIdentityVerified": verified,
                "issues": [{"kind": "contactFailure", "message": str(error)[:500]}],
            },
        }
    if socket_exists or pid is not None:
        return {
            "running": None,
            "pid": pid,
            "socketPath": str(paths.socket_path),
            "stateDir": str(paths.state_dir),
            "health": {
                "state": "ambiguous",
                "rpcResponsive": False,
                "processIdentityVerified": False,
                "issues": [{"kind": "contactFailure", "message": str(error)[:500]}],
            },
        }
    return {
        "running": False,
        "pid": None,
        "socketPath": str(paths.socket_path),
        "stateDir": str(paths.state_dir),
        "health": {
            "state": "stopped",
            "rpcResponsive": False,
            "processIdentityVerified": False,
            "issues": [],
        },
    }


def request_daemon(paths: Paths, payload: Dict[str, Any], timeout: Optional[float] = None) -> Dict[str, Any]:
    request = dict(payload)
    request.setdefault("id", str(uuid.uuid4()))
    validate_json_shape(request)
    data = (json.dumps(request) + "\n").encode("utf-8")
    if len(data) > MAX_REQUEST_BYTES:
        raise ConductorError(f"request exceeds {MAX_REQUEST_BYTES} bytes")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(30.0 if timeout is None else max(0.001, timeout))
        sock.connect(str(paths.socket_path))
        sock.sendall(data)
        with sock.makefile("rb") as file:
            line = file.readline(MAX_RESPONSE_BYTES + 1)
        if not line:
            raise ConductorError("daemon closed connection without a response")
        if len(line) > MAX_RESPONSE_BYTES:
            raise ConductorError(f"daemon response exceeds {MAX_RESPONSE_BYTES} bytes")
        if not line.endswith(b"\n"):
            raise ConductorError("daemon response was not newline terminated")
        response = json.loads(line.decode("utf-8"))
        if not isinstance(response, dict):
            raise ConductorError("daemon response was not a JSON object")
        if response.get("id") != request["id"]:
            raise ConductorError("daemon response id did not match request")
    except (FileNotFoundError, ConnectionRefusedError, socket.timeout, OSError) as exc:
        message = f"could not contact daemon at {paths.socket_path}: {exc}"
        raise DaemonContactError(message, daemon_contact_health(paths, exc))
    except json.JSONDecodeError as exc:
        raise ConductorError(f"daemon returned malformed JSON: {exc}") from exc
    finally:
        sock.close()
    if not response.get("ok"):
        raise ConductorError(response.get("error") or "daemon request failed")
    payload_value = response.get("payload") or {}
    if not isinstance(payload_value, dict):
        raise ConductorError("daemon response payload was not an object")
    return payload_value


def compatible_daemon_status_or_stop_idle_mismatch(
    paths: Paths,
    *,
    startup_lock_held: bool = False,
) -> Tuple[Optional[Dict[str, Any]], Optional[ConductorError]]:
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
    stopped = (
        wait_until_stopped(
            paths,
            timeout=TERMINATE_GRACE_SECONDS + 5.0,
            startup_lock_held=True,
        )
        if startup_lock_held
        else wait_until_stopped(paths, timeout=TERMINATE_GRACE_SECONDS + 5.0)
    )
    if not stopped:
        raise ConductorError(
            f"daemon protocol mismatch (daemon={protocol}, client={PROTOCOL_VERSION}) did not stop cleanly; "
            "run './conductor daemon stop --force' after deciding it is safe"
        )
    return None, None


def ensure_daemon(paths: Paths, start_if_needed: bool = True) -> Dict[str, Any]:
    ensure_state_dirs(paths)
    recovery = cleanup_stale_files(paths)
    contact_error: Optional[ConductorError] = None
    payload, contact_error = compatible_daemon_status_or_stop_idle_mismatch(paths)
    if payload is not None:
        return payload
    if recovery.state == "ambiguous":
        error = contact_error or ConductorError(recovery.reason)
        raise DaemonContactError(
            f"refusing daemon replacement because recovery evidence is ambiguous: {recovery.reason}",
            daemon_contact_health(paths, error),
        )

    live_pid = read_pid(paths.pid_path)
    if contact_error and live_pid and pid_alive(live_pid):
        message = (
            f"daemon pid {live_pid} is alive but the socket is unresponsive; "
            "run './conductor daemon stop --force' before starting a replacement"
        )
        health = contact_error.health_payload if isinstance(contact_error, DaemonContactError) else daemon_contact_health(paths, contact_error)
        raise DaemonContactError(message, health)

    if not start_if_needed:
        if contact_error:
            raise contact_error
        raise ConductorError("daemon is not running")

    with paths.lock_path.open("a+") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        locked_recovery = cleanup_stale_files(paths, startup_lock_held=True)
        payload, locked_contact_error = compatible_daemon_status_or_stop_idle_mismatch(
            paths,
            startup_lock_held=True,
        )
        if payload is not None:
            return payload
        if locked_recovery.state == "ambiguous":
            error = locked_contact_error or ConductorError(locked_recovery.reason)
            raise DaemonContactError(
                f"refusing daemon replacement because recovery evidence is ambiguous: {locked_recovery.reason}",
                daemon_contact_health(paths, error),
            )
        locked_live_pid = read_pid(paths.pid_path)
        if locked_contact_error and locked_live_pid and pid_alive(locked_live_pid):
            message = (
                f"daemon pid {locked_live_pid} is alive but the socket is unresponsive; "
                "run './conductor daemon stop --force' before starting a replacement"
            )
            health = locked_contact_error.health_payload if isinstance(locked_contact_error, DaemonContactError) else daemon_contact_health(paths, locked_contact_error)
            raise DaemonContactError(message, health)
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


def wait_until_stopped(paths: Paths, timeout: float, *, startup_lock_held: bool = False) -> bool:
    deadline = now() + timeout
    while now() < deadline:
        if startup_lock_held:
            cleanup_stale_files(paths, startup_lock_held=True)
        else:
            cleanup_stale_files(paths)
        if not paths.socket_path.exists() and not paths.pid_path.exists():
            return True
        time.sleep(0.1)
    return False


def read_running_processes(paths: Paths, invalid: Optional[List[str]] = None) -> List[Dict[str, Any]]:
    invalid_entries = invalid if invalid is not None else []
    try:
        payload = json.loads(paths.running_processes_path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return []
    except (json.JSONDecodeError, OSError) as exc:
        raise ConductorError(f"could not safely read running-process registry: {exc}") from exc
    if not isinstance(payload, dict) or payload.get("version", 1) not in {1, 2, 3}:
        raise ConductorError("running-process registry has an unsupported schema")
    processes = payload.get("processes")
    if not isinstance(processes, list):
        raise ConductorError("running-process registry processes must be an array")
    validated: List[Dict[str, Any]] = []
    for index, item in enumerate(processes):
        if not isinstance(item, dict):
            invalid_entries.append(f"entry {index}: not an object")
            continue
        try:
            pid = int(item.get("pid"))
            pgid = int(item.get("pgid"))
        except (TypeError, ValueError):
            invalid_entries.append(f"entry {index}: invalid pid/pgid")
            continue
        process_start = item.get("processStart")
        if pid <= 0 or pgid <= 0 or not isinstance(process_start, str) or not process_start:
            invalid_entries.append(f"entry {index}: missing exact identity evidence")
            continue
        validated.append(dict(item))
    return validated


def _read_cache_attempt_recovery_group(
    paths: Paths,
    wrapper: Dict[str, Any],
    invalid: List[str],
) -> Tuple[Optional[Dict[str, Any]], Optional[Path]]:
    record_name = wrapper.get("cacheAttemptRecord")
    if record_name is None:
        return None, None
    ticket = wrapper.get("ticket")
    if not isinstance(ticket, str) or not ticket or len(ticket) > 128:
        invalid.append("cache attempt record: missing bounded ticket identity")
        return None, None
    expected_name = f"{ticket}.cache-attempt.json"
    if not isinstance(record_name, str) or record_name != expected_name or Path(record_name).name != record_name:
        invalid.append(f"cache attempt record for {ticket}: unsafe record path")
        return None, None
    record_path = paths.jobs_dir / record_name
    try:
        info = record_path.lstat()
    except FileNotFoundError:
        # The cache runner uses a pipe gate: the detached attempt cannot exec
        # until this record has been durably replaced. A missing record therefore
        # means there is no released attempt authority to recover.
        return None, record_path
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        invalid.append(f"cache attempt record for {ticket}: unsafe file identity or mode")
        return None, record_path
    try:
        payload = json.loads(record_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        invalid.append(f"cache attempt record for {ticket}: unreadable: {exc}")
        return None, record_path
    try:
        wrapper_pid = int(payload.get("wrapperPID"))
        attempt_pid = int(payload.get("attemptPID"))
        attempt_pgid = int(payload.get("attemptPGID"))
    except (AttributeError, TypeError, ValueError):
        invalid.append(f"cache attempt record for {ticket}: invalid pid/pgid")
        return None, record_path
    wrapper_start = payload.get("wrapperStartToken") if isinstance(payload, dict) else None
    attempt_start = payload.get("attemptStartToken") if isinstance(payload, dict) else None
    if not (
        isinstance(payload, dict)
        and payload.get("version") == 1
        and payload.get("state") == "active"
        and payload.get("ticket") == ticket
        and wrapper_pid == int(wrapper["pid"])
        and wrapper_start == wrapper.get("processStart")
        and attempt_pid > 0
        and attempt_pgid == attempt_pid
        and isinstance(attempt_start, str)
        and attempt_start
    ):
        invalid.append(f"cache attempt record for {ticket}: identity binding mismatch")
        return None, record_path
    return {
        "kind": "cacheAttempt",
        "ticket": ticket,
        "pid": attempt_pid,
        "pgid": attempt_pgid,
        "startToken": attempt_start,
    }, record_path


def _collect_recovery_process_groups(paths: Paths) -> Tuple[List[Dict[str, Any]], List[str], List[Path]]:
    invalid: List[str] = []
    record_paths: List[Path] = []
    try:
        processes = read_running_processes(paths, invalid=invalid)
    except ConductorError as exc:
        return [], [f"registry: {exc}"], []
    groups: List[Dict[str, Any]] = []
    for item in processes:
        attempt, record_path = _read_cache_attempt_recovery_group(paths, item, invalid)
        if record_path is not None:
            record_paths.append(record_path)
        groups.append(
            {
                "kind": "wrapper",
                "ticket": item.get("ticket"),
                "pid": int(item["pid"]),
                "pgid": int(item["pgid"]),
                "startToken": item["processStart"],
            }
        )
        if attempt is not None:
            # Stop the wrapper first so it cannot publish a successor attempt.
            # The sidecar remains supplemental evidence bound to this registry
            # entry and is re-read after wrapper exit before cleanup can finish.
            groups.append(attempt)
    return groups, invalid, record_paths


def _signal_recovery_group(
    group: Dict[str, Any],
    sig: signal.Signals,
    snapshot: Optional[Dict[int, Tuple[int, str]]],
    own_pgid: int,
) -> str:
    pid = int(group["pid"])
    pgid = int(group["pgid"])
    if snapshot is None:
        return "ambiguous"
    record = snapshot.get(pid)
    if record is None:
        return "gone"
    if record[1] != group["startToken"]:
        return "stale"
    if pgid == own_pgid:
        return "ambiguous"
    confirmation = process_table_snapshot()
    if confirmation is None:
        return "ambiguous"
    confirmed = confirmation.get(pid)
    if confirmed is None:
        return "gone"
    if confirmed[1] != group["startToken"]:
        return "stale"
    try:
        if os.getpgid(pid) != pgid:
            return "ambiguous"
        os.killpg(pgid, sig)
        return "verified"
    except ProcessLookupError:
        return "gone"
    except (PermissionError, OSError):
        return "ambiguous"


def signal_running_process_groups(paths: Paths, sig: signal.Signals) -> Dict[str, Any]:
    groups, invalid, record_paths = _collect_recovery_process_groups(paths)
    snapshot = process_table_snapshot()
    report: Dict[str, Any] = {
        "verified": [],
        "skipped": [],
        "gone": [],
        "invalid": invalid,
        "groups": [],
        "recordPaths": [str(path) for path in record_paths],
    }
    own_pgid = os.getpgrp()
    for group in groups:
        state = _signal_recovery_group(group, sig, snapshot, own_pgid)
        pid = int(group["pid"])
        report["groups"].append(
            {
                "kind": group["kind"],
                "ticket": group.get("ticket"),
                "pid": pid,
                "pgid": int(group["pgid"]),
                "startToken": group["startToken"],
                "state": state,
            }
        )
        if state == "verified":
            report["verified"].append(pid)
        elif state == "gone":
            report["gone"].append(pid)
        else:
            report["skipped"].append(pid)
    report["identityComplete"] = not invalid and all(
        group["state"] in {"verified", "gone", "stale"} for group in report["groups"]
    )
    return report


def _live_recovery_targets(targets: List[Dict[str, Any]]) -> Optional[List[Dict[str, Any]]]:
    snapshot = process_table_snapshot()
    if snapshot is None:
        return None
    live: List[Dict[str, Any]] = []
    for target in targets:
        pid = int(target["pid"])
        record = snapshot.get(pid)
        if record is None or record[1] != target["startToken"]:
            continue
        try:
            if os.getpgid(pid) != int(target["pgid"]):
                return None
            live.append(target)
        except ProcessLookupError:
            continue
        except (PermissionError, OSError):
            return None
    return live


def _wait_for_recovery_targets_exit(
    targets: List[Dict[str, Any]],
    timeout: float,
) -> Optional[List[Dict[str, Any]]]:
    if not targets:
        return []
    deadline = time.monotonic() + max(0.0, timeout)
    while True:
        live = _live_recovery_targets(targets)
        if live is None or not live or time.monotonic() >= deadline:
            return live
        time.sleep(min(PROCESS_TREE_POLL_SECONDS, max(0.0, deadline - time.monotonic())))


def _signal_exact_recovery_targets(
    targets: List[Dict[str, Any]],
    sig: signal.Signals,
) -> Tuple[bool, List[Dict[str, Any]]]:
    snapshot = process_table_snapshot()
    own_pgid = os.getpgrp()
    verified: List[Dict[str, Any]] = []
    complete = True
    for target in targets:
        state = _signal_recovery_group(target, sig, snapshot, own_pgid)
        if state == "verified":
            verified.append(target)
        elif state == "ambiguous":
            complete = False
    return complete, verified


def _settle_recovery_report(
    report: Dict[str, Any],
    kinds: set[str],
) -> Tuple[bool, Optional[Dict[str, Any]], List[Dict[str, Any]]]:
    targets = [
        group
        for group in report["groups"]
        if group["state"] == "verified" and group["kind"] in kinds
    ]
    remaining = _wait_for_recovery_targets_exit(targets, TERMINATE_GRACE_SECONDS)
    if remaining is None:
        return False, None, targets
    kill_report: Optional[Dict[str, Any]] = None
    if remaining:
        complete, kill_targets = _signal_exact_recovery_targets(remaining, signal.SIGKILL)
        kill_report = {
            "identityComplete": complete,
            "verified": [int(target["pid"]) for target in kill_targets],
        }
        if not complete:
            return False, kill_report, remaining
        remaining = _wait_for_recovery_targets_exit(kill_targets, KILL_GRACE_SECONDS)
        if remaining is None:
            return False, kill_report, kill_targets
    return not remaining, kill_report, remaining or []


def cleanup_running_process_groups(paths: Paths) -> Dict[str, Any]:
    # First stop and conclusively settle wrappers. Only wrappers can roll the
    # sidecar from attempt A to B, so the registry-bound record becomes stable
    # once their exact identities are gone.
    initial = signal_running_process_groups(paths, signal.SIGTERM)
    if not initial["identityComplete"]:
        return {"safeToForget": False, "term": initial, "kill": None, "remaining": []}
    wrappers_safe, wrapper_kill, remaining = _settle_recovery_report(initial, {"wrapper"})
    if not wrappers_safe:
        return {"safeToForget": False, "term": initial, "kill": wrapper_kill, "remaining": remaining}

    # Re-read after wrapper exit to catch both A->B replacement and a sidecar
    # published after the initial read. No wrapper remains able to create C.
    attempts = signal_running_process_groups(paths, signal.SIGTERM)
    if not attempts["identityComplete"]:
        return {"safeToForget": False, "term": attempts, "kill": None, "remaining": []}
    attempts_safe, attempt_kill, remaining = _settle_recovery_report(attempts, {"cacheAttempt"})
    if not attempts_safe:
        return {"safeToForget": False, "term": attempts, "kill": attempt_kill, "remaining": remaining}

    final = signal_running_process_groups(paths, signal.SIGTERM)
    if not final["identityComplete"]:
        return {"safeToForget": False, "term": final, "kill": None, "remaining": []}
    final_safe, final_kill, remaining = _settle_recovery_report(final, {"wrapper", "cacheAttempt"})
    if not final_safe:
        return {"safeToForget": False, "term": final, "kill": final_kill, "remaining": remaining}
    verification = signal_running_process_groups(paths, signal.SIGTERM)
    verified_live = [group for group in verification["groups"] if group["state"] == "verified"]
    safe = verification["identityComplete"] and not verified_live
    if safe:
        for raw_path in verification.get("recordPaths") or []:
            _durable_unlink(Path(raw_path))
    return {
        "safeToForget": safe,
        "term": initial,
        "kill": {"wrapper": wrapper_kill, "attempt": attempt_kill, "final": final_kill},
        "remaining": verified_live,
        "verification": verification,
    }


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
    term_report = signal_running_process_groups(paths, signal.SIGTERM)
    kill_report: Optional[Dict[str, Any]] = None
    with contextlib.suppress(ProcessLookupError, PermissionError, OSError):
        os.kill(pid, signal.SIGTERM)
    deadline = now() + TERMINATE_GRACE_SECONDS
    while pid_alive(pid) and now() < deadline:
        time.sleep(0.1)
    if pid_alive(pid):
        kill_report = signal_running_process_groups(paths, signal.SIGKILL)
        with contextlib.suppress(ProcessLookupError, PermissionError, OSError):
            os.kill(pid, signal.SIGKILL)
        deadline = now() + 2.0
        while pid_alive(pid) and now() < deadline:
            time.sleep(0.1)
    if pid_alive(pid):
        raise ConductorError(f"force-stop signaled verified daemon pid {pid}, but it is still alive; leaving pid/socket files intact")
    recovery = cleanup_stale_files(paths)
    if recovery.state not in {"cleaned", "stopped"}:
        raise ConductorError(
            f"verified daemon pid {pid} exited, but recovery evidence is {recovery.state}; "
            "preserving pid/socket files for inspection"
        )
    return {
        "stopped": True,
        "pid": pid,
        "forced": True,
        "socketPath": str(paths.socket_path),
        "stateDir": str(paths.state_dir),
        "workerSignals": {"term": term_report, "kill": kill_report},
    }


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
        sample = read_safe_regular_file_sample(
            Path(str(log_path)),
            FULL_LOG_HEAD_BYTES,
            FULL_LOG_TAIL_BYTES,
        )
        content = sample.content.decode("utf-8", errors="replace")
        print(content, end="")
        if content and not content.endswith("\n"):
            print()
        if sample.omitted_bytes:
            print(
                f"(raw log rendering bounded; omitted {sample.omitted_bytes} bytes; inspect {log_path} locally)"
            )
    except (OSError, ConductorError) as exc:
        print(f"(could not safely read log: {exc})")
        tail = payload.get("logTail") or []
        if tail:
            print("--- bounded log tail fallback ---")
            print("".join(tail[-LOG_TAIL_LINES:]), end="")
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
            contact = exc.health_payload if isinstance(exc, DaemonContactError) else {
                "running": False,
                "socketPath": str(paths.socket_path),
                "stateDir": str(paths.state_dir),
                "health": {"state": "stopped", "rpcResponsive": False, "processIdentityVerified": False, "issues": []},
            }
            contact = dict(contact)
            contact["error"] = str(exc)
            if json_mode:
                print_json(contact)
            else:
                health_state = (contact.get("health") or {}).get("state", "unknown")
                print(f"daemon {health_state}: {exc}")
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
        contact = exc.health_payload if isinstance(exc, DaemonContactError) else {
            "running": False,
            "socketPath": str(paths.socket_path),
            "stateDir": str(paths.state_dir),
            "health": {"state": "stopped", "rpcResponsive": False, "processIdentityVerified": False, "issues": []},
        }
        contact = dict(contact)
        contact["error"] = str(exc)
        if json_mode:
            print_json(contact)
        else:
            health_state = (contact.get("health") or {}).get("state", "unknown")
            print(f"conductor daemon {health_state}")
            print(f"socket: {paths.socket_path}")
            if contact.get("running") is False:
                print("start with: ./conductor daemon start")
        return 1
    if json_mode:
        print_json(payload)
    else:
        render_daemon_status(payload, shorthand=True)
    return 0


def handle_cache_command(paths: Paths, argv: List[str]) -> int:
    if not argv or argv[0] in {"-h", "--help"}:
        print("Usage: ./conductor cache status [--limit <n>] [--json] | cache drop <key> [--json]")
        return 0
    subcommand = argv[0]
    parser = argparse.ArgumentParser(prog=f"conductor cache {subcommand}")
    parser.add_argument("--json", action="store_true")
    if subcommand == "status":
        parser.add_argument("--limit", type=int, default=BUILD_CACHE_DIAGNOSTIC_MAX_ROWS)
        ns = parser.parse_args(argv[1:])
        if ns.limit <= 0:
            raise ConductorError("cache status limit must be greater than zero")
        payload = BuildCacheManager(paths.repo_root, startup_hygiene=False).status(ns.limit)
        if ns.json:
            print_json(payload)
        else:
            print(f"build cache: {payload['storePath']}")
            print(f"entries: {payload['entryCount']}")
            for entry in payload["entries"]:
                print(
                    f"  {entry.get('key')} generation={entry.get('generation')} "
                    f"size={format_bytes(entry.get('sizeBytes'))} suspect={entry.get('suspectCount', 0)}"
                )
        return 0
    if subcommand == "drop":
        parser.add_argument("key")
        ns = parser.parse_args(argv[1:])
        dropped = BuildCacheManager(paths.repo_root).drop(ns.key)
        payload = {"key": ns.key, "dropped": dropped}
        if ns.json:
            print_json(payload)
        else:
            print("dropped" if dropped else "not found")
        return 0
    raise ConductorError(f"unknown cache command '{subcommand}'")


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
            output_mode = "full" if getattr(ns, "full_log", False) else "summary"
            payload = wait_for_terminal(
                paths,
                ns.ticket,
                ns.request_key,
                json_mode=ns.json,
                output_mode=output_mode,
                user_timeout=ns.timeout,
            )
        else:
            payload = request_daemon(paths, req, timeout=CANCEL_RPC_TIMEOUT_SECONDS)
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


def _retryable_wait_contact_failure(error: ConductorError) -> bool:
    if not isinstance(error, DaemonContactError):
        return False
    health_payload = error.health_payload
    health = health_payload.get("health")
    return bool(
        health_payload.get("running") is True
        and isinstance(health, dict)
        and health.get("processIdentityVerified") is True
    )


def wait_for_terminal(
    paths: Paths,
    ticket: Optional[str],
    request_key: Optional[str],
    json_mode: bool,
    output_mode: str = "summary",
    user_timeout: Optional[float] = None,
    *,
    clock: Any = time.monotonic,
    poll_wait: Any = None,
) -> Dict[str, Any]:
    deadline = None if user_timeout is None else clock() + user_timeout
    pause = poll_wait or (lambda seconds: threading.Event().wait(seconds))
    degraded_to_status = False
    status_poll_attempted = False
    announced_degradation = False
    consecutive_contact_failures = 0
    last_payload: Optional[Dict[str, Any]] = None
    last_state: Optional[str] = None
    last_tail: List[str] = []
    last_blockers: Optional[Tuple[Tuple[str, ...], ...]] = None
    printed_progress: Deque[str] = deque(maxlen=200)
    printed_progress_set: set[str] = set()
    last_progress_at = now()

    def timed_out_payload(candidate: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        base = dict(last_payload or candidate or {"ticket": ticket, "requestKey": request_key, "state": "unknown"})
        base["waitTimedOut"] = True
        return base

    while True:
        remaining = None if deadline is None else max(0.0, deadline - clock())
        if last_payload is not None and remaining == 0:
            return timed_out_payload()

        if degraded_to_status:
            pause_seconds = WAIT_STATUS_POLL_SECONDS if remaining is None else min(WAIT_STATUS_POLL_SECONDS, remaining)
            if (last_payload is not None or status_poll_attempted) and pause_seconds > 0:
                pause(pause_seconds)
            remaining = None if deadline is None else max(0.0, deadline - clock())
            if last_payload is not None and remaining == 0:
                return timed_out_payload()
            status_poll_attempted = True
            try:
                payload = request_daemon(
                    paths,
                    {"type": "job-status", "ticket": ticket, "requestKey": request_key},
                    timeout=WAIT_RPC_CONTACT_SECONDS,
                )
            except ConductorError as exc:
                error = str(exc)
                if error.startswith("server wait-handler capacity exhausted") or error == "daemon closed connection without a response":
                    continue
                if _retryable_wait_contact_failure(exc):
                    consecutive_contact_failures += 1
                    if consecutive_contact_failures <= MAX_CONSECUTIVE_WAIT_CONTACT_FAILURES:
                        continue
                raise
        else:
            server_wait = WAIT_POLL_SECONDS if remaining is None else min(WAIT_POLL_SECONDS, remaining)
            transport_timeout = (
                server_wait + WAIT_RPC_CONTACT_SECONDS
                if remaining is None
                else max(
                    WAIT_RPC_CONTACT_SECONDS,
                    min(server_wait + WAIT_RPC_CONTACT_SECONDS, remaining),
                )
            )
            try:
                payload = request_daemon(
                    paths,
                    {"type": "job-wait", "ticket": ticket, "requestKey": request_key, "timeout": server_wait},
                    timeout=transport_timeout,
                )
            except ConductorError as exc:
                error = str(exc)
                retryable_contact_failure = _retryable_wait_contact_failure(exc)
                if not (
                    error.startswith("server wait-handler capacity exhausted")
                    or error == "daemon closed connection without a response"
                    or retryable_contact_failure
                ):
                    raise
                if retryable_contact_failure:
                    consecutive_contact_failures += 1
                    if consecutive_contact_failures > MAX_CONSECUTIVE_WAIT_CONTACT_FAILURES:
                        raise
                degraded_to_status = True
                if not json_mode and not announced_degradation:
                    print("wait response unavailable; polling bounded job status instead")
                    announced_degradation = True
                continue
        consecutive_contact_failures = 0
        if deadline is not None and clock() > deadline:
            return timed_out_payload(payload)
        last_payload = payload
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


def execution_location_ui_smoke_timeout(env: Dict[str, str]) -> float:
    try:
        wait_seconds = max(0.0, float(env.get("REPOPROMPT_EXECUTION_LOCATION_UI_SMOKE_WAIT", "3")))
    except ValueError:
        wait_seconds = 3.0
    try:
        cycles = max(1, int(env.get("REPOPROMPT_EXECUTION_LOCATION_UI_SMOKE_CYCLES", "3")))
    except ValueError:
        cycles = 3
    return cycles * (wait_seconds + 60.0) + 60.0


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

    if args.get("executionLocationUI"):
        debug_pids = find_debug_app_pids()
        if len(debug_pids) != 1:
            print(
                "ERROR: execution-location UI smoke requires exactly one running RepoPrompt debug app "
                f"matching {debug_app_executable_path()}; found {len(debug_pids)}.",
                flush=True,
            )
            return 1
        code, _stdout, _stderr = run_operation_command(
            "execution location UI smoke",
            [str(repo_root / "Scripts" / "smoke_agent_execution_location_popover.sh"), debug_pids[0]],
            repo_root,
            env=env,
            timeout=execution_location_ui_smoke_timeout(env),
        )
        if code != 0:
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
                total += current.lstat().st_size
            except OSError:
                pass
        except OSError:
            continue
    return total


def latest_mtime(path: Path) -> Optional[float]:
    try:
        return path.lstat().st_mtime
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
    immutable = BuildCacheManager(repo_root, startup_hygiene=False).status(limit)
    print(f"Immutable seed store: {immutable['storePath']}", flush=True)
    print(f"Immutable seed entries: {immutable['entryCount']}", flush=True)
    for entry in immutable["entries"]:
        print(
            f"  key={entry.get('key')} generation={entry.get('generation')} "
            f"size={format_bytes(entry.get('sizeBytes'))} source={entry.get('sourceHead')} "
            f"suspect={entry.get('suspectCount', 0)}",
            flush=True,
        )
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


def run_cache_attempt_gate(read_fd: int, payload_json: str) -> int:
    try:
        argv = json.loads(payload_json)
    except json.JSONDecodeError as exc:
        raise ConductorError(f"cache attempt gate received invalid argv: {exc}") from exc
    if not isinstance(argv, list) or not argv or not all(isinstance(item, str) and item for item in argv):
        raise ConductorError("cache attempt gate requires a non-empty argv")
    try:
        release = os.read(read_fd, 1)
    finally:
        with contextlib.suppress(OSError):
            os.close(read_fd)
    if release != b"1":
        # The parent died or rejected identity publication before releasing the
        # gate. No build command or descendant was started.
        return 125
    try:
        os.execvpe(argv[0], list(argv), os.environ)
    except OSError as exc:
        raise ConductorError(f"cache attempt gate could not exec {argv[0]}: {exc}") from exc
    return 125


def _run_cache_attempt(
    argv: Sequence[str],
    repo_root: Path,
    attempt_timeout: Optional[float],
    attempt_record_path: Path,
    ticket: str,
) -> Tuple[int, bool]:
    wrapper_start = process_start_token(os.getpid())
    if not wrapper_start:
        raise ConductorError("cache retry wrapper lacks an exact process start token")
    read_fd, write_fd = os.pipe()
    process: Optional[subprocess.Popen[bytes]] = None
    gate_released = False
    record_published = False
    attempt_reaped = False
    try:
        gate_argv = [
            sys.executable,
            str(Path(__file__).resolve()),
            "__cache_attempt_gate",
            str(read_fd),
            json.dumps(list(argv), separators=(",", ":")),
        ]
        process = subprocess.Popen(
            gate_argv,
            cwd=str(repo_root),
            stdin=subprocess.DEVNULL,
            pass_fds=(read_fd,),
            start_new_session=True,
        )
        os.close(read_fd)
        read_fd = -1
        attempt_start = process_start_token(process.pid)
        try:
            attempt_pgid = os.getpgid(process.pid)
        except OSError as exc:
            raise ConductorError(f"cache attempt process-group identity unavailable: {exc}") from exc
        if not attempt_start or attempt_pgid != process.pid:
            raise ConductorError("cache attempt lacks an exact session-leader identity")
        _atomic_write_json(
            attempt_record_path,
            {
                "version": 1,
                "state": "active",
                "ticket": ticket,
                "wrapperPID": os.getpid(),
                "wrapperStartToken": wrapper_start,
                "attemptPID": process.pid,
                "attemptPGID": attempt_pgid,
                "attemptStartToken": attempt_start,
                "publishedAt": now(),
            },
        )
        record_published = True
        if os.write(write_fd, b"1") != 1:
            raise ConductorError("cache attempt gate release was incomplete")
        os.close(write_fd)
        write_fd = -1
        gate_released = True
        try:
            exit_code = process.wait(timeout=attempt_timeout)
            attempt_reaped = True
            return exit_code, False
        except subprocess.TimeoutExpired:
            with contextlib.suppress(ProcessLookupError, PermissionError, OSError):
                os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=TERMINATE_GRACE_SECONDS)
                attempt_reaped = True
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError, PermissionError, OSError):
                    os.killpg(process.pid, signal.SIGKILL)
                try:
                    process.wait(timeout=KILL_GRACE_SECONDS)
                    attempt_reaped = True
                except subprocess.TimeoutExpired:
                    pass
            if process.poll() is None:
                raise ConductorError("timed-out cache attempt did not exit after process-group escalation")
            attempt_reaped = True
            return 124, True
    finally:
        if read_fd >= 0:
            with contextlib.suppress(OSError):
                os.close(read_fd)
        if write_fd >= 0:
            with contextlib.suppress(OSError):
                os.close(write_fd)
        if process is not None and not gate_released:
            # EOF keeps the detached gate from execing the real build. Reap it
            # within a fixed allowance; no descendant can exist before release.
            try:
                process.wait(timeout=KILL_GRACE_SECONDS)
                attempt_reaped = True
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError, PermissionError, OSError):
                    process.kill()
                try:
                    process.wait(timeout=KILL_GRACE_SECONDS)
                    attempt_reaped = True
                except subprocess.TimeoutExpired:
                    pass
        if record_published and attempt_reaped:
            _durable_unlink(attempt_record_path)


def _remove_cache_build_for_retry(build_dir: Path, cleanup_timeout: float) -> bool:
    try:
        completed = subprocess.run(
            ["/bin/rm", "-rf", str(build_dir)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=cleanup_timeout,
        )
        return completed.returncode == 0 and not build_dir.exists() and not build_dir.is_symlink()
    except (OSError, subprocess.TimeoutExpired):
        return False


def _await_cache_retry_wrapper_gate() -> None:
    raw_fd = os.environ.pop("REPOPROMPT_CONDUCTOR_CACHE_WRAPPER_GATE_FD", None)
    if raw_fd is None:
        return
    try:
        read_fd = int(raw_fd)
    except ValueError as exc:
        raise ConductorError("cache retry wrapper gate fd is invalid") from exc
    if read_fd < 3:
        raise ConductorError("cache retry wrapper gate requires an inherited private fd")
    try:
        release = os.read(read_fd, 1)
    finally:
        with contextlib.suppress(OSError):
            os.close(read_fd)
    if release != b"1":
        raise ConductorError("cache retry wrapper was not released after durable registry publication")


def operation_cache_retry(repo_root: Path, args: Dict[str, Any]) -> int:
    _await_cache_retry_wrapper_gate()
    argv = args.get("argv")
    key = str(args.get("key") or "")
    outcome_path = Path(str(args.get("outcomePath") or ""))
    attempt_record_path = Path(str(args.get("attemptRecordPath") or ""))
    ticket = str(args.get("ticket") or "")
    raw_attempt_timeout = args.get("attemptTimeout")
    raw_cleanup_timeout = args.get("cleanupTimeout", BUILD_CACHE_CLONE_MAX_SECONDS)
    if not isinstance(argv, list) or not argv or not all(isinstance(item, str) and item for item in argv):
        raise ConductorError("cache retry requires a non-empty argv")
    if not re.fullmatch(r"[0-9a-f]{64}", key):
        raise ConductorError("cache retry requires an exact key")
    if not ticket or len(ticket) > 128 or attempt_record_path.name != f"{ticket}.cache-attempt.json":
        raise ConductorError("cache retry requires a ticket-bound attempt record")
    if attempt_record_path.parent != outcome_path.parent or not attempt_record_path.parent.is_dir():
        raise ConductorError("cache retry attempt record must share the existing outcome directory")
    attempt_timeout = None if raw_attempt_timeout is None else float(raw_attempt_timeout)
    if attempt_timeout is not None and (not math.isfinite(attempt_timeout) or attempt_timeout < 0):
        raise ConductorError("cache retry attempt timeout must be a finite non-negative number")
    cleanup_timeout = float(raw_cleanup_timeout)
    if not math.isfinite(cleanup_timeout) or cleanup_timeout < 0:
        raise ConductorError("cache retry cleanup timeout must be a finite non-negative number")

    first_code, first_timed_out = _run_cache_attempt(
        argv,
        repo_root,
        attempt_timeout,
        attempt_record_path,
        ticket,
    )
    if first_code == 0:
        return 0
    build_dir = repo_root / ".build"
    provenance = BuildCacheManager._read_json_file(build_dir / ".conductor-cache-provenance.json")
    outcome: Dict[str, Any] = {
        "attemptTimeoutSeconds": attempt_timeout,
        "cleanupTimeoutSeconds": cleanup_timeout,
        "seededExitCode": first_code,
        "seededTimedOut": first_timed_out,
        "coldRetryAttempted": False,
    }
    if not (
        provenance
        and provenance.get("key") == key
        and build_dir.is_dir()
        and not build_dir.is_symlink()
    ):
        outcome["reason"] = "seed provenance unavailable; cold retry refused"
        if outcome_path.parent.is_dir():
            _atomic_write_json(outcome_path, outcome)
        return first_code

    print("seeded build failed; removing the proven seeded .build and retrying cold once", flush=True)
    if not _remove_cache_build_for_retry(build_dir, cleanup_timeout):
        outcome["reason"] = "proven seeded .build removal exceeded its bounded cleanup allowance"
        if outcome_path.parent.is_dir():
            _atomic_write_json(outcome_path, outcome)
        return first_code
    outcome["coldRetryAttempted"] = True
    cold_code, cold_timed_out = _run_cache_attempt(
        argv,
        repo_root,
        attempt_timeout,
        attempt_record_path,
        ticket,
    )
    outcome["coldExitCode"] = cold_code
    outcome["coldTimedOut"] = cold_timed_out
    outcome["coldSucceeded"] = cold_code == 0
    if cold_code == 0:
        try:
            manager = BuildCacheManager(repo_root)
            outcome.update(manager.confirm_seeded_failure(key))
        except Exception as exc:
            # A successful cold build is authoritative. Suspect bookkeeping is
            # advisory, but its failure remains visible in the retained outcome.
            outcome["suspectBookkeepingError"] = str(exc)[:500]
    if outcome_path.parent.is_dir():
        _atomic_write_json(outcome_path, outcome)
    return cold_code


def run_operation_runner(payload_json: str) -> int:
    payload = json.loads(payload_json)
    kind = payload.get("kind")
    args = payload.get("args") or {}
    repo_root = Path(payload.get("repoRoot") or resolve_repo_root()).resolve()
    if kind == "swift_build_all":
        return operation_swift_build_all(repo_root)
    if kind == "cache_retry":
        return operation_cache_retry(repo_root, args)
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
    if kind == "diagnostics_focused_build" or kind == "diagnostics_high_output":
        import conductor_diagnostics

        return conductor_diagnostics.run_diagnostic(kind, repo_root, args)
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
        "codex-schema-check",
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
        parser.add_argument("--filter")
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
        parser.add_argument("--execution-location-ui", action="store_true")
        ns = parser.parse_args(rest)
        if ns.agent_timeout < 0:
            raise ConductorError("--agent-timeout must be non-negative")
        if ns.artifact_manifest and not ns.packaged_app:
            raise ConductorError("--artifact-manifest requires --packaged-app")
        if ns.packaged_app and ns.agent_run:
            raise ConductorError("--agent-run is not supported with --packaged-app")
        if ns.packaged_app and ns.execution_location_ui:
            raise ConductorError("--execution-location-ui is not supported with --packaged-app")
        args.update(
            {
                "launch": ns.launch,
                "packagedApp": ns.packaged_app,
                "artifactManifest": ns.artifact_manifest,
                "workspace": ns.workspace,
                "windowId": ns.window_id,
                "agentRun": ns.agent_run,
                "agentTimeout": ns.agent_timeout,
                "executionLocationUI": ns.execution_location_ui,
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

        focused_build = subparsers.add_parser("focused-build")
        focused_build.add_argument("--product", default="RepoPrompt")
        focused_build.add_argument("--test", action="store_true")
        focused_build.add_argument("--filter")

        high_output = subparsers.add_parser("high-output")
        high_output.add_argument("--lines", type=int, default=1000)
        high_output.add_argument("--warnings", type=int, default=0)
        high_output.add_argument("--exit-code", type=int, default=0)
        high_output.add_argument("--linger", type=float, default=0.0)

        ns = parser.parse_args(rest)
        args["subcommand"] = ns.subcommand
        if ns.subcommand == "agent-mode-on":
            args.update({"logFile": ns.log_file, "windowId": ns.window_id})
        elif ns.subcommand == "build-cache":
            if ns.limit <= 0:
                raise ConductorError("diagnostics build-cache --limit must be greater than zero")
            args["limit"] = ns.limit
        elif ns.subcommand == "focused-build":
            args.update({
                "product": ns.product,
                "runTests": ns.test or bool(ns.filter),
                "testFilter": ns.filter,
            })
        elif ns.subcommand == "high-output":
            if ns.lines < 0:
                raise ConductorError("diagnostics high-output --lines must be non-negative")
            if ns.warnings < 0:
                raise ConductorError("diagnostics high-output --warnings must be non-negative")
            if ns.exit_code < 0 or ns.exit_code > 255:
                raise ConductorError("diagnostics high-output --exit-code must be 0-255")
            if ns.linger < 0:
                raise ConductorError("diagnostics high-output --linger must be non-negative")
            args.update({
                "lines": ns.lines,
                "warnings": ns.warnings,
                "exitCode": ns.exit_code,
                "linger": ns.linger,
            })
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
    if argv and argv[0] == "__cache_attempt_gate":
        if len(argv) != 3:
            raise ConductorError("__cache_attempt_gate requires a read fd and argv JSON")
        try:
            read_fd = int(argv[1])
        except ValueError as exc:
            raise ConductorError("__cache_attempt_gate requires an integer read fd") from exc
        if read_fd < 3:
            raise ConductorError("__cache_attempt_gate requires an inherited private read fd")
        return run_cache_attempt_gate(read_fd, argv[2])
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
    if command == "cache":
        return handle_cache_command(paths, argv[1:])
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
