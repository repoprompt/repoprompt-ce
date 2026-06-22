#!/usr/bin/env python3
"""Deterministic negative tests for Core-isolation structural guards."""

from __future__ import annotations

import copy
import json
import tempfile
import unittest
from pathlib import Path

from core_isolation_guardrails import (
    CORE_DECLARATIONS,
    EXPECTED_DEPENDENCIES,
    RESERVED_TEST_PATHS,
    TARGET_PATHS,
    validate_package,
    validate_sources,
)


def dependency(value: tuple[str, str, str]) -> dict[str, list[str | None]]:
    kind, name, package = value
    if kind == "target":
        return {"byName": [name, None]}
    return {"product": [name, package, None, None]}


def valid_package() -> dict[str, object]:
    targets = [
        {
            "name": name,
            "path": TARGET_PATHS[name],
            "type": "executable" if name == "RepoPromptHeadless" else "regular",
            "dependencies": [dependency(item) for item in sorted(expected)],
        }
        for name, expected in EXPECTED_DEPENDENCIES.items()
    ]
    targets.append(
        {
            "name": "RepoPromptHeadlessTests",
            "path": RESERVED_TEST_PATHS["RepoPromptHeadlessTests"],
            "type": "test",
            "dependencies": [dependency(("target", "RepoPromptHeadless", ""))],
        }
    )
    targets.extend(
        [
            {
                "name": "RepoPrompt",
                "path": "Sources/RepoPrompt",
                "type": "executable",
                "dependencies": [
                    dependency(("target", "RepoPromptShared", "")),
                    dependency(("target", "RepoPromptCore", "")),
                    dependency(("target", "RepoPromptCoreMacOS", "")),
                    dependency(("target", "Sparkle", "")),
                ],
            },
            {
                "name": "RepoPromptMCP",
                "path": "Sources/RepoPromptMCP",
                "type": "executable",
                "dependencies": [
                    dependency(("target", "RepoPromptShared", "")),
                    dependency(("target", "RepoPromptPOSIXSupport", "")),
                ],
            },
            {
                "name": "RepoPromptShared",
                "path": "Sources/RepoPromptShared",
                "type": "regular",
                "dependencies": [],
            },
            {
                "name": "RepoPromptC",
                "path": "Sources/RepoPromptC",
                "type": "regular",
                "dependencies": [],
            },
            {
                "name": "CSwiftPCRE2",
                "path": "Sources/CSwiftPCRE2",
                "type": "regular",
                "dependencies": [],
            },
            {
                "name": "TreeSitterScannerSupport",
                "path": "Sources/TreeSitterScannerSupport",
                "type": "regular",
                "dependencies": [],
            },
            {
                "name": "Sparkle",
                "path": "Vendor/Sparkle",
                "type": "binary",
                "dependencies": [],
            },
        ]
    )
    return {
        "products": [
            {"name": "RepoPrompt", "targets": ["RepoPrompt"]},
            {"name": "repoprompt-mcp", "targets": ["RepoPromptMCP"]},
            {"name": "repoprompt-headless", "targets": ["RepoPromptHeadless"]},
        ],
        "targets": targets,
    }


