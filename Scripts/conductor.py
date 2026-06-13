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
import dataclasses
import fcntl
import hashlib
import json
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

PROTOCOL_VERSION = 5
TERMINAL_STATES = {"completed", "failed", "canceled"}
LANE_NAMES = {"build", "debugArtifact", "liveApp", "release", "style"}
LOG_TAIL_LINES = 30
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
FORCE_STOP_RPC_TIMEOUT_SECONDS = 30.0
APP_STOP_POLL_SECONDS = 0.2
APP_STOP_QUIET_SECONDS = 1.0
APP_STOP_DELAYED_LAUNCH_GUARD_SECONDS = 12.0
APP_STOP_CONFIRM_TIMEOUT_SECONDS = 8.0
APP_STOP_DELAYED_LAUNCH_CONFIRM_TIMEOUT_SECONDS = 25.0

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
  ./conductor test [--filter <filter>]
  ./conductor provider-test [--filter <filter>]
  ./conductor install-debug-cli
  ./conductor debug-cli-status
  ./conductor run [-- <app args...>]                  # FIFO coordinated run
  ./conductor app status
  ./conductor app stop                                 # latest interactive stop intent
  ./conductor app relaunch [-- <app args...>]          # latest interactive relaunch intent
  ./conductor smoke [--launch | --packaged-app <path>] [--artifact-manifest <path>] [--workspace <name>] [--window-id <id>] [--agent-run]
    (without --launch/--packaged-app, requires the CE debug app to already be running and CLI installed)
  ./conductor diagnostics agent-mode-on [--log-file <path>]
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
  overrides: REPOPROMPT_DEV_DAEMON_STATE_DIR, REPOPROMPT_DEV_DAEMON_SOCKET (socket parent must be owned 0700)

