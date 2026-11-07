import AppKit
import Foundation
import RepoPromptAIContracts
@testable import RepoPromptApp
import RepoPromptCodexProvider
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import XCTest

@MainActor
final class AgentSessionAttachmentRuntimeTests: XCTestCase {
    func testProviderHooksRetainFilesAndScopeWithoutPresentationUntilDrain() async throws {
        var fixture: Fixture? = try Fixture()
        let f = try XCTUnwrap(fixture)
        let root = f.root
        let session = f.session
        let runtime = f.scope.attachments
        let store = f.store
        let attachment = f.attachment
        let sessionID = try XCTUnwrap(session.activeAgentSessionID)
        weak let scope = f.scope
        let gate = TestReleaseFence(name: "runtime retention without presenter")
        await AgentSessionDataService.shared.test_setBeforeAttachmentRetentionHook { _ in await gate.enterAndWait() }
        addTeardownBlock {
            gate.release()
            await runtime.waitForRetention()
            await AgentSessionDataService.shared.test_setBeforeAttachmentRetentionHook(nil)
            try? FileManager.default.removeItem(at: root)
        }
        let hooks = runtime.makeRunHooks()
        let reservation = hooks.reserveAttachmentsForTurn([attachment], session)
        hooks.markAttachmentsConsumed(session, reservation)
        hooks.stageConsumedAttachmentFilesForDeferredCleanup([attachment], session)
        hooks.finalizeAttachmentsForTurn(session, reservation, .deleteFiles)
        guard await gate.waitUntilEntered() else { return }
        f.scope.beginRetirement()
        session.isDirty = false
        XCTAssertFalse(f.scope.releaseWriterClaimsAfterDrain(), "An admitted attachment move must settle before writer release")
        fixture = nil
        XCTAssertNotNil(scope)
        XCTAssertTrue(store.attachmentSweepProtection().sessionIDs.contains(sessionID))
        XCTAssertTrue(try store.attachmentSweepProtection().temporaryPaths.contains(XCTUnwrap(AgentImageAttachmentAvailabilityResolver.path(for: attachment))))
        // Even a cancelled drain waiter cannot report completion before the disk operation.
        let waiter = Task { await runtime.waitForRetention() }
        waiter.cancel()
        gate.release()
        await waiter.value
        let kept = try XCTUnwrap(session.items.first?.attachments.first)
        XCTAssertNotEqual(kept.source, attachment.source)
        XCTAssertEqual(kept.id, attachment.id)
        XCTAssertEqual(kept.title, attachment.title)
        XCTAssertTrue(try FileManager.default.fileExists(atPath: XCTUnwrap(AgentImageAttachmentAvailabilityResolver.path(for: kept))))
        XCTAssertFalse(try FileManager.default.fileExists(atPath: XCTUnwrap(AgentImageAttachmentAvailabilityResolver.path(for: attachment))))
        XCTAssertTrue(session.isDirty)
        XCTAssertFalse(f.scope.releaseWriterClaimsAfterDrain(), "Repaired attachment paths still need a final payload save")
        XCTAssertEqual(runtime.sweepProtection.sessionIDs, [])
        // f deliberately remains in this scope; a separate test below checks final scope release.
        withExtendedLifetime(f) {}
    }

    func testRetentionReleasesScopeAfterCallerAndPresenterHaveGone() async throws {
        var fixture: Fixture? = try Fixture()
        let root = try XCTUnwrap(fixture?.root)
        let runtime = try XCTUnwrap(fixture?.scope.attachments)
        let session = try XCTUnwrap(fixture?.session)
        let attachment = try XCTUnwrap(fixture?.attachment)
        weak let scope = fixture?.scope
        let gate = TestReleaseFence(name: "retention scope lifetime")
        await AgentSessionDataService.shared.test_setBeforeAttachmentRetentionHook { _ in await gate.enterAndWait() }
        addTeardownBlock {
            gate.release()
            await runtime.waitForRetention()
            await AgentSessionDataService.shared.test_setBeforeAttachmentRetentionHook(nil)
            try? FileManager.default.removeItem(at: root)
        }
        let id = runtime.reserveAttachmentsForTurn([attachment], session: session)
        runtime.finalizeAttachmentsForTurn(for: session, reservationID: id, disposition: .deleteFiles)
        guard await gate.waitUntilEntered() else { return }
        fixture = nil
        XCTAssertNotNil(scope)
        gate.release()
        await runtime.waitForRetention()
        XCTAssertNil(scope)
        XCTAssertNotEqual(session.items.first?.attachments.first?.source, attachment.source)
    }

