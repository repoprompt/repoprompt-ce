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

    func testCancelledOrClosingReadinessWaitFailsClosedWithoutAdapterPublication() async throws {
        for interruption in ReadinessInterruption.allCases {
            let fixture = try makeFixture(gateInitialRestore: true)
            try await fulfillment(of: [XCTUnwrap(fixture.initialPresentationReached)], timeout: 3)

            XCTAssertTrue(fixture.recorder.didRequestHydration)
            XCTAssertTrue(fixture.recorder.didReachInitialActiveSessionPresentation)
            XCTAssertEqual(fixture.recorder.events, [.firstAuthoritativeProjectionApplied])
            switch interruption {
            case .cancel:
                fixture.composition.workspaceSessionActivationTask?.cancel()
            case .beginClosing:
                fixture.composition.workspaceRuntimeBeginClose()
            }
            await fixture.initialPresentationGate.release()
            await fixture.indexGate.release()
            await fixture.composition.workspaceSessionActivationTask?.value

            XCTAssertEqual(
                fixture.recorder.events,
                [.firstAuthoritativeProjectionApplied],
                "unexpected readiness progress for \(interruption)"
            )
            XCTAssertFalse(
                fixture.composition.workspaceManager.isInitialized,
                "selected initialization escaped fail-closed boundary for \(interruption)"
            )
            XCTAssertTrue(
                fixture.container.runtimeAdapterRegistry?.latestRoutingTableSnapshot.mappings.isEmpty == true,
                "stale adapter published for \(interruption)"
            )
            if let runtimeID = fixture.composition.workspaceRuntimeID {
                XCTAssertNil(
                    fixture.container.runtimeAdapterRegistry?.publicationState(runtimeID: runtimeID),
                    "adapter entry was staged for \(interruption)"
                )
            }

            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }
    }

    private enum ReadinessInterruption: String, CaseIterable {
        case cancel
        case beginClosing
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
        let readinessReached: XCTestExpectation?
        let initialPresentationReached: XCTestExpectation?
    }

    private static var nextWindowID = -20000

    private func makeFixture(gateInitialRestore: Bool = false) throws -> Fixture {
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
        let readinessReached = gateInitialRestore ? nil : expectation(description: "assembled readiness reached")
        let initialPresentationReached = gateInitialRestore
            ? expectation(description: "initial active-session presentation reached")
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
                viewModel.setAgentModeActive(true)
            },
            recordActivationEvent: { recorder.record($0) },
            waitAfterInitialActiveSessionRestore: {
                readinessReached?.fulfill()
                await readinessGate.wait()
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
            readinessReached: readinessReached,
            initialPresentationReached: initialPresentationReached
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
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }
}
