import Cocoa
import Combine
import RepoPromptAIContracts
@testable import RepoPromptApp
@testable import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import XCTest

@MainActor
final class CommandCenterConversationTests: XCTestCase {
    private func row(_ workspace: UUID = UUID(), session: UUID = UUID(), date: TimeInterval = 0) -> CommandCenterSessionRow {
        .init(
            sessionID: session,
            workspaceID: workspace,
            tabID: UUID(),
            name: "Conversation",
            provider: nil,
            attention: .saved,
            detail: nil,
            provenance: .saved(recordedAt: Date(timeIntervalSince1970: date)),
            activityDate: Date(timeIntervalSince1970: date)
        )
    }

    private func frame(_ row: CommandCenterSessionRow, text: String) -> CommandCenterConversationModel.Snapshot {
        .init(
            windowID: 1,
            workspaceID: row.workspaceID,
            tabID: row.tabID!,
            title: row.name,
            provider: "Fixture",
            runState: "idle",
            rows: [.user(text, sequenceIndex: 0)],
            hasEarlierRows: false,
            hasPendingInteraction: false
        )
    }

    func testDisabledConversationDoesNotLoadOrPublishAndKeepsDraft() async {
        var loads = 0
        let model = CommandCenterConversationModel(isEnabled: { false }, load: { _ in
            loads += 1
            return .unavailable("unexpected")
        })
        model.draft = "unsent"
        model.select(row())
        model.newSession(projectID: UUID())
        model.refresh()
        await Task.yield()
        XCTAssertEqual(loads, 0)
        XCTAssertNil(model.selectedID)
        XCTAssertNil(model.snapshot)
        XCTAssertEqual(model.draft, "unsent")
    }

    func testSelectedConversationAndDraftsAreIndependentOfSourceSelectionChanges() async throws {
        let first = row(), second = row()
        let signal = PassthroughSubject<Void, Never>()
        var currentText = "first frame"
        let model = CommandCenterConversationModel(isEnabled: { true }, load: { [self] selected in
            .ready(.init(isCurrent: { true }, snapshot: { [self] _ in frame(selected, text: currentText) }, changes: signal.eraseToAnyPublisher()))
        })
        defer { model.stop() }
        model.draft = "new session draft"
        model.select(first)
        try await AsyncTestWait.waitUntil("first independent presentation", timeout: 3) { model.snapshot != nil }
        model.draft = "reply to first"
        currentText = "background update"
        model.refresh()
        XCTAssertEqual(model.selectedID, first.id)
        XCTAssertEqual(model.snapshot?.rows.first?.text, "background update")
        model.select(second)
        try await AsyncTestWait.waitUntil("second independent presentation", timeout: 3) { model.snapshot?.workspaceID == second.workspaceID }
        XCTAssertEqual(model.draft, "")
        model.draft = "reply to second"
        model.select(first)
        XCTAssertEqual(model.draft, "reply to first")
        model.newSession()
        XCTAssertEqual(model.draft, "new session draft")
        XCTAssertNil(model.selectedID)
    }

    func testStaleSelectedLoadCannotReplaceNewSelection() async throws {
        let first = row(), second = row()
        var continuation: CheckedContinuation<CommandCenterConversationModel.LoadResult, Never>?
        let model = CommandCenterConversationModel(isEnabled: { true }, load: { selected in
            if selected.id == first.id { return await withCheckedContinuation { continuation = $0 } }
            return .unavailable("second selected")
        })
        defer { model.stop() }
        model.select(first)
        try await AsyncTestWait.waitUntil("first selected load suspended", timeout: 3) { continuation != nil }
        model.select(second)
        try await AsyncTestWait.waitUntil("second selected load finished", timeout: 3) { model.message == "second selected" }
        continuation?.resume(returning: .unavailable("stale first"))
        await Task.yield()
        XCTAssertEqual(model.selectedID, second.id)
        XCTAssertEqual(model.message, "second selected")
        XCTAssertNil(model.snapshot)
    }

    func testOwnerRetirementAndDisableReleaseObservationWithoutDroppingDraft() async throws {
        var enabled = true, current = true, cancellations = 0
        let selected = row()
        let signal = PassthroughSubject<Void, Never>()
        let changes = signal.handleEvents(receiveCancel: { cancellations += 1 }).eraseToAnyPublisher()
        let model = CommandCenterConversationModel(isEnabled: { enabled }, load: { [self] _ in
            .ready(.init(isCurrent: { current }, snapshot: { [self] _ in frame(selected, text: "retained") }, changes: changes))
        })
        model.select(selected)
        try await AsyncTestWait.waitUntil("selected source installed", timeout: 3) { model.snapshot != nil }
        model.draft = "keep this"
        current = false
        model.refresh()
        XCTAssertNil(model.snapshot)
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(model.draft, "keep this")
        XCTAssertNotNil(model.message)
        current = true
        model.select(selected)
        try await AsyncTestWait.waitUntil("source reselected explicitly", timeout: 3) { model.snapshot != nil }
        enabled = false
        model.refresh()
        XCTAssertEqual(cancellations, 2)
        XCTAssertNil(model.snapshot)
        XCTAssertEqual(model.draft, "keep this")
        model.stop()
    }

    func testRecentSessionsSortAcrossProjectsAndKeepCompositeIdentities() {
        let workspaceA = UUID(), workspaceB = UUID(), sameSession = UUID()
        let older = row(workspaceA, session: sameSession, date: 1)
        let newer = row(workspaceB, session: sameSession, date: 3)
        func workspace(_ id: UUID, sessions: [CommandCenterSessionRow]) -> CommandCenterWorkspaceRow {
            .init(
                id: id,
                name: "Same project name",
                roots: [id.uuidString],
                unavailable: false,
                hidden: false,
                sessions: sessions,
                coverage: nil,
                savedCount: sessions.count,
                savedLimit: 100
            )
        }
        let snapshot = CommandCenterSnapshot(workspaces: [workspace(workspaceA, sessions: [older]), workspace(workspaceB, sessions: [newer])], catalogCoverage: nil)
        let rows = CommandCenterRecentSessions.rows(in: snapshot, matching: "")
        XCTAssertEqual(rows.map(\.id), [newer.id, older.id])
        XCTAssertNotEqual(rows[0].id, rows[1].id)
        XCTAssertEqual(CommandCenterRecentSessions.rows(in: snapshot, matching: workspaceA.uuidString).map(\.id), [older.id])
        XCTAssertEqual(CommandCenterRecentSessions.rows(in: snapshot, matching: "Same project").count, 2)
    }

    func testRecentInventoryDemandIncludesRecoveryWithoutChangingWorkspaceIDs() {
        let id = UUID()
        func snapshot(unavailable: Bool, loaded: Bool) -> CommandCenterSnapshot {
            .init(workspaces: [.init(
                id: id,
                name: "Project",
                roots: [],
                unavailable: unavailable,
                hidden: false,
                sessions: [],
                coverage: nil,
                savedCount: loaded ? 0 : nil,
                savedLimit: 100
            )], catalogCoverage: nil)
        }
        XCTAssertEqual(CommandCenterRecentSessions.inventoryWorkspaceIDs(in: snapshot(unavailable: true, loaded: false)), [])
        XCTAssertEqual(CommandCenterRecentSessions.inventoryWorkspaceIDs(in: snapshot(unavailable: false, loaded: false)), [id])
        XCTAssertEqual(CommandCenterRecentSessions.inventoryWorkspaceIDs(in: snapshot(unavailable: false, loaded: true)), [])
    }