    func testHeldMoveCannotApplyToReboundIncarnationOrMovedStorage() async throws {
        for rebind in [true, false] {
            let f = try Fixture()
            let runtime = f.scope.attachments
            let originalLocation = f.location.value
            let originalID = try XCTUnwrap(f.session.activeAgentSessionID)
            let gate = TestReleaseFence(name: "retention identity fence")
            await AgentSessionDataService.shared.test_setBeforeAttachmentRetentionHook { _ in await gate.enterAndWait() }
            addTeardownBlock {
                gate.release()
                await runtime.waitForRetention()
                await AgentSessionDataService.shared.test_setBeforeAttachmentRetentionHook(nil)
                try? FileManager.default.removeItem(at: f.root)
            }
            let reservation = runtime.reserveAttachmentsForTurn([f.attachment], session: f.session)
            runtime.finalizeAttachmentsForTurn(for: f.session, reservationID: reservation, disposition: .deleteFiles)
            guard await gate.waitUntilEntered() else { return }
            if rebind {
                let old = f.session.currentRestorationBindingToken
                f.session.installPersistentSessionBinding(.init(tabID: f.session.tabID, sessionID: originalID, workspaceID: f.workspaceID))
                XCTAssertNotEqual(old, f.session.currentRestorationBindingToken)
            } else {
                f.location.value = .init(workspaceDirectory: f.root.appendingPathComponent("other"), retainedRoot: f.root.appendingPathComponent("other/attachments"))
            }
            gate.release()
            await runtime.waitForRetention()
            XCTAssertEqual(f.session.items.first?.attachments.first?.source, f.attachment.source)
            let retained = try AgentSessionAttachmentStore(rootURL: XCTUnwrap(originalLocation.retainedRoot))
                .sessionFolderURL(sessionID: originalID).appendingPathComponent("\(f.attachment.id.uuidString).png")
            XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path), "A stale publication does not roll back the admitted disk effect")
            // A fresh exact hydration can repair the original canonical path after handoff.
            f.location.value = originalLocation
            runtime.repairRetainedAttachmentPathsAfterHydration(f.session, sessionID: originalID)
            await runtime.waitForRetention()
            XCTAssertEqual(f.session.items.first?.attachments.first?.source, .localFile(path: retained.path))
        }
    }

    func testReservationCapturesTemporaryDirectoryAndRetainedRoot() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let runtime = f.scope.attachments
        let id = runtime.reserveAttachmentsForTurn([f.attachment], session: f.session)
        let captured = f.location.value
        f.location.value = .init(workspaceDirectory: f.root.appendingPathComponent("switched"), retainedRoot: f.root.appendingPathComponent("switched/attachments"))
        runtime.finalizeAttachmentsForTurn(for: f.session, reservationID: id, disposition: .deleteFiles)
        await runtime.waitForRetention()
        let retained = try AgentSessionAttachmentStore(rootURL: XCTUnwrap(captured.retainedRoot))
            .sessionFolderURL(sessionID: XCTUnwrap(f.session.activeAgentSessionID))
            .appendingPathComponent("\(f.attachment.id.uuidString).png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        XCTAssertFalse(try FileManager.default.fileExists(atPath: XCTUnwrap(AgentImageAttachmentAvailabilityResolver.path(for: f.attachment))))
        XCTAssertEqual(f.session.items.first?.attachments.first?.source, f.attachment.source, "The moved placement cannot receive an old-location publication")
    }

    func testIdleDeferredCleanupAndFirstBindingRetainTheirOriginalSemantics() async throws {
        for bindAfterReservation in [false, true] {
            let f = try Fixture(bound: !bindAfterReservation)
            defer { try? FileManager.default.removeItem(at: f.root) }
            let runtime = f.scope.attachments
            if bindAfterReservation {
                _ = runtime.reserveAttachmentsForTurn([f.attachment], session: f.session)
                XCTAssertNil(f.session.attachmentRetentionPlacement?.binding)
                f.session.installPersistentSessionBinding(.init(tabID: f.session.tabID, sessionID: UUID(), workspaceID: f.workspaceID))
            } else {
                XCTAssertNil(f.session.attachmentRetentionPlacement)
                runtime.stageConsumedAttachmentFilesForDeferredCleanup([f.attachment], session: f.session)
            }
            runtime.finalizeAttachmentsForTurn(for: f.session, disposition: .deleteFiles)
            await runtime.waitForRetention()
            let original = try XCTUnwrap(AgentImageAttachmentAvailabilityResolver.path(for: f.attachment))
            XCTAssertFalse(FileManager.default.fileExists(atPath: original))
            XCTAssertTrue(f.session.attachmentsPendingProviderConsumptionCleanup.isEmpty)
            if bindAfterReservation {
                let retained = try XCTUnwrap(f.session.items.first?.attachments.first)
                XCTAssertNotEqual(retained.source, f.attachment.source)
                XCTAssertTrue(try FileManager.default.fileExists(atPath: XCTUnwrap(AgentImageAttachmentAvailabilityResolver.path(for: retained))))
            }
        }
    }

    func testSweepReleasesWindowFreeOwnerOnlyAfterScopeAndPendingWorkAreGone() throws {
        var f: Fixture? = try Fixture()
        let root = try XCTUnwrap(f?.root)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try XCTUnwrap(f?.store)
        let session = try XCTUnwrap(f?.session)
        let attachment = try XCTUnwrap(f?.attachment)
        _ = f?.scope.attachments.reserveAttachmentsForTurn([attachment], session: session)
        XCTAssertEqual(store.attachmentSweepProtection().sessionIDs, try [XCTUnwrap(session.activeAgentSessionID)])
        XCTAssertEqual(store.attachmentSweepProtection().temporaryPaths, try [XCTUnwrap(AgentImageAttachmentAvailabilityResolver.path(for: attachment))])
        f = nil
        XCTAssertTrue(store.attachmentSweepProtection().sessionIDs.isEmpty)
        XCTAssertTrue(store.attachmentSweepProtection().temporaryPaths.isEmpty)
    }

    @MainActor
    private final class Location {
        var value: AgentSessionAttachmentLocation
        init(_ value: AgentSessionAttachmentLocation) {
            self.value = value
        }
    }

    @MainActor
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("M9Attachment-\(UUID())")
        let store = AgentSessionRuntimeStore()
        let scope: AgentSessionRuntimeStore.Scope
        let session = AgentTabSession(tabID: UUID())
        let workspaceID = UUID()
        let location: Location
        let attachment: AgentFileAttachment

        init(bound: Bool = true) throws {
            scope = store.makeScope()
            location = Location(.init(workspaceDirectory: root, retainedRoot: root.appendingPathComponent("AgentSessions/attachments")))
            let temporary = AgentAttachmentStore.managedStorageRootURL(for: root).appendingPathComponent("image.png")
            try FileManager.default.createDirectory(at: temporary.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: temporary)
            attachment = AgentFileAttachment(source: .localFile(path: temporary.path), title: "reserved image")
            if bound {
                session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: UUID(), workspaceID: workspaceID))
                session.recordRestorationAuthoritative(.persistedPayloadApplied)
            }
            session.appendItem(.user("Retain without a window", attachments: [attachment]))
            scope.replaceSessions([session.tabID: session])
            let location = location
            scope.attachments.configuration = .init(location: { _ in location.value }, locationIsCurrent: { $0 == location.value && $1.persistentSessionBindingIdentity != nil })
        }
    }
}

@MainActor
final class AgentSessionStreamRuntimeTests: XCTestCase {
    func testDetachedPresentationDoesNotDropAcceptedStreamOrToolBoundaries() async throws {
        let f = Fixture()
        let runtime = f.scope.stream
        var refreshes = 0
        let attachment = f.scope.presentation.attach(f.session, sink: .init(activityChanged: { _, _ in }, refresh: { _, _, _ in refreshes += 1 }, turnComplete: { _ in }, turnFailed: { _, _ in }))
        f.scope.presentation.detach(attachment)
        let owner = try XCTUnwrap(f.session.activeRunOwnership)
        let runID = try XCTUnwrap(f.session.runID)
        let hooks = runtime.makeRunHooks()
        await hooks.handleHeadlessStreamResult(.init(type: "content", text: "accepted content"), f.session, runID, owner.attemptID)
        let invocation = UUID()
        await hooks.handleHeadlessStreamResult(.init(type: "tool_call", text: nil, toolName: "fixture_tool", toolInvocationID: invocation, toolArgsJSON: "{}"), f.session, runID, owner.attemptID)
        await hooks.handleHeadlessStreamResult(.init(type: "tool_result", text: nil, toolName: "fixture_tool", toolInvocationID: invocation, toolResultJSON: "real output"), f.session, runID, owner.attemptID)
        await hooks.handleHeadlessStreamResult(.init(type: "final_content", text: "final response"), f.session, runID, owner.attemptID)
        XCTAssertEqual(f.session.items.map(\.kind), [.assistant, .toolResult, .assistant])
        XCTAssertEqual(f.session.items.map(\.text), ["accepted content", "real output", "final response"])
        XCTAssertFalse(f.session.items.contains(where: \.isStreaming))
        XCTAssertEqual(refreshes, 0)
        XCTAssertEqual(f.session.activeRunOwnership, owner)
        XCTAssertEqual(f.session.runState, .running)
    }

    func testStaleAttemptAndReboundIncarnationCannotApplyStreamEvents() async throws {
        let f = Fixture()
        let owner = try XCTUnwrap(f.session.activeRunOwnership)
        let runID = try XCTUnwrap(f.session.runID)
        await f.scope.stream.handleStreamResult(.init(type: "final_content", text: "wrong attempt"), session: f.session, runID: runID, runAttemptID: UUID())
        XCTAssertTrue(f.session.items.isEmpty)
        let binding = try XCTUnwrap(f.session.persistentSessionBindingIdentity)
        f.session.installPersistentSessionBinding(.init(tabID: f.session.tabID, sessionID: binding.sessionID, workspaceID: binding.workspaceID))
        await f.scope.stream.handleStreamResult(.init(type: "final_content", text: "old incarnation"), session: f.session, runID: runID, runAttemptID: owner.attemptID)
        XCTAssertTrue(f.session.items.isEmpty)
    }

