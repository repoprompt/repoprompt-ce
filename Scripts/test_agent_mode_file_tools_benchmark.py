#!/usr/bin/env python3
"""Pure tests for benchmark_agent_mode_file_tools.py."""
from __future__ import annotations

import contextlib
import io
import json
from pathlib import Path
import re
import sys
import unittest
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
FIXTURE_ROOT = SCRIPT_DIR / "Fixtures" / "agent-mode-file-tools" / "v1"
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import benchmark_agent_mode_file_tools as benchmark  # noqa: E402


def event(ordinal: int, offset: float, name: str, connection: str, invocation: str, dimensions: str = "") -> dict:
    return {
        "ordinal": ordinal,
        "offset_ms": offset,
        "event_name": name,
        "correlation_id": invocation,
        "request_identity": {
            "connection_id": connection,
            "app_invocation_id": invocation,
            "jsonrpc_request_id": ordinal,
        },
        "sanitized_dimensions": dimensions,
    }


def timeline(connection: str, invocation: str, tool: str, start: float, run_id: str | None = None) -> list[dict]:
    success = "Search.ProviderResultReady" if tool == "file_search" else "ReadFile.ProviderResultReady"
    run_id = run_id or f"{connection}-run"
    events = [
        event(1, start, benchmark.RECEIVED, connection, invocation, f"tool={tool}"),
        event(2, start + 1, "MCP.ToolCall.RoutingSnapshotCompleted", connection, invocation, f"tool={tool}"),
    ]
    if tool == "file_search":
        projected = connection in {"connection-b", "worktree-connection"}
        events.append(event(
            3,
            start + 2,
            "Search.ProviderDTOReady",
            connection,
            invocation,
            f"outcome=completed matchCount=1 usesWorktreeProjection={str(projected).lower()}",
        ))
    events.extend([
        event(4, start + 3, success, connection, invocation),
        event(5, start + 5, benchmark.MAIN_ACTOR_EXITED, connection, invocation,
              f"tool={tool} observerType=event_completion runID={run_id}"),
    ])
    return events


class CaptureParsingTests(unittest.TestCase):
    def test_build_samples_uses_event_completion_main_actor_exit_envelope(self) -> None:
        events = timeline("local-connection", "one", "file_search", 10)
        events.insert(-1, event(3, 14, benchmark.MAIN_ACTOR_EXITED, "local-connection", "one",
                                "tool=file_search observerType=provider_projection_capture"))
        events.append(event(6, 17, benchmark.MAIN_ACTOR_EXITED, "local-connection", "one",
                            "tool=file_search observerType=provider_projection_resume"))
        sample = benchmark.build_samples({"lifecycle_events": events})[0]
        self.assertEqual(sample["envelope_ms"], 5)
        self.assertEqual(sample["stages"][1]["delta_ms"], 1)
        self.assertEqual(sample["stages"][-1]["dimensions"]["observerType"], "event_completion")
        self.assertEqual(sample["connection_id"], "local-connection")

    def test_build_samples_rejects_missing_envelope_endpoint(self) -> None:
        events = timeline("local", "one", "read_file", 0)[:-1]
        with self.assertRaisesRegex(benchmark.BenchmarkError, "event_completion MainActorExited"):
            benchmark.build_samples({"lifecycle_events": events})

    def test_build_samples_requires_run_id_on_event_completion(self) -> None:
        events = timeline("local", "one", "read_file", 0)
        events[1]["sanitized_dimensions"] = "tool=read_file runID=earlier-only"
        events[-1]["sanitized_dimensions"] = "tool=read_file observerType=event_completion"
        with self.assertRaisesRegex(benchmark.BenchmarkError, "event_completion omitted runID"):
            benchmark.build_samples({"lifecycle_events": events})

    def test_parse_dimensions_preserves_typed_stage_metadata(self) -> None:
        self.assertEqual(
            benchmark.parse_dimensions("tool=file_search matchCount=3 cacheHit=true durationUs=4.5"),
            {"tool": "file_search", "matchCount": 3, "cacheHit": True, "durationUs": 4.5},
        )


