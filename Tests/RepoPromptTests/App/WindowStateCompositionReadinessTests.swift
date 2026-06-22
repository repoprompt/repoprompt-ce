import MCP
@testable import RepoPrompt
@testable import RepoPromptCore
import XCTest

@MainActor
final class WindowStateCompositionReadinessTests: XCTestCase {
    func testActiveChatRestoreSettlesBetweenFirstProjectionAndRuntimePublication() async throws {
        let fixture = try makeFixture()
        defer {
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        try await fulfillment(of: [XCTUnwrap(fixture.readinessReached)], timeout: 3)

        XCTAssertTrue(fixture.recorder.didRequestHydration)
        XCTAssertTrue(fixture.recorder.didReachInitialActiveSessionPresentation)
        XCTAssertEqual(
            fixture.recorder.events,
            [.firstAuthoritativeProjectionApplied, .initialActiveSessionRestoreSettled]
        )
        XCTAssertEqual(fixture.composition.workspaceManager.activeWorkspaceID, fixture.workspaceID)
        XCTAssertEqual(
            fixture.composition.agentModeViewModel.activeTranscriptPresentation.visibleRows.map(\.text),
            ["restored user", "restored assistant"]
        )
        XCTAssertTrue(fixture.composition.agentModeViewModel.activeTranscriptPresentation.bindingsHydrated)
        XCTAssertFalse(fixture.composition.workspaceManager.isInitialized)
        XCTAssertTrue(fixture.container.runtimeAdapterRegistry?.latestRoutingTableSnapshot.mappings.isEmpty == true)

        await fixture.readinessGate.release()
        await fixture.indexGate.release()
        await fixture.composition.workspaceSessionActivationTask?.value

        XCTAssertEqual(
            fixture.recorder.events,
            [
                .firstAuthoritativeProjectionApplied,
                .initialActiveSessionRestoreSettled,
                .runtimeAdapterPublished,
                .selectedSessionInitializationCompleted
            ]
        )
        XCTAssertEqual(
            fixture.composition.agentModeViewModel.activeTranscriptPresentation.visibleRows.map(\.text),
            ["restored user", "restored assistant"]
        )
        XCTAssertTrue(fixture.composition.agentModeViewModel.activeTranscriptPresentation.bindingsHydrated)
        XCTAssertTrue(fixture.composition.workspaceManager.isInitialized)

        let mapping = try XCTUnwrap(
            fixture.container.runtimeAdapterRegistry?.latestRoutingTableSnapshot.mapping(windowID: fixture.windowID)
        )
        XCTAssertEqual(mapping.runtimeID, fixture.composition.workspaceRuntimeID)
        XCTAssertEqual(mapping.sessionID, fixture.composition.workspaceSessionID)
        XCTAssertEqual(mapping.activeWorkspaceID, fixture.workspaceID)

        fixture.composition.workspaceRuntimeBeginClose()
        await fixture.composition.workspaceSessionShutdown()
    }

    func testInactiveAgentModeStillRestoresBeforeRuntimePublication() async throws {
        let fixture = try makeFixture(activateAgentMode: false)
        defer {
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        try await fulfillment(of: [XCTUnwrap(fixture.readinessReached)], timeout: 3)

        XCTAssertTrue(fixture.recorder.didRequestHydration)
        XCTAssertTrue(fixture.recorder.didReachInitialActiveSessionPresentation)
        XCTAssertEqual(
            fixture.composition.agentModeViewModel.activeTranscriptPresentation.visibleRows.map(\.text),
            ["restored user", "restored assistant"]
        )
        XCTAssertTrue(fixture.composition.agentModeViewModel.activeTranscriptPresentation.bindingsHydrated)

        await fixture.readinessGate.release()
        await fixture.indexGate.release()
        await fixture.composition.workspaceSessionActivationTask?.value

        XCTAssertEqual(
            fixture.recorder.events,
            [
                .firstAuthoritativeProjectionApplied,
                .initialActiveSessionRestoreSettled,
                .runtimeAdapterPublished,
                .selectedSessionInitializationCompleted
            ]
        )
        XCTAssertTrue(fixture.composition.workspaceManager.isInitialized)
        XCTAssertEqual(
            fixture.container.runtimeAdapterRegistry?.latestRoutingTableSnapshot
                .mapping(windowID: fixture.windowID)?.runtimeID,
            fixture.composition.workspaceRuntimeID
        )

        fixture.composition.workspaceRuntimeBeginClose()
        await fixture.composition.workspaceSessionShutdown()
    }

    func testCancelledOrClosingReadinessWaitFailsClosedWithoutAdapterPublication() async throws {
        for interruption in ReadinessInterruption.allCases {
            var fixture: Fixture? = try makeFixture(gateInitialRestore: true)
            let storageRoot = try XCTUnwrap(fixture?.storageRoot)
            do {
                let activeFixture = try XCTUnwrap(fixture)
                try await fulfillment(of: [XCTUnwrap(activeFixture.initialPresentationReached)], timeout: 3)
                for _ in 0 ..< 100
                    where activeFixture.composition.agentModeViewModel.test_initialActiveSessionRestoreWaiterCount != 1
                {
                    await Task.yield()
                }

                XCTAssertTrue(activeFixture.recorder.didRequestHydration)
                XCTAssertTrue(activeFixture.recorder.didReachInitialActiveSessionPresentation)
                XCTAssertEqual(activeFixture.recorder.events, [.firstAuthoritativeProjectionApplied])
                XCTAssertEqual(
                    activeFixture.composition.agentModeViewModel.test_initialActiveSessionRestoreWaiterCount,
                    1
                )

                switch interruption {
                case .cancel:
                    let activationFinished = expectation(description: "cancelled activation finished")
                    activeFixture.composition.workspaceSessionActivationTask?.cancel()
                    Task { @MainActor in
                        await activeFixture.composition.workspaceSessionActivationTask?.value
                        activationFinished.fulfill()
                    }
                    await fulfillment(of: [activationFinished], timeout: 3)
                    XCTAssertEqual(
                        activeFixture.composition.agentModeViewModel.test_initialActiveSessionRestoreWaiterCount,
                        0
                    )
                    await activeFixture.composition.agentModeViewModel.prepareForWindowClose()
                case .beginClosing:
                    activeFixture.composition.workspaceRuntimeBeginClose()
                    await activeFixture.initialPresentationGate.release()
                    await activeFixture.indexGate.release()
                    await activeFixture.composition.workspaceSessionActivationTask?.value
                }

                XCTAssertEqual(
                    activeFixture.recorder.events,
                    [.firstAuthoritativeProjectionApplied],
                    "unexpected readiness progress for \(interruption)"
                )
                XCTAssertFalse(
                    activeFixture.composition.workspaceManager.isInitialized,
                    "selected initialization escaped fail-closed boundary for \(interruption)"
                )
                XCTAssertTrue(
                    activeFixture.container.runtimeAdapterRegistry?.latestRoutingTableSnapshot.mappings.isEmpty == true,
                    "stale adapter published for \(interruption)"
                )
                if let runtimeID = activeFixture.composition.workspaceRuntimeID {
                    XCTAssertNil(
                        activeFixture.container.runtimeAdapterRegistry?.publicationState(runtimeID: runtimeID),
                        "adapter entry was staged for \(interruption)"
                    )
                }
            }

            fixture = nil
            try? FileManager.default.removeItem(at: storageRoot)
        }
    }

    func testPostPublicationOwnershipLossFailsClosedBeforeSelectedInitialization() async throws {
        for interruption in PostPublicationInterruption.allCases {
            let fixture = try makeFixture(gateRuntimePublicationReady: true)
            try await fulfillment(of: [XCTUnwrap(fixture.readinessReached)], timeout: 3)
            await fixture.readinessGate.release()
            try await fulfillment(of: [XCTUnwrap(fixture.runtimePublicationReadyReached)], timeout: 3)

            XCTAssertFalse(fixture.composition.workspaceManager.isInitialized)
            XCTAssertNotNil(
                fixture.container.runtimeAdapterRegistry?.latestRoutingTableSnapshot.mapping(windowID: fixture.windowID)
            )

            switch interruption {
            case .cancel:
                fixture.composition.workspaceSessionActivationTask?.cancel()
            case .beginClosing:
                fixture.composition.workspaceRuntimeBeginClose()
            case .adapterOwnershipLoss:
                if let runtimeID = fixture.composition.workspaceRuntimeID {
                    _ = fixture.container.runtimeAdapterRegistry?.beginClosing(runtimeID: runtimeID)
                }
            case .lifecycleOwnershipLoss:
                if let runtimeID = fixture.composition.workspaceRuntimeID {
                    _ = await fixture.container.runtimeLifecycleRegistry?.beginDraining(runtimeID: runtimeID)
                }
            }
            if interruption != .cancel {
                await fixture.runtimePublicationReadyGate.release()
            }

            let activationFinished = expectation(description: "post-publication interruption finished")
            Task { @MainActor in
                await fixture.composition.workspaceSessionActivationTask?.value
                activationFinished.fulfill()
            }
            await fulfillment(of: [activationFinished], timeout: 3)
            await fixture.indexGate.release()

            XCTAssertEqual(
                fixture.recorder.events,
                [.firstAuthoritativeProjectionApplied, .initialActiveSessionRestoreSettled],
                "unexpected selected-session progress for \(interruption)"
            )
            XCTAssertFalse(
                fixture.composition.workspaceManager.isInitialized,
                "selected initialization escaped post-publication ownership fence for \(interruption)"
            )
            XCTAssertNil(
                fixture.container.runtimeAdapterRegistry?.latestRoutingTableSnapshot.mapping(windowID: fixture.windowID),
                "runtime mapping remained published for \(interruption)"
            )

            await fixture.composition.workspaceSessionShutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }
    }

    private enum ReadinessInterruption: String, CaseIterable {
        case cancel
        case beginClosing
    }

    private enum PostPublicationInterruption: String, CaseIterable {
        case cancel
        case beginClosing
        case adapterOwnershipLoss
        case lifecycleOwnershipLoss
    }

    private struct Fixture {
        let windowID: Int
        let workspaceID: UUID
        let storageRoot: URL
        let container: RepoPromptAppCoreContainer
        let composition: WindowStateComposition
        let recorder: ActivationEventRecorder
        let readinessGate: CompositionReadinessGate
        let indexGate: CompositionReadinessGate
        let initialPresentationGate: CompositionReadinessGate
        let runtimePublicationReadyGate: CompositionReadinessGate
        let readinessReached: XCTestExpectation?
        let initialPresentationReached: XCTestExpectation?
        let runtimePublicationReadyReached: XCTestExpectation?
    }

    private static var nextWindowID = -20000

    private func makeFixture(
        gateInitialRestore: Bool = false,
        activateAgentMode: Bool = true,
        gateRuntimePublicationReady: Bool = false
    ) throws -> Fixture {
        let windowID = Self.nextWindowID
        Self.nextWindowID -= 1

        let tabID = UUID()
        let sessionID = UUID()
        let workspace = WorkspaceModel(
            name: "Readiness",
            repoPaths: [],
            composeTabs: [
                ComposeTabState(
                    id: tabID,
                    name: "Active",
                    activeAgentSessionID: sessionID
                )
            ],
            activeComposeTabID: tabID
        )
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowStateCompositionReadinessTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        try writeIndexedWorkspace(workspace, baseRoot: storageRoot)

        let payload = makeHydrationPayload(sessionID: sessionID, tabID: tabID)
        let recorder = ActivationEventRecorder()
        let readinessGate = CompositionReadinessGate()
        let indexGate = CompositionReadinessGate()
        let initialPresentationGate = CompositionReadinessGate()
        let runtimePublicationReadyGate = CompositionReadinessGate()
        let readinessReached = gateInitialRestore ? nil : expectation(description: "assembled readiness reached")
        let initialPresentationReached = gateInitialRestore
            ? expectation(description: "initial active-session presentation reached")
            : nil
        let runtimePublicationReadyReached = gateRuntimePublicationReady
            ? expectation(description: "runtime publication ready returned")
            : nil
        let hooks = WindowStateCompositionTestHooks(
            configureAgentModeViewModel: { viewModel in
                viewModel.test_setPersistedHydrationPreparer { request in
                    recorder.recordHydrationRequest()
                    return request.sessionID == sessionID ? payload : nil
                }
                viewModel.test_setSidebarIndexBuilders(
                    prioritized: { _ in
                        AgentSessionSidebarBuildResult(
                            entriesBySessionID: [:],
                            preferredSessionIDByTabID: [:]
                        )
                    },
                    stream: { _, _ in
                        AsyncThrowingStream { continuation in
                            Task {
                                await indexGate.wait()
                                continuation.finish()
                            }
                        }
                    }
                )
                viewModel.test_setBeforeInitialActiveSessionPresentation {
                    recorder.recordInitialActiveSessionPresentation()
                    if gateInitialRestore {
                        initialPresentationReached?.fulfill()
                        await initialPresentationGate.wait()
                    }
                }
                if activateAgentMode {
                    viewModel.setAgentModeActive(true)
                }
            },
            recordActivationEvent: { recorder.record($0) },
            waitAfterInitialActiveSessionRestore: {
                readinessReached?.fulfill()
                await readinessGate.wait()
            },
            waitAfterRuntimePublicationReady: {
                guard gateRuntimePublicationReady else { return }
                runtimePublicationReadyReached?.fulfill()
                await runtimePublicationReadyGate.wait()
            }
        )

        let containerDefaults = try XCTUnwrap(
            UserDefaults(suiteName: "WindowStateCompositionReadinessTests.\(UUID().uuidString)")
        )
        let container = RepoPromptAppCoreContainer(
            userDefaults: containerDefaults,
            debugOverride: .core,
            debugRoutingOverride: .lifecycleRegistry
        )

        let defaults = UserDefaults.standard
        let previousStoragePath = defaults.string(forKey: "GlobalCustomStorageURL")
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        defaults.set(storageRoot.path, forKey: "GlobalCustomStorageURL")
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let composition = WindowStateCompositionFactory.make(
            windowID: windowID,
            deferredInitialAgentSystemWorkspaceRefresh: false,
            sharedMCPService: MCPService(),
            appCoreContainer: container,
            loadStoredAPISettingsDataOnInit: false,
            testHooks: hooks
        )
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        if let previousStoragePath {
            defaults.set(previousStoragePath, forKey: "GlobalCustomStorageURL")
        } else {
            defaults.removeObject(forKey: "GlobalCustomStorageURL")
        }

        return Fixture(
            windowID: windowID,
            workspaceID: workspace.id,
            storageRoot: storageRoot,
            container: container,
            composition: composition,
            recorder: recorder,
            readinessGate: readinessGate,
            indexGate: indexGate,
            initialPresentationGate: initialPresentationGate,
            runtimePublicationReadyGate: runtimePublicationReadyGate,
            readinessReached: readinessReached,
            initialPresentationReached: initialPresentationReached,
            runtimePublicationReadyReached: runtimePublicationReadyReached
        )
    }

    private func makeHydrationPayload(
        sessionID: UUID,
        tabID: UUID
    ) -> AgentSessionHydrationPayload {
        let items = [
            AgentChatItem.user("restored user", sequenceIndex: 0),
            AgentChatItem.assistant("restored assistant", sequenceIndex: 1)
        ]
        let transcript = AgentTranscriptIO.buildTranscript(
            from: items,
            terminalState: .idle,
            nextSequenceIndex: 2,
            compact: false
        )
        let selection = AgentModelCatalog.normalizePersistedSelection(
            agentRaw: nil,
            modelRaw: nil
        )
        let savedAt = Date(timeIntervalSince1970: 100)
        let persistedSession = AgentSession(
            id: sessionID,
            composeTabID: tabID,
            name: "Restored",
            savedAt: savedAt,
            transcript: transcript,
            itemCount: items.count,
            lastUserMessageAt: items[0].timestamp,
            agentKind: selection.agent.rawValue,
            agentModel: selection.modelRaw,
            lastRunState: AgentSessionRunState.idle.rawValue,
            autoEditEnabled: false
        )
        return AgentSessionHydrationPayload(
            sessionID: sessionID,
            persistedSession: persistedSession,
            canonicalLiveItems: items,
            transcript: transcript,
            builtPresentation: AgentSessionRestoreSupport.buildTranscriptPresentation(
                from: transcript,
                sourceItems: items,
                selectedAgent: selection.agent,
                previousPerformanceSnapshot: .empty,
                projectionProtection: .none,
                isCompressedHistoryRevealed: false,
                isColdLoad: true
            ),
            normalizedRunState: .idle,
            normalizedSelection: selection,
            lastUserMessageAt: items[0].timestamp,
            restoredIndexEntry: AgentSessionRestoreSupport.buildSidebarIndexEntry(
                from: persistedSession,
                tabID: tabID,
                name: "Restored",
                lastUserMessageAt: items[0].timestamp,
                itemCount: items.count
            ),
            needsReloadMigrationSave: false
        )
    }

    private func writeIndexedWorkspace(
        _ workspace: WorkspaceModel,
        baseRoot: URL
    ) throws {
        let workspaceDirectory = baseRoot
            .appendingPathComponent("Workspace-\(workspace.name)-\(workspace.id.uuidString)")
        try FileManager.default.createDirectory(
            at: workspaceDirectory,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(workspace).write(
            to: workspaceDirectory.appendingPathComponent("workspace.json"),
            options: .atomic
        )
        let entry = WorkspaceIndexEntry(
            id: workspace.id,
            name: workspace.name,
            customStoragePath: workspace.customStoragePath,
            isSystemWorkspace: workspace.isSystemWorkspace,
            isHiddenInMenus: workspace.isHiddenInMenus
        )
        try JSONEncoder().encode([entry]).write(
            to: baseRoot.appendingPathComponent("workspacesIndex.json"),
            options: .atomic
        )
    }
}

@MainActor
private final class ActivationEventRecorder {
    private(set) var events: [WindowStateCompositionActivationEvent] = []
    private(set) var didRequestHydration = false
    private(set) var didReachInitialActiveSessionPresentation = false

    func record(_ event: WindowStateCompositionActivationEvent) {
        events.append(event)
    }

    func recordHydrationRequest() {
        didRequestHydration = true
    }

    func recordInitialActiveSessionPresentation() {
        didReachInitialActiveSessionPresentation = true
    }
}

private actor CompositionReadinessGate {
    private var isReleased = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func wait() async {
        guard !isReleased, !Task.isCancelled else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !isReleased, !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                waiters[waiterID] = continuation
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterID)
            }
        }
    }

    func release() {
        isReleased = true
        let currentWaiters = Array(waiters.values)
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        waiters.removeValue(forKey: waiterID)?.resume()
    }
}
