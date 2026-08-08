#!/usr/bin/env python3
"""Run or analyze paired MCP tool latency cohorts against an already-running CE app.

This command never builds, launches, relaunches, or stops the app. Invoke live runs
through `make dev-mcp-latency` / `./conductor mcp-latency` so existing-app
measurement is serialized on the configuration-specific artifact and liveApp lanes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import shlex
import shutil
import subprocess
import sys
import time
import uuid
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any, Iterable

SCHEMA_VERSION = 1
TRACE_ENV = "RP_MCP_LATENCY_TRACE_PATH"
DEBUG_TOOL = "__repoprompt_debug_diagnostics"


def new_invocation_id() -> str:
    """Match Foundation UUID.uuidString casing for exact client/server joins."""
    return str(uuid.uuid4()).upper()


def canonical_invocation_id(value: Any) -> str:
    """Canonicalize UUID spelling without weakening exact request-identity joins."""
    text = str(value)
    try:
        return str(uuid.UUID(text)).upper()
    except ValueError:
        return text


TERMINAL_OUTCOMES = {"cancelled", "timeout", "transport_closed"}
UNEXPECTED_TERMINAL_OUTCOMES = {"cancelled", "timeout", "transport_closed"}
SUCCESS_EXPECTATIONS = {"success", "cap_hit_success"}
INCLUSIVE_STAGES = {
    "EditFlow.Search.ProviderTotal",
    "EditFlow.Search.ProviderWorkspaceSearchAwait",
    "EditFlow.Search.WorkspaceReadinessAcquireGate",
    "EditFlow.Search.RootScopeAvailabilityGate",
    "EditFlow.Search.DTOBuild",
    "EditFlow.FileTree.ProviderTotal",
    "EditFlow.FileTree.BridgeTotal",
    "EditFlow.FileTree.RenderAttempt",
    "EditFlow.FormattedOutput.SearchTreeAssembly",
    "EditFlow.MCPToolCall.FormatResult",
    "EditFlow.MCPToolCall.CompletionObservers",
}
DERIVED_SEARCH_CORE_STAGE = "Derived.Search.CoreScanRemainder"
DERIVED_SEARCH_READINESS_SCOPE_STAGE = "Derived.Search.ReadinessAndScopeGateExclusive"
DERIVED_SEARCH_TREE_STAGE = "Derived.FormattedOutput.SearchTreeAssemblyExclusive"
RESIDUAL_OVERLAP_TOLERANCE_MS = 0.01
DIRECT_STAGE_CHILDREN = {
    "EditFlow.Search.ProviderTotal": {
        "EditFlow.Search.ProviderRequestMetadata",
        "EditFlow.Search.ProviderLookupContextResolution",
        "EditFlow.Search.ProviderWorkspaceSearchAwait",
        "EditFlow.Search.DTOBuild",
        "EditFlow.Search.ProviderValueEncoding",
    },
    "EditFlow.Search.ProviderWorkspaceSearchAwait": {
        "EditFlow.Search.BroadAdmissionWait",
        "EditFlow.Search.IngressFreshnessWait",
        "EditFlow.Search.WorkspaceReadinessAcquireGate",
        "EditFlow.Search.RootScopeAvailabilityGate",
    },
    "EditFlow.Search.WorkspaceReadinessAcquireGate": {
        "EditFlow.Search.WorkspaceReadinessValidationGate",
    },
    "EditFlow.Search.RootScopeAvailabilityGate": {
        "EditFlow.Search.WorkspaceReadinessValidationGate",
    },
    "EditFlow.Search.DTOBuild": {
        "EditFlow.Search.DTOBuild.Assembly",
    },
    "EditFlow.FileTree.ProviderTotal": {
        "EditFlow.FileTree.ProviderArgumentParsing",
        "EditFlow.FileTree.ProviderRequestMetadata",
        "EditFlow.FileTree.ProviderLookupContextResolution",
        "EditFlow.FileTree.ProviderIngressFreshnessWait",
        "EditFlow.FileTree.ProviderSelectionDrain",
        "EditFlow.FileTree.BridgeTotal",
        "EditFlow.FileTree.DTOAssembly",
        "EditFlow.FileTree.ProviderValueEncoding",
    },
    "EditFlow.FileTree.BridgeTotal": {
        "EditFlow.FileTree.SettingsSnapshot",
        "EditFlow.FileTree.SelectionPhysicalization",
        "EditFlow.FileTree.SnapshotConstruction",
        "EditFlow.FileTree.CodemapMarkerProjection",
        "EditFlow.FileTree.LogicalProjection",
        "EditFlow.FileTree.RenderAttempt",
    },
    "EditFlow.FileTree.RenderAttempt": {
        "EditFlow.FileTree.RenderIndexPreparation",
        "EditFlow.FileTree.RenderTokenEstimation",
    },
    "EditFlow.FormattedOutput.SearchTreeAssembly": {
        "EditFlow.FormattedOutput.SearchSnippetAssembly",
    },
    "EditFlow.MCPToolCall.CompletionObservers": {
        "EditFlow.MCPToolCall.CompletionObserverResultEncoding",
        "EditFlow.MCPToolCall.CompletionObserverCallbacks",
    },
}
LEAF_STAGES = {
    "EditFlow.MCPToolCall.LimiterWait",
    "EditFlow.MCPToolCall.HandlerResultHandoff",
    "EditFlow.MCPToolCall.CompletionObserverResultEncoding",
    "EditFlow.MCPToolCall.CompletionObserverCallbacks",
    "EditFlow.Search.BroadAdmissionWait",
    "EditFlow.Search.IngressFreshnessWait",
    "EditFlow.Search.WorkspaceReadinessValidationGate",
    "EditFlow.Search.DTOBuild.Assembly",
    "EditFlow.Search.ProviderValueEncoding",
    "EditFlow.FileTree.ProviderArgumentParsing",
    "EditFlow.FileTree.ProviderRequestMetadata",
    "EditFlow.FileTree.ProviderLookupContextResolution",
    "EditFlow.FileTree.ProviderIngressFreshnessWait",
    "EditFlow.FileTree.ProviderSelectionDrain",
    "EditFlow.FileTree.SettingsSnapshot",
    "EditFlow.FileTree.SelectionPhysicalization",
    "EditFlow.FileTree.SnapshotConstruction",
    "EditFlow.FileTree.CodemapMarkerProjection",
    "EditFlow.FileTree.LogicalProjection",
    "EditFlow.FileTree.RenderIndexPreparation",
    "EditFlow.FileTree.RenderTokenEstimation",
    "EditFlow.FileTree.DTOAssembly",
    "EditFlow.FileTree.ProviderValueEncoding",
    "EditFlow.FormattedOutput.Decode",
    "EditFlow.FormattedOutput.PromptEnvelopeProbeDecode",
    "EditFlow.FormattedOutput.PromptContextDecode",
    "EditFlow.FormattedOutput.SearchSnippetAssembly",
    "EditFlow.FormattedOutput.FileTreeAssembly",
    "EditFlow.FormattedOutput.WorkspaceContextAssembly",
    "EditFlow.FormattedOutput.GenericFallbackAssembly",
}
SELECTOR_ACTIONS = {
    "EditFlow.Search.ProviderValueEncoding": "W5",
    "EditFlow.Search.DTOBuild.Assembly": "W4",
    "EditFlow.MCPToolCall.CompletionObserverResultEncoding": "S5-C2-follow-up",
    "EditFlow.MCPToolCall.CompletionObserverCallbacks": "S5-C2-follow-up",
    "Boundary.S7S8.SDKEncode": "S5-C2-follow-up",
    "Boundary.S8S9.TransportWrite": "S5-C2-follow-up",
    "Boundary.C1C2.ClientOutput": "S5-C2-follow-up",
    DERIVED_SEARCH_TREE_STAGE: "W3",
    "EditFlow.FormattedOutput.SearchSnippetAssembly": "W3",
    "EditFlow.FileTree.CodemapMarkerProjection": "W6a",
    "EditFlow.FileTree.RenderIndexPreparation": "W6b",
    "EditFlow.FileTree.RenderTokenEstimation": "W6b",
    "EditFlow.FormattedOutput.PromptEnvelopeProbeDecode": "W7",
    "EditFlow.Search.BroadAdmissionWait": "search-follow-up",
    "EditFlow.Search.IngressFreshnessWait": "search-follow-up",
    "EditFlow.Search.WorkspaceReadinessValidationGate": "search-follow-up",
    DERIVED_SEARCH_READINESS_SCOPE_STAGE: "search-follow-up",
    DERIVED_SEARCH_CORE_STAGE: "search-follow-up",
}
SERVER_CAPTURE_MODE = "mcp_latency_evidence"
SERVER_SAMPLE_CAPACITY_UNIT = "unique_stage_dimension_request_keys"
SERVER_PERCENTILE_SEMANTICS = "unavailable_online_aggregation"
SEGMENTED_CAPTURE_LAYOUT = "segmented_canonical_matrix_v1"
SEGMENTED_CAPTURE_CONTRACT_VERSION = 1
SEGMENTED_CAPTURE_STRATEGY = "ordinary_row_client_mode_and_wi3_workload"
SEGMENTED_CAPTURE_MAX_ORDINARY_INVOCATIONS = 256
SERVER_STAGE_NAME_ALLOWLIST = sorted(LEAF_STAGES | INCLUSIVE_STAGES)
LIFECYCLE_BOUNDARIES = (
    ("s0_s1_permit_wait_ms", "MCP.ToolCall.Received", "MCP.ToolCall.PermitAcquired"),
    ("s1_s2_pre_provider_ms", "MCP.ToolCall.PermitAcquired", "MCP.ToolCall.ResolvedProviderBegan"),
    ("s2_s3_provider_ms", "MCP.ToolCall.ResolvedProviderBegan", "MCP.ToolCall.ResolvedProviderEnded"),
    ("s3_s4_pre_format_ms", "MCP.ToolCall.ResolvedProviderEnded", "MCP.ToolCall.FormatResultBegan"),
    ("s4_s5_format_ms", "MCP.ToolCall.FormatResultBegan", "MCP.ToolCall.FormatResultReturned"),
    ("s5_s6_completion_observers_ms", "MCP.ToolCall.FormatResultReturned", "MCP.ToolCall.CompletionObserverReturned"),
    ("s6_s7_handler_handoff_ms", "MCP.ToolCall.CompletionObserverReturned", "MCP.ToolCall.HandlerResultReady"),
)
LIFECYCLE_EVENT_ALLOWLIST = sorted({
    event_name
    for _, start_name, end_name in LIFECYCLE_BOUNDARIES
    for event_name in (start_name, end_name)
})
DELIVERY_BOUNDARIES = (
    ("s7_s8_sdk_encode_ms", "handler_result_ready", "sdk_encode_completed"),
    ("s8_s9_transport_write_ms", "sdk_encode_completed", "transport_write_completed"),
    ("handler_to_write_ms", "handler_result_ready", "transport_write_completed"),
)
WI3_MATRIX_IDS = {
    "same-connection-ordinary-burst",
    "same-connection-mixed-ordinary-search",
    "distinct-connections-one-window",
    "distinct-windows-one-physical-root",
    "short-versus-long-agent-transcript",
}
WI3_COUNTER_GROUPS = {
    "catalog_rebuilds",
    "search_rebuilds",
    "ui_projection_rebuilds",
    "freshness",
    "watchers_crawls",
    "content_reads",
    "git_processes",
}


class MatrixError(RuntimeError):
    pass


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def default_matrix() -> Path:
    return repo_root() / "Scripts/Fixtures/mcp-tool-latency/v1/matrix.json"


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def save_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def current_source_fingerprint() -> str:
    process = subprocess.run(
        [sys.executable, str(repo_root() / "Scripts/source_tree_fingerprint.py"),
         "--repo", str(repo_root())],
        text=True, capture_output=True,
    )
    if process.returncode:
        raise MatrixError(process.stderr.strip() or "source fingerprint failed")
    digest = process.stdout.strip()
    if len(digest) != 64:
        raise MatrixError("source fingerprint returned an invalid digest")
    return digest


def resolve_cli(argument: str | None) -> Path:
    candidates = [
        argument,
        os.environ.get("REPOPROMPT_DEBUG_CLI_INSTALL_PATH"),
        shutil.which("rpce-cli-debug"),
        str(Path.home() / "Library/Application Support/RepoPrompt CE/repoprompt_ce_cli_debug"),
    ]
    for candidate in candidates:
        if candidate:
            path = Path(candidate).expanduser()
            if path.is_file() and os.access(path, os.X_OK):
                return path.resolve()
    raise MatrixError("CE CLI not found; pass --cli or install rpce-cli-debug")


def new_capture_directory(path: Path) -> Path:
    resolved = path.expanduser().resolve()
    if resolved.exists():
        raise MatrixError(f"capture directory must be new: {resolved}")
    resolved.mkdir(parents=True, mode=0o700)
    os.chmod(resolved, 0o700)
    return resolved


def replace_variables(value: Any, variables: dict[str, str]) -> Any:
    if isinstance(value, str):
        for key, replacement in variables.items():
            value = value.replace("${" + key + "}", replacement)
        if "${" in value:
            raise MatrixError(f"unresolved matrix variable: {value}")
        return value
    if isinstance(value, list):
        return [replace_variables(item, variables) for item in value]
    if isinstance(value, dict):
        return {key: replace_variables(item, variables) for key, item in value.items()}
    return value


def validate_fixture_manifest_location(
    fixture_root: Path | None,
    fixture_manifest: Path | None,
) -> None:
    if fixture_root is None:
        if fixture_manifest is not None:
            raise MatrixError("fixture manifest requires --fixture-root")
        return
    if fixture_manifest is None:
        raise MatrixError("generated fixture workspace requires --fixture-manifest")
    root = fixture_root.expanduser().resolve()
    manifest = fixture_manifest.expanduser().resolve()
    if manifest == root or root in manifest.parents:
        raise MatrixError("fixture manifest must reside outside the measured workspace")


def fixture_variables(fixture_root: Path | None) -> dict[str, str]:
    if fixture_root is None:
        return {}
    root = fixture_root.expanduser().resolve()
    return {
        "FIXTURE_ROOT": str(root),
        "FIXTURE_SUBTREE": str(root / "root-1" / "fanout-00"),
        "FIXTURE_EMPTY_ROOT": str(root / "empty-root"),
        "FIXTURE_SMALL_FILE": str(root / "root-1" / "fanout-00" / "branch-00" / "deep-0" / "deep-1" / "deep-2" / "deep-3" / "deep-4" / "deep-5" / "deep-6" / "deep-7" / "Duplicate.swift"),
    }


def load_wi3_authority(matrix_path: Path) -> dict[str, Any]:
    matrix = load_json(matrix_path)
    if matrix.get("schema_version") != SCHEMA_VERSION:
        raise MatrixError("unsupported matrix schema")
    authority = matrix.get("wi3_authority")
    if not isinstance(authority, dict):
        raise MatrixError("matrix is missing the WI-3 authority contract")
    if authority.get("source") != matrix.get("work_count_authority"):
        raise MatrixError("WI-3 authority source must match work_count_authority")
    matrix_ids = {item.get("id") for item in authority.get("workload_matrices", []) if isinstance(item, dict)}
    if matrix_ids != WI3_MATRIX_IDS:
        raise MatrixError("WI-3 workload matrix contract is incomplete")
    counter_groups = set(authority.get("parity_counter_groups", []))
    if counter_groups != WI3_COUNTER_GROUPS:
        raise MatrixError("WI-3 work-count parity groups are incomplete")
    capacities = authority.get("lane_capacities")
    if capacities != {"connection_ordinary": 1, "connection_file_search": 4, "store_file_search": 4}:
        raise MatrixError("WI-3 lane capacities do not match the authoritative baseline")
    return authority


def load_rows(matrix_path: Path, profile: str, include_manual: bool, variables: dict[str, str]) -> list[dict[str, Any]]:
    matrix = load_json(matrix_path)
    if matrix.get("schema_version") != SCHEMA_VERSION:
        raise MatrixError("unsupported matrix schema")
    load_wi3_authority(matrix_path)
    rows = []
    seen = set()
    for source in matrix.get("rows", []):
        row_id = source.get("id")
        if not isinstance(row_id, str) or not row_id or row_id in seen:
            raise MatrixError("matrix row identifiers must be unique non-empty strings")
        seen.add(row_id)
        if profile not in source.get("profiles", []):
            continue
        if not include_manual and not source.get("enabled_by_default", False):
            continue
        row = replace_variables(source, variables)
        expected_by_profile = row.pop("expected_outcome_by_profile", None)
        if expected_by_profile is not None:
            if not isinstance(expected_by_profile, dict) or profile not in expected_by_profile:
                raise MatrixError(f"matrix row {row_id} lacks an expected outcome for profile {profile}")
            row["expected_outcome"] = expected_by_profile[profile]
        rows.append(row)
    if not rows:
        raise MatrixError(f"matrix has no rows for profile {profile}")
    return rows


def selector_required_wi3_matrix_ids(authority: dict[str, Any]) -> list[str]:
    return sorted(
        str(workload["id"])
        for workload in authority["workload_matrices"]
        if isinstance(workload.get("execution"), dict)
        and workload["execution"].get("enabled_by_default") is True
    )


def sample_discipline(matrix_path: Path) -> dict[str, int]:
    value = load_json(matrix_path).get("sample_discipline")
    required = {"cold_samples", "warmups_discarded", "warm_samples_per_repeat", "warm_repeats"}
    if not isinstance(value, dict) or set(value) != required:
        raise MatrixError("matrix sample_discipline contract is incomplete")
    result = {key: int(value[key]) for key in required}
    if any(number <= 0 for number in result.values()):
        raise MatrixError("matrix sample discipline values must be positive")
    return result


def resolve_sample_discipline(matrix_path: Path, args: argparse.Namespace) -> dict[str, Any]:
    declared = sample_discipline(matrix_path)
    if args.cohort == "warm":
        warmups = declared["warmups_discarded"] if args.warmups is None else args.warmups
        repeats = declared["warm_repeats"] if args.repeats is None else args.repeats
        samples = declared["warm_samples_per_repeat"] if args.samples_per_repeat is None else args.samples_per_repeat
        if warmups < declared["warmups_discarded"] or repeats < declared["warm_repeats"] or samples < declared["warm_samples_per_repeat"]:
            raise MatrixError("warm sample overrides cannot be below the matrix-declared discipline")
        return {"cohort": "warm", "warmups": warmups, "repeats": repeats, "samples_per_repeat": samples,
                "declared": declared, "activation_id": None, "cold_sample_index": None}
    if args.warmups not in (None, 0) or args.repeats not in (None, 1) or args.samples_per_repeat not in (None, 1):
        raise MatrixError("a cold activation run records exactly one sample with no warmups")
    if not args.activation_id or args.cold_sample_index is None:
        raise MatrixError("cold runs require --activation-id and --cold-sample-index")
    if not 1 <= args.cold_sample_index <= declared["cold_samples"]:
        raise MatrixError("--cold-sample-index is outside the declared cold campaign")
    return {"cohort": "cold", "warmups": 0, "repeats": 1, "samples_per_repeat": 1,
            "declared": declared, "activation_id": args.activation_id, "cold_sample_index": args.cold_sample_index}


def command_text(tool: str, arguments: dict[str, Any]) -> str:
    payload = json.dumps(arguments, separators=(",", ":"), sort_keys=True)
    return f"{tool} {payload}"


def classify_process(returncode: int, stderr: str, response: bytes) -> tuple[str, bool]:
    """Fallback classification used only when the authoritative trace is absent."""
    lowered = stderr.lower()
    if "timed out" in lowered or "timeout" in lowered:
        return "timeout", True
    if "transport closed" in lowered or "connection closed" in lowered or "broken pipe" in lowered:
        return "transport_closed", True
    if returncode:
        return "client_error", True
    return ("success", False) if response else ("client_error", True)


def classify_sample(trace: dict[str, Any] | None, returncode: int, stderr: str, response: bytes) -> tuple[str, bool]:
    if trace is not None:
        outcome = str(trace.get("outcome") or "client_error")
        return outcome, bool(trace.get("is_error")) or outcome != "success"
    return classify_process(returncode, stderr, response)


def validate_expected(sample: dict[str, Any]) -> None:
    expected = sample["expected_outcome"]
    actual = sample["outcome"]
    if expected in SUCCESS_EXPECTATIONS and actual != "success":
        raise MatrixError(f"{sample['sample_id']} expected {expected}, got {actual}")
    if expected == "cap_hit_success" and sample.get("cap_hit") is not True:
        raise MatrixError(f"{sample['sample_id']} expected a response cap to be hit")
    if expected == "retryable_error" and actual != "tool_error":
        raise MatrixError(f"{sample['sample_id']} expected retryable error, got {actual}")
    if expected == "expected_timeout" and actual != "timeout":
        raise MatrixError(f"{sample['sample_id']} expected timeout, got {actual}")


def invalid_connection_cohorts(samples: Iterable[dict[str, Any]]) -> dict[str, str]:
    invalid: dict[str, str] = {}
    terminal: dict[str, str] = {}
    for sample in samples:
        cohort = str(sample.get("connection_cohort") or "")
        sample_id = str(sample.get("sample_id") or "unknown")
        if cohort in terminal:
            invalid.setdefault(cohort, f"{sample_id} occurs after terminal sample {terminal[cohort]}")
            continue
        outcome = sample.get("outcome")
        expected = sample.get("expected_outcome")
        if outcome in TERMINAL_OUTCOMES:
            terminal[cohort] = sample_id
            if expected != "expected_timeout":
                invalid.setdefault(cohort, f"{sample_id} has unexpected terminal outcome {outcome}")
        if len(sample.get("client_trace", [])) != 1:
            invalid.setdefault(cohort, f"{sample_id} has missing or duplicate client trace")
    return invalid


def validate_connection_cohorts(samples: Iterable[dict[str, Any]]) -> None:
    invalid = invalid_connection_cohorts(samples)
    if invalid:
        raise MatrixError("; ".join(f"{cohort}: {reason}" for cohort, reason in sorted(invalid.items())))


def validate_delivery_terminals(
    events: list[dict[str, Any]],
    lifecycle_events: list[dict[str, Any]],
    samples: list[dict[str, Any]],
) -> None:
    request_connections: dict[str, tuple[str, int | None]] = {}
    for event in lifecycle_events:
        identity = event.get("request_identity")
        if not isinstance(identity, dict):
            continue
        invocation_id = identity.get("app_invocation_id")
        connection_id = identity.get("connection_id")
        if invocation_id and connection_id:
            generation = identity.get("connection_generation")
            request_connections[canonical_invocation_id(invocation_id)] = (
                str(connection_id), int(generation) if isinstance(generation, int) else None,
            )
    expected_timeout_ids = {
        canonical_invocation_id(sample["invocation_id"])
        for sample in samples
        if sample.get("expected_outcome") == "expected_timeout"
    }
    missing_correlations = sorted(expected_timeout_ids - set(request_connections))
    if missing_correlations:
        raise MatrixError(
            "expected-timeout requests omitted authoritative server correlation: "
            + ", ".join(missing_correlations)
        )
    expected_connections = {request_connections[invocation_id] for invocation_id in expected_timeout_ids}
    retained_connections = {
        request_connections[canonical_invocation_id(sample["invocation_id"])]
        for sample in samples
        if sample.get("expected_outcome") != "expected_timeout"
        and canonical_invocation_id(sample["invocation_id"]) in request_connections
    }
    terminal_counts = Counter(
        (str(event["connection_id"]), int(event["connection_generation"])
         if isinstance(event.get("connection_generation"), int) else None)
        for event in events
        if (event.get("terminal_reason") or event.get("phase") == "connection_terminal")
        and event.get("connection_id")
    )
    terminal_connections = set(terminal_counts)
    unexpected = (terminal_connections & retained_connections) - expected_connections
    if unexpected:
        rendered = ", ".join(
            f"{connection}@{generation}"
            for connection, generation in sorted(unexpected, key=lambda item: (item[0], str(item[1])))
        )
        raise MatrixError(
            "server delivery capture terminalized a retained connection cohort: " + rendered
        )
    for connection in expected_connections:
        if terminal_counts[connection] != 1:
            raise MatrixError(
                "expected-timeout connection requires exactly one authoritative terminal event: "
                f"{connection[0]}@{connection[1]} got {terminal_counts[connection]}"
            )


def baseline_key(sample: dict[str, Any]) -> str:
    return "/".join((sample["row_id"], sample["format"], sample["client_mode"]))


def apply_baseline(
    samples: list[dict[str, Any]],
    sidecar: Path,
    update: bool,
    wi3_work_count_signature: dict[str, Any] | None = None,
) -> None:
    grouped: dict[str, set[tuple[str, int]]] = defaultdict(set)
    for sample in samples:
        grouped[baseline_key(sample)].add((sample["response_sha256"], sample["response_byte_count"]))
    unstable = [key for key, values in grouped.items() if len(values) != 1]
    if unstable:
        raise MatrixError("response bytes changed within cohort: " + ", ".join(unstable))
    current = {
        key: {"sha256": next(iter(values))[0], "byte_count": next(iter(values))[1]}
        for key, values in grouped.items()
    }
    if update:
        payload: dict[str, Any] = {"schema_version": SCHEMA_VERSION, "responses": current}
        if wi3_work_count_signature is not None:
            payload["wi3_work_count_parity"] = wi3_work_count_signature
        save_json(sidecar, payload)
        return
    if not sidecar.is_file():
        raise MatrixError(f"baseline sidecar missing: {sidecar}; use --update-baseline after reviewing outputs")
    expected_payload = load_json(sidecar)
    expected = expected_payload.get("responses", {})
    failures = sorted(
        key for key in set(current) | set(expected)
        if current.get(key) != expected.get(key)
    )
    if failures:
        raise MatrixError("response parity mismatch (missing, extra, or changed): " + ", ".join(failures))
    if wi3_work_count_signature is not None:
        expected_work_counts = expected_payload.get("wi3_work_count_parity")
        if expected_work_counts is None:
            raise MatrixError("WI-3 work-count baseline missing; update the reviewed DEBUG sidecar")
        if expected_work_counts != wi3_work_count_signature:
            raise MatrixError("WI-3 work-count parity mismatch")


def read_trace(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    records = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        try:
            value = json.loads(line)
        except json.JSONDecodeError as error:
            raise MatrixError(f"invalid trace JSON at {path}:{line_number}") from error
        forbidden = {"arguments", "path", "content", "output_text", "result_text"}.intersection(value)
        if forbidden:
            raise MatrixError(f"trace contains forbidden fields: {sorted(forbidden)}")
        records.append(value)
    return records


def run_cli(command: list[str], *, cwd: Path, env: dict[str, str], timeout: float) -> subprocess.CompletedProcess[bytes]:
    try:
        return subprocess.run(command, cwd=cwd, env=env, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout or b""
        stderr = (error.stderr or b"") + b"\nrunner timeout"
        return subprocess.CompletedProcess(command, 124, stdout, stderr)


def call_debug_tool(cli: Path, window_id: int, payload: dict[str, Any], timeout: float) -> Any:
    routed = {**payload, "_windowID": window_id}
    command = [str(cli), "--raw-json", "-w", str(window_id), "-c", DEBUG_TOOL, "-j", json.dumps(routed)]
    process = run_cli(command, cwd=repo_root(), env={key: value for key, value in os.environ.items() if key != TRACE_ENV}, timeout=timeout)
    if process.returncode:
        raise MatrixError(process.stderr.decode("utf-8", errors="replace").strip() or "debug diagnostics call failed")
    return json.loads(process.stdout.decode("utf-8"))


def find_named_object(value: Any, key: str) -> Any:
    if isinstance(value, dict):
        if key in value:
            return value[key]
        for child in value.values():
            found = find_named_object(child, key)
            if found is not None:
                return found
    elif isinstance(value, list):
        for child in value:
            found = find_named_object(child, key)
            if found is not None:
                return found
    return None


def probe_server_app_identity(
    cli: Path, window_id: int, timeout: float, expected_configuration: str,
) -> dict[str, Any]:
    response = call_debug_tool(
        cli, window_id, {"op": "mcp_latency_server_identity"}, timeout,
    )
    identity = find_named_object(response, "server_app_identity")
    if not isinstance(identity, dict):
        raise MatrixError("server identity probe returned no server_app_identity")
    if identity.get("identity_authority") != "server_process":
        raise MatrixError("server identity probe is not process-authoritative")
    if identity.get("app_configuration") != expected_configuration:
        raise MatrixError(
            f"server configuration mismatch: expected {expected_configuration}, "
            f"got {identity.get('app_configuration')}"
        )
    if identity.get("diagnostic_surface") != "mcp_latency_v1":
        raise MatrixError("server identity probe returned the wrong diagnostic surface")
    for field in ("process_identifier", "bundle_path", "executable_path", "executable_sha256"):
        if not identity.get(field):
            raise MatrixError(f"server identity probe omitted {field}")
    return identity


def validate_optimized_artifact_manifest(path: Path) -> dict[str, Any]:
    path = path.expanduser().resolve()
    manifest = load_json(path)
    required = {
        "artifact_kind": "optimized_mcp_latency_diagnostic_server",
        "ordinary_release_artifact": False,
        "swift_configuration": "release",
        "server_diagnostic_configuration": "optimized_diagnostic",
        "diagnostic_surface": "mcp_latency_v1",
        "signing_mode": "mcp-latency-diagnostic-adhoc",
        "secure_storage_backend": "alternate-in-memory",
        "enabled_defines_by_target": {
            "RepoPromptApp": ["MCP_LATENCY_DIAGNOSTICS"],
            "RepoPromptDomainRuntime": ["MCP_LATENCY_DIAGNOSTICS"],
            "RepoPromptMCP": ["MCP_LATENCY_TRACE"],
            "RepoPromptShared": ["MCP_LATENCY_DIAGNOSTICS"],
        },
    }
    for field, expected in required.items():
        if manifest.get(field) != expected:
            raise MatrixError(f"optimized server artifact manifest mismatch: {field}")
    for field in ("artifact_id", "commit", "source_fingerprint_sha256", "bundle_path",
                  "bundle_identifier", "executable_path", "executable_sha256",
                  "embedded_cli_path", "embedded_cli_sha256", "provenance_path",
                  "provenance_sha256"):
        if not manifest.get(field):
            raise MatrixError(f"optimized server artifact manifest omitted {field}")
    canonical_root = (repo_root() / ".build/mcp-latency/optimized-server").resolve()
    if path != canonical_root / "artifact-manifest.json":
        raise MatrixError("optimized server artifact manifest is not at the canonical isolated path")
    bundle = Path(manifest["bundle_path"]).resolve()
    if bundle != canonical_root / "RepoPrompt.app":
        raise MatrixError("optimized server bundle is not at the canonical isolated path")
    if manifest.get("bundle_identifier") != "com.pvncher.repoprompt.ce.mcp-latency-diagnostic":
        raise MatrixError("optimized server bundle identifier mismatch")
    executable = Path(manifest["executable_path"]).resolve()
    embedded_cli = Path(manifest["embedded_cli_path"]).resolve()
    provenance = Path(manifest["provenance_path"]).resolve()
    try:
        bundle.relative_to(path.parent)
        executable.relative_to(bundle)
        embedded_cli.relative_to(bundle)
        provenance.relative_to(bundle)
    except ValueError as error:
        raise MatrixError("optimized server artifact member escapes its isolated artifact root") from error
    for member, digest_field in (
        (executable, "executable_sha256"),
        (embedded_cli, "embedded_cli_sha256"),
        (provenance, "provenance_sha256"),
    ):
        if not member.is_file():
            raise MatrixError(f"optimized server artifact member is missing: {member}")
        if sha256_bytes(member.read_bytes()) != manifest[digest_field]:
            raise MatrixError(f"optimized server artifact member hash mismatch: {digest_field}")
    provenance_payload = load_json(provenance)
    for field in ("artifact_id", "artifact_kind", "ordinary_release_artifact",
                  "swift_configuration", "server_diagnostic_configuration",
                  "diagnostic_surface", "enabled_defines_by_target", "commit", "dirty",
                  "source_fingerprint_sha256"):
        if provenance_payload.get(field) != manifest.get(field):
            raise MatrixError(f"optimized server provenance mismatch: {field}")
    return manifest


def validate_runtime_artifact_identity(identity: dict[str, Any], artifact: dict[str, Any]) -> None:
    for field in ("bundle_path", "bundle_identifier", "signing_mode", "secure_storage_backend",
                  "executable_path", "executable_sha256", "embedded_cli_path",
                  "embedded_cli_sha256", "provenance_sha256"):
        if identity.get(field) != artifact.get(field):
            raise MatrixError(f"running optimized server does not match artifact manifest: {field}")
    provenance = identity.get("provenance")
    if not isinstance(provenance, dict) or provenance.get("artifact_id") != artifact.get("artifact_id"):
        raise MatrixError("running optimized server provenance artifact ID mismatch")
    for field in ("commit", "dirty", "source_fingerprint_sha256"):
        if provenance.get(field) != artifact.get(field):
            raise MatrixError(f"running optimized server provenance mismatch: {field}")


def runtime_work_counters(payload: Any) -> dict[str, int]:
    runtime = find_named_object(payload, "runtime")
    if not isinstance(runtime, dict):
        raise MatrixError("WI-3 runtime snapshot is missing `runtime`")
    counters: defaultdict[str, int] = defaultdict(int)
    for window in runtime.get("windows", []):
        if not isinstance(window, dict):
            continue
        store = window.get("store_work") or {}
        catalog = store.get("catalog_rebuild") or {}
        shards = store.get("root_catalog_shards") or {}
        counters["catalog_rebuild_count"] += int(catalog.get("count", 0))
        counters["catalog_shard_build_count"] += int(shards.get("total_build_count", 0))
        counters["catalog_shard_backstop_count"] += int(shards.get("total_backstop_count", 0))
        counters["catalog_shadow_comparison_count"] += int(shards.get("shadow_comparison_count", 0))
        counters["catalog_shadow_mismatch_count"] += int(shards.get("shadow_mismatch_count", 0))
        counters["catalog_invalidation_event_count"] += len(store.get("invalidations", []))

        search = window.get("search_rebuild") or {}
        counters["search_rebuild_count"] += int(search.get("count", 0))
        counters["search_debounce_cancellation_count"] += int(search.get("debounce_cancellation_count", 0))
        counters["search_stale_discarded_count"] += int(search.get("stale_discarded_count", 0))

        projection = window.get("ui_index_rebuild") or {}
        counters["ui_projection_rebuild_count"] += int(projection.get("count", 0))
        counters["ui_projection_visited_folder_count"] += int(projection.get("visited_folder_count", 0))
        counters["ui_projection_visited_file_count"] += int(projection.get("visited_file_count", 0))

        for root in window.get("roots", []):
            if not isinstance(root, dict):
                continue
            counters["crawl_count"] += int(root.get("crawl_count", 0))
            counters["active_watcher_count"] += 1 if root.get("watcher_active") is True else 0
            barrier = root.get("barrier") or {}
            for field in ("launch_count", "join_count", "successor_count", "coalesced_successor_count", "completion_count", "noop_count"):
                counters["freshness_barrier_" + field] += int(barrier.get(field, 0))
            freshness = root.get("freshness") or {}
            for field in ("flush_call_count", "noop_flush_count", "debounce_cancellation_count", "watcher_batch_count", "watcher_batch_event_count"):
                counters["freshness_" + field] += int(freshness.get(field, 0))

    for duplication in runtime.get("physical_root_duplication", []):
        if not isinstance(duplication, dict):
            continue
        counters["duplicated_window_count"] += int(duplication.get("window_count", 0))
        counters["duplication_watcher_count"] += int(duplication.get("watcher_count", 0))
        counters["duplication_crawl_count"] += int(duplication.get("crawl_count", 0))
        counters["current_freshness_flight_count"] += int(duplication.get("current_freshness_flight_count", 0))
        counters["total_freshness_flight_launch_count"] += int(duplication.get("total_freshness_flight_launch_count", 0))

    tool_work = runtime.get("tool_work") or {}
    reads = [item for item in tool_work.get("read_file_invocations", []) if isinstance(item, dict)]
    counters["read_file_invocation_count"] = len(reads)
    counters["read_file_full_bytes"] = sum(int(item.get("read_bytes", 0)) for item in reads)
    counters["read_file_returned_bytes"] = sum(int(item.get("returned_bytes", 0)) for item in reads)
    counters["read_file_returned_lines"] = sum(int(item.get("returned_lines", 0)) for item in reads)
    counters["read_file_cache_hit_count"] = sum(1 for item in reads if item.get("cache_hit") is True)
    git = [item for item in tool_work.get("git_invocations", []) if isinstance(item, dict)]
    counters["git_invocation_count"] = len(git)
    counters["git_command_count"] = sum(int(item.get("command_count", 0)) for item in git)
    return dict(sorted(counters.items()))


def observed_lane_capacities(runtime_payload: Any, admission_payload: Any) -> dict[str, int]:
    runtime = find_named_object(runtime_payload, "runtime")
    admission = find_named_object(admission_payload, "admission")
    if not isinstance(runtime, dict) or not isinstance(admission, dict):
        raise MatrixError("WI-3 lane-capacity snapshots are incomplete")
    limiter = runtime.get("limiter") or {}
    lanes = limiter.get("lanes") or {}
    store_capacities = {
        int(item.get("configuration", {}).get("active_capacity", 0))
        for item in admission.get("lanes", [])
        if isinstance(item, dict)
    }
    if len(store_capacities) != 1:
        raise MatrixError("WI-3 store search lanes do not share one authoritative capacity")
    return {
        "connection_ordinary": int((lanes.get("ordinary") or {}).get("limit", 0)),
        "connection_file_search": int((lanes.get("file_search") or {}).get("limit", 0)),
        "store_file_search": next(iter(store_capacities)),
    }


def project_wi3_work_counts(
    runtime_before: Any,
    runtime_after: Any,
    admission_before: Any,
    admission_after: Any,
    authority: dict[str, Any],
    executed_matrix_ids: Iterable[str] = (),
) -> dict[str, Any]:
    expected_capacities = authority["lane_capacities"]
    before_capacities = observed_lane_capacities(runtime_before, admission_before)
    after_capacities = observed_lane_capacities(runtime_after, admission_after)
    if before_capacities != expected_capacities or after_capacities != expected_capacities:
        raise MatrixError("observed lane capacities do not match the WI-3 authority")
    before = runtime_work_counters(runtime_before)
    after = runtime_work_counters(runtime_after)
    names = sorted(set(before) | set(after))
    deltas = {name: max(0, after.get(name, 0) - before.get(name, 0)) for name in names}
    declared_matrix_ids = {item["id"] for item in authority["workload_matrices"]}
    matrix_ids = sorted(set(executed_matrix_ids))
    if not set(matrix_ids).issubset(declared_matrix_ids):
        raise MatrixError("executed WI-3 workload IDs are not declared by the authority")
    gauge_names = {
        "active_watcher_count",
        "current_freshness_flight_count",
        "duplicated_window_count",
        "duplication_watcher_count",
    }
    gauge_before = {name: before.get(name, 0) for name in sorted(gauge_names)}
    gauge_after = {name: after.get(name, 0) for name in sorted(gauge_names)}
    parity_signature = {
        "authority_baseline_commit": authority["baseline_commit"],
        "workload_matrix_ids": matrix_ids,
        "lane_capacities": after_capacities,
        "counter_deltas": deltas,
        "gauge_before": gauge_before,
        "gauge_after": gauge_after,
    }
    return {
        "authority_source": authority["source"],
        "snapshot_surfaces": authority["snapshot_surfaces"],
        "workload_matrices": [
            item for item in authority["workload_matrices"] if item["id"] in set(matrix_ids)
        ],
        "lane_capacity_evidence": {
            "expected": expected_capacities,
            "before": before_capacities,
            "after": after_capacities,
            "matches_authority": True,
        },
        "counter_before": before,
        "counter_after": after,
        "counter_deltas": deltas,
        "gauge_before": gauge_before,
        "gauge_after": gauge_after,
        "parity_signature": parity_signature,
    }


def response_is_json(response: bytes) -> bool:
    try:
        json.loads(response.decode("utf-8"))
        return True
    except (UnicodeDecodeError, json.JSONDecodeError):
        return False


def response_hit_cap(response: bytes) -> bool:
    try:
        decoded = json.loads(response.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        text = response.decode("utf-8", errors="replace")
        return "Partial (limit reached)" in text or "results trimmed by response size cap" in text

    def contains_cap(value: Any) -> bool:
        if isinstance(value, dict):
            if value.get("limit_hit") is True or value.get("size_limit_hit") is True:
                return True
            return any(contains_cap(child) for child in value.values())
        if isinstance(value, list):
            return any(contains_cap(child) for child in value)
        return False

    return contains_cap(decoded)


def invocation_arguments(row: dict[str, Any], output_format: str, window_id: int, invocation_id: str) -> dict[str, Any]:
    arguments = {**row.get("arguments", {}), "_windowID": window_id, "_latencyTraceID": invocation_id}
    if output_format == "raw":
        arguments["_rawJSON"] = True
    else:
        arguments.pop("_rawJSON", None)
    return arguments


def create_sample(
    row: dict[str, Any],
    output_format: str,
    client_mode: str,
    cohort: str,
    cohort_kind: str,
    invocation_id: str,
    response: bytes,
    process: subprocess.CompletedProcess[bytes],
    trace_records: list[dict[str, Any]],
    elapsed_ms: float | None,
    phase: str = "recorded",
    workload_matrix_id: str | None = None,
) -> dict[str, Any]:
    matching = [record for record in trace_records if record.get("invocation_id") == invocation_id]
    trace = matching[0] if len(matching) == 1 else None
    outcome, is_error = classify_sample(
        trace,
        process.returncode,
        process.stderr.decode("utf-8", errors="replace"),
        response,
    )
    sample = {
        "sample_id": f"{row['id']}:{output_format}:{client_mode}:r{row.get('_repeat', 0)}:s{row.get('_sample', 0)}:{invocation_id}",
        "invocation_id": invocation_id,
        "row_id": row["id"],
        "tool": row["tool"],
        "format": output_format,
        "client_mode": client_mode,
        "cohort_kind": cohort_kind,
        "phase": phase,
        "connection_cohort": cohort,
        "expected_outcome": row["expected_outcome"],
        "outcome": outcome,
        "is_error": is_error,
        "process_elapsed_ms": round(elapsed_ms, 3) if elapsed_ms is not None else None,
        "response_byte_count": len(response),
        "response_sha256": sha256_bytes(response),
        "response_is_json": response_is_json(response),
        "returncode": process.returncode,
        "repeat_ordinal": row.get("_repeat", 0),
        "sample_ordinal": row.get("_sample", 0),
        "cap_hit": response_hit_cap(response),
        "client_trace": matching,
    }
    if workload_matrix_id is not None:
        sample["workload_matrix_id"] = workload_matrix_id
    return sample


def run_fresh(
    cli: Path,
    window_id: int,
    rows: list[dict[str, Any]],
    capture: Path,
    timeout: float,
    cohort_kind: str,
    phase: str,
) -> list[dict[str, Any]]:
    samples = []
    for ordinal, row in enumerate(rows):
        for output_format in row["formats"]:
            invocation_id = new_invocation_id()
            arguments = invocation_arguments(row, output_format, window_id, invocation_id)
            trace = capture / "traces" / f"fresh-{phase}-{ordinal:05d}-{output_format}-{invocation_id}.jsonl"
            trace.parent.mkdir(parents=True, exist_ok=True)
            env = {**os.environ, TRACE_ENV: str(trace.resolve())}
            command = [str(cli)]
            if output_format == "raw":
                command.append("--raw-json")
            command.extend(["-w", str(window_id), "-c", row["tool"], "-j", json.dumps(arguments, separators=(",", ":"), sort_keys=True)])
            started = time.perf_counter_ns()
            process = run_cli(command, cwd=repo_root(), env=env, timeout=timeout)
            elapsed = (time.perf_counter_ns() - started) / 1_000_000
            response = process.stdout
            raw_path = capture / "responses" / f"fresh-{phase}-{ordinal:05d}-{output_format}-{invocation_id}.out"
            raw_path.parent.mkdir(parents=True, exist_ok=True)
            raw_path.write_bytes(response)
            records = read_trace(trace)
            sample = create_sample(
                row, output_format, "fresh", f"fresh-{invocation_id}", cohort_kind,
                invocation_id, response, process, records, elapsed, phase,
            )
            sample["trace_file"] = str(trace.relative_to(capture))
            samples.append(sample)
    return samples


def run_fresh_with_recovery(
    cli: Path,
    window_id: int,
    rows: list[dict[str, Any]],
    capture: Path,
    timeout: float,
    cohort_kind: str,
    phase: str,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    retained: list[dict[str, Any]] = []
    discarded_invalid: list[dict[str, Any]] = []
    for row in rows:
        for generation in range(2):
            generation_samples = run_fresh(
                cli, window_id, [row], capture, timeout, cohort_kind,
                f"{phase}-g{generation}",
            )
            for sample in generation_samples:
                sample["phase"] = phase
            invalid = invalid_connection_cohorts(generation_samples)
            if not invalid:
                retained.extend(generation_samples)
                break
            for sample in generation_samples:
                sample["discard_reason"] = next(iter(invalid.values()))
            discarded_invalid.extend(generation_samples)
        else:
            raise MatrixError(
                f"fresh row {row['id']} remained invalid after reconnect"
            )
    return retained, discarded_invalid


def run_persistent_generation(
    cli: Path,
    window_id: int,
    warmup_rows_for_generation: list[dict[str, Any]],
    recorded_rows: list[dict[str, Any]],
    capture: Path,
    timeout: float,
    cohort_kind: str,
    generation: int,
    cohort_label: str,
) -> list[dict[str, Any]]:
    cohort = f"persistent-{cohort_label}-g{generation}"
    trace = (capture / "traces" / f"{cohort}.jsonl").resolve()
    trace.parent.mkdir(parents=True, exist_ok=True)
    command = [str(cli), "-w", str(window_id)]
    ordered: list[tuple[dict[str, Any], str, str, Path, str]] = []
    all_rows = [(row, "warmup") for row in warmup_rows_for_generation] + [(row, "recorded") for row in recorded_rows]
    for ordinal, (row, phase) in enumerate(all_rows):
        for output_format in row["formats"]:
            invocation_id = new_invocation_id()
            arguments = invocation_arguments(row, output_format, window_id, invocation_id)
            response_path = (capture / "responses" / f"{cohort}-{phase}-{ordinal:05d}-{output_format}-{invocation_id}.out").resolve()
            response_path.parent.mkdir(parents=True, exist_ok=True)
            command.extend(["-e", f"{command_text(row['tool'], arguments)} > {shlex.quote(str(response_path))}"])
            ordered.append((row, output_format, invocation_id, response_path, phase))
    env = {**os.environ, TRACE_ENV: str(trace)}
    process = run_cli(command, cwd=repo_root(), env=env, timeout=timeout * max(1, len(ordered)))
    traces = read_trace(trace)
    samples = []
    for row, output_format, invocation_id, response_path, phase in ordered:
        response = response_path.read_bytes() if response_path.exists() else b""
        sample = create_sample(
            row, output_format, "persistent", cohort, cohort_kind, invocation_id,
            response, process, traces, None, phase,
        )
        sample["trace_file"] = str(trace.relative_to(capture))
        samples.append(sample)
    return samples


def run_persistent_with_recovery(
    cli: Path,
    window_id: int,
    warmup_rows_for_generation: list[dict[str, Any]],
    recorded_rows: list[dict[str, Any]],
    capture: Path,
    timeout: float,
    cohort_kind: str,
    cohort_label: str,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    discarded_invalid: list[dict[str, Any]] = []
    for generation in range(2):
        generation_samples = run_persistent_generation(
            cli, window_id, warmup_rows_for_generation, recorded_rows, capture,
            timeout, cohort_kind, generation, cohort_label,
        )
        invalid = invalid_connection_cohorts(generation_samples)
        if not invalid:
            warmups = [sample for sample in generation_samples if sample["phase"] == "warmup"]
            recorded = [sample for sample in generation_samples if sample["phase"] == "recorded"]
            return recorded, warmups, discarded_invalid
        for sample in generation_samples:
            sample["discard_reason"] = next(iter(invalid.values()))
        discarded_invalid.extend(generation_samples)
    raise MatrixError(f"persistent cohort {cohort_label} remained invalid after reconnect and re-warm")


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil(len(ordered) * fraction) - 1))
    return ordered[index]


def validate_capture_contract(capture: dict[str, Any]) -> None:
    expected = {
        "capture_mode": SERVER_CAPTURE_MODE,
        "sample_capacity_unit": SERVER_SAMPLE_CAPACITY_UNIT,
        "percentile_semantics": SERVER_PERCENTILE_SEMANTICS,
        "lifecycle_capture_contract": "s0_s7_required_boundaries",
        "stage_capture_contract": "w2_selector_stages",
    }
    for field, value in expected.items():
        if capture.get(field) != value:
            raise MatrixError(f"server capture contract mismatch: {field}")
    if capture.get("lifecycle_event_allowlist") != LIFECYCLE_EVENT_ALLOWLIST:
        raise MatrixError("server capture lifecycle allowlist mismatch")
    if capture.get("stage_name_allowlist") != SERVER_STAGE_NAME_ALLOWLIST:
        raise MatrixError("server capture stage allowlist mismatch")


def validate_capture_begin(capture: dict[str, Any]) -> None:
    validate_capture_contract(capture)
    if capture.get("active") is not True:
        raise MatrixError("server capture begin did not activate evidence mode")


def validate_capture_integrity(capture: dict[str, Any]) -> None:
    validate_capture_contract(capture)
    for field in ("dropped_sample_count", "dropped_lifecycle_event_count"):
        if int(capture.get(field, 0)) != 0:
            raise MatrixError(f"debug capture has nonzero {field}")
    if capture.get("active") is True:
        raise MatrixError("debug capture was not finished")

    stages = capture.get("stages")
    if not isinstance(stages, list):
        raise MatrixError("server capture stages are missing")
    retained = int(capture.get("retained_sample_count", -1))
    dropped = int(capture.get("dropped_sample_count", -1))
    ignored = int(capture.get("ignored_out_of_contract_sample_count", -1))
    if int(capture.get("retained_aggregate_key_count", -1)) != len(stages):
        raise MatrixError("server capture aggregate-key count mismatch")
    if sum(int(stage.get("sample_count", -1)) for stage in stages) != retained:
        raise MatrixError("server capture retained sample accounting mismatch")
    if int(capture.get("observed_sample_count", -1)) != retained + dropped + ignored:
        raise MatrixError("server capture observed sample accounting mismatch")
    for stage in stages:
        if stage.get("stage_name") not in SERVER_STAGE_NAME_ALLOWLIST:
            raise MatrixError("server capture retained an out-of-contract stage")
        if stage.get("p50_ms") is not None or stage.get("p95_ms") is not None:
            raise MatrixError("server evidence capture unexpectedly retained per-span percentiles")
        for field in ("total_ms", "max_ms"):
            if not isinstance(stage.get(field), (int, float)) or isinstance(stage.get(field), bool):
                raise MatrixError(f"server evidence capture has invalid {field}")

    lifecycle = capture.get("lifecycle_events")
    if not isinstance(lifecycle, list):
        raise MatrixError("server capture lifecycle events are missing")
    if any(event.get("event_name") not in LIFECYCLE_EVENT_ALLOWLIST for event in lifecycle):
        raise MatrixError("server capture retained an out-of-contract lifecycle event")
    retained_lifecycle = int(capture.get("retained_lifecycle_event_count", -1))
    dropped_lifecycle = int(capture.get("dropped_lifecycle_event_count", -1))
    ignored_lifecycle = int(capture.get("ignored_out_of_contract_lifecycle_event_count", -1))
    if retained_lifecycle != len(lifecycle):
        raise MatrixError("server capture retained lifecycle accounting mismatch")
    if int(capture.get("observed_lifecycle_event_count", -1)) \
            != retained_lifecycle + dropped_lifecycle + ignored_lifecycle:
        raise MatrixError("server capture observed lifecycle accounting mismatch")


def parse_dimensions(raw: str) -> dict[str, str]:
    return dict(part.split("=", 1) for part in raw.split() if "=" in part)


def cohort_key(sample: dict[str, Any]) -> tuple[str, str, str, str]:
    return (sample["row_id"], sample["format"], sample["client_mode"], sample["cohort_kind"])


def cohort_payload(key: tuple[str, str, str, str]) -> dict[str, str]:
    return dict(zip(("row_id", "format", "client_mode", "cohort_kind"), key))


def validate_trace_records(samples: list[dict[str, Any]], configuration: str) -> None:
    seen: set[str] = set()
    expected_configuration = "debug" if configuration == "debug" else "optimized_diagnostic"
    for sample in samples:
        records = sample.get("client_trace", [])
        if len(records) != 1:
            raise MatrixError(f"{sample.get('sample_id', 'unknown')} has missing or duplicate C0-C2 trace records")
        trace = records[0]
        invocation_id = str(trace.get("invocation_id") or "")
        if invocation_id != sample.get("invocation_id") or invocation_id in seen:
            raise MatrixError("client trace invocation identity is missing, duplicated, or mismatched")
        seen.add(invocation_id)
        if trace.get("output_format") != sample.get("format"):
            raise MatrixError(f"{sample['sample_id']} trace output format mismatch")
        if trace.get("diagnostic_configuration") != expected_configuration:
            raise MatrixError(
                f"{sample['sample_id']} was not emitted by the requested {configuration} diagnostic artifact"
            )


def validate_format_pairs(samples: list[dict[str, Any]]) -> None:
    grouped: dict[tuple[str, str, str, int, int], dict[str, dict[str, Any]]] = defaultdict(dict)
    for sample in samples:
        if sample.get("phase") != "recorded" or sample.get("cohort_kind") == "wi3":
            continue
        key = (
            sample["row_id"], sample["client_mode"], sample["cohort_kind"],
            int(sample["repeat_ordinal"]), int(sample["sample_ordinal"]),
        )
        output_format = sample["format"]
        if output_format in grouped[key]:
            raise MatrixError(f"duplicate formatted/raw sample coordinate for {key}: {output_format}")
        grouped[key][output_format] = sample
    for key, pair in grouped.items():
        if set(pair) != {"formatted", "raw"}:
            raise MatrixError(f"formatted/raw cohort is incomplete for {key}")
        formatted, raw = pair["formatted"], pair["raw"]
        if formatted["invocation_id"] == raw["invocation_id"]:
            raise MatrixError(f"formatted/raw requests reused one invocation identity for {key}")
        if formatted["outcome"] == "success" and raw["outcome"] == "success" \
                and formatted["response_sha256"] == raw["response_sha256"]:
            raise MatrixError(f"formatted/raw response digests are identical for {key}")
        if formatted["outcome"] == "success":
            trace = formatted["client_trace"][0]
            if int(trace.get("text_content_block_count", 0)) < 1 or int(trace.get("returned_text_bytes", 0)) < 1:
                raise MatrixError(f"formatted response lacks a rendered text block for {key}")
            if formatted.get("response_is_json") is True:
                raise MatrixError(f"formatted response unexpectedly contains raw JSON for {key}")
        if raw["outcome"] == "success":
            trace = raw["client_trace"][0]
            if int(trace.get("content_block_count", 0)) != 1 or int(trace.get("text_content_block_count", 0)) != 1:
                raise MatrixError(f"raw response is not exactly one text content block for {key}")
            if raw.get("response_is_json") is not True:
                raise MatrixError(f"raw response is not valid JSON for {key}")


def transport_identity_key(identity: dict[str, Any]) -> tuple[str, int, str, int] | None:
    connection_id = identity.get("connection_id")
    generation = identity.get("connection_generation")
    request_id = identity.get("jsonrpc_request_id")
    ordinal = identity.get("request_ordinal")
    if not connection_id or not isinstance(generation, int) or not request_id or not isinstance(ordinal, int):
        return None
    return str(connection_id), generation, str(request_id), ordinal


def phase_index(events: list[dict[str, Any]], *, lifecycle: bool) -> dict[str, dict[str, list[float]]]:
    grouped: dict[str, dict[str, list[float]]] = defaultdict(lambda: defaultdict(list))
    for event in events:
        identity = event.get("request_identity") if lifecycle else None
        invocation_id = (
            identity.get("app_invocation_id") if isinstance(identity, dict) else event.get("app_invocation_id")
        )
        phase = event.get("event_name") if lifecycle else event.get("phase")
        timestamp = event.get("offset_ms") if lifecycle else event.get("monotonic_uptime_ms")
        if invocation_id and isinstance(phase, str) and isinstance(timestamp, (int, float)):
            grouped[canonical_invocation_id(invocation_id)][phase].append(float(timestamp))
    return {key: dict(value) for key, value in grouped.items()}


def transport_phase_index(
    events: list[dict[str, Any]],
) -> dict[tuple[str, int, str, int], dict[str, list[float]]]:
    grouped: dict[tuple[str, int, str, int], dict[str, list[float]]] = defaultdict(
        lambda: defaultdict(list)
    )
    for event in events:
        key = transport_identity_key(event)
        phase = event.get("phase")
        timestamp = event.get("monotonic_uptime_ms")
        if key and isinstance(phase, str) and isinstance(timestamp, (int, float)):
            grouped[key][phase].append(float(timestamp))
    return {key: dict(value) for key, value in grouped.items()}


def lifecycle_transport_keys(
    events: list[dict[str, Any]],
) -> dict[str, set[tuple[str, int, str, int]]]:
    grouped: dict[str, set[tuple[str, int, str, int]]] = defaultdict(set)
    for event in events:
        identity = event.get("request_identity")
        if not isinstance(identity, dict):
            continue
        invocation_id = identity.get("app_invocation_id")
        key = transport_identity_key(identity)
        if invocation_id and key:
            grouped[canonical_invocation_id(invocation_id)].add(key)
    return dict(grouped)


def stage_attribution_report(
    samples: list[dict[str, Any]], capture: dict[str, Any], require_server: bool,
) -> dict[str, Any]:
    per_stage: defaultdict[str, dict[str, int]] = defaultdict(
        lambda: {"identified_sample_count": 0, "unidentified_sample_count": 0}
    )
    identified_request_ids: set[str] = set()
    unidentified_stages: list[str] = []
    for bucket in capture.get("stages", []):
        stage = str(bucket.get("stage_name") or "")
        if stage not in LEAF_STAGES and stage not in INCLUSIVE_STAGES:
            continue
        sample_count = int(bucket.get("sample_count", 0))
        identity = bucket.get("request_identity")
        invocation_id = identity.get("app_invocation_id") if isinstance(identity, dict) else None
        if invocation_id:
            per_stage[stage]["identified_sample_count"] += sample_count
            identified_request_ids.add(canonical_invocation_id(invocation_id))
        else:
            per_stage[stage]["unidentified_sample_count"] += sample_count
            if sample_count > 0:
                unidentified_stages.append(stage)
    successful_request_ids = {
        canonical_invocation_id(sample["invocation_id"])
        for sample in samples
        if sample.get("phase") == "recorded" and sample.get("outcome") == "success"
    }
    missing_request_ids = sorted(successful_request_ids - identified_request_ids)
    report = {
        "status": "complete" if not unidentified_stages and not missing_request_ids else "invalid",
        "identified_sample_count": sum(row["identified_sample_count"] for row in per_stage.values()),
        "unidentified_sample_count": sum(row["unidentified_sample_count"] for row in per_stage.values()),
        "missing_successful_request_ids": missing_request_ids,
        "per_stage": [
            {"stage": stage, **counts}
            for stage, counts in sorted(per_stage.items())
        ],
    }
    if require_server and unidentified_stages:
        raise MatrixError(
            "recorded leaf/inclusive stage samples lack request identity: "
            + ", ".join(sorted(set(unidentified_stages)))
        )
    if require_server and missing_request_ids:
        raise MatrixError(
            "successful recorded requests lack leaf/inclusive stage samples: "
            + ", ".join(missing_request_ids)
        )
    return report


def joined_request_evidence(
    samples: list[dict[str, Any]],
    capture: dict[str, Any],
    delivery_events: list[dict[str, Any]],
    require_server: bool,
) -> list[dict[str, Any]]:
    stage_attribution_report(samples, capture, require_server)
    stage_index: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for stage in capture.get("stages", []):
        identity = stage.get("request_identity")
        invocation_id = identity.get("app_invocation_id") if isinstance(identity, dict) else None
        if invocation_id:
            stage_index[canonical_invocation_id(invocation_id)].append(stage)
    lifecycle_events = capture.get("lifecycle_events", [])
    lifecycle = phase_index(lifecycle_events, lifecycle=True)
    delivery = phase_index(delivery_events, lifecycle=False)
    delivery_by_transport_identity = transport_phase_index(delivery_events)
    transport_keys_by_invocation = lifecycle_transport_keys(lifecycle_events)
    evidence = []
    for sample in samples:
        invocation_id = canonical_invocation_id(sample["invocation_id"])
        trace = sample["client_trace"][0]
        transport_keys = transport_keys_by_invocation.get(invocation_id, set())
        delivery_phases = dict(delivery.get(invocation_id, {}))
        delivery_join_identity = None
        if len(transport_keys) == 1:
            transport_key = next(iter(transport_keys))
            for phase, timestamps in delivery_by_transport_identity.get(transport_key, {}).items():
                delivery_phases.setdefault(phase, timestamps)
            delivery_join_identity = {
                "connection_id": transport_key[0],
                "connection_generation": transport_key[1],
                "jsonrpc_request_id": transport_key[2],
                "request_ordinal": transport_key[3],
            }
        item = {
            "sample": sample,
            "trace": trace,
            "stage_buckets": stage_index.get(invocation_id, []),
            "lifecycle_phases": lifecycle.get(invocation_id, {}),
            "delivery_phases": delivery_phases,
            "delivery_join_identity": delivery_join_identity,
            "boundaries": {
                "c0_c1_client_call_ms": float(trace.get("call_duration_ms", 0)),
                "c1_c2_client_output_ms": float(trace.get("print_duration_ms", 0)),
                "c0_c2_client_total_ms": float(trace.get("call_duration_ms", 0))
                    + float(trace.get("print_duration_ms", 0)),
            },
        }
        if require_server and sample.get("outcome") == "success":
            if len(transport_keys) != 1 or delivery_join_identity is None:
                raise MatrixError(
                    f"{sample['sample_id']} lacks one exact transport request-identity tuple"
                )
            for label, start, end in LIFECYCLE_BOUNDARIES:
                starts = item["lifecycle_phases"].get(start, [])
                ends = item["lifecycle_phases"].get(end, [])
                if len(starts) != 1 or len(ends) != 1 or ends[0] < starts[0]:
                    raise MatrixError(f"{sample['sample_id']} lacks exact request-identity boundary {label}")
                item["boundaries"][label] = ends[0] - starts[0]
            for label, start, end in DELIVERY_BOUNDARIES:
                starts = item["delivery_phases"].get(start, [])
                ends = item["delivery_phases"].get(end, [])
                if len(starts) != 1 or len(ends) != 1 or ends[0] < starts[0]:
                    raise MatrixError(f"{sample['sample_id']} lacks exact request-identity boundary {label}")
                item["boundaries"][label] = ends[0] - starts[0]
            capture_start = capture.get("capture_start_uptime_ms")
            received = item["lifecycle_phases"].get("MCP.ToolCall.Received", [])
            writes = item["delivery_phases"].get("transport_write_completed", [])
            if not isinstance(capture_start, (int, float)) or len(received) != 1 or len(writes) != 1:
                raise MatrixError(f"{sample['sample_id']} lacks exact request-identity boundary s0_s9_server_total_ms")
            received_uptime = float(capture_start) + received[0]
            if writes[0] < received_uptime:
                raise MatrixError(f"{sample['sample_id']} has negative request-identity boundary s0_s9_server_total_ms")
            item["boundaries"]["s0_s9_server_total_ms"] = writes[0] - received_uptime
        evidence.append(item)
    return evidence


def per_request_stage_totals(item: dict[str, Any]) -> tuple[dict[str, float], dict[str, int], list[dict[str, Any]]]:
    totals: defaultdict[str, float] = defaultdict(float)
    spans: defaultdict[str, int] = defaultdict(int)
    relevant_buckets = []
    for bucket in item["stage_buckets"]:
        stage = str(bucket.get("stage_name") or "")
        if stage not in LEAF_STAGES and stage not in INCLUSIVE_STAGES:
            continue
        totals[stage] += float(bucket.get("total_ms", 0))
        spans[stage] += int(bucket.get("sample_count", 0))
        relevant_buckets.append(bucket)
    return dict(totals), dict(spans), relevant_buckets


def signed_parent_minus_children_residual(
    parent_ms: float,
    child_total_ms: float,
    *,
    envelope: str,
    request_id: str,
) -> float:
    """Preserve signed residuals; reject overlap beyond aggregate rounding noise.

    Server aggregates are serialized to 0.001 ms. The widest current residual
    subtracts fewer than ten rounded terms, so 0.01 ms bounds accumulated
    serialization noise without concealing measurable parent/child overlap.
    """
    residual = parent_ms - child_total_ms
    if residual < -RESIDUAL_OVERLAP_TOLERANCE_MS:
        raise MatrixError(
            f"{request_id} has invalid {envelope} residual: "
            f"parent={parent_ms:.6f}ms children={child_total_ms:.6f}ms "
            f"residual={residual:.6f}ms tolerance={RESIDUAL_OVERLAP_TOLERANCE_MS:.3f}ms"
        )
    return residual


def summarize_request_values(
    values: dict[tuple[tuple[str, str, str, str], str], list[tuple[float, int]]]
) -> list[dict[str, Any]]:
    result = []
    for (key, stage), observations in values.items():
        durations = [value for value, _ in observations]
        result.append({
            "cohort": cohort_payload(key),
            "stage": stage,
            "request_count": len(durations),
            "span_count": sum(spans for _, spans in observations),
            "p50_ms": round(percentile(durations, 0.5), 3),
            "p95_ms": round(percentile(durations, 0.95), 3),
            "total_ms": round(sum(durations), 3),
        })
    return sorted(result, key=lambda item: (item["p50_ms"], item["p95_ms"]), reverse=True)


def stage_and_boundary_summaries(evidence: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    leaf_values: defaultdict[tuple[tuple[str, str, str, str], str], list[tuple[float, int]]] = defaultdict(list)
    parent_values: defaultdict[tuple[tuple[str, str, str, str], str], list[tuple[float, int]]] = defaultdict(list)
    boundary_values: defaultdict[tuple[tuple[str, str, str, str], str], list[tuple[float, int]]] = defaultdict(list)
    boundary_names = {
        "s0_s1_permit_wait_ms": "Boundary.S0S1.PermitWait",
        "s1_s2_pre_provider_ms": "Boundary.S1S2.PreProvider",
        "s2_s3_provider_ms": "Boundary.S2S3.Provider",
        "s3_s4_pre_format_ms": "Boundary.S3S4.PreFormat",
        "s4_s5_format_ms": "Boundary.S4S5.Format",
        "s5_s6_completion_observers_ms": "Boundary.S5S6.CompletionObservers",
        "s6_s7_handler_handoff_ms": "Boundary.S6S7.HandlerHandoff",
        "s7_s8_sdk_encode_ms": "Boundary.S7S8.SDKEncode",
        "s8_s9_transport_write_ms": "Boundary.S8S9.TransportWrite",
        "handler_to_write_ms": "Boundary.S7S9.HandlerToWrite",
        "s0_s9_server_total_ms": "Boundary.S0S9.ServerTotal",
        "c0_c1_client_call_ms": "Boundary.C0C1.ClientCall",
        "c1_c2_client_output_ms": "Boundary.C1C2.ClientOutput",
        "c0_c2_client_total_ms": "Boundary.C0C2.ClientTotal",
    }
    for item in evidence:
        sample = item["sample"]
        if sample.get("phase") != "recorded" or sample.get("outcome") != "success":
            continue
        key = cohort_key(sample)
        totals, spans, _ = per_request_stage_totals(item)
        for stage, duration in totals.items():
            target = parent_values if stage in INCLUSIVE_STAGES else leaf_values
            target[(key, stage)].append((duration, spans.get(stage, 0)))
        request_id = str(sample.get("sample_id") or sample.get("app_invocation_id") or "unknown-request")
        tree = totals.get("EditFlow.FormattedOutput.SearchTreeAssembly")
        if tree is not None:
            snippet = totals.get("EditFlow.FormattedOutput.SearchSnippetAssembly", 0)
            residual = signed_parent_minus_children_residual(
                tree,
                snippet,
                envelope="EditFlow.FormattedOutput.SearchTreeAssembly",
                request_id=request_id,
            )
            leaf_values[(key, DERIVED_SEARCH_TREE_STAGE)].append((residual, spans.get("EditFlow.FormattedOutput.SearchTreeAssembly", 0)))
        acquire = totals.get("EditFlow.Search.WorkspaceReadinessAcquireGate", 0)
        scope = totals.get("EditFlow.Search.RootScopeAvailabilityGate", 0)
        if acquire > 0 or scope > 0:
            validation = totals.get("EditFlow.Search.WorkspaceReadinessValidationGate", 0)
            residual = signed_parent_minus_children_residual(
                acquire + scope,
                validation,
                envelope="EditFlow.Search.ReadinessAndScopeGates",
                request_id=request_id,
            )
            leaf_values[(key, DERIVED_SEARCH_READINESS_SCOPE_STAGE)].append((
                residual,
                spans.get("EditFlow.Search.WorkspaceReadinessAcquireGate", 0)
                    + spans.get("EditFlow.Search.RootScopeAvailabilityGate", 0),
            ))
        for metric, stage in boundary_names.items():
            if metric in item["boundaries"]:
                boundary_values[(key, stage)].append((float(item["boundaries"][metric]), 1))
    return (
        summarize_request_values(leaf_values),
        summarize_request_values(parent_values),
        summarize_request_values(boundary_values),
    )


def client_summaries(evidence: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: defaultdict[tuple[str, str, str, str], dict[str, list[float]]] = defaultdict(
        lambda: defaultdict(list)
    )
    for item in evidence:
        sample = item["sample"]
        if sample.get("phase") != "recorded" or sample.get("outcome") != "success":
            continue
        trace = item["trace"]
        key = cohort_key(sample)
        call = float(trace.get("call_duration_ms", 0))
        output = float(trace.get("print_duration_ms", 0))
        grouped[key]["call_ms"].append(call)
        grouped[key]["print_ms"].append(output)
        grouped[key]["total_ms"].append(call + output)
    return [
        {
            "cohort": cohort_payload(key),
            **{
                metric: {
                    "p50_ms": round(percentile(values, 0.5), 3),
                    "p95_ms": round(percentile(values, 0.95), 3),
                    "sample_count": len(values),
                }
                for metric, values in metrics.items()
            },
        }
        for key, metrics in sorted(grouped.items())
    ]


def boundary_denominators(
    evidence: list[dict[str, Any]], metric: str, interval_name: str,
) -> list[dict[str, Any]]:
    grouped: defaultdict[tuple[str, str, str, str], list[float]] = defaultdict(list)
    for item in evidence:
        sample = item["sample"]
        if sample.get("phase") == "recorded" and sample.get("outcome") == "success":
            value = item["boundaries"].get(metric)
            if value is not None:
                grouped[cohort_key(sample)].append(float(value))
    return [
        {
            "cohort": cohort_payload(key),
            "interval_name": interval_name,
            "p50_ms": round(percentile(values, 0.5), 3),
            "p95_ms": round(percentile(values, 0.95), 3),
            "sample_count": len(values),
        }
        for key, values in sorted(grouped.items())
    ]


def attribution_summary(evidence: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: defaultdict[tuple[str, str, str], dict[str, dict[str, list[float]]]] = defaultdict(
        lambda: defaultdict(lambda: defaultdict(list))
    )
    metrics = [label for label, _, _ in LIFECYCLE_BOUNDARIES if label.startswith(("s5_", "s6_"))]
    metrics += [label for label, _, _ in DELIVERY_BOUNDARIES if label != "handler_to_write_ms"]
    metrics += ["c0_c1_client_call_ms", "c1_c2_client_output_ms"]
    for item in evidence:
        sample = item["sample"]
        if sample.get("phase") != "recorded" or sample.get("outcome") != "success":
            continue
        key = (sample["row_id"], sample["client_mode"], sample["cohort_kind"])
        for metric in metrics:
            if metric in item["boundaries"]:
                grouped[key][sample["format"]][metric].append(float(item["boundaries"][metric]))
    result = []
    for key, formats in sorted(grouped.items()):
        per_format = {
            fmt: {
                metric: {
                    "p50_ms": round(percentile(values, 0.5), 3),
                    "p95_ms": round(percentile(values, 0.95), 3),
                    "sample_count": len(values),
                }
                for metric, values in values_by_metric.items()
            }
            for fmt, values_by_metric in formats.items()
        }
        deltas = {}
        for metric in metrics:
            formatted = per_format.get("formatted", {}).get(metric, {}).get("p50_ms")
            raw = per_format.get("raw", {}).get(metric, {}).get("p50_ms")
            if formatted is not None and raw is not None:
                deltas[metric] = round(formatted - raw, 3)
        result.append({
            "row_id": key[0], "client_mode": key[1], "cohort_kind": key[2],
            "per_format": per_format, "formatted_minus_raw_p50_ms": deltas,
        })
    return result


def stage_total(item: dict[str, Any], stage: str, scan_kind: str | None = None) -> float:
    total = 0.0
    for bucket in item["stage_buckets"]:
        if bucket.get("stage_name") != stage:
            continue
        if scan_kind is not None and parse_dimensions(str(bucket.get("sanitized_dimensions") or "")).get("scanKind") != scan_kind:
            continue
        total += float(bucket.get("total_ms", 0))
    return total


def remainder_summaries(evidence: list[dict[str, Any]]) -> list[dict[str, Any]]:
    values: defaultdict[tuple[tuple[str, str, str, str], str, str | None], list[float]] = defaultdict(list)
    provider_children = {
        "EditFlow.FileTree.ProviderArgumentParsing", "EditFlow.FileTree.ProviderRequestMetadata",
        "EditFlow.FileTree.ProviderLookupContextResolution", "EditFlow.FileTree.ProviderIngressFreshnessWait",
        "EditFlow.FileTree.ProviderSelectionDrain", "EditFlow.FileTree.DTOAssembly",
        "EditFlow.FileTree.ProviderValueEncoding",
    }
    bridge_children = {
        "EditFlow.FileTree.SettingsSnapshot", "EditFlow.FileTree.SelectionPhysicalization",
        "EditFlow.FileTree.SnapshotConstruction", "EditFlow.FileTree.CodemapMarkerProjection",
        "EditFlow.FileTree.LogicalProjection", "EditFlow.FileTree.RenderAttempt",
    }
    formatted_children = {
        stage for stage in LEAF_STAGES if stage.startswith("EditFlow.FormattedOutput.")
    } - {"EditFlow.FormattedOutput.SearchSnippetAssembly"}
    observer_children = DIRECT_STAGE_CHILDREN["EditFlow.MCPToolCall.CompletionObservers"]
    search_workspace_children = DIRECT_STAGE_CHILDREN["EditFlow.Search.ProviderWorkspaceSearchAwait"]
    for item in evidence:
        sample = item["sample"]
        if sample.get("phase") != "recorded" or sample.get("outcome") != "success":
            continue
        key = cohort_key(sample)
        request_id = str(sample.get("sample_id") or sample.get("app_invocation_id") or "unknown-request")
        totals, _, _ = per_request_stage_totals(item)
        bridge_total = stage_total(item, "EditFlow.FileTree.BridgeTotal")
        provider_child_total = sum(totals.get(name, 0) for name in provider_children)
        if bridge_total > 0:
            provider_child_total += bridge_total
        else:
            # The roots branch builds its settings/snapshot directly without the bridge envelope.
            provider_child_total += totals.get("EditFlow.FileTree.SettingsSnapshot", 0)
            provider_child_total += totals.get("EditFlow.FileTree.SnapshotConstruction", 0)
        formatted_child_total = sum(
            totals.get(name, 0)
            for name in formatted_children
            if name != "EditFlow.FormattedOutput.SearchTreeAssembly"
        )
        # The tree envelope already contains snippets; use its inclusive duration for
        # the FormatResult remainder while ranking tree-minus-snippet separately.
        formatted_child_total += stage_total(item, "EditFlow.FormattedOutput.SearchTreeAssembly")
        cases = [
            (
                "EditFlow.Search.ProviderWorkspaceSearchAwait",
                sum(totals.get(name, 0) for name in search_workspace_children),
                DERIVED_SEARCH_CORE_STAGE,
            ),
            ("EditFlow.FileTree.ProviderTotal", provider_child_total, None),
            ("EditFlow.FileTree.BridgeTotal", sum(totals.get(name, 0) for name in bridge_children)
             + stage_total(item, "EditFlow.FileTree.RenderIndexPreparation", "root_filter"), None),
            ("EditFlow.FileTree.RenderAttempt", stage_total(item, "EditFlow.FileTree.RenderTokenEstimation")
             + stage_total(item, "EditFlow.FileTree.RenderIndexPreparation", "selected_folder_index"), None),
            ("EditFlow.MCPToolCall.FormatResult", formatted_child_total, None),
            ("EditFlow.MCPToolCall.CompletionObservers", sum(totals.get(name, 0) for name in observer_children), None),
        ]
        for envelope, child_total, derived_stage in cases:
            envelope_total = stage_total(item, envelope)
            if envelope_total > 0:
                values[(key, envelope, derived_stage)].append(signed_parent_minus_children_residual(
                    envelope_total,
                    child_total,
                    envelope=envelope,
                    request_id=request_id,
                ))
    return [
        {
            "cohort": cohort_payload(key), "envelope": envelope,
            **({"stage": derived_stage} if derived_stage else {}),
            "request_count": len(durations),
            "p50_ms": round(percentile(durations, 0.5), 3),
            "p95_ms": round(percentile(durations, 0.95), 3),
            "total_ms": round(sum(durations), 3),
        }
        for (key, envelope, derived_stage), durations in sorted(
            values.items(), key=lambda item: (item[0][0], item[0][1], item[0][2] or "")
        )
    ]


def response_signature(samples: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    grouped: defaultdict[str, set[tuple[Any, ...]]] = defaultdict(set)
    counts: defaultdict[str, int] = defaultdict(int)
    for sample in samples:
        if sample.get("phase") != "recorded":
            continue
        if sample.get("cohort_kind") == "wi3":
            key = "/".join((
                "wi3", str(sample.get("workload_matrix_id")),
                str(sample.get("connection_cohort")), str(sample.get("sample_ordinal")),
                sample["row_id"], sample["format"], sample["client_mode"],
            ))
        else:
            key = "ordinary/" + baseline_key(sample)
        trace = sample["client_trace"][0]
        contract = (
            sample["response_sha256"], int(sample["response_byte_count"]),
            trace.get("output_format"), trace.get("outcome"), bool(trace.get("is_error")),
            int(trace.get("content_block_count", 0)),
            int(trace.get("text_content_block_count", 0)),
            int(trace.get("returned_text_bytes", 0)),
        )
        grouped[key].add(contract)
        counts[key] += 1
    result = {}
    for key, values in grouped.items():
        if len(values) != 1:
            raise MatrixError(f"response or ordered content-block contract changed within paired cohort: {key}")
        digest, size, output_format, outcome, is_error, blocks, text_blocks, text_bytes = next(iter(values))
        result[key] = {
            "sha256": digest, "byte_count": size, "sample_count": counts[key],
            "output_format": output_format, "outcome": outcome, "is_error": is_error,
            "content_block_count": blocks, "text_content_block_count": text_blocks,
            "returned_text_bytes": text_bytes,
        }
    return result


def combine_stage_attribution_reports(reports: list[dict[str, Any]]) -> dict[str, Any]:
    per_stage: defaultdict[str, dict[str, int]] = defaultdict(
        lambda: {"identified_sample_count": 0, "unidentified_sample_count": 0}
    )
    missing: set[str] = set()
    for report in reports:
        missing.update(report.get("missing_successful_request_ids", []))
        for row in report.get("per_stage", []):
            stage = str(row["stage"])
            per_stage[stage]["identified_sample_count"] += int(row["identified_sample_count"])
            per_stage[stage]["unidentified_sample_count"] += int(row["unidentified_sample_count"])
    unidentified = sum(row["unidentified_sample_count"] for row in per_stage.values())
    return {
        "status": "complete" if not missing and unidentified == 0 else "invalid",
        "identified_sample_count": sum(row["identified_sample_count"] for row in per_stage.values()),
        "unidentified_sample_count": unidentified,
        "missing_successful_request_ids": sorted(missing),
        "per_stage": [
            {"stage": stage, **counts} for stage, counts in sorted(per_stage.items())
        ],
    }


def load_server_request_evidence(
    input_dir: Path,
    manifest: dict[str, Any],
    samples: list[dict[str, Any]],
    discarded_warmups: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    index_path = input_dir / "server-capture.json"
    index = load_json(index_path)
    declared_layout = manifest.get("server_capture_layout")
    index_layout = index.get("layout")
    if declared_layout == SEGMENTED_CAPTURE_LAYOUT and index_layout != SEGMENTED_CAPTURE_LAYOUT:
        raise MatrixError("segmented run manifest points to a non-segmented capture index")
    if declared_layout not in (None, index_layout):
        raise MatrixError("server capture manifest/index layout mismatch")
    if index_layout != SEGMENTED_CAPTURE_LAYOUT:
        capture = find_named_object(index, "capture") or {}
        validate_capture_integrity(capture)
        delivery_drops = int(find_named_object(index, "delivery_dropped_event_count") or 0)
        if delivery_drops:
            raise MatrixError(f"server delivery capture dropped {delivery_drops} events")
        delivery_events = find_named_object(index, "delivery_events") or []
        validate_delivery_terminals(delivery_events, capture.get("lifecycle_events", []), samples)
        attribution = stage_attribution_report(samples, capture, require_server=True)
        return joined_request_evidence(samples, capture, delivery_events, True), attribution

    plan = manifest.get("capture_segment_plan")
    if not isinstance(plan, list):
        raise MatrixError("segmented run manifest omitted its capture plan")
    verified_plan_hash = capture_segment_plan_sha256(plan)
    if manifest.get("capture_segment_plan_sha256") != verified_plan_hash:
        raise MatrixError("segmented run manifest capture plan hash mismatch")
    if manifest.get("capture_segment_index_sha256") != sha256_bytes(index_path.read_bytes()):
        raise MatrixError("segmented run capture index hash mismatch")
    validate_segment_index_contract(index, plan)
    if manifest.get("status") != "completed":
        raise MatrixError("segmented run manifest is not complete")
    if manifest.get("accepted_capture_segment_count") != len(plan) \
            or manifest.get("completed_capture_segment_count") != len(plan):
        raise MatrixError("segmented run did not complete every planned segment")
    all_executed = samples + discarded_warmups
    by_segment: defaultdict[str, list[dict[str, Any]]] = defaultdict(list)
    for sample in all_executed:
        segment_id = sample.get("capture_segment_id")
        if not segment_id:
            raise MatrixError("segmented run sample omitted capture_segment_id")
        by_segment[str(segment_id)].append(sample)
    evidence: list[dict[str, Any]] = []
    reports: list[dict[str, Any]] = []
    root = input_dir.resolve()
    seen_invocations: set[str] = set()
    for entry in index["segments"]:
        segment_id = str(entry["segment_id"])
        relative = Path(str(entry.get("artifact_path", "")))
        artifact = (input_dir / relative).resolve()
        try:
            artifact.relative_to(root)
        except ValueError as error:
            raise MatrixError(f"capture segment artifact escapes output directory: {relative}") from error
        if not artifact.is_file():
            raise MatrixError(f"capture segment artifact is missing: {relative}")
        if sha256_bytes(artifact.read_bytes()) != entry.get("artifact_sha256"):
            raise MatrixError(f"capture segment artifact hash mismatch: {segment_id}")
        segment_samples = by_segment.pop(segment_id, [])
        expected_invocations = [canonical_invocation_id(value) for value in entry.get("invocation_ids", [])]
        actual_invocations = [canonical_invocation_id(sample["invocation_id"]) for sample in segment_samples]
        if len(actual_invocations) != len(set(actual_invocations)) \
                or sorted(actual_invocations) != sorted(expected_invocations):
            raise MatrixError(f"capture segment invocation membership mismatch: {segment_id}")
        validate_segment_sample_coordinates(entry, segment_samples)
        duplicate = seen_invocations.intersection(actual_invocations)
        if duplicate:
            raise MatrixError("invocation identity appears in multiple capture segments")
        seen_invocations.update(actual_invocations)
        payload = load_json(artifact)
        classified_setup_ids = validate_capture_request_membership(payload, segment_samples)
        if entry.get("classified_setup_request_ids") != classified_setup_ids:
            raise MatrixError(f"capture segment setup-request classification mismatch: {segment_id}")
        validate_capture_segment_payload(payload, segment_samples, manifest["configuration"])
        capture = find_named_object(payload, "capture") or {}
        delivery_events = find_named_object(payload, "delivery_events") or []
        recorded = [sample for sample in segment_samples if sample.get("phase") == "recorded"]
        reports.append(stage_attribution_report(recorded, capture, require_server=True))
        evidence.extend(joined_request_evidence(recorded, capture, delivery_events, True))
    if by_segment:
        raise MatrixError("run contains samples assigned to an unplanned capture segment")
    if len(seen_invocations) != len(all_executed):
        raise MatrixError("segmented capture invocation coverage is incomplete")
    attribution = combine_stage_attribution_reports(reports)
    if attribution["status"] != "complete":
        raise MatrixError("segmented stage attribution merge is incomplete")
    return evidence, attribution


def aggregate(input_dir: Path) -> dict[str, Any]:
    run = load_json(input_dir / "run.json")
    manifest = load_json(input_dir / "manifest.json")
    matrix_path = Path(manifest.get("matrix", default_matrix()))
    authority = load_wi3_authority(matrix_path)
    samples = list(run.get("samples", []))
    discarded_warmups = list(run.get("discarded_warmups", []))
    validate_connection_cohorts(samples)
    cohort_kinds = {sample.get("cohort_kind") for sample in samples}
    if cohort_kinds != {manifest.get("cohort_kind")} and cohort_kinds != {manifest.get("cohort_kind"), "wi3"}:
        raise MatrixError("aggregation refuses mixed cold/warm cohort kinds")
    validate_trace_records(samples + discarded_warmups, manifest["configuration"])
    validate_format_pairs(samples)

    require_server = manifest["configuration"] in {"debug", "optimized"}
    if require_server:
        if manifest.get("server_capture_mode") != SERVER_CAPTURE_MODE:
            raise MatrixError("run manifest omitted the authoritative server capture mode")
        if not (input_dir / "server-capture.json").is_file():
            raise MatrixError(f"{manifest['configuration']} aggregation requires server capture")
        evidence, attribution = load_server_request_evidence(
            input_dir, manifest, samples, discarded_warmups,
        )
    else:
        attribution = {
            "status": "not_applicable_client_only",
            "identified_sample_count": 0,
            "unidentified_sample_count": 0,
            "missing_successful_request_ids": [],
            "per_stage": [],
        }
        evidence = joined_request_evidence(samples, {}, [], require_server=False)
    leaves, parents, boundary_rankings = stage_and_boundary_summaries(evidence)
    remainders = remainder_summaries(evidence)
    leaves.extend({
        "cohort": row["cohort"], "stage": row["stage"],
        "request_count": row["request_count"], "span_count": row["request_count"],
        "p50_ms": row["p50_ms"], "p95_ms": row["p95_ms"], "total_ms": row["total_ms"],
    } for row in remainders if row.get("stage"))
    leaves.sort(key=lambda item: (item["p50_ms"], item["p95_ms"]), reverse=True)
    client = client_summaries(evidence)
    server_denominators = boundary_denominators(
        evidence, "s0_s9_server_total_ms", "Boundary.S0S9.ServerTotal",
    )
    handler_denominators = boundary_denominators(
        evidence, "handler_to_write_ms", "Boundary.S7S9.HandlerToWrite",
    )

    work_count_files = {
        "runtime_before": input_dir / "runtime-before.json",
        "runtime_after": input_dir / "runtime-after.json",
        "admission_before": input_dir / "admission-before.json",
        "admission_after": input_dir / "admission-after.json",
    }
    present = {name for name, path in work_count_files.items() if path.is_file()}
    if present and len(present) != len(work_count_files):
        raise MatrixError("incomplete WI-3 work-count capture: " + ", ".join(sorted(set(work_count_files) - present)))
    executed_wi3 = sorted(set(run.get("executed_wi3_matrix_ids", [])))
    required_wi3 = selector_required_wi3_matrix_ids(authority)
    if present:
        wi3_work_counts = project_wi3_work_counts(
            load_json(work_count_files["runtime_before"]), load_json(work_count_files["runtime_after"]),
            load_json(work_count_files["admission_before"]), load_json(work_count_files["admission_after"]),
            authority, executed_wi3,
        )
        wi3_work_counts["availability"] = "captured"
        wi3_work_counts["selector_ready"] = executed_wi3 == required_wi3
        wi3_work_counts["selector_required_matrix_ids"] = required_wi3
    else:
        wi3_work_counts = {
            "availability": "not_captured", "authority_source": authority["source"],
            "selector_ready": False, "selector_required_matrix_ids": required_wi3,
            "workload_matrices": [
                item for item in authority["workload_matrices"] if item["id"] in set(executed_wi3)
            ],
        }

    return {
        "schema_version": SCHEMA_VERSION,
        "status": "completed",
        "configuration": manifest["configuration"],
        "cohort_kind": manifest["cohort_kind"],
        "leaf_rankings": leaves,
        "boundary_rankings": boundary_rankings,
        "inclusive_envelopes": parents,
        "selector_eligibility_denominator": "Boundary.S0S9.ServerTotal",
        "s0_s9_server_denominators": server_denominators,
        "handler_to_write_denominators": handler_denominators,
        "stage_attribution": attribution,
        "unattributed_remainders": remainders,
        "residual_policy": {
            "semantics": "signed_parent_minus_declared_children",
            "overlap_tolerance_ms": RESIDUAL_OVERLAP_TOLERANCE_MS,
            "material_negative_residual": "aggregation_refused",
        },
        "client_c0_c2": client,
        "s5_c2_attribution": attribution_summary(evidence),
        "selector": {
            "status": "refused", "selected": None,
            "refusal_reasons": ["single-configuration evidence cannot satisfy paired DEBUG + optimized-persistent gates"],
        },
        "wi3_work_counts": wi3_work_counts,
        "executed_wi3_matrix_ids": executed_wi3,
        "work_count_authority": authority["source"],
        "response_signature": response_signature(samples),
    }


def matching_key(cohort: dict[str, str], include_client_mode: bool = True) -> tuple[str, ...]:
    values = (cohort["row_id"], cohort["format"], cohort["cohort_kind"])
    return values + ((cohort["client_mode"],) if include_client_mode else ())


def mechanical_selector(
    leaves: list[dict[str, Any]],
    boundaries: list[dict[str, Any]],
    server_denominator_rows: list[dict[str, Any]],
    optimized_client_rows: list[dict[str, Any]],
) -> dict[str, Any]:
    candidates = [row for row in leaves + boundaries if row["stage"] in SELECTOR_ACTIONS and row["cohort"]["cohort_kind"] == "warm"]
    server_totals = {matching_key(row["cohort"]): row["p50_ms"] for row in server_denominator_rows}
    optimized = {
        matching_key(row["cohort"], include_client_mode=False): row["total_ms"]["p50_ms"]
        for row in optimized_client_rows
        if row["cohort"]["client_mode"] == "persistent" and row["cohort"]["cohort_kind"] == "warm"
    }
    refusal = []
    if not candidates:
        refusal.append("DEBUG candidate leaf universe is empty")
    if any(matching_key(row["cohort"]) not in server_totals for row in candidates):
        refusal.append("real MCP.ToolCall.Received to transport-write S0-S9 denominator is absent")
    if any(matching_key(row["cohort"], include_client_mode=False) not in optimized for row in candidates):
        refusal.append("matching optimized warm persistent C0-C2 denominator is absent")
    if refusal:
        return {"status": "refused", "selected": None, "refusal_reasons": sorted(set(refusal))}

    qualifying = []
    for row in candidates:
        server = server_totals[matching_key(row["cohort"])]
        client = optimized[matching_key(row["cohort"], include_client_mode=False)]
        absolute = row["p50_ms"] >= 10 and server > 0 and row["p50_ms"] / server >= 0.15
        tail = row["p95_ms"] >= 25
        client_share = client > 0 and row["p50_ms"] / client >= 0.15
        if absolute or tail or client_share:
            qualified = dict(row)
            qualified["eligibility_denominator_interval"] = "Boundary.S0S9.ServerTotal"
            qualified["s0_s9_server_total_p50_ms"] = server
            qualified["optimized_persistent_c0_c2_p50_ms"] = client
            qualifying.append(qualified)
    qualifying.sort(key=lambda item: (item["p50_ms"], item["p95_ms"]), reverse=True)
    if not qualifying:
        return {"status": "no_qualifying_stage", "selected": None, "dominant_leaf": None,
                "policy": "no stage qualifies; stop after investigation"}
    dominant = qualifying[0]
    return {"status": "selected", "selected": SELECTOR_ACTIONS[dominant["stage"]],
            "dominant_leaf": dominant, "policy": "first matching dominant cost by request-level exclusive time"}


def authoritative_paired_server_identity(
    debug_manifest: dict[str, Any], optimized_manifest: dict[str, Any],
) -> dict[str, dict[str, Any]]:
    debug_identity = debug_manifest.get("server_app_identity")
    optimized_identity = optimized_manifest.get("server_app_identity")
    if not isinstance(debug_identity, dict) or not isinstance(optimized_identity, dict):
        raise MatrixError("paired cohort lacks authoritative server app identity/configuration")
    if debug_manifest.get("server_app_identity_end") != debug_identity \
            or optimized_manifest.get("server_app_identity_end") != optimized_identity:
        raise MatrixError("paired cohort server identity changed during collection")
    if debug_identity.get("identity_authority") != "server_process" \
            or optimized_identity.get("identity_authority") != "server_process":
        raise MatrixError("paired cohort server app identity/configuration is not authoritative")
    if debug_identity.get("app_configuration") != "debug" \
            or debug_identity.get("swift_configuration") != "debug":
        raise MatrixError("paired DEBUG cohort did not use a DEBUG server")
    if optimized_identity.get("app_configuration") != "optimized_diagnostic" \
            or optimized_identity.get("swift_configuration") != "release" \
            or optimized_identity.get("ordinary_release_artifact") is not False:
        raise MatrixError("paired optimized cohort did not use the release-optimized diagnostic server")
    if debug_identity.get("executable_sha256") == optimized_identity.get("executable_sha256"):
        raise MatrixError("paired cohorts unexpectedly used the same server executable")
    return {"debug": debug_identity, "optimized": optimized_identity}


def make_server_authorization_explicit(
    selector: dict[str, Any], server_identity: dict[str, Any],
) -> dict[str, Any]:
    result = dict(selector)
    result["server_app_configuration"] = server_identity.get("app_configuration")
    if result.get("status") == "selected" \
            and server_identity.get("app_configuration") == "optimized_diagnostic" \
            and server_identity.get("swift_configuration") == "release" \
            and server_identity.get("ordinary_release_artifact") is False \
            and server_identity.get("identity_authority") == "server_process" \
            and server_identity.get("diagnostic_surface") == "mcp_latency_v1" \
            and server_identity.get("signing_mode") == "mcp-latency-diagnostic-adhoc" \
            and server_identity.get("secure_storage_backend") == "alternate-in-memory":
        result["production_authorized"] = True
        result["authorization_note"] = (
            "authorized by paired DEBUG attribution and the verified release-optimized "
            "server/client diagnostic cohort; exactly one candidate may proceed"
        )
    else:
        result["production_authorized"] = False
    return result


def paired_aggregate(debug_dir: Path, optimized_dir: Path) -> dict[str, Any]:
    debug_manifest = load_json(debug_dir / "manifest.json")
    optimized_manifest = load_json(optimized_dir / "manifest.json")
    if debug_manifest.get("configuration") != "debug" or optimized_manifest.get("configuration") != "optimized":
        raise MatrixError("paired analysis requires DEBUG then optimized inputs")
    debug_completed = float(debug_manifest.get("completed_at_epoch", 0))
    optimized_created = float(optimized_manifest.get("created_at_epoch", 0))
    if debug_completed <= 0 or optimized_created <= debug_completed:
        raise MatrixError("paired analysis requires the completed DEBUG cohort before optimized collection")
    paired_contract_fields = (
        "commit", "source_fingerprint_sha256", "profile", "wi3_authority_sha256",
        "cohort_kind", "matrix_sha256", "sample_discipline", "client_modes",
        "server_capture_mode", "server_capture_layout", "capture_segment_contract_version",
        "capture_segment_strategy", "capture_segment_max_ordinary_invocations",
        "capture_segment_plan_sha256", "planned_capture_segment_count", "planned_row_ids",
    )
    for field in paired_contract_fields:
        if debug_manifest.get(field) != optimized_manifest.get(field):
            raise MatrixError(f"paired cohort manifest mismatch: {field}")
    if debug_manifest.get("client_modes") != ["fresh", "persistent"]:
        raise MatrixError("paired production authorization requires the canonical fresh+persistent client modes")
    verified_plan_hashes: list[str] = []
    for label, manifest in (("DEBUG", debug_manifest), ("optimized", optimized_manifest)):
        if manifest.get("status") != "completed":
            raise MatrixError(f"paired {label} cohort is not complete")
        if manifest.get("server_capture_layout") != SEGMENTED_CAPTURE_LAYOUT:
            raise MatrixError(f"paired {label} cohort did not use the canonical segmented capture layout")
        if manifest.get("capture_segment_contract_version") != SEGMENTED_CAPTURE_CONTRACT_VERSION:
            raise MatrixError(f"paired {label} cohort has an unsupported capture segment contract")
        plan = manifest.get("capture_segment_plan")
        if not isinstance(plan, list):
            raise MatrixError(f"paired {label} cohort omitted its capture segment plan")
        verified_plan_hash = capture_segment_plan_sha256(plan)
        if manifest.get("capture_segment_plan_sha256") != verified_plan_hash:
            raise MatrixError(f"paired {label} cohort capture segment plan hash mismatch")
        verified_plan_hashes.append(verified_plan_hash)
        planned_count = manifest.get("planned_capture_segment_count")
        if planned_count != len(plan) or manifest.get("completed_capture_segment_count") != planned_count:
            raise MatrixError(f"paired {label} cohort omitted a capture segment")
    if len(set(verified_plan_hashes)) != 1:
        raise MatrixError("paired cohorts have different verified capture segment plans")
    identities = authoritative_paired_server_identity(debug_manifest, optimized_manifest)
    optimized_artifact = optimized_manifest.get("optimized_server_artifact")
    if not isinstance(optimized_artifact, dict):
        raise MatrixError("paired optimized cohort omitted its server artifact manifest")
    validate_runtime_artifact_identity(identities["optimized"], optimized_artifact)
    if optimized_artifact.get("commit") != optimized_manifest.get("commit") \
            or optimized_artifact.get("source_fingerprint_sha256") != optimized_manifest.get("source_fingerprint_sha256"):
        raise MatrixError("optimized artifact source identity does not match paired collection")
    debug_provenance = identities["debug"].get("provenance")
    if not isinstance(debug_provenance, dict) \
            or debug_provenance.get("commit") != debug_manifest.get("commit") \
            or debug_provenance.get("source_fingerprint_sha256") != debug_manifest.get("source_fingerprint_sha256"):
        raise MatrixError("DEBUG server provenance does not match paired collection sources")
    debug_fixture = (debug_manifest.get("fixture_manifest") or {}).get("digest")
    optimized_fixture = (optimized_manifest.get("fixture_manifest") or {}).get("digest")
    if debug_fixture != optimized_fixture:
        raise MatrixError("paired fixture digest mismatch")
    debug = aggregate(debug_dir)
    optimized = aggregate(optimized_dir)
    if debug["response_signature"] != optimized["response_signature"]:
        raise MatrixError("DEBUG/optimized exact response parity mismatch")
    if debug["wi3_work_counts"].get("availability") != "captured":
        raise MatrixError("paired selector requires DEBUG WI-3 capacity/work-count evidence")
    required_wi3 = debug["wi3_work_counts"].get("selector_required_matrix_ids", [])
    if debug.get("executed_wi3_matrix_ids") != required_wi3:
        raise MatrixError("paired selector requires every enabled DEBUG WI-3 admission cohort")
    if optimized.get("executed_wi3_matrix_ids") != required_wi3:
        raise MatrixError("paired selector requires matching optimized WI-3 admission cohorts")
    debug_selector = mechanical_selector(
        debug["leaf_rankings"], debug["boundary_rankings"],
        debug["s0_s9_server_denominators"], optimized["client_c0_c2"],
    )
    optimized_selector = mechanical_selector(
        optimized["leaf_rankings"], optimized["boundary_rankings"],
        optimized["s0_s9_server_denominators"], optimized["client_c0_c2"],
    )
    if debug_selector.get("status") != "selected" \
            or optimized_selector.get("status") != "selected" \
            or debug_selector.get("selected") != optimized_selector.get("selected"):
        selector = {
            "status": "refused",
            "selected": None,
            "production_authorized": False,
            "debug_selector": debug_selector,
            "optimized_selector": optimized_selector,
            "refusal_reasons": [
                "DEBUG attribution and release-optimized server/client evidence did not select the same candidate"
            ],
        }
    else:
        selector = dict(optimized_selector)
        selector["debug_attribution"] = debug_selector
        selector = make_server_authorization_explicit(selector, identities["optimized"])
    return {
        "schema_version": SCHEMA_VERSION, "status": "completed", "paired": True,
        "server_app_identities": identities,
        "debug": debug, "optimized": optimized, "selector": selector,
    }


def matrix_row_by_id(matrix_path: Path, row_id: str, variables: dict[str, str]) -> dict[str, Any]:
    for source in load_json(matrix_path).get("rows", []):
        if source.get("id") == row_id:
            return replace_variables(source, variables)
    raise MatrixError(f"WI-3 execution references unknown row: {row_id}")


def run_concurrent_batch_process(
    cli: Path,
    window_id: int,
    row: dict[str, Any],
    request_count: int,
    capture: Path,
    timeout: float,
    workload_matrix_id: str,
    connection_ordinal: int,
    generation: int = 0,
) -> list[dict[str, Any]]:
    cohort = f"wi3-{workload_matrix_id}-g{generation}-c{connection_ordinal}"
    trace = (capture / "traces" / f"{cohort}.jsonl").resolve()
    trace.parent.mkdir(parents=True, exist_ok=True)
    requests = []
    request_metadata = []
    for ordinal in range(request_count):
        invocation_id = new_invocation_id()
        output_path = (capture / "responses" / f"{cohort}-s{ordinal}-{invocation_id}.out").resolve()
        output_path.parent.mkdir(parents=True, exist_ok=True)
        requests.append({
            "invocation_id": invocation_id,
            "tool": row["tool"],
            "output_format": "formatted",
            "output_path": str(output_path),
            "arguments": invocation_arguments(row, "formatted", window_id, invocation_id),
        })
        request_metadata.append((ordinal, invocation_id, output_path))
    batch_path = (capture / "batches" / f"{cohort}.json").resolve()
    batch_path.parent.mkdir(parents=True, exist_ok=True)
    save_json(batch_path, requests)
    env = {**os.environ, TRACE_ENV: str(trace)}
    process = run_cli(
        [str(cli), "-w", str(window_id), "--latency-concurrent-batch", str(batch_path)],
        cwd=repo_root(), env=env, timeout=timeout * max(1, request_count),
    )
    traces = read_trace(trace)
    samples = []
    for ordinal, invocation_id, output_path in request_metadata:
        response = output_path.read_bytes() if output_path.exists() else b""
        invocation_row = {**row, "_repeat": -2, "_sample": ordinal}
        sample = create_sample(
            invocation_row, "formatted", "persistent_concurrent", cohort, "wi3",
            invocation_id, response, process, traces, None, "recorded", workload_matrix_id,
        )
        sample["trace_file"] = str(trace.relative_to(capture))
        samples.append(sample)
    return samples


def run_wi3_cohorts(
    cli: Path,
    window_id: int,
    matrix_path: Path,
    authority: dict[str, Any],
    variables: dict[str, str],
    capture: Path,
    timeout: float,
) -> tuple[list[dict[str, Any]], list[str], list[dict[str, Any]]]:
    samples: list[dict[str, Any]] = []
    executed: list[str] = []
    discarded_invalid: list[dict[str, Any]] = []
    for workload in authority["workload_matrices"]:
        execution = workload.get("execution")
        if not isinstance(execution, dict) or execution.get("enabled_by_default") is not True:
            continue
        workload_id = workload["id"]
        row = matrix_row_by_id(matrix_path, str(execution["row_id"]), variables)
        mode = execution.get("mode")
        for generation in range(2):
            generation_samples: list[dict[str, Any]] = []
            if mode == "same_connection_burst":
                generation_samples.extend(run_concurrent_batch_process(
                    cli, window_id, row, int(execution["request_count"]), capture,
                    timeout, workload_id, 0, generation,
                ))
            elif mode == "distinct_connections":
                connection_count = int(execution["connection_count"])
                with ThreadPoolExecutor(max_workers=connection_count) as executor:
                    futures = [
                        executor.submit(
                            run_concurrent_batch_process, cli, window_id, row, 1,
                            capture, timeout, workload_id, ordinal, generation,
                        )
                        for ordinal in range(connection_count)
                    ]
                    for future in futures:
                        generation_samples.extend(future.result())
            else:
                raise MatrixError(f"unsupported WI-3 execution mode: {mode}")
            invalid = invalid_connection_cohorts(generation_samples)
            if not invalid:
                samples.extend(generation_samples)
                executed.append(workload_id)
                break
            for sample in generation_samples:
                sample["discard_reason"] = next(iter(invalid.values()))
            discarded_invalid.extend(generation_samples)
        else:
            raise MatrixError(f"WI-3 workload {workload_id} remained invalid after re-cohorting")
    validate_connection_cohorts(samples)
    return samples, executed, discarded_invalid


def expanded_rows(rows: list[dict[str, Any]], repeats: int, samples_per_repeat: int) -> list[dict[str, Any]]:
    return [
        {**row, "_repeat": repeat, "_sample": sample}
        for repeat in range(repeats)
        for sample in range(samples_per_repeat)
        for row in rows
    ]


def warmup_rows(rows: list[dict[str, Any]], warmups: int) -> list[dict[str, Any]]:
    return [{**row, "_repeat": -1, "_sample": sample} for sample in range(warmups) for row in rows]


def expected_ordinary_segment_coordinates(
    row: dict[str, Any], client_mode: str, discipline: dict[str, Any], terminal: bool,
) -> list[list[Any]]:
    coordinates: list[list[Any]] = []
    if terminal:
        for output_format in row["formats"]:
            coordinates.append([row["id"], client_mode, output_format, "recorded", 0, 0])
        return coordinates
    for sample in range(discipline["warmups"]):
        for output_format in row["formats"]:
            coordinates.append([row["id"], client_mode, output_format, "warmup", -1, sample])
    for repeat in range(discipline["repeats"]):
        for sample in range(discipline["samples_per_repeat"]):
            for output_format in row["formats"]:
                coordinates.append([row["id"], client_mode, output_format, "recorded", repeat, sample])
    return coordinates


def sample_coordinate(sample: dict[str, Any]) -> tuple[Any, ...]:
    return (
        sample.get("row_id"), sample.get("client_mode"), sample.get("format"),
        sample.get("phase"), sample.get("repeat_ordinal"), sample.get("sample_ordinal"),
    )


def validate_segment_sample_coordinates(spec: dict[str, Any], samples: list[dict[str, Any]]) -> None:
    expected = Counter(tuple(item) for item in spec.get("expected_sample_coordinates", []))
    actual = Counter(sample_coordinate(sample) for sample in samples)
    if actual != expected:
        missing = list((expected - actual).elements())[:5]
        extra = list((actual - expected).elements())[:5]
        raise MatrixError(
            f"segment {spec['segment_id']} sample coordinate mismatch; "
            f"missing={missing}, extra={extra}"
        )


def capture_segment_plan(
    rows: list[dict[str, Any]],
    client_modes: list[str],
    discipline: dict[str, Any],
    authority: dict[str, Any],
    include_wi3: bool,
) -> list[dict[str, Any]]:
    plan: list[dict[str, Any]] = []
    for row in rows:
        terminal = row["expected_outcome"] == "expected_timeout"
        for client_mode in client_modes:
            coordinates = expected_ordinary_segment_coordinates(
                row, client_mode, discipline, terminal,
            )
            ordinary_invocations = len(coordinates)
            if ordinary_invocations > SEGMENTED_CAPTURE_MAX_ORDINARY_INVOCATIONS:
                raise MatrixError(
                    f"row {row['id']} requires {ordinary_invocations} invocations, exceeding "
                    f"the segmented capture bound {SEGMENTED_CAPTURE_MAX_ORDINARY_INVOCATIONS}"
                )
            ordinal = len(plan)
            plan.append({
                "ordinal": ordinal,
                "segment_id": f"{ordinal:03d}-ordinary-{client_mode}-{row['id']}",
                "kind": "expected_terminal" if terminal else "ordinary",
                "client_mode": client_mode,
                "row_ids": [row["id"]],
                "workload_matrix_id": None,
                "expected_invocation_count": ordinary_invocations,
                "expected_sample_coordinates": coordinates,
            })
    if include_wi3:
        for workload in authority["workload_matrices"]:
            execution = workload.get("execution")
            if not isinstance(execution, dict) or execution.get("enabled_by_default") is not True:
                continue
            ordinal = len(plan)
            if execution.get("mode") == "same_connection_burst":
                invocation_count = int(execution["request_count"])
                sample_ordinals = range(invocation_count)
            elif execution.get("mode") == "distinct_connections":
                invocation_count = int(execution["connection_count"])
                sample_ordinals = [0] * invocation_count
            else:
                raise MatrixError(f"unsupported WI-3 execution mode: {execution.get('mode')}")
            coordinates = [
                [str(execution["row_id"]), "persistent_concurrent", "formatted", "recorded", -2, sample]
                for sample in sample_ordinals
            ]
            plan.append({
                "ordinal": ordinal,
                "segment_id": f"{ordinal:03d}-wi3-{workload['id']}",
                "kind": "wi3",
                "client_mode": "persistent_concurrent",
                "row_ids": [str(execution["row_id"])],
                "workload_matrix_id": workload["id"],
                "expected_invocation_count": invocation_count,
                "expected_sample_coordinates": coordinates,
            })
    return plan


def capture_segment_plan_sha256(plan: list[dict[str, Any]]) -> str:
    return sha256_bytes(json.dumps(plan, separators=(",", ":"), sort_keys=True).encode("utf-8"))


def run_wi3_workload_generation(
    cli: Path,
    window_id: int,
    matrix_path: Path,
    workload: dict[str, Any],
    variables: dict[str, str],
    capture: Path,
    timeout: float,
    generation: int,
) -> list[dict[str, Any]]:
    execution = workload.get("execution")
    if not isinstance(execution, dict) or execution.get("enabled_by_default") is not True:
        raise MatrixError(f"WI-3 workload {workload.get('id')} is not enabled")
    workload_id = str(workload["id"])
    row = matrix_row_by_id(matrix_path, str(execution["row_id"]), variables)
    mode = execution.get("mode")
    if mode == "same_connection_burst":
        return run_concurrent_batch_process(
            cli, window_id, row, int(execution["request_count"]), capture,
            timeout, workload_id, 0, generation,
        )
    if mode == "distinct_connections":
        samples: list[dict[str, Any]] = []
        connection_count = int(execution["connection_count"])
        with ThreadPoolExecutor(max_workers=connection_count) as executor:
            futures = [
                executor.submit(
                    run_concurrent_batch_process, cli, window_id, row, 1,
                    capture, timeout, workload_id, ordinal, generation,
                )
                for ordinal in range(connection_count)
            ]
            for future in futures:
                samples.extend(future.result())
        return samples
    raise MatrixError(f"unsupported WI-3 execution mode: {mode}")


def capture_request_ids(capture: dict[str, Any]) -> set[str]:
    request_ids: set[str] = set()
    for stage in capture.get("stages", []):
        identity = stage.get("request_identity")
        invocation_id = identity.get("app_invocation_id") if isinstance(identity, dict) else None
        if invocation_id:
            request_ids.add(canonical_invocation_id(invocation_id))
    for event in capture.get("lifecycle_events", []):
        identity = event.get("request_identity")
        invocation_id = identity.get("app_invocation_id") if isinstance(identity, dict) else None
        if invocation_id:
            request_ids.add(canonical_invocation_id(invocation_id))
    return request_ids


def validate_capture_request_membership(
    payload: dict[str, Any], samples: list[dict[str, Any]],
) -> list[str]:
    capture = find_named_object(payload, "capture") or {}
    delivery_events = find_named_object(payload, "delivery_events") or []
    expected_ids = {canonical_invocation_id(sample["invocation_id"]) for sample in samples}
    foreign_capture_ids = capture_request_ids(capture) - expected_ids
    modes = {sample.get("client_mode") for sample in samples}
    if foreign_capture_ids and not modes <= {"persistent", "persistent_concurrent"}:
        raise MatrixError(
            "capture segment contains foreign lifecycle/stage request identities: "
            + ", ".join(sorted(foreign_capture_ids))
        )
    lifecycle_by_id: defaultdict[str, list[dict[str, Any]]] = defaultdict(list)
    stage_by_id: defaultdict[str, list[dict[str, Any]]] = defaultdict(list)
    for event in capture.get("lifecycle_events", []):
        identity = event.get("request_identity")
        invocation_id = identity.get("app_invocation_id") if isinstance(identity, dict) else None
        if invocation_id:
            lifecycle_by_id[canonical_invocation_id(invocation_id)].append(event)
    for stage in capture.get("stages", []):
        identity = stage.get("request_identity")
        invocation_id = identity.get("app_invocation_id") if isinstance(identity, dict) else None
        if invocation_id:
            stage_by_id[canonical_invocation_id(invocation_id)].append(stage)
    classified_setup_ids: list[str] = []
    required_lifecycle = Counter(LIFECYCLE_EVENT_ALLOWLIST)
    for invocation_id in sorted(foreign_capture_ids):
        lifecycle = lifecycle_by_id.get(invocation_id, [])
        stages = stage_by_id.get(invocation_id, [])
        lifecycle_names = Counter(str(event.get("event_name")) for event in lifecycle)
        lifecycle_tools = {
            parse_dimensions(str(event.get("sanitized_dimensions") or "")).get("tool")
            for event in lifecycle
        }
        stage_tools = {
            parse_dimensions(str(stage.get("sanitized_dimensions") or "")).get("tool")
            for stage in stages
        }
        if lifecycle_names != required_lifecycle \
                or lifecycle_tools != {"bind_context"} \
                or not stages \
                or stage_tools != {"bind_context"} \
                or any(not str(stage.get("stage_name", "")).startswith("EditFlow.MCPToolCall.") for stage in stages):
            raise MatrixError(
                "capture segment contains unclassified foreign lifecycle/stage request identity: "
                + invocation_id
            )
        classified_setup_ids.append(invocation_id)
    # Fresh CLI connections emit initialization/list handshake delivery events, and
    # capture-begin's own response is necessarily observed after the recorder reset.
    # They carry no workload lifecycle/stage identity and are never joined by timing.
    # Workload delivery phases are accepted only by exact invocation identity or the
    # stable transport tuple in joined_request_evidence; terminal events are checked
    # independently against retained workload connections.
    _ = delivery_events
    return classified_setup_ids


def validate_capture_segment_payload(
    payload: dict[str, Any],
    samples: list[dict[str, Any]],
    configuration: str,
) -> None:
    capture = find_named_object(payload, "capture") or {}
    validate_capture_integrity(capture)
    delivery_drops = int(find_named_object(payload, "delivery_dropped_event_count") or 0)
    if delivery_drops:
        raise MatrixError(f"capture segment dropped {delivery_drops} delivery events")
    validate_trace_records(samples, configuration)
    validate_connection_cohorts(samples)
    for sample in samples:
        validate_expected(sample)
    delivery_events = find_named_object(payload, "delivery_events") or []
    validate_delivery_terminals(delivery_events, capture.get("lifecycle_events", []), samples)
    joined_request_evidence(samples, capture, delivery_events, require_server=True)
    validate_capture_request_membership(payload, samples)


def validate_segment_index_contract(
    index: dict[str, Any],
    plan: list[dict[str, Any]],
) -> None:
    if index.get("layout") != SEGMENTED_CAPTURE_LAYOUT:
        raise MatrixError("segmented capture index layout mismatch")
    if index.get("capture_mode") != SERVER_CAPTURE_MODE:
        raise MatrixError("segmented capture index mode mismatch")
    if index.get("segment_plan_sha256") != capture_segment_plan_sha256(plan):
        raise MatrixError("segmented capture plan hash mismatch")
    entries = index.get("segments")
    if not isinstance(entries, list):
        raise MatrixError("segmented capture index omitted segments")
    expected = [(item["ordinal"], item["segment_id"]) for item in plan]
    actual = [(item.get("ordinal"), item.get("segment_id")) for item in entries]
    if actual != expected:
        raise MatrixError("segmented capture index is missing, duplicated, extra, or reordered")
    for spec, entry in zip(plan, entries):
        for field, expected_value in spec.items():
            if entry.get(field) != expected_value:
                raise MatrixError(
                    f"segmented capture index contract mismatch for {spec['segment_id']}: {field}"
                )


def collect_capture_segment(
    cli: Path,
    window_id: int,
    output: Path,
    spec: dict[str, Any],
    configuration: str,
    max_samples: int,
    timeout: float,
    execute_attempt: Any,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]], dict[str, Any]]:
    discarded_invalid: list[dict[str, Any]] = []
    for attempt in range(2):
        begin_started = time.perf_counter_ns()
        begin_payload = call_debug_tool(
            cli, window_id,
            {"op": "mcp_read_search_capture_begin", "label": spec["segment_id"],
             "max_samples": max_samples}, timeout,
        )
        begin_duration_ms = (time.perf_counter_ns() - begin_started) / 1_000_000
        validate_capture_begin(find_named_object(begin_payload, "capture") or {})
        workload_started = time.perf_counter_ns()
        workload_error: BaseException | None = None
        recorded: list[dict[str, Any]] = []
        warmups: list[dict[str, Any]] = []
        try:
            recorded, warmups = execute_attempt(attempt)
        except BaseException as error:
            workload_error = error
        workload_duration_ms = (time.perf_counter_ns() - workload_started) / 1_000_000
        snapshot_started = time.perf_counter_ns()
        try:
            payload = call_debug_tool(
                cli, window_id,
                {"op": "mcp_read_search_capture_snapshot", "finish": True, "include_timeline": True},
                timeout,
            )
        except BaseException as error:
            save_json(output / "capture-finish-error.json", {
                "segment_id": spec["segment_id"], "attempt": attempt, "error": str(error),
            })
            raise
        snapshot_duration_ms = (time.perf_counter_ns() - snapshot_started) / 1_000_000
        if workload_error is not None:
            raise workload_error
        executed = recorded + warmups
        capture = find_named_object(payload, "capture") or {}
        validate_capture_integrity(capture)
        delivery_drops = int(find_named_object(payload, "delivery_dropped_event_count") or 0)
        if delivery_drops:
            raise MatrixError(f"capture segment dropped {delivery_drops} delivery events")
        classified_setup_ids = validate_capture_request_membership(payload, executed)
        invocation_ids = [sample["invocation_id"] for sample in executed]
        if len(invocation_ids) != len(set(invocation_ids)):
            raise MatrixError(f"segment {spec['segment_id']} reused an invocation identity")
        if len(invocation_ids) != int(spec["expected_invocation_count"]):
            raise MatrixError(
                f"segment {spec['segment_id']} invocation count mismatch: "
                f"expected {spec['expected_invocation_count']}, got {len(invocation_ids)}"
            )
        validate_segment_sample_coordinates(spec, executed)
        invalid = invalid_connection_cohorts(executed)
        if invalid:
            attempt_path = output / "server-capture-attempts" / f"{spec['segment_id']}-a{attempt}.json"
            save_json(attempt_path, payload)
            for sample in executed:
                sample["capture_segment_attempt_id"] = f"{spec['segment_id']}-a{attempt}"
                sample["discard_reason"] = next(iter(invalid.values()))
            discarded_invalid.extend(executed)
            if attempt == 0:
                continue
            raise MatrixError(f"segment {spec['segment_id']} remained invalid after re-cohorting")
        for sample in executed:
            sample["capture_segment_id"] = spec["segment_id"]
        validate_capture_segment_payload(payload, executed, configuration)
        relative_path = Path("server-capture-segments") / f"{spec['segment_id']}.json"
        artifact_path = output / relative_path
        save_json(artifact_path, payload)
        artifact_sha256 = sha256_bytes(artifact_path.read_bytes())
        entry = {
            **spec,
            "artifact_path": str(relative_path),
            "artifact_sha256": artifact_sha256,
            "invocation_ids": invocation_ids,
            "classified_setup_request_ids": classified_setup_ids,
            "attempt": attempt,
            "timing": {
                "begin_duration_ms": round(begin_duration_ms, 3),
                "workload_duration_ms": round(workload_duration_ms, 3),
                "snapshot_duration_ms": round(snapshot_duration_ms, 3),
            },
        }
        return recorded, warmups, discarded_invalid, entry
    raise MatrixError(f"segment {spec['segment_id']} did not complete")


def run_matrix(args: argparse.Namespace) -> int:
    optimized_artifact = None
    if args.configuration == "optimized":
        if not args.server_artifact_manifest:
            raise MatrixError("optimized collection requires --server-artifact-manifest")
        optimized_artifact = validate_optimized_artifact_manifest(Path(args.server_artifact_manifest))
        cli = resolve_cli(args.cli or optimized_artifact["embedded_cli_path"])
        if cli != Path(optimized_artifact["embedded_cli_path"]).resolve():
            raise MatrixError("optimized collection must use the diagnostic app's embedded CLI")
        if sha256_bytes(cli.read_bytes()) != optimized_artifact["embedded_cli_sha256"]:
            raise MatrixError("optimized collection CLI hash does not match the artifact manifest")
    else:
        if args.server_artifact_manifest:
            raise MatrixError("DEBUG collection must not use --server-artifact-manifest")
        cli = resolve_cli(args.cli)

    source_fingerprint = current_source_fingerprint()
    if optimized_artifact is not None \
            and optimized_artifact["source_fingerprint_sha256"] != source_fingerprint:
        raise MatrixError("optimized server artifact was built from a different source-tree state")
    output = new_capture_directory(Path(args.output))
    fixture_root = Path(args.fixture_root) if args.fixture_root else None
    fixture_manifest_path = Path(args.fixture_manifest) if args.fixture_manifest else None
    validate_fixture_manifest_location(fixture_root, fixture_manifest_path)
    variables = fixture_variables(fixture_root)
    matrix_path = Path(args.matrix).expanduser().resolve()
    authority = load_wi3_authority(matrix_path)
    discipline = resolve_sample_discipline(matrix_path, args)
    rows = load_rows(matrix_path, args.profile, args.include_manual, variables)
    include_wi3 = discipline["cohort"] == "warm" and not args.skip_wi3
    segment_plan = capture_segment_plan(rows, args.client_mode, discipline, authority, include_wi3)
    segment_plan_hash = capture_segment_plan_sha256(segment_plan)
    fixture_manifest = load_json(fixture_manifest_path) if fixture_manifest_path else None
    expected_server_configuration = "debug" if args.configuration == "debug" else "optimized_diagnostic"
    server_app_identity = probe_server_app_identity(
        cli, args.window_id, args.timeout, expected_server_configuration,
    )
    if optimized_artifact is not None:
        validate_runtime_artifact_identity(server_app_identity, optimized_artifact)

    metadata = {
        "schema_version": SCHEMA_VERSION,
        "status": "collecting",
        "configuration": args.configuration,
        "cohort_kind": discipline["cohort"],
        "profile": args.profile,
        "client_modes": args.client_mode,
        "created_at_epoch": time.time(),
        "commit": subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=repo_root(), text=True, capture_output=True,
        ).stdout.strip(),
        "source_fingerprint_sha256": source_fingerprint,
        "platform": platform.platform(),
        "machine": platform.machine(),
        "cli": str(cli),
        "server_app_identity": server_app_identity,
        "server_app_configuration": server_app_identity.get("app_configuration"),
        "optimized_server_artifact": optimized_artifact,
        "fixture_manifest": fixture_manifest,
        "matrix": str(matrix_path),
        "matrix_sha256": sha256_bytes(matrix_path.read_bytes()),
        "wi3_authority": authority,
        "wi3_authority_sha256": sha256_bytes(
            json.dumps(authority, separators=(",", ":"), sort_keys=True).encode("utf-8")
        ),
        "sample_discipline": discipline,
        "server_capture_mode": SERVER_CAPTURE_MODE,
        "server_capture_layout": SEGMENTED_CAPTURE_LAYOUT,
        "capture_segment_contract_version": SEGMENTED_CAPTURE_CONTRACT_VERSION,
        "capture_segment_strategy": SEGMENTED_CAPTURE_STRATEGY,
        "capture_segment_max_ordinary_invocations": SEGMENTED_CAPTURE_MAX_ORDINARY_INVOCATIONS,
        "capture_segment_plan": segment_plan,
        "capture_segment_plan_sha256": segment_plan_hash,
        "planned_capture_segment_count": len(segment_plan),
        "planned_row_ids": [row["id"] for row in rows],
    }
    save_json(output / "manifest.json", metadata)
    segment_index = {
        "schema_version": SCHEMA_VERSION,
        "layout": SEGMENTED_CAPTURE_LAYOUT,
        "capture_mode": SERVER_CAPTURE_MODE,
        "segment_plan_sha256": segment_plan_hash,
        "segments": [],
    }
    save_json(output / "server-capture.json", segment_index)

    samples: list[dict[str, Any]] = []
    discarded_warmups: list[dict[str, Any]] = []
    discarded_invalid: list[dict[str, Any]] = []
    executed_wi3: list[str] = []
    row_by_id = {row["id"]: row for row in rows}
    workload_by_id = {str(item["id"]): item for item in authority["workload_matrices"]}

    if args.configuration == "debug":
        save_json(output / "runtime-before.json", call_debug_tool(
            cli, args.window_id,
            {"op": "mcp_read_search_runtime_snapshot", "window_id": args.window_id,
             "recent_publication_limit": 16, "root_limit": 256}, args.timeout,
        ))
        save_json(output / "admission-before.json", call_debug_tool(
            cli, args.window_id,
            {"op": "mcp_read_search_admission_snapshot", "window_id": args.window_id},
            args.timeout,
        ))

    for spec in segment_plan:
        if spec["kind"] == "wi3":
            workload = workload_by_id.get(str(spec["workload_matrix_id"]))
            if workload is None:
                raise MatrixError(f"planned WI-3 workload is absent: {spec['workload_matrix_id']}")

            def execute_attempt(attempt: int, workload: dict[str, Any] = workload) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
                return run_wi3_workload_generation(
                    cli, args.window_id, matrix_path, workload, variables, output,
                    args.timeout, attempt,
                ), []
        else:
            row = row_by_id.get(str(spec["row_ids"][0]))
            if row is None:
                raise MatrixError(f"planned ordinary row is absent: {spec['row_ids'][0]}")
            terminal = spec["kind"] == "expected_terminal"
            row_warmups = [] if terminal else warmup_rows([row], discipline["warmups"])
            row_recorded = expanded_rows(
                [row], 1 if terminal else discipline["repeats"],
                1 if terminal else discipline["samples_per_repeat"],
            )

            def execute_attempt(
                attempt: int,
                row_warmups: list[dict[str, Any]] = row_warmups,
                row_recorded: list[dict[str, Any]] = row_recorded,
                spec: dict[str, Any] = spec,
            ) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
                if spec["client_mode"] == "fresh":
                    warmup_samples = run_fresh(
                        cli, args.window_id, row_warmups, output, args.timeout,
                        discipline["cohort"], "warmup",
                    )
                    recorded_samples = run_fresh(
                        cli, args.window_id, row_recorded, output, args.timeout,
                        discipline["cohort"], "recorded",
                    )
                    return recorded_samples, warmup_samples
                generation_samples = run_persistent_generation(
                    cli, args.window_id, row_warmups, row_recorded, output,
                    args.timeout, discipline["cohort"], attempt, spec["segment_id"],
                )
                return (
                    [sample for sample in generation_samples if sample["phase"] == "recorded"],
                    [sample for sample in generation_samples if sample["phase"] == "warmup"],
                )

        recorded, warmups, invalid, entry = collect_capture_segment(
            cli, args.window_id, output, spec, args.configuration,
            args.max_samples, args.timeout, execute_attempt,
        )
        samples.extend(recorded)
        discarded_warmups.extend(warmups)
        discarded_invalid.extend(invalid)
        if spec["kind"] == "wi3":
            executed_wi3.append(str(spec["workload_matrix_id"]))
        segment_index["segments"].append(entry)
        save_json(output / "server-capture.json", segment_index)
        metadata["accepted_capture_segment_count"] = len(segment_index["segments"])
        metadata["rejected_capture_attempt_count"] = len({
            str(sample["capture_segment_attempt_id"])
            for sample in discarded_invalid
            if sample.get("capture_segment_attempt_id")
        })
        save_json(output / "manifest.json", metadata)

    validate_segment_index_contract(segment_index, segment_plan)
    validate_connection_cohorts(samples)
    for sample in samples:
        validate_expected(sample)
    validate_format_pairs(samples)

    if args.configuration == "debug":
        save_json(output / "runtime-after.json", call_debug_tool(
            cli, args.window_id,
            {"op": "mcp_read_search_runtime_snapshot", "window_id": args.window_id,
             "recent_publication_limit": 16, "root_limit": 256}, args.timeout,
        ))
        save_json(output / "admission-after.json", call_debug_tool(
            cli, args.window_id,
            {"op": "mcp_read_search_admission_snapshot", "window_id": args.window_id},
            args.timeout,
        ))

    server_app_identity_end = probe_server_app_identity(
        cli, args.window_id, args.timeout, expected_server_configuration,
    )
    if server_app_identity_end != server_app_identity:
        raise MatrixError("server app identity changed during cohort collection")
    if optimized_artifact is not None:
        validate_runtime_artifact_identity(server_app_identity_end, optimized_artifact)
    metadata["status"] = "completed"
    metadata["server_app_identity_end"] = server_app_identity_end
    metadata["completed_at_epoch"] = time.time()
    metadata["accepted_capture_segment_count"] = len(segment_index["segments"])
    metadata["completed_capture_segment_count"] = len(segment_index["segments"])
    metadata["capture_segment_index_sha256"] = sha256_bytes(
        (output / "server-capture.json").read_bytes()
    )
    save_json(output / "manifest.json", metadata)

    run = {
        "schema_version": SCHEMA_VERSION,
        "status": "completed",
        "samples": samples,
        "discarded_warmups": discarded_warmups,
        "discarded_invalid_cohorts": discarded_invalid,
        "executed_wi3_matrix_ids": executed_wi3,
    }
    save_json(output / "run.json", run)
    summary = aggregate(output)
    wi3_signature = summary["wi3_work_counts"].get("parity_signature")
    baseline_samples = [sample for sample in samples if sample.get("cohort_kind") != "wi3"]
    apply_baseline(baseline_samples, Path(args.baseline), args.update_baseline, wi3_signature)
    save_json(output / "aggregate.json", summary)
    print(json.dumps({
        "output": str(output), "samples": len(samples), "segments": len(segment_plan),
        "selector": summary["selector"],
    }, indent=2, sort_keys=True))
    return 0


def analyze_command(args: argparse.Namespace) -> int:
    if args.debug_input or args.optimized_input:
        if not args.debug_input or not args.optimized_input:
            raise MatrixError("paired analyze requires both --debug-input and --optimized-input")
        summary = paired_aggregate(
            Path(args.debug_input).expanduser().resolve(),
            Path(args.optimized_input).expanduser().resolve(),
        )
    elif args.input:
        summary = aggregate(Path(args.input).expanduser().resolve())
    else:
        raise MatrixError("analyze requires --input or the paired input options")
    save_json(Path(args.output), summary)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    run = subparsers.add_parser("run", help="run against an already-running CE app; performs no lifecycle action")
    run.add_argument("--configuration", required=True, choices=("debug", "optimized"))
    run.add_argument("--cohort", required=True, choices=("cold", "warm"))
    run.add_argument("--profile", required=True, choices=("real", "small", "medium", "large"))
    run.add_argument("--client-mode", action="append", choices=("fresh", "persistent"), required=True)
    run.add_argument("--window-id", type=int, default=1)
    run.add_argument("--cli")
    run.add_argument("--server-artifact-manifest")
    run.add_argument("--matrix", default=str(default_matrix()))
    run.add_argument("--fixture-root")
    run.add_argument("--fixture-manifest")
    run.add_argument("--output", required=True)
    run.add_argument("--baseline", required=True)
    run.add_argument("--update-baseline", action="store_true")
    run.add_argument("--include-manual", action="store_true")
    run.add_argument("--skip-wi3", action="store_true")
    run.add_argument("--activation-id")
    run.add_argument("--cold-sample-index", type=int)
    run.add_argument("--timeout", type=float, default=180)
    run.add_argument("--warmups", type=int)
    run.add_argument("--repeats", type=int)
    run.add_argument("--samples-per-repeat", type=int)
    run.add_argument("--max-samples", type=int, default=100_000)
    analyze = subparsers.add_parser("analyze")
    analyze.add_argument("--input")
    analyze.add_argument("--debug-input")
    analyze.add_argument("--optimized-input")
    analyze.add_argument("--output", required=True)
    args = parser.parse_args(argv)
    if args.command == "run":
        if args.timeout <= 0:
            parser.error("--timeout must be greater than zero")
        if args.warmups is not None and args.warmups < 0:
            parser.error("--warmups must be non-negative")
        if args.repeats is not None and args.repeats <= 0:
            parser.error("--repeats must be greater than zero")
        if args.samples_per_repeat is not None and args.samples_per_repeat <= 0:
            parser.error("--samples-per-repeat must be greater than zero")
        if not 100 <= args.max_samples <= 100_000:
            parser.error("--max-samples must be between 100 and 100000")
    return args


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(argv or sys.argv[1:])
        return run_matrix(args) if args.command == "run" else analyze_command(args)
    except (MatrixError, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
