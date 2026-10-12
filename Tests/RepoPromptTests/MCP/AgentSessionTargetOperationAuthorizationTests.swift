import Foundation
import MCP
import RepoPromptSettingsCore
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

    private final class InvocationDiagnostics: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [MCPInvocationContextFailure] = []

        func record(_ failure: MCPInvocationContextFailure) {
            lock.lock()
            defer { lock.unlock() }
            recorded.append(failure)
        }

        var failures: [MCPInvocationContextFailure] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }
    }

    func testInvocationBridgeMissingContextFailsClosedWithInjectedDiagnostic() throws {
        let diagnostics = InvocationDiagnostics()
        try MCPInvocationContextBridge.$diagnosticSink.withValue({ diagnostics.record($0) }) {
            try MCPInvocationContextBridge.currentTaskLocal.withValue(nil) {
                XCTAssertThrowsError(try MCPInvocationContextBridge.require(toolName: "ask_oracle")) { error in
                    XCTAssertEqual(error as? MCPInvocationContextFailure, .missingExpectedContext)
                }
            }
        }
        #if DEBUG
            XCTAssertEqual(diagnostics.failures, [.missingExpectedContext])
        #endif
    }

    func testInvocationBridgeRejectsForeignConnectionAuthority() throws {
        let connection = NSObject()
        let invocationID = UUID()
        let context = ToolInvocationContext(
            origin: .network,
            invocationID: invocationID,
            requestID: nil,
            toolName: "ask_oracle",
            metadata: MCPRequestMetadata(
                connectionID: UUID(), clientName: "test", windowID: nil,
                invocationID: invocationID
            ),
            dispatchAuthorization: MCPToolDispatchAuthorization(
                connectionID: UUID(), connectionIdentity: ObjectIdentifier(connection),
                lifecycleGeneration: 1, windowIdentity: nil
            )
        )
        try MCPInvocationContextBridge.currentTaskLocal.withValue(context) {
            XCTAssertThrowsError(try MCPInvocationContextBridge.require(toolName: "ask_oracle")) { error in
                XCTAssertEqual(error as? MCPInvocationContextFailure, .connectionMismatch)
            }
        }
    }

    func testInvocationBridgeRejectsWrongToolAndMissingNetworkWindowAuthorization() throws {
        let invocationID = UUID()
        let context = ToolInvocationContext(
            origin: .network,
            invocationID: invocationID,
            requestID: nil,
            toolName: "ask_oracle",
            metadata: MCPRequestMetadata(
                connectionID: UUID(), clientName: "test", windowID: 42,
                invocationID: invocationID
            ),
            dispatchAuthorization: nil
        )
        try MCPInvocationContextBridge.currentTaskLocal.withValue(context) {
            XCTAssertThrowsError(try MCPInvocationContextBridge.require(toolName: "ask_user")) { error in
                XCTAssertEqual(error as? MCPInvocationContextFailure, .toolMismatch)
            }
            XCTAssertThrowsError(try MCPInvocationContextBridge.require(toolName: "ask_oracle", expectedWindowID: 42)) { error in
                XCTAssertEqual(error as? MCPInvocationContextFailure, .missingAuthorization)
            }
        }
    }

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

    func testChildZeroDoesNotDescribeANonemptyWorkspaceAsEmpty() async throws {
        let window = try await makeWindow(waitForInitialization: true)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let tabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let siblingSession = window.agentModeViewModel.session(for: tabID)
        let sibling = try XCTUnwrap(window.agentModeViewModel.test_ensureSessionBoundToTab(siblingSession))
        XCTAssertNil(siblingSession.parentSessionID, "the workspace witness is a real top-level session, not a child")

        let childCaller = makeManageService(window: window, callerSessionID: callerSessionID)
        let reply = try await childCaller.execute(args: ["op": .string("list_sessions")])
        XCTAssertEqual(reply.objectValue?["sessions"], .array([]))
        XCTAssertEqual(reply.objectValue?["scope"], .string("spawned_by_caller"))
        let note = try XCTUnwrap(reply.objectValue?["note"]?.stringValue)
        XCTAssertTrue(note.contains("not a workspace inventory"))
        XCTAssertTrue(note.contains("session_admin request_scope"))
        XCTAssertTrue(note.contains("observe"))
        XCTAssertTrue(note.contains("inventory"))
        let rendered = ToolOutputFormatter.formatAgentManage(args: ["op": .string("list_sessions")], value: reply)
        guard case let .text(text, _, _) = rendered.first else { return XCTFail("expected rendered text") }
        XCTAssertTrue(text.contains("spawned_by_caller"))
        XCTAssertTrue(text.contains(note), "scope guidance must survive the agent-facing formatter")
        XCTAssertFalse(text.contains(sibling.uuidString), "disclosure must not enumerate siblings")

        let admin = makeManageService(window: window, callerSessionID: nil, runPurpose: nil)
        let adminReply = try await admin.execute(args: ["op": .string("list_sessions")])
        XCTAssertEqual(try Set(XCTUnwrap(adminReply.objectValue).keys), ["sessions"])
        let adminIDs = try await sessionIDs(in: admin.execute(args: ["op": .string("list_sessions")]))
        XCTAssertTrue(adminIDs.contains(sibling.uuidString))

        let unrouted = makeManageService(window: window, callerSessionID: nil, runPurpose: .agentModeRun)
        let unresolved = try await unrouted.execute(args: ["op": .string("list_sessions")])
        XCTAssertEqual(unresolved.objectValue?["scope"], .string("unresolved_caller"))
        XCTAssertEqual(unresolved.objectValue?["sessions"], .array([]))
    }

    func testAdministrativePinAndReorderDoesNotResumeIndexOnlySessions() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let firstTabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let firstSession = window.agentModeViewModel.session(for: firstTabID)
        let firstID = try XCTUnwrap(window.agentModeViewModel.test_ensureSessionBoundToTab(firstSession))
        let createdSecondTab = await window.promptManager.createBackgroundComposeTab(strategy: .blank, name: "Second")
        let secondTab = try XCTUnwrap(createdSecondTab)
        let secondSession = window.agentModeViewModel.session(for: secondTab.id)
        let secondID = try XCTUnwrap(window.agentModeViewModel.test_ensureSessionBoundToTab(secondSession))
        firstSession.hasLoadedPersistedState = false
        secondSession.hasLoadedPersistedState = false

        let admin = makeManageService(window: window, callerSessionID: nil, runPurpose: nil)
        for sessionID in [firstID, secondID] {
            _ = try await admin.execute(args: [
                "op": .string("set_session_pin"),
                "session_id": .string(sessionID.uuidString),
                "pinned": .bool(true)
            ])
        }
        let beforeValue = try await admin.execute(args: ["op": .string("list_pinned_sessions")])
        let before = try pinnedSessionIDs(in: beforeValue)
        XCTAssertEqual(Set(before), Set([firstID, secondID]))
        let desired = Array(before.reversed())
        _ = try await admin.execute(args: [
            "op": .string("reorder_pinned_sessions"),
            "expected_session_ids": .array(before.map { .string($0.uuidString) }),
            "session_ids": .array(desired.map { .string($0.uuidString) })
        ])
        let afterValue = try await admin.execute(args: ["op": .string("list_pinned_sessions")])
        XCTAssertEqual(try pinnedSessionIDs(in: afterValue), desired)
        XCTAssertFalse(firstSession.hasLoadedPersistedState)
        XCTAssertFalse(secondSession.hasLoadedPersistedState)

        do {
            _ = try await admin.execute(args: [
                "op": .string("reorder_pinned_sessions"),
                "expected_session_ids": .array(before.map { .string($0.uuidString) }),
                "session_ids": .array(before.map { .string($0.uuidString) })
            ])
            XCTFail("Expected a stale-order rejection")
        } catch {
            XCTAssertTrue(String(describing: error).contains("Pinned session order changed"))
        }

        let agent = makeManageService(window: window, callerSessionID: firstID)
        do {
            _ = try await agent.execute(args: ["op": .string("list_pinned_sessions")])
            XCTFail("Agent-origin caller must not enumerate workspace-wide pins")
        } catch {
            XCTAssertTrue(String(describing: error).contains("external administrative MCP connection"))
        }
    }

    private func pinnedSessionIDs(in value: Value) throws -> [UUID] {
        let sessions = try XCTUnwrap(value.objectValue?["sessions"]?.arrayValue)
        return try sessions.map { item in
            let raw = try XCTUnwrap(item.objectValue?["session_id"]?.stringValue)
            return try XCTUnwrap(UUID(uuidString: raw))
        }
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
                message.contains("is not available to this caller's scope"),
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
            startRun: { _, _, _, _, _, _, _, _, _, _, _, _ in
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
            acpModelParameterSelections: [],
            parentSessionID: parentSessionID,
            createdByOverseerSessionID: nil,
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

    private func makeWindow(waitForInitialization: Bool = false) async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        if waitForInitialization {
            // Establish the witness only after launch restoration can no longer switch its workspace.
            await window.workspaceManager.awaitInitialized()
        }

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

// MARK: - DelegationMembershipCensusTests regressions

@MainActor
final class DelegationMembershipCensusTests: XCTestCase {
    func testUsageAndMembersEachReadOneCensusWithoutPerMemberSourceResolution() {
        let root = UUID(), workspace = UUID()
        let rows = [row(root, workspace: workspace)] + (0 ..< 1500).map { index in
            row(
                UUID(),
                workspace: workspace,
                parent: root,
                live: index.isMultiple(of: 2),
                worktrees: index.isMultiple(of: 3) ? ["shared"] : []
            )
        }
        let source = CountingSource(rows)
        var projector = SpawnProvenanceDelegationMembershipProjector(source: source)
        projector.ownedUnreleasedWorktreeIDs = { members in
            XCTAssertEqual(members, Set(rows.map(\.sessionID)))
            return ["shared", "owned-unbound"]
        }
        let scope = grant(.tree(rootSessionID: root), grantee: root)
        let usage = projector.usage(of: scope, spawnParentSessionID: rows.last?.sessionID)
        XCTAssertEqual(usage.liveSessionCount, 751)
        XCTAssertEqual(usage.worktreeCount, 2)
        XCTAssertEqual(usage.spawnParentDepth, 1)
        XCTAssertEqual(source.censusReads, 1)
        XCTAssertEqual(source.individualReads, 0)
        XCTAssertEqual(Set(projector.members(of: scope)), Set(rows.map(\.sessionID)))
        XCTAssertEqual(source.censusReads, 2)
        XCTAssertEqual(source.individualReads, 0)

        // A later synchronous call must see changed ownership/liveness, not a cached census.
        source.rows = [row(root, workspace: workspace, live: false)]
        projector.ownedUnreleasedWorktreeIDs = { _ in [] }
        XCTAssertEqual(projector.usage(of: scope, spawnParentSessionID: nil).liveSessionCount, 0)
        XCTAssertEqual(source.censusReads, 3)
    }

    func testCensusMembershipMatchesIndividualProofsForCyclesMissingParentsAndDepthLimit() {
        let root = UUID(), workspace = UUID(), cycleA = UUID(), cycleB = UUID()
        var rows = [
            row(root, workspace: workspace),
            row(cycleA, workspace: workspace, parent: cycleB),
            row(cycleB, workspace: workspace, parent: cycleA),
            row(UUID(), workspace: workspace, parent: UUID())
        ]
        var parent = root
        for _ in 0 ..< 260 {
            let id = UUID()
            rows.append(row(id, workspace: workspace, parent: parent))
            parent = id
        }
        let source = CountingSource(rows)
        let projector = SpawnProvenanceDelegationMembershipProjector(source: source)
        let kinds: [DomainDelegationScopeKind] = [.tree(rootSessionID: root), .workspace(workspaceID: workspace), .allSessions]
        for kind in kinds {
            let scope = grant(kind, grantee: root)
            let individual = rows.filter { projector.membershipProof(for: $0.sessionID, in: scope) != nil }.map(\.sessionID)
            source.resetCounts()
            XCTAssertEqual(projector.members(of: scope), individual)
            XCTAssertEqual(source.censusReads, 1)
            XCTAssertEqual(source.individualReads, 0)
            let usage = projector.usage(of: scope, spawnParentSessionID: parent)
            XCTAssertEqual(usage.liveSessionCount, individual.count)
            XCTAssertEqual(source.censusReads, 2)
            XCTAssertEqual(source.individualReads, 0)
            if case .tree = kind {
                XCTAssertNil(usage.spawnParentDepth)
                XCTAssertFalse(individual.contains(cycleA))
                XCTAssertFalse(individual.contains(parent))
            }
        }
    }

    func testBatchLiveStateMatchesSingleResolutionAndSeesSameTurnAmbiguity() throws {
        let viewModel = AgentModeViewModel(
            testWindowID: -992, testWorkspacePath: FileManager.default.temporaryDirectory.path,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Census tests must not start providers")
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        let idleID = UUID(), runningID = UUID(), ambiguousID = UUID(), missingID = UUID()
        for (id, active) in [(idleID, false), (runningID, true), (ambiguousID, false), (ambiguousID, false)] {
            let session = AgentModeViewModel.TabSession(tabID: UUID())
            viewModel.test_installLiveSession(session)
            _ = try XCTUnwrap(viewModel.test_installPersistentSessionBinding(sessionID: id, on: session))
            if active { session.runState = .running }
        }
        let ids: Set = [idleID, runningID, ambiguousID, missingID]
        var individual: [UUID: AgentModeViewModel.AuthoritativeLiveSessionState] = [:]
        for id in ids {
            do {
                let session = try viewModel.authoritativeLiveSession(for: id)
                individual[id] = session.map { $0.runState.isActive ? .running : .idle } ?? .notFound
            } catch {
                individual[id] = .ambiguous
            }
        }
        viewModel.test_resetPersistentBindingResolutionSnapshotBuildCount()
        XCTAssertEqual(viewModel.authoritativeLiveSessionStates(for: ids), individual)
        XCTAssertEqual(individual[ambiguousID], .ambiguous)
        XCTAssertEqual(viewModel.test_persistentBindingResolutionBuildCount, 1)
        let secondIdle = AgentModeViewModel.TabSession(tabID: UUID())
        viewModel.test_installLiveSession(secondIdle)
        _ = try XCTUnwrap(viewModel.test_installPersistentSessionBinding(sessionID: idleID, on: secondIdle))
        XCTAssertEqual(viewModel.authoritativeLiveSessionStates(for: ids)[idleID], .ambiguous)
        XCTAssertEqual(viewModel.test_persistentBindingResolutionBuildCount, 2)
        XCTAssertTrue(viewModel.authoritativeLiveSessionStates(for: []).isEmpty)
        XCTAssertEqual(viewModel.test_persistentBindingResolutionBuildCount, 2)
    }

    func testProductionCensusBuildsOneBindingSnapshotPerWindowAndPreservesOwnerAndLiveness() async throws {
        let first = WindowState(), second = WindowState()
        addTeardownBlock { @MainActor in
            await first.tearDown()
            await second.tearDown()
        }
        await first.workspaceManager.awaitInitialized()
        await second.workspaceManager.awaitInitialized()
        let ownerWorkspace = WorkspaceModel(name: "Index owner", repoPaths: [])
        let otherWorkspace = WorkspaceModel(name: "Other index owner", repoPaths: [])
        let ambiguousID = UUID(), runningID = UUID(), idleID = UUID(), absentID = UUID()
        let ids = [ambiguousID, runningID, idleID, absentID] + (0 ..< 1500).map { _ in UUID() }
        installIndex(ids, workspace: ownerWorkspace, on: first.agentModeViewModel)
        installIndex([ambiguousID, runningID], workspace: otherWorkspace, on: second.agentModeViewModel)
        for id in [ambiguousID, runningID] {
            for _ in 0 ..< 2 {
                let session = AgentModeViewModel.TabSession(tabID: UUID())
                first.agentModeViewModel.test_installLiveSession(session)
                _ = try XCTUnwrap(first.agentModeViewModel.test_installPersistentSessionBinding(sessionID: id, on: session))
            }
        }
        let running = AgentModeViewModel.TabSession(tabID: UUID())
        second.agentModeViewModel.test_installLiveSession(running)
        _ = try XCTUnwrap(second.agentModeViewModel.test_installPersistentSessionBinding(sessionID: runningID, on: running))
        running.runState = .running
        let idle = AgentModeViewModel.TabSession(tabID: UUID())
        second.agentModeViewModel.test_installLiveSession(idle)
        _ = try XCTUnwrap(second.agentModeViewModel.test_installPersistentSessionBinding(sessionID: idleID, on: idle))
        let source = OpenWindowsDelegationProvenanceSource(windows: { [first, second] })
        let expected = Dictionary(uniqueKeysWithValues: ids.compactMap { id in source.provenance(for: id).map { (id, $0) } })
        first.agentModeViewModel.test_resetPersistentBindingResolutionSnapshotBuildCount()
        second.agentModeViewModel.test_resetPersistentBindingResolutionSnapshotBuildCount()
        let census = source.allKnownSessions()
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: census.map { ($0.sessionID, $0) }), expected)
        XCTAssertEqual(census.count, ids.count, "Duplicate indexes keep the first owning index")
        XCTAssertEqual(expected[ambiguousID]?.workspaceID, ownerWorkspace.id)
        XCTAssertEqual(expected[ambiguousID]?.runState, .unknown)
        XCTAssertEqual(expected[ambiguousID]?.isLive, true)
        XCTAssertEqual(expected[runningID]?.runState, .running, "Running beats ambiguity in another window")
        XCTAssertEqual(expected[idleID]?.runState, .idle)
        XCTAssertEqual(expected[idleID]?.isLive, true)
        XCTAssertEqual(expected[absentID]?.isLive, false)
        XCTAssertEqual(first.agentModeViewModel.test_persistentBindingResolutionBuildCount, 1)
        XCTAssertEqual(second.agentModeViewModel.test_persistentBindingResolutionBuildCount, 1)

        // A displaced index must contribute nothing, even if it still physically holds rows.
        let owner = AgentModeViewModel.SessionIndexOwner(workspaceID: ownerWorkspace.id, activationEpoch: 1)
        first.agentModeViewModel.test_installSessionIndexSnapshot(
            first.agentModeViewModel.sessionIndex, owner: owner,
            latestOwner: .init(workspaceID: UUID(), activationEpoch: 2), activeWorkspace: ownerWorkspace
        )
        XCTAssertEqual(Set(source.allKnownSessions().map(\.sessionID)), [ambiguousID, runningID])
        XCTAssertEqual(source.provenance(for: ambiguousID)?.workspaceID, otherWorkspace.id)
    }

    func testProductionMembershipReadsPlacementWithoutBuildingLivenessAndRemainsFresh() async throws {
        let window = WindowState()
        addTeardownBlock { @MainActor in await window.tearDown() }
        await window.workspaceManager.awaitInitialized()
        let workspace = WorkspaceModel(name: "Placement only", repoPaths: [])
        let root = UUID(), middle = UUID(), child = UUID()
        installIndex([root, middle, child], workspace: workspace, on: window.agentModeViewModel)
        var entries = window.agentModeViewModel.sessionIndex
        entries[middle]?.parentSessionID = root
        entries[child]?.parentSessionID = middle
        let owner = AgentModeViewModel.SessionIndexOwner(workspaceID: workspace.id, activationEpoch: 1)
        window.agentModeViewModel.test_installSessionIndexSnapshot(entries, owner: owner, latestOwner: owner, activeWorkspace: workspace)
        let session = try AgentModeViewModel.TabSession(tabID: XCTUnwrap(entries[child]?.tabID))
        window.agentModeViewModel.test_installLiveSession(session)
        _ = try XCTUnwrap(window.agentModeViewModel.test_installPersistentSessionBinding(sessionID: child, on: session))
        session.runState = .running
        let projector = SpawnProvenanceDelegationMembershipProjector(source: OpenWindowsDelegationProvenanceSource(windows: { [window] }))
        let scope = grant(.tree(rootSessionID: root), grantee: root)
        window.agentModeViewModel.test_resetPersistentBindingResolutionSnapshotBuildCount()
        XCTAssertEqual(projector.membershipProof(for: child, in: scope)?.basis, .treePath([child, middle, root]))
        XCTAssertEqual(window.agentModeViewModel.test_persistentBindingResolutionBuildCount, 0, "Placement walks must not census liveness for each ancestor")
        XCTAssertEqual(projector.targetState(for: child), .running, "State-dependent authority still resolves real liveness")
        XCTAssertEqual(window.agentModeViewModel.test_persistentBindingResolutionBuildCount, 1)
        entries[child]?.organizationalParentID = UUID()
        window.agentModeViewModel.test_installSessionIndexSnapshot(entries, owner: owner, latestOwner: owner, activeWorkspace: workspace)
        XCTAssertNil(projector.membershipProof(for: child, in: scope), "A same-turn reparent cannot ride the preceding placement proof")
        XCTAssertEqual(window.agentModeViewModel.test_persistentBindingResolutionBuildCount, 1)
        window.agentModeViewModel.test_installSessionIndexSnapshot(entries, owner: owner, latestOwner: .init(workspaceID: UUID(), activationEpoch: 2), activeWorkspace: workspace)
        XCTAssertNil(projector.membershipProof(for: child, in: grant(.workspace(workspaceID: workspace.id), grantee: root)), "Stale-owner indexes remain unavailable")
        XCTAssertEqual(window.agentModeViewModel.test_persistentBindingResolutionBuildCount, 1)
    }

    func testBatchAuthorizationUsesOneFreshCensusAndSameTurnAmbiguityTightensSpawnGuardrail() async throws {
        let window = WindowState()
        addTeardownBlock { @MainActor in await window.tearDown() }
        await window.workspaceManager.awaitInitialized()
        let workspace = WorkspaceModel(name: "Authorization census", repoPaths: [])
        let callerID = UUID(), targetID = UUID(), conflictID = UUID()
        let ids = [callerID, targetID, conflictID] + (0 ..< 253).map { _ in UUID() }
        installIndex(ids, workspace: workspace, on: window.agentModeViewModel)
        let source = OpenWindowsDelegationProvenanceSource(windows: { [window] })
        let projector = SpawnProvenanceDelegationMembershipProjector(source: source)
        let scopes = DelegationScopeRuntime(notifyCatalogChanged: { _ in })
        let requested = try scopes.requestScope(
            requesterSessionID: callerID, requesterTabID: nil, kind: .workspace(workspaceID: workspace.id),
            capabilities: [.observe, .organize, .spawn],
            guardrails: .init(maxLiveSessions: 1, bulkConfirmationThreshold: 1000),
            reason: nil, idempotencyKey: nil
        ).get()
        XCTAssertEqual(
            requested.guardrails.bulkConfirmationThreshold,
            25,
            "An agent cannot loosen the default bulk-card threshold in its request"
        )
        // This fixture measures authorization census work, not the bulk-card workflow. Only the
        // user's approval may permit this 256-item reversible batch without a separate card.
        let scope = try scopes.approve(
            requestID: requested.id,
            guardrails: .init(maxLiveSessions: 1, bulkConfirmationThreshold: 1000)
        ).get()
        XCTAssertEqual(scope.grant.guardrails.bulkConfirmationThreshold, 1000)
        let core = AgentSessionAdministrationCore(scopes: scopes, projector: projector)
        window.agentModeViewModel.test_resetPersistentBindingResolutionSnapshotBuildCount()
        guard case .authorized = core.authorize(.init(
            operation: .adminInventory, caller: .agentSession(callerID), scopeID: scope.id
        )) else { return XCTFail("Scope-only inventory authorization should not need a session census") }
        XCTAssertEqual(window.agentModeViewModel.test_persistentBindingResolutionBuildCount, 0)
        let rename = core.authorize(.init(
            operation: .adminRename, caller: .agentSession(callerID), scopeID: scope.id,
            targetSessionIDs: ids, arguments: ["name": .string("Batch")]
        ))
        guard case let .authorized(batch) = rename else {
            return XCTFail("Every indexed workspace member should be authorized; got \(String(describing: rename))")
        }
        XCTAssertEqual(Set(batch.admittedSessionIDs), Set(ids))
        XCTAssertTrue(batch.itemsRequiringControl.isEmpty)
        XCTAssertEqual(window.agentModeViewModel.test_persistentBindingResolutionBuildCount, 1)

        let fork = AgentSessionAdministrationRequest(
            operation: .adminFork, caller: .agentSession(callerID), scopeID: scope.id, targetSessionIDs: [targetID]
        )
        window.agentModeViewModel.test_resetPersistentBindingResolutionSnapshotBuildCount()
        guard case .authorized = core.authorize(fork) else { return XCTFail("No live member consumes the available slot yet") }
        XCTAssertEqual(window.agentModeViewModel.test_persistentBindingResolutionBuildCount, 1)
        // Two idle runtime claims are not a proven idle endpoint. Ambiguity must count as live
        // on the very next synchronous authorization, without awaiting a publication or cache reset.
        for _ in 0 ..< 2 {
            let session = AgentModeViewModel.TabSession(tabID: UUID())
            window.agentModeViewModel.test_installLiveSession(session)
            _ = try XCTUnwrap(window.agentModeViewModel.test_installPersistentSessionBinding(sessionID: conflictID, on: session))
        }
        window.agentModeViewModel.test_resetPersistentBindingResolutionSnapshotBuildCount()
        guard case let .denied(denial, _) = core.authorize(fork) else { return XCTFail("Ambiguous live membership must consume the last slot") }
        XCTAssertEqual(denial, DomainDelegationScopeDenial.guardrailExceeded(guardrail: .maxLiveSessions, limit: 1, current: 1))
        XCTAssertEqual(window.agentModeViewModel.test_persistentBindingResolutionBuildCount, 1)
    }

    private func installIndex(_ ids: [UUID], workspace: WorkspaceModel, on viewModel: AgentModeViewModel) {
        let entries = ids.map { id in
            AgentSessionIndexEntry(
                id: id, tabID: UUID(), name: "Indexed", savedAt: Date(timeIntervalSince1970: 0),
                itemCount: 0, autoEditEnabled: false, hasUnknownConversationContent: false,
                isMCPOriginated: false, worktreeBindingSummaries: [], activeWorktreeMergeSummaries: []
            )
        }
        let owner = AgentModeViewModel.SessionIndexOwner(workspaceID: workspace.id, activationEpoch: 1)
        viewModel.test_installSessionIndexSnapshot(
            Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) }),
            owner: owner, latestOwner: owner, activeWorkspace: workspace
        )
    }

    private func grant(_ kind: DomainDelegationScopeKind, grantee: UUID) -> DomainDelegationScopeGrant {
        .init(
            id: UUID(),
            granteeSessionID: grantee,
            kind: kind,
            capabilities: [.observe, .organize],
            guardrails: .init(),
            origin: .user,
            grantedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func row(_ id: UUID, workspace: UUID, parent: UUID? = nil, live: Bool = true, worktrees: Set<String> = []) -> DelegationSessionProvenance {
        .init(
            sessionID: id,
            workspaceID: workspace,
            parentSessionID: parent,
            createdByOverseerSessionID: nil,
            isLive: live,
            worktreeCount: worktrees.count,
            boundWorktreeIDs: worktrees,
            runState: live ? .idle : .unknown
        )
    }

    @MainActor
    private final class CountingSource: DelegationProvenanceSource {
        var rows: [DelegationSessionProvenance]
        var censusReads = 0
        var individualReads = 0
        init(_ rows: [DelegationSessionProvenance]) {
            self.rows = rows
        }

        func provenance(for sessionID: UUID) -> DelegationSessionProvenance? {
            individualReads += 1
            return rows.first { $0.sessionID == sessionID }
        }

        func allKnownSessions() -> [DelegationSessionProvenance] {
            censusReads += 1
            return rows
        }

        func resetCounts() {
            censusReads = 0
            individualReads = 0
        }
    }
}
