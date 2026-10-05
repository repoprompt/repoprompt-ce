import Foundation
@testable import RepoPromptApp
import RepoPromptSettingsCore
import XCTest

final class ClaudeNativeEffortResolutionTests: XCTestCase {
    private actor FixedModelResolver: ClaudeCodeLaunchEnvironmentResolving {
        func resolve(
            variant _: ClaudeCodeRuntimeVariant,
            requestedModel _: String?
        ) async throws -> ClaudeCodeLaunchEnvironment {
            ClaudeCodeLaunchEnvironment(
                effectiveModel: "claude-opus-5-5",
                environmentOverrides: [:],
                backend: .defaultClaude
            )
        }
    }

    private actor EffortRequests {
        var levels: [String] = []
        func record(_ level: String?) {
            if let level {
                levels.append(level)
            }
        }
    }

    @MainActor
    private func withClaudeDefaults(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let keys = ["claudeCodeEffortLevel", "claudeCodeEffortLevelsByModelSlug"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.removeObject(forKey: keys[1])
        ClaudeAgentToolPreferences.setEffortLevel(.high)
        try body()
    }

    @MainActor
    private func effortViewModel(windowID: Int = 1) -> AgentModeViewModel {
        AgentModeViewModel(
            testWindowID: windowID,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Effort selection tests must not start Codex")
            },
            claudeControllerFactory: { _, _, _, _ in
                preconditionFailure("Effort selection tests must not start Claude")
            },
            headlessProviderFactory: { _, _ in UnsupportedHeadlessAgentProvider(reason: "effort selection test") },
            mcpServerEnabler: { false }
        )
    }

    @MainActor
    private func activeEffortSession(in viewModel: AgentModeViewModel) -> AgentTabSession {
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = viewModel.session(for: tabID)
        session.selectedModelRaw = "claude-opus-5-5"
        viewModel.updateBindingsFromSession(session)
        return session
    }

    @MainActor
    func testClaudeEffortChangeKeepsOtherWindowSessionAndControlsUnchanged() {
        withClaudeDefaults {
            let first = effortViewModel()
            let second = effortViewModel(windowID: 2)
            let firstSession = activeEffortSession(in: first)
            let secondSession = activeEffortSession(in: second)
            defer {
                firstSession.saveDebounceTask?.cancel()
                secondSession.saveDebounceTask?.cancel()
            }
            XCTAssertEqual(second.claudeCoordinator.currentClaudeEffortLevel(for: secondSession), .high)
            let settings = AgentProviderPermissionsSettingsViewModel(
                bindingService: second.providerBindingService,
                claudeEffortLevelProvider: { second.claudeCoordinator.currentClaudeEffortLevel(for: secondSession) }
            )
            XCTAssertEqual(settings.controlsBinding(for: .claude)?.claudeTools?.effortLevel, .high)

            first.setClaudeEffortLevel(.low)
            second.updatePermissionBindingState(from: secondSession, syncUI: false)

            XCTAssertEqual(firstSession.persistedReasoningEffortRaw, "low")
            XCTAssertEqual(secondSession.persistedReasoningEffortRaw, "high")
            XCTAssertEqual(first.activeProviderControlsBinding?.claudeTools?.effortLevel, .low)
            XCTAssertEqual(second.activeProviderControlsBinding?.claudeTools?.effortLevel, .high)
            XCTAssertEqual(settings.controlsBinding(for: .claude)?.claudeTools?.effortLevel, .high)
            XCTAssertEqual(second.claudeCoordinator.currentClaudeEffortLevel(for: secondSession), .high)
            XCTAssertEqual(ClaudeAgentToolPreferences.effortLevel(
                forModelRaw: "claude-opus-5-5", agentKind: .claudeCode
            ), .low)
        }
    }

