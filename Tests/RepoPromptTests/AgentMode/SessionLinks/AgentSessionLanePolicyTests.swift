import Foundation
import RepoPromptSettingsCore
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class AgentSessionLanePolicyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        GlobalSettingsStore.installApplicationModelIdentityPolicy()
    }

    @MainActor
    func testSharedWarmCompletionDoesNotInvalidateAlreadyAdvertisedModels() async throws {
        let registry = AgentACPModelRegistry.shared
        let catalogue = AgentAdvertisedModelCatalog.shared
        let availability = AgentModelCatalog.AvailabilityContext(openCodeAvailable: true)
        registry.test_reset(providerID: .openCode)
        defer { registry.test_reset(providerID: .openCode) }
        let option = AgentModelOption(
            rawValue: "warm-race-model", displayName: "Warm race", description: nil,
            isPlaceholderDefault: false, isProviderDefault: false
        )
        XCTAssertTrue(registry.updateDiscoveredModels(
            ACPDiscoveredSessionModels(options: [option], currentModelRaw: option.rawValue), for: .openCode
        ))
        registry.test_clearMemoryPreservingStore(providerID: .openCode)
        let firstGate = ACPWarmCompletionGate()
        let secondGate = ACPWarmCompletionGate()
        let firstParked = expectation(description: "First waiter loaded the shared warm task")
        let secondParked = expectation(description: "Second waiter loaded the shared warm task")
        let first = Task {
            await registry.warmStandardStoreIfNeeded(beforeCompleting: {
                firstParked.fulfill()
                await firstGate.wait()
            })
        }
        await fulfillment(of: [firstParked], timeout: 5)
        let second = Task {
            await registry.warmStandardStoreIfNeeded(beforeCompleting: {
                secondParked.fulfill()
                await secondGate.wait()
            })
        }
        await fulfillment(of: [secondParked], timeout: 5)
        await firstGate.open()
        await first.value
        let options = AgentModelCatalog.options(for: .openCode, availability: availability)
        XCTAssertTrue(options.contains { $0.rawValue == option.rawValue })
        XCTAssertNoThrow(try catalogue.selection("openCode:warm-race-model", availability: availability))
        let generationAfterAdvertising = catalogue.productionGeneration(for: .openCode)
        await secondGate.open()
        await second.value
        XCTAssertEqual(
            catalogue.productionGeneration(for: .openCode), generationAfterAdvertising,
            "The second waiter must not invalidate the first waiter's newly advertised catalogue"
        )
        XCTAssertNoThrow(
            try catalogue.selection("openCode:warm-race-model", availability: availability),
            "A model just advertised without source changes must remain admissible"
        )
    }

    func testExplicitModelUsesAdvertisedFullIDWithoutRoleSubstitution() throws {
        let availability = AgentModelCatalog.AvailabilityContext(cursorAvailable: true, grokBuildAvailable: true)
        // Use the production producer, not another list of accepted models.
        let entries = AgentModelCatalog.discoveryAgents(availability: availability)
        defer {
            for entry in entries {
                AgentAdvertisedModelCatalog.shared.invalidate(entry.agent)
            }
        }
        for entry in entries where entry.available {
            guard AgentModelCatalog.AgentSelectionSurface.headless.allows(entry.agent) else { continue }
            for model in entry.models {
                for target in model.startTargets {
                    let selected = try AgentSessionLanePolicy.resolveModel(target.selectionID.rawValue, availability: availability)
                    XCTAssertEqual(selected.role, .pair, "Explicit models keep the default selection label, not a permission grant")
                    XCTAssertEqual(selected.agentRaw, entry.agent.rawValue)
                    XCTAssertEqual(selected.modelRaw, target.modelRaw)
                    XCTAssertTrue(selected.modelParameterSelections.isEmpty)
                }
            }
        }
        XCTAssertThrowsError(try AgentSessionLanePolicy.resolveModel("pair", availability: availability))
        XCTAssertThrowsError(try AgentSessionLanePolicy.resolveModel("codexExec:unadvertised-future-model-high", availability: availability))
        XCTAssertNotNil(
            AgentModelCatalog.resolveSelectionID("codexExec:unadvertised-future-model-high", availability: availability),
            "Legacy launch resolver remains permissive"
        )
    }

    func testACPResetInvalidatesProducerThatReadBeforeMemoryWasCleared() throws {
        let registry = AgentACPModelRegistry.shared
        let catalogue = AgentAdvertisedModelCatalog.shared
        let availability = AgentModelCatalog.AvailabilityContext(openCodeAvailable: true)
        registry.test_reset(providerID: .openCode)
        defer { registry.test_reset(providerID: .openCode) }
        let option = AgentModelOption(
            rawValue: "reset-race-model", displayName: "Reset race", description: nil,
            isPlaceholderDefault: false, isProviderDefault: false
        )
        for preserveStore in [false, true] {
            XCTAssertTrue(registry.updateDiscoveredModels(
                ACPDiscoveredSessionModels(options: [option], currentModelRaw: option.rawValue), for: .openCode
            ))
            var producerGeneration: UInt64 = 0
            var producerOptions: [AgentModelOption] = []
            let beforeClear = {
                // Deterministically interleave a real producer after the first invalidation,
                // while the old registry snapshot is still readable.
                producerGeneration = catalogue.productionGeneration(for: .openCode)
                producerOptions = AgentModelCatalog.options(for: .openCode, availability: availability)
                XCTAssertTrue(producerOptions.contains { $0.rawValue == option.rawValue })
                do {
                    _ = try catalogue.selection("openCode:reset-race-model", availability: availability)
                } catch {
                    XCTFail("Interleaved producer should publish the still-readable snapshot: \(error)")
                }
            }
            if preserveStore {
                registry.test_clearMemoryPreservingStore(providerID: .openCode, beforeClearingMemory: beforeClear)
            } else {
                registry.test_reset(providerID: .openCode, beforeClearingMemory: beforeClear)
            }
            XCTAssertNil(registry.resolvedSnapshot(for: .openCode))
            XCTAssertThrowsError(try catalogue.selection("openCode:reset-race-model", availability: availability))
            XCTAssertFalse(
                catalogue.record(producerOptions, for: .openCode, generation: producerGeneration),
                "A paused producer must not republish the removed snapshot after reset"
            )
        }
    }

    func testBackendConfigurationChangeInvalidatesAdmissionAndFencesPausedProducers() throws {
        let catalogue = AgentAdvertisedModelCatalog.shared
        let agents: [AgentProviderKind] = [.claudeCodeGLM, .kimiCode, .customClaudeCompatible]
        let availability = AgentModelCatalog.AvailabilityContext(
            zaiConfigured: true, kimiConfigured: true, customClaudeCompatibleConfigured: true
        )
        let option = AgentModelOption(
            rawValue: "claude-opus-5-5", displayName: "Model", description: nil,
            isPlaceholderDefault: false, isProviderDefault: false
        )
        let generations = Dictionary(uniqueKeysWithValues: agents.map {
            ($0, catalogue.productionGeneration(for: $0))
        })
        defer { agents.forEach { catalogue.invalidate($0) } }
        for agent in agents {
            XCTAssertTrue(try catalogue.record([option], for: agent, generation: XCTUnwrap(generations[agent])))
            XCTAssertNoThrow(try catalogue.selection("\(agent.rawValue):\(option.rawValue)", availability: availability))
        }

        let suiteName = "backend-admission-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // A separate store exercises the process-wide invalidator without changing real preferences.
        ClaudeCodeCompatibleBackendStore(defaults: defaults).saveConfig(ClaudeCodeCompatibleBackendID.custom.defaultPreset)

        for agent in agents {
            XCTAssertThrowsError(try catalogue.selection("\(agent.rawValue):\(option.rawValue)", availability: availability)) {
                XCTAssertEqual($0 as? AgentAdvertisedModelCatalog.AdmissionError, .catalogueUnavailable)
            }
            XCTAssertFalse(try catalogue.record([option], for: agent, generation: XCTUnwrap(generations[agent])))
        }
    }

    func testMemoryOnlyAdmissionDoesNotDiscoverOrSubstituteMissingCatalogue() throws {
        let catalogue = AgentAdvertisedModelCatalog()
        let availability = AgentModelCatalog.AvailabilityContext(cursorAvailable: true)
        XCTAssertThrowsError(try catalogue.selection("cursor:auto", availability: availability)) { error in
            XCTAssertEqual(error as? AgentAdvertisedModelCatalog.AdmissionError, .catalogueUnavailable)
        }
        let dynamic = AgentModelOption(
            rawValue: "future-model-high",
            displayName: "Future",
            description: nil,
            isPlaceholderDefault: false,
            isProviderDefault: false
        )
        catalogue.record([dynamic], for: .codexExec, generation: catalogue.productionGeneration(for: .codexExec))
        let selected = try catalogue.selection("codexExec:future-model-high", availability: availability)
        XCTAssertEqual(selected.storedModelRaw, "future-model-high")
        XCTAssertEqual(selected.reasoningEffortRaw, "high")
        XCTAssertThrowsError(try catalogue.selection("codexExec:future-model-low", availability: availability))
        XCTAssertThrowsError(try catalogue.selection("codexExec:future-model-high", availability: .none))
        catalogue.invalidate(.codexExec)
        XCTAssertThrowsError(try catalogue.selection("codexExec:future-model-high", availability: availability)) { error in
            XCTAssertEqual(error as? AgentAdvertisedModelCatalog.AdmissionError, .catalogueUnavailable)
        }
        let colon = AgentModelOption(
            rawValue: "vendor:model:variant",
            displayName: "Colon",
            description: nil,
            isPlaceholderDefault: false,
            isProviderDefault: false
        )
        catalogue.record([colon], for: .openCode, generation: catalogue.productionGeneration(for: .openCode))
        XCTAssertEqual(
            try catalogue.selection("openCode:vendor:model:variant", availability: availability).storedModelRaw,
            "vendor:model:variant"
        )
    }

    func testNativeCataloguePreservesOnlyExplicitEffortAndInvalidatesPerAgent() throws {
        let catalogue = AgentAdvertisedModelCatalog()
        let availability = AgentModelCatalog.AvailabilityContext()
        let generation = catalogue.productionGeneration(for: .claudeCode)
        let options = ["claude-opus-5-5", "claude-opus-5-5:high"].map {
            AgentModelOption(
                rawValue: $0,
                displayName: $0,
                description: nil,
                isPlaceholderDefault: false,
                isProviderDefault: false
            )
        }
        catalogue.invalidate(.codexExec)
        XCTAssertTrue(catalogue.record(options, for: .claudeCode, generation: generation))
        XCTAssertNil(try catalogue.selection("claudeCode:claude-opus-5-5", availability: availability).reasoningEffortRaw)
        XCTAssertEqual(
            try catalogue.selection("claudeCode:claude-opus-5-5:high", availability: availability).reasoningEffortRaw,
            "high"
        )
    }

    @MainActor
    func testMCPCompatibleNativeConfigurationPreservesExplicitPinAndClearsNilPins() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lane-native-pin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        defer {
            WindowStatesManager.shared.unregisterWindowState(window)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        }
        let workspace = window.workspaceManager.createWorkspace(
            name: "Compatible native pin", repoPaths: [root.path], ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: "compatibleNativePinTests")
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        let tabID = try XCTUnwrap(activeWorkspace.activeComposeTabID)
        let viewModel = window.agentModeViewModel
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        session.isMCPOriginated = true
        for agent in AgentProviderKind.allCases where agent.usesClaudeNativeRuntime && agent != .claudeCode {
            try await viewModel.mcpConfigureSession(
                tabID: tabID, agentRaw: agent.rawValue, modelRaw: "default", reasoningEffortRaw: "high"
            )
            XCTAssertEqual(session.selectedAgent, agent)
            XCTAssertEqual(session.selectedReasoningEffortRaw, "high", agent.rawValue)
            try await viewModel.mcpConfigureSession(
                tabID: tabID, agentRaw: agent.rawValue, modelRaw: "default", reasoningEffortRaw: nil
            )
            XCTAssertNil(session.selectedReasoningEffortRaw, "Same-agent unpinned selection: \(agent.rawValue)")
            session.selectedAgent = .codexExec
            session.selectedReasoningEffortRaw = "xhigh"
            try await viewModel.mcpConfigureSession(
                tabID: tabID, agentRaw: agent.rawValue, modelRaw: "default", reasoningEffortRaw: nil
            )
            XCTAssertEqual(session.selectedAgent, agent)
            XCTAssertNil(session.selectedReasoningEffortRaw, "Inherited provider pin: \(agent.rawValue)")
        }
    }

    func testCreateLaneDigestDistinguishesExplicitModelFromRoleAndDefault() {
        let original = AgentSessionLaneCreateRequest(
            idempotencyKey: "key",
            role: nil,
            sessionName: nil,
            message: nil,
            workflowReference: nil
        )
        let role = AgentSessionLaneCreateRequest(
            idempotencyKey: "key",
            role: "pair",
            sessionName: nil,
            message: nil,
            workflowReference: nil
        )
        var explicit = original
        explicit.modelID = "codexExec:gpt-5.4-high"
        XCTAssertEqual(original.digest, role.digest, "Preserve default role retry identity")
        XCTAssertNotEqual(original.digest, explicit.digest)
        var changed = explicit
        changed.modelID = "codexExec:gpt-5.4-low"
        XCTAssertNotEqual(explicit.digest, changed.digest)
    }

    @MainActor
    func testEveryRoleUsesItsEffectiveRoleDefaultAndMappedEffort() throws {
        let workspaceID = UUID()
        let overrides = Dictionary(
            uniqueKeysWithValues: AgentModelCatalog.TaskLabelKind.allCases.map {
                ($0.rawValue, "codexExec:gpt-5.4-high")
            }
        )
        let settings = AgentModelsProfileRoleDefaultsStore(overrides: overrides)
        let availability = AgentModelCatalog.AvailabilityContext()
        for role in AgentModelCatalog.TaskLabelKind.allCases {
            let selected = try AgentSessionLanePolicy.resolveRole(
                role.rawValue,
                availability: availability,
                workspaceID: workspaceID,
                settingsStore: settings
            )
            XCTAssertEqual(selected.role, role)
            XCTAssertEqual(selected.agentRaw, AgentProviderKind.codexExec.rawValue)
            XCTAssertEqual(selected.modelRaw, "gpt-5.4-high")
            XCTAssertEqual(selected.reasoningEffortRaw, "high")
        }
    }

    @MainActor
    func testFreshHandoffDestinationDoesNotInheritCreatorProvenance() {
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        let destination = viewModel.session(for: UUID())
        destination.createdByOverseerSessionID = UUID()
        viewModel.markSessionAsFreshlyCreated(destination)
        XCTAssertNil(destination.createdByOverseerSessionID)
        XCTAssertNil(AgentSession(id: UUID()).createdByOverseerSessionID)
    }

    @MainActor
    func testHandoffBuiltAgentSessionDoesNotCopySourceCreatorProvenance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lane-handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let cleanup: @MainActor () async -> Void = {
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
        }
        do {
            await window.workspaceManager.awaitInitialized()
            let workspace = window.workspaceManager.createWorkspace(
                name: "Lane handoff provenance", repoPaths: [root.path], ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace, saveState: false, reason: "laneHandoffProvenanceTest"
            )
            let sourceTabID = UUID()
            let sourceSessionID = UUID()
            let sourceTab = ComposeTabState(id: sourceTabID, name: "Source", activeAgentSessionID: sourceSessionID)
            let workspaceIndex = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex {
                $0.id == workspace.id
            })
            window.workspaceManager.workspaces[workspaceIndex].composeTabs = [sourceTab]
            window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = sourceTabID
            window.promptManager.loadComposeTabsFromWorkspace(
                window.workspaceManager.workspaces[workspaceIndex], syncPromptText: true
            )
            let viewModel = window.agentModeViewModel
            let source = viewModel.session(for: sourceTabID)
            source.hasLoadedPersistedState = true
            source.createdByOverseerSessionID = UUID()
            source.setItemsSilently([
                .user("Source user", sequenceIndex: 0),
                .assistant("Source assistant", sequenceIndex: 1)
            ], reason: .testOverride)
            viewModel.refreshDerivedTranscriptState(for: source)
            viewModel.setAgentModeActive(true)
            var savedCreator: UUID?
            var saveWasCalled = false
            viewModel.test_setAgentSessionSaver { session, _, _ in
                savedCreator = session.createdByOverseerSessionID
                saveWasCalled = true
                return root.appendingPathComponent("handoff-session.json")
            }
            let cutoff = try XCTUnwrap(source.items.last?.id)
            let destinationTabID = try await viewModel.prepareHandoffToNewTab(
                upToItemID: cutoff,
                destinationAgent: source.selectedAgent,
                destinationModelRaw: source.selectedModelRaw,
                destinationReasoningEffortRaw: source.selectedReasoningEffortRaw
            )
            XCTAssertTrue(saveWasCalled)
            XCTAssertNil(savedCreator)
            XCTAssertNil(viewModel.sessions[destinationTabID]?.createdByOverseerSessionID)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @MainActor
    func testUnmappedOrUnusableRolesFailClosedWithoutSubstitution() {
        let availability = AgentModelCatalog.AvailabilityContext()
        let workspaceID = UUID()
        let badOverride = AgentModelsProfileRoleDefaultsStore(overrides: ["pair": "no-such-provider:model"])
        XCTAssertThrowsError(try AgentSessionLanePolicy.resolveRole(
            "pair",
            availability: availability,
            workspaceID: workspaceID,
            settingsStore: badOverride
        )) { error in
            XCTAssertEqual(error as? AgentSessionLanePolicy.RoleResolutionError, .roleUnavailable)
        }
        XCTAssertThrowsError(try AgentSessionLanePolicy.resolveRole(
            "unrecognized",
            availability: availability,
            workspaceID: workspaceID
        )) { error in
            XCTAssertEqual(error as? AgentSessionLanePolicy.RoleResolutionError, .roleUnavailable)
        }
        XCTAssertThrowsError(try AgentSessionLanePolicy.resolveRole(
            "pair",
            availability: AgentModelCatalog.AvailabilityContext(
                claudeCodeAvailable: false,
                codexAvailable: false,
                openCodeAvailable: false
            ),
            workspaceID: workspaceID
        )) { error in
            XCTAssertEqual(error as? AgentSessionLanePolicy.RoleResolutionError, .roleUnavailable)
        }
    }
}

private actor ACPWarmCompletionGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