    func testConversationProjectionUsesMutableSuffixAndRetainedHistoryWithoutChangingCanonicalData() {
        let old = AgentChatItem.user("retained request", sequenceIndex: 0)
        var transcript = AgentTranscriptIO.buildTranscript(from: [old, .assistant("old response", sequenceIndex: 1)], compact: false)
        transcript.turns[0].retentionTier = .summary
        let canonical = transcript
        let live = AgentChatItem.assistant("live response", sequenceIndex: 10)
        let projected = CommandCenterConversationRows.build(transcript: transcript, working: [live], hiddenIDs: [], limit: 500)
        XCTAssertTrue(projected.rows.contains { $0.id == old.id })
        XCTAssertEqual(projected.rows.last?.text, "live response")
        var replaced = live
        replaced.text = "streamed update"
        let updated = CommandCenterConversationRows.build(transcript: transcript, working: [replaced], hiddenIDs: [], limit: 1)
        XCTAssertEqual(updated.rows.map(\.text), ["streamed update"])
        XCTAssertTrue(updated.hasEarlier)
        let removed = CommandCenterConversationRows.build(transcript: transcript, working: [], hiddenIDs: [], limit: 500)
        XCTAssertFalse(removed.rows.contains { $0.id == live.id })
        let hidden = CommandCenterConversationRows.build(transcript: transcript, working: [live], hiddenIDs: [live.id], limit: 500)
        XCTAssertFalse(hidden.rows.contains { $0.id == live.id })
        XCTAssertEqual(transcript, canonical)
    }

    func testExplicitProjectChangePreservesNewDraftAndDoesNotRetargetSelectedConversation() {
        let model = CommandCenterConversationModel(isEnabled: { true }, load: { _ in .unavailable("fixture") })
        defer { model.stop() }
        let project = UUID(), another = UUID()
        model.newSession(projectID: project)
        model.draft = "new task"
        model.chooseProject(another)
        XCTAssertEqual(model.draft, "new task")
        XCTAssertEqual(model.projectID, another)
        let selected = row(project)
        model.select(selected)
        model.chooseProject(another)
        XCTAssertEqual(model.projectID, project)
        XCTAssertEqual(model.selectedID, selected.id)
    }
}

@MainActor
final class DockMenuTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AppWindowOpener.shared.resetForTesting()
    }

    override func tearDown() {
        AppWindowOpener.shared.resetForTesting()
        super.tearDown()
    }

    func testDockNewWindowMenuItemMetadataAndNilSenderRouting() throws {
        var events: [String] = []
        let controller = DockMenuController(
            activateApplication: {
                events.append("activate")
            },
            requestNewWindow: {
                events.append("request")
            },
            commandCenterEnabled: { true }
        )

        let menu = controller.makeMenu()
        XCTAssertEqual(menu.items.count, 2)

        let item = try XCTUnwrap(menu.items.first)
        XCTAssertEqual(item.title, "New Window")
        XCTAssertTrue(item.target === controller)
        XCTAssertNotNil(item.action)
        XCTAssertTrue(item.isEnabled)

        let didSend = try NSApplication.shared.sendAction(
            XCTUnwrap(item.action),
            to: item.target,
            from: nil
        )
        XCTAssertTrue(didSend)
        XCTAssertEqual(events, ["request", "activate"])
    }

    func testDockCommandCenterIsAnExplicitIndependentRequest() throws {
        var events: [String] = []
        let controller = DockMenuController(
            activateApplication: { events.append("activate") },
            requestNewWindow: { events.append("workspace") },
            requestCommandCenter: { events.append("center") },
            commandCenterEnabled: { true }
        )
        let item = try XCTUnwrap(controller.makeMenu().items.last)
        XCTAssertEqual(item.title, "Command Center")
        XCTAssertTrue(try NSApplication.shared.sendAction(XCTUnwrap(item.action), to: item.target, from: nil))
        XCTAssertEqual(events, ["center", "activate"])
    }

    func testDockRequestsQueueUntilOpenerIsInstalled() throws {
        var activationCount = 0
        var openCount = 0
        let controller = DockMenuController(activateApplication: {
            activationCount += 1
        })
        let item = try XCTUnwrap(controller.makeMenu().items.first)
        let action = try XCTUnwrap(item.action)

        XCTAssertTrue(NSApplication.shared.sendAction(action, to: item.target, from: nil))
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: item.target, from: nil))
        XCTAssertFalse(AppWindowOpener.shared.isAvailable)
        XCTAssertEqual(activationCount, 2)
        XCTAssertEqual(openCount, 0)

        AppWindowOpener.shared.install {
            openCount += 1
        }
        XCTAssertEqual(activationCount, 2)
        XCTAssertEqual(openCount, 2)

        XCTAssertTrue(NSApplication.shared.sendAction(action, to: item.target, from: nil))
        XCTAssertEqual(activationCount, 3)
        XCTAssertEqual(openCount, 3)
    }

    func testDisabledCommandCenterHasNoDockEntryAndRefusesAStaleMenuAction() throws {
        var enabled = false
        var events: [String] = []
        let controller = DockMenuController(
            activateApplication: { events.append("activate") },
            requestNewWindow: { events.append("workspace") },
            requestCommandCenter: { events.append("center") },
            commandCenterEnabled: { enabled }
        )
        XCTAssertEqual(controller.makeMenu().items.map(\.title), ["New Window"])
        enabled = true
        let item = try XCTUnwrap(controller.makeMenu().items.last)
        XCTAssertEqual(item.title, "Command Center")
        enabled = false
        XCTAssertTrue(try NSApplication.shared.sendAction(XCTUnwrap(item.action), to: item.target, from: nil))
        XCTAssertTrue(events.isEmpty)
    }

    func testCommandCenterOpenerDropsDisabledAndWithdrawnQueuedRequests() {
        var enabled = false
        var opens = 0
        let opener = CommandCenterWindowOpener(isEnabled: { enabled })
        opener.show()
        opener.install { opens += 1 }
        XCTAssertEqual(opens, 0)
        enabled = true
        opener.show()
        XCTAssertEqual(opens, 1)
        let queued = CommandCenterWindowOpener(isEnabled: { enabled })
        queued.show()
        enabled = false
        queued.install { opens += 1 }
        enabled = true
        queued.install { opens += 1 }
        XCTAssertEqual(opens, 1, "Re-enabling never replays a withdrawn window request")
    }

    func testThrowingOpenMainWindowStillReportsUnavailableOpener() {
        XCTAssertThrowsError(try AppWindowOpener.shared.openMainWindow()) { error in
            guard let windowError = error as? WindowOpenError,
                  case .openerUnavailable = windowError
            else {
                return XCTFail("Expected WindowOpenError.openerUnavailable, got \(error)")
            }
        }
    }
}

/// Lookout's app-surface tests share this existing app-entry test file to keep the app-import
/// boundary ratchet unchanged. No fixture creates a WindowState or a provider.
@MainActor
final class CommandCenterTests: XCTestCase {
    private let workspaceID = UUID()
    private let sessionID = UUID()

    private func catalog(unavailable: Set<UUID> = [], sequence: UInt64 = 1) -> DomainWorkspaceCatalogSnapshot {
        let metadata = DomainWorkspaceMetadata(
            workspaceID: workspaceID, schemaVersion: 1, dateModified: Date(), lastUsed: Date(),
            name: "Workspace", repoPaths: ["/tmp/lookout"], customStoragePath: nil,
            isSystemWorkspace: false, isHiddenInMenus: false, isEphemeral: false,
            activeContextID: nil, contexts: []
        )
        let document = DomainWorkspaceDocument(
            workspaceID: workspaceID, fileURL: URL(fileURLWithPath: "/tmp/lookout/workspace.json"),
            documentBytes: Data(), metadata: metadata
        )
        return DomainWorkspaceCatalogSnapshot(
            runtimeIdentity: .init(runtimeID: UUID(), lifecycleGeneration: 1, processID: 0, mode: .app, createdAt: Date()),
            isBootstrapped: true, publicationSequence: sequence, catalogRevision: sequence, health: .writable,
            workspaces: [.init(document: document, revisions: .initial, health: .writable, contexts: [])],
            unavailableWorkspaceIDs: unavailable
        )
    }

    private func sample(windowID: Int = 1, loaded: Bool = true, outcome: DomainAgentSessionLaneBoard.RunOutcome = .running) -> AgentSessionStatusCensus.Sample {
        let tabID = UUID()
        let binding = AgentPersistentSessionBindingIdentity(tabID: tabID, sessionID: sessionID)
        let candidate = AgentSessionLinkEndpointCandidate(
            windowID: windowID, workspaceID: workspaceID, tabID: tabID, sessionID: sessionID,
            persistentBindingGeneration: binding.generation, bindingTransitionGeneration: 0,
            isTopLevel: true, hasLoadedPersistedState: loaded, bindingTransitionInProgress: false,
            isClosing: false, isMCPControlled: false, isMCPOriginated: false, roleAllowsOutboundMonitoring: true,
            displayName: "Agent", providerDisplayName: "Codex", locationLabel: nil,
            restorationReadiness: .authoritative(.init(bindingIdentity: binding, bindingTransitionGeneration: 0), .persistedPayloadApplied)
        )
        return .init(candidate: candidate, status: .init(status: .running, pendingInteractionKind: nil), outcome: outcome)
    }

