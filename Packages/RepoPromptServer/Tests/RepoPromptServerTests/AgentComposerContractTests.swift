import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import RepoPromptAgentRuntimeCore
@testable import RepoPromptHeadlessRuntime
@testable import RepoPromptServiceHTTP
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
private func testIdentity() -> CanonicalTurnIdentity {
    .init(requestAnchorID: UUID(), runID: UUID(), generation: 1, turnEpoch: 1, turnID: UUID(), responseSpanID: UUID())
}

private func testConfiguration(at date: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> EffectiveTurnConfigurationRecord {
    .init(
        catalogRevision: "catalog-v1",
        providerID: .codex,
        modelID: "gpt-5.6-sol",
        providerRawModelValue: "gpt-5.6-sol-high",
        effortID: "high",
        permissionID: "codex.defaultPermission",
        toolValues: ["codex.bash": .boolean(true), "codex.mcpServers": .choices(["repoprompt"])],
        capabilityDigest: "capability-v1",
        actorID: "actor-1",
        acceptedAt: date
    )
}

private func tinyPNG() -> Data {
    Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl9sAAAAASUVORK5CYII=")!
}

final class AgentComposerCatalogTests: XCTestCase {
    func testDesktopFallbackPopulatesCodexComposerWithoutDiscoveredCatalog() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        _ = try await store.upsertProviderSettings(
            ProviderSettingsPreference(providerID: .codex, enabled: true, revision: 1),
            expectedRevision: 0
        )
        let instant = Date(timeIntervalSince1970: 1_786_400_000)
        let connection = ProviderConnectionRecord(
            connectionID: UUID(),
            providerID: .codex,
            authenticationMethod: .deviceCodeBeta,
            state: .attention,
            accountLabel: "sandbox",
            lastTestedAt: instant,
            testState: .unavailable,
            detail: "Authentication status is temporarily unavailable",
            keyHelperConfigured: false,
            workloadIdentityConfigured: false,
            createdAt: instant,
            updatedAt: instant,
            revision: 1
        )
        _ = try await store.upsertProviderConnection(.init(record: connection, credentialReference: nil), expectedRevision: 0)
        let runner = StructuredStartProviderRunner()
        let configuration = ProviderCLIConfiguration(kind: .codex, executable: "/usr/bin/swift", expectedVersion: "6.2")
        let settings = ProviderSettingsService(
            store: store,
            adapter: ProviderCLIAdapter(configurations: [configuration], enabledProviders: [.codex], runner: runner),
            configurations: [configuration],
            initiallyEnabled: [.codex],
            runner: runner
        )
        try await settings.bootstrap()

        let snapshot = try await AgentComposerCatalogService(providerSettings: settings, store: store).snapshot(
            context: .init(kind: .project, projectID: UUID(), actorID: "catalog-reader")
        )

        let group = try XCTUnwrap(snapshot.providerGroups.first { $0.providerID == .codex })
        let sol = try XCTUnwrap(group.models.first { $0.id == "gpt-5.6-sol" })
        XCTAssertEqual(sol.supportedEffortIDs, ["low", "medium", "high", "xhigh", "max", "ultra"])
        XCTAssertEqual(sol.defaultEffortID, "medium")
        XCTAssertTrue(group.models.contains { $0.id == "gpt-5.6-sol-fast" })
        XCTAssertEqual(snapshot.selected?.providerID, .codex)
        XCTAssertEqual(snapshot.selected?.modelID, "gpt-5.6-sol")
        XCTAssertEqual(snapshot.selected?.effortID, "medium")
        XCTAssertNotNil(group.permissionControl)
        XCTAssertFalse(group.toolControls.isEmpty)
    }

    func testComposerSelectionLiveReadsPreferredComposeModelFromAgentModelsStore() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        _ = try await store.upsertProviderSettings(
            ProviderSettingsPreference(providerID: .codex, enabled: true, revision: 1),
            expectedRevision: 0
        )
        let instant = Date(timeIntervalSince1970: 1_786_400_000)
        let connection = ProviderConnectionRecord(
            connectionID: UUID(),
            providerID: .codex,
            authenticationMethod: .deviceCodeBeta,
            state: .attention,
            accountLabel: "sandbox",
            lastTestedAt: instant,
            testState: .unavailable,
            detail: "Authentication status is temporarily unavailable",
            keyHelperConfigured: false,
            workloadIdentityConfigured: false,
            createdAt: instant,
            updatedAt: instant,
            revision: 1
        )
        _ = try await store.upsertProviderConnection(.init(record: connection, credentialReference: nil), expectedRevision: 0)
        let runner = StructuredStartProviderRunner()
        let configuration = ProviderCLIConfiguration(kind: .codex, executable: "/usr/bin/swift", expectedVersion: "6.2")
        let settings = ProviderSettingsService(
            store: store,
            adapter: ProviderCLIAdapter(configurations: [configuration], enabledProviders: [.codex], runner: runner),
            configurations: [configuration],
            initiallyEnabled: [.codex],
            runner: runner
        )
        try await settings.bootstrap()

        let snapshot = try await AgentComposerCatalogService(
            providerSettings: settings,
            store: store,
            composeModelLoader: { "gpt-5.6-sol-fast" }
        ).snapshot(context: .init(kind: .project, projectID: UUID(), actorID: "compose-reader"))

        XCTAssertEqual(snapshot.selected?.providerID, .codex)
        XCTAssertEqual(snapshot.selected?.modelID, "gpt-5.6-sol-fast")
    }

    func testComposerEmptyStateLiveReadsFeaturedOrderInsteadOfBootFrozenPrefix() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let authority = RepoPromptHeadlessAuthority(store: store)
        try await authority.recover()
        let initial = try await authority.workflowRepositorySnapshot()
        XCTAssertTrue(initial.workflows.allSatisfy { $0.featuredOrder == nil })
        _ = try await authority.reorderWorkflows(
            .init(expectedRevision: initial.revision, featuredWorkflowIDs: ["rp-review", "rp-orchestrate", "rp-deep-plan"]),
            attribution: .init(actorID: "certificate:featured-order-test", actorLabel: "Featured Order Test", channel: "test")
        )

        let runner = StructuredStartProviderRunner()
        let configuration = ProviderCLIConfiguration(kind: .codex, executable: "/usr/bin/swift", expectedVersion: "6.2")
        let settings = ProviderSettingsService(
            store: store,
            adapter: ProviderCLIAdapter(configurations: [configuration], enabledProviders: [.codex], runner: runner),
            configurations: [configuration],
            initiallyEnabled: [.codex],
            runner: runner
        )
        try await settings.bootstrap()
        let catalog = AgentComposerCatalogService(
            providerSettings: settings,
            store: store,
            workflows: [
                .init(id: "boot-a", displayName: "A"),
                .init(id: "boot-b", displayName: "B"),
                .init(id: "boot-c", displayName: "C"),
                .init(id: "boot-d", displayName: "D"),
                .init(id: "boot-e", displayName: "E"),
            ],
            emptyState: .init(featuredWorkflowIDs: ["boot-a", "boot-b", "boot-c", "boot-d"], tips: [])
        )
        let snapshot = try await catalog.snapshot(context: .init(kind: .project, projectID: UUID(), actorID: "featured-reader"))
        XCTAssertEqual(snapshot.emptyState.featuredWorkflowIDs, ["rp-review", "rp-orchestrate", "rp-deep-plan"])
        XCTAssertEqual(
            snapshot.workflows.filter { $0.featuredOrder != nil }.map(\.id),
            ["rp-review", "rp-orchestrate", "rp-deep-plan"]
        )
        XCTAssertEqual(snapshot.workflows.first { $0.id == "rp-review" }?.featuredOrder, 0)
        XCTAssertFalse(snapshot.workflows.contains { $0.id == "rp-build" })
        let bootWorkflows = snapshot.workflows.filter { $0.id.hasPrefix("boot-") }
        XCTAssertEqual(bootWorkflows.map(\.id), ["boot-a", "boot-b", "boot-c", "boot-d", "boot-e"])
        XCTAssertTrue(bootWorkflows.allSatisfy { $0.featuredOrder == nil })
    }

    func testBuiltInVisibilityDefaultsHideBuildUnfeaturesAndKeepsSelectedLookup() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let authority = RepoPromptHeadlessAuthority(store: store)
        try await authority.recover()
        let initial = try await authority.workflowRepositorySnapshot()
        let build = try XCTUnwrap(initial.workflows.first { $0.workflowID == "rp-build" })
        XCTAssertFalse(build.visible)
        XCTAssertTrue(
            initial.workflows
                .filter { $0.source == .builtin && $0.workflowID != "rp-build" }
                .allSatisfy(\.visible)
        )
        let discoveredAfterBoot = try await authority.workflowSnapshots()
        XCTAssertFalse(discoveredAfterBoot.contains { $0.workflowID == "rp-build" })
        _ = try await authority.workflowSnapshot(workflowID: "rp-build")

        do {
            _ = try await authority.reorderWorkflows(
                .init(expectedRevision: initial.revision, featuredWorkflowIDs: ["rp-build"]),
                attribution: .init(actorID: "certificate:visibility-test", actorLabel: "Visibility Test", channel: "test")
            )
            XCTFail("expected hidden built-in to be rejected from featured order")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
        }

        let featured = try await authority.reorderWorkflows(
            .init(expectedRevision: initial.revision, featuredWorkflowIDs: ["rp-review"]),
            attribution: .init(actorID: "certificate:visibility-test", actorLabel: "Visibility Test", channel: "test")
        )
        let review = try XCTUnwrap(featured.workflows.first { $0.workflowID == "rp-review" })
        XCTAssertEqual(review.featuredOrder, 0)
        let hidden = try await authority.setWorkflowVisibility(
            workflowID: "rp-review",
            request: .init(expectedRevision: featured.revision, expectedRowRevision: review.rowRevision, visible: false),
            attribution: .init(actorID: "certificate:visibility-test", actorLabel: "Visibility Test", channel: "test")
        )
        XCTAssertNil(hidden.workflows.first { $0.workflowID == "rp-review" }?.featuredOrder)
        let discoveredAfterHide = try await authority.workflowSnapshots()
        XCTAssertFalse(discoveredAfterHide.contains { $0.workflowID == "rp-review" })
        _ = try await authority.workflowSnapshot(workflowID: "rp-review")

        let created = try await authority.createWorkflow(
            .init(expectedRevision: hidden.revision, name: "Custom Visible", definition: """
            ---
            name: custom-visible
            description: Custom
            ---

            # Custom
            """),
            attribution: .init(actorID: "certificate:visibility-test", actorLabel: "Visibility Test", channel: "test")
        )
        let custom = try XCTUnwrap(created.workflows.first { $0.source == .custom })
        XCTAssertTrue(custom.visible)
        do {
            _ = try await authority.setWorkflowVisibility(
                workflowID: custom.workflowID,
                request: .init(expectedRevision: created.revision, expectedRowRevision: custom.rowRevision, visible: false),
                attribution: .init(actorID: "certificate:visibility-test", actorLabel: "Visibility Test", channel: "test")
            )
            XCTFail("expected custom hide to be rejected")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
        }

        let runner = StructuredStartProviderRunner()
        let configuration = ProviderCLIConfiguration(kind: .codex, executable: "/usr/bin/swift", expectedVersion: "6.2")
        let settings = ProviderSettingsService(
            store: store,
            adapter: ProviderCLIAdapter(configurations: [configuration], enabledProviders: [.codex], runner: runner),
            configurations: [configuration],
            initiallyEnabled: [.codex],
            runner: runner
        )
        try await settings.bootstrap()
        let catalog = AgentComposerCatalogService(providerSettings: settings, store: store)
        let snapshot = try await catalog.snapshot(context: .init(kind: .project, projectID: UUID(), actorID: "visibility-reader"))
        XCTAssertFalse(snapshot.workflows.contains { $0.id == "rp-build" })
        XCTAssertFalse(snapshot.workflows.contains { $0.id == "rp-review" })
        XCTAssertTrue(snapshot.workflows.contains { $0.id == "rp-orchestrate" })
        XCTAssertTrue(snapshot.emptyState.featuredWorkflowIDs.isEmpty)
    }

    func testCustomWorkflowWrapsArgumentsAndOmitsCleanup() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let authority = RepoPromptHeadlessAuthority(store: store)
        try await authority.recover()
        let initial = try await authority.workflowRepositorySnapshot()
        let created = try await authority.createWorkflow(
            .init(expectedRevision: initial.revision, name: "Custom Review", definition: """
            ---
            name: custom-review
            description: Review selected context
            ---

            Review: $ARGUMENTS
            """),
            attribution: .init(actorID: "certificate:wrap-test", actorLabel: "Wrap Test", channel: "test")
        )
        let custom = try XCTUnwrap(created.workflows.first { $0.source == .custom })
        let wrapped = try await authority.wrapWorkflowUserText(workflowID: custom.workflowID, userText: "auth bug")
        XCTAssertTrue(wrapped.contains("Review: auth bug"))
        XCTAssertFalse(wrapped.contains("$ARGUMENTS"))
        XCTAssertFalse(wrapped.contains("### Session cleanup guidance"))
        XCTAssertFalse(wrapped.contains("---\nname: custom-review"))

        let builtin = try await authority.wrapWorkflowUserText(workflowID: "rp-review", userText: "auth bug")
        XCTAssertTrue(builtin.contains("auth bug"))
        XCTAssertFalse(builtin.contains("$ARGUMENTS"))
        XCTAssertTrue(builtin.contains("### Session cleanup guidance"))
    }

    func testDurableProviderCatalogRemainsVisibleDuringTransientRuntimeFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let modelID = "gpt-5.6-sol"
        let catalogURL = root.appendingPathComponent("codex-models.json")
        try JSONEncoder.serviceEncoder.encode([
            ProviderModelCatalogEntry(
                id: modelID,
                providerRawValue: modelID,
                displayName: "GPT-5.6 Sol",
                isProviderDefault: true,
                reasoningEfforts: ["low", "high"],
                defaultReasoningEffort: "high",
                supportsNativeImages: true,
                supportsSteering: true
            )
        ]).write(to: catalogURL)
        _ = try await store.upsertProviderSettings(
            ProviderSettingsPreference(providerID: .codex, enabled: true, defaultModel: modelID, reasoningEffort: "high", revision: 1),
            expectedRevision: 0
        )
        let instant = Date(timeIntervalSince1970: 1_786_400_000)
        let connection = ProviderConnectionRecord(
            connectionID: UUID(),
            providerID: .codex,
            authenticationMethod: .deviceCodeBeta,
            state: .attention,
            accountLabel: "sandbox",
            lastTestedAt: instant,
            testState: .unavailable,
            detail: "Authentication status is temporarily unavailable",
            keyHelperConfigured: false,
            workloadIdentityConfigured: false,
            createdAt: instant,
            updatedAt: instant,
            revision: 1
        )
        _ = try await store.upsertProviderConnection(.init(record: connection, credentialReference: nil), expectedRevision: 0)
        let runner = StructuredStartProviderRunner()
        let configuration = ProviderCLIConfiguration(kind: .codex, executable: "/usr/bin/swift", expectedVersion: "6.2")
        let settings = ProviderSettingsService(
            store: store,
            adapter: ProviderCLIAdapter(configurations: [configuration], enabledProviders: [.codex], runner: runner),
            configurations: [configuration],
            initiallyEnabled: [.codex],
            modelCatalogFiles: [.codex: catalogURL.path],
            runner: runner
        )
        try await settings.bootstrap()
        let beforeRefresh = try await settings.catalog()
        let codex = try XCTUnwrap(beforeRefresh.providers.first { $0.providerID == .codex })
        XCTAssertTrue(codex.runtimePreflightVerified)
        XCTAssertFalse(codex.preflight.ready)
        XCTAssertEqual(codex.authentication.state, .attention)

        let snapshot = try await AgentComposerCatalogService(providerSettings: settings, store: store).snapshot(
            context: .init(kind: .project, projectID: UUID(), actorID: "catalog-reader")
        )

        let group = try XCTUnwrap(snapshot.providerGroups.first { $0.providerID == .codex })
        XCTAssertEqual(group.models.first?.id, modelID)
        XCTAssertTrue(group.models.contains { $0.id == "gpt-5.6-sol-fast" })
        XCTAssertNotNil(group.permissionControl)
        XCTAssertFalse(group.toolControls.isEmpty)
    }

    func testProviderMatrixAndDiscoveryPoliciesAreExact() throws {
        XCTAssertEqual(AgentComposerProviderMatrix.entries.map(\.providerID), [.codex, .claudeCompatible, .claudeGLM, .claudeKimi, .claudeCustom, .openCodeACP, .cursorACP, .grokBuildACP, .openAIAPI, .anthropicAPI, .openRouter, .customOpenAICompatible, .gemini, .azure, .deepseek, .fireworks, .xAI, .groq, .zAI, .ollama])
        XCTAssertEqual(AgentComposerProviderMatrix.liveFreshnessSeconds, 900)
        XCTAssertEqual(AgentComposerProviderMatrix.persistedFallbackMaximumAgeSeconds, 86_400)

        let packages = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = packages.appendingPathComponent("RepoPromptPortableRuntime/Tests/Fixtures/AgentParity/v1/provider-matrix.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any]
        XCTAssertEqual((object?["providers"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, AgentComposerProviderMatrix.entries.map { $0.providerID.rawValue })
    }

    func testSharedAuthorityAndHeadlessProjectionHaveByteSemanticParityAcrossProviderStates() async throws {
        let instant = Date(timeIntervalSince1970: 1_786_400_000)
        let liveOnly = ProviderDiscoveryPolicy(allowsPersistedFallback: false, allowsStaticFallbackAfterSuccessfulPreflight: false, discoveryReplacesStaticChoices: true)
        let cached = ProviderDiscoveryPolicy(allowsPersistedFallback: true, allowsStaticFallbackAfterSuccessfulPreflight: false, discoveryReplacesStaticChoices: true)
        let discoveredWithFallback = ProviderDiscoveryPolicy(allowsPersistedFallback: true, allowsStaticFallbackAfterSuccessfulPreflight: true, discoveryReplacesStaticChoices: false)
        let codexTools = ProviderComposerStableControls.descriptors(providerID: .codex, values: ["codex.goals": .boolean(false)], mutable: true, lockReasonCode: nil)
        let codexPermission = ProviderComposerStableControls.permissionDescriptor(providerID: .codex, selectedID: "codex.defaultPermission", mutable: true, lockReasonCode: nil)
        let claudeTools = ProviderComposerStableControls.descriptors(providerID: .claudeCompatible, values: ["claude.bash": .boolean(false)], mutable: true, lockReasonCode: nil)
        let claudePermission = ProviderComposerStableControls.permissionDescriptor(providerID: .claudeCompatible, selectedID: "claude.requireApproval", mutable: true, lockReasonCode: nil)
        let states: [AgentCatalogProviderState] = [
            .init(
                providerID: .codex,
                displayName: "Codex discovered",
                enabled: true,
                configured: true,
                preflightReady: true,
                discoveryPolicy: liveOnly,
                modelSources: [.init(kind: .live, observedAt: instant, models: [
                    .init(modelID: "codex-dynamic", rawValue: "provider/codex-low", displayName: "Codex Dynamic", variantEffortID: "low", supportedEffortIDs: ["low"], capabilities: .init(nativeImages: true, steering: true)),
                    .init(modelID: "codex-dynamic", rawValue: "provider/codex-xhigh", displayName: "Codex Dynamic", variantEffortID: "xhigh", supportedEffortIDs: ["xhigh"], defaultEffortID: "xhigh", isProviderDefault: true, capabilities: .init(nativeImages: true, steering: true))
                ])],
                preferredModelID: "codex-dynamic",
                preferredEffortID: "xhigh",
                toolControls: codexTools,
                permissionControl: codexPermission
            ),
            .init(
                providerID: .claudeCompatible,
                displayName: "Claude runtime catalog",
                enabled: true,
                configured: true,
                preflightReady: true,
                discoveryPolicy: liveOnly,
                modelSources: [.init(kind: .live, observedAt: instant, models: [
                    .init(modelID: "claude-runtime", rawValue: "claude-runtime", displayName: "Claude Runtime", capabilities: .init(nativeImages: true))
                ])],
                toolControls: claudeTools,
                permissionControl: claudePermission
            ),
            .init(
                providerID: .openAIAPI,
                displayName: "Direct API",
                enabled: true,
                configured: true,
                preflightReady: true,
                discoveryPolicy: liveOnly,
                modelSources: [.init(kind: .live, observedAt: instant, models: [
                    .init(modelID: "direct-model", rawValue: "direct-model", displayName: "Direct Model", supportedEffortIDs: ["low", "high"], defaultEffortID: "low")
                ])]
            ),
            .init(
                providerID: .openRouter,
                displayName: "Fresh cached API",
                enabled: true,
                configured: true,
                preflightReady: true,
                discoveryPolicy: cached,
                modelSources: [.init(kind: .persisted, observedAt: instant.addingTimeInterval(-300), models: [
                    .init(modelID: "cached-model", rawValue: "cached-model", displayName: "Cached Model")
                ])]
            ),
            .init(
                providerID: .openCodeACP,
                displayName: "ACP discovered plus provider fallback",
                enabled: true,
                configured: true,
                preflightReady: true,
                discoveryPolicy: discoveredWithFallback,
                modelSources: [
                    .init(kind: .live, observedAt: instant, models: [.init(modelID: "acp-discovered", rawValue: "acp/discovered", displayName: "ACP Discovered")]),
                    .init(kind: .providerFallback, models: [.init(modelID: "acp-provider-fallback", rawValue: "acp/fallback", displayName: "ACP Provider Fallback")])
                ]
            ),
            .init(providerID: .cursorACP, displayName: "Disabled", enabled: false, configured: true, preflightReady: true, discoveryPolicy: liveOnly, modelSources: [.init(kind: .live, observedAt: instant, models: [.init(modelID: "must-not-appear", rawValue: "disabled", displayName: "Disabled")])]),
            .init(providerID: .anthropicAPI, displayName: "Unhealthy", enabled: true, configured: true, preflightReady: false, discoveryPolicy: liveOnly, modelSources: [.init(kind: .live, observedAt: instant, models: [.init(modelID: "must-not-appear", rawValue: "unhealthy", displayName: "Unhealthy")])]),
            .init(providerID: .customOpenAICompatible, displayName: "Empty", enabled: true, configured: true, preflightReady: true, discoveryPolicy: cached, modelSources: []),
            .init(providerID: .xAI, displayName: "Stale cached API", enabled: true, configured: true, preflightReady: true, discoveryPolicy: cached, modelSources: [.init(kind: .persisted, observedAt: instant.addingTimeInterval(-86_401), models: [.init(modelID: "must-not-appear", rawValue: "stale", displayName: "Stale")])])
        ]
        let expected = AgentCatalogAuthority.resolve(providers: states, storedSelection: nil, context: .init(now: instant, activeRun: true))
        XCTAssertEqual(expected.providers.map(\.providerID), [.codex, .claudeCompatible, .openAIAPI, .openRouter, .openCodeACP])
        XCTAssertEqual(expected.providers[0].models[0].descriptor.supportedEffortIDs, ["low", "xhigh"])
        XCTAssertEqual(expected.providers[0].models[0].descriptor.defaultEffortID, "xhigh")
        XCTAssertEqual(expected.providers[0].models[0].descriptor.providerRawValue, "provider/codex-xhigh")
        XCTAssertEqual(expected.providers[0].models[0].descriptor(selectingEffortID: "low").providerRawValue, "provider/codex-low")
        XCTAssertTrue(expected.providers.flatMap(\.toolControls).allSatisfy(Self.isActiveRunLocked))
        XCTAssertTrue(expected.providers.compactMap(\.permissionControl).allSatisfy { $0.mutable && $0.lockReasonCode == nil })

        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let runner = StructuredStartProviderRunner()
        let settings = ProviderSettingsService(store: store, adapter: ProviderCLIAdapter(configurations: [], enabledProviders: [], runner: runner), configurations: [], initiallyEnabled: [], runner: runner)
        let service = AgentComposerCatalogService(providerSettings: settings, store: store, providerStateLoader: { _ in states }, now: { instant })
        let actual = try await service.snapshot(context: .init(kind: .project, projectID: UUID(), actorID: "parity", activeRun: true))
        let expectedGroups = expected.providers.map(Self.wireGroup)
        XCTAssertEqual(try JSONEncoder.serviceEncoder.encode(actual.providerGroups), try JSONEncoder.serviceEncoder.encode(expectedGroups))
        XCTAssertEqual(actual.selected?.providerID, expected.selection?.providerID)
        XCTAssertEqual(actual.selected?.modelID, expected.selection?.modelID)
        XCTAssertEqual(actual.selected?.effortID, expected.selection?.effortID)
        XCTAssertEqual(actual.selected?.permissionID, expected.selection?.permissionID)
        XCTAssertEqual(actual.selected?.toolValues, expected.selection?.toolValues.mapValues(Self.wireValue))
        XCTAssertTrue(actual.locks.tools.locked)
        XCTAssertEqual(actual.locks.tools.reasonCode, "active_run")
        XCTAssertFalse(actual.locks.permissions.locked)
        XCTAssertNil(actual.locks.permissions.reasonCode)

        let unavailable = AgentCatalogAuthority.resolve(
            providers: states,
            storedSelection: .init(providerID: .xAI, modelID: "stale-selection", effortID: "high", permissionID: "preserved", toolValues: ["preserved": .boolean(true)]),
            context: .init(now: instant, externallyControlled: true)
        )
        XCTAssertEqual(unavailable.selection?.unavailable, true)
        XCTAssertEqual(unavailable.selection?.modelID, "stale-selection")
        XCTAssertEqual(unavailable.selection?.effortID, "high")
        XCTAssertEqual(unavailable.selection?.permissionID, "preserved")
        XCTAssertEqual(unavailable.selection?.toolValues, ["preserved": .boolean(true)])
    }

    private static func isActiveRunLocked(_ control: ProviderComposerControlDescriptor) -> Bool {
        switch control {
        case let .toggle(_, _, _, _, _, mutable, _, reason),
             let .singleChoice(_, _, _, _, _, _, mutable, _, reason),
             let .multiChoice(_, _, _, _, _, _, mutable, _, reason):
            return !mutable && reason == "active_run"
        }
    }

    private static func wireGroup(_ provider: AgentCatalogResolvedProvider) -> ComposerProviderGroupWire {
        .init(
            providerID: provider.providerID,
            displayName: provider.displayName,
            models: provider.models.map {
                .init(id: $0.descriptor.modelID, displayName: $0.descriptor.displayName, description: $0.descriptor.description, supportedEffortIDs: $0.descriptor.supportedEffortIDs, defaultEffortID: $0.descriptor.defaultEffortID, capabilities: .init(nativeImages: $0.descriptor.capabilities.nativeImages, steering: $0.descriptor.capabilities.steering))
            },
            toolControls: provider.toolControls.map { control in
                switch control {
                case let .toggle(id, name, detail, value, required, mutable, warning, reason): .toggle(common: .init(id: id, displayName: name, detailText: detail, required: required, mutable: mutable, warning: warning, lockReasonCode: reason), value: value)
                case let .singleChoice(id, name, detail, selected, choices, required, mutable, warning, reason): .singleChoice(common: .init(id: id, displayName: name, detailText: detail, required: required, mutable: mutable, warning: warning, lockReasonCode: reason), selectedID: selected, choices: choices.map { .init(id: $0.id, displayName: $0.displayName, detailText: $0.detailText, enabled: $0.enabled, warning: $0.warning) })
                case let .multiChoice(id, name, detail, selected, choices, required, mutable, warning, reason): .multiChoice(common: .init(id: id, displayName: name, detailText: detail, required: required, mutable: mutable, warning: warning, lockReasonCode: reason), selectedIDs: selected, choices: choices.map { .init(id: $0.id, displayName: $0.displayName, detailText: $0.detailText, enabled: $0.enabled, warning: $0.warning) })
                }
            },
            permissionControl: provider.permissionControl.map { permission in
                .init(id: permission.id, displayName: permission.displayName, selectedID: permission.selectedID, choices: permission.choices.map { .init(id: $0.id, displayName: $0.displayName, detailText: $0.detailText, enabled: $0.enabled, warning: $0.warning) }, externallyManaged: permission.externallyManaged, mutable: permission.mutable, lockReasonCode: permission.lockReasonCode)
            }
        )
    }

    private static func wireValue(_ value: AgentControlValue) -> ComposerControlValueWire {
        switch value {
        case let .boolean(value): .boolean(value)
        case let .choice(value): .choice(value)
        case let .choices(value): .choices(value)
        }
    }

    func testCodexAdapterRejectsUnknownControlsAndKeepsRequiredRepoPromptMCP() throws {
        let model = ProviderModelDescriptor(providerID: .codex, modelID: "gpt-5.6-sol-fast", providerRawValue: "gpt-5.6-sol", displayName: "GPT-5.6 Sol Fast", supportedEffortIDs: ["high"], defaultEffortID: "high", serviceTier: "fast", capabilities: .init(nativeImages: true, steering: true))
        let adapter = CodexTurnConfigurationAdapter()
        let compiled = try adapter.compile(.init(providerID: .codex, model: model, effortID: "high", permissionID: "codex.defaultPermission", toolValues: ["codex.mcpServers": .choices([])]))
        XCTAssertEqual(compiled.providerRawModelValue, "gpt-5.6-sol")
        XCTAssertEqual(compiled.executionPolicy.providerSettings["provider.serviceTier"], "fast")
        XCTAssertNil(compiled.executionPolicy.providerSettings["codex.enabledMCPServers"])
        XCTAssertEqual(compiled.normalizedToolValues["codex.mcpServers"], .choices(["repoprompt"]))
        XCTAssertEqual(compiled.executionPolicy.providerSettings["provider.permissionId"], "codex.defaultPermission")
        XCTAssertEqual(compiled.executionPolicy.providerSettings["codex.approvalsReviewer"], "user")
        let autoReview = try adapter.compile(.init(providerID: .codex, model: model, effortID: "high", permissionID: "codex.autoReview", toolValues: ["codex.mcpServers": .choices([])]))
        XCTAssertEqual(autoReview.executionPolicy.mode, .workspaceWrite)
        XCTAssertEqual(autoReview.executionPolicy.providerSettings["provider.permissionId"], "codex.autoReview")
        XCTAssertEqual(autoReview.executionPolicy.providerSettings["codex.approvalsReviewer"], "auto_review")
        XCTAssertThrowsError(try adapter.compile(.init(providerID: .codex, model: model, toolValues: ["codex.unknown": .boolean(true)])))
    }

    func testDirectAPIAdaptersFollowAuthoritativeCatalogsAndExactRuntimeIdentity() throws {
        let cases: [(ProviderSettingsID, String, [String])] = [
            (.openAIAPI, "gpt-direct", ["low", "medium", "high", "xhigh", "max"]),
            (.anthropicAPI, "claude-direct", []),
            (.openRouter, "router/direct", ["low", "medium", "high", "xhigh", "max"]),
            (.customOpenAICompatible, "custom-direct", ["low", "medium", "high", "xhigh", "max"])
        ]
        let adapters = ProviderTurnConfigurationAdapters.builtIn()

        for (providerID, rawModelID, catalogEfforts) in cases {
            let matrix = try XCTUnwrap(AgentComposerProviderMatrix.entry(for: providerID))
            XCTAssertEqual(matrix.runtimeKind, .headlessAdapter)
            XCTAssertTrue(matrix.discoveryPolicy.allowsPersistedFallback)
            XCTAssertFalse(matrix.discoveryPolicy.allowsStaticFallbackAfterSuccessfulPreflight)
            XCTAssertTrue(matrix.discoveryPolicy.discoveryReplacesStaticChoices)
            XCTAssertNil(ProviderComposerStableControls.permissionDescriptor(providerID: providerID, selectedID: nil, mutable: true, lockReasonCode: nil))

            let adapter = try XCTUnwrap(adapters[providerID])
            let selectedEffort = catalogEfforts.first
            let model = ProviderModelDescriptor(
                providerID: providerID,
                modelID: rawModelID,
                providerRawValue: rawModelID,
                displayName: rawModelID,
                supportedEffortIDs: catalogEfforts,
                defaultEffortID: selectedEffort
            )
            let compiled = try adapter.compile(.init(providerID: providerID, model: model, effortID: selectedEffort))
            XCTAssertEqual(compiled.runtimeKind, .headlessAdapter)
            XCTAssertEqual(compiled.providerRawModelValue, rawModelID)
            XCTAssertEqual(compiled.executionPolicy.mode, .workspaceWrite)
            XCTAssertEqual(compiled.executionPolicy.providerSettings["provider.settingsID"], providerID.rawValue)
            XCTAssertEqual(compiled.executionPolicy.providerSettings["provider.reasoningEffort"], selectedEffort)
            XCTAssertFalse(compiled.supportsNativeImages)
            XCTAssertTrue(compiled.normalizedToolValues.isEmpty)

            XCTAssertThrowsError(try adapter.compile(.init(providerID: providerID, model: model, effortID: "not-in-catalog")))
            XCTAssertThrowsError(try adapter.compile(.init(providerID: providerID, model: model, permissionID: "filesystem.fullAccess")))
            XCTAssertThrowsError(try adapter.compile(.init(providerID: providerID, model: model, toolValues: ["direct.unknown": .boolean(true)])))
            let mismatched = ProviderModelDescriptor(providerID: .codex, modelID: rawModelID, providerRawValue: rawModelID, displayName: rawModelID)
            XCTAssertThrowsError(try adapter.compile(.init(providerID: providerID, model: mismatched)))
        }
    }

    func testGrokBuildAdapterPassesDesktopSessionSetModelEffort() throws {
        let adapter = try XCTUnwrap(ProviderTurnConfigurationAdapters.builtIn()[.grokBuildACP])
        let model = ProviderModelDescriptor(
            providerID: .grokBuildACP,
            modelID: "grok-code",
            providerRawValue: "grok-code",
            displayName: "Grok Code",
            supportedEffortIDs: ["low", "high"],
            defaultEffortID: "low"
        )
        let compiled = try adapter.compile(.init(providerID: .grokBuildACP, model: model, effortID: "high", permissionID: "grok.managedDefault"))
        XCTAssertEqual(compiled.runtimeKind, .grokBuildACP)
        XCTAssertEqual(compiled.executionPolicy.mode, .workspaceWrite)
        XCTAssertEqual(compiled.executionPolicy.providerSettings["provider.permissionId"], "grok.managedDefault")
        XCTAssertEqual(compiled.executionPolicy.providerSettings["provider.reasoningEffort"], "high")
        XCTAssertThrowsError(try adapter.compile(.init(providerID: .grokBuildACP, model: model, effortID: "not-in-catalog")))
        let fullAccess = try adapter.compile(.init(providerID: .grokBuildACP, model: model, permissionID: "grok.fullAccess"))
        XCTAssertEqual(fullAccess.executionPolicy.mode, .fullAccess)
        XCTAssertEqual(fullAccess.executionPolicy.providerSettings["provider.reasoningEffort"], "low")
    }
}

final class AgentComposerWireContractTests: XCTestCase {
    func testClosedUnionsRoundTripAndRejectUnknownDiscriminator() throws {
        let value = ComposerControlWire.multiChoice(common: .init(id: "codex.mcpServers", displayName: "MCP servers", required: true), selectedIDs: ["repoprompt"], choices: [.init(id: "repoprompt", displayName: "RepoPrompt")])
        XCTAssertEqual(try JSONDecoder.serviceDecoder.decode(ComposerControlWire.self, from: JSONEncoder.serviceEncoder.encode(value)), value)
        XCTAssertThrowsError(try JSONDecoder.serviceDecoder.decode(ComposerControlValueWire.self, from: Data(#"{"type":"text","value":true}"#.utf8)))
    }

    func testLegacyModelCatalogPayloadStillDecodes() throws {
        let legacy = Data(#"{"id":"gpt-5.6-sol","provider":"codex","displayName":"Sol","enabled":true}"#.utf8)
        let decoded = try JSONDecoder.serviceDecoder.decode(ModelCatalogItem.self, from: legacy)
        XCTAssertEqual(decoded.id, "gpt-5.6-sol")
        XCTAssertNil(decoded.providerID)
        XCTAssertNil(decoded.supportedEffortIDs)
    }

    func testSessionSnapshotAgentStateFieldsAreAdditiveAndVersioned() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionID = UUID(), projectID = UUID(), runID = UUID()
        let actor = ExternalActor(userID: "actor-1", username: "actor", displayName: "Actor")
        let configuration = EffectiveTurnConfigurationWireSnapshot(testConfiguration(at: now))
        let defaults = SessionNextTurnDefaultsWireSnapshot(sessionID: sessionID, revision: 3, configuration: configuration, updatedAt: now)
        let presentation = RunPresentationWireSnapshot(sessionID: sessionID, runID: runID, generation: 2, turnEpoch: 2, phase: .waiting, phaseRevision: 4, runningStatusCode: "awaiting_input", runStartedAt: now, priorActivePhase: .working)
        let enriched = SessionSnapshot(sessionID: sessionID, projectID: projectID, parentSessionID: nil, rootSessionID: sessionID, creator: actor, provider: .codex, model: "gpt-5.6-sol-high", visibility: .privateSession, state: .running, runGeneration: 2, turnEpoch: 2, revision: 7, transcript: [], interactions: [], cursor: .init(storeID: UUID(), globalSequence: 9), effectiveTurnConfiguration: configuration, nextTurnDefaults: defaults, runPresentation: presentation)
        let decoded = try JSONDecoder.serviceDecoder.decode(SessionSnapshot.self, from: JSONEncoder.serviceEncoder.encode(enriched))
        XCTAssertEqual(decoded.effectiveTurnConfiguration?.schemaVersion, 1)
        XCTAssertEqual(decoded.nextTurnDefaults?.revision, 3)
        XCTAssertEqual(decoded.runPresentation?.phaseRevision, 4)
        XCTAssertEqual(decoded.runPresentation?.phase, .waiting)

        let legacy = SessionSnapshot(sessionID: sessionID, projectID: projectID, parentSessionID: nil, rootSessionID: sessionID, creator: actor, provider: .codex, model: nil, visibility: .privateSession, state: .idle, runGeneration: 0, turnEpoch: 0, revision: 1, transcript: [], interactions: [], cursor: .init(storeID: UUID(), globalSequence: 1))
        let legacyDecoded = try JSONDecoder.serviceDecoder.decode(SessionSnapshot.self, from: JSONEncoder.serviceEncoder.encode(legacy))
        XCTAssertNil(legacyDecoded.effectiveTurnConfiguration)
        XCTAssertNil(legacyDecoded.nextTurnDefaults)
        XCTAssertNil(legacyDecoded.runPresentation)
        XCTAssertNil(legacyDecoded.contextUsage)

        let usage = ContextUsageWireSnapshot(modelContextWindow: 200_000, lastTotalTokens: 12_345, totalTotalTokens: 12_345)
        let withUsage = SessionSnapshot(sessionID: sessionID, projectID: projectID, parentSessionID: nil, rootSessionID: sessionID, creator: actor, provider: .codex, model: nil, visibility: .privateSession, state: .running, runGeneration: 1, turnEpoch: 1, revision: 2, transcript: [], interactions: [], cursor: .init(storeID: UUID(), globalSequence: 2), contextUsage: usage)
        let decodedUsage = try JSONDecoder.serviceDecoder.decode(SessionSnapshot.self, from: JSONEncoder.serviceEncoder.encode(withUsage))
        XCTAssertEqual(decodedUsage.contextUsage?.modelContextWindow, 200_000)
        XCTAssertEqual(decodedUsage.contextUsage?.lastTotalTokens, 12_345)
        let reconstructed = decodedUsage.replacing(interactions: [])
        XCTAssertEqual(reconstructed.contextUsage?.lastTotalTokens, 12_345)
    }
}

final class AgentComposerAttachmentStoreTests: XCTestCase {
    func testRasterOwnershipExpiryPreviewAndPreparationLease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let attachments = try AgentComposerAttachmentStore(store: store, configuration: .init(stagingRoot: root.appendingPathComponent("staged").path, acceptedRoot: root.appendingPathComponent("accepted").path, maximumStagedBytesPerActor: 512, maximumGlobalStagedBytes: 1_024, minimumFreeBytes: 0))
        let projectID = UUID()
        let staged = try await attachments.stage(data: tinyPNG(), displayName: "../bad\u{0}name.png", declaredMediaType: "image/png", actorID: "owner", projectID: projectID)
        XCTAssertEqual(staged.pixelWidth, 1)
        XCTAssertFalse(staged.displayName.contains("/"))
        let foreignResolution = try await attachments.resolve(attachmentIDs: [staged.attachmentID], actorID: "other", projectID: projectID)
        XCTAssertEqual(foreignResolution.first?.errorCode, "resource_owner_mismatch")
        let wrongProjectResolution = try await attachments.resolve(attachmentIDs: [staged.attachmentID], actorID: "owner", projectID: UUID())
        XCTAssertEqual(wrongProjectResolution.first?.errorCode, "resource_context_mismatch")
        let opaqueResolution = try await attachments.resolve(attachmentIDs: [staged.attachmentID], actorID: "other", projectID: UUID())
        XCTAssertEqual(opaqueResolution.first?.errorCode, "forbidden")
        let expiring = try await attachments.stage(data: tinyPNG(), displayName: "expired.png", declaredMediaType: "image/png", actorID: "owner", projectID: projectID, now: Date(timeIntervalSince1970: 100))
        let expiredResolution = try await attachments.resolve(attachmentIDs: [expiring.attachmentID], actorID: "owner", projectID: projectID, now: Date(timeIntervalSince1970: 100 + 86_401))
        XCTAssertEqual(expiredResolution.first?.errorCode, "expired_resource")
        do {
            _ = try await attachments.preview(attachmentID: staged.attachmentID, actorID: "other", projectID: projectID)
            XCTFail("Cross-owner preview must remain opaque")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .notFound)
        }
        let preview = try await attachments.preview(attachmentID: staged.attachmentID, actorID: "owner", projectID: projectID)
        XCTAssertEqual(preview.1, tinyPNG())

        do {
            _ = try await attachments.prepareAcceptance(attachmentIDs: [staged.attachmentID], submissionID: UUID(), actorID: "other", projectID: projectID, sessionID: UUID(), turnID: UUID(), supportsNativeImages: true)
            XCTFail("Cross-owner claim must fail with a stable code")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .resourceOwnerMismatch)
        }
        do {
            _ = try await attachments.prepareAcceptance(attachmentIDs: [staged.attachmentID], submissionID: UUID(), actorID: "owner", projectID: UUID(), sessionID: UUID(), turnID: UUID(), supportsNativeImages: true)
            XCTFail("Cross-project claim must fail with a stable code")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .resourceContextMismatch)
        }
        do {
            _ = try await attachments.prepareAcceptance(attachmentIDs: [expiring.attachmentID], submissionID: UUID(), actorID: "owner", projectID: projectID, sessionID: UUID(), turnID: UUID(), supportsNativeImages: true)
            XCTFail("Expired claim must fail with a stable code")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .expiredResource)
        }

        let submissionID = UUID(), sessionID = UUID(), turnID = UUID()
        let manifest = try await attachments.prepareAcceptance(attachmentIDs: [staged.attachmentID], submissionID: submissionID, actorID: "owner", projectID: projectID, sessionID: sessionID, turnID: turnID, supportsNativeImages: true)
        XCTAssertEqual(manifest.attachments.map(\.attachmentID), [staged.attachmentID])
        XCTAssertEqual(manifest.nativeImages.count, 1)
        try await attachments.releasePreparation(submissionID: submissionID)
        let released = try await store.composerAttachment(attachmentID: staged.attachmentID)
        XCTAssertNil(released?.leaseSubmissionID)
        try await store.close()
    }

    func testRejectsMediaMismatchAndActorQuota() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let attachments = try AgentComposerAttachmentStore(store: store, configuration: .init(stagingRoot: root.appendingPathComponent("staged").path, acceptedRoot: root.appendingPathComponent("accepted").path, maximumStagedBytesPerActor: tinyPNG().count, maximumGlobalStagedBytes: 1_000, minimumFreeBytes: 0))
        await XCTAssertThrowsErrorAsync { try await attachments.stage(data: tinyPNG(), displayName: "x.jpg", declaredMediaType: "image/jpeg", actorID: "a", projectID: UUID()) }
        _ = try await attachments.stage(data: tinyPNG(), displayName: "x.png", declaredMediaType: nil, actorID: "a", projectID: UUID())
        await XCTAssertThrowsErrorAsync { try await attachments.stage(data: tinyPNG(), displayName: "y.png", declaredMediaType: nil, actorID: "a", projectID: UUID()) }
        try await store.close()
    }
}