class RoutingTests(unittest.TestCase):
    def test_opposite_tool_order_signatures_classify_local_and_worktree(self) -> None:
        events = []
        offset = 0.0
        for index, tool in enumerate(["file_search", "file_search", "read_file"]):
            events += timeline("connection-a", f"a-{index}", tool, offset, "local-run")
            offset += 10
        for index, tool in enumerate(["read_file", "file_search", "file_search"]):
            events += timeline("connection-b", f"b-{index}", tool, offset, "worktree-run")
            offset += 10
        samples = benchmark.build_samples({"lifecycle_events": events})
        routes = benchmark.classify_routes(
            samples,
            search_count=2,
            read_count=1,
            expected_run_ids={"local": "local-run", "worktree": "worktree-run"},
        )
        self.assertEqual(routes, {"connection-a": "local", "connection-b": "worktree"})
        self.assertEqual({sample["route"] for sample in samples}, {"local", "worktree"})

    def test_unexpected_or_extra_connection_fails_classification(self) -> None:
        samples = benchmark.build_samples({"lifecycle_events": timeline("only", "one", "file_search", 0)})
        with self.assertRaisesRegex(benchmark.BenchmarkError, "two file-tool connections"):
            benchmark.classify_routes(
                samples,
                search_count=1,
                read_count=1,
                expected_run_ids={"local": "local-run", "worktree": "worktree-run"},
            )

    def test_classification_rejects_capture_from_unexpected_agent_run(self) -> None:
        events = timeline("connection-a", "a-search", "file_search", 0, "unrelated-run")
        events += timeline("connection-a", "a-read", "read_file", 10, "unrelated-run")
        events += timeline("connection-b", "b-read", "read_file", 20, "worktree-run")
        events += timeline("connection-b", "b-search", "file_search", 30, "worktree-run")
        samples = benchmark.build_samples({"lifecycle_events": events})
        with self.assertRaisesRegex(benchmark.BenchmarkError, "unexpected agent run"):
            benchmark.classify_routes(
                samples,
                search_count=1,
                read_count=1,
                expected_run_ids={"local": "local-run", "worktree": "worktree-run"},
            )


class StatisticsAndSchemaTests(unittest.TestCase):
    def test_percentile_interpolates_and_handles_empty_input(self) -> None:
        self.assertEqual(benchmark.percentile([], 0.95), None)
        self.assertEqual(benchmark.percentile([1, 3], 0.50), 2)
        self.assertAlmostEqual(benchmark.percentile([1, 2, 3, 4], 0.95), 3.85)

    def test_summary_is_report_only_and_grouped_by_route_and_tool(self) -> None:
        samples = [
            {"route": "local", "tool": "read_file", "envelope_ms": 2},
            {"route": "local", "tool": "read_file", "envelope_ms": 4},
        ]
        grouped = benchmark.summarize_samples(samples)
        self.assertEqual(grouped["groups"][0]["p50_ms"], 3)
        summary = {
            "schema_version": benchmark.SCHEMA_VERSION,
            "status": "completed",
            "latency_policy": "report_only",
            "samples": grouped,
            "integrity": {"ok": True, "failures": []},
        }
        benchmark.validate_summary_schema(summary)
        bad = dict(summary, latency_policy="threshold")
        with self.assertRaisesRegex(benchmark.BenchmarkError, "schema metadata"):
            benchmark.validate_summary_schema(bad)

    def test_nested_json_payload_schema_is_found(self) -> None:
        wrapped = {"content": [{"text": json.dumps({"ok": True, "op": "capture", "capture": {"active": False}})}]}
        self.assertEqual(benchmark.find_object(wrapped, "capture", "capture")["capture"], {"active": False})