    private func row(_ sample: AgentSessionStatusCensus.Sample) -> AgentSessionStatusCensus.Row {
        .init(sample: sample, sequence: 1, observedAt: Date())
    }

    func testCatalogIncludesUnavailableWithoutAnyWindowsOrInventory() {
        let unavailable = UUID()
        let result = CommandCenterProjection.build(catalog: catalog(unavailable: [unavailable]), live: [], saved: [:], limits: [:])
        XCTAssertEqual(Set(result.workspaces.map(\.id)), [workspaceID, unavailable])
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertEqual(result.coverage.count, 1)
        XCTAssertEqual(result.workspaces.first(where: { $0.id == unavailable })?.rollup, "Unavailable")
    }

    func testDisabledFeatureAdmitsNoCatalogCensusOrSavedInventoryWork() async {
        let initial = catalog()
        let events = AsyncStream<DomainWorkspaceEvent>.makeStream()
        var captures = 0
        var subscriptions = 0
        var catalogReads = 0
        let diskReads = LookoutReadCounter()
        let census = AgentSessionStatusCensus(capture: { captures += 1
            return []
        }, observe: { _, _ in
            XCTFail("Disabled census must install no observation")
            return nil
        }, isEnabled: { false })
        let model = CommandCenterReadModel(
            subscribe: { subscriptions += 1
                return .init(snapshot: initial, events: events.stream)
            },
            readCatalog: { catalogReads += 1
                return initial
            }, census: census,
            loadInventory: { _, _, limit in
                await diskReads.record(limit)
                return .init(entries: [], totalCount: 0, coverage: nil)
            }, isEnabled: { false }
        )
        model.start()
        await model.refresh()
        model.loadSaved(workspaceID: workspaceID)
        census.start { _ in XCTFail("Disabled census must publish nothing") }
        census.refresh()
        XCTAssertFalse(model.isActive)
        XCTAssertEqual(subscriptions, 0)
        XCTAssertEqual(catalogReads, 0)
        XCTAssertEqual(captures, 0)
        let reads = await diskReads.values
        XCTAssertTrue(reads.isEmpty)
        XCTAssertTrue(model.snapshot.workspaces.isEmpty)
        events.continuation.finish()
    }

    func testDisablingOpenLookoutCancelsObservationsAndRefusesFurtherReads() async {
        var enabled = true
        let changes = PassthroughSubject<Void, Never>()
        let initial = catalog()
        let events = AsyncStream<DomainWorkspaceEvent>.makeStream()
        let liveSample = sample()
        var captures = 0
        var cancellations = 0
        var subscriptions = 0
        var catalogReads = 0
        let census = AgentSessionStatusCensus(capture: { captures += 1
            return [liveSample]
        }, observe: { _, _ in
            AgentSessionLinkObservationToken { cancellations += 1 }
        }, isEnabled: { enabled })
        let model = CommandCenterReadModel(
            subscribe: { subscriptions += 1
                return .init(snapshot: initial, events: events.stream)
            },
            readCatalog: { catalogReads += 1
                return initial
            }, census: census,
            isEnabled: { enabled }, enabledChanges: changes.eraseToAnyPublisher()
        )
        let opened = expectation(description: "enabled Lookout has an observed row")
        let disabled = expectation(description: "disabling clears the observed projection")
        var didOpen = false
        var didDisable = false
        let token = model.$snapshot.sink { value in
            if !didOpen, value.sessions.count == 1 { didOpen = true
                opened.fulfill()
            }
            if didOpen, !didDisable, value.workspaces.isEmpty { didDisable = true
                disabled.fulfill()
            }
        }
        defer { token.cancel()
            model.stop()
            events.continuation.finish()
        }
        model.start()
        await fulfillment(of: [opened], timeout: 3)
        XCTAssertTrue(model.isActive)
        XCTAssertEqual(subscriptions, 1)
        let capturesBefore = captures
        enabled = false
        changes.send(())
        // Explicit refresh/lazy work is refused too, independently of UI presentation.
        await model.refresh()
        model.loadSaved(workspaceID: workspaceID)
        census.refresh()
        await fulfillment(of: [disabled], timeout: 3)
        XCTAssertFalse(model.isActive)
        XCTAssertTrue(model.snapshot.workspaces.isEmpty)
        XCTAssertEqual(captures, capturesBefore)
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(catalogReads, 0)
        model.start()
        XCTAssertFalse(model.isActive)
        XCTAssertEqual(subscriptions, 1)
    }

    func testSavedAndUnloadedAreNeverWitnessedRunning() throws {
        let recorded = Date(timeIntervalSince1970: 123)
        let saved = CommandCenterProjection.SavedInventory(
            entries: [.init(id: sessionID, tabID: nil, name: "Saved", provider: nil, recordedAt: recorded)], totalCount: 1, coverage: nil
        )
        for live in [[], [row(sample(loaded: false))]] {
            let result = CommandCenterProjection.build(catalog: catalog(), live: live, saved: [workspaceID: saved], limits: [:])
            let session = try XCTUnwrap(result.sessions.first)
            XCTAssertEqual(session.attention, .saved)
            XCTAssertEqual(session.provenance, .saved(recordedAt: recorded))
        }
        let unknown = CommandCenterProjection.build(catalog: catalog(), live: [row(sample(loaded: false))], saved: [:], limits: [:])
        XCTAssertEqual(unknown.sessions.first?.attention, .unknown)
    }

    func testLiveTemporaryWorkspaceAbsentFromCatalogIsListedButNeverBecomesAProject() {
        let base = catalog()
        let empty = DomainWorkspaceCatalogSnapshot(
            runtimeIdentity: base.runtimeIdentity,
            isBootstrapped: true,
            publicationSequence: 1,
            catalogRevision: 1,
            health: .writable,
            workspaces: [],
            unavailableWorkspaceIDs: []
        )
        var temporary = sample()
        temporary.workspaceName = "Temporary project"
        let projection = CommandCenterProjection.build(catalog: empty, live: [row(temporary)], saved: [:], limits: [:])
        XCTAssertEqual(projection.sessions.count, 1)
        XCTAssertEqual(projection.workspaces.first?.name, "Temporary project")
        XCTAssertTrue(projection.projects.isEmpty)
        XCTAssertEqual(CommandCenterSidebarProjection.rows(snapshot: projection, tab: .active, search: "").count, 1)
        let retired = CommandCenterProjection.build(catalog: empty, live: [], saved: [:], limits: [:], unwitnessed: [row(temporary)])
        XCTAssertEqual(retired.sessions.first?.attention, .unknown)
    }

    func testLateCoalescedIndexIsRetriedAfterLiveRetirementWithoutUIRefresh() async throws {
        let stream = AsyncStream<DomainWorkspaceEvent>.makeStream()
        var current = [sample()]
        let index = CommandCenterLateIndex()
        let census = AgentSessionStatusCensus(capture: { current }, observe: { _, _ in nil }, isEnabled: { true })
        let initial = catalog()
        let sessionID = sessionID, workspaceID = workspaceID
        let model = CommandCenterReadModel(
            subscribe: { .init(snapshot: initial, events: stream.stream) },
            readCatalog: { initial },
            census: census,
            loadInventory: { _, _, _ in
                let published = await index.read()
                return .init(entries: published ? [.init(id: sessionID, tabID: nil, name: "Settled", provider: nil, recordedAt: Date())] : [], totalCount: published ? 1 : 0, coverage: nil)
            },
            isEnabled: { true }
        )
        defer { model.stop()
            stream.continuation.finish()
        }
        model.start()
        try await AsyncTestWait.waitUntil("initial live row") { model.snapshot.sessions.first?.attention == .working }
        current = []
        census.refresh()
        try await AsyncTestWait.waitUntil("initial retirement index read") { await index.reads >= 2 }
        await index.publish()
        try await AsyncTestWait.waitUntil("late index establishes saved row", timeout: 5) { model.snapshot.sessions.first?.attention == .saved }
        XCTAssertEqual(model.snapshot.sessions.first?.workspaceID, workspaceID)
    }

