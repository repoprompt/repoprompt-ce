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

    func testGlobalOverseerAutoApproveLetsAnAgentRunEveryTargetOperationOnAnySession() throws {
        let previous = OverseerGlobalAutoApprove.isEnabled
        defer { OverseerGlobalAutoApprove.isEnabled = previous }
        let unrelated = DomainAgentSessionTargetProvenance.known(targetSessionID: UUID(), parentSessionID: nil)
        let caller = DomainAgentSessionCallerIdentity.agentSession(callerSessionID)
        let operations: [DomainAgentSessionTargetOperation] = [.runSteer, .runCancel, .runRespond, .manageStop, .manageCleanup]

        OverseerGlobalAutoApprove.isEnabled = { false }
        for operation in operations {
            XCTAssertThrowsError(
                try AgentSessionTargetOperationGuard.require(operation: operation, caller: caller, provenance: unrelated, reference: "x"),
                "\(operation.rawValue): off keeps the direct-child and human-only rules"
            )
        }

        OverseerGlobalAutoApprove.isEnabled = { true }
        for operation in operations {
            XCTAssertNoThrow(
                try AgentSessionTargetOperationGuard.require(operation: operation, caller: caller, provenance: unrelated, reference: "x"),
                "\(operation.rawValue): global on removes the barrier, including session deletion"
            )
        }
        XCTAssertThrowsError(
            try AgentSessionTargetOperationGuard.require(
                operation: .runSteer, caller: .unresolvedAgentRun, provenance: unrelated, reference: "x"
            ),
            "unresolved routing is not a caller and still fails closed"
        )
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

        await assertHumanOnlyCleanupDenial {
            try await service.execute(args: [
                "op": .string("cleanup_sessions"),
                "session_ids": .array([.string(child.uuidString), .string(sibling.uuidString)])
            ])
        }
        XCTAssertTrue(
            deleted.sessionIDs.isEmpty,
            "Agent Mode must not delete any saved conversation"
        )

        await assertHumanOnlyCleanupDenial {
            try await service.execute(args: [
                "op": .string("cleanup_sessions"),
                "session_ids": .array([.string(child.uuidString)])
            ])
        }
        XCTAssertTrue(deleted.sessionIDs.isEmpty, "Direct spawn provenance does not authorize deletion")
    }

    func testLoadingLiveCarrierCannotErasePersistedSpawnParentFromChildCount() async throws {
        let window = try await makeWindow(waitForInitialization: true)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let child = UUID()
        try await persistSession(id: child, workspace: workspace, parentSessionID: callerSessionID)
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)
        let loading = window.agentModeViewModel.session(for: tabID)
        _ = try XCTUnwrap(window.agentModeViewModel.test_installPersistentSessionBinding(sessionID: child, on: loading, updateWorkspaceMetadata: true))
        loading.hasLoadedPersistedState = false
        XCTAssertNil(loading.parentSessionID)
        let service = makeManageService(window: window, callerSessionID: callerSessionID)
        let reply = try await service.execute(args: ["op": .string("list_sessions")])
        XCTAssertEqual(reply.objectValue?["matching_child_count"], .int(1))
        let ids = try await sessionIDs(in: service.execute(args: ["op": .string("list_sessions")]))
        XCTAssertEqual(ids, [child.uuidString])
        loading.hasLoadedPersistedState = true
        loading.parentSessionID = nil
        let loadedReply = try await service.execute(args: ["op": .string("list_sessions")])
        XCTAssertEqual(loadedReply.objectValue?["matching_child_count"], .int(0), "A hydrated carrier's nil remains authoritative; stale metadata grants no child access")
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
        XCTAssertTrue(note.contains("become_overseer"))
        XCTAssertTrue(note.contains("user approves the scope card"))
        XCTAssertEqual(reply.objectValue?["workspace_id"], try .string(XCTUnwrap(window.workspaceManager.activeWorkspace).id.uuidString))
        XCTAssertEqual(reply.objectValue?["matching_child_count"], .int(0))
        let rendered = ToolOutputFormatter.formatAgentManage(args: ["op": .string("list_sessions")], value: reply)
        guard case let .text(text, _, _) = rendered.first else { return XCTFail("expected rendered text") }
        XCTAssertTrue(text.contains("spawned_by_caller"))
        XCTAssertTrue(text.contains("Matching child sessions: **0**"))
        XCTAssertFalse(text.contains("- Sessions: **0**"))
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
        XCTAssertNil(unresolved.objectValue?["workspace_id"])
        XCTAssertNil(unresolved.objectValue?["matching_child_count"])
    }

    func testListSessionsNoteResamplesFullAccess() async throws {
        let original = OverseerGlobalAutoApprove.isEnabled
        defer { OverseerGlobalAutoApprove.isEnabled = original }
        var fullAccess = false
        OverseerGlobalAutoApprove.isEnabled = { fullAccess }
        let window = try await makeWindow(waitForInitialization: true)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let service = makeManageService(window: window, callerSessionID: callerSessionID)
        for enabled in [false, true, false] {
            fullAccess = enabled
            let reply = try await service.execute(args: ["op": .string("list_sessions")])
            let note = try XCTUnwrap(reply.objectValue?["note"]?.stringValue)
            XCTAssertTrue(note.contains("not a workspace inventory"))
            if enabled {
                XCTAssertTrue(note.contains("Overseer full access: ON"))
                XCTAssertTrue(note.contains("session_admin inventory"))
                XCTAssertFalse(note.contains("request_scope"))
                XCTAssertFalse(note.contains("scope card"))
            } else {
                XCTAssertTrue(note.contains("when no current grant covers"))
                XCTAssertTrue(note.contains("standing consent"))
                XCTAssertTrue(note.contains("session_admin request_scope"))
            }
        }
    }

    func testListSessionsRejectsWorkspaceChangeAfterMetadataRead() async throws {
        let window = try await makeWindow(waitForInitialization: true)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let child = UUID()
        try await persistSession(id: child, workspace: workspace, parentSessionID: callerSessionID)
        var service = makeManageService(window: window, callerSessionID: callerSessionID)
        service.testAfterListMetadata = {
            let replacement = window.workspaceManager.createWorkspace(
                name: "Discovery switched", repoPaths: [], ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(to: replacement, saveState: false, reason: "discovery-race-test")
        }
        do {
            _ = try await service.execute(args: ["op": .string("list_sessions")])
            XCTFail("a stale workspace read must not disclose rows or a workspace UUID")
        } catch let MCPError.invalidParams(message) {
            XCTAssertTrue(message?.contains("context changed") == true)
        } catch { XCTFail("unexpected error: \(error)") }
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

    func testCleanupFullAccessDeletesNonMCPOriginsAndReportsMixedDiagnostics() async throws {
        let previous = OverseerGlobalAutoApprove.isEnabled
        OverseerGlobalAutoApprove.isEnabled = { true }
        defer { OverseerGlobalAutoApprove.isEnabled = previous }
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let lane = UUID(), fork = UUID(), absent = UUID(), active = UUID(), broken = UUID()
        let deleted = DeletionRecorder()
        let service = cleanupService(window: window, deleted: deleted, metadata: { id in
            if id == absent { return nil }
            if id == broken { throw CocoaError(.fileReadCorruptFile) }
            return self.makeMeta(
                id: id,
                parentSessionID: nil,
                isMCPOriginated: false,
                lastRunState: id == active ? .running : .completed
            )
        })
        let value = try await service.execute(args: cleanupArgs([lane, fork, absent, active, broken]))
        let result = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(Set(deleted.sessionIDs), Set([lane, fork]))
        XCTAssertEqual(result["result"], .string("partial"))
        let skipped = try XCTUnwrap(result["skipped_sessions"]?.arrayValue)
        XCTAssertEqual(skipped.count, 3)
        for item in skipped {
            assertCleanupDiagnostic(item)
        }
        let text = ToolOutputFormatter.formatAgentManage(args: cleanupArgs([]), value: value).compactMap { content -> String? in
            if case let .text(text, _, _) = content { return text }
            return nil
        }.joined(separator: "\n")
        XCTAssertTrue(text.contains(active.uuidString))
        XCTAssertTrue(text.contains("skipped_active"))
        XCTAssertTrue(text.contains("Next"))
        // Successful deletions are listed by ID too, not only counted.
        XCTAssertTrue(text.contains(lane.uuidString) && text.contains(fork.uuidString), text)
        XCTAssertTrue(text.contains("deleted"))
        for id in [absent, active, broken] {
            XCTAssertTrue(text.contains(id.uuidString), "skipped \(id) must be listed")
        }
    }

    func testCleanupRechecksModeAndCallerAfterResolutionBeforeDeletion() async throws {
        let previous = OverseerGlobalAutoApprove.isEnabled
        defer { OverseerGlobalAutoApprove.isEnabled = previous }
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        for changeCaller in [false, true] {
            var enabled = true
            var caller = callerSessionID
            OverseerGlobalAutoApprove.isEnabled = { enabled }
            let target = UUID(), deleted = DeletionRecorder()
            let service = cleanupService(window: window, deleted: deleted, caller: { caller }, metadata: { id in
                self.makeMeta(id: id, parentSessionID: nil, isMCPOriginated: false)
            }, load: {
                if changeCaller { caller = UUID() } else { enabled = false }
            })
            let result = try await service.execute(args: cleanupArgs([target]))
            XCTAssertTrue(deleted.sessionIDs.isEmpty)
            XCTAssertEqual(result.objectValue?["result"], .string("not_applied"))
            for item in result.objectValue?["skipped_sessions"]?.arrayValue ?? [] {
                assertCleanupDiagnostic(item)
            }
        }
    }

    func testCleanupCommitFenceRevalidatesCallerAndModeWhileDeletionIsParked() async throws {
        let previous = OverseerGlobalAutoApprove.isEnabled
        defer { OverseerGlobalAutoApprove.isEnabled = previous }
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        for change in ["none", "mode_off", "caller_changed"] {
            var enabled = true
            var caller = callerSessionID
            OverseerGlobalAutoApprove.isEnabled = { enabled }
            let target = UUID(), deleted = DeletionRecorder()
            let service = cleanupService(window: window, deleted: deleted, caller: { caller }, metadata: { id in
                self.makeMeta(id: id, parentSessionID: nil, isMCPOriginated: false)
            }, atStorageCommit: {
                switch change {
                case "mode_off": enabled = false
                case "caller_changed": caller = UUID()
                default: break
                }
            })
            let result = try await service.execute(args: cleanupArgs([target]))
            if change == "none" {
                XCTAssertEqual(deleted.sessionIDs, [target], "unchanged authority deletes")
            } else {
                XCTAssertTrue(deleted.sessionIDs.isEmpty, "\(change): authority that ended at commit deletes nothing")
                let skipped = result.objectValue?["skipped_sessions"]?.arrayValue ?? []
                XCTAssertEqual(skipped.first?.objectValue?["reason"], .string("authority_changed_before_commit"), change)
            }
        }
    }

    func testCleanupOffRefusesExplicitlyAndCancellationHasActionableItems() async throws {
        let previous = OverseerGlobalAutoApprove.isEnabled
        defer { OverseerGlobalAutoApprove.isEnabled = previous }
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        OverseerGlobalAutoApprove.isEnabled = { false }
        let target = UUID(), deleted = DeletionRecorder()
        let service = cleanupService(window: window, deleted: deleted, metadata: { self.makeMeta(id: $0, parentSessionID: nil) })
        let denied = try await service.execute(args: cleanupArgs([target]))
        XCTAssertEqual(denied.objectValue?["code"], .string("human_only_operation"))
        XCTAssertEqual(denied.objectValue?["retryable"], .bool(false))
        XCTAssertTrue(deleted.sessionIDs.isEmpty)
        OverseerGlobalAutoApprove.isEnabled = { true }
        let cancelled = cleanupService(window: window, deleted: deleted, metadata: { self.makeMeta(id: $0, parentSessionID: nil) }, cancellation: { throw CancellationError() })
        let result = try await cancelled.execute(args: cleanupArgs([target, UUID()]))
        XCTAssertEqual(result.objectValue?["result"], .string("not_applied"))
        let items = try XCTUnwrap(result.objectValue?["unprocessed_sessions"]?.arrayValue)
        XCTAssertEqual(items.count, 2)
        for item in items {
            assertCleanupDiagnostic(item)
        }
        let text = ToolOutputFormatter.formatAgentManage(args: cleanupArgs([]), value: result).compactMap { content -> String? in
            if case let .text(text, _, _) = content { return text }
            return nil
        }.joined(separator: "\n")
        XCTAssertTrue(text.contains(target.uuidString))
        XCTAssertTrue(text.contains("cancelled_before_processing"))
    }

    func testCleanupAllFailedAbsentAndPostDurableFailureReceipts() async throws {
        let previous = OverseerGlobalAutoApprove.isEnabled
        OverseerGlobalAutoApprove.isEnabled = { true }
        defer { OverseerGlobalAutoApprove.isEnabled = previous }
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let target = UUID(), deleted = DeletionRecorder()
        let failed = cleanupService(window: window, deleted: deleted, metadata: { _ in throw CocoaError(.fileReadCorruptFile) })
        let failure = try await failed.execute(args: cleanupArgs([target]))
        XCTAssertEqual(failure.objectValue?["result"], .string("not_applied"))
        XCTAssertEqual(failure.objectValue?["retry_session_ids"], .array([]))
        for item in failure.objectValue?["skipped_sessions"]?.arrayValue ?? [] {
            assertCleanupDiagnostic(item)
        }
        let absent = cleanupService(window: window, deleted: deleted, metadata: { _ in nil })
        let absentResult = try await absent.execute(args: cleanupArgs([target]))
        XCTAssertEqual(absentResult.objectValue?["result"], .string("not_applied"))
        XCTAssertEqual(absentResult.objectValue?["status"], .string("completed"))
        let postCommit = cleanupService(window: window, deleted: deleted, metadata: {
            self.makeMeta(id: $0, parentSessionID: nil)
        }, cancellation: {
            if !deleted.sessionIDs.isEmpty { throw CocoaError(.fileWriteUnknown) }
        })
        let committed = try await postCommit.execute(args: cleanupArgs([target]))
        XCTAssertEqual(committed.objectValue?["result"], .string("partial"))
        XCTAssertEqual(committed.objectValue?["deleted_count"], .int(1))
        XCTAssertEqual(committed.objectValue?["retry_session_ids"], .array([]))
        let receipt = try XCTUnwrap(committed.objectValue?["deleted_sessions"]?.arrayValue?.first)
        XCTAssertEqual(receipt.objectValue?["durable"], .bool(true))
        XCTAssertEqual(receipt.objectValue?["retryable"], .bool(false))
        assertCleanupDiagnostic(receipt)
    }

    func testCleanupFinalFenceRejectsNewActivityAndReboundTab() async throws {
        let previous = OverseerGlobalAutoApprove.isEnabled
        OverseerGlobalAutoApprove.isEnabled = { true }
        defer { OverseerGlobalAutoApprove.isEnabled = previous }
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let tab = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let vm = window.agentModeViewModel
        let session = vm.session(for: tab)
        session.hasLoadedPersistedState = true
        for rebind in [false, true] {
            let target = UUID(), deleted = DeletionRecorder()
            session.runState = .idle
            _ = try XCTUnwrap(vm.test_installPersistentSessionBinding(sessionID: target, on: session, updateWorkspaceMetadata: true))
            session.recordRestorationAuthoritative(.persistedPayloadApplied)
            var callerReads = 0
            let service = cleanupService(window: window, deleted: deleted, caller: {
                callerReads += 1
                if callerReads == 4 {
                    if rebind {
                        _ = vm.test_installPersistentSessionBinding(sessionID: self.callerSessionID, on: session, updateWorkspaceMetadata: true)
                    } else { session.runState = .running }
                }
                return self.callerSessionID
            }, metadata: { _ in nil })
            let result = try await service.execute(args: cleanupArgs([target]))
            XCTAssertTrue(deleted.sessionIDs.isEmpty)
            XCTAssertEqual(result.objectValue?["result"], .string("not_applied"))
            let receipt = try XCTUnwrap(result.objectValue?["skipped_sessions"]?.arrayValue?.first)
            XCTAssertEqual(receipt.objectValue?["code"], .string(rebind ? "target_binding_changed" : "skipped_active"))
        }
        session.runState = .idle
    }

    func testCleanupSelfTargetDoesNotMislabelOtherBatchItemsAndRequiresRoutedConnection() async throws {
        let previous = OverseerGlobalAutoApprove.isEnabled
        OverseerGlobalAutoApprove.isEnabled = { true }
        defer { OverseerGlobalAutoApprove.isEnabled = previous }
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let other = UUID(), deleted = DeletionRecorder()
        let service = cleanupService(window: window, deleted: deleted, metadata: { _ in nil })
        let result = try await service.execute(args: cleanupArgs([other, callerSessionID]))
        let items = try XCTUnwrap(result.objectValue?["skipped_sessions"]?.arrayValue)
        XCTAssertEqual(items[0].objectValue?["code"], .string("batch_preflight_not_applied"))
        XCTAssertEqual(items[1].objectValue?["code"], .string("self_target"))
        let unidentified = cleanupService(window: window, deleted: deleted, connectionID: nil, metadata: { _ in nil })
        let refused = try await unidentified.execute(args: cleanupArgs([other]))
        XCTAssertEqual(refused.objectValue?["code"], .string("caller_routing_unresolved"))
        XCTAssertTrue(deleted.sessionIDs.isEmpty)
    }

    private func assertHumanOnlyCleanupDenial(_ operation: () async throws -> Value) async {
        do {
            let result = try await operation()
            XCTAssertEqual(result.objectValue?["result"], .string("not_applied"))
            XCTAssertEqual(result.objectValue?["code"], .string("human_only_operation"))
        } catch { XCTFail("Expected an actionable human-only receipt, got \(error)") }
    }

    private func cleanupArgs(_ ids: [UUID]) -> [String: Value] {
        ["op": .string("cleanup_sessions"), "session_ids": .array(ids.map { .string($0.uuidString) })]
    }

    private func assertCleanupDiagnostic(_ value: Value, file: StaticString = #filePath, line: UInt = #line) {
        for key in ["session_id", "code", "subreason", "detail", "next_step", "retryable"] {
            XCTAssertNotNil(value.objectValue?[key], key, file: file, line: line)
        }
    }

    private func cleanupService(
        window: WindowState, deleted: DeletionRecorder,
        caller: (() -> UUID)? = nil,
        connectionID: UUID? = UUID(),
        metadata: @escaping (UUID) throws -> AgentSessionMeta?,
        load: @escaping () -> Void = {},
        cancellation: @escaping () throws -> Void = {},
        atStorageCommit: @escaping @MainActor () -> Void = {}
    ) -> AgentManageMCPToolService {
        AgentManageMCPToolService(
            toolName: MCPWindowToolName.agentManage,
            captureRequestMetadata: { .init(connectionID: connectionID, clientName: "cleanup-regression", windowID: window.windowID, runPurpose: .agentModeRun) },
            requireTargetWindow: { window }, resolveSpawnSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in caller?() ?? self.callerSessionID },
            bindCurrentRequestToTab: { _, _ in },
            cleanupDependencies: .init(
                loadPersistedMetadata: { id, _ in try metadata(id) },
                loadPersistedSession: { _, _ in load()
                    return nil
                },
                deleteOpenSession: { vm, tab, _ in
                    if let id = vm.sessions[tab]?.activeAgentSessionID { deleted.sessionIDs.append(id) }
                    return nil
                },
                deletePersistedSession: { id, _ in
                    // Mirror AgentSessionDataService: authority can change while deletion is parked,
                    // and the caller-supplied fence is evaluated at the commit point.
                    atStorageCommit()
                    if let fence = AgentSessionDataService.destructiveCommitFence.get(), await !fence() {
                        throw AgentSessionDestructiveCommitRefused()
                    }
                    deleted.sessionIDs.append(id)
                },
                finalizePersistedReferences: { _, _, _ in 0 }, checkCancellation: cancellation
            )
        )
    }

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

    private func makeMeta(
        id: UUID, parentSessionID: UUID?, isMCPOriginated: Bool = true,
        lastRunState: AgentSessionRunState = .completed
    ) -> AgentSessionMeta {
        AgentSessionMeta(
            id: id,
            composeTabID: nil,
            name: "Session \(id.uuidString.prefix(8))",
            lastModified: Date(timeIntervalSinceReferenceDate: 1),
            itemCount: 0,
            agentKind: AgentProviderKind.codexExec.rawValue,
            agentModel: "codex",
            lastRunState: lastRunState.rawValue,
            acpModelParameterSelections: [],
            parentSessionID: parentSessionID,
            createdByOverseerSessionID: nil,
            isMCPOriginated: isMCPOriginated,
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

    func testPointAuthorizationReadsOnlyTargetsAndRechecksOwnershipOnEachCall() throws {
        let caller = UUID(), target = UUID(), workspace = UUID(), otherWorkspace = UUID()
        let source = CountingSource([row(target, workspace: workspace, live: true)])
        let projector = SpawnProvenanceDelegationMembershipProjector(source: source)
        let scopes = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
        let pending = try scopes.requestScope(
            requesterSessionID: caller, requesterTabID: nil, kind: .workspace(workspaceID: workspace),
            capabilities: [.observe, .organize], guardrails: .init(), reason: nil, idempotencyKey: nil
        ).get()
        let scope = try scopes.approve(requestID: pending.id).get()
        let core = AgentSessionAdministrationCore(scopes: scopes, projector: projector)
        let request = AgentSessionAdministrationRequest(
            operation: .adminRename, caller: .agentSession(caller), scopeID: scope.id,
            targetSessionIDs: [target], arguments: ["name": .string("Renamed")]
        )
        for unrelatedCount in [0, 1500] {
            source.rows = [row(target, workspace: workspace, live: true)]
                + (0 ..< unrelatedCount).map { _ in row(UUID(), workspace: otherWorkspace) }
            source.resetCounts()
            guard case let .authorized(batch) = core.authorize(request) else {
                return XCTFail("The explicit workspace member should be authorized")
            }
            XCTAssertEqual(batch.admittedSessionIDs, [target])
            XCTAssertEqual(source.censusReads, 0)
            XCTAssertEqual(source.individualReads, 1)
        }
        source.rows = [row(target, workspace: otherWorkspace, live: true)]
        source.resetCounts()
        guard case .denied = core.authorize(request) else {
            return XCTFail("Fresh ownership must refuse a target moved outside the scope")
        }
        XCTAssertEqual(source.censusReads, 0)
        XCTAssertEqual(source.individualReads, 1)
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
            let members = projector.members(of: scope)
            XCTAssertEqual(Set(members), Set(individual))
            XCTAssertEqual(members.count, individual.count, "Census membership must not duplicate a session")
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

    func testProductionCensusRetainsConservativeAccountingWithoutGrantingAmbiguousAuthority() async throws {
        let first = WindowState(), second = WindowState()
        addTeardownBlock { @MainActor in
            await first.tearDown()
            await second.tearDown()
        }
        await first.workspaceManager.awaitInitialized()
        await second.workspaceManager.awaitInitialized()
        let ownerWorkspace = WorkspaceModel(name: "Index owner", repoPaths: [], ephemeralFlag: true)
        let ambiguousID = UUID(), runningID = UUID(), idleID = UUID(), absentID = UUID(), replicaID = UUID()
        let ids = [ambiguousID, runningID, idleID, absentID, replicaID] + (0 ..< 1500).map { _ in UUID() }
        installIndex(ids, workspace: ownerWorkspace, on: first)
        second.agentModeViewModel.test_setAgentSessionSaver { _, _, _ in
            FileManager.default.temporaryDirectory.appendingPathComponent("point-index-\(UUID()).json")
        }
        second.workspaceManager.workspaces = [ownerWorkspace]
        second.workspaceManager.activeWorkspace = ownerWorkspace
        second.promptManager.loadComposeTabsFromWorkspace(ownerWorkspace)
        let owner = AgentModeViewModel.SessionIndexOwner(workspaceID: ownerWorkspace.id, activationEpoch: 1)
        second.agentModeViewModel.test_installSessionIndexSnapshot(
            first.agentModeViewModel.sessionIndex.filter { [ambiguousID, runningID, replicaID].contains($0.key) },
            owner: owner, latestOwner: owner, activeWorkspace: ownerWorkspace
        )
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
        XCTAssertNil(source.provenance(for: ambiguousID), "A resource claim is not an authority proof")
        XCTAssertNil(source.provenance(for: runningID), "Running must not make conflicting identities actionable")
        XCTAssertEqual(source.provenance(for: replicaID)?.workspaceID, ownerWorkspace.id)
        first.agentModeViewModel.test_resetPersistentBindingResolutionSnapshotBuildCount()
        second.agentModeViewModel.test_resetPersistentBindingResolutionSnapshotBuildCount()
        let census = source.allKnownSessions()
        let accounting = Dictionary(uniqueKeysWithValues: census.map { ($0.sessionID, $0) })
        XCTAssertEqual(census.count, ids.count, "Agreeing metadata replicas count once without losing conflicted resources")
        XCTAssertEqual(accounting[ambiguousID]?.workspaceID, ownerWorkspace.id)
        XCTAssertEqual(accounting[ambiguousID]?.runState, .unknown)
        XCTAssertEqual(accounting[ambiguousID]?.isLive, true)
        XCTAssertEqual(accounting[runningID]?.runState, .running, "Running beats ambiguity for conservative accounting")
        XCTAssertEqual(accounting[idleID]?.runState, .idle)
        XCTAssertEqual(accounting[idleID]?.isLive, true)
        XCTAssertEqual(accounting[absentID]?.isLive, false)
        XCTAssertEqual(first.agentModeViewModel.test_persistentBindingResolutionBuildCount, 1)
        XCTAssertEqual(second.agentModeViewModel.test_persistentBindingResolutionBuildCount, 1)

        var projector = SpawnProvenanceDelegationMembershipProjector(source: source)
        projector.ownedUnreleasedWorktreeIDs = { members in
            XCTAssertTrue(members.isSuperset(of: [ambiguousID, runningID]))
            return ["owned-by-ambiguous-session"]
        }
        let accountingScope = grant(.workspace(workspaceID: ownerWorkspace.id), grantee: UUID())
        let usage = projector.usage(of: accountingScope, spawnParentSessionID: nil)
        XCTAssertEqual(usage.liveSessionCount, 3, "Ambiguous runtime claims must not release occupied capacity")
        XCTAssertEqual(usage.worktreeCount, 1)
        let evidence = try XCTUnwrap(projector.usageEvidence(of: accountingScope, spawnParentSessionID: nil))
        XCTAssertEqual(evidence.liveSessionCount, usage.liveSessionCount)
        XCTAssertEqual(evidence.worktreeCount, usage.worktreeCount)

        // A displaced index must contribute nothing, even if it still physically holds rows.
        first.agentModeViewModel.test_installSessionIndexSnapshot(
            first.agentModeViewModel.sessionIndex, owner: owner,
            latestOwner: .init(workspaceID: UUID(), activationEpoch: 2), activeWorkspace: ownerWorkspace
        )
        XCTAssertEqual(Set(source.allKnownSessions().map(\.sessionID)), [ambiguousID, runningID, replicaID])
        XCTAssertNil(source.provenance(for: ambiguousID), "Displacing one metadata owner does not erase its raw runtime claims")
        XCTAssertEqual(source.provenance(for: replicaID)?.workspaceID, ownerWorkspace.id)
    }

    func testProductionMembershipReadsPlacementWithoutBuildingLivenessAndRemainsFresh() async throws {
        let window = WindowState()
        addTeardownBlock { @MainActor in await window.tearDown() }
        await window.workspaceManager.awaitInitialized()
        let workspace = WorkspaceModel(name: "Placement only", repoPaths: [], ephemeralFlag: true)
        let root = UUID(), middle = UUID(), child = UUID()
        installIndex([root, middle, child], workspace: workspace, on: window)
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
        let workspace = WorkspaceModel(name: "Authorization census", repoPaths: [], ephemeralFlag: true)
        let callerID = UUID(), targetID = UUID(), conflictID = UUID()
        let ids = [callerID, targetID, conflictID] + (0 ..< 253).map { _ in UUID() }
        installIndex(ids, workspace: workspace, on: window)
        let source = OpenWindowsDelegationProvenanceSource(windows: { [window] })
        let projector = SpawnProvenanceDelegationMembershipProjector(source: source)
        let scopes = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
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

    func testExplicitAdministrationRefusesCrossWindowCarrierAndPlacementConflictsInEitherOrder() async throws {
        for conflict in ["archive", "tab", "workspace", "metadata-only", "name", "pin", "ancestry", "scope-stamp"] {
            let target = UUID()
            let tab = ComposeTabState(name: "Original", activeAgentSessionID: target)
            var firstWorkspace = WorkspaceModel(
                name: "Carrier owner", repoPaths: [], ephemeralFlag: true,
                composeTabs: [tab], activeComposeTabID: tab.id
            )
            var secondWorkspace = firstWorkspace
            let firstEntry = carrierEntry(target, tabID: tab.id)
            var secondEntry = firstEntry
            switch conflict {
            case "archive":
                firstWorkspace.composeTabs = []
                firstWorkspace.activeComposeTabID = nil
                firstWorkspace.stashedTabs = [StashedTab(tab: tab)]
            case "tab":
                let otherTab = ComposeTabState(name: "Original", activeAgentSessionID: target)
                secondWorkspace.composeTabs = [otherTab]
                secondWorkspace.activeComposeTabID = otherTab.id
                secondEntry = carrierEntry(target, tabID: otherTab.id)
            case "workspace", "metadata-only":
                secondWorkspace = WorkspaceModel(
                    name: "Other owner", repoPaths: [], ephemeralFlag: true,
                    composeTabs: [tab], activeComposeTabID: tab.id
                )
                if conflict == "metadata-only" {
                    firstWorkspace.composeTabs = []
                    firstWorkspace.activeComposeTabID = nil
                }
            case "name": secondWorkspace.composeTabs[0].name = "Conflicting title"
            case "pin": secondWorkspace.composeTabs[0].isPinned = true
            case "ancestry": secondEntry.organizationalParentID = UUID()
            case "scope-stamp": secondEntry.delegationScopeID = UUID()
            default: XCTFail("Unhandled fixture")
            }
            let first = await carrierWindow(workspace: firstWorkspace, entries: [firstEntry])
            let second = await carrierWindow(workspace: secondWorkspace, entries: [secondEntry])
            if let firstTab = firstWorkspace.composeTabs.first {
                installIdleCarrier(target, tabID: firstTab.id, on: first)
            }
            let liveTab = try XCTUnwrap(secondWorkspace.composeTabs.first)
            installIdleCarrier(target, tabID: liveTab.id, on: second)
            for windows in [[first, second], [second, first]] {
                try await assertAmbiguousAdministrationRefused(
                    target, workspaceID: firstWorkspace.id, windows: windows, context: conflict
                )
            }
        }
    }

    func testExplicitAdministrationRetainsEverySameWindowPhysicalOccurrence() async throws {
        for conflict in ["two-tabs", "repeated-tab", "active-and-stashed", "two-stashes"] {
            let target = UUID()
            let tab = ComposeTabState(name: "Original", activeAgentSessionID: target)
            var workspace = WorkspaceModel(
                name: "Physical collisions", repoPaths: [], ephemeralFlag: true,
                composeTabs: [tab], activeComposeTabID: tab.id
            )
            switch conflict {
            case "two-tabs": workspace.composeTabs.append(ComposeTabState(name: "Other carrier", activeAgentSessionID: target))
            case "repeated-tab": workspace.composeTabs.append(tab)
            case "active-and-stashed": workspace.stashedTabs = [StashedTab(tab: tab)]
            case "two-stashes":
                workspace.composeTabs = []
                workspace.activeComposeTabID = nil
                workspace.stashedTabs = [StashedTab(tab: tab), StashedTab(tab: tab)]
            default: XCTFail("Unhandled fixture")
            }
            let window = await carrierWindow(workspace: workspace, entries: [carrierEntry(target, tabID: tab.id)])
            XCTAssertEqual(window.workspaceManager.activeWorkspace, workspace)
            XCTAssertEqual(window.workspaceManager.sessionCarriers(sessionIDs: [target]).count, 2, conflict)
            if !workspace.composeTabs.isEmpty { installIdleCarrier(target, tabID: tab.id, on: window) }
            try await assertAmbiguousAdministrationRefused(target, workspaceID: workspace.id, windows: [window], context: conflict)
        }
    }

    func testCoherentCanonicalReplicasRemainReadableButRefuseWritesAndPreserveAncestry() async throws {
        let root = UUID(), middle = UUID(), target = UUID()
        let tab = ComposeTabState(name: "Original", activeAgentSessionID: target)
        let workspace = WorkspaceModel(
            name: "Coherent replicas", repoPaths: [], ephemeralFlag: true,
            composeTabs: [tab], activeComposeTabID: tab.id
        )
        var middleEntry = carrierEntry(middle, tabID: UUID())
        middleEntry.parentSessionID = root
        var targetEntry = carrierEntry(target, tabID: tab.id)
        targetEntry.parentSessionID = middle
        let entries = [carrierEntry(root, tabID: UUID()), middleEntry, targetEntry]
        let first = await carrierWindow(workspace: workspace, entries: entries)
        let second = await carrierWindow(workspace: workspace, entries: entries)
        // The cold replica observes the same physical carrier; runtime absence is not a second identity.
        installIdleCarrier(target, tabID: tab.id, on: second)
        for windows in [[first, second], [second, first]] {
            let source = OpenWindowsDelegationProvenanceSource(windows: { windows })
            let projector = SpawnProvenanceDelegationMembershipProjector(source: source)
            let tree = grant(.tree(rootSessionID: root), grantee: UUID())
            first.agentModeViewModel.test_resetPersistentBindingResolutionSnapshotBuildCount()
            second.agentModeViewModel.test_resetPersistentBindingResolutionSnapshotBuildCount()
            XCTAssertEqual(projector.membershipProof(for: target, in: tree)?.basis, .treePath([target, middle, root]))
            XCTAssertEqual(projector.pointResolutionState(for: root), .indexOnly)
            XCTAssertEqual(projector.pointResolutionState(for: target), .replicated)
            XCTAssertEqual(first.agentModeViewModel.test_persistentBindingResolutionBuildCount, 0)
            XCTAssertEqual(second.agentModeViewModel.test_persistentBindingResolutionBuildCount, 0)
            XCTAssertEqual(source.provenance(for: target)?.workspaceID, workspace.id)
            let organizer = OpenWindowsAgentSessionOrganizer(windows: { windows })
            XCTAssertEqual(organizer.state(of: target)?.tabID, tab.id)
            XCTAssertNil(organizer.state(of: root), "Metadata ancestry does not manufacture a mutation address")
            let fixture = try carrierAdministration(windows: windows, workspaceID: workspace.id)
            guard case let .authorized(batch) = fixture.core.authorize(.init(
                operation: .adminGet, caller: .agentSession(fixture.callerID), scopeID: fixture.scope.id,
                targetSessionIDs: [target]
            )) else { return XCTFail("Coherent replicas must remain readable") }
            XCTAssertEqual(batch.admittedSessionIDs, [target])
        }

        let accountingProjector = SpawnProvenanceDelegationMembershipProjector(source: OpenWindowsDelegationProvenanceSource(windows: { [first, second] }))
        let accountingScope = grant(.tree(rootSessionID: root), grantee: UUID())
        let beforeInactive = try XCTUnwrap(accountingProjector.usageEvidence(of: accountingScope, spawnParentSessionID: nil))
        first.workspaceManager.workspaces.append(WorkspaceModel(
            name: "Unrelated inactive workspace", repoPaths: [], ephemeralFlag: true,
            composeTabs: [ComposeTabState(name: "Unloaded metadata", activeAgentSessionID: UUID())]
        ))
        XCTAssertEqual(
            accountingProjector.usageEvidence(of: accountingScope, spawnParentSessionID: nil), beforeInactive,
            "An unrelated inactive-only carrier must not become missing usage evidence for the active tree"
        )

        // An ancestor conflict must be checked even when a tree walk reaches its root directly.
        var conflictingEntries = second.agentModeViewModel.sessionIndex
        conflictingEntries[root]?.delegationScopeID = UUID()
        installCarrierIndex(conflictingEntries, workspace: workspace, on: second)
        let source = OpenWindowsDelegationProvenanceSource(windows: { [first, second] })
        let projector = SpawnProvenanceDelegationMembershipProjector(source: source)
        XCTAssertNil(projector.membershipProof(for: target, in: grant(.tree(rootSessionID: root), grantee: UUID())))
        XCTAssertTrue(projector.authorityConflictInAncestry(of: target))

        installCarrierIndex(first.agentModeViewModel.sessionIndex, workspace: workspace, on: second)
        installIdleCarrier(target, tabID: tab.id, on: first)
        var undoTokens = 0
        let fixture = try carrierAdministration(windows: [first, second], workspaceID: workspace.id, makeToken: {
            undoTokens += 1
            return "coherent-replica-undo"
        })
        let windows = [first, second]
        let beforeWorkspaces = windows.map(\.workspaceManager.workspaces)
        let beforeIndexes = windows.map(\.agentModeViewModel.sessionIndex)
        let operations: [(DomainAgentSessionTargetOperation, [String: Value])] = [
            (.adminRename, ["name": .string("Must not write one replica")]),
            (.adminSetPin, ["pinned": .bool(true)]),
            (.adminSetGroup, ["group": .string("Must not diverge")]),
            (.adminArchive, [:])
        ]
        for (operation, arguments) in operations {
            guard case let .denied(_, deniedTarget) = try await fixture.core.perform(.init(
                operation: operation, caller: .agentSession(fixture.callerID), scopeID: fixture.scope.id,
                targetSessionIDs: [target], arguments: arguments
            )) else { return XCTFail("Replicated active carriers cannot be mutated atomically yet") }
            XCTAssertEqual(deniedTarget, target)
        }
        let organizer = OpenWindowsAgentSessionOrganizer(windows: { windows })
        XCTAssertTrue(organizer.rename([target: "Rejected replica rename"]).isEmpty)
        XCTAssertTrue(organizer.setPinned(true, sessionIDs: [target]).isEmpty)
        XCTAssertTrue(organizer.setGroup("Rejected replica group", order: 1, sessionIDs: [target]).isEmpty)
        let archived = await organizer.archive([target], isAuthorized: { _ in true })
        XCTAssertTrue(archived.isEmpty)
        XCTAssertEqual(windows.map(\.workspaceManager.workspaces), beforeWorkspaces)
        XCTAssertEqual(windows.map(\.agentModeViewModel.sessionIndex), beforeIndexes)
        XCTAssertEqual(undoTokens, 0)
    }

    func testInactiveWorkspaceCacheDoesNotPoisonActiveMutationReadbackOrUndo() async throws {
        let target = UUID()
        let tab = ComposeTabState(name: "Original", activeAgentSessionID: target)
        let keepAlive = ComposeTabState(name: "Keep active")
        let workspace = WorkspaceModel(
            name: "Active owner", repoPaths: [], ephemeralFlag: true,
            composeTabs: [tab, keepAlive], activeComposeTabID: keepAlive.id
        )
        let otherWorkspace = WorkspaceModel(name: "Other active workspace", repoPaths: [], ephemeralFlag: true)
        let owner = await carrierWindow(workspace: workspace, entries: [carrierEntry(target, tabID: tab.id)])
        let cached = await carrierWindow(workspace: otherWorkspace, entries: [])
        cached.workspaceManager.workspaces.append(workspace)
        let operations: [(DomainAgentSessionTargetOperation, [String: Value])] = [
            (.adminRename, ["name": .string("New title")]),
            (.adminSetPin, ["pinned": .bool(true)]),
            (.adminSetGroup, ["group": .string("New group")]),
            (.adminArchive, [:])
        ]
        for windows in [[owner, cached], [cached, owner]] {
            installIdleCarrier(target, tabID: tab.id, on: owner)
            let source = OpenWindowsDelegationProvenanceSource(windows: { windows })
            let projector = SpawnProvenanceDelegationMembershipProjector(source: source)
            let organizer = OpenWindowsAgentSessionOrganizer(windows: { windows })
            let fixture = try carrierAdministration(windows: windows, workspaceID: workspace.id)
            for (operation, arguments) in operations {
                let before = try XCTUnwrap(organizer.state(of: target))
                guard case let .completed(value) = try await fixture.core.perform(.init(
                    operation: operation, caller: .agentSession(fixture.callerID), scopeID: fixture.scope.id,
                    targetSessionIDs: [target], arguments: arguments
                )) else { return XCTFail("An inactive catalog copy must not block \(operation)") }
                XCTAssertEqual(value.objectValue?["result"]?.stringValue, "applied")
                XCTAssertEqual(value.objectValue?["changed_count"]?.intValue, 1)
                let after = try XCTUnwrap(organizer.state(of: target), "Stale cached placement must not hide the committed result")
                switch operation {
                case .adminRename: XCTAssertEqual(after.name, "New title")
                case .adminSetPin: XCTAssertTrue(after.isPinned)
                case .adminSetGroup: XCTAssertEqual(after.sidebarGroup, "New group")
                case .adminArchive: XCTAssertTrue(after.isArchived)
                default: XCTFail("Unhandled fixture")
                }
                XCTAssertEqual(projector.pointResolutionState(for: target), .unique)
                XCTAssertEqual(source.provenance(for: target)?.workspaceID, workspace.id)
                guard case .authorized = fixture.core.authorize(.init(
                    operation: .adminGet, caller: .agentSession(fixture.callerID), scopeID: fixture.scope.id,
                    targetSessionIDs: [target]
                )) else { return XCTFail("A committed mutation must remain readable") }
                XCTAssertEqual(cached.workspaceManager.workspaces.first { $0.id == workspace.id }, workspace)

                let token = try XCTUnwrap(value.objectValue?["undo_token"]?.stringValue)
                guard case let .redeemed(entry) = fixture.handler.redeemUndo(token: token, granteeSessionID: fixture.callerID) else {
                    return XCTFail("The real handler must issue a usable undo token")
                }
                guard case let .authorized(batch) = fixture.core.authorize(.init(
                    operation: entry.payload.authorizationOperation(original: entry.operation),
                    caller: .agentSession(fixture.callerID), scopeID: entry.scopeID, targetSessionIDs: entry.targetSessionIDs
                )) else { return XCTFail("Undo must reauthorize against the active owner") }
                let undone = try await fixture.handler.performUndo(entry, batch: batch)
                XCTAssertEqual(undone.objectValue?["result"]?.stringValue, "undone")
                XCTAssertEqual(undone.objectValue?["changed_count"]?.intValue, 1)
                let restored = try XCTUnwrap(organizer.state(of: target))
                XCTAssertEqual(restored.name, before.name)
                XCTAssertEqual(restored.isPinned, before.isPinned)
                XCTAssertEqual(restored.sidebarGroup, before.sidebarGroup)
                XCTAssertEqual(restored.isArchived, before.isArchived)
                XCTAssertEqual(projector.pointResolutionState(for: target), .unique)
            }
        }

        // The active owner is authoritative even after it stops carrying this session. An old
        // cached active tab may not resurrect a physical mutation address in another window.
        owner.workspaceManager.workspaces[0].composeTabs.removeAll { $0.id == tab.id }
        let source = OpenWindowsDelegationProvenanceSource(windows: { [cached, owner] })
        let projector = SpawnProvenanceDelegationMembershipProjector(source: source)
        let organizer = OpenWindowsAgentSessionOrganizer(windows: { [cached, owner] })
        XCTAssertEqual(projector.pointResolutionState(for: target), .indexOnly)
        XCTAssertNil(organizer.state(of: target))
        XCTAssertTrue(organizer.rename([target: "Must not revive cached carrier"]).isEmpty)
        XCTAssertEqual(cached.workspaceManager.workspaces.first { $0.id == workspace.id }, workspace)
    }

    func testPointAuthorizationAndOrganizerVisitsStayBoundedWithUnrelatedConflicts() async throws {
        var baselineVisits: [Int]?
        for unrelatedCount in [0, 4000] {
            let target = UUID(), conflicting = UUID()
            let tab = ComposeTabState(name: "Original", activeAgentSessionID: target)
            let unrelated = (0 ..< unrelatedCount).map { index in
                ComposeTabState(name: "Unrelated \(index)", activeAgentSessionID: UUID())
            }
            let duplicate = ComposeTabState(name: "Unrelated conflict", activeAgentSessionID: conflicting)
            let competing = ComposeTabState(name: "Other unrelated carrier", activeAgentSessionID: conflicting)
            let workspace = WorkspaceModel(
                name: "Bounded point proof", repoPaths: [], ephemeralFlag: true,
                composeTabs: [tab, duplicate, competing] + unrelated, activeComposeTabID: tab.id
            )
            let entries = [carrierEntry(target, tabID: tab.id), carrierEntry(conflicting, tabID: duplicate.id)]
                + unrelated.map { carrierEntry($0.activeAgentSessionID!, tabID: $0.id) }
            let window = await carrierWindow(workspace: workspace, entries: entries)
            installIdleCarrier(target, tabID: tab.id, on: window)
            XCTAssertEqual(window.workspaceManager.sessionCarriers(sessionIDs: [conflicting]).count, 2)
            XCTAssertEqual(
                SpawnProvenanceDelegationMembershipProjector(source: OpenWindowsDelegationProvenanceSource(windows: { [window] }))
                    .pointResolutionState(for: conflicting),
                .ambiguous
            )
            let fixture = try carrierAdministration(windows: [window], workspaceID: workspace.id)
            let manager = window.workspaceManager
            let viewModel = window.agentModeViewModel
            manager.test_sessionCarrierRowsVisited = 0
            viewModel.sessionIndexStore.test_metadataRowsVisited = 0
            viewModel.test_persistentBindingClaimRowsVisited = 0
            let request = AgentSessionAdministrationRequest(
                operation: .adminRename, caller: .agentSession(fixture.callerID), scopeID: fixture.scope.id,
                targetSessionIDs: [target], arguments: ["name": .string("Renamed")]
            )
            guard case let .authorized(batch) = fixture.core.authorize(request) else {
                return XCTFail("An unrelated conflicting identity must not poison a valid point proof")
            }
            XCTAssertEqual(batch.admittedSessionIDs, [target])
            let organizer = OpenWindowsAgentSessionOrganizer(windows: { [window] })
            XCTAssertEqual(organizer.state(of: target)?.tabID, tab.id)
            let visits = [
                manager.test_sessionCarrierRowsVisited,
                viewModel.test_persistentBindingClaimRowsVisited,
                viewModel.sessionIndexStore.test_metadataRowsVisited
            ]
            XCTAssertGreaterThan(visits[0], 0, "The test must exercise real indexed carrier reads")
            XCTAssertGreaterThan(visits[1], 0, "The test must exercise real indexed binding reads")
            if let baselineVisits { XCTAssertEqual(visits, baselineVisits) }
            else { baselineVisits = visits }
            XCTAssertEqual(organizer.rename([target: "Renamed"]), [target])
            XCTAssertEqual(manager.workspaces[0].composeTabs.first?.name, "Renamed")
            XCTAssertEqual(Array(manager.workspaces[0].composeTabs.dropFirst()), Array(workspace.composeTabs.dropFirst()))
        }
    }

    func testArchiveRechecksWritableCarrierAfterPreflightActivatesAReplica() async throws {
        let target = UUID()
        let tab = ComposeTabState(name: "Original", activeAgentSessionID: target)
        let keepAlive = ComposeTabState(name: "Keep active")
        let workspace = WorkspaceModel(
            name: "Archive owner", repoPaths: [], ephemeralFlag: true,
            composeTabs: [tab, keepAlive], activeComposeTabID: keepAlive.id
        )
        let otherWorkspace = WorkspaceModel(name: "Peer before activation", repoPaths: [], ephemeralFlag: true)
        let entry = carrierEntry(target, tabID: tab.id)
        let owner = await carrierWindow(workspace: workspace, entries: [entry])
        let peer = await carrierWindow(workspace: otherWorkspace, entries: [])
        let ownerChatID = await owner.oracleViewModel.ensureActiveSessionForCurrentTab(createIfMissing: true)
        XCTAssertNotNil(ownerChatID)
        let settledOwnerWorkspace = try XCTUnwrap(owner.workspaceManager.activeWorkspace)
        XCTAssertEqual(settledOwnerWorkspace.composeTabs.first { $0.id == keepAlive.id }?.activeChatSessionID, ownerChatID)
        peer.workspaceManager.workspaces.append(settledOwnerWorkspace)
        installIdleCarrier(target, tabID: tab.id, on: owner)
        let windows = [owner, peer]
        let projector = SpawnProvenanceDelegationMembershipProjector(source: OpenWindowsDelegationProvenanceSource(windows: { windows }))
        let fixture = try carrierAdministration(windows: windows, workspaceID: workspace.id)
        guard case let .authorized(organizeBatch) = fixture.core.authorize(.init(
            operation: .adminArchive, caller: .agentSession(fixture.callerID), scopeID: fixture.scope.id,
            targetSessionIDs: [target]
        )), case let .authorized(observeBatch) = fixture.core.authorize(.init(
            operation: .adminGet, caller: .agentSession(fixture.callerID), scopeID: fixture.scope.id,
            targetSessionIDs: [target]
        )) else { return XCTFail("The original unique owner must admit both operations before preflight") }
        let organizeLease = try XCTUnwrap(organizeBatch.leases.first)
        let observeLease = try XCTUnwrap(observeBatch.leases.first)
        let context = SessionAdminHandlerContext(scopes: fixture.scopes, projector: projector)
        XCTAssertTrue(context.isStillAuthorized(organizeLease, scope: fixture.scope))
        XCTAssertTrue(context.isStillAuthorized(observeLease, scope: fixture.scope, requiresMutationOwner: false))
        let beforeOwnerIndex = owner.agentModeViewModel.sessionIndex
        var preflightVisits = 0
        var beforePeerWorkspace: WorkspaceModel?
        let token = owner.promptManager.setComposeTabsRemovalPreflight { tabIDs, _, workspaceID in
            XCTAssertEqual(tabIDs, [tab.id])
            XCTAssertEqual(workspaceID, workspace.id)
            preflightVisits += 1
            peer.workspaceManager.activeWorkspace = settledOwnerWorkspace
            peer.promptManager.loadComposeTabsFromWorkspace(settledOwnerWorkspace)
            let peerChatID = await peer.oracleViewModel.ensureActiveSessionForCurrentTab(createIfMissing: true)
            XCTAssertNotNil(peerChatID)
            beforePeerWorkspace = peer.workspaceManager.activeWorkspace
            XCTAssertEqual(beforePeerWorkspace?.composeTabs.first { $0.id == keepAlive.id }?.activeChatSessionID, peerChatID)
            self.installCarrierIndex([target: entry], workspace: settledOwnerWorkspace, on: peer)
            return .proceed
        }
        defer { owner.promptManager.removeComposeTabsRemovalPreflight(token) }
        let organizer = OpenWindowsAgentSessionOrganizer(windows: { windows })
        // The callback deliberately grants authority: the backend must independently re-prove
        // one writable physical carrier after its awaited preflight.
        let archived = await organizer.archive([target], isAuthorized: { _ in true })
        XCTAssertEqual(preflightVisits, 1)
        XCTAssertTrue(archived.isEmpty)
        XCTAssertEqual(owner.workspaceManager.activeWorkspace, settledOwnerWorkspace)
        XCTAssertEqual(peer.workspaceManager.activeWorkspace, try XCTUnwrap(beforePeerWorkspace))
        XCTAssertEqual(owner.agentModeViewModel.sessionIndex, beforeOwnerIndex)
        XCTAssertEqual(peer.agentModeViewModel.sessionIndex, [target: entry])
        XCTAssertEqual(projector.pointResolutionState(for: target), .replicated)
        XCTAssertTrue(fixture.scopes.isCurrent(organizeLease), "The refusal must come from changed carrier ownership, not revoked authority")
        XCTAssertFalse(context.isStillAuthorized(organizeLease, scope: fixture.scope))
        XCTAssertTrue(context.isStillAuthorized(observeLease, scope: fixture.scope, requiresMutationOwner: false))
    }

    func testArchiveBatchRetainsEarlierReceiptAndUndoWhenLaterPreflightCreatesAReplica() async throws {
        let first = UUID(), second = UUID()
        let firstTab = ComposeTabState(name: "First", activeAgentSessionID: first)
        let secondTab = ComposeTabState(name: "Second", activeAgentSessionID: second)
        let keepAlive = ComposeTabState(name: "Keep active")
        let workspace = WorkspaceModel(
            name: "Partial archive owner", repoPaths: [], ephemeralFlag: true,
            composeTabs: [firstTab, secondTab, keepAlive], activeComposeTabID: keepAlive.id
        )
        let otherWorkspace = WorkspaceModel(name: "Peer before partial archive", repoPaths: [], ephemeralFlag: true)
        let entries = [carrierEntry(first, tabID: firstTab.id), carrierEntry(second, tabID: secondTab.id)]
        let owner = await carrierWindow(workspace: workspace, entries: entries)
        let peer = await carrierWindow(workspace: otherWorkspace, entries: [])
        let ownerChatIDValue = await owner.oracleViewModel.ensureActiveSessionForCurrentTab(createIfMissing: true)
        let ownerChatID = try XCTUnwrap(ownerChatIDValue)
        let ownerForegroundChat = try XCTUnwrap(owner.oracleViewModel.sessions.first { $0.id == ownerChatID })
        let settledOwnerWorkspace = try XCTUnwrap(owner.workspaceManager.activeWorkspace)
        XCTAssertEqual(settledOwnerWorkspace.composeTabs.first { $0.id == keepAlive.id }?.activeChatSessionID, ownerChatID)
        peer.workspaceManager.workspaces.append(settledOwnerWorkspace)
        installIdleCarrier(first, tabID: firstTab.id, on: owner)
        installIdleCarrier(second, tabID: secondTab.id, on: owner)
        let windows = [owner, peer]
        var undoTokens = 0
        let fixture = try carrierAdministration(windows: windows, workspaceID: workspace.id, makeToken: {
            undoTokens += 1
            return "earlier-archive-undo"
        })
        var preflightTargets: [Set<UUID>] = []
        var copiedStashID: UUID?
        let hook = owner.promptManager.setComposeTabsRemovalPreflight { tabIDs, _, workspaceID in
            preflightTargets.append(tabIDs)
            XCTAssertEqual(workspaceID, workspace.id)
            if tabIDs == [secondTab.id] {
                guard let current = owner.workspaceManager.activeWorkspace,
                      let firstStash = current.stashedTabs.first(where: { $0.tab.id == firstTab.id })
                else {
                    XCTFail("The first archive must have committed before the second preflight")
                    return .proceed
                }
                copiedStashID = firstStash.id
                // Copy the committed state, including the exact stash wrapper. Both observations
                // agree; only the second target's newly replicated mutation ownership is refused.
                peer.workspaceManager.workspaces = [otherWorkspace, current]
                peer.workspaceManager.activeWorkspace = current
                peer.promptManager.loadComposeTabsFromWorkspace(current)
                // Replicate the unsaved foreground chat as well as its tab pointer, so the peer's
                // independent Oracle initialization cannot replace it with a different blank chat.
                peer.oracleViewModel.prepareChatSessionCatalog(for: current)
                peer.oracleViewModel.sessions = [ownerForegroundChat]
                let peerChatID = await peer.oracleViewModel.ensureActiveSessionForCurrentTab(createIfMissing: true)
                XCTAssertEqual(peerChatID, ownerChatID)
                XCTAssertEqual(peer.workspaceManager.activeWorkspace, current)
                self.installCarrierIndex(owner.agentModeViewModel.sessionIndex, workspace: current, on: peer)
            }
            return .proceed
        }
        defer { owner.promptManager.removeComposeTabsRemovalPreflight(hook) }
        guard case let .completed(value) = try await fixture.core.perform(.init(
            operation: .adminArchive, caller: .agentSession(fixture.callerID), scopeID: fixture.scope.id,
            targetSessionIDs: [first, second]
        )) else { return XCTFail("A later refusal must retain the earlier committed archive result") }
        XCTAssertEqual(preflightTargets, [[firstTab.id], [secondTab.id]])
        XCTAssertEqual(value.objectValue?["result"]?.stringValue, "partial")
        XCTAssertEqual(value.objectValue?["changed_count"]?.intValue, 1)
        let items = try XCTUnwrap(value.objectValue?["items"]?.arrayValue)
        XCTAssertEqual(items.count, 2)
        let firstResult = try XCTUnwrap(items.first { $0.objectValue?["session_id"]?.stringValue == first.uuidString }?.objectValue)
        let secondResult = try XCTUnwrap(items.first { $0.objectValue?["session_id"]?.stringValue == second.uuidString }?.objectValue)
        XCTAssertEqual(firstResult["status"]?.stringValue, "changed")
        XCTAssertNil(firstResult["reason"])
        XCTAssertEqual(secondResult["status"]?.stringValue, "failed")
        XCTAssertEqual(secondResult["reason"]?.stringValue, "mutation_rejected")

        let committed = try XCTUnwrap(owner.workspaceManager.activeWorkspace)
        XCTAssertEqual(committed.composeTabs.map(\.id), [secondTab.id, keepAlive.id])
        XCTAssertEqual(committed.stashedTabs.map(\.tab.id), [firstTab.id])
        XCTAssertEqual(committed.stashedTabs.first?.id, try XCTUnwrap(copiedStashID))
        XCTAssertEqual(peer.workspaceManager.activeWorkspace, committed)
        let organizer = OpenWindowsAgentSessionOrganizer(windows: { windows })
        XCTAssertEqual(organizer.state(of: first)?.isArchived, true)
        XCTAssertEqual(organizer.state(of: second)?.isArchived, false)
        let source = OpenWindowsDelegationProvenanceSource(windows: { windows })
        XCTAssertEqual(source.provenance(for: first)?.workspaceID, workspace.id)
        XCTAssertEqual(source.provenance(for: second)?.workspaceID, workspace.id)
        guard case .authorized = fixture.core.authorize(.init(
            operation: .adminGet, caller: .agentSession(fixture.callerID), scopeID: fixture.scope.id,
            targetSessionIDs: [first, second]
        )) else { return XCTFail("Fresh read authority must agree with the partial archive receipt") }

        XCTAssertEqual(undoTokens, 1)
        let token = try XCTUnwrap(value.objectValue?["undo_token"]?.stringValue)
        guard case let .redeemed(entry) = fixture.handler.redeemUndo(token: token, granteeSessionID: fixture.callerID),
              case let .unarchive(restorable) = entry.payload
        else { return XCTFail("The committed first archive must retain its real undo payload") }
        XCTAssertEqual(restorable, [first], "The refused second archive must never appear in the undo payload")
    }

    func testApprovedCardRechecksSameTurnCarrierConflictBeforeAnyEffectAndCanRecover() async throws {
        let targets = [UUID(), UUID()]
        let tabs = targets.map { ComposeTabState(name: "Original", activeAgentSessionID: $0) }
        let workspace = WorkspaceModel(
            name: "Fresh card proof", repoPaths: [], ephemeralFlag: true,
            composeTabs: tabs, activeComposeTabID: tabs[0].id
        )
        let window = await carrierWindow(workspace: workspace, entries: zip(targets, tabs).map { carrierEntry($0.0, tabID: $0.1.id) })
        for (target, tab) in zip(targets, tabs) {
            installIdleCarrier(target, tabID: tab.id, on: window)
        }
        var undoTokens = 0
        let fixture = try carrierAdministration(windows: [window], workspaceID: workspace.id, threshold: 1, makeToken: {
            undoTokens += 1
            return "carrier-card-undo"
        })
        func request(preview: Bool = false, confirmation: UUID? = nil) -> AgentSessionAdministrationRequest {
            .init(
                operation: .adminRename, caller: .agentSession(fixture.callerID), scopeID: fixture.scope.id,
                targetSessionIDs: targets, idempotencyKey: "carrier-card", confirmationID: confirmation,
                preview: preview, arguments: ["name": .string("Approved rename")]
            )
        }
        guard case .confirmationRequired = fixture.core.authorize(request(preview: true)) else {
            return XCTFail("A coherent preview should require the real two-item card")
        }
        guard case let .pendingConfirmation(card, _) = try await fixture.core.perform(request()) else {
            return XCTFail("The coherent batch must produce a reviewable card")
        }
        XCTAssertNotNil(fixture.scopes.confirmations.approve(confirmationID: card.id))
        XCTAssertEqual(window.workspaceManager.workspaces, [workspace])
        XCTAssertEqual(undoTokens, 0)

        window.workspaceManager.workspaces[0].stashedTabs.append(StashedTab(tab: tabs[0]))
        let conflictedWorkspaces = window.workspaceManager.workspaces
        let beforeIndex = window.agentModeViewModel.sessionIndex
        guard case let .denied(_, target) = fixture.core.authorize(request(preview: true)) else {
            return XCTFail("Preview must resolve identity again after the card was created")
        }
        XCTAssertEqual(target, targets[0])
        guard case let .denied(_, target) = try await fixture.core.perform(request(confirmation: card.id)) else {
            return XCTFail("An approved card cannot override fresh identity ambiguity")
        }
        XCTAssertEqual(target, targets[0])
        XCTAssertEqual(window.workspaceManager.workspaces, conflictedWorkspaces)
        XCTAssertEqual(window.agentModeViewModel.sessionIndex, beforeIndex)
        XCTAssertEqual(undoTokens, 0)
        XCTAssertEqual(fixture.scopes.confirmations.confirmation(id: card.id, granteeSessionID: fixture.callerID)?.state, .approved)

        window.workspaceManager.workspaces[0].stashedTabs.removeAll()
        guard case .authorized = fixture.core.authorize(request(confirmation: card.id)) else {
            return XCTFail("Removing the competing carrier must restore the next proof without cache invalidation")
        }
    }

    func testConflictingPlacementRetainsAccountingButDeniesUsageAndNewSessionAdmission() async throws {
        let creator = UUID(), caller = UUID()
        let tab = ComposeTabState(name: "Creator", activeAgentSessionID: creator)
        let firstWorkspace = WorkspaceModel(
            name: "First placement", repoPaths: [], ephemeralFlag: true,
            composeTabs: [tab], activeComposeTabID: tab.id
        )
        let secondWorkspace = WorkspaceModel(
            name: "Conflicting placement", repoPaths: [], ephemeralFlag: true,
            composeTabs: [tab], activeComposeTabID: tab.id
        )
        let first = await carrierWindow(workspace: firstWorkspace, entries: [carrierEntry(creator, tabID: tab.id)])
        let second = await carrierWindow(workspace: secondWorkspace, entries: [carrierEntry(creator, tabID: tab.id)])
        installIdleCarrier(creator, tabID: tab.id, on: second)
        let windows = [first, second]
        let source = OpenWindowsDelegationProvenanceSource(windows: { windows })
        let projector = SpawnProvenanceDelegationMembershipProjector(source: source)
        let fixture = try carrierAdministration(windows: windows, workspaceID: firstWorkspace.id, callerID: caller)
        let accounting = source.allKnownSessions()
        XCTAssertEqual(accounting.map(\.sessionID), [creator])
        XCTAssertNil(accounting.first?.workspaceID, "Conflicting placement cannot choose a first owner for accounting")
        XCTAssertEqual(accounting.first?.isLive, true, "Uncertain placement must not erase a live resource")
        XCTAssertNil(projector.usageEvidence(of: fixture.scope.grant, spawnParentSessionID: creator))
        XCTAssertNotNil(projector.usageEvidence(of: grant(.workspace(workspaceID: UUID()), grantee: caller), spawnParentSessionID: nil))

        let pending = try fixture.scopes.requestScope(
            requesterSessionID: creator, requesterTabID: nil, kind: .workspace(workspaceID: firstWorkspace.id),
            capabilities: [.observe, .spawn], guardrails: .init(maxLiveSessions: 10), reason: nil, idempotencyKey: nil
        ).get()
        let spawnScope = try fixture.scopes.approve(requestID: pending.id).get()
        let emptyUsage = DomainDelegationScopeUsage(scopeID: spawnScope.id, liveSessionCount: 0, worktreeCount: 0, spawnParentDepth: nil)
        let before = fixture.scopes.usageIncludingReservations(emptyUsage)
        XCTAssertEqual(DelegationSpawnAdmission.admit(
            creatorSessionID: creator, target: .newSession,
            scopes: fixture.scopes, administration: fixture.core, projector: projector
        ), .creatorPlacementUnresolved(projector.pointResolutionState(for: creator) == .replicated ? "creator_replicated" : "creator_ancestry_conflict"), "A missing safe placement is not evidence that this creator is unscoped")
        let after = fixture.scopes.usageIncludingReservations(emptyUsage)
        XCTAssertEqual(after.liveSessionCount, before.liveSessionCount)
        XCTAssertEqual(after.worktreeCount, before.worktreeCount)
    }

    func testKnownUnprovenTreeRootCannotUseUnloadedAncestorShortcutOrUnscopedSpawn() async throws {
        let root = UUID(), child = UUID()
        let rootTab = ComposeTabState(name: "Unproven root", activeAgentSessionID: root)
        let childTab = ComposeTabState(name: "Trusted child", activeAgentSessionID: child)
        let workspace = WorkspaceModel(
            name: "Root identity fence", repoPaths: [], ephemeralFlag: true,
            composeTabs: [rootTab, childTab], activeComposeTabID: childTab.id
        )
        var childEntry = carrierEntry(child, tabID: childTab.id)
        childEntry.parentSessionID = root
        let window = await carrierWindow(workspace: workspace, entries: [childEntry])
        let source = OpenWindowsDelegationProvenanceSource(windows: { [window] })
        let projector = SpawnProvenanceDelegationMembershipProjector(source: source)
        let scopes = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
        let unscopedCore = AgentSessionAdministrationCore(scopes: scopes, projector: projector)
        XCTAssertEqual(DelegationSpawnAdmission.admit(
            creatorSessionID: child, target: .newSession, scopes: scopes, administration: unscopedCore, projector: projector
        ), .unscoped, "With no live delegation anywhere, scope provenance cannot revoke the creation surface's own authority")
        let pending = try scopes.requestScope(
            requesterSessionID: child, requesterTabID: nil, kind: .tree(rootSessionID: root),
            capabilities: [.observe, .spawn], guardrails: .init(maxLiveSessions: 10), reason: nil, idempotencyKey: nil
        ).get()
        let scope = try scopes.approve(requestID: pending.id).get()
        let core = AgentSessionAdministrationCore(scopes: scopes, projector: projector)
        XCTAssertEqual(projector.pointResolutionState(for: root), .unproven)
        XCTAssertNil(projector.membershipProof(for: child, in: scope.grant))
        XCTAssertTrue(projector.authorityConflictInAncestry(of: child))
        let emptyUsage = DomainDelegationScopeUsage(scopeID: scope.id, liveSessionCount: 0, worktreeCount: 0)
        XCTAssertEqual(DelegationSpawnAdmission.admit(
            creatorSessionID: child, target: .newSession, scopes: scopes, administration: core, projector: projector
        ), .creatorPlacementUnresolved("creator_ancestry_conflict"))
        for subreason in ["creator_ancestry_conflict", "creator_replicated"] {
            guard case let .invalidParams(message) = DelegationSpawnAdmission.error(for: .usageProofMissing, subreason: subreason),
                  let message, let start = message.firstIndex(of: "{"),
                  let fields = try JSONSerialization.jsonObject(with: Data(message[start...].utf8)) as? [String: Any]
            else { return XCTFail("placement refusal must stay a structured invalid-params error") }
            XCTAssertEqual(fields["reason"] as? String, "placement_unresolved")
            XCTAssertEqual(fields["subreason"] as? String, subreason)
            XCTAssertEqual(fields["retryable"] as? Bool, false)
            XCTAssertEqual(fields["recovery"] as? String, "manual")
            XCTAssertNil(fields["next_call"], "no executable call repairs placement; a generic scope_status is not a repair")
            XCTAssertEqual(fields["detail"] as? String, DelegationSpawnAdmission.placementUnresolvedDetail(subreason: subreason))
        }
        XCTAssertTrue(DelegationSpawnAdmission.placementUnresolvedDetail(subreason: "creator_replicated").contains("duplicate presentation"))
        XCTAssertEqual(scopes.usageIncludingReservations(emptyUsage), emptyUsage)

        // An actually unloaded root retains the existing ancestry contract; it is distinct from a
        // loaded root whose authority metadata is missing or stale.
        window.workspaceManager.workspaces[0].composeTabs.removeAll { $0.id == rootTab.id }
        XCTAssertEqual(projector.pointResolutionState(for: root), .absent)
        XCTAssertEqual(projector.membershipProof(for: child, in: scope.grant)?.basis, .treePath([child, root]))
        XCTAssertFalse(projector.authorityConflictInAncestry(of: child))
    }

    private func assertAmbiguousAdministrationRefused(
        _ sessionID: UUID,
        workspaceID: UUID,
        windows: [WindowState],
        context: String
    ) async throws {
        let beforeWorkspaces = windows.map(\.workspaceManager.workspaces)
        let beforeIndexes = windows.map(\.agentModeViewModel.sessionIndex)
        let source = OpenWindowsDelegationProvenanceSource(windows: { windows })
        XCTAssertNil(source.placement(for: sessionID), context)
        XCTAssertNil(source.provenance(for: sessionID), context)
        XCTAssertNil(source.provenance(for: [sessionID])[sessionID], context)
        let organizer = OpenWindowsAgentSessionOrganizer(windows: { windows })
        XCTAssertNil(organizer.state(of: sessionID), context)
        for control in [false, true] {
            var undoTokens = 0
            let capabilities: Set<DomainDelegationScopeCapability> = control ? [.observe, .organize, .control] : [.observe, .organize]
            let fixture = try carrierAdministration(windows: windows, workspaceID: workspaceID, capabilities: capabilities, makeToken: {
                undoTokens += 1
                return UUID().uuidString
            })
            let operations: [(DomainAgentSessionTargetOperation, [String: Value])] = [
                (.adminRename, ["name": .string("Must not rename")]),
                (.adminSetPin, ["pinned": .bool(true)]),
                (.adminSetGroup, ["group": .string("Must not regroup")]),
                (.adminArchive, [:])
            ]
            for (operation, arguments) in operations {
                for preview in [false, true] {
                    let result = try await fixture.core.perform(.init(
                        operation: operation, caller: .agentSession(fixture.callerID), scopeID: fixture.scope.id,
                        targetSessionIDs: [sessionID], idempotencyKey: UUID().uuidString, preview: preview, arguments: arguments
                    ))
                    guard case let .denied(_, target) = result else {
                        XCTFail("\(context): ambiguous \(operation) must be refused even with control=\(control), preview=\(preview)")
                        continue
                    }
                    XCTAssertEqual(target, sessionID, context)
                }
            }
            XCTAssertEqual(undoTokens, 0, context)
        }
        // The backend must independently refuse an address even when its caller already holds a lease.
        XCTAssertTrue(organizer.rename([sessionID: "Must not rename"]).isEmpty, context)
        XCTAssertTrue(organizer.setPinned(true, sessionIDs: [sessionID]).isEmpty, context)
        XCTAssertTrue(organizer.setGroup("Must not regroup", order: 1, sessionIDs: [sessionID]).isEmpty, context)
        let archived = await organizer.archive([sessionID], isAuthorized: { _ in true })
        XCTAssertTrue(archived.isEmpty, context)
        XCTAssertEqual(windows.map(\.workspaceManager.workspaces), beforeWorkspaces, context)
        XCTAssertEqual(windows.map(\.agentModeViewModel.sessionIndex), beforeIndexes, context)
    }

    private func carrierWindow(workspace: WorkspaceModel, entries: [AgentSessionIndexEntry]) async -> WindowState {
        let window = WindowState()
        addTeardownBlock { @MainActor in await window.tearDown() }
        await window.workspaceManager.awaitInitialized()
        // These fixtures prove authority and model mutation, not durable transcript persistence.
        window.agentModeViewModel.test_setAgentSessionSaver { _, _, _ in
            FileManager.default.temporaryDirectory.appendingPathComponent("point-carrier-\(UUID()).json")
        }
        window.workspaceManager.workspaces = [workspace]
        window.workspaceManager.activeWorkspace = workspace
        // Keep every raw carrier claim in the mutation owner, including deliberately repeated
        // tab IDs. Sidebar rendering requires one UI row per tab and is not the proof under test.
        var presentation = workspace
        var presentedTabIDs: Set<UUID> = []
        presentation.composeTabs = workspace.composeTabs.filter { presentedTabIDs.insert($0.id).inserted }
        window.promptManager.loadComposeTabsFromWorkspace(presentation)
        installCarrierIndex(Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) }), workspace: workspace, on: window)
        return window
    }

    private func installCarrierIndex(_ entries: [UUID: AgentSessionIndexEntry], workspace: WorkspaceModel, on window: WindowState) {
        let owner = AgentModeViewModel.SessionIndexOwner(workspaceID: workspace.id, activationEpoch: 1)
        window.agentModeViewModel.test_installSessionIndexSnapshot(entries, owner: owner, latestOwner: owner, activeWorkspace: workspace)
    }

    private func installIdleCarrier(_ sessionID: UUID, tabID: UUID, on window: WindowState) {
        let live = AgentModeViewModel.TabSession(tabID: tabID)
        live.testInstallPersistentSessionBinding(sessionID: sessionID)
        live.hasLoadedPersistedState = true
        live.recordRestorationAuthoritative(.persistedPayloadApplied)
        XCTAssertNil(live.operationAdmissionFailureMessage)
        window.agentModeViewModel.test_installLiveSession(live)
    }

    private func carrierEntry(_ sessionID: UUID, tabID: UUID) -> AgentSessionIndexEntry {
        AgentSessionIndexEntry(
            id: sessionID, tabID: tabID, name: "Original", savedAt: Date(timeIntervalSince1970: 0),
            itemCount: 1, autoEditEnabled: false, hasUnknownConversationContent: false,
            isMCPOriginated: false, worktreeBindingSummaries: [], activeWorktreeMergeSummaries: []
        )
    }

    private func carrierAdministration(
        windows: [WindowState],
        workspaceID: UUID,
        callerID: UUID = UUID(),
        capabilities: Set<DomainDelegationScopeCapability> = [.observe, .organize, .control],
        threshold: Int = 25,
        makeToken: @escaping () -> String = { UUID().uuidString }
    ) throws -> (
        core: AgentSessionAdministrationCore, scopes: DelegationScopeRuntime,
        scope: DomainDelegationScopeRecord, callerID: UUID, handler: AgentSessionOrganizeOperationHandler
    ) {
        let source = OpenWindowsDelegationProvenanceSource(windows: { windows })
        let projector = SpawnProvenanceDelegationMembershipProjector(source: source)
        let scopes = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
        let pending = try scopes.requestScope(
            requesterSessionID: callerID, requesterTabID: nil, kind: .workspace(workspaceID: workspaceID),
            capabilities: capabilities, guardrails: .init(bulkConfirmationThreshold: threshold), reason: nil, idempotencyKey: nil
        ).get()
        let scope = try scopes.approve(requestID: pending.id).get()
        let core = AgentSessionAdministrationCore(scopes: scopes, projector: projector)
        let handler = AgentSessionOrganizeOperationHandler(
            backend: OpenWindowsAgentSessionOrganizer(windows: { windows }),
            isLeaseCurrent: { scopes.isCurrent($0) }, holdsControl: { $0.grant.capabilities.contains(.control) }, makeToken: makeToken
        )
        core.register(handler)
        return (core, scopes, scope, callerID, handler)
    }

    private func installIndex(_ ids: [UUID], workspace: WorkspaceModel, on window: WindowState) {
        window.agentModeViewModel.test_setAgentSessionSaver { _, _, _ in
            FileManager.default.temporaryDirectory.appendingPathComponent("point-index-\(UUID()).json")
        }
        window.workspaceManager.workspaces = [workspace]
        window.workspaceManager.activeWorkspace = workspace
        window.promptManager.loadComposeTabsFromWorkspace(workspace)
        let entries = ids.map { id in
            AgentSessionIndexEntry(
                id: id, tabID: UUID(), name: "Indexed", savedAt: Date(timeIntervalSince1970: 0),
                itemCount: 0, autoEditEnabled: false, hasUnknownConversationContent: false,
                isMCPOriginated: false, worktreeBindingSummaries: [], activeWorktreeMergeSummaries: []
            )
        }
        let owner = AgentModeViewModel.SessionIndexOwner(workspaceID: workspace.id, activationEpoch: 1)
        window.agentModeViewModel.test_installSessionIndexSnapshot(
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

@MainActor
final class AgentSessionPointReadScalingTests: XCTestCase {
    func testContextBuilderSaveSkipsEquivalentConfigAndKeepsWorkspaceOwnership() async {
        for rawFollowUp in [nil, "unsupported"] as [String?] {
            let window = WindowState()
            await window.workspaceManager.awaitInitialized()
            let manager = window.workspaceManager
            let promptID = UUID()
            let secondPromptID = UUID()
            let target = ComposeTabState(
                name: "Active target",
                contextBuilder: ContextBuilderTabConfig(
                    instructions: "Active instructions", followUpTypeRaw: rawFollowUp,
                    selectedContextBuilderPromptIDs: [secondPromptID, promptID, secondPromptID]
                )
            )
            var shadow = target
            shadow.name = "Inactive target"
            shadow.contextBuilder.instructions = "Inactive instructions"
            let inactive = WorkspaceModel(
                name: "Inactive workspace", repoPaths: [], ephemeralFlag: true,
                composeTabs: [shadow], activeComposeTabID: shadow.id
            )
            let active = WorkspaceModel(
                name: "Active workspace", repoPaths: [], ephemeralFlag: true,
                composeTabs: [target], activeComposeTabID: target.id
            )
            manager.workspaces = [inactive, active]
            manager.activeWorkspace = active
            window.promptManager.loadComposeTabsFromWorkspace(active)
            let viewModel = window.contextBuilderAgentViewModel
            XCTAssertNotNil(viewModel.sessions[target.id])
            XCTAssertEqual(viewModel.contextBuilderInstructions, "Active instructions")
            XCTAssertEqual(viewModel.selectedFollowUpType, .plan)
            XCTAssertEqual(viewModel.selectedContextBuilderPromptIDs, [promptID, secondPromptID])

            let initialRebuilds = manager.test_sessionCarrierIndexRebuildCount
            manager.pollAndSaveState()
            XCTAssertEqual(manager.test_sessionCarrierIndexRebuildCount, initialRebuilds)
            XCTAssertEqual(manager.modelRoutingTab(workspaceID: active.id, tabID: target.id)?.contextBuilder, target.contextBuilder)
            XCTAssertEqual(manager.workspaces.first(where: { $0.id == inactive.id })?.composeTabs.first(where: { $0.id == shadow.id }), shadow)

            viewModel.contextBuilderInstructions = "Edited instructions"
            viewModel.selectedFollowUpType = .review
            viewModel.selectedContextBuilderPromptIDs = [secondPromptID]
            let saved = manager.modelRoutingTab(workspaceID: active.id, tabID: target.id)
            XCTAssertNotNil(saved)
            XCTAssertEqual(saved?.contextBuilder.instructions, "Edited instructions")
            XCTAssertEqual(saved?.contextBuilder.followUpTypeRaw, ContextBuilderFollowUpType.review.rawValue)
            XCTAssertEqual(saved?.contextBuilder.selectedContextBuilderPromptIDs, [secondPromptID])
            XCTAssertEqual(manager.workspaces.first(where: { $0.id == inactive.id })?.composeTabs.first(where: { $0.id == shadow.id }), shadow)
            let changedRebuilds = manager.test_sessionCarrierIndexRebuildCount
            manager.pollAndSaveState()
            XCTAssertEqual(manager.test_sessionCarrierIndexRebuildCount, changedRebuilds)
            XCTAssertEqual(manager.modelRoutingTab(workspaceID: active.id, tabID: target.id)?.contextBuilder, saved?.contextBuilder)
            await window.tearDown()
        }
    }

    func testPointReadsVisitOnlyClaimsAndPresentationWritesKeepIdentityIndexes() async {
        for unrelatedCount in [0, 4000] {
            let window = WindowState()
            await window.workspaceManager.awaitInitialized()
            let manager = window.workspaceManager
            let viewModel = window.agentModeViewModel
            let targetID = UUID()
            let target = ComposeTabState(name: "Target", activeAgentSessionID: targetID)
            let unrelated = (0 ..< unrelatedCount).map {
                ComposeTabState(name: "Unrelated \($0)", activeAgentSessionID: UUID())
            }
            let workspace = WorkspaceModel(
                name: "Point read scale", repoPaths: [], ephemeralFlag: true,
                composeTabs: unrelated + [target], activeComposeTabID: target.id
            )
            manager.workspaces = [workspace]
            manager.activeWorkspace = workspace
            window.promptManager.loadComposeTabsFromWorkspace(workspace)
            let entries = workspace.composeTabs.compactMap { tab -> AgentSessionIndexEntry? in
                guard let sessionID = tab.activeAgentSessionID else { return nil }
                return AgentSessionIndexEntry(
                    id: sessionID, tabID: tab.id, name: tab.name,
                    savedAt: Date(timeIntervalSince1970: 0), itemCount: 1,
                    autoEditEnabled: false, hasUnknownConversationContent: false, isMCPOriginated: false,
                    worktreeBindingSummaries: [], activeWorktreeMergeSummaries: []
                )
            }
            let owner = AgentModeViewModel.SessionIndexOwner(workspaceID: workspace.id, activationEpoch: 1)
            viewModel.test_installSessionIndexSnapshot(
                Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) }),
                owner: owner, latestOwner: owner, activeWorkspace: workspace
            )
            let organizer = OpenWindowsAgentSessionOrganizer(windows: { [window] })
            manager.test_sessionCarrierRowsVisited = 0
            viewModel.test_persistentBindingClaimRowsVisited = 0
            viewModel.test_sidebarSessionRowsBuildCount = 0
            XCTAssertEqual(organizer.states(of: [targetID])[targetID]?.name, "Target")
            XCTAssertLessThanOrEqual(manager.test_sessionCarrierRowsVisited, 3, "Unrelated carriers must not enter a point read")
            XCTAssertEqual(viewModel.test_persistentBindingClaimRowsVisited, 1)
            XCTAssertEqual(viewModel.test_sidebarSessionRowsBuildCount, 0, "Authority lookup must not construct presentation rows")

            let rebuilds = manager.test_sessionCarrierIndexRebuildCount
            window.promptManager.renameComposeTab(target.id, to: "Renamed")
            XCTAssertEqual(manager.test_sessionCarrierIndexRebuildCount, rebuilds)
            XCTAssertEqual(organizer.setPinned(true, sessionIDs: [targetID]), [targetID])
            XCTAssertEqual(manager.test_sessionCarrierIndexRebuildCount, rebuilds)
            XCTAssertEqual(organizer.setGroup("Group", order: 1, sessionIDs: [targetID]), [targetID])
            XCTAssertEqual(manager.test_sessionCarrierIndexRebuildCount, rebuilds)
            XCTAssertEqual(manager.modelRoutingTab(workspaceID: workspace.id, tabID: target.id)?.name, "Renamed")
            XCTAssertEqual(manager.modelRoutingTab(workspaceID: workspace.id, tabID: target.id)?.sidebarGroup, "Group")

            // Fresh same-turn identity mutations must invalidate the point result, even for a
            // conflicting claim in a stash rather than an active sidebar row.
            var duplicate = target
            duplicate.id = UUID()
            manager.workspaces[0].stashedTabs.append(StashedTab(tab: duplicate))
            XCTAssertEqual(viewModel.authoritativeLiveSessionStates(for: [targetID])[targetID], .ambiguous)
            manager.workspaces[0].stashedTabs.removeAll()
            let live = AgentModeViewModel.TabSession(tabID: target.id)
            viewModel.test_installLiveSession(live)
            live.testInstallPersistentSessionBinding(sessionID: targetID)
            XCTAssertEqual(viewModel.authoritativeLiveSessionStates(for: [targetID])[targetID], .idle)
            live.testInstallPersistentSessionBinding(sessionID: UUID())
            XCTAssertEqual(viewModel.authoritativeLiveSessionStates(for: [targetID])[targetID], .ambiguous)
            await window.tearDown()
        }
    }

    func testPointMetadataUpdatePreservesOtherRowsAndReadsOnlyTheChangedTab() async {
        let window = WindowState()
        await window.workspaceManager.awaitInitialized()
        let viewModel = window.agentModeViewModel
        let workspace = WorkspaceModel(name: "Metadata delta", repoPaths: [], ephemeralFlag: true)
        let entries = (0 ..< 4000).map { number in
            AgentSessionIndexEntry(
                id: UUID(), tabID: UUID(), name: "Row \(number)",
                savedAt: Date(timeIntervalSince1970: 0), itemCount: 1,
                autoEditEnabled: false, hasUnknownConversationContent: false, isMCPOriginated: false,
                worktreeBindingSummaries: [], activeWorktreeMergeSummaries: []
            )
        }
        let owner = AgentModeViewModel.SessionIndexOwner(workspaceID: workspace.id, activationEpoch: 1)
        viewModel.test_installSessionIndexSnapshot(
            Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) }),
            owner: owner, latestOwner: owner, activeWorkspace: workspace
        )
        let store = viewModel.sessionIndexStore
        var changed = entries[0]
        changed.name = "Renamed"
        store.test_metadataRowsVisited = 0
        store.applyLocalUpsert(changed)
        XCTAssertEqual(store.ownerValidatedEntries(forTabID: changed.tabID).first?.name, "Renamed")
        XCTAssertEqual(store.test_metadataRowsVisited, 1)
        XCTAssertEqual(store.sessionIndex[entries[1].id], entries[1])
        XCTAssertEqual(store.sessionIndex.count, entries.count)
        await window.tearDown()
    }

    func testPointFallbackMatchesSidebarAndMutatesOnlyResolvedSession() async throws {
        for binding in [FallbackOtherBinding.persistedNewer, .liveNewer, .liveOverride] {
            let fixture = await makeFallbackFixture(otherBinding: binding)
            let window = fixture.window
            let manager = window.workspaceManager
            let viewModel = window.agentModeViewModel
            let organizer = OpenWindowsAgentSessionOrganizer(windows: { [window] })
            let expectedID = binding == .liveOverride ? fixture.newerID : fixture.olderID
            let unchangedID = expectedID == fixture.olderID ? fixture.newerID : fixture.olderID
            let originalUnchangedEntry = viewModel.ownerValidatedSessionIndex[unchangedID]
            let workspaceID = fixture.workspaceID
            let rows = try viewModel.sidebarSessions(for: XCTUnwrap(manager.activeWorkspace?.composeTabs))
            XCTAssertEqual(rows.first { $0.tabID == fixture.targetID }?.sessionID, expectedID)
            XCTAssertEqual(viewModel.boundSessionID(for: fixture.targetID), expectedID)
            if binding == .persistedNewer {
                XCTAssertEqual(organizer.states(of: [fixture.newerID])[fixture.newerID]?.tabID, fixture.otherID)
            } else {
                XCTAssertNil(organizer.state(of: fixture.newerID), "Presentation may choose a fallback while raw persisted/live identity remains conflicted")
            }
            if binding == .liveOverride {
                let beforeWorkspaces = manager.workspaces
                let beforeIndex = viewModel.sessionIndex
                XCTAssertNil(organizer.state(of: expectedID))
                XCTAssertTrue(organizer.setPinned(true, sessionIDs: [expectedID]).isEmpty)
                XCTAssertTrue(organizer.setGroup("Rejected group", order: 1, sessionIDs: [expectedID]).isEmpty)
                XCTAssertTrue(organizer.rename([expectedID: "Rejected rename"]).isEmpty)
                XCTAssertEqual(manager.workspaces, beforeWorkspaces)
                XCTAssertEqual(viewModel.sessionIndex, beforeIndex)
                await window.tearDown()
                continue
            }
            XCTAssertEqual(organizer.states(of: [expectedID])[expectedID]?.tabID, fixture.targetID)

            XCTAssertEqual(organizer.setPinned(true, sessionIDs: [expectedID]), [expectedID])
            XCTAssertEqual(organizer.setGroup("Chosen group", order: 1, sessionIDs: [expectedID]), [expectedID])
            XCTAssertEqual(organizer.rename([expectedID: "Renamed chosen session"]), [expectedID])
            XCTAssertEqual(manager.modelRoutingTab(workspaceID: workspaceID, tabID: fixture.targetID)?.name, "Renamed chosen session")
            XCTAssertEqual(manager.modelRoutingTab(workspaceID: workspaceID, tabID: fixture.targetID)?.isPinned, true)
            XCTAssertEqual(manager.modelRoutingTab(workspaceID: workspaceID, tabID: fixture.targetID)?.sidebarGroup, "Chosen group")
            XCTAssertEqual(manager.modelRoutingTab(workspaceID: workspaceID, tabID: fixture.otherID)?.name, "Other tab")
            XCTAssertEqual(manager.modelRoutingTab(workspaceID: workspaceID, tabID: fixture.otherID)?.isPinned, false)
            XCTAssertNil(manager.modelRoutingTab(workspaceID: workspaceID, tabID: fixture.otherID)?.sidebarGroup)
            XCTAssertEqual(viewModel.ownerValidatedSessionIndex[expectedID]?.name, "Renamed chosen session")
            XCTAssertEqual(viewModel.ownerValidatedSessionIndex[unchangedID], originalUnchangedEntry)
            XCTAssertEqual(viewModel.sessions[fixture.targetID]?.activeAgentSessionID, expectedID)
            await window.tearDown()
        }
    }

    func testPointFallbackRechecksPresentationButRefusesConflictingMutationClaims() async throws {
        for unrelatedCount in [0, 4000] {
            let fixture = await makeFallbackFixture(otherBinding: .liveOverride, unrelatedCount: unrelatedCount)
            let window = fixture.window
            let manager = window.workspaceManager
            let viewModel = window.agentModeViewModel
            let organizer = OpenWindowsAgentSessionOrganizer(windows: { [window] })
            manager.workspaces[0].stashedTabs.append(StashedTab(tab: ComposeTabState(name: "Archived claim", activeAgentSessionID: fixture.newerID)))
            manager.workspaces.append(WorkspaceModel(
                name: "Inactive claim", repoPaths: [], ephemeralFlag: true,
                composeTabs: [ComposeTabState(name: "Inactive", activeAgentSessionID: fixture.newerID)]
            ))
            let orphan = AgentModeViewModel.TabSession(tabID: UUID())
            orphan.testInstallPersistentSessionBinding(sessionID: fixture.newerID)
            viewModel.test_installLiveSession(orphan)

            manager.test_sessionCarrierRowsVisited = 0
            viewModel.sessionIndexStore.test_metadataRowsVisited = 0
            XCTAssertEqual(viewModel.preferredActiveSidebarEntry(for: fixture.targetID, workspaceID: fixture.workspaceID)?.id, fixture.newerID)
            XCTAssertEqual(manager.test_sessionCarrierRowsVisited, 3, "Only the competing active, archived, and inactive claims should be visited")
            XCTAssertEqual(viewModel.sessionIndexStore.test_metadataRowsVisited, 2, "Only this tab's competing metadata should be visited")
            XCTAssertNil(organizer.state(of: fixture.newerID), "Archived, inactive and orphan claims must not become an arbitrary active mutation address")
            XCTAssertEqual(viewModel.boundSessionID(for: fixture.targetID), fixture.newerID)

            // A same-turn live rebind must change the fallback immediately, even though the
            // metadata and persisted bindings have not changed.
            let other = try XCTUnwrap(viewModel.sessions[fixture.otherID])
            other.testInstallPersistentSessionBinding(sessionID: fixture.newerID)
            XCTAssertEqual(viewModel.preferredActiveSidebarEntry(for: fixture.targetID, workspaceID: fixture.workspaceID)?.id, fixture.olderID)
            XCTAssertEqual(organizer.state(of: fixture.olderID)?.tabID, fixture.targetID)
            XCTAssertNil(organizer.state(of: fixture.newerID), "A live rebind does not erase the other physical claimants")
            XCTAssertEqual(viewModel.boundSessionID(for: fixture.targetID), fixture.olderID)
            // Archived fallback keeps its own metadata preference; active shadowing is separate.
            XCTAssertEqual(viewModel.preferredSidebarEntry(for: fixture.targetID)?.id, fixture.newerID)

            other.testInstallPersistentSessionBinding(sessionID: nil)
            XCTAssertEqual(viewModel.preferredActiveSidebarEntry(for: fixture.targetID, workspaceID: fixture.workspaceID)?.id, fixture.olderID)
            manager.workspaces[0].composeTabs[1].activeAgentSessionID = nil
            XCTAssertEqual(viewModel.preferredActiveSidebarEntry(for: fixture.targetID, workspaceID: fixture.workspaceID)?.id, fixture.newerID)
            XCTAssertEqual(viewModel.boundSessionID(for: fixture.targetID), fixture.newerID)
            await window.tearDown()
        }
    }

    private enum FallbackOtherBinding {
        case persistedNewer
        case liveNewer
        case liveOverride
    }

    private func makeFallbackFixture(
        otherBinding: FallbackOtherBinding,
        unrelatedCount: Int = 0
    ) async -> (window: WindowState, workspaceID: UUID, targetID: UUID, otherID: UUID, olderID: UUID, newerID: UUID) {
        let window = WindowState()
        await window.workspaceManager.awaitInitialized()
        let manager = window.workspaceManager
        let viewModel = window.agentModeViewModel
        viewModel.test_setAgentSessionSaver { _, _, _ in
            FileManager.default.temporaryDirectory.appendingPathComponent("point-fallback-\(UUID()).json")
        }
        let olderID = UUID()
        let newerID = UUID()
        let overrideID = UUID()
        let target = ComposeTabState(name: "Fallback tab")
        let other = ComposeTabState(name: "Other tab", activeAgentSessionID: otherBinding == .liveNewer ? overrideID : newerID)
        let unrelated = (0 ..< unrelatedCount).map {
            ComposeTabState(name: "Unrelated \($0)", activeAgentSessionID: UUID())
        }
        let workspace = WorkspaceModel(
            name: "Competing fallback", repoPaths: [], ephemeralFlag: true,
            composeTabs: [target, other] + unrelated, activeComposeTabID: target.id
        )
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        window.promptManager.loadComposeTabsFromWorkspace(workspace)
        let targetLive = AgentModeViewModel.TabSession(tabID: target.id)
        viewModel.test_installLiveSession(targetLive)
        if otherBinding != .persistedNewer {
            let otherLive = AgentModeViewModel.TabSession(tabID: other.id)
            otherLive.testInstallPersistentSessionBinding(sessionID: otherBinding == .liveNewer ? newerID : overrideID)
            viewModel.test_installLiveSession(otherLive)
        }
        var entries = unrelated.map { tab in
            AgentSessionIndexEntry(
                id: tab.activeAgentSessionID!, tabID: tab.id, name: tab.name,
                savedAt: Date(timeIntervalSince1970: 0), itemCount: 1,
                autoEditEnabled: false, hasUnknownConversationContent: false, isMCPOriginated: false,
                worktreeBindingSummaries: [], activeWorktreeMergeSummaries: []
            )
        }
        entries += [(olderID, "Older metadata", 1.0), (newerID, "Newer metadata", 2.0)].map { id, name, timestamp in
            AgentSessionIndexEntry(
                id: id, tabID: target.id, name: name,
                savedAt: Date(timeIntervalSince1970: timestamp), itemCount: 1,
                autoEditEnabled: false, hasUnknownConversationContent: false, isMCPOriginated: false,
                worktreeBindingSummaries: [], activeWorktreeMergeSummaries: []
            )
        }
        let owner = AgentModeViewModel.SessionIndexOwner(workspaceID: workspace.id, activationEpoch: 1)
        viewModel.test_installSessionIndexSnapshot(
            Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) }),
            owner: owner, latestOwner: owner, activeWorkspace: workspace
        )
        return (window, workspace.id, target.id, other.id, olderID, newerID)
    }
}