    @MainActor
    func testNewClaudeSessionUsesLastUsedDefaultWithoutChangingExistingSession() {
        withClaudeDefaults {
            let first = effortViewModel()
            let second = effortViewModel(windowID: 2)
            let existing = activeEffortSession(in: first)
            let edited = activeEffortSession(in: second)
            defer {
                existing.saveDebounceTask?.cancel()
                edited.saveDebounceTask?.cancel()
            }
            second.setClaudeEffortLevel(.low)

            let newSession = first.session(for: UUID())
            defer { newSession.saveDebounceTask?.cancel() }
            XCTAssertEqual(first.claudeCoordinator.currentClaudeEffortLevel(for: newSession), .low)
            XCTAssertEqual(first.claudeCoordinator.currentClaudeEffortLevel(for: existing), .high)
        }
    }

    @MainActor
    func testNewClaudeSessionPreservesExplicitEncodedEffortOverLastUsedDefault() {
        withClaudeDefaults {
            let viewModel = effortViewModel()
            viewModel.selectedAgent = .claudeCode
            viewModel.selectModel(rawModel: "claude-opus-5-5:low")
            let session = viewModel.session(for: UUID())
            defer { session.saveDebounceTask?.cancel() }

            XCTAssertEqual(viewModel.claudeCoordinator.currentClaudeEffortLevel(for: session), .low)
            XCTAssertEqual(session.persistedReasoningEffortRaw, "low")
            XCTAssertEqual(ClaudeAgentToolPreferences.effortLevel(
                forModelRaw: session.selectedModelRaw, agentKind: .claudeCode
            ), .high)
        }
    }

