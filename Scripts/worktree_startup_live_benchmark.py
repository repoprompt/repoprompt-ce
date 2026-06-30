#!/usr/bin/env python3
"""Plan, run, and aggregate the RepoPrompt CE worktree-startup live diagnostic.

The live subcommands require an already-running RepoPrompt CE DEBUG app and
rpce-cli-debug. This script never builds, installs, launches, stops, or
relaunches the app. Run ``plan`` and ``aggregate`` without contacting the app.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import html
import json
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from typing import Any, Iterable


SCHEMA_VERSION = 1
DIAGNOSTIC_SCHEMA_VERSION = 6
PRIMARY_REVALIDATION_VERSION = 1
DEBUG_TOOL = "__repoprompt_debug_diagnostics"
WORKSPACE_PREFIXES = ("RPCE 8E Bench ", "RPCE Search Bench ")
DEFAULT_OUTPUT_ROOT = "/tmp/rpce-worktree-startup/v1"
BENCHMARK_GATE_KEY = "agent_mode.worktree_startup_benchmark_diagnostics_enabled"
OWNERSHIP_MARKER_NAME = ".rpce-worktree-startup-benchmark.json"
TERMINAL_STATES = {"completed", "failed", "cancelled", "canceled", "stopped", "expired"}
ROUTES = {
    "baseline": {"observe": False, "serve": False, "force_full": False, "expected": "fullCrawl"},
    "forced-full": {"observe": False, "serve": False, "force_full": True, "expected": "forcedFullCrawl"},
    "projected": {"observe": True, "serve": True, "force_full": False, "expected": "diffSeedServing"},
}
EXPECTED_ACTUAL_ROUTE_COUNTS = {
    "baseline": {"fullCrawl": 1},
    "forced-full": {"fullCrawl": 1},
    "projected": {"diffSeedServing": 1},
}


@dataclass(frozen=True)
class RouteObservationExpectation:
    phase: str
    route: str


POLICY_DIGEST_PROBE_ROUTE_EVENTS = (
    RouteObservationExpectation("seedWatcherAttached", "diffSeedServing"),
    RouteObservationExpectation("seedReplayFenced", "diffSeedServing"),
    RouteObservationExpectation("seedReadyForCommit", "diffSeedServing"),
    RouteObservationExpectation("seedPublished", "diffSeedServing"),
)


def policy_digest_probe_route_observation_count(route: str) -> int:
    return sum(event.route == route for event in POLICY_DIGEST_PROBE_ROUTE_EVENTS)


DELTA_COMPATIBILITY_FIELDS = [
    "repositoryNamespace",
    "objectFormat",
    "repositoryRelativeRootPrefix",
    "inventorySchemaVersion",
    "mandatoryIgnorePolicyIdentity",
    "committedIgnoreControlDigest",
    "configuredIgnoreAuthorityDigest",
    "attributePolicyDigest",
    "sparsePolicyDigest",
    "searchABIMatcherSchemaVersion",
    "searchABIProjectedKeySchemaVersion",
    "searchABIComparatorSchemaVersion",
    "searchABIPathNormalizationSchemaVersion",
    "resolvedExcludesFileIdentity",
    "resolvedAttributesFileIdentity",
]
POLICY_CANONICALIZATION_CONSTITUENTS = [
    "rootNeutralPolicyConfig",
    "commonInfoExclude",
    "canonicalIgnoreFooter",
    "externalExcludes",
    "configuredIgnorePolicy",
    "commonInfoAttributes",
    "canonicalAttributeFooter",
    "externalAttributes",
    "attributePolicy",
    "sparsePolicy",
    "canonicalization",
    "committedControls",
]
POLICY_CANONICALIZATION_CLASSIFICATIONS = {
    "canonicalEquivalentAfterReachabilityFiltering",
    "semanticInputDifference",
    "incomplete",
    "incoherent",
}
REQUIRED_GIT_FIELDS = {
    "available", "command_count", "families", "priorities", "queue_wait_us",
    "duration_us", "output_bytes", "cancelled_count",
}
REQUIRED_FILESYSTEM_FIELDS = {
    "available", "operation_count", "duration_us", "item_count",
}
REQUIRED_RESOURCE_FIELDS = {
    "baseline_resident_mb", "peak_resident_mb", "final_resident_mb",
    "peak_resident_delta_mb", "retained_resident_delta_mb",
    "baseline_physical_footprint_mb", "peak_physical_footprint_mb",
    "final_physical_footprint_mb", "peak_physical_footprint_delta_mb",
    "retained_physical_footprint_delta_mb", "physical_footprint_available",
    "session_cpu_ms", "session_user_cpu_ms", "session_system_cpu_ms",
    "average_core_utilization_percent", "peak_interval_core_utilization_percent",
    "sample_count", "duration_seconds",
}
AUTOMATED_SCENARIOS = [
    "linked-worktree",
    "parallel-1",
    "parallel-2",
    "parallel-4",
    "parallel-8",
]
CORRECTNESS_SCENARIOS = [
    "nested-inherited-worktree-agent",
    "selection-exact-root",
    "code-structure-exact-root",
    "cross-root-negative",
    "non-git-root",
    "watcher-create-edit-rename-delete",
    "secondary-ordinary-root-idle",
    "secondary-worktree-root-idle",
    "secondary-ordinary-root-in-flight",
    "secondary-worktree-root-in-flight",
    "active-agent-tab-binding",
]
METRICS = (
    "materialize_to_root_ready",
    "materialize_to_first_search",
    "materialize_to_first_read",
    "interactive_readiness_us",
)
TOOL_METRICS = ("first_search", "first_read", "first_codemap", "warm_codemap", "passive_tree", "selection")
ALL_METRICS = METRICS + TOOL_METRICS
DURATION_METRICS = tuple(metric for metric in ALL_METRICS if metric != "interactive_readiness_us")
REQUIRED_BOUNDARY_KEYS = (
    "bindingTransitionStarted", "rootReady",
    "firstBenchmarkSearchStarted", "firstBenchmarkSearchCompleted",
    "firstBenchmarkReadStarted", "firstBenchmarkReadCompleted",
    "firstBenchmarkCodemapStarted", "firstBenchmarkCodemapCompleted",
    "warmBenchmarkCodemapStarted", "warmBenchmarkCodemapCompleted",
    "passiveBenchmarkTreeStarted", "passiveBenchmarkTreeCompleted",
    "benchmarkSelectionStarted", "benchmarkSelectionCompleted",
)
PRIMARY_BOUNDARY_KEYS = (
    "bindingTransitionStarted", "rootReady",
    "firstBenchmarkSearchStarted", "firstBenchmarkSearchCompleted",
    "firstBenchmarkReadStarted", "firstBenchmarkReadCompleted",
)
PRIMARY_DURATION_METRICS = (
    "materialize_to_root_ready", "materialize_to_first_search",
    "materialize_to_first_read", "first_search", "first_read",
)
FOLLOW_ON_OPERATION_ORDER = (
    "first_codemap", "warm_codemap", "passive_tree", "selection",
)
FOLLOW_ON_FAILURE_TYPES = {"timeout", "malformed", "transport_error", "mark_error"}
RECEIPT_TERMINAL_STAGE = "consumption"
BOUNDARY_DURATION_PAIRS = {
    "materialize_to_root_ready": ("bindingTransitionStarted", "rootReady"),
    "materialize_to_first_search": ("bindingTransitionStarted", "firstBenchmarkSearchCompleted"),
    "materialize_to_first_read": ("bindingTransitionStarted", "firstBenchmarkReadCompleted"),
    "first_search": ("firstBenchmarkSearchStarted", "firstBenchmarkSearchCompleted"),
    "first_read": ("firstBenchmarkReadStarted", "firstBenchmarkReadCompleted"),
    "first_codemap": ("firstBenchmarkCodemapStarted", "firstBenchmarkCodemapCompleted"),
    "warm_codemap": ("warmBenchmarkCodemapStarted", "warmBenchmarkCodemapCompleted"),
    "passive_tree": ("passiveBenchmarkTreeStarted", "passiveBenchmarkTreeCompleted"),
    "selection": ("benchmarkSelectionStarted", "benchmarkSelectionCompleted"),
}
FIXED_WARMUPS = 1
FIXED_RETAINED_SAMPLES = 5
PRIMARY_CV_CONFIRMATION_THRESHOLD = 0.50
CODEMAP_GATE_MINIMUM_SUPPORTED_FILES = 5_000
CODEMAP_GATE_MINIMUM_COLD_SAMPLES = 20
CODEMAP_GATE_MINIMUM_WARM_SAMPLES = 40
CODEMAP_GATE_WAIT_MILLISECONDS = 10_000
CODEMAP_GATE_HARNESS_ALLOWANCE_MILLISECONDS = 500
CODEMAP_TREE_LEGEND = "(+ denotes code-map available)"
CODEMAP_GATE_SENTINEL = "RPCE_CODEMAP_GATE_OK"
CODEMAP_TEMP_OWNERSHIP_MARKER = ".rpce-codemap-gate-owned.json"
CODEMAP_BASELINE_LEDGER_KIND = "codemap-gate-baseline-ledger"
CODEMAP_REQUIRED_METRICS = (
    "cold_individual_structure", "warm_individual_structure",
    "cold_directory_structure", "warm_directory_structure",
    "tree_marker_availability", "first_search", "first_read",
    "root_readiness", "queue_wait", "operation_duration",
    "memory_peak_resident_delta_mb", "memory_retained_resident_delta_mb",
    "memory_peak_physical_footprint_delta_mb",
    "memory_retained_physical_footprint_delta_mb",
)
CODEMAP_REQUIRED_GATES = (
    "exact cold/warm sample counts",
    "complete p50/p95 metric inventory",
    "all codemap content/path/tree scenarios",
    "every request within 10s + 500ms",
    "root/search/read p95 regression <= 10%",
    "warm structure p50/p95 regression <= 10%",
    "memory delta p95 regression <= 10%",
    "owned cleanup complete",
    "owner-only raw artifacts and privacy scan",
)
CODEMAP_PRIVACY_KEYS = {
    "ok", "scanned_file_count", "failure_codes",
    "allowlisted_root_sha256", "allowlisted_prompt_sha256",
}


class BenchmarkError(RuntimeError):
    pass


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def safe_name(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "-", value).strip("-") or "run"


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def load_strict_json(path: Path, label: str) -> tuple[Any, bytes]:
    raw = path.read_bytes()
    try:
        value = json.loads(
            raw,
            parse_constant=lambda constant: (_ for _ in ()).throw(
                ValueError(f"non-finite JSON constant {constant}")
            ),
        )
    except (json.JSONDecodeError, ValueError) as error:
        raise BenchmarkError(f"{label} is not strict finite JSON") from error
    return value, raw


def secure_write(path: Path, data: bytes, *, exclusive: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    flags = os.O_WRONLY | os.O_CREAT | (os.O_EXCL if exclusive else os.O_TRUNC)
    fd = os.open(path, flags, 0o600)
    try:
        with os.fdopen(fd, "wb", closefd=False) as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
    finally:
        os.close(fd)


def save_json(path: Path, value: Any, *, exclusive: bool = False) -> None:
    secure_write(path, (json.dumps(value, indent=2, sort_keys=True) + "\n").encode(), exclusive=exclusive)


_CLEANUP_PROOF_SENSITIVE_KEYS = {
    "path", "session_id", "context_id", "worktree_id", "branch", "head",
}


def redacted_cleanup_proof(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    proof: list[dict[str, Any]] = []
    for entry in entries:
        redacted: dict[str, Any] = {}
        for key, value in entry.items():
            if key in _CLEANUP_PROOF_SENSITIVE_KEYS and isinstance(value, str):
                redacted[f"{key}_sha256"] = sha256_bytes(value.encode())
            elif key not in _CLEANUP_PROOF_SENSITIVE_KEYS:
                redacted[key] = value
        proof.append(redacted)
    return proof


def save_cleanup_proof(path: Path, entries: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    save_json(path, redacted_cleanup_proof(entries))
    os.chmod(path, 0o600)


def append_ndjson(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(fd, canonical_json(value))
        os.fsync(fd)
    finally:
        os.close(fd)


def walk_json(value: Any) -> Iterable[Any]:
    yield value
    if isinstance(value, dict):
        for child in value.values():
            yield from walk_json(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk_json(child)
    elif isinstance(value, str) and value.lstrip().startswith(("{", "[")):
        try:
            yield from walk_json(json.loads(value))
        except json.JSONDecodeError:
            pass


def structured_json_objects(value: Any) -> Iterable[dict[str, Any]]:
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from structured_json_objects(child)
    elif isinstance(value, list):
        for child in value:
            yield from structured_json_objects(child)
    elif isinstance(value, str) and value.lstrip().startswith(("{", "[")):
        try:
            parsed = json.loads(value)
        except json.JSONDecodeError:
            return
        yield from structured_json_objects(parsed)


def canonicalize_evidence_path(path: str, root_path: str) -> str:
    candidate = Path(path).expanduser()
    if not candidate.is_absolute():
        parts = candidate.parts
        if parts and parts[0] == Path(root_path).name:
            candidate = Path(*parts[1:])
        candidate = Path(root_path) / candidate
    return str(candidate.resolve(strict=False))


def attribute_result_path(
    raw_path: str,
    *,
    explicit_root_path: str | None,
    bound_root_paths: list[str] | None,
    enriched_root_path: str | None,
) -> tuple[str, str]:
    roots = bound_root_paths or ([enriched_root_path] if enriched_root_path else [])
    roots = [str(Path(root).expanduser().resolve(strict=False)) for root in roots]
    candidate = Path(raw_path).expanduser()
    attributed_root: str | None = None
    relative = candidate
    if explicit_root_path is not None:
        attributed_root = str(Path(explicit_root_path).expanduser().resolve(strict=False))
        if roots and attributed_root not in roots:
            raise BenchmarkError("result file root attribution was not present in the atomic binding")
    elif candidate.is_absolute():
        matches = [
            root for root in roots
            if Path(root) == candidate or Path(root) in candidate.parents
        ]
        if len(matches) != 1:
            raise BenchmarkError("absolute result path did not resolve to exactly one bound root")
        attributed_root = matches[0]
    else:
        prefix_matches = [
            root for root in roots if candidate.parts and Path(root).name == candidate.parts[0]
        ]
        if len(prefix_matches) == 1:
            attributed_root = prefix_matches[0]
            relative = Path(*candidate.parts[1:])
        elif len(prefix_matches) > 1:
            raise BenchmarkError("relative result path matched multiple bound roots with the same name")
        elif len(roots) == 1:
            attributed_root = roots[0]
        else:
            raise BenchmarkError("relative result path lacked unambiguous bound-root attribution")
    if attributed_root is None:
        raise BenchmarkError("result path omitted root attribution")
    canonical = (
        candidate.resolve(strict=False)
        if candidate.is_absolute()
        else (Path(attributed_root) / relative).resolve(strict=False)
    )
    root = Path(attributed_root)
    if canonical == root or root not in canonical.parents:
        raise BenchmarkError("result path escaped its attributed root")
    return str(canonical), attributed_root


def benchmark_final_response(value: Any) -> Any:
    if isinstance(value, dict) and "_benchmark_response" in value:
        return value["_benchmark_response"]
    return value


def benchmark_binding(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, dict) or "_benchmark_response" not in value:
        return None
    binding = value.get("_benchmark_binding")
    if (
        value.get("_benchmark_output_valid") is not True
        or value.get("_benchmark_binding_valid") is not True
        or not isinstance(binding, dict)
    ):
        raise BenchmarkError("CLI call omitted exact atomic context binding evidence")
    if binding.get("context_id") != value.get("_benchmark_requested_context_id"):
        raise BenchmarkError("CLI call binding context did not match the requested context")
    return binding


def binding_root_paths(value: Any) -> list[str] | None:
    binding = benchmark_binding(value)
    if binding is None:
        return None
    paths = binding.get("repo_paths")
    if not isinstance(paths, list) or not all(isinstance(path, str) for path in paths):
        raise BenchmarkError("CLI binding omitted loaded root paths")
    return [str(Path(path).expanduser().resolve(strict=False)) for path in paths]


def validate_worktree_scope(
    record: dict[str, Any],
    *,
    expected_logical_root_path: str,
    expected_worktree_id: str,
    expected_physical_worktree_path: str,
) -> dict[str, Any]:
    """Validate CE's logical display identity against an exact physical binding.

    Filesystem tools intentionally display the logical workspace root. The physical
    app-managed path is proven by the agent-start binding and correlated here by the
    exact worktree ID; CE redacts effective_root_path as ``session-bound``.
    """
    scope = record.get("worktree_scope")
    if not isinstance(scope, dict):
        raise BenchmarkError("tool response omitted structured worktree_scope")
    if (
        scope.get("kind") != "session_bound_worktree"
        or scope.get("display_identity") != "logical_canonical_root"
        or scope.get("effective_identity") != "bound_worktree_root"
    ):
        raise BenchmarkError("tool response reported the wrong worktree_scope identities")
    mappings = scope.get("root_mappings")
    if not isinstance(mappings, list):
        raise BenchmarkError("tool response omitted worktree_scope root mappings")
    logical_root = Path(expected_logical_root_path).expanduser().resolve(strict=False)
    logical_labels = {logical_root.name, str(logical_root)}
    matches = [
        item for item in mappings
        if isinstance(item, dict)
        and item.get("worktree_id") == expected_worktree_id
        and item.get("logical_root_path") in logical_labels
        and item.get("effective_root_path") in {
            "session-bound",
            str(Path(expected_physical_worktree_path).expanduser().resolve(strict=False)),
        }
    ]
    if len(matches) != 1:
        raise BenchmarkError("tool worktree_scope did not match the exact physical binding")
    return {
        "worktree_id": expected_worktree_id,
        "physical_worktree_path": str(
            Path(expected_physical_worktree_path).expanduser().resolve(strict=False)
        ),
        "logical_root_path": str(logical_root),
        "display_identity": scope["display_identity"],
        "effective_identity": scope["effective_identity"],
    }


def tool_payload(value: Any, tool: str) -> dict[str, Any]:
    signatures = {
        "file_search": lambda item: isinstance(item.get("total_matches"), int)
        and isinstance(item.get("content_match_groups"), list),
        "read_file": lambda item: isinstance(item.get("display_path"), str)
        and isinstance(item.get("content"), str),
        "manage_selection": lambda item: isinstance(item.get("status"), str)
        and isinstance(item.get("files"), list)
        and ("total_tokens" in item or "codemap_auto_enabled" in item),
        "get_code_structure": lambda item: isinstance(item.get("status"), str)
        and isinstance(item.get("files"), list)
        and ("issues" in item or "retry" in item or "summary" in item),
        "get_file_tree": lambda item: isinstance(item.get("tree"), str)
        and isinstance(item.get("uses_legend"), bool),
    }
    declared: list[dict[str, Any]] = []
    current: list[dict[str, Any]] = []
    for candidate in structured_json_objects(benchmark_final_response(value)):
        candidate_tool = candidate.get("tool") or candidate.get("tool_name")
        if candidate_tool is not None:
            if str(candidate_tool).split("__")[-1] == tool:
                declared.append(candidate)
            continue
        if signatures[tool](candidate):
            current.append(candidate)
    candidates = declared or current
    if len(candidates) != 1:
        raise BenchmarkError(f"{tool} response requires exactly one recognizable tool payload")
    return candidates[0]


def structured_mcp_record(
    value: Any,
    tool: str,
    *,
    expected_root_id: str,
    expected_root_path: str,
    expected_root_type: str,
    expected_worktree_id: str | None = None,
    expected_physical_worktree_path: str | None = None,
) -> dict[str, Any]:
    record = tool_payload(value, tool)
    canonical_root_path = str(Path(expected_root_path).expanduser().resolve(strict=False))
    bound_paths = binding_root_paths(value)
    if bound_paths is not None and canonical_root_path not in bound_paths:
        raise BenchmarkError(f"{tool} binding did not include the expected root")
    if (expected_worktree_id is None) != (expected_physical_worktree_path is None):
        raise BenchmarkError("worktree_scope validation requires ID and physical path together")
    worktree_scope: dict[str, Any] | None = None
    if expected_worktree_id is not None and expected_physical_worktree_path is not None:
        worktree_scope = validate_worktree_scope(
            record,
            expected_logical_root_path=canonical_root_path,
            expected_worktree_id=expected_worktree_id,
            expected_physical_worktree_path=expected_physical_worktree_path,
        )
    expected_root = {
        "id": str(uuid.UUID(expected_root_id)).upper(),
        "path": canonical_root_path,
        "type": expected_root_type,
    }
    enriched_root = record.get("root")
    enriched_root_path: str | None = None
    if isinstance(enriched_root, dict):
        root_id = enriched_root.get("id") or enriched_root.get("root_id")
        root_path = enriched_root.get("path") or enriched_root.get("root_path")
        root_type = enriched_root.get("type") or enriched_root.get("root_type")
        if not all(isinstance(item, str) and item for item in (root_id, root_path, root_type)):
            raise BenchmarkError(f"{tool} structured root identity was incomplete")
        actual_root = {
            "id": str(uuid.UUID(root_id)).upper(),
            "path": str(Path(root_path).expanduser().resolve(strict=False)),
            "type": root_type,
        }
        enriched_root_path = actual_root["path"]
        if actual_root != expected_root:
            raise BenchmarkError(f"{tool} returned the wrong canonical root")

    files_raw: list[dict[str, Any]]
    if tool == "file_search" and isinstance(record.get("content_match_groups"), list):
        files_raw = []
        for group in record["content_match_groups"]:
            if not isinstance(group, dict) or not isinstance(group.get("path"), str):
                raise BenchmarkError("file_search match group omitted path")
            lines = group.get("lines")
            if not isinstance(lines, list):
                raise BenchmarkError("file_search match group omitted lines")
            content = "\n".join(
                line.get("line_text", "") for line in lines if isinstance(line, dict)
            )
            files_raw.append({"path": group["path"], "type": "file", "content": content})
    elif tool == "file_search":
        raw = record.get("matches")
        files_raw = raw if isinstance(raw, list) else []
    elif tool == "read_file" and isinstance(record.get("display_path"), str):
        files_raw = [{
            "path": record["display_path"], "type": "file", "content": record.get("content"),
        }]
    elif tool == "read_file":
        raw = record.get("files")
        if not isinstance(raw, list) and isinstance(record.get("path"), str):
            raw = [{
                "path": record["path"],
                "type": record.get("file_type") or record.get("type") or "file",
                "content": record.get("content"),
            }]
        files_raw = raw if isinstance(raw, list) else []
    else:
        raw = record.get("files")
        files_raw = raw if isinstance(raw, list) else []

    files: list[dict[str, Any]] = []
    for file in files_raw:
        if not isinstance(file, dict):
            raise BenchmarkError(f"{tool} returned a non-object file record")
        raw_path = file.get("path_within_root") or file.get("path")
        if not isinstance(raw_path, str):
            raise BenchmarkError(f"{tool} file record omitted path")
        source_root = file.get("root_path")
        explicit_root = source_root if isinstance(source_root, str) else None
        canonical_path, attributed_root = attribute_result_path(
            raw_path,
            explicit_root_path=explicit_root,
            bound_root_paths=bound_paths,
            enriched_root_path=enriched_root_path,
        )
        file_type = file.get("type") or file.get("file_type") or file.get("kind")
        if not isinstance(file_type, str) or not file_type:
            file_type = Path(raw_path).suffix.lstrip(".") if tool == "get_code_structure" else "file"
        files.append({
            "path": canonical_path,
            "root_path": attributed_root,
            "type": file_type,
            "content": file.get("content") or file.get("text") or file.get("code"),
        })
    result = dict(record)
    result["status"] = record.get("status") or "success"
    result["root"] = expected_root
    result["files"] = files
    if worktree_scope is not None:
        result["validated_worktree_scope"] = worktree_scope
    return result


def request_path_evidence(
    value: Any,
    tool: str,
    *,
    expected_root_path: str,
    expected_file_path: str | None,
) -> None:
    if not isinstance(value, dict) or "_benchmark_payload" not in value:
        return
    payload = value.get("_benchmark_payload")
    if not isinstance(payload, dict):
        raise BenchmarkError(f"{tool} call omitted request payload evidence")
    raw_paths: list[str] = []
    if tool == "file_search":
        filters = payload.get("filter")
        paths = filters.get("paths") if isinstance(filters, dict) else None
        raw_paths = paths if isinstance(paths, list) and all(isinstance(path, str) for path in paths) else []
    elif tool == "read_file":
        raw_paths = [payload["path"]] if isinstance(payload.get("path"), str) else []
    elif tool == "get_code_structure":
        if payload.get("scope") == "selected":
            return
        paths = payload.get("paths")
        raw_paths = paths if isinstance(paths, list) and all(isinstance(path, str) for path in paths) else []
    else:
        return
    if not raw_paths:
        raise BenchmarkError(f"{tool} call omitted explicit path routing")
    root = Path(expected_root_path).resolve(strict=False)
    canonical_paths = [Path(canonicalize_evidence_path(path, str(root))) for path in raw_paths]
    if any(path != root and root not in path.parents for path in canonical_paths):
        raise BenchmarkError(f"{tool} request escaped the expected root")
    if expected_file_path is not None:
        expected = Path(canonicalize_evidence_path(expected_file_path, str(root)))
        if tool == "read_file" and canonical_paths != [expected]:
            raise BenchmarkError("read_file request did not target the exact expected file")
        if tool in {"file_search", "get_code_structure"} and not any(
            path == expected or path in expected.parents for path in canonical_paths
        ):
            raise BenchmarkError(f"{tool} request did not scope the expected file")


def require_structured_success(
    value: Any,
    tool: str,
    *,
    expected_root_id: str,
    expected_root_path: str,
    expected_root_type: str,
    expected_file_path: str,
    expected_file_type: str,
    expected_content: str | None = None,
    require_only_file: bool = True,
    allow_other_roots: bool = False,
    expected_worktree_id: str | None = None,
    expected_physical_worktree_path: str | None = None,
) -> dict[str, Any]:
    if not call_succeeded(value):
        raise BenchmarkError(f"{tool} transport/tool call failed")
    request_path_evidence(
        value, tool, expected_root_path=expected_root_path, expected_file_path=expected_file_path
    )
    record = structured_mcp_record(
        value, tool, expected_root_id=expected_root_id,
        expected_root_path=expected_root_path, expected_root_type=expected_root_type,
        expected_worktree_id=expected_worktree_id,
        expected_physical_worktree_path=expected_physical_worktree_path,
    )
    if record.get("status") not in {"ok", "complete", "completed", "ready", "success"}:
        raise BenchmarkError(f"{tool} returned non-success status")
    expected_root = {
        "id": str(uuid.UUID(expected_root_id)).upper(),
        "path": str(Path(expected_root_path).resolve(strict=False)),
        "type": expected_root_type,
    }
    if record["root"] != expected_root:
        raise BenchmarkError(f"{tool} returned the wrong canonical root")
    expected_path = canonicalize_evidence_path(expected_file_path, expected_root_path)
    matches = [
        file for file in record["files"]
        if file["path"] == expected_path
        and file.get("root_path") in (None, expected_root["path"])
    ]
    if len(matches) != 1:
        raise BenchmarkError(f"{tool} did not return exactly the expected file")
    if require_only_file and len(record["files"]) != 1:
        raise BenchmarkError(f"{tool} returned cross-root or extra files")
    if not allow_other_roots and any(
        file.get("root_path") not in (None, expected_root["path"]) for file in record["files"]
    ):
        raise BenchmarkError(f"{tool} returned files from another bound root")
    if matches[0]["type"] != expected_file_type:
        raise BenchmarkError(f"{tool} returned the wrong file type")
    if expected_content is not None and expected_content not in str(matches[0].get("content") or ""):
        raise BenchmarkError(f"{tool} expected file content missing")
    if tool == "file_search":
        count = record.get("total_matches")
        if not isinstance(count, int) or count < 1:
            raise BenchmarkError("file_search returned invalid match count")
    return record


def require_structured_removed(
    value: Any,
    tool: str,
    *,
    expected_root_id: str,
    expected_root_path: str,
    expected_root_type: str,
    expected_file_path: str | None = None,
    require_absent_bound_root: bool = False,
) -> dict[str, Any]:
    request_path_evidence(
        value, tool, expected_root_path=expected_root_path, expected_file_path=expected_file_path
    )
    bound_paths = binding_root_paths(value)
    canonical_root = str(Path(expected_root_path).resolve(strict=False))
    payload = tool_payload(value, tool) if tool != "read_file" or call_succeeded(value) else None
    if isinstance(payload, dict) and isinstance(payload.get("root"), dict):
        if require_absent_bound_root and (
            bound_paths is None or canonical_root in bound_paths
        ):
            raise BenchmarkError(
                "enriched removed Git-root evidence required the root absent from atomic binding"
            )
        enriched_root = payload["root"]
        raw_root_id = enriched_root.get("id") or enriched_root.get("root_id")
        raw_root_path = enriched_root.get("path") or enriched_root.get("root_path")
        raw_root_type = enriched_root.get("type") or enriched_root.get("root_type")
        if not all(isinstance(item, str) and item for item in (
            raw_root_id, raw_root_path, raw_root_type,
        )):
            raise BenchmarkError(f"{tool} enriched removed-root identity was incomplete")
        expected_root = {
            "id": str(uuid.UUID(expected_root_id)).upper(),
            "path": canonical_root,
            "type": expected_root_type,
        }
        actual_root = {
            "id": str(uuid.UUID(raw_root_id)).upper(),
            "path": str(Path(raw_root_path).resolve(strict=False)),
            "type": raw_root_type,
        }
        raw_files = payload.get("matches") if tool == "file_search" else payload.get("files")
        record = dict(payload)
        record["root"] = actual_root
        record["files"] = raw_files if isinstance(raw_files, list) else []
        issue = record.get("issue")
        issue_code = issue.get("code") if isinstance(issue, dict) else record.get("issue_code")
        allowed_issue_codes = (
            {"root_not_found", "root_removed", "root_unavailable", "path_not_found"}
            if require_absent_bound_root else
            {"root_not_found", "root_removed", "root_unavailable", "git_root_unavailable"}
        )
        if (
            call_succeeded(value)
            and actual_root == expected_root
            and record.get("status") in {"not_found", "unavailable", "removed"}
            and issue_code in allowed_issue_codes
            and not record["files"]
        ):
            return record
        raise BenchmarkError(f"{tool} enriched removed-root evidence was invalid")
    if tool == "file_search":
        if not call_succeeded(value) or bound_paths is None or canonical_root in bound_paths:
            raise BenchmarkError("file_search removal check lacked successful absent-root binding")
        if (
            payload.get("total_matches") != 0
            or payload.get("matched_files") != 0
            or payload.get("searched_files") != 0
            or payload.get("content_match_groups")
        ):
            raise BenchmarkError("file_search removal check returned stale matches")
        return {
            "status": "removed", "root": {
                "id": str(uuid.UUID(expected_root_id)).upper(), "path": canonical_root,
                "type": expected_root_type,
            }, "files": [], "issue": {"code": "root_removed"},
        }
    if tool == "get_code_structure":
        if not call_succeeded(value) or not isinstance(payload, dict):
            raise BenchmarkError("get_code_structure unavailable check failed")
        issues = payload.get("issues")
        codes = {
            issue.get("code") for issue in issues if isinstance(issue, dict)
        } if isinstance(issues, list) else set()
        root_present = bound_paths is not None and canonical_root in bound_paths
        if require_absent_bound_root:
            if bound_paths is None or root_present:
                raise BenchmarkError(
                    "removed Git-root structure check required the root absent from atomic binding"
                )
            allowed_codes = {"path_not_found"}
        else:
            if bound_paths is None or not root_present:
                raise BenchmarkError(
                    "non-Git structure check required the current root in atomic binding"
                )
            allowed_codes = {"git_root_unavailable"}
        if payload.get("status") != "unavailable" or payload.get("files") or not (codes & allowed_codes):
            raise BenchmarkError("get_code_structure unavailable check lacked exact issue/root evidence")
        return {
            "status": "unavailable", "root": {
                "id": str(uuid.UUID(expected_root_id)).upper(), "path": canonical_root,
                "type": expected_root_type,
            }, "files": [], "issue": {"code": sorted(codes & allowed_codes)[0]},
        }
    if tool == "read_file":
        stderr = value.get("_benchmark_stderr") if isinstance(value, dict) else None
        expected_path = canonicalize_evidence_path(expected_file_path or "", canonical_root)
        if (
            call_succeeded(value)
            or bound_paths is None
            or canonical_root in bound_paths
            or not isinstance(stderr, str)
            or expected_path not in stderr
            or "not inside any loaded folder" not in stderr
        ):
            raise BenchmarkError("read_file removal check lacked exact absent-root path rejection")
        return {
            "status": "removed", "root": {
                "id": str(uuid.UUID(expected_root_id)).upper(), "path": canonical_root,
                "type": expected_root_type,
            }, "files": [], "issue": {"code": "root_removed"},
        }
    raise BenchmarkError(f"unsupported removed-root tool {tool}")


def structured_success_evidence(value: Any, tool: str, **expected: Any) -> dict[str, Any]:
    try:
        record = require_structured_success(value, tool, **expected)
        return {
            "ok": True,
            "status": record["status"],
            "root": record["root"],
            "files": record["files"],
            "worktree_scope": record.get("validated_worktree_scope"),
        }
    except BenchmarkError as error:
        return {"ok": False, "error": str(error)}


def structured_removed_evidence(value: Any, tool: str, **expected: Any) -> dict[str, Any]:
    try:
        record = require_structured_removed(value, tool, **expected)
        return {"ok": True, "status": record["status"], "root": record["root"], "issue": record.get("issue")}
    except BenchmarkError as error:
        return {"ok": False, "error": str(error)}


def structured_empty_success_evidence(
    value: Any,
    tool: str,
    *,
    expected_root_id: str,
    expected_root_path: str,
    expected_root_type: str,
) -> dict[str, Any]:
    try:
        if not call_succeeded(value):
            raise BenchmarkError(f"{tool} transport/tool call failed")
        record = structured_mcp_record(
            value, tool, expected_root_id=expected_root_id,
            expected_root_path=expected_root_path, expected_root_type=expected_root_type,
        )
        request_path_evidence(
            value, tool, expected_root_path=expected_root_path, expected_file_path=None
        )
        if record.get("status") not in {"ok", "complete", "completed", "ready", "success"}:
            raise BenchmarkError(f"{tool} returned non-success status")
        expected_root = {
            "id": str(uuid.UUID(expected_root_id)).upper(),
            "path": str(Path(expected_root_path).resolve(strict=False)),
            "type": expected_root_type,
        }
        if record["root"] != expected_root or record["files"]:
            raise BenchmarkError(f"{tool} empty result had wrong root or stale files")
        if tool == "file_search" and record.get("total_matches") != 0:
            raise BenchmarkError("file_search empty result had nonzero total_matches")
        return {"ok": True, "status": record["status"], "root": record["root"]}
    except BenchmarkError as error:
        return {"ok": False, "error": str(error)}


def find_value(value: Any, key: str) -> Any:
    for candidate in walk_json(value):
        if isinstance(candidate, dict) and key in candidate:
            return candidate[key]
    return None


def find_object(value: Any, key: str) -> dict[str, Any]:
    for candidate in walk_json(value):
        if isinstance(candidate, dict) and key in candidate:
            return candidate
    raise BenchmarkError(f"response omitted {key!r}")


def nested_response_object(value: Any, key: str) -> dict[str, Any]:
    enclosing = find_object(value, key)
    nested = enclosing.get(key)
    if not isinstance(nested, dict):
        raise BenchmarkError(f"response {key!r} payload was not an object")
    return nested


def response_text(value: Any) -> str:
    chunks: list[str] = []
    for candidate in walk_json(value):
        if isinstance(candidate, dict) and isinstance(candidate.get("text"), str):
            chunks.append(candidate["text"])
    return "\n".join(chunks)


def response_session_id(value: Any) -> str:
    found = find_value(value, "session_id") or find_value(value, "sessionId")
    if not isinstance(found, str) or not found:
        raise BenchmarkError("agent response omitted session_id")
    return found


def response_context_id(value: Any) -> str | None:
    found = find_value(value, "context_id") or find_value(value, "tab_id")
    return found if isinstance(found, str) and found else None


def response_status(value: Any) -> str:
    found = find_value(value, "status") or find_value(value, "state")
    return str(found or "unknown").lower()


def response_worktree_paths(value: Any) -> list[str]:
    paths: set[str] = set()
    for candidate in walk_json(value):
        if not isinstance(candidate, dict):
            continue
        if any(key in candidate for key in ("worktree_id", "worktree_path", "worktree")):
            for key in ("path", "worktree_path", "worktree_root_path"):
                path = candidate.get(key)
                if isinstance(path, str) and path.startswith("/"):
                    paths.add(path)
    return sorted(paths)


def response_worktree_binding_set(value: Any) -> set[tuple[str, str]]:
    bindings: set[tuple[str, str]] = set()
    for candidate in structured_json_objects(benchmark_final_response(value)):
        raw_id = candidate.get("worktree_id") or candidate.get("id")
        raw_path = candidate.get("worktree_root_path") or candidate.get("worktree_path")
        if not isinstance(raw_id, str) or not raw_id:
            continue
        if not isinstance(raw_path, str) or not Path(raw_path).is_absolute():
            continue
        bindings.add((raw_id, str(Path(raw_path).resolve(strict=False))))
    return bindings


def exact_response_worktree_binding(value: Any, expected_path: Path) -> tuple[str, str]:
    canonical = str(expected_path.expanduser().resolve(strict=False))
    matches = [item for item in response_worktree_binding_set(value) if item[1] == canonical]
    if len(matches) != 1:
        raise BenchmarkError("agent response omitted one exact physical worktree binding")
    return matches[0]


def child_inheritance_evidence(
    parent_response: Any,
    child_response: Any,
    *,
    parent_context_id: str,
    parent_worktree_path: str,
) -> dict[str, Any]:
    child_context_id = response_context_id(child_response)
    parent_bindings = response_worktree_binding_set(parent_response)
    child_bindings = response_worktree_binding_set(child_response)
    canonical_parent_worktree = str(Path(parent_worktree_path).resolve(strict=False))
    distinct_context = (
        isinstance(child_context_id, str)
        and child_context_id.upper() != parent_context_id.upper()
    )
    exact_binding_set = bool(
        parent_bindings
        and child_bindings == parent_bindings
        and any(path == canonical_parent_worktree for _, path in child_bindings)
    )
    return {
        "ok": distinct_context and exact_binding_set,
        "distinct_child_context": distinct_context,
        "child_context_id": child_context_id,
        "exact_worktree_binding_set": exact_binding_set,
        "parent_worktree_bindings": sorted(parent_bindings),
        "child_worktree_bindings": sorted(child_bindings),
    }


def git_work_records(value: Any) -> list[dict[str, Any]]:
    records = find_value(value, "git_invocations")
    if not isinstance(records, list):
        return []
    return [record for record in records if isinstance(record, dict)]


def new_records(before: list[dict[str, Any]], after: list[dict[str, Any]]) -> list[dict[str, Any]]:
    remaining = [canonical_json(record) for record in before]
    result: list[dict[str, Any]] = []
    for record in after:
        encoded = canonical_json(record)
        try:
            remaining.remove(encoded)
        except ValueError:
            result.append(record)
    return result


def runtime_root_identity(value: Any, expected_path: str) -> dict[str, str]:
    canonical = str(Path(expected_path).resolve(strict=False))
    matches: list[dict[str, str]] = []
    for candidate in structured_json_objects(value):
        raw_path = candidate.get("root_path") or candidate.get("path")
        raw_id = candidate.get("root_id") or candidate.get("id")
        raw_type = candidate.get("root_kind") or candidate.get("root_type") or candidate.get("type")
        if not all(isinstance(item, str) and item for item in (raw_path, raw_id, raw_type)):
            continue
        if str(Path(raw_path).resolve(strict=False)) != canonical:
            continue
        matches.append({
            "id": str(uuid.UUID(raw_id)).upper(), "path": canonical, "type": raw_type,
        })
    unique = {canonical_json(match) for match in matches}
    if len(unique) != 1:
        raise BenchmarkError(f"runtime snapshot did not contain exactly one root identity for {canonical}")
    return json.loads(next(iter(unique)))


def strict_telemetry_number(value: Any, *, positive: bool, label: str) -> float:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise BenchmarkError(f"{label} must be a numeric non-bool value")
    number = float(value)
    if not math.isfinite(number):
        raise BenchmarkError(f"{label} must be finite")
    if number < 0 or (positive and number == 0):
        qualifier = "positive" if positive else "non-negative"
        raise BenchmarkError(f"{label} must be {qualifier}")
    return number


def nearest_rank(values: Iterable[float], fraction: float) -> float | None:
    ordered = sorted(
        strict_telemetry_number(value, positive=False, label="percentile value")
        for value in values
    )
    if not ordered:
        return None
    return ordered[max(0, math.ceil(fraction * len(ordered)) - 1)]


def stats(
    values: Iterable[float], *, positive: bool = False, label: str = "telemetry value"
) -> dict[str, Any]:
    ordered = sorted(
        strict_telemetry_number(value, positive=positive, label=label)
        for value in values
    )
    if not ordered:
        return {"count": 0, "p50": None, "p95": None, "variance": None, "cv": None}
    mean = statistics.fmean(ordered)
    variance = statistics.variance(ordered) if len(ordered) > 1 else 0.0
    cv = math.sqrt(variance) / mean if mean else None
    return {
        "count": len(ordered),
        "p50": statistics.median(ordered),
        "p95": nearest_rank(ordered, 0.95),
        "variance": variance,
        "cv": cv,
        "reliability": "high" if cv is not None and cv <= 0.10 else "moderate" if cv is not None and cv <= 0.20 else "low",
        "min": ordered[0],
        "max": ordered[-1],
    }


def comparison_direction(control_p95: float, candidate_p95: float, minimum_improvement: float) -> str:
    control = strict_telemetry_number(control_p95, positive=True, label="control p95")
    candidate = strict_telemetry_number(candidate_p95, positive=True, label="candidate p95")
    improvement = (control - candidate) / control
    return "pass" if improvement >= minimum_improvement else "fail"


def confirmation_policy(
    primary: dict[str, Any], confirmation: dict[str, Any] | None, *, minimum_improvement: float
) -> dict[str, Any]:
    direction = comparison_direction(primary["control_p95"], primary["candidate_p95"], minimum_improvement)
    high_variance = max(float(primary["control_cv"]), float(primary["candidate_cv"])) > PRIMARY_CV_CONFIRMATION_THRESHOLD
    if not high_variance:
        return {"status": direction, "direction": direction, "confirmation_required": False}
    if confirmation is None:
        return {"status": "high-variance/inconclusive", "direction": direction, "confirmation_required": True}
    confirmation_direction = comparison_direction(
        confirmation["control_p95"], confirmation["candidate_p95"], minimum_improvement
    )
    return {
        "status": direction if direction == confirmation_direction else "high-variance/inconclusive",
        "direction": direction,
        "confirmation_direction": confirmation_direction,
        "confirmation_required": True,
    }


def register_unique(value: Any, seen: set[Any], label: str) -> None:
    if value in seen:
        raise BenchmarkError(f"duplicate {label}: {value}")
    seen.add(value)


def validate_sample_ordinals(samples: list[dict[str, Any]], expected_count: int) -> None:
    if not positive_integer(expected_count):
        raise BenchmarkError("expected sample count must be a positive integer")
    raw_ordinals = [sample.get("ordinal") for sample in samples]
    if not all(positive_integer(ordinal) for ordinal in raw_ordinals):
        raise BenchmarkError("sample ordinals must be positive integers")
    ordinals = set(raw_ordinals)
    if len(samples) != expected_count or ordinals != set(range(1, expected_count + 1)):
        raise BenchmarkError("sample ordinal/accounting mismatch")


def cohort_accounting_valid(
    cohort: dict[str, Any], *, width: int, warmups: int, retained: int, invocations: int
) -> bool:
    return (
        invocations > 0
        and cohort.get("invocation_count") == invocations
        and cohort.get("attempted") == invocations * (warmups + retained) * width
        and cohort.get("valid_retained") == invocations * retained * width
        and cohort.get("invalid_attempted") == 0
    )


def run_local(command: list[str], cwd: Path, *, check: bool = True) -> subprocess.CompletedProcess[str]:
    process = subprocess.run(command, cwd=cwd, text=True, capture_output=True)
    if check and process.returncode:
        raise BenchmarkError(f"{' '.join(command)} failed: {process.stderr.strip()}")
    return process


def resolve_commit_oid(root: Path, base_ref: str) -> str:
    process = run_local(
        ["git", "rev-parse", "--verify", f"{base_ref}^{{commit}}"], root, check=False
    )
    oid = process.stdout.strip().lower()
    if process.returncode or re.fullmatch(r"[0-9a-f]{40,64}", oid) is None:
        raise BenchmarkError(f"base-ref {base_ref!r} did not resolve to one commit OID")
    return oid


def validate_planned_base_commit(plan: dict[str, Any], root: Path) -> str:
    dataset = plan.get("dataset")
    if not isinstance(dataset, dict):
        raise BenchmarkError("plan omitted dataset")
    base_ref = dataset.get("base_ref")
    planned_oid = dataset.get("base_commit_oid")
    if not isinstance(base_ref, str) or not isinstance(planned_oid, str):
        raise BenchmarkError("plan omitted immutable base commit OID")
    if re.fullmatch(r"[0-9a-f]{40,64}", planned_oid.lower()) is None:
        raise BenchmarkError("plan base commit OID was invalid")
    current_oid = resolve_commit_oid(root, base_ref)
    if current_oid != planned_oid.lower():
        raise BenchmarkError(
            f"base-ref {base_ref!r} moved from planned commit {planned_oid} to {current_oid}"
        )
    return planned_oid.lower()


def validate_tracked_read_fixture(
    root: Path,
    *,
    base_ref: str,
    read_path: str,
    search_marker: str,
    read_marker: str,
) -> str:
    relative = Path(read_path)
    if relative.is_absolute() or ".." in relative.parts or not relative.parts:
        raise BenchmarkError("read-path must be root-relative and remain inside the root")
    object_name = f"{base_ref}:{relative.as_posix()}"
    exists = run_local(["git", "cat-file", "-e", object_name], root, check=False)
    if exists.returncode:
        raise BenchmarkError(
            f"read-path {relative.as_posix()!r} does not exist in exact base-ref {base_ref!r}"
        )
    blob = run_local(["git", "cat-file", "blob", object_name], root, check=False)
    if blob.returncode:
        raise BenchmarkError(
            f"read-path {relative.as_posix()!r} is not a readable blob in exact base-ref {base_ref!r}"
        )
    missing = [marker for marker in (search_marker, read_marker) if marker not in blob.stdout]
    if missing:
        raise BenchmarkError(
            f"tracked read-path blob in {base_ref!r} omitted required marker(s): {missing}"
        )
    return sha256_bytes(blob.stdout.encode())


def resolve_cli(raw: str | None) -> Path:
    candidates = [
        raw,
        os.environ.get("REPOPROMPT_DEBUG_CLI_INSTALL_PATH"),
        shutil.which("rpce-cli-debug"),
        str(Path.home() / "Library/Application Support/RepoPrompt CE/repoprompt_ce_cli_debug"),
    ]
    for candidate in candidates:
        if candidate:
            path = Path(candidate).expanduser()
            if path.is_file() and os.access(path, os.X_OK):
                return path.resolve(strict=True)
    raise BenchmarkError("rpce-cli-debug was not found")


def exact_live_build_identity(cli: Path, plan: dict[str, Any]) -> dict[str, str]:
    resolved_cli = cli.resolve(strict=True)
    app_executable = resolved_cli.parent / "RepoPrompt"
    if not app_executable.is_file() or not os.access(app_executable, os.X_OK):
        raise BenchmarkError("resolved CE CLI did not identify the exact RepoPrompt app executable")
    source = Path(__file__).resolve(strict=True)
    return {
        "cli_sha256": sha256_bytes(resolved_cli.read_bytes()),
        "app_executable_sha256": sha256_bytes(app_executable.read_bytes()),
        "harness_source_sha256": sha256_bytes(source.read_bytes()),
        "base_commit_oid": str(plan["dataset"]["base_commit_oid"]),
    }


def validate_uuid(value: str, label: str) -> str:
    try:
        return str(uuid.UUID(value)).upper()
    except ValueError as error:
        raise BenchmarkError(f"{label} must be a UUID") from error


def repository_root() -> Path:
    return Path(__file__).resolve().parent.parent


def ownership_marker_path(root: Path) -> Path:
    return root / OWNERSHIP_MARKER_NAME


def create_marker_command(args: argparse.Namespace) -> int:
    root = Path(args.root_path).expanduser().resolve(strict=True)
    real_repository = root == repository_root().resolve()
    if real_repository:
        if not args.confirm_real_repository_benchmark or not args.confirm_dedicated_workspace:
            raise BenchmarkError(
                "marking the real repository requires --confirm-real-repository-benchmark "
                "and --confirm-dedicated-workspace"
            )
    elif not args.confirm_disposable_root:
        raise BenchmarkError("create-marker requires --confirm-disposable-root")
    marker = ownership_marker_path(root)
    payload = {
        "schema_version": SCHEMA_VERSION,
        "purpose": "rpce-worktree-startup-live-benchmark",
        "disposable": not real_repository,
        "target_kind": "real-repository-dedicated" if real_repository else "disposable-fixture",
        "workspace_id": validate_uuid(args.workspace_id, "workspace-id"),
        "root_id": validate_uuid(args.root_id, "root-id"),
        "canonical_root": str(root),
        "owner_token": validate_uuid(args.owner_token, "owner-token"),
        "created_at": utc_now(),
    }
    save_json(marker, payload, exclusive=True)
    print(marker)
    return 0


def load_ownership_marker(root: Path) -> tuple[Path, dict[str, Any], str]:
    marker_path = ownership_marker_path(root)
    raw = marker_path.read_bytes()
    marker = json.loads(raw)
    if not isinstance(marker, dict):
        raise BenchmarkError("benchmark ownership marker must be a JSON object")
    return marker_path, marker, sha256_bytes(raw)


def validate_ownership_marker(
    root: Path,
    *,
    workspace_id: str,
    root_id: str,
    owner_token: str | None = None,
    expected_sha256: str | None = None,
    allow_real_repository: bool = False,
) -> tuple[Path, dict[str, Any], str]:
    real_repository = root.resolve() == repository_root().resolve()
    if real_repository and not allow_real_repository:
        raise BenchmarkError("the development checkout is not a disposable benchmark target")
    marker_path, marker, digest = load_ownership_marker(root)
    expected = {
        "schema_version": SCHEMA_VERSION,
        "purpose": "rpce-worktree-startup-live-benchmark",
        "disposable": not real_repository,
        "target_kind": "real-repository-dedicated" if real_repository else "disposable-fixture",
        "workspace_id": workspace_id,
        "root_id": root_id,
        "canonical_root": str(root.resolve()),
    }
    for key, value in expected.items():
        if str(marker.get(key)).upper() != str(value).upper():
            raise BenchmarkError(f"benchmark ownership marker mismatch for {key}")
    validate_uuid(str(marker.get("owner_token") or ""), "marker owner-token")
    if owner_token is not None and str(marker.get("owner_token")).upper() != owner_token.upper():
        raise BenchmarkError("benchmark ownership marker owner token mismatch")
    if expected_sha256 is not None and digest != expected_sha256:
        raise BenchmarkError("benchmark ownership marker digest changed")
    return marker_path, marker, digest


def load_plan(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or value.get("schema_version") != SCHEMA_VERSION:
        raise BenchmarkError("unsupported plan schema")
    digest = value.get("plan_sha256")
    body = dict(value)
    body.pop("plan_sha256", None)
    if digest != sha256_bytes(canonical_json(body)):
        raise BenchmarkError("plan digest mismatch")
    return value


def plan_digest(value: dict[str, Any]) -> str:
    body = dict(value)
    body.pop("plan_sha256", None)
    return sha256_bytes(canonical_json(body))


def exact_scope(plan: dict[str, Any]) -> dict[str, Any]:
    scope = plan["scope"]
    return {
        "window_id": scope["window_id"],
        "workspace_id": scope["workspace_id"],
        "context_id": scope["context_id"],
        "benchmark_context_id": scope["context_id"],
        "root_id": scope["root_id"],
    }


@dataclass
class TimedCall:
    response: Any
    started_ns: int
    finished_ns: int
    returncode: int


def parse_atomic_cli_output(
    stdout: str,
    *,
    expected_context_id: str,
    expected_window_id: int,
) -> tuple[dict[str, Any], dict[str, Any]]:
    raw_documents = stdout.strip().split("\n\n---\n\n")
    if len(raw_documents) != 2 or any(not document.strip() for document in raw_documents):
        raise BenchmarkError("atomic CLI output must contain exactly binding then tool-result JSON")
    documents: list[Any] = []
    for raw_document in raw_documents:
        try:
            documents.append(json.loads(raw_document))
        except json.JSONDecodeError as error:
            raise BenchmarkError("atomic CLI output contained non-JSON content") from error
    binding_document, final_response = documents
    if not isinstance(binding_document, dict) or not isinstance(binding_document.get("binding"), dict):
        raise BenchmarkError("atomic CLI output first document was not a binding result")
    if not isinstance(final_response, dict) or isinstance(final_response.get("binding"), dict):
        raise BenchmarkError("atomic CLI output second document was not the tool result")
    binding = binding_document["binding"]
    binding_context = binding.get("context_id")
    if (
        not isinstance(binding_context, str)
        or binding_context.upper() != expected_context_id.upper()
        or binding.get("window_id") != expected_window_id
    ):
        raise BenchmarkError("atomic CLI binding did not match the requested context/window")
    return binding, final_response


class CLIRunner:
    def __init__(
        self, cli: Path, window_id: int, context_id: str, cwd: Path, artifact: Path | None = None
    ) -> None:
        self.cli = cli
        self.window_id = window_id
        self.context_id = validate_uuid(context_id, "context-id")
        self.cwd = cwd
        self.artifact = artifact
        self.lock = threading.Lock()
        existing_ordinals: list[int] = []
        if artifact and (artifact / "raw").is_dir():
            for path in (artifact / "raw").glob("*.json"):
                prefix = path.name.split("-", 1)[0]
                if prefix.isdigit():
                    existing_ordinals.append(int(prefix))
        self.ordinal = max(existing_ordinals, default=-1) + 1

    def call(
        self,
        label: str,
        tool: str,
        payload: dict[str, Any],
        *,
        timeout: float = 300,
        check: bool = True,
        context_id: str | None = None,
    ) -> Any:
        return self.timed_call(
            label, tool, payload, timeout=timeout, check=check, context_id=context_id
        ).response

    def timed_call(
        self,
        label: str,
        tool: str,
        payload: dict[str, Any],
        *,
        timeout: float = 300,
        check: bool = True,
        context_id: str | None = None,
    ) -> TimedCall:
        routed = dict(payload)
        routed.setdefault("_windowID", self.window_id)
        payload_context = routed.get("context_id")
        target_context = validate_uuid(
            context_id or (payload_context if isinstance(payload_context, str) else self.context_id),
            "context-id",
        )
        payload_json = json.dumps(routed, separators=(",", ":"), sort_keys=True)
        command_text = (
            f"bind_context op=bind context_id={target_context} && "
            f"call {tool} {payload_json}"
        )
        command = [
            str(self.cli), "--raw-json", "-w", str(self.window_id), "-e", command_text,
        ]
        started_ns = time.monotonic_ns()
        try:
            process = subprocess.run(command, cwd=self.cwd, text=True, capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired as error:
            finished_ns = time.monotonic_ns()

            def partial_text(value: str | bytes | None) -> str:
                if value is None:
                    return ""
                return value.decode(errors="replace") if isinstance(value, bytes) else value

            record = {
                "label": label,
                "tool": tool,
                "started_at": utc_now(),
                "started_monotonic_ns": started_ns,
                "finished_monotonic_ns": finished_ns,
                "timed_out": True,
                "timeout_seconds": timeout,
                "preparation_id": routed.get("preparation_id"),
                "returncode": None,
                "stdout": partial_text(error.stdout),
                "stderr": partial_text(error.stderr),
            }
            if self.artifact:
                with self.lock:
                    ordinal = self.ordinal
                    self.ordinal += 1
                    save_json(
                        self.artifact / "raw" / f"{ordinal:04d}-{safe_name(label)}.json",
                        record,
                        exclusive=True,
                    )
                    append_ndjson(self.artifact / "raw-cli-calls.ndjson", record)
            raise
        finished_ns = time.monotonic_ns()
        record = {
            "label": label,
            "tool": tool,
            "started_at": utc_now(),
            "started_monotonic_ns": started_ns,
            "finished_monotonic_ns": finished_ns,
            "timed_out": False,
            "timeout_seconds": timeout,
            "preparation_id": routed.get("preparation_id"),
            "returncode": process.returncode,
            "stdout": process.stdout,
            "stderr": process.stderr,
        }
        if self.artifact:
            with self.lock:
                ordinal = self.ordinal
                self.ordinal += 1
                save_json(self.artifact / "raw" / f"{ordinal:04d}-{safe_name(label)}.json", record, exclusive=True)
                append_ndjson(self.artifact / "raw-cli-calls.ndjson", record)
        if check and process.returncode:
            raise BenchmarkError(f"{label} failed ({process.returncode}): {process.stderr.strip()}")
        output_error: str | None = None
        try:
            binding, final_response = parse_atomic_cli_output(
                process.stdout,
                expected_context_id=target_context,
                expected_window_id=self.window_id,
            )
        except BenchmarkError as error:
            if check:
                raise BenchmarkError(f"{label}: {error}") from error
            binding, final_response = None, {}
            output_error = str(error)
        output_valid = output_error is None
        response: Any = {
            "_benchmark_response": final_response,
            "_benchmark_binding": binding,
            "_benchmark_requested_context_id": target_context,
            "_benchmark_payload": routed,
            "_benchmark_tool": tool,
            "_benchmark_started_monotonic_ns": started_ns,
            "_benchmark_finished_monotonic_ns": finished_ns,
            "_benchmark_binding_valid": output_valid,
            "_benchmark_output_valid": output_valid,
        }
        if output_error is not None:
            response["_benchmark_output_error"] = output_error
        if not check and process.returncode:
            response["_benchmark_cli_returncode"] = process.returncode
            response["_benchmark_stderr"] = process.stderr
        return TimedCall(response, started_ns, finished_ns, process.returncode)

    def describe(self, tool: str) -> str:
        process = subprocess.run(
            [str(self.cli), "describe", tool], cwd=self.cwd, text=True, capture_output=True, timeout=60
        )
        if process.returncode:
            raise BenchmarkError(f"describe {tool} failed: {process.stderr.strip()}")
        return process.stdout


def make_artifact(output_root: Path, label: str) -> Path:
    output_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    artifact = output_root / f"{stamp}-{safe_name(label)}-{uuid.uuid4().hex[:8]}"
    artifact.mkdir(mode=0o700)
    return artifact


def plan_command(args: argparse.Namespace) -> int:
    root = Path(args.root_path).expanduser().resolve(strict=True)
    read_path = Path(args.read_path)
    if read_path.is_absolute() or ".." in read_path.parts:
        raise BenchmarkError("read-path must be root-relative and remain inside the root")
    if not args.workspace_name.startswith(WORKSPACE_PREFIXES):
        allowed = ", ".join(repr(prefix) for prefix in WORKSPACE_PREFIXES)
        raise BenchmarkError(f"workspace-name must start with one of: {allowed}")
    real_repository = args.confirm_real_repository_benchmark
    tracked_files = run_local(["git", "ls-files", "-z"], root).stdout.count("\0")
    if real_repository:
        if root != repository_root().resolve() or not args.confirm_dedicated_workspace:
            raise BenchmarkError(
                "real-repository benchmarking requires this exact checkout plus --confirm-dedicated-workspace"
            )
        if args.asserted_file_count != tracked_files:
            raise BenchmarkError(
                f"asserted-file-count must equal observed tracked count {tracked_files} for the real repository"
            )
    elif args.asserted_file_count < 100_000:
        raise BenchmarkError("disposable large-workspace asserted-file-count must be at least 100000")
    if args.retained_samples != FIXED_RETAINED_SAMPLES:
        raise BenchmarkError("readiness plans require exactly five retained samples")
    if args.warmups != FIXED_WARMUPS:
        raise BenchmarkError("readiness plans require exactly one excluded warmup")
    if args.invocations_per_series < 1:
        raise BenchmarkError("invocations-per-series must be at least 1")
    base_commit_oid = resolve_commit_oid(root, args.base_ref)
    read_blob_sha256 = validate_tracked_read_fixture(
        root, base_ref=base_commit_oid, read_path=str(read_path),
        search_marker=args.search_marker, read_marker=args.read_marker,
    )
    marker_path, marker, marker_sha256 = validate_ownership_marker(
        root,
        workspace_id=validate_uuid(args.workspace_id, "workspace-id"),
        root_id=validate_uuid(args.root_id, "root-id"),
        owner_token=validate_uuid(args.owner_token, "owner-token"),
        allow_real_repository=real_repository,
    )
    owner_token = marker["owner_token"]
    plan: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "created_at": utc_now(),
        "scope": {
            "workspace_name": args.workspace_name,
            "window_id": args.window_id,
            "workspace_id": validate_uuid(args.workspace_id, "workspace-id"),
            "context_id": validate_uuid(args.context_id, "context-id"),
            "root_id": validate_uuid(args.root_id, "root-id"),
            "root_path": str(root),
            "target_kind": "real-repository-dedicated" if real_repository else "disposable-fixture",
            "explicit_real_repository_confirmation": real_repository,
            "ownership_marker": str(marker_path),
            "ownership_marker_sha256": marker_sha256,
            "owner_token": owner_token,
        },
        "dataset": {
            "label": args.dataset_label,
            "asserted_file_count": args.asserted_file_count,
            "observed_tracked_file_count": tracked_files,
            "base_ref": args.base_ref,
            "base_commit_oid": base_commit_oid,
            "search_marker": args.search_marker,
            "read_path": str(read_path),
            "read_marker": args.read_marker,
            "read_blob_sha256": read_blob_sha256,
            "code_file_type": args.code_file_type,
        },
        "matrix": {
            "process_states": ["warm", "aged"],
            "checkout_kinds": ["linked-worktree"],
            "routes": list(ROUTES),
            "widths": [1, 4, 8],
            "warmups_per_series": args.warmups,
            "retained_samples_per_series": args.retained_samples,
            "invocations_per_series": args.invocations_per_series,
            "automated_scenarios": AUTOMATED_SCENARIOS,
            "correctness_scenarios": CORRECTNESS_SCENARIOS,
            "required_external_evidence": [
                "cold-main-workspace-open-root-ready",
                "main-checkout-cold-warm-root-search-read",
                "fresh-process-provenance",
                "aged-process-session-and-thread-inventory",
                "host-sleep-and-thermal-validity",
            ],
        },
        "thresholds": {
            "correctness_mismatches": 0,
            "eligible_warm_fallbacks": 0,
            "projected_p95_improvement_minimum": 0.30,
            "other_p95_regression_maximum": 0.10,
            "peak_memory_regression_maximum": 0.10,
        },
        "synthetic_hooks": {
            "routine_entries": 100_000,
            "opt_in_entries": 1_000_000,
            "environment": "REPOPROMPT_NAMESPACE_MANIFEST_SCALE_ENTRY_COUNT",
            "test_filter": "RepoPromptTests.WorkspaceRootNamespaceManifestTests/testSyntheticHundredThousandEntriesRemainWithinConfiguredBatchBytes",
        },
        "scoreboard": "prompt-exports/optimize-worktree-interactive-readiness-runs.md",
    }
    plan["plan_sha256"] = plan_digest(plan)
    output = Path(args.output).expanduser().resolve()
    save_json(output, plan, exclusive=True)
    print(output)
    return 0


def record_evidence_command(args: argparse.Namespace) -> int:
    plan = load_plan(Path(args.plan).expanduser().resolve(strict=True))
    required = set(plan["matrix"]["required_external_evidence"])
    if args.scenario not in required:
        raise BenchmarkError(f"scenario must be one of {sorted(required)}")
    details: dict[str, Any] = {}
    if args.details:
        value = json.loads(Path(args.details).expanduser().resolve(strict=True).read_text(encoding="utf-8"))
        if not isinstance(value, dict):
            raise BenchmarkError("details must contain one JSON object")
        details = value
    evidence = {
        "schema_version": SCHEMA_VERSION,
        "plan_sha256": plan["plan_sha256"],
        "scenario": args.scenario,
        "status": args.status,
        "recorded_at": utc_now(),
        "details": details,
    }
    output = Path(args.output).expanduser().resolve()
    save_json(output, evidence, exclusive=True)
    print(output)
    return 0


def self_test_command(_args: argparse.Namespace) -> int:
    checks: dict[str, bool] = {}
    with tempfile.TemporaryDirectory(prefix="rpce-worktree-benchmark-self-test-") as raw:
        root = Path(raw).resolve()
        workspace_id = str(uuid.uuid4()).upper()
        root_id = str(uuid.uuid4()).upper()
        owner_token = str(uuid.uuid4()).upper()
        marker = {
            "schema_version": SCHEMA_VERSION,
            "purpose": "rpce-worktree-startup-live-benchmark",
            "disposable": True,
            "target_kind": "disposable-fixture",
            "workspace_id": workspace_id,
            "root_id": root_id,
            "canonical_root": str(root),
            "owner_token": owner_token,
            "created_at": utc_now(),
        }
        save_json(ownership_marker_path(root), marker, exclusive=True)
        _, _, marker_digest = validate_ownership_marker(
            root, workspace_id=workspace_id, root_id=root_id, owner_token=owner_token
        )
        checks["ownership_marker"] = len(marker_digest) == 64
        run_local(["git", "init", "-q"], root)
        tracked_fixture = root / "tracked-marker.swift"
        tracked_fixture.write_text(
            "// RPCE_TRACKED_SEARCH\nlet RPCE_TRACKED_READ = true\n", encoding="utf-8"
        )
        bad_fixture = root / "tracked-bad.swift"
        bad_fixture.write_text("// RPCE_TRACKED_SEARCH\n", encoding="utf-8")
        run_local(["git", "add", tracked_fixture.name, bad_fixture.name], root)
        run_local([
            "git", "-c", "user.name=RPCE Harness", "-c", "user.email=harness@example.invalid",
            "commit", "-q", "-m", "self-test fixture",
        ], root)
        planned_oid = resolve_commit_oid(root, "HEAD")
        oid_plan = {"dataset": {"base_ref": "HEAD", "base_commit_oid": planned_oid}}
        checks["immutable_base_oid_resolved"] = (
            validate_planned_base_commit(oid_plan, root) == planned_oid
        )
        tracked_digest = validate_tracked_read_fixture(
            root, base_ref="HEAD", read_path=tracked_fixture.name,
            search_marker="RPCE_TRACKED_SEARCH", read_marker="RPCE_TRACKED_READ",
        )
        tracked_fixture.write_text("working tree content is intentionally irrelevant\n", encoding="utf-8")
        checks["tracked_fixture_exact_base_ref"] = tracked_digest == validate_tracked_read_fixture(
            root, base_ref="HEAD", read_path=tracked_fixture.name,
            search_marker="RPCE_TRACKED_SEARCH", read_marker="RPCE_TRACKED_READ",
        )
        (root / "untracked-marker.swift").write_text(
            "// RPCE_TRACKED_SEARCH\nlet RPCE_TRACKED_READ = true\n", encoding="utf-8"
        )
        try:
            validate_tracked_read_fixture(
                root, base_ref="HEAD", read_path="untracked-marker.swift",
                search_marker="RPCE_TRACKED_SEARCH", read_marker="RPCE_TRACKED_READ",
            )
            checks["untracked_fixture_rejected"] = False
        except BenchmarkError:
            checks["untracked_fixture_rejected"] = True
        try:
            validate_tracked_read_fixture(
                root, base_ref="HEAD", read_path=bad_fixture.name,
                search_marker="RPCE_TRACKED_SEARCH", read_marker="RPCE_TRACKED_READ",
            )
            checks["tracked_fixture_missing_marker_rejected"] = False
        except BenchmarkError:
            checks["tracked_fixture_missing_marker_rejected"] = True
        (root / "drift.txt").write_text("drift\n", encoding="utf-8")
        run_local(["git", "add", "drift.txt"], root)
        run_local([
            "git", "-c", "user.name=RPCE Harness", "-c", "user.email=harness@example.invalid",
            "commit", "-q", "-m", "move symbolic ref",
        ], root)
        try:
            validate_planned_base_commit(oid_plan, root)
            checks["moving_symbolic_base_rejected"] = False
        except BenchmarkError:
            checks["moving_symbolic_base_rejected"] = True

    correlation = str(uuid.uuid4()).upper()
    session = str(uuid.uuid4()).upper()
    context_id = str(uuid.uuid4()).upper()
    fixture_root = Path("/tmp/rpce-benchmark-structured-fixture").resolve()
    fixture_file = fixture_root / "Fixture.swift"
    fixture_root_id = str(uuid.uuid4()).upper()
    fixture_root_record = {
        "id": fixture_root_id, "path": str(fixture_root), "type": "linkedWorktree",
    }
    marker = "RPCE_STRUCTURED_FIXTURE"

    def tool_record(tool: str, *, status: str = "ok") -> dict[str, Any]:
        base: dict[str, Any] = {"tool": tool, "status": status, "root": fixture_root_record}
        if tool == "file_search":
            base.update({
                "matches": [{"path": str(fixture_file), "type": "file", "content": marker}],
                "total_matches": 1,
            })
        elif tool == "read_file":
            base.update({"path": str(fixture_file), "file_type": "file", "content": marker})
        elif tool == "manage_selection":
            base["files"] = [{"path": str(fixture_file), "type": "file"}]
        else:
            base["files"] = [{"path": str(fixture_file), "type": "swift", "content": marker}]
        return base

    search_record = tool_record("file_search")
    read_record = tool_record("read_file")
    transcript = "".join((
        '<tool_call name="mcp__file_search">',
        html.escape(json.dumps({
            "pattern": marker, "regex": False,
            "filter": {"paths": [str(fixture_file)]},
        })),
        "</tool_call>",
        '<tool_result name="mcp__file_search"/>',
        '<tool_call name="mcp__read_file">',
        html.escape(json.dumps({"path": str(fixture_file)})), "</tool_call>",
        '<tool_result name="mcp__read_file"/>',
        "<assistant>RPCE_INHERITED_CHILD_OK</assistant>",
    ))
    transcript_evidence = verify_agent_file_tool_transcript(
        transcript, expected_output="RPCE_INHERITED_CHILD_OK", expected_marker=marker,
        expected_file_path=str(fixture_file),
    )
    checks["nested_spartan_tool_events"] = (
        transcript_evidence["call_count"] == 2
        and transcript_evidence["reported_result_status_count"] == 0
    )
    fixture_worktree_id = "wt-transcript-fixture"
    fixture_worktree_path = Path("/tmp/rpce-transcript-physical").resolve()
    worktree_scope = {
        "kind": "session_bound_worktree",
        "display_identity": "logical_canonical_root",
        "effective_identity": "bound_worktree_root",
        "root_mappings": [{
            "worktree_id": fixture_worktree_id,
            "logical_root_path": str(fixture_root),
            "effective_root_path": str(fixture_worktree_path),
        }],
    }
    structured_search_record = dict(search_record, worktree_scope=worktree_scope)
    structured_read_record = dict(read_record, worktree_scope=worktree_scope)
    strict_transcript = "".join((
        '<tool_call name="mcp__file_search">',
        html.escape(json.dumps({
            "pattern": marker, "regex": False,
            "filter": {"paths": [str(fixture_file)]},
        })),
        "</tool_call>",
        '<tool_result name="mcp__file_search">',
        html.escape(json.dumps(structured_search_record)),
        "</tool_result>",
        '<tool_call name="mcp__read_file">',
        html.escape(json.dumps({"path": str(fixture_file)})),
        "</tool_call>",
        '<tool_result name="mcp__read_file">',
        html.escape(json.dumps(structured_read_record)),
        "</tool_result>",
        "<assistant>RPCE_STRICT_TRANSCRIPT_OK</assistant>",
    ))
    strict_expectations = {
        "root_id": fixture_root_id,
        "root_path": str(fixture_root),
        "root_type": "linkedWorktree",
        "worktree_id": fixture_worktree_id,
        "worktree_path": str(fixture_worktree_path),
        "read_marker": marker,
    }
    strict_evidence = verify_agent_file_tool_transcript(
        strict_transcript,
        expected_output="RPCE_STRICT_TRANSCRIPT_OK",
        expected_marker=marker,
        expected_file_path=str(fixture_file),
        strict_result_expectations=strict_expectations,
    )
    checks["strict_transcript_structured_results_accepted"] = (
        len(strict_evidence["structured_result_evidence"]) == 2
    )
    try:
        verify_agent_file_tool_transcript(
            transcript,
            expected_output="RPCE_INHERITED_CHILD_OK",
            expected_marker=marker,
            expected_file_path=str(fixture_file),
            strict_result_expectations=strict_expectations,
        )
        checks["strict_transcript_spartan_results_rejected"] = False
    except BenchmarkError:
        checks["strict_transcript_spartan_results_rejected"] = True
    parent_transcript = "".join([
        "".join((
            '<tool_call name="mcp__file_search">',
            html.escape(json.dumps({
                "pattern": marker, "regex": False,
                "filter": {"paths": [str(fixture_file)]},
            })),
            "</tool_call>",
            '<tool_result name="mcp__file_search"/>',
            '<tool_call name="mcp__read_file">',
            html.escape(json.dumps({"path": str(fixture_file)})), "</tool_call>",
            '<tool_result name="mcp__read_file"/>',
        ))
        for _ in range(10)
    ]) + "<assistant>RPCE_ACTIVE_PARENT_OK</assistant>"
    parent_transcript_evidence = verify_agent_file_tool_transcript(
        parent_transcript, expected_output="RPCE_ACTIVE_PARENT_OK", expected_marker=marker,
        expected_file_path=str(fixture_file), expected_pairs=10,
    )
    checks["parent_exact_twenty_alternating_calls"] = (
        parent_transcript_evidence["call_count"] == 20
        and parent_transcript_evidence["search_call_count"] == 10
        and parent_transcript_evidence["read_call_count"] == 10
    )
    try:
        verify_agent_file_tool_transcript(
            parent_transcript.replace(
                "<assistant>", '<tool_call name="Bash">{}</tool_call><assistant>', 1
            ),
            expected_output="RPCE_ACTIVE_PARENT_OK", expected_marker=marker,
            expected_file_path=str(fixture_file), expected_pairs=10,
        )
        checks["parent_substitute_tool_rejected"] = False
    except BenchmarkError:
        checks["parent_substitute_tool_rejected"] = True
    try:
        parse_agent_transcript_records(
            '<tool_call tool="Bash">{}</tool_call><assistant>RPCE_ACTIVE_PARENT_OK</assistant>'
        )
        checks["malformed_tool_event_rejected"] = False
    except BenchmarkError:
        checks["malformed_tool_event_rejected"] = True
    try:
        parse_agent_transcript_records(
            '<shell_call name="Bash">{}</shell_call><assistant>RPCE_ACTIVE_PARENT_OK</assistant>'
        )
        checks["substitute_event_encoding_rejected"] = False
    except BenchmarkError:
        checks["substitute_event_encoding_rejected"] = True
    try:
        verify_agent_file_tool_transcript(
            "<assistant>file_search read_file RPCE_INHERITED_CHILD_OK</assistant>",
            expected_output="RPCE_INHERITED_CHILD_OK", expected_marker=marker,
            expected_file_path=str(fixture_file),
        )
        checks["nested_prompt_text_rejected"] = False
    except BenchmarkError:
        checks["nested_prompt_text_rejected"] = True

    fixture_context = str(uuid.uuid4()).upper()
    atomic_binding_document = {
        "binding": {"context_id": fixture_context, "window_id": 1, "repo_paths": [str(fixture_root)]}
    }
    atomic_result_document = {"status": "ok"}
    atomic_stdout = (
        json.dumps(atomic_binding_document) + "\n\n---\n\n" + json.dumps(atomic_result_document)
    )
    parsed_binding, parsed_result = parse_atomic_cli_output(
        atomic_stdout, expected_context_id=fixture_context, expected_window_id=1
    )
    checks["atomic_exact_two_documents"] = (
        parsed_binding == atomic_binding_document["binding"]
        and parsed_result == atomic_result_document
    )
    for name, stdout in {
        "atomic_extra_document_rejected": atomic_stdout + "\n\n---\n\n{}",
        "atomic_reordered_documents_rejected": (
            json.dumps(atomic_result_document) + "\n\n---\n\n" + json.dumps(atomic_binding_document)
        ),
        "atomic_missing_result_rejected": json.dumps(atomic_binding_document),
    }.items():
        try:
            parse_atomic_cli_output(
                stdout, expected_context_id=fixture_context, expected_window_id=1
            )
            checks[name] = False
        except BenchmarkError:
            checks[name] = True
    parent_context_fixture = str(uuid.uuid4()).upper()
    child_context_fixture = str(uuid.uuid4()).upper()
    worktree_binding_fixture = {
        "worktree_id": "wt_fixture", "worktree_root_path": str(fixture_root),
    }
    parent_start_fixture = {
        "session": {"context_id": parent_context_fixture},
        "worktree_bindings": [worktree_binding_fixture],
    }
    child_start_fixture = {
        "session": {"context_id": child_context_fixture},
        "worktree_bindings": [worktree_binding_fixture],
    }
    checks["child_distinct_context_exact_binding_set"] = child_inheritance_evidence(
        parent_start_fixture, child_start_fixture,
        parent_context_id=parent_context_fixture, parent_worktree_path=str(fixture_root),
    )["ok"]
    same_context_child = json.loads(json.dumps(child_start_fixture))
    same_context_child["session"]["context_id"] = parent_context_fixture
    checks["child_same_context_rejected"] = not child_inheritance_evidence(
        parent_start_fixture, same_context_child,
        parent_context_id=parent_context_fixture, parent_worktree_path=str(fixture_root),
    )["ok"]
    different_binding_child = json.loads(json.dumps(child_start_fixture))
    different_binding_child["worktree_bindings"][0]["worktree_id"] = "wt_other"
    checks["child_binding_id_mismatch_rejected"] = not child_inheritance_evidence(
        parent_start_fixture, different_binding_child,
        parent_context_id=parent_context_fixture, parent_worktree_path=str(fixture_root),
    )["ok"]

    def routed_response(
        response: dict[str, Any],
        *,
        roots: list[str] | None = None,
        payload: dict[str, Any] | None = None,
        returncode: int | None = None,
        stderr: str | None = None,
    ) -> dict[str, Any]:
        result: dict[str, Any] = {
            "_benchmark_response": response,
            "_benchmark_binding": {
                "context_id": fixture_context, "window_id": 1,
                "repo_paths": roots if roots is not None else [str(fixture_root)],
            },
            "_benchmark_requested_context_id": fixture_context,
            "_benchmark_binding_valid": True,
            "_benchmark_output_valid": True,
            "_benchmark_payload": payload or {},
        }
        if returncode is not None:
            result["_benchmark_cli_returncode"] = returncode
        if stderr is not None:
            result["_benchmark_stderr"] = stderr
        return result

    workspace_fixture_id = str(uuid.uuid4()).upper()
    workspace_wrapper = routed_response({
        "workspaces": [{
            "id": workspace_fixture_id, "name": "planned-workspace",
            "repo_paths": [str(fixture_root)],
        }],
    })
    workspace_wrapper["_benchmark_binding"]["workspace_id"] = workspace_fixture_id
    checks["workspace_inventory_ignores_atomic_binding"] = (
        workspace_inventory_record(workspace_wrapper, workspace_fixture_id).get("name")
        == "planned-workspace"
    )
    scope_wrapper = routed_response({
        "scope": {
            "window_id": 1, "workspace_id": workspace_fixture_id,
            "context_id": fixture_context, "root_id": fixture_root_id,
        },
    })
    scope_wrapper["_benchmark_binding"]["root_id"] = str(uuid.uuid4()).upper()
    checks["scope_ignores_atomic_binding"] = (
        scope_response_record(scope_wrapper).get("root_id") == fixture_root_id
    )

    actual_search = routed_response({
        "total_matches": 1, "total_files": 1, "matched_files": 1,
        "searched_files": 1, "content_matches": 1, "path_matches": 0,
        "limit_hit": False, "content_match_groups": [{
            "path": f"{fixture_root.name}/{fixture_file.name}",
            "lines": [{"line_number": 1, "line_text": marker}],
        }],
    }, payload={
        "pattern": marker, "regex": False,
        "filter": {"paths": [str(fixture_file)]},
    })
    actual_read = routed_response({
        "content": marker, "display_path": f"{fixture_root.name}/{fixture_file.name}",
        "first_line": 1, "last_line": 1, "total_lines": 1,
    }, payload={"path": str(fixture_file)})
    actual_selection = routed_response({
        "status": "ok", "total_tokens": 1, "files": [{
            "path": f"{fixture_root.name}/{fixture_file.name}",
            "root_path": str(fixture_root), "path_within_root": fixture_file.name,
            "tokens": 1, "render_mode": "full",
        }],
    })
    actual_structure = routed_response({
        "status": "success", "files": [{
            "path": f"{fixture_root.name}/{fixture_file.name}",
            "content": marker, "role": "seed", "tokens": 1,
        }],
        "summary": {"requested_seeds": 1, "resolved_seeds": 1, "returned_files": 1},
        "issues": [],
    }, payload={"scope": "paths", "paths": [str(fixture_file)]})
    tree_fixture_text = (
        f"{fixture_root.name}\n"
        f"└── {fixture_file.name} +\n\n{CODEMAP_TREE_LEGEND}"
    )
    actual_tree = routed_response({
        "tree": tree_fixture_text, "text": tree_fixture_text,
        "uses_legend": True, "was_truncated": False,
    }, payload={"type": "files", "mode": "full", "path": ".", "max_depth": 1})
    physical_worktree_fixture = Path("/tmp/rpce-app-managed/session-bound-worktree")
    worktree_scope_fixture = {
        "kind": "session_bound_worktree",
        "display_identity": "logical_canonical_root",
        "effective_identity": "bound_worktree_root",
        "root_mappings": [{
            "logical_root_name": fixture_root.name,
            "logical_root_path": fixture_root.name,
            "effective_root_name": physical_worktree_fixture.name,
            "effective_root_path": "session-bound",
            "worktree_id": "wt_exact_fixture",
        }],
    }
    scoped_search = json.loads(json.dumps(actual_search))
    scoped_search["_benchmark_response"]["worktree_scope"] = worktree_scope_fixture
    checks["logical_display_exact_physical_scope_accepted"] = structured_success_evidence(
        scoped_search, "file_search", expected_root_id=fixture_root_id,
        expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
        expected_file_path=str(fixture_file), expected_file_type="file", expected_content=marker,
        expected_worktree_id="wt_exact_fixture",
        expected_physical_worktree_path=str(physical_worktree_fixture),
    )["ok"]
    wrong_scope = json.loads(json.dumps(scoped_search))
    wrong_scope["_benchmark_response"]["worktree_scope"]["root_mappings"][0]["worktree_id"] = "wt_wrong"
    checks["logical_display_wrong_physical_scope_rejected"] = not structured_success_evidence(
        wrong_scope, "file_search", expected_root_id=fixture_root_id,
        expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
        expected_file_path=str(fixture_file), expected_file_type="file", expected_content=marker,
        expected_worktree_id="wt_exact_fixture",
        expected_physical_worktree_path=str(physical_worktree_fixture),
    )["ok"]
    checks["tree_exact_context_parent_full_path"] = codemap_tree_marker_evidence(
        actual_tree, expected_context_id=fixture_context,
        expected_root_path=str(fixture_root), requested_parent=".",
        expected_file_path=fixture_file.name,
    )["marker_present"]
    wrong_parent_tree = json.loads(json.dumps(actual_tree))
    wrong_parent_tree["_benchmark_payload"]["path"] = "other-parent"
    try:
        codemap_tree_marker_evidence(
            wrong_parent_tree, expected_context_id=fixture_context,
            expected_root_path=str(fixture_root), requested_parent=".",
            expected_file_path=fixture_file.name,
        )
        checks["tree_same_basename_wrong_parent_rejected"] = False
    except BenchmarkError:
        checks["tree_same_basename_wrong_parent_rejected"] = True
    checks["actual_file_search_shape"] = structured_success_evidence(
        actual_search, "file_search", expected_root_id=fixture_root_id,
        expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
        expected_file_path=str(fixture_file), expected_file_type="file", expected_content=marker,
    )["ok"]
    checks["actual_read_file_shape"] = structured_success_evidence(
        actual_read, "read_file", expected_root_id=fixture_root_id,
        expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
        expected_file_path=str(fixture_file), expected_file_type="file", expected_content=marker,
    )["ok"]
    checks["actual_selection_shape"] = structured_success_evidence(
        actual_selection, "manage_selection", expected_root_id=fixture_root_id,
        expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
        expected_file_path=str(fixture_file), expected_file_type="file",
    )["ok"]
    checks["actual_code_structure_shape"] = structured_success_evidence(
        actual_structure, "get_code_structure", expected_root_id=fixture_root_id,
        expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
        expected_file_path=str(fixture_file), expected_file_type="swift", expected_content=marker,
    )["ok"]
    selected_structure = dict(actual_structure)
    selected_structure["_benchmark_payload"] = {"scope": "selected"}
    checks["actual_selected_code_structure_shape"] = structured_success_evidence(
        selected_structure, "get_code_structure", expected_root_id=fixture_root_id,
        expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
        expected_file_path=str(fixture_file), expected_file_type="swift", expected_content=marker,
    )["ok"]
    wrong_binding = dict(actual_search)
    wrong_binding["_benchmark_binding"] = dict(
        actual_search["_benchmark_binding"], repo_paths=["/tmp/another-root"]
    )
    checks["actual_cross_root_binding_rejected"] = not structured_success_evidence(
        wrong_binding, "file_search", expected_root_id=fixture_root_id,
        expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
        expected_file_path=str(fixture_file), expected_file_type="file", expected_content=marker,
    )["ok"]
    duplicate_name_root = Path("/var/tmp") / fixture_root.name
    ambiguous_search = json.loads(json.dumps(actual_search))
    ambiguous_search["_benchmark_binding"]["repo_paths"] = [
        str(fixture_root), str(duplicate_name_root),
    ]
    checks["ambiguous_same_basename_result_rejected"] = not structured_success_evidence(
        ambiguous_search, "file_search", expected_root_id=fixture_root_id,
        expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
        expected_file_path=str(fixture_file), expected_file_type="file", expected_content=marker,
    )["ok"]
    unattributed_search = json.loads(json.dumps(actual_search))
    unattributed_search["_benchmark_binding"]["repo_paths"] = [
        str(fixture_root), "/var/tmp/another-root",
    ]
    unattributed_search["_benchmark_response"]["content_match_groups"][0]["path"] = fixture_file.name
    checks["unattributed_relative_result_rejected"] = not structured_success_evidence(
        unattributed_search, "file_search", expected_root_id=fixture_root_id,
        expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
        expected_file_path=str(fixture_file), expected_file_type="file", expected_content=marker,
    )["ok"]
    actual_empty = routed_response({
        "total_matches": 0, "total_files": 0, "matched_files": 0,
        "searched_files": 1, "content_matches": 0, "path_matches": 0,
        "limit_hit": False, "content_match_groups": [],
    }, payload={"pattern": "OTHER_ROOT_MARKER", "regex": False,
                "filter": {"paths": [str(fixture_root)]}})
    checks["actual_empty_cross_root_shape"] = structured_empty_success_evidence(
        actual_empty, "file_search", expected_root_id=fixture_root_id,
        expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
    )["ok"]

    exact_selection = require_structured_success(
        tool_record("manage_selection"), "manage_selection",
        expected_root_id=fixture_root_id, expected_root_path=str(fixture_root),
        expected_root_type="linkedWorktree", expected_file_path=str(fixture_file),
        expected_file_type="file",
    )
    checks["structured_exact_root"] = exact_selection["root"] == fixture_root_record
    wrong_root = tool_record("get_code_structure")
    wrong_root["root"] = dict(fixture_root_record, id=str(uuid.uuid4()).upper())
    checks["structured_cross_root_rejected"] = not structured_success_evidence(
        wrong_root, "get_code_structure", expected_root_id=fixture_root_id,
        expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
        expected_file_path=str(fixture_file), expected_file_type="swift",
        expected_content=marker,
    )["ok"]
    removed_record = {
        "tool": "get_code_structure", "status": "unavailable", "root": fixture_root_record,
        "files": [], "issue": {"code": "git_root_unavailable"},
    }
    checks["structured_non_git_typed_status"] = structured_removed_evidence(
        removed_record, "get_code_structure", expected_root_id=fixture_root_id,
        expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
    )["ok"]
    removed_search = {
        "tool": "file_search", "status": "removed", "root": fixture_root_record,
        "matches": [], "total_matches": 0, "issue": {"code": "root_removed"},
    }
    checks["removed_root_typed_success"] = structured_removed_evidence(
        removed_search, "file_search", expected_root_id=fixture_root_id,
        expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
    )["ok"]
    removed_read = {
        "tool": "read_file", "status": "not_found", "root": fixture_root_record,
        "files": [], "issue": {"code": "root_not_found"},
    }
    checks["removed_read_typed_success"] = structured_removed_evidence(
        removed_read, "read_file", expected_root_id=fixture_root_id,
        expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
    )["ok"]
    checks["removed_root_transport_failure_rejected"] = not structured_removed_evidence(
        {"_benchmark_cli_returncode": 1, "_benchmark_response": removed_search},
        "file_search", expected_root_id=fixture_root_id,
        expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
    )["ok"]
    removed_search_actual = routed_response({
        "total_matches": 0, "total_files": 0, "matched_files": 0,
        "searched_files": 0, "content_matches": 0, "path_matches": 0,
        "limit_hit": False, "content_match_groups": [],
    }, roots=[], payload={
        "pattern": marker, "regex": False, "filter": {"paths": [str(fixture_file)]},
    })
    checks["actual_removed_search_shape"] = structured_removed_evidence(
        removed_search_actual, "file_search", expected_root_id=fixture_root_id,
        expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
        expected_file_path=str(fixture_file), require_absent_bound_root=True,
    )["ok"]
    removed_structure_actual = routed_response({
        "status": "unavailable", "files": [],
        "issues": [{"code": "path_not_found", "phase": "seed_resolution"}],
        "summary": {"requested_seeds": 0, "resolved_seeds": 0, "returned_files": 0},
    }, roots=[], payload={"scope": "paths", "paths": [str(fixture_file)]})
    checks["actual_removed_structure_shape"] = structured_removed_evidence(
        removed_structure_actual, "get_code_structure", expected_root_id=fixture_root_id,
        expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
        expected_file_path=str(fixture_file), require_absent_bound_root=True,
    )["ok"]
    removed_structure_bound = dict(removed_structure_actual)
    removed_structure_bound["_benchmark_binding"] = dict(
        removed_structure_actual["_benchmark_binding"], repo_paths=[str(fixture_root)]
    )
    checks["removed_structure_bound_root_rejected"] = not structured_removed_evidence(
        removed_structure_bound, "get_code_structure", expected_root_id=fixture_root_id,
        expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
        expected_file_path=str(fixture_file), require_absent_bound_root=True,
    )["ok"]
    linked_active_fixture = {"ok": True, "status": "running"}
    checks["linked_root_active_then_revoked_terminal"] = linked_root_removal_evidence(
        linked_active_fixture, "cancelled", {"ok": True}
    )["ok"]
    checks["linked_root_early_completion_rejected"] = not linked_root_removal_evidence(
        {"ok": False, "status": "completed"}, "completed", {"ok": True}
    )["ok"]
    checks["linked_root_cross_root_fallback_rejected"] = not linked_root_removal_evidence(
        linked_active_fixture, "failed", {"ok": False, "reason": "fallback_files"}
    )["ok"]
    enriched_removed_structure = routed_response({
        "tool": "get_code_structure", "status": "unavailable",
        "root": fixture_root_record, "files": [],
        "issue": {"code": "path_not_found"},
    }, roots=[], payload={"scope": "paths", "paths": [str(fixture_file)]})
    checks["enriched_removed_structure_absent_root"] = structured_removed_evidence(
        enriched_removed_structure, "get_code_structure", expected_root_id=fixture_root_id,
        expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
        expected_file_path=str(fixture_file), require_absent_bound_root=True,
    )["ok"]
    enriched_removed_bound = json.loads(json.dumps(enriched_removed_structure))
    enriched_removed_bound["_benchmark_binding"]["repo_paths"] = [str(fixture_root)]
    checks["enriched_removed_structure_bound_root_rejected"] = not structured_removed_evidence(
        enriched_removed_bound, "get_code_structure", expected_root_id=fixture_root_id,
        expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
        expected_file_path=str(fixture_file), require_absent_bound_root=True,
    )["ok"]
    for tool, status, issue_code, files_key, request_payload in (
        (
            "file_search", "removed", "root_removed", "matches",
            {"pattern": marker, "regex": False, "filter": {"paths": [str(fixture_file)]}},
        ),
        (
            "read_file", "not_found", "root_not_found", "files",
            {"path": str(fixture_file)},
        ),
    ):
        enriched_removed = routed_response({
            "tool": tool, "status": status, "root": fixture_root_record,
            files_key: [], "issue": {"code": issue_code},
        }, roots=[], payload=request_payload)
        checks[f"enriched_removed_{tool}_absent_root"] = structured_removed_evidence(
            enriched_removed, tool, expected_root_id=fixture_root_id,
            expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
            expected_file_path=str(fixture_file), require_absent_bound_root=True,
        )["ok"]
        enriched_removed["_benchmark_binding"]["repo_paths"] = [str(fixture_root)]
        checks[f"enriched_removed_{tool}_bound_root_rejected"] = not structured_removed_evidence(
            enriched_removed, tool, expected_root_id=fixture_root_id,
            expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
            expected_file_path=str(fixture_file), require_absent_bound_root=True,
        )["ok"]
    removed_read_actual = routed_response(
        {}, roots=[], payload={"path": str(fixture_file)}, returncode=1,
        stderr=(
            f"Cannot read {str(fixture_file)!r}. The requested path {str(fixture_file)!r} "
            "is not inside any loaded folder in this window."
        ),
    )
    checks["actual_removed_read_shape"] = structured_removed_evidence(
        removed_read_actual, "read_file", expected_root_id=fixture_root_id,
        expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
        expected_file_path=str(fixture_file), require_absent_bound_root=True,
    )["ok"]
    non_git_structure_actual = routed_response({
        "status": "unavailable", "files": [],
        "issues": [{"code": "git_root_unavailable", "phase": "seed_demand"}],
        "summary": {"requested_seeds": 1, "resolved_seeds": 0, "returned_files": 0},
    }, payload={"scope": "paths", "paths": [str(fixture_file)]})
    checks["actual_non_git_structure_shape"] = structured_removed_evidence(
        non_git_structure_actual, "get_code_structure", expected_root_id=fixture_root_id,
        expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
        expected_file_path=str(fixture_file),
    )["ok"]

    def receipt_fixture(route: str) -> dict[str, Any]:
        consumption: dict[str, Any] = {
            "owner_generation_match": "notEvaluated",
            "hint_session_match": "notEvaluated",
            "hint_correlation_match": "notEvaluated",
            "hint_owner_match": "notEvaluated",
            "ownership_reused": False,
            "pending_seeded_preparation_result": None,
        }
        decision: dict[str, Any] = {
            "correlation_id": correlation,
            "ambiguous_or_duplicate": False,
            "terminal_stage": RECEIPT_TERMINAL_STAGE,
            "creation_attempt_count": 0,
            "creation": None,
            "coordinator": {
                "create_result_receipt_count": 0,
                "hint_count": 0,
                "binding_count": 1,
                "hint_keyed_by_created_binding": "notEvaluated",
                "creation_fallback_observed": None,
            },
            "projection": {
                "supplied_hint_count": 0,
                "matched_hint_count": 0,
                "all_hint_keys_matched_bindings": True,
                "validation_fallback": None,
            },
            "consumption": consumption,
        }
        if route == "baseline":
            consumption.update({
                "selected_route": "fullCrawl",
                "full_crawl_performed": True,
                "initial_hint_observation": {"state": "disabled"},
                "final_observation": {"state": "disabled"},
            })
        elif route == "forced-full":
            consumption.update({
                "selected_route": "fullCrawl",
                "full_crawl_performed": True,
                "initial_hint_observation": {
                    "state": "fallback", "fallback_reason": "noReceipt",
                },
                "final_observation": {
                    "state": "fallback", "fallback_reason": "noReceipt",
                },
            })
        else:
            decision.update({
                "creation_attempt_count": 1,
                "creation": {
                    "source_layout_state": "mainCheckout",
                    "destination_eligibility": "eligible",
                    "source_authority_key_digest": "1" * 64,
                    "source_common_directory_digest": "2" * 64,
                    "repository_id_digest": "3" * 64,
                    "repository_namespace_digest": "4" * 64,
                    "requested_prefix_digest": "5" * 64,
                    "current_lease_present": True,
                    "current_lease_current_at_snapshot_lookup": True,
                    "current_snapshot_present": True,
                    "current_snapshot_content_address_valid": True,
                    "current_snapshot_sha256": "6" * 64,
                    "parent_lookup_route": "currentAlias",
                    "parent_lookup_failure": "none",
                    "parent_authority_key_match": "match",
                    "parent_prefix_match": "match",
                    "target_tree_resolution": "succeeded",
                    "witness_requested": True,
                    "witness_started": True,
                    "witness_finished": True,
                    "witness_start_event_id": 100,
                    "witness_end_event_id": 110,
                    "witness_start_event_id_valid": True,
                    "witness_end_event_id_valid": True,
                    "witness_stable_root_available_before_mutation": True,
                    "witness_destination_absent_before_mutation": True,
                    "witness_destination_strict_descendant": True,
                    "witness_stable_root_unchanged_after_initialization": True,
                    "witness_stream_creation_succeeded": True,
                    "witness_activation_flush_completed": True,
                    "witness_activation_callback_barrier_completed": True,
                    "witness_ending_flush_completed": True,
                    "witness_ending_callback_barrier_completed": True,
                    "witness_start_accepted_callback_watermark": 10,
                    "witness_end_accepted_callback_watermark": 12,
                    "witness_accepted_callback_count": 12,
                    # The producer counts every callback event, including events
                    # beyond the closed semantic cut. Only the two classified
                    # events below contribute to the interval evidence.
                    "witness_accepted_event_count": 3,
                    "witness_accepted_destination_event_count": 1,
                    "witness_accepted_non_destination_event_count": 1,
                    "witness_must_scan_sub_dirs": False,
                    "witness_root_changed": False,
                    "witness_user_dropped": False,
                    "witness_kernel_dropped": False,
                    "witness_event_ids_wrapped": False,
                    "witness_event_id_regressed": False,
                    "witness_lifetime_exceeded": False,
                    "witness_gap": False,
                    "witness_drop": False,
                    "witness_overflow": False,
                    "witness_proves_interval": True,
                    "include_copy_requested": True,
                    "include_copy_result_present": False,
                    "include_copy_complete": True,
                    "include_copy_had_failures": False,
                    "target_layout_present": True,
                    "target_layout_linked": True,
                    "target_authority_capture": "succeeded",
                    "common_directory_match": "match",
                    "repository_id_match": "match",
                    "repository_namespace_match": "match",
                    "target_prefix_match": "match",
                    "target_tree_authority_match": "match",
                    "receipt_emitted": True,
                    "outcome": "receiptEmitted",
                    "receipt_fallback_reason": None,
                    "initialization_fallback_reason": None,
                },
                "coordinator": {
                    "create_result_receipt_count": 1,
                    "hint_count": 1,
                    "binding_count": 1,
                    "hint_keyed_by_created_binding": "match",
                    "creation_fallback_observed": None,
                },
                "projection": {
                    "supplied_hint_count": 1,
                    "matched_hint_count": 1,
                    "all_hint_keys_matched_bindings": True,
                    "validation_fallback": None,
                },
            })
            consumption.update({
                "selected_route": "diffSeedServing",
                "full_crawl_performed": False,
                "owner_generation_match": "match",
                "hint_session_match": "match",
                "hint_correlation_match": "match",
                "hint_owner_match": "match",
                "initial_hint_observation": {"state": "eligible"},
                "pending_seeded_preparation_result": {"state": "eligible"},
                "final_observation": {"state": "eligible"},
            })
        return decision

    def policy_canonicalization_fixture() -> dict[str, Any]:
        base_constituents: list[dict[str, Any]] = [
            {"constituent": "rootNeutralPolicyConfig", "byte_count": 0, "sha256": "a" * 64},
            {"constituent": "commonInfoExclude", "state": "missing", "digest": "b" * 64},
            {"constituent": "canonicalIgnoreFooter", "digest": "c" * 64, "record_count": 4},
            {
                "constituent": "externalExcludes", "state": "unset",
                "identity_digest": "d" * 64, "byte_count": 0,
            },
            {"constituent": "configuredIgnorePolicy", "digest": "e" * 64},
            {"constituent": "commonInfoAttributes", "state": "regular", "digest": "f" * 64},
            {"constituent": "canonicalAttributeFooter", "digest": "1" * 64, "record_count": 1},
            {
                "constituent": "externalAttributes", "state": "unset",
                "identity_digest": "2" * 64, "byte_count": 0,
            },
            {"constituent": "attributePolicy", "digest": "3" * 64},
            {"constituent": "sparsePolicy", "digest": "4" * 64},
            {
                "constituent": "canonicalization",
                "policy_version": "mandatory-gitignore-floor-reachable-controls-v3",
                "pruned_root_count": 1,
                "pruned_root_summary_sha256": "5" * 64,
                "completeness": "complete",
            },
            {
                "constituent": "committedControls", "record_count": 5,
                "summary_sha256": "6" * 64,
            },
        ]
        target_constituents = json.loads(json.dumps(base_constituents))
        target_constituents[-2].update({
            "pruned_root_count": 0,
            "pruned_root_summary_sha256": "7" * 64,
        })
        return {
            "classification": "canonicalEquivalentAfterReachabilityFiltering",
            "constituent_comparisons": [
                {"constituent": name, "matched": True}
                for name in POLICY_CANONICALIZATION_CONSTITUENTS
            ],
            "base": {"constituents": base_constituents},
            "target": {"constituents": target_constituents},
        }

    def export_fixture(route: str) -> dict[str, Any]:
        boundaries = {
            "bindingTransitionStarted": 0, "rootReady": 100,
            "firstBenchmarkSearchStarted": 110, "firstBenchmarkReadStarted": 120,
            "firstBenchmarkSearchCompleted": 210, "firstBenchmarkReadCompleted": 220,
            "firstBenchmarkCodemapStarted": 230, "firstBenchmarkCodemapCompleted": 330,
            "warmBenchmarkCodemapStarted": 340, "warmBenchmarkCodemapCompleted": 440,
            "passiveBenchmarkTreeStarted": 450, "passiveBenchmarkTreeCompleted": 550,
            "benchmarkSelectionStarted": 560, "benchmarkSelectionCompleted": 660,
        }
        durations = {
            "materialize_to_root_ready": 100,
            "materialize_to_first_search": 210,
            "materialize_to_first_read": 220,
            "first_search": 100, "first_read": 100, "first_codemap": 100,
            "warm_codemap": 100, "passive_tree": 100, "selection": 100,
        }
        delta_evaluations: list[dict[str, Any]] = []
        if route == "projected":
            for source in ("hintEvaluator", "planner"):
                delta_evaluations.append({
                    "correlation_id": correlation,
                    "source": source,
                    "decision": "compatible",
                    "field_evaluations": [
                        {
                            "field": field,
                            "decision": "match",
                            "base_digest": "a" * 64,
                            "target_digest": "a" * 64,
                        }
                        for field in DELTA_COMPATIBILITY_FIELDS
                    ],
                    "mismatched_fields": [],
                    "correction_rule_applied": "none",
                    "tree_relation": "sameExcludedFromDeltaCompatibility",
                    "exact_snapshot_lookup_reached": True,
                    "exact_snapshot_lookup_passed": True,
                    "target_authority_comparison_reached": True,
                    "target_authority_comparison_passed": True,
                    "current_search_abi_reached": source == "hintEvaluator",
                    "current_search_abi_matched": True if source == "hintEvaluator" else None,
                    "catalog_policy_comparison_reached": source == "planner",
                    "catalog_policy_matched": True if source == "planner" else None,
                    "terminal_fallback": None,
                    "duplicate": False,
                    "contradictory": False,
                    "policy_canonicalization_comparison": policy_canonicalization_fixture(),
                })
        return {
            "schema_version": DIAGNOSTIC_SCHEMA_VERSION,
            "scope": {"context_id": context_id},
            "sample": {
                "valid": True,
                "configured_route": ROUTES[route]["expected"],
                "correlation_id": correlation,
                "agent_session_id": session,
                "invocation": 1,
                "ordinal": 1,
                "root_ready": True,
                "first_search_complete": True,
                "first_read_complete": True,
                "route_counts": EXPECTED_ACTUAL_ROUTE_COUNTS[route],
                "fallback_counts": {},
                "durations_us": durations,
                "interactive_readiness_us": 220,
                "operation_boundaries_us": boundaries,
                "boundary_evidence_available": True,
                "boundary_invalid_reasons": [],
            },
            "receipt_decision_count": 1,
            "terminal_receipt_decision_count": 1,
            "receipt_decision_buffer_evicted": False,
            "receipt_decision_ambiguous": False,
            "receipt_decisions": [receipt_fixture(route)],
            "delta_compatibility_evaluation_count": len(delta_evaluations),
            "delta_compatibility_evaluation_buffer_evicted": False,
            "delta_compatibility_evaluation_ambiguous": False,
            "delta_compatibility_evaluation_contradictory": False,
            "delta_compatibility_evaluations": delta_evaluations,
            "git": {
                "available": True, "command_count": 1, "families": {"test": 1},
                "priorities": {"test": 1}, "queue_wait_us": 0, "duration_us": 1,
                "output_bytes": 0, "cancelled_count": 0,
            },
            "work": {
                "filesystem": {
                    "available": True, "operation_count": 1, "duration_us": 1,
                    "item_count": 1,
                },
                "planner": {
                    phase: {"count": 1, "duration_us": 1, "item_count": 1}
                    for phase in ("targetNamespace", "treeEvidence", "indexEvidence", "statusEvidence", "reconcile")
                },
                "mutation_lock": {
                    "available": True, "count": 1, "queue_wait_us": 0, "held_us": 1,
                    "mutation_us": 1, "post_mutation_finalization_us": 1,
                },
                "passive_tree": {"available": True, "operation_count": 1, "duration_us": 100},
                "marker_publications": [{
                    "root_id": str(uuid.uuid4()), "root_lifetime_id": str(uuid.uuid4()),
                    "revision": 1, "effective_change_count": 1,
                    "source": "warmReplay", "timestamp_us": 550,
                }],
            },
        }

    for route in ROUTES:
        export = export_fixture(route)
        failures = validate_export(
            export, route, {"search": True, "read": True},
            expected_correlation=correlation, expected_session=session,
            expected_invocation=1, expected_ordinal=1,
        )
        checks[f"route_{route}"] = not failures
        export["sample"]["route_counts"] = {"wrong": 1}
        checks[f"route_{route}_negative"] = "actual_route_counts_mismatch" in validate_export(
            export, route, {"search": True, "read": True},
            expected_correlation=correlation, expected_session=session,
            expected_invocation=1, expected_ordinal=1,
        )

    primary_build = {"cli_sha256": "a" * 64, "base_commit_oid": "b" * 40}
    primary_fixture_identity = {
        "base_commit_oid": "b" * 40,
        "read_blob_sha256": "c" * 64,
        "read_path": "Fixture.swift",
        "search_marker": marker,
        "read_marker": "import CryptoKit",
    }

    def primary_fixture(route: str = "baseline") -> dict[str, Any]:
        return {
            "identity": {
                "correlation_id": correlation,
                "session_id": session,
                "context_id": context_id,
                "invocation": 1,
                "ordinal": 1,
                "build": primary_build,
            },
            "committed_fixture": primary_fixture_identity,
            "direct_tool_evidence": {
                "concurrent": True,
                "mark_failures": [],
                "search": {"ok": True},
                "read": {"ok": True},
            },
            "diagnostic_checkpoint": export_fixture(route),
            "checkpoint_capture": {"ok": True, "type": "success"},
            "resource_cleanup": None,
            "valid": False,
            "invalid_reasons": ["resource_cleanup_pending"],
        }

    def finalize_primary_fixture(
        primary: dict[str, Any], *, route: str = "baseline", cleanup_complete: bool = True,
        expected_route_observation_count: int = 1,
    ) -> None:
        finalize_primary_performance(
            primary, route=route,
            expected_correlation=correlation, expected_session=session,
            expected_context=context_id, expected_scope_context=context_id,
            expected_invocation=1, expected_ordinal=1,
            expected_build=primary_build, expected_fixture=primary_fixture_identity,
            resource_failures=[], cleanup_complete=cleanup_complete,
            build_unchanged=True,
            expected_route_observation_count=expected_route_observation_count,
        )

    codemap_timeout_primary = primary_fixture()
    finalize_primary_fixture(codemap_timeout_primary)
    codemap_timeout_follow_on = {
        "accepted": False,
        "invalid_reasons": ["missing_first_codemap"],
        "collection": {
            "ok": False, "completed": True,
            "failures": [{"operation": "first_codemap", "type": "timeout"}],
        },
    }
    checks["codemap_timeout_retains_primary"] = (
        codemap_timeout_primary["valid"] is True
        and codemap_timeout_follow_on["accepted"] is False
    )
    failed_read_primary = primary_fixture()
    failed_read_primary["direct_tool_evidence"]["read"] = {
        "ok": False, "type": "malformed", "error": "missing committed marker",
    }
    finalize_primary_fixture(failed_read_primary)
    checks["failed_read_invalidates_primary"] = (
        failed_read_primary["valid"] is False
        and "direct_content_oracle_mismatch" in failed_read_primary["invalid_reasons"]
    )
    route_mismatch_primary = primary_fixture("projected")
    route_mismatch_primary["diagnostic_checkpoint"]["sample"]["route_counts"] = {"fullCrawl": 1}
    route_mismatch_primary["diagnostic_checkpoint"]["sample"]["fallback_counts"] = {"fallback": 1}
    finalize_primary_fixture(route_mismatch_primary, route="projected")
    checks["route_fallback_mismatch_invalidates_primary"] = (
        route_mismatch_primary["valid"] is False
        and "actual_route_counts_mismatch" in route_mismatch_primary["invalid_reasons"]
        and "unexpected_fallback" in route_mismatch_primary["invalid_reasons"]
    )
    cleanup_failure_primary = primary_fixture()
    finalize_primary_fixture(cleanup_failure_primary, cleanup_complete=False)
    checks["cleanup_failure_invalidates_cohort"] = (
        cleanup_failure_primary["valid"] is False
        and "cleanup_incomplete" in cleanup_failure_primary["invalid_reasons"]
    )

    nonconcurrent_primary = primary_fixture()
    nonconcurrent_primary["direct_tool_evidence"]["concurrent"] = False
    finalize_primary_fixture(nonconcurrent_primary)
    checks["recorded_sequential_search_read_rejected"] = (
        "primary_direct_concurrency_unproven" in nonconcurrent_primary["invalid_reasons"]
    )
    nonoverlap_primary = primary_fixture()
    nonoverlap_sample = nonoverlap_primary["diagnostic_checkpoint"]["sample"]
    nonoverlap_sample["operation_boundaries_us"].update({
        "firstBenchmarkSearchCompleted": 115,
        "firstBenchmarkReadStarted": 120,
    })
    nonoverlap_sample["durations_us"].update({
        "materialize_to_first_search": 115,
        "first_search": 5,
    })
    finalize_primary_fixture(nonoverlap_primary)
    checks["interval_sequential_search_read_rejected"] = (
        "primary_search_read_intervals_do_not_overlap"
        in nonoverlap_primary["invalid_reasons"]
    )

    receipt_identity_primary = primary_fixture()
    receipt_identity_primary["diagnostic_checkpoint"]["receipt_decisions"][0][
        "correlation_id"
    ] = str(uuid.uuid4()).upper()
    finalize_primary_fixture(receipt_identity_primary)
    checks["receipt_identity_mismatch_rejected"] = (
        "receipt_decision_identity_or_terminal_mismatch"
        in receipt_identity_primary["invalid_reasons"]
    )
    receipt_terminal_primary = primary_fixture()
    receipt_terminal_primary["diagnostic_checkpoint"]["receipt_decisions"][0][
        "terminal_stage"
    ] = "projection"
    finalize_primary_fixture(receipt_terminal_primary)
    checks["receipt_nonconsumption_terminal_rejected"] = (
        "receipt_decision_identity_or_terminal_mismatch"
        in receipt_terminal_primary["invalid_reasons"]
    )
    receipt_route_primary = primary_fixture("projected")
    receipt_route_primary["diagnostic_checkpoint"]["receipt_decisions"][0][
        "consumption"
    ]["selected_route"] = "fullCrawl"
    finalize_primary_fixture(receipt_route_primary, route="projected")
    checks["receipt_route_semantics_rejected"] = (
        "receipt_projected_decision_contract_mismatch"
        in receipt_route_primary["invalid_reasons"]
    )

    def receipt_failures(checkpoint: dict[str, Any], route: str) -> list[str]:
        return validate_receipt_oracle(
            checkpoint, checkpoint["sample"], route,
            expected_correlation=correlation, expected_session=session,
            expected_invocation=1, expected_ordinal=1,
        )

    for source_route in ROUTES:
        for validated_route in ROUTES:
            route_failures = receipt_failures(
                export_fixture(source_route), validated_route
            )
            check_name = (
                f"receipt_route_matrix_{source_route.replace('-', '_')}_as_"
                f"{validated_route.replace('-', '_')}"
            )
            expected_contract_failure = (
                f"receipt_{validated_route.replace('-', '_')}_decision_contract_mismatch"
            )
            checks[check_name] = (
                not route_failures if source_route == validated_route
                else expected_contract_failure in route_failures
            )

    for nonprojected_route in ("baseline", "forced-full"):
        mixed_checkpoint = export_fixture(nonprojected_route)
        projected_decision = receipt_fixture("projected")
        mixed_checkpoint["receipt_decisions"][0]["coordinator"] = projected_decision[
            "coordinator"
        ]
        mixed_checkpoint["receipt_decisions"][0]["projection"] = projected_decision[
            "projection"
        ]
        checks[f"receipt_{nonprojected_route.replace('-', '_')}_rejects_projected_evidence"] = (
            f"receipt_{nonprojected_route.replace('-', '_')}_decision_contract_mismatch"
            in receipt_failures(mixed_checkpoint, nonprojected_route)
        )

    projected_mutations = {
        "creation": ("creation", "receipt_emitted", False),
        "coordinator": ("coordinator", "hint_count", 0),
        "projection": ("projection", "matched_hint_count", 0),
        "consumption": ("consumption", "selected_route", "fullCrawl"),
    }
    for name, (section, field, value) in projected_mutations.items():
        malformed = export_fixture("projected")
        malformed["receipt_decisions"][0][section][field] = value
        checks[f"receipt_projected_exact_{name}_required"] = (
            "receipt_projected_decision_contract_mismatch"
            in receipt_failures(malformed, "projected")
        )
    projected_mixed_attempt = export_fixture("projected")
    projected_mixed_attempt["receipt_decisions"][0]["creation_attempt_count"] = 2
    projected_mixed_attempt["receipt_decisions"][0]["extra_attempt"] = {
        "outcome": "fallback"
    }
    checks["receipt_projected_extra_mixed_attempt_rejected"] = (
        "receipt_projected_decision_contract_mismatch"
        in receipt_failures(projected_mixed_attempt, "projected")
    )
    additive_receipt = export_fixture("projected")
    additive_receipt["receipt_decisions"][0]["creation"]["future_physical_evidence"] = {
        "producer_version": 7,
    }
    checks["receipt_projected_unknown_additive_field_accepted"] = not receipt_failures(
        additive_receipt, "projected"
    )
    for field in ("current_snapshot_content_address_valid", "witness_proves_interval"):
        contradictory_receipt = export_fixture("projected")
        contradictory_receipt["receipt_decisions"][0]["creation"][field] = False
        checks[f"receipt_projected_contradictory_{field}_rejected"] = (
            "receipt_projected_decision_contract_mismatch"
            in receipt_failures(contradictory_receipt, "projected")
        )
    wrong_physical_type = export_fixture("projected")
    wrong_physical_type["receipt_decisions"][0]["creation"]["witness_proves_interval"] = 1
    checks["receipt_projected_known_physical_type_rejected"] = (
        "receipt_projected_decision_contract_mismatch"
        in receipt_failures(wrong_physical_type, "projected")
    )
    event_id_overflow = export_fixture("projected")
    event_id_overflow["receipt_decisions"][0]["creation"]["witness_end_event_id"] = 1 << 64
    checks["receipt_projected_uint64_event_id_overflow_rejected"] = (
        "receipt_projected_decision_contract_mismatch"
        in receipt_failures(event_id_overflow, "projected")
    )
    event_id_sentinel = export_fixture("projected")
    event_id_sentinel["receipt_decisions"][0]["creation"]["witness_end_event_id"] = (1 << 64) - 1
    checks["receipt_projected_uint64_event_id_sentinel_rejected"] = (
        "receipt_projected_decision_contract_mismatch"
        in receipt_failures(event_id_sentinel, "projected")
    )
    callback_watermark_overflow = export_fixture("projected")
    callback_watermark_overflow["receipt_decisions"][0]["creation"].update({
        "witness_end_accepted_callback_watermark": 1 << 64,
        "witness_accepted_callback_count": (1 << 63) - 1,
    })
    checks["receipt_projected_uint64_callback_watermark_overflow_rejected"] = (
        "receipt_projected_decision_contract_mismatch"
        in receipt_failures(callback_watermark_overflow, "projected")
    )
    callback_count_overflow = export_fixture("projected")
    callback_count_overflow["receipt_decisions"][0]["creation"].update({
        "witness_end_accepted_callback_watermark": 1 << 63,
        "witness_accepted_callback_count": 1 << 63,
    })
    checks["receipt_projected_swift_int_callback_count_overflow_rejected"] = (
        "receipt_projected_decision_contract_mismatch"
        in receipt_failures(callback_count_overflow, "projected")
    )
    callback_count_mismatch = export_fixture("projected")
    callback_count_mismatch["receipt_decisions"][0]["creation"][
        "witness_accepted_callback_count"
    ] = 11
    checks["receipt_projected_callback_watermark_count_mismatch_rejected"] = (
        "receipt_projected_decision_contract_mismatch"
        in receipt_failures(callback_count_mismatch, "projected")
    )
    events_outside_semantic_cut = export_fixture("projected")
    outside_cut_creation = events_outside_semantic_cut["receipt_decisions"][0]["creation"]
    checks["receipt_projected_total_events_outside_semantic_cut_accepted"] = (
        outside_cut_creation["witness_accepted_event_count"]
        > outside_cut_creation["witness_accepted_destination_event_count"]
        + outside_cut_creation["witness_accepted_non_destination_event_count"]
        and not receipt_failures(events_outside_semantic_cut, "projected")
    )
    callback_watermark_regression = export_fixture("projected")
    callback_watermark_regression["receipt_decisions"][0]["creation"].update({
        "witness_start_accepted_callback_watermark": 13,
        "witness_end_accepted_callback_watermark": 12,
    })
    checks["receipt_projected_callback_watermark_regression_rejected"] = (
        "receipt_projected_decision_contract_mismatch"
        in receipt_failures(callback_watermark_regression, "projected")
    )
    wrong_mandatory_type = export_fixture("projected")
    wrong_mandatory_type["receipt_decisions"][0]["creation_attempt_count"] = True
    checks["receipt_projected_mandatory_type_rejected"] = (
        "receipt_projected_decision_contract_mismatch"
        in receipt_failures(wrong_mandatory_type, "projected")
    )
    duplicated_terminal = export_fixture("projected")
    duplicated_terminal["receipt_decision_count"] = 2
    duplicated_terminal["terminal_receipt_decision_count"] = 2
    duplicated_terminal["receipt_decisions"].append(receipt_fixture("projected"))
    checks["receipt_duplicate_terminal_decision_rejected"] = (
        "terminal_receipt_evidence_invalid"
        in receipt_failures(duplicated_terminal, "projected")
    )

    probe_route_export = export_fixture("projected")
    derived_probe_observations = policy_digest_probe_route_observation_count("diffSeedServing")
    probe_route_export["sample"]["route_counts"] = {
        "diffSeedServing": derived_probe_observations
    }
    checks["policy_digest_probe_observation_count_derived_from_typed_events"] = (
        derived_probe_observations
        == len([
            event for event in POLICY_DIGEST_PROBE_ROUTE_EVENTS
            if event.route == "diffSeedServing"
        ])
        and all(event.phase for event in POLICY_DIGEST_PROBE_ROUTE_EVENTS)
    )
    checks["policy_digest_probe_exact_projected_observation_count_accepted"] = not validate_export(
        probe_route_export, "projected", {"search": True, "read": True},
        expected_correlation=correlation, expected_session=session,
        expected_invocation=1, expected_ordinal=1,
        expected_route_observation_count=derived_probe_observations,
    )
    checks["aggregate_projected_route_still_requires_one_observation"] = (
        "actual_route_counts_mismatch" in validate_export(
            probe_route_export, "projected", {"search": True, "read": True},
            expected_correlation=correlation, expected_session=session,
            expected_invocation=1, expected_ordinal=1,
        )
    )
    probe_route_primary = primary_fixture("projected")
    probe_route_primary["diagnostic_checkpoint"]["sample"]["route_counts"] = {
        "diffSeedServing": derived_probe_observations
    }
    finalize_primary_fixture(
        probe_route_primary,
        route="projected",
        expected_route_observation_count=derived_probe_observations,
    )
    checks["policy_digest_probe_primary_accepts_exact_projected_observations"] = (
        probe_route_primary["valid"] is True
    )

    forced_delta = export_fixture("forced-full")
    forced_delta["delta_compatibility_evaluation_count"] = 1
    forced_delta["delta_compatibility_evaluations"] = [
        export_fixture("projected")["delta_compatibility_evaluations"][0]
    ]
    checks["forced_full_delta_evidence_rejected"] = (
        "delta_compatibility_evidence_invalid"
        in validate_delta_compatibility_oracle(
            forced_delta, "forced-full", expected_correlation=correlation,
        )
    )
    missing_planner = export_fixture("projected")
    missing_planner["delta_compatibility_evaluation_count"] = 1
    missing_planner["delta_compatibility_evaluations"].pop()
    checks["projected_requires_evaluator_and_planner_delta_evidence"] = (
        "delta_compatibility_evidence_invalid"
        in validate_delta_compatibility_oracle(
            missing_planner, "projected", expected_correlation=correlation,
        )
    )
    duplicate_delta = export_fixture("projected")
    duplicate_delta["delta_compatibility_evaluation_ambiguous"] = True
    duplicate_delta["delta_compatibility_evaluations"][0]["duplicate"] = True
    checks["delta_duplicate_rejected"] = (
        "delta_compatibility_evidence_invalid"
        in validate_delta_compatibility_oracle(
            duplicate_delta, "projected", expected_correlation=correlation,
        )
    )
    contradictory_delta = export_fixture("projected")
    contradictory_delta["delta_compatibility_evaluation_contradictory"] = True
    contradictory_delta["delta_compatibility_evaluations"][0]["contradictory"] = True
    checks["delta_contradiction_rejected"] = (
        "delta_compatibility_evidence_invalid"
        in validate_delta_compatibility_oracle(
            contradictory_delta, "projected", expected_correlation=correlation,
        )
    )
    canonical_equivalent = policy_canonicalization_fixture()
    checks["policy_canonicalization_equivalence_accepted"] = not validate_policy_canonicalization_comparison(
        canonical_equivalent, require_canonical_equivalence=True,
    )
    semantic_policy = policy_canonicalization_fixture()
    semantic_policy["classification"] = "semanticInputDifference"
    semantic_policy["target"]["constituents"][2]["digest"] = "6" * 64
    semantic_policy["constituent_comparisons"][2]["matched"] = False
    checks["policy_canonicalization_semantic_classified_but_not_authorized"] = (
        not validate_policy_canonicalization_comparison(
            semantic_policy, require_canonical_equivalence=False,
        )
        and "policy_canonicalization_not_equivalent"
        in validate_policy_canonicalization_comparison(
            semantic_policy, require_canonical_equivalence=True,
        )
    )
    incomplete_policy = policy_canonicalization_fixture()
    incomplete_policy["classification"] = "incomplete"
    incomplete_policy["base"]["constituents"][-2]["completeness"] = "incomplete"
    incomplete_policy["constituent_comparisons"][-2]["matched"] = False
    checks["policy_canonicalization_incomplete_fails_closed"] = (
        "policy_canonicalization_not_equivalent"
        in validate_policy_canonicalization_comparison(
            incomplete_policy, require_canonical_equivalence=True,
        )
    )
    duplicate_policy = policy_canonicalization_fixture()
    duplicate_policy["base"]["constituents"].append(
        json.loads(json.dumps(duplicate_policy["base"]["constituents"][-1]))
    )
    checks["policy_canonicalization_duplicate_rejected"] = (
        "policy_canonicalization_base_constituent_order_invalid"
        in validate_policy_canonicalization_comparison(
            duplicate_policy, require_canonical_equivalence=True,
        )
    )
    contradictory_policy = policy_canonicalization_fixture()
    contradictory_policy["constituent_comparisons"][0]["matched"] = False
    checks["policy_canonicalization_contradiction_rejected"] = (
        "policy_canonicalization_comparison_contradictory"
        in validate_policy_canonicalization_comparison(
            contradictory_policy, require_canonical_equivalence=True,
        )
    )
    large_policy = policy_canonicalization_fixture()
    for label in ("base", "target"):
        large_policy[label]["constituents"][-2]["pruned_root_count"] = 1_000_000
        large_policy[label]["constituents"][-1]["record_count"] = 1_000_000
    checks["policy_canonicalization_large_summary_counts_accepted"] = (
        not validate_policy_canonicalization_comparison(
            large_policy, require_canonical_equivalence=True,
        )
    )
    additive_policy = policy_canonicalization_fixture()
    additive_policy["producer_revision"] = 7
    additive_policy["constituent_comparisons"][0]["future_comparison_evidence"] = "base-target"
    for label, marker_value in (("base", "left"), ("target", "right")):
        additive_policy[label]["future_side_evidence"] = marker_value
        additive_policy[label]["constituents"][0]["future_policy_evidence"] = marker_value
        additive_policy[label]["constituents"][-1]["future_control_evidence"] = marker_value
    checks["policy_canonicalization_unknown_additive_fields_accepted"] = (
        not validate_policy_canonicalization_comparison(
            additive_policy, require_canonical_equivalence=True,
        )
    )
    count_policy = policy_canonicalization_fixture()
    count_policy["target"]["constituents"][-1]["record_count"] = 6
    checks["policy_canonicalization_exact_counts_required"] = (
        "policy_canonicalization_comparison_contradictory"
        in validate_policy_canonicalization_comparison(
            count_policy, require_canonical_equivalence=True,
        )
    )
    summary_policy = policy_canonicalization_fixture()
    summary_policy["target"]["constituents"][-1]["summary_sha256"] = "A" * 64
    checks["policy_canonicalization_summary_digest_required"] = (
        "policy_canonicalization_target_committedControls_value_invalid"
        in validate_policy_canonicalization_comparison(
            summary_policy, require_canonical_equivalence=True,
        )
    )
    digest_policy = policy_canonicalization_fixture()
    digest_policy["target"]["constituents"][0]["sha256"] = "A" * 64
    checks["policy_canonicalization_lowercase_digests_required"] = (
        "policy_canonicalization_target_rootNeutralPolicyConfig_value_invalid"
        in validate_policy_canonicalization_comparison(
            digest_policy, require_canonical_equivalence=True,
        )
    )
    semantic_mismatch = export_fixture("projected")
    semantic_field = semantic_mismatch["delta_compatibility_evaluations"][0]["field_evaluations"][0]
    semantic_field["decision"] = "mismatch"
    semantic_field["target_digest"] = "b" * 64
    semantic_mismatch["delta_compatibility_evaluations"][0]["mismatched_fields"] = [
        "repositoryNamespace"
    ]
    checks["semantic_delta_correction_rejected"] = (
        "delta_compatibility_hintEvaluator_correction_contract_mismatch"
        in validate_delta_compatibility_oracle(
            semantic_mismatch, "projected", expected_correlation=correlation,
        )
    )
    representation_correction = export_fixture("projected")
    for evaluation in representation_correction["delta_compatibility_evaluations"]:
        field = evaluation["field_evaluations"][-2]
        field["decision"] = "mismatch"
        field["target_digest"] = "b" * 64
        evaluation["mismatched_fields"] = ["resolvedExcludesFileIdentity"]
        evaluation["correction_rule_applied"] = "canonicalMissingResolvedExcludesFileIdentity"
    checks["authorized_representation_delta_correction_accepted"] = not validate_delta_compatibility_oracle(
        representation_correction, "projected", expected_correlation=correlation,
    )
    malformed_evaluation = export_fixture("projected")
    malformed_evaluation["delta_compatibility_evaluations"][0] = "not-an-evaluation"
    checks["delta_malformed_evaluation_entry_rejected_fail_closed"] = (
        validate_delta_compatibility_oracle(
            malformed_evaluation, "projected", expected_correlation=correlation,
        ) == ["delta_compatibility_evaluation_entry_malformed"]
    )
    malformed_field = export_fixture("projected")
    malformed_field["delta_compatibility_evaluations"][0]["field_evaluations"].append(
        "not-a-field-evaluation"
    )
    checks["delta_malformed_extra_field_entry_rejected_fail_closed"] = (
        "delta_compatibility_hintEvaluator_field_entry_malformed"
        in validate_delta_compatibility_oracle(
            malformed_field, "projected", expected_correlation=correlation,
        )
    )

    def follow_on_fixture() -> dict[str, Any]:
        def operation(name: str) -> dict[str, Any]:
            return {
                "operation": name,
                "start_mark_attempted": True,
                "start_marked": True,
                "completion_mark_attempted": True,
                "completion_marked": True,
                "ok": True,
                "type": "success",
            }

        selection = operation("selection")
        selection.update({
            "set_attempted": True,
            "get_attempted": True,
            "get_result_recorded": True,
            "get_finished_ns": 100,
            "completion_mark_attempted_ns": 101,
        })
        return {
            "ok": True,
            "completed": True,
            "codemap": [operation("first_codemap"), operation("warm_codemap")],
            "tree": operation("passive_tree"),
            "selection": selection,
            "failures": [],
        }

    checks["follow_on_exact_inventory_accepted"] = not validate_follow_on_collection(
        follow_on_fixture()
    )
    start_mark_failure = follow_on_fixture()
    start_mark_failure["codemap"][0]["start_marked"] = False
    checks["follow_on_start_mark_failure_not_overwritten"] = (
        "first_codemap_start_marked_missing"
        in validate_follow_on_collection(start_mark_failure)
    )
    early_selection_completion = follow_on_fixture()
    early_selection_completion["selection"]["completion_mark_attempted_ns"] = 99
    checks["selection_completion_requires_get_result"] = (
        "selection_completed_before_get_result"
        in validate_follow_on_collection(early_selection_completion)
    )
    missing_follow_on = follow_on_fixture()
    missing_follow_on["codemap"].pop()
    checks["follow_on_exact_operation_inventory_required"] = (
        "follow_on_operation_inventory_mismatch"
        in validate_follow_on_collection(missing_follow_on)
    )

    provenance_samples = [
        {
            "ordinal": ordinal,
            "warmup": ordinal == 1,
            "correlation_id": str(uuid.uuid4()).upper(),
            "session_id": str(uuid.uuid4()).upper(),
            "source_record_sha256": f"{ordinal:x}" * 64,
            "checkpoint_sha256": f"{ordinal + 6:x}" * 64,
            "revalidated_checkpoint_sha256": f"{ordinal + 6:x}" * 64,
            "raw_primary_ms": float(700 + ordinal),
            "revalidated_primary_ms": float(700 + ordinal),
            "primary_valid": True,
            "invalid_reasons": [],
        }
        for ordinal in range(1, 7)
    ]
    provenance_retained = [item["raw_primary_ms"] for item in provenance_samples[1:]]
    provenance_fixture = {
        "schema_version": SCHEMA_VERSION,
        "kind": "primary-performance-offline-revalidation",
        "validator": {
            "version": PRIMARY_REVALIDATION_VERSION,
            "source_path": "Scripts/worktree_startup_live_benchmark.py",
            "source_sha256": "a" * 64,
        },
        "command": {"cwd": "/tmp/repo", "exact": "python3 Scripts/harness.py revalidate-primary"},
        "artifact": {
            "artifact_id": "forced-full-fixture",
            "plan_sha256": "c" * 64,
            "route": "forced-full",
            "width": 1,
            "invocation": 1,
            "build_identity": {"cli_sha256": "d" * 64, "base_commit_oid": "e" * 40},
        },
        "inputs": {
            name: {"path": f"/tmp/{name}", "sha256": "b" * 64}
            for name in (
                "plan_argument", "artifact_plan", "summary", "samples_ndjson",
                "resources", "cleanup",
            )
        },
        "samples": provenance_samples,
        "raw_values_ms": {
            "source_warmup": [provenance_samples[0]["raw_primary_ms"]],
            "source_retained": provenance_retained,
            "revalidated_retained": list(provenance_retained),
        },
        "proof": {
            "plan_content_matches_artifact": True,
            "artifact_identity_exact": True,
            "exact_sample_accounting": True,
            "checkpoint_hashes_recorded": True,
            "source_raw_values_equal_revalidated": True,
            "no_mixed_samples": True,
            "cleanup_complete": True,
            "resource_evidence_valid": True,
        },
    }
    checks["revalidation_provenance_exact_fixture_accepted"] = (
        not validate_primary_revalidation_provenance(provenance_fixture)
    )
    changed_provenance = json.loads(json.dumps(provenance_fixture))
    changed_provenance["raw_values_ms"]["revalidated_retained"][0] += 1
    checks["revalidation_provenance_changed_raw_rejected"] = (
        "revalidation_raw_values_changed_or_mixed"
        in validate_primary_revalidation_provenance(changed_provenance)
    )
    mixed_provenance = json.loads(json.dumps(provenance_fixture))
    mixed_provenance["samples"][5]["session_id"] = mixed_provenance["samples"][4]["session_id"]
    mixed_provenance["samples"][5]["correlation_id"] = mixed_provenance["samples"][4]["correlation_id"]
    checks["revalidation_provenance_mixed_identity_rejected"] = (
        "revalidation_sample_identity_reused"
        in validate_primary_revalidation_provenance(mixed_provenance)
    )

    schema_export = export_fixture("baseline")
    schema_export["schema_version"] = 4
    checks["schema_v4_rejected"] = "diagnostic_schema_mismatch" in validate_export(
        schema_export, "baseline", {"search": True, "read": True},
        expected_correlation=correlation, expected_session=session,
        expected_invocation=1, expected_ordinal=1,
    )
    nested_schema_export = export_fixture("baseline")
    nested_schema_export.pop("schema_version")
    nested_schema_export["nested"] = {"schema_version": DIAGNOSTIC_SCHEMA_VERSION}
    checks["nested_schema_v6_does_not_satisfy_top_level_contract"] = (
        "diagnostic_schema_mismatch" in validate_export(
            nested_schema_export, "baseline", {"search": True, "read": True},
            expected_correlation=correlation, expected_session=session,
            expected_invocation=1, expected_ordinal=1,
        )
    )
    invalid_boundary_export = export_fixture("baseline")
    invalid_boundary_export["sample"]["operation_boundaries_us"][
        "firstBenchmarkReadCompleted"
    ] = 119
    checks["non_monotonic_boundary_rejected"] = (
        "non_monotonic_operation_boundaries" in validate_export(
            invalid_boundary_export, "baseline", {"search": True, "read": True},
            expected_correlation=correlation, expected_session=session,
            expected_invocation=1, expected_ordinal=1,
        )
    )
    inconsistent_duration_export = export_fixture("baseline")
    inconsistent_duration_export["sample"]["durations_us"]["selection"] = 98
    checks["inconsistent_boundary_duration_rejected"] = (
        "inconsistent_selection_duration" in validate_export(
            inconsistent_duration_export, "baseline", {"search": True, "read": True},
            expected_correlation=correlation, expected_session=session,
            expected_invocation=1, expected_ordinal=1,
        )
    )

    def export_failures(export: dict[str, Any], route: str = "baseline") -> list[str]:
        return validate_export(
            export, route, {"search": True, "read": True},
            expected_correlation=correlation, expected_session=session,
            expected_invocation=1, expected_ordinal=1,
        )

    invalid_count_cases = {
        "sample_route_bool_count_rejected": ("route_counts", {"fullCrawl": True}, "invalid_route_counts"),
        "sample_route_string_count_rejected": ("route_counts", {"fullCrawl": "1"}, "invalid_route_counts"),
        "sample_route_float_count_rejected": ("route_counts", {"fullCrawl": 1.0}, "invalid_route_counts"),
        "sample_route_negative_count_rejected": ("route_counts", {"fullCrawl": -1}, "invalid_route_counts"),
        "sample_fallback_bool_count_rejected": ("fallback_counts", {"fallback": True}, "invalid_fallback_counts"),
    }
    for name, (field, value, expected_failure) in invalid_count_cases.items():
        export = export_fixture("baseline")
        export["sample"][field] = value
        checks[name] = expected_failure in export_failures(export)

    for name, value in {
        "sample_duration_bool_rejected": True,
        "sample_duration_string_rejected": "100",
        "sample_duration_nan_rejected": float("nan"),
        "sample_duration_inf_rejected": float("inf"),
        "sample_duration_negative_rejected": -1,
        "sample_duration_zero_rejected": 0,
    }.items():
        export = export_fixture("baseline")
        export["sample"]["durations_us"][METRICS[0]] = value
        checks[name] = "invalid_sample_durations" in export_failures(export)

    for name, value in {
        "sample_invocation_bool_rejected": True,
        "sample_invocation_string_rejected": "1",
    }.items():
        export = export_fixture("baseline")
        export["sample"]["invocation"] = value
        checks[name] = "sample_invocation_mismatch" in export_failures(export)

    checks["numeric_float_timings_accepted"] = not validate_export(
        {
            **export_fixture("baseline"),
            "git": {
                **export_fixture("baseline")["git"], "queue_wait_us": 0.5, "duration_us": 1.5,
            },
            "work": {
                **export_fixture("baseline")["work"],
                "filesystem": {
                    **export_fixture("baseline")["work"]["filesystem"], "duration_us": 1.25,
                },
            },
        },
        "baseline", {"search": True, "read": True}, expected_correlation=correlation,
        expected_session=session, expected_invocation=1, expected_ordinal=1,
    )
    checks["git_bool_timing_rejected"] = "invalid_git_duration_us" in validate_git_evidence({
        **export_fixture("baseline")["git"], "duration_us": True,
    })
    checks["filesystem_nan_timing_rejected"] = "invalid_filesystem_duration_us" in validate_filesystem_evidence({
        **export_fixture("baseline")["work"]["filesystem"], "duration_us": float("nan"),
    })

    def stats_rejects(value: Any, *, positive: bool = False) -> bool:
        try:
            stats([value], positive=positive, label="self-test timing")
        except BenchmarkError:
            return True
        return False

    checks["stats_bool_rejected"] = stats_rejects(True)
    checks["stats_numeric_string_rejected"] = stats_rejects("1")
    checks["stats_nan_rejected"] = stats_rejects(float("nan"))
    checks["stats_inf_rejected"] = stats_rejects(float("inf"))
    checks["stats_negative_rejected"] = stats_rejects(-1)
    checks["stats_required_positive_zero_rejected"] = stats_rejects(0, positive=True)
    checks["stats_finite_numeric_accepted"] = stats([0, 1.5])["p95"] == 1.5

    baseline_fixture_sha = "f" * 64
    baseline_artifact_id = "accepted-codemap-artifact"
    baseline_cold, baseline_warm = 20, 40
    baseline_exact_counts = {
        "cold_individual_structure": baseline_cold,
        "warm_individual_structure": baseline_warm,
        "cold_directory_structure": baseline_cold,
        "warm_directory_structure": baseline_warm,
        "tree_marker_availability": 2 * (baseline_cold + baseline_warm),
        "first_search": 2 * (baseline_cold // 2),
        "first_read": 2 * (baseline_cold // 2),
        "root_readiness": 2 * (baseline_cold // 2),
    }
    baseline_fixture = {
        "schema_version": SCHEMA_VERSION, "kind": "codemap-gate",
        "artifact_id": baseline_artifact_id, "decision": "pass", "status": "completed",
        "fixture_sha256": baseline_fixture_sha, "cleanup_complete": True,
        "configuration": {
            "cold_samples_per_cohort": baseline_cold,
            "warm_samples_per_cohort": baseline_warm,
            "wait_contract_ms": CODEMAP_GATE_WAIT_MILLISECONDS,
            "harness_allowance_ms": CODEMAP_GATE_HARNESS_ALLOWANCE_MILLISECONDS,
        },
        "sample_counts": {"attempted": 120, "valid": 120, "invalid": 0},
        "gates": {name: True for name in CODEMAP_REQUIRED_GATES},
        "metrics": {
            name: {"count": baseline_exact_counts.get(name, 1), "p50": 1.0, "p95": 2.0}
            for name in CODEMAP_REQUIRED_METRICS
        },
        "privacy": {
            "ok": True, "scanned_file_count": 1, "failure_codes": [],
            "allowlisted_root_sha256": ["a" * 64],
            "allowlisted_prompt_sha256": ["b" * 64],
        },
    }
    with tempfile.TemporaryDirectory(prefix="rpce-codemap-baseline-self-test-") as raw:
        baseline_path = Path(raw) / "summary.json"
        ledger_path = Path(raw) / "ledger.json"
        save_json(baseline_path, baseline_fixture)
        baseline_digest = sha256_bytes(baseline_path.read_bytes())
        ledger_fixture = {
            "schema_version": SCHEMA_VERSION,
            "kind": CODEMAP_BASELINE_LEDGER_KIND,
            "accepted_summaries": [{
                "artifact_id": baseline_artifact_id,
                "summary_sha256": baseline_digest,
                "fixture_sha256": baseline_fixture_sha,
            }],
        }
        save_json(ledger_path, ledger_fixture)
        accepted_ledger_digest = sha256_bytes(ledger_path.read_bytes())
        accepted_baseline, acceptance = validate_codemap_baseline(
            baseline_path, ledger_path, expected_ledger_sha256=accepted_ledger_digest,
            fixture_sha256=baseline_fixture_sha,
            cold_samples=baseline_cold, warm_samples=baseline_warm,
        )
        checks["baseline_exact_inventory_and_ledger_accepted"] = (
            accepted_baseline["artifact_id"] == baseline_artifact_id
            and acceptance["summary_sha256"] == baseline_digest
            and len(acceptance["ledger_sha256"]) == 64
        )
        nonfinite_path = Path(raw) / "nonfinite.json"
        nonfinite = json.loads(json.dumps(baseline_fixture))
        nonfinite["metrics"]["queue_wait"]["p95"] = float("inf")
        secure_write(nonfinite_path, json.dumps(nonfinite).encode())
        try:
            validate_codemap_baseline(
                nonfinite_path, ledger_path, fixture_sha256=baseline_fixture_sha,
                expected_ledger_sha256=accepted_ledger_digest,
                cold_samples=baseline_cold, warm_samples=baseline_warm,
            )
            checks["baseline_infinity_rejected"] = False
        except BenchmarkError:
            checks["baseline_infinity_rejected"] = True
        missing_metric_path = Path(raw) / "missing-metric.json"
        missing_metric = json.loads(json.dumps(baseline_fixture))
        del missing_metric["metrics"]["queue_wait"]
        save_json(missing_metric_path, missing_metric)
        try:
            validate_codemap_baseline(
                missing_metric_path, ledger_path, fixture_sha256=baseline_fixture_sha,
                expected_ledger_sha256=accepted_ledger_digest,
                cold_samples=baseline_cold, warm_samples=baseline_warm,
            )
            checks["baseline_missing_inventory_rejected"] = False
        except BenchmarkError:
            checks["baseline_missing_inventory_rejected"] = True
        wrong_ledger_path = Path(raw) / "wrong-ledger.json"
        wrong_ledger = json.loads(json.dumps(ledger_fixture))
        wrong_ledger["accepted_summaries"][0]["summary_sha256"] = "0" * 64
        save_json(wrong_ledger_path, wrong_ledger)
        try:
            validate_codemap_baseline(
                baseline_path, wrong_ledger_path, fixture_sha256=baseline_fixture_sha,
                expected_ledger_sha256=accepted_ledger_digest,
                cold_samples=baseline_cold, warm_samples=baseline_warm,
            )
            checks["synthetic_passing_baseline_without_acceptance_rejected"] = False
        except BenchmarkError:
            checks["synthetic_passing_baseline_without_acceptance_rejected"] = True

    seen: set[Any] = set()
    register_unique(("warm", "projected", 1), seen, "cohort invocation")
    try:
        register_unique(("warm", "projected", 1), seen, "cohort invocation")
        checks["duplicate_rejected"] = False
    except BenchmarkError:
        checks["duplicate_rejected"] = True
    validate_sample_ordinals([{"ordinal": 1}, {"ordinal": 2}], 2)
    try:
        validate_sample_ordinals([{"ordinal": 1}, {"ordinal": 1}], 2)
        checks["ordinal_duplicate_rejected"] = False
    except BenchmarkError:
        checks["ordinal_duplicate_rejected"] = True
    for name, ordinal in {
        "ordinal_bool_rejected": True,
        "ordinal_string_rejected": "1",
        "ordinal_float_rejected": 1.0,
    }.items():
        try:
            validate_sample_ordinals([{"ordinal": ordinal}], 1)
        except BenchmarkError:
            checks[name] = True
        else:
            checks[name] = False
    identity_seen: set[str] = set()
    register_unique(correlation, identity_seen, "sample correlation identity")
    try:
        register_unique(correlation, identity_seen, "sample correlation identity")
        checks["duplicate_correlation_rejected"] = False
    except BenchmarkError:
        checks["duplicate_correlation_rejected"] = True
    session_seen: set[str] = set()
    register_unique(session, session_seen, "sample session identity")
    try:
        register_unique(session, session_seen, "sample session identity")
        checks["duplicate_session_rejected"] = False
    except BenchmarkError:
        checks["duplicate_session_rejected"] = True

    valid_accounting = {
        "invocation_count": 2, "attempted": 8, "valid_retained": 6,
        "invalid_attempted": 0,
    }
    checks["cohort_exact_accounting"] = cohort_accounting_valid(
        valid_accounting, width=1, warmups=1, retained=3, invocations=2
    )
    checks["cohort_extra_sample_rejected"] = not cohort_accounting_valid(
        dict(valid_accounting, attempted=9, valid_retained=7),
        width=1, warmups=1, retained=3, invocations=2,
    )
    checks["cohort_invalid_attempt_rejected"] = not cohort_accounting_valid(
        dict(valid_accounting, invalid_attempted=1),
        width=1, warmups=1, retained=3, invocations=2,
    )

    resource_fixture = {
        "baseline_resident_mb": 100.0, "peak_resident_mb": 120.0,
        "final_resident_mb": 110.0, "peak_resident_delta_mb": 20.0,
        "retained_resident_delta_mb": 10.0,
        "baseline_physical_footprint_mb": 80.0, "peak_physical_footprint_mb": 88.0,
        "final_physical_footprint_mb": 82.0, "peak_physical_footprint_delta_mb": 8.0,
        "retained_physical_footprint_delta_mb": 2.0,
        "physical_footprint_available": True,
        "session_cpu_ms": 30.0, "session_user_cpu_ms": 20.0,
        "session_system_cpu_ms": 10.0, "average_core_utilization_percent": 25.0,
        "peak_interval_core_utilization_percent": 50.0,
        "sample_count": 3, "duration_seconds": 1.0,
    }
    checks["resource_values_validated"] = not validate_resource_evidence(resource_fixture)
    live_resource_fixture = dict(resource_fixture)
    live_resource_fixture["phys_footprint_available"] = live_resource_fixture.pop(
        "physical_footprint_available"
    )
    checks["live_resource_availability_alias_validated"] = not validate_resource_evidence(
        live_resource_fixture
    )
    checks["resource_core_range_rejected"] = "invalid_resource_core_utilization" in validate_resource_evidence(
        dict(resource_fixture, peak_interval_core_utilization_percent=10.0)
    )
    quantized_resource = dict(
        resource_fixture,
        baseline_resident_mb=408.8,
        peak_resident_mb=465.7,
        final_resident_mb=420.0,
        peak_resident_delta_mb=57.0,
        retained_resident_delta_mb=11.2,
    )
    checks["resource_quantized_point_one_discrepancy_accepted"] = not validate_resource_evidence(
        quantized_resource
    )
    checks["resource_quantized_point_two_discrepancy_rejected"] = (
        "inconsistent_resident_peak_delta" in validate_resource_evidence(
            dict(quantized_resource, peak_resident_delta_mb=57.1)
        )
    )
    checks["resource_off_grid_rejected"] = "invalid_resident_absolute_mb" in validate_resource_evidence(
        dict(resource_fixture, peak_resident_mb=120.05)
    )
    negative_retained_resource = dict(
        resource_fixture,
        final_resident_mb=99.9,
        retained_resident_delta_mb=-0.1,
        final_physical_footprint_mb=79.9,
        retained_physical_footprint_delta_mb=-0.1,
    )
    checks["resource_negative_retained_deltas_accepted"] = not validate_resource_evidence(
        negative_retained_resource
    )
    checks["resource_negative_peak_delta_rejected"] = (
        "inconsistent_resident_peak_delta" in validate_resource_evidence(
            dict(resource_fixture, peak_resident_delta_mb=-20.0)
        )
    )
    checks["resource_nonfinite_signed_delta_rejected"] = (
        "invalid_resident_delta_mb" in validate_resource_evidence(
            dict(resource_fixture, retained_resident_delta_mb=float("-inf"))
        )
    )
    drained_fixture = {
        "contains_paths": False, "is_drained": True,
        **{field: 0 for field in DRAIN_ZERO_COUNT_FIELDS},
    }
    checks["session_drain_zero_snapshot_accepted"] = valid_drain_snapshot(drained_fixture)
    checks["session_drain_nonzero_snapshot_rejected"] = not valid_drain_snapshot(
        dict(drained_fixture, matching_live_root_count=1)
    )
    recovery_shape = {
        "content": [{"type": "text", "text": json.dumps({
            "ok": True, "recovery": {"phase": "provider_start", "worktree_id": "worktree-1"},
        })}],
    }
    drain_shape = {
        "structuredContent": {
            "ok": True, "drain": {"is_drained": True, "reserved_load_flight_count": 0},
        },
    }
    checks["recovery_nested_payload_normalized"] = nested_response_object(
        recovery_shape, "recovery"
    ) == {"phase": "provider_start", "worktree_id": "worktree-1"}
    checks["drain_nested_payload_normalized"] = nested_response_object(
        drain_shape, "drain"
    ) == {"is_drained": True, "reserved_load_flight_count": 0}
    try:
        nested_response_object({"recovery": "not-an-object"}, "recovery")
        checks["nested_payload_wrong_shape_rejected"] = False
    except BenchmarkError:
        checks["nested_payload_wrong_shape_rejected"] = True
    try:
        required_cleanup_worktree_inventory({"isError": True})
        checks["failed_final_status_free_inventory_rejected"] = False
    except BenchmarkError:
        checks["failed_final_status_free_inventory_rejected"] = True
    failed_final_inventory_state = {
        "cleanup_manual_required": True,
        "attempts": [{
            "path": None,
            "manual_cleanup": True,
            "cleanup_reason": "final_status_free_inventory_failed",
        }],
    }
    checks["cleanup_command_nil_path_manual_inventory_failure_rejected"] = not (
        cleanup_command_acceptance(True, failed_final_inventory_state)
    )

    projected_artifact_id = "projected-fixture"
    projected_plan_fixture = {
        "plan_sha256": "1" * 64,
        "scope": {
            "window_id": 1,
            "workspace_id": str(uuid.uuid4()).upper(),
            "context_id": str(uuid.uuid4()).upper(),
            "root_id": str(uuid.uuid4()).upper(),
            "root_path": "/tmp/projected-root",
        },
    }
    projected_build_fixture = {
        "cli_sha256": "2" * 64,
        "app_executable_sha256": "3" * 64,
        "harness_source_sha256": "4" * 64,
        "base_commit_oid": "5" * 40,
    }
    projected_invocation = 7
    projected_summary_fixture = {
        "status": "completed",
        "artifact_id": projected_artifact_id,
        "plan_sha256": projected_plan_fixture["plan_sha256"],
        "build_identity": projected_build_fixture,
        "process_state": "warm",
        "checkout_kind": "linked-worktree",
        "route": "projected",
        "width": 1,
        "invocation": projected_invocation,
        "warmup_groups": 1,
        "retained_groups": FIXED_RETAINED_SAMPLES,
        "expected_sample_count": 1 + FIXED_RETAINED_SAMPLES,
        "sample_count": 1 + FIXED_RETAINED_SAMPLES,
        "valid_retained_count": FIXED_RETAINED_SAMPLES,
        "primary_valid_retained_count": FIXED_RETAINED_SAMPLES,
        "follow_on_accepted_retained_count": FIXED_RETAINED_SAMPLES,
        "invalid_count": 0,
        "operational_error": None,
        "cleanup_complete": True,
    }

    def projected_sample_fixture(ordinal: int) -> dict[str, Any]:
        return {
            "artifact_id": projected_artifact_id,
            "plan_sha256": projected_plan_fixture["plan_sha256"],
            "process_state": "warm",
            "checkout_kind": "linked-worktree",
            "route": "projected",
            "width": 1,
            "invocation": projected_invocation,
            "ordinal": ordinal,
            "warmup": ordinal == 1,
            "valid": True,
            "invalid_reasons": [],
            "primary_performance": {
                "valid": True,
                "identity": {
                    "build": projected_build_fixture,
                    "invocation": projected_invocation,
                    "ordinal": ordinal,
                },
                "diagnostic_checkpoint": {
                    "sample": {
                        "invocation": projected_invocation,
                        "ordinal": ordinal,
                        "route_counts": expected_actual_route_counts("projected"),
                        "fallback_counts": {},
                    },
                },
            },
            "follow_on_acceptance": {"accepted": True},
        }

    projected_samples_fixture = [
        projected_sample_fixture(ordinal)
        for ordinal in range(1, 2 + FIXED_RETAINED_SAMPLES)
    ]
    require_exact_projected_inference_identity(
        projected_summary_fixture,
        projected_plan_fixture,
        projected_plan_fixture,
        artifact_id=projected_artifact_id,
        expected_build=projected_build_fixture,
    )
    require_exact_projected_inference_cohort(
        projected_summary_fixture,
        projected_samples_fixture,
        artifact_id=projected_artifact_id,
        plan_sha256=projected_plan_fixture["plan_sha256"],
        expected_build=projected_build_fixture,
    )
    checks["projected_prerequisite_exact_fixture_accepted"] = True
    bad_root_plan = json.loads(json.dumps(projected_plan_fixture))
    bad_root_plan["scope"]["root_path"] = "/tmp/wrong-root"
    try:
        require_exact_projected_inference_identity(
            projected_summary_fixture,
            bad_root_plan,
            projected_plan_fixture,
            artifact_id=projected_artifact_id,
            expected_build=projected_build_fixture,
        )
        checks["projected_prerequisite_wrong_root_rejected"] = False
    except BenchmarkError:
        checks["projected_prerequisite_wrong_root_rejected"] = True
    bad_build_summary = dict(
        projected_summary_fixture,
        build_identity=dict(projected_build_fixture, harness_source_sha256="9" * 64),
    )
    try:
        require_exact_projected_inference_identity(
            bad_build_summary,
            projected_plan_fixture,
            projected_plan_fixture,
            artifact_id=projected_artifact_id,
            expected_build=projected_build_fixture,
        )
        checks["projected_prerequisite_wrong_source_rejected"] = False
    except BenchmarkError:
        checks["projected_prerequisite_wrong_source_rejected"] = True
    for field in ("cli_sha256", "app_executable_sha256", "base_commit_oid"):
        wrong_value = "8" * (40 if field == "base_commit_oid" else 64)
        wrong_summary = dict(
            projected_summary_fixture,
            build_identity=dict(projected_build_fixture, **{field: wrong_value}),
        )
        check_name = f"projected_prerequisite_wrong_{field}_rejected"
        try:
            require_exact_projected_inference_identity(
                wrong_summary,
                projected_plan_fixture,
                projected_plan_fixture,
                artifact_id=projected_artifact_id,
                expected_build=projected_build_fixture,
            )
            checks[check_name] = False
        except BenchmarkError:
            checks[check_name] = True
    bad_samples = json.loads(json.dumps(projected_samples_fixture))
    bad_samples[0]["warmup"] = False
    bad_samples[1]["primary_performance"]["diagnostic_checkpoint"]["sample"][
        "fallback_counts"
    ] = {"unexpected": 1}
    try:
        require_exact_projected_inference_cohort(
            projected_summary_fixture,
            bad_samples,
            artifact_id=projected_artifact_id,
            plan_sha256=projected_plan_fixture["plan_sha256"],
            expected_build=projected_build_fixture,
        )
        checks["projected_prerequisite_bad_warmup_fallback_rejected"] = False
    except BenchmarkError:
        checks["projected_prerequisite_bad_warmup_fallback_rejected"] = True
    bad_summary = dict(projected_summary_fixture, invalid_count=1)
    try:
        require_exact_projected_inference_cohort(
            bad_summary,
            projected_samples_fixture,
            artifact_id=projected_artifact_id,
            plan_sha256=projected_plan_fixture["plan_sha256"],
            expected_build=projected_build_fixture,
        )
        checks["projected_prerequisite_invalid_sample_rejected"] = False
    except BenchmarkError:
        checks["projected_prerequisite_invalid_sample_rejected"] = True
    checks["git_family_count_rejected"] = "invalid_git_family_counts" in validate_git_evidence({
        "available": True, "command_count": 2, "families": {"status": 1},
        "priorities": {"normal": 2}, "queue_wait_us": 0, "duration_us": 1,
        "output_bytes": 0, "cancelled_count": 0,
    })
    checks["filesystem_item_type_rejected"] = "invalid_filesystem_item_count" in validate_filesystem_evidence({
        "available": True, "operation_count": 1, "duration_us": 1, "item_count": "1",
    })

    checks["memory_absolute"] = math.isclose(
        absolute_memory_regression([100.0, 100.0], [110.0, 110.0]) or -1,
        0.10,
        rel_tol=1e-9,
    )
    checks["memory_zero_rejected"] = absolute_memory_regression([0.0], [10.0]) is None
    checks["memory_negative_rejected"] = absolute_memory_regression([-1.0], [10.0]) is None

    cleanup_artifact_name = "20260625T171028Z-warm-baseline-w1-73bd1572"
    cleanup_branch = safe_name(f"rpce-bench-{cleanup_artifact_name}-i1-o1")[:120]
    cleanup_commit_oid = "a" * 40
    cleanup_session_id = str(uuid.uuid4()).upper()
    cleanup_context_id = str(uuid.uuid4()).upper()
    cleanup_worktree_id = "wt-owned"
    cleanup_worktree_path = str((fixture_root / "owned-worktree").resolve(strict=False))
    cleanup_live_worktrees = {
        (cleanup_worktree_id, cleanup_worktree_path, cleanup_branch, cleanup_commit_oid),
    }
    cleanup_snapshot = {
        "session_id": cleanup_session_id, "status": "running",
        "session": {"context_id": cleanup_context_id},
        "worktree_bindings": [{
            "worktree_id": cleanup_worktree_id,
            "worktree_root_path": cleanup_worktree_path,
            "branch": cleanup_branch, "head": cleanup_commit_oid,
        }],
    }
    cleanup_session_proof = cleanup_session_ownership_evidence(
        cleanup_snapshot, expected_session_id=cleanup_session_id,
        expected_context_id=cleanup_context_id, live_worktrees=cleanup_live_worktrees,
        artifact_name=cleanup_artifact_name, plan_commit_oid=cleanup_commit_oid,
    )
    checks["cleanup_live_session_relationship_proven"] = cleanup_session_proof["ok"]
    checks["cleanup_direct_poll_has_no_inventory_cap_dependency"] = (
        cleanup_session_proof["ok"] and cleanup_session_proof["session_id"] == cleanup_session_id
    )
    checks["cleanup_tampered_session_rejected"] = not cleanup_session_ownership_evidence(
        cleanup_snapshot, expected_session_id=str(uuid.uuid4()).upper(),
        expected_context_id=cleanup_context_id, live_worktrees=cleanup_live_worktrees,
        artifact_name=cleanup_artifact_name, plan_commit_oid=cleanup_commit_oid,
    )["ok"]
    wrong_branch_snapshot = json.loads(json.dumps(cleanup_snapshot))
    wrong_branch_snapshot["worktree_bindings"][0]["branch"] = "unrelated-branch"
    checks["cleanup_wrong_branch_rejected"] = not cleanup_session_ownership_evidence(
        wrong_branch_snapshot, expected_session_id=cleanup_session_id,
        expected_context_id=cleanup_context_id, live_worktrees=cleanup_live_worktrees,
        artifact_name=cleanup_artifact_name, plan_commit_oid=cleanup_commit_oid,
    )["ok"]
    wrong_context_snapshot = json.loads(json.dumps(cleanup_snapshot))
    wrong_context_snapshot["session"]["context_id"] = str(uuid.uuid4()).upper()
    checks["cleanup_wrong_context_rejected"] = not cleanup_session_ownership_evidence(
        wrong_context_snapshot, expected_session_id=cleanup_session_id,
        expected_context_id=cleanup_context_id, live_worktrees=cleanup_live_worktrees,
        artifact_name=cleanup_artifact_name, plan_commit_oid=cleanup_commit_oid,
    )["ok"]
    cleanup_state_worktree = {"path": cleanup_worktree_path, "branch": cleanup_branch}
    checks["cleanup_live_worktree_relationship_proven"] = cleanup_worktree_ownership_evidence(
        cleanup_state_worktree, live_worktrees=cleanup_live_worktrees,
        proven_sessions=[cleanup_session_proof], artifact_name=cleanup_artifact_name,
        plan_commit_oid=cleanup_commit_oid,
    )["ok"]
    checks["cleanup_worktree_requires_session_relationship"] = not cleanup_worktree_ownership_evidence(
        cleanup_state_worktree, live_worktrees=cleanup_live_worktrees,
        proven_sessions=[], artifact_name=cleanup_artifact_name,
        plan_commit_oid=cleanup_commit_oid,
    )["ok"]
    checks["cleanup_wrong_plan_commit_rejected"] = not cleanup_worktree_ownership_evidence(
        cleanup_state_worktree, live_worktrees=cleanup_live_worktrees,
        proven_sessions=[cleanup_session_proof], artifact_name=cleanup_artifact_name,
        plan_commit_oid="b" * 40,
    )["ok"]

    class MemoryRunnerFixture:
        def __init__(self, responses: list[dict[str, Any]]) -> None:
            self.responses = responses
            self.payloads: list[dict[str, Any]] = []

        def call(self, _label: str, _tool: str, payload: dict[str, Any], **_kwargs: Any) -> Any:
            self.payloads.append(payload)
            return self.responses.pop(0)

    started_memory_id = str(uuid.uuid4()).upper()
    start_memory_runner = MemoryRunnerFixture([
        {
            "ok": True, "op": "large_workspace_memory", "action": "current",
            "running": False,
        },
        {
            "ok": True, "op": "large_workspace_memory", "action": "start",
            "running": True, "session_id": started_memory_id,
            "session": {"id": started_memory_id, "label": cleanup_artifact_name,
                        "running": True},
        },
    ])
    start_acquisition = MemorySamplerAcquisition(label=cleanup_artifact_name)
    returned_memory_id, _ = start_owned_memory_sampler(
        start_memory_runner, cleanup_artifact_name, start_acquisition
    )
    checks["memory_start_returns_owner_without_reset_takeover"] = (
        returned_memory_id == started_memory_id
        and start_acquisition.session_id == started_memory_id
        and start_acquisition.acquisition_uncertain is False
        and [payload["action"] for payload in start_memory_runner.payloads]
        == ["current", "start"]
        and all("reset" not in payload for payload in start_memory_runner.payloads)
    )

    partial_memory_id = str(uuid.uuid4()).upper()
    partial_memory_runner = MemoryRunnerFixture([
        {
            "ok": True, "op": "large_workspace_memory", "action": "current",
            "running": False,
        },
        {
            "ok": True, "op": "large_workspace_memory", "action": "start",
            "running": True, "session_id": partial_memory_id,
            "session": {"label": cleanup_artifact_name, "running": True},
        },
        {
            "ok": True, "op": "large_workspace_memory", "action": "current",
            "running": True, "session_id": partial_memory_id,
            "session": {"id": partial_memory_id, "label": cleanup_artifact_name,
                        "running": True},
        },
        {
            "ok": True, "op": "large_workspace_memory", "action": "stop",
            "running": False, "session_id": partial_memory_id,
            "session": {"id": partial_memory_id, "label": cleanup_artifact_name,
                        "running": False},
        },
    ])
    partial_acquisition = MemorySamplerAcquisition(label=cleanup_artifact_name)
    try:
        start_owned_memory_sampler(
            partial_memory_runner, cleanup_artifact_name, partial_acquisition
        )
        partial_start_rejected = False
    except BenchmarkError:
        partial_start_rejected = True
    partial_cleanup, _ = cleanup_memory_sampler_acquisition(
        partial_memory_runner, partial_acquisition,
        label=cleanup_artifact_name, settle_seconds=0,
    )
    checks["memory_start_success_parse_failure_recovers_only_proven_owner"] = (
        partial_start_rejected
        and partial_acquisition.preflight_inactive_proven is True
        and partial_acquisition.start_attempted is True
        and partial_acquisition.acquisition_uncertain is True
        and partial_acquisition.session_id is None
        and partial_cleanup.get("ownership_proven") is True
        and partial_cleanup.get("recovered_uncertain_acquisition") is True
        and partial_cleanup.get("verified_stopped") is True
        and [payload["action"] for payload in partial_memory_runner.payloads]
        == ["current", "start", "current", "stop"]
        and partial_memory_runner.payloads[-1].get("session_id") == partial_memory_id
    )

    foreign_memory_id = str(uuid.uuid4()).upper()
    active_memory_runner = MemoryRunnerFixture([{
        "ok": True, "op": "large_workspace_memory", "action": "current",
        "running": True, "session_id": foreign_memory_id,
        "session": {
            "id": foreign_memory_id, "label": "foreign-owner",
            "running": True,
        },
    }])
    active_memory_action = verify_resumed_memory_sampler_inactive(
        active_memory_runner, expected_session_id=str(uuid.uuid4()).upper(),
        expected_label=cleanup_artifact_name,
    )
    checks["cleanup_active_global_memory_sampler_never_stopped"] = (
        active_memory_action["ok"] is False
        and active_memory_action["manual_cleanup"] is True
        and active_memory_action["stop_attempted"] is False
        and [payload["action"] for payload in active_memory_runner.payloads] == ["current"]
    )
    inactive_memory_runner = MemoryRunnerFixture([{
        "ok": True, "op": "large_workspace_memory", "action": "current",
        "running": False,
    }])
    inactive_memory_action = verify_resumed_memory_sampler_inactive(
        inactive_memory_runner, expected_session_id=str(uuid.uuid4()).upper(),
        expected_label=cleanup_artifact_name,
    )
    checks["cleanup_inactive_global_memory_sampler_verified"] = (
        inactive_memory_action["ok"] is True
        and inactive_memory_action["verified_stopped"] is True
        and inactive_memory_action["stop_attempted"] is False
        and [payload["action"] for payload in inactive_memory_runner.payloads] == ["current"]
    )
    owned_memory_id = str(uuid.uuid4()).upper()
    owned_memory_runner = MemoryRunnerFixture([
        {
            "ok": True, "op": "large_workspace_memory", "action": "current",
            "running": True, "session_id": owned_memory_id,
            "session": {"id": owned_memory_id, "label": cleanup_artifact_name,
                        "running": True},
        },
        {
            "ok": True, "op": "large_workspace_memory", "action": "stop",
            "running": False, "session_id": owned_memory_id,
            "session": {"id": owned_memory_id, "label": cleanup_artifact_name,
                        "running": False},
        },
    ])
    owned_memory_action = verify_resumed_memory_sampler_inactive(
        owned_memory_runner, expected_session_id=owned_memory_id,
        expected_label=cleanup_artifact_name,
    )
    checks["cleanup_stops_only_matching_memory_owner"] = (
        owned_memory_action["ok"] is True
        and owned_memory_action["ownership_proven"] is True
        and [payload["action"] for payload in owned_memory_runner.payloads]
        == ["current", "stop"]
        and owned_memory_runner.payloads[-1]["session_id"] == owned_memory_id
    )

    run_cleanup = [
        {"action": "terminalize_agent", "terminal": True},
        {
            "action": "remove_worktree", "removed": True,
            "ownership_proven": True, "worktree_absent": True,
            "branch_absent": True,
        },
        {"action": "stop_memory_sampler", "ok": True, "verified_stopped": True},
        {"action": "restore_route", "ok": True},
        {"action": "reset_diagnostics", "ok": True},
        {"action": "preserve_benchmark_setting", "ok": True},
        {"action": "restore_workspace_roots", "ok": True},
    ]
    checks["cleanup_complete"] = validate_cleanup_evidence(
        run_cleanup, run_artifact=True, expected_agent_count=1, expected_worktree_count=1
    )
    checks["cleanup_missing_rejected"] = not validate_cleanup_evidence(
        run_cleanup[:-1], run_artifact=True, expected_agent_count=1, expected_worktree_count=1
    )
    checks["cleanup_memory_unverified_rejected"] = not validate_cleanup_evidence(
        [dict(item, verified_stopped=False) if item["action"] == "stop_memory_sampler" else item for item in run_cleanup],
        run_artifact=True, expected_agent_count=1, expected_worktree_count=1,
    )
    for field in ("ownership_proven", "worktree_absent", "branch_absent"):
        checks[f"cleanup_{field}_required"] = not validate_cleanup_evidence(
            [dict(item, **{field: False}) if item["action"] == "remove_worktree" else item
             for item in run_cleanup],
            run_artifact=True, expected_agent_count=1, expected_worktree_count=1,
        )
    with tempfile.TemporaryDirectory() as cleanup_proof_temp:
        proof_dir = Path(cleanup_proof_temp) / "private-proof"
        proof_path = proof_dir / "cleanup.json"
        save_cleanup_proof(proof_path, [{
            "action": "terminalize_agent", "ok": True,
            "session_id": "session-id-sentinel", "path": "/private/path-sentinel",
        }])
        proof_text = proof_path.read_text(encoding="utf-8")
        checks["cleanup_proof_redacts_sensitive_identity"] = (
            "session-id-sentinel" not in proof_text
            and "/private/path-sentinel" not in proof_text
            and "session_id_sha256" in proof_text
            and "path_sha256" in proof_text
        )
        checks["cleanup_proof_permissions_private"] = (
            proof_dir.stat().st_mode & 0o777 == 0o700
            and proof_path.stat().st_mode & 0o777 == 0o600
        )
    setup_failure_cleanup = [
        {"action": "stop_memory_sampler", "ok": True, "verified_stopped": True,
         "reason": "not_acquired"},
        {"action": "restore_route", "ok": True, "reason": "not_acquired"},
        {"action": "reset_diagnostics", "ok": True},
        {"action": "preserve_benchmark_setting", "ok": True},
        {"action": "restore_workspace_roots", "ok": True},
    ]
    checks["setup_failure_cleanup_is_complete_without_owned_resources"] = validate_cleanup_evidence(
        setup_failure_cleanup, run_artifact=True,
        expected_agent_count=0, expected_worktree_count=0,
    )
    frozen_matrix_fixture = {
        "matrix": {
            "process_states": ["warm", "aged"],
            "checkout_kinds": ["linked-worktree"],
            "routes": ["baseline", "forced-full", "projected"],
            "widths": [1, 4, 8],
        },
        "thresholds": {
            "projected_p95_improvement_minimum": 0.30,
            "other_p95_regression_maximum": 0.10,
            "peak_memory_regression_maximum": 0.10,
        },
    }
    frozen_keys = configured_required_matrix_keys(frozen_matrix_fixture)
    checks["aggregate_uses_exact_frozen_matrix_variants"] = (
        len(frozen_keys) == 18
        and all(key.split("/")[0] in {"warm", "aged"} for key in frozen_keys)
        and all(key.rsplit("/", 1)[1] in {"1", "4", "8"} for key in frozen_keys)
        and not any("/cold/" in f"/{key}/" or key.endswith("/2") for key in frozen_keys)
        and frozen_matrix_fixture["thresholds"]["projected_p95_improvement_minimum"] == 0.30
        and frozen_matrix_fixture["thresholds"]["other_p95_regression_maximum"] == 0.10
    )
    fixed_stats = stats([100, 200, 300, 400, 500], positive=True, label="fixed readiness")
    checks["fixed_percentiles"] = fixed_stats["p50"] == 300 and fixed_stats["p95"] == 500
    checks["fixed_cv"] = math.isclose(float(fixed_stats["cv"]), math.sqrt(25_000) / 300)
    checks["confirmation_not_required_at_boundary"] = confirmation_policy(
        {"control_p95": 100, "candidate_p95": 70, "control_cv": 0.50, "candidate_cv": 0.10},
        None, minimum_improvement=0.30,
    )["status"] == "pass"
    checks["high_variance_requires_confirmation"] = confirmation_policy(
        {"control_p95": 100, "candidate_p95": 70, "control_cv": 0.51, "candidate_cv": 0.10},
        None, minimum_improvement=0.30,
    )["status"] == "high-variance/inconclusive"
    checks["high_cv_confirmation_policy_unchanged"] = confirmation_policy(
        {"control_p95": 100, "candidate_p95": 70, "control_cv": 0.500001, "candidate_cv": 0.50},
        None, minimum_improvement=0.30,
    ) == {
        "status": "high-variance/inconclusive",
        "direction": "pass",
        "confirmation_required": True,
    }
    checks["directional_confirmation_agrees"] = confirmation_policy(
        {"control_p95": 100, "candidate_p95": 70, "control_cv": 0.51, "candidate_cv": 0.10},
        {"control_p95": 200, "candidate_p95": 130}, minimum_improvement=0.30,
    )["status"] == "pass"
    checks["directional_confirmation_disagrees"] = confirmation_policy(
        {"control_p95": 100, "candidate_p95": 70, "control_cv": 0.51, "candidate_cv": 0.10},
        {"control_p95": 200, "candidate_p95": 150}, minimum_improvement=0.30,
    )["status"] == "high-variance/inconclusive"
    with tempfile.TemporaryDirectory(prefix="rpce-worktree-timeout-self-test-") as timeout_raw:
        timeout_root = Path(timeout_raw)
        timeout_artifact = timeout_root / "artifact"
        (timeout_artifact / "raw").mkdir(parents=True)
        timeout_cli = timeout_root / "timeout-cli"
        timeout_cli.write_text("#!/bin/sh\nsleep 1\n", encoding="utf-8")
        timeout_cli.chmod(0o700)
        preparation_id = str(uuid.uuid4())
        timeout_runner = CLIRunner(
            timeout_cli,
            1,
            str(uuid.uuid4()),
            timeout_root,
            timeout_artifact,
        )
        try:
            timeout_runner.timed_call(
                "timeout-contract",
                DEBUG_TOOL,
                {"preparation_id": preparation_id},
                timeout=0.01,
            )
            checks["timed_call_timeout_raw_record"] = False
        except subprocess.TimeoutExpired:
            raw_records = sorted((timeout_artifact / "raw").glob("*.json"))
            timeout_record = json.loads(raw_records[0].read_text(encoding="utf-8")) if raw_records else {}
            checks["timed_call_timeout_raw_record"] = (
                timeout_record.get("timed_out") is True
                and timeout_record.get("timeout_seconds") == 0.01
                and timeout_record.get("preparation_id") == preparation_id
                and isinstance(timeout_record.get("started_monotonic_ns"), int)
                and isinstance(timeout_record.get("finished_monotonic_ns"), int)
                and "stdout" in timeout_record
                and "stderr" in timeout_record
            )

    class TimeoutQueryRunner:
        artifact = None

        def __init__(self) -> None:
            self.calls: list[tuple[str, dict[str, Any], float]] = []

        def timed_call(
            self,
            label: str,
            _tool: str,
            payload: dict[str, Any],
            *,
            timeout: float = 300,
            check: bool = True,
            context_id: str | None = None,
        ) -> TimedCall:
            del check, context_id
            self.calls.append((label, payload, timeout))
            if len(self.calls) == 1:
                raise subprocess.TimeoutExpired(["debug-cli"], timeout)
            return TimedCall({"ok": True}, 1, 2, 0)

    query_runner = TimeoutQueryRunner()
    query_plan = {
        "scope": {
            "window_id": 1,
            "workspace_id": str(uuid.uuid4()),
            "context_id": str(uuid.uuid4()),
            "root_id": str(uuid.uuid4()),
        }
    }
    try:
        set_route(query_runner, query_plan, "projected")  # type: ignore[arg-type]
        checks["set_route_timeout_queries_preparation"] = False
    except BenchmarkError:
        checks["set_route_timeout_queries_preparation"] = (
            len(query_runner.calls) == 2
            and query_runner.calls[0][2] == 300
            and query_runner.calls[1][1].get("action") == "preparation_snapshot"
            and query_runner.calls[1][2] == 15
            and query_runner.calls[0][1].get("preparation_id")
            == query_runner.calls[1][1].get("preparation_id")
        )
    bypass_counter_fixture = {
        "preparation": {
            "counters": {"prefix_cache_bypasses": 0},
            "counter_saturated": {"prefix_cache_bypasses": False},
        }
    }
    checks["policy_digest_probe_cache_bypass_not_inferred_from_field_presence"] = (
        prefix_control_cache_bypass_evidence(bypass_counter_fixture)["observed"] is False
    )
    bypass_counter_fixture["preparation"]["counters"]["prefix_cache_bypasses"] = 1
    checks["policy_digest_probe_cache_bypass_requires_positive_counter"] = (
        prefix_control_cache_bypass_evidence(bypass_counter_fixture)
        == {"counter": 1, "counter_saturated": False, "observed": True}
    )
    bypass_counter_fixture["preparation"]["counter_saturated"]["prefix_cache_bypasses"] = True
    checks["policy_digest_probe_cache_bypass_rejects_saturated_counter"] = (
        prefix_control_cache_bypass_evidence(bypass_counter_fixture)["observed"] is False
    )
    probe_args = configure_policy_digest_probe(argparse.Namespace())
    checks["policy_digest_probe_configuration_exact"] = {
        "process_state": probe_args.process_state,
        "checkout_kind": probe_args.checkout_kind,
        "route": probe_args.route,
        "width": probe_args.width,
        "invocation": probe_args.invocation,
        "warmups": probe_args.warmups,
        "samples": probe_args.samples,
        "bypass_prefix_control_cache": probe_args.bypass_prefix_control_cache,
        "expected_route_observation_count": probe_args.expected_route_observation_count,
        "policy_digest_probe": probe_args.policy_digest_probe,
    } == {
        "process_state": "warm",
        "checkout_kind": "linked-worktree",
        "route": "projected",
        "width": 1,
        "invocation": 1,
        "warmups": 0,
        "samples": 1,
        "bypass_prefix_control_cache": True,
        "expected_route_observation_count": (
            policy_digest_probe_route_observation_count("diffSeedServing")
        ),
        "policy_digest_probe": True,
    }
    checks["policy_digest_probe_non_aggregatable"] = is_policy_digest_probe_summary({
        "kind": "policy-digest-probe",
        "non_aggregatable": True,
    }) and not is_policy_digest_probe_summary({"kind": "cohort"})
    if not all(checks.values()):
        raise BenchmarkError(f"self-test failed: {[name for name, ok in checks.items() if not ok]}")
    print(json.dumps({"status": "completed", "checks": checks}, indent=2, sort_keys=True))
    return 0


def scope_response_record(value: Any) -> dict[str, Any]:
    benchmark_binding(value)
    return find_object(benchmark_final_response(value), "root_id")


def verify_scope(runner: CLIRunner, plan: dict[str, Any]) -> dict[str, Any]:
    scope = plan["scope"]
    payload = {
        "op": "worktree_startup_benchmark",
        "action": "scope",
        "window_id": scope["window_id"],
        "workspace_id": scope["workspace_id"],
        "context_id": scope["context_id"],
        "benchmark_context_id": scope["context_id"],
        "expected_root_path": scope["root_path"],
    }
    response = runner.call("scope", DEBUG_TOOL, payload)
    actual = scope_response_record(response)
    expected = {
        "window_id": scope["window_id"],
        "workspace_id": scope["workspace_id"],
        "context_id": scope["context_id"],
        "root_id": scope["root_id"],
    }
    for key, value in expected.items():
        if str(actual.get(key)).upper() != str(value).upper():
            raise BenchmarkError(f"scope mismatch for {key}")
    return actual


def workspace_inventory_record(value: Any, workspace_id: str) -> dict[str, Any]:
    matches: list[dict[str, Any]] = []
    benchmark_binding(value)
    for candidate in walk_json(benchmark_final_response(value)):
        if not isinstance(candidate, dict):
            continue
        candidate_id = candidate.get("id") or candidate.get("workspace_id")
        if isinstance(candidate_id, str) and candidate_id.upper() == workspace_id.upper():
            matches.append(candidate)
    if len(matches) != 1:
        raise BenchmarkError("workspace inventory did not contain exactly one planned workspace identity")
    return matches[0]


def workspace_root_paths(record: dict[str, Any]) -> list[str]:
    for key in ("repo_paths", "repoPaths", "all_repo_paths", "allRepoPaths", "folder_paths"):
        value = record.get(key)
        if isinstance(value, list) and all(isinstance(item, str) for item in value):
            return [str(Path(item).expanduser().resolve()) for item in value]
    raise BenchmarkError("workspace inventory omitted root paths")


def verify_disposable_target(
    runner: CLIRunner,
    plan: dict[str, Any],
    *,
    require_only_planned_root: bool,
) -> dict[str, Any]:
    scope = plan["scope"]
    root = Path(scope["root_path"]).resolve(strict=True)
    real_repository = scope.get("target_kind") == "real-repository-dedicated"
    if real_repository:
        if (
            scope.get("explicit_real_repository_confirmation") is not True
            or root != repository_root().resolve()
            or not str(scope.get("workspace_name", "")).startswith("RPCE Search Bench ")
        ):
            raise BenchmarkError("real repository target lost its strict dedicated-workspace identity")
    validate_ownership_marker(
        root,
        workspace_id=scope["workspace_id"],
        root_id=scope["root_id"],
        owner_token=scope["owner_token"],
        expected_sha256=scope["ownership_marker_sha256"],
        allow_real_repository=real_repository,
    )
    inventory = runner.call(
        "workspace-identity", "manage_workspaces", {"action": "list", "include_hidden": True}
    )
    record = workspace_inventory_record(inventory, scope["workspace_id"])
    if record.get("name") != scope["workspace_name"]:
        raise BenchmarkError("planned workspace identity was renamed or substituted")
    roots = workspace_root_paths(record)
    planned_root = str(root)
    if planned_root not in roots:
        raise BenchmarkError("planned root is not owned by the planned workspace identity")
    if require_only_planned_root and roots != [planned_root]:
        raise BenchmarkError("benchmark workspace must contain exactly the planned root before/after the campaign")
    return {"workspace_id": scope["workspace_id"], "workspace_name": record.get("name"), "roots": roots}


def require_benchmark_gate(runner: CLIRunner) -> None:
    response = runner.call(
        "benchmark-gate-status", "app_settings", {"op": "get", "key": BENCHMARK_GATE_KEY}
    )
    enabled: bool | None = None
    for candidate in walk_json(response):
        if not isinstance(candidate, dict):
            continue
        values = candidate.get("values")
        if isinstance(values, dict) and isinstance(values.get(BENCHMARK_GATE_KEY), bool):
            enabled = values[BENCHMARK_GATE_KEY]
            break
        if candidate.get("key") == BENCHMARK_GATE_KEY:
            value = candidate.get("value")
            if isinstance(value, bool):
                enabled = value
                break
    if enabled is not True:
        raise BenchmarkError(
            f"DEBUG benchmark gate {BENCHMARK_GATE_KEY!r} must be explicitly enabled before the campaign"
        )


def preflight_command(args: argparse.Namespace) -> int:
    if not args.confirm_live_debug_app:
        raise BenchmarkError("pass --confirm-live-debug-app after verifying the dedicated DEBUG app is already running")
    plan_path = Path(args.plan).expanduser().resolve(strict=True)
    plan = load_plan(plan_path)
    if plan["scope"].get("target_kind") == "real-repository-dedicated" and not args.confirm_dedicated_workspace:
        raise BenchmarkError("real-repository preflight requires --confirm-dedicated-workspace")
    cli = resolve_cli(args.cli)
    root = Path(plan["scope"]["root_path"])
    dataset = plan["dataset"]
    base_commit_oid = validate_planned_base_commit(plan, root)
    read_blob_sha256 = validate_tracked_read_fixture(
        root, base_ref=base_commit_oid, read_path=dataset["read_path"],
        search_marker=dataset["search_marker"], read_marker=dataset["read_marker"],
    )
    planned_blob_sha256 = dataset.get("read_blob_sha256")
    if planned_blob_sha256 is not None and planned_blob_sha256 != read_blob_sha256:
        raise BenchmarkError("tracked read-path blob changed since plan creation")
    artifact = make_artifact(Path(args.output_root), "preflight")
    runner = CLIRunner(
        cli, plan["scope"]["window_id"], plan["scope"]["context_id"], root, artifact
    )
    schemas: dict[str, str] = {}
    for tool in (
        "bind_context", "manage_workspaces", "agent_run", "agent_manage", "manage_worktree",
        "file_search", "read_file", "manage_selection", "get_code_structure", "file_actions",
        "apply_edits", "app_settings", DEBUG_TOOL,
    ):
        schema = runner.describe(tool)
        schemas[tool] = sha256_bytes(schema.encode())
        secure_write(artifact / "schemas" / f"{tool}.txt", schema.encode(), exclusive=True)
    if "_worktree_startup_benchmark_token" not in (artifact / "schemas" / "agent_run.txt").read_text():
        raise BenchmarkError("agent_run schema omitted the DEBUG benchmark token")
    if "remove_folder" not in (artifact / "schemas" / "manage_workspaces.txt").read_text():
        raise BenchmarkError("manage_workspaces schema omitted remove_folder")
    verified = verify_scope(runner, plan)
    require_benchmark_gate(runner)
    target = verify_disposable_target(runner, plan, require_only_planned_root=True)
    summary = {
        "schema_version": SCHEMA_VERSION,
        "status": "completed",
        "plan_sha256": plan["plan_sha256"],
        "cli": str(cli),
        "cli_sha256": sha256_bytes(cli.read_bytes()),
        "schema_sha256": schemas,
        "base_commit_oid": base_commit_oid,
        "read_blob_sha256": read_blob_sha256,
        "scope": verified,
        "disposable_target": target,
        "artifact_directory": str(artifact),
    }
    save_json(artifact / "summary.json", summary, exclusive=True)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


def diagnostic_payload(plan: dict[str, Any], action: str, **extra: Any) -> dict[str, Any]:
    return {"op": "worktree_startup_benchmark", "action": action, **exact_scope(plan), **extra}


def validate_preparation_snapshot(value: Any, preparation_id: str, terminal: str) -> dict[str, Any]:
    preparation = find_value(value, "preparation")
    if not isinstance(preparation, dict):
        raise BenchmarkError("set_flags omitted the preparation snapshot")
    required_phases = {
        "scope_resolution", "set_flags_total", "loaded_root_ingress_fence",
        "loaded_root_policy_snapshot", "discovery_observation", "discovery_authority_capture",
        "replacement_observation", "collection_fence", "captured_authority_capture",
        "captured_observation_validation", "authority_metadata_git", "prefix_control_cache_lookup",
        "prefix_control_scan", "prefix_control_cache_admit", "tree_inventory_spool",
        "catalog_manifest_build", "authority_install", "snapshot_materialization",
        "admission_prepare", "prepared_admission_currentness", "admission_commit",
        "committed_admission_currentness", "final_loaded_root_currentness",
    }
    required_counters = {
        "authority_captures", "git_command_count", "git_queue_us", "git_duration_us",
        "prefix_cache_hits", "prefix_cache_misses", "prefix_cache_invalidations",
        "prefix_cache_admissions", "prefix_cache_evictions", "prefix_cache_bypasses",
        "prefix_cache_coalesces",
        "prefix_scan_count", "enumerated_candidates", "enumerated_directories",
        "explicitly_pruned_directories", "control_record_count", "tree_records",
        "tree_spool_bytes", "inventory_records", "catalog_batches", "catalog_regular_paths",
        "snapshot_searchable_paths",
    }
    phases, counters, saturation = (
        preparation.get("phases"), preparation.get("counters"), preparation.get("counter_saturated")
    )
    if preparation.get("preparation_id", "").upper() != preparation_id.upper():
        raise BenchmarkError("preparation snapshot ID mismatch")
    if preparation.get("terminal_state") != terminal or preparation.get("path_free") is not True:
        raise BenchmarkError("preparation snapshot terminal/privacy contract mismatch")
    if not isinstance(phases, dict) or set(phases) != required_phases:
        raise BenchmarkError("preparation snapshot phase schema mismatch")
    if not isinstance(counters, dict) or set(counters) != required_counters:
        raise BenchmarkError("preparation snapshot counter schema mismatch")
    if not isinstance(saturation, dict) or set(saturation) != required_counters:
        raise BenchmarkError("preparation snapshot saturation schema mismatch")
    return preparation


def prefix_control_cache_bypass_evidence(value: Any) -> dict[str, Any]:
    """Derive bypass truth only from a valid, unsaturated preparation counter."""
    try:
        preparation = find_value(value, "preparation")
    except BenchmarkError:
        preparation = None
    counters = preparation.get("counters") if isinstance(preparation, dict) else None
    saturation = preparation.get("counter_saturated") if isinstance(preparation, dict) else None
    counter = counters.get("prefix_cache_bypasses") if isinstance(counters, dict) else None
    saturated = saturation.get("prefix_cache_bypasses") if isinstance(saturation, dict) else None
    observed = (
        nonnegative_integer(counter)
        and counter > 0
        and saturated is False
    )
    return {
        "counter": counter if nonnegative_integer(counter) else None,
        "counter_saturated": saturated if isinstance(saturated, bool) else None,
        "observed": observed,
    }


def set_route(
    runner: CLIRunner,
    plan: dict[str, Any],
    route: str,
    *,
    bypass_prefix_control_cache: bool = False,
) -> tuple[str, Any]:
    config = ROUTES[route]
    preparation_id = str(uuid.uuid4())
    payload = diagnostic_payload(
        plan,
        "set_flags",
        preparation_id=preparation_id,
        bypass_prefix_control_cache=bypass_prefix_control_cache,
        expires_seconds=900,
        **{key: config[key] for key in ("observe", "serve", "force_full")},
    )
    try:
        response = runner.timed_call(f"set-route-{route}", DEBUG_TOOL, payload).response
    except subprocess.TimeoutExpired as error:
        snapshot_response: Any = None
        snapshot_error: str | None = None
        try:
            snapshot_response = runner.timed_call(
                f"set-route-{route}-preparation-snapshot-after-timeout",
                DEBUG_TOOL,
                diagnostic_payload(plan, "preparation_snapshot", preparation_id=preparation_id),
                timeout=15,
                check=False,
            ).response
        except Exception as snapshot_exception:  # Preserve the original fixed-deadline failure.
            snapshot_error = f"{type(snapshot_exception).__name__}: {snapshot_exception}"
        timeout_record = {
            "preparation_id": preparation_id,
            "timeout_seconds": error.timeout,
            "preparation_snapshot": snapshot_response,
            "preparation_snapshot_error": snapshot_error,
        }
        if runner.artifact:
            save_json(runner.artifact / "preparation-timeout.json", timeout_record, exclusive=True)
        raise BenchmarkError(
            f"{route} set_flags timed out after {error.timeout}s; preparation_id={preparation_id}"
        ) from error
    validate_preparation_snapshot(response, preparation_id, "admitted")
    control_id = find_value(response, "control_id")
    if not isinstance(control_id, str):
        raise BenchmarkError(f"{route} control omitted control_id")
    if route == "projected" and find_value(response, "base_snapshot_prepared") is not True:
        raise BenchmarkError("projected route did not prepare a base snapshot")
    return control_id, response


def arm_sample(
    runner: CLIRunner,
    plan: dict[str, Any],
    control_id: str,
    route: str,
    process_state: str,
    invocation: int,
    ordinal: int,
    warmup: bool,
    branch: str,
) -> tuple[str, str]:
    scenario = "aged" if process_state == "aged" else "parallel" if ordinal > 1 else "clean_same_tree"
    response = runner.call(
        f"arm-{route}-{ordinal}", DEBUG_TOOL,
        diagnostic_payload(
            plan, "arm", control_id=control_id, scenario=scenario, invocation=invocation,
            ordinal=ordinal, warmup=warmup, expires_seconds=900,
            worktree_base_ref=plan["dataset"]["base_commit_oid"],
            worktree_branch=branch,
        ),
    )
    token, correlation = find_value(response, "token"), find_value(response, "correlation_id")
    if not isinstance(token, str) or not isinstance(correlation, str):
        raise BenchmarkError("arm response omitted token or correlation_id")
    return token, correlation


def start_agent(
    runner: CLIRunner,
    plan: dict[str, Any],
    route: str,
    token: str,
    invocation: int,
    ordinal: int,
    label: str,
    branch: str,
) -> Any:
    return runner.call(
        f"agent-start-{ordinal}", "agent_run",
        {
            "op": "start", "model_id": "explore", "detach": True,
            "message": "Reply exactly RPCE_WORKTREE_STARTUP_READY and stop. Do not edit files or invoke tools.",
            "session_name": f"RPCE startup {route} {ordinal}",
            "worktree_create": True, "worktree_branch": branch,
            "worktree_base_ref": plan["dataset"]["base_commit_oid"],
            "worktree_label": f"RPCE startup {label} {ordinal}",
            "context_id": plan["scope"]["context_id"],
            "_worktree_startup_benchmark_token": token,
        },
        timeout=180,
    )


def mark(runner: CLIRunner, plan: dict[str, Any], correlation: str, phase: str) -> None:
    runner.call(
        f"mark-{phase}", DEBUG_TOOL,
        diagnostic_payload(plan, "mark", correlation_id=correlation, mark=phase),
    )


def safe_mark(
    runner: CLIRunner, plan: dict[str, Any], correlation: str, phase: str
) -> dict[str, str] | None:
    try:
        mark(runner, plan, correlation, phase)
        return None
    except BaseException as error:
        return {"phase": phase, "type": "mark_error", "error": repr(error)}


def operation_failure_type(error: BaseException | str) -> str:
    text = str(error).lower()
    if isinstance(error, subprocess.TimeoutExpired) or "timeout" in text or "timed out" in text:
        return "timeout"
    if isinstance(error, str):
        return "malformed"
    if isinstance(error, BenchmarkError):
        return "malformed"
    return "transport_error"


def capture_diagnostic(
    runner: CLIRunner,
    plan: dict[str, Any],
    correlation: str,
    *,
    action: str,
    label: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    try:
        response = runner.call(
            label, DEBUG_TOOL,
            diagnostic_payload(plan, action, correlation_id=correlation),
            check=False,
        )
        if not call_succeeded(response):
            raise BenchmarkError("diagnostic call failed or returned malformed output")
        return find_object(response, "sample"), {"ok": True, "type": "success"}
    except BaseException as error:
        return {}, {
            "ok": False,
            "type": operation_failure_type(error),
            "error": repr(error),
        }


def first_search_read(
    runner: CLIRunner,
    plan: dict[str, Any],
    correlation: str,
    context_id: str,
    worktree_path: Path,
    worktree_id: str,
) -> tuple[dict[str, bool], dict[str, Any], dict[str, str]]:
    routed = {"context_id": context_id}
    runtime = runner.call(
        "first-tools-root-identity", DEBUG_TOOL,
        {"op": "mcp_read_search_runtime_snapshot", "window_id": plan["scope"]["window_id"],
         "recent_publication_limit": 0, "root_limit": 256}, check=False, context_id=context_id,
    )
    physical_root_identity = runtime_root_identity(runtime, str(worktree_path))
    root_identity = {
        "id": plan["scope"]["root_id"],
        "path": plan["scope"]["root_path"],
        "type": "primary_workspace",
    }
    marker_failures = [
        failure for failure in (
            safe_mark(runner, plan, correlation, "first_search_started"),
            safe_mark(runner, plan, correlation, "first_read_started"),
        ) if failure is not None
    ]
    calls: dict[str, TimedCall] = {}
    call_failures: dict[str, dict[str, str]] = {}
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = {
            pool.submit(
                runner.timed_call, "first-search", "file_search",
                {"pattern": plan["dataset"]["search_marker"], "regex": False, "mode": "content",
                 "filter": {"paths": [plan["dataset"]["read_path"]]}, "max_results": 20, **routed},
                check=False,
                context_id=context_id,
            ): "search",
            pool.submit(
                runner.timed_call, "first-read", "read_file",
                {"path": plan["dataset"]["read_path"], "start_line": 1, "limit": 80, **routed},
                check=False,
                context_id=context_id,
            ): "read",
        }
        for future in as_completed(futures):
            name = futures[future]
            try:
                calls[name] = future.result()
            except BaseException as error:
                call_failures[name] = {
                    "type": operation_failure_type(error), "error": repr(error),
                }
            finally:
                completion_failure = safe_mark(
                    runner, plan, correlation, f"first_{name}_completed"
                )
                if completion_failure is not None:
                    marker_failures.append(completion_failure)

    def direct_evidence(name: str, tool: str, marker: str) -> dict[str, Any]:
        if name in call_failures:
            return {"ok": False, **call_failures[name]}
        timed = calls.get(name)
        if timed is None:
            return {"ok": False, "type": "malformed", "error": "missing direct call result"}
        evidence = structured_success_evidence(
            timed.response, tool, expected_root_id=root_identity["id"],
            expected_root_path=root_identity["path"], expected_root_type=root_identity["type"],
            expected_file_path=plan["dataset"]["read_path"], expected_file_type="file",
            expected_content=marker, expected_worktree_id=worktree_id,
            expected_physical_worktree_path=str(worktree_path),
        )
        if evidence.get("ok") is not True:
            evidence["type"] = operation_failure_type(str(evidence.get("error") or "malformed"))
        return evidence

    search_evidence = direct_evidence("search", "file_search", plan["dataset"]["search_marker"])
    read_evidence = direct_evidence("read", "read_file", plan["dataset"]["read_marker"])
    concurrent = False
    if set(calls) == {"search", "read"}:
        concurrent = max(calls["search"].started_ns, calls["read"].started_ns) < min(
            calls["search"].finished_ns, calls["read"].finished_ns
        )
    evidence = {
        "concurrent": concurrent,
        "search_duration_us": (
            (calls["search"].finished_ns - calls["search"].started_ns) / 1000
            if "search" in calls else None
        ),
        "read_duration_us": (
            (calls["read"].finished_ns - calls["read"].started_ns) / 1000
            if "read" in calls else None
        ),
        "search": search_evidence, "read": read_evidence,
        "physical_runtime_root": physical_root_identity,
        "mark_failures": marker_failures,
    }
    return {
        "search": search_evidence.get("ok") is True and concurrent and not marker_failures,
        "read": read_evidence.get("ok") is True and concurrent and not marker_failures,
    }, evidence, root_identity


def collect_follow_on_evidence(
    runner: CLIRunner, plan: dict[str, Any], correlation: str, context_id: str,
    root_identity: dict[str, str], worktree_id: str, worktree_path: Path,
) -> dict[str, Any]:
    path = plan["dataset"]["read_path"]
    parent = str(Path(path).parent)
    # RepoPrompt intentionally displays the logical canonical root for
    # session-bound worktree tools. The first search/read probes separately
    # prove the physical effective worktree; follow-on tools must therefore
    # validate the logical binding plus their structured worktree_scope.
    logical_root_id = plan["scope"]["root_id"]
    logical_root_path = plan["scope"]["root_path"]
    logical_root_type = "primary_workspace"
    structures: list[dict[str, Any]] = []
    operation_failures: list[dict[str, Any]] = []

    def timed_operation(
        mark_prefix: str,
        label: str,
        tool: str,
        payload: dict[str, Any],
        validator: Any,
    ) -> tuple[dict[str, Any], TimedCall | None]:
        item: dict[str, Any] = {
            "operation": mark_prefix,
            "start_mark_attempted": True,
            "start_marked": False,
            "completion_mark_attempted": False,
            "completion_marked": False,
        }
        start_failure = safe_mark(runner, plan, correlation, f"{mark_prefix}_started")
        item["start_marked"] = start_failure is None
        if start_failure is not None:
            item["mark_failures"] = [start_failure]
            item["error"] = start_failure["error"]
        timed: TimedCall | None = None
        try:
            timed = runner.timed_call(
                label, tool, payload, check=False, context_id=context_id,
            )
            validated = validator(timed.response)
            validator_ok = validated.get("ok", True)
            item.update({key: value for key, value in validated.items() if key != "ok"})
            item["ok"] = validator_ok is True and start_failure is None
            if item["ok"] is True:
                item["type"] = "success"
            elif start_failure is not None:
                item["type"] = "mark_error"
            else:
                item["type"] = operation_failure_type(
                    str(item.get("error") or "malformed follow-on response")
                )
        except BaseException as error:
            item["ok"] = False
            item["type"] = "mark_error" if start_failure is not None else operation_failure_type(error)
            item.setdefault("error", repr(error))
        finally:
            item["completion_mark_attempted"] = True
            completion_failure = safe_mark(
                runner, plan, correlation, f"{mark_prefix}_completed"
            )
            item["completion_marked"] = completion_failure is None
            if completion_failure is not None:
                item["ok"] = False
                item.setdefault("mark_failures", []).append(completion_failure)
                item["type"] = "mark_error"
                item.setdefault("error", completion_failure["error"])
        if timed is not None:
            item["duration_us"] = (timed.finished_ns - timed.started_ns) / 1000
        if item.get("ok") is not True:
            operation_failures.append({
                "operation": mark_prefix,
                "type": item.get("type") or "malformed",
                "error": item.get("error"),
            })
        return item, timed

    for mark_prefix, label in (("first_codemap", "first-codemap"), ("warm_codemap", "warm-codemap")):
        item, _ = timed_operation(
            mark_prefix, label, "get_code_structure",
            {"scope": "paths", "paths": [path], "context_id": context_id},
            lambda response: codemap_structure_evidence(
                response, expected_root_id=logical_root_id,
                expected_root_path=logical_root_path,
                expected_root_type=logical_root_type, expected_file_path=path,
                expected_marker=plan["dataset"]["read_marker"],
                expected_file_type=plan["dataset"]["code_file_type"],
                expected_worktree_id=worktree_id,
                expected_physical_worktree_path=str(worktree_path),
            ),
        )
        structures.append(item)

    def tree_validator(response: Any) -> dict[str, Any]:
        try:
            return {
                **codemap_tree_marker_evidence(
                    response, expected_context_id=context_id,
                    expected_root_path=logical_root_path, requested_parent=parent,
                    expected_file_path=path, expected_worktree_id=worktree_id,
                    expected_physical_worktree_path=str(worktree_path),
                ),
                "ok": True,
            }
        except BenchmarkError as error:
            return {"ok": False, "error": str(error)}

    tree_evidence, _ = timed_operation(
        "passive_tree", "passive-tree", "get_file_tree",
        {"type": "files", "mode": "full", "path": parent, "max_depth": 1,
         "context_id": context_id},
        tree_validator,
    )

    selection_started_ns = time.monotonic_ns()
    selection_record: dict[str, Any] = {
        "operation": "selection",
        "start_mark_attempted": True,
        "start_marked": False,
        "completion_mark_attempted": False,
        "completion_marked": False,
        "set_attempted": True,
        "get_attempted": False,
        "get_result_recorded": False,
    }
    selection_start_failure = safe_mark(
        runner, plan, correlation, "selection_started"
    )
    selection_record["start_marked"] = selection_start_failure is None
    selection_errors: list[tuple[str, str]] = []
    if selection_start_failure is not None:
        selection_record["mark_failures"] = [selection_start_failure]
        selection_errors.append(("mark_error", selection_start_failure["error"]))
    selection_timed: TimedCall | None = None
    try:
        selection_timed = runner.timed_call(
            "selection-set", "manage_selection",
            {"op": "set", "paths": [path], "mode": "full", "context_id": context_id},
            check=False, context_id=context_id,
        )
        selection_record["set"] = {"ok": call_succeeded(selection_timed.response)}
        if not call_succeeded(selection_timed.response):
            selection_errors.append(("malformed", "selection set failed"))
    except BaseException as error:
        selection_record["set"] = {"ok": False, "error": repr(error)}
        selection_errors.append((operation_failure_type(error), repr(error)))
    selection_get_timed: TimedCall | None = None
    try:
        selection_record["get_attempted"] = True
        selection_get_timed = runner.timed_call(
            "selection-get", "manage_selection",
            {"op": "get", "view": "files", "context_id": context_id},
            check=False, context_id=context_id,
        )
        selection_record["get_result_recorded"] = True
        selection_evidence = structured_success_evidence(
            selection_get_timed.response, "manage_selection", expected_root_id=logical_root_id,
            expected_root_path=logical_root_path, expected_root_type=logical_root_type,
            expected_file_path=path, expected_file_type="file",
            expected_worktree_id=worktree_id,
            expected_physical_worktree_path=str(worktree_path),
        )
        if selection_evidence.get("ok") is not True:
            selection_evidence["type"] = operation_failure_type(
                str(selection_evidence.get("error") or "malformed selection response")
            )
            selection_errors.append((
                selection_evidence["type"],
                str(selection_evidence.get("error") or "malformed selection response"),
            ))
    except BaseException as error:
        selection_evidence = {
            "ok": False, "type": operation_failure_type(error), "error": repr(error),
        }
        selection_errors.append((selection_evidence["type"], repr(error)))
    finally:
        selection_record["completion_mark_attempted"] = True
        selection_record["completion_mark_attempted_ns"] = time.monotonic_ns()
        completion_failure = safe_mark(
            runner, plan, correlation, "selection_completed"
        )
        selection_record["completion_marked"] = completion_failure is None
        if completion_failure is not None:
            selection_record.setdefault("mark_failures", []).append(completion_failure)
            selection_errors.append(("mark_error", completion_failure["error"]))
    if selection_get_timed is not None:
        selection_record["get_finished_ns"] = selection_get_timed.finished_ns
    selection_ok = (
        selection_record["start_marked"] is True
        and selection_record["completion_marked"] is True
        and selection_record.get("set", {}).get("ok") is True
        and selection_evidence.get("ok") is True
        and selection_record["get_result_recorded"] is True
        and isinstance(selection_record.get("get_finished_ns"), int)
        and selection_record["get_finished_ns"]
        <= selection_record["completion_mark_attempted_ns"]
    )
    selection_type = "success" if selection_ok else (
        "mark_error" if any(kind == "mark_error" for kind, _ in selection_errors)
        else selection_errors[0][0] if selection_errors else "malformed"
    )
    selection_record.update(selection_evidence)
    selection_record["ok"] = selection_ok
    selection_record["type"] = selection_type
    selection_record["duration_us"] = (
        (time.monotonic_ns() - selection_started_ns) / 1000
    )
    if selection_errors:
        selection_record["error"] = selection_errors[0][1]
    if not selection_ok:
        operation_failures.append({
            "operation": "selection", "type": selection_type,
            "error": selection_record.get("error"),
        })
    return {
        "ok": all(item.get("ok") for item in structures) and tree_evidence.get("ok") is True
        and selection_ok and not operation_failures,
        "codemap": structures, "tree": tree_evidence,
        "selection": selection_record,
        "failures": operation_failures,
        "completed": True,
    }


def validate_follow_on_collection(value: Any) -> list[str]:
    if not isinstance(value, dict):
        return ["follow_on_collection_malformed"]
    failures: list[str] = []
    if value.get("completed") is not True:
        failures.append("follow_on_collection_incomplete")
    codemap = value.get("codemap")
    tree = value.get("tree")
    selection = value.get("selection")
    if not isinstance(codemap, list) or not isinstance(tree, dict) or not isinstance(selection, dict):
        return failures + ["follow_on_operation_inventory_malformed"]
    operations = [*codemap, tree, selection]
    if (
        len(operations) != len(FOLLOW_ON_OPERATION_ORDER)
        or any(not isinstance(item, dict) for item in operations)
        or tuple(item.get("operation") for item in operations) != FOLLOW_ON_OPERATION_ORDER
    ):
        failures.append("follow_on_operation_inventory_mismatch")
        return failures

    expected_failure_inventory: list[dict[str, Any]] = []
    for item in operations:
        operation = str(item["operation"])
        for field in (
            "start_mark_attempted", "start_marked",
            "completion_mark_attempted", "completion_marked",
        ):
            if item.get(field) is not True:
                failures.append(f"{operation}_{field}_missing")
        operation_ok = item.get("ok") is True
        operation_type = item.get("type")
        if operation_ok:
            if operation_type != "success":
                failures.append(f"{operation}_success_type_mismatch")
        else:
            if operation_type not in FOLLOW_ON_FAILURE_TYPES:
                failures.append(f"{operation}_failure_type_invalid")
            expected_failure_inventory.append({
                "operation": operation,
                "type": operation_type,
                "error": item.get("error"),
            })

    if selection.get("set_attempted") is not True:
        failures.append("selection_set_not_attempted")
    if selection.get("get_attempted") is not True:
        failures.append("selection_get_not_attempted")
    if selection.get("get_result_recorded") is not True:
        failures.append("selection_get_result_not_recorded")
    get_finished_ns = selection.get("get_finished_ns")
    completion_attempted_ns = selection.get("completion_mark_attempted_ns")
    if (
        not isinstance(get_finished_ns, int) or isinstance(get_finished_ns, bool)
        or not isinstance(completion_attempted_ns, int) or isinstance(completion_attempted_ns, bool)
        or get_finished_ns > completion_attempted_ns
    ):
        failures.append("selection_completed_before_get_result")

    recorded_failure_inventory = value.get("failures")
    if recorded_failure_inventory != expected_failure_inventory:
        failures.append("follow_on_failure_inventory_mismatch")
    expected_ok = not expected_failure_inventory and not failures
    if value.get("ok") is not expected_ok:
        failures.append("follow_on_collection_ok_mismatch")
    return failures


def nonnegative_integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def positive_integer(value: Any) -> bool:
    return nonnegative_integer(value) and value > 0


def expected_actual_route_counts(
    route: str, observation_count: int = 1
) -> dict[str, int]:
    if route not in EXPECTED_ACTUAL_ROUTE_COUNTS or not positive_integer(observation_count):
        raise BenchmarkError("expected route observation count must be a positive integer")
    return {
        name: count * observation_count
        for name, count in EXPECTED_ACTUAL_ROUTE_COUNTS[route].items()
    }


def finite_number(value: Any, *, positive: bool = False) -> bool:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return False
    number = float(value)
    return math.isfinite(number) and (number > 0 if positive else number >= 0)


def validate_count_breakdown(value: Any, expected_total: int) -> bool:
    return (
        isinstance(value, dict)
        and all(isinstance(key, str) and key for key in value)
        and all(nonnegative_integer(count) for count in value.values())
        and sum(value.values()) == expected_total
        and (expected_total == 0 or bool(value))
    )


def validate_named_counts(value: Any) -> bool:
    return (
        isinstance(value, dict)
        and all(isinstance(key, str) and key for key in value)
        and all(nonnegative_integer(count) for count in value.values())
    )


def validate_git_evidence(value: Any) -> list[str]:
    if not isinstance(value, dict) or not REQUIRED_GIT_FIELDS <= set(value):
        return ["incomplete_git_evidence"]
    failures: list[str] = []
    count = value.get("command_count")
    if value.get("available") is not True:
        failures.append("git_evidence_unavailable")
    if not nonnegative_integer(count):
        failures.append("invalid_git_command_count")
        return failures
    if not validate_count_breakdown(value.get("families"), count):
        failures.append("invalid_git_family_counts")
    if not validate_count_breakdown(value.get("priorities"), count):
        failures.append("invalid_git_priority_counts")
    for field in ("queue_wait_us", "duration_us"):
        if not finite_number(value.get(field)):
            failures.append(f"invalid_git_{field}")
    for field in ("output_bytes", "cancelled_count"):
        if not nonnegative_integer(value.get(field)):
            failures.append(f"invalid_git_{field}")
    cancelled = value.get("cancelled_count")
    if nonnegative_integer(cancelled) and cancelled > count:
        failures.append("invalid_git_cancelled_count")
    return failures


def validate_filesystem_evidence(value: Any) -> list[str]:
    if not isinstance(value, dict) or not REQUIRED_FILESYSTEM_FIELDS <= set(value):
        return ["incomplete_filesystem_evidence"]
    failures: list[str] = []
    for field in ("operation_count", "item_count"):
        if not nonnegative_integer(value.get(field)):
            failures.append(f"invalid_filesystem_{field}")
    if not finite_number(value.get("duration_us")):
        failures.append("invalid_filesystem_duration_us")
    operation_count = value.get("operation_count")
    expected_available = nonnegative_integer(operation_count) and operation_count > 0
    if not isinstance(value.get("available"), bool) or value.get("available") != expected_available:
        failures.append("invalid_filesystem_availability")
    return failures


PUBLISHED_MEMORY_GRID_MB = 0.1
PUBLISHED_MEMORY_DELTA_TOLERANCE_MB = PUBLISHED_MEMORY_GRID_MB + 1e-9


def published_memory_value(value: Any, *, signed: bool = False) -> bool:
    if (
        not isinstance(value, (int, float))
        or isinstance(value, bool)
        or not math.isfinite(float(value))
        or (not signed and float(value) < 0)
    ):
        return False
    scaled = float(value) / PUBLISHED_MEMORY_GRID_MB
    return math.isclose(scaled, round(scaled), rel_tol=0.0, abs_tol=1e-8)


def validate_resource_evidence(value: Any) -> list[str]:
    required = REQUIRED_RESOURCE_FIELDS - {"physical_footprint_available"}
    if (
        not isinstance(value, dict)
        or not required <= set(value)
        or not ({"physical_footprint_available", "phys_footprint_available"} & set(value))
    ):
        return ["incomplete_resource_evidence"]
    failures: list[str] = []
    footprint_available = value.get(
        "physical_footprint_available", value.get("phys_footprint_available")
    )
    if footprint_available is not True:
        failures.append("physical_footprint_unavailable")
    for family in ("resident", "physical_footprint"):
        baseline = value.get(f"baseline_{family}_mb")
        peak = value.get(f"peak_{family}_mb")
        final = value.get(f"final_{family}_mb")
        peak_delta = value.get(f"peak_{family}_delta_mb")
        retained_delta = value.get(f"retained_{family}_delta_mb")
        if not all(
            finite_number(item, positive=True) and published_memory_value(item)
            for item in (baseline, peak, final)
        ):
            failures.append(f"invalid_{family}_absolute_mb")
            continue
        if not all(
            isinstance(item, (int, float))
            and not isinstance(item, bool)
            and math.isfinite(float(item))
            and published_memory_value(item, signed=True)
            for item in (peak_delta, retained_delta)
        ):
            failures.append(f"invalid_{family}_delta_mb")
            continue
        if float(peak) < max(float(baseline), float(final)):
            failures.append(f"invalid_{family}_peak_mb")
        # Absolute values and deltas are independently published on a 0.1 MiB grid.
        # Their displayed arithmetic may legitimately differ by one grid cell, never two.
        tolerance = PUBLISHED_MEMORY_DELTA_TOLERANCE_MB
        if not math.isclose(
            float(peak_delta), float(peak) - float(baseline), rel_tol=0.0, abs_tol=tolerance
        ):
            failures.append(f"inconsistent_{family}_peak_delta")
        if not math.isclose(
            float(retained_delta), float(final) - float(baseline), rel_tol=0.0, abs_tol=tolerance
        ):
            failures.append(f"inconsistent_{family}_retained_delta")
    for field in (
        "session_cpu_ms", "session_user_cpu_ms", "session_system_cpu_ms",
        "average_core_utilization_percent", "peak_interval_core_utilization_percent",
        "duration_seconds",
    ):
        if not finite_number(value.get(field), positive=field == "duration_seconds"):
            failures.append(f"invalid_resource_{field}")
    if not nonnegative_integer(value.get("sample_count")) or value.get("sample_count", 0) < 2:
        failures.append("invalid_resource_sample_count")
    if all(finite_number(value.get(field)) for field in ("session_cpu_ms", "session_user_cpu_ms", "session_system_cpu_ms")):
        if not math.isclose(
            float(value["session_cpu_ms"]),
            float(value["session_user_cpu_ms"]) + float(value["session_system_cpu_ms"]),
            rel_tol=1e-6, abs_tol=1e-6,
        ):
            failures.append("inconsistent_resource_cpu_total")
    average = value.get("average_core_utilization_percent")
    peak = value.get("peak_interval_core_utilization_percent")
    if finite_number(average) and finite_number(peak) and float(peak) < float(average):
        failures.append("invalid_resource_core_utilization")
    return failures


def expected_receipt_decision(route: str, correlation: str) -> dict[str, Any]:
    if route not in ROUTES:
        raise BenchmarkError(f"unsupported receipt route: {route}")
    nonprojected_coordinator = {
        "binding_count": 1,
        "create_result_receipt_count": 0,
        "creation_fallback_observed": None,
        "hint_count": 0,
        "hint_keyed_by_created_binding": "notEvaluated",
    }
    nonprojected_projection = {
        "all_hint_keys_matched_bindings": True,
        "matched_hint_count": 0,
        "supplied_hint_count": 0,
        "validation_fallback": None,
    }
    if route in {"baseline", "forced-full"}:
        observation = {"state": "disabled"} if route == "baseline" else {
            "fallback_reason": "noReceipt", "state": "fallback",
        }
        return {
            "ambiguous_or_duplicate": False,
            "consumption": {
                "final_observation": observation,
                "full_crawl_performed": True,
                "hint_correlation_match": "notEvaluated",
                "hint_owner_match": "notEvaluated",
                "hint_session_match": "notEvaluated",
                "initial_hint_observation": dict(observation),
                "owner_generation_match": "notEvaluated",
                "ownership_reused": False,
                "pending_seeded_preparation_result": None,
                "selected_route": "fullCrawl",
            },
            "coordinator": nonprojected_coordinator,
            "correlation_id": correlation,
            "creation": None,
            "creation_attempt_count": 0,
            "projection": nonprojected_projection,
            "terminal_stage": RECEIPT_TERMINAL_STAGE,
        }
    return {
        "ambiguous_or_duplicate": False,
        "consumption": {
            "final_observation": {"state": "eligible"},
            "full_crawl_performed": False,
            "hint_correlation_match": "match",
            "hint_owner_match": "match",
            "hint_session_match": "match",
            "initial_hint_observation": {"state": "eligible"},
            "owner_generation_match": "match",
            "ownership_reused": False,
            "pending_seeded_preparation_result": {"state": "eligible"},
            "selected_route": "diffSeedServing",
        },
        "coordinator": {
            "binding_count": 1,
            "create_result_receipt_count": 1,
            "creation_fallback_observed": None,
            "hint_count": 1,
            "hint_keyed_by_created_binding": "match",
        },
        "correlation_id": correlation,
        "creation": {
            "initialization_fallback_reason": None,
            "outcome": "receiptEmitted",
            "receipt_emitted": True,
            "receipt_fallback_reason": None,
        },
        "creation_attempt_count": 1,
        "projection": {
            "all_hint_keys_matched_bindings": True,
            "matched_hint_count": 1,
            "supplied_hint_count": 1,
            "validation_fallback": None,
        },
        "terminal_stage": RECEIPT_TERMINAL_STAGE,
    }


def matches_mandatory_typed_subset(actual: Any, expected: Any) -> bool:
    """Require every expected receipt field while permitting additive evidence."""
    if isinstance(expected, dict):
        return (
            isinstance(actual, dict)
            and all(
                key in actual and matches_mandatory_typed_subset(actual[key], value)
                for key, value in expected.items()
            )
        )
    if expected is None:
        return actual is None
    return type(actual) is type(expected) and actual == expected


PROJECTED_RECEIPT_CREATION_EXACT_VALUES: dict[str, Any] = {
    "destination_eligibility": "eligible",
    "current_lease_present": True,
    "current_lease_current_at_snapshot_lookup": True,
    "current_snapshot_present": True,
    "current_snapshot_content_address_valid": True,
    "parent_lookup_route": "currentAlias",
    "parent_lookup_failure": "none",
    "parent_authority_key_match": "match",
    "parent_prefix_match": "match",
    "target_tree_resolution": "succeeded",
    "witness_requested": True,
    "witness_started": True,
    "witness_finished": True,
    "witness_start_event_id_valid": True,
    "witness_end_event_id_valid": True,
    "witness_stable_root_available_before_mutation": True,
    "witness_destination_absent_before_mutation": True,
    "witness_destination_strict_descendant": True,
    "witness_stable_root_unchanged_after_initialization": True,
    "witness_stream_creation_succeeded": True,
    "witness_activation_flush_completed": True,
    "witness_activation_callback_barrier_completed": True,
    "witness_ending_flush_completed": True,
    "witness_ending_callback_barrier_completed": True,
    "witness_must_scan_sub_dirs": False,
    "witness_root_changed": False,
    "witness_user_dropped": False,
    "witness_kernel_dropped": False,
    "witness_event_ids_wrapped": False,
    "witness_event_id_regressed": False,
    "witness_lifetime_exceeded": False,
    "witness_gap": False,
    "witness_drop": False,
    "witness_overflow": False,
    "witness_proves_interval": True,
    "include_copy_requested": True,
    "include_copy_complete": True,
    "include_copy_had_failures": False,
    "target_layout_present": True,
    "target_layout_linked": True,
    "target_authority_capture": "succeeded",
    "common_directory_match": "match",
    "repository_id_match": "match",
    "repository_namespace_match": "match",
    "target_prefix_match": "match",
    "target_tree_authority_match": "match",
}
PROJECTED_RECEIPT_CREATION_DIGEST_FIELDS = {
    "source_authority_key_digest", "source_common_directory_digest",
    "repository_id_digest", "repository_namespace_digest", "requested_prefix_digest",
    "current_snapshot_sha256",
}
PROJECTED_RECEIPT_CREATION_NONNEGATIVE_INTEGER_FIELDS = {
    "witness_start_accepted_callback_watermark",
    "witness_end_accepted_callback_watermark",
    "witness_accepted_callback_count",
    "witness_accepted_event_count",
    "witness_accepted_destination_event_count",
    "witness_accepted_non_destination_event_count",
}
UINT64_MAX = (1 << 64) - 1
SWIFT_INT64_MAX = (1 << 63) - 1


def valid_projected_receipt_creation(value: Any) -> bool:
    """Validate every known physical correctness field; unknown fields remain additive."""
    if not isinstance(value, dict):
        return False
    if value.get("source_layout_state") not in {"mainCheckout", "linkedWorktree"}:
        return False
    if any(
        key not in value
        or type(value[key]) is not type(expected)
        or value[key] != expected
        for key, expected in PROJECTED_RECEIPT_CREATION_EXACT_VALUES.items()
    ):
        return False
    if type(value.get("include_copy_result_present")) is not bool:
        return False
    if any(not lowercase_sha256(value.get(key)) for key in PROJECTED_RECEIPT_CREATION_DIGEST_FIELDS):
        return False
    if any(
        not nonnegative_integer(value.get(key))
        for key in PROJECTED_RECEIPT_CREATION_NONNEGATIVE_INTEGER_FIELDS
    ):
        return False
    start_event_id = value.get("witness_start_event_id")
    end_event_id = value.get("witness_end_event_id")
    start_watermark = value.get("witness_start_accepted_callback_watermark")
    end_watermark = value.get("witness_end_accepted_callback_watermark")
    accepted_callback_count = value.get("witness_accepted_callback_count")
    if (
        not positive_integer(start_event_id)
        or not positive_integer(end_event_id)
        or start_event_id >= UINT64_MAX
        or end_event_id >= UINT64_MAX
        or end_event_id < start_event_id
        or start_watermark > UINT64_MAX
        or end_watermark > UINT64_MAX
        or end_watermark < start_watermark
        or accepted_callback_count > SWIFT_INT64_MAX
        or accepted_callback_count != min(end_watermark, SWIFT_INT64_MAX)
    ):
        return False
    return True


def validate_receipt_oracle(
    checkpoint: dict[str, Any],
    sample: dict[str, Any],
    route: str,
    *,
    expected_correlation: str,
    expected_session: str,
    expected_invocation: int,
    expected_ordinal: int,
) -> list[str]:
    failures: list[str] = []
    if (
        sample.get("correlation_id") != expected_correlation
        or sample.get("agent_session_id") != expected_session
        or sample.get("invocation") != expected_invocation
        or sample.get("ordinal") != expected_ordinal
    ):
        failures.append("receipt_sample_identity_mismatch")
    decisions = checkpoint.get("receipt_decisions")
    if (
        checkpoint.get("receipt_decision_count") != 1
        or checkpoint.get("terminal_receipt_decision_count") != 1
        or checkpoint.get("receipt_decision_buffer_evicted") is not False
        or checkpoint.get("receipt_decision_ambiguous") is not False
        or not isinstance(decisions, list)
        or len(decisions) != 1
        or not isinstance(decisions[0], dict)
    ):
        return failures + ["terminal_receipt_evidence_invalid"]
    decision = decisions[0]
    if (
        decision.get("correlation_id") != expected_correlation
        or decision.get("ambiguous_or_duplicate") is not False
        or decision.get("terminal_stage") != RECEIPT_TERMINAL_STAGE
    ):
        failures.append("receipt_decision_identity_or_terminal_mismatch")
    if not matches_mandatory_typed_subset(
        decision, expected_receipt_decision(route, expected_correlation)
    ) or (
        route == "projected"
        and not valid_projected_receipt_creation(decision.get("creation"))
    ):
        failures.append(
            f"receipt_{route.replace('-', '_')}_decision_contract_mismatch"
        )
    return failures


def lowercase_sha256(value: Any) -> bool:
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def validate_policy_canonicalization_side(value: Any, label: str) -> tuple[list[str], list[dict[str, Any]] | None]:
    failures: list[str] = []
    if not isinstance(value, dict) or "constituents" not in value:
        return [f"policy_canonicalization_{label}_inventory_invalid"], None
    constituents = value.get("constituents")
    if not isinstance(constituents, list) or not all(isinstance(item, dict) for item in constituents):
        return [f"policy_canonicalization_{label}_constituents_invalid"], None
    if [item.get("constituent") for item in constituents] != POLICY_CANONICALIZATION_CONSTITUENTS:
        return [f"policy_canonicalization_{label}_constituent_order_invalid"], None

    for item in constituents:
        name = item["constituent"]
        if name == "rootNeutralPolicyConfig":
            if not {"constituent", "byte_count", "sha256"}.issubset(item):
                failures.append(f"policy_canonicalization_{label}_{name}_inventory_invalid")
            elif not nonnegative_integer(item.get("byte_count")) or not lowercase_sha256(item.get("sha256")):
                failures.append(f"policy_canonicalization_{label}_{name}_value_invalid")
        elif name in {"commonInfoExclude", "commonInfoAttributes"}:
            if not {"constituent", "state", "digest"}.issubset(item):
                failures.append(f"policy_canonicalization_{label}_{name}_inventory_invalid")
            elif item.get("state") not in {"missing", "directory", "regular"} or not lowercase_sha256(item.get("digest")):
                failures.append(f"policy_canonicalization_{label}_{name}_value_invalid")
        elif name in {"canonicalIgnoreFooter", "canonicalAttributeFooter"}:
            if not {"constituent", "digest", "record_count"}.issubset(item):
                failures.append(f"policy_canonicalization_{label}_{name}_inventory_invalid")
            elif not lowercase_sha256(item.get("digest")) or not nonnegative_integer(item.get("record_count")):
                failures.append(f"policy_canonicalization_{label}_{name}_value_invalid")
        elif name in {"externalExcludes", "externalAttributes"}:
            if not {"constituent", "state", "identity_digest", "byte_count"}.issubset(item):
                failures.append(f"policy_canonicalization_{label}_{name}_inventory_invalid")
            elif (
                item.get("state") not in {"unset", "missing", "present"}
                or not lowercase_sha256(item.get("identity_digest"))
                or not nonnegative_integer(item.get("byte_count"))
            ):
                failures.append(f"policy_canonicalization_{label}_{name}_value_invalid")
        elif name in {"configuredIgnorePolicy", "attributePolicy", "sparsePolicy"}:
            if not {"constituent", "digest"}.issubset(item):
                failures.append(f"policy_canonicalization_{label}_{name}_inventory_invalid")
            elif not lowercase_sha256(item.get("digest")):
                failures.append(f"policy_canonicalization_{label}_{name}_value_invalid")
        elif name == "canonicalization":
            expected = {
                "constituent", "policy_version", "pruned_root_count",
                "pruned_root_summary_sha256", "completeness",
            }
            if not expected.issubset(item):
                failures.append(f"policy_canonicalization_{label}_{name}_inventory_invalid")
            elif (
                not isinstance(item.get("policy_version"), str)
                or not item["policy_version"]
                or "/" in item["policy_version"]
                or "\\" in item["policy_version"]
                or item.get("completeness") not in {"complete", "incomplete"}
                or not nonnegative_integer(item.get("pruned_root_count"))
                or not lowercase_sha256(item.get("pruned_root_summary_sha256"))
            ):
                failures.append(f"policy_canonicalization_{label}_{name}_value_invalid")
        elif name == "committedControls":
            expected = {"constituent", "record_count", "summary_sha256"}
            if not expected.issubset(item):
                failures.append(f"policy_canonicalization_{label}_{name}_inventory_invalid")
            elif (
                not nonnegative_integer(item.get("record_count"))
                or not lowercase_sha256(item.get("summary_sha256"))
            ):
                failures.append(f"policy_canonicalization_{label}_{name}_value_invalid")
    return failures, constituents


def policy_constituents_match(
    name: str,
    base: dict[str, Any],
    target: dict[str, Any],
) -> bool:
    if name == "canonicalization":
        return (
            base.get("policy_version") == target.get("policy_version")
            and base.get("completeness") == target.get("completeness")
        )
    if name == "committedControls":
        return (
            base.get("record_count") == target.get("record_count")
            and base.get("summary_sha256") == target.get("summary_sha256")
        )
    known_keys = {
        "rootNeutralPolicyConfig": {"constituent", "byte_count", "sha256"},
        "commonInfoExclude": {"constituent", "state", "digest"},
        "canonicalIgnoreFooter": {"constituent", "digest", "record_count"},
        "externalExcludes": {"constituent", "state", "identity_digest", "byte_count"},
        "configuredIgnorePolicy": {"constituent", "digest"},
        "commonInfoAttributes": {"constituent", "state", "digest"},
        "canonicalAttributeFooter": {"constituent", "digest", "record_count"},
        "externalAttributes": {"constituent", "state", "identity_digest", "byte_count"},
        "attributePolicy": {"constituent", "digest"},
        "sparsePolicy": {"constituent", "digest"},
    }[name]
    return all(base.get(key) == target.get(key) for key in known_keys)


def validate_policy_canonicalization_comparison(
    value: Any,
    *,
    require_canonical_equivalence: bool,
) -> list[str]:
    if not isinstance(value, dict) or not {
        "classification", "constituent_comparisons", "base", "target",
    }.issubset(value):
        return ["policy_canonicalization_comparison_inventory_invalid"]
    failures: list[str] = []
    classification = value.get("classification")
    if classification not in POLICY_CANONICALIZATION_CLASSIFICATIONS:
        failures.append("policy_canonicalization_classification_invalid")
    comparisons = value.get("constituent_comparisons")
    if not isinstance(comparisons, list) or not all(isinstance(item, dict) for item in comparisons):
        return failures + ["policy_canonicalization_constituent_comparisons_invalid"]
    if [item.get("constituent") for item in comparisons] != POLICY_CANONICALIZATION_CONSTITUENTS:
        failures.append("policy_canonicalization_comparison_order_invalid")
    comparison_shape_valid = not any(
        not {"constituent", "matched"}.issubset(item) or not isinstance(item.get("matched"), bool)
        for item in comparisons
    )
    if not comparison_shape_valid:
        failures.append("policy_canonicalization_comparison_value_invalid")

    base_value = value.get("base")
    target_value = value.get("target")
    base_constituents: list[dict[str, Any]] | None = None
    target_constituents: list[dict[str, Any]] | None = None
    if base_value is not None:
        side_failures, base_constituents = validate_policy_canonicalization_side(base_value, "base")
        failures.extend(side_failures)
    if target_value is not None:
        side_failures, target_constituents = validate_policy_canonicalization_side(target_value, "target")
        failures.extend(side_failures)

    incomplete = base_constituents is None or target_constituents is None
    if (
        comparison_shape_valid
        and len(comparisons) == len(POLICY_CANONICALIZATION_CONSTITUENTS)
        and base_constituents is not None
        and target_constituents is not None
    ):
        for comparison, base, target in zip(comparisons, base_constituents, target_constituents):
            if comparison.get("constituent") != base.get("constituent") or base.get("constituent") != target.get("constituent"):
                failures.append("policy_canonicalization_comparison_alignment_invalid")
                break
            computed_match = policy_constituents_match(comparison["constituent"], base, target)
            if comparison.get("matched") is not computed_match:
                failures.append("policy_canonicalization_comparison_contradictory")
                break
        for constituents in (base_constituents, target_constituents):
            canonicalization = constituents[-2]
            if canonicalization.get("completeness") != "complete":
                incomplete = True

    declared_matches = [item.get("matched") for item in comparisons]
    if classification == "canonicalEquivalentAfterReachabilityFiltering":
        if incomplete or declared_matches != [True] * len(POLICY_CANONICALIZATION_CONSTITUENTS):
            failures.append("policy_canonicalization_equivalence_incoherent")
    elif classification == "semanticInputDifference":
        if incomplete or all(declared_matches):
            failures.append("policy_canonicalization_semantic_difference_incoherent")
    elif classification == "incomplete":
        if not incomplete:
            failures.append("policy_canonicalization_incomplete_classification_incoherent")
    elif classification == "incoherent":
        failures.append("policy_canonicalization_reported_incoherent")
    if require_canonical_equivalence and classification != "canonicalEquivalentAfterReachabilityFiltering":
        failures.append("policy_canonicalization_not_equivalent")
    return failures


def validate_delta_compatibility_oracle(
    checkpoint: dict[str, Any],
    route: str,
    *,
    expected_correlation: str,
) -> list[str]:
    failures: list[str] = []
    evaluations = checkpoint.get("delta_compatibility_evaluations")
    expected_count = 2 if route == "projected" else 0
    if (
        checkpoint.get("delta_compatibility_evaluation_count") != expected_count
        or checkpoint.get("delta_compatibility_evaluation_buffer_evicted") is not False
        or checkpoint.get("delta_compatibility_evaluation_ambiguous") is not False
        or checkpoint.get("delta_compatibility_evaluation_contradictory") is not False
        or not isinstance(evaluations, list)
        or len(evaluations) != expected_count
    ):
        return ["delta_compatibility_evidence_invalid"]
    if route != "projected":
        return failures

    if not all(isinstance(item, dict) for item in evaluations):
        return ["delta_compatibility_evaluation_entry_malformed"]
    if [item.get("source") for item in evaluations] != [
        "hintEvaluator", "planner",
    ]:
        failures.append("delta_compatibility_source_contract_mismatch")
        return failures

    for evaluation in evaluations:
        source = evaluation.get("source")
        fields = evaluation.get("field_evaluations")
        mismatched = evaluation.get("mismatched_fields")
        correction = evaluation.get("correction_rule_applied")
        comparison_failures = validate_policy_canonicalization_comparison(
            evaluation.get("policy_canonicalization_comparison"),
            require_canonical_equivalence=True,
        )
        failures.extend(
            f"delta_compatibility_{source}_{failure}" for failure in comparison_failures
        )
        if (
            evaluation.get("correlation_id") != expected_correlation
            or evaluation.get("decision") != "compatible"
            or evaluation.get("duplicate") is not False
            or evaluation.get("contradictory") is not False
            or evaluation.get("exact_snapshot_lookup_reached") is not True
            or evaluation.get("exact_snapshot_lookup_passed") is not True
            or evaluation.get("target_authority_comparison_reached") is not True
            or evaluation.get("target_authority_comparison_passed") is not True
            or evaluation.get("terminal_fallback") is not None
            or evaluation.get("tree_relation") not in {
                "sameExcludedFromDeltaCompatibility",
                "differentExcludedFromDeltaCompatibility",
            }
        ):
            failures.append(f"delta_compatibility_{source}_decision_contract_mismatch")
        if not isinstance(fields, list):
            failures.append(f"delta_compatibility_{source}_field_contract_mismatch")
            continue
        if not all(isinstance(item, dict) for item in fields):
            failures.append(f"delta_compatibility_{source}_field_entry_malformed")
            continue
        if [item.get("field") for item in fields] != DELTA_COMPATIBILITY_FIELDS:
            failures.append(f"delta_compatibility_{source}_field_contract_mismatch")
            continue
        for field in fields:
            if (
                not isinstance(field, dict)
                or field.get("decision") not in {"match", "mismatch"}
                or not isinstance(field.get("base_digest"), str)
                or re.fullmatch(r"[0-9a-f]{64}", field["base_digest"]) is None
                or not isinstance(field.get("target_digest"), str)
                or re.fullmatch(r"[0-9a-f]{64}", field["target_digest"]) is None
                or (field.get("decision") == "match" and field["base_digest"] != field["target_digest"])
            ):
                failures.append(f"delta_compatibility_{source}_field_digest_invalid")
                break
        derived_mismatches = [field["field"] for field in fields if field.get("decision") == "mismatch"]
        if mismatched != derived_mismatches:
            failures.append(f"delta_compatibility_{source}_mismatch_set_invalid")
        authorized_corrections = {
            (): "none",
            ("resolvedExcludesFileIdentity",): "canonicalMissingResolvedExcludesFileIdentity",
            ("resolvedAttributesFileIdentity",): "canonicalMissingResolvedAttributesFileIdentity",
            (
                "resolvedExcludesFileIdentity",
                "resolvedAttributesFileIdentity",
            ): "canonicalMissingResolvedExternalAuthorityIdentities",
        }
        if authorized_corrections.get(tuple(derived_mismatches)) != correction:
            failures.append(f"delta_compatibility_{source}_correction_contract_mismatch")
        if source == "hintEvaluator":
            if (
                evaluation.get("current_search_abi_reached") is not True
                or evaluation.get("current_search_abi_matched") is not True
                or evaluation.get("catalog_policy_comparison_reached") is not False
                or evaluation.get("catalog_policy_matched") is not None
            ):
                failures.append("delta_compatibility_hintEvaluator_gate_contract_mismatch")
        elif source == "planner":
            if (
                evaluation.get("current_search_abi_reached") is not False
                or evaluation.get("current_search_abi_matched") is not None
                or evaluation.get("catalog_policy_comparison_reached") is not True
                or evaluation.get("catalog_policy_matched") is not True
            ):
                failures.append("delta_compatibility_planner_gate_contract_mismatch")
    return failures


def validate_primary_checkpoint(
    checkpoint: dict[str, Any],
    route: str,
    direct_correctness: dict[str, bool],
    *,
    expected_correlation: str,
    expected_session: str,
    expected_context: str,
    expected_scope_context: str,
    expected_invocation: int,
    expected_ordinal: int,
    expected_route_observation_count: int = 1,
) -> list[str]:
    """Validate only the correlation-bound root/search/read critical path."""
    failures: list[str] = []
    if checkpoint.get("schema_version") != DIAGNOSTIC_SCHEMA_VERSION:
        failures.append("diagnostic_schema_mismatch")
    scope = checkpoint.get("scope")
    if (
        not isinstance(scope, dict)
        or not isinstance(scope.get("context_id"), str)
        or scope["context_id"].upper() != expected_scope_context.upper()
    ):
        failures.append("sample_context_id_mismatch")
    sample = checkpoint.get("sample")
    if not isinstance(sample, dict):
        return failures + ["missing_sample"]
    if sample.get("configured_route") != ROUTES[route]["expected"]:
        failures.append("configured_route_mismatch")
    for key, expected in {
        "correlation_id": expected_correlation,
        "agent_session_id": expected_session,
    }.items():
        if not isinstance(sample.get(key), str) or sample[key].upper() != expected.upper():
            failures.append(f"sample_{key}_mismatch")
    for key, expected in (("invocation", expected_invocation), ("ordinal", expected_ordinal)):
        if not positive_integer(sample.get(key)) or sample[key] != expected:
            failures.append(f"sample_{key}_mismatch")
    if sample.get("root_ready") is not True:
        failures.append("root_not_ready")
    if sample.get("first_search_complete") is not True:
        failures.append("first_search_incomplete")
    if sample.get("first_read_complete") is not True:
        failures.append("first_read_incomplete")
    route_counts = sample.get("route_counts")
    fallback_counts = sample.get("fallback_counts")
    if not validate_named_counts(route_counts):
        failures.append("invalid_route_counts")
    elif route_counts != expected_actual_route_counts(
        route, expected_route_observation_count
    ):
        failures.append("actual_route_counts_mismatch")
    if not validate_named_counts(fallback_counts):
        failures.append("invalid_fallback_counts")
    elif fallback_counts != {}:
        failures.append("unexpected_fallback")
    if direct_correctness != {"search": True, "read": True}:
        failures.append("direct_content_oracle_mismatch")

    boundaries = sample.get("operation_boundaries_us")
    durations = sample.get("durations_us")
    if not isinstance(boundaries, dict):
        failures.append("invalid_primary_operation_boundaries")
    elif any(not finite_number(boundaries.get(key)) for key in PRIMARY_BOUNDARY_KEYS):
        failures.append("invalid_primary_operation_boundaries")
    else:
        ordered_pairs = (
            ("bindingTransitionStarted", "rootReady"),
            ("rootReady", "firstBenchmarkSearchStarted"),
            ("rootReady", "firstBenchmarkReadStarted"),
            ("firstBenchmarkSearchStarted", "firstBenchmarkSearchCompleted"),
            ("firstBenchmarkReadStarted", "firstBenchmarkReadCompleted"),
        )
        if not all(
            float(boundaries[before]) <= float(boundaries[after])
            for before, after in ordered_pairs
        ):
            failures.append("non_monotonic_primary_operation_boundaries")
        if not (
            max(
                float(boundaries["firstBenchmarkSearchStarted"]),
                float(boundaries["firstBenchmarkReadStarted"]),
            )
            < min(
                float(boundaries["firstBenchmarkSearchCompleted"]),
                float(boundaries["firstBenchmarkReadCompleted"]),
            )
        ):
            failures.append("primary_search_read_intervals_do_not_overlap")
    if not isinstance(durations, dict):
        failures.append("invalid_primary_durations")
        durations = {}
    elif any(not finite_number(durations.get(metric), positive=True) for metric in PRIMARY_DURATION_METRICS):
        failures.append("invalid_primary_durations")
    if isinstance(boundaries, dict) and all(
        finite_number(boundaries.get(key)) for key in PRIMARY_BOUNDARY_KEYS
    ):
        for metric in PRIMARY_DURATION_METRICS:
            start, end = BOUNDARY_DURATION_PAIRS[metric]
            duration = durations.get(metric)
            if finite_number(duration, positive=True):
                expected = float(boundaries[end]) - float(boundaries[start])
                if expected <= 0 or not math.isclose(float(duration), expected, abs_tol=1.0):
                    failures.append(f"inconsistent_{metric}_duration")
        interactive = sample.get("interactive_readiness_us")
        expected_interactive = max(
            float(boundaries["firstBenchmarkSearchCompleted"]),
            float(boundaries["firstBenchmarkReadCompleted"]),
        ) - float(boundaries["bindingTransitionStarted"])
        if not finite_number(interactive, positive=True):
            failures.append("invalid_interactive_readiness_us")
        elif not math.isclose(float(interactive), expected_interactive, abs_tol=1.0):
            failures.append("interactive_readiness_boundary_mismatch")

    failures.extend(validate_receipt_oracle(
        checkpoint, sample, route,
        expected_correlation=expected_correlation,
        expected_session=expected_session,
        expected_invocation=expected_invocation,
        expected_ordinal=expected_ordinal,
    ))
    failures.extend(validate_delta_compatibility_oracle(
        checkpoint, route, expected_correlation=expected_correlation,
    ))
    return failures


def validate_primary_performance(
    primary: dict[str, Any],
    route: str,
    *,
    expected_correlation: str,
    expected_session: str,
    expected_context: str,
    expected_scope_context: str,
    expected_invocation: int,
    expected_ordinal: int,
    expected_build: dict[str, str],
    expected_fixture: dict[str, str],
    expected_route_observation_count: int = 1,
) -> list[str]:
    failures: list[str] = []
    identity = primary.get("identity")
    expected_identity: dict[str, Any] = {
        "correlation_id": expected_correlation,
        "session_id": expected_session,
        "context_id": expected_context,
        "invocation": expected_invocation,
        "ordinal": expected_ordinal,
        "build": expected_build,
    }
    if identity != expected_identity:
        failures.append("primary_identity_mismatch")
    if primary.get("committed_fixture") != expected_fixture:
        failures.append("committed_fixture_mismatch")
    direct = primary.get("direct_tool_evidence")
    if not isinstance(direct, dict) or direct.get("concurrent") is not True:
        failures.append("primary_direct_concurrency_unproven")
    if not isinstance(direct, dict) or direct.get("mark_failures") != []:
        failures.append("primary_direct_mark_failure")
    correctness = {
        "search": isinstance(direct, dict) and isinstance(direct.get("search"), dict)
        and direct["search"].get("ok") is True,
        "read": isinstance(direct, dict) and isinstance(direct.get("read"), dict)
        and direct["read"].get("ok") is True,
    }
    checkpoint = primary.get("diagnostic_checkpoint")
    if not isinstance(checkpoint, dict):
        failures.append("missing_primary_diagnostic_checkpoint")
    else:
        failures.extend(validate_primary_checkpoint(
            checkpoint, route, correctness,
            expected_correlation=expected_correlation,
            expected_session=expected_session,
            expected_context=expected_context,
            expected_scope_context=expected_scope_context,
            expected_invocation=expected_invocation,
            expected_ordinal=expected_ordinal,
            expected_route_observation_count=expected_route_observation_count,
        ))
    resource_cleanup = primary.get("resource_cleanup")
    if not isinstance(resource_cleanup, dict):
        failures.append("missing_resource_cleanup_proof")
    else:
        resource_failures = resource_cleanup.get("resource_failures")
        if not isinstance(resource_failures, list) or resource_failures:
            failures.append("resource_evidence_invalid")
        if resource_cleanup.get("cleanup_complete") is not True:
            failures.append("cleanup_incomplete")
        if resource_cleanup.get("build_unchanged") is not True:
            failures.append("build_changed_during_run")
    return failures


def finalize_primary_performance(
    primary: dict[str, Any],
    *,
    route: str,
    expected_correlation: str,
    expected_session: str,
    expected_context: str,
    expected_scope_context: str,
    expected_invocation: int,
    expected_ordinal: int,
    expected_build: dict[str, str],
    expected_fixture: dict[str, str],
    resource_failures: list[str],
    cleanup_complete: bool,
    build_unchanged: bool,
    expected_route_observation_count: int = 1,
) -> None:
    primary["resource_cleanup"] = {
        "resource_failures": resource_failures,
        "cleanup_complete": cleanup_complete,
        "build_unchanged": build_unchanged,
    }
    failures = validate_primary_performance(
        primary, route,
        expected_correlation=expected_correlation,
        expected_session=expected_session,
        expected_context=expected_context,
        expected_scope_context=expected_scope_context,
        expected_invocation=expected_invocation,
        expected_ordinal=expected_ordinal,
        expected_build=expected_build,
        expected_fixture=expected_fixture,
        expected_route_observation_count=expected_route_observation_count,
    )
    primary["invalid_reasons"] = failures
    primary["valid"] = not failures


def validate_boundary_evidence(sample: dict[str, Any]) -> list[str]:
    boundaries = sample.get("operation_boundaries_us")
    durations = sample.get("durations_us")
    failures: list[str] = []
    if sample.get("boundary_evidence_available") is not True:
        failures.append("boundary_evidence_unavailable")
    reasons = sample.get("boundary_invalid_reasons")
    if not isinstance(reasons, list) or reasons:
        failures.append("boundary_evidence_reported_invalid")
    if not isinstance(boundaries, dict):
        return failures + ["invalid_operation_boundaries"]
    if set(REQUIRED_BOUNDARY_KEYS) - set(boundaries):
        failures.append("missing_required_operation_boundaries")
    if any(not finite_number(boundaries.get(key)) for key in REQUIRED_BOUNDARY_KEYS):
        failures.append("invalid_operation_boundaries")
        return failures

    def ordered(before: str, after: str) -> bool:
        return float(boundaries[before]) <= float(boundaries[after])

    ordering = [
        ("bindingTransitionStarted", "rootReady"),
        ("rootReady", "firstBenchmarkSearchStarted"),
        ("rootReady", "firstBenchmarkReadStarted"),
        ("firstBenchmarkSearchStarted", "firstBenchmarkSearchCompleted"),
        ("firstBenchmarkReadStarted", "firstBenchmarkReadCompleted"),
        ("firstBenchmarkSearchCompleted", "firstBenchmarkCodemapStarted"),
        ("firstBenchmarkReadCompleted", "firstBenchmarkCodemapStarted"),
        ("firstBenchmarkCodemapStarted", "firstBenchmarkCodemapCompleted"),
        ("firstBenchmarkCodemapCompleted", "warmBenchmarkCodemapStarted"),
        ("warmBenchmarkCodemapStarted", "warmBenchmarkCodemapCompleted"),
        ("warmBenchmarkCodemapCompleted", "passiveBenchmarkTreeStarted"),
        ("passiveBenchmarkTreeStarted", "passiveBenchmarkTreeCompleted"),
        ("passiveBenchmarkTreeCompleted", "benchmarkSelectionStarted"),
        ("benchmarkSelectionStarted", "benchmarkSelectionCompleted"),
    ]
    if not all(ordered(before, after) for before, after in ordering):
        failures.append("non_monotonic_operation_boundaries")
    if not isinstance(durations, dict):
        return failures + ["invalid_sample_durations"]
    for metric, (start, end) in BOUNDARY_DURATION_PAIRS.items():
        duration = durations.get(metric)
        if finite_number(duration, positive=True):
            expected = float(boundaries[end]) - float(boundaries[start])
            if expected <= 0 or not math.isclose(float(duration), expected, abs_tol=1.0):
                failures.append(f"inconsistent_{metric}_duration")
    interactive = sample.get("interactive_readiness_us")
    if finite_number(interactive, positive=True):
        expected_interactive = max(
            float(boundaries["firstBenchmarkSearchCompleted"]),
            float(boundaries["firstBenchmarkReadCompleted"]),
        ) - float(boundaries["bindingTransitionStarted"])
        if not math.isclose(float(interactive), expected_interactive, abs_tol=1.0):
            failures.append("interactive_readiness_boundary_mismatch")
    return failures


def validate_export(
    export: dict[str, Any],
    route: str,
    correctness: dict[str, bool],
    *,
    expected_correlation: str,
    expected_session: str,
    expected_invocation: int,
    expected_ordinal: int,
    expected_route_observation_count: int = 1,
) -> list[str]:
    failures: list[str] = []
    if export.get("schema_version") != DIAGNOSTIC_SCHEMA_VERSION:
        failures.append("diagnostic_schema_mismatch")
    sample = export.get("sample")
    if not isinstance(sample, dict):
        return ["missing_sample"]
    if sample.get("valid") is not True:
        failures.append("diagnostic_invalid")
    if sample.get("configured_route") != ROUTES[route]["expected"]:
        failures.append("configured_route_mismatch")
    string_identity_expectations = {
        "correlation_id": expected_correlation,
        "agent_session_id": expected_session,
    }
    for key, expected in string_identity_expectations.items():
        if not isinstance(sample.get(key), str) or sample[key].upper() != expected.upper():
            failures.append(f"sample_{key}_mismatch")
    for key, expected in (("invocation", expected_invocation), ("ordinal", expected_ordinal)):
        if not positive_integer(sample.get(key)) or sample[key] != expected:
            failures.append(f"sample_{key}_mismatch")
    route_counts = sample.get("route_counts")
    fallbacks = sample.get("fallback_counts")
    if not validate_named_counts(route_counts):
        failures.append("invalid_route_counts")
    elif route_counts != expected_actual_route_counts(
        route, expected_route_observation_count
    ):
        failures.append("actual_route_counts_mismatch")
    if not validate_named_counts(fallbacks):
        failures.append("invalid_fallback_counts")
    elif fallbacks != {}:
        failures.append("unexpected_fallback")
    if not all(correctness.values()):
        failures.append("content_oracle_mismatch")
    durations = sample.get("durations_us")
    if not isinstance(durations, dict) or not all(isinstance(key, str) and key for key in durations):
        failures.append("invalid_sample_durations")
        durations = {}
    elif any(not finite_number(value, positive=True) for value in durations.values()):
        failures.append("invalid_sample_durations")
    for metric in DURATION_METRICS:
        if metric not in durations:
            failures.append(f"missing_{metric}")
    interactive = sample.get("interactive_readiness_us")
    if not finite_number(interactive, positive=True):
        failures.append("invalid_interactive_readiness_us")
    else:
        search = durations.get("materialize_to_first_search")
        read = durations.get("materialize_to_first_read")
        if finite_number(search, positive=True) and finite_number(read, positive=True):
            if not math.isclose(float(interactive), max(float(search), float(read)), abs_tol=1.0):
                failures.append("interactive_readiness_mismatch")
    failures.extend(validate_boundary_evidence(sample))
    git = export.get("git")
    failures.extend(validate_git_evidence(git))
    work = export.get("work")
    filesystem = work.get("filesystem") if isinstance(work, dict) else None
    failures.extend(validate_filesystem_evidence(filesystem))
    planner = work.get("planner") if isinstance(work, dict) else None
    expected_planner = {"targetNamespace", "treeEvidence", "indexEvidence", "statusEvidence", "reconcile"}
    if not isinstance(planner, dict):
        failures.append("invalid_planner_evidence")
    elif route == "projected" and set(planner) != expected_planner:
        failures.append("incomplete_planner_evidence")
    elif any(
        not isinstance(value, dict)
        or not nonnegative_integer(value.get("count"))
        or not finite_number(value.get("duration_us"))
        or not nonnegative_integer(value.get("item_count"))
        for value in planner.values()
    ):
        failures.append("invalid_planner_evidence")
    mutation = work.get("mutation_lock") if isinstance(work, dict) else None
    if not isinstance(mutation, dict) or mutation.get("available") is not True:
        failures.append("mutation_lock_evidence_unavailable")
    elif (
        not positive_integer(mutation.get("count"))
        or any(not finite_number(mutation.get(field)) for field in (
            "queue_wait_us", "held_us", "mutation_us", "post_mutation_finalization_us"
        ))
    ):
        failures.append("invalid_mutation_lock_evidence")
    passive = work.get("passive_tree") if isinstance(work, dict) else None
    if not isinstance(passive, dict) or not isinstance(passive.get("available"), bool):
        failures.append("invalid_passive_tree_evidence")
    elif passive.get("available") is not True or passive.get("operation_count", 0) < 1:
        failures.append("passive_tree_evidence_unavailable")
    elif (
        not nonnegative_integer(passive.get("operation_count"))
        or not finite_number(passive.get("duration_us"))
    ):
        failures.append("invalid_passive_tree_evidence")
    markers = work.get("marker_publications") if isinstance(work, dict) else None
    if not isinstance(markers, list) or any(
        not isinstance(item, dict)
        or not all(isinstance(item.get(key), str) and item.get(key) for key in (
            "root_id", "root_lifetime_id", "source"
        ))
        or not nonnegative_integer(item.get("revision"))
        or not positive_integer(item.get("effective_change_count"))
        or not finite_number(item.get("timestamp_us"))
        for item in markers
    ):
        failures.append("invalid_marker_publication_evidence")
    elif not markers:
        failures.append("marker_publication_evidence_unavailable")
    return failures


def terminalize(runner: CLIRunner, session_id: str, context_id: str | None = None) -> str:
    response = runner.call(
        f"wait-{session_id[:8]}", "agent_run", {"op": "wait", "session_id": session_id, "timeout": 120},
        timeout=150, check=False, context_id=context_id,
    )
    status = response_status(response)
    if status not in TERMINAL_STATES:
        runner.call(
            f"cancel-{session_id[:8]}", "agent_run", {"op": "cancel", "session_id": session_id},
            timeout=30, check=False, context_id=context_id,
        )
        response = runner.call(
            f"settle-{session_id[:8]}", "agent_run", {"op": "wait", "session_id": session_id, "timeout": 30},
            timeout=45, check=False, context_id=context_id,
        )
        status = response_status(response)
    return status


def worktree_branch(path: Path, repo: Path) -> str | None:
    process = run_local(["git", "-C", str(path), "branch", "--show-current"], repo, check=False)
    value = process.stdout.strip()
    return value if process.returncode == 0 and value else None


def discover_owned_worktree(response: Any, repo: Path, expected_branch: str) -> Path:
    matches: list[Path] = []
    for raw_path in response_worktree_paths(response):
        candidate = Path(raw_path)
        if candidate.exists() and worktree_branch(candidate, repo) == expected_branch:
            matches.append(candidate.resolve())
    unique = sorted(set(matches))
    if len(unique) != 1:
        raise BenchmarkError(
            f"agent response did not identify exactly one worktree on owned branch {expected_branch!r}"
        )
    return unique[0]


def clean_owned_worktree(
    repo: Path,
    path: str,
    terminal: bool,
    *,
    expected_branch: str | None = None,
    expected_path: str | None = None,
    expected_head: str | None = None,
    ownership_proven: bool = False,
) -> dict[str, Any]:
    candidate = Path(path)
    result: dict[str, Any] = {
        "action": "remove_worktree",
        "path_sha256": sha256_bytes(str(candidate.resolve(strict=False)).encode()),
        "branch_sha256": sha256_bytes(expected_branch.encode()) if expected_branch else None,
        "head_sha256": sha256_bytes(expected_head.encode()) if expected_head else None,
        "ownership_proven": ownership_proven,
        "worktree_removed": False,
        "worktree_absent": False,
        "branch_removed": False,
        "branch_absent": False,
        "removed": False,
        "reason": None,
    }
    if not terminal:
        result["reason"] = "session_nonterminal"
        return result
    if expected_path is not None and candidate.resolve() != Path(expected_path).resolve():
        result["reason"] = "ownership_path_mismatch"
        return result
    if (
        not ownership_proven
        or expected_path is None
        or expected_head is None
    ):
        result["reason"] = "ownership_unproven"
        return result
    branch_ref = f"refs/heads/{expected_branch}" if expected_branch else None
    if branch_ref:
        branch_lookup = run_local(
            ["git", "show-ref", "--verify", "--hash", branch_ref], repo, check=False
        )
        if branch_lookup.returncode == 0 and branch_lookup.stdout.strip() != expected_head:
            result["reason"] = "ownership_head_mismatch"
            return result

    if candidate.exists():
        if worktree_branch(candidate, repo) != expected_branch:
            result["reason"] = "ownership_branch_mismatch"
            return result
        worktree_head = run_local(["git", "-C", str(candidate), "rev-parse", "HEAD"], repo, check=False)
        if worktree_head.returncode != 0 or worktree_head.stdout.strip() != expected_head:
            result["reason"] = "ownership_head_mismatch"
            return result
        listed = run_local(["git", "worktree", "list", "--porcelain"], repo).stdout
        if f"worktree {candidate.resolve()}\n" not in listed:
            result["reason"] = "not_registered"
            return result
        dirty = run_local(
            ["git", "-C", str(candidate), "status", "--porcelain=v1", "--untracked-files=all"],
            repo,
            check=False,
        ).stdout.strip()
        if dirty:
            result["reason"] = "dirty"
            return result
        removal = run_local(["git", "worktree", "remove", str(candidate)], repo, check=False)
        if removal.returncode != 0:
            result["reason"] = "git_worktree_remove_failed"
            return result
        result["worktree_removed"] = True

    listed_after_removal = run_local(["git", "worktree", "list", "--porcelain"], repo).stdout
    result["worktree_absent"] = (
        not candidate.exists() and f"worktree {candidate.resolve(strict=False)}\n" not in listed_after_removal
    )
    if not result["worktree_absent"]:
        result["reason"] = "worktree_absence_unproven"
        return result

    if branch_ref:
        branch_lookup = run_local(
            ["git", "show-ref", "--verify", "--hash", branch_ref], repo, check=False
        )
        if branch_lookup.returncode == 0:
            if branch_lookup.stdout.strip() != expected_head:
                result["reason"] = "ownership_head_mismatch"
                return result
            if f"branch {branch_ref}\n" in listed_after_removal:
                result["reason"] = "branch_still_checked_out"
                return result
            deletion = run_local(["git", "branch", "-D", "--", expected_branch], repo, check=False)
            if deletion.returncode != 0:
                result["reason"] = "git_branch_remove_failed"
                return result
            result["branch_removed"] = True

        branch_verification = run_local(
            ["git", "show-ref", "--verify", "--quiet", branch_ref], repo, check=False
        )
        result["branch_absent"] = branch_verification.returncode != 0
    else:
        result["branch_absent"] = True
    result["removed"] = result["worktree_absent"] and result["branch_absent"]
    result["reason"] = None if result["removed"] else "branch_absence_unproven"
    return result


def run_command(args: argparse.Namespace) -> int:
    policy_digest_probe = getattr(args, "policy_digest_probe", False) is True
    expected_route_observation_count = getattr(
        args, "expected_route_observation_count", 1
    )
    if not args.confirm_live_debug_app or not args.confirm_process_state:
        raise BenchmarkError("run requires --confirm-live-debug-app and --confirm-process-state")
    plan_path = Path(args.plan).expanduser().resolve(strict=True)
    plan = load_plan(plan_path)
    configured_states, configured_checkouts, configured_routes, configured_widths = configured_matrix_variants(plan)
    if args.process_state not in configured_states:
        raise BenchmarkError("run process state was not declared by the frozen plan")
    if args.checkout_kind not in configured_checkouts:
        raise BenchmarkError("run checkout kind was not declared by the frozen plan")
    if args.route not in configured_routes:
        raise BenchmarkError("run route was not declared by the frozen plan")
    if args.width not in configured_widths:
        raise BenchmarkError("run width was not declared by the frozen plan")
    if plan["scope"].get("target_kind") == "real-repository-dedicated" and not args.confirm_dedicated_workspace:
        raise BenchmarkError("real-repository runs require --confirm-dedicated-workspace")
    if policy_digest_probe:
        exact_probe_configuration = {
            "process_state": "warm",
            "checkout_kind": "linked-worktree",
            "route": "projected",
            "width": 1,
            "invocation": 1,
            "warmups": 0,
            "samples": 1,
            "bypass_prefix_control_cache": True,
            "expected_route_observation_count": (
                policy_digest_probe_route_observation_count("diffSeedServing")
            ),
        }
        if any(getattr(args, key, None) != value for key, value in exact_probe_configuration.items()):
            raise BenchmarkError("policy-digest-probe configuration must remain exact")
    elif args.warmups != FIXED_WARMUPS or args.samples != FIXED_RETAINED_SAMPLES:
        raise BenchmarkError("run requires one excluded warmup and exactly five retained samples")
    cli = resolve_cli(args.cli)
    root = Path(plan["scope"]["root_path"])
    validate_planned_base_commit(plan, root)
    resolved_cli = cli.resolve(strict=True)
    build_identity = exact_live_build_identity(cli, plan)
    committed_fixture = {
        "base_commit_oid": str(plan["dataset"]["base_commit_oid"]),
        "read_blob_sha256": str(plan["dataset"]["read_blob_sha256"]),
        "read_path": str(plan["dataset"]["read_path"]),
        "search_marker": str(plan["dataset"]["search_marker"]),
        "read_marker": str(plan["dataset"]["read_marker"]),
    }
    artifact_label = (
        "policy-digest-probe"
        if policy_digest_probe
        else f"{args.process_state}-{args.route}-w{args.width}"
    )
    artifact = make_artifact(Path(args.output_root), artifact_label)
    runner = CLIRunner(
        cli, plan["scope"]["window_id"], plan["scope"]["context_id"], root, artifact
    )
    save_json(artifact / "plan.json", plan, exclusive=True)
    state: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION, "plan_sha256": plan["plan_sha256"], "sessions": [],
        "worktrees": [], "attempts": [], "control_id": None, "scope_reset": False,
        "benchmark_gate_expected_enabled": True, "memory_session_id": None,
        "build_identity": build_identity,
    }
    save_json(artifact / "state.json", state)
    verify_scope(runner, plan)
    require_benchmark_gate(runner)
    verify_disposable_target(runner, plan, require_only_planned_root=True)
    if args.process_state == "aged":
        inventory = runner.call("aged-session-inventory", "agent_manage", {"op": "list_sessions", "limit": 500})
        session_count = sum(1 for item in walk_json(inventory) if isinstance(item, dict) and "session_id" in item)
        if session_count < args.minimum_aged_sessions:
            raise BenchmarkError(f"aged cohort requires at least {args.minimum_aged_sessions} existing sessions; found {session_count}")
    control_id: str | None = None
    memory_session_id: str | None = None
    memory_acquisition = MemorySamplerAcquisition(label=artifact.name)
    invocation = args.invocation
    sample_records: list[dict[str, Any]] = []
    operational_error: str | None = None
    cleanup: list[dict[str, Any]] = []
    control_response: Any = None
    try:
        control_id, control_response = set_route(
            runner,
            plan,
            args.route,
            bypass_prefix_control_cache=args.bypass_prefix_control_cache,
        )
        state["control_id"] = control_id
        state["control_response"] = control_response
        save_json(artifact / "state.json", state)
        memory_session_id, memory_start_response = start_owned_memory_sampler(
            runner, artifact.name, memory_acquisition
        )
        state["memory_session_id"] = memory_session_id
        state["memory_start_response_recorded"] = call_succeeded(memory_start_response)
        save_json(artifact / "state.json", state)
        total_groups = args.warmups + args.samples
        global_ordinal = 0
        for group in range(total_groups):
            warmup = group < args.warmups
            armed: list[tuple[int, str, str, str]] = []
            for member in range(args.width):
                global_ordinal += 1
                branch = safe_name(
                    f"rpce-bench-{artifact.name}-i{invocation}-o{global_ordinal}"
                )[:120]
                token, correlation = arm_sample(
                    runner, plan, control_id, args.route, args.process_state,
                    invocation, global_ordinal, warmup, branch,
                )
                armed.append((global_ordinal, token, correlation, branch))
                state["attempts"].append({
                    "correlation_id": correlation,
                    "control_id": control_id,
                    "invocation": invocation,
                    "ordinal": global_ordinal,
                    "warmup": warmup,
                    "branch": branch,
                    "expected_head": plan["dataset"]["base_commit_oid"],
                    "state": "armed",
                    "session_id": None,
                    "context_id": None,
                    "worktree_id": None,
                    "path": None,
                })
                save_json(artifact / "state.json", state)
            starts: dict[int, Any] = {}
            with ThreadPoolExecutor(max_workers=args.width) as pool:
                futures = {
                    pool.submit(
                        start_agent, runner, plan, args.route, token, invocation, ordinal,
                        f"{artifact.name}-{group}", branch,
                    ): ordinal
                    for ordinal, token, _, branch in armed
                }
                for future in as_completed(futures):
                    starts[futures[future]] = future.result()
            for ordinal, _, correlation, branch in armed:
                start = starts[ordinal]
                session_id = response_session_id(start)
                context_id = response_context_id(start)
                if context_id is None:
                    raise BenchmarkError("agent start omitted the child context_id")
                owned_worktree = discover_owned_worktree(start, root, branch)
                worktree_id, bound_worktree_path = exact_response_worktree_binding(
                    start, owned_worktree
                )
                if bound_worktree_path != str(owned_worktree):
                    raise BenchmarkError("agent worktree binding path changed after discovery")
                attempt = next(
                    item for item in state["attempts"]
                    if item["correlation_id"] == correlation
                )
                attempt.update({
                    "state": "started", "session_id": session_id,
                    "context_id": context_id, "worktree_id": worktree_id,
                    "path": str(owned_worktree),
                    "path_sha256": sha256_bytes(str(owned_worktree).encode()),
                })
                state["sessions"].append({"session_id": session_id, "context_id": context_id, "terminal": False})
                state["worktrees"].append({
                    "path": str(owned_worktree), "worktree_id": worktree_id,
                    "owned": True, "branch": branch,
                })
                save_json(artifact / "state.json", state)
                correctness, direct_tools, root_identity = first_search_read(
                    runner, plan, correlation, context_id, owned_worktree, worktree_id
                )
                checkpoint_payload, checkpoint_capture = capture_diagnostic(
                    runner, plan, correlation, action="snapshot",
                    label=f"primary-checkpoint-{ordinal}",
                )
                primary_performance = {
                    "identity": {
                        "correlation_id": correlation,
                        "session_id": session_id,
                        "context_id": context_id,
                        "invocation": invocation,
                        "ordinal": ordinal,
                        "build": build_identity,
                    },
                    "committed_fixture": committed_fixture,
                    "direct_tool_evidence": direct_tools,
                    "diagnostic_checkpoint": checkpoint_payload,
                    "checkpoint_capture": checkpoint_capture,
                    "resource_cleanup": None,
                    "valid": False,
                    "invalid_reasons": ["resource_cleanup_pending"],
                }
                follow_on: dict[str, Any] = {
                    "ok": False, "completed": False,
                    "failures": [{"operation": "collection", "type": "not_started"}],
                }
                export_payload: dict[str, Any] = {}
                export_capture: dict[str, Any]
                try:
                    follow_on = collect_follow_on_evidence(
                        runner, plan, correlation, context_id, root_identity,
                        worktree_id, owned_worktree
                    )
                except BaseException as error:
                    follow_on = {
                        "ok": False, "completed": True,
                        "failures": [{
                            "operation": "collection",
                            "type": operation_failure_type(error),
                            "error": repr(error),
                        }],
                    }
                finally:
                    export_payload, export_capture = capture_diagnostic(
                        runner, plan, correlation, action="export",
                        label=f"export-{ordinal}",
                    )
                collection_failures = validate_follow_on_collection(follow_on)
                correctness["follow_on"] = not collection_failures
                follow_on_failures = validate_export(
                    export_payload, args.route, correctness,
                    expected_correlation=correlation,
                    expected_session=session_id,
                    expected_invocation=invocation,
                    expected_ordinal=ordinal,
                    expected_route_observation_count=expected_route_observation_count,
                )
                follow_on_failures.extend(
                    f"follow_on_collection:{failure}" for failure in collection_failures
                )
                if export_capture.get("ok") is not True:
                    follow_on_failures.append(
                        f"final_export_{export_capture.get('type') or 'failed'}"
                    )
                follow_on_acceptance = {
                    "accepted": not follow_on_failures,
                    "invalid_reasons": follow_on_failures,
                    "collection": follow_on,
                    "final_export": export_payload,
                    "export_capture": export_capture,
                }
                try:
                    status = terminalize(runner, session_id, context_id)
                except BaseException as error:
                    status = f"terminalize_error:{error!r}"
                state["sessions"][-1]["terminal"] = status in TERMINAL_STATES
                state["sessions"][-1]["status"] = status
                record = {
                    "schema_version": SCHEMA_VERSION, "plan_sha256": plan["plan_sha256"],
                    "artifact_id": artifact.name,
                    "process_state": args.process_state, "checkout_kind": args.checkout_kind,
                    "route": args.route, "width": args.width, "invocation": invocation,
                    "ordinal": ordinal, "warmup": warmup, "correlation_id": correlation,
                    "session_id": session_id,
                    "context_id": context_id, "correctness": correctness,
                    "direct_tool_evidence": direct_tools, "follow_on_evidence": follow_on,
                    "primary_performance": primary_performance,
                    "follow_on_acceptance": follow_on_acceptance,
                    "valid": False, "invalid_reasons": ["resource_cleanup_pending"],
                    "diagnostic": export_payload,
                }
                sample_records.append(record)
                save_json(artifact / "state.json", state)
    except BaseException as error:
        operational_error = repr(error)
    finally:
        state["cleanup_entered"] = True
        try:
            memory_cleanup, resources = cleanup_memory_sampler_acquisition(
                runner, memory_acquisition, label=artifact.name,
            )
        except BaseException as cleanup_error:
            memory_cleanup = {
                "action": "stop_memory_sampler", "ok": False,
                "verified_stopped": False, "stop_attempted": False,
                "manual_cleanup": True,
                "reason": f"memory sampler cleanup failed: {cleanup_error!r}",
            }
            resources = {
                "available": False,
                "reason": "sampler_cleanup_failed",
                "error": repr(cleanup_error),
            }
        save_json(artifact / "resources.json", resources, exclusive=True)
        state["memory_stopped"] = memory_cleanup.get("verified_stopped") is True
        try:
            cleanup.extend(cleanup_benchmark_attempts(runner, plan, state, artifact.name))
        except BaseException as cleanup_error:
            state["cleanup_manual_required"] = True
            cleanup.append({
                "action": "recover_agent_worktrees", "ok": False,
                "manual_cleanup": True, "reason": operation_failure_type(cleanup_error),
            })
        state["route_restored"] = control_id is None
        if control_id is not None:
            try:
                restore_response = runner.call(
                    "restore-route", DEBUG_TOOL,
                    diagnostic_payload(plan, "restore_flags", control_id=control_id), check=False,
                )
                state["route_restored"] = call_succeeded(restore_response)
            except BaseException:
                state["route_restored"] = False
        try:
            reset_response = runner.call(
                "reset-scope", DEBUG_TOOL, diagnostic_payload(plan, "reset"), check=False
            )
            state["scope_reset"] = call_succeeded(reset_response) and isinstance(
                find_value(reset_response, "reset"), dict
            )
        except BaseException:
            state["scope_reset"] = False
        try:
            require_benchmark_gate(runner)
            state["benchmark_gate_unchanged"] = True
        except BenchmarkError:
            state["benchmark_gate_unchanged"] = False
        cleanup.extend([
            memory_cleanup,
            {
                "action": "restore_route", "ok": state["route_restored"],
                "reason": "not_acquired" if control_id is None else None,
            },
            {"action": "reset_diagnostics", "ok": state["scope_reset"]},
            {"action": "preserve_benchmark_setting", "ok": state["benchmark_gate_unchanged"]},
        ])
        final_target_ok = False
        try:
            verify_disposable_target(runner, plan, require_only_planned_root=True)
            final_target_ok = True
        except BenchmarkError:
            pass
        cleanup.append({"action": "restore_workspace_roots", "ok": final_target_ok})
        save_cleanup_proof(artifact / "cleanup.json", cleanup)
        save_json(artifact / "state.json", state)
    cleanup_ok = validate_cleanup_evidence(
        cleanup, run_artifact=True, expected_agent_count=len(state.get("attempts", [])),
        expected_worktree_count=len({
            item.get("path") for item in state.get("attempts", [])
            if isinstance(item, dict) and isinstance(item.get("path"), str)
        }),
    )
    resource_metrics = find_value(resources, "metrics")
    resource_failures = validate_resource_evidence(resource_metrics)
    try:
        build_unchanged = (
            resolved_cli.exists()
            and exact_live_build_identity(cli, plan) == build_identity
            and validate_planned_base_commit(plan, root) == build_identity["base_commit_oid"]
        )
    except (BenchmarkError, OSError):
        build_unchanged = False
    for record in sample_records:
        primary = record["primary_performance"]
        finalize_primary_performance(
            primary, route=args.route,
            expected_correlation=record["correlation_id"],
            expected_session=record["session_id"],
            expected_context=record["context_id"],
            expected_scope_context=plan["scope"]["context_id"],
            expected_invocation=record["invocation"],
            expected_ordinal=record["ordinal"],
            expected_build=build_identity,
            expected_fixture=committed_fixture,
            resource_failures=resource_failures,
            cleanup_complete=cleanup_ok,
            build_unchanged=build_unchanged,
            expected_route_observation_count=expected_route_observation_count,
        )
        follow_on_acceptance = record["follow_on_acceptance"]
        record["valid"] = (
            primary["valid"] is True
            and follow_on_acceptance["accepted"] is True
        )
        record["invalid_reasons"] = (
            [f"primary:{reason}" for reason in primary["invalid_reasons"]]
            + [
                f"follow_on:{reason}"
                for reason in follow_on_acceptance["invalid_reasons"]
            ]
        )
        append_ndjson(artifact / "samples.ndjson", record)
    valid = [sample for sample in sample_records if sample["valid"] and not sample["warmup"]]
    primary_valid = [
        sample for sample in sample_records
        if sample["primary_performance"]["valid"] and not sample["warmup"]
    ]
    follow_on_accepted = [
        sample for sample in sample_records
        if sample["follow_on_acceptance"]["accepted"] and not sample["warmup"]
    ]
    summary = {
        "schema_version": SCHEMA_VERSION,
        "status": "failed" if operational_error or not cleanup_ok else "completed",
        "artifact_id": artifact.name,
        "plan_sha256": plan["plan_sha256"], "artifact_directory": str(artifact),
        "build_identity": build_identity,
        "process_state": args.process_state, "checkout_kind": args.checkout_kind,
        "route": args.route, "width": args.width, "invocation": args.invocation,
        "warmup_groups": args.warmups, "retained_groups": args.samples,
        "expected_sample_count": (args.warmups + args.samples) * args.width,
        "operational_error": operational_error,
        "sample_count": len(sample_records), "valid_retained_count": len(valid),
        "primary_valid_retained_count": len(primary_valid),
        "follow_on_accepted_retained_count": len(follow_on_accepted),
        "invalid_count": len([sample for sample in sample_records if not sample["valid"]]),
        "cleanup_complete": cleanup_ok,
    }
    if policy_digest_probe:
        cache_bypass_evidence = prefix_control_cache_bypass_evidence(control_response)
        diagnostic_gate_passed = (
            summary["status"] == "completed"
            and summary["sample_count"] == 1
            and summary["valid_retained_count"] == 1
            and summary["invalid_count"] == 0
            and cache_bypass_evidence["observed"] is True
        )
        summary.update({
            "kind": "policy-digest-probe",
            "non_aggregatable": True,
            "performance_acceptance_applied": False,
            "prefix_control_cache_bypassed": cache_bypass_evidence["observed"],
            "prefix_control_cache_bypass_evidence": cache_bypass_evidence,
            "diagnostic_gate_passed": diagnostic_gate_passed,
        })
        if not diagnostic_gate_passed:
            summary["status"] = "failed"
    save_json(artifact / "summary.json", summary, exclusive=True)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["status"] == "completed" else 1


def configure_policy_digest_probe(args: argparse.Namespace) -> argparse.Namespace:
    """Force the single diagnostic-only canonicalization probe configuration."""
    args.process_state = "warm"
    args.checkout_kind = "linked-worktree"
    args.route = "projected"
    args.width = 1
    args.invocation = 1
    args.warmups = 0
    args.samples = 1
    args.minimum_aged_sessions = 0
    args.confirm_process_state = True
    args.bypass_prefix_control_cache = True
    args.expected_route_observation_count = (
        policy_digest_probe_route_observation_count("diffSeedServing")
    )
    args.policy_digest_probe = True
    return args


def policy_digest_probe_command(args: argparse.Namespace) -> int:
    return run_command(configure_policy_digest_probe(args))


def bounded_poll_search(
    runner: CLIRunner,
    context_id: str | None,
    marker: str,
    path: str,
    *,
    expected_root_id: str,
    expected_root_path: str,
    expected_root_type: str,
    present: bool,
    timeout: float = 30,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    last_evidence: dict[str, Any] = {"ok": False, "error": "no structured response"}
    while time.monotonic() < deadline:
        response = runner.call(
            "watcher-poll", "file_search",
            {"pattern": marker, "regex": False, "mode": "content", "filter": {"paths": [path]},
             "max_results": 20, "context_id": context_id},
            timeout=60, check=False,
        )
        if present:
            last_evidence = structured_success_evidence(
                response, "file_search", expected_root_id=expected_root_id,
                expected_root_path=expected_root_path, expected_root_type=expected_root_type,
                expected_file_path=path, expected_file_type="file", expected_content=marker,
            )
        else:
            last_evidence = structured_empty_success_evidence(
                response, "file_search", expected_root_id=expected_root_id,
                expected_root_path=expected_root_path, expected_root_type=expected_root_type,
            )
        if last_evidence["ok"]:
            return last_evidence
        time.sleep(0.2)
    return last_evidence


def overlap(call: TimedCall, mutation: TimedCall) -> bool:
    return call.started_ns < mutation.finished_ns and call.finished_ns > mutation.started_ns


def call_succeeded(value: Any) -> bool:
    if isinstance(value, TimedCall):
        if value.returncode != 0:
            return False
        value = value.response
    if find_value(value, "_benchmark_cli_returncode") not in (None, 0):
        return False
    if find_value(value, "_benchmark_binding_valid") is False:
        return False
    if find_value(value, "_benchmark_output_valid") is False:
        return False
    if find_value(value, "isError") is True:
        return False
    if find_value(value, "ok") is False:
        return False
    return True


def transcript_xml_from_log(value: Any) -> str:
    transcript = find_value(value, "transcript_xml")
    if not isinstance(transcript, str) or not transcript:
        raise BenchmarkError("agent log omitted transcript_xml")
    return transcript


def parse_agent_transcript_records(transcript_xml: str) -> dict[str, Any]:
    raw_tool_event_count = len(re.findall(r"<tool_(?:call|result)\b", transcript_xml))
    if re.search(r"<(?:function|command|shell|exec)_(?:call|result)\b", transcript_xml):
        raise BenchmarkError("transcript contained an unsupported substitute tool-event encoding")
    event_pattern = re.compile(
        r'<tool_call name="([^"]+)"(?:>(.*?)</tool_call>|/>)'
        r'|<tool_result name="([^"]+)"([^>]*?)(?:>(.*?)</tool_result>|/>)'
        r'|<assistant>(.*?)</assistant>',
        re.DOTALL,
    )
    calls: list[dict[str, Any]] = []
    results: list[dict[str, Any]] = []
    assistants: list[str] = []
    for ordinal, match in enumerate(event_pattern.finditer(transcript_xml), start=1):
        if match.group(1) is not None:
            tool = match.group(1).split("__")[-1]
            raw = match.group(2)
            if raw is None:
                arguments: Any = {}
            else:
                try:
                    arguments = json.loads(html.unescape(raw))
                except json.JSONDecodeError as error:
                    raise BenchmarkError(f"invalid structured {tool} transcript arguments") from error
            if not isinstance(arguments, dict):
                raise BenchmarkError(f"structured {tool} transcript arguments must be an object")
            calls.append({"ordinal": ordinal, "tool": tool, "arguments": arguments})
        elif match.group(3) is not None:
            tool = match.group(3).split("__")[-1]
            attributes = match.group(4) or ""
            status_match = re.search(r'\bstatus="([^"]+)"', attributes)
            raw_result = match.group(5)
            result: dict[str, Any] | None = None
            if raw_result is not None and raw_result.strip():
                try:
                    parsed_result = json.loads(html.unescape(raw_result))
                except json.JSONDecodeError as error:
                    raise BenchmarkError(f"invalid structured {tool} transcript result") from error
                if not isinstance(parsed_result, dict):
                    raise BenchmarkError(f"structured {tool} transcript result must be an object")
                result = parsed_result
            results.append({
                "ordinal": ordinal, "tool": tool,
                "status": status_match.group(1) if status_match else (
                    result.get("status") if result is not None else None
                ),
                "result": result,
            })
        else:
            assistants.append(html.unescape(match.group(6) or "").strip())
    if len(calls) + len(results) != raw_tool_event_count:
        raise BenchmarkError("transcript contained an unrecognized or malformed tool event")
    return {"calls": calls, "results": results, "assistants": assistants}


def verify_agent_file_tool_transcript(
    transcript_xml: str,
    *,
    expected_output: str,
    expected_marker: str,
    expected_file_path: str,
    expected_pairs: int = 1,
    strict_result_expectations: dict[str, Any] | None = None,
) -> dict[str, Any]:
    records = parse_agent_transcript_records(transcript_xml)
    if expected_pairs < 1:
        raise BenchmarkError("transcript expected pair count must be positive")
    allowed_tools = {"file_search", "read_file"}
    unexpected = sorted({
        item["tool"] for item in records["calls"] + records["results"]
        if item["tool"] not in allowed_tools
    })
    if unexpected:
        raise BenchmarkError(f"transcript used forbidden/substitute tools: {unexpected}")
    expected_tools = [tool for _ in range(expected_pairs) for tool in ("file_search", "read_file")]
    if [item["tool"] for item in records["calls"]] != expected_tools:
        raise BenchmarkError("transcript did not contain the exact alternating file-tool calls")
    if [item["tool"] for item in records["results"]] != expected_tools:
        raise BenchmarkError("transcript did not contain one result for every exact file-tool call")
    statuses = {"ok", "complete", "completed", "ready", "success"}
    previous_ordinal = 0
    reported_statuses: list[str] = []
    structured_results: list[dict[str, Any]] = []
    for call, result in zip(records["calls"], records["results"], strict=True):
        if not (previous_ordinal < call["ordinal"] < result["ordinal"]):
            raise BenchmarkError("transcript tool calls/results were unordered")
        previous_ordinal = result["ordinal"]
        reported_status = result.get("status")
        if reported_status is not None:
            if reported_status not in statuses:
                raise BenchmarkError("transcript contained an explicitly unsuccessful tool result")
            reported_statuses.append(reported_status)
        arguments = call["arguments"]
        if call["tool"] == "file_search":
            search_paths = ((arguments.get("filter") or {}).get("paths"))
            if (
                arguments.get("pattern") != expected_marker
                or arguments.get("regex") is not False
                or search_paths != [expected_file_path]
            ):
                raise BenchmarkError("file_search transcript arguments did not match the exact request")
        else:
            if arguments.get("path") != expected_file_path:
                raise BenchmarkError("read_file transcript arguments did not match the exact request")
        if strict_result_expectations is not None:
            result_payload = result.get("result")
            if not isinstance(result_payload, dict):
                raise BenchmarkError("transcript result omitted structured file-tool evidence")
            expected_content = (
                expected_marker if call["tool"] == "file_search"
                else strict_result_expectations["read_marker"]
            )
            evidence = structured_success_evidence(
                result_payload,
                call["tool"],
                expected_root_id=strict_result_expectations["root_id"],
                expected_root_path=strict_result_expectations["root_path"],
                expected_root_type=strict_result_expectations["root_type"],
                expected_file_path=expected_file_path,
                expected_file_type="file",
                expected_content=expected_content,
                expected_worktree_id=strict_result_expectations["worktree_id"],
                expected_physical_worktree_path=strict_result_expectations["worktree_path"],
            )
            if evidence.get("ok") is not True:
                raise BenchmarkError(
                    f"transcript {call['tool']} result evidence was invalid: {evidence.get('error')}"
                )
            structured_results.append(evidence)
    if not records["assistants"] or records["assistants"][-1] != expected_output:
        raise BenchmarkError("transcript final assistant output mismatch")
    return {
        "call_count": expected_pairs * 2, "result_count": expected_pairs * 2,
        "search_call_count": expected_pairs, "read_call_count": expected_pairs,
        "reported_result_status_count": len(reported_statuses),
        "structured_result_evidence": structured_results,
        "proof_basis": (
            "successful structured result content and exact bound-root identity"
            if strict_result_expectations is not None
            else "spartan ordered invocations and paired result events"
        ),
        "final_output": records["assistants"][-1],
    }


def poll_active_agent(
    runner: CLIRunner,
    session_id: str,
    expected_context_id: str,
    label: str,
) -> dict[str, Any]:
    call = runner.timed_call(
        label, "agent_run", {"op": "poll", "session_id": session_id},
        check=False, context_id=expected_context_id,
    )
    response = call.response
    return {
        "label": label,
        "ok": (
            call_succeeded(response)
            and response_status(response) == "running"
            and response_context_id(response) == expected_context_id
        ),
        "status": response_status(response),
        "context_id": response_context_id(response),
        "started_ns": call.started_ns,
        "finished_ns": call.finished_ns,
    }


def linked_root_removal_evidence(
    active_before_remove: dict[str, Any],
    terminal_status: str,
    revoked_probe: dict[str, Any],
) -> dict[str, Any]:
    ok = (
        active_before_remove.get("ok") is True
        and active_before_remove.get("status") == "running"
        and terminal_status in TERMINAL_STATES
        and revoked_probe.get("ok") is True
    )
    return {
        "ok": ok,
        "active_before_remove": active_before_remove.get("ok") is True,
        "terminal_status": terminal_status,
        "typed_revocation": revoked_probe,
        "no_cross_root_fallback": revoked_probe.get("ok") is True,
    }


def wait_agent_success(
    runner: CLIRunner,
    session_id: str,
    *,
    expected_output: str,
    expected_marker: str,
    expected_file_path: str,
    context_id: str,
    expected_pairs: int = 1,
    strict_result_expectations: dict[str, Any] | None = None,
) -> dict[str, Any]:
    waited = runner.call(
        f"wait-success-{session_id[:8]}", "agent_run",
        {"op": "wait", "session_id": session_id, "timeout": 180}, timeout=210, check=False,
        context_id=context_id,
    )
    log = runner.call(
        f"log-success-{session_id[:8]}", "agent_manage",
        {"op": "get_log", "session_id": session_id, "offset": 0, "limit": 1000},
        timeout=90, check=False, context_id=context_id,
    )
    status = response_status(waited)
    transcript_evidence: dict[str, Any] | None = None
    transcript_error: str | None = None
    try:
        transcript_evidence = verify_agent_file_tool_transcript(
            transcript_xml_from_log(log), expected_output=expected_output,
            expected_marker=expected_marker, expected_file_path=expected_file_path,
            expected_pairs=expected_pairs,
            strict_result_expectations=strict_result_expectations,
        )
    except BenchmarkError as error:
        transcript_error = str(error)
    return {
        "ok": (
            call_succeeded(waited)
            and call_succeeded(log)
            and status == "completed"
            and transcript_evidence is not None
        ),
        "status": status,
        "transcript_evidence": transcript_evidence,
        "transcript_error": transcript_error,
    }


def fixture_relative_path(root: Path, raw: Any, label: str, *, directory: bool) -> tuple[str, Path]:
    if not isinstance(raw, str) or not raw.strip():
        raise BenchmarkError(f"{label} must be a non-empty root-relative path")
    relative = Path(raw)
    if relative.is_absolute() or ".." in relative.parts:
        raise BenchmarkError(f"{label} must remain root-relative")
    resolved = (root / relative).resolve(strict=True)
    if root != resolved and root not in resolved.parents:
        raise BenchmarkError(f"{label} escaped the planned root")
    if directory != resolved.is_dir():
        kind = "directory" if directory else "file"
        raise BenchmarkError(f"{label} must resolve to a {kind}")
    return relative.as_posix(), resolved


def create_codemap_temp_ownership_marker(
    root: Path,
    *,
    artifact_id: str,
    plan_sha256: str,
) -> dict[str, str]:
    marker_path = root / CODEMAP_TEMP_OWNERSHIP_MARKER
    owner_token = str(uuid.uuid4()).upper()
    marker = {
        "schema_version": SCHEMA_VERSION,
        "purpose": "rpce-codemap-gate-temporary-root",
        "root_path": str(root.resolve()),
        "artifact_id": artifact_id,
        "plan_sha256": plan_sha256,
        "owner_token": owner_token,
    }
    secure_write(marker_path, canonical_json(marker), exclusive=True)
    return {
        "marker_path": str(marker_path),
        "marker_sha256": sha256_bytes(canonical_json(marker)),
        "owner_token": owner_token,
    }


def validate_codemap_temp_ownership_marker(
    item: dict[str, Any],
    *,
    artifact_id: str,
    plan_sha256: str,
) -> bool:
    try:
        root = Path(str(item["path"])).resolve(strict=True)
        marker_path = Path(str(item["marker_path"])).resolve(strict=True)
        if marker_path != root / CODEMAP_TEMP_OWNERSHIP_MARKER:
            return False
        raw = marker_path.read_bytes()
        marker = json.loads(raw)
        return (
            sha256_bytes(raw) == item.get("marker_sha256")
            and marker.get("schema_version") == SCHEMA_VERSION
            and marker.get("purpose") == "rpce-codemap-gate-temporary-root"
            and marker.get("root_path") == str(root)
            and marker.get("artifact_id") == artifact_id
            and marker.get("plan_sha256") == plan_sha256
            and marker.get("owner_token") == item.get("owner_token")
        )
    except (KeyError, OSError, json.JSONDecodeError):
        return False


def load_codemap_gate_fixture(
    path: Path,
    *,
    plan: dict[str, Any],
    cold_samples: int,
) -> tuple[dict[str, Any], dict[str, Any]]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or value.get("schema_version") != SCHEMA_VERSION:
        raise BenchmarkError("codemap fixture uses an unsupported schema")
    root = Path(plan["scope"]["root_path"]).resolve(strict=True)
    if int(plan["dataset"].get("asserted_file_count", 0)) < CODEMAP_GATE_MINIMUM_SUPPORTED_FILES:
        raise BenchmarkError(
            f"codemap gate requires at least {CODEMAP_GATE_MINIMUM_SUPPORTED_FILES} asserted files"
        )

    individuals: list[dict[str, str]] = []
    for index, item in enumerate(value.get("individuals") or []):
        if not isinstance(item, dict):
            raise BenchmarkError("every individual fixture must be an object")
        relative, resolved = fixture_relative_path(
            root, item.get("path"), f"individuals[{index}].path", directory=False
        )
        marker = item.get("marker")
        if not isinstance(marker, str) or not marker or marker not in resolved.read_text(
            encoding="utf-8", errors="strict"
        ):
            raise BenchmarkError(f"individuals[{index}].marker is absent from the exact fixture")
        individuals.append({"path": relative, "marker": marker})

    directories: list[dict[str, str]] = []
    for index, item in enumerate(value.get("directories") or []):
        if not isinstance(item, dict):
            raise BenchmarkError("every directory fixture must be an object")
        relative, resolved = fixture_relative_path(
            root, item.get("path"), f"directories[{index}].path", directory=True
        )
        expected_relative, expected = fixture_relative_path(
            root, item.get("expected_file"), f"directories[{index}].expected_file", directory=False
        )
        if resolved != expected and resolved not in expected.parents:
            raise BenchmarkError(f"directories[{index}].expected_file is outside its directory")
        marker = item.get("marker")
        if not isinstance(marker, str) or not marker or marker not in expected.read_text(
            encoding="utf-8", errors="strict"
        ):
            raise BenchmarkError(f"directories[{index}].marker is absent from the exact fixture")
        directories.append({
            "path": relative,
            "expected_file": expected_relative,
            "marker": marker,
        })

    if len({item["path"] for item in individuals}) < cold_samples:
        raise BenchmarkError(f"codemap fixture requires {cold_samples} unique individual files")
    if len({item["path"] for item in directories}) < cold_samples:
        raise BenchmarkError(f"codemap fixture requires {cold_samples} unique directories")

    overflow_relative, overflow = fixture_relative_path(
        root, value.get("overflow_directory"), "overflow_directory", directory=True
    )
    overflow_members = {
        item["path"] for item in individuals
        if overflow == (root / item["path"]).resolve()
        or overflow in (root / item["path"]).resolve().parents
    }
    if len(overflow_members) < 2:
        raise BenchmarkError("overflow_directory must contain at least two individual fixtures")
    watcher_relative = value.get("watcher_directory", ".rpce-codemap-gate")
    if not isinstance(watcher_relative, str):
        raise BenchmarkError("watcher_directory must be a relative string")
    watcher = Path(watcher_relative)
    if watcher.is_absolute() or ".." in watcher.parts or not watcher.parts:
        raise BenchmarkError("watcher_directory must remain root-relative")

    normalized = {
        "schema_version": SCHEMA_VERSION,
        "individuals": individuals,
        "directories": directories,
        "overflow_directory": overflow_relative,
        "watcher_directory": watcher.as_posix(),
    }
    sanitized = {
        "schema_version": SCHEMA_VERSION,
        "fixture_sha256": sha256_bytes(canonical_json(normalized)),
        "individual_count": len(individuals),
        "directory_count": len(directories),
        "individual_path_sha256": [sha256_bytes(item["path"].encode()) for item in individuals],
        "directory_path_sha256": [sha256_bytes(item["path"].encode()) for item in directories],
        "overflow_path_sha256": sha256_bytes(overflow_relative.encode()),
    }
    return normalized, sanitized


def codemap_structure_evidence(
    value: Any,
    *,
    expected_root_id: str,
    expected_root_path: str,
    expected_root_type: str,
    expected_file_path: str,
    expected_marker: str,
    expected_file_type: str,
    expected_worktree_id: str | None = None,
    expected_physical_worktree_path: str | None = None,
) -> dict[str, Any]:
    if not call_succeeded(value):
        raise BenchmarkError("get_code_structure transport/tool call failed")
    record = structured_mcp_record(
        value,
        "get_code_structure",
        expected_root_id=expected_root_id,
        expected_root_path=expected_root_path,
        expected_root_type=expected_root_type,
        expected_worktree_id=expected_worktree_id,
        expected_physical_worktree_path=expected_physical_worktree_path,
    )
    if record.get("status") != "ready":
        raise BenchmarkError(f"get_code_structure returned {record.get('status')!r}, not ready")
    if record.get("retry") is not None:
        raise BenchmarkError("ready get_code_structure unexpectedly included retry metadata")
    issues = record.get("issues")
    if not isinstance(issues, list):
        raise BenchmarkError("get_code_structure omitted typed issues")
    expected = canonicalize_evidence_path(expected_file_path, expected_root_path)
    matches = [item for item in record["files"] if item.get("path") == expected]
    if len(matches) != 1:
        raise BenchmarkError("get_code_structure did not return the exact expected logical file")
    matched = matches[0]
    content = matched.get("content")
    if matched.get("type") != expected_file_type or not isinstance(content, str):
        raise BenchmarkError("get_code_structure returned the wrong file type or no codemap text")
    if expected_marker not in content:
        raise BenchmarkError("get_code_structure codemap text omitted the expected real marker")
    return {
        "status": "ready",
        "file_path_sha256": sha256_bytes(expected_file_path.encode()),
        "codemap_content_sha256": sha256_bytes(content.encode()),
        "codemap_content_present": True,
        "issue_codes": sorted({
            str(issue.get("code")) for issue in issues
            if isinstance(issue, dict) and isinstance(issue.get("code"), str)
        }),
        "returned_file_count": len(record["files"]),
    }


def codemap_tree_marker_evidence(
    value: Any,
    *,
    expected_context_id: str,
    expected_root_path: str,
    requested_parent: str,
    expected_file_path: str,
    expected_worktree_id: str | None = None,
    expected_physical_worktree_path: str | None = None,
) -> dict[str, Any]:
    if not call_succeeded(value):
        raise BenchmarkError("get_file_tree transport/tool call failed")
    binding = benchmark_binding(value)
    if (
        not isinstance(binding, dict)
        or str(binding.get("context_id", "")).upper() != expected_context_id.upper()
    ):
        raise BenchmarkError("get_file_tree was not atomically bound to the expected context")
    canonical_root = Path(expected_root_path).expanduser().resolve(strict=False)
    roots = binding_root_paths(value)
    if roots is None or str(canonical_root) not in roots:
        raise BenchmarkError("get_file_tree binding omitted the exact expected root")
    request = value.get("_benchmark_payload") if isinstance(value, dict) else None
    if not isinstance(request, dict):
        raise BenchmarkError("get_file_tree omitted its exact request payload")
    if (
        request.get("type") != "files"
        or request.get("mode") != "full"
        or request.get("max_depth") != 1
        or request.get("path") != requested_parent
    ):
        raise BenchmarkError("get_file_tree request did not bind the exact parent contract")
    canonical_parent = Path(
        canonicalize_evidence_path(requested_parent, str(canonical_root))
    )
    canonical_file = Path(
        canonicalize_evidence_path(expected_file_path, str(canonical_root))
    )
    if canonical_file.parent != canonical_parent:
        raise BenchmarkError("get_file_tree expected file was not a direct child of its parent")
    payload = tool_payload(value, "get_file_tree")
    if expected_worktree_id is not None and expected_physical_worktree_path is not None:
        validate_worktree_scope(
            payload,
            expected_logical_root_path=expected_root_path,
            expected_worktree_id=expected_worktree_id,
            expected_physical_worktree_path=expected_physical_worktree_path,
        )
    tree = payload.get("tree")
    if not isinstance(tree, str) or payload.get("uses_legend") is not True:
        raise BenchmarkError("get_file_tree omitted its exact codemap marker legend")
    lines = tree.splitlines()
    if not lines:
        raise BenchmarkError("get_file_tree returned an empty tree")
    relative_parent = canonical_parent.relative_to(canonical_root)
    logical_parent = (
        canonical_root.name
        if str(relative_parent) == "."
        else f"{canonical_root.name}/{relative_parent.as_posix()}"
    )
    if lines[0].rstrip() not in {logical_parent, str(canonical_parent)}:
        raise BenchmarkError("get_file_tree header did not identify the exact requested parent")
    name = canonical_file.name
    marker_lines = [
        line for line in lines
        if line.rstrip() in {f"├── {name} +", f"└── {name} +"}
    ]
    if (
        len(marker_lines) != 1
        or payload.get("was_truncated") is True
        or CODEMAP_TREE_LEGEND not in response_text(value)
        or (canonical_parent / name).resolve(strict=False) != canonical_file
    ):
        raise BenchmarkError("get_file_tree omitted the exact full-path current marker or legend")
    return {
        "status": "ready",
        "file_path_sha256": sha256_bytes(expected_file_path.encode()),
        "parent_path_sha256": sha256_bytes(requested_parent.encode()),
        "context_id_sha256": sha256_bytes(expected_context_id.upper().encode()),
        "marker_present": True,
        "legend_present": True,
        "tree_sha256": sha256_bytes(tree.encode()),
    }


def codemap_retryable_terminal_evidence(
    value: Any,
    *,
    expected_status: str,
    expected_issue_code: str,
) -> dict[str, Any]:
    payload = tool_payload(value, "get_code_structure")
    issues = payload.get("issues")
    retry = payload.get("retry")
    if payload.get("status") != expected_status or payload.get("files") != []:
        raise BenchmarkError(f"expected empty typed {expected_status} code-structure result")
    if not isinstance(issues, list) or not isinstance(retry, dict):
        raise BenchmarkError("retryable terminal result omitted typed issues or reply retry")
    matches = [item for item in issues if isinstance(item, dict) and item.get("code") == expected_issue_code]
    if len(matches) != 1:
        raise BenchmarkError(f"terminal result omitted exact issue {expected_issue_code}")
    issue = matches[0]
    if (
        issue.get("retryable") is not True
        or not positive_integer(issue.get("retry_after_ms"))
        or not isinstance(issue.get("attempted"), int)
        or not (
            CODEMAP_GATE_WAIT_MILLISECONDS - CODEMAP_GATE_HARNESS_ALLOWANCE_MILLISECONDS
            <= issue["attempted"]
            <= CODEMAP_GATE_WAIT_MILLISECONDS + CODEMAP_GATE_HARNESS_ALLOWANCE_MILLISECONDS
        )
        or issue.get("limit") != CODEMAP_GATE_WAIT_MILLISECONDS
        or retry.get("retryable") is not True
        or not positive_integer(retry.get("retry_after_ms"))
    ):
        raise BenchmarkError("retryable terminal result omitted non-null retry metadata")
    return {
        "status": expected_status,
        "issue_codes": [expected_issue_code],
        "empty": True,
        "retryable": True,
        "retry_after_ms": retry["retry_after_ms"],
        "attempted": issue["attempted"],
        "limit": issue["limit"],
    }


def codemap_budget_evidence(value: Any) -> dict[str, Any]:
    payload = tool_payload(value, "get_code_structure")
    issues = payload.get("issues")
    matches = [
        issue for issue in issues or []
        if isinstance(issue, dict) and issue.get("code") == "hard_budget_exceeded"
    ]
    if (
        payload.get("status") != "budget"
        or payload.get("files") != []
        or len(matches) != 1
        or matches[0].get("attempted") != 2
        or matches[0].get("limit") != 1
    ):
        raise BenchmarkError("strict directory overflow lacked exact empty limit-plus-one evidence")
    return {
        "status": "budget",
        "empty": True,
        "attempted": 2,
        "limit": 1,
        "issue_codes": ["hard_budget_exceeded"],
    }


def codemap_debug_action(
    runner: CLIRunner,
    plan: dict[str, Any],
    action: str,
    **extra: Any,
) -> dict[str, Any]:
    response = runner.call(
        f"codemap-{action}", DEBUG_TOOL, diagnostic_payload(plan, action, **extra), check=False
    )
    if not call_succeeded(response):
        raise BenchmarkError(f"DEBUG codemap action {action!r} failed")
    snapshot = find_value(response, "codemap_projection")
    if not isinstance(snapshot, dict):
        raise BenchmarkError(f"DEBUG codemap action {action!r} omitted codemap_projection")
    return {"response": response, "snapshot": snapshot}


def codemap_counter_delta(before: dict[str, Any], after: dict[str, Any], key: str) -> int:
    left, right = before.get(key), after.get(key)
    if not nonnegative_integer(left) or not nonnegative_integer(right) or right < left:
        raise BenchmarkError(f"invalid monotonic codemap counter {key!r}")
    return right - left


def verify_agent_codemap_transcript(
    transcript_xml: str,
    *,
    expected_output: str,
    expected_calls: list[tuple[str, dict[str, Any]]],
) -> dict[str, Any]:
    records = parse_agent_transcript_records(transcript_xml)
    allowed_tools = {"get_code_structure", "get_file_tree"}
    unexpected = sorted({
        item["tool"] for item in records["calls"] + records["results"]
        if item["tool"] not in allowed_tools
    })
    if unexpected:
        raise BenchmarkError(f"codemap transcript used forbidden/substitute tools: {unexpected}")
    expected_tools = [item[0] for item in expected_calls]
    if [item["tool"] for item in records["calls"]] != expected_tools:
        raise BenchmarkError("codemap transcript tool calls did not match the exact ordered scenario")
    if [item["tool"] for item in records["results"]] != expected_tools:
        raise BenchmarkError("codemap transcript omitted exact ordered paired results")
    previous_ordinal = 0
    successful_statuses = {"ok", "complete", "completed", "ready", "success"}
    reported_status_count = 0
    for (tool, expected), call, result in zip(
        expected_calls, records["calls"], records["results"], strict=True
    ):
        if not (previous_ordinal < call["ordinal"] < result["ordinal"]):
            raise BenchmarkError("codemap transcript calls/results were unordered")
        previous_ordinal = result["ordinal"]
        if result.get("status") is not None:
            if result["status"] not in successful_statuses:
                raise BenchmarkError("codemap transcript contained an unsuccessful tool result")
            reported_status_count += 1
        arguments = call["arguments"]
        if tool == "get_code_structure":
            if arguments.get("scope") != "paths" or arguments.get("paths") != expected["paths"]:
                raise BenchmarkError("codemap transcript structure paths did not match")
            limits = arguments.get("limits")
            if isinstance(limits, dict) and "wait_ms" in limits:
                raise BenchmarkError("agent supplied forbidden model-facing limits.wait_ms")
        elif arguments.get("path") != expected.get("path"):
            raise BenchmarkError("codemap transcript tree path did not match")
    if not records["assistants"] or records["assistants"][-1] != expected_output:
        raise BenchmarkError("codemap transcript final assistant output mismatch")
    return {
        "call_count": len(expected_calls),
        "result_count": len(expected_calls),
        "tool_sequence_sha256": sha256_bytes("\n".join(expected_tools).encode()),
        "ordered_pairs": True,
        "forbidden_tool_count": 0,
        "reported_result_status_count": reported_status_count,
        "structured_result_payload_count": sum(
            result.get("result") is not None for result in records["results"]
        ),
        "same_context_direct_probe_required": any(
            result.get("result") is None for result in records["results"]
        ),
        "final_output": expected_output,
    }


def wait_codemap_agent_success(
    runner: CLIRunner,
    session_id: str,
    context_id: str,
    *,
    start_response: Any,
    expected_output: str,
    expected_calls: list[tuple[str, dict[str, Any]]],
) -> dict[str, Any]:
    waited_call = runner.timed_call(
        f"codemap-wait-{session_id[:8]}", "agent_run",
        {"op": "wait", "session_id": session_id, "timeout": 300},
        timeout=330, check=False, context_id=context_id,
    )
    waited = waited_call.response
    log = runner.call(
        f"codemap-log-{session_id[:8]}", "agent_manage",
        {"op": "get_log", "session_id": session_id, "offset": 0, "limit": 4000},
        timeout=120, check=False, context_id=context_id,
    )
    evidence: dict[str, Any] | None = None
    error: str | None = None
    try:
        evidence = verify_agent_codemap_transcript(
            transcript_xml_from_log(log),
            expected_output=expected_output,
            expected_calls=expected_calls,
        )
    except BenchmarkError as caught:
        error = str(caught)
    status = response_status(waited)
    started_ns = find_value(start_response, "_benchmark_started_monotonic_ns")
    inference_elapsed_ms = (
        (waited_call.finished_ns - started_ns) / 1_000_000
        if isinstance(started_ns, int) and waited_call.finished_ns >= started_ns else None
    )
    return {
        "ok": call_succeeded(waited) and call_succeeded(log) and status == "completed" and evidence is not None,
        "status": status,
        "inference_elapsed_ms": inference_elapsed_ms,
        "transcript_evidence": evidence,
        "transcript_error": error,
    }


def agent_codemap_direct_evidence(
    runner: CLIRunner,
    plan: dict[str, Any],
    *,
    start_response: Any,
    session_id: str,
    context_id: str,
    worktree_path: Path,
    expected_calls: list[tuple[str, dict[str, Any]]],
) -> dict[str, Any]:
    if response_context_id(start_response) != context_id:
        raise BenchmarkError("agent start/session context correlation failed")
    start_bindings = response_worktree_binding_set(start_response)
    matching_bindings = {
        (worktree_id, str(Path(path).resolve(strict=False)))
        for worktree_id, path in start_bindings
        if Path(path).resolve(strict=False) == worktree_path.resolve(strict=False)
    }
    if len(matching_bindings) != 1:
        raise BenchmarkError("agent start omitted one exact worktree binding")
    runtime = runner.call(
        f"codemap-agent-root-{session_id[:8]}", DEBUG_TOOL,
        {"op": "mcp_read_search_runtime_snapshot",
         "window_id": plan["scope"]["window_id"],
         "recent_publication_limit": 0, "root_limit": 256},
        check=False, context_id=context_id,
    )
    if not call_succeeded(runtime):
        raise BenchmarkError("agent-bound runtime root identity snapshot failed")
    root_identity = runtime_root_identity(runtime, str(worktree_path))
    structure_evidence: list[dict[str, Any]] = []
    tree_evidence: list[dict[str, Any]] = []
    for ordinal, (tool, expected) in enumerate(expected_calls, start=1):
        if tool == "get_code_structure":
            timed = runner.timed_call(
                f"codemap-agent-direct-structure-{session_id[:8]}-{ordinal}",
                tool,
                {"scope": "paths", "paths": expected["paths"],
                 "limits": {"max_files": 100, "max_edges": 400,
                            "max_codemap_tokens": 12_000},
                 "context_id": context_id},
                check=False, context_id=context_id,
            )
            evidence = codemap_structure_evidence(
                timed.response,
                expected_root_id=root_identity["id"],
                expected_root_path=root_identity["path"],
                expected_root_type=root_identity["type"],
                expected_file_path=expected["expected_file"],
                expected_marker=expected["marker"],
                expected_file_type=plan["dataset"]["code_file_type"],
            )
            evidence["duration_ms"] = (timed.finished_ns - timed.started_ns) / 1_000_000
            structure_evidence.append(evidence)
        elif tool == "get_file_tree":
            timed = runner.timed_call(
                f"codemap-agent-direct-tree-{session_id[:8]}-{ordinal}",
                tool,
                {"type": "files", "mode": "full", "path": expected["path"],
                 "max_depth": 1, "context_id": context_id},
                check=False, context_id=context_id,
            )
            evidence = codemap_tree_marker_evidence(
                timed.response,
                expected_context_id=context_id,
                expected_root_path=root_identity["path"],
                requested_parent=expected["path"],
                expected_file_path=expected["expected_file"],
            )
            evidence["duration_ms"] = (timed.finished_ns - timed.started_ns) / 1_000_000
            tree_evidence.append(evidence)
        else:
            raise BenchmarkError("agent direct evidence received an unsupported tool")
    if not structure_evidence or not tree_evidence:
        raise BenchmarkError("agent direct evidence requires structure and tree results")
    return {
        "ok": True,
        "proof_basis": "atomic_same_agent_context_direct_probe",
        "session_id_sha256": sha256_bytes(session_id.upper().encode()),
        "context_id_sha256": sha256_bytes(context_id.upper().encode()),
        "worktree_path_sha256": sha256_bytes(str(worktree_path.resolve()).encode()),
        "worktree_id_sha256": sha256_bytes(next(iter(matching_bindings))[0].encode()),
        "root_identity_sha256": sha256_bytes(canonical_json(root_identity)),
        "structure": structure_evidence,
        "trees": tree_evidence,
    }


def verify_agent_codemap_revoked_transcript(
    transcript_xml: str,
    *,
    expected_first_path: str,
) -> dict[str, Any]:
    records = parse_agent_transcript_records(transcript_xml)
    allowed = {"get_code_structure", "get_file_tree"}
    if any(item["tool"] not in allowed for item in records["calls"] + records["results"]):
        raise BenchmarkError("revoked linked agent used a forbidden/substitute tool")
    if not records["calls"]:
        raise BenchmarkError("revoked linked agent transcript omitted its held call")
    matching = [
        call for call in records["calls"]
        if call["tool"] == "get_code_structure"
        and call["arguments"].get("scope") == "paths"
        and call["arguments"].get("paths") == [expected_first_path]
    ]
    if len(matching) != 1:
        raise BenchmarkError("revoked linked agent did not issue one exact held request")
    if len(records["results"]) > len(records["calls"]):
        raise BenchmarkError("revoked linked agent transcript contained orphan results")
    return {
        "ok": True,
        "held_call_present": True,
        "call_count": len(records["calls"]),
        "result_count": len(records["results"]),
        "forbidden_tool_count": 0,
    }


def wait_for_exact_agent_structure_call(
    runner: CLIRunner,
    *,
    session_id: str,
    context_id: str,
    expected_path: str,
    timeout_seconds: float = 30,
) -> dict[str, Any]:
    started_ns = time.monotonic_ns()
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        log = runner.call(
            f"codemap-held-call-{session_id[:8]}", "agent_manage",
            {"op": "get_log", "session_id": session_id, "offset": 0, "limit": 4000},
            timeout=60, check=False, context_id=context_id,
        )
        if call_succeeded(log):
            try:
                records = parse_agent_transcript_records(transcript_xml_from_log(log))
            except BenchmarkError:
                time.sleep(0.1)
                continue
            if any(
                call["tool"] == "get_code_structure"
                and call["arguments"].get("scope") == "paths"
                and call["arguments"].get("paths") == [expected_path]
                for call in records["calls"]
            ):
                finished_ns = time.monotonic_ns()
                return {
                    "ok": True, "observed_before_remove": True,
                    "duration_ms": (finished_ns - started_ns) / 1_000_000,
                    "path_sha256": sha256_bytes(expected_path.encode()),
                }
        time.sleep(0.1)
    raise BenchmarkError("linked agent did not issue the exact held demand before removal")


def codemap_agent_prompt(
    calls: list[tuple[str, dict[str, Any]]],
    *,
    sentinel: str,
) -> str:
    instructions: list[str] = [
        "Use exactly the following RepoPrompt tools in order. Use no other tools, no delegation, "
        "and no Bash, shell, exec, command, scripting, encoded substitutes, or filesystem APIs."
    ]
    for ordinal, (tool, expected) in enumerate(calls, start=1):
        if tool == "get_code_structure":
            instructions.append(
                f"{ordinal}. Call get_code_structure with scope paths and paths exactly {expected['paths']!r}; "
                "do not supply limits.wait_ms; the server owns a fixed 10-second demand wait. "
                "Require status ready with non-empty real codemap content."
            )
        else:
            instructions.append(
                f"{ordinal}. Call get_file_tree with path exactly {expected['path']!r}; require the "
                "exact '+ denotes code-map available' legend and a + marker for file "
                f"{expected['expected_file']!r}."
            )
    instructions.append(f"After every call succeeds, reply exactly {sentinel}.")
    return " ".join(instructions)


def sanitize_codemap_summary_value(value: Any, key: str = "") -> Any:
    sensitive_key = any(fragment in key.lower() for fragment in (
        "path", "root", "session_id", "context_id", "hold_id", "worktree_id",
    ))
    if isinstance(value, dict):
        return {
            child_key: sanitize_codemap_summary_value(
                child, f"{key}.{child_key}" if key else child_key
            )
            for child_key, child in value.items()
            if child_key not in {"transcript_error", "operational_error", "message", "content"}
        }
    if isinstance(value, list):
        return [sanitize_codemap_summary_value(child, key) for child in value]
    if isinstance(value, str) and (sensitive_key or value.startswith("/")):
        return {"sha256": sha256_bytes(value.encode()), "present": True}
    return value


def validate_codemap_baseline(
    baseline_path: Path,
    ledger_path: Path,
    *,
    expected_ledger_sha256: str,
    fixture_sha256: str,
    cold_samples: int,
    warm_samples: int,
) -> tuple[dict[str, Any], dict[str, str]]:
    baseline_value, baseline_raw = load_strict_json(baseline_path, "codemap baseline")
    ledger_value, ledger_raw = load_strict_json(ledger_path, "codemap baseline ledger")
    ledger_sha256 = sha256_bytes(ledger_raw)
    if (
        re.fullmatch(r"[0-9a-f]{64}", expected_ledger_sha256.lower()) is None
        or ledger_sha256 != expected_ledger_sha256.lower()
    ):
        raise BenchmarkError("baseline ledger does not match the independently accepted digest")
    if not isinstance(baseline_value, dict):
        raise BenchmarkError("codemap baseline must contain one object")
    baseline = baseline_value
    if (
        baseline.get("schema_version") != SCHEMA_VERSION
        or baseline.get("kind") != "codemap-gate"
        or baseline.get("decision") != "pass"
        or baseline.get("status") != "completed"
        or baseline.get("fixture_sha256") != fixture_sha256
        or baseline.get("cleanup_complete") is not True
    ):
        raise BenchmarkError("baseline is not a completed accepted-fixture codemap gate")
    artifact_id = baseline.get("artifact_id")
    if not isinstance(artifact_id, str) or not artifact_id:
        raise BenchmarkError("baseline omitted its artifact identity")
    expected_configuration = {
        "cold_samples_per_cohort": cold_samples,
        "warm_samples_per_cohort": warm_samples,
        "wait_contract_ms": CODEMAP_GATE_WAIT_MILLISECONDS,
        "harness_allowance_ms": CODEMAP_GATE_HARNESS_ALLOWANCE_MILLISECONDS,
    }
    if baseline.get("configuration") != expected_configuration:
        raise BenchmarkError("baseline configuration/sample inventory does not match this gate")
    expected_sample_counts = {
        "attempted": 2 * (cold_samples + warm_samples),
        "valid": 2 * (cold_samples + warm_samples),
        "invalid": 0,
    }
    if baseline.get("sample_counts") != expected_sample_counts:
        raise BenchmarkError("baseline sample accounting was not exact")
    gates = baseline.get("gates")
    if not isinstance(gates, dict) or set(gates) != set(CODEMAP_REQUIRED_GATES):
        raise BenchmarkError("baseline gate inventory was not exact")
    if any(gates[name] is not True for name in CODEMAP_REQUIRED_GATES):
        raise BenchmarkError("baseline contains a non-passing gate")
    metrics = baseline.get("metrics")
    if not isinstance(metrics, dict) or set(metrics) != set(CODEMAP_REQUIRED_METRICS):
        raise BenchmarkError("baseline metric inventory was not exact")
    exact_counts = {
        "cold_individual_structure": cold_samples,
        "warm_individual_structure": warm_samples,
        "cold_directory_structure": cold_samples,
        "warm_directory_structure": warm_samples,
        "tree_marker_availability": 2 * (cold_samples + warm_samples),
        "first_search": 2 * (cold_samples // 2),
        "first_read": 2 * (cold_samples // 2),
        "root_readiness": 2 * (cold_samples // 2),
    }
    for name in CODEMAP_REQUIRED_METRICS:
        metric = metrics.get(name)
        if not isinstance(metric, dict) or not positive_integer(metric.get("count")):
            raise BenchmarkError(f"baseline metric {name!r} omitted a positive sample count")
        if name in exact_counts and metric["count"] != exact_counts[name]:
            raise BenchmarkError(f"baseline metric {name!r} sample count was not exact")
        for percentile in ("p50", "p95"):
            value = metric.get(percentile)
            if not finite_number(value) or float(value) <= 0:
                raise BenchmarkError(
                    f"baseline metric {name!r} {percentile} must be finite and positive"
                )
    privacy = baseline.get("privacy")
    if not isinstance(privacy, dict) or set(privacy) != CODEMAP_PRIVACY_KEYS:
        raise BenchmarkError("baseline privacy inventory was not exact")
    if (
        privacy.get("ok") is not True
        or not positive_integer(privacy.get("scanned_file_count"))
        or privacy.get("failure_codes") != []
        or not isinstance(privacy.get("allowlisted_root_sha256"), list)
        or not privacy["allowlisted_root_sha256"]
        or not isinstance(privacy.get("allowlisted_prompt_sha256"), list)
        or not privacy["allowlisted_prompt_sha256"]
    ):
        raise BenchmarkError("baseline privacy evidence was incomplete or non-passing")
    if not isinstance(ledger_value, dict) or set(ledger_value) != {
        "schema_version", "kind", "accepted_summaries",
    }:
        raise BenchmarkError("baseline ledger schema/inventory was not exact")
    accepted = ledger_value.get("accepted_summaries")
    if (
        ledger_value.get("schema_version") != SCHEMA_VERSION
        or ledger_value.get("kind") != CODEMAP_BASELINE_LEDGER_KIND
        or not isinstance(accepted, list)
    ):
        raise BenchmarkError("baseline ledger is unsupported")
    baseline_sha256 = sha256_bytes(baseline_raw)
    matches = [
        entry for entry in accepted
        if isinstance(entry, dict)
        and set(entry) == {"artifact_id", "summary_sha256", "fixture_sha256"}
        and entry.get("artifact_id") == artifact_id
        and entry.get("summary_sha256") == baseline_sha256
        and entry.get("fixture_sha256") == fixture_sha256
    ]
    if len(matches) != 1:
        raise BenchmarkError("baseline artifact digest is not uniquely accepted by the ledger")
    return baseline, {
        "summary_sha256": baseline_sha256,
        "ledger_sha256": ledger_sha256,
        "acceptance_entry_sha256": sha256_bytes(canonical_json(matches[0])),
        "artifact_id_sha256": sha256_bytes(artifact_id.encode()),
    }


def codemap_artifact_privacy_scan(
    artifact: Path,
    *,
    allowlisted_roots: Iterable[Path],
    allowlisted_prompts: Iterable[str],
) -> dict[str, Any]:
    failures: list[str] = []
    scanned_files = 0
    secret_patterns = [
        re.compile(r"\b(?:sk|rk|sess)-[A-Za-z0-9_-]{16,}\b"),
        re.compile(r"(?i)\b(?:authorization|api[_-]?key|access[_-]?token|client[_-]?secret|password)\b\s*[:=]\s*[^\s,}\]]+"),
        re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    ]
    forbidden_roots = [Path.home().resolve(), repository_root().resolve()]
    allowlisted = sorted({str(path.resolve()) for path in allowlisted_roots}, key=len, reverse=True)
    prompt_allowlist = set(allowlisted_prompts)
    if not allowlisted:
        raise BenchmarkError("privacy scan requires at least one allowlisted owned root")
    for directory in [artifact, *[item for item in artifact.rglob("*") if item.is_dir()]]:
        if directory.stat().st_mode & 0o777 != 0o700:
            failures.append(f"directory_mode:{directory.relative_to(artifact) if directory != artifact else '.'}")
    for item in artifact.rglob("*"):
        if not item.is_file():
            continue
        scanned_files += 1
        if item.stat().st_mode & 0o777 != 0o600:
            failures.append(f"file_mode:{item.relative_to(artifact)}")
        raw = item.read_bytes()
        text_value = raw.decode("utf-8", errors="replace")
        for prompt in re.findall(r"<user>(.*?)</user>", text_value, re.DOTALL):
            if html.unescape(prompt).strip() not in prompt_allowlist:
                failures.append(f"unallowlisted_prompt:{item.relative_to(artifact)}")
        scrubbed = text_value
        for owned in allowlisted:
            scrubbed = scrubbed.replace(owned, "<ALLOWLISTED_ROOT>")
        if any(pattern.search(scrubbed) for pattern in secret_patterns):
            failures.append(f"credential_pattern:{item.relative_to(artifact)}")
        for forbidden in forbidden_roots:
            forbidden_text = str(forbidden)
            if forbidden_text not in allowlisted and forbidden_text in scrubbed:
                failures.append(f"private_path:{item.relative_to(artifact)}")

        json_documents: list[Any] = []
        try:
            json_documents.append(json.loads(text_value))
        except json.JSONDecodeError:
            pass
        for document in text_value.split("\n\n---\n\n"):
            try:
                json_documents.append(json.loads(document))
            except json.JSONDecodeError:
                continue
        nested_documents: list[Any] = []
        for document in json_documents:
            for candidate in walk_json(document):
                if not isinstance(candidate, str) or "\n\n---\n\n" not in candidate:
                    continue
                for nested in candidate.split("\n\n---\n\n"):
                    try:
                        nested_documents.append(json.loads(nested))
                    except json.JSONDecodeError:
                        continue
        json_documents.extend(nested_documents)
        for document in json_documents:
            for candidate in walk_json(document):
                if not isinstance(candidate, dict):
                    continue
                for candidate_key, candidate_value in candidate.items():
                    if "path" not in str(candidate_key).lower():
                        continue
                    path_values = candidate_value if isinstance(candidate_value, list) else [candidate_value]
                    for raw_path in path_values:
                        if not isinstance(raw_path, str) or not raw_path.startswith("/"):
                            continue
                        resolved_path = str(Path(raw_path).resolve(strict=False))
                        if not any(
                            resolved_path == owned or resolved_path.startswith(owned + os.sep)
                            for owned in allowlisted
                        ):
                            failures.append(f"unallowlisted_physical_path:{item.relative_to(artifact)}")
    return {
        "ok": not failures,
        "scanned_file_count": scanned_files,
        "failure_codes": sorted(set(failures)),
        "allowlisted_root_sha256": [sha256_bytes(item.encode()) for item in allowlisted],
        "allowlisted_prompt_sha256": sorted(sha256_bytes(item.encode()) for item in prompt_allowlist),
    }


def smoke_command(args: argparse.Namespace) -> int:
    if not args.confirm_live_debug_app or not args.confirm_dedicated_workspace:
        raise BenchmarkError("smoke requires both live-app and dedicated-workspace confirmations")
    plan = load_plan(Path(args.plan).expanduser().resolve(strict=True))
    cli = resolve_cli(args.cli)
    root = Path(plan["scope"]["root_path"])
    base_commit_oid = validate_planned_base_commit(plan, root)
    artifact = make_artifact(Path(args.output_root), "correctness-smoke")
    runner = CLIRunner(
        cli, plan["scope"]["window_id"], plan["scope"]["context_id"], root, artifact
    )
    save_json(artifact / "plan.json", plan, exclusive=True)
    verify_scope(runner, plan)
    verify_disposable_target(runner, plan, require_only_planned_root=True)
    results: dict[str, dict[str, Any]] = {}
    owned_dirs: list[Path] = []
    added_roots: list[Path] = []
    parent_session: str | None = None
    parent_context: str | None = None
    parent_worktree: Path | None = None
    parent_branch = safe_name(f"rpce-bench-smoke-{artifact.name}")[:120]
    linked_secondary: Path | None = None
    linked_parent: Path | None = None
    linked_file: Path | None = None
    smoke_cleanup: list[dict[str, Any]] = []
    detached_workspace_roots: set[Path] = set()
    relevant_agent_status: dict[str, str] = {}
    parent_activity: list[dict[str, Any]] = []
    child_session: str | None = None
    try:
        parent = runner.call(
            "active-parent-start", "agent_run",
            {
                "op": "start", "model_id": "explore", "detach": True,
                "message": (
                    "Make exactly 20 sequential tool calls, strictly alternating: file_search then "
                    "read_file, repeated 10 times. Every file_search must use marker "
                    f"{plan['dataset']['search_marker']!r} with regex false and filter.paths exactly "
                    f"[{plan['dataset']['read_path']!r}]. Every read_file must read exactly "
                    f"{plan['dataset']['read_path']!r}. Use no other tools; do not use Bash, shell, "
                    "exec, delegation, or substitute calls. After all 20 calls succeed, reply exactly "
                    "RPCE_ACTIVE_PARENT_OK."
                ),
                "session_name": "RPCE active-root smoke", "worktree_create": True,
                "worktree_branch": parent_branch,
                "worktree_base_ref": base_commit_oid,
                "worktree_label": f"RPCE smoke {artifact.name}", "context_id": plan["scope"]["context_id"],
            }, timeout=180,
        )
        parent_session = response_session_id(parent)
        parent_context = response_context_id(parent)
        if parent_context is None:
            raise BenchmarkError("smoke parent start omitted context_id")
        parent_worktree = discover_owned_worktree(benchmark_final_response(parent), root, parent_branch)
        parent_worktree_bindings = response_worktree_binding_set(parent)
        parent_started_in_worktree = any(
            Path(path).resolve() == parent_worktree.resolve()
            for _, path in parent_worktree_bindings
        )
        parent_runtime = runner.call(
            "parent-root-identity", DEBUG_TOOL,
            {"op": "mcp_read_search_runtime_snapshot", "window_id": plan["scope"]["window_id"],
             "recent_publication_limit": 0, "root_limit": 256}, check=False,
        )
        if not call_succeeded(parent_runtime):
            raise BenchmarkError("parent runtime root identity snapshot failed")
        parent_root_identity = runtime_root_identity(parent_runtime, str(parent_worktree))
        parent_activity.append(poll_active_agent(
            runner, parent_session, parent_context, "parent-poll-before"
        ))

        child = runner.call(
            "nested-child-start", "agent_run",
            {
                "op": "start", "model_id": "explore", "detach": True, "inherit_worktree": True,
                "message": (
                    "In the inherited worktree, call file_search exactly once for marker "
                    f"{plan['dataset']['search_marker']!r} scoped to {plan['dataset']['read_path']!r}, "
                    f"then call read_file exactly once for {plan['dataset']['read_path']!r}. "
                    "Require both calls to succeed and reply exactly RPCE_INHERITED_CHILD_OK."
                ),
                "session_name": "RPCE inherited child", "context_id": parent_context,
            }, timeout=180, check=False, context_id=parent_context,
        )
        child_session = find_value(child, "session_id")
        child_parent = find_value(child, "parent_session_id")
        child_context = response_context_id(child)
        inheritance = child_inheritance_evidence(
            parent, child, parent_context_id=parent_context,
            parent_worktree_path=str(parent_worktree),
        )
        child_completion = (
            wait_agent_success(
                runner, child_session,
                expected_output="RPCE_INHERITED_CHILD_OK",
                expected_marker=plan["dataset"]["search_marker"],
                expected_file_path=plan["dataset"]["read_path"],
                context_id=child_context,
            )
            if isinstance(child_session, str) and isinstance(child_context, str)
            else {"ok": False, "status": "missing"}
        )
        if isinstance(child_session, str):
            relevant_agent_status[child_session] = str(child_completion["status"])
        nested_ok = (
            call_succeeded(child)
            and isinstance(child_session, str)
            and child_parent == parent_session
            and inheritance["ok"]
            and child_completion["ok"]
        )
        results["nested-inherited-worktree-agent"] = {
            **inheritance,
            "ok": nested_ok, "parent_session_id_matches": child_parent == parent_session,
            "terminal_success": child_completion,
        }

        selected = runner.call(
            "selection-set", "manage_selection",
            {"op": "set", "paths": [plan["dataset"]["read_path"]], "mode": "full", "context_id": parent_context},
            check=False,
        )
        selected_get = runner.call(
            "selection-get", "manage_selection",
            {"op": "get", "view": "files", "context_id": parent_context}, check=False,
        )
        structure = runner.call(
            "structure-selected", "get_code_structure",
            {"scope": "selected", "context_id": parent_context}, check=False,
        )
        explicit_structure = runner.call(
            "structure-explicit", "get_code_structure",
            {"scope": "paths", "paths": [plan["dataset"]["read_path"]],
             "context_id": parent_context}, check=False,
        )
        selected_evidence = structured_success_evidence(
            selected_get, "manage_selection",
            expected_root_id=parent_root_identity["id"],
            expected_root_path=parent_root_identity["path"],
            expected_root_type=parent_root_identity["type"],
            expected_file_path=plan["dataset"]["read_path"],
            expected_file_type="file",
        )
        results["selection-exact-root"] = {
            "ok": call_succeeded(selected) and selected_evidence["ok"],
            "structured_evidence": selected_evidence,
        }
        structure_selected = structured_success_evidence(
            structure, "get_code_structure",
            expected_root_id=parent_root_identity["id"],
            expected_root_path=parent_root_identity["path"],
            expected_root_type=parent_root_identity["type"],
            expected_file_path=plan["dataset"]["read_path"],
            expected_file_type=plan["dataset"]["code_file_type"],
            expected_content=plan["dataset"]["read_marker"],
            require_only_file=False,
        )
        structure_explicit = structured_success_evidence(
            explicit_structure, "get_code_structure",
            expected_root_id=parent_root_identity["id"],
            expected_root_path=parent_root_identity["path"],
            expected_root_type=parent_root_identity["type"],
            expected_file_path=plan["dataset"]["read_path"],
            expected_file_type=plan["dataset"]["code_file_type"],
            expected_content=plan["dataset"]["read_marker"],
            require_only_file=False,
        )
        results["code-structure-exact-root"] = {
            "ok": structure_selected["ok"] and structure_explicit["ok"],
            "selected": structure_selected,
            "explicit": structure_explicit,
        }

        non_git = Path(tempfile.mkdtemp(prefix="rpce-startup-nongit-"))
        owned_dirs.append(non_git)
        non_git_marker = f"RPCE_NON_GIT_{uuid.uuid4().hex}"
        (non_git / "NonGit.swift").write_text(f"struct {non_git_marker} {{}}\n", encoding="utf-8")
        add_non_git = runner.timed_call(
            "add-non-git", "manage_workspaces",
            {"action": "add_folder", "workspace": plan["scope"]["workspace_id"],
             "folder_path": str(non_git), "window_id": plan["scope"]["window_id"]},
        )
        added_roots.append(non_git)
        non_git_runtime = runner.call(
            "non-git-root-identity", DEBUG_TOOL,
            {"op": "mcp_read_search_runtime_snapshot", "window_id": plan["scope"]["window_id"],
             "recent_publication_limit": 0, "root_limit": 256}, check=False,
        )
        if not call_succeeded(non_git_runtime):
            raise BenchmarkError("non-Git runtime root identity snapshot failed")
        non_git_root_identity = runtime_root_identity(non_git_runtime, str(non_git))
        non_git_search = runner.call(
            "non-git-search", "file_search",
            {"pattern": non_git_marker, "regex": False, "filter": {"paths": [str(non_git)]}, "context_id": parent_context},
            check=False,
        )
        non_git_read = runner.call(
            "non-git-read", "read_file", {"path": str(non_git / "NonGit.swift"), "context_id": parent_context}, check=False,
        )
        work_before = runner.call(
            "non-git-work-before", DEBUG_TOOL,
            {"op": "mcp_read_search_runtime_snapshot", "window_id": plan["scope"]["window_id"],
             "recent_publication_limit": 0, "root_limit": 256}, check=False,
        )
        non_git_structure = runner.call(
            "non-git-structure", "get_code_structure",
            {"scope": "paths", "paths": [str(non_git / "NonGit.swift")],
             "context_id": parent_context},
            check=False,
        )
        main_structure_after_non_git = runner.call(
            "main-structure-after-non-git", "get_code_structure",
            {"scope": "paths", "paths": [plan["dataset"]["read_path"]],
             "context_id": parent_context}, check=False,
        )
        work_after = runner.call(
            "non-git-work-after", DEBUG_TOOL,
            {"op": "mcp_read_search_runtime_snapshot", "window_id": plan["scope"]["window_id"],
             "recent_publication_limit": 0, "root_limit": 256}, check=False,
        )
        non_git_work = [
            record for record in new_records(git_work_records(work_before), git_work_records(work_after))
            if record.get("operation") == "get_code_structure"
        ]
        zero_git = len(non_git_work) == 1 and non_git_work[0].get("command_count") == 0
        non_git_search_evidence = structured_success_evidence(
            non_git_search, "file_search",
            expected_root_id=non_git_root_identity["id"],
            expected_root_path=non_git_root_identity["path"],
            expected_root_type=non_git_root_identity["type"],
            expected_file_path=str(non_git / "NonGit.swift"), expected_file_type="file",
            expected_content=non_git_marker,
        )
        non_git_read_evidence = structured_success_evidence(
            non_git_read, "read_file",
            expected_root_id=non_git_root_identity["id"],
            expected_root_path=non_git_root_identity["path"],
            expected_root_type=non_git_root_identity["type"],
            expected_file_path=str(non_git / "NonGit.swift"), expected_file_type="file",
            expected_content=non_git_marker,
        )
        non_git_structure_evidence = structured_removed_evidence(
            non_git_structure, "get_code_structure",
            expected_root_id=non_git_root_identity["id"],
            expected_root_path=non_git_root_identity["path"],
            expected_root_type=non_git_root_identity["type"],
        )
        results["non-git-root"] = {
            "ok": (
                non_git_search_evidence["ok"]
                and non_git_read_evidence["ok"]
                and non_git_structure_evidence["ok"]
                and zero_git
            ),
            "search": non_git_search_evidence,
            "read": non_git_read_evidence,
            "structure": non_git_structure_evidence,
            "git_work_record_count": len(non_git_work),
            "git_command_count": non_git_work[0].get("command_count") if len(non_git_work) == 1 else None,
        }
        cross = runner.call(
            "cross-root-negative", "file_search",
            {"pattern": non_git_marker, "regex": False, "filter": {"paths": [plan["scope"]["root_path"]],
             "exclude": [str(non_git)]}, "context_id": parent_context}, check=False,
        )
        cross_search_evidence = structured_empty_success_evidence(
            cross, "file_search", expected_root_id=parent_root_identity["id"],
            expected_root_path=parent_root_identity["path"],
            expected_root_type=parent_root_identity["type"],
        )
        cross_structure_evidence = structured_success_evidence(
            main_structure_after_non_git, "get_code_structure",
            expected_root_id=parent_root_identity["id"],
            expected_root_path=parent_root_identity["path"],
            expected_root_type=parent_root_identity["type"],
            expected_file_path=plan["dataset"]["read_path"],
            expected_file_type=plan["dataset"]["code_file_type"],
            expected_content=plan["dataset"]["read_marker"],
            require_only_file=False,
        )
        results["cross-root-negative"] = {
            "ok": cross_search_evidence["ok"] and cross_structure_evidence["ok"],
            "search": cross_search_evidence,
            "structure": cross_structure_evidence,
        }

        ordinary = Path(tempfile.mkdtemp(prefix="rpce-startup-ordinary-"))
        owned_dirs.append(ordinary)
        ordinary_marker = f"RPCE_ORDINARY_{uuid.uuid4().hex}"
        ordinary_file = ordinary / "Ordinary.swift"
        ordinary_file.write_text(f"struct {ordinary_marker} {{}}\n", encoding="utf-8")
        linked_parent = Path(tempfile.mkdtemp(prefix="rpce-startup-linked-parent-"))
        linked_secondary = linked_parent / "worktree"
        run_local(["git", "worktree", "add", "--detach", str(linked_secondary), base_commit_oid], root)
        linked_marker = f"RPCE_LINKED_{uuid.uuid4().hex}"
        linked_file = linked_secondary / f"{linked_marker}.swift"
        linked_file.write_text(f"struct {linked_marker} {{}}\n", encoding="utf-8")

        def in_flight_calls(label: str, marker: str, file_path: str) -> dict[str, TimedCall]:
            calls = {
                "search": ("file_search", {"pattern": marker, "regex": False, "mode": "content", "filter": {"paths": [file_path]}, "max_results": 2000, "context_id": parent_context}),
                "read": ("read_file", {"path": file_path, "start_line": 1, "limit": 1000, "context_id": parent_context}),
                "selection": ("manage_selection", {"op": "get", "view": "files", "context_id": parent_context}),
                "structure": ("get_code_structure", {
                    "scope": "paths", "paths": [file_path],
                    "limits": {"max_files": 100, "max_edges": 200, "max_codemap_tokens": 6000},
                    "context_id": parent_context,
                }),
            }
            with ThreadPoolExecutor(max_workers=4) as pool:
                futures = {
                    key: pool.submit(runner.timed_call, f"{label}-{key}", tool, payload, check=False)
                    for key, (tool, payload) in calls.items()
                }
                return {key: future.result() for key, future in futures.items()}

        for kind, secondary, secondary_file, secondary_marker in (
            ("ordinary", ordinary, ordinary_file, ordinary_marker),
            ("worktree", linked_secondary, linked_file, linked_marker),
        ):
            parent_activity.append(poll_active_agent(
                runner, parent_session, parent_context, f"parent-{kind}-before-add"
            ))
            with ThreadPoolExecutor(max_workers=2) as pool:
                calls_future = pool.submit(
                    in_flight_calls, f"{kind}-add-inflight",
                    plan["dataset"]["search_marker"], plan["dataset"]["read_path"],
                )
                mutation_future = pool.submit(
                    runner.timed_call, f"add-{kind}-root", "manage_workspaces",
                    {"action": "add_folder", "workspace": plan["scope"]["workspace_id"],
                     "folder_path": str(secondary), "window_id": plan["scope"]["window_id"]},
                )
                during_add = poll_active_agent(
                    runner, parent_session, parent_context, f"parent-{kind}-during-add"
                )
                calls, mutation = calls_future.result(), mutation_future.result()
            during_add["overlapped_mutation"] = (
                during_add["started_ns"] < mutation.finished_ns
                and during_add["finished_ns"] > mutation.started_ns
            )
            parent_activity.append(during_add)
            added_roots.append(secondary)
            parent_activity.append(poll_active_agent(
                runner, parent_session, parent_context, f"parent-{kind}-after-add"
            ))
            overlapped_add = [key for key, call in calls.items() if overlap(call, mutation) and call_succeeded(call)]
            overlap_add = call_succeeded(mutation) and bool(overlapped_add)
            inventory_after_add = runner.call(
                f"inventory-{kind}-after-add", "manage_workspaces",
                {"action": "list", "include_hidden": True}, check=False,
            )
            added_inventory_paths = (
                workspace_root_paths(workspace_inventory_record(inventory_after_add, plan["scope"]["workspace_id"]))
                if call_succeeded(inventory_after_add) else []
            )
            secondary_runtime = runner.call(
                f"{kind}-root-identity", DEBUG_TOOL,
                {"op": "mcp_read_search_runtime_snapshot", "window_id": plan["scope"]["window_id"],
                 "recent_publication_limit": 0, "root_limit": 256}, check=False,
            )
            if not call_succeeded(secondary_runtime):
                raise BenchmarkError(f"{kind} runtime root identity snapshot failed")
            secondary_root_identity = runtime_root_identity(secondary_runtime, str(secondary))
            added_search = runner.call(
                f"{kind}-added-search", "file_search",
                {"pattern": secondary_marker, "regex": False, "mode": "content",
                 "filter": {"paths": [str(secondary_file)]}, "context_id": parent_context}, check=False,
            )
            added_read = runner.call(
                f"{kind}-added-read", "read_file",
                {"path": str(secondary_file), "start_line": 1, "limit": 40,
                 "context_id": parent_context}, check=False,
            )
            selection_add = runner.call(
                f"{kind}-selection-add", "manage_selection",
                {"op": "add", "paths": [str(secondary_file)], "mode": "full",
                 "context_id": parent_context}, check=False,
            )
            selection_with_root = runner.call(
                f"{kind}-selection-after-add", "manage_selection",
                {"op": "get", "view": "files", "context_id": parent_context}, check=False,
            )
            added_structure = runner.call(
                f"{kind}-structure-after-add", "get_code_structure",
                {"scope": "paths", "paths": [str(secondary_file)],
                 "context_id": parent_context}, check=False,
            )
            added_search_evidence = structured_success_evidence(
                added_search, "file_search", expected_root_id=secondary_root_identity["id"],
                expected_root_path=secondary_root_identity["path"],
                expected_root_type=secondary_root_identity["type"],
                expected_file_path=str(secondary_file), expected_file_type="file",
                expected_content=secondary_marker,
            )
            added_read_evidence = structured_success_evidence(
                added_read, "read_file", expected_root_id=secondary_root_identity["id"],
                expected_root_path=secondary_root_identity["path"],
                expected_root_type=secondary_root_identity["type"],
                expected_file_path=str(secondary_file), expected_file_type="file",
                expected_content=secondary_marker,
            )
            added_selection_evidence = structured_success_evidence(
                selection_with_root, "manage_selection",
                expected_root_id=secondary_root_identity["id"],
                expected_root_path=secondary_root_identity["path"],
                expected_root_type=secondary_root_identity["type"],
                expected_file_path=str(secondary_file), expected_file_type="file",
                require_only_file=False, allow_other_roots=True,
            )
            added_structure_evidence = structured_success_evidence(
                added_structure, "get_code_structure",
                expected_root_id=secondary_root_identity["id"],
                expected_root_path=secondary_root_identity["path"],
                expected_root_type=secondary_root_identity["type"],
                expected_file_path=str(secondary_file),
                expected_file_type=plan["dataset"]["code_file_type"],
                expected_content=secondary_marker,
                require_only_file=False,
            )
            added_usable = (
                str(secondary.resolve()) in added_inventory_paths
                and added_search_evidence["ok"] and added_read_evidence["ok"]
                and call_succeeded(selection_add) and added_selection_evidence["ok"]
                and added_structure_evidence["ok"]
            )
            results[f"secondary-{kind}-root-in-flight"] = {
                "ok": overlap_add, "add_overlapped_calls": overlapped_add,
            }
            results[f"secondary-{kind}-root-idle"] = {
                "ok": call_succeeded(mutation) and added_usable,
                "visible_and_usable_after_add": added_usable,
                "search": added_search_evidence, "read": added_read_evidence,
                "selection": added_selection_evidence, "structure": added_structure_evidence,
            }

            parent_activity.append(poll_active_agent(
                runner, parent_session, parent_context, f"parent-{kind}-before-remove"
            ))
            with ThreadPoolExecutor(max_workers=2) as pool:
                calls_future = pool.submit(
                    in_flight_calls, f"{kind}-remove-inflight", secondary_marker, str(secondary_file)
                )
                mutation_future = pool.submit(
                    runner.timed_call, f"remove-{kind}-root", "manage_workspaces",
                    {"action": "remove_folder", "workspace": plan["scope"]["workspace_id"],
                     "folder_path": str(secondary), "window_id": plan["scope"]["window_id"]},
                )
                during_remove = poll_active_agent(
                    runner, parent_session, parent_context, f"parent-{kind}-during-remove"
                )
                calls, mutation = calls_future.result(), mutation_future.result()
            during_remove["overlapped_mutation"] = (
                during_remove["started_ns"] < mutation.finished_ns
                and during_remove["finished_ns"] > mutation.started_ns
            )
            parent_activity.append(during_remove)
            if call_succeeded(mutation):
                added_roots.remove(secondary)
                detached_workspace_roots.add(secondary.resolve())
            if call_succeeded(mutation):
                smoke_cleanup.append({
                    "action": "remove_workspace_root", "path": str(secondary), "ok": True,
                })
            parent_activity.append(poll_active_agent(
                runner, parent_session, parent_context, f"parent-{kind}-after-remove"
            ))
            remove_overlapped = [key for key, call in calls.items() if overlap(call, mutation) and call_succeeded(call)]
            inventory_after_remove = runner.call(
                f"inventory-{kind}-after-remove", "manage_workspaces",
                {"action": "list", "include_hidden": True}, check=False,
            )
            removed_inventory_paths = (
                workspace_root_paths(workspace_inventory_record(inventory_after_remove, plan["scope"]["workspace_id"]))
                if call_succeeded(inventory_after_remove) else []
            )
            removed_search = runner.call(
                f"{kind}-removed-search", "file_search",
                {"pattern": secondary_marker, "regex": False, "mode": "content",
                 "filter": {"paths": [str(secondary_file)]}, "context_id": parent_context}, check=False,
            )
            removed_read = runner.call(
                f"{kind}-removed-read", "read_file",
                {"path": str(secondary_file), "start_line": 1, "limit": 40,
                 "context_id": parent_context}, check=False,
            )
            selection_after_remove = runner.call(
                f"{kind}-selection-after-remove", "manage_selection",
                {"op": "get", "view": "files", "context_id": parent_context}, check=False,
            )
            structure_after_remove = runner.call(
                f"{kind}-structure-after-remove", "get_code_structure",
                {"scope": "paths", "paths": [str(secondary_file)],
                 "context_id": parent_context}, check=False,
            )
            removed_search_evidence = structured_removed_evidence(
                removed_search, "file_search",
                expected_root_id=secondary_root_identity["id"],
                expected_root_path=secondary_root_identity["path"],
                expected_root_type=secondary_root_identity["type"],
                expected_file_path=str(secondary_file),
                require_absent_bound_root=True,
            )
            removed_read_evidence = structured_removed_evidence(
                removed_read, "read_file",
                expected_root_id=secondary_root_identity["id"],
                expected_root_path=secondary_root_identity["path"],
                expected_root_type=secondary_root_identity["type"],
                expected_file_path=str(secondary_file),
                require_absent_bound_root=True,
            )
            removed_structure_evidence = structured_removed_evidence(
                structure_after_remove, "get_code_structure",
                expected_root_id=secondary_root_identity["id"],
                expected_root_path=secondary_root_identity["path"],
                expected_root_type=secondary_root_identity["type"],
                expected_file_path=str(secondary_file),
                require_absent_bound_root=True,
            )
            selection_after_remove_evidence = structured_success_evidence(
                selection_after_remove, "manage_selection",
                expected_root_id=parent_root_identity["id"],
                expected_root_path=parent_root_identity["path"],
                expected_root_type=parent_root_identity["type"],
                expected_file_path=plan["dataset"]["read_path"],
                expected_file_type="file",
            )
            removed_revoked = (
                str(secondary.resolve()) not in removed_inventory_paths
                and removed_search_evidence["ok"]
                and removed_read_evidence["ok"]
                and removed_structure_evidence["ok"]
                and selection_after_remove_evidence["ok"]
            )
            results[f"secondary-{kind}-root-in-flight"]["remove_overlapped_calls"] = remove_overlapped
            results[f"secondary-{kind}-root-in-flight"]["ok"] = (
                results[f"secondary-{kind}-root-in-flight"]["ok"]
                and call_succeeded(mutation) and bool(remove_overlapped) and removed_revoked
            )
            results[f"secondary-{kind}-root-in-flight"]["removed_state_revoked"] = removed_revoked
            results[f"secondary-{kind}-root-in-flight"]["removed_search"] = removed_search_evidence
            results[f"secondary-{kind}-root-in-flight"]["removed_read"] = removed_read_evidence
            results[f"secondary-{kind}-root-in-flight"]["removed_structure"] = removed_structure_evidence
            results[f"secondary-{kind}-root-in-flight"]["selection_after_remove"] = selection_after_remove_evidence
            results[f"secondary-{kind}-root-idle"]["ok"] = (
                results[f"secondary-{kind}-root-idle"]["ok"] and removed_revoked
            )
            results[f"secondary-{kind}-root-idle"]["removed_state_revoked"] = removed_revoked

        if parent_worktree:
            relative_dir = ".rpce-benchmark"
            old_relative = f"{relative_dir}/{artifact.name}.swift"
            new_relative = f"{relative_dir}/{artifact.name}-renamed.swift"
            marker_v1 = f"RPCE_WATCHER_{uuid.uuid4().hex}_V1"
            marker_v2 = marker_v1.replace("_V1", "_V2")
            created = runner.call(
                "watcher-create", "file_actions",
                {"action": "create", "path": str(parent_worktree / old_relative), "content": f"struct {marker_v1} {{}}\n", "context_id": parent_context},
                check=False,
            )
            watcher_root = {
                "expected_root_id": parent_root_identity["id"],
                "expected_root_path": parent_root_identity["path"],
                "expected_root_type": parent_root_identity["type"],
            }
            create_visible = bounded_poll_search(
                runner, parent_context, marker_v1, old_relative, present=True, **watcher_root
            )
            edited = runner.call(
                "watcher-edit", "apply_edits",
                {"path": old_relative, "search": marker_v1, "replace": marker_v2, "context_id": parent_context}, check=False,
            )
            edit_visible = bounded_poll_search(
                runner, parent_context, marker_v2, old_relative, present=True, **watcher_root
            )
            moved = runner.call(
                "watcher-rename", "file_actions",
                {"action": "move", "path": str(parent_worktree / old_relative),
                 "new_path": str(parent_worktree / new_relative), "context_id": parent_context}, check=False,
            )
            rename_visible = bounded_poll_search(
                runner, parent_context, marker_v2, new_relative, present=True, **watcher_root
            )
            old_absent = bounded_poll_search(
                runner, parent_context, marker_v2, old_relative, present=False, **watcher_root
            )
            deleted = runner.call(
                "watcher-delete", "file_actions",
                {"action": "delete", "path": str(parent_worktree / new_relative), "context_id": parent_context}, check=False,
            )
            delete_absent = bounded_poll_search(
                runner, parent_context, marker_v2, new_relative, present=False, **watcher_root
            )
            results["watcher-create-edit-rename-delete"] = {
                "ok": all((
                    call_succeeded(created), call_succeeded(edited), call_succeeded(moved), call_succeeded(deleted),
                    create_visible["ok"], edit_visible["ok"], rename_visible["ok"],
                    old_absent["ok"], delete_absent["ok"],
                )),
                "create_visible": create_visible, "edit_visible": edit_visible,
                "rename_visible": rename_visible, "old_absent": old_absent, "delete_absent": delete_absent,
                "tool_calls_succeeded": all(call_succeeded(item) for item in (created, edited, moved, deleted)),
            }

        parent_activity.append(poll_active_agent(
            runner, parent_session, parent_context, "parent-poll-after"
        ))
        surviving_search = runner.call(
            "surviving-root-search", "file_search",
            {"pattern": plan["dataset"]["search_marker"], "regex": False,
             "filter": {"paths": [plan["dataset"]["read_path"]]}, "context_id": parent_context}, check=False,
        )
        surviving_read = runner.call(
            "surviving-root-read", "read_file",
            {"path": plan["dataset"]["read_path"], "start_line": 1, "limit": 80,
            "context_id": parent_context}, check=False,
        )
        surviving_search_evidence = structured_success_evidence(
            surviving_search, "file_search", expected_root_id=parent_root_identity["id"],
            expected_root_path=parent_root_identity["path"],
            expected_root_type=parent_root_identity["type"],
            expected_file_path=plan["dataset"]["read_path"], expected_file_type="file",
            expected_content=plan["dataset"]["search_marker"],
        )
        surviving_read_evidence = structured_success_evidence(
            surviving_read, "read_file", expected_root_id=parent_root_identity["id"],
            expected_root_path=parent_root_identity["path"],
            expected_root_type=parent_root_identity["type"],
            expected_file_path=plan["dataset"]["read_path"], expected_file_type="file",
            expected_content=plan["dataset"]["read_marker"],
        )
        parent_completion = wait_agent_success(
            runner, parent_session, expected_output="RPCE_ACTIVE_PARENT_OK",
            expected_marker=plan["dataset"]["search_marker"],
            expected_file_path=plan["dataset"]["read_path"],
            context_id=parent_context, expected_pairs=10,
        )
        relevant_agent_status[parent_session] = str(parent_completion["status"])
        results["active-agent-tab-binding"] = {
            "ok": (
                bool(parent_activity)
                and parent_started_in_worktree
                and all(item["ok"] for item in parent_activity)
                and all(
                    item.get("overlapped_mutation") is True
                    for item in parent_activity
                    if "during-" in str(item.get("label", ""))
                )
                and surviving_search_evidence["ok"]
                and surviving_read_evidence["ok"]
                and parent_completion["ok"]
            ),
            "parent_started_in_worktree": parent_started_in_worktree,
            "parent_terminal_success": parent_completion,
            "activity_checks": parent_activity,
            "context_id_unchanged": all(
                item.get("context_id") == parent_context for item in parent_activity
            ),
            "surviving_root_usable": (
                surviving_search_evidence["ok"] and surviving_read_evidence["ok"]
            ),
            "surviving_search": surviving_search_evidence,
            "surviving_read": surviving_read_evidence,
        }
    finally:
        for path in reversed(added_roots):
            removal_response = runner.call(
                f"cleanup-remove-{safe_name(path.name)}", "manage_workspaces",
                {"action": "remove_folder", "workspace": plan["scope"]["workspace_id"],
                 "folder_path": str(path), "window_id": plan["scope"]["window_id"]}, check=False,
            )
            smoke_cleanup.append({"action": "remove_workspace_root", "path": str(path), "ok": call_succeeded(removal_response)})
            if call_succeeded(removal_response):
                detached_workspace_roots.add(path.resolve())
        if child_session:
            child_status = relevant_agent_status.get(child_session)
            if child_status not in TERMINAL_STATES:
                child_status = terminalize(runner, child_session)
                relevant_agent_status[child_session] = child_status
            smoke_cleanup.append({
                "action": "terminalize_child",
                "session_id_sha256": sha256_bytes(child_session.encode()),
                "status": child_status, "terminal": child_status in TERMINAL_STATES,
            })
        if parent_session:
            parent_status = terminalize(runner, parent_session)
            relevant_agent_status[parent_session] = parent_status
            smoke_cleanup.append({
                "action": "terminalize_parent",
                "session_id_sha256": sha256_bytes(parent_session.encode()),
                "status": parent_status, "terminal": parent_status in TERMINAL_STATES,
            })
        all_relevant_terminal = bool(relevant_agent_status) and all(
            status in TERMINAL_STATES for status in relevant_agent_status.values()
        )
        if parent_worktree:
            smoke_cleanup.append(clean_owned_worktree(
                root,
                str(parent_worktree),
                all_relevant_terminal,
                expected_branch=parent_branch,
                expected_path=str(parent_worktree),
                expected_head=base_commit_oid,
                ownership_proven=True,
            ))
        if linked_secondary and linked_secondary.resolve() in detached_workspace_roots:
            if linked_file and linked_file.exists():
                linked_file.unlink()
            smoke_cleanup.append(clean_owned_worktree(
                root, str(linked_secondary), all_relevant_terminal,
                expected_path=str(linked_secondary), expected_head=base_commit_oid,
                ownership_proven=True,
            ))
        if linked_parent:
            try:
                linked_parent.rmdir()
            except OSError:
                pass
        for path in reversed(owned_dirs):
            if path.resolve() in detached_workspace_roots:
                shutil.rmtree(path, ignore_errors=True)
        final_target_ok = False
        try:
            verify_disposable_target(runner, plan, require_only_planned_root=True)
            final_target_ok = True
        except BenchmarkError:
            pass
        smoke_cleanup.append({
            "action": "restore_workspace_roots", "ok": final_target_ok,
        })
        smoke_cleanup.extend([
            {"action": "route_control_unchanged", "ok": True},
            {"action": "benchmark_setting_unchanged", "ok": True},
            {"action": "diagnostics_reset_not_required", "ok": True},
        ])
    save_cleanup_proof(artifact / "cleanup.json", smoke_cleanup)
    for scenario in CORRECTNESS_SCENARIOS:
        results.setdefault(scenario, {"ok": False, "reason": "not_exercised"})
    smoke_cleanup_ok = all(
        item.get("terminal") is True
        or item.get("ok") is True
        or item.get("removed") is True
        or item.get("reason") == "already_absent"
        for item in smoke_cleanup
    )
    summary = {
        "schema_version": SCHEMA_VERSION,
        "status": "completed" if all(item.get("ok") for item in results.values()) and smoke_cleanup_ok else "failed",
        "artifact_id": artifact.name,
        "plan_sha256": plan["plan_sha256"], "artifact_directory": str(artifact),
        "cleanup_complete": smoke_cleanup_ok, "results": results,
    }
    save_json(artifact / "summary.json", summary, exclusive=True)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["status"] == "completed" else 1


def codemap_gate_command(args: argparse.Namespace) -> int:
    if not args.confirm_live_debug_app or not args.confirm_dedicated_workspace:
        raise BenchmarkError("codemap-gate requires live-app and dedicated-workspace confirmations")
    if not args.confirm_synthetic_allowlisted_source:
        raise BenchmarkError("codemap-gate requires explicit synthetic/allowlisted-source confirmation")
    if args.cold_samples < CODEMAP_GATE_MINIMUM_COLD_SAMPLES:
        raise BenchmarkError(
            f"codemap-gate requires at least {CODEMAP_GATE_MINIMUM_COLD_SAMPLES} cold samples"
        )
    if args.warm_samples < CODEMAP_GATE_MINIMUM_WARM_SAMPLES:
        raise BenchmarkError(
            f"codemap-gate requires at least {CODEMAP_GATE_MINIMUM_WARM_SAMPLES} warm samples"
        )

    plan = load_plan(Path(args.plan).expanduser().resolve(strict=True))
    cli = resolve_cli(args.cli)
    root = Path(plan["scope"]["root_path"]).resolve(strict=True)
    validate_planned_base_commit(plan, root)
    fixture, sanitized_fixture = load_codemap_gate_fixture(
        Path(args.fixture).expanduser().resolve(strict=True),
        plan=plan,
        cold_samples=args.cold_samples,
    )
    baseline, baseline_acceptance = validate_codemap_baseline(
        Path(args.baseline).expanduser().resolve(strict=True),
        Path(args.baseline_ledger).expanduser().resolve(strict=True),
        expected_ledger_sha256=args.baseline_ledger_sha256,
        fixture_sha256=sanitized_fixture["fixture_sha256"],
        cold_samples=args.cold_samples,
        warm_samples=args.warm_samples,
    )

    artifact = make_artifact(Path(args.output_root), "codemap-gate")
    runner = CLIRunner(
        cli, plan["scope"]["window_id"], plan["scope"]["context_id"], root, artifact
    )
    structure_schema = runner.describe("get_code_structure")
    secure_write(
        artifact / "get-code-structure-schema.txt", structure_schema.encode(), exclusive=True
    )
    if re.search(r"\bwait_ms\b", structure_schema):
        raise BenchmarkError(
            "get_code_structure still advertises model-facing wait_ms; "
            "demand wait must be an internal fixed 10-second contract"
        )
    save_json(artifact / "plan.json", plan, exclusive=True)
    save_json(artifact / "codemap-fixture.json", fixture, exclusive=True)
    state: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "kind": "codemap-gate",
        "plan_sha256": plan["plan_sha256"],
        "sessions": [],
        "worktrees": [],
        "added_roots": [],
        "codemap_holds": [],
        "memory_stopped": False,
        "memory_session_id": None,
        "route_restored": True,
        "scope_reset": True,
        "benchmark_gate_unchanged": False,
    }
    save_json(artifact / "state.json", state)
    samples: list[dict[str, Any]] = []
    results: dict[str, dict[str, Any]] = {}
    cleanup: list[dict[str, Any]] = []
    owned_dirs: list[Path] = []
    privacy_allowlist: list[Path] = [root]
    privacy_prompt_allowlist: list[str] = []
    active_hold: str | None = None
    active_hold_target_root_id: str | None = None
    watcher_paths: list[str] = []
    memory_session_id: str | None = None
    memory_acquisition = MemorySamplerAcquisition(label=artifact.name)
    operational_error: str | None = None
    resources: Any = {}

    try:
        verify_scope(runner, plan)
        require_benchmark_gate(runner)
        verify_disposable_target(runner, plan, require_only_planned_root=True)
        runtime = runner.call(
            "codemap-root-identity", DEBUG_TOOL,
            {"op": "mcp_read_search_runtime_snapshot", "window_id": plan["scope"]["window_id"],
             "recent_publication_limit": 0, "root_limit": 256}, check=False,
        )
        if not call_succeeded(runtime):
            raise BenchmarkError("codemap root identity snapshot failed")
        root_identity = runtime_root_identity(runtime, str(root))
        start_snapshot = codemap_debug_action(runner, plan, "codemap_projection_snapshot")["snapshot"]
        memory_session_id, _ = start_owned_memory_sampler(
            runner, artifact.name, memory_acquisition
        )
        state["memory_session_id"] = memory_session_id
        save_json(artifact / "state.json", state)

        cold_provenance: list[dict[str, Any]] = []
        for cohort, key in (("individual", "individuals"), ("directory", "directories")):
            for index, item in enumerate(fixture[key][:args.cold_samples], start=1):
                expected_path = item.get("expected_file", item["path"])
                tree_path = (
                    str(Path(expected_path).parent)
                )
                preflight_tree = runner.call(
                    f"codemap-cold-provenance-{cohort}-{index}", "get_file_tree",
                    {"type": "files", "mode": "full", "path": tree_path,
                     "max_depth": 1}, check=False,
                )
                tree_payload = tool_payload(preflight_tree, "get_file_tree")
                marker_was_absent = (
                    f"{Path(expected_path).name} +" not in str(tree_payload.get("tree") or "")
                )
                cold_provenance.append({
                    "scenario": cohort,
                    "path_sha256": sha256_bytes(item["path"].encode()),
                    "marker_was_absent": marker_was_absent,
                })
        results["cold-fixture-provenance"] = {
            "ok": len(cold_provenance) == args.cold_samples * 2
            and all(item["marker_was_absent"] for item in cold_provenance),
            "probes": cold_provenance,
        }

        def run_structure_sample(
            cohort: str,
            temperature: str,
            ordinal: int,
            item: dict[str, str],
        ) -> dict[str, Any]:
            requested_path = item["path"]
            expected_path = item.get("expected_file", requested_path)
            limits = {"max_files": 100, "max_edges": 400, "max_codemap_tokens": 12_000}
            call = runner.timed_call(
                f"codemap-{cohort}-{temperature}-{ordinal}",
                "get_code_structure",
                {"scope": "paths", "paths": [requested_path], "limits": limits,
                 "context_id": plan["scope"]["context_id"]},
                timeout=CODEMAP_GATE_WAIT_MILLISECONDS / 1000
                + CODEMAP_GATE_HARNESS_ALLOWANCE_MILLISECONDS / 1000 + 5,
                check=False,
            )
            elapsed_ms = (call.finished_ns - call.started_ns) / 1_000_000
            invalid: list[str] = []
            evidence: dict[str, Any] | None = None
            tree_evidence: dict[str, Any] | None = None
            tree_elapsed_ms: float | None = None
            try:
                if elapsed_ms > CODEMAP_GATE_WAIT_MILLISECONDS + CODEMAP_GATE_HARNESS_ALLOWANCE_MILLISECONDS:
                    raise BenchmarkError("structure request exceeded the 10s + 500ms contract")
                evidence = codemap_structure_evidence(
                    call.response,
                    expected_root_id=root_identity["id"],
                    expected_root_path=root_identity["path"],
                    expected_root_type=root_identity["type"],
                    expected_file_path=expected_path,
                    expected_marker=item["marker"],
                    expected_file_type=plan["dataset"]["code_file_type"],
                )
                tree_call = runner.timed_call(
                    f"codemap-tree-{cohort}-{temperature}-{ordinal}",
                    "get_file_tree",
                    {"type": "files", "mode": "full",
                     "path": str(Path(expected_path).parent), "max_depth": 1},
                    timeout=60, check=False,
                )
                tree_elapsed_ms = (tree_call.finished_ns - tree_call.started_ns) / 1_000_000
                tree_evidence = codemap_tree_marker_evidence(
                    tree_call.response,
                    expected_context_id=plan["scope"]["context_id"],
                    expected_root_path=root_identity["path"],
                    requested_parent=str(Path(expected_path).parent),
                    expected_file_path=expected_path,
                )
            except BenchmarkError as error:
                invalid.append(str(error))
            record = {
                "schema_version": SCHEMA_VERSION,
                "scenario": f"{temperature}-{cohort}",
                "ordinal": ordinal,
                "path_sha256": sha256_bytes(requested_path.encode()),
                "expected_file_sha256": sha256_bytes(expected_path.encode()),
                "wait_ms_omitted": True,
                "internal_wait_contract_ms": CODEMAP_GATE_WAIT_MILLISECONDS,
                "duration_ms": elapsed_ms,
                "tree_marker_duration_ms": tree_elapsed_ms,
                "valid": not invalid,
                "invalid_reasons": invalid,
                "structure": evidence,
                "tree_marker": tree_evidence,
            }
            append_ndjson(artifact / "codemap-samples.ndjson", record)
            return record

        search_durations: list[float] = []
        read_durations: list[float] = []
        readiness_durations: list[float] = []

        def record_responsiveness_sample(label: str, item: dict[str, str]) -> None:
            search_call = runner.timed_call(
                f"codemap-saturated-search-{label}", "file_search",
                {"pattern": item["marker"], "regex": False, "mode": "content",
                 "filter": {"paths": [item["path"]]}, "max_results": 20,
                 "context_id": plan["scope"]["context_id"]}, check=False,
            )
            read_call = runner.timed_call(
                f"codemap-saturated-read-{label}", "read_file",
                {"path": item["path"], "start_line": 1, "limit": 80,
                 "context_id": plan["scope"]["context_id"]}, check=False,
            )
            readiness_call = runner.timed_call(
                f"codemap-saturated-root-{label}", DEBUG_TOOL,
                {"op": "mcp_read_search_runtime_snapshot", "window_id": plan["scope"]["window_id"],
                 "recent_publication_limit": 0, "root_limit": 256}, check=False,
            )
            search_ok = structured_success_evidence(
                search_call.response, "file_search",
                expected_root_id=root_identity["id"], expected_root_path=root_identity["path"],
                expected_root_type=root_identity["type"], expected_file_path=item["path"],
                expected_file_type="file", expected_content=item["marker"],
            )["ok"]
            read_ok = structured_success_evidence(
                read_call.response, "read_file",
                expected_root_id=root_identity["id"], expected_root_path=root_identity["path"],
                expected_root_type=root_identity["type"], expected_file_path=item["path"],
                expected_file_type="file", expected_content=item["marker"],
            )["ok"]
            if not search_ok or not read_ok or not call_succeeded(readiness_call.response):
                raise BenchmarkError("saturated root/search/read responsiveness sample failed")
            if runtime_root_identity(readiness_call.response, str(root)) != root_identity:
                raise BenchmarkError("saturated root readiness changed canonical identity")
            search_durations.append((search_call.finished_ns - search_call.started_ns) / 1_000_000)
            read_durations.append((read_call.finished_ns - read_call.started_ns) / 1_000_000)
            readiness_durations.append(
                (readiness_call.finished_ns - readiness_call.started_ns) / 1_000_000
            )

        for cohort, key in (("individual", "individuals"), ("directory", "directories")):
            cold_items = fixture[key][:args.cold_samples]
            with ThreadPoolExecutor(max_workers=min(4, args.cold_samples)) as pool:
                futures = {
                    pool.submit(run_structure_sample, cohort, "cold", index, item): index
                    for index, item in enumerate(cold_items, start=1)
                }
                for index, item in enumerate(
                    fixture["individuals"][:args.cold_samples // 2], start=1
                ):
                    record_responsiveness_sample(f"{cohort}-{index}", item)
                cold_records = [future.result() for future in as_completed(futures)]
            samples.extend(sorted(cold_records, key=lambda item: item["ordinal"]))
            warm_items = [cold_items[index % len(cold_items)] for index in range(args.warm_samples)]
            with ThreadPoolExecutor(max_workers=min(4, args.warm_samples)) as pool:
                futures = {
                    pool.submit(run_structure_sample, cohort, "warm", index, item): index
                    for index, item in enumerate(warm_items, start=1)
                }
                warm_records = [future.result() for future in as_completed(futures)]
            samples.extend(sorted(warm_records, key=lambda item: item["ordinal"]))

        # Directory overflow must fail before any codemap admission or build.
        before_overflow = codemap_debug_action(
            runner, plan, "codemap_projection_snapshot"
        )["snapshot"]
        overflow = runner.call(
            "codemap-directory-overflow", "get_code_structure",
            {"scope": "paths", "paths": [fixture["overflow_directory"]],
             "limits": {"max_files": 1, "max_edges": 1, "max_codemap_tokens": 256},
             "context_id": plan["scope"]["context_id"]}, check=False,
        )
        overflow_evidence = codemap_budget_evidence(overflow)
        after_overflow = codemap_debug_action(
            runner, plan, "codemap_projection_snapshot"
        )["snapshot"]
        overflow_deltas = {
            key: codemap_counter_delta(before_overflow, after_overflow, key)
            for key in (
                "builds", "materializations", "manifest_writes",
                "projection_demands_acquired", "projection_batches_queued",
                "projection_batches_started", "projection_catalog_pages",
                "projection_catalog_candidates", "projection_builds_started",
                "projection_segments_published",
            )
        }
        results["directory-overflow"] = {
            "ok": all(value == 0 for value in overflow_deltas.values()),
            "evidence": overflow_evidence,
            "downstream_counter_deltas": overflow_deltas,
        }

        # Non-Git roots must serve search/read while producing no codemap engine work.
        non_git = Path(tempfile.mkdtemp(prefix="rpce-codemap-gate-nongit-"))
        owned_dirs.append(non_git)
        privacy_allowlist.append(non_git)
        non_git_ownership = create_codemap_temp_ownership_marker(
            non_git, artifact_id=artifact.name, plan_sha256=plan["plan_sha256"]
        )
        non_git_marker = f"RPCE_CODEMAP_NON_GIT_{uuid.uuid4().hex}"
        non_git_file = non_git / "NonGit.swift"
        non_git_file.write_text(f"struct {non_git_marker} {{}}\n", encoding="utf-8")
        added_non_git = runner.call(
            "codemap-add-non-git", "manage_workspaces",
            {"action": "add_folder", "workspace": plan["scope"]["workspace_id"],
             "folder_path": str(non_git), "window_id": plan["scope"]["window_id"]}, check=False,
        )
        if not call_succeeded(added_non_git):
            raise BenchmarkError("failed to add owned non-Git root")
        state["added_roots"].append({
            "path": str(non_git), "kind": "non-git", "owned": True,
            **non_git_ownership,
        })
        save_json(artifact / "state.json", state)
        non_git_runtime = runner.call(
            "codemap-non-git-root", DEBUG_TOOL,
            {"op": "mcp_read_search_runtime_snapshot", "window_id": plan["scope"]["window_id"],
             "recent_publication_limit": 0, "root_limit": 256}, check=False,
        )
        non_git_identity = runtime_root_identity(non_git_runtime, str(non_git))
        before_non_git = codemap_debug_action(
            runner, plan, "codemap_root_snapshot", target_root_id=non_git_identity["id"]
        )
        non_git_search = runner.call(
            "codemap-non-git-search", "file_search",
            {"pattern": non_git_marker, "regex": False,
             "filter": {"paths": [str(non_git_file)]},
             "context_id": plan["scope"]["context_id"]}, check=False,
        )
        non_git_read = runner.call(
            "codemap-non-git-read", "read_file",
            {"path": str(non_git_file), "context_id": plan["scope"]["context_id"]}, check=False,
        )
        non_git_structure = runner.call(
            "codemap-non-git-structure", "get_code_structure",
            {"scope": "paths", "paths": [str(non_git_file)],
             "context_id": plan["scope"]["context_id"]}, check=False,
        )
        after_non_git = codemap_debug_action(
            runner, plan, "codemap_root_snapshot", target_root_id=non_git_identity["id"]
        )
        non_git_search_ok = structured_success_evidence(
            non_git_search, "file_search", expected_root_id=non_git_identity["id"],
            expected_root_path=non_git_identity["path"], expected_root_type=non_git_identity["type"],
            expected_file_path=str(non_git_file), expected_file_type="file",
            expected_content=non_git_marker,
        )["ok"]
        non_git_read_ok = structured_success_evidence(
            non_git_read, "read_file", expected_root_id=non_git_identity["id"],
            expected_root_path=non_git_identity["path"], expected_root_type=non_git_identity["type"],
            expected_file_path=str(non_git_file), expected_file_type="file",
            expected_content=non_git_marker,
        )["ok"]
        non_git_terminal = structured_removed_evidence(
            non_git_structure, "get_code_structure", expected_root_id=non_git_identity["id"],
            expected_root_path=non_git_identity["path"], expected_root_type=non_git_identity["type"],
        )
        non_git_deltas = {
            key: codemap_counter_delta(before_non_git["snapshot"], after_non_git["snapshot"], key)
            for key in ("builds", "projection_batches_started", "projection_catalog_candidates")
        }
        non_git_engine_absent = (
            find_value(before_non_git["response"], "engine_present") is False
            and find_value(after_non_git["response"], "engine_present") is False
        )
        results["non-git-zero-codemap-work"] = {
            "ok": non_git_search_ok and non_git_read_ok and non_git_terminal["ok"]
            and non_git_engine_absent and all(value == 0 for value in non_git_deltas.values()),
            "typed_terminal": non_git_terminal,
            "engine_present": not non_git_engine_absent,
            "counter_deltas": non_git_deltas,
        }

        # Watcher lifecycle requires current structure and marker publication at each live state.
        watcher_dir = fixture["watcher_directory"]
        watcher_old = f"{watcher_dir}/{artifact.name}.swift"
        watcher_new = f"{watcher_dir}/{artifact.name}-renamed.swift"
        watcher_paths.extend([watcher_old, watcher_new])
        watcher_v1 = f"RPCE_CODEMAP_WATCHER_{uuid.uuid4().hex}_V1"
        watcher_v2 = watcher_v1.replace("_V1", "_V2")
        created = runner.call(
            "codemap-watcher-create", "file_actions",
            {"action": "create", "path": str(root / watcher_old),
             "content": f"struct {watcher_v1} {{}}\n",
             "context_id": plan["scope"]["context_id"]}, check=False,
        )
        created_structure = runner.call(
            "codemap-watcher-create-structure", "get_code_structure",
            {"scope": "paths", "paths": [watcher_old],
             "context_id": plan["scope"]["context_id"]}, check=False,
        )
        create_evidence = codemap_structure_evidence(
            created_structure, expected_root_id=root_identity["id"],
            expected_root_path=root_identity["path"], expected_root_type=root_identity["type"],
            expected_file_path=watcher_old, expected_marker=watcher_v1,
            expected_file_type=plan["dataset"]["code_file_type"],
        )
        create_tree = runner.call(
            "codemap-watcher-create-tree", "get_file_tree",
            {"type": "files", "mode": "full", "path": watcher_dir, "max_depth": 1}, check=False,
        )
        create_marker = codemap_tree_marker_evidence(
            create_tree, expected_context_id=plan["scope"]["context_id"],
            expected_root_path=root_identity["path"], requested_parent=watcher_dir,
            expected_file_path=watcher_old,
        )
        edited = runner.call(
            "codemap-watcher-edit", "apply_edits",
            {"path": watcher_old, "search": watcher_v1, "replace": watcher_v2,
             "context_id": plan["scope"]["context_id"]}, check=False,
        )
        edited_structure = runner.call(
            "codemap-watcher-edit-structure", "get_code_structure",
            {"scope": "paths", "paths": [watcher_old],
             "context_id": plan["scope"]["context_id"]}, check=False,
        )
        edit_evidence = codemap_structure_evidence(
            edited_structure, expected_root_id=root_identity["id"],
            expected_root_path=root_identity["path"], expected_root_type=root_identity["type"],
            expected_file_path=watcher_old, expected_marker=watcher_v2,
            expected_file_type=plan["dataset"]["code_file_type"],
        )
        edit_tree = runner.call(
            "codemap-watcher-edit-tree", "get_file_tree",
            {"type": "files", "mode": "full", "path": watcher_dir, "max_depth": 1}, check=False,
        )
        edit_marker = codemap_tree_marker_evidence(
            edit_tree, expected_context_id=plan["scope"]["context_id"],
            expected_root_path=root_identity["path"], requested_parent=watcher_dir,
            expected_file_path=watcher_old,
        )
        moved = runner.call(
            "codemap-watcher-rename", "file_actions",
            {"action": "move", "path": str(root / watcher_old),
             "new_path": str(root / watcher_new),
             "context_id": plan["scope"]["context_id"]}, check=False,
        )
        moved_structure = runner.call(
            "codemap-watcher-rename-structure", "get_code_structure",
            {"scope": "paths", "paths": [watcher_new],
             "context_id": plan["scope"]["context_id"]}, check=False,
        )
        rename_evidence = codemap_structure_evidence(
            moved_structure, expected_root_id=root_identity["id"],
            expected_root_path=root_identity["path"], expected_root_type=root_identity["type"],
            expected_file_path=watcher_new, expected_marker=watcher_v2,
            expected_file_type=plan["dataset"]["code_file_type"],
        )
        watcher_tree = runner.call(
            "codemap-watcher-tree", "get_file_tree",
            {"type": "files", "mode": "full", "path": watcher_dir, "max_depth": 1}, check=False,
        )
        watcher_marker = codemap_tree_marker_evidence(
            watcher_tree, expected_context_id=plan["scope"]["context_id"],
            expected_root_path=root_identity["path"], requested_parent=watcher_dir,
            expected_file_path=watcher_new,
        )
        deleted = runner.call(
            "codemap-watcher-delete", "file_actions",
            {"action": "delete", "path": str(root / watcher_new),
             "context_id": plan["scope"]["context_id"]}, check=False,
        )
        deleted_structure = runner.call(
            "codemap-watcher-delete-structure", "get_code_structure",
            {"scope": "paths", "paths": [watcher_new],
             "context_id": plan["scope"]["context_id"]}, check=False,
        )
        deleted_payload = tool_payload(deleted_structure, "get_code_structure")
        deleted_issues = deleted_payload.get("issues")
        deleted_issue_codes = sorted({
            str(issue.get("code")) for issue in deleted_issues or []
            if isinstance(issue, dict) and isinstance(issue.get("code"), str)
        })
        deleted_tree = runner.call(
            "codemap-watcher-delete-tree", "get_file_tree",
            {"type": "files", "mode": "full", "path": watcher_dir, "max_depth": 1}, check=False,
        )
        deleted_tree_payload = tool_payload(deleted_tree, "get_file_tree")
        delete_absent = (
            deleted_payload.get("status") == "unavailable"
            and deleted_payload.get("files") == []
            and "path_not_found" in deleted_issue_codes
            and f"{Path(watcher_new).name} +" not in str(deleted_tree_payload.get("tree") or "")
        )
        results["watcher-create-edit-rename-delete"] = {
            "ok": all(call_succeeded(item) for item in (created, edited, moved, deleted))
            and delete_absent,
            "create": create_evidence, "edit": edit_evidence,
            "rename": rename_evidence,
            "markers": {"create": create_marker, "edit": edit_marker, "rename": watcher_marker},
            "delete": {"status": deleted_payload.get("status"),
                       "issue_codes": deleted_issue_codes, "marker_absent": delete_absent},
        }

        # The DEBUG hold pauses only future projection-batch admission; timeout must be real.
        hold_result = codemap_debug_action(
            runner, plan, "codemap_projection_hold_acquire", expires_ms=30_000
        )
        hold_id = find_value(hold_result["response"], "hold_id")
        if not isinstance(hold_id, str):
            raise BenchmarkError("DEBUG codemap hold acquire omitted hold_id")
        active_hold = hold_id
        active_hold_target_root_id = root_identity["id"]
        state["codemap_holds"].append({
            "hold_id": hold_id, "target_root_id": root_identity["id"], "released": False,
        })
        save_json(artifact / "state.json", state)
        timeout_path = f"{watcher_dir}/{artifact.name}-timeout.swift"
        watcher_paths.append(timeout_path)
        timeout_marker = f"RPCE_CODEMAP_TIMEOUT_{uuid.uuid4().hex}"
        timeout_create = runner.call(
            "codemap-timeout-create", "file_actions",
            {"action": "create", "path": str(root / timeout_path),
             "content": f"struct {timeout_marker} {{}}\n",
             "context_id": plan["scope"]["context_id"]}, check=False,
        )
        timeout_call = runner.timed_call(
            "codemap-held-timeout", "get_code_structure",
            {"scope": "paths", "paths": [timeout_path],
             "expand": {"direction": "referrers", "max_depth": 1},
             "context_id": plan["scope"]["context_id"]},
            timeout=CODEMAP_GATE_WAIT_MILLISECONDS / 1000
            + CODEMAP_GATE_HARNESS_ALLOWANCE_MILLISECONDS / 1000 + 5,
            check=False,
        )
        timeout_elapsed_ms = (timeout_call.finished_ns - timeout_call.started_ns) / 1_000_000
        timeout_evidence = codemap_retryable_terminal_evidence(
            timeout_call.response, expected_status="timeout", expected_issue_code="readiness_timeout"
        )
        if not (
            CODEMAP_GATE_WAIT_MILLISECONDS - CODEMAP_GATE_HARNESS_ALLOWANCE_MILLISECONDS
            <= timeout_elapsed_ms
            <= CODEMAP_GATE_WAIT_MILLISECONDS + CODEMAP_GATE_HARNESS_ALLOWANCE_MILLISECONDS
        ):
            raise BenchmarkError("held timeout did not honor the 10s ± 500ms monotonic contract")
        released = codemap_debug_action(
            runner, plan, "codemap_projection_hold_release", hold_id=hold_id
        )
        if find_value(released["response"], "released") is not True:
            raise BenchmarkError("DEBUG codemap hold was not owned/released")
        active_hold = None
        active_hold_target_root_id = None
        state["codemap_holds"][-1]["released"] = True
        save_json(artifact / "state.json", state)
        timeout_retry = runner.call(
            "codemap-timeout-retry", "get_code_structure",
            {"scope": "paths", "paths": [timeout_path],
             "expand": {"direction": "referrers", "max_depth": 1},
             "context_id": plan["scope"]["context_id"]}, check=False,
        )
        retry_evidence = codemap_structure_evidence(
            timeout_retry, expected_root_id=root_identity["id"],
            expected_root_path=root_identity["path"], expected_root_type=root_identity["type"],
            expected_file_path=timeout_path, expected_marker=timeout_marker,
            expected_file_type=plan["dataset"]["code_file_type"],
        )
        results["explicit-10s-timeout-contract"] = {
            "ok": call_succeeded(timeout_create),
            "elapsed_ms": timeout_elapsed_ms,
            "timeout": timeout_evidence,
            "retry": retry_evidence,
            "future_admission_hold_released": True,
        }

        # Real agent_run transcript: multiple file/directory calls, marker trees, inherited child.
        parent_calls: list[tuple[str, dict[str, Any]]] = []
        for item in fixture["individuals"][:2]:
            parent_calls.extend([
                ("get_code_structure", {"paths": [item["path"]], "omit_wait_ms": True,
                                        "expected_file": item["path"], "marker": item["marker"]}),
                ("get_file_tree", {"path": str(Path(item["path"]).parent),
                                   "expected_file": item["path"]}),
            ])
        for item in fixture["directories"][:2]:
            parent_calls.extend([
                ("get_code_structure", {"paths": [item["path"]], "omit_wait_ms": True,
                                        "expected_file": item["expected_file"],
                                        "marker": item["marker"]}),
                ("get_file_tree", {"path": str(Path(item["expected_file"]).parent),
                                   "expected_file": item["expected_file"]}),
            ])
        parent_branch = safe_name(f"rpce-bench-{artifact.name}-i1-o1")[:120]
        parent_prompt = codemap_agent_prompt(parent_calls, sentinel=CODEMAP_GATE_SENTINEL)
        privacy_prompt_allowlist.append(parent_prompt)
        parent = runner.call(
            "codemap-agent-parent", "agent_run",
            {"op": "start", "model_id": "explore", "detach": True,
             "message": parent_prompt,
             "session_name": "RPCE codemap gate parent", "worktree_create": True,
             "worktree_branch": parent_branch,
             "worktree_base_ref": plan["dataset"]["base_commit_oid"],
             "worktree_label": f"RPCE codemap {artifact.name}",
             "context_id": plan["scope"]["context_id"]}, timeout=180,
        )
        parent_session = response_session_id(parent)
        parent_context = response_context_id(parent)
        if parent_context is None:
            raise BenchmarkError("codemap parent omitted context_id")
        parent_worktree = discover_owned_worktree(parent, root, parent_branch)
        privacy_allowlist.append(parent_worktree)
        state["sessions"].append({
            "session_id": parent_session, "context_id": parent_context,
            "terminal": False, "scenario": "multiple-files-directories",
        })
        state["worktrees"].append({
            "path": str(parent_worktree), "owned": True, "branch": parent_branch,
        })
        save_json(artifact / "state.json", state)
        child_calls = [
            ("get_code_structure", {"paths": [fixture["individuals"][5]["path"]],
                                    "omit_wait_ms": True,
                                    "expected_file": fixture["individuals"][5]["path"],
                                    "marker": fixture["individuals"][5]["marker"]}),
            ("get_file_tree", {"path": str(Path(fixture["individuals"][5]["path"]).parent),
                               "expected_file": fixture["individuals"][5]["path"]}),
        ]
        child_prompt = codemap_agent_prompt(child_calls, sentinel=CODEMAP_GATE_SENTINEL)
        privacy_prompt_allowlist.append(child_prompt)
        child = runner.call(
            "codemap-agent-child", "agent_run",
            {"op": "start", "model_id": "explore", "detach": True,
             "inherit_worktree": True,
             "message": child_prompt,
             "session_name": "RPCE codemap inherited child", "context_id": parent_context},
            timeout=180, check=False, context_id=parent_context,
        )
        child_session = response_session_id(child)
        child_context = response_context_id(child)
        if child_context is None:
            raise BenchmarkError("codemap inherited child omitted context_id")
        state["sessions"].append({
            "session_id": child_session, "context_id": child_context,
            "terminal": False, "scenario": "inherited-worktree-child",
        })
        save_json(artifact / "state.json", state)
        child_result = wait_codemap_agent_success(
            runner, child_session, child_context,
            start_response=child,
            expected_output=CODEMAP_GATE_SENTINEL, expected_calls=child_calls,
        )
        if not child_result["ok"]:
            raise BenchmarkError("fail-fast inherited child inference probe failed")
        state["sessions"][-1]["terminal"] = child_result["status"] in TERMINAL_STATES
        state["sessions"][-1]["status"] = child_result["status"]
        parent_result = wait_codemap_agent_success(
            runner, parent_session, parent_context,
            start_response=parent,
            expected_output=CODEMAP_GATE_SENTINEL, expected_calls=parent_calls,
        )
        if not parent_result["ok"]:
            raise BenchmarkError("fail-fast multi-path parent inference probe failed")
        state["sessions"][-2]["terminal"] = parent_result["status"] in TERMINAL_STATES
        state["sessions"][-2]["status"] = parent_result["status"]
        child_direct = agent_codemap_direct_evidence(
            runner, plan, start_response=child, session_id=child_session,
            context_id=child_context, worktree_path=parent_worktree,
            expected_calls=child_calls,
        )
        parent_direct = agent_codemap_direct_evidence(
            runner, plan, start_response=parent, session_id=parent_session,
            context_id=parent_context, worktree_path=parent_worktree,
            expected_calls=parent_calls,
        )
        inheritance = child_inheritance_evidence(
            parent, child, parent_context_id=parent_context,
            parent_worktree_path=str(parent_worktree),
        )
        results["agent-multiple-files-directories"] = {
            "ok": parent_result["ok"] and parent_direct["ok"],
            "transcript": parent_result, "structured": parent_direct,
        }
        results["inherited-worktree-child"] = {
            "ok": child_result["ok"] and inheritance["ok"] and child_direct["ok"],
            "transcript": child_result,
            "inheritance": inheritance,
            "structured": child_direct,
        }
        save_json(artifact / "state.json", state)

        # Concurrent ordinary/linked-worktree agents plus active add/remove root churn.
        linked_parent = Path(tempfile.mkdtemp(prefix="rpce-codemap-gate-linked-"))
        owned_dirs.append(linked_parent)
        linked_root = linked_parent / "worktree"
        linked_branch = safe_name(f"rpce-bench-{artifact.name}-i3-o1")[:120]
        run_local(
            ["git", "worktree", "add", "-b", linked_branch, str(linked_root),
             plan["dataset"]["base_commit_oid"]], root
        )
        privacy_allowlist.append(linked_root)
        state["worktrees"].append({
            "path": str(linked_root), "owned": True, "branch": linked_branch,
        })
        primary_probe_calls = [
            ("get_code_structure", {"paths": [fixture["individuals"][6]["path"]],
                                    "omit_wait_ms": True,
                                    "expected_file": fixture["individuals"][6]["path"],
                                    "marker": fixture["individuals"][6]["marker"]}),
            ("get_file_tree", {"path": str(Path(fixture["individuals"][6]["path"]).parent),
                               "expected_file": fixture["individuals"][6]["path"]}),
        ]

        def primary_structure_pressure(label: str) -> TimedCall:
            return runner.timed_call(
                label, "get_code_structure",
                {"scope": "paths", "paths": [fixture["directories"][6]["path"]],
                 "limits": {"max_files": 100, "max_edges": 400,
                            "max_codemap_tokens": 12_000},
                 "context_id": plan["scope"]["context_id"]}, check=False,
            )

        with ThreadPoolExecutor(max_workers=2) as pool:
            pressure_future = pool.submit(primary_structure_pressure, "codemap-primary-during-add")
            add_future = pool.submit(
                runner.timed_call, "codemap-add-linked-root", "manage_workspaces",
                {"action": "add_folder", "workspace": plan["scope"]["workspace_id"],
                 "folder_path": str(linked_root), "window_id": plan["scope"]["window_id"]},
                check=False,
            )
            pressure_add, add_linked = pressure_future.result(), add_future.result()
        if not call_succeeded(add_linked) or not call_succeeded(pressure_add):
            raise BenchmarkError("linked-root add or concurrent primary structure failed")
        state["added_roots"].append({"path": str(linked_root), "kind": "git-worktree", "owned": True})
        save_json(artifact / "state.json", state)
        secondary_calls = [
            ("get_code_structure", {"paths": [fixture["individuals"][7]["path"]],
                                    "omit_wait_ms": True,
                                    "expected_file": fixture["individuals"][7]["path"],
                                    "marker": fixture["individuals"][7]["marker"]}),
            ("get_file_tree", {"path": str(Path(fixture["individuals"][7]["path"]).parent),
                               "expected_file": fixture["individuals"][7]["path"]}),
        ]
        linked_runtime = runner.call(
            "codemap-linked-root-identity", DEBUG_TOOL,
            {"op": "mcp_read_search_runtime_snapshot",
             "window_id": plan["scope"]["window_id"],
             "recent_publication_limit": 0, "root_limit": 256}, check=False,
        )
        linked_identity = runtime_root_identity(linked_runtime, str(linked_root))
        linked_prewarm_path = str(linked_root / fixture["individuals"][7]["path"])
        linked_prewarm_parent = str(Path(linked_prewarm_path).parent)
        linked_prewarm = runner.call(
            "codemap-linked-prewarm", "get_code_structure",
            {"scope": "paths", "paths": [linked_prewarm_path],
             "context_id": plan["scope"]["context_id"]}, check=False,
        )
        linked_prewarm_evidence = codemap_structure_evidence(
            linked_prewarm, expected_root_id=linked_identity["id"],
            expected_root_path=linked_identity["path"],
            expected_root_type=linked_identity["type"],
            expected_file_path=linked_prewarm_path,
            expected_marker=fixture["individuals"][7]["marker"],
            expected_file_type=plan["dataset"]["code_file_type"],
        )
        linked_prewarm_tree = runner.call(
            "codemap-linked-prewarm-tree", "get_file_tree",
            {"type": "files", "mode": "full", "path": linked_prewarm_parent,
             "max_depth": 1, "context_id": plan["scope"]["context_id"]}, check=False,
        )
        linked_prewarm_tree_evidence = codemap_tree_marker_evidence(
            linked_prewarm_tree,
            expected_context_id=plan["scope"]["context_id"],
            expected_root_path=linked_identity["path"],
            requested_parent=linked_prewarm_parent,
            expected_file_path=linked_prewarm_path,
        )
        linked_hold = codemap_debug_action(
            runner, plan, "codemap_projection_hold_acquire",
            target_root_id=linked_identity["id"], expires_ms=60_000,
        )
        linked_hold_id = find_value(linked_hold["response"], "hold_id")
        if not isinstance(linked_hold_id, str):
            raise BenchmarkError("linked-root DEBUG hold acquire omitted hold_id")
        active_hold = linked_hold_id
        active_hold_target_root_id = linked_identity["id"]
        state["codemap_holds"].append({
            "hold_id": linked_hold_id,
            "target_root_id": linked_identity["id"],
            "released": False,
        })
        blocked_item = fixture["individuals"][8]
        linked_blocked_path = str(linked_root / blocked_item["path"])
        linked_blocked_calls = [*secondary_calls,
            ("get_code_structure", {
                "paths": [linked_blocked_path], "omit_wait_ms": True,
                "expected_file": linked_blocked_path, "marker": blocked_item["marker"],
            }),
            ("get_file_tree", {
                "path": str(Path(linked_blocked_path).parent),
                "expected_file": linked_blocked_path,
            }),
        ]
        save_json(artifact / "state.json", state)
        ordinary_branch = safe_name(f"rpce-bench-{artifact.name}-i2-o1")[:120]
        ordinary_prompt = codemap_agent_prompt(
            primary_probe_calls, sentinel=CODEMAP_GATE_SENTINEL
        )
        linked_prompt = codemap_agent_prompt(
            linked_blocked_calls, sentinel=CODEMAP_GATE_SENTINEL
        )
        privacy_prompt_allowlist.extend([ordinary_prompt, linked_prompt])
        with ThreadPoolExecutor(max_workers=2) as pool:
            ordinary_future = pool.submit(
                runner.call, "codemap-agent-ordinary", "agent_run",
                {"op": "start", "model_id": "explore", "detach": True,
                 "message": ordinary_prompt,
                 "session_name": "RPCE codemap primary agent", "worktree_create": True,
                 "worktree_branch": ordinary_branch,
                 "worktree_base_ref": plan["dataset"]["base_commit_oid"],
                 "worktree_label": f"RPCE codemap {artifact.name} primary",
                 "context_id": plan["scope"]["context_id"]},
                timeout=180,
            )
            linked_future = pool.submit(
                runner.call, "codemap-agent-linked", "agent_run",
                {"op": "start", "model_id": "explore", "detach": True,
                 "message": linked_prompt,
                 "session_name": "RPCE codemap linked root", "worktree": str(linked_root),
                 "context_id": plan["scope"]["context_id"]},
                timeout=180,
            )
            ordinary, linked = ordinary_future.result(), linked_future.result()
        ordinary_session, linked_session = response_session_id(ordinary), response_session_id(linked)
        ordinary_context, linked_context = response_context_id(ordinary), response_context_id(linked)
        if ordinary_context is None or linked_context is None:
            raise BenchmarkError("concurrent codemap agents omitted contexts")
        ordinary_worktree = discover_owned_worktree(ordinary, root, ordinary_branch)
        privacy_allowlist.append(ordinary_worktree)
        state["worktrees"].append({
            "path": str(ordinary_worktree), "owned": True, "branch": ordinary_branch,
        })
        linked_binding_ok = any(
            Path(path).resolve() == linked_root.resolve()
            for _, path in response_worktree_binding_set(linked)
        )
        ordinary_binding_ok = any(
            Path(path).resolve() == ordinary_worktree.resolve()
            for _, path in response_worktree_binding_set(ordinary)
        )
        state["sessions"].extend([
            {"session_id": ordinary_session, "context_id": ordinary_context,
             "terminal": False, "scenario": "concurrent-ordinary-root"},
            {"session_id": linked_session, "context_id": linked_context,
             "terminal": False, "scenario": "concurrent-linked-root"},
        ])
        save_json(artifact / "state.json", state)
        linked_direct = agent_codemap_direct_evidence(
            runner, plan, start_response=linked, session_id=linked_session,
            context_id=linked_context, worktree_path=linked_root,
            expected_calls=secondary_calls,
        )
        held_call_observed = wait_for_exact_agent_structure_call(
            runner, session_id=linked_session, context_id=linked_context,
            expected_path=linked_blocked_path,
        )
        linked_active_before_remove = poll_active_agent(
            runner, linked_session, linked_context, "codemap-linked-before-remove"
        )
        ordinary_active_before_remove = poll_active_agent(
            runner, ordinary_session, ordinary_context, "codemap-ordinary-before-remove"
        )
        if not linked_active_before_remove["ok"]:
            raise BenchmarkError("linked-root agent terminalized before root removal")
        with ThreadPoolExecutor(max_workers=2) as pool:
            pressure_future = pool.submit(primary_structure_pressure, "codemap-primary-during-remove")
            remove_future = pool.submit(
                runner.timed_call, "codemap-remove-linked-root", "manage_workspaces",
                {"action": "remove_folder", "workspace": plan["scope"]["workspace_id"],
                 "folder_path": str(linked_root), "window_id": plan["scope"]["window_id"]},
                check=False,
            )
            pressure_remove, remove_linked = pressure_future.result(), remove_future.result()
        if call_succeeded(remove_linked):
            state["added_roots"] = [
                item for item in state["added_roots"] if item.get("path") != str(linked_root)
            ]
        ordinary_active_after_remove = poll_active_agent(
            runner, ordinary_session, ordinary_context, "codemap-ordinary-after-remove"
        )
        revoked_call = runner.call(
            "codemap-linked-revoked-probe", "get_code_structure",
            {"scope": "paths", "paths": [linked_blocked_path],
             "context_id": linked_context}, check=False, context_id=linked_context,
        )
        linked_revoked = structured_removed_evidence(
            revoked_call, "get_code_structure",
            expected_root_id=linked_identity["id"],
            expected_root_path=linked_identity["path"],
            expected_root_type=linked_identity["type"],
            expected_file_path=linked_blocked_path,
            require_absent_bound_root=True,
        )
        linked_status = terminalize(runner, linked_session, linked_context)
        linked_started_ns = find_value(linked, "_benchmark_started_monotonic_ns")
        linked_inference_elapsed_ms = (
            (time.monotonic_ns() - linked_started_ns) / 1_000_000
            if isinstance(linked_started_ns, int) else None
        )
        state["sessions"][-1]["terminal"] = linked_status in TERMINAL_STATES
        state["sessions"][-1]["status"] = linked_status
        linked_log = runner.call(
            "codemap-linked-revoked-log", "agent_manage",
            {"op": "get_log", "session_id": linked_session, "offset": 0, "limit": 4000},
            timeout=120, check=False, context_id=linked_context,
        )
        linked_transcript = verify_agent_codemap_revoked_transcript(
            transcript_xml_from_log(linked_log), expected_first_path=linked_blocked_path,
        )
        linked_released = codemap_debug_action(
            runner, plan, "codemap_projection_hold_release",
            target_root_id=linked_identity["id"], hold_id=linked_hold_id,
        )
        if find_value(linked_released["response"], "released") is not True:
            raise BenchmarkError("linked-root DEBUG hold was not released by its owner")
        active_hold = None
        active_hold_target_root_id = None
        state["codemap_holds"][-1]["released"] = True
        ordinary_result = wait_codemap_agent_success(
            runner, ordinary_session, ordinary_context,
            start_response=ordinary,
            expected_output=CODEMAP_GATE_SENTINEL, expected_calls=primary_probe_calls,
        )
        if not ordinary_result["ok"]:
            raise BenchmarkError("fail-fast concurrent ordinary inference probe failed")
        state["sessions"][-2]["terminal"] = ordinary_result["status"] in TERMINAL_STATES
        state["sessions"][-2]["status"] = ordinary_result["status"]
        ordinary_direct = agent_codemap_direct_evidence(
            runner, plan, start_response=ordinary, session_id=ordinary_session,
            context_id=ordinary_context, worktree_path=ordinary_worktree,
            expected_calls=primary_probe_calls,
        )
        linked_lifecycle = linked_root_removal_evidence(
            linked_active_before_remove, linked_status, linked_revoked
        )
        save_json(artifact / "state.json", state)
        results["concurrent-roots-agents"] = {
            "ok": linked_direct["ok"] and ordinary_result["ok"]
            and ordinary_direct["ok"] and linked_binding_ok and ordinary_binding_ok,
            "ordinary": {"transcript": ordinary_result, "structured": ordinary_direct},
            "linked": {"structured": linked_direct, "transcript": linked_transcript},
            "linked_binding_exact": linked_binding_ok,
            "ordinary_binding_exact": ordinary_binding_ok,
            "linked_prewarm": linked_prewarm_evidence,
            "linked_prewarm_tree": linked_prewarm_tree_evidence,
            "held_call_observed_before_remove": held_call_observed,
            "linked_inference_elapsed_ms": linked_inference_elapsed_ms,
        }
        results["active-secondary-root-add-remove"] = {
            "ok": (
                call_succeeded(add_linked) and call_succeeded(remove_linked)
                and call_succeeded(pressure_add) and call_succeeded(pressure_remove)
                and linked_lifecycle["ok"]
                and overlap(pressure_add, add_linked)
                and overlap(pressure_remove, remove_linked)
            ),
            "primary_status_before_remove": ordinary_active_before_remove["status"],
            "primary_status_after_remove": ordinary_active_after_remove["status"],
            "linked_lifecycle": linked_lifecycle,
            "add_overlap": overlap(pressure_add, add_linked),
            "remove_overlap": overlap(pressure_remove, remove_linked),
        }

        final_snapshot = codemap_debug_action(
            runner, plan, "codemap_projection_snapshot"
        )["snapshot"]
        raw_queue_wait_values = final_snapshot.get("queue_wait_ms")
        start_queue_ordinal = start_snapshot.get("queue_wait_sample_ordinal")
        final_queue_ordinal = final_snapshot.get("queue_wait_sample_ordinal")
        if (
            not isinstance(raw_queue_wait_values, list)
            or not nonnegative_integer(start_queue_ordinal)
            or not nonnegative_integer(final_queue_ordinal)
            or final_queue_ordinal < start_queue_ordinal
        ):
            raise BenchmarkError("DEBUG codemap snapshot omitted scoped queue sample ordinals")
        queue_sample_delta = final_queue_ordinal - start_queue_ordinal
        if queue_sample_delta > len(raw_queue_wait_values) or not all(
            isinstance(value, (int, float)) and not isinstance(value, bool) and value >= 0
            for value in raw_queue_wait_values
        ):
            raise BenchmarkError("DEBUG codemap snapshot omitted queue_wait_ms samples")
        queue_wait_values = (
            raw_queue_wait_values[-queue_sample_delta:] if queue_sample_delta else []
        )
        resource_keys = (
            "retained_path_bytes", "retained_source_bytes", "retained_projection_bytes",
            "staged_graph_bytes", "resident_graph_bytes", "queued_manifest_mutation_bytes",
        )
        resources_bounded = all(
            nonnegative_integer(final_snapshot.get(key))
            and positive_integer(final_snapshot.get(f"limit_{key}"))
            and final_snapshot[key] <= final_snapshot[f"limit_{key}"]
            for key in resource_keys
        )
        rejection_keys = (
            "projection_budget_rejections", "projection_demand_busy_rejections",
            "busy_rejections", "failures", "manifest_failures",
        )
        rejection_deltas = {
            key: codemap_counter_delta(start_snapshot, final_snapshot, key)
            for key in rejection_keys
        }
        no_policy_rejection = all(value == 0 for value in rejection_deltas.values())
        results["resource-policy"] = {
            "ok": resources_bounded and no_policy_rejection,
            "resource_bytes": {
                key: {"used": final_snapshot.get(key),
                      "limit": final_snapshot.get(f"limit_{key}")}
                for key in resource_keys
            },
            "rejection_deltas": rejection_deltas,
        }

        if memory_session_id is None:
            raise BenchmarkError("codemap memory session ownership was lost")
        memory_stopped, resources = stop_owned_memory_sampler(
            runner, memory_session_id, label="codemap-memory-stop",
        )
        memory_acquisition.stop_verified = memory_stopped
        memory_acquisition.stop_response = resources
        state["memory_stopped"] = memory_stopped
    except BaseException as error:
        operational_error = repr(error)
    finally:
        if active_hold:
            released = runner.call(
                "codemap-finally-release-hold", DEBUG_TOOL,
                diagnostic_payload(
                    plan, "codemap_projection_hold_release", hold_id=active_hold,
                    **({"target_root_id": active_hold_target_root_id}
                       if active_hold_target_root_id else {}),
                ),
                check=False,
            )
            released_ok = (
                call_succeeded(released)
                and (find_value(released, "released") is True or find_value(released, "hold_count") == 0)
            )
            cleanup.append({
                "action": "release_codemap_hold", "hold_id_sha256": sha256_bytes(active_hold.encode()),
                "ok": released_ok,
            })
            for item in state["codemap_holds"]:
                if item.get("hold_id") == active_hold:
                    item["released"] = released_ok
        for raw in watcher_paths:
            candidate = root / raw
            if candidate.exists():
                response = runner.call(
                    f"codemap-cleanup-file-{safe_name(candidate.name)}", "file_actions",
                    {"action": "delete", "path": str(candidate),
                     "context_id": plan["scope"]["context_id"]}, check=False,
                )
                cleanup.append({
                    "action": "remove_owned_fixture", "path_sha256": sha256_bytes(raw.encode()),
                    "ok": call_succeeded(response),
                })
        for session in state["sessions"]:
            if not session.get("terminal"):
                status = terminalize(runner, session["session_id"])
                session["status"] = status
                session["terminal"] = status in TERMINAL_STATES
            cleanup.append({
                "action": "terminalize_agent",
                "session_id_sha256": sha256_bytes(session["session_id"].encode()),
                "status": session.get("status"), "terminal": session.get("terminal") is True,
            })
        all_terminal = all(session.get("terminal") is True for session in state["sessions"])
        remaining_added_roots: list[dict[str, Any]] = []
        for item in reversed(state["added_roots"]):
            path = item.get("path")
            ownership_proven = (
                item.get("kind") == "non-git"
                and validate_codemap_temp_ownership_marker(
                    item, artifact_id=artifact.name, plan_sha256=plan["plan_sha256"]
                )
            )
            if not all_terminal or not ownership_proven:
                cleanup.append({
                    "action": "remove_workspace_root",
                    "path_sha256": sha256_bytes(str(path).encode()),
                    "ok": False, "manual_cleanup": True,
                    "reason": (
                        "agents_not_terminal" if not all_terminal else
                        "live_cleanup_ownership_proof_required"
                    ),
                })
                remaining_added_roots.append(item)
                continue
            response = runner.call(
                f"codemap-cleanup-root-{safe_name(str(path))}", "manage_workspaces",
                {"action": "remove_folder", "workspace": plan["scope"]["workspace_id"],
                 "folder_path": path, "window_id": plan["scope"]["window_id"]}, check=False,
            )
            ok = call_succeeded(response)
            cleanup.append({
                "action": "remove_workspace_root",
                "path_sha256": sha256_bytes(str(path).encode()), "ok": ok,
            })
            if not ok:
                remaining_added_roots.append(item)
        state["added_roots"] = list(reversed(remaining_added_roots))
        for worktree in {item["path"]: item for item in state["worktrees"]}.values():
            cleaned = clean_owned_worktree(
                root, worktree["path"], all_terminal,
                expected_branch=worktree.get("branch"), expected_path=worktree["path"],
                expected_head=plan["dataset"]["base_commit_oid"], ownership_proven=True,
            )
            cleanup.append(cleaned)
        try:
            memory_cleanup, resources = cleanup_memory_sampler_acquisition(
                runner, memory_acquisition, label=artifact.name,
            )
        except BaseException as cleanup_error:
            memory_cleanup = {
                "action": "stop_memory_sampler", "ok": False,
                "verified_stopped": False, "stop_attempted": False,
                "manual_cleanup": True,
                "reason": f"memory sampler cleanup failed: {cleanup_error!r}",
            }
            resources = {
                "available": False, "reason": "sampler_cleanup_failed",
                "error": repr(cleanup_error),
            }
        state["memory_stopped"] = memory_cleanup.get("verified_stopped") is True
        cleanup.append(memory_cleanup)
        try:
            require_benchmark_gate(runner)
            state["benchmark_gate_unchanged"] = True
        except BenchmarkError:
            state["benchmark_gate_unchanged"] = False
        cleanup.append({
            "action": "preserve_benchmark_setting", "ok": state["benchmark_gate_unchanged"],
        })
        final_target_ok = False
        try:
            verify_disposable_target(runner, plan, require_only_planned_root=True)
            final_target_ok = True
        except BenchmarkError:
            pass
        cleanup.append({"action": "restore_workspace_roots", "ok": final_target_ok})
        remaining_paths = {
            str(Path(item["path"]).resolve())
            for item in state["added_roots"] if isinstance(item.get("path"), str)
        }
        for path in reversed(owned_dirs):
            if not path.exists() or str(path.resolve()) in remaining_paths:
                continue
            if path.name.startswith("rpce-codemap-gate-nongit-"):
                shutil.rmtree(path, ignore_errors=True)
            else:
                try:
                    path.rmdir()
                except OSError:
                    pass
        save_cleanup_proof(artifact / "cleanup.json", cleanup)
        save_json(artifact / "state.json", state)
        save_json(artifact / "resources.json", resources)

    retained = [sample for sample in samples if sample.get("valid")]
    direct_structure_durations: list[float] = []
    raw_cli_file = artifact / "raw-cli-calls.ndjson"
    if raw_cli_file.exists():
        for line in raw_cli_file.read_text(encoding="utf-8").splitlines():
            raw_call = json.loads(line)
            if raw_call.get("tool") != "get_code_structure":
                continue
            started = raw_call.get("started_monotonic_ns")
            finished = raw_call.get("finished_monotonic_ns")
            if not isinstance(started, int) or not isinstance(finished, int) or finished < started:
                raise BenchmarkError("raw get_code_structure timing evidence was malformed")
            direct_structure_durations.append((finished - started) / 1_000_000)
    metric_values = {
        "cold_individual_structure": [
            sample["duration_ms"] for sample in retained
            if sample["scenario"] == "cold-individual"
        ],
        "warm_individual_structure": [
            sample["duration_ms"] for sample in retained
            if sample["scenario"] == "warm-individual"
        ],
        "cold_directory_structure": [
            sample["duration_ms"] for sample in retained
            if sample["scenario"] == "cold-directory"
        ],
        "warm_directory_structure": [
            sample["duration_ms"] for sample in retained
            if sample["scenario"] == "warm-directory"
        ],
        "tree_marker_availability": [
            sample["tree_marker_duration_ms"] for sample in retained
            if sample.get("tree_marker_duration_ms") is not None
        ],
        "first_search": locals().get("search_durations", []),
        "first_read": locals().get("read_durations", []),
        "root_readiness": locals().get("readiness_durations", []),
        "queue_wait": (
            locals().get("queue_wait_values", [])
            if isinstance(locals().get("queue_wait_values", []), list) else []
        ),
        "operation_duration": direct_structure_durations,
    }
    resource_metrics = find_value(resources, "metrics")
    memory_metric_names = (
        "peak_resident_delta_mb", "retained_resident_delta_mb",
        "peak_physical_footprint_delta_mb", "retained_physical_footprint_delta_mb",
    )
    for key in memory_metric_names:
        metric_values[f"memory_{key}"] = []
    if isinstance(resource_metrics, dict):
        for key in memory_metric_names:
            value = resource_metrics.get(key)
            if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value):
                metric_values[f"memory_{key}"] = [max(0.0, float(value))]
            else:
                metric_values[f"memory_{key}"] = []
    metrics = {name: stats(values, label=f"codemap {name}") for name, values in metric_values.items()}

    def metric_within_baseline(name: str, percentile: str) -> bool:
        current = (metrics.get(name) or {}).get(percentile)
        baseline_value = ((baseline.get("metrics") or {}).get(name) or {}).get(percentile)
        return (
            isinstance(current, (int, float)) and not isinstance(current, bool)
            and isinstance(baseline_value, (int, float)) and not isinstance(baseline_value, bool)
            and baseline_value > 0 and current <= baseline_value * 1.10
        )

    scenario_ok = operational_error is None and all(item.get("ok") is True for item in results.values())
    exact_counts = all((
        metrics["cold_individual_structure"]["count"] == args.cold_samples,
        metrics["warm_individual_structure"]["count"] == args.warm_samples,
        metrics["cold_directory_structure"]["count"] == args.cold_samples,
        metrics["warm_directory_structure"]["count"] == args.warm_samples,
    ))
    required_metric_inventory = all(
        metrics[name]["count"] > 0
        and finite_number(metrics[name]["p50"])
        and finite_number(metrics[name]["p95"])
        and metrics[name]["p50"] > 0
        and metrics[name]["p95"] > 0
        for name in CODEMAP_REQUIRED_METRICS
    )
    cleanup_ok = bool(cleanup) and all(
        item.get("ok") is True or item.get("terminal") is True
        or item.get("removed") is True or item.get("reason") == "already_absent"
        for item in cleanup
    )
    gates = {
        "exact cold/warm sample counts": exact_counts,
        "complete p50/p95 metric inventory": required_metric_inventory,
        "all codemap content/path/tree scenarios": scenario_ok,
        "every request within 10s + 500ms": all(
            duration
            <= CODEMAP_GATE_WAIT_MILLISECONDS + CODEMAP_GATE_HARNESS_ALLOWANCE_MILLISECONDS
            for duration in direct_structure_durations
        ) and bool(direct_structure_durations),
        "root/search/read p95 regression <= 10%": all(
            metric_within_baseline(name, "p95")
            for name in ("root_readiness", "first_search", "first_read")
        ),
        "warm structure p50/p95 regression <= 10%": all(
            metric_within_baseline(name, percentile)
            for name in ("warm_individual_structure", "warm_directory_structure")
            for percentile in ("p50", "p95")
        ),
        "memory delta p95 regression <= 10%": all(
            metric_within_baseline(f"memory_{name}", "p95")
            for name in memory_metric_names
        ),
        "owned cleanup complete": cleanup_ok,
    }
    sanitized_results = sanitize_codemap_summary_value(results)
    summary = {
        "schema_version": SCHEMA_VERSION,
        "kind": "codemap-gate",
        "artifact_id": artifact.name,
        "plan_sha256": plan["plan_sha256"],
        "fixture_sha256": sanitized_fixture["fixture_sha256"],
        "status": "failed",
        "decision": "fail",
        "gates": gates,
        "metrics": metrics,
        "sample_counts": {
            "attempted": len(samples), "valid": len(retained),
            "invalid": len(samples) - len(retained),
        },
        "configuration": {
            "cold_samples_per_cohort": args.cold_samples,
            "warm_samples_per_cohort": args.warm_samples,
            "wait_contract_ms": CODEMAP_GATE_WAIT_MILLISECONDS,
            "harness_allowance_ms": CODEMAP_GATE_HARNESS_ALLOWANCE_MILLISECONDS,
        },
        "scenarios": sanitized_results,
        "cleanup_complete": cleanup_ok,
        "operational_error_code": "operational_error" if operational_error else None,
        "baseline_sha256": baseline_acceptance["summary_sha256"],
        "baseline_acceptance": baseline_acceptance,
        "fixture": sanitized_fixture,
    }
    save_json(artifact / "summary.json", summary)
    privacy = codemap_artifact_privacy_scan(
        artifact,
        allowlisted_roots=privacy_allowlist,
        allowlisted_prompts=privacy_prompt_allowlist,
    )
    gates["owner-only raw artifacts and privacy scan"] = privacy["ok"]
    summary["privacy"] = privacy
    decision = "pass" if gates and all(gates.values()) else "fail"
    summary["decision"] = decision
    summary["status"] = "completed" if decision == "pass" else "failed"
    save_json(artifact / "summary.json", summary)
    print(json.dumps({
        "status": summary["status"], "decision": decision,
        "artifact_directory": str(artifact), "gates": gates,
    }, indent=2, sort_keys=True))
    return 0 if decision == "pass" else 1


def gate_ratio(control: float | None, candidate: float | None) -> float | None:
    if control in (None, 0) or candidate is None:
        return None
    return (control - candidate) / control


def diagnostic_number(
    item: dict[str, Any],
    section: str,
    field: str,
    subsection: str | None = None,
) -> float | None:
    value = find_value(item.get("diagnostic"), section)
    if not isinstance(value, dict):
        return None
    if subsection is not None:
        value = value.get(subsection)
        if not isinstance(value, dict):
            return None
    number = value.get(field)
    return float(number) if finite_number(number) else None


def sample_metric_number(item: dict[str, Any], metric: str) -> float | None:
    diagnostic = (
        (item.get("primary_performance") or {}).get("diagnostic_checkpoint")
        if metric in METRICS else item.get("diagnostic")
    )
    sample = find_value(diagnostic, "sample")
    if not isinstance(sample, dict):
        return None
    if metric == "interactive_readiness_us":
        value = sample.get(metric)
    else:
        durations = sample.get("durations_us")
        value = durations.get(metric) if isinstance(durations, dict) else None
    return float(value) if finite_number(value, positive=True) else None


def absolute_memory_regression(control: Iterable[float], candidate: Iterable[float]) -> float | None:
    control_values = [float(value) for value in control]
    candidate_values = [float(value) for value in candidate]
    if not control_values or not candidate_values:
        return None
    if not all(math.isfinite(value) and value > 0 for value in control_values + candidate_values):
        return None
    baseline = statistics.median(control_values)
    if baseline <= 0:
        return None
    return statistics.median(candidate_values) / baseline - 1.0


def cleanup_entry_succeeded(item: dict[str, Any]) -> bool:
    return (
        item.get("terminal") is True
        or item.get("ok") is True
        or item.get("removed") is True
        or item.get("reason") == "already_absent"
    )


def validate_cleanup_evidence(
    entries: list[dict[str, Any]],
    *,
    run_artifact: bool,
    expected_agent_count: int,
    expected_worktree_count: int,
) -> bool:
    if not entries or not all(cleanup_entry_succeeded(item) for item in entries):
        return False
    by_action: dict[str, list[dict[str, Any]]] = {}
    for item in entries:
        action = item.get("action")
        if isinstance(action, str):
            by_action.setdefault(action, []).append(item)
    if run_artifact and len(by_action.get("terminalize_agent", [])) != expected_agent_count:
        return False
    if len(by_action.get("remove_worktree", [])) != expected_worktree_count:
        return False
    if any(
        item.get("ownership_proven") is not True
        or item.get("worktree_absent") is not True
        or item.get("branch_absent") is not True
        or item.get("removed") is not True
        for item in by_action.get("remove_worktree", [])
    ):
        return False
    required = (
        {
            "stop_memory_sampler", "restore_route", "reset_diagnostics",
            "preserve_benchmark_setting", "restore_workspace_roots",
        }
        if run_artifact else
        {
            "terminalize_child", "terminalize_parent", "restore_workspace_roots",
            "route_control_unchanged", "benchmark_setting_unchanged",
            "diagnostics_reset_not_required",
        }
    )
    if not run_artifact and len(by_action.get("remove_workspace_root", [])) < 3:
        return False
    if run_artifact and (
        len(by_action.get("stop_memory_sampler", [])) != 1
        or not all(
        item.get("ok") is True and item.get("verified_stopped") is True
        for item in by_action.get("stop_memory_sampler", [])
        )
    ):
        return False
    return required <= set(by_action)


def cleanup_command_acceptance(
    cleanup_evidence_complete: bool,
    state: dict[str, Any],
) -> bool:
    return (
        cleanup_evidence_complete
        and state.get("cleanup_manual_required") is not True
    )


def memory_sampler_record(value: Any, action: str) -> dict[str, Any]:
    if not call_succeeded(value):
        raise BenchmarkError(f"memory sampler {action} query failed")
    matches: dict[str, dict[str, Any]] = {}
    for candidate in structured_json_objects(benchmark_final_response(value)):
        if (
            candidate.get("op") == "large_workspace_memory"
            and candidate.get("action") == action
            and isinstance(candidate.get("running"), bool)
        ):
            matches[json.dumps(candidate, sort_keys=True, separators=(",", ":"))] = candidate
    if len(matches) != 1:
        raise BenchmarkError(f"memory sampler {action} response was missing or ambiguous")
    record = next(iter(matches.values()))
    if action in {"start", "stop"} or record.get("running") is True:
        session = record.get("session")
        top_level_id = record.get("session_id")
        nested_id = session.get("id") if isinstance(session, dict) else None
        if (
            not isinstance(top_level_id, str)
            or not isinstance(nested_id, str)
            or validate_uuid(top_level_id, "memory session-id")
            != validate_uuid(nested_id, "memory nested session-id")
        ):
            raise BenchmarkError(f"memory sampler {action} omitted one exact session owner")
    return record


@dataclass
class MemorySamplerAcquisition:
    label: str
    preflight_inactive_proven: bool = False
    start_attempted: bool = False
    session_id: str | None = None
    acquisition_uncertain: bool = False
    stop_verified: bool = False
    stop_response: Any = None


def start_owned_memory_sampler(
    runner: CLIRunner,
    label: str,
    acquisition: MemorySamplerAcquisition | None = None,
) -> tuple[str, Any]:
    owner = acquisition or MemorySamplerAcquisition(label=label)
    if owner.label != label or owner.start_attempted:
        raise BenchmarkError("memory sampler acquisition handle was invalid or already used")
    current = runner.call(
        f"{safe_name(label)}-memory-preflight", DEBUG_TOOL,
        {"op": "large_workspace_memory", "action": "current"},
        timeout=60, check=False,
    )
    current_record = memory_sampler_record(current, "current")
    if current_record.get("running") is not False:
        raise BenchmarkError("memory sampler start requires a proven inactive global sampler")
    owner.preflight_inactive_proven = True
    owner.start_attempted = True
    owner.acquisition_uncertain = True
    response = runner.call(
        f"{safe_name(label)}-memory-start", DEBUG_TOOL,
        {"op": "large_workspace_memory", "action": "start", "label": label,
         "interval_ms": 100, "benchmark_gate": True},
    )
    record = memory_sampler_record(response, "start")
    session_id = validate_uuid(str(record["session_id"]), "memory session-id")
    if record.get("running") is not True:
        raise BenchmarkError("owned memory sampler did not start")
    session = record.get("session")
    if not isinstance(session, dict) or session.get("label") != label:
        raise BenchmarkError("owned memory sampler start returned the wrong owner label")
    owner.session_id = session_id
    owner.acquisition_uncertain = False
    return session_id, response


def stop_owned_memory_sampler(
    runner: CLIRunner,
    session_id: str,
    *,
    label: str,
    settle_seconds: float = 2,
) -> tuple[bool, Any]:
    owned_id = validate_uuid(session_id, "memory session-id")
    response = runner.call(
        label, DEBUG_TOOL,
        {"op": "large_workspace_memory", "action": "stop",
         "session_id": owned_id, "settle_seconds": settle_seconds},
        timeout=60, check=False,
    )
    try:
        record = memory_sampler_record(response, "stop")
        stopped_id = validate_uuid(str(record["session_id"]), "stopped memory session-id")
        ok = stopped_id == owned_id and record.get("running") is False
    except BenchmarkError:
        ok = False
    return ok, response


def cleanup_memory_sampler_acquisition(
    runner: CLIRunner,
    acquisition: MemorySamplerAcquisition,
    *,
    label: str,
    settle_seconds: float = 2,
) -> tuple[dict[str, Any], Any]:
    if acquisition.label != label:
        return ({
            "action": "stop_memory_sampler", "ok": False, "verified_stopped": False,
            "stop_attempted": False, "manual_cleanup": True,
            "reason": "memory sampler cleanup label did not match the acquisition handle",
        }, {"available": False, "reason": "acquisition_label_mismatch"})
    if acquisition.stop_verified:
        return ({
            "action": "stop_memory_sampler", "ok": True, "verified_stopped": True,
            "stop_attempted": True, "ownership_proven": True,
            "reason": "owned_session_already_stopped",
        }, acquisition.stop_response)
    if acquisition.session_id is not None:
        stopped, response = stop_owned_memory_sampler(
            runner, acquisition.session_id, label=label,
            settle_seconds=settle_seconds,
        )
        return ({
            "action": "stop_memory_sampler", "ok": stopped,
            "verified_stopped": stopped, "stop_attempted": True,
            "ownership_proven": True,
            "session_id_sha256": sha256_bytes(acquisition.session_id.encode()),
        }, response)
    if not acquisition.start_attempted:
        return ({
            "action": "stop_memory_sampler", "ok": True, "verified_stopped": True,
            "stop_attempted": False, "ownership_proven": True,
            "reason": "start_not_attempted",
        }, {"available": False, "reason": "sampler_start_not_attempted"})
    if not acquisition.preflight_inactive_proven:
        return ({
            "action": "stop_memory_sampler", "ok": False, "verified_stopped": False,
            "stop_attempted": False, "manual_cleanup": True,
            "reason": "uncertain sampler acquisition lacked an inactive preflight",
        }, {"available": False, "reason": "sampler_ownership_unproven"})

    current = runner.call(
        "cleanup-memory-uncertain-current", DEBUG_TOOL,
        {"op": "large_workspace_memory", "action": "current"},
        timeout=60, check=False,
    )
    try:
        record = memory_sampler_record(current, "current")
    except BenchmarkError as error:
        return ({
            "action": "stop_memory_sampler", "ok": False, "verified_stopped": False,
            "stop_attempted": False, "manual_cleanup": True,
            "reason": f"uncertain sampler acquisition could not be resolved: {error}",
        }, current)
    if record.get("running") is False:
        return ({
            "action": "stop_memory_sampler", "ok": True, "verified_stopped": True,
            "stop_attempted": False, "ownership_proven": True,
            "observed_running": False, "reason": "uncertain_start_observed_inactive",
        }, current)
    session = record.get("session")
    current_id = record.get("session_id")
    try:
        proven_id = validate_uuid(str(current_id), "uncertain memory session-id")
        ownership_proven = (
            isinstance(session, dict)
            and session.get("label") == acquisition.label
            and validate_uuid(str(session.get("id")), "uncertain nested memory session-id")
            == proven_id
        )
    except BenchmarkError:
        ownership_proven = False
        proven_id = None
    if not ownership_proven or proven_id is None:
        return ({
            "action": "stop_memory_sampler", "ok": False, "verified_stopped": False,
            "stop_attempted": False, "manual_cleanup": True,
            "reason": "uncertain sampler acquisition resolved to a foreign or unproven owner",
        }, current)
    stopped, response = stop_owned_memory_sampler(
        runner, proven_id, label=label, settle_seconds=settle_seconds,
    )
    return ({
        "action": "stop_memory_sampler", "ok": stopped,
        "verified_stopped": stopped, "stop_attempted": True,
        "ownership_proven": True, "recovered_uncertain_acquisition": True,
        "session_id_sha256": sha256_bytes(proven_id.encode()),
    }, response)


def verify_resumed_memory_sampler_inactive(
    runner: CLIRunner,
    *,
    expected_session_id: str | None,
    expected_label: str,
) -> dict[str, Any]:
    current = runner.call(
        "cleanup-memory-current", DEBUG_TOOL,
        {"op": "large_workspace_memory", "action": "current"},
        timeout=60, check=False,
    )
    try:
        record = memory_sampler_record(current, "current")
        running = record["running"]
    except BenchmarkError as error:
        return {
            "action": "stop_memory_sampler", "ok": False, "verified_stopped": False,
            "stop_attempted": False, "manual_cleanup": True,
            "reason": f"resumed cleanup could not prove the global sampler inactive: {error}",
        }
    if running:
        session = record.get("session")
        current_id = record.get("session_id")
        current_label = session.get("label") if isinstance(session, dict) else None
        try:
            matches_owner = (
                isinstance(expected_session_id, str)
                and validate_uuid(str(current_id), "current memory session-id")
                == validate_uuid(expected_session_id, "expected memory session-id")
                and current_label == expected_label
            )
        except BenchmarkError:
            matches_owner = False
        if matches_owner:
            stopped, _ = stop_owned_memory_sampler(
                runner, expected_session_id,
                label="cleanup-memory-stop-owned", settle_seconds=0,
            )
            return {
                "action": "stop_memory_sampler", "ok": stopped,
                "verified_stopped": stopped, "stop_attempted": True,
                "ownership_proven": True,
                "session_id_sha256": sha256_bytes(expected_session_id.encode()),
            }
        return {
            "action": "stop_memory_sampler", "ok": False, "verified_stopped": False,
            "stop_attempted": False, "manual_cleanup": True,
            "reason": (
                "process-global memory sampler is owned by another or unproven session; "
                "resumed cleanup refuses takeover"
            ),
        }
    return {
        "action": "stop_memory_sampler", "ok": True, "verified_stopped": True,
        "stop_attempted": False, "observed_running": False,
    }


def render_scoreboard(summary: dict[str, Any]) -> str:
    lines = [
        f"## Worktree startup live benchmark — {summary['aggregate_id']}", "",
        f"- Plan SHA-256: `{summary['plan_sha256']}`",
        f"- Decision: **{summary['decision']}**",
        f"- Generated: `{summary['created_at']}`", "",
        "| cohort | metric | N | p50 µs | p95 µs | CV |",
        "|---|---|---:|---:|---:|---:|",
    ]
    for key, cohort in sorted(summary["cohorts"].items()):
        for metric, values in cohort["metrics"].items():
            lines.append(
                f"| `{key}` | `{metric}` | {values['count']} | {values['p50']} | {values['p95']} | {values['cv']} |"
            )
    lines.extend([
        "", "### Route and work attribution", "",
        "| cohort | primary retained | follow-on accepted | routes | fallbacks | Git commands p50 | Git µs p50 | FS ops p50 | FS µs p50 | CPU ms | peak physical Δ MB | retained physical Δ MB |",
        "|---|---:|---:|---|---|---:|---:|---:|---:|---:|---:|---:|",
    ])
    for key, cohort in sorted(summary["cohorts"].items()):
        resources = cohort.get("resources") or []
        cpu = [item.get("session_cpu_ms") for item in resources if isinstance(item.get("session_cpu_ms"), (int, float))]
        peak = [item.get("peak_physical_footprint_delta_mb") for item in resources if isinstance(item.get("peak_physical_footprint_delta_mb"), (int, float))]
        retained = [item.get("retained_physical_footprint_delta_mb") for item in resources if isinstance(item.get("retained_physical_footprint_delta_mb"), (int, float))]
        lines.append(
            f"| `{key}` | {cohort.get('primary_valid_retained', 0)} | "
            f"{cohort.get('follow_on_accepted_retained', 0)} | "
            f"`{cohort.get('route_counts', {})}` | `{cohort.get('fallback_counts', {})}` | "
            f"{cohort['git_command_count']['p50']} | {cohort['git_duration_us']['p50']} | "
            f"{cohort['filesystem_operation_count']['p50']} | {cohort['filesystem_duration_us']['p50']} | "
            f"{statistics.median(cpu) if cpu else None} | {statistics.median(peak) if peak else None} | "
            f"{statistics.median(retained) if retained else None} |"
        )
    lines.extend(["", "### Gates", "", "| gate | result |", "|---|---|"])
    for gate, value in summary["gates"].items():
        lines.append(f"| {gate} | `{value}` |")
    lines.extend(["", "### Evidence", ""])
    lines.append(f"- Correctness results: `{summary['correctness']}`")
    lines.append(f"- Invalid attempted samples: `{summary['invalid_attempted_samples']}`")
    lines.append(f"- Invalid retained samples: `{summary['invalid_retained_samples']}`")
    lines.append(f"- Primary-invalid attempted samples: `{summary['primary_invalid_attempted_samples']}`")
    lines.append(f"- Follow-on-failed attempted samples: `{summary['follow_on_failed_attempted_samples']}`")
    lines.append(f"- Artifact directories: `{', '.join(summary['artifacts'])}`")
    return "\n".join(lines) + "\n"


def configured_matrix_variants(plan: dict[str, Any]) -> tuple[list[str], list[str], list[str], list[int]]:
    matrix = plan.get("matrix")
    if not isinstance(matrix, dict):
        raise BenchmarkError("plan omitted benchmark matrix")
    states = matrix.get("process_states")
    checkouts = matrix.get("checkout_kinds")
    routes = matrix.get("routes")
    widths = matrix.get("widths")
    if (
        not isinstance(states, list) or not states
        or not isinstance(checkouts, list) or not checkouts
        or not isinstance(routes, list) or not routes
        or not isinstance(widths, list) or not widths
        or not all(isinstance(item, str) and item for item in states + checkouts + routes)
        or not all(positive_integer(item) for item in widths)
    ):
        raise BenchmarkError("plan benchmark matrix variants were invalid")
    return states, checkouts, routes, widths


def configured_required_matrix_keys(plan: dict[str, Any]) -> set[str]:
    states, checkouts, routes, widths = configured_matrix_variants(plan)
    return {
        f"{state}/{checkout}/{route}/{width}"
        for state in states for checkout in checkouts for route in routes for width in widths
    }


def validate_primary_revalidation_provenance(value: Any) -> list[str]:
    if not isinstance(value, dict):
        return ["provenance_malformed"]
    failures: list[str] = []
    if value.get("schema_version") != SCHEMA_VERSION:
        failures.append("provenance_schema_mismatch")
    if value.get("kind") != "primary-performance-offline-revalidation":
        failures.append("provenance_kind_mismatch")
    validator = value.get("validator")
    if (
        not isinstance(validator, dict)
        or validator.get("version") != PRIMARY_REVALIDATION_VERSION
        or not isinstance(validator.get("source_path"), str)
        or not isinstance(validator.get("source_sha256"), str)
        or len(validator.get("source_sha256", "")) != 64
    ):
        failures.append("validator_provenance_invalid")
    command = value.get("command")
    if (
        not isinstance(command, dict)
        or not isinstance(command.get("cwd"), str)
        or not isinstance(command.get("exact"), str)
        or not command.get("exact")
    ):
        failures.append("revalidation_command_missing")
    artifact = value.get("artifact")
    if (
        not isinstance(artifact, dict)
        or artifact.get("route") != "forced-full"
        or artifact.get("width") != 1
        or not positive_integer(artifact.get("invocation"))
        or not isinstance(artifact.get("artifact_id"), str)
        or not isinstance(artifact.get("plan_sha256"), str)
        or len(artifact.get("plan_sha256", "")) != 64
        or not isinstance(artifact.get("build_identity"), dict)
    ):
        failures.append("revalidation_artifact_identity_invalid")
    inputs = value.get("inputs")
    required_inputs = {
        "plan_argument", "artifact_plan", "summary", "samples_ndjson",
        "resources", "cleanup",
    }
    if not isinstance(inputs, dict) or set(inputs) != required_inputs:
        failures.append("revalidation_input_inventory_mismatch")
    elif any(
        not isinstance(item, dict)
        or not isinstance(item.get("path"), str)
        or not isinstance(item.get("sha256"), str)
        or len(item["sha256"]) != 64
        for item in inputs.values()
    ):
        failures.append("revalidation_input_hash_invalid")

    samples = value.get("samples")
    if not isinstance(samples, list) or len(samples) != 6:
        failures.append("revalidation_sample_count_mismatch")
        samples = []
    else:
        if [item.get("ordinal") for item in samples if isinstance(item, dict)] != list(range(1, 7)):
            failures.append("revalidation_sample_ordinals_mismatch")
        identities = {
            (item.get("correlation_id"), item.get("session_id"))
            for item in samples if isinstance(item, dict)
        }
        if len(identities) != 6:
            failures.append("revalidation_sample_identity_reused")
        for item in samples:
            if (
                not isinstance(item, dict)
                or item.get("primary_valid") is not True
                or item.get("invalid_reasons") != []
                or not isinstance(item.get("source_record_sha256"), str)
                or len(item.get("source_record_sha256", "")) != 64
                or not isinstance(item.get("checkpoint_sha256"), str)
                or len(item.get("checkpoint_sha256", "")) != 64
                or not isinstance(item.get("revalidated_checkpoint_sha256"), str)
                or item.get("revalidated_checkpoint_sha256") != item.get("checkpoint_sha256")
                or not finite_number(item.get("raw_primary_ms"), positive=True)
                or item.get("revalidated_primary_ms") != item.get("raw_primary_ms")
            ):
                failures.append("revalidation_sample_proof_invalid")
                break
    raw_values = value.get("raw_values_ms")
    source_retained = [
        item.get("raw_primary_ms") for item in samples
        if isinstance(item, dict) and item.get("warmup") is False
    ]
    source_warmup = [
        item.get("raw_primary_ms") for item in samples
        if isinstance(item, dict) and item.get("warmup") is True
    ]
    revalidated_retained = [
        item.get("revalidated_primary_ms") for item in samples
        if isinstance(item, dict) and item.get("warmup") is False
    ]
    if (
        not isinstance(raw_values, dict)
        or raw_values.get("source_retained") != source_retained
        or raw_values.get("revalidated_retained") != revalidated_retained
        or revalidated_retained != source_retained
        or raw_values.get("source_warmup") != source_warmup
        or len(source_retained) != 5
        or len(source_warmup) != 1
    ):
        failures.append("revalidation_raw_values_changed_or_mixed")
    proof = value.get("proof")
    required_proof = {
        "plan_content_matches_artifact",
        "artifact_identity_exact",
        "exact_sample_accounting",
        "checkpoint_hashes_recorded",
        "source_raw_values_equal_revalidated",
        "no_mixed_samples",
        "cleanup_complete",
        "resource_evidence_valid",
    }
    if (
        not isinstance(proof, dict)
        or set(proof) != required_proof
        or any(proof.get(key) is not True for key in required_proof)
    ):
        failures.append("revalidation_proof_incomplete")
    return failures


def revalidate_primary_command(args: argparse.Namespace) -> int:
    plan_path = Path(args.plan).expanduser().resolve(strict=True)
    artifact = Path(args.artifact).expanduser().resolve(strict=True)
    output = Path(args.output).expanduser().resolve()
    plan = load_plan(plan_path)
    artifact_files = {
        "artifact_plan": artifact / "plan.json",
        "summary": artifact / "summary.json",
        "samples_ndjson": artifact / "samples.ndjson",
        "resources": artifact / "resources.json",
        "cleanup": artifact / "cleanup.json",
    }
    if any(not path.is_file() for path in artifact_files.values()):
        raise BenchmarkError("revalidation artifact omitted a required input file")
    artifact_plan = load_plan(artifact_files["artifact_plan"])
    summary = json.loads(artifact_files["summary"].read_text(encoding="utf-8"))
    if artifact_plan != plan:
        raise BenchmarkError("revalidation plan argument differs from artifact plan")
    if (
        summary.get("artifact_id") != artifact.name
        or summary.get("plan_sha256") != plan["plan_sha256"]
        or summary.get("route") != "forced-full"
        or summary.get("width") != 1
        or summary.get("warmup_groups") != 1
        or summary.get("retained_groups") != 5
        or summary.get("expected_sample_count") != 6
    ):
        raise BenchmarkError("revalidation artifact is not the exact forced-full 1+5 cohort")
    build_identity = summary.get("build_identity")
    if (
        not isinstance(build_identity, dict)
        or build_identity.get("base_commit_oid") != plan["dataset"]["base_commit_oid"]
        or not isinstance(build_identity.get("cli_sha256"), str)
        or len(build_identity["cli_sha256"]) != 64
    ):
        raise BenchmarkError("revalidation artifact build identity is invalid")

    resources = json.loads(artifact_files["resources"].read_text(encoding="utf-8"))
    resource_failures = validate_resource_evidence(find_value(resources, "metrics"))
    cleanup = json.loads(artifact_files["cleanup"].read_text(encoding="utf-8"))
    cleanup_entries = [item for item in cleanup if isinstance(item, dict)] if isinstance(cleanup, list) else []
    cleanup_complete = validate_cleanup_evidence(
        cleanup_entries, run_artifact=True, expected_agent_count=6,
        expected_worktree_count=6,
    )
    expected_fixture = {
        "base_commit_oid": str(plan["dataset"]["base_commit_oid"]),
        "read_blob_sha256": str(plan["dataset"]["read_blob_sha256"]),
        "read_path": str(plan["dataset"]["read_path"]),
        "search_marker": str(plan["dataset"]["search_marker"]),
        "read_marker": str(plan["dataset"]["read_marker"]),
    }
    raw_lines = artifact_files["samples_ndjson"].read_text(encoding="utf-8").splitlines()
    samples: list[dict[str, Any]] = []
    mixed_samples = 0
    for line in raw_lines:
        sample = json.loads(line)
        expected_identity = (
            sample.get("artifact_id") == artifact.name
            and sample.get("plan_sha256") == plan["plan_sha256"]
            and sample.get("route") == "forced-full"
            and sample.get("width") == 1
            and sample.get("invocation") == summary.get("invocation")
        )
        if not expected_identity:
            mixed_samples += 1
        source_primary = sample.get("primary_performance")
        if not isinstance(source_primary, dict):
            raise BenchmarkError("revalidation sample omitted primary_performance")
        source_checkpoint = source_primary.get("diagnostic_checkpoint")
        source_checkpoint_sample = find_value(source_checkpoint, "sample")
        if not isinstance(source_checkpoint, dict) or not isinstance(source_checkpoint_sample, dict):
            raise BenchmarkError("revalidation source sample omitted its primary checkpoint")
        source_raw_primary_us = source_checkpoint_sample.get("interactive_readiness_us")
        if not finite_number(source_raw_primary_us, positive=True):
            raise BenchmarkError("revalidation source sample primary value is invalid")
        primary = json.loads(json.dumps(source_primary))
        primary["resource_cleanup"] = {
            "resource_failures": resource_failures,
            "cleanup_complete": cleanup_complete,
            "build_unchanged": primary.get("identity", {}).get("build") == build_identity,
        }
        failures = validate_primary_performance(
            primary, "forced-full",
            expected_correlation=sample["correlation_id"],
            expected_session=sample["session_id"],
            expected_context=sample["context_id"],
            expected_scope_context=plan["scope"]["context_id"],
            expected_invocation=sample["invocation"],
            expected_ordinal=sample["ordinal"],
            expected_build=build_identity,
            expected_fixture=expected_fixture,
        )
        checkpoint = primary.get("diagnostic_checkpoint")
        checkpoint_sample = find_value(checkpoint, "sample")
        if not isinstance(checkpoint, dict) or not isinstance(checkpoint_sample, dict):
            raise BenchmarkError("revalidation sample omitted its primary checkpoint")
        revalidated_raw_primary_us = checkpoint_sample.get("interactive_readiness_us")
        if not finite_number(revalidated_raw_primary_us, positive=True):
            raise BenchmarkError("revalidation sample primary value is invalid")
        samples.append({
            "ordinal": sample["ordinal"],
            "warmup": sample["warmup"],
            "correlation_id": sample["correlation_id"],
            "session_id": sample["session_id"],
            "source_record_sha256": sha256_bytes((line + "\n").encode()),
            "checkpoint_sha256": sha256_bytes(canonical_json(source_checkpoint)),
            "revalidated_checkpoint_sha256": sha256_bytes(canonical_json(checkpoint)),
            "raw_primary_ms": float(source_raw_primary_us) / 1000,
            "revalidated_primary_ms": float(revalidated_raw_primary_us) / 1000,
            "primary_valid": not failures,
            "invalid_reasons": failures,
        })
    validate_sample_ordinals(samples, 6)
    if any(item["primary_valid"] is not True for item in samples):
        raise BenchmarkError("one or more forced-full primary samples failed revalidation")

    retained = [item["raw_primary_ms"] for item in samples if item["warmup"] is False]
    revalidated_retained = [
        item["revalidated_primary_ms"] for item in samples if item["warmup"] is False
    ]
    warmup = [item["raw_primary_ms"] for item in samples if item["warmup"] is True]
    source_path = Path(__file__).resolve()
    cwd = Path.cwd().resolve()
    try:
        source_display = str(source_path.relative_to(cwd))
    except ValueError:
        source_display = str(source_path)
    command = " ".join(shlex.quote(item) for item in (
        "python3", source_display, "revalidate-primary",
        "--plan", str(plan_path), "--artifact", str(artifact), "--output", str(output),
    ))
    inputs = {
        "plan_argument": {"path": str(plan_path), "sha256": sha256_bytes(plan_path.read_bytes())},
        **{
            name: {"path": str(path), "sha256": sha256_bytes(path.read_bytes())}
            for name, path in artifact_files.items()
        },
    }
    provenance = {
        "schema_version": SCHEMA_VERSION,
        "kind": "primary-performance-offline-revalidation",
        "validator": {
            "version": PRIMARY_REVALIDATION_VERSION,
            "source_path": source_display,
            "source_sha256": sha256_bytes(source_path.read_bytes()),
        },
        "command": {"cwd": str(cwd), "exact": command},
        "inputs": inputs,
        "artifact": {
            "artifact_id": artifact.name,
            "plan_sha256": plan["plan_sha256"],
            "route": "forced-full",
            "width": 1,
            "invocation": summary["invocation"],
            "build_identity": build_identity,
        },
        "samples": samples,
        "raw_values_ms": {
            "source_warmup": warmup,
            "source_retained": retained,
            "revalidated_retained": revalidated_retained,
        },
        "proof": {
            "plan_content_matches_artifact": artifact_plan == plan,
            "artifact_identity_exact": summary.get("artifact_id") == artifact.name,
            "exact_sample_accounting": len(samples) == 6 and len(warmup) == 1 and len(retained) == 5,
            "checkpoint_hashes_recorded": all(len(item["checkpoint_sha256"]) == 64 for item in samples),
            "source_raw_values_equal_revalidated": retained == revalidated_retained,
            "no_mixed_samples": mixed_samples == 0,
            "cleanup_complete": cleanup_complete,
            "resource_evidence_valid": not resource_failures,
        },
    }
    failures = validate_primary_revalidation_provenance(provenance)
    if failures:
        raise BenchmarkError(f"revalidation provenance failed closed: {failures}")
    save_json(output, provenance, exclusive=True)
    print(output)
    return 0


def is_policy_digest_probe_summary(value: Any) -> bool:
    return (
        isinstance(value, dict)
        and (value.get("kind") == "policy-digest-probe" or value.get("non_aggregatable") is True)
    )


def aggregate_command(args: argparse.Namespace) -> int:
    plan = load_plan(Path(args.plan).expanduser().resolve(strict=True))
    expected_fixture = {
        "base_commit_oid": str(plan["dataset"]["base_commit_oid"]),
        "read_blob_sha256": str(plan["dataset"]["read_blob_sha256"]),
        "read_path": str(plan["dataset"]["read_path"]),
        "search_marker": str(plan["dataset"]["search_marker"]),
        "read_marker": str(plan["dataset"]["read_marker"]),
    }
    samples: list[dict[str, Any]] = []
    correctness: list[dict[str, Any]] = []
    resource_records: dict[str, list[dict[str, Any]]] = {}
    teardown_results: list[bool] = []
    artifacts: list[str] = []
    artifact_paths: set[Path] = set()
    artifact_ids: set[str] = set()
    cohort_invocations: set[tuple[str, str, str, int, int]] = set()
    sample_identities: set[tuple[str, int, str, str, str, int, int, str, str]] = set()
    correlation_ids: set[str] = set()
    session_ids: set[str] = set()
    ordinal_identity_map: dict[tuple[str, int, int], tuple[str, str]] = {}
    for raw in args.artifact:
        artifact = Path(raw).expanduser().resolve(strict=True)
        register_unique(artifact, artifact_paths, "artifact path")
        artifacts.append(str(artifact))
        summary_file = artifact / "summary.json"
        if not summary_file.exists():
            raise BenchmarkError(f"artifact omitted summary.json: {artifact}")
        item = json.loads(summary_file.read_text(encoding="utf-8"))
        if is_policy_digest_probe_summary(item):
            raise BenchmarkError(f"policy-digest-probe artifacts are non-aggregatable: {artifact}")
        if item.get("plan_sha256") != plan["plan_sha256"]:
            raise BenchmarkError(f"artifact summary does not match plan: {artifact}")
        artifact_id = item.get("artifact_id")
        if artifact_id != artifact.name:
            raise BenchmarkError(f"mismatched artifact identity: {artifact}")
        register_unique(artifact_id, artifact_ids, "artifact identity")
        run_fields = ("process_state", "checkout_kind", "route", "width", "invocation")
        is_run = all(item.get(field) is not None for field in run_fields)
        expected_sample_count = 0
        if is_run:
            build_identity = item.get("build_identity")
            if (
                not isinstance(build_identity, dict)
                or set(build_identity) != {
                    "cli_sha256", "app_executable_sha256",
                    "harness_source_sha256", "base_commit_oid",
                }
                or build_identity.get("base_commit_oid") != plan["dataset"]["base_commit_oid"]
                or not isinstance(build_identity.get("cli_sha256"), str)
                or len(build_identity["cli_sha256"]) != 64
            ):
                raise BenchmarkError(f"run artifact omitted exact build identity: {artifact}")
            cohort_invocation = (
                str(item["process_state"]), str(item["checkout_kind"]), str(item["route"]),
                int(item["width"]), int(item["invocation"]),
            )
            register_unique(cohort_invocation, cohort_invocations, "cohort invocation")
            expected_sample_count = int(item.get("expected_sample_count", -1))
            expected_from_groups = (
                int(item.get("warmup_groups", -1)) + int(item.get("retained_groups", -1))
            ) * int(item["width"])
            if expected_sample_count <= 0 or expected_sample_count != expected_from_groups:
                raise BenchmarkError(f"invalid expected sample accounting in {artifact}")
            sample_file = artifact / "samples.ndjson"
            if not sample_file.exists():
                raise BenchmarkError(f"run artifact omitted samples.ndjson: {artifact}")
            artifact_samples: list[dict[str, Any]] = []
            for line in sample_file.read_text(encoding="utf-8").splitlines():
                sample = json.loads(line)
                if sample.get("schema_version") != SCHEMA_VERSION or sample.get("plan_sha256") != plan["plan_sha256"]:
                    raise BenchmarkError(f"sample schema/plan mismatch in {artifact}")
                for field in ("invocation", "width", "ordinal"):
                    if not positive_integer(sample.get(field)):
                        raise BenchmarkError(f"sample {field} must be a positive integer in {artifact}")
                if not isinstance(sample.get("warmup"), bool) or not isinstance(sample.get("valid"), bool):
                    raise BenchmarkError(f"sample warmup/valid flags must be booleans in {artifact}")
                if not isinstance(sample.get("correlation_id"), str) or not isinstance(sample.get("session_id"), str):
                    raise BenchmarkError(f"sample correlation/session IDs must be strings in {artifact}")
                record_correlation = validate_uuid(
                    sample["correlation_id"], "sample record correlation_id"
                )
                record_session = validate_uuid(
                    sample["session_id"], "sample session_id"
                )
                identity = (
                    str(sample.get("artifact_id")), sample["invocation"],
                    str(sample.get("process_state")), str(sample.get("checkout_kind")),
                    str(sample.get("route")), sample["width"],
                    sample["ordinal"], record_correlation, record_session,
                )
                expected_prefix = (
                    artifact_id, int(item["invocation"]), str(item["process_state"]),
                    str(item["checkout_kind"]), str(item["route"]), int(item["width"]),
                )
                if identity[:6] != expected_prefix:
                    raise BenchmarkError(f"mixed sample identity: {identity}")
                primary = sample.get("primary_performance")
                follow_on_acceptance = sample.get("follow_on_acceptance")
                if not isinstance(primary, dict) or not isinstance(follow_on_acceptance, dict):
                    raise BenchmarkError(f"sample omitted split primary/follow-on evidence in {artifact}")
                diagnostic_sample = find_value(primary.get("diagnostic_checkpoint"), "sample")
                if not isinstance(diagnostic_sample, dict):
                    raise BenchmarkError(f"sample omitted primary diagnostic checkpoint in {artifact}")
                correlation_id = validate_uuid(
                    str(diagnostic_sample.get("correlation_id") or ""), "sample correlation_id"
                )
                session_id = record_session
                if correlation_id != record_correlation:
                    raise BenchmarkError(f"sample correlation IDs disagree in {artifact}")
                primary_failures = validate_primary_performance(
                    primary, str(sample["route"]),
                    expected_correlation=correlation_id,
                    expected_session=session_id,
                    expected_context=sample["context_id"],
                    expected_scope_context=plan["scope"]["context_id"],
                    expected_invocation=sample["invocation"],
                    expected_ordinal=sample["ordinal"],
                    expected_build=build_identity,
                    expected_fixture=expected_fixture,
                )
                if sorted(primary_failures) != sorted(primary.get("invalid_reasons") or []):
                    raise BenchmarkError(f"primary validity evidence mismatch in {artifact}")
                if primary.get("valid") is not (not primary_failures):
                    raise BenchmarkError(f"primary valid flag disagrees with evidence in {artifact}")
                follow_on_failures = validate_export(
                    sample["diagnostic"], str(sample["route"]), sample.get("correctness") or {},
                    expected_correlation=correlation_id,
                    expected_session=session_id,
                    expected_invocation=sample["invocation"],
                    expected_ordinal=sample["ordinal"],
                )
                collection = follow_on_acceptance.get("collection")
                if collection != sample.get("follow_on_evidence"):
                    raise BenchmarkError(
                        f"follow-on collection copies disagree in {artifact}"
                    )
                follow_on_failures.extend(
                    f"follow_on_collection:{failure}"
                    for failure in validate_follow_on_collection(collection)
                )
                export_capture = follow_on_acceptance.get("export_capture")
                if isinstance(export_capture, dict) and export_capture.get("ok") is not True:
                    follow_on_failures.append(
                        f"final_export_{export_capture.get('type') or 'failed'}"
                    )
                if sorted(follow_on_failures) != sorted(
                    follow_on_acceptance.get("invalid_reasons") or []
                ):
                    raise BenchmarkError(f"follow-on acceptance evidence mismatch in {artifact}")
                if follow_on_acceptance.get("accepted") is not (not follow_on_failures):
                    raise BenchmarkError(f"follow-on accepted flag disagrees with evidence in {artifact}")
                recomputed_failures = (
                    [f"primary:{reason}" for reason in primary_failures]
                    + [f"follow_on:{reason}" for reason in follow_on_failures]
                )
                if sorted(recomputed_failures) != sorted(sample.get("invalid_reasons") or []):
                    raise BenchmarkError(f"sample validity evidence mismatch in {artifact}")
                if sample["valid"] is not (not recomputed_failures):
                    raise BenchmarkError(f"sample valid flag disagrees with evidence in {artifact}")
                register_unique(identity, sample_identities, "sample identity")
                register_unique(correlation_id, correlation_ids, "sample correlation identity")
                register_unique(session_id, session_ids, "sample session identity")
                ordinal_key = (artifact_id, sample["invocation"], sample["ordinal"])
                if ordinal_key in ordinal_identity_map:
                    raise BenchmarkError(f"duplicate ordinal identity mapping: {ordinal_key}")
                ordinal_identity_map[ordinal_key] = (correlation_id, session_id)
                artifact_samples.append(sample)
            try:
                validate_sample_ordinals(artifact_samples, expected_sample_count)
            except BenchmarkError as error:
                raise BenchmarkError(f"{error} in {artifact}") from error
            samples.extend(artifact_samples)
            key = "/".join(str(item[field]) for field in ("process_state", "checkout_kind", "route", "width"))
            resource_file = artifact / "resources.json"
            if not resource_file.exists():
                raise BenchmarkError(f"run artifact omitted resources.json: {artifact}")
            resource_value = json.loads(resource_file.read_text(encoding="utf-8"))
            metrics_value = find_value(resource_value, "metrics")
            resource_failures = validate_resource_evidence(metrics_value)
            if any(
                (sample.get("primary_performance") or {}).get("resource_cleanup", {}).get(
                    "resource_failures"
                ) != resource_failures
                for sample in artifact_samples
            ):
                raise BenchmarkError(f"sample resource proof disagrees with {artifact}")
            if not resource_failures:
                resource_records.setdefault(key, []).append(metrics_value)
        elif isinstance(item.get("results"), dict):
            correctness.append(item["results"])
        else:
            raise BenchmarkError(f"unsupported artifact kind: {artifact}")
        cleanup_file = artifact / "cleanup.json"
        if not cleanup_file.exists():
            raise BenchmarkError(f"artifact omitted cleanup.json: {artifact}")
        cleanup_value = json.loads(cleanup_file.read_text(encoding="utf-8"))
        entries = [entry for entry in cleanup_value if isinstance(entry, dict)] if isinstance(cleanup_value, list) else []
        expected_cleanup_ok = validate_cleanup_evidence(
            entries, run_artifact=is_run, expected_agent_count=expected_sample_count,
            expected_worktree_count=expected_sample_count if is_run else 2,
        )
        teardown_results.append(expected_cleanup_ok)
        if item.get("cleanup_complete") is not True:
            teardown_results.append(False)
        if is_run:
            actual_cleanup_ok = validate_cleanup_evidence(
                entries, run_artifact=True, expected_agent_count=len(artifact_samples),
                expected_worktree_count=len(artifact_samples),
            )
            if any(
                (sample.get("primary_performance") or {}).get("resource_cleanup", {}).get(
                    "cleanup_complete"
                ) is not actual_cleanup_ok
                for sample in artifact_samples
            ):
                raise BenchmarkError(f"sample cleanup proof disagrees with {artifact}")
            state_file = artifact / "state.json"
            if not state_file.exists():
                raise BenchmarkError(f"run artifact omitted state.json: {artifact}")
            state_value = json.loads(state_file.read_text(encoding="utf-8"))
            state_sessions = state_value.get("sessions", [])
            artifact_session_ids = {str(sample["session_id"]).upper() for sample in artifact_samples}
            teardown_results.append(
                len(state_sessions) == expected_sample_count
                and {str(session.get("session_id", "")).upper() for session in state_sessions}
                == artifact_session_ids
                and all(session.get("terminal") is True for session in state_sessions)
                and state_value.get("memory_stopped") is True
                and state_value.get("route_restored") is True
                and state_value.get("scope_reset") is True
                and state_value.get("benchmark_gate_unchanged") is True
            )
    external_evidence: dict[str, dict[str, Any]] = {}
    for raw in args.evidence or []:
        evidence = json.loads(Path(raw).expanduser().resolve(strict=True).read_text(encoding="utf-8"))
        if evidence.get("schema_version") != SCHEMA_VERSION or evidence.get("plan_sha256") != plan["plan_sha256"]:
            raise BenchmarkError(f"external evidence does not match plan: {raw}")
        scenario = evidence.get("scenario")
        if not isinstance(scenario, str) or scenario in external_evidence:
            raise BenchmarkError(f"duplicate or invalid external evidence scenario: {scenario}")
        external_evidence[scenario] = evidence
    cohorts: dict[str, dict[str, Any]] = {}
    grouped: dict[str, list[dict[str, Any]]] = {}
    for sample in samples:
        key = "/".join(str(sample.get(field)) for field in ("process_state", "checkout_kind", "route", "width"))
        grouped.setdefault(key, []).append(sample)
    for key, members in grouped.items():
        retained = [item for item in members if not item.get("warmup") and item.get("valid")]
        primary_retained = [
            item for item in members
            if not item.get("warmup")
            and (item.get("primary_performance") or {}).get("valid") is True
        ]
        invocation_count = sum(
            1
            for process_state, checkout_kind, route, width, _ in cohort_invocations
            if "/".join((process_state, checkout_kind, route, str(width))) == key
        )
        route_counts: dict[str, int] = {}
        fallback_counts: dict[str, int] = {}
        for item in primary_retained:
            sample_payload = find_value(
                (item.get("primary_performance") or {}).get("diagnostic_checkpoint"),
                "sample",
            )
            if not isinstance(sample_payload, dict):
                continue
            for name, count in (sample_payload.get("route_counts") or {}).items():
                route_counts[name] = route_counts.get(name, 0) + count
            for name, count in (sample_payload.get("fallback_counts") or {}).items():
                fallback_counts[name] = fallback_counts.get(name, 0) + count
        cohorts[key] = {
            "attempted": len(members),
            "invocation_count": invocation_count,
            "valid_retained": len(retained),
            "primary_valid_retained": len(primary_retained),
            "follow_on_accepted_retained": len([
                item for item in members
                if not item.get("warmup")
                and (item.get("follow_on_acceptance") or {}).get("accepted") is True
            ]),
            "invalid_retained": len([item for item in members if not item.get("warmup") and not item.get("valid")]),
            "invalid_attempted": len([item for item in members if not item.get("valid")]),
            "primary_invalid_attempted": len([
                item for item in members
                if (item.get("primary_performance") or {}).get("valid") is not True
            ]),
            "follow_on_failed_attempted": len([
                item for item in members
                if (item.get("follow_on_acceptance") or {}).get("accepted") is not True
            ]),
            "route_counts": route_counts,
            "fallback_counts": fallback_counts,
            "exact_actual_routes": (
                route_counts == {
                    name: count * len(primary_retained)
                    for name, count in EXPECTED_ACTUAL_ROUTE_COUNTS[key.split("/")[2]].items()
                }
                and fallback_counts == {}
            ),
            "metrics": {
                metric: stats(
                    (
                        value
                        for item in (primary_retained if metric in METRICS else retained)
                        if (value := sample_metric_number(item, metric)) is not None
                    ),
                    positive=True,
                    label=f"sample {metric}",
                )
                for metric in ALL_METRICS
            },
            "git_command_count": stats(
                (
                    number
                    for item in retained
                    if (number := diagnostic_number(item, "git", "command_count")) is not None
                ),
                label="Git command count",
            ),
            "git_duration_us": stats(
                (
                    number
                    for item in retained
                    if (number := diagnostic_number(item, "git", "duration_us")) is not None
                ),
                label="Git duration",
            ),
            "filesystem_operation_count": stats(
                (
                    number
                    for item in retained
                    if (number := diagnostic_number(item, "work", "operation_count", "filesystem")) is not None
                ),
                label="filesystem operation count",
            ),
            "filesystem_duration_us": stats(
                (
                    number
                    for item in retained
                    if (number := diagnostic_number(item, "work", "duration_us", "filesystem")) is not None
                ),
                label="filesystem duration",
            ),
            "resources": resource_records.get(key, []),
        }
    gates: dict[str, str] = {}
    improvement_values: list[float] = []
    other_latency_regressions: list[float] = []
    memory_regressions: list[float] = []
    invalid_memory_baseline = False
    expected_comparisons = 0
    expected_memory_comparisons = 0
    states, checkouts, _configured_routes, widths = configured_matrix_variants(plan)
    thresholds = plan["thresholds"]
    primary_improvement = float(thresholds["projected_p95_improvement_minimum"])
    secondary_regression = float(thresholds["other_p95_regression_maximum"])
    memory_regression = float(thresholds["peak_memory_regression_maximum"])
    for state in states:
        for checkout in checkouts:
            for width in widths:
                forced = cohorts.get(f"{state}/{checkout}/forced-full/{width}")
                projected = cohorts.get(f"{state}/{checkout}/projected/{width}")
                expected_comparisons += 1
                ratio = gate_ratio(
                    forced and forced["metrics"]["interactive_readiness_us"]["p95"],
                    projected and projected["metrics"]["interactive_readiness_us"]["p95"],
                )
                if ratio is not None:
                    improvement_values.append(ratio)
                for metric in TOOL_METRICS:
                    forced_p95 = forced and forced["metrics"][metric]["p95"]
                    projected_p95 = projected and projected["metrics"][metric]["p95"]
                    if forced_p95 not in (None, 0) and projected_p95 is not None:
                        other_latency_regressions.append((projected_p95 - forced_p95) / forced_p95)
                forced_resources = (forced or {}).get("resources") or []
                projected_resources = (projected or {}).get("resources") or []
                for memory_metric in (
                    "peak_resident_mb",
                    "final_resident_mb",
                    "peak_physical_footprint_mb",
                    "final_physical_footprint_mb",
                ):
                    expected_memory_comparisons += 1
                    forced_values = [item.get(memory_metric) for item in forced_resources if isinstance(item.get(memory_metric), (int, float))]
                    projected_values = [item.get(memory_metric) for item in projected_resources if isinstance(item.get(memory_metric), (int, float))]
                    regression = absolute_memory_regression(forced_values, projected_values)
                    if regression is not None:
                        memory_regressions.append(regression)
                    elif forced_resources and projected_resources:
                        invalid_memory_baseline = True
    gates[f"projected interactive-readiness p95 improvement >= {primary_improvement:.0%}"] = (
        "pass" if len(improvement_values) == expected_comparisons and min(improvement_values) >= primary_improvement else
        "fail" if len(improvement_values) == expected_comparisons else "incomplete"
    )
    sample_correctness_mismatches = sum(
        1 for sample in samples
        if any(
            str(reason).endswith("content_oracle_mismatch")
            for reason in sample.get("invalid_reasons", [])
        )
    )
    mismatches = sample_correctness_mismatches + sum(
        1 for group in correctness for item in group.values() if not item.get("ok")
    )
    covered_correctness = {
        scenario for group in correctness for scenario, item in group.items() if item.get("ok") is True
    }
    correctness_complete = set(CORRECTNESS_SCENARIOS) <= covered_correctness
    gates["zero correctness mismatches"] = (
        "pass" if correctness_complete and mismatches == 0 else
        "fail" if mismatches else "incomplete"
    )
    invalid = sum(1 for sample in samples if not sample.get("valid"))
    gates["zero invalid attempted samples"] = (
        "pass" if samples and invalid == 0 else "fail" if samples else "incomplete"
    )
    projected_fallbacks = sum(
        1 for sample in samples
        if sample.get("route") == "projected"
        and any(
            str(reason).endswith("unexpected_fallback")
            for reason in sample.get("invalid_reasons", [])
        )
    )
    gates["zero eligible warm fallbacks"] = "pass" if samples and projected_fallbacks == 0 else "fail" if samples else "incomplete"
    expected_secondary_comparisons = len(states) * len(checkouts) * len(widths) * len(TOOL_METRICS)
    gates[f"other p95 regression <= {secondary_regression:.0%}"] = (
        "pass" if len(other_latency_regressions) == expected_secondary_comparisons
        and max(other_latency_regressions) <= secondary_regression else
        "fail" if len(other_latency_regressions) == expected_secondary_comparisons else "incomplete"
    )
    gates[f"peak memory regression <= {memory_regression:.0%}"] = (
        "fail" if invalid_memory_baseline else
        "pass" if len(memory_regressions) == expected_memory_comparisons and max(memory_regressions) <= memory_regression else
        "fail" if len(memory_regressions) == expected_memory_comparisons else "incomplete"
    )
    required_matrix_keys = configured_required_matrix_keys(plan)
    retained_per_series = int(plan["matrix"]["retained_samples_per_series"])
    warmups_per_series = int(plan["matrix"]["warmups_per_series"])
    invocations_per_series = int(plan["matrix"].get("invocations_per_series", 0))
    complete_matrix = required_matrix_keys == set(cohorts) and invocations_per_series > 0 and all(
        cohort_accounting_valid(
            cohorts[key], width=int(key.rsplit("/", 1)[1]),
            warmups=warmups_per_series, retained=retained_per_series,
            invocations=invocations_per_series,
        )
        for key in required_matrix_keys
    )
    gates["complete route/process/checkout/width matrix"] = "pass" if complete_matrix else "incomplete"
    exact_routes_complete = complete_matrix and all(
        cohorts[key]["exact_actual_routes"] is True for key in required_matrix_keys
    )
    gates["exact actual routes and zero fallbacks"] = (
        "pass" if exact_routes_complete else "fail" if complete_matrix else "incomplete"
    )
    attribution_complete = complete_matrix and all(
        cohorts[key]["git_command_count"]["count"] == cohorts[key]["valid_retained"]
        and cohorts[key]["git_duration_us"]["count"] == cohorts[key]["valid_retained"]
        and cohorts[key]["filesystem_operation_count"]["count"] == cohorts[key]["valid_retained"]
        and cohorts[key]["filesystem_duration_us"]["count"] == cohorts[key]["valid_retained"]
        for key in required_matrix_keys
    )
    gates["complete Git/filesystem attribution"] = "pass" if attribution_complete else "incomplete"
    cpu_complete = complete_matrix and all(
        len(cohorts[key]["resources"]) == invocations_per_series
        and all(not validate_resource_evidence(item) for item in cohorts[key]["resources"])
        for key in required_matrix_keys
    )
    gates["complete CPU attribution"] = "pass" if cpu_complete else "incomplete"
    gates["stable owned-resource teardown"] = (
        "pass" if teardown_results and all(teardown_results) else
        "fail" if teardown_results else "incomplete"
    )
    required_external = set(plan["matrix"]["required_external_evidence"])
    failed_external = [
        scenario for scenario, evidence in external_evidence.items()
        if scenario in required_external and evidence.get("status") == "fail"
    ]
    gates["required external process/main-root evidence"] = (
        "fail" if failed_external else
        "pass" if required_external <= {
            scenario for scenario, evidence in external_evidence.items() if evidence.get("status") == "pass"
        } else "incomplete"
    )
    decision = "pass" if gates and all(value == "pass" for value in gates.values()) else "fail" if any(value == "fail" for value in gates.values()) else "incomplete"
    aggregate_id = f"{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-{uuid.uuid4().hex[:8]}"
    summary = {
        "schema_version": SCHEMA_VERSION, "aggregate_id": aggregate_id, "created_at": utc_now(),
        "plan_sha256": plan["plan_sha256"], "decision": decision, "gates": gates,
        "cohorts": cohorts, "correctness": {
            "campaign_count": len(correctness), "mismatch_count": mismatches,
            "covered_scenarios": sorted(covered_correctness),
        },
        "external_evidence": external_evidence,
        "invalid_attempted_samples": invalid,
        "invalid_retained_samples": sum(
            1 for sample in samples if not sample.get("warmup") and not sample.get("valid")
        ),
        "primary_invalid_attempted_samples": sum(
            1 for sample in samples
            if (sample.get("primary_performance") or {}).get("valid") is not True
        ),
        "follow_on_failed_attempted_samples": sum(
            1 for sample in samples
            if (sample.get("follow_on_acceptance") or {}).get("accepted") is not True
        ),
        "identity": {
            "sample_count": len(samples), "unique_correlation_ids": len(correlation_ids),
            "unique_session_ids": len(session_ids),
            "ordinal_mapping_count": len(ordinal_identity_map),
        },
        "artifacts": artifacts,
    }
    output = Path(args.output).expanduser().resolve()
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    save_json(output / "summary.json", summary, exclusive=True)
    section = render_scoreboard(summary)
    secure_write(output / "scoreboard-section.md", section.encode(), exclusive=True)
    if args.append_scoreboard:
        if not args.confirm_append_scoreboard:
            raise BenchmarkError("--append-scoreboard requires --confirm-append-scoreboard")
        scoreboard = Path(args.append_scoreboard).expanduser().resolve(strict=True)
        existing = scoreboard.read_text(encoding="utf-8")
        if aggregate_id in existing:
            raise BenchmarkError("aggregate ID already exists in scoreboard")
        fd = os.open(scoreboard, os.O_WRONLY | os.O_APPEND)
        try:
            os.write(fd, ("\n" + section).encode())
            os.fsync(fd)
        finally:
            os.close(fd)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if decision == "pass" else 2 if decision == "incomplete" else 1


def cleanup_live_worktree_inventory(value: Any) -> list[dict[str, str]]:
    final = benchmark_final_response(value)
    worktrees = final.get("worktrees") if isinstance(final, dict) else None
    if not isinstance(worktrees, list):
        return []
    records: list[dict[str, str]] = []
    for worktree in worktrees:
        if not isinstance(worktree, dict):
            continue
        worktree_id = worktree.get("worktree_id")
        path, branch, head = worktree.get("path"), worktree.get("branch"), worktree.get("head")
        repository_id = find_value(worktree, "repository_id")
        if all(isinstance(item, str) and item for item in (worktree_id, path, branch, head)):
            resolved_path = str(Path(path).resolve(strict=False))
            records.append({
                "worktree_id": worktree_id,
                "path": resolved_path,
                "path_sha256": sha256_bytes(resolved_path.encode()),
                "branch": branch,
                "head": head.lower(),
                "repository_id": repository_id if isinstance(repository_id, str) else "",
            })
    return records


def cleanup_live_worktree_records(value: Any) -> set[tuple[str, str, str, str]]:
    final = benchmark_final_response(value)
    worktrees = final.get("worktrees") if isinstance(final, dict) else None
    if not isinstance(worktrees, list):
        return set()
    records: set[tuple[str, str, str, str]] = set()
    for worktree in worktrees:
        if not isinstance(worktree, dict):
            continue
        worktree_id = worktree.get("worktree_id")
        path, branch, head = worktree.get("path"), worktree.get("branch"), worktree.get("head")
        if all(isinstance(item, str) and item for item in (worktree_id, path, branch, head)):
            records.add((
                worktree_id, str(Path(path).resolve(strict=False)), branch, head.lower(),
            ))
    return records


def cleanup_session_ownership_evidence(
    snapshot: Any,
    *,
    expected_session_id: str,
    expected_context_id: str,
    live_worktrees: set[tuple[str, str, str, str]],
    artifact_name: str,
    plan_commit_oid: str,
) -> dict[str, Any]:
    branch_prefix = safe_name(f"rpce-bench-{artifact_name}") + "-i"
    if not call_succeeded(snapshot):
        return {"ok": False, "reason": "session_poll_failed"}
    try:
        actual_session_id = response_session_id(snapshot).upper()
    except BenchmarkError:
        return {"ok": False, "reason": "session_identity_missing"}
    if actual_session_id != expected_session_id.upper():
        return {"ok": False, "reason": "session_identity_mismatch"}
    actual_context_id = response_context_id(snapshot)
    if (
        not isinstance(actual_context_id, str)
        or actual_context_id.upper() != expected_context_id.upper()
    ):
        return {"ok": False, "reason": "session_context_mismatch"}
    bindings: set[tuple[str, str, str, str]] = set()
    for candidate in structured_json_objects(benchmark_final_response(snapshot)):
        worktree_id = candidate.get("worktree_id")
        path = candidate.get("worktree_root_path")
        branch, head = candidate.get("branch"), candidate.get("head")
        if all(isinstance(item, str) and item for item in (worktree_id, path, branch, head)):
            bindings.add((
                worktree_id, str(Path(path).resolve(strict=False)), branch, head.lower(),
            ))
    if len(bindings) != 1:
        return {"ok": False, "reason": "session_worktree_binding_ambiguous"}
    binding = next(iter(bindings))
    if (
        not binding[2].startswith(branch_prefix)
        or binding[3] != plan_commit_oid.lower()
        or binding not in live_worktrees
    ):
        return {"ok": False, "reason": "session_worktree_not_benchmark_owned"}
    return {
        "ok": True, "session_id": actual_session_id, "worktree_id": binding[0],
        "path": binding[1], "branch": binding[2], "head": binding[3],
        "status": response_status(snapshot), "context_id": actual_context_id,
    }


def cleanup_worktree_ownership_evidence(
    state_item: Any,
    *,
    live_worktrees: set[tuple[str, str, str, str]],
    proven_sessions: list[dict[str, Any]],
    artifact_name: str,
    plan_commit_oid: str,
) -> dict[str, Any]:
    if not isinstance(state_item, dict):
        return {"ok": False, "reason": "invalid_state_worktree"}
    raw_path, raw_branch = state_item.get("path"), state_item.get("branch")
    if not isinstance(raw_path, str) or not isinstance(raw_branch, str):
        return {"ok": False, "reason": "state_worktree_identity_missing"}
    path = str(Path(raw_path).resolve(strict=False))
    branch_prefix = safe_name(f"rpce-bench-{artifact_name}") + "-i"
    live_matches = [
        record for record in live_worktrees
        if record[1] == path and record[2] == raw_branch
        and record[2].startswith(branch_prefix) and record[3] == plan_commit_oid.lower()
    ]
    relationships = {
        (proof.get("worktree_id"), proof.get("path"), proof.get("branch"), proof.get("head"))
        for proof in proven_sessions if proof.get("ok") is True
    }
    if len(live_matches) != 1 or live_matches[0] not in relationships:
        return {"ok": False, "reason": "live_session_worktree_relationship_unproven"}
    match = live_matches[0]
    return {
        "ok": True, "worktree_id": match[0], "path": match[1],
        "branch": match[2], "head": match[3],
    }


DRAIN_ZERO_COUNT_FIELDS = (
    "installed_token_count", "provisional_token_count", "root_claim_count",
    "path_reservation_count", "matching_live_root_count",
    "matching_watcher_attachment_count", "pending_seeded_root_count",
    "pending_visibility_waiter_count", "queued_publication_count",
    "applying_publication_count", "outstanding_publication_count",
    "publisher_waiter_count", "unloading_root_count", "reserved_load_flight_count",
)


def valid_drain_snapshot(value: Any) -> bool:
    return (
        isinstance(value, dict)
        and value.get("is_drained") is True
        and value.get("contains_paths") is False
        and all(value.get(field) == 0 for field in DRAIN_ZERO_COUNT_FIELDS)
    )


def required_cleanup_worktree_inventory(response: Any) -> list[dict[str, Any]]:
    if not call_succeeded(response):
        raise BenchmarkError("status-free worktree inventory failed")
    return cleanup_live_worktree_inventory(response)


def cleanup_benchmark_attempts(
    runner: CLIRunner,
    plan: dict[str, Any],
    state: dict[str, Any],
    artifact_name: str,
) -> list[dict[str, Any]]:
    """Fail-closed logical-release-before-physical-removal cleanup for armed starts."""
    actions: list[dict[str, Any]] = []
    attempts = [item for item in state.get("attempts", []) if isinstance(item, dict)]
    inventory_response = runner.call(
        "cleanup-live-worktrees", "manage_worktree",
        {"op": "list", "repo_root": plan["scope"]["root_path"]},
        check=False, timeout=30,
    )
    inventory = cleanup_live_worktree_inventory(inventory_response) if call_succeeded(inventory_response) else []
    inventory_ok = call_succeeded(inventory_response)
    logical_safe = inventory_ok

    for attempt in attempts:
        correlation = attempt.get("correlation_id")
        control_id = attempt.get("control_id") or state.get("control_id")
        if not isinstance(correlation, str) or not isinstance(control_id, str):
            attempt["manual_cleanup"] = True
            attempt["cleanup_reason"] = "missing_recovery_identity"
            logical_safe = False
            continue
        attempt["control_id"] = control_id
        common = diagnostic_payload(
            plan, "start_recovery_snapshot", correlation_id=correlation,
            control_id=control_id,
        )
        try:
            snapshot_response = runner.call(
                f"cleanup-recovery-{attempt.get('ordinal')}", DEBUG_TOOL,
                common, check=False, timeout=15,
            )
            recovery = nested_response_object(snapshot_response, "recovery") if call_succeeded(snapshot_response) else {}
            abort_response = runner.call(
                f"cleanup-abort-{attempt.get('ordinal')}", DEBUG_TOOL,
                diagnostic_payload(
                    plan, "start_recovery_abort", correlation_id=correlation,
                    control_id=control_id,
                ),
                check=False, timeout=15,
            )
            if call_succeeded(abort_response):
                recovery = nested_response_object(abort_response, "recovery")
            else:
                raise BenchmarkError("recoverable-start abort failed")
        except BaseException as error:
            attempt["manual_cleanup"] = True
            attempt["cleanup_reason"] = f"recovery_failed:{operation_failure_type(error)}"
            logical_safe = False
            continue

        expected = {
            "worktree_id": recovery.get("worktree_id"),
            "branch": recovery.get("branch"),
            "head": str(recovery.get("head") or "").lower(),
            "repository_id": recovery.get("repository_id"),
            "path_sha256": recovery.get("worktree_path_sha256"),
        }
        matches = [item for item in inventory if all(
            not expected[key] or item.get(key) == expected[key]
            for key in expected
        )]
        if expected["worktree_id"] and len(matches) != 1:
            attempt["manual_cleanup"] = True
            attempt["cleanup_reason"] = "ambiguous_status_free_inventory"
            logical_safe = False
            continue
        matched = matches[0] if matches else None
        if matched:
            attempt.update({
                "worktree_id": matched["worktree_id"], "path": matched["path"],
                "path_sha256": matched["path_sha256"], "branch": matched["branch"],
                "head": matched["head"], "repository_id": matched["repository_id"],
            })
        session_id = recovery.get("agent_session_id")
        context_id = recovery.get("target_tab_id")
        requires_cancel = find_value(abort_response, "requires_agent_cancel") is True
        discard_completed = find_value(abort_response, "discard_completed") is True
        terminal = discard_completed
        status = "discarded" if discard_completed else None
        if requires_cancel and isinstance(session_id, str) and isinstance(context_id, str):
            try:
                status = terminalize(runner, session_id, context_id)
                terminal = status in TERMINAL_STATES
            except BaseException as error:
                status = f"cleanup_error:{operation_failure_type(error)}"
        actions.append({
            "action": "terminalize_agent",
            "session_id_sha256": sha256_bytes(str(session_id).encode()),
            "status": status, "terminal": terminal,
            "ownership_proven": isinstance(session_id, str),
        })
        if not terminal or not isinstance(session_id, str):
            attempt["manual_cleanup"] = True
            attempt["cleanup_reason"] = "agent_not_terminal"
            logical_safe = False
            continue
        attempt["session_id"], attempt["context_id"] = session_id, context_id
        if not discard_completed:
            unbind = runner.call(
                f"cleanup-unbind-{attempt.get('ordinal')}", "manage_worktree",
                {"op": "unbind", "session_id": session_id, "all": True},
                check=False, timeout=30,
            )
            actions.append({
                "action": "unbind_session_worktree",
                "session_id_sha256": sha256_bytes(session_id.encode()),
                "ok": call_succeeded(unbind),
            })
            if not call_succeeded(unbind):
                attempt["manual_cleanup"] = True
                attempt["cleanup_reason"] = "unbind_failed"
                logical_safe = False
                continue
        drain_response = runner.call(
            f"cleanup-drain-{attempt.get('ordinal')}", DEBUG_TOOL,
            diagnostic_payload(
                plan, "session_worktree_drain_snapshot", correlation_id=correlation,
                control_id=control_id,
            ),
            check=False, timeout=15,
        )
        drain = nested_response_object(drain_response, "drain") if call_succeeded(drain_response) else {}
        attempt["drain"] = drain
        attempt["drained"] = valid_drain_snapshot(drain)
        actions.append({
            "action": "prove_session_worktree_drain",
            "session_id_sha256": sha256_bytes(session_id.encode()),
            "ok": attempt["drained"], "drain": drain,
        })
        if not attempt["drained"]:
            attempt["manual_cleanup"] = True
            attempt["cleanup_reason"] = "store_not_drained"
            logical_safe = False

    if logical_safe:
        for attempt in attempts:
            path = attempt.get("path")
            branch = attempt.get("branch")
            if not isinstance(path, str) or not isinstance(branch, str):
                continue
            actions.append(clean_owned_worktree(
                Path(plan["scope"]["root_path"]), path, True,
                expected_branch=branch, expected_path=path,
                expected_head=plan["dataset"]["base_commit_oid"], ownership_proven=True,
            ))

    final_inventory_response = runner.call(
        "cleanup-final-live-worktrees", "manage_worktree",
        {"op": "list", "repo_root": plan["scope"]["root_path"]},
        check=False, timeout=30,
    )
    try:
        final_inventory = required_cleanup_worktree_inventory(final_inventory_response)
    except BenchmarkError:
        final_inventory = None
        logical_safe = False
        for attempt in attempts:
            attempt["manual_cleanup"] = True
            attempt["cleanup_reason"] = "final_status_free_inventory_failed"
    for attempt in attempts:
        path_digest = attempt.get("path_sha256")
        correlation, control_id = attempt.get("correlation_id"), attempt.get("control_id")
        absent = (
            final_inventory is not None
            and isinstance(path_digest, str)
            and not any(item["path_sha256"] == path_digest for item in final_inventory)
        )
        final_drain: dict[str, Any] = {}
        if isinstance(correlation, str) and isinstance(control_id, str):
            response = runner.call(
                f"cleanup-final-drain-{attempt.get('ordinal')}", DEBUG_TOOL,
                diagnostic_payload(
                    plan, "session_worktree_drain_snapshot", correlation_id=correlation,
                    control_id=control_id,
                ),
                check=False, timeout=15,
            )
            final_drain = nested_response_object(response, "drain") if call_succeeded(response) else {}
        attempt["final_absent"] = absent
        attempt["final_drain"] = final_drain
        actions.append({
            "action": "final_session_worktree_proof",
            "path_sha256": path_digest,
            "worktree_absent": absent,
            "drain": final_drain,
            "ok": attempt.get("path") is None
                or (absent and valid_drain_snapshot(final_drain)),
        })
        if attempt.get("path") is not None and (not absent or not valid_drain_snapshot(final_drain)):
            attempt["manual_cleanup"] = True
            logical_safe = False
    state["attempts"] = attempts
    state["cleanup_manual_required"] = not logical_safe
    return actions


def cleanup_command(args: argparse.Namespace) -> int:
    if not args.confirm_live_debug_app or not args.confirm_owned_resources:
        raise BenchmarkError("cleanup requires live-app and owned-resource confirmations")
    artifact = Path(args.artifact).expanduser().resolve(strict=True)
    state = json.loads((artifact / "state.json").read_text(encoding="utf-8"))
    plan = load_plan(artifact / "plan.json")
    cli = resolve_cli(args.cli)
    root = Path(plan["scope"]["root_path"])
    runner = CLIRunner(
        cli, plan["scope"]["window_id"], plan["scope"]["context_id"], root, artifact
    )
    verify_disposable_target(runner, plan, require_only_planned_root=False)
    plan_commit_oid = plan["dataset"].get("base_commit_oid")
    if not isinstance(plan_commit_oid, str) or re.fullmatch(r"[0-9a-f]{40,64}", plan_commit_oid) is None:
        raise BenchmarkError("cleanup plan omitted a valid immutable base commit OID")
    worktree_inventory = runner.call(
        "cleanup-live-worktrees", "manage_worktree",
        {"op": "list", "repo_root": str(root)}, check=False, timeout=30,
    )
    live_worktrees = (
        cleanup_live_worktree_records(worktree_inventory) if call_succeeded(worktree_inventory) else set()
    )
    actions: list[dict[str, Any]] = []
    if state.get("attempts"):
        actions.extend(cleanup_benchmark_attempts(runner, plan, state, artifact.name))
    if state.get("kind") == "codemap-gate":
        for hold in state.get("codemap_holds", []):
            if not isinstance(hold, dict) or hold.get("released") is True:
                continue
            hold_id = hold.get("hold_id")
            response = runner.call(
                f"cleanup-release-codemap-hold-{str(hold_id)[:8]}", DEBUG_TOOL,
                diagnostic_payload(
                    plan, "codemap_projection_hold_release", hold_id=hold_id,
                    **({"target_root_id": hold.get("target_root_id")}
                       if isinstance(hold.get("target_root_id"), str) else {}),
                ),
                check=False,
            ) if isinstance(hold_id, str) else {}
            released_or_expired = (
                call_succeeded(response)
                and (find_value(response, "released") is True or find_value(response, "hold_count") == 0)
            )
            hold["released"] = released_or_expired
            actions.append({
                "action": "release_codemap_hold",
                "hold_id_sha256": sha256_bytes(str(hold_id).encode()),
                "ok": released_or_expired,
            })

    session_proofs: list[dict[str, Any]] = []
    for session in ([] if state.get("attempts") else state.get("sessions", [])):
        session_id = session.get("session_id") if isinstance(session, dict) else None
        context_id = session.get("context_id") if isinstance(session, dict) else None
        try:
            routed_context_id = (
                validate_uuid(context_id, "cleanup session context-id")
                if isinstance(context_id, str) else None
            )
        except BenchmarkError:
            routed_context_id = None
        snapshot = (
            runner.call(
                f"cleanup-prove-session-{str(session_id)[:8]}", "agent_run",
                {"op": "poll", "session_id": session_id}, check=False,
                context_id=routed_context_id,
            )
            if isinstance(session_id, str) and routed_context_id is not None else {}
        )
        proof = cleanup_session_ownership_evidence(
            snapshot, expected_session_id=str(session_id or ""),
            expected_context_id=str(context_id or ""), live_worktrees=live_worktrees,
            artifact_name=artifact.name, plan_commit_oid=plan_commit_oid,
        )
        session_proofs.append(proof)
        if not proof["ok"]:
            if isinstance(session, dict):
                session["terminal"] = False
            actions.append({
                "action": "terminalize_agent",
                "session_id_sha256": sha256_bytes(str(session_id).encode()),
                "terminal": False, "ownership_proven": False,
                "manual_cleanup": True, "reason": proof["reason"],
            })
            continue
        live_status = str(proof["status"])
        status = (
            live_status if live_status in TERMINAL_STATES
            else terminalize(runner, session_id, context_id)
        )
        session["status"], session["terminal"] = status, status in TERMINAL_STATES
        actions.append({
            "action": "terminalize_agent",
            "session_id_sha256": sha256_bytes(str(session["session_id"]).encode()),
            "status": status, "terminal": session["terminal"], "ownership_proven": True,
        })
    if state.get("kind") == "codemap-gate":
        inventory = runner.call(
            "cleanup-codemap-workspace-inventory", "manage_workspaces",
            {"action": "list", "include_hidden": True}, check=False,
        )
        current_roots = set()
        if call_succeeded(inventory):
            current_roots = set(workspace_root_paths(
                workspace_inventory_record(inventory, plan["scope"]["workspace_id"])
            ))
        all_recorded_agents_terminal = all(
            isinstance(item, dict) and item.get("terminal") is True
            for item in state.get("sessions", [])
        )
        remaining_added_roots: list[dict[str, Any]] = []
        for item in state.get("added_roots", []):
            if not isinstance(item, dict) or not isinstance(item.get("path"), str):
                actions.append({
                    "action": "remove_workspace_root", "ok": False,
                    "manual_cleanup": True, "reason": "invalid_owned_root_record",
                })
                continue
            candidate = Path(item["path"]).resolve()
            root_proof: dict[str, Any]
            if item.get("kind") == "non-git":
                ownership_proven = validate_codemap_temp_ownership_marker(
                    item,
                    artifact_id=artifact.name,
                    plan_sha256=plan["plan_sha256"],
                )
                root_proof = {
                    "ok": ownership_proven,
                    "basis": "live_exclusive_non_git_marker",
                }
            elif item.get("kind") == "git-worktree":
                state_matches = [
                    worktree for worktree in state.get("worktrees", [])
                    if isinstance(worktree, dict)
                    and isinstance(worktree.get("path"), str)
                    and Path(worktree["path"]).resolve() == candidate
                ]
                root_proof = (
                    cleanup_worktree_ownership_evidence(
                        state_matches[0], live_worktrees=live_worktrees,
                        proven_sessions=session_proofs, artifact_name=artifact.name,
                        plan_commit_oid=plan_commit_oid,
                    )
                    if len(state_matches) == 1
                    else {"ok": False, "reason": "state_worktree_identity_ambiguous"}
                )
                ownership_proven = root_proof.get("ok") is True
            else:
                ownership_proven = False
                root_proof = {"ok": False, "reason": "unsupported_owned_root_kind"}
            if not ownership_proven or not all_recorded_agents_terminal:
                reason = "ownership_not_proven" if not ownership_proven else "agents_not_terminal"
                actions.append({
                    "action": "remove_workspace_root",
                    "path_sha256": sha256_bytes(str(candidate).encode()), "ok": False,
                    "manual_cleanup": True, "reason": reason,
                })
                remaining_added_roots.append(item)
                continue
            if str(candidate) not in current_roots:
                actions.append({
                    "action": "remove_workspace_root",
                    "path_sha256": sha256_bytes(str(candidate).encode()),
                    "ok": True, "reason": "already_absent",
                })
                continue
            response = runner.call(
                f"cleanup-codemap-root-{safe_name(candidate.name)}", "manage_workspaces",
                {"action": "remove_folder", "workspace": plan["scope"]["workspace_id"],
                 "folder_path": str(candidate), "window_id": plan["scope"]["window_id"]},
                check=False,
            )
            ok = call_succeeded(response)
            actions.append({
                "action": "remove_workspace_root",
                "path_sha256": sha256_bytes(str(candidate).encode()), "ok": ok,
                "ownership_proven": True,
                "ownership_basis": (
                    "live_cleanup_worktree_ownership_evidence"
                    if item.get("kind") == "git-worktree"
                    else "live_exclusive_non_git_marker"
                ),
                "ownership_proof_sha256": sha256_bytes(canonical_json(root_proof)),
            })
            if ok and item.get("kind") == "non-git":
                shutil.rmtree(candidate, ignore_errors=True)
            if not ok:
                remaining_added_roots.append(item)
        state["added_roots"] = remaining_added_roots
    memory_action = verify_resumed_memory_sampler_inactive(
        runner,
        expected_session_id=state.get("memory_session_id"),
        expected_label=artifact.name,
    )
    state["memory_stopped"] = memory_action["verified_stopped"]
    actions.append(memory_action)
    control = state.get("control_id")
    if control and not state.get("route_restored"):
        response = runner.call(
            "cleanup-restore-route", DEBUG_TOOL,
            diagnostic_payload(plan, "restore_flags", control_id=control), check=False,
        )
        state["route_restored"] = call_succeeded(response)
    actions.append({"action": "restore_route", "ok": state.get("route_restored") is True})
    if not state.get("scope_reset"):
        reset = runner.call(
            "cleanup-reset", DEBUG_TOOL, diagnostic_payload(plan, "reset"), check=False
        )
        state["scope_reset"] = call_succeeded(reset) and isinstance(find_value(reset, "reset"), dict)
    actions.append({"action": "reset_diagnostics", "ok": state.get("scope_reset") is True})
    try:
        require_benchmark_gate(runner)
        state["benchmark_gate_unchanged"] = True
    except BenchmarkError:
        state["benchmark_gate_unchanged"] = False
    actions.append({
        "action": "preserve_benchmark_setting", "ok": state["benchmark_gate_unchanged"],
    })
    for item in ([] if state.get("attempts") else state.get("worktrees", [])):
        proof = cleanup_worktree_ownership_evidence(
            item, live_worktrees=live_worktrees, proven_sessions=session_proofs,
            artifact_name=artifact.name, plan_commit_oid=plan_commit_oid,
        )
        if not proof["ok"]:
            item_path = item.get("path") if isinstance(item, dict) else None
            item_branch = item.get("branch") if isinstance(item, dict) else None
            actions.append({
                "action": "remove_worktree",
                "path_sha256": (
                    sha256_bytes(str(item_path).encode()) if isinstance(item_path, str) else None
                ),
                "branch_sha256": (
                    sha256_bytes(item_branch.encode()) if isinstance(item_branch, str) else None
                ),
                "removed": False, "ownership_proven": False, "manual_cleanup": True,
                "reason": proof["reason"],
            })
            continue
        actions.append(clean_owned_worktree(
            root, proof["path"], all(session.get("terminal") for session in state.get("sessions", [])),
            expected_branch=proof["branch"], expected_path=proof["path"],
            expected_head=plan_commit_oid, ownership_proven=True,
        ))
    final_roots_restored = False
    try:
        verify_disposable_target(runner, plan, require_only_planned_root=True)
        final_roots_restored = True
    except BenchmarkError:
        pass
    actions.append({"action": "restore_workspace_roots", "ok": final_roots_restored})
    cleanup_evidence_complete = validate_cleanup_evidence(
        actions, run_artifact=True,
        expected_agent_count=(
            len(state.get("attempts", [])) if state.get("attempts")
            else len(state.get("sessions", []))
        ),
        expected_worktree_count=(
            len({
                item.get("path") for item in state.get("attempts", [])
                if isinstance(item, dict) and isinstance(item.get("path"), str)
            }) if state.get("attempts") else len(state.get("worktrees", []))
        ),
    )
    cleanup_complete = cleanup_command_acceptance(
        cleanup_evidence_complete,
        state,
    )
    state["cleanup_complete"] = cleanup_complete
    save_cleanup_proof(artifact / "cleanup.json", actions)
    save_json(artifact / "state.json", state)
    print(json.dumps(actions, indent=2, sort_keys=True))
    return 0 if cleanup_complete else 1


def require_exact_projected_inference_identity(
    summary: dict[str, Any],
    projected_plan: dict[str, Any],
    plan: dict[str, Any],
    *,
    artifact_id: str,
    expected_build: dict[str, str],
) -> None:
    if (
        summary.get("artifact_id") != artifact_id
        or summary.get("plan_sha256") != plan.get("plan_sha256")
        or summary.get("build_identity") != expected_build
        or projected_plan != plan
    ):
        raise BenchmarkError("projected prerequisite plan/root/build identity was not exact")


def require_exact_projected_inference_cohort(
    summary: dict[str, Any],
    samples: list[dict[str, Any]],
    *,
    artifact_id: str,
    plan_sha256: str,
    expected_build: dict[str, str],
) -> None:
    invocation = summary.get("invocation")
    exact_summary = {
        "status": "completed",
        "artifact_id": artifact_id,
        "plan_sha256": plan_sha256,
        "build_identity": expected_build,
        "process_state": "warm",
        "checkout_kind": "linked-worktree",
        "route": "projected",
        "width": 1,
        "warmup_groups": 1,
        "retained_groups": FIXED_RETAINED_SAMPLES,
        "expected_sample_count": 1 + FIXED_RETAINED_SAMPLES,
        "sample_count": 1 + FIXED_RETAINED_SAMPLES,
        "valid_retained_count": FIXED_RETAINED_SAMPLES,
        "primary_valid_retained_count": FIXED_RETAINED_SAMPLES,
        "follow_on_accepted_retained_count": FIXED_RETAINED_SAMPLES,
        "invalid_count": 0,
        "operational_error": None,
        "cleanup_complete": True,
    }
    if (
        not positive_integer(invocation)
        or any(summary.get(key) != value for key, value in exact_summary.items())
        or len(samples) != 1 + FIXED_RETAINED_SAMPLES
    ):
        raise BenchmarkError("projected prerequisite cohort summary was not exact")
    for index, sample in enumerate(samples, start=1):
        primary = sample.get("primary_performance")
        checkpoint = primary.get("diagnostic_checkpoint") if isinstance(primary, dict) else None
        diagnostic_sample = checkpoint.get("sample") if isinstance(checkpoint, dict) else None
        identity = primary.get("identity") if isinstance(primary, dict) else None
        follow_on = sample.get("follow_on_acceptance")
        if (
            sample.get("artifact_id") != artifact_id
            or sample.get("plan_sha256") != plan_sha256
            or sample.get("process_state") != "warm"
            or sample.get("checkout_kind") != "linked-worktree"
            or sample.get("route") != "projected"
            or sample.get("width") != 1
            or sample.get("invocation") != invocation
            or sample.get("ordinal") != index
            or sample.get("warmup") is not (index == 1)
            or sample.get("valid") is not True
            or sample.get("invalid_reasons") != []
            or not isinstance(primary, dict)
            or primary.get("valid") is not True
            or not isinstance(follow_on, dict)
            or follow_on.get("accepted") is not True
            or not isinstance(identity, dict)
            or identity.get("build") != expected_build
            or identity.get("invocation") != invocation
            or identity.get("ordinal") != index
            or not isinstance(diagnostic_sample, dict)
            or diagnostic_sample.get("invocation") != invocation
            or diagnostic_sample.get("ordinal") != index
            or diagnostic_sample.get("route_counts") != expected_actual_route_counts("projected")
            or diagnostic_sample.get("fallback_counts") != {}
        ):
            raise BenchmarkError("projected prerequisite sample identity/routes/fallbacks were not exact")


def projected_inference_prerequisite(
    projected: Path,
    plan: dict[str, Any],
    cli: Path,
) -> dict[str, Any]:
    required_files = ("summary.json", "plan.json", "samples.ndjson", "resources.json", "cleanup.json")
    files = {name: projected / name for name in required_files}
    if not all(path.is_file() for path in files.values()):
        raise BenchmarkError("projected prerequisite omitted a required artifact file")
    projected_summary = json.loads(files["summary.json"].read_text(encoding="utf-8"))
    projected_plan = load_plan(files["plan.json"])
    samples: list[dict[str, Any]] = []
    for line in files["samples.ndjson"].read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        value = json.loads(line)
        if not isinstance(value, dict):
            raise BenchmarkError("projected prerequisite sample was not an object")
        samples.append(value)
    expected_build = exact_live_build_identity(cli, plan)
    require_exact_projected_inference_identity(
        projected_summary,
        projected_plan,
        plan,
        artifact_id=projected.name,
        expected_build=expected_build,
    )
    require_exact_projected_inference_cohort(
        projected_summary,
        samples,
        artifact_id=projected.name,
        plan_sha256=plan["plan_sha256"],
        expected_build=expected_build,
    )
    scope = plan["scope"]
    root_identity = {
        key: scope[key]
        for key in ("window_id", "workspace_id", "context_id", "root_id", "root_path")
    }
    return {
        "artifact_id": projected.name,
        "plan_sha256": plan["plan_sha256"],
        "build_identity": expected_build,
        "root_identity": root_identity,
        "root_identity_sha256": sha256_bytes(canonical_json(root_identity)),
        "artifact_sha256": {
            name: sha256_bytes(path.read_bytes()) for name, path in sorted(files.items())
        },
    }


def live_inference_gate_command(args: argparse.Namespace) -> int:
    if not args.confirm_live_debug_app or not args.confirm_owned_resources:
        raise BenchmarkError("live-inference-gate requires live-app and owned-resource confirmations")
    plan = load_plan(Path(args.plan))
    cli = resolve_cli(args.cli)
    root = Path(plan["scope"]["root_path"])
    validate_planned_base_commit(plan, root)
    projected = Path(args.projected_artifact).expanduser().resolve(strict=True)
    prerequisite = projected_inference_prerequisite(projected, plan, cli)
    artifact = make_artifact(Path(args.output_root), "live-inference-gate")
    runner = CLIRunner(
        cli, plan["scope"]["window_id"], plan["scope"]["context_id"], root, artifact
    )
    save_json(artifact / "plan.json", plan, exclusive=True)
    state: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION, "plan_sha256": plan["plan_sha256"],
        "kind": "live-inference-gate", "sessions": [], "worktrees": [],
        "attempts": [], "control_id": None, "route_restored": False,
        "scope_reset": False, "projected_prerequisite": prerequisite,
    }
    save_json(artifact / "state.json", state)
    verify_scope(runner, plan)
    require_benchmark_gate(runner)
    verify_disposable_target(runner, plan, require_only_planned_root=True)
    control_id: str | None = None
    result: dict[str, Any] = {
        "ok": False,
        "projected_prerequisite": prerequisite,
    }
    cleanup: list[dict[str, Any]] = []
    try:
        control_id, _ = set_route(runner, plan, "projected")
        state["control_id"] = control_id
        branch = safe_name(f"rpce-bench-{artifact.name}-i1-o1")[:120]
        token, correlation = arm_sample(
            runner, plan, control_id, "projected", "warm", 1, 1, False, branch
        )
        attempt = {
            "correlation_id": correlation, "control_id": control_id,
            "invocation": 1, "ordinal": 1, "warmup": False,
            "branch": branch, "expected_head": plan["dataset"]["base_commit_oid"],
            "state": "armed", "session_id": None, "context_id": None,
            "worktree_id": None, "path": None,
        }
        state["attempts"].append(attempt)
        save_json(artifact / "state.json", state)
        sentinel = "RPCE_LIVE_INFERENCE_FILE_TOOLS_OK"
        message = (
            "Use exactly two tools in this order and no others. First call file_search with "
            f"pattern {plan['dataset']['search_marker']!r}, regex false, and filter.paths exactly "
            f"[{plan['dataset']['read_path']!r}]. Then call read_file with path exactly "
            f"{plan['dataset']['read_path']!r}. Do not use shell, edits, delegation, or any other tool. "
            f"After both results, reply exactly {sentinel}."
        )
        start = runner.call(
            "live-inference-start", "agent_run",
            {
                "op": "start", "detach": True, "message": message,
                "session_name": "RPCE live inference gate",
                "worktree_create": True, "worktree_branch": branch,
                "worktree_base_ref": plan["dataset"]["base_commit_oid"],
                "worktree_label": "RPCE live inference gate",
                "context_id": plan["scope"]["context_id"],
                "_worktree_startup_benchmark_token": token,
            },
            timeout=180,
        )
        session_id, context_id = response_session_id(start), response_context_id(start)
        if not isinstance(context_id, str):
            raise BenchmarkError("live inference start omitted child context")
        owned_worktree = discover_owned_worktree(start, root, branch)
        worktree_id, bound_path = exact_response_worktree_binding(start, owned_worktree)
        if bound_path != str(owned_worktree):
            raise BenchmarkError("live inference worktree binding mismatch")
        attempt.update({
            "state": "started", "session_id": session_id, "context_id": context_id,
            "worktree_id": worktree_id, "path": str(owned_worktree),
            "path_sha256": sha256_bytes(str(owned_worktree).encode()),
        })
        state["sessions"].append({
            "session_id": session_id, "context_id": context_id, "terminal": False,
        })
        state["worktrees"].append({
            "path": str(owned_worktree), "worktree_id": worktree_id,
            "owned": True, "branch": branch,
        })
        save_json(artifact / "state.json", state)
        transcript = wait_agent_success(
            runner, session_id, expected_output=sentinel,
            expected_marker=plan["dataset"]["search_marker"],
            expected_file_path=plan["dataset"]["read_path"],
            context_id=context_id,
            expected_pairs=1,
            strict_result_expectations={
                "root_id": plan["scope"]["root_id"],
                "root_path": plan["scope"]["root_path"],
                "root_type": "primary_workspace",
                "worktree_id": worktree_id,
                "worktree_path": str(owned_worktree),
                "read_marker": plan["dataset"]["read_marker"],
            },
        )
        correctness, direct, _ = first_search_read(
            runner, plan, correlation, context_id, owned_worktree, worktree_id
        )
        export, capture = capture_diagnostic(
            runner, plan, correlation, action="export", label="live-inference-export"
        )
        sample = export.get("sample") if isinstance(export, dict) else None
        identity_ok = isinstance(sample, dict) and all((
            str(sample.get("correlation_id", "")).upper() == correlation.upper(),
            str(sample.get("agent_session_id", "")).upper() == session_id.upper(),
            sample.get("invocation") == 1, sample.get("ordinal") == 1,
            sample.get("route_counts") == {"diffSeedServing": 1},
            sample.get("fallback_counts") == {},
        ))
        result = {
            "ok": transcript.get("ok") is True
                and correctness == {"search": True, "read": True}
                and direct.get("search", {}).get("ok") is True
                and direct.get("read", {}).get("ok") is True
                and capture.get("ok") is True and identity_ok,
            "transcript": transcript,
            "direct_bound_probes": direct,
            "diagnostic_identity_valid": identity_ok,
            "assistant_prose_accepted_as_evidence": False,
        }
    finally:
        cleanup.extend(cleanup_benchmark_attempts(runner, plan, state, artifact.name))
        if control_id is not None:
            restored = runner.call(
                "live-inference-restore", DEBUG_TOOL,
                diagnostic_payload(plan, "restore_flags", control_id=control_id), check=False,
            )
            state["route_restored"] = call_succeeded(restored)
        reset = runner.call(
            "live-inference-reset", DEBUG_TOOL, diagnostic_payload(plan, "reset"), check=False
        )
        state["scope_reset"] = call_succeeded(reset)
        sampler_cleanup = verify_resumed_memory_sampler_inactive(
            runner,
            expected_session_id=None,
            expected_label=artifact.name,
        )
        try:
            require_benchmark_gate(runner)
            state["benchmark_gate_unchanged"] = True
        except BenchmarkError:
            state["benchmark_gate_unchanged"] = False
        roots_restored = False
        try:
            verify_disposable_target(runner, plan, require_only_planned_root=True)
            roots_restored = True
        except BenchmarkError:
            pass
        cleanup.extend([
            sampler_cleanup,
            {"action": "restore_route", "ok": state["route_restored"]},
            {"action": "reset_diagnostics", "ok": state["scope_reset"]},
            {
                "action": "preserve_benchmark_setting",
                "ok": state["benchmark_gate_unchanged"],
            },
            {"action": "restore_workspace_roots", "ok": roots_restored},
        ])
        cleanup_complete = validate_cleanup_evidence(
            cleanup,
            run_artifact=True,
            expected_agent_count=len(state.get("attempts", [])),
            expected_worktree_count=len({
                item.get("path")
                for item in state.get("attempts", [])
                if isinstance(item, dict) and isinstance(item.get("path"), str)
            }),
        )
        state["cleanup_manual_required"] = (
            state.get("cleanup_manual_required", False) or not cleanup_complete
        )
        save_cleanup_proof(artifact / "cleanup.json", cleanup)
        save_json(artifact / "state.json", state)
    result["cleanup_complete"] = not state.get("cleanup_manual_required", True)
    result["artifact_directory"] = str(artifact)
    result["ok"] = result.get("ok") is True and result["cleanup_complete"]
    save_json(artifact / "summary.json", result, exclusive=True)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["ok"] else 1


def add_live_common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--plan", required=True)
    parser.add_argument("--cli")
    parser.add_argument("--output-root", default=DEFAULT_OUTPUT_ROOT)
    parser.add_argument("--confirm-live-debug-app", action="store_true")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    marker = sub.add_parser("create-marker", help="create the exclusive disposable-root ownership marker offline")
    marker.add_argument("--root-path", required=True)
    marker.add_argument("--workspace-id", required=True)
    marker.add_argument("--root-id", required=True)
    marker.add_argument("--owner-token", required=True)
    marker.add_argument("--confirm-disposable-root", action="store_true")
    marker.add_argument("--confirm-real-repository-benchmark", action="store_true")
    marker.add_argument("--confirm-dedicated-workspace", action="store_true")
    marker.set_defaults(func=create_marker_command)

    self_test = sub.add_parser("self-test", help="run deterministic offline contract validation")
    self_test.set_defaults(func=self_test_command)

    plan = sub.add_parser("plan", help="write a non-live campaign plan")
    plan.add_argument("--workspace-name", required=True)
    plan.add_argument("--window-id", type=int, required=True)
    plan.add_argument("--workspace-id", required=True)
    plan.add_argument("--context-id", required=True)
    plan.add_argument("--root-id", required=True)
    plan.add_argument("--root-path", required=True)
    plan.add_argument("--owner-token", required=True)
    plan.add_argument("--dataset-label", required=True)
    plan.add_argument("--asserted-file-count", type=int, required=True)
    plan.add_argument("--base-ref", default="HEAD")
    plan.add_argument("--search-marker", required=True)
    plan.add_argument("--read-path", required=True)
    plan.add_argument("--read-marker", required=True)
    plan.add_argument("--code-file-type", default="swift")
    plan.add_argument("--warmups", type=int, default=1)
    plan.add_argument("--retained-samples", type=int, default=5)
    plan.add_argument("--invocations-per-series", type=int, default=3)
    plan.add_argument("--confirm-real-repository-benchmark", action="store_true")
    plan.add_argument("--confirm-dedicated-workspace", action="store_true")
    plan.add_argument("--output", required=True)
    plan.set_defaults(func=plan_command)

    preflight = sub.add_parser("preflight", help="discover schemas and verify exact scope")
    add_live_common(preflight)
    preflight.add_argument("--confirm-dedicated-workspace", action="store_true")
    preflight.set_defaults(func=preflight_command)

    evidence = sub.add_parser("record-evidence", help="write one reviewed external-evidence record offline")
    evidence.add_argument("--plan", required=True)
    evidence.add_argument("--scenario", required=True)
    evidence.add_argument("--status", choices=("pass", "fail"), required=True)
    evidence.add_argument("--details", help="optional JSON object with sanitized evidence details")
    evidence.add_argument("--output", required=True)
    evidence.set_defaults(func=record_evidence_command)

    revalidate_primary = sub.add_parser(
        "revalidate-primary",
        help="revalidate one forced-full primary cohort and persist hashed offline provenance",
    )
    revalidate_primary.add_argument("--plan", required=True)
    revalidate_primary.add_argument("--artifact", required=True)
    revalidate_primary.add_argument("--output", required=True)
    revalidate_primary.set_defaults(func=revalidate_primary_command)

    run = sub.add_parser("run", help="run one route/process/width cohort")
    add_live_common(run)
    run.add_argument("--route", choices=sorted(ROUTES), required=True)
    run.add_argument("--process-state", required=True)
    run.add_argument("--checkout-kind", default="linked-worktree")
    run.add_argument("--width", type=int, required=True)
    run.add_argument("--invocation", type=int, required=True)
    run.add_argument("--warmups", type=int, default=1)
    run.add_argument("--samples", type=int, default=5)
    run.add_argument("--minimum-aged-sessions", type=int, default=32)
    run.add_argument("--confirm-process-state", action="store_true")
    run.add_argument("--confirm-dedicated-workspace", action="store_true")
    run.add_argument(
        "--bypass-prefix-control-cache",
        action="store_true",
        help="DEBUG attribution only: bypass reusable prefix-control evidence reads and admission",
    )
    run.set_defaults(func=run_command)

    policy_probe = sub.add_parser(
        "policy-digest-probe",
        help="run one non-aggregatable projected canonicalization diagnostic probe",
    )
    add_live_common(policy_probe)
    policy_probe.add_argument("--confirm-dedicated-workspace", action="store_true")
    policy_probe.set_defaults(func=policy_digest_probe_command)

    smoke = sub.add_parser("smoke", help="run correctness, watcher, inheritance, and root-churn checks")
    add_live_common(smoke)
    smoke.add_argument("--confirm-dedicated-workspace", action="store_true")
    smoke.set_defaults(func=smoke_command)

    codemap_gate = sub.add_parser(
        "codemap-gate",
        help="run the mandatory live codemap projection-demand release gate",
    )
    add_live_common(codemap_gate)
    codemap_gate.add_argument("--fixture", required=True)
    codemap_gate.add_argument("--baseline", required=True)
    codemap_gate.add_argument("--baseline-ledger", required=True)
    codemap_gate.add_argument("--baseline-ledger-sha256", required=True)
    codemap_gate.add_argument("--cold-samples", type=int, default=20)
    codemap_gate.add_argument("--warm-samples", type=int, default=40)
    codemap_gate.add_argument("--confirm-dedicated-workspace", action="store_true")
    codemap_gate.add_argument("--confirm-synthetic-allowlisted-source", action="store_true")
    codemap_gate.set_defaults(func=codemap_gate_command)

    aggregate = sub.add_parser("aggregate", help="aggregate existing artifacts offline")
    aggregate.add_argument("--plan", required=True)
    aggregate.add_argument("--artifact", action="append", required=True)
    aggregate.add_argument("--evidence", action="append")
    aggregate.add_argument("--output", required=True)
    aggregate.add_argument("--append-scoreboard")
    aggregate.add_argument("--confirm-append-scoreboard", action="store_true")
    aggregate.set_defaults(func=aggregate_command)

    inference = sub.add_parser(
        "live-inference-gate",
        help="run one fail-fast real Agent Mode file-tool correctness gate",
    )
    add_live_common(inference)
    inference.add_argument("--projected-artifact", required=True)
    inference.add_argument("--confirm-owned-resources", action="store_true")
    inference.set_defaults(func=live_inference_gate_command)

    cleanup = sub.add_parser("cleanup", help="resume idempotent cleanup for an interrupted run")
    cleanup.add_argument("--artifact", required=True)
    cleanup.add_argument("--cli")
    cleanup.add_argument("--confirm-live-debug-app", action="store_true")
    cleanup.add_argument("--confirm-owned-resources", action="store_true")
    cleanup.set_defaults(func=cleanup_command)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except BenchmarkError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("interrupted; run the cleanup subcommand for any recorded live artifact", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