private struct TestTaggedResolver: AgentTurnTaggedFileResolving {
    func resolve(_ reference: ComposerTaggedFileReferenceWire, projectID: UUID, sessionID: UUID?) async throws -> ResolvedTaggedFile {
        .init(reference: reference, logicalLabel: reference.logicalPath, content: "let fixture = true")
    }
}

private struct TestSuggestionResolver: AgentTurnSuggestionResolving {
    func resolve(_ token: ComposerResolvedSuggestionTokenWire, providerID: ProviderSettingsID, catalogRevision: String) async throws -> ResolvedComposerSuggestion {
        token.kind == .skill ? .init(token: token, expansion: "skill instructions") : .init(token: token, nativeInvocation: "native invocation")
    }
}

final class AgentTurnIntentCompilerTests: XCTestCase {
    func testDeterministicSectionOrderAndSeparateNativeImages() async throws {
        let identity = testIdentity(), config = testConfiguration(), attachmentID = UUID()
        let file = ComposerTaggedFileReferenceWire(rootID: UUID(), logicalPath: "Sources/A.swift", displayName: "A.swift")
        let skill = ComposerResolvedSuggestionTokenWire(kind: .skill, id: "review", insertionText: "/review")
        let command = ComposerResolvedSuggestionTokenWire(kind: .nativeCommand, id: "compact", insertionText: "/compact")
        let wireAttachment = ComposerAttachmentWire(attachmentID: attachmentID, displayName: "x.png", mediaType: "image/png", byteSize: tinyPNG().count, digest: "digest", pixelWidth: 1, pixelHeight: 1, lifecycle: .staged)
        let native = ProviderNativeImageDescriptor(attachmentID: attachmentID, mediaType: "image/png", byteSize: tinyPNG().count, digest: "digest", filePath: "/private/accepted/x.png")
        let provider = CompiledProviderTurnConfiguration(runtimeKind: .codex, providerRawModelValue: "gpt-5.6-sol-high", executionPolicy: .init(), supportsNativeImages: true, normalizedToolValues: [:])
        let compiler = AgentTurnIntentCompiler(taggedFiles: TestTaggedResolver(), suggestions: TestSuggestionResolver())
        let result = try await compiler.compile(.init(projectID: UUID(), sessionID: UUID(), identity: identity, content: .init(text: "literal text", attachmentIDs: [attachmentID], taggedFiles: [file], resolvedSuggestionTokens: [skill, command]), effectiveConfiguration: config, providerConfiguration: provider, attachmentManifest: .init(attachments: [wireAttachment], nativeImages: [native]), continuationContext: "handoff", providerPromptWrapper: "wrapper", workflowGuidance: "workflow", goalGuidance: "goal"))
        let prompt = result.providerInput.prompt
        let markers = ["continuation-context", "provider-instructions", "workflow-guidance", "goal-guidance", "skill review", "native command compact", "tagged-file", "user-request"]
        let positions = markers.compactMap { prompt.range(of: $0)?.lowerBound }.map { prompt.distance(from: prompt.startIndex, to: $0) }
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertEqual(result.providerInput.nativeImages, [native])
        XCTAssertFalse(result.canonicalUserTurn.text.contains("skill instructions"))
    }