    func testBufferedDeltaRetainsScopeWithoutPresenterButNotAcrossRebind() async throws {
        for rebind in [false, true] {
            var fixture: Fixture? = Fixture()
            let session = try XCTUnwrap(fixture?.session)
            let runtime = try XCTUnwrap(fixture?.scope.stream)
            weak let scope = fixture?.scope
            let gate = TestReleaseFence(name: "runtime assistant delta")
            defer { gate.release() }
            runtime.assistantFlushDelay = { await gate.enterAndWait() }
            runtime.enqueueAssistantDelta("buffered without a view model", session: session)
            let task = try XCTUnwrap(session.assistantDeltaFlushTask)
            guard await gate.waitUntilEntered() else { return }
            if rebind {
                let binding = try XCTUnwrap(session.persistentSessionBindingIdentity)
                session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: binding.sessionID, workspaceID: binding.workspaceID))
            }
            fixture = nil
            XCTAssertNotNil(scope)
            gate.release()
            await task.value
            XCTAssertNil(scope)
            XCTAssertEqual(session.items.map(\.text), rebind ? [] : ["buffered without a view model"])
            XCTAssertTrue(session.pendingAssistantDelta.isEmpty)
        }
    }

    func testToolHooksCannotRefreshOrSaveARecycledTabAndStillFinalizeExactTranscript() {
        let f = Fixture()
        let hooks = f.scope.stream.makeToolTrackingHooks()
        let successor = AgentTabSession(tabID: f.session.tabID)
        successor.isDirty = true
        f.scope.replaceSessions([successor.tabID: successor])
        var successorRefreshes = 0
        _ = f.scope.presentation.attach(successor, sink: .init(activityChanged: { _, _ in }, refresh: { _, _, _ in successorRefreshes += 1 }, turnComplete: { _ in }, turnFailed: { _, _ in }))
        hooks.requestUIRefresh(f.session, true)
        hooks.scheduleSave(f.session)
        XCTAssertEqual(successorRefreshes, 0)
        XCTAssertNil(successor.saveDebounceTask)
        XCTAssertTrue(successor.isDirty)
        let session = f.session
        _ = f.scope.stream.applyAssistantDelta("already accepted", session: session)
        hooks.sealAssistantBoundary(session)
        XCTAssertEqual(session.items.map(\.text), ["already accepted"])
        XCTAssertFalse(session.items.contains(where: \.isStreaming))
        XCTAssertTrue(successor.items.isEmpty)
    }

    func testRuntimePublishesAssistantRevisionAndDerivedFinalizationOnce() {
        let f = Fixture()
        var assistantPublications: [(Int, UInt64)] = []
        var derivedPublications = 0
        _ = f.scope.presentation.attach(f.session, sink: .init(
            activityChanged: { _, _ in }, refresh: { _, _, _ in }, turnComplete: { _ in }, turnFailed: { _, _ in },
            assistantDelta: { [weak expected = f.session] session, revision, generation in
                XCTAssertTrue(session === expected)
                assistantPublications.append((revision, generation))
            },
            derivedTranscript: { [weak expected = f.session] session in
                XCTAssertTrue(session === expected)
                derivedPublications += 1
            }
        ))
        f.scope.stream.enqueueAssistantDelta("stream", session: f.session)
        f.scope.stream.flushPendingAssistantDelta(f.session)
        XCTAssertEqual(assistantPublications.count, 1)
        XCTAssertEqual(assistantPublications.first?.0, f.session.sourceItemsRevision)
        XCTAssertEqual(assistantPublications.first?.1, f.session.assistantDeltaFlushGeneration)
        f.session.appendItem(.toolCall(name: "fixture_tool", argsJSON: "{}", sequenceIndex: f.session.nextSequenceIndex))
        let hooks = f.scope.stream.makeRunHooks()
        hooks.finalizePendingToolCalls(f.session, .completed)
        XCTAssertEqual(derivedPublications, 1)
        hooks.finalizePendingToolCalls(f.session, .completed)
        XCTAssertEqual(derivedPublications, 1, "An already finalized tool must not republish derived state")
    }

    @MainActor
    private final class Fixture {
        let store = AgentSessionRuntimeStore()
        let scope: AgentSessionRuntimeStore.Scope
        let session = AgentTabSession(tabID: UUID())
        init() {
            scope = store.makeScope()
            session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: UUID(), workspaceID: UUID()))
            session.recordRestorationAuthoritative(.persistedPayloadApplied)
            session.selectedAgent = .codexExec
            session.installRunID(UUID())
            session.runState = .running
            session.beginRunAttempt(source: "standalone stream runtime")
            scope.replaceSessions([session.tabID: session])
        }
    }
}