class IntegrityAndCleanupTests(unittest.TestCase):
    def test_transcript_arguments_require_exact_workload(self) -> None:
        path = "Sources/Marker.swift"
        search = {
            "pattern": "KNOWN",
            "regex": False,
            "mode": "content",
            "filter": {"paths": [path]},
            "max_results": 20,
            "context_lines": 1,
        }
        read = {"path": path, "start_line": 1, "limit": 24}
        transcript = (
            f'<tool_call name="file_search">{json.dumps(search)}</tool_call>\n'
            f'<tool_call name="read_file">{json.dumps(read)}</tool_call>'
        )
        benchmark.validate_transcript_arguments(transcript, "KNOWN", path, 24)
        bad_search = dict(search, mode="auto")
        bad_transcript = transcript.replace(json.dumps(search), json.dumps(bad_search))
        with self.assertRaisesRegex(benchmark.BenchmarkError, "exact configured workload"):
            benchmark.validate_transcript_arguments(bad_transcript, "KNOWN", path, 24)

    def test_transcript_rejects_extra_tools_and_wrong_read_values(self) -> None:
        path = "Sources/Marker.swift"
        search = {
            "pattern": "KNOWN", "regex": False, "mode": "content",
            "filter": {"paths": [path]}, "max_results": 20, "context_lines": 1,
        }
        read = {"path": path, "start_line": 1, "limit": 23}
        transcript = (
            f'<tool_call name="file_search">{json.dumps(search)}</tool_call>\n'
            f'<tool_call name="read_file">{json.dumps(read)}</tool_call>\n'
            '<tool_call name="get_file_tree">{}</tool_call>'
        )
        with self.assertRaisesRegex(benchmark.BenchmarkError, "unexpected transcript tools"):
            benchmark.validate_transcript_arguments(transcript, "KNOWN", path, 24)
        transcript = transcript.rsplit("\n", 1)[0]
        with self.assertRaisesRegex(benchmark.BenchmarkError, "configured workload"):
            benchmark.validate_transcript_arguments(transcript, "KNOWN", path, 24)

    def test_compacted_transcript_allows_key_paths_and_single_set_status(self) -> None:
        path = "Sources/Marker.swift"
        search = {
            "pattern": "KNOWN", "regex": False, "mode": "content",
            "filter": {"paths": [path]}, "max_results": 20, "context_lines": 1,
        }
        read = {"path": path, "start_line": 1, "limit": 24, "key_paths": ["content"]}
        status = '<tool_call name="set_status">{"session_name":"diagnostic"}</tool_call>'
        compacted_workload = (
            f'<tool_call name="read_file">{json.dumps(read)}</tool_call>\n'
            f'<tool_call name="file_search">{json.dumps(search)}</tool_call>'
        )
        benchmark.validate_transcript_arguments(
            f"{status}\n{compacted_workload}", "KNOWN", path, 24
        )
        with self.assertRaisesRegex(benchmark.BenchmarkError, "duplicate set_status"):
            benchmark.validate_transcript_arguments(
                f"{status}\n{status}\n{compacted_workload}", "KNOWN", path, 24
            )
        with self.assertRaisesRegex(benchmark.BenchmarkError, "unexpected transcript tools"):
            benchmark.validate_transcript_arguments(
                f'<tool_call name="git">{{"op":"status"}}</tool_call>\n{compacted_workload}',
                "KNOWN", path, 24,
            )

    def test_transcript_rejects_unknown_read_enrichment_and_missing_surface(self) -> None:
        path = "Sources/Marker.swift"
        search = {
            "pattern": "KNOWN", "regex": False, "mode": "content",
            "filter": {"paths": [path]}, "max_results": 20, "context_lines": 1,
        }
        read = {"path": path, "start_line": 1, "limit": 24, "unknown": True}
        transcript = (
            f'<tool_call name="file_search">{json.dumps(search)}</tool_call>\n'
            f'<tool_call name="read_file">{json.dumps(read)}</tool_call>'
        )
        with self.assertRaisesRegex(benchmark.BenchmarkError, "unknown enrichment"):
            benchmark.validate_transcript_arguments(transcript, "KNOWN", path, 24)
        with self.assertRaisesRegex(benchmark.BenchmarkError, "at least one"):
            benchmark.validate_transcript_arguments(
                f'<tool_call name="file_search">{json.dumps(search)}</tool_call>', "KNOWN", path, 24
            )

    def test_worktree_manifest_metadata_records_sha_and_dirty_state(self) -> None:
        metadata = benchmark.worktree_manifest_metadata(
            Path("/tmp/worktree"), "abc123", " M Sources/File.swift\n", Path("/tmp/repo/.git")
        )
        self.assertEqual(metadata["sha"], "abc123")
        self.assertTrue(metadata["dirty"])
        self.assertEqual(metadata["status_porcelain"], [" M Sources/File.swift"])

    def test_route_binding_metadata_independently_proves_local_and_worktree_routes(self) -> None:
        configured = Path("/tmp/rpce-route-worktree")
        results = {
            "local": {
                "start_response": {"status": "running", "session": {"id": "local"}},
                "wait_response": {"status": "completed", "session": {"id": "local"}},
            },
            "worktree": {
                "start_response": {
                    "status": "running",
                    "worktree_bindings": [{"worktree_root_path": str(configured)}],
                },
                "wait_response": {
                    "status": "completed",
                    "worktree": {"path": "/tmp/rpce-route-worktree/../rpce-route-worktree"},
                },
            },
        }
        self.assertEqual(benchmark.validate_route_binding_metadata(results, configured), [])

        results["worktree"]["wait_response"] = {"status": "completed"}
        failures = benchmark.validate_route_binding_metadata(results, configured)
        self.assertTrue(any("omitted worktree binding" in failure for failure in failures))

        results["worktree"]["wait_response"] = {"worktree": {"path": "/tmp/wrong-worktree"}}
        results["local"]["start_response"] = {
            "worktree_bindings": [{"worktree_root_path": str(configured)}]
        }
        failures = benchmark.validate_route_binding_metadata(results, configured)
        self.assertTrue(any("local agent unexpectedly" in failure for failure in failures))
        self.assertTrue(any("mismatched binding" in failure for failure in failures))

    def test_agent_completion_requires_completed_status_and_exact_token(self) -> None:
        transcripts = {
            "local": "<assistant>AGENT_FILE_TOOL_DIAGNOSTIC_OK</assistant>",
            "worktree": "<assistant>AGENT_FILE_TOOL_DIAGNOSTIC_OK</assistant>",
        }
        results = {
            "local": {"status": "completed", "wait_response": {"assistant_text": "AGENT_FILE_TOOL_DIAGNOSTIC_OK"}},
            "worktree": {"status": "completed", "wait_response": {}},
        }
        self.assertEqual(benchmark.validate_agent_completion(results, transcripts), [])
        results["worktree"]["status"] = "failed"
        results["local"]["wait_response"] = {"assistant_text": "almost AGENT_FILE_TOOL_DIAGNOSTIC_OK"}
        failures = benchmark.validate_agent_completion(results, transcripts)
        self.assertTrue(any("status was failed" in failure for failure in failures))
        self.assertTrue(any("final response" in failure for failure in failures))

    def test_agent_session_identity_requires_matching_distinct_start_and_wait_sessions(self) -> None:
        results = {
            "local": {
                "session_id": "local-session",
                "start_response": {"session_id": "local-session"},
                "wait_response": {"session_id": "local-session"},
            },
            "worktree": {
                "session_id": "worktree-session",
                "start_response": {"session_id": "worktree-session"},
                "wait_response": {"session_id": "worktree-session"},
            },
        }
        self.assertEqual(benchmark.validate_agent_session_identity(results), [])
        results["worktree"]["wait_response"] = {"session_id": "local-session"}
        failures = benchmark.validate_agent_session_identity(results)
        self.assertTrue(any("worktree agent start/wait" in failure for failure in failures))
        results["worktree"]["wait_response"] = {
            "session_id": "worktree-session",
            "sessionId": "conflicting-alias-session",
        }
        failures = benchmark.validate_agent_session_identity(results)
        self.assertTrue(any("worktree agent start/wait" in failure for failure in failures))
        results["worktree"]["wait_response"] = {
            "session_id": "worktree-session",
            "session": {"id": "conflicting-session"},
        }
        failures = benchmark.validate_agent_session_identity(results)
        self.assertTrue(any("worktree agent start/wait" in failure for failure in failures))

    def test_agent_run_identity_rejects_conflicting_aliases(self) -> None:
        results = {
            "local": {"wait_response": {"run_id": "local-run", "runId": "conflict"}},
            "worktree": {"wait_response": {"run_id": "worktree-run"}},
        }
        with self.assertRaisesRegex(benchmark.BenchmarkError, "local agent wait response omitted run_id"):
            benchmark.expected_agent_run_ids(results)

    def test_positive_search_stages_require_local_and_worktree_projection_counts(self) -> None:
        capture = {
            "stages": [
                {
                    "stage_name": "EditFlow.Search.DTOBuild",
                    "sample_count": 2,
                    "sanitized_dimensions": (
                        "outcome=completed matchCount=1 usesWorktreeProjection=false"
                    ),
                },
                {
                    "stage_name": "EditFlow.Search.DTOBuild",
                    "sample_count": 2,
                    "sanitized_dimensions": (
                        "outcome=completed matchCount=1 usesWorktreeProjection=true"
                    ),
                },
            ]
        }
        self.assertEqual(
            benchmark.positive_search_projection_counts(capture),
            {False: 2, True: 2},
        )
        capture["stages"][1]["sanitized_dimensions"] = (
            "outcome=completed matchCount=1 usesWorktreeProjection=false"
        )
        self.assertEqual(benchmark.positive_search_projection_counts(capture), {False: 4})

    def test_sequential_calls_reject_same_connection_overlap_but_allow_cross_agent_overlap(self) -> None:
        samples = [
            {"connection_id": "a", "join_key": "a1", "received_offset_ms": 0, "main_actor_exited_offset_ms": 5},
            {"connection_id": "a", "join_key": "a2", "received_offset_ms": 4, "main_actor_exited_offset_ms": 7},
            {"connection_id": "b", "join_key": "b1", "received_offset_ms": 1, "main_actor_exited_offset_ms": 6},
        ]
        failures = benchmark.sequential_call_failures(samples)
        self.assertEqual(len(failures), 1)
        self.assertIn("a1 and a2", failures[0])
        samples[1]["received_offset_ms"] = 5
        self.assertEqual(benchmark.sequential_call_failures(samples), [])

    def test_cancel_failure_and_nonterminal_settle_are_cleanup_failures(self) -> None:
        cancel_error = RuntimeError("cancel transport failed")
        failures = benchmark.cancellation_failure_messages("local", cancel_error, "running")
        self.assertEqual(len(failures), 2)
        self.assertIn("cancellation failed", failures[0])
        self.assertIn("remained nonterminal", failures[1])
        self.assertEqual(benchmark.cancellation_failure_messages("local", None, "cancelled"), [])

    def test_cleanup_removes_only_owned_clean_terminal_worktree(self) -> None:
        self.assertEqual(benchmark.cleanup_decision(True, True, True, True), "remove_clean_auto_created")
        self.assertEqual(benchmark.cleanup_decision(True, True, True, False), "preserve_nonterminal_sessions")
        self.assertEqual(benchmark.cleanup_decision(True, True, False, True), "preserve_dirty")
        self.assertEqual(benchmark.cleanup_decision(False, True, True, False), "preserve_not_owned")
        self.assertEqual(benchmark.cleanup_decision(True, False, True, False), "already_absent")

    def test_worktree_identity_requires_same_common_dir_link_and_distinct_root(self) -> None:
        common = Path("/tmp/repo/.git").resolve()
        benchmark.validate_worktree_identity(common, common, linked=True, same_as_workspace_root=False)
        with self.assertRaisesRegex(benchmark.BenchmarkError, "different git common"):
            benchmark.validate_worktree_identity(common, Path("/tmp/other/.git"), True, False)
        with self.assertRaisesRegex(benchmark.BenchmarkError, "not registered"):
            benchmark.validate_worktree_identity(common, common, False, False)
        with self.assertRaisesRegex(benchmark.BenchmarkError, "must differ"):
            benchmark.validate_worktree_identity(common, common, True, True)