class CoreIsolationGuardrailTests(unittest.TestCase):
    def test_valid_frozen_graph_passes(self) -> None:
        self.assertEqual(validate_package(valid_package()), [])

    def test_reverse_dependency_is_rejected(self) -> None:
        package = copy.deepcopy(valid_package())
        core = next(target for target in package["targets"] if target["name"] == "RepoPromptCore")
        core["dependencies"].append(dependency(("target", "RepoPrompt", "")))
        errors = validate_package(package)
        self.assertTrue(any("RepoPromptCore direct dependencies drifted" in error for error in errors))
        self.assertTrue(any("dependency cycle" in error for error in errors))

    def test_acyclic_forbidden_app_and_mcp_edges_are_rejected(self) -> None:
        package = copy.deepcopy(valid_package())
        app = next(target for target in package["targets"] if target["name"] == "RepoPrompt")
        app["dependencies"].append(dependency(("target", "RepoPromptHeadless", "")))
        mcp = next(target for target in package["targets"] if target["name"] == "RepoPromptMCP")
        mcp["dependencies"].append(dependency(("target", "RepoPromptCore", "")))
        errors = validate_package(package)
        self.assertTrue(any("RepoPrompt local dependencies drifted" in error for error in errors))
        self.assertTrue(any("RepoPromptMCP local dependencies drifted" in error for error in errors))

    def test_forbidden_core_import_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            (root / TARGET_PATHS["RepoPromptCore"] / "Forbidden.swift").write_text("import SwiftUI\n")
            errors = validate_sources(root)
            self.assertTrue(any("imports forbidden module SwiftUI" in error for error in errors))

    def test_direct_app_implementation_imports_are_rejected(self) -> None:
        for module in ("RepoPromptC", "RepoPromptPOSIXSupport", "RepoPromptSyntaxCBridge"):
            with self.subTest(module=module), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self._write_minimal_sources(root)
                leaked = root / "Sources/RepoPrompt/DirectImplementationLeak.swift"
                leaked.write_text(f"import {module}\n")
                errors = validate_sources(root)
                self.assertTrue(any(module in error and "forbidden direct app imports" in error for error in errors))

    def test_attributed_forbidden_core_import_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            (root / TARGET_PATHS["RepoPromptCore"] / "Forbidden.swift").write_text(
                "@_implementationOnly import AppKit\n"
            )
            errors = validate_sources(root)
            self.assertTrue(any("imports forbidden module AppKit" in error for error in errors))

    def test_unprefixed_c_symbol_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            (root / TARGET_PATHS["RepoPromptPOSIXSupport"] / "unsafe.h").write_text(
                "int unsafe_helper(void);\n"
            )
            errors = validate_sources(root)
            self.assertTrue(any("declares unprefixed CE C symbol unsafe_helper" in error for error in errors))

    def test_headless_app_packaging_overlap_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            script = root / "Scripts/package_app.sh"
            script.parent.mkdir(parents=True)
            script.write_text("cp repoprompt-headless RepoPrompt.app/Contents/MacOS/\n")
            errors = validate_sources(root)
            self.assertTrue(any("package_app.sh must remain app/proxy-only" in error for error in errors))

    def test_declared_test_target_requires_a_meaningful_test_root(self) -> None:
        package = copy.deepcopy(valid_package())
        package["targets"].append(
            {
                "name": "RepoPromptCoreTests",
                "path": RESERVED_TEST_PATHS["RepoPromptCoreTests"],
                "type": "test",
                "dependencies": [dependency(("target", "RepoPromptCore", ""))],
            }
        )
        self.assertEqual(validate_package(package), [])

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            reserved = root / RESERVED_TEST_PATHS["RepoPromptCoreTests"]
            reserved.mkdir(parents=True)
            (reserved / "PlaceholderTests.swift").write_text("// placeholder\n")
            self.assertTrue(any("must contain a meaningful XCTestCase" in error for error in validate_sources(root)))

    def test_phase_two_declaration_duplicate_in_any_production_root_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            duplicate = root / TARGET_PATHS["RepoPromptCoreMacOS"] / "Duplicate.swift"
            duplicate.write_text("struct WorkspaceModel {}\n")
            errors = validate_sources(root)
            self.assertTrue(any("WorkspaceModel must have exactly one" in error for error in errors))

    def test_phase_five_backend_selection_outside_container_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            container = root / "Sources/RepoPrompt/App/CoreAdapters/RepoPromptAppCoreContainer.swift"
            container.parent.mkdir(parents=True)
            container.write_text("// container\n")
            leaked = root / "Sources/RepoPrompt/LeakedBackend.swift"
            leaked.write_text('let key = "coreIsolation.workspaceBackend"\n')
            errors = validate_sources(root)
            self.assertTrue(any("must not select the Phase 5 workspace backend" in error for error in errors))

    def test_phase_five_observation_bridge_command_feedback_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            bridge = root / "Sources/RepoPrompt/App/CoreAdapters/WorkspaceSessionObservationBridge.swift"
            bridge.parent.mkdir(parents=True)
            bridge.write_text("func bad() { ingress.execute(command) }\n")
            errors = validate_sources(root)
            self.assertTrue(any("observation-only" in error for error in errors))

    def test_phase_five_headless_session_authority_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            leaked = root / TARGET_PATHS["RepoPromptHeadless"] / "SessionLeak.swift"
            leaked.write_text("let host = RepoPromptCoreHost()\n")
            errors = validate_sources(root)
            self.assertTrue(any("must not instantiate Phase 5 app session authority" in error for error in errors))

    def test_phase_five_manager_optimistic_projection_feedback_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            manager = root / "Sources/RepoPrompt/Features/Workspaces/ViewModels/WorkspaceManagerViewModel.swift"
            manager.parent.mkdir(parents=True)
            manager.write_text("func reconcileWorkspaceProjectionMutation() {}\n")
            self.assertTrue(any("receipt-first" in error for error in validate_sources(root)))

    def test_phase_six_core_git_authority_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            leaked = root / TARGET_PATHS["RepoPromptCore"] / "WorkspaceContext/Prompt/Leak.swift"
            leaked.parent.mkdir(parents=True, exist_ok=True)
            leaked.write_text("let service: VCSService\n")
            self.assertTrue(any("must not discover or carry Git authority" in error for error in validate_sources(root)))

    def test_phase_six_factual_result_path_property_fixtures(self) -> None:
        fixture_path = Path(__file__).parent / "Fixtures/core-isolation-guardrails/prompt_factual_path_properties.json"
        fixture = json.loads(fixture_path.read_text(encoding="utf-8"))

        for declaration in fixture["declarations"]:
            for token in fixture["forbidden_property_tokens"]:
                with self.subTest(declaration=declaration, token=token):
                    with tempfile.TemporaryDirectory() as temporary:
                        root = Path(temporary)
                        self._write_minimal_sources(root)
                        models = root / "Sources/RepoPromptCore/WorkspaceContext/Prompt/PromptFactualContextModels.swift"
                        models.parent.mkdir(parents=True, exist_ok=True)
                        models.write_text(
                            f"package struct {declaration} {{\n"
                            f"    package let leaked{token}Value: String\n"
                            "}\n",
                            encoding="utf-8",
                        )
                        errors = validate_sources(root)
                        self.assertIn(
                            f"{declaration} must not expose physical path properties",
                            errors,
                        )

    def test_phase_six_factual_result_logical_display_fixture_passes(self) -> None:
        fixture_path = Path(__file__).parent / "Fixtures/core-isolation-guardrails/prompt_factual_path_properties.json"
        fixture = json.loads(fixture_path.read_text(encoding="utf-8"))

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            models = root / "Sources/RepoPromptCore/WorkspaceContext/Prompt/PromptFactualContextModels.swift"
            models.parent.mkdir(parents=True, exist_ok=True)
            models.write_text(
                "\n".join(
                    f"package struct {declaration} {{\n"
                    + "\n".join(
                        f"    package let {property_name}: String"
                        for property_name in fixture["safe_property_names"]
                    )
                    + "\n}"
                    for declaration in fixture["declarations"]
                )
                + "\n",
                encoding="utf-8",
            )
            errors = validate_sources(root)
            self.assertFalse(any("must not expose physical path properties" in error for error in errors))

    def test_phase_six_headless_factual_provider_construction_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            leaked = root / TARGET_PATHS["RepoPromptHeadless"] / "PromptProviderLeak.swift"
            leaked.write_text("let provider = CorePromptFactualContextProvider(handle: handle)\n")
            self.assertTrue(any("must not instantiate Phase 5 app session authority" in error for error in validate_sources(root)))

    def test_phase_six_direct_common_factual_caller_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            leaked = root / "Sources/RepoPrompt/Features/AgentMode/Services/AgentProviderContextBuilder.swift"
            leaked.parent.mkdir(parents=True, exist_ok=True)
            leaked.write_text("let accounting = PromptContextAccountingService()\n")
            errors = validate_sources(root)
            self.assertTrue(any("retains a direct common factual path" in error for error in errors))

    def test_phase_five_raw_store_runtime_exposure_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            container = root / "Sources/RepoPrompt/App/CoreAdapters/RepoPromptAppCoreContainer.swift"
            container.parent.mkdir(parents=True)
            container.write_text("struct Bundle { let workspaceFileContextStore: WorkspaceFileContextStore }\n")
            self.assertTrue(any("raw WorkspaceFileContextStore" in error for error in validate_sources(root)))

    def test_phase_five_selection_direct_fallback_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            coordinator = root / "Sources/RepoPrompt/Infrastructure/WorkspaceContext/Selection/WorkspaceSelectionCoordinator.swift"
            coordinator.parent.mkdir(parents=True)
            coordinator.write_text("func bad() { updateComposeTabStoredOnly(tab) }\n")
            self.assertTrue(any("direct canonical tab-write fallback" in error for error in validate_sources(root)))

    def test_phase_five_legacy_unsupported_common_command_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            backend = root / "Sources/RepoPrompt/App/CoreAdapters/LegacyWorkspaceSessionBackend.swift"
            backend.parent.mkdir(parents=True)
            backend.write_text('let error = "legacy rollback command is not supported"\n')
            self.assertTrue(any("complete rollback parity" in error for error in validate_sources(root)))

    def test_phase_five_missing_exact_mcp_binding_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            binding = root / "Sources/RepoPrompt/Infrastructure/MCP/MCPBindingResolver.swift"
            connection = root / "Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift"
            binding.parent.mkdir(parents=True)
            binding.write_text("struct Resolver {}\n")
            connection.write_text("struct Manager {}\n")
            errors = validate_sources(root)
            self.assertTrue(any("coherent admitted context binding" in error for error in errors))
            self.assertTrue(any("propagate the exact admitted" in error for error in errors))

    def test_phase_seven_core_window_identity_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            contracts = root / "Sources/RepoPromptCore/Workspaces/Runtime/WorkspaceRuntimeContracts.swift"
            contracts.parent.mkdir(parents=True)
            contracts.write_text("struct RuntimeToken { let windowID: Int }\n")
            registry = contracts.parent / "WorkspaceRuntimeLifecycleRegistry.swift"
            registry.write_text("actor WorkspaceRuntimeLifecycleRegistry {}\n")
            self.assertTrue(any("window/UI neutral" in error for error in validate_sources(root)))

    def test_phase_seven_strong_adapter_retention_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            adapter = root / "Sources/RepoPrompt/Infrastructure/MCP/Runtime/MCPAppRuntimeAdapterRegistry.swift"
            adapter.parent.mkdir(parents=True)
            adapter.write_text("final class Entry { var adapter: Any; var windowState: Any; var serverViewModel: Any }\n")
            self.assertTrue(any("retain UI weakly" in error for error in validate_sources(root)))

    def test_phase_seven_strong_tool_dependency_retention_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            dependencies = root / "Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPWindowToolDependencies.swift"
            dependencies.parent.mkdir(parents=True)
            dependencies.write_text("struct Dependencies { let promptVM: PromptViewModel }\n")
            errors = validate_sources(root)
            self.assertTrue(any("must not strongly retain UI dependency" in error for error in errors))

    def test_phase_seven_routing_selection_outside_container_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            container = root / "Sources/RepoPrompt/App/CoreAdapters/RepoPromptAppCoreContainer.swift"
            container.parent.mkdir(parents=True)
            container.write_text("// container\n")
            leaked = root / "Sources/RepoPrompt/LeakedRuntimeRouting.swift"
            leaked.write_text('let key = "coreIsolation.runtimeRoutingBackend"\n')
            self.assertTrue(any("must not select the Phase 7 routing backend" in error for error in validate_sources(root)))

    def test_phase_seven_headless_runtime_registry_construction_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            leaked = root / TARGET_PATHS["RepoPromptHeadless"] / "RuntimeLeak.swift"
            leaked.write_text("let registry = WorkspaceRuntimeLifecycleRegistry()\n")
            self.assertTrue(any("must not instantiate Phase 5 app session authority" in error for error in validate_sources(root)))

    def test_phase_eight_headless_test_target_is_required(self) -> None:
        package = copy.deepcopy(valid_package())
        package["targets"] = [
            target for target in package["targets"]
            if target["name"] != "RepoPromptHeadlessTests"
        ]
        self.assertTrue(any("requires the RepoPromptHeadlessTests" in error for error in validate_package(package)))

    def test_phase_eight_headless_stdout_bypass_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            leaked = root / TARGET_PATHS["RepoPromptHeadless"] / "StdoutLeak.swift"
            leaked.write_text("let output = FileHandle.standardOutput\n")
            self.assertTrue(any("writes stdout outside" in error for error in validate_sources(root)))

    def test_phase_eight_headless_app_identity_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            leaked = root / TARGET_PATHS["RepoPromptHeadless"] / "IdentityLeak.swift"
            leaked.write_text('let identity = "repoprompt-ce-D-7.sock"\n')
            self.assertTrue(any("leaks app/proxy identity" in error for error in validate_sources(root)))

    def test_phase_eight_headless_tool_profile_drift_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            registry = root / TARGET_PATHS["RepoPromptHeadless"] / "MCP/HeadlessToolRegistry.swift"
            registry.parent.mkdir(parents=True, exist_ok=True)
            registry.write_text('Registration(name: "apply_edits", capability: .safeProfile)\n')
            self.assertTrue(any("safe tool registry drifted" in error for error in validate_sources(root)))

    def test_phase_eight_headless_packaging_cannot_reference_proxy(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            script = root / "Scripts/package_headless.sh"
            script.parent.mkdir(parents=True, exist_ok=True)
            script.write_text("./Scripts/package_app.sh release\n")
            self.assertTrue(any("must remain standalone" in error for error in validate_sources(root)))

    def _write_minimal_sources(self, root: Path) -> None:
        for relative in TARGET_PATHS.values():
            directory = root / relative
            directory.mkdir(parents=True)
            (directory / "Scaffold.swift").write_text("// scaffold\n")
        (root / "Package.swift").write_text("// fixture package\n")
        app = root / "Sources/RepoPrompt/Frozen.swift"
        app.parent.mkdir(parents=True)
        declarations = "\n".join(f"struct {name} {{}}" for name in sorted(CORE_DECLARATIONS))
        app.write_text(declarations + "\n")


if __name__ == "__main__":
    unittest.main()
