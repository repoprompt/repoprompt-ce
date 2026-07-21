#!/usr/bin/env python3
"""Local-first structured build/test failure diagnostics for conductor.

This module is intentionally independent from the daemon: it defines a small,
versioned failure record, a bounded on-disk store, conservative classification,
and a read-only query surface. It never copies raw log text, source content,
prompts, transcripts, credentials, or environment dumps into aggregate records.
"""

from __future__ import annotations

import contextlib
import dataclasses
import json
import os
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple


CURRENT_SCHEMA_VERSION = 1
SCHEMA_LINEAGE = "repoprompt-ce.failure-record"
LEGACY_UNLINEAGED_SCHEMA_VERSION_CEILING = 0

# Bounded by the same floor as terminal job retention in conductor.py.
DEFAULT_FAILURE_RECORD_RETENTION_SECONDS = 24 * 60 * 60
DEFAULT_MAX_FAILURE_RECORDS = 200

# Environment keys treated as toolchain-known metadata. The daemon already
# snapshots a filtered env list, so this is a further narrow selection.
TOOLCHAIN_KNOWN_ENV_KEYS = {
    "CC",
    "CXX",
    "DEVELOPER_DIR",
    "SDKROOT",
    "SWIFT_EXEC",
    "TOOLCHAINS",
}

FAILURE_CLASSES = {
    "none",
    "timeout",
    "sourceMutatedBuild",
    "compilerFailure",
    "testFailure",
    "processCleanupFailure",
    "heavyLaneWait",
    "infrastructureOrRPCFailure",
    "cancellation",
    "unknown",
}

# Operation args that are unbounded, user-supplied strings or paths. These are
# filtered out of aggregate failure records so the record never carries a raw
# prompt, log contents, or a filesystem path.
REDACTED_RECORD_ARG_KEYS = {"message", "logFile"}

EXIT_CLASSES = {
    "completed",
    "timeout",
    "canceled",
    "killed",
    "infrastructure",
    "nonZero",
    "unknown",
}

AGGREGATE_JSON_PRIVACY_NOTE = (
    "aggregate-only; excludes raw logs, source content, prompts, transcripts, "
    "credentials, environment dumps, and unbounded operation args"
)


class FailureDiagnosticsError(Exception):
    """Error raised by failure diagnostics internals."""