@MainActor
final class AgentSessionMCPRuntimeTests: XCTestCase {
    func testRegistrationRetainsExactRuntimeCancellationUntilCleanupWithoutPresentation() async throws {
        let store = makeCancellationStore()
        var scope: AgentSessionRuntimeStore.Scope? = AgentSessionRuntimeStore().makeScope()
        weak let retainedScope = scope
        let session = AgentTabSession(tabID: UUID())
        let sessionID = UUID(), activationID = UUID()
        session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: sessionID, workspaceID: UUID()))
        scope?.replaceSessions([session.tabID: session])
        var cancellations = 0
        let registration: AgentRunSessionStore.Registration
        do {
            let capability = try AgentSessionMCPRuntime.ControlActivationCancellation(
                scope: XCTUnwrap(scope), session: session, activationID: activationID
            ) { exact in
                XCTAssertIdentical(exact, session)
                cancellations += 1
            }
            registration = await store.register(sessionID: sessionID) { await capability.cancel(registration: $0) }
        }
        session.mcpControlContext = .init(
            sessionID: sessionID, activationID: activationID, registration: registration,
            currentEpoch: nil, preparedEpoch: nil, pendingEpochTransition: nil,
            originatingConnectionID: nil, interactionTransport: .mcp(sessionID: sessionID, originatingConnectionID: nil),
            suppressUserNotifications: true, forceAutoEditEnabled: false, autoEditEnabledBeforeOverride: false, taskLabelKind: nil
        )
        session.waitingPrompt = "Waiting for exact runtime cancellation"
        scope = nil
        XCTAssertNotNil(retainedScope, "Domain cancellation owns the runtime even without a presenter")
        let invoked = await store.test_invokeCancellationHandler(registration: registration)
        XCTAssertTrue(invoked)
        XCTAssertEqual(cancellations, 1)
        XCTAssertNil(session.waitingPrompt)
        retainedScope?.beginRetirement()
        _ = session.beginPersistentBindingTransition()
        session.mcpControlActivationGeneration &+= 1
        session.waitingPrompt = "Original run awaiting drain"
        _ = await store.test_invokeCancellationHandler(registration: registration)
        XCTAssertEqual(cancellations, 2, "Transition preparation cannot suppress the original run's shutdown drain")
        XCTAssertNil(session.waitingPrompt)
        let original = try XCTUnwrap(session.persistentSessionBindingIdentity)
        session.installPersistentSessionBinding(.init(tabID: original.tabID, sessionID: original.sessionID, workspaceID: original.workspaceID))
        session.waitingPrompt = "Successor instruction"
        _ = await store.test_invokeCancellationHandler(registration: registration)
        XCTAssertEqual(cancellations, 2, "A same-ID rebound incarnation cannot be cancelled")
        XCTAssertEqual(session.waitingPrompt, "Successor instruction")
        await store.cleanup(registration: registration)
        XCTAssertNil(retainedScope, "The domain registration must not permanently retain the scope")
        _ = await store.shutdown()
    }

    func testPendingActivationCancellationDoesNotCancelPreviouslyInstalledControl() async throws {
        let f = try await makeFixture()
        let previous = f.session.mcpControlContext
        var cancellations = 0
        let pending = AgentSessionMCPRuntime.ControlActivationCancellation(
            scope: f.scope, session: f.session, activationID: UUID()
        ) { _ in cancellations += 1 }
        XCTAssertTrue(pending.permitsPublication)
        f.scope.beginRetirement()
        XCTAssertFalse(pending.permitsPublication, "Retirement blocks new control without suppressing an installed run's drain")
        await pending.cancel(registration: f.registration)
        XCTAssertFalse(pending.permitsPublication)
        XCTAssertEqual(cancellations, 0)
        XCTAssertEqual(f.session.mcpControlContext, previous)
        XCTAssertTrue(f.session.runState.isActive)
    }

    func testResumableClaimInstallsCancellationBeforePersistenceAndPreservesReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let original = makeCancellationStore(root: root)
        let sessionID = UUID()
        _ = await original.register(sessionID: sessionID)
        _ = await original.shutdown()
        let store = makeCancellationStore(root: root)
        await store.bootstrap()
        let release = TestReleaseFence(name: "resumable claim persistence")
        defer { release.release() }
        await store.test_setMetadataFlushBeforeCAS { await release.enterAndWait() }
        let cancelled = expectation(description: "pending resume cancellation")
        let claim = Task {
            await store.claimResumableSession(sessionID: sessionID) { _ in cancelled.fulfill() }
        }
        await release.waitUntilEntered()
        let pendingRegistration = await store.currentRegistration(for: sessionID)
        let pending = try XCTUnwrap(pendingRegistration)
        let state = await store.test_shutdownOwnedState()
        XCTAssertEqual(state.recordCount, 1)
        XCTAssertEqual(state.cancellationHandlerCount, 1)
        let refused = await store.registerIfMissing(sessionID: sessionID) { _ in
            XCTFail("A rejected admission must not replace the pending cancellation capability")
        }
        XCTAssertNil(refused)
        let invoked = await store.test_invokeCancellationHandler(registration: pending)
        XCTAssertTrue(invoked)
        await fulfillment(of: [cancelled], timeout: 1)
        let successorCancelled = expectation(description: "replacement cancellation")
        let successor = await store.register(sessionID: sessionID) { registration in
            XCTAssertNotEqual(registration, pending)
            successorCancelled.fulfill()
        }
        await store.test_setMetadataFlushBeforeCAS(nil)
        release.release()
        let result = await claim.value
        XCTAssertEqual(result, .alreadyActive)
        await store.cleanup(registration: pending)
        let current = await store.currentRegistration(for: sessionID)
        XCTAssertEqual(current, successor, "The suspended claim cannot roll back a replacement")
        _ = await store.shutdown()
        await fulfillment(of: [successorCancelled], timeout: 1)
    }

    private func makeCancellationStore(root: URL? = nil) -> DomainAgentRunSessionStore {
        let directory = root ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        if root == nil { addTeardownBlock { try? FileManager.default.removeItem(at: directory) } }
        let identity = DomainRuntimeIdentity(runtimeID: UUID(), lifecycleGeneration: 1, processID: 42, mode: .standalone, createdAt: Date())
        let configuration = DomainRuntimeConfiguration(
            mode: .standalone, profileIdentifier: "M9 cancellation test", storageDirectory: directory,
            eventDirectory: directory.appendingPathComponent("Events"), temporaryDirectory: directory.appendingPathComponent("Temporary"),
            externalReloadInterval: nil
        )
        return DomainAgentRunSessionStore(
            identity: identity, persistence: DomainPersistenceCoordinator(configuration: configuration, identity: identity),
            profileIdentifier: configuration.profileIdentifier
        )
    }

    func testWindowFreeSnapshotAndInstructionPublicationUseExistingDomainRegistration() async throws {
        let f = try await makeFixture()
        let runtime = f.scope.mcp
        f.session.waitingPrompt = "Continue?"
        let snapshot = try XCTUnwrap(runtime.mcpSnapshot(for: f.session))
        XCTAssertEqual(snapshot.status, .waitingForInput)
        XCTAssertEqual(snapshot.interaction?.prompt, "Continue?")
        XCTAssertEqual(snapshot.sessionName, "Runtime fixture")
        await runtime.signalMCPInstructionDelivered(for: f.session)
        let published = await AgentRunSessionStore.snapshot(for: f.registration)
        XCTAssertEqual(published?.interaction, snapshot.interaction)
        XCTAssertEqual(published?.sessionID, f.sessionID)
        await AgentRunSessionStore.cleanup(registration: f.registration)
    }

    func testTerminalCommitPublishesAndAdvancesEpochWithoutPresentation() async throws {
        let f = try await makeFixture()
        let revision = try f.revision()
        let result = await f.scope.mcp.publishTerminalCommit(revision, successorKind: .relatedFollowUp, for: f.session)
        XCTAssertTrue(result.isResolved)
        let successor = try XCTUnwrap(result.successorEpoch)
        XCTAssertNotEqual(successor, f.epoch)
        XCTAssertEqual(f.session.mcpControlContext?.currentEpoch, successor)
        XCTAssertEqual(f.session.mcpControlContext?.preparedEpoch, successor)
        XCTAssertNotNil(f.session.mcpControlCleanupTask)
        let domainEpoch = await AgentRunSessionStore.currentEpoch(for: f.registration)
        XCTAssertEqual(domainEpoch, successor)
        await AgentRunSessionStore.cleanup(registration: f.registration)
    }

    func testCommittedDomainEffectCannotStampReboundIncarnationAfterSuspension() async throws {
        let f = try await makeFixture()
        let release = TestReleaseFence(name: "domain publication committed")
        defer { release.release() }
        f.scope.mcp.test_afterDomainTerminalPublication = { await release.enterAndWait() }
        let revision = try f.revision()
        let publication = Task { await f.scope.mcp.publishTerminalCommit(revision, successorKind: .relatedFollowUp, for: f.session) }
        await release.waitUntilEntered()
        let original = try XCTUnwrap(f.session.persistentSessionBindingIdentity)
        f.session.installPersistentSessionBinding(.init(tabID: original.tabID, sessionID: original.sessionID, workspaceID: original.workspaceID))
        XCTAssertNotEqual(f.session.persistentSessionBindingIdentity, original)
        release.release()
        let result = await publication.value
        XCTAssertTrue(result.isResolved, "A completed domain effect must not be reported as no effect")
        XCTAssertNotNil(result.successorEpoch)
        XCTAssertEqual(f.session.mcpControlContext?.currentEpoch, f.epoch, "Do not stamp the rebound incarnation")
        XCTAssertNil(f.session.mcpControlContext?.preparedEpoch)
        XCTAssertNil(f.session.mcpControlCleanupTask)
        await AgentRunSessionStore.cleanup(registration: f.registration)
    }

    func testRemovedScopeObjectStillPublishesOwnedTerminalWithoutTouchingReplacement() async throws {
        let f = try await makeFixture()
        let revision = try f.revision()
        let replacement = AgentTabSession(tabID: f.session.tabID)
        replacement.mcpControlContext = f.session.mcpControlContext
        try replacement.installPersistentSessionBinding(XCTUnwrap(f.session.persistentSessionBindingIdentity))
        f.scope.replaceSessions([replacement.tabID: replacement])
        let result = await f.scope.mcp.publishTerminalCommit(revision, successorKind: nil, for: f.session)
        XCTAssertEqual(result, .accepted(successorEpoch: nil))
        let before = await AgentRunSessionStore.snapshot(for: f.registration)
        XCTAssertEqual(before?.status, .completed)
        f.session.waitingPrompt = "stale question"
        await f.scope.mcp.signalMCPInstructionDelivered(for: f.session)
        let after = await AgentRunSessionStore.snapshot(for: f.registration)
        XCTAssertEqual(after, before)
        XCTAssertNil(replacement.mcpControlContext?.preparedEpoch)
        await AgentRunSessionStore.cleanup(registration: f.registration)
    }

    func testBarrierPreservesQueuedAndProviderSuccessorsWhenPublicationOutlivesBinding() async throws {
        for providerSpecific in [false, true] {
            let f = try await makeFixture()
            let session = f.session
            let ownership = session.beginRunAttempt(source: "runtime publication fence")
            let fence = AgentRunStartStopFence(session: session)
            if !providerSpecific { session.pendingInstructions = ["undelivered follow-up"] }
            var starts = 0
            var consumedProviderSuccessors = 0
            let release = TestReleaseFence(name: "barrier domain publication")
            defer { release.release() }
            f.scope.mcp.test_afterDomainTerminalPublication = { await release.enterAndWait() }
            let hooks = AgentRunTerminalSessionBinding.Hooks(
                flushPendingAssistantDelta: {}, finalizeStreamingItems: {}, finalizePendingToolCalls: { _ in },
                finalizeNonCodexTurnUsage: {}, cancelPendingInteractions: { _ in }, finalizeAttachments: { _, _ in },
                setAgentRunInactive: {}, prepareTerminalPublication: {},
                makeTerminalPublicationEnvelope: { owner, state, runID, failure in
                    f.scope.mcp.makeTerminalPublicationEnvelope(for: session, ownership: owner, terminalState: state, providerRunID: runID, failureReason: failure)
                },
                updateBindings: {}, notifyAgentTurnComplete: {}, scheduleSave: {},
                publishTerminalCommit: { revision, successor in
                    await f.scope.mcp.publishTerminalCommit(revision, successorKind: successor, for: session)
                },
                permitsTerminalSuccessor: { revision, result in
                    f.scope.sessions[session.tabID] === session
                        && fence.permitsTerminalSuccessor(of: session, revision: revision, publication: result)
                },
                startFollowUpRun: { _ in starts += 1 }
            )
            let binding = AgentRunTerminalSessionBinding(
                tabID: session.tabID, lifecycle: session.runLifecycle, hooks: hooks,
                validatesOwnership: { owner, runID in session.isCurrentRunAttemptForCurrentBinding(owner, expectedRunID: runID) },
                providerDrainGeneration: { 0 }, terminalTurnID: { nil },
                queuedFollowUp: { session.pendingInstructions.first?.providerText },
                setFollowUpPending: { session.mcpFollowUpRunPending = $0 },
                removeFirstQueuedFollowUp: { session.pendingInstructions.isEmpty ? nil : session.pendingInstructions.removeFirst() },
                appendError: { _ in },
                finishActiveState: { owner, state, source in
                    _ = session.endRunAttempt(ifCurrent: owner, source: source)
                    session.runState = state
                },
                retainProcessRunIdentity: { _, _ in }, sourceItemsRevision: { session.sourceItemsRevision },
                assistantDeltaFlushGeneration: { session.assistantDeltaFlushGeneration }, latestFailureText: { nil }
            )
            let successor: AgentRunTerminalCommitBarrier.ProviderSuccessor? = providerSpecific ? .init(
                id: UUID(), transitionKind: .relatedFollowUp,
                consumeAfterPublication: { _, _ in consumedProviderSuccessors += 1
                    return true
                }
            ) : nil
            let request = AgentRunTerminalCommitBarrier.Request(
                binding: binding, ownership: ownership, expectedRunID: session.runID, terminalState: .completed,
                source: "test.runtime-publication", attachmentDisposition: .deleteFiles,
                finalizeNonCodexUsage: false, supportsFollowUp: !providerSpecific,
                providerSuccessor: successor, notifyTurnComplete: false
            )
            let barrier = AgentRunTerminalCommitBarrier()
            let commit = Task { await barrier.commit(request) }
            await release.waitUntilEntered()
            let oldBinding = try XCTUnwrap(session.persistentSessionBindingIdentity)
            session.installPersistentSessionBinding(.init(tabID: oldBinding.tabID, sessionID: oldBinding.sessionID, workspaceID: oldBinding.workspaceID))
            release.release()
            let revision = await commit.value
            XCTAssertNotNil(revision)
            XCTAssertTrue(session.runLifecycle.lastTerminalPublicationResult?.isResolved == true)
            XCTAssertEqual(starts, 0)
            XCTAssertEqual(consumedProviderSuccessors, 0)
            XCTAssertTrue(session.mcpFollowUpRunPending)
            XCTAssertEqual(session.pendingInstructions.count, providerSpecific ? 0 : 1)
            _ = await barrier.commit(request)
            XCTAssertEqual(starts, 0, "A repeated commit cannot bypass the successor fence")
            XCTAssertEqual(consumedProviderSuccessors, 0)
            XCTAssertEqual(session.pendingInstructions.count, providerSpecific ? 0 : 1)
        }
    }

    private func makeFixture() async throws -> Fixture {
        let fixture = try await Fixture.make()
        let registration = fixture.registration
        addTeardownBlock { await AgentRunSessionStore.cleanup(registration: registration) }
        return fixture
    }

    @MainActor
    private struct Fixture {
        let scope: AgentSessionRuntimeStore.Scope
        let session: AgentTabSession
        let sessionID: UUID
        let registration: AgentRunSessionStore.Registration
        let epoch: AgentRunTurnEpoch

        static func make() async throws -> Fixture {
            let scope = AgentSessionRuntimeStore().makeScope()
            let session = AgentTabSession(tabID: UUID())
            let sessionID = UUID(), activationID = UUID()
            session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: sessionID, workspaceID: UUID()))
            session.recordRestorationAuthoritative(.persistedPayloadApplied)
            session.installRunID(UUID())
            session.runState = .running
            scope.replaceSessions([session.tabID: session])
            scope.mcp.metadata = .init(sessionName: { _, _ in "Runtime fixture" }, parentIsWorktreeBound: { _ in nil })
            let registration = await AgentRunSessionStore.register(sessionID: sessionID)
            guard case let .accepted(epoch) = await AgentRunSessionStore.beginEpoch(registration: registration, activationID: activationID, expectedCurrentEpoch: nil, transitionKind: .initial) else {
                throw NSError(domain: "MCP runtime fixture epoch", code: 1)
            }
            session.mcpControlContext = .init(sessionID: sessionID, activationID: activationID, registration: registration, currentEpoch: epoch, preparedEpoch: nil, pendingEpochTransition: nil, originatingConnectionID: nil, interactionTransport: .mcp(sessionID: sessionID, originatingConnectionID: nil), suppressUserNotifications: true, forceAutoEditEnabled: false, autoEditEnabledBeforeOverride: false, taskLabelKind: .pair)
            return .init(scope: scope, session: session, sessionID: sessionID, registration: registration, epoch: epoch)
        }

        func revision() throws -> AgentRunTerminalCommitRevision {
            let owner = AgentRunOwnership(binding: .init(tabID: session.tabID, persistentSessionID: sessionID), turnEpoch: epoch)
            let envelope = try XCTUnwrap(scope.mcp.makeTerminalPublicationEnvelope(for: session, ownership: owner, terminalState: .completed, providerRunID: session.runID, failureReason: nil))
            return .init(commitID: UUID(), ownership: owner, terminalState: .completed, failureReason: nil, expectedRunID: session.runID, sourceItemsRevision: session.sourceItemsRevision, assistantDeltaFlushGeneration: session.assistantDeltaFlushGeneration, providerDrainGeneration: 0, mcpPublicationEnvelope: envelope, successorKind: .relatedFollowUp, providerSuccessorID: nil)
        }
    }
}

