#!/usr/bin/env python3
"""Phase 2 runtime, prompt-assembly, and reviewed-headless boundary checks."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

from shared_runtime_headless_baseline import verify_reviewed_headless_baseline


ROOT = Path(__file__).resolve().parents[1]
PHASE0_ARTIFACT_BASELINE = "48a335e"
PHASE0_ROOT = "Tests/SharedRuntimeConvergenceFixtures/Phase0"
PHASE0_FROZEN_FILES = (
    "docs/characterization/shared-runtime-phase0-2026-06-05.md",
    "Scripts/test_shared_runtime_phase0_characterization.py",
)

REQUIRED_RUNTIME_PATHS = (
    "Sources/RepoPromptCore/FileSystem/FileSystemService.swift",
    "Sources/RepoPromptCore/Regex/PCRE2Regex.swift",
    "Sources/RepoPromptCore/SyntaxParsing/SyntaxManager.swift",
    "Sources/RepoPromptCore/CodeMap/CodeMapGenerator.swift",
    "Sources/RepoPromptCore/WorkspaceContext/WorkspaceRuntimeDependencies.swift",
    "Sources/RepoPromptCore/WorkspaceContext/WorkspaceFileContextStore.swift",
    "Sources/RepoPromptCore/WorkspaceContext/WorkspaceFileSystemIngressCoordinator.swift",
    "Sources/RepoPromptCore/WorkspaceContext/Search/WorkspaceSearchService.swift",
    "Sources/RepoPromptCore/WorkspaceContext/Selection/WorkspaceSelectionController.swift",
    "Sources/RepoPromptCore/WorkspaceContext/Slices/SelectionSliceCoordinator.swift",
    "Sources/RepoPromptCore/WorkspaceContext/TokenAccounting/TokenCalculationService.swift",
    "Sources/RepoPromptCoreMacOS/FileSystem/MacOSWorkspaceDirectoryListingBackend.swift",
    "Sources/RepoPrompt/App/RepoPromptEmbeddedWorkspaceRuntimeFactory.swift",
)

RETIRED_RUNTIME_PATHS = (
    "Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemService.swift",
    "Sources/RepoPrompt/Infrastructure/Regex/PCRE2Regex.swift",
    "Sources/RepoPrompt/Infrastructure/SyntaxParsing/SyntaxManager.swift",
    "Sources/RepoPrompt/Features/CodeMap/CodeMapGenerator.swift",
    "Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift",
    "Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileSystemIngressCoordinator.swift",
    "Sources/RepoPrompt/Infrastructure/WorkspaceContext/Search/WorkspaceSearchService.swift",
    "Sources/RepoPrompt/Infrastructure/WorkspaceContext/Selection/WorkspaceSelectionController.swift",
    "Sources/RepoPrompt/Infrastructure/WorkspaceContext/Slices/SelectionSliceCoordinator.swift",
    "Sources/RepoPrompt/App/CoreAdapters/WorkspaceSessionSelectionForwarder.swift",
)

REQUIRED_PROMPT_ASSEMBLY_PATHS = (
    "Sources/RepoPromptCore/Prompt/PromptAssemblyBuilder.swift",
    "Sources/RepoPromptCore/Prompt/PromptContextAccountingService.swift",
    "Sources/RepoPromptCore/Prompt/PromptRenderingService.swift",
    "Sources/RepoPromptCore/Prompt/PromptRenderingValues.swift",
    "Sources/RepoPromptCore/Prompt/PromptRenderPolicy.swift",
    "Sources/RepoPromptCore/WorkspaceContext/Projection/WorkspaceSelectionProjection.swift",
    "Sources/RepoPromptCore/WorkspaceContext/Projection/WorkspaceSelectionProjectionService.swift",
    "Sources/RepoPromptCore/WorkspaceContext/Projection/TokenProjection.swift",
    "Sources/RepoPromptCore/WorkspaceContext/Projection/TokenProjectionService.swift",
    "Sources/RepoPromptCore/WorkspaceContext/Projection/WorkspaceContextProjection.swift",
    "Sources/RepoPromptCore/WorkspaceContext/Projection/WorkspaceContextProjectionService.swift",
    "Sources/RepoPromptCore/Prompt/PromptSection.swift",
    "Sources/RepoPrompt/Features/Prompt/Models/PromptSection+DisplayName.swift",
    "Sources/RepoPrompt/Features/Prompt/Services/PromptContextAccountingService.swift",
)

RETIRED_PROMPT_ASSEMBLY_PATHS = (
    "Sources/RepoPrompt/Features/Prompt/Models/PromptAssemblyBuilder.swift",
)

REQUIRED_PROVIDER_ACCOUNTING_PATHS = (
    "Sources/RepoPrompt/Infrastructure/AI/Models/AIProviderInputProjection.swift",
    "Sources/RepoPrompt/Infrastructure/AI/Providers/AIProviderInputProjectionCapability.swift",
)

CORE_IMPORTERS = {
    "RepoPromptC": {
        "FileSystem/GitignoreCompiler.swift",
        "Utilities/StringFNV.swift",
        "Utilities/StringLineEndingUtilities.swift",
        "WorkspaceContext/Search/PathSearchIndex.swift",
        "WorkspaceContext/Search/RepoSearchBatchScorer.swift",
        "WorkspaceContext/Search/SearchMatch.swift",
        "WorkspaceContext/Search/SearchPathFiltering.swift",
    },
    "CSwiftPCRE2": {
        "Regex/PCRE2Error.swift",
        "Regex/PCRE2JIT.swift",
        "Regex/PCRE2Options.swift",
        "Regex/PCRE2Regex.swift",
    },
    "RepoPromptSyntaxCBridge": {"SyntaxParsing/SyntaxManager.swift"},
    "SwiftTreeSitter": {
        "CodeMap/CodeMapCaptureIndex.swift",
        "CodeMap/CodeMapGenerator.swift",
        "CodeMap/LanguageStrategies/SwiftCodeMapStrategy.swift",
        "CodeMap/LanguageStrategies/TypeScriptCodeMapStrategy.swift",
        "SyntaxParsing/SyntaxManager.swift",
    },
    "UniversalCharsetDetection": {"FileSystem/FileSystemService+ContentLoading.swift"},
    "Cuchardet": {"FileSystem/FileSystemService+ContentLoading.swift"},
}


def fail(message: str) -> None:
    raise AssertionError(message)


def git_paths(revision: str, root: str) -> list[str]:
    return subprocess.check_output(
        ["git", "ls-tree", "-r", "--name-only", revision, root], cwd=ROOT, text=True
    ).splitlines()


def git_bytes(revision: str, path: str) -> bytes:
    return subprocess.check_output(["git", "show", f"{revision}:{path}"], cwd=ROOT)


def assert_phase0_artifacts_unchanged() -> None:
    baseline_paths = git_paths(PHASE0_ARTIFACT_BASELINE, PHASE0_ROOT)
    if not baseline_paths:
        fail(f"No Phase 0 fixtures found at {PHASE0_ARTIFACT_BASELINE}")
    current_paths = sorted(
        path.relative_to(ROOT).as_posix()
        for path in (ROOT / PHASE0_ROOT).rglob("*")
        if path.is_file()
    )
    if current_paths != baseline_paths:
        fail(
            "Frozen Phase 0 fixture path set changed relative to "
            f"{PHASE0_ARTIFACT_BASELINE}: baseline={baseline_paths}, current={current_paths}"
        )
    for relative in [*baseline_paths, *PHASE0_FROZEN_FILES]:
        if (ROOT / relative).read_bytes() != git_bytes(PHASE0_ARTIFACT_BASELINE, relative):
            fail(
                "Frozen Phase 0 artifact changed relative to "
                f"{PHASE0_ARTIFACT_BASELINE}: {relative}"
            )


def swift_imports(source: Path) -> list[str]:
    pattern = re.compile(
        r"^\s*(?:(?:@[_A-Za-z0-9]+(?:\([^)]*\))?)\s+)*"
        r"import(?:\s+(?:typealias|struct|class|enum|protocol|let|var|func))?"
        r"\s+([A-Za-z_][A-Za-z0-9_]*)",
        re.MULTILINE,
    )
    return pattern.findall(source.read_text())


def dependency_names(target: dict[str, object], kind: str) -> set[str]:
    return {
        dependency[kind][0]
        for dependency in target.get("dependencies", [])
        if kind in dependency
    }


def importer_paths(module: str) -> set[str]:
    core_root = ROOT / "Sources/RepoPromptCore"
    return {
        source.relative_to(core_root).as_posix()
        for source in core_root.rglob("*.swift")
        if module in swift_imports(source)
    }


def token_files(token: str, root: Path) -> list[str]:
    return sorted(
        source.relative_to(ROOT).as_posix()
        for source in root.rglob("*.swift")
        if token in source.read_text()
    )


def assert_single_source_file(filename: str, expected: str) -> None:
    actual = sorted(
        source.relative_to(ROOT).as_posix()
        for source in (ROOT / "Sources").rglob(filename)
        if source.is_file()
    )
    if actual != [expected]:
        fail(f"{filename} canonical ownership drift: expected={[expected]}, actual={actual}")


def main() -> int:
    package = json.loads(
        subprocess.check_output(["swift", "package", "dump-package"], cwd=ROOT, text=True)
    )
    products = [(product["name"], product["type"]) for product in package["products"]]
    expected_products = ["RepoPrompt", "repoprompt-mcp", "repoprompt-headless"]
    if [name for name, _ in products] != expected_products:
        fail(f"Expected executable-only products {expected_products}, found {products}")
    if any("executable" not in product_type for _, product_type in products):
        fail(f"Every advertised product must remain executable: {products}")

    targets = {target["name"]: target for target in package["targets"]}
    expected_target_paths = {
        "RepoPromptShared": "Sources/RepoPromptShared",
        "RepoPromptPOSIXSupport": "Sources/RepoPromptPOSIXSupport",
        "RepoPromptCore": "Sources/RepoPromptCore",
        "RepoPromptCoreMacOS": "Sources/RepoPromptCoreMacOS",
    }
    for name, path in expected_target_paths.items():
        if targets.get(name, {}).get("path") != path:
            fail(f"Target {name} must remain at {path}")

    core_target = targets["RepoPromptCore"]
    expected_by_name = {"RepoPromptC", "CSwiftPCRE2", "RepoPromptSyntaxCBridge"}
    expected_products = {"SwiftTreeSitter", "UniversalCharsetDetection", "Cuchardet"}
    actual_by_name = dependency_names(core_target, "byName")
    actual_products = dependency_names(core_target, "product")
    if actual_by_name != expected_by_name:
        fail(
            "RepoPromptCore by-name dependencies must match importer-backed native edges: "
            f"expected={sorted(expected_by_name)}, actual={sorted(actual_by_name)}"
        )
    if actual_products != expected_products:
        fail(
            "RepoPromptCore product dependencies must match importer-backed native edges: "
            f"expected={sorted(expected_products)}, actual={sorted(actual_products)}"
        )
    if len(core_target.get("dependencies", [])) != len(expected_by_name) + len(expected_products):
        fail(f"RepoPromptCore has an unsupported dependency record: {core_target.get('dependencies', [])}")

    for module, expected in CORE_IMPORTERS.items():
        actual = importer_paths(module)
        if actual != expected:
            fail(
                f"RepoPromptCore {module} importer ownership drift: "
                f"expected={sorted(expected)}, actual={sorted(actual)}"
            )

    direct_grammar_products = sorted(
        product
        for product in actual_products
        if product.startswith("TreeSitter") and product != "SwiftTreeSitter"
    )
    if direct_grammar_products:
        fail(f"RepoPromptCore must not depend directly on grammar products: {direct_grammar_products}")

    for relative in REQUIRED_RUNTIME_PATHS:
        if not (ROOT / relative).is_file():
            fail(f"Required Phase 2 Slice 2 runtime owner missing: {relative}")
    for relative in RETIRED_RUNTIME_PATHS:
        if (ROOT / relative).exists():
            fail(f"Retired app runtime owner still exists: {relative}")
    for relative in REQUIRED_PROMPT_ASSEMBLY_PATHS:
        if not (ROOT / relative).is_file():
            fail(f"Required Slice 3 prompt assembly owner missing: {relative}")
    for relative in RETIRED_PROMPT_ASSEMBLY_PATHS:
        if (ROOT / relative).exists():
            fail(f"Retired app prompt assembly owner still exists: {relative}")
    for relative in REQUIRED_PROVIDER_ACCOUNTING_PATHS:
        if not (ROOT / relative).is_file():
            fail(f"Required provider-aware accounting foundation missing: {relative}")

    canonical_source_owners = {
        "CodeMapGenerator.swift": "Sources/RepoPromptCore/CodeMap/CodeMapGenerator.swift",
        "AgentSupportDirectoryCatalog.swift": "Sources/RepoPromptCore/WorkspaceContext/PathResolution/AgentSupportDirectoryCatalog.swift",
        "WorkspaceReadableFileService.swift": "Sources/RepoPromptCore/WorkspaceContext/WorkspaceReadableFileService.swift",
        "WorkspaceSessionController.swift": "Sources/RepoPromptCore/Workspaces/WorkspaceSessionController.swift",
        "WorkspaceSelectionProjection.swift": "Sources/RepoPromptCore/WorkspaceContext/Projection/WorkspaceSelectionProjection.swift",
        "WorkspaceSelectionProjectionService.swift": "Sources/RepoPromptCore/WorkspaceContext/Projection/WorkspaceSelectionProjectionService.swift",
        "TokenProjection.swift": "Sources/RepoPromptCore/WorkspaceContext/Projection/TokenProjection.swift",
        "TokenProjectionService.swift": "Sources/RepoPromptCore/WorkspaceContext/Projection/TokenProjectionService.swift",
        "WorkspaceContextProjection.swift": "Sources/RepoPromptCore/WorkspaceContext/Projection/WorkspaceContextProjection.swift",
        "WorkspaceContextProjectionService.swift": "Sources/RepoPromptCore/WorkspaceContext/Projection/WorkspaceContextProjectionService.swift",
    }
    for filename, expected in canonical_source_owners.items():
        assert_single_source_file(filename, expected)

    workspace_files_source = (
        ROOT / "Sources/RepoPrompt/Features/WorkspaceFiles/ViewModels/WorkspaceFilesViewModel.swift"
    ).read_text()
    for duplicate_token in (
        "struct ExternalReadableFile",
        "enum ReadableFileHandle",
        "resolveReadableFileForUserInput(",
        "readAlwaysReadableExternalFile(",
        "alwaysReadableHomeDirectoryURL",
    ):
        if duplicate_token in workspace_files_source:
            fail(f"WorkspaceFilesViewModel retains duplicate Core readable-file state: {duplicate_token}")

    workspace_manager_source = (
        ROOT / "Sources/RepoPrompt/Features/Workspaces/ViewModels/WorkspaceManagerViewModel.swift"
    ).read_text()
    for duplicate_token in (
        "struct ComposeTabBindingCandidate",
        "func bindingCandidate(forContextID",
        "func bindingCandidates(matchingWorkingDirs",
        "normalizeBindingPath(",
    ):
        if duplicate_token in workspace_manager_source:
            fail(f"WorkspaceManagerViewModel retains duplicate Core session binding state: {duplicate_token}")

    window_routing_source = (
        ROOT / "Sources/RepoPrompt/Infrastructure/MCP/WindowRoutingService.swift"
    ).read_text()
    if (
        "window.coreSessionHandle.session.workspaceSessionController" not in window_routing_source
        or ".bindingCandidate(forContextID: contextID)" not in window_routing_source
    ):
        fail("Window context binding must query the canonical Core session controller")

    workspace_model_adapter_source = (
        ROOT / "Sources/RepoPrompt/Features/Workspaces/WorkspaceModel.swift"
    ).read_text()
    if "typealias WorkspaceModel = RepoPromptCore.WorkspaceModel" not in workspace_model_adapter_source:
        fail("App workspace model compatibility file must alias canonical Core state")
    for declaration in ("struct WorkspaceModel", "class WorkspaceModel", "enum WorkspaceModel"):
        if declaration in workspace_model_adapter_source:
            fail(f"App workspace model compatibility file redeclares Core state: {declaration}")

    observation_bridge_source = (
        ROOT / "Sources/RepoPrompt/App/CoreAdapters/WorkspaceSessionObservationBridge.swift"
    ).read_text()
    if "controller.observe" not in observation_bridge_source or "@Published" not in observation_bridge_source:
        fail("WorkspaceSessionObservationBridge must remain an app observation adapter over Core")
    prompt_projection_adapter_source = (
        ROOT / "Sources/RepoPrompt/Features/Prompt/Services/WorkspacePromptProjectionAdapter.swift"
    ).read_text()
    if "WorkspaceContextProjectionService(" not in prompt_projection_adapter_source:
        fail("WorkspacePromptProjectionAdapter must delegate canonical projection to Core")

    agent_support_catalog_source = (
        ROOT / "Sources/RepoPromptCore/WorkspaceContext/PathResolution/AgentSupportDirectoryCatalog.swift"
    ).read_text()
    if "case globalCodexPrompts" in agent_support_catalog_source:
        fail("Codex prompts readable-root access requires a separate explicit product/security policy change")
    built_in_body = agent_support_catalog_source.split("package static func builtInAlwaysReadableDirectories", 1)[1].split("package static func effectiveAlwaysReadableDirectories", 1)[0]
    if "roots.codexPrompts" in built_in_body:
        fail("~/.codex/prompts must not become always-readable without explicit policy approval")

    core_accounting_source = (
        ROOT / "Sources/RepoPromptCore/Prompt/PromptContextAccountingService.swift"
    ).read_text()
    app_accounting_source = (
        ROOT / "Sources/RepoPrompt/Features/Prompt/Services/PromptContextAccountingService.swift"
    ).read_text()
    for declaration in (
        "package struct PromptContextAccountingRequest",
        "package struct PromptContextAccountingResolution",
        "package struct PromptContextAccountingResult",
        "package actor PromptContextAccountingService",
    ):
        if declaration not in core_accounting_source:
            fail(f"Canonical Core prompt accounting declaration missing: {declaration}")
        if declaration in app_accounting_source:
            fail(f"App prompt accounting facade redeclares Core ownership: {declaration}")
    if "private let core = RepoPromptCore.PromptContextAccountingService()" not in app_accounting_source:
        fail("App prompt accounting compatibility owner must delegate to RepoPromptCore")

    core_rendering_values_source = (
        ROOT / "Sources/RepoPromptCore/Prompt/PromptRenderingValues.swift"
    ).read_text()
    core_rendering_service_source = (
        ROOT / "Sources/RepoPromptCore/Prompt/PromptRenderingService.swift"
    ).read_text()
    core_assembly_source = (
        ROOT / "Sources/RepoPromptCore/Prompt/PromptAssemblyBuilder.swift"
    ).read_text()
    app_packaging_source = (
        ROOT / "Sources/RepoPrompt/Features/Prompt/Services/PromptPackagingService.swift"
    ).read_text()
    app_ai_message_source = (
        ROOT / "Sources/RepoPrompt/Infrastructure/AI/AIMessage.swift"
    ).read_text()
    app_prompt_view_model_source = (
        ROOT / "Sources/RepoPrompt/Features/Prompt/ViewModels/PromptViewModel.swift"
    ).read_text()
    app_provider_projection_source = (
        ROOT / "Sources/RepoPrompt/Infrastructure/AI/Models/AIProviderInputProjection.swift"
    ).read_text()
    app_provider_factory_source = (
        ROOT / "Sources/RepoPrompt/Infrastructure/AI/Providers/AIProviderFactory.swift"
    ).read_text()
    app_provider_capability_source = (
        ROOT
        / "Sources/RepoPrompt/Infrastructure/AI/Providers/AIProviderInputProjectionCapability.swift"
    ).read_text()
    app_queries_source = (
        ROOT / "Sources/RepoPrompt/Infrastructure/AI/AIQueriesService.swift"
    ).read_text()
    for declaration in (
        "package struct PromptRenderingFileValue",
        "package struct PromptRenderingDiffValue",
        "package struct PromptRenderedFileBlock",
        "package struct PromptPartitionedFileBlocks",
        "package struct PromptRenderedFactualSnippets",
    ):
        if declaration not in core_rendering_values_source:
            fail(f"Canonical Core prompt rendering value missing: {declaration}")
    if "package enum PromptRenderingService" not in core_rendering_service_source:
        fail("Canonical Core prompt rendering service missing")
    for delegation in (
        "PromptRenderingService.codeFenceStart",
        "PromptRenderingService.renderFileBlocks",
        "PromptRenderingService.renderPartitionedFileBlocks",
        "PromptRenderingService.renderDiffParts",
        "PromptRenderingService.renderSelectedDiffText",
        "PromptRenderingService.renderFactualSnippets",
    ):
        if delegation not in app_packaging_source:
            fail(f"App prompt packaging facade must delegate factual rendering: {delegation}")
    expected_core_standard_chat_owners = [
        "Sources/RepoPrompt/Features/Prompt/ViewModels/PromptViewModel.swift",
        "Sources/RepoPrompt/Infrastructure/AI/AIMessage.swift",
    ]
    actual_core_standard_chat_owners = token_files("coreStandardChat", ROOT / "Sources")
    if actual_core_standard_chat_owners != expected_core_standard_chat_owners:
        fail(
            "Core standard chat opt-in must remain limited to AIMessage and the standard "
            "PromptViewModel path: "
            f"expected={expected_core_standard_chat_owners}, "
            f"actual={actual_core_standard_chat_owners}"
        )
    for required_ai_message_adapter in (
        "enum TailAssemblyStrategy",
        "struct PreparedOpenAIChatInput",
        "struct PreparedOpenAIResponsesInput",
        "func preparedOpenAIChatInput(embedSystemPrompt: Bool)",
        "func preparedOpenAIResponsesInput()",
        "preparedOpenAIChatInput(embedSystemPrompt: embedSystemPrompt).messages.map",
        "let prepared = preparedOpenAIResponsesInput()",
        "case legacy",
        "case coreStandardChat",
        "envelopePolicy: .chatStyleTree",
        "layout: .blankLineSeparatedFragments",
        "disabledPromptSections.union([.userInstructions])",
        "duplicateUserInstructionsAtTop: false",
        'return [tail, "", systemPrompt].joined(separator: "\\n\\n")',
        "var fileTreeXML: String",
        "var fileBlocksXML: String",
        "var gitDiffXML: String",
        "var combinedXML: String",
        "private let renderedFactualSnippets: PromptRenderedFactualSnippets",
    ):
        if required_ai_message_adapter not in app_ai_message_source:
            fail(f"AIMessage standard-chat compatibility adapter missing: {required_ai_message_adapter}")
    for required_packaging_adapter in (
        "tailAssemblyStrategy: AIMessage.TailAssemblyStrategy = .legacy",
        "tailAssemblyStrategy: tailAssemblyStrategy",
        "exactRenderedPayload(renderedChatPayload(for: message)",
    ):
        if required_packaging_adapter not in app_packaging_source:
            fail(f"Prompt packaging standard-chat adapter missing: {required_packaging_adapter}")
    if app_prompt_view_model_source.count("tailAssemblyStrategy: .coreStandardChat") != 1:
        fail("Exactly one standard PromptViewModel packagePromptResult path must opt into Core assembly")
    if "exactChatPayload(for: message, source: tokenSource)" not in app_prompt_view_model_source:
        fail("Standard chat exact accounting must continue to derive from the packaged AIMessage")

    for required_projection_foundation in (
        "struct AIProviderInputProjection",
        "struct ChatInputTokenEstimate",
        "enum AIProviderInputProjectionResolver",
        "enum RouteResolution",
        "case unresolved",
        "case preflightResolved",
        "case providerResolved",
        "private init(",
        "fragments: fragments(for: input)",
        "TokenProjectionService.renderedPayloadEstimate",
    ):
        if required_projection_foundation not in app_provider_projection_source:
            fail(f"Provider-aware accounting foundation missing: {required_projection_foundation}")
    if "TokenProjectionService.exactRenderedPayload" in app_provider_projection_source:
        fail("App-content projections must never claim exact rendered payload provenance")
    for required_preflight_boundary in (
        "case .openAI:",
        "case .openRouter:",
        "case .azure, .customProvider:",
        "case .anthropic, .ollama, .gemini, .deepseek,",
    ):
        if required_preflight_boundary not in app_provider_projection_source:
            fail(f"Narrow preflight boundary changed: {required_preflight_boundary}")
    if "isKnownOpenAITransport" in app_provider_projection_source:
        fail("Preflight must preserve AIModel.providerType routing for legacy Azure-backed models")
    if "AIProviderInputProjection" in core_rendering_values_source or "AIProviderInputProjection" in core_rendering_service_source:
        fail("Provider-aware accounting DTOs must remain app-owned")
    if "func streamMessageWithInputProjection(" not in app_provider_factory_source:
        fail("AIProvider protocol projection seam missing")
    for required_provider_seam in (
        "struct AIProviderStreamStart",
        "func streamMessageWithInputProjection(",
        "inputProjection: nil",
    ):
        if required_provider_seam not in app_provider_capability_source:
            fail(f"Additive provider projection seam missing: {required_provider_seam}")
    if "streamMessageWithInputProjection" in app_queries_source:
        fail("Checkpoint 1 must not change AIQueriesService lazy send lifecycle")
    projection_seam_owners = token_files("streamMessageWithInputProjection", ROOT / "Sources")
    if projection_seam_owners != [
        "Sources/RepoPrompt/Infrastructure/AI/Providers/AIProviderFactory.swift",
        "Sources/RepoPrompt/Infrastructure/AI/Providers/AIProviderInputProjectionCapability.swift",
    ]:
        fail(
            "Checkpoint 1 must keep the provider projection seam defaulted and unused; "
            f"found concrete adaptations: {projection_seam_owners}"
        )

    provider_compatibility_tokens = {
        "Sources/RepoPrompt/Infrastructure/AI/Providers/AnthropicProvider.swift": (
            "aiMessage.buildTail(embedSystemPrompt: false)",
        ),
        "Sources/RepoPrompt/Infrastructure/AI/Providers/AzureOpenAIProvider.swift": (
            "let embedSystemPrompt = baseModel == .o1Mini || baseModel == .o1Preview",
            "message.openAIChatMessages(embedSystemPrompt: embedSystemPrompt)",
            "message.openAIResponsesInput()",
        ),
        "Sources/RepoPrompt/Infrastructure/AI/Providers/ClaudeCodeProvider.swift": (
            "aiMessage.buildTail(embedSystemPrompt: false)",
        ),
        "Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/CodexCLIProvider.swift": (
            "aiMessage.buildTail(embedSystemPrompt: false)",
        ),
        "Sources/RepoPrompt/Infrastructure/AI/Providers/Cursor/CursorCLIProvider.swift": (
            "aiMessage.buildTail(embedSystemPrompt: false)",
        ),
        "Sources/RepoPrompt/Infrastructure/AI/Providers/CustomOpenai/CustomOpenAIProvider.swift": (
            "aiMessage.fileTreeXML",
            "aiMessage.fileBlocksXML",
            "aiMessage.metaPrompts",
        ),
        "Sources/RepoPrompt/Infrastructure/AI/Providers/OpenAIProvider.swift": (
            "let isO1PreviewOrMini = (effectiveModel == .o1Mini || effectiveModel == .o1Preview)",
            "aiMessage.openAIChatMessages(embedSystemPrompt: isO1PreviewOrMini)",
            "aiMessage.openAIResponsesInput()",
        ),
        "Sources/RepoPrompt/Infrastructure/AI/Providers/OpenCode/OpenCodeCLIProvider.swift": (
            "aiMessage.buildTail(embedSystemPrompt: false)",
        ),
        "Sources/RepoPrompt/Infrastructure/AI/Providers/OpenRouterProvider.swift": (
            "aiMessage.openAIChatMessages(embedSystemPrompt: false)",
        ),
    }
    for relative, required_tokens in provider_compatibility_tokens.items():
        source = (ROOT / relative).read_text()
        for required_token in required_tokens:
            if required_token not in source:
                fail(f"Provider compatibility call changed in {relative}: {required_token}")

    for retained_app_token in ("enum PromptGitDiffArtifactClassifier", "_git_data"):
        if retained_app_token not in app_packaging_source:
            fail(f"App prompt packaging policy owner missing: {retained_app_token}")
        if retained_app_token in core_rendering_values_source or retained_app_token in core_rendering_service_source:
            fail(f"Core prompt rendering must not own app classification policy: {retained_app_token}")
    for forbidden_core_token in (
        "FileViewModel",
        "PromptFileEntry",
        "ResolvedPromptFileEntry",
        "FileAPI",
        "WorkspaceCodemapSnapshot",
        "CopyPreset",
        "AIMessage",
        "ConversationEntry",
        "embedSystemPrompt",
        "systemPrompt",
        "MCP",
        "Worktree",
        "UserDefaults",
        "NSPasteboard",
        "DateFormatter",
        "Diagnostics",
    ):
        if any(
            forbidden_core_token in source
            for source in (
                core_rendering_values_source,
                core_rendering_service_source,
                core_assembly_source,
            )
        ):
            fail(f"Core prompt rendering/assembly leaks app/product policy: {forbidden_core_token}")
    core_selection_projection_source = (
        ROOT
        / "Sources/RepoPromptCore/WorkspaceContext/Projection/WorkspaceSelectionProjection.swift"
    ).read_text()
    core_selection_projection_service_source = (
        ROOT
        / "Sources/RepoPromptCore/WorkspaceContext/Projection/WorkspaceSelectionProjectionService.swift"
    ).read_text()
    for declaration in (
        "package struct WorkspaceSelectionProjection",
        "package struct WorkspaceSelectionProjectionRequest",
    ):
        if declaration not in core_selection_projection_source:
            fail(f"Canonical Core selection projection declaration missing: {declaration}")
    if "package enum WorkspaceSelectionProjectionService" not in core_selection_projection_service_source:
        fail("Canonical Core selection projection service missing")
    for forbidden_projection_token in (
        "ToolResultDTO",
        "CopyPreset",
        "PromptViewModel",
        "PromptContextResolved",
        "FileViewModel",
        "WorkspaceRootBindingProjection",
        "AgentSessionWorktreeBinding",
        "MCP",
    ):
        if (
            forbidden_projection_token in core_selection_projection_source
            or forbidden_projection_token in core_selection_projection_service_source
        ):
            fail(
                "Core selection projection leaks app/product policy: "
                f"{forbidden_projection_token}"
            )
    for forbidden_service_token in ("Task", "async", "await", "actor"):
        if forbidden_service_token in core_selection_projection_service_source:
            fail(
                "Core selection projection service must remain synchronous and request-scoped: "
                f"{forbidden_service_token}"
            )

    core_token_projection_source = (
        ROOT / "Sources/RepoPromptCore/WorkspaceContext/Projection/TokenProjection.swift"
    ).read_text()
    core_token_projection_service_source = (
        ROOT / "Sources/RepoPromptCore/WorkspaceContext/Projection/TokenProjectionService.swift"
    ).read_text()
    core_context_projection_source = (
        ROOT / "Sources/RepoPromptCore/WorkspaceContext/Projection/WorkspaceContextProjection.swift"
    ).read_text()
    core_context_projection_service_source = (
        ROOT / "Sources/RepoPromptCore/WorkspaceContext/Projection/WorkspaceContextProjectionService.swift"
    ).read_text()
    app_projection_adapter_source = (
        ROOT / "Sources/RepoPrompt/Features/Prompt/Services/WorkspacePromptProjectionAdapter.swift"
    ).read_text()
    app_token_recount_source = (
        ROOT / "Sources/RepoPrompt/Features/Prompt/ViewModels/TokenCountingViewModel.swift"
    ).read_text()
    if token_files("package struct TokenProjection", ROOT / "Sources") != [
        "Sources/RepoPromptCore/WorkspaceContext/Projection/TokenProjection.swift"
    ]:
        fail("Canonical TokenProjection ownership must remain in RepoPromptCore")
    if token_files("package enum TokenProjectionService", ROOT / "Sources") != [
        "Sources/RepoPromptCore/WorkspaceContext/Projection/TokenProjectionService.swift"
    ]:
        fail("Canonical TokenProjectionService ownership must remain in RepoPromptCore")
    if "AIProviderInputProjection" in core_token_projection_source + core_token_projection_service_source:
        fail("Core token projection must remain provider-neutral")
    if "package enum WorkspaceTokenProjectionInput" not in core_context_projection_source:
        fail("Typed workspace token projection input must remain Core-owned")
    if "TokenProjectionService.activeLiveWorkspaceEstimates" not in core_context_projection_service_source:
        fail("Workspace context projection must delegate active-live repair to TokenProjectionService")
    if "tokenProjectionInput: WorkspaceTokenProjectionInput" not in app_projection_adapter_source:
        fail("App workspace projection adapter must forward the typed Core token input")
    if "tokenProjectionInput: .activeLive" not in app_token_recount_source:
        fail("Active recount must request canonical active-live projection semantics")
    if ".virtualRecomputed" not in app_token_recount_source:
        fail("Light recount must retain virtual recomputation provenance")
    for forbidden_app_recount_token in (
        "private let tokenCalculationService",
        "normalizedTotal - normalizedFiles",
        "max(userComponentSum, replacementTotal)",
    ):
        if forbidden_app_recount_token in app_token_recount_source or forbidden_app_recount_token in app_projection_adapter_source:
            fail(f"App recount reconstructs canonical token arithmetic: {forbidden_app_recount_token}")
    for required_core_token in (
        "package struct TokenProjection",
        "package enum TokenProjectionService",
        "case renderedPayloadEstimate",
        "package static func renderedPayloadEstimate",
        "activeLiveWorkspaceEstimates",
    ):
        if required_core_token not in core_token_projection_source + core_token_projection_service_source:
            fail(f"Canonical Core token projection declaration missing: {required_core_token}")

    for retired_app_helper in (
        "private static func renderFullFileBlock",
        "private static func renderSliceFileBlock",
        "private static func renderFileBlock",
        "private static func formatRange",
        "SliceAssemblyBuilder.build(",
        "URL(fileURLWithPath:",
    ):
        if retired_app_helper in app_packaging_source:
            fail(f"App prompt packaging retains duplicate factual renderer: {retired_app_helper}")

    core_root = ROOT / "Sources/RepoPromptCore"
    forbidden_imports = {
        "AppKit",
        "SwiftUI",
        "Combine",
        "Cocoa",
        "Sparkle",
        "KeyboardShortcuts",
        "CoreServices",
        "Security",
        "Darwin",
        "Glibc",
        "SystemPackage",
        "OSLog",
        "os",
        "RepoPromptShared",
        "RepoPromptPOSIXSupport",
        "RepoPromptCoreMacOS",
    }
    for source in sorted(core_root.rglob("*.swift")):
        leaked = sorted(set(swift_imports(source)) & forbidden_imports)
        if leaked:
            fail(f"Core app/platform import leakage: {source.relative_to(ROOT)} imports {leaked}")

    core_text = "\n".join(source.read_text() for source in sorted(core_root.rglob("*.swift")))
    for token in ("OSSignpost", "OSSignposter", "os_signpost", "CODEMAP_PERF_SIGNPOSTS", "signposts"):
        if token in core_text:
            fail(f"Core owns Apple signpost instrumentation token: {token}")
    forbidden_tokens = (
        "UserDefaults.standard",
        "Bundle.main",
        "Notification.Name",
        "applicationSupportDirectory",
        "WindowState",
        "WindowStatesManager",
        "NSApplication",
        "NSWorkspace",
    )
    for token in forbidden_tokens:
        if token in core_text:
            fail(f"Core app/platform ownership token remains: {token}")

    all_sources_text = "\n".join(
        source.read_text() for source in sorted((ROOT / "Sources").rglob("*.swift"))
    )
    for token in ("WorkspaceSessionSelectionForwarder", "WorkspaceSelectionHost"):
        if token in all_sources_text:
            fail(f"Obsolete Slice 1 runtime bridge remains: {token}")

    factory_path = "Sources/RepoPrompt/App/RepoPromptEmbeddedWorkspaceRuntimeFactory.swift"
    constructor_owners = {
        "WorkspaceRuntimeDependencies(": [factory_path],
        "WorkspaceFileContextStore(runtimeDependencies:": [factory_path],
        "WorkspaceSearchService()": [factory_path],
        "SelectionSliceCoordinator(store:": [factory_path],
    }
    for token, expected in constructor_owners.items():
        actual = token_files(token, ROOT / "Sources")
        if actual != expected:
            fail(f"Core runtime construction ownership changed for {token}: expected={expected}, actual={actual}")

    headless_text = "\n".join(
        source.read_text()
        for root in (ROOT / "Sources/RepoPromptHeadless", ROOT / "Tests/RepoPromptHeadlessTests")
        for source in sorted(root.rglob("*.swift"))
    )
    for token in (
        "RepoPromptEmbeddedWorkspaceRuntimeFactory",
        "WorkspaceRuntimeDependencies(",
        "WorkspaceFileContextStore(",
        "WorkspaceSelectionController(",
        "WorkspaceSearchService(",
    ):
        if token in headless_text:
            fail(f"Reviewed headless surface constructs the Phase 2 runtime: {token}")

    assert_phase0_artifacts_unchanged()
    verify_reviewed_headless_baseline(ROOT)

    print("OK: shared runtime Phase 2 boundaries passed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
