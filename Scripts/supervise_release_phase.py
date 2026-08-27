#!/usr/bin/env python3
"""Bounded, process-group-safe runner for material release phases.

The wrapped command is started in a new POSIX session. Its combined stdout and
stderr are retained in a mode-0600 descriptor whose pathname is securely
unlinked before command launch; only structured, sanitized lifecycle events
are written to this process's stderr. The raw capture is never caller-visible
and must never be uploaded because it may contain secrets.

Shell callers must use ``exec`` when launching this supervisor so SIGINT,
SIGTERM, and SIGHUP from the workflow runner reach it directly.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import errno
import json
import math
import os
import re
import signal
import stat
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any, BinaryIO, Iterable, TextIO

EXIT_TIMEOUT = 124
EXIT_CLEANUP_FAILURE = 125
EXIT_LAUNCH_FAILURE = 126
MAX_OUTPUT_TAIL_BYTES = 64 * 1024
MAX_REDACTION_OVERLAP_BYTES = 64 * 1024
POLL_INTERVAL_SECONDS = 0.05
DEFAULT_TERM_GRACE_SECONDS = 2.0
DEFAULT_KILL_WAIT_SECONDS = 2.0
MAX_PHASE_TIMEOUT_SECONDS = 3600.0
MAX_HEARTBEAT_SECONDS = 600.0
MAX_CLEANUP_WAIT_SECONDS = 60.0
RAW_CAPTURE_DISPOSITION = (
    "anonymous ephemeral raw output; supervisor unlinks before command launch "
    "and must never upload"
)
MAX_NOTARY_EVIDENCE_BYTES = 1024 * 1024

_SENSITIVE_ENV_NAME = re.compile(
    r"(?:^|_)(?:AUTH|BEARER|COOKIE|CREDENTIAL|PASSCODE|PASSPHRASE|PASSWORD|"
    r"PRIVATE_KEY|SECRET|TOKEN)(?:_|$)",
    re.IGNORECASE,
)
_PRIVATE_KEY_BLOCK = re.compile(
    r"-----BEGIN [^-\r\n]*PRIVATE KEY-----.*?-----END [^-\r\n]*PRIVATE KEY-----",
    re.DOTALL,
)
_GITHUB_TOKEN = re.compile(r"(?:github_pat_|gh[oprsu]_)[A-Za-z0-9_]{16,}")
_JWT = re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b")
_AUTHORIZATION_HEADER = re.compile(
    r"(?i)\b(authorization\s*:\s*(?:bearer|basic)\s+)([^\s,;]+)"
)
_CREDENTIAL_ASSIGNMENT = re.compile(
    r"(?i)\b(authorization|bearer|cookie|credential|password|passphrase|secret|"
    r"token|api[_ -]?key)(\s*[:=]\s*)([^\s,;]+)"
)
_OPAQUE_TOKEN = re.compile(r"(?<![A-Za-z0-9_+/=-])[A-Za-z0-9_+/=-]{40,}")


@dataclasses.dataclass(frozen=True)
class CleanupResult:
    term_sent: bool
    kill_sent: bool
    child_reaped: bool
    group_gone: bool
    errors: tuple[str, ...]

    @property
    def succeeded(self) -> bool:
        return self.child_reaped and self.group_gone and not self.errors


@dataclasses.dataclass(frozen=True)
class OutputTail:
    """Marker for a pre-sanitized tail that must bypass generic field truncation."""

    text: str


class Redactor:
    """Redacts known environment secrets and common credential encodings."""

    def __init__(self, literal_values: Iterable[str]) -> None:
        self._literal_values = tuple(
            sorted({value for value in literal_values if value}, key=len, reverse=True)
        )

    @classmethod
    def from_environment(cls, explicit_names: Iterable[str]) -> "Redactor":
        explicit = set(explicit_names)
        values: set[str] = set()
        for name, value in os.environ.items():
            if name in explicit:
                if value:
                    values.add(value)
            elif _SENSITIVE_ENV_NAME.search(name) and len(value) >= 8:
                values.add(value)
        return cls(values)

    def redact(self, value: str) -> str:
        redacted = value
        for secret in self._literal_values:
            redacted = redacted.replace(secret, "[REDACTED]")
        redacted = _PRIVATE_KEY_BLOCK.sub("[REDACTED PRIVATE KEY]", redacted)
        redacted = _GITHUB_TOKEN.sub("[REDACTED]", redacted)
        redacted = _JWT.sub("[REDACTED JWT]", redacted)
        redacted = _AUTHORIZATION_HEADER.sub(
            lambda match: f"{match.group(1)}[REDACTED]", redacted
        )
        redacted = _CREDENTIAL_ASSIGNMENT.sub(
            lambda match: f"{match.group(1)}{match.group(2)}[REDACTED]",
            redacted,
        )
        return redacted

    @property
    def maximum_literal_bytes(self) -> int:
        return max(
            (len(value.encode("utf-8")) for value in self._literal_values),
            default=0,
        )


def utc_timestamp() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds").replace(
        "+00:00", "Z"
    )


def sanitize_text(
    value: str,
    redactor: Redactor,
    *,
    limit: int = 2048,
    preserve_newlines: bool = False,
) -> str:
    value = redactor.redact(value)
    sanitized: list[str] = []
    for character in value:
        if character == "\n" and preserve_newlines:
            sanitized.append(character)
        elif character == "\t" and preserve_newlines:
            sanitized.append(character)
        elif ord(character) < 32 or ord(character) == 127:
            sanitized.append("?")
        else:
            sanitized.append(character)
        if len(sanitized) >= limit:
            sanitized.append("…")
            break
    return "".join(sanitized)


def sanitize_value(value: Any, redactor: Redactor) -> Any:
    if isinstance(value, OutputTail):
        return value.text
    if isinstance(value, str):
        return sanitize_text(value, redactor)
    if isinstance(value, dict):
        return {
            sanitize_text(str(key), redactor, limit=128): sanitize_value(item, redactor)
            for key, item in value.items()
        }
    if isinstance(value, (list, tuple)):
        return [sanitize_value(item, redactor) for item in value]
    return value


class EventReporter:
    def __init__(
        self,
        *,
        phase: str,
        command_name: str,
        metadata: dict[str, Any],
        redactor: Redactor,
        stream: TextIO = sys.stderr,
    ) -> None:
        self.phase = phase
        self.command_name = command_name
        self.metadata = metadata
        self.redactor = redactor
        self.stream = stream

    def emit(self, event: str, *, elapsed_seconds: float, **fields: Any) -> None:
        payload: dict[str, Any] = {
            "timestamp": utc_timestamp(),
            "event": event,
            "phase": self.phase,
            "command": self.command_name,
            "elapsed_seconds": round(max(0.0, elapsed_seconds), 3),
            **self.metadata,
            **fields,
        }
        encoded = json.dumps(
            sanitize_value(payload, self.redactor),
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )
        print(encoded, file=self.stream, flush=True)


def remove_owned_capture_path(path: Path, owned_stat: os.stat_result) -> None:
    """Unlink only the regular path that still names the descriptor we created."""

    current_stat = os.lstat(path)
    if not stat.S_ISREG(current_stat.st_mode):
        raise ValueError(f"capture path ceased to be a regular file: {path}")
    if (current_stat.st_dev, current_stat.st_ino) != (
        owned_stat.st_dev,
        owned_stat.st_ino,
    ):
        raise ValueError(f"capture path identity changed before unlink: {path}")
    os.unlink(path)


def secure_capture_file(requested_path: str) -> tuple[BinaryIO, Path]:
    """Create mode-0600 capture storage and immediately make it anonymous."""

    path = Path(requested_path)
    flags = (
        os.O_RDWR
        | os.O_CREAT
        | os.O_EXCL
        | os.O_NONBLOCK
        | os.O_NOFOLLOW
        | getattr(os, "O_CLOEXEC", 0)
    )
    descriptor = os.open(path, flags, 0o600)
    try:
        file_stat = os.fstat(descriptor)
        if not stat.S_ISREG(file_stat.st_mode):
            raise ValueError(f"capture path is not a regular file: {path}")
        os.fchmod(descriptor, 0o600)
        proven_stat = os.fstat(descriptor)
        if stat.S_IMODE(proven_stat.st_mode) != 0o600:
            raise ValueError(f"capture path is not mode 0600: {path}")
        remove_owned_capture_path(path, proven_stat)
        return os.fdopen(descriptor, "w+b", buffering=0), path
    except BaseException:
        try:
            created_stat = os.fstat(descriptor)
            remove_owned_capture_path(path, created_stat)
        except (FileNotFoundError, OSError, ValueError):
            pass
        os.close(descriptor)
        raise


def process_group_is_live(process_group: int) -> bool:
    if process_group <= 0 or process_group == os.getpgrp():
        return False
    try:
        os.killpg(process_group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError as error:
        if error.errno == errno.ESRCH:
            return False
        return True
    return True


def signal_owned_group(process_group: int, sent_signal: signal.Signals) -> str | None:
    if process_group <= 0 or process_group == os.getpgrp():
        return "refused to signal the supervisor process group"
    try:
        os.killpg(process_group, sent_signal)
    except ProcessLookupError:
        return None
    except OSError as error:
        if error.errno == errno.ESRCH:
            return None
        return f"{sent_signal.name}: {type(error).__name__}"
    return None


def wait_for_group_exit(
    process: subprocess.Popen[bytes], process_group: int, deadline: float
) -> bool:
    while process_group_is_live(process_group):
        process.poll()
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        time.sleep(min(POLL_INTERVAL_SECONDS, remaining))
    process.poll()
    return True


def cleanup_owned_group(
    process: subprocess.Popen[bytes],
    process_group: int,
    *,
    term_grace_seconds: float,
    kill_wait_seconds: float,
) -> CleanupResult:
    """TERM, then KILL, the one process group created by this supervisor."""

    errors: list[str] = []
    term_sent = False
    kill_sent = False

    if process_group_is_live(process_group):
        term_sent = True
        if error := signal_owned_group(process_group, signal.SIGTERM):
            errors.append(error)

    grace_deadline = time.monotonic() + term_grace_seconds
    group_gone = wait_for_group_exit(process, process_group, grace_deadline)

    if not group_gone:
        kill_sent = True
        if error := signal_owned_group(process_group, signal.SIGKILL):
            errors.append(error)
        kill_deadline = time.monotonic() + kill_wait_seconds
        group_gone = wait_for_group_exit(process, process_group, kill_deadline)
    else:
        kill_deadline = time.monotonic() + kill_wait_seconds

    child_reaped = process.poll() is not None
    if not child_reaped:
        remaining = max(0.0, kill_deadline - time.monotonic())
        try:
            process.wait(timeout=remaining)
            child_reaped = True
        except subprocess.TimeoutExpired:
            try:
                process.kill()
            except ProcessLookupError:
                pass
            remaining = max(0.0, kill_deadline - time.monotonic())
            try:
                process.wait(timeout=remaining)
                child_reaped = True
            except subprocess.TimeoutExpired:
                errors.append("direct child could not be reaped before cleanup deadline")

    group_gone = not process_group_is_live(process_group)
    if not group_gone:
        errors.append("owned process group remained after SIGKILL deadline")

    return CleanupResult(
        term_sent=term_sent,
        kill_sent=kill_sent,
        child_reaped=child_reaped,
        group_gone=group_gone,
        errors=tuple(errors),
    )


def empty_cleanup_result() -> CleanupResult:
    return CleanupResult(
        term_sent=False,
        kill_sent=False,
        child_reaped=True,
        group_gone=True,
        errors=(),
    )


def sanitize_output_tail(value: str, redactor: Redactor) -> str:
    def redact_opaque_token(match: re.Match[str]) -> str:
        token = match.group(0)
        if len(token) in (40, 64) and all(
            character in "0123456789abcdefABCDEF" for character in token
        ):
            return token
        return "[REDACTED]"

    redacted = _OPAQUE_TOKEN.sub(redact_opaque_token, redactor.redact(value))
    return "".join(
        character
        if character in ("\n", "\t") or (ord(character) >= 32 and ord(character) != 127)
        else "?"
        for character in redacted
    )


def utf8_bounded_suffix(value: str, byte_limit: int) -> str:
    encoded = value.encode("utf-8")
    if len(encoded) <= byte_limit:
        return value
    suffix = encoded[-byte_limit:]
    while suffix and suffix[0] & 0xC0 == 0x80:
        suffix = suffix[1:]
    return suffix.decode("utf-8", errors="strict")


def read_output_tail(capture: BinaryIO, byte_limit: int, redactor: Redactor) -> str:
    # Read enough overlap to avoid starting in the middle of a known literal
    # secret and consequently exposing only its unmatched suffix.
    overlap = min(
        MAX_REDACTION_OVERLAP_BYTES,
        redactor.maximum_literal_bytes + 256,
    )
    capture.flush()
    capture.seek(0, os.SEEK_END)
    size = capture.tell()
    capture.seek(max(0, size - byte_limit - overlap), os.SEEK_SET)
    data = capture.read(byte_limit + overlap)
    decoded = data.decode("utf-8", errors="replace")
    sanitized = sanitize_output_tail(decoded, redactor)
    return utf8_bounded_suffix(sanitized, byte_limit)


def read_notarytool_evidence(capture: BinaryIO) -> tuple[str, str]:
    """Read only the public UUID/status proof from successful notarytool JSON."""

    capture.flush()
    capture.seek(0, os.SEEK_END)
    size = capture.tell()
    if size > MAX_NOTARY_EVIDENCE_BYTES:
        raise ValueError("notarytool output exceeds the 1 MiB evidence bound")
    capture.seek(0, os.SEEK_SET)
    try:
        text = capture.read().decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise ValueError("notarytool output is not UTF-8 JSON") from error
    start = text.find("{")
    end = text.rfind("}")
    if start < 0 or end < start:
        raise ValueError("notarytool output does not contain a JSON object")
    try:
        result = json.loads(text[start : end + 1])
    except json.JSONDecodeError as error:
        raise ValueError("notarytool output contains malformed JSON") from error
    if not isinstance(result, dict):
        raise ValueError("notarytool output must be a JSON object")
    submission_id = result.get("id")
    status_value = result.get("status")
    if not isinstance(submission_id, str):
        raise ValueError("notarytool output is missing its submission ID")
    try:
        normalized_id = str(uuid.UUID(submission_id))
    except ValueError as error:
        raise ValueError("notarytool output has a malformed submission ID") from error
    if status_value != "Accepted":
        raise ValueError("notarytool output did not report Accepted status")
    return normalized_id, "Accepted"


def output_tail_fields(
    *,
    capture: BinaryIO | None,
    include_output_tail: bool,
    output_tail_bytes: int,
    redactor: Redactor,
    unavailable_reason: str | None = None,
) -> dict[str, Any]:
    if not include_output_tail:
        return {"output_tail_included": False}
    if capture is None:
        fields: dict[str, Any] = {
            "output_tail_included": True,
            "output_tail_limit_bytes": output_tail_bytes,
            "output_tail_utf8_bytes": 0,
            "output_tail": OutputTail(""),
        }
        if unavailable_reason is not None:
            fields["output_tail_error"] = unavailable_reason
        return fields
    try:
        tail = read_output_tail(capture, output_tail_bytes, redactor)
        error_name = None
    except OSError as error:
        tail = ""
        error_name = type(error).__name__
    fields = {
        "output_tail_included": True,
        "output_tail_limit_bytes": output_tail_bytes,
        "output_tail_utf8_bytes": len(tail.encode("utf-8")),
        "output_tail": OutputTail(tail),
    }
    if error_name is not None:
        fields["output_tail_error"] = error_name
    return fields


def cleanup_fields(result: CleanupResult) -> dict[str, Any]:
    return {
        "cleanup_succeeded": result.succeeded,
        "term_sent": result.term_sent,
        "kill_sent": result.kill_sent,
        "child_reaped": result.child_reaped,
        "process_group_gone": result.group_gone,
        "cleanup_errors": list(result.errors),
    }


def normalized_child_exit_code(return_code: int) -> int:
    if return_code < 0:
        return min(255, 128 + abs(return_code))
    if return_code == 0:
        return 0
    return return_code if return_code <= 255 else 1


class CancellationRequest:
    def __init__(self) -> None:
        self.signal_number: int | None = None

    def request(self, signal_number: int) -> None:
        if self.signal_number is None:
            self.signal_number = signal_number


def install_cancellation_handlers(
    cancellation: CancellationRequest,
) -> dict[signal.Signals, Any]:
    previous: dict[signal.Signals, Any] = {}

    def handle(signal_number: int, _frame: Any) -> None:
        cancellation.request(signal_number)

    for handled_signal in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        previous[handled_signal] = signal.getsignal(handled_signal)
        signal.signal(handled_signal, handle)
    return previous


def restore_signal_handlers(previous: dict[signal.Signals, Any]) -> None:
    for handled_signal, handler in previous.items():
        signal.signal(handled_signal, handler)


def command_basename(command: list[str]) -> str:
    stripped = command[0].rstrip(os.sep)
    return os.path.basename(stripped) or stripped


def terminal_exit_code_for_signal(signal_number: int) -> int:
    return min(255, 128 + signal_number)


def run_supervised(args: argparse.Namespace) -> int:
    # Programmatic callers use this function directly rather than argparse, so
    # enforce the same finite upper bounds at the actual process boundary.
    args.timeout_seconds = phase_timeout_seconds(str(args.timeout_seconds))
    args.heartbeat_seconds = heartbeat_seconds(str(args.heartbeat_seconds))
    args.term_grace_seconds = cleanup_grace_seconds(str(args.term_grace_seconds))
    args.kill_wait_seconds = cleanup_wait_seconds(str(args.kill_wait_seconds))
    command = list(args.command)
    if command and command[0] == "--":
        command.pop(0)
    if not command:
        raise ValueError("a command is required after --")

    # Own the wall-clock deadline and cancellation signals before any setup that
    # touches the filesystem or launches a subprocess.
    started = time.monotonic()
    deadline = started + args.timeout_seconds
    next_heartbeat = started + args.heartbeat_seconds
    cancellation = CancellationRequest()
    previous_handlers = install_cancellation_handlers(cancellation)

    redactor = Redactor.from_environment(args.redact_env)
    capture_path = Path(args.capture_file)
    metadata: dict[str, Any] = {
        "capture_path": str(capture_path),
        "capture_disposition": RAW_CAPTURE_DISPOSITION,
        "timeout_seconds": args.timeout_seconds,
        "app_path": args.app_path,
        "app_size_bytes": args.app_size_bytes,
        "payload_path": args.payload_path,
        "payload_size_bytes": args.payload_size_bytes,
    }
    if args.cwd is not None:
        metadata["working_directory"] = args.cwd
    reporter = EventReporter(
        phase=args.phase,
        command_name=command_basename(command),
        metadata=metadata,
        redactor=redactor,
    )

    capture: BinaryIO | None = None
    process: subprocess.Popen[bytes] | None = None

    try:
        reporter.emit(
            "phase_start",
            elapsed_seconds=time.monotonic() - started,
        )
        try:
            capture, capture_path = secure_capture_file(args.capture_file)
        except (OSError, ValueError) as error:
            reporter.emit(
                "failure",
                elapsed_seconds=time.monotonic() - started,
                failure_kind="capture_setup_failure",
                error_type=type(error).__name__,
                error_message=str(error),
                **output_tail_fields(
                    capture=None,
                    include_output_tail=True,
                    output_tail_bytes=args.output_tail_bytes,
                    redactor=redactor,
                    unavailable_reason="capture_not_created",
                ),
            )
            return EXIT_LAUNCH_FAILURE

        now = time.monotonic()
        if cancellation.signal_number is not None or now >= deadline:
            cleanup = empty_cleanup_result()
            tail_fields = output_tail_fields(
                capture=capture,
                include_output_tail=True,
                output_tail_bytes=args.output_tail_bytes,
                redactor=redactor,
            )
            capture.close()
            if cancellation.signal_number is not None:
                signal_number = cancellation.signal_number
                reporter.emit(
                    "cancellation",
                    elapsed_seconds=time.monotonic() - started,
                    cancellation_signal=signal.Signals(signal_number).name,
                    **cleanup_fields(cleanup),
                    **tail_fields,
                )
                return terminal_exit_code_for_signal(signal_number)
            reporter.emit(
                "timeout",
                elapsed_seconds=time.monotonic() - started,
                **cleanup_fields(cleanup),
                **tail_fields,
            )
            return EXIT_TIMEOUT

        try:
            process = subprocess.Popen(
                command,
                cwd=args.cwd,
                stdout=capture,
                stderr=subprocess.STDOUT,
                start_new_session=True,
                close_fds=True,
            )
        except OSError as error:
            tail_fields = output_tail_fields(
                capture=capture,
                include_output_tail=True,
                output_tail_bytes=args.output_tail_bytes,
                redactor=redactor,
            )
            capture.close()
            reporter.emit(
                "failure",
                elapsed_seconds=time.monotonic() - started,
                failure_kind="launch_failure",
                error_type=type(error).__name__,
                error_message=str(error),
                **tail_fields,
            )
            return 127 if isinstance(error, FileNotFoundError) else EXIT_LAUNCH_FAILURE

        process_group = process.pid
        reporter.emit(
            "launched",
            elapsed_seconds=time.monotonic() - started,
            child_pid=process.pid,
            process_group=process_group,
        )
        outcome = "completed"

        while True:
            return_code = process.poll()
            if return_code is not None:
                break
            if cancellation.signal_number is not None:
                outcome = "cancellation"
                break
            now = time.monotonic()
            if now >= deadline:
                outcome = "timeout"
                break
            if now >= next_heartbeat:
                reporter.emit(
                    "heartbeat",
                    elapsed_seconds=now - started,
                    remaining_seconds=round(max(0.0, deadline - now), 3),
                )
                while next_heartbeat <= now:
                    next_heartbeat += args.heartbeat_seconds
            sleep_for = min(
                POLL_INTERVAL_SECONDS,
                max(0.0, deadline - now),
                max(0.0, next_heartbeat - now),
            )
            time.sleep(sleep_for)

        if outcome == "completed":
            return_code = process.wait()
            if process_group_is_live(process_group):
                cleanup = cleanup_owned_group(
                    process,
                    process_group,
                    term_grace_seconds=args.term_grace_seconds,
                    kill_wait_seconds=args.kill_wait_seconds,
                )
                tail_fields = output_tail_fields(
                    capture=capture,
                    include_output_tail=True,
                    output_tail_bytes=args.output_tail_bytes,
                    redactor=redactor,
                )
                capture.close()
                reporter.emit(
                    "failure",
                    elapsed_seconds=time.monotonic() - started,
                    failure_kind=(
                        "process_group_leak"
                        if cleanup.succeeded
                        else "cleanup_failure"
                    ),
                    child_return_code=return_code,
                    **cleanup_fields(cleanup),
                    **tail_fields,
                )
                return EXIT_CLEANUP_FAILURE

            if return_code == 0:
                if args.notarytool_json_evidence:
                    try:
                        submission_id, notarization_status = read_notarytool_evidence(
                            capture
                        )
                    except (OSError, ValueError) as error:
                        capture.close()
                        reporter.emit(
                            "failure",
                            elapsed_seconds=time.monotonic() - started,
                            failure_kind="notary_evidence_failure",
                            error_type=type(error).__name__,
                            error_message=str(error),
                            output_tail_included=False,
                        )
                        return EXIT_LAUNCH_FAILURE
                    reporter.emit(
                        "notarization_evidence",
                        elapsed_seconds=time.monotonic() - started,
                        submission_id=submission_id,
                        status=notarization_status,
                    )
                tail_fields = output_tail_fields(
                    capture=capture,
                    include_output_tail=args.emit_output_tail,
                    output_tail_bytes=args.output_tail_bytes,
                    redactor=redactor,
                )
                capture.close()
                reporter.emit(
                    "completion",
                    elapsed_seconds=time.monotonic() - started,
                    child_return_code=return_code,
                    **tail_fields,
                )
                return 0
            tail_fields = output_tail_fields(
                capture=capture,
                include_output_tail=True,
                output_tail_bytes=args.output_tail_bytes,
                redactor=redactor,
            )
            capture.close()
            reporter.emit(
                "failure",
                elapsed_seconds=time.monotonic() - started,
                failure_kind="command_failure",
                child_return_code=return_code,
                **tail_fields,
            )
            return normalized_child_exit_code(return_code)

        cleanup = cleanup_owned_group(
            process,
            process_group,
            term_grace_seconds=args.term_grace_seconds,
            kill_wait_seconds=args.kill_wait_seconds,
        )
        tail_fields = output_tail_fields(
            capture=capture,
            include_output_tail=True,
            output_tail_bytes=args.output_tail_bytes,
            redactor=redactor,
        )
        capture.close()
        if outcome == "timeout":
            reporter.emit(
                "timeout",
                elapsed_seconds=time.monotonic() - started,
                **cleanup_fields(cleanup),
                **tail_fields,
            )
            desired_exit_code = EXIT_TIMEOUT
        else:
            signal_number = cancellation.signal_number or int(signal.SIGTERM)
            reporter.emit(
                "cancellation",
                elapsed_seconds=time.monotonic() - started,
                cancellation_signal=signal.Signals(signal_number).name,
                **cleanup_fields(cleanup),
                **tail_fields,
            )
            desired_exit_code = terminal_exit_code_for_signal(signal_number)

        if not cleanup.succeeded:
            reporter.emit(
                "failure",
                elapsed_seconds=time.monotonic() - started,
                failure_kind="cleanup_failure",
                triggered_by=outcome,
                **cleanup_fields(cleanup),
                **tail_fields,
            )
            return EXIT_CLEANUP_FAILURE
        return desired_exit_code
    except BaseException as error:
        cleanup: CleanupResult | None = None
        if process is not None:
            cleanup = cleanup_owned_group(
                process,
                process.pid,
                term_grace_seconds=args.term_grace_seconds,
                kill_wait_seconds=args.kill_wait_seconds,
            )
        tail_fields = output_tail_fields(
            capture=capture if capture is not None and not capture.closed else None,
            include_output_tail=True,
            output_tail_bytes=args.output_tail_bytes,
            redactor=redactor,
            unavailable_reason="capture_unavailable",
        )
        if capture is not None and not capture.closed:
            capture.close()
        reporter.emit(
            "failure",
            elapsed_seconds=time.monotonic() - started,
            failure_kind=(
                "cleanup_failure"
                if cleanup is not None and not cleanup.succeeded
                else "supervisor_failure"
            ),
            error_type=type(error).__name__,
            error_message=str(error),
            **(cleanup_fields(cleanup) if cleanup is not None else {}),
            **tail_fields,
        )
        return EXIT_CLEANUP_FAILURE if cleanup is not None else EXIT_LAUNCH_FAILURE
    finally:
        if capture is not None and not capture.closed:
            capture.close()
        restore_signal_handlers(previous_handlers)


def finite_positive_float(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a number") from error
    if not math.isfinite(parsed) or parsed <= 0:
        raise argparse.ArgumentTypeError("must be a finite number greater than zero")
    return parsed


def bounded_positive_seconds(value: str, *, maximum: float, label: str) -> float:
    parsed = finite_positive_float(value)
    if parsed > maximum:
        raise argparse.ArgumentTypeError(f"{label} must not exceed {maximum:g} seconds")
    return parsed


def phase_timeout_seconds(value: str) -> float:
    return bounded_positive_seconds(
        value, maximum=MAX_PHASE_TIMEOUT_SECONDS, label="phase timeout"
    )


def heartbeat_seconds(value: str) -> float:
    return bounded_positive_seconds(
        value, maximum=MAX_HEARTBEAT_SECONDS, label="heartbeat interval"
    )


def cleanup_wait_seconds(value: str) -> float:
    return bounded_positive_seconds(
        value, maximum=MAX_CLEANUP_WAIT_SECONDS, label="cleanup wait"
    )


def cleanup_grace_seconds(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a number") from error
    if not math.isfinite(parsed) or parsed < 0:
        raise argparse.ArgumentTypeError("must be a finite number that is not negative")
    if parsed > MAX_CLEANUP_WAIT_SECONDS:
        raise argparse.ArgumentTypeError(
            f"cleanup grace must not exceed {MAX_CLEANUP_WAIT_SECONDS:g} seconds"
        )
    return parsed


def nonnegative_int(value: str) -> int:
    parsed = int(value)
    if parsed < 0:
        raise argparse.ArgumentTypeError("must not be negative")
    return parsed


def output_tail_byte_count(value: str) -> int:
    parsed = finite_positive_float(value)
    if not float(parsed).is_integer():
        raise argparse.ArgumentTypeError("must be an integer")
    integer = int(parsed)
    if integer > MAX_OUTPUT_TAIL_BYTES:
        raise argparse.ArgumentTypeError(
            f"must not exceed {MAX_OUTPUT_TAIL_BYTES} bytes"
        )
    return integer


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run one release phase with a bounded process-group watchdog.",
        epilog=(
            "Shell callers must use exec so workflow cancellation reaches the supervisor. "
            "The supervisor makes its raw mode-0600 capture anonymous before command "
            "launch and never uploads it because it may contain secrets."
        ),
    )
    parser.add_argument("--phase", required=True, help="Human-readable release phase label")
    parser.add_argument("--timeout-seconds", required=True, type=phase_timeout_seconds)
    parser.add_argument("--heartbeat-seconds", type=heartbeat_seconds, default=30.0)
    parser.add_argument(
        "--term-grace-seconds",
        type=cleanup_grace_seconds,
        default=DEFAULT_TERM_GRACE_SECONDS,
    )
    parser.add_argument(
        "--kill-wait-seconds",
        type=cleanup_wait_seconds,
        default=DEFAULT_KILL_WAIT_SECONDS,
    )
    parser.add_argument(
        "--capture-file",
        required=True,
        help="New ephemeral path; it must not already exist",
    )
    parser.add_argument("--cwd")
    parser.add_argument("--app-path", required=True)
    parser.add_argument("--app-size-bytes", required=True, type=nonnegative_int)
    parser.add_argument("--payload-path", required=True)
    parser.add_argument("--payload-size-bytes", required=True, type=nonnegative_int)
    parser.add_argument(
        "--redact-env",
        action="append",
        default=[],
        metavar="NAME",
        help="Also redact the value of this environment variable from emitted events",
    )
    parser.add_argument(
        "--emit-output-tail",
        action="store_true",
        help="Include a bounded, redacted tail on success; non-success tails are mandatory",
    )
    parser.add_argument(
        "--output-tail-bytes",
        type=output_tail_byte_count,
        default=8192,
    )
    parser.add_argument(
        "--notarytool-json-evidence",
        action="store_true",
        help=(
            "On command success, require Accepted notarytool JSON and emit only "
            "its normalized submission ID and status"
        ),
    )
    parser.add_argument("command", nargs=argparse.REMAINDER)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not args.command or args.command == ["--"]:
        parser.error("a command is required after --")
    if args.notarytool_json_evidence and args.emit_output_tail:
        parser.error(
            "--notarytool-json-evidence cannot be combined with --emit-output-tail"
        )
    return run_supervised(args)


if __name__ == "__main__":
    raise SystemExit(main())