@MainActor
final class AgentSessionInteractionRuntimeTests: XCTestCase {
    func testCancellationHooksResumeQuestionOnceWithoutViewModelAndPreserveStatePriority() async {
        let scope = AgentSessionRuntimeStore().makeScope()
        let session = AgentTabSession(tabID: UUID())
        scope.replaceSessions([session.tabID: session])
        let runtime = scope.interactions(routeID: 42, approvalStore: ApplyEditsApprovalStore())
        let observer = Observer()
        runtime.observer = observer
        let hooks = runtime.makeRunHooks()
        session.runState = .waitingForQuestion
        let generation = session.pendingAskUserTimeoutGeneration
        do {
            let _: AgentAskUserResponse = try await withCheckedThrowingContinuation { continuation in
                session.askUserContinuation = continuation
                hooks.cancelPendingQuestion(session)
                hooks.cancelPendingQuestion(session)
            }
            XCTFail("Cancelled question must throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNil(session.askUserContinuation)
        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.pendingAskUserTimeoutGeneration, generation + 2)
        XCTAssertEqual(observer.reasons, [.pendingQuestionCancelled, .pendingQuestionCancelled])
        session.pendingApplyEditsReview = .init(scope: runtime.approvalScope(for: session), path: "file", unifiedDiff: "diff")
        session.waitingPrompt = "next instruction"
        AgentSessionInteractionRuntime.reconcileInteractiveRunState(session)
        XCTAssertEqual(session.runState, .waitingForApproval)
        hooks.cancelPendingApproval(session)
        XCTAssertEqual(session.runState, .waitingForApproval, "An independent apply-edits review still owns the wait")
        session.pendingApplyEditsReview = nil
        AgentSessionInteractionRuntime.reconcileInteractiveRunState(session)
        XCTAssertEqual(session.runState, .waitingForUser)
        AgentSessionInteractionRuntime.cancelPendingInstruction(for: session)
        XCTAssertNil(session.waitingPrompt)
    }

    func testLateApprovalCancellationDrainsOriginalEffectWithoutCancellingSuccessorReview() async throws {
        var scope: AgentSessionRuntimeStore.Scope? = AgentSessionRuntimeStore().makeScope()
        let session = AgentTabSession(tabID: UUID())
        scope?.replaceSessions([session.tabID: session])
        let store = ApplyEditsApprovalStore()
        let runtime = try XCTUnwrap(scope).interactions(routeID: 42, approvalStore: store)
        weak let retainedScope = scope
        let address = runtime.approvalScope(for: session)
        let (subscription, stream) = await store.subscribe(scope: address)
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        let original = Task { await store.requestReview(scope: address, path: "first", unifiedDiff: "diff", timeoutSeconds: 60) }
        let firstSnapshot = await iterator.next()
        let first = try XCTUnwrap(firstSnapshot?.pendingReview)
        session.pendingApplyEditsReview = first
        let gate = TestReleaseFence(name: "interaction cancellation drain")
        runtime.test_beforeApprovalCancellation = { await gate.enterAndWait() }
        addTeardownBlock {
            gate.release()
            await runtime.drainPendingEffects()
            await store.cleanupScope(address)
            await store.unsubscribe(scope: address, id: subscription)
            _ = await original.value
        }
        runtime.makeRunHooks().cancelPendingApplyEditsReview(session, "Stopped")
        guard await gate.waitUntilEntered() else { return }
        scope = nil
        XCTAssertNotNil(retainedScope, "An admitted store effect keeps its exact runtime owner alive")
        let successor = Task { await store.requestReview(scope: address, path: "second", unifiedDiff: "diff", timeoutSeconds: 60) }
        var nextReview: PendingApplyEditsReview?
        while nextReview == nil {
            let received = await iterator.next()
            let snapshot = try XCTUnwrap(received)
            if let review = snapshot.pendingReview, review.id != first.id { nextReview = review }
        }
        let next = try XCTUnwrap(nextReview)
        var drained = false
        let drainStarted = expectation(description: "Cancelled waiter entered the drain")
        let drain = Task {
            drainStarted.fulfill()
            await runtime.drainPendingEffects()
            drained = true
        }
        drain.cancel()
        await fulfillment(of: [drainStarted], timeout: 5)
        XCTAssertFalse(drained)
        gate.release()
        await drain.value
        XCTAssertTrue(drained)
        XCTAssertNil(retainedScope)
        let (_, currentStream) = await store.subscribe(scope: address)
        var currentIterator = currentStream.makeAsyncIterator()
        let current = await currentIterator.next()
        XCTAssertEqual(current?.pendingReview?.id, next.id)
        await store.resolveReview(scope: address, reviewID: next.id, decision: .accept)
        let result = await successor.value
        XCTAssertEqual(result, .accept)
    }

    func testStopCancelsUndisplayedReviewButStaleOwnerCannotCancelReplacement() async throws {
        let scope = AgentSessionRuntimeStore().makeScope()
        let session = AgentTabSession(tabID: UUID())
        scope.replaceSessions([session.tabID: session])
        let store = ApplyEditsApprovalStore()
        let runtime = scope.interactions(routeID: 42, approvalStore: store)
        let address = runtime.approvalScope(for: session)
        let (subscription, stream) = await store.subscribe(scope: address)
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        addTeardownBlock { await store.cleanupScope(address) }
        let first = Task { await store.requestReview(scope: address, path: "displayed", unifiedDiff: "diff", timeoutSeconds: 60) }
        let displayed = await iterator.next()
        session.pendingApplyEditsReview = try XCTUnwrap(displayed?.pendingReview)
        let second = Task { await store.requestReview(scope: address, path: "not yet displayed", unifiedDiff: "diff", timeoutSeconds: 60) }
        _ = await iterator.next() // cancellation of first
        let buffered = await iterator.next()
        let bufferedSnapshot = try XCTUnwrap(buffered)
        XCTAssertNotEqual(bufferedSnapshot.pendingReview?.id, session.pendingApplyEditsReview?.id)
        runtime.cancelPendingApplyEditsReview(for: session, reason: "Stopping original run")
        session.runState = .completed
        await runtime.drainPendingEffects(for: session)
        let secondResult = await second.value
        XCTAssertEqual(secondResult, .cancelled(reason: "Stopping original run"))
        runtime.applyApprovalSnapshot(bufferedSnapshot, to: session)
        XCTAssertNil(session.pendingApplyEditsReview, "A buffered pre-stop review cannot resurrect the stopped run")
        XCTAssertEqual(session.runState, .completed)
        _ = await first.value
        _ = await iterator.next() // cancellation of second

        let replacement = AgentTabSession(tabID: session.tabID)
        scope.replaceSessions([replacement.tabID: replacement])
        let third = Task { await store.requestReview(scope: address, path: "replacement", unifiedDiff: "diff", timeoutSeconds: 60) }
        let thirdSnapshot = await iterator.next()
        let thirdReview = try XCTUnwrap(thirdSnapshot?.pendingReview)
        XCTAssertNil(session.pendingApplyEditsReview)
        runtime.cancelPendingApplyEditsReview(for: session, reason: "Late old terminal")
        await runtime.drainPendingEffects(for: session)
        await store.resolveReview(scope: address, reviewID: thirdReview.id, decision: .accept)
        let thirdResult = await third.value
        XCTAssertEqual(thirdResult, .accept, "An old object without a known review has no namespace-wide cancellation authority")
        await store.unsubscribe(scope: address, id: subscription)
    }

    func testApprovalSubscriptionRejectsRecycledTabAndJoinsBeforeTeardown() async throws {
        let scope = AgentSessionRuntimeStore().makeScope()
        let session = AgentTabSession(tabID: UUID())
        session.autoEditEnabled = true
        scope.replaceSessions([session.tabID: session])
        let store = ApplyEditsApprovalStore()
        let runtime = scope.interactions(routeID: 42, approvalStore: store)
        let subscribed = expectation(description: "Initial approval projection")
        var refreshes = 0
        let attachment = scope.presentation.attach(session, sink: .init(
            activityChanged: { _, _ in },
            refresh: { _, _, _ in refreshes += 1
                if refreshes == 1 { subscribed.fulfill() }
            },
            turnComplete: { _ in }, turnFailed: { _, _ in }
        ))
        runtime.ensureApprovalSync(for: session)
        await fulfillment(of: [subscribed], timeout: 5)
        let task = try XCTUnwrap(session.applyEditsApprovalSubscriptionTask)
        let replacement = AgentTabSession(tabID: session.tabID)
        replacement.autoEditEnabled = true
        scope.replaceSessions([replacement.tabID: replacement])
        scope.presentation.detach(attachment)
        await store.setAutoEditEnabled(false, for: runtime.approvalScope(for: replacement), updateGlobalDefault: false)
        await task.value
        XCTAssertTrue(replacement.autoEditEnabled)
        XCTAssertNil(replacement.pendingApplyEditsReview)
        XCTAssertNil(session.applyEditsApprovalSubscriptionTask)
        XCTAssertNil(session.applyEditsApprovalSubscriptionID)
        await runtime.teardownApprovalSync(for: session, cleanupScope: true)
        let value = await store.autoEditEnabled(for: runtime.approvalScope(for: replacement))
        XCTAssertFalse(value, "Old teardown must not clean the replacement's approval namespace")
        await store.cleanupScope(runtime.approvalScope(for: replacement))
    }

    @MainActor
    private final class Observer: AgentRunInteractionStateObserving {
        var reasons: [AgentRunInteractionStateChangeReason] = []
        func runInteractionStateChanged(for session: AgentTabSession, reason: AgentRunInteractionStateChangeReason) {
            reasons.append(reason)
        }
    }
}

@MainActor
final class AgentSessionCodexRuntimeEffectsTests: XCTestCase {
    func testNativeUsageAndActivityContinueWithoutViewModelOrPresentation() async throws {
        let scope = AgentSessionRuntimeStore().makeScope()
        let coordinator = makeCoordinator(scope: scope)
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .codexExec
        session.selectedModelRaw = "gpt-5"
        session.codexConversationID = "runtime-thread"
        session.codexController = LifecycleNoopCodexController(recorder: LifecycleRecorder())
        session.installRunID(UUID())
        _ = session.beginRunAttempt(source: "test.runtime.codex")
        scope.replaceSessions([session.tabID: session])
        await coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "turn-one"), session: session)
        XCTAssertEqual(session.runState, .running)
        let startedAt = try XCTUnwrap(session.activeAgentRunStartedAt)
        await coordinator.test_handleCodexNativeEvent(.tokenUsage(.init(modelContextWindow: 200_000, lastTotalTokens: 1200, totalTotalTokens: 1800)), session: session)
        XCTAssertEqual(session.contextUsageSnapshot?.used, 1200)
        XCTAssertEqual(session.contextUsageSnapshot?.window, 200_000)
        XCTAssertTrue(session.isDirty)