    @MainActor
    func testRestoredClaudeEffortSurvivesChangedDefaultsAndEncodedModel() throws {
        try withClaudeDefaults {
            let persisted = AgentSession(
                name: "Saved effort", agentKind: AgentProviderKind.claudeCode.rawValue,
                agentModel: "claude-opus-5-5:high", agentReasoningEffort: "low"
            )
            let decoded = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(persisted))
            let viewModel = effortViewModel()
            let session = activeEffortSession(in: viewModel)
            defer { session.saveDebounceTask?.cancel() }
            session.selectedModelRaw = try XCTUnwrap(decoded.agentModel)
            viewModel.restoreClaudeEffort(from: decoded, to: session)
            viewModel.updatePermissionBindingState(from: session, syncUI: false)

            XCTAssertEqual(session.persistedReasoningEffortRaw, "low")
            XCTAssertEqual(viewModel.claudeCoordinator.currentClaudeEffortLevel(for: session), .low)
            XCTAssertEqual(viewModel.activeProviderControlsBinding?.claudeTools?.effortLevel, .low)
        }
    }

    @MainActor
    func testLegacyClaudeSessionAdoptsDefaultOnceAndPersistsIt() throws {
        try withClaudeDefaults {
            let legacy = AgentSession(name: "Legacy effort", agentKind: AgentProviderKind.claudeCode.rawValue)
            let viewModel = effortViewModel()
            let session = activeEffortSession(in: viewModel)
            defer { session.saveDebounceTask?.cancel() }
            viewModel.restoreClaudeEffort(from: legacy, to: session)
            XCTAssertEqual(session.persistedReasoningEffortRaw, "high")

            ClaudeAgentToolPreferences.setEffortLevel(.low, forModelRaw: session.selectedModelRaw, agentKind: .claudeCode)
            XCTAssertEqual(viewModel.claudeCoordinator.currentClaudeEffortLevel(for: session), .high)
            let saved = AgentSession(name: "Adopted effort", agentReasoningEffort: session.persistedReasoningEffortRaw)
            let restored = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(saved))
            viewModel.restoreClaudeEffort(from: restored, to: session)
            XCTAssertEqual(viewModel.claudeCoordinator.currentClaudeEffortLevel(for: session), .high)
        }
    }

    @MainActor
    func testClaudePickerOverridesEncodedEffortInBothControlsAndExecutionResolver() {
        withClaudeDefaults {
            let viewModel = effortViewModel()
            let session = activeEffortSession(in: viewModel)
            defer { session.saveDebounceTask?.cancel() }
            viewModel.selectModel(rawModel: "claude-opus-5-5:high")
            viewModel.setClaudeEffortLevel(.low)
            XCTAssertEqual(viewModel.claudeCoordinator.currentClaudeEffortLevel(for: session), .low)
            XCTAssertEqual(viewModel.activeProviderControlsBinding?.claudeTools?.effortLevel, .low)

            viewModel.selectModel(rawModel: "claude-opus-5-5:high")
            XCTAssertEqual(viewModel.claudeCoordinator.currentClaudeEffortLevel(for: session), .high)
            XCTAssertEqual(viewModel.activeProviderControlsBinding?.claudeTools?.effortLevel, .high)
        }
    }

    @MainActor
    func testNativeConfigurationUsesSessionEffortRatherThanSharedOrEncodedEffort() async {
        let requests = EffortRequests()
        let controller = ClaudeNativeProcessSessionController(
            runID: UUID(), tabID: UUID(), windowID: 1, workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false", runtimeVariant: .standard),
            environmentResolver: FixedModelResolver()
        )
        await controller.test_installConfigurationTransport(controlRequest: { request in
            await requests.record((request["settings"] as? [String: Any])?["effortLevel"] as? String)
            return [:]
        }, write: { _ in })
        let coordinator = ClaudeAgentModeCoordinator(
            windowID: 1, workspacePathProvider: { _ in nil },
            claudeControllerFactory: { _, _, _, _ in controller }
        )
        let session = AgentTabSession(tabID: UUID())
        session.selectedModelRaw = "claude-opus-5-5:high"
        session.selectedClaudeEffortRaw = "low"
        session.claudeController = controller

        await coordinator.applyCurrentClaudeModelAndEffortIfPossible(for: session, reason: "test.session-effort")
        let levels = await requests.levels
        XCTAssertEqual(levels, ["low"])
    }

    func testTurnScopedEffortOverridesEncodedModelEffortInFlagSettings() async throws {
        let controller = ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false", runtimeVariant: .standard),
            environmentResolver: FixedModelResolver()
        )

        let overridden = try await controller.test_resolveApplyFlagSettingsRequest(
            model: "claude-opus-5-5:high",
            effortLevel: .low
        )
        XCTAssertEqual((overridden?["settings"] as? [String: Any])?["effortLevel"] as? String, "low")

        let baseline = try await controller.test_resolveApplyFlagSettingsRequest(
            model: "claude-opus-5-5:high",
            effortLevel: nil
        )
        XCTAssertEqual((baseline?["settings"] as? [String: Any])?["effortLevel"] as? String, "high")
    }

    @MainActor
    func testMCPExplicitClaudeEffortPinWinsOverStoredPreference() {
        let extracted = AgentExternalMCPRunStarter.extractReasoningEffort(from: "claude-opus-5-5:low")
        XCTAssertEqual(extracted.model, "claude-opus-5-5:low")
        XCTAssertEqual(extracted.effort, "low")
        XCTAssertEqual(ClaudeAgentModeCoordinator.resolvedMCPPinnedEffort(
            modelRaw: "claude-opus-5-5:low",
            agentKind: .claudeCode,
            pinnedEffortRaw: extracted.effort,
            isMCPOriginated: true,
            stored: .high
        ), .low)
        XCTAssertEqual(ClaudeAgentModeCoordinator.resolvedMCPPinnedEffort(
            modelRaw: "claude-opus-5-5:low",
            agentKind: .claudeCode,
            pinnedEffortRaw: extracted.effort,
            isMCPOriginated: false,
            stored: .high
        ), .low)
        XCTAssertEqual(ClaudeAgentModeCoordinator.resolvedMCPPinnedEffort(
            modelRaw: "claude-opus-5-5",
            agentKind: .claudeCode,
            pinnedEffortRaw: nil,
            isMCPOriginated: true,
            stored: .high
        ), .high)
        XCTAssertEqual(ClaudeAgentModeCoordinator.validatedMCPPinnedEffort(
            modelRaw: "claude-opus-5-5:low",
            agentKind: .claudeCode,
            pinnedEffortRaw: "low",
            isMCPOriginated: true
        ), .low)
        XCTAssertNil(ClaudeAgentModeCoordinator.validatedMCPPinnedEffort(
            modelRaw: "claude-opus-5-5",
            agentKind: .claudeCode,
            pinnedEffortRaw: "low",
            isMCPOriginated: false
        ))
    }

    @MainActor
    func testEncodedManualEffortIsBaselineButValidMCPPinStillWins() {
        XCTAssertEqual(ClaudeAgentModeCoordinator.resolvedMCPPinnedEffort(
            modelRaw: "claude-opus-5-5:low",
            agentKind: .claudeCode,
            pinnedEffortRaw: "high",
            isMCPOriginated: false,
            stored: .high
        ), .low)
        XCTAssertEqual(ClaudeAgentModeCoordinator.resolvedMCPPinnedEffort(
            modelRaw: "claude-opus-5-5:low",
            agentKind: .claudeCode,
            pinnedEffortRaw: "high",
            isMCPOriginated: true,
            stored: .medium
        ), .high)
    }

    @MainActor
    func testColdClaudeControlsDoNotSaveBeforeHydrationAndAdoptionPreservesContent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpce-claude-cold-effort-\(UUID().uuidString)", isDirectory: true)
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
            name: "Cold Claude effort", repoPaths: [root.path], ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: "coldClaudeEffortTests")
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        let tabID = try XCTUnwrap(activeWorkspace.activeComposeTabID)
        let viewModel = window.agentModeViewModel
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        session.selectedAgent = .claudeCode
        session.selectedModelRaw = "claude-opus-5-5"
        let sessionID = try XCTUnwrap(viewModel.test_ensureSessionBoundToTab(session))
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer {
            viewModel.test_setCurrentTabIDOverride(nil)
            session.saveDebounceTask?.cancel()
        }
        session.saveDebounceTask?.cancel()
        session.hasLoadedPersistedState = false
        session.selectedClaudeEffortRaw = nil
        session.isDirty = false
        var saves: [AgentSession] = []
        viewModel.test_setAgentSessionSaver { saved, _, _ in
            saves.append(saved)
            return root.appendingPathComponent("session.json")
        }
        let settings = AgentProviderPermissionsSettingsViewModel(
            bindingService: viewModel.providerBindingService,
            claudeEffortLevelProvider: { viewModel.claudeCoordinator.currentClaudeEffortLevel(for: session) }
        )
        let expected = viewModel.providerBindingService.claudeEffortLevel(
            forModelRaw: session.selectedModelRaw, agentKind: session.selectedAgent
        )
        XCTAssertEqual(settings.controlsBinding(for: .claude)?.claudeTools?.effortLevel, expected)
        await viewModel.flushSave(for: tabID)
        XCTAssertTrue(saves.isEmpty, "Projecting cold controls must not persist an incomplete existing conversation")
        XCTAssertNil(session.selectedClaudeEffortRaw, "Default adoption waits for authoritative hydration")

        // Commit the authoritative payload before restoring the legacy effort, as hydration does.
        session.setItemsSilently([.user("Existing conversation")], reason: .persistedSessionHydration)
        session.providerSessionID = "existing-provider-session"
        session.hasLoadedPersistedState = true
        viewModel.restoreClaudeEffort(from: AgentSession(id: sessionID, name: "Legacy conversation"), to: session)
        await viewModel.flushSave(for: tabID)
        XCTAssertEqual(saves.count, 1)
        let saved = try XCTUnwrap(saves.last)
        XCTAssertEqual(saved.id, sessionID)
        XCTAssertEqual(saved.agentReasoningEffort, expected.rawValue)
        XCTAssertEqual(saved.providerSessionID, "existing-provider-session")
        XCTAssertEqual(saved.toLiveItems().map(\.text), ["Existing conversation"])
    }

    @MainActor
    func testMCPConfigurationPreservesClaudePinAndClearsItForUnpinnedModel() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpce-claude-effort-\(UUID().uuidString)", isDirectory: true)
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
            name: "Claude MCP effort pin",
            repoPaths: [root.path],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: "claudeEffortPinTests")
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        let tabID = try XCTUnwrap(activeWorkspace.activeComposeTabID)
        let viewModel = window.agentModeViewModel
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        session.isMCPOriginated = true
        let sessionID = try XCTUnwrap(viewModel.test_ensureSessionBoundToTab(session))
        viewModel.test_setCurrentTabIDOverride(UUID())
        defer {
            viewModel.test_setCurrentTabIDOverride(nil)
            for session in viewModel.sessions.values {
                session.saveDebounceTask?.cancel()
            }
        }
        let savedFile = root.appendingPathComponent("effort-session.json")
        viewModel.test_setAgentSessionSaver { saved, _, _ in
            try JSONEncoder().encode(saved).write(to: savedFile, options: .atomic)
            return savedFile
        }

        try await viewModel.mcpConfigureSession(
            tabID: tabID,
            agentRaw: AgentProviderKind.claudeCode.rawValue,
            modelRaw: "claude-opus-5-5",
            reasoningEffortRaw: "low"
        )
        XCTAssertEqual(session.selectedReasoningEffortRaw, "low")
        XCTAssertEqual(session.persistedReasoningEffortRaw, "low")
        session.isDirty = true
        await viewModel.flushSave(for: tabID)
        let saved = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: savedFile))
        XCTAssertEqual(saved.agentReasoningEffort, "low")
        XCTAssertEqual(viewModel.ownerValidatedSessionIndex[sessionID]?.agentReasoningEffortRaw, "low")

        viewModel.test_removeSession(tabID: tabID)
        let restored = viewModel.session(for: tabID)
        XCTAssertEqual(restored.persistedReasoningEffortRaw, "low")
        viewModel.restoreClaudeEffort(from: saved, to: restored)
        XCTAssertEqual(viewModel.claudeCoordinator.currentClaudeEffortLevel(for: restored), .low)

        try await viewModel.mcpConfigureSession(
            tabID: tabID,
            agentRaw: AgentProviderKind.claudeCode.rawValue,
            modelRaw: "claude-opus-5-5",
            reasoningEffortRaw: nil
        )
        XCTAssertNil(restored.selectedReasoningEffortRaw)
    }
}