    func testDuplicateOwnersAreUnknownRatherThanSmallestWindowWinner() {
        let result = CommandCenterProjection.build(catalog: catalog(), live: [row(sample()), row(sample(windowID: 2))], saved: [:], limits: [:])
        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions.first?.attention, .unknown)
        XCTAssertEqual(result.sessions.first?.provenance, .unknown("Ambiguous live owners"))
    }

    func testTerminalOutcomesDoNotCollapseIntoIdleAndRollupIsAttentionFirst() {
        for (outcome, expected) in [(DomainAgentSessionLaneBoard.RunOutcome.completed, CommandCenterSessionRow.Attention.finished), (.failed, .failed)] {
            let result = CommandCenterProjection.build(catalog: catalog(), live: [row(sample(outcome: outcome))], saved: [:], limits: [:])
            XCTAssertEqual(result.sessions.first?.attention, expected)
            XCTAssertEqual(result.workspaces.first?.rollup, expected.title)
        }
        let base = sample()
        let needsHuman = AgentSessionStatusCensus.Sample(candidate: base.candidate, status: .init(status: .awaitingUser, pendingInteractionKind: nil), outcome: .awaitingUser)
        XCTAssertEqual(CommandCenterProjection.build(catalog: catalog(), live: [row(needsHuman)], saved: [:], limits: [:]).sessions.first?.attention, .needsYou)
    }

    func testCensusDemandDedupRebindAndExplicitCancellation() {
        var samples = [sample()]
        var captures = 0
        var cancellations = 0
        var subscriptions = 0
        var publications: [[AgentSessionStatusCensus.Row]] = []
        let census = AgentSessionStatusCensus(capture: { captures += 1
            return samples
        }, observe: { _, _ in
            subscriptions += 1
            return AgentSessionLinkObservationToken { cancellations += 1 }
        }, isEnabled: { true })
        census.refresh()
        XCTAssertEqual(captures, 0)
        census.start { publications.append($0) }
        XCTAssertEqual(publications.count, 1)
        census.refresh()
        XCTAssertEqual(publications.count, 1)
        XCTAssertEqual(subscriptions, 1)
        // A prepared-owner handoff has a different exact endpoint, even for the same durable ID.
        samples = [sample(windowID: 9)]
        census.refresh()
        XCTAssertEqual(subscriptions, 2)
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(publications.count, 2)
        census.stop()
        XCTAssertEqual(cancellations, 2)
        let before = captures
        census.refresh()
        XCTAssertEqual(captures, before)
        census.start { publications.append($0) }
        XCTAssertEqual(publications.count, 3, "Reopening always receives a fresh initial snapshot")
        census.stop()
    }

    func testSavedInventoryMissingCorruptFutureAndBoundedReadsNeverRepairOrHydrate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = CommandCenterSavedInventory.load(workspaceID: workspaceID, directory: directory, limit: 100)
        XCTAssertNotNil(missing.coverage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("AgentSessions").path))
        let folder = directory.appendingPathComponent("AgentSessions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("AgentSessionIndex.json")
        for bytes in try [Data("corrupt".utf8), JSONEncoder().encode(AgentSessionMetadataIndex(schemaVersion: 999))] {
            try bytes.write(to: url)
            XCTAssertNotNil(CommandCenterSavedInventory.load(workspaceID: workspaceID, directory: directory, limit: 100).coverage)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
        // A valid index can be read even alongside an unreadable session payload. Lookout never
        // invokes the sidebar's index rebuild or transcript-enrichment path.
        try Data("not a session".utf8).write(to: folder.appendingPathComponent("AgentSession-\(sessionID).json"))
        let bytes = try JSONEncoder().encode(AgentSessionMetadataIndex())
        try bytes.write(to: url)
        XCTAssertNil(CommandCenterSavedInventory.load(workspaceID: workspaceID, directory: directory, limit: 100).coverage)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testUnavailableOverlapAndLoadedEmptyInventoryAreHonest() {
        let overlapped = CommandCenterProjection.build(catalog: catalog(unavailable: [workspaceID]), live: [], saved: [:], limits: [:])
        XCTAssertEqual(overlapped.workspaces.count, 1)
        XCTAssertTrue(overlapped.workspaces[0].unavailable)
        XCTAssertFalse(overlapped.coverage.isEmpty)
        let loaded = CommandCenterProjection.build(
            catalog: catalog(), live: [], saved: [workspaceID: .init(entries: [], totalCount: 0, coverage: nil)], limits: [:]
        )
        XCTAssertEqual(loaded.workspaces[0].rollup, "No indexed saved sessions")
    }

    func testLostLiveWitnessKeepsUnknownUntilSavedMetadataEstablishesTheRow() {
        let prior = row(sample())
        let lost = CommandCenterProjection.build(catalog: catalog(), live: [], saved: [:], limits: [:], unwitnessed: [prior])
        XCTAssertEqual(lost.sessions.first?.attention, .unknown)
        XCTAssertFalse(lost.coverage.isEmpty)
        let saved = CommandCenterProjection.SavedInventory(
            entries: [.init(id: sessionID, tabID: nil, name: "Saved", provider: nil, recordedAt: Date())], totalCount: 1, coverage: nil
        )
        let reconciled = CommandCenterProjection.build(catalog: catalog(), live: [], saved: [workspaceID: saved], limits: [:], unwitnessed: [prior])
        XCTAssertEqual(reconciled.sessions.first?.attention, .saved)
        XCTAssertTrue(reconciled.coverage.isEmpty)
        XCTAssertNotEqual(
            CommandCenterSessionRow.ID(workspaceID: workspaceID, sessionID: sessionID),
            CommandCenterSessionRow.ID(workspaceID: UUID(), sessionID: sessionID)
        )
    }

    func testCensusCoalescesSettledSignalBurst() async {
        var current = sample()
        var notify: (@MainActor () -> Void)?
        var captures = 0
        var publications = 0
        let changed = expectation(description: "one settled publication")
        let census = AgentSessionStatusCensus(capture: { captures += 1
            return [current]
        }, observe: { _, callback in
            notify = callback
            return AgentSessionLinkObservationToken { notify = nil }
        }, isEnabled: { true })
        census.start { _ in
            publications += 1
            if publications == 2 { changed.fulfill() }
        }
        let candidate = current.candidate
        current = .init(candidate: candidate, status: .init(status: .awaitingUser, pendingInteractionKind: nil), outcome: .awaitingUser)
        for _ in 0 ..< 100 {
            notify?()
        }
        XCTAssertEqual(captures, 1, "Signals are sampled only after the settled batch")
        await fulfillment(of: [changed], timeout: 3)
        XCTAssertEqual(publications, 2)
        XCTAssertEqual(captures, 2)
        census.stop()
        XCTAssertNil(notify)
    }

    func testSavedIndexSizeBudgetRejectsWithoutReadingPayload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = directory.appendingPathComponent("AgentSessions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = folder.appendingPathComponent("AgentSessionIndex.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(CommandCenterSavedInventory.maximumIndexBytes + 1))
        try handle.close()
        let result = CommandCenterSavedInventory.load(workspaceID: workspaceID, directory: directory, limit: 100)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertTrue(result.coverage?.contains("16 MiB") == true)
    }

    func testColdCatalogLoadsSavedInventoryWithoutUIChangeEventAndGapRefetches() async {
        let initial = catalog()
        let unavailable = UUID()
        var current = catalog(unavailable: [unavailable], sequence: 400)
        let stream = AsyncStream<DomainWorkspaceEvent>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let census = AgentSessionStatusCensus(capture: { [] }, observe: { _, _ in nil }, isEnabled: { true })
        let reads = LookoutReadCounter()
        var refetches = 0
        let model = CommandCenterReadModel(
            subscribe: { .init(snapshot: initial, events: stream.stream) },
            readCatalog: { refetches += 1
                return current
            }, census: census,
            loadInventory: { _, _, limit in
                await reads.record(limit)
                return .init(entries: [], totalCount: 0, coverage: "fixture unreadable")
            }, isEnabled: { true }
        )
        var latest = model.snapshot
        let first = expectation(description: "initial catalog")
        let gap = expectation(description: "gap refetched")
        let inventory = expectation(description: "inventory coverage")
        var firstDone = false
        var gapDone = false
        var inventoryDone = false
        let token = model.$snapshot.sink { value in
            latest = value
            if !firstDone, value.workspaces.contains(where: { $0.id == self.workspaceID }) { firstDone = true
                first.fulfill()
            }
            if !gapDone, value.workspaces.contains(where: { $0.id == unavailable }) { gapDone = true
                gap.fulfill()
            }
            if !inventoryDone, value.coverage.contains(where: { $0.contains("fixture unreadable") }) { inventoryDone = true
                inventory.fulfill()
            }
        }
        model.start()
        await fulfillment(of: [first], timeout: 3)
        let unloaded = await reads.values
        XCTAssertEqual(unloaded, [100], "Cold model installation starts bounded inventory, without a UI onChange or later stream event")
        // Intentionally skip hundreds of sequence values, as a bounded stream may do.
        stream.continuation.yield(.init(runtimeID: initial.runtimeIdentity.runtimeID, sequence: 400, catalogRevision: 400, kind: .degraded, workspaceID: nil, contextID: nil, operationID: nil, origin: nil, revisions: nil, timestamp: Date(), diagnostic: nil))
        await fulfillment(of: [gap], timeout: 3)
        XCTAssertGreaterThan(refetches, 0)
        model.loadSaved(workspaceID: workspaceID)
        model.loadSaved(workspaceID: workspaceID)
        await fulfillment(of: [inventory], timeout: 3)
        let loaded = await reads.values
        XCTAssertEqual(loaded, [100])
        XCTAssertTrue(latest.sessions.isEmpty)
        model.stop()
        XCTAssertFalse(model.isActive)
        current = initial
        await model.refresh()
        XCTAssertTrue(model.snapshot.workspaces.isEmpty)
        stream.continuation.finish()
        token.cancel()
    }
}