        var scopes: [AgentSessionPresentationRefreshScope] = []
        let attachment = scope.presentation.attach(session, sink: .init(
            activityChanged: { _, _ in XCTFail("Attaching a presenter must not restart the turn") },
            refresh: { actual, _, refreshScope in
                XCTAssertTrue(actual === session)
                scopes.append(refreshScope)
            },
            turnComplete: { _ in }, turnFailed: { _, _ in }
        ))
        await coordinator.test_handleCodexNativeEvent(.tokenUsage(.init(modelContextWindow: 200_000, lastTotalTokens: 2400, totalTotalTokens: 3600)), session: session)
        XCTAssertEqual(scopes, [.runtimeMetrics])
        scope.presentation.detach(attachment)
        await coordinator.test_handleCodexNativeEvent(.tokenUsage(.init(modelContextWindow: 200_000, lastTotalTokens: 3600, totalTotalTokens: 5400)), session: session)
        XCTAssertEqual(session.contextUsageSnapshot?.used, 3600)
        XCTAssertEqual(session.activeAgentRunStartedAt, startedAt)
        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(scopes, [.runtimeMetrics], "Detached presentation receives no later metrics")
        await session.codexController?.shutdown()
    }

    func testProductionAttachmentPublishesNativeEffectsButRejectsRecycledTab() async {
        let viewModel = AgentModeViewModel(
            testWindowID: -902, testWorkspacePath: nil, shouldManageCodexTooling: false,
            codexControllerFactory: { _, _, _, _, _, _ in fatalError("Event handling must not launch a controller") }
        )
        let coordinator = viewModel.test_codexCoordinator
        let predecessor = viewModel.session(for: UUID())
        predecessor.selectedAgent = .codexExec
        predecessor.codexConversationID = "presentation-thread"
        predecessor.codexController = LifecycleNoopCodexController(recorder: LifecycleRecorder())
        predecessor.installRunID(UUID())
        _ = predecessor.beginRunAttempt(source: "test.runtime.presentation")
        await coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "turn-one"), session: predecessor)
        XCTAssertTrue(viewModel.tabsWithActiveAgentRun.contains(predecessor.tabID))
        viewModel.test_flushPendingUIRefresh()
        await coordinator.test_handleCodexNativeEvent(.tokenUsage(.init(modelContextWindow: 200_000, lastTotalTokens: 1200, totalTotalTokens: 1200)), session: predecessor)
        XCTAssertEqual(viewModel.test_pendingUIRefreshScopes(for: predecessor.tabID), [.runtimeMetrics])
        XCTAssertEqual(predecessor.contextUsageSnapshot?.used, 1200)

        viewModel.setAgentRunActive(predecessor, isActive: false)
        viewModel.removePendingUIRefresh(for: predecessor.tabID)
        let replacement = AgentTabSession(tabID: predecessor.tabID)
        viewModel.test_installLiveSession(replacement)
        await coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "turn-one"), session: predecessor)
        await coordinator.test_handleCodexNativeEvent(.tokenUsage(.init(modelContextWindow: 200_000, lastTotalTokens: 7200, totalTotalTokens: 7200)), session: predecessor)
        XCTAssertEqual(predecessor.contextUsageSnapshot?.used, 7200)
        XCTAssertNotNil(predecessor.activeAgentRunStartedAt, "Originating runtime state remains independent of the replacement UI")
        XCTAssertFalse(viewModel.tabsWithActiveAgentRun.contains(replacement.tabID))
        XCTAssertEqual(viewModel.test_pendingUIRefreshScopes(for: replacement.tabID), [])
        XCTAssertNil(replacement.contextUsageSnapshot)
        XCTAssertNil(replacement.activeAgentRunStartedAt)
        await predecessor.codexController?.shutdown()
        await viewModel.prepareForWindowClose()
    }

    private func makeCoordinator(scope: AgentSessionRuntimeStore.Scope) -> CodexAgentModeCoordinator {
        let coordinator = CodexAgentModeCoordinator(
            windowID: -901, runtimeWorkspacePathsProvider: { _ in .uniform(nil) },
            codexControllerFactory: { _, _, _, _, _, _, _, _ in fatalError("Event handling must not launch a controller") },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            shouldManageCodexTooling: false, codexHookApprovalSettings: GlobalSettingsStore.shared
        )
        coordinator.installUsageRuntime(scope.usage)
        coordinator.installPresentationRuntime(scope.presentation)
        return coordinator
    }
}

