import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptInstrumentation
import XCTest

@MainActor
final class AgentSessionSaveRuntimeTests: XCTestCase {
    func testConfiguredFirstSaveAcknowledgesExactPayloadWithoutPresentation() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let prepared = try AgentSessionSaveRuntime.prepare(payload: f.payload, session: f.session, creation: .configured(f.creation))
        XCTAssertFalse(f.session.qualifiedRestorationReadiness.isAuthoritative)
        let service = AgentSessionDataService()
        var phases: [AgentSessionRequiredSavePhase] = []
        let result = try await f.commit(prepared, phases: { phases.append($0) }) { payload, workspace, count in
            try await service.saveAgentSession(payload, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: count)
        }
        guard case let .committed(receipt) = result else { return XCTFail("Configured payload must earn acknowledgment") }
        let saved = try await service.loadAgentSession(from: XCTUnwrap(receipt.payload.fileURL))
        XCTAssertEqual(saved.id, f.creation.bindingToken.bindingIdentity.sessionID)
        XCTAssertEqual(saved.workspaceID, f.workspace.id)
        XCTAssertEqual(saved.transcript, f.payload.transcript)
        XCTAssertEqual(saved.effectiveItemCount, 2)
        XCTAssertNotNil(saved.lastUserMessageAt)
        XCTAssertTrue(receipt.acknowledgedCreation)
        XCTAssertEqual(receipt.binding, f.session.currentRestorationBindingToken)
        XCTAssertTrue(f.session.qualifiedRestorationReadiness.isAuthoritative)
        XCTAssertFalse(f.session.isDirty)
        XCTAssertEqual(phases, [.writeMayHaveCommitted, .writeReturned], "Terminal owner, not storage, publishes the final durable phase")
    }

    func testHeldFirstSaveRejectsConfigurationAndIncarnationChangesAfterDiskWrite() async throws {
        enum Change: CaseIterable { case configuration, name, rebind, request }
        for change in Change.allCases {
            let f = try Fixture()
            defer { f.cleanUp() }
            let prepared = try AgentSessionSaveRuntime.prepare(payload: f.payload, session: f.session, creation: .configured(f.creation))
            let entered = expectation(description: "Durable effect before \(change)")
            var release: CheckedContinuation<Void, Never>?
            var currentName = f.payload.name
            var savedURL: URL?
            let service = AgentSessionDataService()
            let work = Task { @MainActor in
                try await f.commit(prepared, name: { currentName }) { payload, workspace, count in
                    savedURL = try await service.saveAgentSession(payload, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: count)
                    await withCheckedContinuation { release = $0
                        entered.fulfill()
                    }
                    return try XCTUnwrap(savedURL)
                }
            }
            await fulfillment(of: [entered], timeout: 5)
            switch change {
            case .configuration: f.session.autoEditEnabled.toggle()
            case .name: currentName = "Renamed during save"
            case .rebind:
                let original = f.session.currentRestorationBindingToken
                f.session.installPersistentSessionBinding(.init(tabID: f.session.tabID, sessionID: f.payload.id, workspaceID: f.workspace.id))
                XCTAssertNotEqual(f.session.currentRestorationBindingToken, original, "Same UUID must still exercise a new binding incarnation")
            case .request: f.session.saveRequestGeneration &+= 1
            }
            release?.resume()
            let result = try await work.value
            guard case .deferred = result else { return XCTFail("\(change) must refuse stale acknowledgment") }
            let saved = try await service.loadAgentSession(from: XCTUnwrap(savedURL))
            XCTAssertEqual(saved.name, f.payload.name)
            XCTAssertTrue(f.session.isDirty)
            XCTAssertFalse(f.session.qualifiedRestorationReadiness.isAuthoritative)
        }
    }

    func testCancellationAfterWritePreservesCreatingAndDirtyState() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let prepared = try AgentSessionSaveRuntime.prepare(payload: f.payload, session: f.session, creation: .configured(f.creation))
        let service = AgentSessionDataService()
        var savedURL: URL?
        var phases: [AgentSessionRequiredSavePhase] = []
        do {
            _ = try await f.commit(prepared, phases: { phases.append($0) }) { payload, workspace, count in
                savedURL = try await service.saveAgentSession(payload, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: count)
                throw CancellationError()
            }
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {}
        XCTAssertNotNil(savedURL)
        XCTAssertEqual(phases, [.writeMayHaveCommitted])
        XCTAssertTrue(f.session.isDirty)
        XCTAssertFalse(f.session.qualifiedRestorationReadiness.isAuthoritative)
        XCTAssertNotNil(f.session.captureCreationRetryHandle())
    }

    func testSaveQueueCoalescesAndDrainsIndependentlyOfPresentation() async {
        let store = AgentSessionRuntimeStore()
        let scope = store.makeScope()
        let queue = scope.saveQueue
        let id = UUID()
        let other = UUID()
        XCTAssertTrue(queue.begin(sessionID: id))
        XCTAssertFalse(queue.begin(sessionID: id))
        XCTAssertFalse(queue.begin(sessionID: id))
        XCTAssertTrue(queue.begin(sessionID: other), "Different session IDs do not serialize unrelated effects")
        let waiting = expectation(description: "Waiter started")
        var completed = false
        let waiter = Task { @MainActor in
            waiting.fulfill()
            await queue.waitForInFlightSave(sessionID: id)
            completed = true
        }
        await fulfillment(of: [waiting], timeout: 5)
        waiter.cancel()
        XCTAssertFalse(completed, "Cancellation is not a writer drain receipt")
        XCTAssertFalse(queue.finish(sessionID: other))
        XCTAssertTrue(queue.finish(sessionID: id), "All overlapping saves coalesce into one follow-up")
        await waiter.value
        XCTAssertTrue(completed)
        XCTAssertTrue(queue.inFlightSessionIDs.isEmpty)
        XCTAssertTrue(queue.begin(sessionID: id))
        XCTAssertFalse(queue.finish(sessionID: id), "Follow-up request was consumed by completion")
        XCTAssertTrue(queue.begin(sessionID: id))
        XCTAssertFalse(queue.begin(sessionID: id))
        queue.discardFollowUp(sessionID: id)
        XCTAssertTrue(queue.inFlightSessionIDs.contains(id), "Deletion withdraws retry intent, not in-flight effects")
        XCTAssertFalse(queue.finish(sessionID: id))
    }

    @MainActor
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("M9SaveRuntime-\(UUID())")
        let store = AgentSessionRuntimeStore()
        let scope: AgentSessionRuntimeStore.Scope
        let workspace: WorkspaceModel
        let session = AgentTabSession(tabID: UUID())
        let creation: AgentSessionCreationHandle
        let writer: AgentSessionRuntimeStore.Writer
        let payload: AgentSession
        let token: AgentSessionSaveCommitToken

        init() throws {
            workspace = WorkspaceModel(name: "Runtime save", repoPaths: [], customStoragePath: root)
            scope = store.makeScope()
            let claim = AgentSessionCreationClaim(workspaceID: workspace.id)
            session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: claim.sessionID, workspaceID: workspace.id))
            creation = try XCTUnwrap(session.acceptFreshCreation(claim, workspaceID: workspace.id))
            scope.replaceSessions([session.tabID: session])
            guard case let .unique(resolved) = store.resolveWriter(workspaceID: workspace.id, sessionID: claim.sessionID) else {
                throw NSError(domain: "M9SaveRuntime", code: 1)
            }
            writer = resolved
            session.runState = .completed
            session.setItemsSilently([
                AgentChatItem(kind: .user, text: "Persist this exact request", sequenceIndex: 0),
                AgentChatItem(kind: .assistant, text: "And its response", sequenceIndex: 1)
            ], reason: .persistedSessionHydration)
            session.nextSequenceIndex = 2
            let preparation = AgentSessionTranscriptRefreshRuntime.prepareSave(
                for: session, isActiveOwnedForSave: false,
                perfRecorder: NoopAgentModePerfRecorder(), diagnosticPresentationID: "none"
            )
            payload = AgentSessionPayloadBuilder.makePayload(
                session: session, sessionID: claim.sessionID, workspaceID: workspace.id, name: "Runtime save",
                snapshot: preparation.snapshot
            )
            token = .init(
                tabID: session.tabID,
                sessionIdentity: ObjectIdentifier(session),
                workspaceID: workspace.id,
                workspaceDirectoryPath: WorkspaceSessionSidecarMigration.workspaceDirectory(
                    for: workspace, root: AgentSessionDataService.defaultWorkspaceRootURL()
                ).standardizedFileURL.path,
                binding: resolved.binding,
                bindingTransitionGeneration: session.bindingTransitionGeneration,
                sourceItemsRevision: session.sourceItemsRevision,
                persistenceMutationGeneration: session.persistenceMutationGeneration,
                saveRequestGeneration: session.saveRequestGeneration
            )
        }

        func commit(
            _ prepared: AgentSessionSaveRuntime.PreparedWrite,
            name: (() -> String)? = nil,
            phases: ((AgentSessionRequiredSavePhase) -> Void)? = nil,
            saver: AgentSessionPayloadWriter.Saver
        ) async throws -> AgentSessionSaveRuntime.Outcome {
            try await AgentSessionSaveRuntime.commit(
                prepared, workspace: workspace, canonicalItemCount: payload.effectiveItemCount, writer: writer, token: token,
                storageIsCurrent: { true }, currentName: name ?? { payload.name }, observingPhase: phases, saver: saver
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
