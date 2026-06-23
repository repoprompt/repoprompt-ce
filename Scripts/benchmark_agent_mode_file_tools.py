#!/usr/bin/env python3
"""Run a paired live Agent Mode read_file/file_search performance diagnostic.

Requires an already-running RepoPrompt CE DEBUG app. This script never launches,
stops, or relaunches the app.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import html
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import uuid
from typing import Any, Iterable

SCHEMA_VERSION = 1
DEBUG_TOOL = "__repoprompt_debug_diagnostics"
RECEIVED = "MCP.ToolCall.Received"
MAIN_ACTOR_EXITED = "MCP.ToolCall.MainActorExited"
RELEVANT_TOOLS = {"file_search", "read_file"}
TERMINAL_STATUSES = {"completed", "failed", "cancelled", "canceled", "stopped", "expired"}


class BenchmarkError(RuntimeError):
    pass


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def parse_dimensions(raw: str) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for part in raw.split():
        if "=" not in part:
            continue
        key, value = part.split("=", 1)
        if value in {"true", "false"}:
            result[key] = value == "true"
        elif re.fullmatch(r"-?\d+", value):
            result[key] = int(value)
        elif re.fullmatch(r"-?(?:\d+\.\d*|\d*\.\d+)", value):
            result[key] = float(value)
        else:
            result[key] = value
    return result


def percentile(values: Iterable[float], fraction: float) -> float | None:
    ordered = sorted(float(value) for value in values)
    if not ordered:
        return None
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * fraction
    lower, upper = math.floor(position), math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


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


def find_object(value: Any, required_key: str, expected_op: str | None = None) -> dict[str, Any]:
    for candidate in walk_json(value):
        if not isinstance(candidate, dict) or required_key not in candidate:
            continue
        if expected_op is None or candidate.get("op") == expected_op:
            return candidate
    raise BenchmarkError(f"response omitted {required_key!r}")


def find_string(value: Any, key: str) -> str | None:
    for candidate in walk_json(value):
        if isinstance(candidate, dict) and isinstance(candidate.get(key), str):
            return candidate[key]
    return None


def response_session_ids(value: Any) -> set[str]:
    if not isinstance(value, dict):
        return set()
    result: set[str] = set()
    for key in ("session_id", "sessionId"):
        direct = value.get(key)
        if isinstance(direct, str) and direct:
            result.add(direct)
    session = value.get("session")
    if isinstance(session, dict):
        nested = session.get("id")
        if isinstance(nested, str) and nested:
            result.add(nested)
    return result


def response_session_id(value: Any) -> str | None:
    values = response_session_ids(value)
    return values.pop() if len(values) == 1 else None


def response_run_ids(value: Any) -> set[str]:
    if not isinstance(value, dict):
        return set()
    return {
        direct
        for key in ("run_id", "runId")
        if isinstance((direct := value.get(key)), str) and direct
    }


def response_run_id(value: Any) -> str | None:
    values = response_run_ids(value)
    return values.pop() if len(values) == 1 else None


def extract_capture(value: Any) -> dict[str, Any]:
    return find_object(value, "capture").get("capture")


def event_join_key(event: dict[str, Any]) -> str:
    identity = event.get("request_identity")
    if isinstance(identity, dict) and identity.get("app_invocation_id"):
        return str(identity["app_invocation_id"])
    return str(event.get("correlation_id") or "")


def build_samples(capture: dict[str, Any]) -> list[dict[str, Any]]:
    events = capture.get("lifecycle_events")
    if not isinstance(events, list):
        raise BenchmarkError("capture omitted lifecycle_events")
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for event in events:
        if isinstance(event, dict):
            grouped[event_join_key(event)].append(event)
    samples: list[dict[str, Any]] = []
    for join_key, group in grouped.items():
        ordered = sorted(group, key=lambda item: int(item.get("ordinal", 0)))
        received = [event for event in ordered if event.get("event_name") == RECEIVED]
        if len(received) != 1:
            continue
        first = received[0]
        tool = parse_dimensions(str(first.get("sanitized_dimensions", ""))).get("tool")
        if tool not in RELEVANT_TOOLS:
            continue
        exits = [
            event for event in ordered
            if event.get("event_name") == MAIN_ACTOR_EXITED
            and parse_dimensions(str(event.get("sanitized_dimensions", ""))).get("observerType") == "event_completion"
        ]
        if len(exits) != 1:
            raise BenchmarkError(f"{tool} timeline {join_key} requires exactly one event_completion MainActorExited")
        last = exits[0]
        start = float(first["offset_ms"])
        end = float(last["offset_ms"])
        envelope = [
            event for event in ordered
            if int(first.get("ordinal", 0)) <= int(event.get("ordinal", 0)) <= int(last.get("ordinal", 0))
        ]
        previous = start
        stages = []
        for event in envelope:
            offset = float(event["offset_ms"])
            stages.append({
                "event": event.get("event_name"),
                "from_received_ms": round(offset - start, 3),
                "delta_ms": round(offset - previous, 3),
                "dimensions": parse_dimensions(str(event.get("sanitized_dimensions", ""))),
            })
            previous = offset
        identity = first.get("request_identity") if isinstance(first.get("request_identity"), dict) else {}
        completion_dimensions = parse_dimensions(str(last.get("sanitized_dimensions", "")))
        run_id = completion_dimensions.get("runID")
        if not isinstance(run_id, str) or not run_id:
            raise BenchmarkError(f"{tool} timeline {join_key} event_completion omitted runID")
        worktree_projection: bool | None = None
        search_match_count: int | None = None
        if tool == "file_search":
            projection_events = [
                stage for stage in stages
                if stage.get("event") == "Search.ProviderDTOReady"
                and isinstance(stage.get("dimensions"), dict)
                and stage["dimensions"].get("outcome") in {"completed", "capped"}
            ]
            projections = {
                stage["dimensions"].get("usesWorktreeProjection")
                for stage in projection_events
            }
            if len(projections) != 1 or not all(isinstance(value, bool) for value in projections):
                raise BenchmarkError(
                    f"{tool} timeline {join_key} requires one successful usesWorktreeProjection value"
                )
            worktree_projection = projections.pop()
            match_counts = {stage["dimensions"].get("matchCount") for stage in projection_events}
            if len(match_counts) != 1 or not all(isinstance(value, int) for value in match_counts):
                raise BenchmarkError(f"{tool} timeline {join_key} requires one successful matchCount value")
            search_match_count = match_counts.pop()
        samples.append({
            "schema_version": SCHEMA_VERSION,
            "join_key": join_key,
            "route": None,
            "tool": tool,
            "connection_id": identity.get("connection_id"),
            "run_id": run_id,
            "uses_worktree_projection": worktree_projection,
            "search_match_count": search_match_count,
            "request_identity": identity,
            "received_offset_ms": start,
            "main_actor_exited_offset_ms": end,
            "envelope_ms": round(end - start, 3),
            "stages": stages,
            "event_names": [event.get("event_name") for event in envelope],
        })
    return sorted(samples, key=lambda item: (item["received_offset_ms"], item["join_key"]))


def classify_routes(
    samples: list[dict[str, Any]],
    search_count: int,
    read_count: int,
    expected_run_ids: dict[str, str],
) -> dict[str, str]:
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for sample in samples:
        connection = sample.get("connection_id")
        if not connection:
            raise BenchmarkError("sample omitted connection_id")
        grouped[str(connection)].append(sample)
    if len(grouped) != 2:
        raise BenchmarkError(f"expected two file-tool connections, found {len(grouped)}")
    expected = {
        "local": ["file_search"] * search_count + ["read_file"] * read_count,
        "worktree": ["read_file"] * read_count + ["file_search"] * search_count,
    }
    routes: dict[str, str] = {}
    for connection, group in grouped.items():
        run_ids = {str(sample.get("run_id") or "") for sample in group}
        if len(run_ids) != 1:
            raise BenchmarkError(f"connection {connection} spans multiple agent runs: {sorted(run_ids)}")
        run_id = run_ids.pop()
        matches = [route for route, expected_run_id in expected_run_ids.items() if run_id == expected_run_id]
        if len(matches) != 1:
            raise BenchmarkError(f"connection {connection} belongs to unexpected agent run {run_id!r}")
        route = matches[0]
        signature = [sample["tool"] for sample in sorted(group, key=lambda item: item["received_offset_ms"])]
        if signature != expected[route]:
            raise BenchmarkError(f"{route} connection {connection} has unexpected signature {signature}")
        routes[connection] = route
    if set(routes.values()) != {"local", "worktree"}:
        raise BenchmarkError("route signatures were not unique")
    for sample in samples:
        sample["route"] = routes[str(sample["connection_id"])]
    return routes


def sequential_call_failures(samples: list[dict[str, Any]]) -> list[str]:
    failures: list[str] = []
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for sample in samples:
        grouped[str(sample.get("connection_id"))].append(sample)
    for connection, group in grouped.items():
        ordered = sorted(group, key=lambda item: float(item["received_offset_ms"]))
        for previous, current in zip(ordered, ordered[1:]):
            if float(current["received_offset_ms"]) < float(previous["main_actor_exited_offset_ms"]):
                failures.append(
                    f"connection {connection} overlapped {previous['join_key']} and {current['join_key']}"
                )
    return failures


def search_projection_failures(samples: list[dict[str, Any]]) -> list[str]:
    failures: list[str] = []
    for sample in samples:
        if sample.get("tool") != "file_search":
            continue
        expected = sample.get("route") == "worktree"
        if sample.get("uses_worktree_projection") != expected:
            failures.append(
                f"{sample.get('route')} search {sample.get('join_key')} reported "
                f"usesWorktreeProjection={sample.get('uses_worktree_projection')!r}"
            )
        if int(sample.get("search_match_count") or 0) <= 0:
            failures.append(
                f"{sample.get('route')} search {sample.get('join_key')} reported no matches"
            )
    return failures


def transcript_tool_calls(transcript_xml: str) -> list[tuple[str, dict[str, Any]]]:
    pattern = re.compile(r'<tool_call name="([^"]+)"(?:>(.*?)</tool_call>|/>)', re.DOTALL)
    calls: list[tuple[str, dict[str, Any]]] = []
    for match in pattern.finditer(transcript_xml):
        name = match.group(1).split("__")[-1]
        raw = match.group(2)
        if raw is None:
            calls.append((name, {}))
            continue
        try:
            value = json.loads(html.unescape(raw))
        except json.JSONDecodeError as error:
            raise BenchmarkError(f"invalid {name} transcript arguments: {error}") from error
        if not isinstance(value, dict):
            raise BenchmarkError(f"invalid {name} transcript arguments: expected object")
        calls.append((name, value))
    return calls


def tool_calls_from_transcript(transcript_xml: str, tool: str) -> list[dict[str, Any]]:
    return [arguments for name, arguments in transcript_tool_calls(transcript_xml) if name == tool]


def final_agent_response(wait_response: Any, transcript_xml: str) -> str | None:
    for key in ("assistant_text", "last_message"):
        value = find_string(wait_response, key)
        if value is not None:
            return value.strip()
    messages = re.findall(r"<assistant>(.*?)</assistant>", transcript_xml, re.DOTALL)
    return html.unescape(messages[-1]).strip() if messages else None


def agent_worktree_paths(response: Any) -> list[str]:
    paths: list[str] = []

    def visit(value: Any, worktree_context: bool = False) -> None:
        if isinstance(value, dict):
            explicit = value.get("worktree_root_path") or value.get("worktreeRootPath")
            if isinstance(explicit, str) and explicit.strip():
                paths.append(explicit)
            if worktree_context and isinstance(value.get("path"), str) and value["path"].strip():
                paths.append(value["path"])
            for key, child in value.items():
                visit(child, worktree_context or key in {"worktree", "worktree_binding", "worktree_bindings"})
        elif isinstance(value, list):
            for child in value:
                visit(child, worktree_context)
        elif isinstance(value, str) and value.lstrip().startswith(("{", "[")):
            try:
                visit(json.loads(value), worktree_context)
            except json.JSONDecodeError:
                pass

    visit(response)
    return paths


def validate_route_binding_metadata(
    agent_results: dict[str, dict[str, Any]],
    configured_worktree: Path,
) -> list[str]:
    failures: list[str] = []
    expected = configured_worktree.expanduser().resolve()
    for route in ("local", "worktree"):
        result = agent_results.get(route, {})
        for response_name in ("start_response", "wait_response"):
            response = result.get(response_name)
            if response is None:
                failures.append(f"{route} agent omitted {response_name} metadata")
                continue
            reported = agent_worktree_paths(response)
            if route == "local":
                if reported:
                    failures.append(f"local agent unexpectedly reported worktree binding in {response_name}")
                continue
            if not reported:
                failures.append(f"worktree agent omitted worktree binding in {response_name}")
                continue
            mismatches = [path for path in reported if Path(path).expanduser().resolve() != expected]
            if mismatches:
                failures.append(
                    f"worktree agent reported mismatched binding in {response_name}: {mismatches}"
                )
    return failures


def validate_agent_completion(agent_results: dict[str, dict[str, Any]], transcripts: dict[str, str]) -> list[str]:
    failures: list[str] = []
    for route in ("local", "worktree"):
        result = agent_results.get(route, {})
        status = str(result.get("status") or "").lower()
        if status != "completed":
            failures.append(f"{route} agent status was {status or 'missing'}, not completed")
        response = final_agent_response(result.get("wait_response", {}), transcripts.get(route, ""))
        if response != "AGENT_FILE_TOOL_DIAGNOSTIC_OK":
            failures.append(f"{route} agent final response did not match diagnostic token")
    return failures


def validate_agent_session_identity(agent_results: dict[str, dict[str, Any]]) -> list[str]:
    failures: list[str] = []
    seen_session_ids: set[str] = set()
    for route in ("local", "worktree"):
        result = agent_results.get(route) or {}
        expected = result.get("session_id")
        start_ids = response_session_ids(result.get("start_response"))
        wait_ids = response_session_ids(result.get("wait_response"))
        session_ids = {str(value) for value in (expected,) if value}.union(start_ids, wait_ids)
        if len(session_ids) != 1 or len(start_ids) != 1 or len(wait_ids) != 1:
            failures.append(f"{route} agent start/wait session identity mismatch: {sorted(session_ids)}")
            continue
        seen_session_ids.update(session_ids)
    if len(seen_session_ids) != 2:
        failures.append("local and worktree agents did not report two distinct session IDs")
    return failures


def expected_agent_run_ids(agent_results: dict[str, dict[str, Any]]) -> dict[str, str]:
    run_ids: dict[str, str] = {}
    for route in ("local", "worktree"):
        wait_response = (agent_results.get(route) or {}).get("wait_response")
        run_id = response_run_id(wait_response)
        if not run_id:
            raise BenchmarkError(f"{route} agent wait response omitted run_id")
        run_ids[route] = run_id
    if len(set(run_ids.values())) != len(run_ids):
        raise BenchmarkError("local and worktree agents reported the same run_id")
    return run_ids


def validate_transcript_arguments(
    transcript_xml: str,
    marker: str,
    path: str,
    read_limit: int,
) -> None:
    calls = transcript_tool_calls(transcript_xml)
    extra_tools = [name for name, _ in calls if name not in RELEVANT_TOOLS and name != "set_status"]
    if extra_tools:
        raise BenchmarkError(f"unexpected transcript tools: {extra_tools}")
    set_status_count = sum(name == "set_status" for name, _ in calls)
    if set_status_count > 1:
        raise BenchmarkError(f"unexpected duplicate set_status calls: {set_status_count}")
    searches = [arguments for name, arguments in calls if name == "file_search"]
    reads = [arguments for name, arguments in calls if name == "read_file"]
    if not searches or not reads:
        raise BenchmarkError("transcript must surface at least one file_search and read_file call")
    expected_search = {
        "pattern": marker,
        "regex": False,
        "mode": "content",
        "filter": {"paths": [path]},
        "max_results": 20,
        "context_lines": 1,
    }
    required_read = {"path": path, "start_line": 1, "limit": read_limit}
    if any(call != expected_search for call in searches):
        raise BenchmarkError("surfaced search calls did not use the exact configured workload")
    for call in reads:
        if any(call.get(key) != value for key, value in required_read.items()):
            raise BenchmarkError("surfaced read calls did not use the configured workload")
        unexpected_keys = set(call) - set(required_read) - {"key_paths"}
        if unexpected_keys:
            raise BenchmarkError(f"surfaced read calls used unknown enrichment: {sorted(unexpected_keys)}")


def positive_search_projection_counts(capture: dict[str, Any]) -> Counter[bool]:
    counts: Counter[bool] = Counter()
    for stage in capture.get("stages", []):
        if not isinstance(stage, dict) or stage.get("stage_name") != "EditFlow.Search.DTOBuild":
            continue
        dimensions = parse_dimensions(str(stage.get("sanitized_dimensions", "")))
        if int(dimensions.get("matchCount", 0)) <= 0 or dimensions.get("outcome") not in {"completed", "capped"}:
            continue
        projection = dimensions.get("usesWorktreeProjection")
        if not isinstance(projection, bool):
            raise BenchmarkError("search DTO stage omitted usesWorktreeProjection")
        counts[projection] += int(stage.get("sample_count", 0))
    return counts


def validate_integrity(
    capture: dict[str, Any],
    samples: list[dict[str, Any]],
    transcripts: dict[str, str],
    agent_results: dict[str, dict[str, Any]],
    marker: str,
    path: str,
    search_count: int,
    read_count: int,
    read_limit: int,
    configured_worktree: Path,
) -> list[str]:
    failures: list[str] = []
    counts = Counter(sample["tool"] for sample in samples)
    if counts != Counter({"file_search": 2 * search_count, "read_file": 2 * read_count}):
        failures.append(f"unexpected sample counts: {dict(counts)}")
    if int(capture.get("dropped_lifecycle_event_count", 0)):
        failures.append("capture dropped lifecycle events")
    for sample in samples:
        success_event = "Search.ProviderResultReady" if sample["tool"] == "file_search" else "ReadFile.ProviderResultReady"
        if success_event not in sample["event_names"]:
            failures.append(f"{sample['route']} {sample['tool']} omitted {success_event}")
    projection_counts = positive_search_projection_counts(capture)
    expected_projection_counts = Counter({False: search_count, True: search_count})
    if projection_counts != expected_projection_counts:
        failures.append(
            "search DTO stages do not prove the expected local/worktree projections: "
            f"{dict(projection_counts)}"
        )
    failures.extend(sequential_call_failures(samples))
    failures.extend(search_projection_failures(samples))
    failures.extend(validate_agent_completion(agent_results, transcripts))
    failures.extend(validate_agent_session_identity(agent_results))
    failures.extend(validate_route_binding_metadata(agent_results, configured_worktree))
    for route in ("local", "worktree"):
        try:
            validate_transcript_arguments(transcripts[route], marker, path, read_limit)
        except (BenchmarkError, KeyError) as error:
            failures.append(f"{route} transcript: {error}")
    return failures


def summarize_samples(samples: list[dict[str, Any]]) -> dict[str, Any]:
    grouped: dict[tuple[str, str], list[float]] = defaultdict(list)
    for sample in samples:
        grouped[(str(sample["route"]), str(sample["tool"]))].append(float(sample["envelope_ms"]))
    return {
        "schema_version": SCHEMA_VERSION,
        "sample_count": len(samples),
        "groups": [
            {
                "route": route,
                "tool": tool,
                "count": len(values),
                "p50_ms": round(percentile(values, 0.50) or 0, 3),
                "p95_ms": round(percentile(values, 0.95) or 0, 3),
                "max_ms": round(max(values), 3),
            }
            for (route, tool), values in sorted(grouped.items())
        ],
    }


def cancellation_failure_messages(route: str, cancel_error: BaseException | None, settled_status: str) -> list[str]:
    failures: list[str] = []
    if cancel_error is not None:
        failures.append(f"{route} cancellation failed: {cancel_error}")
    if settled_status not in TERMINAL_STATUSES:
        failures.append(f"{route} remained nonterminal after cancellation: {settled_status or 'unknown'}")
    return failures


def cleanup_decision(auto_created: bool, exists: bool, clean: bool, sessions_terminal: bool = True) -> str:
    if not auto_created:
        return "preserve_not_owned"
    if not exists:
        return "already_absent"
    if not sessions_terminal:
        return "preserve_nonterminal_sessions"
    if not clean:
        return "preserve_dirty"
    return "remove_clean_auto_created"


def validate_summary_schema(summary: dict[str, Any]) -> None:
    required = {"schema_version", "status", "latency_policy", "samples", "integrity"}
    missing = required - set(summary)
    if missing:
        raise BenchmarkError(f"summary missing keys: {sorted(missing)}")
    if summary["schema_version"] != SCHEMA_VERSION or summary["latency_policy"] != "report_only":
        raise BenchmarkError("invalid summary schema metadata")


def save_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def load_replay_input(source: Path) -> dict[str, Any]:
    source = source.expanduser().resolve(strict=True)
    replay_file = source / "replay.json" if source.is_dir() else source
    if replay_file.name == "replay.json" and replay_file.is_file():
        value = json.loads(replay_file.read_text(encoding="utf-8"))
        if not isinstance(value, dict):
            raise BenchmarkError("replay fixture must be a JSON object")
        return value
    if not source.is_dir():
        raise BenchmarkError("replay input must be replay.json or an artifact directory")
    manifest = json.loads((source / "manifest.json").read_text(encoding="utf-8"))
    final = json.loads((source / "capture-final.json").read_text(encoding="utf-8"))
    agents: dict[str, Any] = {}
    for route in ("local", "worktree"):
        start = json.loads((source / "agents" / route / "start.json").read_text(encoding="utf-8"))
        wait = json.loads((source / "agents" / route / "wait.json").read_text(encoding="utf-8"))
        log = json.loads((source / "agents" / route / "log.json").read_text(encoding="utf-8"))
        agents[route] = {
            "status": (find_string(wait, "status") or "").lower(),
            "start_response": start,
            "wait_response": wait,
            "transcript_xml": find_string(log, "transcript_xml") or "",
        }
    configuration = manifest.get("configuration", {})
    return {
        "schema_version": SCHEMA_VERSION,
        "configuration": {
            "marker": configuration.get("marker"),
            "path": configuration.get("path"),
            "search_count": configuration.get("search_count"),
            "read_count": configuration.get("read_count"),
            "read_limit": configuration.get("read_limit"),
            "worktree_path": manifest.get("worktree", {}).get("path"),
        },
        "capture": extract_capture(final),
        "agents": agents,
    }


def replay_artifact(source: Path) -> dict[str, Any]:
    replay = load_replay_input(source)
    configuration = replay.get("configuration")
    capture = replay.get("capture")
    agents = replay.get("agents")
    if not isinstance(configuration, dict) or not isinstance(capture, dict) or not isinstance(agents, dict):
        raise BenchmarkError("replay input omitted configuration, capture, or agents")
    marker = configuration.get("marker")
    path = configuration.get("path")
    worktree_path = configuration.get("worktree_path")
    if not all(isinstance(value, str) and value for value in (marker, path, worktree_path)):
        raise BenchmarkError("replay configuration omitted marker, path, or worktree_path")
    search_count = int(configuration.get("search_count", 0))
    read_count = int(configuration.get("read_count", 0))
    read_limit = int(configuration.get("read_limit", 0))
    transcripts = {
        route: str((agents.get(route) or {}).get("transcript_xml") or "")
        for route in ("local", "worktree")
    }
    agent_results = {
        route: {
            "status": (agents.get(route) or {}).get("status"),
            "session_id": response_session_id((agents.get(route) or {}).get("start_response")),
            "start_response": (agents.get(route) or {}).get("start_response"),
            "wait_response": (agents.get(route) or {}).get("wait_response"),
        }
        for route in ("local", "worktree")
    }
    samples: list[dict[str, Any]] = []
    failures: list[str] = []
    try:
        samples = build_samples(capture)
        classify_routes(samples, search_count, read_count, expected_agent_run_ids(agent_results))
        failures.extend(validate_integrity(
            capture,
            samples,
            transcripts,
            agent_results,
            marker,
            path,
            search_count,
            read_count,
            read_limit,
            Path(worktree_path),
        ))
    except (BenchmarkError, KeyError, TypeError, ValueError) as error:
        failures.append(str(error))
    summary = {
        "schema_version": SCHEMA_VERSION,
        "status": "failed" if failures else "completed",
        "latency_policy": "report_only",
        "operational_error": None,
        "integrity": {"ok": not failures, "failures": failures},
        "samples": summarize_samples(samples),
        "replay_source": source.name,
    }
    validate_summary_schema(summary)
    return summary


class CLIRunner:
    def __init__(self, cli: Path, window_id: int, root: Path, output: Path) -> None:
        self.cli, self.window_id, self.root, self.output = cli, window_id, root, output
        self.lock = threading.Lock()
        self.ordinal = 0

    def run(self, label: str, tool: str | None = None, payload: dict[str, Any] | None = None,
            timeout: float = 180, check: bool = True, extra: list[str] | None = None,
            parse_json: bool = True) -> Any:
        if extra is not None:
            command = [str(self.cli), *extra]
        else:
            routed = dict(payload or {})
            routed["_windowID"] = self.window_id
            command = [str(self.cli), "--raw-json", "-w", str(self.window_id), "-c", str(tool),
                       "-j", json.dumps(routed, separators=(",", ":"), sort_keys=True)]
        started = utc_now()
        process = subprocess.run(command, cwd=self.root, text=True, capture_output=True, timeout=timeout)
        record = {
            "schema_version": SCHEMA_VERSION,
            "label": label,
            "command": command,
            "started_at": started,
            "finished_at": utc_now(),
            "returncode": process.returncode,
            "stdout": process.stdout,
            "stderr": process.stderr,
        }
        with self.lock:
            ordinal = self.ordinal
            self.ordinal += 1
            record["ordinal"] = ordinal
            safe = re.sub(r"[^A-Za-z0-9_.-]+", "-", label)
            save_json(self.output / "raw-cli-calls" / f"{ordinal:03d}-{safe}.json", record)
            with (self.output / "raw-cli-calls.ndjson").open("a", encoding="utf-8") as stream:
                stream.write(json.dumps(record, sort_keys=True) + "\n")
        if check and process.returncode:
            raise BenchmarkError(f"{label} failed ({process.returncode}): {process.stderr.strip()}")
        if not parse_json:
            return {"stdout": process.stdout.strip(), "stderr": process.stderr.strip(), "returncode": process.returncode}
        if not process.stdout.strip():
            return {}
        try:
            return json.loads(process.stdout)
        except json.JSONDecodeError as error:
            if check:
                raise BenchmarkError(f"{label} returned non-JSON stdout") from error
            return {"unparsed_stdout": process.stdout}


def command(command: list[str], root: Path, check: bool = True) -> subprocess.CompletedProcess[str]:
    process = subprocess.run(command, cwd=root, text=True, capture_output=True)
    if check and process.returncode:
        raise BenchmarkError(f"{' '.join(command)} failed: {process.stderr.strip()}")
    return process


def validate_worktree_identity(
    repo_common_directory: Path,
    candidate_common_directory: Path,
    linked: bool,
    same_as_workspace_root: bool,
) -> None:
    if repo_common_directory.resolve() != candidate_common_directory.resolve():
        raise BenchmarkError("supplied worktree belongs to a different git common directory")
    if not linked:
        raise BenchmarkError("supplied worktree is not registered as a linked git worktree")
    if same_as_workspace_root:
        raise BenchmarkError("supplied worktree must differ from the normal workspace root")


def git_common_directory(path: Path) -> Path:
    raw = command(["git", "rev-parse", "--git-common-dir"], path).stdout.strip()
    common = Path(raw)
    return (common if common.is_absolute() else path / common).resolve()


def worktree_manifest_metadata(path: Path, sha: str, status: str, common_directory: Path) -> dict[str, Any]:
    return {
        "path": str(path),
        "sha": sha,
        "dirty": bool(status),
        "status_porcelain": status.splitlines(),
        "git_common_directory": str(common_directory),
    }


def worktree_metadata(root: Path, candidate: Path) -> dict[str, Any]:
    resolved_root = root.resolve()
    resolved_candidate = candidate.resolve(strict=True)
    listed = {
        Path(line.removeprefix("worktree ")).resolve()
        for line in command(["git", "worktree", "list", "--porcelain"], root).stdout.splitlines()
        if line.startswith("worktree ")
    }
    validate_worktree_identity(
        git_common_directory(root),
        git_common_directory(resolved_candidate),
        resolved_candidate in listed,
        resolved_candidate == resolved_root,
    )
    status = command(
        ["git", "status", "--porcelain=v1", "--untracked-files=all"], resolved_candidate
    ).stdout
    return worktree_manifest_metadata(
        resolved_candidate,
        command(["git", "rev-parse", "HEAD"], resolved_candidate).stdout.strip(),
        status,
        git_common_directory(resolved_candidate),
    )


def resolve_cli(argument: str | None) -> Path:
    candidates = [argument, os.environ.get("REPOPROMPT_DEBUG_CLI_INSTALL_PATH"), shutil.which("rpce-cli-debug"),
                  str(Path.home() / "Library/Application Support/RepoPrompt CE/repoprompt_ce_cli_debug")]
    for candidate in candidates:
        if candidate:
            path = Path(candidate).expanduser()
            if path.is_file() and os.access(path, os.X_OK):
                return path.resolve(strict=True)
    raise BenchmarkError("rpce-cli-debug was not found")


def agent_prompt(route: str, marker: str, path: str, searches: int, reads: int, read_limit: int) -> str:
    search = (
        f'Call file_search exactly {searches} times sequentially with exactly '
        f'{{"pattern":{json.dumps(marker)},"regex":false,"mode":"content","filter":{{"paths":[{json.dumps(path)}]}},'
        '"max_results":20,"context_lines":1}}.'
    )
    read = (
        f'Call read_file exactly {reads} times sequentially with exactly '
        f'{{"path":{json.dumps(path)},"start_line":1,"limit":{read_limit}}}.'
    )
    ordered = f"{search} Then {read}" if route == "local" else f"{read} Then {search}"
    return (
        "Run a strict bounded file-tool diagnostic. Do not delegate, edit, use shell, or call any tool except "
        f"file_search and read_file. Do not batch or parallelize calls. {ordered} "
        f"Each search must return at least one match for {marker!r}; each read must succeed. "
        "After all calls reply exactly AGENT_FILE_TOOL_DIAGNOSTIC_OK."
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--replay", help="offline replay.json file, fixture directory, or benchmark artifact directory")
    parser.add_argument("--cli")
    parser.add_argument("--window-id", type=int, default=1)
    parser.add_argument("--marker", default="debugDiagnosticsToolName")
    parser.add_argument("--path", default="Sources/RepoPrompt/Features/Diagnostics/MCP/MCPConnectionManager+DebugDiagnostics.swift")
    parser.add_argument("--search-count", type=int, default=5)
    parser.add_argument("--read-count", type=int, default=5)
    parser.add_argument("--read-limit", type=int, default=24)
    parser.add_argument("--timeout", type=float, default=720)
    parser.add_argument("--max-samples", type=int, default=50000)
    parser.add_argument("--worktree", help="existing linked worktree to preserve")
    parser.add_argument("--output-root", default="/tmp/rpce-agent-file-tools/v1")
    parser.add_argument("--label", default="paired")
    args = parser.parse_args(argv)
    if args.replay:
        summary = replay_artifact(Path(args.replay))
        print(json.dumps(summary, indent=2, sort_keys=True))
        return 0 if summary["status"] == "completed" else 1
    if min(args.window_id, args.search_count, args.read_count, args.read_limit) < 1:
        parser.error("window-id and counts must be positive")
    if not 100 <= args.max_samples <= 100000:
        parser.error("max-samples must be between 100 and 100000")

    root = Path(__file__).resolve().parent.parent
    repo_sha = command(["git", "rev-parse", "HEAD"], root).stdout.strip()
    repo_status = command(["git", "status", "--porcelain=v1", "--untracked-files=all"], root).stdout
    cli = resolve_cli(args.cli)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    safe_label = re.sub(r"[^A-Za-z0-9_.-]+", "-", args.label).strip("-") or "paired"
    output_root = (root / args.output_root).resolve()
    output_root.mkdir(parents=True, exist_ok=True)
    output = output_root / f"{stamp}-{safe_label}-{uuid.uuid4().hex[:8]}"
    output.mkdir(mode=0o700)
    runner = CLIRunner(cli, args.window_id, root, output)
    version = runner.run("cli-version", extra=["--version"], parse_json=False)

    def interrupted(signum: int, _frame: Any) -> None:
        raise KeyboardInterrupt(f"signal {signum}")

    old_handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
    for sig in old_handlers:
        signal.signal(sig, interrupted)

    auto_created = args.worktree is None
    temporary_parent: Path | None = None
    if args.worktree:
        worktree = Path(args.worktree).expanduser().resolve(strict=True)
    else:
        temporary_parent = Path(tempfile.mkdtemp(prefix="rpce-agent-file-tools-"))
        worktree = temporary_parent / "worktree"
        try:
            command(["git", "worktree", "add", "--detach", str(worktree), repo_sha], root)
        except BaseException:
            if worktree.exists():
                command(["git", "worktree", "remove", str(worktree)], root, check=False)
            try:
                temporary_parent.rmdir()
            except OSError:
                pass
            for sig, handler in old_handlers.items():
                signal.signal(sig, handler)
            raise

    try:
        worktree_info = worktree_metadata(root, worktree)
    except BaseException:
        if auto_created and worktree.exists():
            command(["git", "worktree", "remove", str(worktree)], root, check=False)
        if temporary_parent:
            try:
                temporary_parent.rmdir()
            except OSError:
                pass
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)
        raise

    manifest: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "run_id": output.name,
        "created_at": utc_now(),
        "repo": {"root": str(root), "sha": repo_sha, "dirty": bool(repo_status),
                 "status_porcelain": repo_status.splitlines()},
        "cli": {"realpath": str(cli), "version": version, "sha256": hashlib.sha256(cli.read_bytes()).hexdigest()},
        "configuration": vars(args),
        "worktree": {**worktree_info, "auto_created": auto_created, "cleanup": "pending"},
        "sessions": {},
    }
    save_json(output / "manifest.json", manifest)

    capture_started = False
    capture: dict[str, Any] | None = None
    sessions: dict[str, dict[str, Any]] = {}
    logs: dict[str, Any] = {}
    runtime_after: Any = None
    operational_error: BaseException | None = None

    try:
        begin = runner.run("capture-begin", DEBUG_TOOL, {
            "op": "mcp_read_search_capture_begin", "label": output.name, "max_samples": args.max_samples,
        })
        capture_started = True
        save_json(output / "capture-begin.json", begin)
        before = runner.run("runtime-before", DEBUG_TOOL, {
            "op": "mcp_read_search_runtime_snapshot", "window_id": args.window_id,
            "recent_publication_limit": 16, "root_limit": 256,
        })
        save_json(output / "runtime-before.json", before)

        def start(route: str) -> tuple[str, Any]:
            payload: dict[str, Any] = {
                "op": "start", "detach": True, "model_id": "explore", "inherit_worktree": False,
                "session_name": f"Agent file-tool diagnostic ({route})",
                "message": agent_prompt(route, args.marker, args.path, args.search_count, args.read_count, args.read_limit),
            }
            if route == "worktree":
                payload["worktree"] = str(worktree)
            return route, runner.run(f"agent-{route}-start", "agent_run", payload, timeout=90)

        start_errors: list[BaseException] = []
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = {route: pool.submit(start, route) for route in ("local", "worktree")}
            for route, future in futures.items():
                try:
                    _, response = future.result()
                    session_id = response_session_id(response)
                    if not session_id:
                        raise BenchmarkError(f"{route} start omitted session_id")
                    sessions[route] = {
                        "session_id": session_id,
                        "status": find_string(response, "status"),
                        "start_response": response,
                    }
                    save_json(output / "agents" / route / "start.json", response)
                except BaseException as error:
                    start_errors.append(error)
        manifest["sessions"] = {route: {"session_id": value["session_id"]} for route, value in sessions.items()}
        save_json(output / "manifest.json", manifest)
        if start_errors:
            raise BenchmarkError("; ".join(str(error) for error in start_errors))

        def wait(item: tuple[str, dict[str, Any]]) -> tuple[str, Any]:
            route, session = item
            return route, runner.run(f"agent-{route}-wait", "agent_run", {
                "op": "wait", "session_id": session["session_id"], "timeout": args.timeout,
            }, timeout=args.timeout + 30)

        with ThreadPoolExecutor(max_workers=2) as pool:
            waits = dict(pool.map(wait, sessions.items()))
        for route, response in waits.items():
            sessions[route]["status"] = (find_string(response, "status") or "").lower()
            sessions[route]["wait_response"] = response
            save_json(output / "agents" / route / "wait.json", response)
        runtime_after = runner.run("runtime-after", DEBUG_TOOL, {
            "op": "mcp_read_search_runtime_snapshot", "window_id": args.window_id,
            "recent_publication_limit": 16, "root_limit": 256,
        })
        save_json(output / "runtime-after.json", runtime_after)
    except BaseException as error:
        operational_error = error
    finally:
        if capture_started:
            try:
                final = runner.run("capture-finish", DEBUG_TOOL, {
                    "op": "mcp_read_search_capture_snapshot", "finish": True, "include_timeline": True,
                })
                capture = extract_capture(final)
                save_json(output / "capture-final.json", final)
            except BaseException as error:
                operational_error = operational_error or error
        cleanup_errors: list[BaseException] = []
        for route, session in sessions.items():
            status = str(session.get("status") or "").lower()
            try:
                if status not in TERMINAL_STATUSES:
                    polled = runner.run(f"agent-{route}-poll-cleanup", "agent_run", {
                        "op": "poll", "session_id": session["session_id"],
                    }, timeout=30, check=False)
                    status = (find_string(polled, "status") or "").lower()
                if status not in TERMINAL_STATUSES:
                    cancel_error: BaseException | None = None
                    try:
                        runner.run(f"agent-{route}-cancel-cleanup", "agent_run", {
                            "op": "cancel", "session_id": session["session_id"],
                        }, timeout=30, check=True)
                    except BaseException as error:
                        cancel_error = error
                    settled = runner.run(f"agent-{route}-wait-after-cancel", "agent_run", {
                        "op": "wait", "session_id": session["session_id"], "timeout": 30,
                    }, timeout=45, check=False)
                    status = (find_string(settled, "status") or "").lower()
                    cleanup_errors.extend(
                        BenchmarkError(message)
                        for message in cancellation_failure_messages(route, cancel_error, status)
                    )
                session["final_status"] = status
                log = runner.run(f"agent-{route}-get-log", "agent_manage", {
                    "op": "get_log", "session_id": session["session_id"], "offset": 0, "limit": 1000,
                }, timeout=60, check=False)
                logs[route] = log
                save_json(output / "agents" / route / "log.json", log)
            except BaseException as error:
                session["final_status"] = status
                cleanup_errors.append(error)
        if cleanup_errors:
            manifest["cleanup_errors"] = [str(error) for error in cleanup_errors]
            operational_error = operational_error or BenchmarkError("; ".join(str(error) for error in cleanup_errors))
        if runtime_after is None:
            try:
                runtime_after = runner.run("runtime-cleanup", DEBUG_TOOL, {
                    "op": "mcp_read_search_runtime_snapshot", "window_id": args.window_id,
                    "recent_publication_limit": 16, "root_limit": 256,
                }, check=False)
                save_json(output / "runtime-after.json", runtime_after)
            except BaseException as error:
                operational_error = operational_error or error

        exists = worktree.exists()
        clean = exists and not command(
            ["git", "-C", str(worktree), "status", "--porcelain=v1", "--untracked-files=all"], root, check=False
        ).stdout.strip()
        sessions_terminal = all(
            str(session.get("final_status") or session.get("status") or "").lower() in TERMINAL_STATUSES
            for session in sessions.values()
        )
        decision = cleanup_decision(auto_created, exists, clean, sessions_terminal)
        manifest["worktree"]["cleanup"] = decision
        if decision == "remove_clean_auto_created":
            removal = command(["git", "worktree", "remove", str(worktree)], root, check=False)
            manifest["worktree"]["remove_returncode"] = removal.returncode
            manifest["worktree"]["remove_stderr"] = removal.stderr.strip()
            if removal.returncode:
                operational_error = operational_error or BenchmarkError("clean temporary worktree removal failed")
            elif temporary_parent:
                try:
                    temporary_parent.rmdir()
                except OSError:
                    pass
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)

    samples: list[dict[str, Any]] = []
    failures: list[str] = []
    transcripts = {route: find_string(log, "transcript_xml") or "" for route, log in logs.items()}
    if capture is None:
        failures.append("final capture unavailable")
        failures.extend(validate_agent_completion(sessions, transcripts))
        failures.extend(validate_route_binding_metadata(sessions, worktree))
    else:
        try:
            samples = build_samples(capture)
            classify_routes(samples, args.search_count, args.read_count, expected_agent_run_ids(sessions))
            failures.extend(validate_integrity(
                capture,
                samples,
                transcripts,
                sessions,
                args.marker,
                args.path,
                args.search_count,
                args.read_count,
                args.read_limit,
                worktree,
            ))
        except BenchmarkError as error:
            failures.append(str(error))
    with (output / "samples.ndjson").open("w", encoding="utf-8") as stream:
        for sample in samples:
            stream.write(json.dumps(sample, sort_keys=True) + "\n")
    summary = {
        "schema_version": SCHEMA_VERSION,
        "status": "failed" if operational_error or failures else "completed",
        "latency_policy": "report_only",
        "operational_error": repr(operational_error) if operational_error else None,
        "integrity": {"ok": not failures, "failures": failures},
        "samples": summarize_samples(samples),
        "artifact_directory": str(output),
    }
    validate_summary_schema(summary)
    save_json(output / "summary.json", summary)
    manifest.update({"finished_at": utc_now(), "status": summary["status"], "integrity": summary["integrity"]})
    save_json(output / "manifest.json", manifest)
    print(json.dumps(summary, indent=2, sort_keys=True))
    print(f"Artifacts: {output}")
    if isinstance(operational_error, KeyboardInterrupt):
        return 130
    return 0 if summary["status"] == "completed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