Protocol version: {PROTOCOL_VERSION}
"""


class ConductorError(Exception):
    pass


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
        r"(ERROR:|FAILED|failed with|process exited with status|fatal error|Traceback|Exception|Permission denied|No such file or directory|timed out|killing process group|terminating process group)",
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
    TIMEOUT_RE = re.compile(r"(timed out after|terminating process group|killing process group|canceled)", re.IGNORECASE)
    PHASE_RE = re.compile(r"^(==>|\$ |\+ )")
    ARTIFACT_RE = re.compile(
        r"^(Created:|APP_BUNDLE=|COMPAT_APP_BUNDLE=|CLI_PATH=|Output written to:|Agent Mode diagnostics enabled|Resolved rpce-cli-debug:)"
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
    if operation == "app" and args.get("subcommand") in {"status", "stop", "relaunch"}:
        return f"app {args['subcommand']}"
    return operation


def latest_lifecycle_intent(operation: str, args: Dict[str, Any]) -> Optional[str]:
    if operation == "app" and args.get("subcommand") in {"stop", "relaunch"}:
        return operation_display_name(operation, args)
    return None


def is_launch_capable_job(operation: str, args: Dict[str, Any]) -> bool:
    return (
        operation == "run"
        or (operation == "app" and args.get("subcommand") == "relaunch")
        or (operation == "smoke" and bool(args.get("launch") or args.get("packagedApp")))
    )


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
    process_pid: Optional[int] = None
    process_pgid: Optional[int] = None
    exit_code: Optional[int] = None
    error: Optional[str] = None
    result_summary: Optional[str] = None
    cancel_requested: bool = False
    superseded_by_ticket: Optional[str] = None
    superseded_by_operation: Optional[str] = None
    timed_out: bool = False
    output_summary: Optional[Dict[str, Any]] = None
    tail: Deque[str] = dataclasses.field(default_factory=lambda: deque(maxlen=LOG_TAIL_LINES))

    def to_payload(self, include_tail: bool = True, include_summary: bool = True) -> Dict[str, Any]:
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
            "logPath": str(self.log_path),
            "processPID": self.process_pid,
            "processPGID": self.process_pgid,
            "exitCode": self.exit_code,
            "error": self.error,
            "resultSummary": self.result_summary,
            "cancelRequested": self.cancel_requested,
            "supersededByTicket": self.superseded_by_ticket,
            "supersededByOperation": self.superseded_by_operation,
            "timedOut": self.timed_out,
        }
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
    PASSTHROUGH_ENV_KEYS = sorted(set(SIGNING_ENV_KEYS + DEBUG_ENV_KEYS + BUILD_ENV_KEYS + STYLE_ENV_KEYS))

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
            return [script("source_layout_guardrails.sh")], lanes, cwd, env, effective_timeout
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
            if args.get("filter"):
                argv.extend(["--filter", str(args["filter"])])
            return argv, ["build"], cwd, env, effective_timeout
        if operation == "provider-test":
            argv = ["swift", "test"]
            if args.get("filter"):
                argv.extend(["--filter", str(args["filter"])])
            return argv, ["build"], self.repo_root / "Packages" / "RepoPromptAgentProviders", env, effective_timeout
        if operation == "install-debug-cli":
            return [script("install_debug_cli.sh"), "install", "--build"], ["build", "debugArtifact"], cwd, env, effective_timeout
        if operation == "debug-cli-status":
            return [script("install_debug_cli.sh"), "status"], lanes, cwd, env, effective_timeout
        if operation == "run":
            return [script("run.sh"), *[str(arg) for arg in args.get("appArgs") or []]], ["build", "debugArtifact", "liveApp"], cwd, env, effective_timeout
        if operation == "app":
            subcommand = args.get("subcommand")
            if subcommand == "stop":
                internal_args = {"guardDelayedLaunch": bool(args.get("guardDelayedLaunch"))}
                return self._internal_argv("app_stop", internal_args), ["liveApp"], cwd, env, effective_timeout
            if subcommand == "status":
                return self._internal_argv("app_status", {}), lanes, cwd, env, effective_timeout
            if subcommand == "relaunch":
                if args.get("guardDelayedLaunch"):
                    env["REPOPROMPT_GUARD_DELAYED_LAUNCH"] = "1"
                return [script("run.sh"), *[str(arg) for arg in args.get("appArgs") or []]], ["build", "debugArtifact", "liveApp"], cwd, env, effective_timeout
        if operation == "smoke":
            lanes = ["debugArtifact", "liveApp"]
            if args.get("launch"):
                lanes = ["build", "debugArtifact", "liveApp"]
            elif args.get("packagedApp"):
                lanes = ["liveApp"]
            smoke_args = dict(args)
            smoke_args["operationTimeout"] = effective_timeout
            return self._internal_argv("smoke", smoke_args), lanes, cwd, env, effective_timeout
        if operation == "diagnostics":
            return self._internal_argv("diagnostics_agent_mode_on", dict(args)), ["debugArtifact", "liveApp"], cwd, env, effective_timeout
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
        if operation == "app" and args.get("subcommand") in {"stop", "relaunch"}:
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
            while job and job.state == "running" and not (job.process_pid or job.process_pgid):
                self.condition.wait(timeout=0.1)
                job = self.jobs.get(ticket)
            if not job or job.state != "running":
                return
            if not termination_sent:
                self._terminate_process_group_locked(job, reason=reason)
            deadline = now() + TERMINATE_GRACE_SECONDS
            while job.state == "running" and now() < deadline:
                self.condition.wait(timeout=min(0.1, max(0.0, deadline - now())))
            if job.state == "running":
                self._kill_process_group_locked(job, reason=f"{reason}; SIGKILL after grace period")
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
        deadline = now() + TERMINATE_GRACE_SECONDS
        while now() < deadline:
            with self.condition:
                if all((self.jobs.get(ticket) is None or self.jobs[ticket].state != "running") for ticket in tickets):
                    break
            time.sleep(0.1)
        with self.condition:
            for ticket in tickets:
                job = self.jobs.get(ticket)
                if job and job.state == "running":
                    self._kill_process_group_locked(job, reason="daemon stop --force; SIGKILL after grace period")
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

    def _run_job(self, ticket: str) -> None:
        job: Optional[Job] = None
        process: Optional[subprocess.Popen[bytes]] = None
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
            start_line = f"$ {format_argv(argv)}\n"
            with job.log_path.open("ab") as log_file:
                with self.lock:
                    self._append_tail_locked(job, start_line)
                log_file.write(start_line.encode("utf-8", errors="replace"))
                log_file.flush()
                process = subprocess.Popen(
                    argv,
                    cwd=str(cwd),
                    env=env,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
                with self.condition:
                    job.process_pid = process.pid
                    with contextlib.suppress(OSError):
                        job.process_pgid = os.getpgid(process.pid)
                    self._write_running_processes_locked()
                    if job.cancel_requested and job.superseded_by_ticket is None:
                        self._terminate_process_group_locked(job, reason="cancellation requested before PID assignment")
                    self.condition.notify_all()

                reader = threading.Thread(
                    target=self._read_process_output,
                    args=(job.ticket, process, log_file),
                    daemon=True,
                )
                reader.start()
                try:
                    exit_code = process.wait(timeout=effective_timeout)
                except subprocess.TimeoutExpired:
                    with self.condition:
                        job.timed_out = True
                        job.error = f"timed out after {effective_timeout:.1f}s"
                        self._append_system_line_locked(job, job.error + "\n")
                        self._terminate_process_group_locked(job, reason=job.error)
                    try:
                        exit_code = process.wait(timeout=TERMINATE_GRACE_SECONDS)
                    except subprocess.TimeoutExpired:
                        with self.condition:
                            self._kill_process_group_locked(job, reason="SIGKILL after timeout grace period")
                        exit_code = process.wait()
                    if exit_code == 0:
                        exit_code = 124
                reader.join(timeout=2.0)
                with self.condition:
                    if job.cancel_requested:
                        job.state = "canceled"
                        job.exit_code = 130
                        job.result_summary = "canceled"
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

    def _read_process_output(self, ticket: str, process: subprocess.Popen[bytes], log_file: Any) -> None:
        assert process.stdout is not None
        while True:
            chunk = process.stdout.readline()
            if not chunk:
                break
            log_file.write(chunk)
            log_file.flush()
            text = chunk.decode("utf-8", errors="replace")
            with self.condition:
                job = self.jobs.get(ticket)
                if job:
                    self._append_tail_locked(job, text)
                    self.condition.notify_all()

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
        while job.state == "running" and not (job.process_pid or job.process_pgid) and now() < pid_deadline:
            self.condition.wait(timeout=0.05)
        if job.state != "running":
            return
        self._terminate_process_group_locked(job, reason=reason)
        term_deadline = now() + TERMINATE_GRACE_SECONDS
        while job.state == "running" and now() < term_deadline:
            self.condition.wait(timeout=0.1)
        if job.state != "running":
            return
        self._kill_process_group_locked(job, reason=f"{reason}; SIGKILL after grace period")
        kill_deadline = now() + 2.0
        while job.state == "running" and now() < kill_deadline:
            self.condition.wait(timeout=0.1)

    def _terminate_process_group_locked(self, job: Job, reason: str) -> None:
        self._append_system_line_locked(job, f"terminating process group: {reason}\n")
        pgid = job.process_pgid or job.process_pid
        if pgid:
            with contextlib.suppress(ProcessLookupError, PermissionError, OSError):
                os.killpg(pgid, signal.SIGTERM)

    def _kill_process_group_locked(self, job: Job, reason: str) -> None:
        self._append_system_line_locked(job, f"killing process group: {reason}\n")
        pgid = job.process_pgid or job.process_pid
        if pgid:
            with contextlib.suppress(ProcessLookupError, PermissionError, OSError):
                os.killpg(pgid, signal.SIGKILL)

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
            print(f"  {lane}: {job.get('ticket')} {job.get('operationLabel') or job.get('operation')} [{job.get('state')}]")
    else:
        print("active lanes: none")
    print(f"queued:   {payload.get('queueDepth', 0)}")
    print(f"retained terminal jobs: {payload.get('retainedTerminalCount', 0)}")
    if shorthand and payload.get("queuedJobs"):
        print("queued jobs:")
        for job in payload.get("queuedJobs") or []:
            print(f"  {job.get('ticket')} {job.get('operationLabel') or job.get('operation')} lanes={','.join(job.get('lanes') or [])}")


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
    status_script = repo_root / "Scripts" / "install_debug_cli.sh"
    code, _stdout, _stderr = run_operation_command("debug CLI status", [str(status_script), "status"], repo_root, allow_exit_codes={0, 1})
    return 0 if code in {0, 1} else code


def operation_app_stop(repo_root: Path, args: Dict[str, Any]) -> int:
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

    window_id = str(args.get("windowId") or 1)
    workspace = str(args.get("workspace") or "repoprompt-ce")
    operation_timeout = float(args.get("operationTimeout") or MEDIUM_TIMEOUT_SECONDS)
    deadline = now() + operation_timeout

    launched = bool(args.get("launch"))
    if launched:
        code, _stdout, _stderr = run_operation_command("launch debug app", [str(repo_root / "Scripts" / "run.sh")], repo_root, env=env)
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
        ("workspace switch", [cli, "-w", window_id, "-e", f"workspace switch {workspace}"]),
        ("tree roots", [cli, "-w", window_id, "-e", "tree --type roots"]),
        ("manage_worktree list", [cli, "-w", window_id, "-e", "manage_worktree op=list"]),
        (
            "agent_manage roles",
            [cli, "-w", window_id, "-c", "agent_manage", "-j", json.dumps({"op": "list_agents", "roles_only": True})],
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
            [cli, "-w", window_id, "-c", "agent_run", "-j", json.dumps(start_payload)],
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
            [cli, "-w", window_id, "-c", "agent_run", "-j", json.dumps(wait_payload)],
            repo_root,
            env=env,
            timeout=agent_timeout + 10.0,
        )
        if code != 0:
            return code
    return 0


def operation_diagnostics_agent_mode_on(repo_root: Path, args: Dict[str, Any]) -> int:
    cli = require_debug_cli()
    if not cli:
        return 1
    window_id = str(args.get("windowId") or 1)
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
            [cli, "-w", window_id, "-c", "app_settings", "-j", json.dumps(payload)],
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
    if kind == "smoke":
        return operation_smoke(repo_root, args)
    if kind == "diagnostics_agent_mode_on":
        return operation_diagnostics_agent_mode_on(repo_root, args)
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
    elif operation == "test":
        parser = argparse.ArgumentParser(prog="conductor test")
        parser.add_argument("--filter")
        ns = parser.parse_args(rest)
        if ns.filter:
            args["filter"] = ns.filter
    elif operation == "provider-test":
        parser = argparse.ArgumentParser(prog="conductor provider-test")
        parser.add_argument("--filter")
        ns = parser.parse_args(rest)
        if ns.filter:
            args["filter"] = ns.filter
    elif operation == "run":
        app_args = rest[1:] if rest and rest[0] == "--" else rest
        args["appArgs"] = app_args
    elif operation == "app":
        if not rest or rest[0] not in {"status", "stop", "relaunch"}:
            raise ConductorError("usage: ./conductor app status|stop|relaunch [-- <app args...>]")
        args["subcommand"] = rest[0]
        trailing = rest[1:]
        if args["subcommand"] in {"status", "stop"} and trailing:
            raise ConductorError(f"app {args['subcommand']} does not accept application arguments")
        if args["subcommand"] == "relaunch":
            if trailing and trailing[0] != "--":
                raise ConductorError("app relaunch application arguments must follow '--'")
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
        parser.add_argument("subcommand", choices=["agent-mode-on"])
        parser.add_argument("--log-file", default="/tmp/repoprompt-ce-claude-raw-events")
        parser.add_argument("--window-id", type=int, default=1)
        ns = parser.parse_args(rest)
        args.update({"subcommand": ns.subcommand, "logFile": ns.log_file, "windowId": ns.window_id})
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
    paths = compute_paths(repo_root)
    ensure_state_dirs(paths)

    if argv and argv[0] == "__daemon":
        parser = argparse.ArgumentParser(prog="conductor.py __daemon")
        parser.add_argument("--repo-root", required=True)
        ns = parser.parse_args(argv[1:])
        daemon_paths = compute_paths(Path(ns.repo_root))
        return run_daemon(daemon_paths)
    if argv and argv[0] == "__operation_runner":
        if len(argv) != 2:
            raise ConductorError("__operation_runner requires one JSON payload argument")
        return run_operation_runner(argv[1])

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