class ReplayFixtureTests(unittest.TestCase):
    def test_success_fixture_replays_exact_scrubbed_timings_offline(self) -> None:
        fixture_dir = FIXTURE_ROOT / "paired-success"
        fixture = json.loads((fixture_dir / "replay.json").read_text(encoding="utf-8"))
        summary = benchmark.replay_artifact(fixture_dir)
        self.assertEqual(summary["status"], fixture["expected"]["status"])
        self.assertTrue(summary["integrity"]["ok"])
        self.assertEqual(summary["samples"]["sample_count"], fixture["expected"]["sample_count"])
        samples = benchmark.build_samples(fixture["capture"])
        actual_timings = {sample["join_key"]: sample["envelope_ms"] for sample in samples}
        self.assertEqual(actual_timings, fixture["expected"]["envelope_ms"])
        grouped = {(group["route"], group["tool"]): group["p50_ms"] for group in summary["samples"]["groups"]}
        self.assertEqual(grouped[("local", "file_search")], 105.353)
        self.assertEqual(grouped[("worktree", "read_file")], 22.929)

        with mock.patch.object(benchmark, "resolve_cli", side_effect=AssertionError("live CLI used")):
            with mock.patch.object(benchmark, "command", side_effect=AssertionError("subprocess used")):
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(benchmark.main(["--replay", str(fixture_dir)]), 0)

    def test_negative_fixture_is_rejected_for_missing_completion(self) -> None:
        fixture_dir = FIXTURE_ROOT / "missing-event-completion"
        fixture = json.loads((fixture_dir / "replay.json").read_text(encoding="utf-8"))
        summary = benchmark.replay_artifact(fixture_dir)
        self.assertEqual(summary["status"], fixture["expected"]["status"])
        self.assertFalse(summary["integrity"]["ok"])
        self.assertTrue(any(
            fixture["expected"]["failure_contains"] in failure
            for failure in summary["integrity"]["failures"]
        ))

    def test_success_fixture_rejects_missing_worktree_projection(self) -> None:
        fixture = json.loads((FIXTURE_ROOT / "paired-success" / "replay.json").read_text(encoding="utf-8"))
        for stage in fixture["capture"]["stages"]:
            stage["sanitized_dimensions"] = stage["sanitized_dimensions"].replace(
                "usesWorktreeProjection=true", "usesWorktreeProjection=false"
            )
        with mock.patch.object(benchmark, "load_replay_input", return_value=fixture):
            summary = benchmark.replay_artifact(Path("fixture.json"))
        self.assertEqual(summary["status"], "failed")
        self.assertTrue(any("local/worktree projections" in failure for failure in summary["integrity"]["failures"]))

    def test_success_fixture_rejects_inverted_per_run_worktree_projection(self) -> None:
        fixture = json.loads((FIXTURE_ROOT / "paired-success" / "replay.json").read_text(encoding="utf-8"))
        for event_value in fixture["capture"]["lifecycle_events"]:
            if event_value.get("event_name") != "Search.ProviderDTOReady":
                continue
            dimensions = event_value["sanitized_dimensions"]
            if "usesWorktreeProjection=true" in dimensions:
                event_value["sanitized_dimensions"] = dimensions.replace(
                    "usesWorktreeProjection=true", "usesWorktreeProjection=false"
                )
            else:
                event_value["sanitized_dimensions"] = dimensions.replace(
                    "usesWorktreeProjection=false", "usesWorktreeProjection=true"
                )
        with mock.patch.object(benchmark, "load_replay_input", return_value=fixture):
            summary = benchmark.replay_artifact(Path("fixture.json"))
        self.assertEqual(summary["status"], "failed")
        self.assertTrue(any(
            "reported usesWorktreeProjection" in failure
            for failure in summary["integrity"]["failures"]
        ))

    def test_success_fixture_rejects_zero_match_per_run_evidence(self) -> None:
        fixture = json.loads((FIXTURE_ROOT / "paired-success" / "replay.json").read_text(encoding="utf-8"))
        for event_value in fixture["capture"]["lifecycle_events"]:
            if event_value.get("event_name") == "Search.ProviderDTOReady":
                event_value["sanitized_dimensions"] = re.sub(
                    r"matchCount=\d+", "matchCount=0", event_value["sanitized_dimensions"]
                )
                break
        with mock.patch.object(benchmark, "load_replay_input", return_value=fixture):
            summary = benchmark.replay_artifact(Path("fixture.json"))
        self.assertEqual(summary["status"], "failed")
        self.assertTrue(any(
            "reported no matches" in failure
            for failure in summary["integrity"]["failures"]
        ))

    def test_checked_in_fixture_text_is_privacy_scrubbed(self) -> None:
        uuid_pattern = re.compile(
            r"(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
        )
        forbidden = ["/Users/", "pvncher", "/Documents/Git/", "repoprompt-worktrees"]
        for replay_file in sorted(FIXTURE_ROOT.glob("*/replay.json")):
            text = replay_file.read_text(encoding="utf-8")
            self.assertIsNone(uuid_pattern.search(text), replay_file)
            for value in forbidden:
                self.assertNotIn(value, text, replay_file)
            fixture = json.loads(text)
            for agent in fixture["agents"].values():
                transcript = agent["transcript_xml"]
                self.assertNotIn("<user>", transcript)
                assistant = re.findall(r"<assistant>(.*?)</assistant>", transcript, re.DOTALL)
                self.assertEqual(assistant, ["AGENT_FILE_TOOL_DIAGNOSTIC_OK"])


if __name__ == "__main__":
    unittest.main()