private actor LookoutReadCounter {
    private(set) var values: [Int] = []
    func record(_ value: Int) {
        values.append(value)
    }
}

// MARK: - Command Center submission and shared UI regressions

@MainActor
final class CommandCenterSendCoordinatorTests: XCTestCase {
    private let id = CommandCenterSessionRow.ID(workspaceID: UUID(), sessionID: UUID())
    private var selection: AgentSessionLanePolicy.RoleSelection {
        .init(role: .pair, agentRaw: "claudeCode", modelRaw: "claude-fable-5-2", reasoningEffortRaw: nil, modelParameterSelections: [])
    }

    func testGateAndUnknownOwnerRefuseWithoutCreationOrDispatch() async {
        var enabled = false
        var resolutions = 0
        let coordinator = CommandCenterSendCoordinator(environment: .init(
            isEnabled: { enabled }, resolve: { _ in resolutions += 1
                return nil
            }, destinations: { _ in [] },
            create: { _, _, _, _, _ in XCTFail("No creation")
                return .incomplete(self.id)
            }
        ))
        let disabled = await coordinator.send(target: .session(id), text: "hello", windowID: nil, selection: nil)
        XCTAssertEqual(disabled.outcome, .blocked)
        XCTAssertEqual(resolutions, 0)
        enabled = true
        let unknown = await coordinator.send(target: .session(id), text: "hello", windowID: nil, selection: nil)
        XCTAssertEqual(unknown.outcome, .needsOpen)
        XCTAssertEqual(resolutions, 1)
    }

    func testOnlyExplicitOpenAndSendMayOpenAnUnhostedProjectAndStaleChoiceNeverFallsBack() async {
        var hosts: [Int] = [], opens = 0, creations = 0, sends = 0
        let endpoint = CommandCenterSendCoordinator.Endpoint(id: id, isCurrent: { true }, submit: { _ in sends += 1
            return .submitted
        })
        var environment = CommandCenterSendCoordinator.Environment(isEnabled: { true }, resolve: { _ in nil }, destinations: { _ in hosts }, create: { _, window, _, _, _ in
            XCTAssertEqual(window, 12)
            creations += 1
            return .ready(endpoint)
        })
        environment.openDestination = { project in XCTAssertEqual(project, self.id.workspaceID)
            opens += 1
            hosts = [12]
            return 12
        }
        let coordinator = CommandCenterSendCoordinator(environment: environment)
        let target = CommandCenterTarget.draft(projectID: id.workspaceID, draftID: UUID())
        let passive = await coordinator.send(target: target, text: "draft", windowID: nil, selection: selection)
        XCTAssertEqual(passive.outcome, .needsOpen)
        XCTAssertEqual(opens, 0)
        let stale = await coordinator.send(target: target, text: "draft", windowID: 99, selection: selection, openIfNeeded: true)
        XCTAssertEqual(stale.outcome, .needsOpen)
        XCTAssertEqual(opens, 0)
        let submitted = await coordinator.send(target: target, text: "draft", windowID: nil, selection: selection, openIfNeeded: true)
        XCTAssertEqual(submitted.outcome, .sent)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(sends, 1)
    }

    func testDraftRequiresOpenOrExplicitAmbiguousDestinationAndStaleChoiceNeverFallsBack() async {
        var hosts: [Int] = []
        var creations = 0
        let coordinator = CommandCenterSendCoordinator(environment: .init(
            isEnabled: { true }, resolve: { _ in nil }, destinations: { _ in hosts },
            create: { _, _, _, _, _ in creations += 1
                return .incomplete(self.id)
            }
        ))
        let target = CommandCenterTarget.draft(projectID: id.workspaceID, draftID: UUID())
        let closed = await coordinator.send(target: target, text: "draft", windowID: nil, selection: selection)
        XCTAssertEqual(closed.outcome, .needsOpen)
        hosts = [1, 2]
        let ambiguous = await coordinator.send(target: target, text: "draft", windowID: nil, selection: selection)
        XCTAssertEqual(ambiguous.outcome, .chooseDestination)
        hosts = [2]
        let stale = await coordinator.send(target: target, text: "draft", windowID: 1, selection: selection)
        XCTAssertEqual(stale.outcome, .chooseDestination)
        XCTAssertEqual(creations, 0)
        let incomplete = await coordinator.send(target: target, text: "draft", windowID: 2, selection: selection)
        XCTAssertEqual(incomplete.outcome, .creationIncomplete)
        XCTAssertEqual(incomplete.sessionID, id)
        XCTAssertEqual(creations, 1)
    }

    func testDuplicateClickDispatchesOnceAndOwnerLossReportsUncertain() async {
        var current = true
        var sends = 0
        let entered = expectation(description: "entered dispatch")
        var finish: CheckedContinuation<Void, Never>?
        let endpoint = CommandCenterSendCoordinator.Endpoint(id: id, isCurrent: { current }, submit: { _ in
            sends += 1
            entered.fulfill()
            await withCheckedContinuation { finish = $0 }
            return .submitted
        })
        let coordinator = CommandCenterSendCoordinator(environment: .init(
            isEnabled: { true }, resolve: { _ in endpoint }, destinations: { _ in [] },
            create: { _, _, _, _, _ in XCTFail("No creation")
                return .incomplete(self.id)
            }
        ))
        let task = Task { await coordinator.send(target: .session(id), text: "once", windowID: nil, selection: nil) }
        await fulfillment(of: [entered], timeout: 2)
        let duplicate = await coordinator.send(target: .session(id), text: "once", windowID: nil, selection: nil)
        XCTAssertEqual(duplicate.outcome, .blocked)
        current = false
        finish?.resume()
        let first = await task.value
        XCTAssertEqual(first.outcome, .uncertain)
        XCTAssertFalse(first.remainsCurrent?() ?? true, "A receipt retains the originating owner fence, never a fresh UUID-only lookup")
        XCTAssertEqual(sends, 1)
    }