    func testStructuredFirstTurnFreezesSelectedMessageContextForCanonicalAndProviderInput() async throws {
        let context = SelectedMessageContext(source: "explicit-selection", messages: [
            .init(roomID: "room-1", messageID: "message-1", text: "Exact selected chat text", senderID: "sender-1", timestamp: "2026-08-12T12:00:00Z", revision: "7", threadID: "thread-1")
        ])
        let provider = CompiledProviderTurnConfiguration(runtimeKind: .codex, providerRawModelValue: "gpt-5.6-sol-high", executionPolicy: .init(), supportsNativeImages: true, normalizedToolValues: [:])
        let compiler = AgentTurnIntentCompiler()
        let result = try await compiler.compile(.init(projectID: UUID(), sessionID: nil, identity: testIdentity(), content: .init(text: "Investigate the regression"), selectedMessageContext: context, effectiveConfiguration: testConfiguration(), providerConfiguration: provider))
        let frozen = context.frozenPrompt(userPrompt: "Investigate the regression")
        XCTAssertEqual(result.canonicalUserTurn.text, frozen)
        XCTAssertEqual(result.providerInput.prompt, frozen)
        XCTAssertTrue(result.canonicalUserTurn.taggedFiles.isEmpty)
    }

    func testSnapshotTitlesPreferAgentLabelsAndFallBackToTheFirstUserPrompt() {
        let actor = ExternalActor(userID: "user", username: "alice", displayName: "Alice")
        let sessionID = UUID()
        let session = SessionSnapshot(
            sessionID: sessionID,
            projectID: UUID(),
            parentSessionID: nil,
            rootSessionID: sessionID,
            creator: actor,
            provider: .codex,
            model: "gpt-5.6-sol",
            visibility: .privateSession,
            state: .completed,
            runGeneration: 1,
            turnEpoch: 1,
            revision: 2,
            transcript: [
                .init(entryID: UUID(), sessionSequence: 1, kind: .human, content: "  Build   compact session cards  ", actor: actor, timestamp: Date())
            ],
            interactions: [],
            cursor: .init(storeID: UUID(), globalSequence: 1)
        )
        let agent = AgentSnapshot(
            agentID: sessionID,
            sessionID: sessionID,
            rootSessionID: sessionID,
            parentAgentID: nil,
            role: "root",
            label: "Polish agent session cards",
            state: .completed,
            revision: 2
        )

        XCTAssertEqual(
            RepoPromptPortalSessionProjection.snapshotTitles(sessions: [session], agents: [agent]),
            [sessionID.uuidString: "Polish agent session cards"]
        )
        XCTAssertEqual(
            RepoPromptPortalSessionProjection.snapshotTitles(sessions: [session], agents: []),
            [sessionID.uuidString: "Build compact session cards"]
        )
        let storeID = UUID()
        let snapshot = AuthoritativeSnapshot(
            storeID: storeID,
            projects: [],
            sessions: [session],
            cursor: .init(storeID: storeID, globalSequence: 1)
        )
        let encoded = try? JSONEncoder.serviceEncoder.encode(
            AuthoritativeWireSnapshot(snapshot, sessionTitles: [sessionID.uuidString: "Polish agent session cards"])
        )
        XCTAssertNotNil(encoded)
        XCTAssertTrue(encoded.map { String(decoding: $0, as: UTF8.self).contains("sessionTitles") } == true)
    }

