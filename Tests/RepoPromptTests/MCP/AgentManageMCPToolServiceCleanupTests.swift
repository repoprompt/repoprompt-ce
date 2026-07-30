import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class AgentManageMCPToolServiceCleanupTests: XCTestCase {
    func testCleanupSessionsIncludesPersistedProviderCleanupOutcome() async throws {
        let previousAction = GlobalSettingsStore.shared.providerConversationCleanupAction()
        GlobalSettingsStore.shared.setProviderConversationCleanupAction(.archive, commit: false)
        defer { GlobalSettingsStore.shared.setProviderConversationCleanupAction(previousAction, commit: false) }

        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let recorder = AgentManageCleanupRecorder(outcome: .succeeded(message: "archived from MCP cleanup"))
        window.agentModeViewModel.test_setPersistedProviderConversationCleaner { handle, action in
            recorder.record(handle: handle, action: action)
            return recorder.outcome
        }

        let sessionID = UUID()
        let session = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            name: "Cleanup Session",
            savedAt: Date(timeIntervalSinceReferenceDate: 298),
            itemCount: 0,
            agentKind: AgentProviderKind.codexExec.rawValue,
            lastRunState: AgentSessionRunState.completed.rawValue,
            autoEditEnabled: true,
            codexConversationID: "mcp-cleanup-thread",
            codexRolloutPath: "/tmp/mcp-cleanup-rollout.jsonl",
            isMCPOriginated: true
        )
        try await AgentSessionDataService.shared.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )

        let service = makeService(window: window, cleanupDependencies: .live)
        let result = try await service.execute(args: [
            "op": .string("cleanup_sessions"),
            "session_ids": .array([.string(sessionID.uuidString)])
        ])

        let object = try XCTUnwrap(result.objectValue)
        XCTAssertEqual(object["status"]?.stringValue, "completed")
        XCTAssertEqual(object["deleted_count"]?.intValue, 1)
        let deletedSessions = try XCTUnwrap(object["deleted_sessions"]?.arrayValue)
        let deleted = try XCTUnwrap(deletedSessions.first?.objectValue)
        let cleanup = try XCTUnwrap(deleted["provider_cleanup"]?.objectValue)
        XCTAssertEqual(cleanup["status"]?.stringValue, "succeeded")
        XCTAssertEqual(cleanup["message"]?.stringValue, "archived from MCP cleanup")

        let calls = recorder.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.handle.conversationID, "mcp-cleanup-thread")
        XCTAssertEqual(calls.first?.handle.rolloutPath, "/tmp/mcp-cleanup-rollout.jsonl")
        XCTAssertEqual(calls.first?.action, .archive)
    }

    func testCleanupSessionsReportsUnsupportedProviderCleanupForNonCodexPersistedSession() async throws {
        let previousAction = GlobalSettingsStore.shared.providerConversationCleanupAction()
        GlobalSettingsStore.shared.setProviderConversationCleanupAction(.archive, commit: false)
        defer { GlobalSettingsStore.shared.setProviderConversationCleanupAction(previousAction, commit: false) }

        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let recorder = AgentManageCleanupRecorder(outcome: .succeeded(message: "should not run"))
        window.agentModeViewModel.test_setPersistedProviderConversationCleaner { handle, action in
            recorder.record(handle: handle, action: action)
            return recorder.outcome
        }

        let sessionID = UUID()
        let session = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            name: "Unsupported Cleanup Session",
            savedAt: Date(timeIntervalSinceReferenceDate: 299),
            itemCount: 0,
            agentKind: AgentProviderKind.openCode.rawValue,
            lastRunState: AgentSessionRunState.completed.rawValue,
            providerSessionID: "open-code-session",
            autoEditEnabled: true,
            isMCPOriginated: true
        )
        try await AgentSessionDataService.shared.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )

        let service = makeService(window: window, cleanupDependencies: .live)
        let result = try await service.execute(args: [
            "op": .string("cleanup_sessions"),
            "session_ids": .array([.string(sessionID.uuidString)])
        ])

        let object = try XCTUnwrap(result.objectValue)
        XCTAssertEqual(object["status"]?.stringValue, "completed")
        XCTAssertEqual(object["deleted_count"]?.intValue, 1)
        let deletedSessions = try XCTUnwrap(object["deleted_sessions"]?.arrayValue)
        let deleted = try XCTUnwrap(deletedSessions.first?.objectValue)
        let cleanup = try XCTUnwrap(deleted["provider_cleanup"]?.objectValue)
        XCTAssertEqual(cleanup["status"]?.stringValue, "unsupported")
        XCTAssertEqual(
            cleanup["message"]?.stringValue,
            "ACP provider openCode has session metadata but no verified conversation cleanup API."
        )
        XCTAssertTrue(recorder.calls().isEmpty)
    }

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
                if cancellationChecks == 4 {
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

    func testPersistedSessionLoadFailurePreventsDeletionAndProviderCleanup() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let sessionID = UUID()
        let recorder = CleanupRecorder(metadataByID: [sessionID: makeMetadata(id: sessionID)])
        let cleanupRecorder = AgentManageCleanupRecorder(outcome: .succeeded())
        window.agentModeViewModel.test_setPersistedProviderConversationCleaner { handle, action in
            cleanupRecorder.record(handle: handle, action: action)
            return cleanupRecorder.outcome
        }
        let service = makeService(
            window: window,
            recorder: recorder,
            loadPersistedSession: { _, _ in
                throw CleanupResolutionTestError.lookupFailed
            }
        )

        let reply = try await responseObject(service.execute(args: cleanupArgs([sessionID])))

        XCTAssertEqual(reply["status"]?.stringValue, "partial")
        XCTAssertEqual(reply["deleted_count"]?.intValue, 0)
        XCTAssertEqual(recorder.persistedDeleteIDs, [])
        XCTAssertEqual(recorder.persistedFinalizeIDs, [])
        XCTAssertTrue(cleanupRecorder.calls().isEmpty)
        let failure = try XCTUnwrap(reply["skipped_sessions"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(failure["reason"]?.stringValue, "resolution_failed")
        XCTAssertTrue(failure["message"]?.stringValue?.contains("lookup failed") == true)
    }

    func testPersistedSessionLoadCancellationStopsBeforeMutation() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let sessionID = UUID()
        let recorder = CleanupRecorder(metadataByID: [sessionID: makeMetadata(id: sessionID)])
        let cleanupRecorder = AgentManageCleanupRecorder(outcome: .succeeded())
        window.agentModeViewModel.test_setPersistedProviderConversationCleaner { handle, action in
            cleanupRecorder.record(handle: handle, action: action)
            return cleanupRecorder.outcome
        }
        let service = makeService(
            window: window,
            recorder: recorder,
            loadPersistedSession: { _, _ in
                throw CancellationError()
            }
        )

        let reply = try await responseObject(service.execute(args: cleanupArgs([sessionID])))

        XCTAssertEqual(reply["status"]?.stringValue, "cancelled")
        XCTAssertEqual(reply["processed_count"]?.intValue, 0)
        XCTAssertEqual(reply["unprocessed_count"]?.intValue, 1)
        XCTAssertEqual(recorder.persistedDeleteIDs, [])
        XCTAssertEqual(recorder.persistedFinalizeIDs, [])
        XCTAssertTrue(cleanupRecorder.calls().isEmpty)
        XCTAssertEqual(
            reply["unprocessed_sessions"]?.arrayValue?.first?.objectValue?["reason"]?.stringValue,
            "cancelled_before_mutation"
        )
    }

    func testPersistedCleanupDeletesDurablyBeforeProviderCleanup() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let sessionID = UUID()
        let recorder = CleanupRecorder(metadataByID: [sessionID: makeMetadata(id: sessionID)])
        let events = CleanupEventRecorder()
        let persistedSession = makePersistedCleanupSession(id: sessionID, workspaceID: workspace.id)
        window.agentModeViewModel.test_setPersistedProviderConversationCleaner { _, _ in
            events.record("cleanup")
            return .succeeded(message: "provider cleanup after delete")
        }
        let service = makeService(
            window: window,
            recorder: recorder,
            loadPersistedSession: { _, _ in
                events.record("load")
                return persistedSession
            },
            deletePersistedSession: { id, workspace in
                events.record("delete")
                recorder.persistedDeleteIDs.append(id)
                recorder.persistedDeleteWorkspaceIDs.append(workspace.id)
            }
        )

        let reply = try await responseObject(service.execute(args: cleanupArgs([sessionID])))

        XCTAssertEqual(events.values(), ["load", "delete", "cleanup"])
        XCTAssertEqual(reply["deleted_count"]?.intValue, 1)
        let cleanup = reply["deleted_sessions"]?.arrayValue?.first?.objectValue?["provider_cleanup"]?.objectValue
        XCTAssertEqual(cleanup?["status"]?.stringValue, "succeeded")
        XCTAssertEqual(cleanup?["message"]?.stringValue, "provider cleanup after delete")
    }

    func testFinalProviderCleanupCancellationKeepsCommittedDeletionOutOfRetryLedger() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let sessionID = UUID()
        let recorder = CleanupRecorder(metadataByID: [sessionID: makeMetadata(id: sessionID)])
        let cleanupRecorder = AgentManageCleanupRecorder(
            outcome: .cancelled(message: "provider cleanup cancelled")
        )
        window.agentModeViewModel.test_setPersistedProviderConversationCleaner { handle, action in
            cleanupRecorder.record(handle: handle, action: action)
            return cleanupRecorder.outcome
        }
        let persistedSession = makePersistedCleanupSession(id: sessionID, workspaceID: workspace.id)
        let service = makeService(
            window: window,
            recorder: recorder,
            loadPersistedSession: { _, _ in persistedSession }
        )

        let reply = try await responseObject(service.execute(args: cleanupArgs([sessionID])))

        XCTAssertEqual(reply["status"]?.stringValue, "cancelled")
        XCTAssertEqual(reply["cancelled"]?.boolValue, true)
        XCTAssertEqual(reply["processed_count"]?.intValue, 1)
        XCTAssertEqual(reply["deleted_count"]?.intValue, 1)
        XCTAssertEqual(reply["skipped_count"]?.intValue, 0)
        XCTAssertEqual(reply["unprocessed_count"]?.intValue, 0)
        XCTAssertEqual(stringArray(reply["retry_session_ids"]), [])
        XCTAssertEqual(recorder.persistedDeleteIDs, [sessionID])
        let deleted = try XCTUnwrap(reply["deleted_sessions"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(deleted["durable"]?.boolValue, true)
        XCTAssertEqual(deleted["provider_cleanup"]?.objectValue?["status"]?.stringValue, "cancelled")
        XCTAssertEqual(deleted["provider_cleanup"]?.objectValue?["message"]?.stringValue, "provider cleanup cancelled")
    }

    func testProviderCleanupCancellationStopsLargerBatchAfterCommittedDeletion() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let sessionIDs = [UUID(), UUID(), UUID()]
        let recorder = CleanupRecorder(metadataByID: Dictionary(
            uniqueKeysWithValues: sessionIDs.map { ($0, makeMetadata(id: $0)) }
        ))
        let cleanupRecorder = AgentManageCleanupRecorder(outcome: .cancelled())
        window.agentModeViewModel.test_setPersistedProviderConversationCleaner { handle, action in
            cleanupRecorder.record(handle: handle, action: action)
            return cleanupRecorder.outcome
        }
        let persistedSessions = Dictionary(
            uniqueKeysWithValues: sessionIDs.map {
                ($0, makePersistedCleanupSession(id: $0, workspaceID: workspace.id))
            }
        )
        let service = makeService(
            window: window,
            recorder: recorder,
            loadPersistedSession: { sessionID, _ in persistedSessions[sessionID] }
        )

        let reply = try await responseObject(service.execute(args: cleanupArgs(sessionIDs)))

        XCTAssertEqual(reply["status"]?.stringValue, "cancelled")
        XCTAssertEqual(reply["processed_count"]?.intValue, 1)
        XCTAssertEqual(reply["deleted_count"]?.intValue, 1)
        XCTAssertEqual(reply["skipped_count"]?.intValue, 0)
        XCTAssertEqual(reply["unprocessed_count"]?.intValue, 2)
        XCTAssertEqual(recorder.persistedDeleteIDs, [sessionIDs[0]])
        XCTAssertEqual(recorder.persistedFinalizeIDs, [sessionIDs[0]])
        XCTAssertEqual(stringArray(reply["retry_session_ids"]), Array(sessionIDs.dropFirst()).map(\.uuidString))
        XCTAssertEqual(cleanupRecorder.calls().count, 1)
        XCTAssertEqual(
            reply["unprocessed_sessions"]?.arrayValue?.compactMap { $0.objectValue?["reason"]?.stringValue },
            ["cancelled_after_committed_deletion", "cancelled_after_committed_deletion"]
        )
    }

    func testPersistedDeleteFailureDoesNotRunProviderCleanup() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let sessionID = UUID()
        let recorder = CleanupRecorder(metadataByID: [sessionID: makeMetadata(id: sessionID)])
        let events = CleanupEventRecorder()
        let persistedSession = makePersistedCleanupSession(id: sessionID, workspaceID: workspace.id)
        window.agentModeViewModel.test_setPersistedProviderConversationCleaner { _, _ in
            events.record("cleanup")
            return .succeeded()
        }
        let service = makeService(
            window: window,
            recorder: recorder,
            loadPersistedSession: { _, _ in
                events.record("load")
                return persistedSession
            },
            deletePersistedSession: { _, _ in
                events.record("delete")
                throw CleanupResolutionTestError.persistedDeleteFailed
            }
        )

        let reply = try await responseObject(service.execute(args: cleanupArgs([sessionID])))

        XCTAssertEqual(events.values(), ["load", "delete"])
        XCTAssertEqual(reply["deleted_count"]?.intValue, 0)
        XCTAssertEqual(recorder.persistedFinalizeIDs, [])
        let failure = try XCTUnwrap(reply["skipped_sessions"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(failure["reason"]?.stringValue, "delete_failed")
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

    func testLiveOpenTabDeleteFinalizesWorkspaceSessionReferences() async throws {
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
        XCTAssertEqual(
            window.workspaceManager.activeAgentSessionID(
                forTabID: tabID,
                inWorkspaceID: workspace.id
            ),
            sessionID
        )

        let service = makeService(window: window, cleanupDependencies: .live)
        let reply = try await responseObject(service.execute(args: cleanupArgs([sessionID])))

        XCTAssertEqual(reply["status"]?.stringValue, "completed")
        XCTAssertEqual(reply["deleted_count"]?.intValue, 1)
        XCTAssertNil(window.agentModeViewModel.sessionIndex[sessionID])
        XCTAssertFalse(workspace.composeTabs.contains { $0.activeAgentSessionID == sessionID })
        XCTAssertFalse(workspace.stashedTabs.contains { $0.tab.activeAgentSessionID == sessionID })
    }

    func testOpenDeleteFailurePreservesLocalStateAndRetryConverges() async throws {
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
        XCTAssertEqual(partial["reason"]?.stringValue, "delete_failed")
        XCTAssertEqual(partial["durable"]?.boolValue, false)
        XCTAssertEqual(partial["local_cleanup_completed"]?.boolValue, false)
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
        loadPersistedSession: (@MainActor (UUID, WorkspaceModel) async throws -> AgentSession?)? = nil,
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
                loadPersistedSession: { sessionID, workspace in
                    if let loadPersistedSession {
                        return try await loadPersistedSession(sessionID, workspace)
                    }
                    return nil
                },
                deleteOpenSession: { viewModel, tabID, workspace in
                    if let deleteOpenSession {
                        try await deleteOpenSession(viewModel, tabID, workspace)
                    } else {
                        recorder.openDeleteTabIDs.append(tabID)
                        recorder.openDeleteWorkspaceIDs.append(workspace.id)
                    }
                    return nil
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

    private func makePersistedCleanupSession(id: UUID, workspaceID: UUID) -> AgentSession {
        AgentSession(
            id: id,
            workspaceID: workspaceID,
            name: "Persisted cleanup",
            savedAt: Date(timeIntervalSinceReferenceDate: 2),
            itemCount: 0,
            agentKind: AgentProviderKind.codexExec.rawValue,
            lastRunState: AgentSessionRunState.completed.rawValue,
            providerCleanupHandle: ProviderConversationCleanupHandle(
                provider: AgentProviderKind.codexExec.rawValue,
                conversationID: "persisted-cleanup-thread"
            ),
            autoEditEnabled: true,
            isMCPOriginated: true
        )
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

private final class CleanupEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func record(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func values() -> [String] {
        lock.lock()
        let values = events
        lock.unlock()
        return values
    }
}

private final class AgentManageCleanupRecorder: @unchecked Sendable {
    struct Call {
        let handle: ProviderConversationCleanupHandle
        let action: ProviderConversationCleanupAction
    }

    let outcome: ProviderConversationCleanupOutcome
    private let lock = NSLock()
    private var recordedCalls: [Call] = []

    init(outcome: ProviderConversationCleanupOutcome) {
        self.outcome = outcome
    }

    func record(handle: ProviderConversationCleanupHandle, action: ProviderConversationCleanupAction) {
        lock.lock()
        recordedCalls.append(.init(handle: handle, action: action))
        lock.unlock()
    }

    func calls() -> [Call] {
        lock.lock()
        let calls = recordedCalls
        lock.unlock()
        return calls
    }
}