    func testCreatedIdentitySurvivesBlockedFirstSendAndNoAutomaticRetry() async {
        var creations = 0, sends = 0
        let endpoint = CommandCenterSendCoordinator.Endpoint(id: id, isCurrent: { true }, submit: { text in
            XCTAssertEqual(text, "keep this draft")
            sends += 1
            return .blocked(message: "Waiting for approval")
        })
        let coordinator = CommandCenterSendCoordinator(environment: .init(
            isEnabled: { true }, resolve: { _ in nil }, destinations: { _ in [4] },
            create: { project, window, _, _, text in
                XCTAssertEqual(project, self.id.workspaceID)
                XCTAssertEqual(window, 4)
                XCTAssertEqual(text, "keep this draft")
                creations += 1
                return .ready(endpoint)
            }
        ))
        let result = await coordinator.send(
            target: .draft(projectID: id.workspaceID, draftID: UUID()),
            text: "keep this draft",
            windowID: nil,
            selection: selection
        )
        XCTAssertEqual(result.outcome, .blocked)
        XCTAssertEqual(result.sessionID, id)
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(sends, 1)
    }

    func testOneDraftTravelsAcrossProjectsWithoutAnyOwnerOrHydration() {
        let model = CommandCenterComposerModel()
        let a = UUID(), b = UUID()
        model.chooseProject(a)
        model.storeLocalDraftText("project A")
        let actionsA = model.actions()
        model.chooseProject(b)
        let actionsB = model.actions()
        XCTAssertFalse(AgentComposerView.hasEquivalentActionIdentity(actionsA, actionsB), "Equatable composer must replace closures captured for the previous project")
        XCTAssertTrue(AgentComposerView.hasEquivalentActionIdentity(actionsB, model.actions()))
        var changedTitle = actionsB
        changedTitle.sendTitle = "Send Message (Return)"
        XCTAssertFalse(AgentComposerView.hasEquivalentActionIdentity(actionsB, changedTitle))
        XCTAssertEqual(model.draftText, "project A")
        model.storeLocalDraftText("project B")
        model.chooseProject(a)
        XCTAssertEqual(model.draftText, "project B")
        model.chooseProject(b)
        XCTAssertEqual(model.draftText, "project B")
        XCTAssertNil(model.window)
        XCTAssertNil(model.presentationID)
    }

    func testTypingDuringAllocationSurvivesSuccessBlockedAndIncompleteWithoutReallocation() async {
        for outcome in [CommandCenterSendReceipt.Outcome.sent, .blocked, .creationIncomplete] {
            let entered = expectation(description: "allocation entered \(outcome)")
            var resume: CheckedContinuation<Void, Never>?
            var creations = 0
            let endpoint = CommandCenterSendCoordinator.Endpoint(id: id, isCurrent: { true }, submit: { _ in
                outcome == .sent ? .submitted : .blocked(message: "blocked")
            })
            let coordinator = CommandCenterSendCoordinator(environment: .init(
                isEnabled: { true }, resolve: { _ in nil }, destinations: { _ in [9] },
                create: { _, _, _, _, _ in
                    creations += 1
                    entered.fulfill()
                    await withCheckedContinuation { resume = $0 }
                    return outcome == .creationIncomplete ? .incomplete(self.id) : .ready(endpoint)
                }
            ))
            let model = CommandCenterComposerModel(coordinator: coordinator)
            model.newDraft(projectID: id.workspaceID, selection: selection)
            model.storeLocalDraftText("submitted snapshot")
            let send = Task { await model.send("submitted snapshot") }
            await fulfillment(of: [entered], timeout: 2)
            XCTAssertEqual(model.draftText, "", "admission separates submitted text from later typing")
            model.storeLocalDraftText("newer unsent text")
            resume?.resume()
            _ = await send.value
            XCTAssertEqual(model.target, .session(id))
            XCTAssertEqual(model.recoveredDraft?.text, outcome == .sent ? "newer unsent text" : "submitted snapshot\nnewer unsent text")
            _ = await model.send("explicit retry")
            XCTAssertEqual(creations, 1, "an allocated identity cannot create again, even after partial failure")
        }
    }

    func testClosingPresentationWhileAllocationAwaitsDoesNotRestartConversationCallbacks() async {
        let entered = expectation(description: "allocation suspended")
        var resume: CheckedContinuation<Void, Never>?
        var callbacks = 0, submissions = 0
        let endpoint = CommandCenterSendCoordinator.Endpoint(id: id, isCurrent: { true }, submit: { _ in submissions += 1
            return .submitted
        })
        let coordinator = CommandCenterSendCoordinator(environment: .init(
            isEnabled: { true }, resolve: { _ in nil }, destinations: { _ in [1] },
            create: { _, _, _, _, _ in
                entered.fulfill()
                await withCheckedContinuation { resume = $0 }
                return .ready(endpoint)
            }
        ))
        let model = CommandCenterComposerModel(coordinator: coordinator)
        model.newDraft(projectID: id.workspaceID, selection: selection)
        model.onCreatedSession = { _, _ in callbacks += 1 }
        let send = Task { await model.send("an explicit human submission") }
        await fulfillment(of: [entered], timeout: 2)
        model.stop()
        resume?.resume()
        _ = await send.value
        XCTAssertEqual(submissions, 1, "Closing presentation is not an implicit Stop of accepted human work")
        XCTAssertEqual(callbacks, 0)
        XCTAssertNil(model.onCreatedSession)
        XCTAssertNil(model.window)
        XCTAssertEqual(model.props, .empty)
    }
}

@MainActor
final class CommandCenterSidebarProjectionTests: XCTestCase {
    func testRegularRowDefaultsRemainUnchangedAndCCOnlyAddsPresentation() {
        let row = AgentSessionRow(
            title: "Regular",
            isActive: false,
            isPinned: false,
            isMCPControlled: false,
            runState: .idle,
            threadDepth: 0,
            onSelectionGesture: { _ in .ignored },
            onSelect: {},
            onTogglePin: {},
            onDelete: {},
            onRename: { _ in },
            sessionIDCopyAction: .systemClipboard(sessionID: nil)
        )
        XCTAssertTrue(row.isInteractionEnabled)
    }

    func testCreatedConversationUsesCapturedSourceWithoutLoadingOrFollowingReplacement() {
        var loads = 0, current = true
        let model = CommandCenterConversationModel(isEnabled: { true }, load: { _ in
            loads += 1
            return .unavailable("Unexpected lookup")
        })
        let id = CommandCenterSessionRow.ID(workspaceID: UUID(), sessionID: UUID())
        let tab = UUID()
        let source = CommandCenterConversationModel.Source(isCurrent: { current }, snapshot: { _ in
            .init(windowID: 7, workspaceID: id.workspaceID, tabID: tab, title: "Created", provider: "Claude", runState: "idle", rows: [], hasEarlierRows: false, hasPendingInteraction: false)
        }, changes: Empty().eraseToAnyPublisher())
        model.presentCreatedSession(id, source: source)
        XCTAssertEqual(model.snapshot?.tabID, tab)
        XCTAssertEqual(loads, 0)
        current = false
        model.refresh()
        XCTAssertNil(model.snapshot)
        XCTAssertEqual(loads, 0)
        model.presentCreatedSession(id, source: source)
        XCTAssertNil(model.snapshot)
        XCTAssertNotNil(model.message)
        model.stop()
    }