    func testTextOnlyAdapterRejectsAttachmentBeforeAcceptance() async throws {
        let attachmentID = UUID()
        let wire = ComposerAttachmentWire(attachmentID: attachmentID, displayName: "x.png", mediaType: "image/png", byteSize: 24, digest: "d", pixelWidth: 1, pixelHeight: 1, lifecycle: .staged)
        let native = ProviderNativeImageDescriptor(attachmentID: attachmentID, mediaType: "image/png", byteSize: 24, digest: "d", filePath: "/x")
        let compiler = AgentTurnIntentCompiler()
        let provider = CompiledProviderTurnConfiguration(runtimeKind: .openCodeACP, providerRawModelValue: "model", executionPolicy: .init(), supportsNativeImages: false, normalizedToolValues: [:])
        await XCTAssertThrowsErrorAsync { try await compiler.compile(.init(projectID: UUID(), sessionID: nil, identity: testIdentity(), content: .init(text: "", attachmentIDs: [attachmentID]), effectiveConfiguration: testConfiguration(), providerConfiguration: provider, attachmentManifest: .init(attachments: [wire], nativeImages: [native]))) }
    }
}

final class AgentSubmissionCoordinatorTests: XCTestCase {
    func testOversizedPreparedProjectRootFenceIsRejectedBeforeBeginOrAdmission() async throws {
        let store = try await SQLiteServiceStore.openForExecutorSaturationTesting(
            storage: .memory,
            capacity: 32,
            reservedControlCapacity: 16,
            maximumAdmissionWaiters: 32,
            maximumProducerEncodedBytes: 1_048_576
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let identity = testIdentity()
        let sessionID = UUID()
        let submissionID = UUID()
        let actor = ExternalActor(userID: "actor-1", username: "actor", displayName: "Actor")
        let config = testConfiguration(at: now)
        let session = SessionSnapshot(
            sessionID: sessionID,
            projectID: UUID(),
            parentSessionID: nil,
            rootSessionID: sessionID,
            creator: actor,
            provider: .codex,
            model: "fake",
            visibility: .privateSession,
            state: .idle,
            runGeneration: 1,
            turnEpoch: 1,
            revision: 1,
            transcript: [],
            interactions: [],
            cursor: .init(storeID: UUID(), globalSequence: 0)
        )
        let record = AgentSubmissionRecord(
            submissionID: submissionID,
            actorID: actor.userID,
            targetKey: sessionID.uuidString,
            operation: "startSession",
            publicKey: submissionID.uuidString.lowercased(),
            requestDigest: "request-digest",
            state: .preparing,
            sessionID: sessionID,
            identity: identity,
            preparedJSON: Data("prepared".utf8),
            compiledInputJSON: Data("compiled".utf8),
            createdAt: now,
            updatedAt: now
        )
        let receipt = SubmissionReceipt(
            submissionID: submissionID,
            acceptedAt: now,
            operation: "startSession",
            sessionID: sessionID,
            sessionRevision: 1,
            requestAnchorID: identity.requestAnchorID,
            runID: identity.runID,
            generation: identity.generation,
            turnEpoch: identity.turnEpoch,
            runPhase: "preparing",
            runStartedAt: now,
            selectedConfiguration: .init(
                catalogRevision: config.catalogRevision,
                providerID: config.providerID,
                modelID: config.modelID,
                effortID: config.effortID,
                permissionID: config.permissionID
            ),
            session: session
        )
        let prepared = PreparedNewAgentSession(
            snapshot: session,
            agent: .init(
                agentID: sessionID,
                sessionID: sessionID,
                rootSessionID: sessionID,
                parentAgentID: nil,
                role: "root",
                state: .idle,
                revision: 1
            ),
            initialSelection: .init(sessionID: sessionID, entries: [], revision: 1),
            initialPermissions: .init(
                sessionID: sessionID,
                mode: "workspace-write",
                providerSettings: [:],
                revision: 1,
                updatedActor: actor
            ),
            initialCollaboration: .init(
                sessionID: sessionID,
                visibility: .privateSession,
                collaborativeSteeringEnabled: false,
                controllerUserID: actor.userID,
                policyRevision: 1,
                controllerRevision: 1,
                membershipRevision: 1
            ),
            expectedProjectRevision: 1,
            expectedProjectRootIDs: Array(repeating: UUID(), count: 30_000),
            sessionCorrelationID: UUID(),
            agentCorrelationID: UUID()
        )
        do {
            _ = try await store.authorityStore_commitAgentSubmission(
                record: record,
                turn: .init(
                    sessionID: sessionID,
                    identity: identity,
                    firstSequence: 1,
                    lastSequence: 1,
                    canonicalUserTurnJSON: Data("{}".utf8),
                    effectiveConfiguration: config,
                    createdAt: now,
                    acceptedAt: now
                ),
                nextDefaults: .init(sessionID: sessionID, revision: 1, configuration: config, updatedAt: now),
                runPresentation: .init(
                    sessionID: sessionID,
                    runID: identity.runID,
                    generation: 1,
                    turnEpoch: 1,
                    phase: .preparing,
                    phaseRevision: 1,
                    runStartedAt: now
                ),
                receipt: receipt,
                newSession: prepared
            )
            XCTFail("prepared project-root fence must be bounded before BEGIN")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .rateLimited)
        }
        let metrics = await store.database.metrics()
        XCTAssertEqual(metrics.queuedByClass.values.reduce(0, +), 0)
        XCTAssertEqual(metrics.waitingByClass.values.reduce(0, +), 0)
        try await store.close(clean: false)
    }

    func testAtomicAcceptanceStoresExactReceiptAndReplaysPreparedWinner() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let now = Date(timeIntervalSince1970: 1_700_000_000), identity = testIdentity(), sessionID = UUID(), submissionID = UUID()
        let config = testConfiguration(at: now)
        let canonical = CanonicalUserTurn(identity: identity, text: "hello", suggestionTokens: [], taggedFiles: [], attachments: [], effectiveConfiguration: config)
        let record = AgentSubmissionRecord(submissionID: submissionID, actorID: "actor-1", targetKey: sessionID.uuidString, operation: "submitTurn", publicKey: submissionID.uuidString.lowercased(), requestDigest: "request-digest", state: .preparing, sessionID: sessionID, identity: identity, preparedJSON: Data("prepared".utf8), compiledInputJSON: Data("compiled".utf8), createdAt: now, updatedAt: now)
        _ = try await store.prepareAgentSubmission(record)
        let receipt = SubmissionReceipt(submissionID: submissionID, acceptedAt: now, operation: "submitTurn", sessionID: sessionID, sessionRevision: 2, requestAnchorID: identity.requestAnchorID, runID: identity.runID, generation: identity.generation, turnEpoch: identity.turnEpoch, runPhase: "preparing", runStartedAt: now, selectedConfiguration: .init(catalogRevision: config.catalogRevision, providerID: config.providerID, modelID: config.modelID, effortID: config.effortID, permissionID: config.permissionID))
        _ = try await store.commitAgentSubmission(record: record, turn: .init(sessionID: sessionID, identity: identity, firstSequence: 1, lastSequence: 1, canonicalUserTurnJSON: JSONEncoder.serviceEncoder.encode(canonical), effectiveConfiguration: config, createdAt: now, acceptedAt: now), nextDefaults: .init(sessionID: sessionID, revision: 1, configuration: config, updatedAt: now), runPresentation: .init(sessionID: sessionID, runID: identity.runID, generation: 1, turnEpoch: 1, phase: .preparing, phaseRevision: 1, runStartedAt: now), receipt: receipt)
        let fetchedAccepted = try await store.agentSubmission(submissionID: submissionID)
        let accepted = try XCTUnwrap(fetchedAccepted)
        XCTAssertEqual(accepted.state, .accepted)
        XCTAssertEqual(accepted.receiptJSON, try JSONEncoder.serviceEncoder.encode(receipt))
        let replayed = try await store.prepareAgentSubmission(record)
        XCTAssertEqual(replayed.submissionID, submissionID)
        let turns = try await store.semanticTurns(sessionID: sessionID)
        XCTAssertEqual(turns.count, 1)
        let persistedConfiguration = try await store.effectiveTurnConfiguration(turnID: identity.turnID)
        XCTAssertNotNil(persistedConfiguration)
        try await store.close()
    }
}

final class AgentSemanticActivityLedgerTests: XCTestCase {
    func testActivityAndToolUpdatesAreMonotonic() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let now = Date(), identity = testIdentity(), sessionID = UUID(), activityID = UUID()
        let newer = SemanticActivityRecord(activityID: activityID, sessionID: sessionID, identity: identity, canonicalSequence: 3, revision: 2, kind: .assistant, content: "complete", createdAt: now, updatedAt: now)
        let older = SemanticActivityRecord(activityID: activityID, sessionID: sessionID, identity: identity, canonicalSequence: 2, revision: 1, kind: .assistant, content: "partial", createdAt: now, updatedAt: now)
        try await store.upsertSemanticActivity(newer)
        try await store.upsertSemanticActivity(older)
        let persistedActivity = try await store.semanticActivity(activityID: activityID)
        XCTAssertEqual(persistedActivity?.content, "complete")
        let finished = SemanticToolRecord(executionID: "tool-1", activityID: activityID, turnID: identity.turnID, sessionID: sessionID, canonicalSequence: 4, revision: 2, normalizedName: "read_file", status: .success, displayResult: "ok", createdAt: now, updatedAt: now)
        let started = SemanticToolRecord(executionID: "tool-1", activityID: activityID, turnID: identity.turnID, sessionID: sessionID, canonicalSequence: 3, revision: 1, normalizedName: "read_file", status: .running, createdAt: now, updatedAt: now)
        try await store.upsertSemanticTool(finished)
        try await store.upsertSemanticTool(started)
        let tools = try await store.semanticTools(turnID: identity.turnID)
        XCTAssertEqual(tools.first?.status, .success)
        try await store.close()
    }
}

final class SQLiteServiceStoreV6CompatibilityTests: XCTestCase {
    private static let rollbackProjectID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    func testMigrationIsAdditiveAndDetectsLegacyLedgerGap() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let metadata = try await store.metadata()
        XCTAssertEqual(metadata.schemaVersion, SchemaV7.version)
        let tables = try await store.database.query("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0.column("name")?.string }
        XCTAssertTrue(Set(["projects", "sessions", "transcript_entries", "semantic_turns", "semantic_activities", "semantic_tools", "agent_submissions"]).isSubset(of: Set(tables)))
        let sessionID = UUID()
        try await store.advanceSemanticWatermark(sessionID: sessionID, semanticSequence: 2, legacySequence: 5, gapDetected: true, at: Date())
        let fetchedWatermark = try await store.semanticWatermark(sessionID: sessionID)
        let watermark = try XCTUnwrap(fetchedWatermark)
        XCTAssertTrue(watermark.gapDetected)
        XCTAssertEqual(watermark.lastLegacySequence, 5)
        try await store.close()
    }

    func testTypedSettingsV6DigestUpgradesInPlaceToCombinedSchema() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("repoprompt-combined-v6-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        try await StoreMigrationTestSupport.makeV6Store(
            at: URL(fileURLWithPath: path),
            digest: "repoprompt-service-schema-v6-typed-settings-workflows-direct-providers-cas-audit"
        )
        var store: SQLiteServiceStore? = try await SQLiteServiceStore.openForMaintenance(storage: .file(path))
        let composerTables = [
            "composer_provider_catalog_cache", "agent_submissions", "effective_turn_configurations",
            "session_next_turn_defaults", "composer_attachments", "accepted_attachment_manifests",
            "run_presentations", "semantic_turns", "semantic_activities", "semantic_tools",
            "semantic_ingestion_watermarks"
        ]
        for table in composerTables {
            _ = try await store?.database.query("DROP TABLE IF EXISTS \(table)")
        }
        let source = try await XCTUnwrap(store).migrationSourceEvidence()
        _ = try await store?.migrateToLatest(
            verifiedBackup: .init(
                source: source,
                archiveSHA256: String(repeating: "a", count: 64),
                manifestSHA256: String(repeating: "b", count: 64),
                verifierFingerprint: String(repeating: "c", count: 64)
            ),
            namespaceKind: "server",
            databaseIdentityDigest: String(repeating: "d", count: 64)
        )
        try await store?.close(clean: false)
        store = nil

        let upgraded = try await SQLiteServiceStore.open(storage: .file(path))
        let tables = try await upgraded.database.query("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0.column("name")?.string }
        XCTAssertTrue(Set(["advanced_server_settings", "settings_audit", "provider_direct_configurations"]).isSubset(of: Set(tables)))
        XCTAssertTrue(Set(composerTables).isSubset(of: Set(tables)))
        let digest = try await upgraded.database.query("SELECT digest FROM schema_migrations WHERE version=6").first?.column("digest")?.string
        XCTAssertEqual(digest, "repoprompt-service-schema-v6-typed-settings-workflows-direct-providers-cas-audit")
        try await upgraded.close()
    }

    func testCreatesV6DatabaseForExactPreviousV5SourceProbe() async throws {
        guard let path = ProcessInfo.processInfo.environment["REPOPROMPT_SCHEMA_COMPAT_DB"] else {
            throw XCTSkip("External rollback compatibility probe only")
        }
        try? FileManager.default.removeItem(atPath: path)
        let store = try await SQLiteServiceStore.open(storage: .file(path))
        let metadata = try await store.metadata()
        XCTAssertEqual(metadata.schemaVersion, 6)
        try await store.close()
    }

