import AppKit
import Foundation
import RepoPromptAIContracts
@testable import RepoPromptApp
import RepoPromptDomainRuntime
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
        weak var scope = f.scope
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
        weak var scope = fixture?.scope
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
        let attachment = f.scope.presentation.attach(f.session, sink: .init(activityChanged: { _, _ in }, refresh: { _, _ in refreshes += 1 }, turnComplete: { _ in }, turnFailed: { _, _ in }))
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
            weak var scope = fixture?.scope
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
        _ = f.scope.presentation.attach(successor, sink: .init(activityChanged: { _, _ in }, refresh: { _, _ in successorRefreshes += 1 }, turnComplete: { _ in }, turnFailed: { _, _ in }))
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
            activityChanged: { _, _ in }, refresh: { _, _ in }, turnComplete: { _ in }, turnFailed: { _, _ in },
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
