import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentSavedSessionTargetLoaderTests: XCTestCase {
    func testExactDiskLookupNeedsNoWindowAndDoesNotChangeTheVisibleCarrier() async throws {
        let service = AgentSessionDataService()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let savedID = UUID()
        let tab = ComposeTabState(activeAgentSessionID: UUID())
        var workspace = WorkspaceModel(name: "Saved target", repoPaths: [], customStoragePath: directory)
        workspace.composeTabs = [tab]
        workspace.stashedTabs = []
        let file = try await service.saveAgentSession(AgentSession(
            id: savedID, workspaceID: workspace.id, composeTabID: tab.id,
            name: "Historical target", itemCount: 0
        ), for: workspace)
        let before = try Data(contentsOf: file)
        var reads = 0
        let result = await AgentSavedSessionTargetLoader.load(
            sessionID: savedID, workspaces: [workspace],
            readRecord: { id, candidate in
                reads += 1
                return try await service.metadataRecordForSessionID(id, for: candidate)
            },
            currentMetadata: { _ in nil }, currentWorkspace: { _ in workspace }, isAvailable: { true }, isCurrent: { _ in true }
        )
        let target = try result.get()
        XCTAssertEqual(target.entry.id, savedID)
        XCTAssertEqual(target.entry.tabID, tab.id)
        XCTAssertEqual(target.tab.activeAgentSessionID, tab.activeAgentSessionID)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(try Data(contentsOf: file), before, "Metadata lookup must not rewrite the payload.")
    }

    func testReadResamplesLiveEvidenceAndAuthoritativeRuntimeDoesNotNeedDisk() async throws {
        let id = UUID(), tab = ComposeTabState()
        var workspace = WorkspaceModel(name: "Live", repoPaths: [])
        workspace.composeTabs = [tab]
        workspace.stashedTabs = []
        var live = AgentSavedSessionTargetLoader.LiveMetadata(entry: entry(id, tab.id, name: "Before"), isAuthoritative: false)
        var reads = 0
        let result = await AgentSavedSessionTargetLoader.load(
            sessionID: id, workspaces: [workspace],
            readRecord: { _, _ in
                reads += 1
                live = .init(entry: self.entry(id, tab.id, name: "After"), isAuthoritative: true)
                return nil
            },
            currentMetadata: { _ in live }, currentWorkspace: { _ in workspace }, isAvailable: { true }, isCurrent: { $0.entry.name == "After" }
        )
        XCTAssertEqual(try result.get().entry.name, "After")
        let second = await AgentSavedSessionTargetLoader.load(
            sessionID: id, workspaces: [workspace],
            readRecord: { _, _ in reads += 1
                throw CocoaError(.fileReadNoPermission)
            },
            currentMetadata: { _ in live }, currentWorkspace: { _ in workspace }, isAvailable: { true }, isCurrent: { _ in true }
        )
        XCTAssertEqual(try second.get().entry.name, "After")
        XCTAssertEqual(reads, 1, "Known live state remains usable when persistence is unavailable.")
    }

    func testDeletionAndEarlierMatchInvalidationDuringReadsFailClosed() async {
        let id = UUID(), tab = ComposeTabState()
        var first = WorkspaceModel(name: "First", repoPaths: [])
        first.composeTabs = [tab]
        first.stashedTabs = []
        let later = WorkspaceModel(name: "Later", repoPaths: [])
        var available = true
        let deleted = await AgentSavedSessionTargetLoader.load(
            sessionID: id, workspaces: [first],
            readRecord: { _, _ in available = false
                return nil
            },
            currentMetadata: { _ in nil }, currentWorkspace: { _ in first }, isAvailable: { available }, isCurrent: { _ in true }
        )
        assertFailure(deleted, .changed)

        var firstIsCurrent = true
        let moved = await AgentSavedSessionTargetLoader.load(
            sessionID: id, workspaces: [first, later],
            readRecord: { _, _ in firstIsCurrent = false
                return nil
            },
            currentMetadata: { workspaceID in
                workspaceID == first.id ? .init(entry: self.entry(id, tab.id), isAuthoritative: true) : nil
            },
            currentWorkspace: { $0 == first.id ? first : later },
            isAvailable: { true }, isCurrent: { _ in firstIsCurrent }
        )
        assertFailure(moved, .changed)
    }

    func testDistinctMissingAmbiguousAndUnreadableOutcomes() async {
        let id = UUID(), tab = ComposeTabState()
        var workspace = WorkspaceModel(name: "Outcomes", repoPaths: [])
        workspace.composeTabs = [tab]
        workspace.stashedTabs = []
        let missing = await AgentSavedSessionTargetLoader.load(
            sessionID: id, workspaces: [workspace], readRecord: { _, _ in nil },
            currentMetadata: { _ in nil }, currentWorkspace: { _ in workspace }, isAvailable: { true }, isCurrent: { _ in true }
        )
        assertFailure(missing, .missing)
        let unreadable = await AgentSavedSessionTargetLoader.load(
            sessionID: id, workspaces: [workspace], readRecord: { _, _ in throw CocoaError(.fileReadCorruptFile) },
            currentMetadata: { _ in nil }, currentWorkspace: { _ in workspace }, isAvailable: { true }, isCurrent: { _ in true }
        )
        assertFailure(unreadable, .unreadable)
        workspace.composeTabs.append(tab)
        let ambiguous = await AgentSavedSessionTargetLoader.load(
            sessionID: id, workspaces: [workspace], readRecord: { _, _ in XCTFail("Live target does not need IO")
                return nil
            },
            currentMetadata: { _ in .init(entry: self.entry(id, tab.id), isAuthoritative: true) },
            currentWorkspace: { _ in workspace }, isAvailable: { true }, isCurrent: { _ in true }
        )
        assertFailure(ambiguous, .ambiguous)
    }

    func testFreshStashedPlacementIsUsedAfterRead() async throws {
        let id = UUID(), tab = ComposeTabState()
        let stash = StashedTab(tab: tab)
        var workspace = WorkspaceModel(name: "Moving", repoPaths: [], composeTabs: [tab])
        let result = await AgentSavedSessionTargetLoader.load(
            sessionID: id, workspaces: [workspace],
            readRecord: { _, _ in
                workspace.composeTabs = []
                workspace.stashedTabs = [stash]
                return nil
            },
            currentMetadata: { _ in .init(entry: self.entry(id, tab.id), isAuthoritative: false) },
            currentWorkspace: { _ in workspace }, isAvailable: { true }, isCurrent: { _ in true }
        )
        XCTAssertEqual(try result.get().stashedTabID, stash.id)
        XCTAssertEqual(try result.get().workspace.stashedTabs, [stash])
    }

    func testDiskIdentityMismatchAndTwoWorkspaceMatchesAreAmbiguous() async throws {
        let service = AgentSessionDataService()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(), tab = ComposeTabState()
        let workspace = WorkspaceModel(name: "Original", repoPaths: [], customStoragePath: directory, composeTabs: [tab])
        _ = try await service.saveAgentSession(AgentSession(
            id: id, workspaceID: workspace.id, composeTabID: tab.id, name: "Disk", itemCount: 0
        ), for: workspace)
        let loadedRecord = try await service.metadataRecordForSessionID(id, for: workspace)
        let record = try XCTUnwrap(loadedRecord)
        let other = WorkspaceModel(name: "Other", repoPaths: [], composeTabs: [tab])
        for (requestedID, candidate) in [(UUID(), workspace), (id, other)] {
            let result = await AgentSavedSessionTargetLoader.load(
                sessionID: requestedID, workspaces: [candidate], readRecord: { _, _ in record },
                currentMetadata: { _ in nil }, currentWorkspace: { _ in candidate },
                isAvailable: { true }, isCurrent: { _ in true }
            )
            assertFailure(result, .ambiguous)
        }
        let duplicated = await AgentSavedSessionTargetLoader.load(
            sessionID: id, workspaces: [workspace, other], readRecord: { _, _ in nil },
            currentMetadata: { _ in .init(entry: self.entry(id, tab.id), isAuthoritative: true) },
            currentWorkspace: { $0 == workspace.id ? workspace : other }, isAvailable: { true }, isCurrent: { _ in true }
        )
        assertFailure(duplicated, .ambiguous)
    }

    func testCancellationDuringReadIsChangedNotUnreadable() async {
        let workspace = WorkspaceModel(name: "Cancelled", repoPaths: [])
        let result = await AgentSavedSessionTargetLoader.load(
            sessionID: UUID(), workspaces: [workspace], readRecord: { _, _ in throw CancellationError() },
            currentMetadata: { _ in nil }, currentWorkspace: { _ in workspace },
            isAvailable: { true }, isCurrent: { _ in true }
        )
        assertFailure(result, .changed)
    }

    private func entry(_ id: UUID, _ tabID: UUID, name: String = "Target") -> AgentSessionIndexEntry {
        AgentSessionIndexEntry(
            id: id, tabID: tabID, name: name, savedAt: .distantPast,
            itemCount: 0, autoEditEnabled: false, hasUnknownConversationContent: false,
            isMCPOriginated: false, worktreeBindingSummaries: [], activeWorktreeMergeSummaries: []
        )
    }

    private func assertFailure(
        _ result: Result<AgentSavedSessionTargetLoader.Target, AgentSavedSessionTargetLoader.Failure>,
        _ expected: AgentSavedSessionTargetLoader.Failure,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case let .failure(actual) = result else { return XCTFail("Expected \(expected)", file: file, line: line) }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}

@MainActor
final class AgentSavedSessionRuntimeLoadingTests: XCTestCase {
    func testSavedHistoricalPayloadLoadsIntoCanonicalWriterWithoutWindowComposition() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        try await f.save()
        let carrier = f.placement.workspace.composeTabs
        let result = try await f.load().get()
        XCTAssertEqual(result.source, .savedPayload)
        XCTAssertTrue(result.writer.scope === f.scope)
        XCTAssertTrue(result.writer.session.permitsBoundOperationAndSave)
        XCTAssertEqual(result.writer.session.items.map(\.text), ["Saved request", "Saved response"])
        XCTAssertEqual(f.placement.workspace.composeTabs, carrier, "Historical lookup must not select or rebind the visible carrier")
        XCTAssertNil(f.scope.execution, "Loading does not install a fake execution service")
        XCTAssertNil(f.scope.linkExecution)
        XCTAssertNil(f.scope.persistence.presentation)
        XCTAssertNil(f.scope.attachments.invalidatePreviews)
        XCTAssertNil(result.writer.session.activeRunOwnership)
        let second = try await f.load().get()
        XCTAssertEqual(second.source, .existingWriter)
        XCTAssertTrue(second.writer.session === result.writer.session)
        XCTAssertEqual(f.payloadReads, 1)
    }

    func testExistingForeignScopeIsReturnedWithoutComposingOrPopulatingColdScope() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        try await f.save()
        let original = try await f.load().get()
        let cold = f.store.makeScope()
        let reused = try await f.load(into: cold).get()
        XCTAssertEqual(reused.source, .existingWriter)
        XCTAssertTrue(reused.writer.scope === original.writer.scope)
        XCTAssertTrue(cold.sessions.isEmpty)
        XCTAssertNil(cold.persistence.composition)
        XCTAssertEqual(f.payloadReads, 1)
    }

    func testConflictingAndUnreadyWritersDoNotFallBackToSavedPayload() async {
        let f = Fixture()
        defer { f.cleanUp() }
        let first = f.scope.makeSession(tabID: f.tab.id)
        first.installPersistentSessionBinding(.init(tabID: first.tabID, sessionID: f.sessionID, workspaceID: f.placement.workspace.id))
        f.scope.replaceSessions([first.tabID: first])
        await assertFailure(f.load(), reason: .commandRejected(.restorationUnavailable), effects: .none)
        let otherScope = f.store.makeScope()
        let other = otherScope.makeSession(tabID: UUID())
        XCTAssertEqual(otherScope.bindingRejection(f.sessionID, on: other), .conflictingWriter)
        // Deliberate legacy corruption after proving normal binding admission refuses it.
        other.installPersistentSessionBinding(.init(tabID: other.tabID, sessionID: f.sessionID, workspaceID: f.placement.workspace.id))
        otherScope.replaceSessions([other.tabID: other])
        await assertFailure(f.load(), reason: .lookup(.ambiguous), effects: .none)
        XCTAssertEqual(f.payloadReads, 0)
        XCTAssertTrue(f.scope.sessions[first.tabID] === first)
        otherScope.replaceSessions([:])
    }

    func testPayloadFailureReleasesOnlyItsLoadingClaimAndExplicitRetryCanRestore() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        try await f.save()
        f.beforePayload = { _ in throw CocoaError(.fileReadCorruptFile) }
        await assertFailure(f.load(), reason: .lookup(.unreadable), effects: .loadingClaimReleased)
        XCTAssertTrue(f.scope.sessions.isEmpty)
        guard case .unavailable(.absent) = f.store.resolveWriter(sessionID: f.sessionID) else { return XCTFail("Failed clean load must not strand a writer") }
        f.beforePayload = nil
        let retried = try await f.load().get()
        XCTAssertTrue(retried.writer.session.permitsBoundOperationAndSave)
    }

    func testReacquiredLoadingClaimCannotBeHydratedOrReleasedByItsOldRead() async throws {
        for failsRead in [false, true] {
            let f = Fixture()
            defer { f.cleanUp() }
            try await f.save()
            var retained: AgentTabSession?
            f.beforePayload = { _ in
                let session = try XCTUnwrap(f.scope.sessions[f.tab.id])
                let transition = session.persistentBindingTransitionToken()
                f.scope.replaceSessions([:])
                f.scope.replaceSessions([session.tabID: session])
                XCTAssertTrue(transition.matches(session))
                retained = session
                if failsRead { throw CocoaError(.fileReadCorruptFile) }
            }
            await assertFailure(
                f.load(), reason: .lookup(failsRead ? .unreadable : .changed), effects: .loadingClaimRetained
            )
            let session = try XCTUnwrap(retained)
            XCTAssertTrue(f.scope.sessions[f.tab.id] === session)
            XCTAssertTrue(session.items.isEmpty)
            XCTAssertFalse(session.hasLoadedPersistedState)
            XCTAssertFalse(session.qualifiedRestorationReadiness.isAuthoritative)
        }
    }

    func testRevocationAndStorageMoveAfterReadCannotPublishReadiness() async throws {
        for moveStorage in [false, true] {
            let f = Fixture()
            defer { f.cleanUp() }
            try await f.save()
            f.afterPayload = {
                if moveStorage { f.placement.workspace.customStoragePath = f.root.appendingPathComponent("moved") }
                else { f.authorized = false }
            }
            await assertFailure(f.load(), reason: .lookup(.changed), effects: .loadingClaimReleased)
            XCTAssertTrue(f.scope.sessions.isEmpty)
        }
    }

    func testLocalMutationDuringPayloadReadIsRetainedWithHonestFailureEffect() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        try await f.save()
        f.afterPayload = {
            guard let session = f.scope.sessions[f.tab.id] else { return XCTFail("Loading claim missing") }
            session.setItemsSilently([.init(kind: .user, text: "New local input", sequenceIndex: 0)], reason: .persistedSessionHydration)
            session.isDirty = true
        }
        await assertFailure(f.load(), reason: .lookup(.changed), effects: .loadingClaimRetained)
        let retained = try XCTUnwrap(f.scope.sessions[f.tab.id])
        XCTAssertEqual(retained.items.map(\.text), ["New local input"])
        XCTAssertFalse(retained.permitsBoundOperationAndSave)
        XCTAssertTrue(retained.isDirty)
    }

    func testSuppressionAndOccupiedTabHaveNoLoadingSideEffects() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        try await f.save()
        f.placement.suppressed = true
        await assertFailure(f.load(), reason: .suppressed, effects: .none)
        f.placement.suppressed = false
        let draft = f.scope.makeSession(tabID: f.tab.id)
        f.scope.replaceSessions([draft.tabID: draft])
        await assertFailure(f.load(), reason: .occupiedTab, effects: .none)
        XCTAssertEqual(f.payloadReads, 0)
        XCTAssertTrue(f.scope.sessions[draft.tabID] === draft)
    }

    func testRetirementAndReplacementDuringReadCannotPublishOrEvictSuccessor() async throws {
        for replace in [false, true] {
            let f = Fixture()
            defer { f.cleanUp() }
            try await f.save()
            let successor = f.scope.makeSession(tabID: f.tab.id)
            f.afterPayload = {
                if replace { f.scope.replaceSessions([successor.tabID: successor]) }
                else { f.scope.beginRetirement() }
            }
            await assertFailure(f.load(), reason: .lookup(.changed), effects: replace ? .loadingClaimDisplaced : .loadingClaimReleased)
            if replace { XCTAssertTrue(f.scope.sessions[f.tab.id] === successor) }
            else { XCTAssertTrue(f.scope.sessions.isEmpty) }
        }
    }

    func testOldMetadataCannotOverwriteNewPayloadPlacement() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        try await f.save()
        let parent = UUID()
        f.beforePayload = { _ in
            let saved = try await f.service.loadAgentSession(id: f.sessionID, for: f.placement.workspace)
            var payload = try XCTUnwrap(saved)
            payload.organizationalParentID = parent
            _ = try await f.service.saveAgentSession(payload, for: f.placement.workspace)
        }
        let loaded = try await f.load().get()
        XCTAssertEqual(loaded.writer.session.organizationalParentID, parent)
    }

    func testMissingStorageCompositionRefusesBeforePublishingClaim() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        try await f.save()
        f.scope.persistence.composition = nil
        await assertFailure(f.load(), reason: .compositionUnavailable, effects: .none)
        XCTAssertTrue(f.scope.sessions.isEmpty)
        XCTAssertEqual(f.payloadReads, 0)
    }

    func testAttachmentStorageFollowsBoundCatalogRootWithoutPresentation() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        try await f.save()
        let configuration = try XCTUnwrap(f.scope.attachments.configuration)
        let draft = f.scope.makeSession(tabID: UUID())
        XCTAssertNotNil(configuration.location(draft), "An unbound first turn retains its canonical temporary location")
        let session = try await f.load().get().writer.session
        let captured = try XCTUnwrap(configuration.location(session))
        XCTAssertNotNil(captured.retainedRoot)
        let originalLocationIsCurrent = await configuration.locationIsCurrent(captured, session)
        XCTAssertTrue(originalLocationIsCurrent)
        f.placement.workspace.customStoragePath = f.root.appendingPathComponent("moved")
        let movedLocationIsCurrent = await configuration.locationIsCurrent(captured, session)
        XCTAssertFalse(movedLocationIsCurrent)
        f.placement.suppressed = true
        XCTAssertNil(configuration.location(session)?.retainedRoot)
    }

    private func assertFailure(
        _ result: Result<AgentSavedSessionTargetLoader.RuntimeLoad, AgentSavedSessionTargetLoader.RuntimeLoadFailure>,
        reason: AgentSavedSessionTargetLoader.RuntimeLoadFailure.Reason,
        effects: AgentSavedSessionTargetLoader.RuntimeLoadFailure.Effects,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case let .failure(failure) = result else { return XCTFail("Expected refusal", file: file, line: line) }
        XCTAssertEqual(failure.reason, reason, file: file, line: line)
        XCTAssertEqual(failure.effects, effects, file: file, line: line)
    }

    @MainActor
    private final class Placement {
        var workspace: WorkspaceModel
        var suppressed = false
        init(_ workspace: WorkspaceModel) {
            self.workspace = workspace
        }
    }

    @MainActor
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("M93Loading-\(UUID())")
        let sessionID = UUID()
        let tab = ComposeTabState(activeAgentSessionID: UUID())
        let service = AgentSessionDataService()
        let store = AgentSessionRuntimeStore()
        let scope: AgentSessionRuntimeStore.Scope
        let placement: Placement
        let storage: AgentSessionStorageInputs
        var authorized = true
        var payloadReads = 0
        var beforePayload: ((AgentSessionHydrationRequest) async throws -> Void)?
        var afterPayload: (() -> Void)?

        init() {
            var workspace = WorkspaceModel(name: "Canonical catalog", repoPaths: [], customStoragePath: root)
            workspace.composeTabs = [tab]
            workspace.stashedTabs = []
            placement = Placement(workspace)
            scope = store.makeScope()
            let placement = placement
            storage = .init(
                workspaceID: workspace.id,
                workspaceWithID: { $0 == placement.workspace.id ? placement.workspace : nil },
                displayName: { _ in "Saved target" }, isSuppressed: { placement.suppressed },
                attachmentWorkspaceDirectory: { FileManager.default.temporaryDirectory }
            )
            scope.persistence.composition = storage.persistenceComposition(scope: scope)
            scope.attachments.configuration = storage.attachmentConfiguration()
        }

        func save() async throws {
            _ = try await service.saveAgentSession(.init(
                id: sessionID, workspaceID: placement.workspace.id, composeTabID: tab.id, name: "Saved target",
                items: [
                    AgentChatItem(kind: .user, text: "Saved request", sequenceIndex: 0),
                    AgentChatItem(kind: .assistant, text: "Saved response", sequenceIndex: 1)
                ].map { AgentChatItemPersist(from: $0) },
                lastRunState: "completed"
            ), for: placement.workspace)
        }

        func load(into destination: AgentSessionRuntimeStore.Scope? = nil) async -> Result<AgentSavedSessionTargetLoader.RuntimeLoad, AgentSavedSessionTargetLoader.RuntimeLoadFailure> {
            await AgentSavedSessionTargetLoader.loadRuntime(
                sessionID: sessionID, scope: destination ?? scope,
                catalog: .init(
                    workspaces: { [self] in [placement.workspace] }, currentWorkspace: storage.workspaceWithID,
                    currentMetadata: { _, _ in nil }, isCurrent: { [self] target in
                        target.workspace.id == placement.workspace.id && target.tab == placement.workspace.composeTabs.first
                    }
                ), storage: storage,
                selection: { .init(agent: $0.normalizedSelection.agent, modelRaw: $0.normalizedSelection.modelRaw, explicitReasoningEffortRaw: nil) },
                codexPolicy: { _ in .init(options: [], defaultEffort: nil, lastUsed: nil) },
                isStillAuthorized: { [self] in authorized },
                readRecord: { [service] in try await service.metadataRecordForSessionID($0, for: $1) },
                readPayload: { [self] request in
                    payloadReads += 1
                    try await beforePayload?(request)
                    let payload = try await service.preparePersistedHydration(request)
                    afterPayload?()
                    return payload
                }
            )
        }

        func cleanUp() {
            beforePayload = nil
            afterPayload = nil
            for session in scope.sessions.values {
                session.saveDebounceTask?.cancel()
                session.derivedTranscriptRefreshTask?.cancel()
            }
            scope.replaceSessions([:])
            try? FileManager.default.removeItem(at: root)
        }
    }
}