final class ClaudeNativeAutoFallbackTests: XCTestCase {
    private actor ApplicationGate {
        private let fence = TestReleaseFence(name: "native Auto application error")
        func waitUntilEntered() async throws {
            guard await fence.waitUntilEntered(timeout: 3) else { fence.release()
                throw CancellationError()
            }
        }

        func pause() async {
            await fence.enterAndWait()
        }

        nonisolated func resume() {
            fence.release()
        }
    }

    private final class Writes: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [Data] = []
        func append(_ line: Data) {
            lock.lock()
            defer { lock.unlock() }
            lines.append(line)
        }

        func line(at index: Int) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return lines.indices.contains(index) ? lines[index] : nil
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return lines.count
        }
    }

    private actor PassthroughResolver: ClaudeCodeLaunchEnvironmentResolving {
        func resolve(variant _: ClaudeCodeRuntimeVariant, requestedModel: String?) async throws -> ClaudeCodeLaunchEnvironment {
            .init(effectiveModel: requestedModel, environmentOverrides: [:], backend: .defaultClaude)
        }
    }

    private func controller() -> ClaudeNativeProcessSessionController {
        .init(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false", runtimeVariant: .standard),
            environmentResolver: PassthroughResolver()
        )
    }

    @MainActor
    private func fixture(_ controller: ClaudeNativeProcessSessionController) -> (ClaudeAgentModeCoordinator, AgentTabSession, ClaudeAgentModeCoordinator.NativeSessionIntent) {
        let coordinator = ClaudeAgentModeCoordinator(
            windowID: 1, workspacePathProvider: { _ in nil },
            claudeControllerFactory: { _, _, _, _ in controller }, autoEffortEnabledProvider: { true }
        )
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.selectedModelRaw = "claude-opus-5-5:high"
        session.hasLoadedPersistedState = true
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        let runID = UUID()
        session.installRunID(runID)
        session.runState = .running
        let ownership = session.beginRunAttempt(source: "test.native-auto-fallback")
        return (coordinator, session, .runAttempt(ownership: ownership, runID: runID))
    }

    @MainActor
    func testStaleAutoErrorCannotOverwriteNewerIdenticalOrABASelection() async throws {
        for afterClassification in [false, true] {
            for newerModels in [["claude-opus-5-5:high"], ["claude-sonnet-4-6:high", "claude-opus-5-5:high"]] {
                let controller = controller()
                let gate = ApplicationGate()
                let controls = Writes()
                let writes = Writes()
                await controller.test_installConfigurationTransport(controlRequest: { request in
                    controls.append(Data())
                    if (request["settings"] as? [String: Any])?["effortLevel"] as? String == "low" {
                        if !afterClassification { await gate.pause() }
                        throw NativeAgentRuntimeControllerError.invalidControlResponse("Auto rejected")
                    }
                    return [:]
                }, write: { writes.append($0) })
                if afterClassification { await controller.test_setBeforeApplicationErrorReturn { await gate.pause() } }
                let (coordinator, session, intent) = fixture(controller)
                let send = Task {
                    await coordinator.sendClaudeNativeMessage(
                        session: session, text: "older ordinary turn", attachments: [], intent: intent,
                        allowsCatalogRouteControllerRecovery: false,
                        autoEffortSelection: .init(
                            provider: .claudeCode,
                            selectedModelRaw: session.selectedModelRaw,
                            manualEffortRaw: "high",
                            effortRaw: "low"
                        )
                    )
                }
                defer { send.cancel()
                    gate.resume()
                }
                try await gate.waitUntilEntered()
                for model in newerModels {
                    try await controller.applyModelAndEffort(model: model, effortLevel: .high)
                }
                gate.resume()
                let outcome = await send.value
                guard case .failed = outcome else { XCTFail("Stale Auto failure must refuse the older prompt: \(outcome)")
                    continue
                }
                XCTAssertEqual(controls.count, 1 + newerModels.count, "A stale failure cannot issue manual fallback settings")
                XCTAssertEqual(writes.count, 0, "The older prompt must not dispatch")
                XCTAssertEqual(session.providerSessionID, "application-proof-session")
                XCTAssertTrue(session.claudeController === controller)
            }
        }
    }

    @MainActor
    func testCurrentAutoFailureRestoresManualEffortAndDelivers() async throws {
        let controller = controller()
        let controls = Writes()
        let writes = Writes()
        await controller.test_installConfigurationTransport(controlRequest: { request in
            try controls.append(JSONSerialization.data(withJSONObject: request))
            if (request["settings"] as? [String: Any])?["effortLevel"] as? String == "low" {
                throw NativeAgentRuntimeControllerError.invalidControlResponse("Auto rejected")
            }
            return [:]
        }, write: { writes.append($0) })
        let (coordinator, session, intent) = fixture(controller)
        let outcome = await coordinator.sendClaudeNativeMessage(
            session: session, text: "current ordinary turn", attachments: [], intent: intent,
            allowsCatalogRouteControllerRecovery: false,
            autoEffortSelection: .init(
                provider: .claudeCode,
                selectedModelRaw: session.selectedModelRaw,
                manualEffortRaw: "high",
                effortRaw: "low"
            )
        )
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(controls.count, 2)
        XCTAssertEqual(writes.count, 1)
        let restoredRequest = try XCTUnwrap(controls.line(at: 1))
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: restoredRequest) as? [String: Any])
        let settings = try XCTUnwrap(request["settings"] as? [String: Any])
        XCTAssertEqual(settings["model"] as? String, session.selectedModelRaw)
        XCTAssertEqual(settings["effortLevel"] as? String, "high")
    }

    @MainActor
    func testSupersededPickerFailureKeepsNewerAutoEffortRestoration() async throws {
        let controller = controller()
        let pickerGate = ApplicationGate()
        let controls = Writes()
        let applied = Writes()
        let writes = Writes()
        await controller.test_installConfigurationTransport(controlRequest: { request in
            let data = try JSONSerialization.data(withJSONObject: request)
            controls.append(data)
            if controls.count == 1 {
                await pickerGate.pause()
                throw NativeAgentRuntimeControllerError.invalidControlResponse("Picker rejected")
            }
            applied.append(data)
            return [:]
        }, write: { writes.append($0) })
        let (coordinator, session, intent) = fixture(controller)
        let ensured = await coordinator.ensureClaudeNativeSession(session: session, intent: intent)
        XCTAssertEqual(ensured, .ready)
        let picker = Task { await coordinator.applyCurrentClaudeModelAndEffortIfPossible(for: session, reason: "test.picker") }
        defer { picker.cancel()
            pickerGate.resume()
        }
        try await pickerGate.waitUntilEntered()
        let auto = await coordinator.sendClaudeNativeMessage(
            session: session, text: "Auto turn", attachments: [], intent: intent,
            allowsCatalogRouteControllerRecovery: false,
            autoEffortSelection: .init(
                provider: .claudeCode, selectedModelRaw: session.selectedModelRaw,
                manualEffortRaw: "high", effortRaw: "low"
            )
        )
        XCTAssertEqual(auto, .sent)
        // Complete through the real decoder, not a fake interruption or queue reset.
        await controller.test_handleConfigurationStdoutChunk(Data(
            #"{"type":"result","subtype":"success","session_id":"auto-fallback-session","result":"done","is_error":false}"#.utf8
        ) + Data([10]))
        let inFlight = await controller.hasTurnInFlight
        XCTAssertFalse(inFlight)
        pickerGate.resume()
        await picker.value
        let manual = await coordinator.sendClaudeNativeMessage(
            session: session, text: "Manual turn", attachments: [], intent: intent,
            allowsCatalogRouteControllerRecovery: false
        )
        XCTAssertEqual(manual, .sent)
        XCTAssertEqual(controls.count, 3, "A stale picker failure must preserve the Auto restoration marker")
        XCTAssertEqual(writes.count, 2)
        try assertLastAppliedEffort(applied, equals: "high")
    }

    @MainActor
    func testSupersededLandedAutoWriteRestoresAfterNewerPickerFails() async throws {
        let controller = controller()
        let autoGate = ApplicationGate()
        let pickerGate = ApplicationGate()
        let controls = Writes()
        let applied = Writes()
        let writes = Writes()
        await controller.test_installConfigurationTransport(controlRequest: { request in
            let data = try JSONSerialization.data(withJSONObject: request)
            controls.append(data)
            if (request["settings"] as? [String: Any])?["effortLevel"] as? String == "low" {
                await autoGate.pause()
            } else if controls.count == 2 {
                await pickerGate.pause()
                throw NativeAgentRuntimeControllerError.invalidControlResponse("Newer picker rejected")
            }
            applied.append(data)
            return [:]
        }, write: { writes.append($0) })
        let (coordinator, session, intent) = fixture(controller)
        let auto = Task {
            await coordinator.sendClaudeNativeMessage(
                session: session, text: "Superseded Auto turn", attachments: [], intent: intent,
                allowsCatalogRouteControllerRecovery: false,
                autoEffortSelection: .init(
                    provider: .claudeCode, selectedModelRaw: session.selectedModelRaw,
                    manualEffortRaw: "high", effortRaw: "low"
                )
            )
        }
        defer { auto.cancel()
            autoGate.resume()
            pickerGate.resume()
        }
        try await autoGate.waitUntilEntered()
        let picker = Task { await coordinator.applyCurrentClaudeModelAndEffortIfPossible(for: session, reason: "test.newer-picker") }
        defer { picker.cancel() }
        try await pickerGate.waitUntilEntered()
        autoGate.resume()
        let outcome = await auto.value
        guard case .failed = outcome else { return XCTFail("Superseded Auto must not send: \(outcome)") }
        XCTAssertEqual(writes.count, 0)
        pickerGate.resume()
        await picker.value
        let manual = await coordinator.sendClaudeNativeMessage(
            session: session, text: "Manual turn", attachments: [], intent: intent,
            allowsCatalogRouteControllerRecovery: false
        )
        XCTAssertEqual(manual, .sent)
        XCTAssertEqual(controls.count, 3, "A landed but superseded Auto write still needs manual restoration")
        XCTAssertEqual(writes.count, 1)
        try assertLastAppliedEffort(applied, equals: "high")
    }

    @MainActor
    func testSupersededLandedAutoWriteRestoresAfterSuccessfulNewerPicker() async throws {
        let controller = controller()
        let autoGate = ApplicationGate()
        let controls = Writes()
        let applied = Writes()
        let writes = Writes()
        await controller.test_installConfigurationTransport(controlRequest: { request in
            let data = try JSONSerialization.data(withJSONObject: request)
            controls.append(data)
            if (request["settings"] as? [String: Any])?["effortLevel"] as? String == "low" {
                await autoGate.pause()
            }
            applied.append(data)
            return [:]
        }, write: { writes.append($0) })
        let (coordinator, session, intent) = fixture(controller)
        let auto = Task {
            await coordinator.sendClaudeNativeMessage(
                session: session, text: "Superseded Auto turn", attachments: [], intent: intent,
                allowsCatalogRouteControllerRecovery: false,
                autoEffortSelection: .init(
                    provider: .claudeCode, selectedModelRaw: session.selectedModelRaw,
                    manualEffortRaw: "high", effortRaw: "low"
                )
            )
        }
        defer { auto.cancel()
            autoGate.resume()
        }
        try await autoGate.waitUntilEntered()
        await coordinator.applyCurrentClaudeModelAndEffortIfPossible(for: session, reason: "test.newer-picker")
        try assertLastAppliedEffort(applied, equals: "high")
        autoGate.resume()
        let outcome = await auto.value
        guard case .failed = outcome else { return XCTFail("Superseded Auto must not send: \(outcome)") }
        XCTAssertEqual(writes.count, 0)
        try assertLastAppliedEffort(applied, equals: "low")
        let manual = await coordinator.sendClaudeNativeMessage(
            session: session, text: "Manual turn", attachments: [], intent: intent,
            allowsCatalogRouteControllerRecovery: false
        )
        XCTAssertEqual(manual, .sent)
        XCTAssertEqual(controls.count, 3, "A landed but superseded Auto write still needs manual restoration")
        XCTAssertEqual(writes.count, 1)
        try assertLastAppliedEffort(applied, equals: "high")
    }

    private func assertLastAppliedEffort(_ applied: Writes, equals expected: String) throws {
        let data = try XCTUnwrap(applied.line(at: applied.count - 1))
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let settings = try XCTUnwrap(request["settings"] as? [String: Any])
        XCTAssertEqual(settings["effortLevel"] as? String, expected)
    }

    func testFailureTokenCannotBeReusedAfterFallbackOrTransportReplacement() async throws {
        for replaceTransport in [false, true] {
            let controller = controller()
            let controls = Writes()
            let accept: @Sendable ([String: Any]) async throws -> [String: Any] = { request in
                controls.append(Data())
                if (request["settings"] as? [String: Any])?["effortLevel"] as? String == "low" {
                    throw NativeAgentRuntimeControllerError.invalidControlResponse("Auto rejected")
                }
                return [:]
            }
            await controller.test_installConfigurationTransport(controlRequest: accept, write: { _ in })
            var captured: NativeAgentRuntimeConfigurationFailure?
            do {
                _ = try await controller.applyModelAndEffortForTurn(model: "A", effortLevel: .low, replacingFailure: nil)
                XCTFail("Expected failed Auto application")
            } catch let failure as NativeAgentRuntimeConfigurationFailure { captured = failure }
            let failure = try XCTUnwrap(captured)
            if replaceTransport {
                await controller.test_installConfigurationTransport(controlRequest: accept, write: { _ in })
                try await controller.applyModelAndEffort(model: "A", effortLevel: .high)
            } else {
                let restored = try await controller.applyModelAndEffortForTurn(model: "A", effortLevel: .high, replacingFailure: failure)
                XCTAssertEqual(restored, .applied)
            }
            let stale = try await controller.applyModelAndEffortForTurn(model: "A", effortLevel: .high, replacingFailure: failure)
            XCTAssertEqual(stale, .superseded)
            XCTAssertEqual(controls.count, 2, "Consumed or foreign-lifetime failures authorize no provider IO")
        }
    }
}