    func testTabsDatesThreadsAndCollidingProjectLabels() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let a = UUID(), b = UUID(), parent = UUID()
        func row(_ project: UUID, _ name: String, _ date: Date, _ attention: CommandCenterSessionRow.Attention, session: UUID = UUID()) -> CommandCenterSessionRow {
            .init(
                sessionID: session,
                workspaceID: project,
                tabID: UUID(),
                name: name,
                provider: nil,
                attention: attention,
                detail: nil,
                provenance: .saved(recordedAt: date),
                activityDate: date
            )
        }
        var pinned = row(a, "Parent", now, .working, session: parent)
        pinned.isPinned = true
        pinned.oversightRole = .init(ownOverseerSlot: 0, overseers: [], overseeingNames: ["Child"])
        var child = row(a, "Child", now.addingTimeInterval(-86400), .saved)
        child.parentSessionID = parent
        child.createdByOverseerSessionID = parent
        var foreign = row(b, "Foreign", now.addingTimeInterval(-86400), .saved)
        foreign.parentSessionID = parent
        let previous = row(b, "Old", now.addingTimeInterval(-864_000), .saved)
        let snapshot = CommandCenterSnapshot(workspaces: [
            .init(id: a, name: "Project", roots: [], unavailable: false, hidden: false, sessions: [pinned, child], coverage: nil, savedCount: 2, savedLimit: 100),
            .init(id: b, name: "Project", roots: [], unavailable: false, hidden: false, sessions: [foreign, previous], coverage: nil, savedCount: 2, savedLimit: 100)
        ], catalogCoverage: nil)
        let all = CommandCenterSidebarProjection.rows(snapshot: snapshot, tab: .all, search: "", now: now, calendar: calendar)
        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(all.first { $0.id == child.id }?.depth, 1)
        XCTAssertEqual(all.first { $0.id == foreign.id }?.depth, 0)
        XCTAssertEqual(all.filter(\.showsHeader).map(\.bucket), [.today, .yesterday, .previous])
        XCTAssertTrue(all.allSatisfy { $0.projectLabel.hasPrefix("Project · ") })
        XCTAssertEqual(CommandCenterSidebarProjection.rows(snapshot: snapshot, tab: .active, search: "", now: now).map(\.id), [pinned.id])
        XCTAssertEqual(CommandCenterSidebarProjection.rows(snapshot: snapshot, tab: .pinned, search: "", now: now).map(\.id), [pinned.id])
        XCTAssertEqual(CommandCenterSidebarProjection.rows(snapshot: snapshot, tab: .overseers, search: "", now: now).map(\.id), [pinned.id, child.id])
        XCTAssertEqual(CommandCenterSidebarProjection.rows(snapshot: snapshot, tab: .all, search: "foreign", now: now).map(\.id), [foreign.id])
        XCTAssertEqual(CommandCenterSidebarProjection.rows(snapshot: snapshot, tab: .all, search: "project", now: now).count, 4)
    }
}

@MainActor
final class CommandCenterLibraryAndFolderTests: XCTestCase {
    func testCanonicalClassificationAndMenuParityPreserveLegitimateUUIDNames() throws {
        var workspaces: [WorkspaceModel] = []
        for explicit in [nil, true, false] as [Bool?] {
            for ephemeral in [false, true] {
                for root in ["/Users/example/project", "/tmp/scratch", "/Users/example/.repoprompt-worktrees/scratch"] {
                    var workspace = WorkspaceModel(name: UUID().uuidString, repoPaths: [root], isSavedWorkspace: explicit)
                    workspace.isEphemeral = ephemeral
                    workspaces.append(workspace)
                    let expected = ephemeral || (explicit.map { !$0 } ?? (root.contains("/tmp/") || root.contains(".repoprompt-worktrees")))
                    XCTAssertEqual(workspace.isTemporaryWorkspace, expected)
                }
            }
        }
        var hidden = WorkspaceModel(name: "Hidden", repoPaths: ["/Users/example/hidden"], isSavedWorkspace: true)
        hidden.isHiddenInMenus = true
        workspaces.append(hidden)
        let metadata = try workspaces.map { workspace in
            try DomainWorkspaceDocument.decode(documentBytes: JSONEncoder().encode(workspace), fileURL: URL(fileURLWithPath: "/tmp/\(workspace.id)/workspace.json")).metadata
        }
        XCTAssertEqual(WorkspaceMenuPolicy.items(in: workspaces).map(\.id), WorkspaceMenuPolicy.items(in: metadata).map(\.id))
        XCTAssertTrue(WorkspaceMenuPolicy.items(in: metadata).contains { UUID(uuidString: $0.name) != nil && $0.isSavedWorkspace == true })
        let absent = DomainWorkspaceMetadata(workspaceID: UUID(), schemaVersion: 1, dateModified: Date(), lastUsed: Date(), name: "Legacy", repoPaths: [], customStoragePath: nil, isSystemWorkspace: false, isHiddenInMenus: false, isEphemeral: false, activeContextID: nil, contexts: [])
        XCTAssertNil(absent.isSavedWorkspace)
    }

    func testUnavailableSelectedSessionDisablesInputInsteadOfDiscardingTypedDraft() {
        let model = CommandCenterComposerModel()
        model.selectSession(.init(workspaceID: UUID(), sessionID: UUID()))
        XCTAssertTrue(model.isUnavailableSession)
        XCTAssertEqual(model.props, .empty)
        model.stop()
    }

    func testDistinctModelParametersAreMergedByIdentity() {
        let effort = ACPModelParameterSelection(providerID: .cursor, baseModelRaw: "base", kind: .thinking, configID: "effort", valueRaw: "low")
        let mode = ACPModelParameterSelection(providerID: .cursor, baseModelRaw: "base", kind: .speed, configID: "mode", valueRaw: "fast")
        let updated = ACPModelParameterSelection(providerID: .cursor, baseModelRaw: "base", kind: .thinking, configID: "effort", valueRaw: "high")
        let first = AgentComposerProjection.merging([mode], into: [effort])
        XCTAssertEqual(Set(first.map(\.configID)), ["effort", "mode"])
        let second = AgentComposerProjection.merging([updated], into: first)
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(second.first { $0.configID == "effort" }?.valueRaw, "high")
    }

    func testOpenFolderCancelAndSelectionPreserveTheTravellingDraftAndNeverActivateWindows() async throws {
        let settings = GlobalSettingsStore.shared
        let prior = settings.experimentalCommandCenter()
        settings.setExperimentalCommandCenter(true, commit: false)
        defer { settings.setExperimentalCommandCenter(prior, commit: false) }
        let model = CommandCenterComposerModel()
        let project = UUID()
        model.chooseProject(project)
        model.storeLocalDraftText("unfinished message")
        let windows = WindowStatesManager.shared.allWindows.map(\.windowID)
        var resolves = 0
        model.openFolder(pick: { nil }, resolve: { _ in resolves += 1
            return WorkspaceModel(name: "Never", repoPaths: [])
        })
        try await AsyncTestWait.waitUntil("cancelled folder picker") { !model.isOpeningFolder }
        XCTAssertEqual(resolves, 0)
        XCTAssertEqual(model.projectID, project)
        XCTAssertEqual(model.draftText, "unfinished message")
        let chosen = WorkspaceModel(name: "Picked", repoPaths: ["/tmp/picked"], isSavedWorkspace: true)
        model.openFolder(pick: { URL(fileURLWithPath: "/tmp/picked") }, resolve: { _ in resolves += 1
            return chosen
        })
        try await AsyncTestWait.waitUntil("resolved folder picker") { !model.isOpeningFolder }
        XCTAssertEqual(resolves, 1)
        XCTAssertEqual(model.projectID, chosen.id)
        XCTAssertEqual(model.draftText, "unfinished message")
        XCTAssertEqual(WindowStatesManager.shared.allWindows.map(\.windowID), windows)
        model.stop()
    }

    func testFolderDuplicateClickAndCancellationAfterCommitDoNotSelectOrLoseDraft() async {
        let settings = GlobalSettingsStore.shared, prior = settings.experimentalCommandCenter()
        settings.setExperimentalCommandCenter(true, commit: false)
        defer { settings.setExperimentalCommandCenter(prior, commit: false) }
        let model = CommandCenterComposerModel()
        let original = UUID()
        model.chooseProject(original)
        model.storeLocalDraftText("keep me")
        var release: CheckedContinuation<Void, Never>?
        let committed = expectation(description: "authority commit returned")
        var picks = 0, resolves = 0
        let workspace = WorkspaceModel(name: "Committed", repoPaths: ["/tmp/new"], isSavedWorkspace: true)
        model.openFolder(pick: { picks += 1
            return URL(fileURLWithPath: "/tmp/new")
        }, resolve: { _ in
            resolves += 1
            committed.fulfill()
            await withCheckedContinuation { release = $0 }
            return workspace
        })
        await fulfillment(of: [committed], timeout: 2)
        model.openFolder(pick: { picks += 1
            return nil
        })
        XCTAssertEqual(picks, 1)
        XCTAssertEqual(resolves, 1)
        model.stop()
        release?.resume()
        await Task.yield()
        XCTAssertEqual(model.projectID, original)
        XCTAssertEqual(model.draftText, "keep me")
    }