@MainActor
final class AgentSessionHandoffRuntimeTests: XCTestCase {
    func testWindowFreeRecoveryRetainsExactScopeAndDoesNotOverwriteAnotherPreparation() throws {
        var scope: AgentSessionRuntimeStore.Scope? = AgentSessionRuntimeStore().makeScope()
        weak let weakScope = scope
        let session = AgentTabSession(tabID: UUID())
        scope?.replaceSessions([session.tabID: session])
        let runtime = try XCTUnwrap(scope?.handoff)
        var first = runtime.prepareRecovery(for: session, sourceTabName: "A & B", transcriptXML: "<transcript>first</transcript>")
        let second = try XCTUnwrap(runtime.prepareRecovery(for: session, sourceTabName: "other", transcriptXML: "stale"))
        scope = nil
        XCTAssertNotNil(weakScope)
        let staged = try XCTUnwrap(try runtime.stageRecovery(XCTUnwrap(first), initialThreadContextBlock: "<file_map>root</file_map>"))
        XCTAssertTrue(try XCTUnwrap(staged.payload).contains("source=\"A &amp; B\""))
        XCTAssertTrue(try XCTUnwrap(staged.payload).contains("<original_thread_context>"))
        XCTAssertTrue(try XCTUnwrap(staged.payload).contains("<transcript>first</transcript>"))
        XCTAssertNil(runtime.stageRecovery(second, initialThreadContextBlock: "wrong context"))
        XCTAssertEqual(session.pendingHandoff, staged)
        XCTAssertTrue(session.isDirty)
        first = nil
        // The second outstanding preparation still owns its exact scope until its caller finishes.
        withExtendedLifetime(second) { XCTAssertNotNil(weakScope) }
    }