    func testVerifiesExactPreviousV5SourceReadWriteResult() async throws {
        guard let path = ProcessInfo.processInfo.environment["REPOPROMPT_SCHEMA_COMPAT_DB"] else {
            throw XCTSkip("External rollback compatibility probe only")
        }
        let store = try await SQLiteServiceStore.open(storage: .file(path))
        let metadata = try await store.metadata()
        let project = try await store.project(id: Self.rollbackProjectID)
        let semantic = try await store.semanticTurns(sessionID: UUID())
        XCTAssertEqual(metadata.schemaVersion, 6)
        XCTAssertEqual(project?.name, "v5 rollback write")
        XCTAssertTrue(semantic.isEmpty)
        try await store.close()
    }
}

final class SessionAuthorityStreamingTests: XCTestCase {
    func testProviderDeltasAndFinalReplaceOneStableTranscriptEntry() async throws {
        let sessionID = UUID()
        let snapshot = SessionSnapshot(
            sessionID: sessionID,
            projectID: UUID(),
            parentSessionID: nil,
            rootSessionID: sessionID,
            creator: .init(userID: "owner", username: "owner", displayName: "Owner"),
            provider: .codex,
            model: "gpt-5.6-sol",
            visibility: .privateSession,
            state: .idle,
            runGeneration: 0,
            turnEpoch: 0,
            revision: 1,
            transcript: [],
            interactions: [],
            cursor: .init(storeID: UUID(), globalSequence: 0)
        )
        let authority = SessionAuthority(snapshot: snapshot, clock: SystemRuntimeClock(), ids: SystemRuntimeIDGenerator())
        let binding = try await authority.beginRun(connectionGeneration: 1)

        let firstAcceptance = await authority.acceptProviderOutput(binding: binding, kind: .assistant, content: "Hello", mutation: .appendToActiveEntry)
        XCTAssertEqual(firstAcceptance, .accepted)
        let firstSnapshot = await authority.snapshot()
        let firstEntry = try XCTUnwrap(firstSnapshot.transcript.first)
        let deltaAcceptance = await authority.acceptProviderOutput(binding: binding, kind: .assistant, content: ", world", mutation: .appendToActiveEntry)
        XCTAssertEqual(deltaAcceptance, .accepted)
        let finalAcceptance = await authority.acceptProviderOutput(binding: binding, kind: .assistant, content: "Hello, world!", mutation: .replaceActiveEntry)
        XCTAssertEqual(finalAcceptance, .accepted)

        let streamed = await authority.snapshot()
        XCTAssertEqual(streamed.transcript.count, 1)
        XCTAssertEqual(streamed.transcript[0].entryID, firstEntry.entryID)
        XCTAssertEqual(streamed.transcript[0].sessionSequence, firstEntry.sessionSequence)
        XCTAssertEqual(streamed.transcript[0].content, "Hello, world!")

        let settlement = await authority.settle(binding: binding, terminal: .sessionCompleted, lifecycle: .completed)
        XCTAssertEqual(settlement, .accepted)
        let nextBinding = try await authority.beginRun(connectionGeneration: 1)
        let nextAcceptance = await authority.acceptProviderOutput(binding: nextBinding, kind: .assistant, content: "Next turn", mutation: .appendToActiveEntry)
        XCTAssertEqual(nextAcceptance, .accepted)
        let nextRun = await authority.snapshot()
        XCTAssertEqual(nextRun.transcript.map(\.content), ["Hello, world!", "Next turn"])
        XCTAssertEqual(nextRun.transcript.map(\.sessionSequence), [1, 2])
    }

    func testNativeAssistantItemsRetainSeparateTranscriptEntries() async throws {
        let sessionID = UUID()
        let snapshot = SessionSnapshot(
            sessionID: sessionID,
            projectID: UUID(),
            parentSessionID: nil,
            rootSessionID: sessionID,
            creator: .init(userID: "owner", username: "owner", displayName: "Owner"),
            provider: .codex,
            model: "gpt-5.6-sol",
            visibility: .privateSession,
            state: .idle,
            runGeneration: 0,
            turnEpoch: 0,
            revision: 1,
            transcript: [],
            interactions: [],
            cursor: .init(storeID: UUID(), globalSequence: 0)
        )
        let authority = SessionAuthority(snapshot: snapshot, clock: SystemRuntimeClock(), ids: SystemRuntimeIDGenerator())
        let binding = try await authority.beginRun(connectionGeneration: 1)

        _ = await authority.acceptProviderOutput(binding: binding, kind: .assistant, content: "I’ll inspect it.", mutation: .replaceActiveEntry, channel: "message-1")
        _ = await authority.acceptProviderOutput(binding: binding, kind: .assistant, content: "The inspection is complete.", mutation: .replaceActiveEntry, channel: "message-2")

        let transcript = await authority.snapshot().transcript
        XCTAssertEqual(transcript.map(\.content), ["I’ll inspect it.", "The inspection is complete."])
        XCTAssertEqual(transcript.map(\.sessionSequence), [1, 2])
    }
}

final class AgentTranscriptPresentationTests: XCTestCase {
    func testOnlyPendingInteractionStatesRemainActionableInPresentation() {
        let runID = UUID()
        func interaction(_ state: InteractionSnapshot.State) -> InteractionSnapshot {
            .init(interactionID: UUID(), runID: runID, kind: .approval, state: state, payload: Data(), revision: 1, expiresAt: nil)
        }
        XCTAssertTrue(AgentTranscriptPresentationService.isActionable(interaction(.pending)))
        XCTAssertTrue(AgentTranscriptPresentationService.isActionable(interaction(.deliveryIntent)))
        XCTAssertFalse(AgentTranscriptPresentationService.isActionable(interaction(.resolved)))
        XCTAssertFalse(AgentTranscriptPresentationService.isActionable(interaction(.expired)))
        XCTAssertFalse(AgentTranscriptPresentationService.isActionable(interaction(.interrupted)))
    }

    func testSuppressesExactTurnStartedAndClustersMeaningfulActivity() {
        let turnStarted = TranscriptEntry(entryID: UUID(), sessionSequence: 1, kind: .progress, content: "Turn started.", actor: nil, timestamp: Date())
        XCTAssertNil(AgentTranscriptPresentationCore.projectLegacy(turnStarted))
        let tool = AgentPresentationToolWire(executionID: "e1", name: "read_file", status: .success, summary: "Read", keyPaths: ["Sources/A.swift"])
        let projected = AgentTranscriptPresentationCore.project(.init(turnID: "turn", responseSpanID: "span", requestAnchorID: UUID(), requestText: "request", terminalState: "completed", activities: [
            .init(id: "lifecycle", sequence: 1, revision: 1, kind: "progress", content: "turn started"),
            .init(id: "reason", sequence: 2, revision: 1, kind: "reasoning", content: "Considering"),
            .init(id: "tool", sequence: 3, revision: 1, kind: "tool", tool: tool),
            .init(id: "answer", sequence: 4, revision: 2, kind: "assistant", content: "Done")
        ]))
        XCTAssertEqual(projected.blocks.count, 3)
        guard case let .activityCluster(_, rows, summary) = projected.blocks[1] else { return XCTFail("expected activity cluster") }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(summary.toolGroups, ["read_file"])
    }

    func testProviderEmissionOrderKeepsNarrationBeforeToolsAndConclusionAfterThem() {
        let tool = AgentPresentationToolWire(executionID: "e1", name: "read_file", status: .success)
        let projected = AgentTranscriptPresentationCore.project(.init(
            turnID: "turn",
            responseSpanID: "span",
            requestAnchorID: UUID(),
            requestText: "Inspect the workspace",
            activities: [
                .init(id: "narration", sequence: 2, revision: 1, kind: "assistant", content: "I’ll take a look."),
                .init(id: "tool", sequence: 3, revision: 1, kind: "tool", tool: tool),
                .init(id: "conclusion", sequence: 4, revision: 1, kind: "assistant", content: "The inspection is complete."),
            ]
        ))

        XCTAssertEqual(projected.blocks.map(\.id), [
            "turn:request-block",
            "narration",
            "turn:activity:0",
            "conclusion",
        ])
    }

    func testLegacyReasoningLifecycleRowsAreNotPresentedAsTools() {
        let reasoning = AgentPresentationToolWire(
            executionID: "legacy-reasoning",
            name: "reasoning",
            status: .success,
            summary: "reasoning",
            displayArguments: #"{"type":"reasoning"}"#
        )
        let command = AgentPresentationToolWire(executionID: "command", name: "Command", status: .success)
        let projected = AgentTranscriptPresentationCore.project(.init(
            turnID: "turn",
            responseSpanID: "span",
            requestAnchorID: UUID(),
            requestText: "Inspect",
            activities: [
                .init(id: "legacy-reasoning", sequence: 2, revision: 1, kind: "tool", tool: reasoning),
                .init(id: "command", sequence: 3, revision: 1, kind: "tool", tool: command),
            ]
        ))

        guard case let .activityCluster(_, rows, summary) = projected.blocks[1] else { return XCTFail("expected activity cluster") }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(summary.toolCount, 1)
        XCTAssertEqual(summary.toolGroups, ["Command"])
    }

    func testPresentationPublishesProviderApprovalChoicesAsCanonicalClientActions() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let service = AgentTranscriptPresentationService(store: store)
        let sessionID = UUID()
        let runID = UUID()
        let payload = try JSONEncoder.serviceEncoder.encode(ProviderInteractionPayload(
            providerRequestID: "provider-request-1",
            prompt: "Allow the read-only command?",
            choices: ["accept", "decline"]
        ))
        let interaction = InteractionSnapshot(
            interactionID: UUID(),
            runID: runID,
            kind: .approval,
            state: .pending,
            payload: payload,
            revision: 1,
            expiresAt: nil
        )

        let page = try await service.page(
            sessionID: sessionID,
            actorID: "controller",
            legacyTranscript: [],
            interactions: [interaction],
            mutableInteractions: true
        )

        let presented = try XCTUnwrap(page.pendingInteractions.first)
        XCTAssertEqual(presented.prompt, "Allow the read-only command?")
        XCTAssertEqual(presented.choices, ["accept", "decline"])
        XCTAssertTrue(presented.mutable)
        try await store.close()
    }

    func testResolvedProviderApprovalRemainsAttachedToItsTurnAsReadOnlyHistory() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let service = AgentTranscriptPresentationService(store: store)
        let sessionID = UUID()
        let runID = UUID()
        let now = Date(timeIntervalSince1970: 1_786_400_000)
        let configuration = testConfiguration(at: now)
        let identity = CanonicalTurnIdentity(
            requestAnchorID: UUID(),
            runID: runID,
            generation: 1,
            turnEpoch: 1,
            turnID: UUID(),
            responseSpanID: UUID()
        )
        let turn = CanonicalUserTurn(
            identity: identity,
            text: "Run a read-only command",
            suggestionTokens: [],
            taggedFiles: [],
            attachments: [],
            effectiveConfiguration: configuration
        )
        try await store.upsertSemanticTurn(.init(
            sessionID: sessionID,
            identity: identity,
            firstSequence: 1,
            lastSequence: 1,
            canonicalUserTurnJSON: JSONEncoder.serviceEncoder.encode(turn),
            effectiveConfiguration: configuration,
            createdAt: now,
            acceptedAt: now
        ))
        let payload = try JSONEncoder.serviceEncoder.encode(ProviderInteractionPayload(
            providerRequestID: "provider-request-1",
            prompt: "Allow the read-only command?",
            choices: ["accept", "decline"],
            resolution: "accept"
        ))
        let interaction = InteractionSnapshot(
            interactionID: UUID(),
            runID: runID,
            kind: .approval,
            state: .resolved,
            payload: payload,
            revision: 3,
            expiresAt: nil
        )

        let page = try await service.page(
            sessionID: sessionID,
            actorID: "controller",
            legacyTranscript: [],
            interactions: [interaction],
            mutableInteractions: true
        )

        XCTAssertTrue(page.pendingInteractions.isEmpty)
        let presented = try XCTUnwrap(page.turns.first?.interactions.first)
        XCTAssertEqual(presented.state, "resolved")
        XCTAssertEqual(presented.prompt, "Allow the read-only command?")
        XCTAssertEqual(presented.resolution, "accept")
        XCTAssertFalse(presented.mutable)
        XCTAssertFalse(presented.liveTail)
        XCTAssertFalse(presented.requiresAttention)
        try await store.close()
    }

    func testLegacyRollbackGapIsDetectedWithoutInventingSemanticTurns() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let service = AgentTranscriptPresentationService(store: store)
        let sessionID = UUID()
        let legacy = [TranscriptEntry(entryID: UUID(), sessionSequence: 7, kind: .assistant, content: "legacy answer", actor: nil, timestamp: Date())]
        let page = try await service.page(sessionID: sessionID, actorID: "actor", legacyTranscript: legacy)
        let watermark = try await store.semanticWatermark(sessionID: sessionID)
        XCTAssertEqual(page.turns.count, 1)
        XCTAssertTrue(page.turns[0].legacyStandalone)
        XCTAssertTrue(watermark?.gapDetected == true)
        let semantic = try await store.semanticTurns(sessionID: sessionID)
        XCTAssertTrue(semantic.isEmpty)
        try await store.close()
    }

    func testLegacyStreamingFragmentsReconstructOneCoherentTurn() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let service = AgentTranscriptPresentationService(store: store)
        let sessionID = UUID()
        let now = Date()
        let legacy = [
            TranscriptEntry(entryID: UUID(), sessionSequence: 1, kind: .human, content: "Fix the transcript", actor: nil, timestamp: now),
            TranscriptEntry(entryID: UUID(), sessionSequence: 2, kind: .assistant, content: "Implemented", actor: nil, timestamp: now),
            TranscriptEntry(entryID: UUID(), sessionSequence: 3, kind: .assistant, content: " the", actor: nil, timestamp: now),
            TranscriptEntry(entryID: UUID(), sessionSequence: 4, kind: .assistant, content: " complete fix.", actor: nil, timestamp: now),
            TranscriptEntry(entryID: UUID(), sessionSequence: 5, kind: .assistant, content: "Implemented the complete fix.", actor: nil, timestamp: now)
        ]

        let page = try await service.page(sessionID: sessionID, actorID: "actor", legacyTranscript: legacy)
        XCTAssertEqual(page.turns.count, 1)
        XCTAssertTrue(page.turns[0].legacyStandalone)
        XCTAssertEqual(page.turns[0].blocks.count, 2)
        guard case let .request(_, request) = page.turns[0].blocks[0],
              case let .userRequest(_, requestText, _, _) = request,
              case let .standaloneAssistant(_, response) = page.turns[0].blocks[1],
              case let .assistant(_, responseText) = response
        else { return XCTFail("expected one reconstructed request and assistant response") }
        XCTAssertEqual(requestText, "Fix the transcript")
        XCTAssertEqual(responseText, "Implemented the complete fix.")
        try await store.close()
    }

    func testSemanticCoverageConsumesTheCompleteLegacySpanWithoutAttachingTailToOlderMessage() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let service = AgentTranscriptPresentationService(store: store)
        let sessionID = UUID()
        let now = Date(timeIntervalSince1970: 1_786_400_000)
        let configuration = testConfiguration(at: now)
        let helloAnchor = UUID()
        let testingAnchor = UUID()
        let spaceXAnchor = UUID()
        let testingIdentity = CanonicalTurnIdentity(requestAnchorID: testingAnchor, runID: UUID(), generation: 2, turnEpoch: 2, turnID: UUID(), responseSpanID: UUID())
        let spaceXIdentity = CanonicalTurnIdentity(requestAnchorID: spaceXAnchor, runID: UUID(), generation: 3, turnEpoch: 3, turnID: UUID(), responseSpanID: UUID())

        let testingTurn = CanonicalUserTurn(identity: testingIdentity, text: "Testing", suggestionTokens: [], taggedFiles: [], attachments: [], effectiveConfiguration: configuration)
        try await store.upsertSemanticTurn(.init(sessionID: sessionID, identity: testingIdentity, firstSequence: 10, lastSequence: 10, canonicalUserTurnJSON: JSONEncoder.serviceEncoder.encode(testingTurn), effectiveConfiguration: configuration, createdAt: now, acceptedAt: now))
        try await store.upsertSemanticActivity(.init(activityID: UUID(), sessionID: sessionID, identity: testingIdentity, canonicalSequence: 60, revision: 1, kind: .assistant, content: "Received—everything's working.", createdAt: now, updatedAt: now))

        let spaceXTurn = CanonicalUserTurn(identity: spaceXIdentity, text: "Tell me what SpaceX's stock did today", suggestionTokens: [], taggedFiles: [], attachments: [], effectiveConfiguration: configuration)
        try await store.upsertSemanticTurn(.init(sessionID: sessionID, identity: spaceXIdentity, firstSequence: 18, lastSequence: 18, canonicalUserTurnJSON: JSONEncoder.serviceEncoder.encode(spaceXTurn), effectiveConfiguration: configuration, createdAt: now, acceptedAt: now))
        try await store.upsertSemanticActivity(.init(activityID: UUID(), sessionID: sessionID, identity: spaceXIdentity, canonicalSequence: 68, revision: 1, kind: .assistant, content: "SpaceX is privately held.", createdAt: now, updatedAt: now))

        let legacy = [
            TranscriptEntry(entryID: helloAnchor, sessionSequence: 9, kind: .human, content: "hello?", actor: nil, timestamp: now),
            TranscriptEntry(entryID: testingIdentity.turnID, sessionSequence: 10, kind: .human, content: "Testing", actor: nil, timestamp: now),
            TranscriptEntry(entryID: UUID(), sessionSequence: 11, kind: .assistant, content: "Received", actor: nil, timestamp: now),
            TranscriptEntry(entryID: UUID(), sessionSequence: 17, kind: .assistant, content: "Received—everything's working.", actor: nil, timestamp: now),
            TranscriptEntry(entryID: spaceXIdentity.turnID, sessionSequence: 18, kind: .human, content: "Tell me what SpaceX's stock did today", actor: nil, timestamp: now),
            TranscriptEntry(entryID: UUID(), sessionSequence: 19, kind: .assistant, content: "I'll check", actor: nil, timestamp: now),
            TranscriptEntry(entryID: UUID(), sessionSequence: 69, kind: .assistant, content: "SpaceX", actor: nil, timestamp: now),
            TranscriptEntry(entryID: UUID(), sessionSequence: 195, kind: .assistant, content: "SpaceX is privately held.", actor: nil, timestamp: now),
        ]

        let newest = try await service.page(sessionID: sessionID, actorID: "actor", legacyTranscript: legacy, limit: 2)
        XCTAssertEqual(newest.turns.compactMap(Self.requestText), ["Testing", "Tell me what SpaceX's stock did today"])
        let spaceX = try XCTUnwrap(newest.turns.first { Self.requestText($0) == "Tell me what SpaceX's stock did today" })
        XCTAssertEqual(Self.assistantTexts(spaceX), ["SpaceX is privately held."])

        let token = try XCTUnwrap(newest.nextPageToken)
        let earlier = try await service.page(sessionID: sessionID, actorID: "actor", legacyTranscript: legacy, pageToken: token, limit: 2)
        XCTAssertEqual(earlier.turns.compactMap(Self.requestText), ["hello?"])
        XCTAssertTrue(Self.assistantTexts(try XCTUnwrap(earlier.turns.first)).isEmpty)
        XCTAssertNil(earlier.nextPageToken)
        try await store.close()
    }

    func testLegacyPresentationPaginationUsesWholeTurnBoundaries() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let service = AgentTranscriptPresentationService(store: store)
        let sessionID = UUID()
        let now = Date()
        var legacy: [TranscriptEntry] = []
        for turn in 1 ... 3 {
            legacy.append(TranscriptEntry(entryID: UUID(), sessionSequence: Int64(turn * 2 - 1), kind: .human, content: "request \(turn)", actor: nil, timestamp: now))
            legacy.append(TranscriptEntry(entryID: UUID(), sessionSequence: Int64(turn * 2), kind: .assistant, content: "response \(turn)", actor: nil, timestamp: now))
        }

        let newest = try await service.page(sessionID: sessionID, actorID: "actor", legacyTranscript: legacy, limit: 2)
        XCTAssertEqual(newest.turns.compactMap(Self.requestText), ["request 2", "request 3"])
        let token = try XCTUnwrap(newest.nextPageToken)
        XCTAssertNotNil(token.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression))
        let earlier = try await service.page(sessionID: sessionID, actorID: "actor", legacyTranscript: legacy, pageToken: token, limit: 2)
        XCTAssertEqual(earlier.turns.compactMap(Self.requestText), ["request 1"])
        XCTAssertNil(earlier.nextPageToken)
        try await store.close()
    }

    private static func requestText(_ turn: AgentPresentationTurnWire) -> String? {
        for block in turn.blocks {
            guard case let .request(_, row) = block,
                  case let .userRequest(_, text, _, _) = row
            else { continue }
            return text
        }
        return nil
    }

    private static func assistantTexts(_ turn: AgentPresentationTurnWire) -> [String] {
        turn.blocks.compactMap { block in
            let row: AgentPresentationRowWire
            switch block {
            case let .standaloneAssistant(_, value), let .conclusion(_, value):
                row = value
            default:
                return nil
            }
            guard case let .assistant(_, text) = row else { return nil }
            return text
        }
    }
}

