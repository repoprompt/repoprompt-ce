#!/usr/bin/env python3
"""Deterministic contract tests for the MCP latency fixture/matrix tooling."""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock
from types import ModuleType

ROOT = Path(__file__).resolve().parents[1]
MATRIX = ROOT / "Scripts/Fixtures/mcp-tool-latency/v1/matrix.json"


def load_module(name: str, path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


fixture = load_module("mcp_latency_fixture", ROOT / "Scripts/mcp-latency/generate_fixture.py")
runner = load_module("mcp_latency_runner", ROOT / "Scripts/mcp-latency/run_latency_matrix.py")


class MCPToolLatencyToolingTests(unittest.TestCase):
    @staticmethod
    def sample(
        invocation_id: str,
        output_format: str = "formatted",
        client_mode: str = "fresh",
        row_id: str = "search-content-few",
    ) -> dict[str, object]:
        response = b"formatted output\n" if output_format == "formatted" else b'{"data":{"results":[]}}\n'
        return {
            "sample_id": f"{row_id}:{output_format}:{client_mode}:{invocation_id}",
            "invocation_id": invocation_id,
            "row_id": row_id,
            "tool": "file_search",
            "format": output_format,
            "client_mode": client_mode,
            "cohort_kind": "warm",
            "phase": "recorded",
            "connection_cohort": f"{client_mode}-0",
            "expected_outcome": "success",
            "outcome": "success",
            "is_error": False,
            "response_sha256": runner.sha256_bytes(response),
            "response_byte_count": len(response),
            "response_is_json": output_format == "raw",
            "repeat_ordinal": 0,
            "sample_ordinal": 0,
            "client_trace": [{
                "invocation_id": invocation_id,
                "output_format": output_format,
                "diagnostic_configuration": "debug",
                "outcome": "success",
                "is_error": False,
                "call_duration_ms": 30,
                "print_duration_ms": 4,
                "content_block_count": 1,
                "text_content_block_count": 1,
                "returned_text_bytes": len(response),
            }],
        }

    @staticmethod
    def capture_payload() -> dict[str, object]:
        lifecycle = [{"event_name": name} for name in runner.LIFECYCLE_EVENT_ALLOWLIST]
        return {
            "capture_mode": runner.SERVER_CAPTURE_MODE,
            "sample_capacity_unit": runner.SERVER_SAMPLE_CAPACITY_UNIT,
            "percentile_semantics": runner.SERVER_PERCENTILE_SEMANTICS,
            "lifecycle_capture_contract": "s0_s7_required_boundaries",
            "lifecycle_event_allowlist": runner.LIFECYCLE_EVENT_ALLOWLIST,
            "stage_capture_contract": "w2_selector_stages",
            "stage_name_allowlist": runner.SERVER_STAGE_NAME_ALLOWLIST,
            "active": False,
            "retained_sample_count": 3,
            "dropped_sample_count": 0,
            "ignored_out_of_contract_sample_count": 7,
            "observed_sample_count": 10,
            "retained_aggregate_key_count": 1,
            "stages": [{
                "stage_name": "EditFlow.Search.DTOBuild.Assembly",
                "sample_count": 3,
                "p50_ms": None,
                "p95_ms": None,
                "total_ms": 12.5,
                "max_ms": 5.0,
            }],
            "retained_lifecycle_event_count": len(lifecycle),
            "dropped_lifecycle_event_count": 0,
            "ignored_out_of_contract_lifecycle_event_count": 11,
            "observed_lifecycle_event_count": len(lifecycle) + 11,
            "lifecycle_events": lifecycle,
        }

    @staticmethod
    def server_evidence(invocation_id: str, base: float) -> tuple[list[dict[str, object]], list[dict[str, object]]]:
        lifecycle_names = [runner.LIFECYCLE_BOUNDARIES[0][1]]
        lifecycle_names.extend(boundary[2] for boundary in runner.LIFECYCLE_BOUNDARIES)
        lifecycle = [{
            "event_name": name,
            "offset_ms": base + ordinal,
            "request_identity": {
                "app_invocation_id": invocation_id,
                "connection_id": f"connection-{invocation_id}",
                "connection_generation": 1,
                "jsonrpc_request_id": f"string:rpc-{invocation_id}",
                "request_ordinal": 1,
            },
        } for ordinal, name in enumerate(lifecycle_names)]
        delivery_names = [runner.DELIVERY_BOUNDARIES[0][1]]
        delivery_names.extend(boundary[2] for boundary in runner.DELIVERY_BOUNDARIES[:2])
        delivery = [{
            "app_invocation_id": invocation_id,
            "connection_id": f"connection-{invocation_id}",
            "connection_generation": 1,
            "jsonrpc_request_id": f"string:rpc-{invocation_id}",
            "request_ordinal": 1,
            "phase": name,
            "monotonic_uptime_ms": base + 20 + ordinal,
        } for ordinal, name in enumerate(delivery_names)]
        return lifecycle, delivery

    def test_runner_uses_canonical_hidden_diagnostics_tool(self) -> None:
        self.assertEqual(runner.DEBUG_TOOL, "__repoprompt_debug_diagnostics")

    def test_runner_invocation_ids_match_foundation_uuid_casing(self) -> None:
        invocation_id = runner.new_invocation_id()
        self.assertEqual(invocation_id, invocation_id.upper())
        self.assertRegex(invocation_id, r"^[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}$")
        self.assertEqual(runner.canonical_invocation_id(invocation_id.lower()), invocation_id)
        self.assertEqual(runner.canonical_invocation_id("non-uuid-fixture-id"), "non-uuid-fixture-id")

    def test_server_and_runner_selector_stage_allowlists_match(self) -> None:
        source = (ROOT / "Sources/RepoPromptDomainRuntime/Diffing/EditFlowPerf.swift").read_text()
        start = source.index("mcpLatencyStageNameAllowlist")
        end = source.index("private static let sampleLimitRange", start)
        declared = {
            line.split('"')[1]
            for line in source[start:end].splitlines()
            if '"EditFlow.' in line
        }
        self.assertEqual(declared, set(runner.SERVER_STAGE_NAME_ALLOWLIST))
        authorities = sorted((ROOT / "Sources").rglob("EditFlowPerf.swift"))
        self.assertEqual(authorities, [ROOT / "Sources/RepoPromptDomainRuntime/Diffing/EditFlowPerf.swift"])

    def test_latency_request_claiming_uses_exact_invocation_identity_without_fallback(self) -> None:
        registry = (ROOT / "Sources/RepoPrompt/Infrastructure/MCP/MCPRequestTimelineRegistry.swift").read_text()
        self.assertIn("appInvocationID: UUID", registry)
        self.assertIn("matches.count == 1", registry)
        self.assertNotIn("originalToolName", registry)
        self.assertNotIn("pending.startIndex", registry)
        manager = (ROOT / "Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift").read_text()
        start = manager.index("let diagnosticLatencyTraceID")
        end = manager.index("EditFlowPerf.lifecycleEvent", start)
        latency_join = manager[start:end]
        self.assertIn("appInvocationID: diagnosticLatencyTraceID", latency_join)
        self.assertIn("claimed.isCompleteLatencyEvidenceIdentity", latency_join)
        self.assertNotIn("originalToolName", latency_join)

    def test_latency_trace_surfaces_are_compile_gated_out_of_ordinary_release(self) -> None:
        def stripping_gate(source: str, condition: str) -> str:
            output: list[str] = []
            gated_depth = 0
            for line in source.splitlines():
                directive = line.strip()
                if gated_depth:
                    if directive.startswith("#if"):
                        gated_depth += 1
                    elif directive == "#endif":
                        gated_depth -= 1
                    continue
                if directive == f"#if {condition}":
                    gated_depth = 1
                    continue
                output.append(line)
            self.assertEqual(gated_depth, 0)
            return "\n".join(output)

        normalizer = (ROOT / "Sources/RepoPromptDomainRuntime/MCPToolArgsNormalizer.swift").read_text()
        self.assertIn("package static func diagnosticLatencyTraceID", normalizer)
        ordinary_normalizer = stripping_gate(normalizer, "DEBUG || MCP_LATENCY_DIAGNOSTICS")
        self.assertNotIn("_latencyTraceID", ordinary_normalizer)
        bridge = (ROOT / "Sources/RepoPromptShared/MCP/JSONRPCBridgeLedger.swift").read_text()
        ordinary_bridge = stripping_gate(bridge, "DEBUG || MCP_LATENCY_DIAGNOSTICS")
        self.assertNotIn("_latencyTraceID", ordinary_bridge)

        trace_sources = [
            ROOT / "Sources/RepoPromptMCP/Exec/ExecOptions.swift",
            ROOT / "Sources/RepoPromptMCP/Exec/ExecMCPService.swift",
            ROOT / "Sources/RepoPromptMCP/main.swift",
        ]
        for path in trace_sources:
            ordinary_source = stripping_gate(path.read_text(), "DEBUG || MCP_LATENCY_TRACE")
            self.assertNotIn("latencyConcurrentBatch", ordinary_source, path.name)
            self.assertNotIn("--latency-concurrent-batch", ordinary_source, path.name)

        package = (ROOT / "Package.swift").read_text()
        self.assertIn("if mcpLatencyTraceEnabled {", package)
        self.assertIn('repoPromptMCPSwiftSettings.append(.define("MCP_LATENCY_TRACE"))', package)
        self.assertIn("if mcpLatencyDiagnosticsEnabled {", package)
        self.assertIn('repoPromptDomainRuntimeSwiftSettings.append(.define("MCP_LATENCY_DIAGNOSTICS"))', package)
        packaging = (ROOT / "Scripts/package_app.sh").read_text()
        self.assertIn("Ordinary release packaging refuses MCP latency diagnostic compile gates", packaging)

    def test_fixture_is_deterministic_and_external(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            first = fixture.generate_fixture(base / "first", fixture.FixtureSpec("test", 227, 2), repo=ROOT)
            second = fixture.generate_fixture(base / "second", fixture.FixtureSpec("test", 227, 2), repo=ROOT)
            self.assertEqual(first, second)
            self.assertEqual(first["file_count"], 227)
            self.assertEqual(first["root_file_counts"], [114, 113])
            self.assertEqual(first["maximum_relative_directory_depth"], 11)
            self.assertEqual(first["expected_search_counts"]["path_duplicate_basename"], 3)
            self.assertEqual(len(first["digest"]), 64)
            first_root = base / "first"
            manifest_path = fixture.manifest_path_for_output(first_root)
            self.assertTrue(manifest_path.is_file())
            self.assertFalse((first_root / "mcp-latency-fixture-manifest.json").exists())
            self.assertEqual(json.loads(manifest_path.read_text()), first)
            measured_files = sorted(path for path in first_root.rglob("*") if path.is_file())
            measured_entries = [
                (path.relative_to(first_root).as_posix(), path.read_bytes())
                for path in measured_files
            ]
            inventory = first["workspace_inventory"]
            self.assertEqual(len(measured_files), inventory["measured_file_count"])
            self.assertEqual(sum(path.stat().st_size for path in measured_files), inventory["measured_file_bytes"])
            self.assertEqual(fixture.manifest_digest(measured_entries), first["digest"])
            self.assertEqual(
                sorted(path.name for path in first_root.iterdir() if path.is_dir()),
                sorted(inventory["root_paths"]),
            )
            self.assertEqual(inventory["workspace_root_count"], 3)
            self.assertTrue((first_root / "empty-root").is_dir())
            self.assertFalse(any((first_root / "empty-root").iterdir()))
            matrix = json.loads(MATRIX.read_text())
            self.assertEqual(matrix["fixture_inventory"]["manifest_location"], "external_sibling")
            self.assertEqual(matrix["fixture_inventory"]["digest_scope"], inventory["digest_scope"])
            with self.assertRaises(runner.MatrixError):
                runner.new_capture_directory(first_root)

    def test_fixture_manifest_must_be_outside_measured_workspace(self) -> None:
        root = Path("/tmp/rpce-fixture")
        with self.assertRaisesRegex(runner.MatrixError, "requires --fixture-manifest"):
            runner.validate_fixture_manifest_location(root, None)
        with self.assertRaisesRegex(runner.MatrixError, "outside the measured workspace"):
            runner.validate_fixture_manifest_location(root, root / "manifest.json")
        runner.validate_fixture_manifest_location(root, root.with_name("rpce-fixture.manifest.json"))

    def test_fixture_rejects_repository_output(self) -> None:
        with self.assertRaises(fixture.FixtureError):
            fixture.ensure_external_output(ROOT / "local-fixture", repo=ROOT)

    def test_matrix_expansion_is_deterministic_and_manual_rows_are_gated(self) -> None:
        variables = runner.fixture_variables(Path("/tmp/mcp-latency-fixture"))
        ordinary = runner.load_rows(MATRIX, "small", False, variables)
        manual = runner.load_rows(MATRIX, "small", True, variables)
        self.assertGreater(len(manual), len(ordinary))
        self.assertEqual(len({row["id"] for row in manual}), len(manual))
        self.assertFalse(any("${" in json.dumps(row) for row in manual))
        self.assertNotIn("tree-full-large-preflight", {row["id"] for row in ordinary})
        small_outcomes = {row["id"]: row["expected_outcome"] for row in ordinary}
        medium_outcomes = {
            row["id"]: row["expected_outcome"]
            for row in runner.load_rows(MATRIX, "medium", False, variables)
        }
        self.assertEqual(small_outcomes["search-content-capped"], "success")
        self.assertEqual(medium_outcomes["search-content-capped"], "cap_hit_success")
        self.assertEqual(small_outcomes["search-scoped"], "success")
        authority = runner.load_wi3_authority(MATRIX)
        self.assertEqual({item["id"] for item in authority["workload_matrices"]}, runner.WI3_MATRIX_IDS)
        self.assertEqual(set(authority["parity_counter_groups"]), runner.WI3_COUNTER_GROUPS)

    def test_declared_warm_and_cold_sample_discipline_is_enforced(self) -> None:
        warm = argparse.Namespace(
            cohort="warm", warmups=None, repeats=None, samples_per_repeat=None,
            activation_id=None, cold_sample_index=None,
        )
        resolved = runner.resolve_sample_discipline(MATRIX, warm)
        self.assertEqual((resolved["warmups"], resolved["repeats"], resolved["samples_per_repeat"]), (3, 3, 30))
        warm.warmups = 2
        with self.assertRaisesRegex(runner.MatrixError, "matrix-declared discipline"):
            runner.resolve_sample_discipline(MATRIX, warm)

        cold = argparse.Namespace(
            cohort="cold", warmups=None, repeats=None, samples_per_repeat=None,
            activation_id="activation-1", cold_sample_index=1,
        )
        resolved = runner.resolve_sample_discipline(MATRIX, cold)
        self.assertEqual((resolved["warmups"], resolved["repeats"], resolved["samples_per_repeat"]), (0, 1, 1))
        cold.activation_id = None
        with self.assertRaisesRegex(runner.MatrixError, "activation-id"):
            runner.resolve_sample_discipline(MATRIX, cold)

    def test_baseline_sidecar_records_exact_keyset_bytes_and_work_counts(self) -> None:
        sample = {
            "row_id": "tree-auto", "format": "formatted", "client_mode": "fresh",
            "response_sha256": runner.sha256_bytes(b"exact\n"), "response_byte_count": 6,
        }
        with tempfile.TemporaryDirectory() as temporary:
            sidecar = Path(temporary) / "baseline.json"
            work_counts = {"counter_deltas": {"read_file_invocation_count": 1}}
            runner.apply_baseline([sample], sidecar, True, work_counts)
            runner.apply_baseline([sample], sidecar, False, work_counts)
            with self.assertRaisesRegex(runner.MatrixError, "work-count parity"):
                runner.apply_baseline([sample], sidecar, False, {"counter_deltas": {"read_file_invocation_count": 2}})
            payload = runner.load_json(sidecar)
            payload["responses"]["stale/raw/fresh"] = {"sha256": "stale", "byte_count": 1}
            runner.save_json(sidecar, payload)
            with self.assertRaisesRegex(runner.MatrixError, "missing, extra, or changed"):
                runner.apply_baseline([sample], sidecar, False)

    def test_formatted_and_raw_requests_are_distinct_and_validated(self) -> None:
        row = {"arguments": {"pattern": "needle", "_rawJSON": True}}
        formatted_args = runner.invocation_arguments(row, "formatted", 7, "formatted-id")
        raw_args = runner.invocation_arguments(row, "raw", 7, "raw-id")
        self.assertNotIn("_rawJSON", formatted_args)
        self.assertTrue(raw_args["_rawJSON"])
        self.assertNotEqual(formatted_args["_latencyTraceID"], raw_args["_latencyTraceID"])

        formatted = self.sample("formatted-id", "formatted")
        raw = self.sample("raw-id", "raw")
        runner.validate_format_pairs([formatted, raw])
        raw["response_sha256"] = formatted["response_sha256"]
        with self.assertRaisesRegex(runner.MatrixError, "digests are identical"):
            runner.validate_format_pairs([formatted, raw])

    def test_leaf_universe_and_selector_mapping_use_fully_qualified_candidates(self) -> None:
        required = {
            "EditFlow.MCPToolCall.LimiterWait",
            "EditFlow.MCPToolCall.HandlerResultHandoff",
            "EditFlow.MCPToolCall.CompletionObserverResultEncoding",
            "EditFlow.MCPToolCall.CompletionObserverCallbacks",
            "EditFlow.Search.DTOBuild.Assembly",
            "EditFlow.Search.ProviderValueEncoding",
            "EditFlow.FormattedOutput.PromptEnvelopeProbeDecode",
            "EditFlow.FormattedOutput.PromptContextDecode",
            "EditFlow.FileTree.ProviderValueEncoding",
        }
        self.assertTrue(required.issubset(runner.LEAF_STAGES))
        self.assertEqual(runner.SELECTOR_ACTIONS["EditFlow.Search.DTOBuild.Assembly"], "W4")
        self.assertEqual(runner.SELECTOR_ACTIONS["EditFlow.Search.ProviderValueEncoding"], "W5")
        self.assertNotIn("EditFlow.FileTree.DTOAssembly", runner.SELECTOR_ACTIONS)
        self.assertNotIn("EditFlow.FileTree.ProviderValueEncoding", runner.SELECTOR_ACTIONS)
        self.assertIn("EditFlow.Search.ProviderWorkspaceSearchAwait", runner.INCLUSIVE_STAGES)
        self.assertIn("EditFlow.Search.ProviderTotal", runner.INCLUSIVE_STAGES)
        self.assertIn("EditFlow.Search.WorkspaceReadinessAcquireGate", runner.INCLUSIVE_STAGES)
        self.assertIn("EditFlow.Search.RootScopeAvailabilityGate", runner.INCLUSIVE_STAGES)
        self.assertIn("EditFlow.FormattedOutput.SearchTreeAssembly", runner.INCLUSIVE_STAGES)
        self.assertNotIn("EditFlow.Search.ProviderWorkspaceSearchAwait", runner.LEAF_STAGES)
        self.assertNotIn("EditFlow.FormattedOutput.SearchTreeAssembly", runner.LEAF_STAGES)
        ancestors = set(runner.DIRECT_STAGE_CHILDREN)
        self.assertFalse(ancestors & runner.LEAF_STAGES)
        self.assertEqual(runner.SELECTOR_ACTIONS[runner.DERIVED_SEARCH_CORE_STAGE], "search-follow-up")
        self.assertEqual(runner.SELECTOR_ACTIONS[runner.DERIVED_SEARCH_READINESS_SCOPE_STAGE], "search-follow-up")
        self.assertEqual(runner.SELECTOR_ACTIONS[runner.DERIVED_SEARCH_TREE_STAGE], "W3")

    def test_server_identity_pairing_requires_distinct_stable_configurations(self) -> None:
        debug_identity = {
            "identity_authority": "server_process", "app_configuration": "debug",
            "swift_configuration": "debug", "ordinary_release_artifact": False,
            "process_identifier": 7, "bundle_path": "/Debug/RepoPrompt.app",
            "executable_path": "/Debug/RepoPrompt.app/Contents/MacOS/RepoPrompt",
            "executable_sha256": "a" * 64,
        }
        optimized_identity = {
            "identity_authority": "server_process", "app_configuration": "optimized_diagnostic",
            "swift_configuration": "release", "ordinary_release_artifact": False,
            "process_identifier": 9, "bundle_path": "/Optimized/RepoPrompt.app",
            "executable_path": "/Optimized/RepoPrompt.app/Contents/MacOS/RepoPrompt",
            "executable_sha256": "b" * 64,
        }
        debug = {
            "server_app_identity": debug_identity,
            "server_app_identity_end": dict(debug_identity),
        }
        optimized = {
            "server_app_identity": optimized_identity,
            "server_app_identity_end": dict(optimized_identity),
        }
        self.assertEqual(
            runner.authoritative_paired_server_identity(debug, optimized),
            {"debug": debug_identity, "optimized": optimized_identity},
        )
        optimized["server_app_identity_end"]["process_identifier"] = 10
        with self.assertRaisesRegex(runner.MatrixError, "changed during collection"):
            runner.authoritative_paired_server_identity(debug, optimized)

    def test_only_verified_optimized_server_selection_can_authorize(self) -> None:
        debug_identity = {
            "app_configuration": "debug", "swift_configuration": "debug",
            "ordinary_release_artifact": False,
        }
        optimized_identity = {
            "identity_authority": "server_process",
            "app_configuration": "optimized_diagnostic", "swift_configuration": "release",
            "ordinary_release_artifact": False, "diagnostic_surface": "mcp_latency_v1",
            "signing_mode": "mcp-latency-diagnostic-adhoc",
            "secure_storage_backend": "alternate-in-memory",
        }
        debug_result = runner.make_server_authorization_explicit(
            {"status": "selected", "selected": "W4"}, debug_identity,
        )
        self.assertFalse(debug_result["production_authorized"])
        optimized_result = runner.make_server_authorization_explicit(
            {"status": "selected", "selected": "W4"}, optimized_identity,
        )
        self.assertTrue(optimized_result["production_authorized"])
        self.assertEqual(optimized_result["selected"], "W4")

    def test_fresh_invalid_generation_is_discarded_and_recohorted(self) -> None:
        invalid = self.sample("failed")
        invalid["client_trace"] = []
        valid_formatted = self.sample("replacement-formatted")
        valid_raw = self.sample("replacement-raw", "raw")
        with mock.patch.object(
            runner,
            "run_fresh",
            side_effect=[[invalid], [valid_formatted, valid_raw]],
        ) as run_fresh:
            retained, discarded = runner.run_fresh_with_recovery(
                Path("/diagnostic-cli"), 1, [{"id": "row"}], Path("/capture"),
                10, "warm", "recorded",
            )
        self.assertEqual(run_fresh.call_count, 2)
        self.assertEqual([sample["invocation_id"] for sample in retained], [
            "replacement-formatted", "replacement-raw",
        ])
        self.assertEqual([sample["invocation_id"] for sample in discarded], ["failed"])
        self.assertIn("missing or duplicate client trace", discarded[0]["discard_reason"])

    def test_wi3_invalid_generation_is_discarded_and_recohorted(self) -> None:
        invalid = self.sample("wi3-failed")
        invalid["client_trace"] = []
        invalid["connection_cohort"] = "wi3-burst-g0-c0"
        valid = self.sample("wi3-replacement")
        valid["connection_cohort"] = "wi3-burst-g1-c0"
        authority = {"workload_matrices": [{
            "id": "burst",
            "execution": {
                "enabled_by_default": True, "mode": "same_connection_burst",
                "row_id": "tree-roots", "request_count": 1,
            },
        }]}
        with mock.patch.object(runner, "matrix_row_by_id", return_value={"id": "tree-roots"}), \
                mock.patch.object(runner, "run_concurrent_batch_process", side_effect=[[invalid], [valid]]) as batch:
            retained, executed, discarded = runner.run_wi3_cohorts(
                Path("/diagnostic-cli"), 1, MATRIX, authority, {}, Path("/capture"), 10,
            )
        self.assertEqual(batch.call_count, 2)
        self.assertEqual([sample["invocation_id"] for sample in retained], ["wi3-replacement"])
        self.assertEqual(executed, ["burst"])
        self.assertEqual([sample["invocation_id"] for sample in discarded], ["wi3-failed"])

    def test_terminal_event_invalidates_and_recovery_uses_a_new_cohort(self) -> None:
        samples = [
            {"sample_id": "timeout", "connection_cohort": "persistent-0", "outcome": "timeout",
             "expected_outcome": "expected_timeout", "client_trace": [{"outcome": "timeout"}]},
            {"sample_id": "later", "connection_cohort": "persistent-0", "outcome": "success",
             "expected_outcome": "success", "client_trace": [{"outcome": "success"}]},
        ]
        invalid = runner.invalid_connection_cohorts(samples)
        self.assertIn("persistent-0", invalid)
        self.assertIn("after terminal", invalid["persistent-0"])
        with self.assertRaisesRegex(runner.MatrixError, "unexpected terminal"):
            runner.validate_connection_cohorts([{
                "sample_id": "bad", "connection_cohort": "fresh", "outcome": "transport_closed",
                "expected_outcome": "success", "client_trace": [{"outcome": "transport_closed"}],
            }])

    def test_request_identity_joins_out_of_order_lifecycle_and_delivery_events(self) -> None:
        first = self.sample("request-a")
        second = self.sample("request-b")
        first_lifecycle, first_delivery = self.server_evidence("request-a", 100)
        second_lifecycle, second_delivery = self.server_evidence("request-b", 500)
        for event in first_delivery:
            event["app_invocation_id"] = "pre-decode-deterministic-request-a"
        capture = {
            "capture_start_uptime_ms": 0,
            "lifecycle_events": second_lifecycle + first_lifecycle,
            "stages": [
                {"stage_name": "EditFlow.Search.DTOBuild.Assembly", "total_ms": 3, "sample_count": 1,
                 "request_identity": {"app_invocation_id": "request-b"}},
                {"stage_name": "EditFlow.Search.DTOBuild.Assembly", "total_ms": 7, "sample_count": 1,
                 "request_identity": {"app_invocation_id": "request-a"}},
            ],
        }
        evidence = runner.joined_request_evidence(
            [first, second], capture, second_delivery + first_delivery, require_server=True,
        )
        by_id = {item["sample"]["invocation_id"]: item for item in evidence}
        self.assertEqual(by_id["request-a"]["stage_buckets"][0]["total_ms"], 7)
        self.assertEqual(by_id["request-b"]["stage_buckets"][0]["total_ms"], 3)
        self.assertEqual(by_id["request-a"]["boundaries"]["handler_to_write_ms"], 2)
        self.assertEqual(by_id["request-a"]["boundaries"]["s0_s9_server_total_ms"], 22)
        _, _, boundaries = runner.stage_and_boundary_summaries(evidence)
        self.assertEqual({row["stage"] for row in boundaries}, {
            "Boundary.S0S1.PermitWait", "Boundary.S1S2.PreProvider",
            "Boundary.S2S3.Provider", "Boundary.S3S4.PreFormat", "Boundary.S4S5.Format",
            "Boundary.S5S6.CompletionObservers", "Boundary.S6S7.HandlerHandoff",
            "Boundary.S7S8.SDKEncode", "Boundary.S8S9.TransportWrite",
            "Boundary.S7S9.HandlerToWrite", "Boundary.S0S9.ServerTotal", "Boundary.C0C1.ClientCall",
            "Boundary.C1C2.ClientOutput", "Boundary.C0C2.ClientTotal",
        })

    def test_stage_attribution_rejects_detached_and_missing_request_evidence(self) -> None:
        sample = self.sample("request-a")
        unidentified = {
            "stages": [{
                "stage_name": "EditFlow.Search.ProviderValueEncoding",
                "total_ms": 4, "sample_count": 1, "request_identity": None,
            }],
        }
        with self.assertRaisesRegex(runner.MatrixError, "lack request identity"):
            runner.stage_attribution_report([sample], unidentified, require_server=True)

        unrelated = {
            "stages": [{
                "stage_name": "EditFlow.Search.ProviderValueEncoding",
                "total_ms": 4, "sample_count": 1,
                "request_identity": {"app_invocation_id": "discarded-warmup"},
            }],
        }
        with self.assertRaisesRegex(runner.MatrixError, "lack leaf/inclusive stage samples"):
            runner.stage_attribution_report([sample], unrelated, require_server=True)

        attributed = {
            "stages": [{
                "stage_name": "EditFlow.Search.ProviderValueEncoding",
                "total_ms": 4, "sample_count": 2,
                "request_identity": {"app_invocation_id": "request-a"},
            }],
        }
        report = runner.stage_attribution_report([sample], attributed, require_server=True)
        self.assertEqual(report["status"], "complete")
        self.assertEqual(report["identified_sample_count"], 2)
        self.assertEqual(report["unidentified_sample_count"], 0)

    def test_correlated_server_terminal_invalidates_retained_evidence(self) -> None:
        sample = self.sample("request-a")
        lifecycle, _ = self.server_evidence("request-a", 100)
        terminal = [{
            "phase": "connection_terminal", "terminal_reason": "write_failed",
            "connection_id": "connection-request-a", "connection_generation": 1,
        }]
        with self.assertRaisesRegex(runner.MatrixError, "terminalized a retained connection"):
            runner.validate_delivery_terminals(terminal, lifecycle, [sample])
        sample["expected_outcome"] = "expected_timeout"
        runner.validate_delivery_terminals(terminal, lifecycle, [sample])

    def test_repeated_span_buckets_aggregate_per_request_and_remove_nested_snippets(self) -> None:
        item = {"stage_buckets": [
            {"stage_name": "EditFlow.Search.ProviderValueEncoding", "total_ms": 7, "sample_count": 1},
            {"stage_name": "EditFlow.Search.ProviderValueEncoding", "total_ms": 4, "sample_count": 2},
            {"stage_name": "EditFlow.FormattedOutput.SearchTreeAssembly", "total_ms": 12, "sample_count": 1},
            {"stage_name": "EditFlow.FormattedOutput.SearchTreeAssembly", "total_ms": 3, "sample_count": 1},
            {"stage_name": "EditFlow.FormattedOutput.SearchSnippetAssembly", "total_ms": 5, "sample_count": 2},
        ]}
        totals, spans, _ = runner.per_request_stage_totals(item)
        self.assertEqual(totals["EditFlow.Search.ProviderValueEncoding"], 11)
        self.assertEqual(spans["EditFlow.Search.ProviderValueEncoding"], 3)
        self.assertEqual(totals["EditFlow.FormattedOutput.SearchTreeAssembly"], 15)
        self.assertEqual(totals["EditFlow.FormattedOutput.SearchSnippetAssembly"], 5)

        item["sample"] = self.sample("remainder")
        item["boundaries"] = {}
        item["stage_buckets"].append({
            "stage_name": "EditFlow.MCPToolCall.FormatResult", "total_ms": 20, "sample_count": 1,
        })
        remainder = runner.remainder_summaries([item])
        formatted = next(row for row in remainder if row["envelope"] == "EditFlow.MCPToolCall.FormatResult")
        self.assertEqual(formatted["p50_ms"], 5)
        leaves, parents, _ = runner.stage_and_boundary_summaries([item])
        tree_exclusive = next(row for row in leaves if row["stage"] == runner.DERIVED_SEARCH_TREE_STAGE)
        self.assertEqual(tree_exclusive["p50_ms"], 10)
        self.assertTrue(any(
            row["stage"] == "EditFlow.FormattedOutput.SearchTreeAssembly" for row in parents
        ))

    def test_search_core_scan_remainder_subtracts_only_declared_gates(self) -> None:
        item = {"sample": self.sample("search-core"), "boundaries": {}, "stage_buckets": [
            {"stage_name": "EditFlow.Search.ProviderWorkspaceSearchAwait", "total_ms": 100, "sample_count": 1},
            {"stage_name": "EditFlow.Search.BroadAdmissionWait", "total_ms": 10, "sample_count": 1},
            {"stage_name": "EditFlow.Search.IngressFreshnessWait", "total_ms": 5, "sample_count": 1},
            {"stage_name": "EditFlow.Search.WorkspaceReadinessAcquireGate", "total_ms": 15, "sample_count": 1},
            {"stage_name": "EditFlow.Search.WorkspaceReadinessValidationGate", "total_ms": 8, "sample_count": 2},
            {"stage_name": "EditFlow.Search.RootScopeAvailabilityGate", "total_ms": 12, "sample_count": 1},
        ]}
        remainder = runner.remainder_summaries([item])
        core = next(row for row in remainder if row.get("stage") == runner.DERIVED_SEARCH_CORE_STAGE)
        self.assertEqual(core["envelope"], "EditFlow.Search.ProviderWorkspaceSearchAwait")
        self.assertEqual(core["p50_ms"], 58)
        leaves, parents, _ = runner.stage_and_boundary_summaries([item])
        readiness_scope = next(
            row for row in leaves if row["stage"] == runner.DERIVED_SEARCH_READINESS_SCOPE_STAGE
        )
        self.assertEqual(readiness_scope["p50_ms"], 19)
        self.assertTrue(any(
            row["stage"] == "EditFlow.Search.WorkspaceReadinessAcquireGate" for row in parents
        ))

    def test_signed_residual_preserves_tolerated_negative_rounding_noise(self) -> None:
        self.assertAlmostEqual(
            runner.signed_parent_minus_children_residual(
                10.0,
                10.005,
                envelope="test-envelope",
                request_id="request-rounding",
            ),
            -0.005,
        )
        self.assertEqual(
            runner.signed_parent_minus_children_residual(
                10.0,
                4.0,
                envelope="test-envelope",
                request_id="request-positive",
            ),
            6.0,
        )

    def test_derived_residual_rejects_material_parent_child_overlap(self) -> None:
        item = {
            "sample": self.sample("tree-overlap"),
            "boundaries": {},
            "stage_buckets": [
                {
                    "stage_name": "EditFlow.FormattedOutput.SearchTreeAssembly",
                    "total_ms": 10.0,
                    "sample_count": 1,
                },
                {
                    "stage_name": "EditFlow.FormattedOutput.SearchSnippetAssembly",
                    "total_ms": 10.02,
                    "sample_count": 1,
                },
            ],
        }
        with self.assertRaisesRegex(runner.MatrixError, "invalid EditFlow.FormattedOutput.SearchTreeAssembly residual"):
            runner.stage_and_boundary_summaries([item])

    def test_envelope_remainder_rejects_material_negative_residual(self) -> None:
        item = {
            "sample": self.sample("provider-overlap"),
            "boundaries": {},
            "stage_buckets": [
                {
                    "stage_name": "EditFlow.FileTree.ProviderTotal",
                    "total_ms": 1.0,
                    "sample_count": 1,
                },
                {
                    "stage_name": "EditFlow.FileTree.ProviderArgumentParsing",
                    "total_ms": 1.02,
                    "sample_count": 1,
                },
            ],
        }
        with self.assertRaisesRegex(runner.MatrixError, "invalid EditFlow.FileTree.ProviderTotal residual"):
            runner.remainder_summaries([item])

    def test_selector_requires_s0_s9_and_optimized_persistent_denominators(self) -> None:
        cohort = {"row_id": "search-content-few", "format": "formatted", "client_mode": "fresh", "cohort_kind": "warm"}
        leaf = {"cohort": cohort, "stage": "EditFlow.Search.DTOBuild.Assembly", "p50_ms": 30, "p95_ms": 30}
        handler = {
            "cohort": cohort, "interval_name": "Boundary.S0S9.ServerTotal",
            "p50_ms": 40, "p95_ms": 40, "sample_count": 30,
        }
        optimized = {
            "cohort": {**cohort, "client_mode": "persistent"},
            "total_ms": {"p50_ms": 100, "p95_ms": 110, "sample_count": 30},
        }
        selection = runner.mechanical_selector([leaf], [], [handler], [optimized])
        self.assertEqual(selection["status"], "selected")
        self.assertEqual(selection["selected"], "W4")
        self.assertEqual(selection["dominant_leaf"]["eligibility_denominator_interval"], "Boundary.S0S9.ServerTotal")
        refused = runner.mechanical_selector([leaf], [], [handler], [])
        self.assertEqual(refused["status"], "refused")
        self.assertIn("optimized warm persistent", refused["refusal_reasons"][0])

    def test_response_signature_includes_wi3_and_ordered_block_contract(self) -> None:
        ordinary = self.sample("ordinary")
        wi3 = self.sample("wi3")
        wi3.update({
            "cohort_kind": "wi3", "connection_cohort": "wi3-same-connection-ordinary-burst-c0",
            "client_mode": "persistent_concurrent", "workload_matrix_id": "same-connection-ordinary-burst",
            "sample_ordinal": 2,
        })
        signature = runner.response_signature([ordinary, wi3])
        self.assertTrue(any(key.startswith("ordinary/") for key in signature))
        self.assertTrue(any(key.startswith("wi3/same-connection-ordinary-burst/") for key in signature))

        drift = self.sample("ordinary-drift")
        drift["client_trace"][0]["content_block_count"] = 2
        with self.assertRaisesRegex(runner.MatrixError, "content-block contract changed"):
            runner.response_signature([ordinary, drift])

    def test_wi3_projection_stamps_only_executed_authoritative_cohorts(self) -> None:
        def runtime(catalog_count: int, reads: list[dict[str, object]]) -> dict[str, object]:
            return {"runtime": {
                "limiter": {"lanes": {"ordinary": {"limit": 1}, "file_search": {"limit": 4}}},
                "windows": [{
                    "store_work": {"catalog_rebuild": {"count": catalog_count}, "root_catalog_shards": {}, "invalidations": []},
                    "search_rebuild": {}, "ui_index_rebuild": {}, "roots": [],
                }],
                "physical_root_duplication": [],
                "tool_work": {"read_file_invocations": reads, "git_invocations": []},
            }}

        admission = {"admission": {"lanes": [{"configuration": {"active_capacity": 4}}]}}
        authority = runner.load_wi3_authority(MATRIX)
        executed = ["same-connection-ordinary-burst", "distinct-connections-one-window"]
        self.assertEqual(runner.selector_required_wi3_matrix_ids(authority), sorted(executed))
        evidence = runner.project_wi3_work_counts(
            runtime(2, []),
            runtime(5, [{"read_bytes": 19, "returned_bytes": 7, "returned_lines": 1, "cache_hit": False}]),
            admission,
            admission,
            authority,
            executed,
        )
        self.assertTrue(evidence["lane_capacity_evidence"]["matches_authority"])
        self.assertEqual(evidence["counter_deltas"]["catalog_rebuild_count"], 3)
        self.assertEqual(evidence["counter_deltas"]["read_file_full_bytes"], 19)
        self.assertEqual(evidence["counter_deltas"]["read_file_returned_bytes"], 7)
        self.assertEqual(evidence["parity_signature"]["workload_matrix_ids"], sorted(executed))
        self.assertEqual({item["id"] for item in evidence["workload_matrices"]}, set(executed))

    def test_evidence_capture_contract_accepts_exact_online_totals_and_ignored_events(self) -> None:
        capture = self.capture_payload()
        runner.validate_capture_integrity(capture)
        begin = dict(capture)
        begin["active"] = True
        runner.validate_capture_begin(begin)

    def test_evidence_capture_contract_rejects_drops_and_accounting_drift(self) -> None:
        mutations = {
            "drops": lambda capture: capture.update(dropped_sample_count=1, observed_sample_count=11),
            "aggregate_count": lambda capture: capture.update(retained_aggregate_key_count=2),
            "observed_samples": lambda capture: capture.update(observed_sample_count=11),
            "percentiles": lambda capture: capture["stages"][0].update(p50_ms=4.0),
            "lifecycle_event": lambda capture: capture["lifecycle_events"].append({"event_name": "MCP.ToolCall.PermitReleased"}),
            "stage": lambda capture: capture["stages"][0].update(stage_name="EditFlow.Search.LiteralScan"),
            "capture_mode": lambda capture: capture.update(capture_mode="exhaustive"),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label):
                capture = self.capture_payload()
                mutate(capture)
                with self.assertRaises(runner.MatrixError):
                    runner.validate_capture_integrity(capture)

    def test_segment_plan_is_deterministic_bounded_and_includes_wi3(self) -> None:
        rows = [
            {"id": "row-a", "formats": ["formatted", "raw"], "expected_outcome": "success"},
            {"id": "row-terminal", "formats": ["formatted"], "expected_outcome": "expected_timeout"},
        ]
        discipline = {"warmups": 3, "repeats": 3, "samples_per_repeat": 30}
        authority = {"workload_matrices": [
            {"id": "burst", "execution": {
                "enabled_by_default": True, "mode": "same_connection_burst",
                "row_id": "row-a", "request_count": 7,
            }},
            {"id": "connections", "execution": {
                "enabled_by_default": True, "mode": "distinct_connections",
                "row_id": "row-a", "connection_count": 4,
            }},
        ]}
        first = runner.capture_segment_plan(
            rows, ["fresh", "persistent"], discipline, authority, True,
        )
        second = runner.capture_segment_plan(
            rows, ["fresh", "persistent"], discipline, authority, True,
        )
        self.assertEqual(first, second)
        self.assertEqual(runner.capture_segment_plan_sha256(first), runner.capture_segment_plan_sha256(second))
        self.assertEqual([item["ordinal"] for item in first], list(range(6)))
        self.assertEqual(first[0]["expected_invocation_count"], 186)
        self.assertEqual(first[2]["kind"], "expected_terminal")
        self.assertEqual(first[-2]["expected_invocation_count"], 7)
        self.assertEqual(first[-1]["expected_invocation_count"], 4)

        oversized = [{
            "id": "oversized", "formats": ["formatted", "raw"],
            "expected_outcome": "success",
        }]
        with self.assertRaisesRegex(runner.MatrixError, "exceeding the segmented capture bound"):
            runner.capture_segment_plan(
                oversized, ["fresh"],
                {"warmups": 1, "repeats": 1, "samples_per_repeat": 128},
                {"workload_matrices": []}, False,
            )

    def test_segment_index_fails_closed_on_missing_reordered_or_wrong_plan(self) -> None:
        plan = [
            {"ordinal": 0, "segment_id": "000-a"},
            {"ordinal": 1, "segment_id": "001-b"},
        ]
        index = {
            "layout": runner.SEGMENTED_CAPTURE_LAYOUT,
            "capture_mode": runner.SERVER_CAPTURE_MODE,
            "segment_plan_sha256": runner.capture_segment_plan_sha256(plan),
            "segments": [
                {"ordinal": 0, "segment_id": "000-a"},
                {"ordinal": 1, "segment_id": "001-b"},
            ],
        }
        runner.validate_segment_index_contract(index, plan)
        for label, mutate in {
            "missing": lambda value: value["segments"].pop(),
            "reordered": lambda value: value["segments"].reverse(),
            "wrong_hash": lambda value: value.update(segment_plan_sha256="0" * 64),
            "entry_drift": lambda value: value["segments"][0].update(ordinal=9),
        }.items():
            with self.subTest(label=label):
                changed = json.loads(json.dumps(index))
                mutate(changed)
                with self.assertRaises(runner.MatrixError):
                    runner.validate_segment_index_contract(changed, plan)

    def test_capture_drop_cannot_be_hidden_by_invalid_cohort_retry(self) -> None:
        sample = self.sample("request-drop")
        sample["client_trace"] = []
        payload = self.capture_payload()
        payload["dropped_sample_count"] = 1
        payload["retained_sample_count"] = 2
        begin = self.capture_payload()
        begin["active"] = True
        spec = {
            "segment_id": "000-drop", "expected_invocation_count": 1,
            "expected_sample_coordinates": [list(runner.sample_coordinate(sample))],
        }
        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch.object(runner, "call_debug_tool", side_effect=[{"capture": begin}, {"capture": payload}]) as call, \
                mock.patch.object(runner, "save_json") as save:
            with self.assertRaisesRegex(runner.MatrixError, "dropped_sample_count"):
                runner.collect_capture_segment(
                    Path("/diagnostic-cli"), 1, Path(temporary), spec, "debug", 100, 10,
                    lambda _: ([sample], []),
                )
        self.assertEqual(call.call_count, 2)
        save.assert_not_called()

    def test_expected_timeout_requires_one_correlated_server_terminal(self) -> None:
        sample = self.sample("request-timeout")
        sample.update(expected_outcome="expected_timeout", outcome="timeout")
        with self.assertRaisesRegex(runner.MatrixError, "omitted authoritative server correlation"):
            runner.validate_delivery_terminals([], [], [sample])

        lifecycle, _ = self.server_evidence("request-timeout", 10)
        connection = "connection-request-timeout"
        terminal = {
            "connection_id": connection, "connection_generation": 1,
            "phase": "connection_terminal", "terminal_reason": "timeout",
        }
        runner.validate_delivery_terminals([terminal], lifecycle, [sample])
        with self.assertRaisesRegex(runner.MatrixError, "exactly one authoritative terminal"):
            runner.validate_delivery_terminals([terminal, dict(terminal)], lifecycle, [sample])

    def test_capture_membership_rejects_foreign_stage_or_lifecycle_but_ignores_handshake_delivery(self) -> None:
        lifecycle, delivery = self.server_evidence("expected-request", 10)
        delivery[0]["app_invocation_id"] = "predecode-deterministic-request"
        correlated = {
            "capture": {"stages": [], "lifecycle_events": lifecycle},
            "delivery_events": [
                {"app_invocation_id": "unrelated-handshake-request"}, delivery[0],
            ],
        }
        runner.validate_capture_request_membership(
            correlated, [self.sample("expected-request")],
        )
        lifecycle[0]["request_identity"]["app_invocation_id"] = "foreign-lifecycle-request"
        with self.assertRaisesRegex(runner.MatrixError, "foreign lifecycle/stage"):
            runner.validate_capture_request_membership(
                correlated, [self.sample("expected-request")],
            )

        setup_identity = {"app_invocation_id": "persistent-bind-setup"}
        setup = {
            "capture": {
                "lifecycle_events": [
                    {
                        "event_name": name, "request_identity": setup_identity,
                        "sanitized_dimensions": "tool=bind_context",
                    }
                    for name in runner.LIFECYCLE_EVENT_ALLOWLIST
                ],
                "stages": [{
                    "stage_name": "EditFlow.MCPToolCall.LimiterWait",
                    "request_identity": setup_identity,
                    "sanitized_dimensions": "tool=bind_context",
                }],
            },
            "delivery_events": [],
        }
        persistent = self.sample("expected-persistent", client_mode="persistent")
        self.assertEqual(
            runner.validate_capture_request_membership(setup, [persistent]),
            ["persistent-bind-setup"],
        )


if __name__ == "__main__":
    unittest.main()
