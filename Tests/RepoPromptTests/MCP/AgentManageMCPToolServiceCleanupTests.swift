import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class AgentManageMCPToolServiceCleanupTests: XCTestCase {
    func testLargeMixedBatchIsBoundedAndReportsEveryEligibleOutcome() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let sessionIDs = (0 ..< AgentManageMCPToolService.maxCleanupSessionIDs).map { _ in UUID() }
        let eligibleID = sessionIDs[0]
        let userCreatedID = sessionIDs[1]
        let activeID = sessionIDs[2]
        let recorder = CleanupRecorder(metadataByID: [
            eligibleID: makeMetadata(id: eligibleID),
            userCreatedID: makeMetadata(id: userCreatedID, isMCPOriginated: false),
            activeID: makeMetadata(id: activeID, runState: .running)
        ])
        let service = makeService(window: window, recorder: recorder)

        let reply = try await responseObject(service.execute(args: cleanupArgs(sessionIDs)))

        XCTAssertEqual(reply["status"]?.stringValue, "partial")
        XCTAssertEqual(reply["processed_count"]?.intValue, sessionIDs.count)
        XCTAssertEqual(reply["deleted_count"]?.intValue, 1)
        XCTAssertEqual(reply["skipped_count"]?.intValue, sessionIDs.count - 1)
        XCTAssertEqual(reply["unprocessed_count"]?.intValue, 0)
        XCTAssertEqual(recorder.metadataLookupIDs, sessionIDs)
        XCTAssertEqual(recorder.persistedDeleteIDs, [eligibleID])
        XCTAssertEqual(recorder.persistedFinalizeIDs, [eligibleID])
        let reasons = Set(reply["skipped_sessions"]?.arrayValue?.compactMap { $0.objectValue?["reason"]?.stringValue } ?? [])
        XCTAssertEqual(reasons, ["already_absent", "not_mcp_originated", "skipped_active"])

        let oversizedIDs = (0 ... AgentManageMCPToolService.maxCleanupSessionIDs).map { _ in UUID() }
        do {
            _ = try await service.execute(args: cleanupArgs(oversizedIDs))
            XCTFail("Expected cleanup_sessions to reject a batch larger than 256 IDs")
        } catch {
            XCTAssertTrue(String(describing: error).contains("at most 256"), String(describing: error))
        }
    }

    func testInvalidNonStringAndDuplicateInputsFailAtomically() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let validID = UUID()
        let recorder = CleanupRecorder(metadataByID: [validID: makeMetadata(id: validID)])
        let service = makeService(window: window, recorder: recorder)
        let invalidRequests: [([Value], String)] = [
            ([.string(validID.uuidString), .string("not-a-uuid")], "session_ids[1]"),
            ([.string(validID.uuidString), .int(7)], "non-string"),
            ([.string(validID.uuidString), .string(validID.uuidString)], "duplicates UUID")
        ]

        for (sessionIDs, expectedMessage) in invalidRequests {
            do {
                _ = try await service.execute(args: [
                    "op": .string("cleanup_sessions"),
                    "session_ids": .array(sessionIDs)
                ])
                XCTFail("Expected invalid cleanup input to fail atomically")
            } catch {
                XCTAssertTrue(String(describing: error).contains(expectedMessage), String(describing: error))
            }
        }

        XCTAssertEqual(recorder.metadataLookupIDs, [])
        XCTAssertEqual(recorder.openDeleteTabIDs, [])
        XCTAssertEqual(recorder.persistedDeleteIDs, [])
        XCTAssertEqual(recorder.persistedFinalizeIDs, [])
    }

    func testMissingMetadataIndexUsesDirectSessionLookup() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let sessionID = UUID()
        let persisted = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            name: "Direct Lookup",
            transcript: .empty,
            itemCount: 0,
            lastRunState: AgentSessionRunState.completed.rawValue,
            isMCPOriginated: true
        )
        let fileURL = try await AgentSessionDataService.shared.saveAgentSession(
            persisted,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        let indexURL = fileURL.deletingLastPathComponent().appendingPathComponent("AgentSessionIndex.json")
        await AgentSessionDataService.shared.test_clearMetadataIndexCache(
            forAgentSessionsFolder: fileURL.deletingLastPathComponent()
        )
        if FileManager.default.fileExists(atPath: indexURL.path) {
            try FileManager.default.removeItem(at: indexURL)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path))
        XCTAssertNil(window.agentModeViewModel.sessionIndex[sessionID])

        let service = makeService(window: window, cleanupDependencies: .live)
        let reply = try await responseObject(service.execute(args: cleanupArgs([sessionID])))

        XCTAssertEqual(reply["status"]?.stringValue, "completed")
        XCTAssertEqual(reply["deleted_count"]?.intValue, 1)
        XCTAssertEqual(
            reply["deleted_sessions"]?.arrayValue?.first?.objectValue?["durable"]?.boolValue,
            true
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testCancellationBetweenIDsReturnsCommittedAndUnprocessedLedger() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let sessionIDs = [UUID(), UUID(), UUID()]
        let recorder = CleanupRecorder(metadataByID: Dictionary(
            uniqueKeysWithValues: sessionIDs.map { ($0, makeMetadata(id: $0)) }
        ))
        var cancellationChecks = 0
        let service = makeService(
            window: window,
            recorder: recorder,
            checkCancellation: {
                cancellationChecks += 1
                if cancellationChecks == 3 {
                    throw CancellationError()
                }
            }
        )

        let reply = try await responseObject(service.execute(args: cleanupArgs(sessionIDs)))

        XCTAssertEqual(reply["status"]?.stringValue, "cancelled")
        XCTAssertEqual(reply["cancelled"]?.boolValue, true)
        XCTAssertEqual(reply["processed_count"]?.intValue, 1)
        XCTAssertEqual(reply["deleted_count"]?.intValue, 1)
        XCTAssertEqual(reply["unprocessed_count"]?.intValue, 2)
        XCTAssertEqual(recorder.persistedDeleteIDs, [sessionIDs[0]])
        XCTAssertEqual(recorder.persistedFinalizeIDs, [sessionIDs[0]])
        XCTAssertEqual(stringArray(reply["retry_session_ids"]), Array(sessionIDs.dropFirst()).map(\.uuidString))
        XCTAssertEqual(
            reply["unprocessed_sessions"]?.arrayValue?.compactMap { $0.objectValue?["session_id"]?.stringValue },
            Array(sessionIDs.dropFirst()).map(\.uuidString)
        )
    }

    func testCancellationAfterPersistedLookupReturnsCurrentAndRemainingWithoutMutation() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let sessionIDs = [UUID(), UUID()]
        let recorder = CleanupRecorder(metadataByID: Dictionary(
            uniqueKeysWithValues: sessionIDs.map { ($0, makeMetadata(id: $0)) }
        ))
        var didCompleteLookup = false
        let service = makeService(
            window: window,
            recorder: recorder,
            loadPersistedMetadata: { sessionID, _ in
                recorder.metadataLookupIDs.append(sessionID)
                didCompleteLookup = true
                return recorder.metadataByID[sessionID]
            },
            checkCancellation: {
                if didCompleteLookup {
                    throw CancellationError()
                }
            }
        )

        let reply = try await responseObject(service.execute(args: cleanupArgs(sessionIDs)))

        XCTAssertEqual(reply["status"]?.stringValue, "cancelled")
        XCTAssertEqual(reply["processed_count"]?.intValue, 0)
        XCTAssertEqual(reply["unprocessed_count"]?.intValue, 2)
        XCTAssertEqual(recorder.metadataLookupIDs, [sessionIDs[0]])
        XCTAssertEqual(recorder.persistedDeleteIDs, [])
        XCTAssertEqual(recorder.persistedFinalizeIDs, [])
        XCTAssertEqual(stringArray(reply["retry_session_ids"]), sessionIDs.map(\.uuidString))
        XCTAssertEqual(
            reply["unprocessed_sessions"]?.arrayValue?.compactMap { $0.objectValue?["reason"]?.stringValue },
            ["cancelled_before_mutation", "cancelled_before_mutation"]
        )
    }

    func testLastIDMutationCancellationIsProcessedRetryableAndCancelled() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let sessionID = UUID()
        let recorder = CleanupRecorder(metadataByID: [sessionID: makeMetadata(id: sessionID)])
        let service = makeService(
            window: window,
            recorder: recorder,
            deletePersistedSession: { _, _ in
                throw CancellationError()
            }
        )

        let reply = try await responseObject(service.execute(args: cleanupArgs([sessionID])))

        XCTAssertEqual(reply["status"]?.stringValue, "cancelled")
        XCTAssertEqual(reply["cancelled"]?.boolValue, true)
        XCTAssertEqual(reply["processed_count"]?.intValue, 1)
        XCTAssertEqual(reply["unprocessed_count"]?.intValue, 0)
        XCTAssertEqual(stringArray(reply["retry_session_ids"]), [sessionID.uuidString])
        let outcome = try XCTUnwrap(reply["skipped_sessions"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(outcome["reason"]?.stringValue, "mutation_cancelled")
        XCTAssertEqual(outcome["durable"]?.boolValue, false)
        XCTAssertEqual(outcome["mutation_started"]?.boolValue, true)
        XCTAssertEqual(recorder.persistedFinalizeIDs, [])
    }

    func testResolutionFailurePreservesCommittedLedgerAndContinuesLaterIDs() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let sessionIDs = [UUID(), UUID(), UUID()]
        let failingID = sessionIDs[1]
        let recorder = CleanupRecorder(metadataByID: Dictionary(
            uniqueKeysWithValues: sessionIDs.map { ($0, makeMetadata(id: $0)) }
        ))
        let service = makeService(
            window: window,
            recorder: recorder,
            loadPersistedMetadata: { sessionID, _ in
                recorder.metadataLookupIDs.append(sessionID)
                if sessionID == failingID {
                    throw CleanupResolutionTestError.lookupFailed
                }
                return recorder.metadataByID[sessionID]
            }
        )

        let reply = try await responseObject(service.execute(args: cleanupArgs(sessionIDs)))

        XCTAssertEqual(reply["status"]?.stringValue, "partial")
        XCTAssertEqual(reply["processed_count"]?.intValue, 3)
        XCTAssertEqual(reply["deleted_count"]?.intValue, 2)
        XCTAssertEqual(reply["skipped_count"]?.intValue, 1)
        XCTAssertEqual(recorder.metadataLookupIDs, sessionIDs)
        XCTAssertEqual(recorder.persistedDeleteIDs, [sessionIDs[0], sessionIDs[2]])
        XCTAssertEqual(recorder.persistedFinalizeIDs, [sessionIDs[0], sessionIDs[2]])
        XCTAssertEqual(stringArray(reply["retry_session_ids"]), [failingID.uuidString])
        let failure = try XCTUnwrap(reply["skipped_sessions"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(failure["session_id"]?.stringValue, failingID.uuidString)
        XCTAssertEqual(failure["reason"]?.stringValue, "resolution_failed")
        XCTAssertTrue(failure["message"]?.stringValue?.contains("lookup failed") == true)
    }

    func testRetryOfCommittedDeletionIsAlreadyAbsentWithoutRepeatingMutation() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let sessionID = UUID()
        let recorder = CleanupRecorder(metadataByID: [sessionID: makeMetadata(id: sessionID)])
        let service = makeService(window: window, recorder: recorder)

        let first = try await responseObject(service.execute(args: cleanupArgs([sessionID])))
        let retry = try await responseObject(service.execute(args: cleanupArgs([sessionID])))

        XCTAssertEqual(first["deleted_count"]?.intValue, 1)
        XCTAssertEqual(first["deleted_sessions"]?.arrayValue?.first?.objectValue?["durable"]?.boolValue, true)
        XCTAssertEqual(retry["status"]?.stringValue, "completed")
        XCTAssertEqual(retry["deleted_count"]?.intValue, 0)
        XCTAssertEqual(retry["skipped_sessions"]?.arrayValue?.first?.objectValue?["reason"]?.stringValue, "already_absent")
        XCTAssertEqual(recorder.persistedDeleteIDs, [sessionID])
        XCTAssertEqual(recorder.persistedFinalizeIDs, [sessionID])
    }

    func testOpenTabPathUsesSingleDeleteAuthorityWithoutFallbackDeleteOrFinalize() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)
        let sessionID = UUID()
        let session = await window.agentModeViewModel.ensureSessionReady(tabID: tabID)
        session.isMCPOriginated = true
        session.runState = .completed
        _ = window.agentModeViewModel.test_installPersistentSessionBinding(
            sessionID: sessionID,
            on: session,
            updateWorkspaceMetadata: true
        )
        let recorder = CleanupRecorder()
        let service = makeService(window: window, recorder: recorder)

        let reply = try await responseObject(service.execute(args: cleanupArgs([sessionID])))

        XCTAssertEqual(reply["deleted_count"]?.intValue, 1)
        XCTAssertEqual(recorder.openDeleteTabIDs, [tabID])
        XCTAssertEqual(recorder.openDeleteWorkspaceIDs, [workspace.id])
        XCTAssertEqual(recorder.persistedDeleteIDs, [])
        XCTAssertEqual(recorder.persistedFinalizeIDs, [])
        XCTAssertEqual(recorder.metadataLookupIDs, [])
    }

    func testOpenDeleteFailureReportsPartialMutationAndRetryConverges() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)
        let sessionID = UUID()
        let session = await window.agentModeViewModel.ensureSessionReady(tabID: tabID)
        session.isMCPOriginated = true
        session.runState = .completed
        _ = window.agentModeViewModel.test_installPersistentSessionBinding(
            sessionID: sessionID,
            on: session,
            updateWorkspaceMetadata: true
        )
        let recorder = CleanupRecorder()
        var attempts = 0
        let service = makeService(
            window: window,
            recorder: recorder,
            deleteOpenSession: { _, tabID, workspace in
                attempts += 1
                recorder.openDeleteTabIDs.append(tabID)
                recorder.openDeleteWorkspaceIDs.append(workspace.id)
                if attempts == 1 {
                    throw CleanupResolutionTestError.persistedDeleteFailed
                }
            }
        )

        let first = try await responseObject(service.execute(args: cleanupArgs([sessionID])))
        let retry = try await responseObject(service.execute(args: cleanupArgs([sessionID])))

        XCTAssertEqual(first["status"]?.stringValue, "partial")
        XCTAssertEqual(stringArray(first["retry_session_ids"]), [sessionID.uuidString])
        let partial = try XCTUnwrap(first["skipped_sessions"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(partial["reason"]?.stringValue, "delete_partially_completed")
        XCTAssertEqual(partial["durable"]?.boolValue, false)
        XCTAssertEqual(partial["local_cleanup_completed"]?.boolValue, true)
        XCTAssertTrue(partial["message"]?.stringValue?.contains("persisted delete failed") == true)
        XCTAssertEqual(retry["status"]?.stringValue, "completed")
        XCTAssertEqual(retry["deleted_count"]?.intValue, 1)
        XCTAssertEqual(recorder.openDeleteTabIDs, [tabID, tabID])
        XCTAssertEqual(recorder.persistedDeleteIDs, [])
        XCTAssertEqual(recorder.persistedFinalizeIDs, [])
    }

    func testWorkspaceDriftFallsBackToPersistedDeletePinnedToCapturedWorkspace() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let capturedWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let tabID = try XCTUnwrap(capturedWorkspace.activeComposeTabID)
        let sessionID = UUID()
        XCTAssertTrue(window.workspaceManager.compareAndSetActiveAgentSessionID(
            expected: nil,
            replacement: sessionID,
            forTabID: tabID,
            inWorkspaceID: capturedWorkspace.id
        ))
        let driftWorkspace = window.workspaceManager.createWorkspace(
            name: "Cleanup Drift \(UUID().uuidString.prefix(8))",
            repoPaths: [FileManager.default.currentDirectoryPath],
            ephemeral: true
        )
        let recorder = CleanupRecorder(metadataByID: [
            sessionID: makeMetadata(id: sessionID, composeTabID: tabID)
        ])
        let service = makeService(
            window: window,
            recorder: recorder,
            loadPersistedMetadata: { sessionID, _ in
                recorder.metadataLookupIDs.append(sessionID)
                await window.workspaceManager.switchWorkspace(
                    to: driftWorkspace,
                    saveState: false,
                    reason: "agentManageCleanupWorkspaceDriftTest"
                )
                return recorder.metadataByID[sessionID]
            }
        )

        let reply = try await responseObject(service.execute(args: cleanupArgs([sessionID])))

        XCTAssertEqual(reply["deleted_count"]?.intValue, 1)
        XCTAssertEqual(window.workspaceManager.activeWorkspace?.id, driftWorkspace.id)
        XCTAssertEqual(recorder.openDeleteTabIDs, [])
        XCTAssertEqual(recorder.persistedDeleteIDs, [sessionID])
        XCTAssertEqual(recorder.persistedDeleteWorkspaceIDs, [capturedWorkspace.id])
        XCTAssertEqual(recorder.persistedFinalizeIDs, [sessionID])
        XCTAssertEqual(recorder.persistedFinalizeWorkspaceIDs, [capturedWorkspace.id])
    }

    private func makeWindow() async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        let workspace = window.workspaceManager.createWorkspace(
            name: "Cleanup Sessions \(UUID().uuidString.prefix(8))",
            repoPaths: [FileManager.default.currentDirectoryPath],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "agentManageCleanupSessionsTests"
        )
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        return window
    }

    private func makeService(
        window: WindowState,
        recorder: CleanupRecorder,
        loadPersistedMetadata: (@MainActor (UUID, WorkspaceModel) async throws -> AgentSessionMeta?)? = nil,
        deleteOpenSession: (@MainActor (AgentModeViewModel, UUID, WorkspaceModel) async throws -> Void)? = nil,
        deletePersistedSession: (@MainActor (UUID, WorkspaceModel) async throws -> Void)? = nil,
        checkCancellation: @escaping @MainActor () throws -> Void = {}
    ) -> AgentManageMCPToolService {
        makeService(
            window: window,
            cleanupDependencies: AgentManageMCPToolService.CleanupDependencies(
                loadPersistedMetadata: { sessionID, workspace in
                    if let loadPersistedMetadata {
                        return try await loadPersistedMetadata(sessionID, workspace)
                    }
                    recorder.metadataLookupIDs.append(sessionID)
                    return recorder.metadataByID[sessionID]
                },
                deleteOpenSession: { viewModel, tabID, workspace in
                    if let deleteOpenSession {
                        try await deleteOpenSession(viewModel, tabID, workspace)
                    } else {
                        recorder.openDeleteTabIDs.append(tabID)
                        recorder.openDeleteWorkspaceIDs.append(workspace.id)
                    }
                },
                deletePersistedSession: { sessionID, workspace in
                    if let deletePersistedSession {
                        try await deletePersistedSession(sessionID, workspace)
                    } else {
                        recorder.persistedDeleteIDs.append(sessionID)
                        recorder.persistedDeleteWorkspaceIDs.append(workspace.id)
                        recorder.metadataByID.removeValue(forKey: sessionID)
                    }
                },
                finalizePersistedReferences: { _, sessionID, workspaceID in
                    recorder.persistedFinalizeIDs.append(sessionID)
                    recorder.persistedFinalizeWorkspaceIDs.append(workspaceID)
                    return 0
                },
                checkCancellation: checkCancellation
            )
        )
    }

    private func makeService(
        window: WindowState,
        cleanupDependencies: AgentManageMCPToolService.CleanupDependencies
    ) -> AgentManageMCPToolService {
        AgentManageMCPToolService(
            toolName: MCPWindowToolName.agentManage,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: "cleanup-sessions-regression",
                    windowID: window.windowID
                )
            },
            requireTargetWindow: { window },
            resolveSpawnSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in },
            cleanupDependencies: cleanupDependencies
        )
    }

    private func cleanupArgs(_ sessionIDs: [UUID]) -> [String: Value] {
        [
            "op": .string("cleanup_sessions"),
            "session_ids": .array(sessionIDs.map { .string($0.uuidString) })
        ]
    }

    private func makeMetadata(
        id: UUID,
        composeTabID: UUID? = nil,
        isMCPOriginated: Bool = true,
        runState: AgentSessionRunState = .completed
    ) -> AgentSessionMeta {
        AgentSessionMeta(
            id: id,
            composeTabID: composeTabID,
            name: "Session \(id.uuidString.prefix(8))",
            lastModified: Date(timeIntervalSinceReferenceDate: 1),
            itemCount: 0,
            agentKind: AgentProviderKind.codexExec.rawValue,
            agentModel: "codex",
            lastRunState: runState.rawValue,
            parentSessionID: nil,
            isMCPOriginated: isMCPOriginated,
            worktreeBindingSummaries: [],
            activeWorktreeMergeSummaries: []
        )
    }

    private func responseObject(_ value: Value) throws -> [String: Value] {
        try XCTUnwrap(value.objectValue)
    }

    private func stringArray(_ value: Value?) -> [String] {
        value?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

private enum CleanupResolutionTestError: LocalizedError {
    case lookupFailed
    case persistedDeleteFailed

    var errorDescription: String? {
        switch self {
        case .lookupFailed: "lookup failed"
        case .persistedDeleteFailed: "persisted delete failed"
        }
    }
}

@MainActor
private final class CleanupRecorder {
    var metadataByID: [UUID: AgentSessionMeta]
    var metadataLookupIDs: [UUID] = []
    var openDeleteTabIDs: [UUID] = []
    var openDeleteWorkspaceIDs: [UUID] = []
    var persistedDeleteIDs: [UUID] = []
    var persistedDeleteWorkspaceIDs: [UUID] = []
    var persistedFinalizeIDs: [UUID] = []
    var persistedFinalizeWorkspaceIDs: [UUID] = []

    init(metadataByID: [UUID: AgentSessionMeta] = [:]) {
        self.metadataByID = metadataByID
    }
}