    func testFolderResolverCreatesThenReusesCanonicalLibraryIdentityWithoutActivation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CC-folder-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("Picked")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let runtime = MCPDomainRuntime(configuration: .init(mode: .app, profileIdentifier: UUID().uuidString, storageDirectory: root.appendingPathComponent("State"), eventDirectory: root.appendingPathComponent("Events"), temporaryDirectory: root.appendingPathComponent("Tmp"), externalReloadInterval: nil))
        try await runtime.start()
        let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: 9001)
        do {
            let file: (WorkspaceModel) -> URL = { root.appendingPathComponent("State/Workspaces/\($0.id)/workspace.json") }
            let first = try await PersistentFolderWorkspaceResolver.resolve(folderURL: folder, client: client, fileURL: file)
            XCTAssertEqual(first.provenance, .created)
            XCTAssertEqual(first.workspace.isSavedWorkspace, true)
            let second = try await PersistentFolderWorkspaceResolver.resolve(folderURL: folder, client: client, fileURL: file)
            XCTAssertEqual(second.provenance, .reused)
            XCTAssertEqual(first.workspace.id, second.workspace.id)
            XCTAssertEqual(first.workspace.lastUsed, second.workspace.lastUsed, "Resolve alone must not advance activation recency")
        } catch {
            _ = await runtime.shutdown()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        _ = await runtime.shutdown()
        try FileManager.default.removeItem(at: root)
    }
}

private actor CommandCenterLateIndex {
    private(set) var reads = 0
    private var published = false
    func read() -> Bool {
        reads += 1
        return published
    }

    func publish() {
        published = true
    }
}

@MainActor
final class CommandCenterSavedConversationTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func session(workspaceID: UUID) -> AgentSession {
        AgentSession(
            id: UUID(), workspaceID: workspaceID, composeTabID: UUID(), name: "Saved history",
            savedAt: Date(timeIntervalSince1970: 100), autoEditEnabled: false
        ).withItems([.user("Saved question", sequenceIndex: 0), .assistant("Saved answer", sequenceIndex: 1)])
    }

    private func write(_ session: AgentSession, in directory: URL, fileID: UUID? = nil) throws -> URL {
        let folder = directory.appendingPathComponent("AgentSessions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("AgentSession-\((fileID ?? session.id).uuidString).json")
        try JSONEncoder().encode(session).write(to: file)
        return file
    }

    func testSavedHistoryLoadsWithoutWindowRuntimeOrStorageRepair() async throws {
        let root = try directory(), workspaceID = UUID()
        var saved = session(workspaceID: workspaceID)
        saved.serializationVersion = 0
        let file = try write(saved, in: root)
        let original = try Data(contentsOf: file)
        let originalFiles = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        let originalWindows = Set(WindowStatesManager.shared.sessionRuntimeWindows.map(\.windowID))
        let service = AgentSessionDataService()
        let loaded = try await service.readSavedConversation(id: saved.id, workspaceID: workspaceID, directory: root)
        let value = try XCTUnwrap(loaded)
        let row = CommandCenterSessionRow(
            sessionID: saved.id, workspaceID: workspaceID, tabID: saved.composeTabID,
            name: saved.name, provider: nil, attention: .saved, detail: nil,
            provenance: .saved(recordedAt: saved.savedAt)
        )
        let model = CommandCenterConversationModel(isEnabled: { true }, load: { _ in .saved(value) })
        defer { model.stop() }
        model.select(row)
        try await AsyncTestWait.waitUntil("saved history displayed without a runtime", timeout: 3) { model.snapshot != nil }
        XCTAssertEqual(model.snapshot?.rows.map(\.text), ["Saved question", "Saved answer"])
        XCTAssertEqual(model.snapshot?.runState, "saved")
        XCTAssertNil(model.snapshot?.windowID, "History must not manufacture a workspace-action route")
        XCTAssertEqual(Set(WindowStatesManager.shared.sessionRuntimeWindows.map(\.windowID)), originalWindows)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: root.path), originalFiles)
        XCTAssertEqual(value.serializationVersion, 0, "Browsing must not run persistence migrations")
    }

    func testMissingHistoryDoesNotCreateStorageAndForeignOrCorruptPayloadIsRefused() async throws {
        let root = try directory(), workspaceID = UUID(), service = AgentSessionDataService()
        let absent = root.appendingPathComponent("absent")
        let missing = try await service.readSavedConversation(id: UUID(), workspaceID: workspaceID, directory: absent)
        XCTAssertNil(missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
        let foreign = session(workspaceID: UUID())
        let file = try write(foreign, in: root)
        do {
            _ = try await service.readSavedConversation(id: foreign.id, workspaceID: workspaceID, directory: root)
            XCTFail("Foreign workspace payload must not be presented")
        } catch {}
        let wrongID = UUID()
        _ = try write(foreign, in: root, fileID: wrongID)
        do {
            _ = try await service.readSavedConversation(id: wrongID, workspaceID: XCTUnwrap(foreign.workspaceID), directory: root)
            XCTFail("Filename and payload session IDs must agree")
        } catch {}
        let corrupt = Data("not JSON".utf8)
        try corrupt.write(to: file)
        do {
            _ = try await service.readSavedConversation(id: foreign.id, workspaceID: XCTUnwrap(foreign.workspaceID), directory: root)
            XCTFail("Corrupt history must be refused")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    func testSavedFrameReloadsWhenLiveOwnerAppearsAndKeepsDraft() async throws {
        let workspaceID = UUID()
        let saved = session(workspaceID: workspaceID)
        let row = CommandCenterSessionRow(
            sessionID: saved.id, workspaceID: workspaceID, tabID: saved.composeTabID,
            name: saved.name, provider: nil, attention: .saved, detail: nil,
            provenance: .saved(recordedAt: saved.savedAt)
        )
        var live = false, loads = 0
        let model = CommandCenterConversationModel(isEnabled: { true }, load: { _ in
            loads += 1
            if !live { return .saved(saved, isCurrent: { !live }) }
            return .ready(.init(isCurrent: { true }, snapshot: { _ in
                .init(
                    windowID: 123,
                    workspaceID: workspaceID,
                    tabID: saved.composeTabID,
                    title: saved.name,
                    provider: "",
                    runState: "working",
                    rows: [.assistant("Live answer", sequenceIndex: 0)],
                    hasEarlierRows: false,
                    hasPendingInteraction: false
                )
            }, changes: Empty<Void, Never>().eraseToAnyPublisher()))
        })
        defer { model.stop() }
        model.select(row)
        try await AsyncTestWait.waitUntil("saved frame", timeout: 3) { model.snapshot != nil }
        model.draft = "Keep this draft"
        live = true
        model.refresh()
        try await AsyncTestWait.waitUntil("canonical live frame", timeout: 3) { model.snapshot?.windowID == 123 }
        XCTAssertEqual(loads, 2)
        XCTAssertEqual(model.snapshot?.rows.first?.text, "Live answer")
        XCTAssertEqual(model.draft, "Keep this draft")
    }

    func testLegacyHistoryWithoutWorkspaceOrTabAndEarlierMessagesRemainReadable() async throws {
        let root = try directory(), workspaceID = UUID(), service = AgentSessionDataService()
        var saved = session(workspaceID: workspaceID)
        saved.workspaceID = nil
        saved.composeTabID = nil
        saved.transcript = nil
        saved.items = (0 ..< 550).map { AgentChatItemPersist(from: .user("Message \($0)", sequenceIndex: $0)) }
        _ = try write(saved, in: root)
        let loaded = try await service.readSavedConversation(id: saved.id, workspaceID: workspaceID, directory: root)
        let value = try XCTUnwrap(loaded)
        let tail = CommandCenterConversationRows.buildSaved(value, limit: 500)
        XCTAssertEqual(tail.rows.count, 500)
        XCTAssertEqual(tail.rows.first?.text, "Message 50")
        XCTAssertTrue(tail.hasEarlier)
        XCTAssertEqual(CommandCenterConversationRows.buildSaved(value, limit: 1000).rows.count, 550)
    }
}
