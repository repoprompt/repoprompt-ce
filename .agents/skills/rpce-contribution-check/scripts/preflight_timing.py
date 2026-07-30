#!/usr/bin/env python3
"""Timing state and privacy-safe receipt writing for preflight.sh pr-ready."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import tempfile
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

SCHEMA_VERSION = 1
RECEIPT_KIND = "rpce_pr_ready_timing"
PHASE_IDS = [
    "whitespace_checks",
    "staged_index_secret_scan",
    "repository_guardrails",
    "clean_worktree_check",
    "outgoing_range_resolution",
    "outgoing_range_secret_scan",
    "path_selection",
    "conductor_selftests",
    "ci_app_test_runner_selftests",
    "swift_lint",
    "root_tests",
    "provider_tests",
    "repoprompt_build",
    "mcp_build",
    "xcode_generator_tests",
    "xcode_workspace_validation",
]
LANE_IDS = PHASE_IDS[7:]
SHA_PATTERN = re.compile(r"^[0-9a-fA-F]{40,64}$")


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def monotonic_ns() -> int:
    return time.monotonic_ns()


def elapsed_seconds(start_ns: int, finish_ns: int) -> float:
    return round(max(0, finish_ns - start_ns) / 1_000_000_000, 6)


def write_json_temporary(path: Path, payload: dict[str, Any]) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        try:
            os.close(descriptor)
        except OSError:
            pass
        temporary_path.unlink(missing_ok=True)
        raise
    return temporary_path


def sync_parent_directory(path: Path) -> None:
    try:
        directory_descriptor = os.open(path.parent, os.O_RDONLY)
    except OSError:
        return
    try:
        try:
            os.fsync(directory_descriptor)
        except OSError:
            pass
    finally:
        os.close(directory_descriptor)


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    temporary_path = write_json_temporary(path, payload)
    try:
        os.replace(temporary_path, path)
    except BaseException:
        temporary_path.unlink(missing_ok=True)
        raise
    sync_parent_directory(path)


def publish_json_exclusive(path: Path, payload: dict[str, Any]) -> None:
    temporary_path = write_json_temporary(path, payload)
    try:
        os.link(temporary_path, path)
    except BaseException:
        temporary_path.unlink(missing_ok=True)
        raise
    temporary_path.unlink(missing_ok=True)
    sync_parent_directory(path)


def load_state(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        state = json.load(handle)
    if state.get("internal_version") != 1:
        raise ValueError("unsupported timing state version")
    return state


def save_state(path: Path, state: dict[str, Any]) -> None:
    atomic_write_json(path, state)


def phase_for(state: dict[str, Any], phase_id: str) -> dict[str, Any]:
    if phase_id not in PHASE_IDS:
        raise ValueError(f"unknown phase: {phase_id}")
    return state["phases"][PHASE_IDS.index(phase_id)]


def start_state(artifact_dir: Path, head_commit: Optional[str]) -> Path:
    if head_commit and not SHA_PATTERN.fullmatch(head_commit):
        head_commit = None
    run_id = uuid.uuid4().hex
    started_at = utc_now()
    temporary_root = Path(tempfile.mkdtemp(prefix="rpce-pr-ready-timing."))
    state_path = temporary_root / "state.json"
    state: dict[str, Any] = {
        "internal_version": 1,
        "artifact_dir": str(artifact_dir),
        "run_id": run_id,
        "filename_utc": started_at.replace("-", "").replace(":", "").split(".", 1)[0] + "Z",
        "started_at": started_at,
        "started_monotonic_ns": monotonic_ns(),
        "active_phase": None,
        "provenance": {
            "head_commit": head_commit,
            "outgoing_base_kind": None,
            "outgoing_commit_count": None,
        },
        "selection": {
            "changed_path_count": 0,
            "selected_lane_count": 0,
            "selected_lane_ids": [],
        },
        "phases": [
            {
                "id": phase_id,
                "status": "skipped",
                "started_at": None,
                "finished_at": None,
                "elapsed_seconds": 0.0,
            }
            for phase_id in PHASE_IDS
        ],
    }
    save_state(state_path, state)
    return state_path


def start_phase(state_path: Path, phase_id: str) -> None:
    state = load_state(state_path)
    if state["active_phase"] is not None:
        raise ValueError("a timing phase is already active")
    phase = phase_for(state, phase_id)
    if phase["status"] != "skipped":
        raise ValueError(f"phase already recorded: {phase_id}")
    phase.update(
        {
            "status": "running",
            "started_at": utc_now(),
            "started_monotonic_ns": monotonic_ns(),
        }
    )
    state["active_phase"] = phase_id
    save_state(state_path, state)


def pass_phase(state_path: Path, phase_id: str) -> None:
    state = load_state(state_path)
    if state["active_phase"] != phase_id:
        raise ValueError(f"phase is not active: {phase_id}")
    phase = phase_for(state, phase_id)
    finish_ns = monotonic_ns()
    phase.update(
        {
            "status": "passed",
            "finished_at": utc_now(),
            "elapsed_seconds": elapsed_seconds(phase.pop("started_monotonic_ns"), finish_ns),
        }
    )
    state["active_phase"] = None
    save_state(state_path, state)


def record_provenance(state_path: Path, base_kind: str, outgoing_count: int) -> None:
    if base_kind not in {"configured_upstream", "origin_main_fallback"}:
        raise ValueError("unsupported outgoing base kind")
    if outgoing_count < 0:
        raise ValueError("outgoing count cannot be negative")
    state = load_state(state_path)
    state["provenance"].update(
        {"outgoing_base_kind": base_kind, "outgoing_commit_count": outgoing_count}
    )
    save_state(state_path, state)


def record_selection(state_path: Path, changed_path_count: int, lane_ids: list[str]) -> None:
    if changed_path_count < 0:
        raise ValueError("changed path count cannot be negative")
    if len(lane_ids) != len(set(lane_ids)) or any(lane_id not in LANE_IDS for lane_id in lane_ids):
        raise ValueError("invalid selected lane ids")
    ordered_lane_ids = [lane_id for lane_id in LANE_IDS if lane_id in lane_ids]
    state = load_state(state_path)
    state["selection"] = {
        "changed_path_count": changed_path_count,
        "selected_lane_count": len(ordered_lane_ids),
        "selected_lane_ids": ordered_lane_ids,
    }
    save_state(state_path, state)


def cleanup_state(state_path: Path) -> None:
    parent = state_path.parent
    if parent.name.startswith("rpce-pr-ready-timing."):
        shutil.rmtree(parent, ignore_errors=True)
    else:
        state_path.unlink(missing_ok=True)


def finish_state(state_path: Path, exit_code: int) -> str:
    if not 0 <= exit_code <= 255:
        raise ValueError("exit code must be between 0 and 255")

    try:
        state = load_state(state_path)
        finish_ns = monotonic_ns()
        finished_at = utc_now()
        status = "passed" if exit_code == 0 else "failed"
        active_phase_id = state["active_phase"]
        if active_phase_id is not None:
            phase = phase_for(state, active_phase_id)
            phase.update(
                {
                    "status": "passed" if exit_code == 0 else "failed",
                    "finished_at": finished_at,
                    "elapsed_seconds": elapsed_seconds(
                        phase.pop("started_monotonic_ns"), finish_ns
                    ),
                }
            )

        receipt = {
            "schema_version": SCHEMA_VERSION,
            "kind": RECEIPT_KIND,
            "run_id": state["run_id"],
            "started_at": state["started_at"],
            "finished_at": finished_at,
            "elapsed_seconds": elapsed_seconds(state["started_monotonic_ns"], finish_ns),
            "status": status,
            "exit_code": exit_code,
            "signal": None,
            "mode": "pr-ready",
            "provenance": state["provenance"],
            "selection": state["selection"],
            "phases": [
                {
                    "id": phase["id"],
                    "status": phase["status"],
                    "started_at": phase["started_at"],
                    "finished_at": phase["finished_at"],
                    "elapsed_seconds": phase["elapsed_seconds"],
                }
                for phase in state["phases"]
            ],
        }
        filename = f"{state['filename_utc']}-{state['run_id']}.json"
        publish_json_exclusive(Path(state["artifact_dir"]) / filename, receipt)
        return filename
    finally:
        cleanup_state(state_path)


def discard_state(state_path: Path) -> None:
    cleanup_state(state_path)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    start = subparsers.add_parser("start")
    start.add_argument("--artifact-dir", type=Path, required=True)
    start.add_argument("--head-commit")

    phase_start = subparsers.add_parser("phase-start")
    phase_start.add_argument("--state", type=Path, required=True)
    phase_start.add_argument("--phase", choices=PHASE_IDS, required=True)

    phase_pass = subparsers.add_parser("phase-pass")
    phase_pass.add_argument("--state", type=Path, required=True)
    phase_pass.add_argument("--phase", choices=PHASE_IDS, required=True)

    provenance = subparsers.add_parser("provenance")
    provenance.add_argument("--state", type=Path, required=True)
    provenance.add_argument(
        "--base-kind", choices=["configured_upstream", "origin_main_fallback"], required=True
    )
    provenance.add_argument("--outgoing-count", type=int, required=True)

    selection = subparsers.add_parser("selection")
    selection.add_argument("--state", type=Path, required=True)
    selection.add_argument("--changed-path-count", type=int, required=True)
    selection.add_argument("--lane-id", action="append", default=[], choices=LANE_IDS)

    finish = subparsers.add_parser("finish")
    finish.add_argument("--state", type=Path, required=True)
    finish.add_argument("--exit-code", type=int, required=True)

    discard = subparsers.add_parser("discard")
    discard.add_argument("--state", type=Path, required=True)

    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.command == "start":
        print(start_state(args.artifact_dir, args.head_commit))
    elif args.command == "phase-start":
        start_phase(args.state, args.phase)
    elif args.command == "phase-pass":
        pass_phase(args.state, args.phase)
    elif args.command == "provenance":
        record_provenance(args.state, args.base_kind, args.outgoing_count)
    elif args.command == "selection":
        record_selection(args.state, args.changed_path_count, args.lane_id)
    elif args.command == "finish":
        print(finish_state(args.state, args.exit_code))
    elif args.command == "discard":
        discard_state(args.state)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