final class NativeProviderRuntimeLifecycleTests: XCTestCase {
    func testCodexConfigDoesNotEnableUnprovisionedRepoPromptTransport() {
        let config = CodexAppServerProviderRuntime.codexConfig([
            "codex.enabledMCPServers": "[\"repoprompt\",\"RepoPromptCE\",\"external-tools\"]"
        ])
        XCTAssertEqual(CodexAppServerProviderRuntime.appServerArguments, [
            "--disable", "plugins",
            "--disable", "remote_plugin",
            "app-server",
        ])
        XCTAssertEqual(config["features.plugins"] as? Bool, false)
        XCTAssertEqual(config["features.remote_plugin"] as? Bool, false)
        XCTAssertNil(config["mcp_servers.repoprompt.enabled"])
        XCTAssertNil(config["mcp_servers.RepoPromptCE.enabled"])
        XCTAssertEqual(config["mcp_servers.external-tools.enabled"] as? Bool, true)
    }

    func testCodexConfigEnablesProvisionedRepoPromptTransport() {
        let config = CodexAppServerProviderRuntime.codexConfig([
            CodexRepoPromptMCPConfig.provisionedSettingsKey: "true",
            "codex.enabledMCPServers": "[\"RepoPromptCE\",\"external-tools\"]"
        ])
        XCTAssertEqual(config["mcp_servers.RepoPromptCE.enabled"] as? Bool, true)
        XCTAssertEqual(config["mcp_servers.external-tools.enabled"] as? Bool, true)
        XCTAssertNil(config["mcp_servers.repoprompt.enabled"])
    }