@dataclasses.dataclass
class FailureRecord:
    """Versioned local failure record for a terminal conductor job.

    The record is intentionally small and referential: it points to the local
    job log and a persisted output summary, but it does not contain raw log
    text or source content.
    """

    schema_version: int = CURRENT_SCHEMA_VERSION
    schema_lineage: str = SCHEMA_LINEAGE
    recorded_at: Optional[float] = None
    ticket: str = ""
    request_key: Optional[str] = None
    fingerprint: Optional[str] = None
    operation: str = ""
    operation_label: str = ""
    args: Dict[str, Any] = dataclasses.field(default_factory=dict)
    lanes: List[str] = dataclasses.field(default_factory=list)
    created_at: Optional[float] = None
    started_at: Optional[float] = None
    finished_at: Optional[float] = None
    queued_at: Optional[float] = None
    process_started_at: Optional[float] = None
    process_finished_at: Optional[float] = None
    queue_wait_seconds: Optional[float] = None
    execution_seconds: Optional[float] = None
    terminal_state: str = ""
    exit_code: Optional[int] = None
    exit_class: str = ""
    failure_class: str = ""
    failure_class_reason: str = ""
    timed_out: bool = False
    cancel_requested: bool = False
    measurement_invalid: bool = False
    superseded_by_ticket: Optional[str] = None
    superseded_by_operation: Optional[str] = None
    global_heavy_slot_wait_seconds: Optional[float] = None
    global_heavy_slot_path: Optional[str] = None
    global_heavy_slot_holder: Optional[str] = None
    toolchain_known_metadata: Dict[str, Optional[str]] = dataclasses.field(default_factory=dict)
    resource_summary: Dict[str, Any] = dataclasses.field(default_factory=dict)
    local_log_path: Optional[str] = None
    diagnostic_paths: List[str] = dataclasses.field(default_factory=list)

    @classmethod
    def from_job(
        cls,
        job: Any,
        output_summary: Optional[Dict[str, Any]],
        jobs_dir: Optional[Path] = None,
    ) -> FailureRecord:
        """Build a failure record from a conductor Job object and its summary."""
        state = getattr(job, "state", "")
        exit_code = getattr(job, "exit_code", None)
        timed_out = bool(getattr(job, "timed_out", False))
        measurement_invalid = bool(getattr(job, "measurement_invalid", False))
        error = getattr(job, "error", None) or ""
        operation = getattr(job, "operation", "")
        process_started_at = getattr(job, "process_started_at", None)
        global_heavy_slot_wait_seconds = getattr(job, "global_heavy_slot_wait_seconds", None)

        exit_class = classify_exit(
            state=state,
            exit_code=exit_code,
            timed_out=timed_out,
            measurement_invalid=measurement_invalid,
        )
        failure_class, failure_class_reason = classify_failure(
            state=state,
            exit_code=exit_code,
            timed_out=timed_out,
            measurement_invalid=measurement_invalid,
            error=error,
            operation=operation,
            output_summary=output_summary,
            global_heavy_slot_wait_seconds=global_heavy_slot_wait_seconds,
            process_started_at=process_started_at,
            superseded_by_operation=getattr(job, "superseded_by_operation", None),
        )

        resource_summary = build_resource_summary(
            ticket=getattr(job, "ticket", ""),
            output_summary=output_summary,
            jobs_dir=jobs_dir,
        )

        env = getattr(job, "env", {}) or {}
        toolchain_known_metadata = {
            key: env.get(key)
            for key in TOOLCHAIN_KNOWN_ENV_KEYS
            if key in env and env.get(key) is not None
        }

        return cls(
            schema_version=CURRENT_SCHEMA_VERSION,
            schema_lineage=SCHEMA_LINEAGE,
            recorded_at=time.time(),
            ticket=getattr(job, "ticket", ""),
            request_key=getattr(job, "request_key", None),
            fingerprint=getattr(job, "fingerprint", None),
            operation=operation,
            operation_label=operation_display_name(operation, getattr(job, "args", {})),
            args=filter_args_for_record(getattr(job, "args", {}) or {}),
            lanes=list(getattr(job, "lanes", []) or []),
            created_at=getattr(job, "created_at", None),
            started_at=getattr(job, "started_at", None),
            finished_at=getattr(job, "finished_at", None),
            queued_at=getattr(job, "created_at", None),
            process_started_at=process_started_at,
            process_finished_at=getattr(job, "process_finished_at", None),
            queue_wait_seconds=compute_queue_wait_seconds(job),
            execution_seconds=compute_execution_seconds(job),
            terminal_state=state,
            exit_code=exit_code,
            exit_class=exit_class,
            failure_class=failure_class,
            failure_class_reason=failure_class_reason,
            timed_out=timed_out,
            cancel_requested=bool(getattr(job, "cancel_requested", False)),
            measurement_invalid=measurement_invalid,
            superseded_by_ticket=getattr(job, "superseded_by_ticket", None),
            superseded_by_operation=getattr(job, "superseded_by_operation", None),
            global_heavy_slot_wait_seconds=global_heavy_slot_wait_seconds,
            global_heavy_slot_path=getattr(job, "global_heavy_slot_path", None),
            global_heavy_slot_holder=getattr(job, "global_heavy_slot_holder", None),
            toolchain_known_metadata=toolchain_known_metadata,
            resource_summary=resource_summary,
            local_log_path=str(getattr(job, "log_path", None)) if getattr(job, "log_path", None) else None,
            diagnostic_paths=[str(p) for p in getattr(job, "diagnostic_paths", []) or []],
        )

    def to_dict(self) -> Dict[str, Any]:
        """Serialize to a JSON-ready dict with camelCase top-level keys."""
        data = dataclasses.asdict(self)
        return {
            _snake_to_camel(key): value
            for key, value in data.items()
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> FailureRecord:
        """Deserialize a failure record with schema identity checks.

        Unknown top-level fields are ignored. Records with a future schema
        version or a foreign lineage are rejected.
        """
        if not isinstance(data, dict):
            raise FailureDiagnosticsError("record must be a JSON object")

        schema_version = data.get("schemaVersion")
        schema_lineage = data.get("schemaLineage")

        if not isinstance(schema_version, int):
            raise FailureDiagnosticsError("missing schemaVersion")

        if schema_version > CURRENT_SCHEMA_VERSION:
            raise FailureDiagnosticsError(
                f"future schema version {schema_version} > {CURRENT_SCHEMA_VERSION}"
            )

        normalized_lineage = (schema_lineage or "").strip() if isinstance(schema_lineage, str) else ""
        if normalized_lineage == SCHEMA_LINEAGE:
            pass
        elif normalized_lineage:
            raise FailureDiagnosticsError(
                f"foreign schema lineage {schema_lineage!r}"
            )
        else:
            if schema_version > LEGACY_UNLINEAGED_SCHEMA_VERSION_CEILING:
                raise FailureDiagnosticsError(
                    f"unlineaged schema version {schema_version} is not recognized"
                )

        kwargs: Dict[str, Any] = {}
        for field in dataclasses.fields(cls):
            camel = _snake_to_camel(field.name)
            value = data.get(camel)
            if value is None:
                value = _field_default(field)
            kwargs[field.name] = value

        kwargs["args"] = filter_args_for_record(kwargs.get("args"))
        return cls(**kwargs)


def _field_default(field: dataclasses.Field) -> Any:
    """Return the declared default for a dataclass field, preferring static defaults over factories."""
    if field.default is not dataclasses.MISSING:
        return field.default
    if field.default_factory is not None:
        return field.default_factory()
    return None


def filter_args_for_record(args: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    """Return a copy of operation args with unbounded/redacted keys removed."""
    if not args:
        return {}
    return {key: value for key, value in args.items() if key not in REDACTED_RECORD_ARG_KEYS}


class FailureRecordStore:
    """Bounded on-disk store for versioned failure records and summary refs.

    The store is thread-safe and writes records with an atomic temp-file +
    os.replace so readers never see a partially-written file. Temporary files
    are cleaned up on failure and are never visible to the retention glob
    patterns, so an in-flight write cannot be deleted by a concurrent retention
    pass.
    """

    def __init__(
        self,
        jobs_dir: Path,
        max_age_seconds: float = DEFAULT_FAILURE_RECORD_RETENTION_SECONDS,
        max_records: int = DEFAULT_MAX_FAILURE_RECORDS,
        now: Callable[[], float] = time.time,
    ) -> None:
        self.jobs_dir = Path(jobs_dir)
        self.max_age_seconds = max_age_seconds
        self.max_records = max_records
        self.now = now
        self._lock = threading.RLock()
        self._written_tickets: set[str] = set()

    def _record_path(self, ticket: str) -> Path:
        return self.jobs_dir / f"{ticket}.failure.json"

    def _summary_path(self, ticket: str) -> Path:
        return self.jobs_dir / f"{ticket}.summary.json"

    def _ticket_from_record_path(self, path: Path) -> str:
        marker = ".failure.json"
        if path.name.endswith(marker):
            return path.name[: -len(marker)]
        return path.stem

    def _ticket_from_summary_path(self, path: Path) -> str:
        marker = ".summary.json"
        if path.name.endswith(marker):
            return path.name[: -len(marker)]
        return path.stem

    def _write_text_atomic(self, path: Path, text: str) -> None:
        """Write text to a temp file in the same directory and atomically replace ``path``."""
        fd, tmp_path_str = tempfile.mkstemp(
            dir=str(self.jobs_dir),
            suffix=".tmp",
            prefix=".",
        )
        tmp_path = Path(tmp_path_str)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(text)
            # mkstemp creates with 0o600 on most systems; keep it explicit.
            os.chmod(tmp_path, 0o600)
            os.replace(tmp_path, str(path))
        except Exception:
            with contextlib.suppress(OSError):
                os.close(fd)
            with contextlib.suppress(OSError):
                tmp_path.unlink()
            raise

    def write(
        self,
        record: FailureRecord,
        summary: Optional[Dict[str, Any]] = None,
    ) -> Path:
        """Write a failure record and, if provided, its summary resource.

        Both the record and its summary are written to temp files and then
        atomically renamed so readers never see a partially-written file.
        If the record write fails after a summary was already replaced, the
        summary is rolled back so the store is never left pointing to a record
        that does not exist.
        """
        with self._lock:
            self.jobs_dir.mkdir(mode=0o700, parents=True, exist_ok=True)

            ticket = record.ticket
            if ticket in self._written_tickets:
                return self._record_path(ticket)

            summary_path = self._summary_path(ticket)
            record.resource_summary = dict(record.resource_summary)
            summary_written = False

            if summary is not None:
                try:
                    self._write_text_atomic(
                        summary_path,
                        json.dumps(summary, indent=2, sort_keys=True),
                    )
                    record.resource_summary["summaryPath"] = str(summary_path)
                    summary_written = True
                except OSError:
                    # Do not let a summary write failure point the record at a
                    # summary file that was not persisted.
                    record.resource_summary.pop("summaryPath", None)
            else:
                record.resource_summary.pop("summaryPath", None)

            record_path = self._record_path(ticket)
            try:
                self._write_text_atomic(
                    record_path,
                    json.dumps(record.to_dict(), indent=2, sort_keys=True),
                )
            except OSError as exc:
                if summary_written:
                    # Roll back the summary so an orphan summary file does not
                    # reference a record that was not persisted.
                    with contextlib.suppress(OSError):
                        summary_path.unlink()
                    record.resource_summary.pop("summaryPath", None)
                raise FailureDiagnosticsError(f"could not write failure record: {exc}") from exc

            self._written_tickets.add(ticket)
            self.retention_pass()
            return record_path

    def load(self, path: Path) -> Optional[FailureRecord]:
        """Load a single failure record, returning None if it is incompatible."""
        with self._lock:
            try:
                raw = path.read_text(encoding="utf-8", errors="replace")
                data = json.loads(raw)
            except (OSError, json.JSONDecodeError):
                return None
            if not isinstance(data, dict):
                return None
            try:
                return FailureRecord.from_dict(data)
            except FailureDiagnosticsError:
                return None

    def load_all(self) -> List[FailureRecord]:
        """Load all compatible failure records in the store."""
        with self._lock:
            records: List[FailureRecord] = []
            for path in self._list_record_paths():
                record = self.load(path)
                if record is not None:
                    records.append(record)
            return records

    def query_recent(
        self,
        limit: int = 50,
        operation: Optional[str] = None,
        failure_class: Optional[str] = None,
        since_timestamp: Optional[float] = None,
        max_age_seconds: Optional[float] = None,
    ) -> List[FailureRecord]:
        """Return recent failure records, newest first, with optional filters."""
        with self._lock:
            now = self.now()
            if since_timestamp is not None:
                cutoff = since_timestamp
            else:
                cutoff = now - (max_age_seconds if max_age_seconds is not None else self.max_age_seconds)

            records = self.load_all()
            records = [r for r in records if (r.recorded_at or r.finished_at or 0) >= cutoff]

            if operation:
                records = [r for r in records if r.operation == operation]
            if failure_class:
                records = [r for r in records if r.failure_class == failure_class]

            records.sort(key=lambda r: (r.finished_at or r.recorded_at or 0), reverse=True)
            return records[:limit]

    def retention_pass(
        self,
        max_age_seconds: Optional[float] = None,
        max_records: Optional[int] = None,
    ) -> None:
        """Delete expired or excess failure records and orphaned summaries.

        Only files matching ``*.failure.json`` and ``*.summary.json`` are
        considered, so in-flight ``*.tmp`` files cannot be deleted.
        """
        with self._lock:
            max_age = max_age_seconds if max_age_seconds is not None else self.max_age_seconds
            max_count = max_records if max_records is not None else self.max_records
            now = self.now()
            cutoff = now - max_age

            record_paths = self._list_record_paths()
            records: List[Tuple[Path, FailureRecord, float]] = []
            for path in record_paths:
                record = self.load(path)
                if record is None:
                    # Unknown/foreign schema: fall back to file mtime for retention.
                    try:
                        mtime = path.stat().st_mtime
                    except OSError:
                        continue
                    if mtime < cutoff:
                        self._delete_record_and_summary(path)
                    continue

                timestamp = record.recorded_at or record.finished_at or 0
                if timestamp == 0:
                    try:
                        timestamp = path.stat().st_mtime
                    except OSError:
                        pass
                if timestamp < cutoff:
                    self._delete_record_and_summary(path)
                else:
                    records.append((path, record, timestamp))

            records.sort(key=lambda item: item[2], reverse=True)
            for path, _record, _timestamp in records[max_count:]:
                self._delete_record_and_summary(path)

            # Clean orphaned summary files.
            retained_tickets = {
                self._ticket_from_record_path(p) for p in self._list_record_paths()
            }
            for summary_path in self._list_summary_paths():
                if self._ticket_from_summary_path(summary_path) not in retained_tickets:
                    with contextlib.suppress(FileNotFoundError):
                        summary_path.unlink()

    def _list_record_paths(self) -> List[Path]:
        with contextlib.suppress(FileNotFoundError):
            return sorted(self.jobs_dir.glob("*.failure.json"))
        return []

    def _list_summary_paths(self) -> List[Path]:
        with contextlib.suppress(FileNotFoundError):
            return sorted(self.jobs_dir.glob("*.summary.json"))
        return []

    def _delete_record_and_summary(self, record_path: Path) -> None:
        ticket = self._ticket_from_record_path(record_path)
        with contextlib.suppress(FileNotFoundError):
            record_path.unlink()
        summary_path = self._summary_path(ticket)
        with contextlib.suppress(FileNotFoundError):
            summary_path.unlink()


def classify_exit(
    state: str,
    exit_code: Optional[int],
    timed_out: bool,
    measurement_invalid: bool,
) -> str:
    """Return a bounded exit class for a terminal job."""
    if state == "completed" or (exit_code == 0 and not timed_out and not measurement_invalid):
        return "completed"
    if timed_out or exit_code == 124:
        return "timeout"
    if state == "canceled" or exit_code == 130:
        return "canceled"
    if exit_code == 137:
        return "killed"
    if measurement_invalid or exit_code == 70:
        return "infrastructure"
    if exit_code is not None and exit_code != 0:
        return "nonZero"
    return "unknown"


def classify_failure(
    state: str,
    exit_code: Optional[int],
    timed_out: bool,
    measurement_invalid: bool,
    error: str,
    operation: str,
    output_summary: Optional[Dict[str, Any]],
    global_heavy_slot_wait_seconds: Optional[float],
    process_started_at: Optional[float],
    superseded_by_operation: Optional[str],
) -> Tuple[str, str]:
    """Return a bounded failure class and a short reason.

    Classification is conservative: if evidence is ambiguous, the record is
    marked ``unknown`` rather than guessed into a more specific bucket.
    """
    error = (error or "").strip()

    if state == "completed" and exit_code == 0:
        return "none", "completed successfully"

    if state == "canceled" or exit_code == 130:
        if superseded_by_operation:
            return "cancellation", f"canceled (superseded by {superseded_by_operation})"
        return "cancellation", "canceled"

    if timed_out or exit_code == 124:
        return "timeout", error or "timed out"

    lifecycle = (output_summary or {}).get("launchLifecycle") or {}
    if lifecycle.get("sourceChangedDuringBuild"):
        return "sourceMutatedBuild", "source files changed during the build"

    sections = {
        section.get("title")
        for section in (output_summary or {}).get("sections", [])
        if isinstance(section, dict)
    }
    if "Swift compiler errors" in sections:
        return "compilerFailure", "Swift compiler errors"
    if "Test failures" in sections:
        return "testFailure", "test failures"

    if error and (
        "did not exit after SIGKILL" in error
        or "remained alive after SIGKILL" in error
        or "canceled job descendants remained alive" in error
    ):
        return "processCleanupFailure", error

    if measurement_invalid or exit_code == 70 or "daemon runner error" in error:
        return "infrastructureOrRPCFailure", error or "infrastructure failure"

    if (
        global_heavy_slot_wait_seconds is not None
        and global_heavy_slot_wait_seconds >= 30.0
        and process_started_at is None
        and state != "completed"
    ):
        return (
            "heavyLaneWait",
            f"waited {global_heavy_slot_wait_seconds:.1f}s for a global heavy slot before process start",
        )

    if "Style findings" in sections:
        return "unknown", "style findings; no recognized failure class"

    return "unknown", "failure evidence not recognized by current classifier"


def build_resource_summary(
    ticket: str,
    output_summary: Optional[Dict[str, Any]],
    jobs_dir: Optional[Path] = None,
) -> Dict[str, Any]:
    """Build a bounded resource summary reference from an output summary."""
    summary_path: Optional[str] = None
    if jobs_dir is not None and ticket:
        summary_path = str(jobs_dir / f"{ticket}.summary.json")

    if not isinstance(output_summary, dict):
        return {"summaryPath": summary_path}

    sections = output_summary.get("sections") or []
    section_titles = [
        section["title"]
        for section in sections
        if isinstance(section, dict) and section.get("title")
    ]

    return {
        "summaryPath": summary_path,
        "headline": output_summary.get("headline"),
        "summarySectionTitles": section_titles,
        "errorCount": output_summary.get("errorCount"),
        "warningCount": output_summary.get("warningCount"),
        "logLineCount": output_summary.get("logLineCount"),
        "truncated": output_summary.get("truncated"),
        "launchLifecycle": output_summary.get("launchLifecycle"),
    }


def operation_display_name(operation: str, args: Dict[str, Any]) -> str:
    """Mirror of conductor.operation_display_name for the record label."""
    if operation == "app" and args.get("subcommand") in {"status", "stop", "launch-existing", "relaunch"}:
        return f"app {args['subcommand']}"
    return operation


def compute_queue_wait_seconds(job: Any) -> Optional[float]:
    created_at = getattr(job, "created_at", None)
    started_at = getattr(job, "started_at", None)
    if created_at is not None and started_at is not None:
        return max(0.0, started_at - created_at)
    return None


def compute_execution_seconds(job: Any) -> Optional[float]:
    process_started_at = getattr(job, "process_started_at", None)
    process_finished_at = getattr(job, "process_finished_at", None)
    if process_started_at is not None and process_finished_at is not None:
        return max(0.0, process_finished_at - process_started_at)
    return None


def _snake_to_camel(name: str) -> str:
    parts = name.split("_")
    return parts[0] + "".join(part.capitalize() for part in parts[1:])


def format_recent_failures(records: List[FailureRecord], json_mode: bool = False) -> str:
    """Render a list of recent failure records for human or JSON output."""
    if json_mode:
        return json.dumps(
            {
                "schemaVersion": CURRENT_SCHEMA_VERSION,
                "schemaLineage": SCHEMA_LINEAGE,
                "privacy": AGGREGATE_JSON_PRIVACY_NOTE,
                "count": len(records),
                "records": [r.to_dict() for r in records],
            },
            indent=2,
            sort_keys=True,
        )

    if not records:
        return "No recent failure records."

    lines = ["Recent failure records:", ""]
    lines.append(
        f"{'Ticket':<36} {'Operation':<20} {'State':<10} {'Exit':<6} {'Failure class':<26} {'Reason'}"
    )
    for record in records:
        operation = record.operation_label or record.operation
        if len(operation) > 20:
            operation = operation[:17] + "..."
        reason = record.failure_class_reason or ""
        if len(reason) > 60:
            reason = reason[:57] + "..."
        state = record.terminal_state or ""
        exit_code = str(record.exit_code) if record.exit_code is not None else ""
        lines.append(
            f"{record.ticket:<36} {operation:<20} {state:<10} {exit_code:<6} {record.failure_class:<26} {reason}"
        )
        if record.local_log_path:
            lines.append(f"  log: {record.local_log_path}")
        if record.resource_summary.get("summaryPath"):
            lines.append(f"  summary: {record.resource_summary['summaryPath']}")
    return "\n".join(lines)