    func testRecoveryRefusesChangedIncarnationsInputsAndHandoffABA() throws {
        enum Mutation: CaseIterable { case rebind, replace, stop, retirement, handoff, handoffABA }
        for mutation in Mutation.allCases {
            let scope = AgentSessionRuntimeStore().makeScope()
            let session = AgentTabSession(tabID: UUID())
            let binding = AgentPersistentSessionBindingIdentity(tabID: session.tabID, sessionID: UUID(), workspaceID: UUID())
            session.installPersistentSessionBinding(binding)
            scope.replaceSessions([session.tabID: session])
            let runtime = scope.handoff
            let preparation = try XCTUnwrap(runtime.prepareRecovery(for: session, sourceTabName: "source", transcriptXML: "old transcript"))
            switch mutation {
            case .rebind:
                session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: binding.sessionID, workspaceID: binding.workspaceID))
            case .replace:
                let replacement = AgentTabSession(tabID: session.tabID)
                replacement.installPersistentSessionBinding(binding)
                scope.replaceSessions([replacement.tabID: replacement])
            case .stop: session.stopState.invalidateScheduledStarts()
            case .retirement: scope.beginRetirement()
            case .handoff: session.pendingHandoff.payload = "newer handoff"
            case .handoffABA:
                let original = session.pendingHandoff
                session.pendingHandoff.payload = "intervening handoff"
                session.pendingHandoff = original
            }
            let expected = session.pendingHandoff
            let dirty = session.isDirty
            XCTAssertNil(runtime.stageRecovery(preparation, initialThreadContextBlock: "stale context"), "\(mutation)")
            XCTAssertEqual(session.pendingHandoff, expected, "\(mutation)")
            XCTAssertEqual(session.isDirty, dirty, "Refused preparation is not a new mutation: \(mutation)")
            if mutation == .replace {
                XCTAssertNil(scope.sessions[session.tabID]?.pendingHandoff.payload)
            }
        }
    }

    func testCancelledContextWaitCannotStageAndReleasesScopeAfterCompletion() async throws {
        var scope: AgentSessionRuntimeStore.Scope? = AgentSessionRuntimeStore().makeScope()
        weak let weakScope = scope
        let session = AgentTabSession(tabID: UUID())
        scope?.replaceSessions([session.tabID: session])
        let runtime = try XCTUnwrap(scope?.handoff)
        var preparation = runtime.prepareRecovery(for: session, sourceTabName: "source", transcriptXML: "transcript")
        let gate = TestReleaseFence(name: "handoff context IO")
        XCTAssertNotNil(preparation)
        let task = Task { [preparation] in
            await gate.enterAndWait()
            guard let preparation else { return nil as AgentPendingHandoffState? }
            return runtime.stageRecovery(preparation, initialThreadContextBlock: "late context")
        }
        addTeardownBlock { gate.release() }
        preparation = nil
        scope = nil
        guard await gate.waitUntilEntered() else { return XCTFail("Recovery context IO was never entered") }
        XCTAssertNotNil(weakScope, "Pending context work retains its exact owner, not a presentation")
        task.cancel()
        gate.release()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertNil(session.pendingHandoff.payload)
        XCTAssertNil(weakScope, "The finished request must release its scope")
    }

    func testCutoffSnapshotSurvivesLaterRowsAndModelOnlyChangeAndAdmissionIsLazy() throws {
        let scope = AgentSessionRuntimeStore().makeScope()
        let session = AgentTabSession(tabID: UUID())
        scope.replaceSessions([session.tabID: session])
        let runtime = scope.handoff
        var builds = 0
        func transcript() -> String {
            builds += 1
            return "captured transcript"
        }
        let preparation = try XCTUnwrap(runtime.prepareRecovery(for: session, sourceTabName: "source", transcriptXML: transcript()))
        session.items.append(.init(kind: .user, text: "later input"))
        session.selectedModelRaw = "new-model"
        let staged = try XCTUnwrap(runtime.stageRecovery(preparation, initialThreadContextBlock: nil))
        XCTAssertTrue(try XCTUnwrap(staged.payload).contains("captured transcript"))
        XCTAssertFalse(try XCTUnwrap(staged.payload).contains("later input"))
        XCTAssertTrue(runtime.canReuseRecovery(for: session))
        XCTAssertNil(runtime.prepareRecovery(for: session, sourceTabName: "source", transcriptXML: transcript()))
        XCTAssertEqual(builds, 1, "An existing handoff must not rebuild the transcript")
        session.pendingHandoff = .init()
        _ = session.beginPersistentBindingTransition()
        XCTAssertFalse(runtime.canReuseRecovery(for: session))
        XCTAssertNil(runtime.prepareRecovery(for: session, sourceTabName: "source", transcriptXML: transcript()))
        XCTAssertEqual(builds, 1, "An unadmitted binding must not build recovery context")
    }

    func testMissingRecoveryHostCannotStartContextlessClaudeReplacement() async {
        let session = AgentTabSession(tabID: UUID())
        session.hasLoadedPersistedState = true
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        session.selectedAgent = .claudeCode
        session.providerSessionID = "missing-original-session"
        let controller = MonitorFakeNativeController()
        await controller.setRejectResume(true)
        var creations = 0
        let coordinator = ClaudeAgentModeCoordinator(
            windowID: -903, workspacePathProvider: { _ in nil },
            claudeControllerFactory: { _, _, _, _ in creations += 1
                return controller
            }
        )
        let runID = UUID()
        session.installRunID(runID)
        let owner = session.beginRunAttempt(source: "test.handoff.missingHost")
        let result = await coordinator.ensureClaudeNativeSession(session: session, intent: .runAttempt(ownership: owner, runID: runID))
        XCTAssertNotEqual(result, .ready)
        XCTAssertEqual(creations, 1, "No fresh controller without acknowledged recovery preparation")
        let attempts = await controller.startOrResumeExistingSessionIDs
        XCTAssertEqual(attempts, ["missing-original-session"])
        XCTAssertEqual(session.providerSessionID, "missing-original-session")
        await controller.shutdown()
    }

    func testConsumptionKeepsFailureMarkerAndCannotTouchRecycledTab() {
        let scope = AgentSessionRuntimeStore().makeScope()
        let session = AgentTabSession(tabID: UUID())
        scope.replaceSessions([session.tabID: session])
        let runtime = scope.handoff
        session.pendingHandoff = .init(payload: " recovery ", executionLocationFailure: "worktree unavailable")
        XCTAssertEqual(runtime.prependPendingHandoffIfNeeded("input", session: session), "recovery\n\ninput")
        XCTAssertEqual(runtime.prependPendingHandoffIfNeeded("input", session: session), "input")
        runtime.recordSendOutcome(for: session, didSend: false)
        XCTAssertFalse(session.pendingHandoff.isStagedForSend)
        XCTAssertNotNil(session.pendingHandoff.payload)
        _ = runtime.prependPendingHandoffIfNeeded("retry", session: session)
        runtime.recordSendOutcome(for: session, didSend: true)
        XCTAssertNil(session.pendingHandoff.payload)
        XCTAssertEqual(session.pendingHandoff.executionLocationFailure, "worktree unavailable")
        XCTAssertTrue(session.isDirty)
        session.pendingHandoff = .init(payload: "old", isStagedForSend: true)
        let replacement = AgentTabSession(tabID: session.tabID)
        replacement.pendingHandoff = .init(payload: "new", isStagedForSend: true)
        scope.replaceSessions([replacement.tabID: replacement])
        runtime.recordSendOutcome(for: session, didSend: true)
        XCTAssertEqual(session.pendingHandoff.payload, "old")
        XCTAssertEqual(replacement.pendingHandoff.payload, "new")
        XCTAssertEqual(runtime.prependPendingHandoffIfNeeded("input", session: session), "input")
    }
}
