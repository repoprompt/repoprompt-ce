import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// Execution-time isolation for existing target-bearing `agent_run` / `agent_manage` operations.
///
/// A disclosed full session UUID plus same-window routing must not be enough to reach an unrelated
/// session. Denials reuse the exact "not found" wording so an unauthorized UUID is indistinguishable
/// from a nonexistent one.
@MainActor
final class AgentSessionTargetOperationAuthorizationTests: XCTestCase {
    private let callerSessionID = UUID()

    // MARK: - agent_run

    func testAgentOriginCallerCannotPollAnUnrelatedSessionByFullUUID() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let service = makeRunService(window: window, callerSessionID: callerSessionID)
        let sibling = UUID()

        await assertUniformDenial(reference: sibling.uuidString) {
            try await service.execute(args: [
                "op": .string("poll"),
                "session_id": .string(sibling.uuidString)
            ])
        }
    }

    func testAgentOriginCallerCannotSteerCancelOrRespondToAnUnrelatedSession() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let service = makeRunService(window: window, callerSessionID: callerSessionID)
        let sibling = UUID()

        for args in [
            ["op": Value.string("steer"), "session_id": .string(sibling.uuidString), "message": .string("hi")],
            ["op": Value.string("cancel"), "session_id": .string(sibling.uuidString)],
            [
                "op": Value.string("respond"),
                "session_id": .string(sibling.uuidString),
                "interaction_id": .string(UUID().uuidString),
                "answer": .string("yes")
            ]
        ] {
            await assertUniformDenial(reference: sibling.uuidString) {
                try await service.execute(args: args)
            }
        }
    }

    func testAgentOriginCallerCannotTargetItsOwnSession() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let service = makeRunService(window: window, callerSessionID: callerSessionID)

        await assertUniformDenial(reference: callerSessionID.uuidString) {
            try await service.execute(args: [
                "op": .string("respond"),
                "session_id": .string(callerSessionID.uuidString),
                "interaction_id": .string(UUID().uuidString),
                "answer": .string("yes")
            ])
        }
    }

    func testMultiTargetPollIsAllOrNothing() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let service = makeRunService(window: window, callerSessionID: callerSessionID)
        let siblings = [UUID(), UUID()]

        await assertUniformDenial(reference: siblings[0].uuidString) {
            try await service.execute(args: [
                "op": .string("poll"),
                "session_ids": .array(siblings.map { .string($0.uuidString) })
            ])
        }
    }

    func testUnresolvedAgentRunRoutingFailsClosed() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        // Agent Mode purpose with no exact run-scoped session resolution must never be treated as an
        // administrative principal.
        let service = makeRunService(window: window, callerSessionID: nil, runPurpose: .agentModeRun)
        let sibling = UUID()

        await assertUniformDenial(reference: sibling.uuidString) {
            try await service.execute(args: [
                "op": .string("poll"),
                "session_id": .string(sibling.uuidString)
            ])
        }
    }

    func testReconnectingAgentWithStaleCaptureTimePurposeIsNotTreatedAsAdministrative() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        // Reconnect/handover shape: capture-time metadata still reads `.unknown` while the live
        // connection purpose already says Agent Mode, and exact run-scoped routing has not settled.
        let connectionID = UUID()
        await ServerNetworkManager.shared.setRunPurpose(.agentModeRun, for: connectionID)
        let staleMetadata = MCPServerViewModel.RequestMetadata(
            connectionID: connectionID,
            clientName: "agent-session-authorization-tests",
            windowID: window.windowID,
            runPurpose: nil
        )

        let isAgentOrigin = await AgentSessionTargetOperationGuard.isAgentOriginConnection(
            metadata: staleMetadata
        )
        XCTAssertTrue(isAgentOrigin, "the live connection purpose is an authoritative Agent Mode signal")
        let caller = await AgentSessionTargetOperationGuard.resolveCaller(
            metadata: staleMetadata,
            targetWindow: window,
            resolveSpawnParentSessionID: { _, _ in nil }
        )
        XCTAssertEqual(caller, .unresolvedAgentRun)

        let service = makeRunService(
            window: window,
            callerSessionID: nil,
            runPurpose: nil,
            connectionID: connectionID
        )
        let sibling = UUID()
        await assertUniformDenial(reference: sibling.uuidString) {
            try await service.execute(args: [
                "op": .string("poll"),
                "session_id": .string(sibling.uuidString)
            ])
        }
        await ServerNetworkManager.shared.setRunPurpose(.unknown, for: connectionID)
    }

    func testCachedRunPolicyPurposeAloneAlsoBlocksAdministrativeClassification() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        // Only the captured signal says Agent Mode; live and cached purposes are unknown. Any single
        // authoritative Agent Mode signal must still fail closed.
        let metadata = MCPServerViewModel.RequestMetadata(
            connectionID: UUID(),
            clientName: "agent-session-authorization-tests",
            windowID: window.windowID,
            runPurpose: .agentModeRun
        )
        let isAgentOrigin = await AgentSessionTargetOperationGuard.isAgentOriginConnection(metadata: metadata)
        XCTAssertTrue(isAgentOrigin)
    }

    /// Regression: run-installed tab context is Agent-origin evidence even with no purpose at all.
    ///
    /// A reconnect or handover can lose the captured, live, *and* cached purposes simultaneously —
    /// capture-time metadata predates the new purpose, the live purpose has not been reapplied, and
    /// no run policy is cached to rehydrate from — while the connection is still the run's own. A
    /// purpose-only classification read exactly that state as an unrestricted administrative
    /// principal and let it operate on any session in the window.
    func testRunInstalledTabContextWithoutAnyPurposeSignalStillFailsClosed() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let connectionID = UUID()
        let runID = UUID()
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let tabID = try XCTUnwrap(workspace.composeTabs.first?.id)

        // Server-installed run routing for this connection; no purpose recorded anywhere. A bound
        // context carrying a run ID resolves as `.runInstall`.
        window.mcpServer.tabContextByConnectionID[connectionID] = MCPServerViewModel.TabContextSnapshot(
            tabID: tabID,
            windowID: window.windowID,
            workspaceID: workspace.id,
            promptText: "",
            selection: StoredSelection(),
            selectedMetaPromptIDs: [],
            tabName: "Run tab",
            runID: runID,
            explicitlyBound: false
        )
        defer { window.mcpServer.tabContextByConnectionID.removeValue(forKey: connectionID) }

        let metadata = MCPServerViewModel.RequestMetadata(
            connectionID: connectionID,
            clientName: "agent-session-authorization-tests",
            windowID: window.windowID,
            runPurpose: nil
        )
        let livePurpose = await ServerNetworkManager.shared.runPurpose(for: connectionID)
        XCTAssertEqual(livePurpose, .unknown)
        let purposeOnly = await AgentSessionTargetOperationGuard.isAgentOriginConnection(
            metadata: metadata
        )
        XCTAssertFalse(purposeOnly, "the purpose triple alone cannot see this connection")

        let isAgentOrigin = await AgentSessionTargetOperationGuard.isAgentOriginConnection(
            metadata: metadata,
            targetWindow: window
        )
        XCTAssertTrue(isAgentOrigin, "run-installed tab context is server-owned Agent-origin routing")
        let caller = await AgentSessionTargetOperationGuard.resolveCaller(
            metadata: metadata,
            targetWindow: window,
            resolveSpawnParentSessionID: { _, _ in nil }
        )
        XCTAssertEqual(
            caller,
            .unresolvedAgentRun,
            "Unresolved run-scoped routing must never be handed unrestricted administrative authority"
        )
        XCTAssertEqual(
            DomainAgentSessionOperationAuthorizer.discoveryScope(for: caller),
            .none,
            "...and must not be able to enumerate sessions either"
        )
    }

    /// A connection→run mapping alone is deliberately *not* Agent-origin evidence.
    ///
    /// An external supervisor that started a run carries one too, so treating it as proof would
    /// downgrade every such client from administrative to denied.
    func testRunMappingAloneDoesNotMakeASupervisorConnectionAgentOrigin() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let connectionID = UUID()
        let runID = UUID()
        window.mcpServer.connectionIDToRunID[connectionID] = runID
        window.mcpServer.connectionIDByRunID[runID] = connectionID
        defer {
            window.mcpServer.connectionIDToRunID.removeValue(forKey: connectionID)
            window.mcpServer.connectionIDByRunID.removeValue(forKey: runID)
        }

        let metadata = MCPServerViewModel.RequestMetadata(
            connectionID: connectionID,
            clientName: "agent-session-authorization-tests",
            windowID: window.windowID,
            runPurpose: nil
        )
        let caller = await AgentSessionTargetOperationGuard.resolveCaller(
            metadata: metadata,
            targetWindow: window,
            resolveSpawnParentSessionID: { _, _ in nil }
        )
        XCTAssertEqual(
            caller,
            .administrativePrincipal,
            "Supervising a run is not the same as being one"
        )
    }

    func testConnectionWithNoAuthoritativePurposeSignalRemainsAdministrative() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let metadata = MCPServerViewModel.RequestMetadata(
            connectionID: UUID(),
            clientName: "agent-session-authorization-tests",
            windowID: window.windowID,
            runPurpose: nil
        )
        let isAgentOrigin = await AgentSessionTargetOperationGuard.isAgentOriginConnection(metadata: metadata)
        XCTAssertFalse(isAgentOrigin)
        let caller = await AgentSessionTargetOperationGuard.resolveCaller(
            metadata: metadata,
            targetWindow: window,
            resolveSpawnParentSessionID: { _, _ in nil }
        )
        XCTAssertEqual(caller, .administrativePrincipal)
    }

    func testAdministrativePrincipalRetainsExistingRoutedBehavior() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let service = makeRunService(window: window, callerSessionID: nil, runPurpose: nil)
        let unknown = UUID()

        // Administrative callers are not gated by spawn provenance, so this reaches the existing
        // expired-handle path rather than an authorization denial.
        let reply = try await service.execute(args: [
            "op": .string("poll"),
            "session_id": .string(unknown.uuidString)
        ])
        XCTAssertEqual(reply.objectValue?["status"]?.stringValue, "expired")
    }

    // MARK: - agent_manage

    func testAgentOriginCallerCannotGetLogOrStopAnUnrelatedSession() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let sibling = UUID()
        try await persistSession(id: sibling, workspace: workspace, parentSessionID: nil)
        let service = makeManageService(window: window, callerSessionID: callerSessionID)

        for op in ["get_log", "stop_session", "extract_handoff"] {
            await assertUniformDenial(reference: sibling.uuidString) {
                try await service.execute(args: [
                    "op": .string(op),
                    "session_id": .string(sibling.uuidString)
                ])
            }
        }
    }

    /// Regression: `get_log` and `extract_handoff` must authorize **before** touching the target.
    ///
    /// Both used to resolve the transcript first, which hydrates a live session (or loads its full
    /// persisted transcript) and surfaces target-specific errors — real target-side work performed
    /// for a caller that was then denied. Hydration is the observable proxy: a denied caller must
    /// leave the unrelated session exactly as unloaded as it found it.
    func testGetLogAndExtractHandoffAuthorizeBeforeHydratingTheTarget() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let agentModeVM = window.agentModeViewModel

        // A live, not-yet-hydrated sibling session this caller did not spawn.
        let tabID = try XCTUnwrap(workspace.composeTabs.first?.id)
        let siblingSession = agentModeVM.session(for: tabID)
        let sibling = try XCTUnwrap(
            agentModeVM.test_ensureSessionBoundToTab(siblingSession),
            "expected a durable persistent binding for the sibling tab"
        )
        siblingSession.hasLoadedPersistedState = false

        let service = makeManageService(window: window, callerSessionID: callerSessionID)
        for op in ["get_log", "extract_handoff"] {
            await assertUniformDenial(reference: sibling.uuidString) {
                try await service.execute(args: [
                    "op": .string(op),
                    "session_id": .string(sibling.uuidString)
                ])
            }
            XCTAssertFalse(
                siblingSession.hasLoadedPersistedState,
                "\(op) must deny before hydrating a session the caller has no authority over"
            )
        }
    }

    func testCleanupSessionsAuthorizesEveryTargetBeforeAnyMutation() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let child = UUID()
        let sibling = UUID()
        let deleted = DeletionRecorder()
        let service = makeManageService(
            window: window,
            callerSessionID: callerSessionID,
            metadataByID: [
                child: makeMeta(id: child, parentSessionID: callerSessionID),
                sibling: makeMeta(id: sibling, parentSessionID: UUID())
            ],
            deleted: deleted
        )

        await assertUniformDenial(reference: sibling.uuidString) {
            try await service.execute(args: [
                "op": .string("cleanup_sessions"),
                "session_ids": .array([.string(child.uuidString), .string(sibling.uuidString)])
            ])
        }
        XCTAssertTrue(
            deleted.sessionIDs.isEmpty,
            "the authorized sibling target must not be deleted when a later target is denied"
        )

        // The direct child alone is authorized and proceeds.
        let reply = try await service.execute(args: [
            "op": .string("cleanup_sessions"),
            "session_ids": .array([.string(child.uuidString)])
        ])
        XCTAssertEqual(reply.objectValue?["deleted_count"]?.intValue, 1)
        XCTAssertEqual(deleted.sessionIDs, [child])
    }

    func testListSessionsScopesDiscoveryToDirectChildrenAndFailsClosedWhenUnrouted() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let child = UUID()
        let sibling = UUID()
        try await persistSession(id: child, workspace: workspace, parentSessionID: callerSessionID)
        try await persistSession(id: sibling, workspace: workspace, parentSessionID: UUID())

        let scoped = makeManageService(window: window, callerSessionID: callerSessionID)
        let scopedIDs = try await sessionIDs(in: scoped.execute(args: ["op": .string("list_sessions")]))
        XCTAssertEqual(scopedIDs, [child.uuidString])

        let unrouted = makeManageService(window: window, callerSessionID: nil, runPurpose: .agentModeRun)
        let unroutedIDs = try await sessionIDs(in: unrouted.execute(args: ["op": .string("list_sessions")]))
        XCTAssertTrue(unroutedIDs.isEmpty, "an unrouted Agent Mode caller must enumerate nothing")

        let administrative = makeManageService(window: window, callerSessionID: nil, runPurpose: nil)
        let allIDs = try await sessionIDs(in: administrative.execute(args: ["op": .string("list_sessions")]))
        XCTAssertTrue(allIDs.contains(child.uuidString))
        XCTAssertTrue(allIDs.contains(sibling.uuidString))
    }

    // MARK: - Helpers

    private final class DeletionRecorder {
        var sessionIDs: [UUID] = []
    }

    private func assertUniformDenial(
        reference: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Value
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected an authorization denial for \(reference)", file: file, line: line)
        } catch {
            let message = "\(error)"
            XCTAssertTrue(
                message.contains("was not found in the active workspace"),
                "Denial must be indistinguishable from a missing session; got: \(message)",
                file: file,
                line: line
            )
        }
    }

    private func sessionIDs(in value: Value) throws -> [String] {
        let sessions = try XCTUnwrap(value.objectValue?["sessions"]?.arrayValue)
        return sessions.compactMap { $0.objectValue?["session_id"]?.stringValue }.sorted()
    }

    private func makeRunService(
        window: WindowState,
        callerSessionID: UUID?,
        runPurpose: MCPRunPurpose? = .agentModeRun,
        connectionID: UUID? = nil
    ) -> AgentRunMCPToolService {
        var service = AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: connectionID,
                    clientName: "agent-session-authorization-tests",
                    windowID: window.windowID,
                    runPurpose: runPurpose
                )
            },
            requireTargetWindow: { window },
            resolveRequestedTabID: { _ in nil },
            resolveSpawnParentSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in callerSessionID },
            withHeartbeat: { _, _, _, _, operation in try await operation() },
            startRun: { _, _, _, _, _, _, _, _, _, _, _ in
                throw MCPError.internalError("startRun is not used by authorization tests")
            }
        )
        service.testAgentModeViewModel = window.agentModeViewModel
        return service
    }

    private func makeManageService(
        window: WindowState,
        callerSessionID: UUID?,
        runPurpose: MCPRunPurpose? = .agentModeRun,
        metadataByID: [UUID: AgentSessionMeta] = [:],
        deleted: DeletionRecorder = DeletionRecorder()
    ) -> AgentManageMCPToolService {
        AgentManageMCPToolService(
            toolName: MCPWindowToolName.agentManage,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: nil,
                    clientName: "agent-session-authorization-tests",
                    windowID: window.windowID,
                    runPurpose: runPurpose
                )
            },
            requireTargetWindow: { window },
            resolveSpawnSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in callerSessionID },
            bindCurrentRequestToTab: { _, _ in },
            cleanupDependencies: AgentManageMCPToolService.CleanupDependencies(
                loadPersistedMetadata: { sessionID, _ in metadataByID[sessionID] },
                loadPersistedSession: { _, _ in nil },
                deleteOpenSession: { _, _, _ in nil },
                deletePersistedSession: { sessionID, _ in deleted.sessionIDs.append(sessionID) },
                finalizePersistedReferences: { _, _, _ in 0 },
                checkCancellation: {}
            )
        )
    }

    private func makeMeta(id: UUID, parentSessionID: UUID?) -> AgentSessionMeta {
        AgentSessionMeta(
            id: id,
            composeTabID: nil,
            name: "Session \(id.uuidString.prefix(8))",
            lastModified: Date(timeIntervalSinceReferenceDate: 1),
            itemCount: 0,
            agentKind: AgentProviderKind.codexExec.rawValue,
            agentModel: "codex",
            lastRunState: AgentSessionRunState.completed.rawValue,
            parentSessionID: parentSessionID,
            isMCPOriginated: true,
            worktreeBindingSummaries: [],
            activeWorktreeMergeSummaries: []
        )
    }

    private func persistSession(
        id: UUID,
        workspace: WorkspaceModel,
        parentSessionID: UUID?
    ) async throws {
        let session = AgentSession(
            id: id,
            workspaceID: workspace.id,
            name: "Session \(id.uuidString.prefix(8))",
            savedAt: Date(timeIntervalSinceReferenceDate: 42),
            itemCount: 0,
            agentKind: AgentProviderKind.codexExec.rawValue,
            lastRunState: AgentSessionRunState.completed.rawValue,
            autoEditEnabled: true,
            parentSessionID: parentSessionID,
            isMCPOriginated: true
        )
        try await AgentSessionDataService.shared.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
    }

    private func makeWindow() async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        let workspace = window.workspaceManager.createWorkspace(
            name: "Agent Session Authorization \(UUID().uuidString.prefix(8))",
            repoPaths: [FileManager.default.currentDirectoryPath],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "agentSessionTargetOperationAuthorizationTests"
        )
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        return window
    }
}