    func testCodexTurnStartedIsLifecycleOnlyAndPhaseRevisionAdvances() throws {
        let frame = Data(#"{"method":"turn/started","params":{}}"#.utf8)
        let normalized = try CodexAppServerProviderRuntime.normalize(frame)
        XCTAssertEqual(normalized.events.count, 1)
        guard case let .runStatusChanged(phase, code, text) = normalized.events[0] else { return XCTFail("turn started must be lifecycle") }
        XCTAssertEqual(phase, .thinking)
        XCTAssertEqual(code, HeadlessRunStatusCopy.thinkingCode)
        XCTAssertEqual(text, HeadlessRunStatusCopy.thinking)
        let now = Date(), sessionID = UUID(), runID = UUID()
        let preparing = RunPresentationSnapshot(sessionID: sessionID, runID: runID, generation: 1, turnEpoch: 1, phase: .preparing, phaseRevision: 1, runStartedAt: now)
        let thinking = try preparing.transitioning(to: .thinking, statusCode: code)
        XCTAssertEqual(thinking.phaseRevision, 2)
        XCTAssertEqual(thinking.phase, .thinking)
    }

    func testCodexMessageItemsDriveWorkingWithoutFakeToolRowsAndIdleCompletes() throws {
        let userStarted = try CodexAppServerProviderRuntime.normalize(Data(#"{"method":"item/started","params":{"item":{"id":"user-1","type":"userMessage"}}}"#.utf8))
        XCTAssertTrue(userStarted.events.isEmpty)
        XCTAssertFalse(userStarted.completed)

        let assistantStarted = try CodexAppServerProviderRuntime.normalize(Data(#"{"method":"item/started","params":{"item":{"id":"assistant-1","type":"agentMessage"}}}"#.utf8))
        XCTAssertEqual(assistantStarted.events.count, 1)
        guard case let .runStatusChanged(phase, code, text) = assistantStarted.events[0] else { return XCTFail("agent message start must advance lifecycle") }
        XCTAssertEqual(phase, .working)
        XCTAssertEqual(code, HeadlessRunStatusCopy.thinkingCode)
        XCTAssertEqual(text, HeadlessRunStatusCopy.thinking)

        let assistantDelta = try CodexAppServerProviderRuntime.normalize(Data(#"{"method":"item/agentMessage/delta","params":{"itemId":"assistant-1","delta":"one coherent "}}"#.utf8))
        guard case let .assistantItemDelta(providerItemID, delta) = assistantDelta.events.first else { return XCTFail("agent message delta must retain its native item identity") }
        XCTAssertEqual(providerItemID, "assistant-1")
        XCTAssertEqual(delta, "one coherent ")

        let assistantCompleted = try CodexAppServerProviderRuntime.normalize(Data(#"{"method":"item/completed","params":{"item":{"id":"assistant-1","type":"agentMessage","text":"one coherent response"}}}"#.utf8))
        XCTAssertEqual(assistantCompleted.events.count, 1)
        guard case let .assistantItemFinal(completedItemID, text) = assistantCompleted.events[0] else { return XCTFail("agent message completion must retain its native item identity") }
        XCTAssertEqual(completedItemID, "assistant-1")
        XCTAssertEqual(text, "one coherent response")

        let reasoningStarted = try CodexAppServerProviderRuntime.normalize(Data(#"{"method":"item/started","params":{"item":{"id":"reasoning-1","type":"reasoning"}}}"#.utf8))
        let reasoningCompleted = try CodexAppServerProviderRuntime.normalize(Data(#"{"method":"item/completed","params":{"item":{"id":"reasoning-1","type":"reasoning","summary":["Checked the workspace"]}}}"#.utf8))
        XCTAssertTrue(reasoningStarted.events.isEmpty)
        XCTAssertTrue(reasoningCompleted.events.isEmpty)

        let reasoningDelta = try CodexAppServerProviderRuntime.normalize(Data(#"{"method":"item/reasoning/summaryTextDelta","params":{"itemId":"reasoning-1","delta":"Checking"}}"#.utf8))
        guard case let .reasoningItemDelta(reasoningItemID, reasoningText) = reasoningDelta.events.first else { return XCTFail("reasoning delta must not become a tool") }
        XCTAssertEqual(reasoningItemID, "reasoning-1")
        XCTAssertEqual(reasoningText, "Checking")

        let idle = try CodexAppServerProviderRuntime.normalize(Data(#"{"method":"thread/status/changed","params":{"status":{"type":"idle"}}}"#.utf8))
        XCTAssertTrue(idle.events.isEmpty)
        XCTAssertTrue(idle.completed)
    }

    func testCodexTokenUsageUpdatedProjectsDesktopContextMeter() throws {
        let normalized = try CodexAppServerProviderRuntime.normalize(Data(#"{"method":"thread/tokenUsage/updated","params":{"tokenUsage":{"modelContextWindow":272000,"last":{"totalTokens":4096},"total":{"totalTokens":8192}}}}"#.utf8))
        XCTAssertFalse(normalized.completed)
        guard case let .contextUsage(usage) = normalized.events.first else {
            return XCTFail("Codex tokenUsage must become the composer context meter")
        }
        XCTAssertEqual(usage.modelContextWindow, 272_000)
        XCTAssertEqual(usage.lastTotalTokens, 4096)
        XCTAssertEqual(usage.totalTotalTokens, 8192)

        let empty = try CodexAppServerProviderRuntime.normalize(Data(#"{"method":"thread/tokenUsage/updated","params":{}}"#.utf8))
        XCTAssertTrue(empty.events.isEmpty)
    }

    func testReconnectReadsEveryDurablePhaseAndTerminalSettlement() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("run-presentation-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let now = Date(timeIntervalSince1970: 1_786_400_000), sessionID = UUID(), runID = UUID()
        var expected = RunPresentationSnapshot(sessionID: sessionID, runID: runID, generation: 4, turnEpoch: 9, phase: .preparing, phaseRevision: 1, runStartedAt: now)
        for phase in [RunPresentationPhase.preparing, .thinking, .working, .waiting, .cancelling] {
            if expected.phase != phase { expected = try expected.transitioning(to: phase, statusCode: "phase_\(phase.rawValue)") }
            let writer = try await SQLiteServiceStore.open(storage: .file(path))
            try await writer.upsertRunPresentation(expected)
            try await writer.close()
            let reader = try await SQLiteServiceStore.open(storage: .file(path))
            let restored = try await reader.runPresentation(sessionID: sessionID)
            XCTAssertEqual(restored, expected)
            try await reader.close()
        }
        let terminal = expected.settling(code: "cancelled", at: now.addingTimeInterval(5))
        let writer = try await SQLiteServiceStore.open(storage: .file(path))
        try await writer.upsertRunPresentation(terminal)
        try await writer.close()
        let reader = try await SQLiteServiceStore.open(storage: .file(path))
        let restored = try await reader.runPresentation(sessionID: sessionID)
        XCTAssertEqual(restored?.phase, nil)
        XCTAssertEqual(restored?.terminalSettlementCode, "cancelled")
        XCTAssertEqual(restored?.phaseRevision, terminal.phaseRevision)
        try await reader.close()
    }
}

final class RepoPromptHTTPComposerContractTests: XCTestCase {
    func testAuthenticatedComposerCatalogUsesRunnerCompositionAndKeepsFailureCategoriesDistinct() async throws {
        let fixture = try await StructuredStartFixture.make()
        defer { Task { try? await fixture.store.close(); try? FileManager.default.removeItem(at: fixture.root) } }
        let instant = Date(timeIntervalSince1970: 1_786_400_000)
        let key = InternalSigningKey(keyID: "composer-http", role: .app, direction: "test", secret: Data("composer-http-contract-secret-32bytes".utf8))
        let path = "/internal/v1/catalog/composer?projectId=\(fixture.sessionInput.projectID.uuidString.lowercased())"
        let completeWorkflowGuidance = String(repeating: "Desktop parity 🚫 ", count: 2_000)
        let composedCatalog = RepoPromptServerRunner.composeAgentCatalog(
            providerSettings: fixture.providerSettings,
            store: fixture.store,
            workflows: [.init(id: "complete-workflow", displayName: "Complete workflow", guidance: completeWorkflowGuidance)],
            suggestions: [],
            emptyState: .init(featuredWorkflowIDs: [], tips: []),
            providerProfileLoader: { providerID in
                guard providerID == .claudeCompatible else { return .init() }
                return .init(
                    toolControls: ProviderComposerStableControls.descriptors(
                        providerID: providerID,
                        values: ["claude.bash": .boolean(false)],
                        mutable: true,
                        lockReasonCode: nil
                    ),
                    permissionControl: ProviderComposerStableControls.permissionDescriptor(
                        providerID: providerID,
                        selectedID: "claude.autoApproveEdits",
                        mutable: true,
                        lockReasonCode: nil
                    )
                )
            }
        )
        let authenticator = InternalRequestAuthenticator(keys: [key], store: fixture.store, now: { instant })
        let composedService = RepoPromptHTTPService(authority: fixture.authority, store: fixture.store, authenticator: authenticator, eventSigningKey: key, composerCatalog: composedCatalog, mutationGate: AuthorityMutationGate())
        let composedApp = Application(router: composedService.internalRouter())
        try await composedApp.test(.router) { client in
            let headers = try composerCatalogHeaders(actor: fixture.actor, projectID: fixture.sessionInput.projectID, path: path, nonce: "composercatalog001", instant: instant, key: key)
            try await client.execute(uri: path, method: .get, headers: headers) { response in
                XCTAssertEqual(response.status, .ok)
                let snapshot = try JSONDecoder.serviceDecoder.decode(ComposerCatalogWireSnapshot.self, from: Data(response.body.readableBytesView))
                let group = try XCTUnwrap(snapshot.providerGroups.first { $0.providerID == .claudeCompatible })
                XCTAssertEqual(Set(group.models.map(\.id)), Set([fixture.modelID, "sonnet", "opus", "haiku"]))
                let runtimeModel = try XCTUnwrap(group.models.first { $0.id == fixture.modelID })
                XCTAssertEqual(runtimeModel.supportedEffortIDs, ["high"])
                XCTAssertEqual(runtimeModel.defaultEffortID, "high")
                XCTAssertEqual(snapshot.selected?.permissionID, "claude.autoApproveEdits")
                XCTAssertEqual(snapshot.selected?.toolValues["claude.bash"], .boolean(false))
                let completeWorkflow = try XCTUnwrap(snapshot.workflows.first { $0.guidance == completeWorkflowGuidance })
                XCTAssertGreaterThan(try XCTUnwrap(completeWorkflow.guidance).utf8.count, 16_384)
            }
        }

        let missingService = RepoPromptHTTPService(authority: fixture.authority, store: fixture.store, authenticator: authenticator, eventSigningKey: key, mutationGate: AuthorityMutationGate())
        let missingApp = Application(router: missingService.internalRouter())
        try await missingApp.test(.router) { client in
            let headers = try composerCatalogHeaders(actor: fixture.actor, projectID: fixture.sessionInput.projectID, path: path, nonce: "composercatalog002", instant: instant, key: key)
            try await client.execute(uri: path, method: .get, headers: headers) { response in
                XCTAssertEqual(response.status, .serviceUnavailable)
                let error = try JSONDecoder.serviceDecoder.decode(ServiceAPIError.self, from: Data(response.body.readableBytesView))
                XCTAssertEqual(error.code, .dependencyUnavailable)
                XCTAssertEqual(error.message, "Agent composer catalog is unavailable")
            }
        }

        let failingService = RepoPromptHTTPService(authority: fixture.authority, store: fixture.store, authenticator: authenticator, eventSigningKey: key, composerCatalog: FailingComposerCatalog(), mutationGate: AuthorityMutationGate())
        let failingApp = Application(router: failingService.internalRouter())
        try await failingApp.test(.router) { client in
            let headers = try composerCatalogHeaders(actor: fixture.actor, projectID: fixture.sessionInput.projectID, path: path, nonce: "composercatalog003", instant: instant, key: key)
            try await client.execute(uri: path, method: .get, headers: headers) { response in
                XCTAssertEqual(response.status, .internalServerError)
                let error = try JSONDecoder.serviceDecoder.decode(ServiceAPIError.self, from: Data(response.body.readableBytesView))
                XCTAssertEqual(error.code, .internalFailure)
                XCTAssertEqual(error.message, "Internal service failure")
                XCTAssertFalse(error.retryable)
            }
        }
    }

    func testActorScopedResponsesArePrivateAndVaryOnCredentials() throws {
        let json = try HTTPResponses.privateJSON(["ok": true])
        XCTAssertEqual(json.headers[.cacheControl], "private, no-store")
        XCTAssertEqual(json.headers[.vary], "Cookie, Authorization")
        let empty = HTTPResponses.privateEmpty()
        XCTAssertEqual(empty.headers[.cacheControl], "private, no-store")
        XCTAssertEqual(empty.headers[.vary], "Cookie, Authorization")
    }

    func testAttachmentErrorsExposeStableSanitizedHTTPStatusCodes() throws {
        XCTAssertEqual(HTTPResponses.error(ServiceAPIError(code: .resourceOwnerMismatch, message: "sanitized")).status, .forbidden)
        XCTAssertEqual(HTTPResponses.error(ServiceAPIError(code: .resourceContextMismatch, message: "sanitized")).status, .forbidden)
        XCTAssertEqual(HTTPResponses.error(ServiceAPIError(code: .expiredResource, message: "sanitized")).status, .gone)
        XCTAssertEqual(HTTPResponses.error(ServiceAPIError(code: .notFound, message: "Attachment is unavailable")).status, .notFound)
    }
}

final class RepoPromptHTTPStructuredStartAtomicityTests: XCTestCase {
    func testPreCommitConfigurationFailurePublishesNoSessionEventOrSemanticTurn() async throws {
        let fixture = try await StructuredStartFixture.make()
        defer { Task { try? await fixture.store.close(); try? FileManager.default.removeItem(at: fixture.root) } }
        let invalid = AgentTurnSubmissionWire(
            content: .init(text: "must not publish"),
            configuration: .init(catalogRevision: "stale-catalog", providerID: .claudeCompatible, modelID: fixture.modelID)
        )

        let body = try JSONEncoder.serviceEncoder.encode(AgentStartSessionWire(projectID: fixture.sessionInput.projectID, visibility: fixture.sessionInput.visibility, turn: invalid))
        let instant = Date(timeIntervalSince1970: 1_786_400_000)
        let key = InternalSigningKey(keyID: "atomic-http", role: .app, direction: "test", secret: Data("atomic-http-secret".utf8))
        let service = RepoPromptHTTPService(authority: fixture.authority, store: fixture.store, authenticator: InternalRequestAuthenticator(keys: [key], store: fixture.store, now: { instant }), eventSigningKey: key, submissionCoordinator: fixture.coordinator, mutationGate: AuthorityMutationGate())
        let app = Application(router: service.internalRouter())
        try await app.test(.router) { client in
            let headers = try structuredStartHeaders(body: body, actor: fixture.actor, projectID: fixture.sessionInput.projectID, idempotencyKey: UUID().uuidString.lowercased(), nonce: "atomicfailure001", instant: instant, key: key)
            try await client.execute(uri: "/internal/v1/sessions", method: .post, headers: headers, body: ByteBuffer(bytes: body)) { response in
                XCTAssertEqual(response.status, .conflict)
            }
        }

        let publishedSessions = try await fixture.authority.sessionSnapshots()
        XCTAssertTrue(publishedSessions.isEmpty)
        let rows = try await fixture.store.database.query("SELECT COUNT(*) AS count FROM sessions")
        XCTAssertEqual(rows.first?.column("count")?.integer, 0)
        let eventRows = try await fixture.store.database.query("SELECT COUNT(*) AS count FROM events WHERE session_id IS NOT NULL")
        XCTAssertEqual(eventRows.first?.column("count")?.integer, 0)
        let turnRows = try await fixture.store.database.query("SELECT COUNT(*) AS count FROM semantic_turns")
        XCTAssertEqual(turnRows.first?.column("count")?.integer, 0)
        let receiptRows = try await fixture.store.database.query("SELECT COUNT(*) AS count FROM agent_submissions WHERE state='accepted' OR receipt_json IS NOT NULL")
        XCTAssertEqual(receiptRows.first?.column("count")?.integer, 0)
    }

    func testStructuredStartCarriesSelectedMessageContextWithoutSelectionMutation() async throws {
        let fixture = try await StructuredStartFixture.make()
        defer { Task { try? await fixture.store.close(); try? FileManager.default.removeItem(at: fixture.root) } }
        let submissionKey = UUID().uuidString.lowercased()
        let selectedContext = SelectedMessageContext(source: "explicit-selection", messages: [
            .init(roomID: "room-1", messageID: "message-1", text: "Exact selected chat text", senderID: "sender-1", timestamp: "2026-08-12T12:00:00Z", revision: "3", threadID: "thread-1")
        ])
        let submission = AgentTurnSubmissionWire(
            content: .init(text: "Investigate the regression"),
            configuration: .init(catalogRevision: fixture.catalogRevision, providerID: .claudeCompatible, modelID: fixture.modelID, effortID: fixture.effortID, permissionID: "claude.requireApproval", toolValues: ["claude.mcpStrictMode": .boolean(true)])
        )
        let body = try JSONEncoder.serviceEncoder.encode(AgentStartSessionWire(projectID: fixture.sessionInput.projectID, visibility: fixture.sessionInput.visibility, turn: submission, selectedMessageContext: selectedContext))
        let instant = Date(timeIntervalSince1970: 1_786_400_000)
        let signingKey = InternalSigningKey(keyID: "atomic-http", role: .app, direction: "test", secret: Data("atomic-http-secret".utf8))
        let dispatchQueue = AgentSubmissionDispatchQueue(authority: fixture.authority, coordinator: fixture.coordinator)
        let service = RepoPromptHTTPService(authority: fixture.authority, store: fixture.store, authenticator: InternalRequestAuthenticator(keys: [signingKey], store: fixture.store, now: { instant }), eventSigningKey: signingKey, submissionCoordinator: fixture.coordinator, submissionDispatchQueue: dispatchQueue, mutationGate: AuthorityMutationGate())
        let app = Application(router: service.internalRouter())
        let receipt = try await app.test(.router) { client in
            let headers = try structuredStartHeaders(body: body, actor: fixture.actor, projectID: fixture.sessionInput.projectID, idempotencyKey: submissionKey, nonce: "atomiccontext001", instant: instant, key: signingKey)
            return try await client.execute(uri: "/internal/v1/sessions", method: .post, headers: headers, body: ByteBuffer(bytes: body)) { response in
                XCTAssertEqual(response.status, .accepted)
                return try JSONDecoder.serviceDecoder.decode(SubmissionReceipt.self, from: Data(response.body.readableBytesView))
            }
        }
        await dispatchQueue.waitForIdle()
        let frozen = selectedContext.frozenPrompt(userPrompt: submission.content.text)
        XCTAssertEqual(receipt.session?.transcript.map(\.content), [frozen])
        let turns = try await fixture.store.semanticTurns(sessionID: receipt.sessionID)
        let turn = try XCTUnwrap(turns.first)
        let canonical = try JSONDecoder.serviceDecoder.decode(CanonicalUserTurn.self, from: turn.canonicalUserTurnJSON)
        XCTAssertEqual(canonical.text, frozen)
        let storedRecord = try await fixture.store.agentSubmission(actorID: fixture.actor.userID, targetKey: "project:\(fixture.sessionInput.projectID.uuidString.lowercased())", operation: "startSession", publicKey: submissionKey)
        let stored = try XCTUnwrap(storedRecord)
        let compiled = try JSONDecoder.serviceDecoder.decode(CompiledProviderTurnInput.self, from: try XCTUnwrap(stored.compiledInputJSON))
        XCTAssertTrue(compiled.prompt.contains(frozen))
        let selection = try await fixture.authority.selectionSnapshot(sessionID: receipt.sessionID)
        XCTAssertTrue(selection.entries.isEmpty)
    }

    func testStructuredStartReturnsDurableReceiptBeforeProviderDispatchCompletes() async throws {
        let fixture = try await StructuredStartFixture.make()
        defer { Task { try? await fixture.store.close(); try? FileManager.default.removeItem(at: fixture.root) } }
        let submissionKey = UUID().uuidString.lowercased()
        let submission = AgentTurnSubmissionWire(
            content: .init(text: "accept before launch"),
            configuration: .init(catalogRevision: fixture.catalogRevision, providerID: .claudeCompatible, modelID: fixture.modelID, effortID: fixture.effortID, permissionID: "claude.requireApproval", toolValues: ["claude.mcpStrictMode": .boolean(true)])
        )
        let body = try JSONEncoder.serviceEncoder.encode(AgentStartSessionWire(projectID: fixture.sessionInput.projectID, visibility: fixture.sessionInput.visibility, turn: submission))
        let instant = Date(timeIntervalSince1970: 1_786_400_000)
        let signingKey = InternalSigningKey(keyID: "atomic-http", role: .app, direction: "test", secret: Data("atomic-http-secret".utf8))
        let gate = SubmissionDispatchGate()
        let coordinator = fixture.coordinator
        let dispatchQueue = AgentSubmissionDispatchQueue { accepted, _, _ in
            await gate.hold()
            try? await coordinator.markDispatched(submissionID: accepted.receipt.submissionID)
        }
        let service = RepoPromptHTTPService(authority: fixture.authority, store: fixture.store, authenticator: InternalRequestAuthenticator(keys: [signingKey], store: fixture.store, now: { instant }), eventSigningKey: signingKey, submissionCoordinator: fixture.coordinator, submissionDispatchQueue: dispatchQueue, mutationGate: AuthorityMutationGate())
        let app = Application(router: service.internalRouter())
        let fallbackRelease = Task {
            try? await Task.sleep(for: .seconds(1))
            await gate.release()
        }
        let clock = ContinuousClock()
        let startedAt = clock.now
        let receipt = try await app.test(.router) { client in
            let headers = try structuredStartHeaders(body: body, actor: fixture.actor, projectID: fixture.sessionInput.projectID, idempotencyKey: submissionKey, nonce: "atomiclatency001", instant: instant, key: signingKey)
            return try await client.execute(uri: "/internal/v1/sessions", method: .post, headers: headers, body: ByteBuffer(bytes: body)) { response in
                XCTAssertEqual(response.status, .accepted)
                return try JSONDecoder.serviceDecoder.decode(SubmissionReceipt.self, from: Data(response.body.readableBytesView))
            }
        }
        let responseTime = startedAt.duration(to: clock.now)
        XCTAssertLessThan(responseTime, .milliseconds(500))
        XCTAssertEqual(receipt.runPhase, "preparing")
        await gate.waitUntilStarted()
        let pendingRecord = try await fixture.store.agentSubmission(submissionID: receipt.submissionID)
        let pending = try XCTUnwrap(pendingRecord)
        XCTAssertEqual(pending.dispatchState, "pending")
        fallbackRelease.cancel()
        await gate.release()
        await dispatchQueue.waitForIdle()
        let dispatchedRecord = try await fixture.store.agentSubmission(submissionID: receipt.submissionID)
        let dispatched = try XCTUnwrap(dispatchedRecord)
        XCTAssertEqual(dispatched.dispatchState, "dispatched")
    }

    func testLostResponseReplayReturnsOneSessionTurnAndStoredReceipt() async throws {
        let fixture = try await StructuredStartFixture.make()
        defer { Task { try? await fixture.store.close(); try? FileManager.default.removeItem(at: fixture.root) } }
        let key = UUID().uuidString.lowercased()
        let submission = AgentTurnSubmissionWire(
            content: .init(text: "accepted exactly once"),
            configuration: .init(catalogRevision: fixture.catalogRevision, providerID: .claudeCompatible, modelID: fixture.modelID, effortID: fixture.effortID, permissionID: "claude.requireApproval", toolValues: ["claude.mcpStrictMode": .boolean(true)])
        )

        let body = try JSONEncoder.serviceEncoder.encode(AgentStartSessionWire(projectID: fixture.sessionInput.projectID, visibility: fixture.sessionInput.visibility, turn: submission))
        let instant = Date(timeIntervalSince1970: 1_786_400_000)
        let signingKey = InternalSigningKey(keyID: "atomic-http", role: .app, direction: "test", secret: Data("atomic-http-secret".utf8))
        let dispatchQueue = AgentSubmissionDispatchQueue(authority: fixture.authority, coordinator: fixture.coordinator)
        let service = RepoPromptHTTPService(authority: fixture.authority, store: fixture.store, authenticator: InternalRequestAuthenticator(keys: [signingKey], store: fixture.store, now: { instant }), eventSigningKey: signingKey, submissionCoordinator: fixture.coordinator, submissionDispatchQueue: dispatchQueue, mutationGate: AuthorityMutationGate())
        let app = Application(router: service.internalRouter())
        let receipts = try await app.test(.router) { client in
            let firstHeaders = try structuredStartHeaders(body: body, actor: fixture.actor, projectID: fixture.sessionInput.projectID, idempotencyKey: key, nonce: "atomicreplay0001", instant: instant, key: signingKey)
            let first = try await client.execute(uri: "/internal/v1/sessions", method: .post, headers: firstHeaders, body: ByteBuffer(bytes: body)) { response in
                XCTAssertEqual(response.status, .accepted)
                return try JSONDecoder.serviceDecoder.decode(SubmissionReceipt.self, from: Data(response.body.readableBytesView))
            }
            let replayHeaders = try structuredStartHeaders(body: body, actor: fixture.actor, projectID: fixture.sessionInput.projectID, idempotencyKey: key, nonce: "atomicreplay0002", instant: instant, key: signingKey)
            let replay = try await client.execute(uri: "/internal/v1/sessions", method: .post, headers: replayHeaders, body: ByteBuffer(bytes: body)) { response in
                XCTAssertEqual(response.status, .accepted)
                return try JSONDecoder.serviceDecoder.decode(SubmissionReceipt.self, from: Data(response.body.readableBytesView))
            }
            let detailPath = "/internal/v1/sessions/\(first.sessionID.uuidString)/snapshot"
            let detailHeaders = try sessionSnapshotHeaders(actor: fixture.actor, sessionID: first.sessionID, path: detailPath, nonce: "atomicdetail0001", instant: instant, key: signingKey)
            let detail = try await client.execute(uri: detailPath, method: .get, headers: detailHeaders) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.headers[.cacheControl], "private, no-store")
                return try JSONDecoder.serviceDecoder.decode(SessionSnapshot.self, from: Data(response.body.readableBytesView))
            }
            return (first, replay, detail)
        }
        await dispatchQueue.waitForIdle()
        let accepted = receipts.0
        XCTAssertEqual(accepted, receipts.1)
        XCTAssertEqual(accepted.session?.effectiveTurnConfiguration?.configuration.modelID, fixture.modelID)
        XCTAssertEqual(accepted.session?.nextTurnDefaults?.configuration.configuration.modelID, fixture.modelID)
        XCTAssertEqual(accepted.session?.runPresentation?.runID, accepted.runID)
        XCTAssertEqual(receipts.2.effectiveTurnConfiguration?.configuration.modelID, fixture.modelID)
        XCTAssertEqual(receipts.2.nextTurnDefaults?.revision, 1)
        XCTAssertEqual(receipts.2.runPresentation?.runID, accepted.runID)
        XCTAssertGreaterThanOrEqual(receipts.2.runPresentation?.phaseRevision ?? 0, 1)
        let sessions = try await fixture.authority.sessionSnapshots()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.sessionID, accepted.sessionID)
        XCTAssertEqual(sessions.first?.transcript.map(\.content), ["accepted exactly once"])
        let turns = try await fixture.store.semanticTurns(sessionID: accepted.sessionID)
        XCTAssertEqual(turns.count, 1)
        let sessionEvents = try await fixture.store.database.query("SELECT event_type,COUNT(*) AS count FROM events WHERE session_id=? GROUP BY event_type", [.text(accepted.sessionID.uuidString)])
        XCTAssertEqual(sessionEvents.first { $0.column("event_type")?.string == EventType.sessionCreated.rawValue }?.column("count")?.integer, 1)
        XCTAssertEqual(sessionEvents.first { $0.column("event_type")?.string == EventType.agentStarted.rawValue }?.column("count")?.integer, 1)
        let storedReceipts = try await fixture.store.database.query("SELECT COUNT(*) AS count FROM agent_submissions WHERE state='accepted' AND receipt_json IS NOT NULL")
        XCTAssertEqual(storedReceipts.first?.column("count")?.integer, 1)
    }
}

private actor SubmissionDispatchGate {
    private var started = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func hold() async {
        started = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private struct FailingComposerCatalog: AgentComposerCatalogProviding {
    private struct Failure: Error {}

    func snapshot(context _: ComposerCatalogContext) async throws -> ComposerCatalogWireSnapshot { throw Failure() }
    func suggestions(context _: ComposerCatalogContext, query _: String, kinds _: Set<ComposerSuggestionWire.Kind>, limit _: Int) async throws -> ComposerSuggestionPageWire { throw Failure() }
    func validate(_: AgentTurnConfigurationWire, context _: ComposerCatalogContext, acceptedAt _: Date) async throws -> (EffectiveTurnConfigurationRecord, CompiledProviderTurnConfiguration, ProviderModelDescriptor, String?) { throw Failure() }
    func compatibilityModels() async throws -> [ModelCatalogItem] { throw Failure() }
}

private func composerCatalogHeaders(actor: ExternalActor, projectID: UUID, path: String, nonce: String, instant: Date, key: InternalSigningKey) throws -> HTTPFields {
    let bodyDigest = CanonicalSigning.bodyDigest(Data())
    let unsigned = AuthorizationDecision(
        decisionID: UUID(),
        actor: actor,
        projectID: projectID,
        operation: "getComposerCatalog",
        requestDigest: bodyDigest,
        policyRevision: 1,
        controllerRevision: 1,
        membershipRevision: 1,
        issuedAt: instant,
        expiresAt: instant.addingTimeInterval(30),
        requestID: UUID(),
        correlationID: UUID(),
        keyID: key.keyID,
        signature: ""
    )
    let unsignedData = try JSONEncoder.serviceEncoder.encode(unsigned)
    let decisionSignature = CanonicalSigning.hmacSHA256(message: try CanonicalSigning.canonicalJSONObject(unsignedData, removingTopLevelKeys: ["signature"]), key: key.secret)
    let decision = AuthorizationDecision(decisionID: unsigned.decisionID, actor: actor, projectID: projectID, operation: unsigned.operation, requestDigest: bodyDigest, policyRevision: 1, controllerRevision: 1, membershipRevision: 1, issuedAt: instant, expiresAt: unsigned.expiresAt, requestID: unsigned.requestID, correlationID: unsigned.correlationID, keyID: key.keyID, signature: decisionSignature)
    let decisionData = try JSONEncoder.serviceEncoder.encode(decision)
    let decisionDigest = CanonicalSigning.bodyDigest(decisionData)
    let timestamp = CanonicalSigning.iso8601String(instant)
    let canonical = CanonicalSigning.requestString(method: "GET", pathAndQuery: path, timestamp: timestamp, nonce: nonce, bodyDigest: bodyDigest, authorizationDecisionDigest: decisionDigest, keyID: key.keyID)
    var headers = HTTPFields()
    headers[.init("x-internal-key-id")!] = key.keyID
    headers[.init("x-internal-timestamp")!] = timestamp
    headers[.init("x-internal-nonce")!] = nonce
    headers[.init("x-internal-body-digest")!] = bodyDigest
    headers[.init("x-internal-authorization-digest")!] = decisionDigest
    headers[.init("x-internal-signature")!] = CanonicalSigning.hmacSHA256(message: canonical, key: key.secret)
    headers[.init("x-repoprompt-authorization-decision")!] = CanonicalSigning.base64URLEncode(decisionData)
    return headers
}

private func structuredStartHeaders(body: Data, actor: ExternalActor, projectID: UUID, idempotencyKey: String, nonce: String, instant: Date, key: InternalSigningKey) throws -> HTTPFields {
    let bodyDigest = CanonicalSigning.bodyDigest(body)
    let unsigned = AuthorizationDecision(
        decisionID: UUID(),
        actor: actor,
        projectID: projectID,
        operation: "startSession",
        requestDigest: bodyDigest,
        policyRevision: 1,
        controllerRevision: 1,
        membershipRevision: 1,
        issuedAt: instant,
        expiresAt: instant.addingTimeInterval(30),
        requestID: UUID(),
        correlationID: UUID(),
        keyID: key.keyID,
        signature: ""
    )
    let unsignedData = try JSONEncoder.serviceEncoder.encode(unsigned)
    let decisionSignature = CanonicalSigning.hmacSHA256(message: try CanonicalSigning.canonicalJSONObject(unsignedData, removingTopLevelKeys: ["signature"]), key: key.secret)
    let decision = AuthorizationDecision(decisionID: unsigned.decisionID, actor: actor, projectID: projectID, operation: unsigned.operation, requestDigest: bodyDigest, policyRevision: 1, controllerRevision: 1, membershipRevision: 1, issuedAt: instant, expiresAt: unsigned.expiresAt, requestID: unsigned.requestID, correlationID: unsigned.correlationID, keyID: key.keyID, signature: decisionSignature)
    let decisionData = try JSONEncoder.serviceEncoder.encode(decision)
    let decisionDigest = CanonicalSigning.bodyDigest(decisionData)
    let timestamp = CanonicalSigning.iso8601String(instant)
    let canonical = CanonicalSigning.requestString(method: "POST", pathAndQuery: "/internal/v1/sessions", timestamp: timestamp, nonce: nonce, bodyDigest: bodyDigest, authorizationDecisionDigest: decisionDigest, keyID: key.keyID)
    var headers = HTTPFields()
    headers[.init("content-type")!] = "application/json"
    headers[.init("x-internal-key-id")!] = key.keyID
    headers[.init("x-internal-timestamp")!] = timestamp
    headers[.init("x-internal-nonce")!] = nonce
    headers[.init("x-internal-body-digest")!] = bodyDigest
    headers[.init("x-internal-authorization-digest")!] = decisionDigest
    headers[.init("x-internal-signature")!] = CanonicalSigning.hmacSHA256(message: canonical, key: key.secret)
    headers[.init("x-repoprompt-authorization-decision")!] = CanonicalSigning.base64URLEncode(decisionData)
    headers[.init("idempotency-key")!] = idempotencyKey
    return headers
}

private func sessionSnapshotHeaders(actor: ExternalActor, sessionID: UUID, path: String, nonce: String, instant: Date, key: InternalSigningKey) throws -> HTTPFields {
    let body = Data()
    let bodyDigest = CanonicalSigning.bodyDigest(body)
    let unsigned = AuthorizationDecision(
        decisionID: UUID(),
        actor: actor,
        sessionID: sessionID,
        operation: "getSession",
        requestDigest: bodyDigest,
        policyRevision: 1,
        controllerRevision: 1,
        membershipRevision: 1,
        issuedAt: instant,
        expiresAt: instant.addingTimeInterval(30),
        requestID: UUID(),
        correlationID: UUID(),
        keyID: key.keyID,
        signature: ""
    )
    let unsignedData = try JSONEncoder.serviceEncoder.encode(unsigned)
    let decisionSignature = CanonicalSigning.hmacSHA256(message: try CanonicalSigning.canonicalJSONObject(unsignedData, removingTopLevelKeys: ["signature"]), key: key.secret)
    let decision = AuthorizationDecision(decisionID: unsigned.decisionID, actor: actor, sessionID: sessionID, operation: unsigned.operation, requestDigest: bodyDigest, policyRevision: 1, controllerRevision: 1, membershipRevision: 1, issuedAt: instant, expiresAt: unsigned.expiresAt, requestID: unsigned.requestID, correlationID: unsigned.correlationID, keyID: key.keyID, signature: decisionSignature)
    let decisionData = try JSONEncoder.serviceEncoder.encode(decision)
    let decisionDigest = CanonicalSigning.bodyDigest(decisionData)
    let timestamp = CanonicalSigning.iso8601String(instant)
    let canonical = CanonicalSigning.requestString(method: "GET", pathAndQuery: path, timestamp: timestamp, nonce: nonce, bodyDigest: bodyDigest, authorizationDecisionDigest: decisionDigest, keyID: key.keyID)
    var headers = HTTPFields()
    headers[.init("x-internal-key-id")!] = key.keyID
    headers[.init("x-internal-timestamp")!] = timestamp
    headers[.init("x-internal-nonce")!] = nonce
    headers[.init("x-internal-body-digest")!] = bodyDigest
    headers[.init("x-internal-authorization-digest")!] = decisionDigest
    headers[.init("x-internal-signature")!] = CanonicalSigning.hmacSHA256(message: canonical, key: key.secret)
    headers[.init("x-repoprompt-authorization-decision")!] = CanonicalSigning.base64URLEncode(decisionData)
    return headers
}

private struct StructuredStartFixture {
    let root: URL
    let store: SQLiteServiceStore
    let authority: RepoPromptHeadlessAuthority
    let coordinator: AgentSubmissionCoordinator
    let providerSettings: ProviderSettingsService
    let actor: ExternalActor
    let sessionInput: CreateSessionInput
    let catalogRevision: String
    let modelID: String
    let effortID: String?

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let actor = ExternalActor(userID: "atomic-start-owner", username: "owner", displayName: "Owner")
        let authority = RepoPromptHeadlessAuthority(store: store)
        let project = try await authority.createProject(input: .init(name: "Atomic start", roots: []), externalActor: actor, idempotencyKey: "project", requestDigest: "project")
        let environment = ProcessInfo.processInfo.environment
        let swiftCommand = environment["SWIFT_EXEC"] ?? "swift"
        guard let swiftExecutable = PortableExecutableDiscovery.resolve(
            named: swiftCommand,
            path: environment["PATH"]
        ) else {
            throw XCTSkip("A Swift executable is required to verify provider readiness")
        }
        let configuration = ProviderCLIConfiguration(kind: .claudeCompatible, executable: swiftExecutable, protocolVersion: "stream-json-v1", credentialSourceDirectory: root.path)
        let now = Date()
        let connection = ProviderConnectionRecord(connectionID: UUID(), providerID: .claudeCompatible, authenticationMethod: .providerSpecific, state: .connected, accountLabel: "test", lastTestedAt: now, testState: .valid, detail: "Connected", keyHelperConfigured: false, workloadIdentityConfigured: false, createdAt: now, updatedAt: now, revision: 1)
        _ = try await store.upsertProviderConnection(.init(record: connection, credentialReference: nil), expectedRevision: 0)
        let runner = StructuredStartProviderRunner()
        let providerAdapter = ProviderCLIAdapter(configurations: [configuration], enabledProviders: [.claudeCompatible], runner: runner)
        let modelID = "claude-runtime-test"
        let modelCatalogPath = root.appendingPathComponent("claude-models.json")
        try JSONEncoder.serviceEncoder.encode([
            ProviderModelCatalogEntry(id: modelID, displayName: "Claude Runtime Test", isProviderDefault: true, reasoningEfforts: ["high"], defaultReasoningEffort: "high", supportsNativeImages: true)
        ]).write(to: modelCatalogPath)
        let settings = ProviderSettingsService(store: store, adapter: providerAdapter, configurations: [configuration], initiallyEnabled: [.claudeCompatible], modelCatalogFiles: [.claudeCompatible: modelCatalogPath.path], runner: runner)
        try await settings.bootstrap()
        let initialSettings = try await settings.catalog()
        let claude = try XCTUnwrap(initialSettings.providers.first { $0.providerID == .claudeCompatible })
        _ = try await settings.update(providerID: .claudeCompatible, request: .init(expectedRevision: claude.preference.revision, enabled: true, defaultModel: modelID, reasoningEffort: nil, speedMode: nil, serviceTier: nil))
        let refreshed = try await settings.catalog(refreshCLI: true, refreshRuntime: true)
        XCTAssertTrue(refreshed.providers.first(where: { $0.providerID == .claudeCompatible })?.preflight.ready == true)
        let catalog = AgentComposerCatalogService(providerSettings: settings, store: store)
        let snapshot = try await catalog.snapshot(context: .init(kind: .project, projectID: project.projectID, actorID: actor.userID))
        let model = try XCTUnwrap(snapshot.providerGroups.first { $0.providerID == .claudeCompatible }?.models.first)
        let attachments = try AgentComposerAttachmentStore(store: store, configuration: .init(stagingRoot: root.appendingPathComponent("staged").path, acceptedRoot: root.appendingPathComponent("accepted").path, minimumFreeBytes: 0))
        let coordinator = AgentSubmissionCoordinator(store: store, catalog: catalog, compiler: AgentTurnIntentCompiler(), attachments: attachments)
        return .init(root: root, store: store, authority: authority, coordinator: coordinator, providerSettings: settings, actor: actor, sessionInput: .init(projectID: project.projectID, provider: .claudeCompatible, model: model.id, visibility: .privateSession, startImmediately: false), catalogRevision: snapshot.revision, modelID: model.id, effortID: model.defaultEffortID)
    }
}

private actor StructuredStartProviderRunner: WorkspaceCommandRunning {
    func run(executable _: String, arguments: [String], workingDirectory _: String, maximumBytes _: Int) async throws -> String {
        response(arguments)
    }

    func run(executable _: String, arguments: [String], workingDirectory _: String, maximumBytes _: Int, environment _: [String: String]) async throws -> String {
        response(arguments)
    }

    private nonisolated func response(_ arguments: [String]) -> String {
        if arguments == ["auth", "status", "--json"] { return #"{"loggedIn":true}"# }
        return "Swift version 6.2"
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
