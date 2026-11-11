import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class AgentSessionPersistenceRuntimeTests: XCTestCase {
    func testRunHookPersistsWithoutPresentationAndRetainsScopeUntilDebounceSettles() async throws {
        var fixture: Fixture? = try Fixture()
        let root = try XCTUnwrap(fixture?.root)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try XCTUnwrap(fixture?.scope.persistence)
        let session = try XCTUnwrap(fixture?.session)
        let workspace = try XCTUnwrap(fixture?.placement.workspace)
        weak let scope = fixture?.scope
        let entered = expectation(description: "Debounce admitted")
        var release: CheckedContinuation<Void, Never>?
        runtime.debounce = {
            await withCheckedContinuation { release = $0
                entered.fulfill()
            }
        }
        runtime.makeRunHooks().scheduleSave(session)
        let task = try XCTUnwrap(session.saveDebounceTask)
        await fulfillment(of: [entered], timeout: 5)
        fixture = nil
        XCTAssertNotNil(scope, "An admitted debounce retains its exact scope, not a presentation")
        XCTAssertNil(runtime.presentation)
        release?.resume()
        await task.value
        XCTAssertFalse(session.isDirty)
        XCTAssertNil(scope, "The completed debounce releases its exact scope")
        let saved = try await AgentSessionDataService.shared.loadAgentSession(id: XCTUnwrap(session.activeAgentSessionID), for: workspace)
        XCTAssertEqual(saved?.effectiveItemCount, 2)
        XCTAssertEqual(saved?.name, "Headless persistence")
    }

    func testDebounceRequalifiesSameObjectButCannotPersistRecycledTab() async throws {
        for replaceObject in [false, true] {
            let f = try Fixture()
            defer { f.cleanUp() }
            let entered = expectation(description: "Original debounce admitted")
            let rearmed = replaceObject ? nil : expectation(description: "Requalified debounce admitted")
            var releases: [CheckedContinuation<Void, Never>] = []
            var writes = 0
            f.scope.persistence.debounce = {
                await withCheckedContinuation { continuation in
                    releases.append(continuation)
                    if releases.count == 1 { entered.fulfill() } else { rearmed?.fulfill() }
                }
            }
            f.scope.persistence.saver = { payload, workspace, count in
                writes += 1
                return try await AgentSessionDataService.shared.saveAgentSession(payload, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: count)
            }
            f.scope.persistence.scheduleSave(for: f.session)
            let originalTask = try XCTUnwrap(f.session.saveDebounceTask)
            await fulfillment(of: [entered], timeout: 5)
            if replaceObject {
                let successor = AgentTabSession(tabID: f.session.tabID)
                successor.isDirty = true
                f.scope.replaceSessions([successor.tabID: successor])
            } else {
                let prior = f.session.currentRestorationBindingToken
                try f.session.installPersistentSessionBinding(.init(tabID: f.session.tabID, sessionID: XCTUnwrap(f.session.activeAgentSessionID), workspaceID: f.placement.workspace.id))
                XCTAssertNotEqual(prior, f.session.currentRestorationBindingToken)
                f.session.recordRestorationAuthoritative(.persistedPayloadApplied)
            }
            releases[0].resume()
            await originalTask.value
            XCTAssertEqual(writes, 0, "The old timer cannot write a different incarnation")
            if replaceObject {
                XCTAssertEqual(releases.count, 1)
                XCTAssertNil(f.scope.sessions[f.session.tabID]?.saveDebounceTask)
                XCTAssertTrue(try XCTUnwrap(f.scope.sessions[f.session.tabID]).isDirty)
            } else {
                try await fulfillment(of: [XCTUnwrap(rearmed)], timeout: 5)
                let newTask = try XCTUnwrap(f.session.saveDebounceTask)
                releases[1].resume()
                await newTask.value
                XCTAssertEqual(writes, 1)
                XCTAssertFalse(f.session.isDirty, "A transition follow-up must not be lost")
            }
        }
    }

    func testObservedSourceMutationPersistsAndRefreshesWithoutPresentation() async throws {
        var fixture: Fixture? = try Fixture()
        let root = try XCTUnwrap(fixture?.root)
        defer { try? FileManager.default.removeItem(at: root) }
        weak let owner = fixture?.scope
        let session = try XCTUnwrap(fixture?.session)
        let workspace = try XCTUnwrap(fixture?.placement.workspace)
        try XCTUnwrap(owner).observation.install(on: session)
        try XCTUnwrap(owner).persistence.debounce = {}
        session.hasLoadedPersistedState = true
        session.appendItem(AgentChatItem(kind: .assistant, text: "Observed without a VM", sequenceIndex: 2))
        let refresh = try XCTUnwrap(session.derivedTranscriptRefreshTask)
        let save = try XCTUnwrap(session.saveDebounceTask)
        XCTAssertNil(owner?.persistence.presentation)
        fixture = nil
        XCTAssertNotNil(owner, "Pending source-derived work retains the exact runtime scope")
        await refresh.value
        await save.value
        XCTAssertNil(owner, "Completed source work does not retain a hidden owner")
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(session.derivedTranscriptSyncState, AgentSessionTranscriptRuntime.syncState(for: session, projectionProtection: AgentSessionTranscriptRefreshRuntime.transcriptProjectionProtection(for: session)))
        let saved = try await AgentSessionDataService.shared.loadAgentSession(id: XCTUnwrap(session.activeAgentSessionID), for: workspace)
        XCTAssertEqual(saved?.effectiveItemCount, 3)
    }

    func testRuntimeConstructionCoalescesSourceChangesAndFencesRecycledObjects() async throws {
        let scope = AgentSessionRuntimeStore().makeScope()
        let session = scope.makeSession(tabID: UUID())
        scope.replaceSessions([session.tabID: session])
        session.appendItem(.init(kind: .user, text: "First", sequenceIndex: 0))
        let generation = session.derivedTranscriptRefreshGeneration
        let refresh = try XCTUnwrap(session.derivedTranscriptRefreshTask)
        session.appendItem(.init(kind: .assistant, text: "Second", sequenceIndex: 1))
        XCTAssertEqual(session.derivedTranscriptRefreshGeneration, generation)
        await refresh.value
        XCTAssertEqual(session.derivedTranscriptSyncState, AgentSessionTranscriptRuntime.syncState(for: session, projectionProtection: AgentSessionTranscriptRefreshRuntime.transcriptProjectionProtection(for: session)))
        session.appendItem(.init(kind: .assistant, text: "Old object", sequenceIndex: 2))
        let staleRefresh = try XCTUnwrap(session.derivedTranscriptRefreshTask)
        let replacement = scope.makeSession(tabID: session.tabID)
        scope.replaceSessions([replacement.tabID: replacement])
        await staleRefresh.value
        XCTAssertNil(session.derivedTranscriptRefreshTask, "A refused scheduled refresh cannot wedge later readmission")
        XCTAssertTrue(replacement.items.isEmpty)
        XCTAssertNil(replacement.derivedTranscriptRefreshTask)
        let priorSummary = session.pendingSourceItemsMutationSummary
        session.appendItem(.init(kind: .assistant, text: "Retired source", sequenceIndex: 3))
        XCTAssertEqual(session.pendingSourceItemsMutationSummary, priorSummary)
        XCTAssertNil(session.derivedTranscriptRefreshTask)
        XCTAssertNil(session.saveDebounceTask)
        XCTAssertNil(replacement.saveDebounceTask)
        XCTAssertTrue(replacement.items.isEmpty)
        scope.replaceSessions([session.tabID: session])
        session.appendItem(.init(kind: .assistant, text: "Readmitted", sequenceIndex: 4))
        let readmittedRefresh = try XCTUnwrap(session.derivedTranscriptRefreshTask)
        await readmittedRefresh.value
        XCTAssertEqual(session.derivedTranscriptSyncState, AgentSessionTranscriptRuntime.syncState(for: session, projectionProtection: AgentSessionTranscriptRefreshRuntime.transcriptProjectionProtection(for: session)))
    }

    func testObservedRunStateHonorsRestorationAndCanPersistDuringOriginatingDrain() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        f.scope.observation.install(on: f.session)
        f.session.hasLoadedPersistedState = true
        f.session.isDirty = false
        f.scope.persistence.composition?.isRestoringConfiguration = { true }
        f.session.runState = .running
        XCTAssertFalse(f.session.isDirty)
        XCTAssertNil(f.session.saveDebounceTask)
        f.scope.persistence.composition?.isRestoringConfiguration = { false }
        f.scope.persistence.debounce = {}
        f.scope.beginRetirement()
        f.session.runState = .completed
        let save = try XCTUnwrap(f.session.saveDebounceTask)
        XCTAssertTrue(f.session.isDirty)
        await save.value
        XCTAssertFalse(f.session.isDirty, "Retirement must retain the originating final writer")
        // Persistence keeps its completed debounce handle. Discard that settled handle so
        // the following assertion witnesses new scheduling, not historical task storage.
        f.session.saveDebounceTask = nil
        XCTAssertTrue(f.scope.releaseWriterClaimsAfterDrain())
        let generation = f.session.saveRequestGeneration
        f.session.appendItem(.init(kind: .assistant, text: "Released source", sequenceIndex: 2))
        f.session.runState = .running
        XCTAssertEqual(f.session.saveRequestGeneration, generation, "Configured persistence cannot be rearmed by a released object")
        XCTAssertNil(f.session.saveDebounceTask)
        XCTAssertNil(f.session.derivedTranscriptRefreshTask)
    }

    func testMissingCompositionCannotAcknowledgeRequiredPersistence() async {
        let scope = AgentSessionRuntimeStore().makeScope()
        let session = AgentTabSession(tabID: UUID())
        session.isDirty = true
        scope.replaceSessions([session.tabID: session])
        scope.persistence.scheduleSave(for: session)
        XCTAssertNil(session.saveDebounceTask)
        let result = await scope.persistence.flushSaveRequired(for: session.tabID, workspaceID: UUID())
        guard case .failure = result else { return XCTFail("Missing runtime composition is not a durable acknowledgment") }
        XCTAssertTrue(session.isDirty)
    }

    func testConfiguredCreationAndRequiredFlushUseSameRuntimeTransaction() async throws {
        let f = try Fixture(fresh: true)
        defer { f.cleanUp() }
        let handle = try XCTUnwrap(f.creation)
        let prematureFlush = await f.scope.persistence.flushSaveRequired(for: f.session.tabID, workspaceID: f.placement.workspace.id)
        guard case .failure = prematureFlush else { return XCTFail("Required flush cannot qualify an unconfigured creation") }
        XCTAssertFalse(f.session.qualifiedRestorationReadiness.isAuthoritative)
        var phases: [AgentSessionRequiredSavePhase] = []
        let result = await f.scope.persistence.saveSessionCore(for: f.session.tabID, creationSave: .configured(handle), observingPhase: { phases.append($0) })
        guard case let .durablySaved(binding) = result else { return XCTFail("Configured first save must acknowledge its exact incarnation") }
        XCTAssertEqual(binding, f.session.currentRestorationBindingToken)
        XCTAssertTrue(f.session.qualifiedRestorationReadiness.isAuthoritative)
        XCTAssertFalse(f.session.isDirty)
        XCTAssertEqual(phases, [.writeMayHaveCommitted, .writeReturned, .durablySaved(binding)])
        f.session.isDirty = true
        let flush = await f.scope.persistence.flushSaveRequired(for: f.session.tabID, workspaceID: f.placement.workspace.id)
        try flush.get()
        XCTAssertFalse(f.session.isDirty)
    }

    func testExactRequiredSaveCannotAcknowledgeSuppressedDirtyState() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        guard case let .unique(writer) = try f.scope.resolveWriter(
            workspaceID: f.placement.workspace.id, sessionID: XCTUnwrap(f.session.activeAgentSessionID)
        ) else { return XCTFail("The restored fixture must have one canonical writer") }
        var writes = 0
        f.scope.persistence.saver = { payload, workspace, count in
            writes += 1
            return try await AgentSessionDataService.shared.saveAgentSession(payload, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: count)
        }
        try await f.scope.persistence.flushSaveRequired(writer: writer).get()
        XCTAssertEqual(writes, 1)
        XCTAssertFalse(f.session.isDirty)

        f.placement.suppressed = true
        var phases: [AgentSessionRequiredSavePhase] = []
        try await f.scope.persistence.flushSaveRequired(writer: writer, observingSavePhase: { phases.append($0) }).get()
        XCTAssertEqual(writes, 1, "An already clean, restored writer needs no additional write")
        XCTAssertEqual(phases, [.beforeWrite])

        f.session.isDirty = true
        phases.removeAll()
        let skipped = await f.scope.persistence.flushSaveRequired(writer: writer, observingSavePhase: { phases.append($0) })
        guard case let .failure(failure) = skipped else { return XCTFail("Suppression is not a required-save acknowledgment") }
        XCTAssertEqual(failure.message, "Required persistence was skipped without a clean, restored session.")
        XCTAssertEqual(writes, 1)
        XCTAssertTrue(f.session.isDirty, "A refusal preserves the outstanding save obligation")
        XCTAssertEqual(phases, [.beforeWrite], "A skipped write must not publish a durable-save phase")

        f.placement.suppressed = false
        f.scope.beginRetirement()
        try await f.scope.persistence.flushSaveRequired(writer: writer).get()
        XCTAssertEqual(writes, 2, "The originating writer may still commit its final retirement save")
        XCTAssertFalse(f.session.isDirty)
    }

    func testBoundTabRequiredSaveKeepsItsWriterAcrossQueueWait() async throws {
        for reacquire in [false, true] {
            let f = try Fixture()
            defer { f.cleanUp() }
            let sessionID = try XCTUnwrap(f.session.activeAgentSessionID)
            let binding = f.session.currentRestorationBindingToken
            var writes = 0
            f.scope.persistence.saver = { payload, workspace, count in
                writes += 1
                return try await AgentSessionDataService.shared.saveAgentSession(payload, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: count)
            }
            let debounce = TestReleaseFence(name: "ordinary save retained through tab required-save wait")
            f.scope.persistence.debounce = {
                await debounce.enterAndWait()
                try Task.checkCancellation()
            }
            f.scope.persistence.scheduleSave(for: f.session)
            let pendingTask = try XCTUnwrap(f.session.saveDebounceTask)
            let pendingID = try XCTUnwrap(f.session.saveDebounceRequestID)
            XCTAssertTrue(f.scope.persistence.queue.begin(sessionID: sessionID))
            var ownsQueueSlot = true
            let entered = expectation(description: "Tab required save entered its queue wait")
            let task = Task {
                await f.scope.persistence.flushSaveRequired(for: f.session.tabID, workspaceID: f.placement.workspace.id, observingSavePhase: { phase in
                    if phase == .beforeWrite { entered.fulfill() }
                })
            }
            defer {
                if ownsQueueSlot { _ = f.scope.persistence.queue.finish(sessionID: sessionID) }
                task.cancel()
                pendingTask.cancel()
                debounce.release()
            }
            await fulfillment(of: [entered], timeout: 5)
            if reacquire {
                f.scope.replaceSessions([:])
                f.scope.replaceSessions([f.session.tabID: f.session])
                XCTAssertEqual(f.session.currentRestorationBindingToken, binding, "Binding checks alone cannot detect this ABA")
            }
            _ = f.scope.persistence.queue.finish(sessionID: sessionID)
            ownsQueueSlot = false
            let result = await task.value
            if reacquire {
                guard case let .failure(failure) = result else { return XCTFail("A queued tab save must not adopt a reacquired writer") }
                XCTAssertEqual(failure.message, "The live session owner changed during required persistence.")
                XCTAssertEqual(writes, 0)
                XCTAssertTrue(f.session.isDirty)
                XCTAssertEqual(f.session.saveDebounceRequestID, pendingID)
                XCTAssertFalse(pendingTask.isCancelled, "Refusal must preserve the independent ordinary save")
            } else {
                try result.get()
                XCTAssertEqual(writes, 1)
                XCTAssertFalse(f.session.isDirty)
                XCTAssertNil(f.session.saveDebounceTask)
                XCTAssertTrue(pendingTask.isCancelled)
            }
            debounce.release()
            await pendingTask.value
            XCTAssertEqual(writes, 1, "Either the exact flush or the retained ordinary save writes, not both")
            XCTAssertFalse(f.session.isDirty)
        }
    }

    func testBoundTabRequiredSaveRefusesObserverReacquisitionAndUnownedCleanClaims() async throws {
        enum Refusal: CaseIterable { case observerReacquire, conflicting, unscoped, wrongWorkspace, suppressedDirty }
        for refusal in Refusal.allCases {
            let f = try Fixture()
            defer { f.cleanUp() }
            var writes = 0
            f.scope.persistence.saver = { [root = f.root] _, _, _ in writes += 1
                return root
            }
            f.session.isDirty = refusal == .suppressedDirty
            let otherScope = f.store.makeScope()
            if refusal == .conflicting {
                let other = AgentTabSession(tabID: UUID())
                try other.installPersistentSessionBinding(.init(tabID: other.tabID, sessionID: XCTUnwrap(f.session.activeAgentSessionID), workspaceID: f.placement.workspace.id))
                otherScope.replaceSessions([other.tabID: other])
            } else if refusal == .unscoped {
                try f.session.installPersistentSessionBinding(.init(tabID: f.session.tabID, sessionID: XCTUnwrap(f.session.activeAgentSessionID)))
                f.session.recordRestorationAuthoritative(.persistedPayloadApplied)
            }
            f.placement.suppressed = refusal == .suppressedDirty
            var phases: [AgentSessionRequiredSavePhase] = []
            let result = await f.scope.persistence.flushSaveRequired(
                for: f.session.tabID, workspaceID: refusal == .wrongWorkspace ? UUID() : f.placement.workspace.id,
                observingSavePhase: { phase in
                    phases.append(phase)
                    if refusal == .observerReacquire, phase == .beforeWrite {
                        f.scope.replaceSessions([:])
                        f.scope.replaceSessions([f.session.tabID: f.session])
                    }
                }
            )
            withExtendedLifetime(otherScope) {}
            guard case let .failure(failure) = result else { return XCTFail("Unowned or suppressed persistence must refuse: \(refusal)") }
            let expectedMessage = switch refusal {
            case .observerReacquire: "The originating writer changed before required persistence."
            case .conflicting, .unscoped, .wrongWorkspace: "The session does not have a unique runtime writer for this workspace."
            case .suppressedDirty: "Required persistence was skipped without a clean, restored session."
            }
            XCTAssertEqual(failure.message, expectedMessage)
            XCTAssertEqual(writes, 0)
            XCTAssertEqual(phases, [.beforeWrite])
            XCTAssertEqual(f.session.isDirty, refusal == .suppressedDirty)
        }
    }

    func testTabRequiredSavePreservesCleanAndBlankNoOpPolicy() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        var writes = 0
        f.scope.persistence.saver = { [root = f.root] _, _, _ in writes += 1
            return root
        }
        f.session.isDirty = false
        f.placement.suppressed = true
        try await f.scope.persistence.flushSaveRequired(for: f.session.tabID, workspaceID: f.placement.workspace.id).get()
        f.placement.suppressed = false
        let blank = AgentTabSession(tabID: UUID())
        f.scope.replaceSessions([blank.tabID: blank])
        try await f.scope.persistence.flushSaveRequired(for: blank.tabID, workspaceID: f.placement.workspace.id).get()
        try await f.scope.persistence.flushSaveRequired(for: UUID(), workspaceID: f.placement.workspace.id).get()
        XCTAssertNil(blank.activeAgentSessionID, "Closing a blank tab must not allocate a persistent identity")
        XCTAssertEqual(writes, 0)
        let insertedBinding = await f.scope.persistence.flushSaveRequired(for: blank.tabID, workspaceID: f.placement.workspace.id, observingSavePhase: { phase in
            if phase == .beforeWrite {
                blank.installPersistentSessionBinding(.init(tabID: blank.tabID, sessionID: UUID(), workspaceID: f.placement.workspace.id))
                blank.recordRestorationAuthoritative(.persistedPayloadApplied)
            }
        })
        guard case .failure = insertedBinding else { return XCTFail("An observer cannot promote an unbound ingress into an uncaptured writer") }
        XCTAssertEqual(writes, 0)
    }

    func testHeldRequiredSaveDoesNotAcknowledgeMovedStorageOrReboundIncarnation() async throws {
        for rebind in [false, true] {
            let f = try Fixture()
            defer { f.cleanUp() }
            let entered = expectation(description: "Disk write completed")
            var release: CheckedContinuation<Void, Never>?
            var savedURL: URL?
            f.scope.persistence.saver = { payload, workspace, count in
                savedURL = try await AgentSessionDataService.shared.saveAgentSession(payload, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: count)
                await withCheckedContinuation { release = $0
                    entered.fulfill()
                }
                return try XCTUnwrap(savedURL)
            }
            let work = Task { await f.scope.persistence.flushSaveRequired(for: f.session.tabID, workspaceID: f.placement.workspace.id) }
            await fulfillment(of: [entered], timeout: 5)
            if rebind {
                try f.session.installPersistentSessionBinding(.init(tabID: f.session.tabID, sessionID: XCTUnwrap(f.session.activeAgentSessionID), workspaceID: f.placement.workspace.id))
            } else {
                f.placement.workspace.customStoragePath = f.root.appendingPathComponent("moved")
            }
            release?.resume()
            guard case .failure = await work.value else { return XCTFail("A stale disk write is not a required-save receipt") }
            f.session.saveDebounceTask?.cancel()
            XCTAssertNotNil(savedURL, "Partial disk effect must remain observable")
            XCTAssertTrue(f.session.isDirty)
        }
    }

    func testAdmissionRefusalLeavesDirtyWithoutStartingIO() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        var writes = 0
        f.scope.persistence.saver = { _, _, _ in writes += 1
            return f.root
        }
        f.placement.refusal = "provider transition"
        let result = await f.scope.persistence.flushSaveRequired(for: f.session.tabID, workspaceID: f.placement.workspace.id)
        guard case let .failure(error) = result else { return XCTFail("An existing authority's refusal must defer persistence") }
        XCTAssertEqual(error.message, "provider transition")
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(f.session.isDirty)
        f.placement.refusal = nil
        f.scope.persistence.saver = { payload, workspace, count in
            try await AgentSessionDataService.shared.saveAgentSession(payload, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: count)
        }
        try await f.scope.persistence.flushSaveRequired(for: f.session.tabID, workspaceID: f.placement.workspace.id).get()
        XCTAssertFalse(f.session.isDirty)
    }

    @MainActor
    private final class Placement {
        var workspace: WorkspaceModel
        var refusal: String?
        var suppressed = false
        init(_ workspace: WorkspaceModel) {
            self.workspace = workspace
        }
    }

    @MainActor
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("M9Persistence-\(UUID())")
        let store = AgentSessionRuntimeStore()
        let scope: AgentSessionRuntimeStore.Scope
        let session = AgentTabSession(tabID: UUID())
        let placement: Placement
        let creation: AgentSessionCreationHandle?

        init(fresh: Bool = false) throws {
            let workspace = WorkspaceModel(name: "Headless persistence", repoPaths: [], customStoragePath: root)
            placement = Placement(workspace)
            scope = store.makeScope()
            let claim = AgentSessionCreationClaim(workspaceID: workspace.id)
            session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: claim.sessionID, workspaceID: workspace.id))
            if fresh { creation = try XCTUnwrap(session.acceptFreshCreation(claim, workspaceID: workspace.id)) }
            else { creation = nil
                session.recordRestorationAuthoritative(.persistedPayloadApplied)
            }
            session.runState = .completed
            session.setItemsSilently([
                AgentChatItem(kind: .user, text: "Persist me without a window", sequenceIndex: 0),
                AgentChatItem(kind: .assistant, text: "A real saved response", sequenceIndex: 1)
            ], reason: .persistedSessionHydration)
            session.nextSequenceIndex = 2
            session.isDirty = true
            scope.replaceSessions([session.tabID: session])
            let placement = placement
            let storage = AgentSessionStorageInputs(
                workspaceID: workspace.id,
                workspaceWithID: { $0 == placement.workspace.id ? placement.workspace : nil },
                displayName: { _ in "Headless persistence" }, isSuppressed: { placement.suppressed },
                attachmentWorkspaceDirectory: { FileManager.default.temporaryDirectory }
            )
            scope.persistence.composition = storage.persistenceComposition(scope: scope, saveAdmission: { _ in placement.refusal })
        }

        func cleanUp() {
            session.saveDebounceTask?.cancel()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
