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
    func testClaudeReasoningPreviewAccumulatesChunksAndBoundsBufferAfterFullBlock() {
        let viewModel = AgentModeViewModel(
            testWorkspacePath: NSTemporaryDirectory(),
            codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) }
        )
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        // Exercise immediate updates to an already visible reasoning status, without a timer.
        _ = session.setRunningStatus("Thinking", source: .reasoning)
        let deltas = ["First line\nInvest", "igating the ", "parser."]
        for delta in deltas {
            XCTAssertTrue(viewModel.test_applyClaudeReasoningStatusDelta(delta, session: session))
        }
        let fullBlock = deltas.joined()
        XCTAssertEqual(session.claudeReasoningStatusBuffer, fullBlock)
        XCTAssertEqual(session.runningStatusText, "Investigating the parser.")

        // The translator can emit the complete multiline thinking block after its chunks.
        XCTAssertFalse(viewModel.test_applyClaudeReasoningStatusDelta(fullBlock, session: session))
        XCTAssertEqual(session.runningStatusText, "Investigating the parser.")

        let oversizedDelta = String(repeating: "🧠", count: 4000) + "\nLatest "
        XCTAssertTrue(viewModel.test_applyClaudeReasoningStatusDelta(oversizedDelta, session: session))
        XCTAssertEqual(session.claudeReasoningStatusBuffer.count, 4000)
        XCTAssertTrue(viewModel.test_applyClaudeReasoningStatusDelta("bounded line", session: session))
        XCTAssertEqual(session.claudeReasoningStatusBuffer, String((oversizedDelta + "bounded line").suffix(4000)))
        XCTAssertEqual(session.claudeReasoningStatusBuffer.count, 4000)
        XCTAssertEqual(session.runningStatusText, "Latest bounded line")
        XCTAssertNil(session.claudeReasoningStatusFlushTask)
    }

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
    func testRecoveredEpochCancellationIsInstalledBeforeControlPublication() async throws {
        for refusal in ["cancel", "retire", "replacement", "installed"] {
            let cancelBeforePublication = refusal != "installed"
            let store = makeCancellationStore()
            let scope = AgentSessionRuntimeStore().makeScope()
            let session = AgentTabSession(tabID: UUID())
            let id = UUID(), activationID = UUID()
            session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: id, workspaceID: UUID()))
            session.recordRestorationAuthoritative(.persistedPayloadApplied)
            scope.replaceSessions([session.tabID: session])
            let original = await store.register(sessionID: id)
            await store.cleanup(registration: original)
            for invalid in [
                DomainAgentSessionRegistration(runtimeID: original.runtimeID, runtimeGeneration: original.runtimeGeneration + 1, sessionID: id, generation: original.generation),
                DomainAgentSessionRegistration(runtimeID: original.runtimeID, runtimeGeneration: original.runtimeGeneration, sessionID: id, generation: 0)
            ] {
                let admitted = await store.registerIfMissing(recovering: invalid) { _ in
                    XCTFail("Invalid recovery must not install a cancellation capability")
                }
                XCTAssertNil(admitted)
            }
            session.mcpControlContext = try .init(
                sessionID: id, activationID: activationID, writerIdentity: controlWriterIdentity(for: session, scope: scope), registration: original,
                currentEpoch: nil, preparedEpoch: nil, pendingEpochTransition: nil,
                originatingConnectionID: nil, interactionTransport: .mcp(sessionID: id, originatingConnectionID: nil),
                suppressUserNotifications: true, forceAutoEditEnabled: false, autoEditEnabledBeforeOverride: false, taskLabelKind: nil, autoEditOverride: nil
            )
            let foreignStore = makeCancellationStore()
            await scope.mcp.prepareRunEpoch(
                session: session, stopFence: .init(session: session), transitionToken: nil, store: foreignStore,
                cancelInstalledRun: { _ in XCTFail("A foreign authority cannot own recovery cancellation") }
            )
            let foreignRegistration = await foreignStore.currentRegistration(for: id)
            XCTAssertNil(foreignRegistration, "A foreign runtime must not turn a rejected epoch into local admission")
            XCTAssertEqual(session.mcpControlContext?.registration, original)
            _ = await foreignStore.shutdown()
            var cancellations = 0
            var recovered: AgentRunSessionStore.Registration?
            await scope.mcp.prepareRunEpoch(
                session: session, stopFence: .init(session: session), transitionToken: nil, store: store,
                cancelInstalledRun: { exact in
                    XCTAssertIdentical(exact, session)
                    cancellations += 1
                }, afterEpochBegan: {
                    recovered = await store.currentRegistration(for: id)
                    XCTAssertNotEqual(recovered, original)
                    XCTAssertEqual(session.mcpControlContext?.registration, original)
                    if refusal == "cancel", let recovered {
                        let handled = await store.test_invokeCancellationHandler(registration: recovered)
                        XCTAssertTrue(handled, "Recovery must install cancellation in the registration actor turn")
                    } else if refusal == "retire" {
                        scope.beginRetirement()
                    } else if refusal == "replacement" {
                        let replacement = AgentTabSession(tabID: session.tabID)
                        scope.replaceSessions([replacement.tabID: replacement])
                    }
                }
            )
            let registration = try XCTUnwrap(recovered)
            if cancelBeforePublication {
                XCTAssertEqual(cancellations, 0, "A pending replacement must not cancel the previous context")
                XCTAssertEqual(session.mcpControlContext?.registration, original)
                XCTAssertNil(session.mcpControlContext?.preparedEpoch)
                let current = await store.currentRegistration(for: id)
                XCTAssertNil(current, "Cancelled recovery must release its own registration")
            } else {
                XCTAssertEqual(session.mcpControlContext?.registration, registration)
                XCTAssertNotNil(session.mcpControlContext?.preparedEpoch)
                let handled = await store.test_invokeCancellationHandler(registration: registration)
                XCTAssertTrue(handled)
                XCTAssertEqual(cancellations, 1)
                session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: id, workspaceID: UUID()))
                _ = await store.test_invokeCancellationHandler(registration: registration)
                XCTAssertEqual(cancellations, 1, "Recovery cancellation must not reach a rebound incarnation")
                await store.cleanup(registration: registration)
            }
            _ = await store.shutdown()
        }
    }

    func testRecoveredEpochAcceptedBeforeStopIsRetainedWithoutStartingFollowUp() async throws {
        let store = makeCancellationStore()
        let scope = AgentSessionRuntimeStore().makeScope()
        let session = AgentTabSession(tabID: UUID())
        let id = UUID()
        session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: id, workspaceID: UUID()))
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        scope.replaceSessions([session.tabID: session])
        let original = await store.register(sessionID: id)
        await store.cleanup(registration: original)
        session.mcpControlContext = try .init(
            sessionID: id, activationID: UUID(), writerIdentity: controlWriterIdentity(for: session, scope: scope), registration: original,
            currentEpoch: nil, preparedEpoch: nil, pendingEpochTransition: nil,
            originatingConnectionID: nil, interactionTransport: .mcp(sessionID: id, originatingConnectionID: nil),
            suppressUserNotifications: true, forceAutoEditEnabled: false, autoEditEnabledBeforeOverride: false, taskLabelKind: nil, autoEditOverride: nil
        )
        await scope.mcp.prepareRunEpoch(
            session: session, stopFence: .init(session: session), transitionToken: nil, store: store,
            cancelInstalledRun: { _ in XCTFail("Local Stop fencing must not invoke shutdown cancellation") },
            afterEpochBegan: { session.stopState.invalidateScheduledStarts() }
        )
        let registration = try XCTUnwrap(session.mcpControlContext?.registration)
        XCTAssertNotEqual(registration, original)
        let actualEpoch = await store.currentEpoch(for: registration)
        XCTAssertNotNil(actualEpoch)
        XCTAssertEqual(session.mcpControlContext?.currentEpoch, actualEpoch)
        XCTAssertEqual(session.mcpControlContext?.preparedEpoch, actualEpoch)
        XCTAssertFalse(session.mcpFollowUpRunPending)
        await store.cleanup(registration: registration)
        _ = await store.shutdown()
    }

    func testAcceptedOriginalEpochIsReconciledAfterScopeMembershipChanges() async throws {
        let store = makeCancellationStore()
        let scope = AgentSessionRuntimeStore().makeScope()
        let session = AgentTabSession(tabID: UUID())
        let id = UUID()
        session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: id, workspaceID: UUID()))
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        scope.replaceSessions([session.tabID: session])
        let original = await store.register(sessionID: id)
        session.mcpControlContext = try .init(
            sessionID: id, activationID: UUID(), writerIdentity: controlWriterIdentity(for: session, scope: scope), registration: original,
            currentEpoch: nil, preparedEpoch: nil, pendingEpochTransition: nil,
            originatingConnectionID: nil, interactionTransport: .mcp(sessionID: id, originatingConnectionID: nil),
            suppressUserNotifications: true, forceAutoEditEnabled: false, autoEditEnabledBeforeOverride: false, taskLabelKind: nil, autoEditOverride: nil
        )
        await scope.mcp.prepareRunEpoch(
            session: session, stopFence: .init(session: session), transitionToken: nil, store: store,
            cancelInstalledRun: { _ in XCTFail("An existing registration must not be replaced") },
            afterEpochBegan: { scope.replaceSessions([:]) }
        )
        let actualEpoch = await store.currentEpoch(for: original)
        XCTAssertNotNil(actualEpoch)
        XCTAssertEqual(session.mcpControlContext?.currentEpoch, actualEpoch)
        XCTAssertEqual(session.mcpControlContext?.preparedEpoch, actualEpoch)
        XCTAssertFalse(session.mcpFollowUpRunPending, "Only the original epoch is reconciled, not a successor start")
        await store.cleanup(registration: original)
        _ = await store.shutdown()
    }

    func testControlContextCannotAuthorizeAReacquiredClaimOrCopiedObject() async throws {
        let f = try await makeFixture()
        let original = try XCTUnwrap(f.scope.mcp.controlledWriter(sessionID: f.sessionID))
        let context = try XCTUnwrap(f.session.mcpControlContext)
        XCTAssertEqual(context.writerIdentity, original.identity)
        XCTAssertEqual(context.replacingRegistration(f.registration).writerIdentity, original.identity)
        XCTAssertNotNil(f.scope.mcp.registration(sessionID: f.sessionID))

        let copy = AgentTabSession(tabID: UUID())
        copy.mcpControlContext = context
        f.scope.replaceSessions([f.session.tabID: f.session, copy.tabID: copy])
        XCTAssertTrue(original.isCurrent, "An unbound copy is not a persistent writer")
        XCTAssertNil(f.scope.mcp.controlledWriter(sessionID: f.sessionID), "Control ambiguity still vetoes routing")
        XCTAssertEqual(
            f.scope.mcp.registration(sessionID: f.sessionID),
            context.registration,
            "An unbound copy cannot hide the exact installed read receipt"
        )
        XCTAssertNotNil(f.scope.mcp.mcpReadSnapshot(for: f.session))
        XCTAssertNil(f.scope.mcp.mcpReadSnapshot(for: copy))
        f.scope.replaceSessions([f.session.tabID: f.session])
        XCTAssertNotNil(f.scope.mcp.controlledWriter(sessionID: f.sessionID))

        let binding = f.session.currentRestorationBindingToken
        f.scope.replaceSessions([:])
        XCTAssertNil(f.scope.mcp.registration(sessionID: f.sessionID), "A released claim really is expired")
        XCTAssertNil(f.scope.mcp.waitCursor(sessionID: f.sessionID))
        XCTAssertNil(f.scope.mcp.mcpReadSnapshot(for: f.session))
        f.scope.replaceSessions([f.session.tabID: f.session])
        guard case let .unique(successor) = f.scope.resolveWriter(sessionID: f.sessionID),
              case let .success(command) = successor.admitCommand() else { return XCTFail("Expected the new writer") }
        XCTAssertEqual(f.session.currentRestorationBindingToken, binding)
        XCTAssertNotEqual(successor.identity, context.writerIdentity)
        XCTAssertNil(f.scope.mcp.controlledWriter(sessionID: f.sessionID))
        XCTAssertNil(f.scope.mcp.registration(sessionID: f.sessionID))
        XCTAssertNil(f.scope.mcp.waitCursor(sessionID: f.sessionID))
        XCTAssertNil(f.scope.mcp.mcpSnapshot(for: f.session))
        XCTAssertNil(f.scope.mcp.mcpReadSnapshot(for: f.session), "Reads cannot adopt a superseded control incarnation")
        XCTAssertFalse(f.scope.mcp.mcpControlContextMatches(tabID: f.session.tabID, sessionID: f.sessionID, activationID: context.activationID, registration: f.registration))
        f.scope.mcp.setFollowUpRunPending(sessionID: f.sessionID, true)
        XCTAssertFalse(f.session.mcpFollowUpRunPending)
        XCTAssertNil(f.scope.mcp.stageEpochTransition(command: command, kind: .relatedFollowUp))
        f.session.runState = .completed
        await f.scope.mcp.prepareRunEpoch(
            session: f.session, stopFence: .init(session: f.session), transitionToken: nil,
            store: AgentRunSessionStore.shared,
            cancelInstalledRun: { _ in XCTFail("The stale context cannot acquire new cancellation ownership") },
            afterEpochBegan: { XCTFail("A fresh command does not adopt an old control context") }
        )
        XCTAssertEqual(f.session.mcpControlContext, context)
        let epoch = await AgentRunSessionStore.currentEpoch(for: f.registration)
        XCTAssertEqual(epoch, f.epoch)
        let stale = try XCTUnwrap(f.scope.mcp.controlSessionForTeardown(sessionID: f.sessionID))
        let removed = await f.scope.mcp.deactivateControlContext(
            session: stale, expectedContext: context, approvalStore: ApplyEditsApprovalStore(),
            cleanupRegistration: true, requireInactive: true
        )
        XCTAssertTrue(removed, "Teardown can release the obsolete receipt without admitting new work")
        XCTAssertNil(f.session.mcpControlContext)
        let registration = await AgentRunSessionStore.currentRegistration(for: f.sessionID)
        XCTAssertNil(registration)
        let ordinaryStart = await f.scope.mcp.prepareWaitTrackingForRunStart(session: f.session, stopFence: .init(session: f.session))
        XCTAssertTrue(ordinaryStart, "A removed stale context must not permanently block ordinary starts")
    }

    func testCrossScopeCopiedControlCannotReleaseStructuralHolderDuringConflict() async throws {
        for (conflictingClaim, sharesRegistration) in [(false, true), (true, true), (false, false), (true, false)] {
            let store = AgentSessionRuntimeStore()
            let approvals = ApplyEditsApprovalStore()
            let address = ApplyEditsApprovalScope(windowID: 42, tabID: UUID())
            await approvals.setAutoEditEnabled(false, for: address, updateGlobalDefault: false)
            let override = await approvals.prepareAutoEditOverride(for: address)
            let applied = await approvals.applyAutoEditOverride(override)
            XCTAssertTrue(applied)
            let f = try await makeFixture(store: store, autoEditOverride: override)
            let context = try XCTUnwrap(f.session.mcpControlContext)
            let otherRegistration = await AgentRunSessionStore.register(sessionID: UUID())
            addTeardownBlock { await AgentRunSessionStore.cleanup(registration: otherRegistration) }
            let copiedContext = sharesRegistration ? context : context.replacingRegistration(otherRegistration)
            let original = try XCTUnwrap(f.scope.mcp.controlledWriter(sessionID: f.sessionID))
            let other = store.makeScope()
            let copy = AgentTabSession(tabID: UUID())
            copy.mcpControlContext = copiedContext
            other.replaceSessions([copy.tabID: copy])
            if conflictingClaim {
                XCTAssertEqual(other.bindingRejection(f.sessionID, on: copy), .conflictingWriter)
                // Bypass admission only to model corrupt competing claims. Production must refuse this.
                copy.installPersistentSessionBinding(.init(
                    tabID: copy.tabID, sessionID: f.sessionID, workspaceID: original.identity.workspaceID
                ))
                guard case .conflicting = store.resolveWriter(sessionID: f.sessionID) else {
                    return XCTFail("Expected raw conflict")
                }
                XCTAssertFalse(original.ownsPersistentClaim)
            }
            let removedCopy = await other.mcp.deactivateControlContext(
                session: copy, expectedContext: copiedContext, approvalStore: approvals, cleanupRegistration: true
            )
            XCTAssertFalse(removedCopy, "A copied context cannot release the structural holder's resources")
            XCTAssertEqual(copy.mcpControlContext, copiedContext)
            let protectedOverride = await approvals.autoEditEnabled(for: address)
            XCTAssertTrue(protectedOverride, "Protection must cover approval receipts independently of registration equality")
            let current = await AgentRunSessionStore.currentRegistration(for: f.sessionID)
            XCTAssertEqual(current, f.registration)
            XCTAssertEqual(f.session.mcpControlContext, context)

            f.session.runState = .completed
            let removedOwner = await f.scope.mcp.deactivateControlContext(
                session: f.session, expectedContext: context, approvalStore: approvals, cleanupRegistration: true
            )
            XCTAssertTrue(removedOwner, "A raw conflict must not turn the copied receipt into a cleanup owner")
            let released = await AgentRunSessionStore.currentRegistration(for: f.sessionID)
            XCTAssertNil(released)
            let restored = await approvals.autoEditEnabled(for: address)
            XCTAssertFalse(restored)
            XCTAssertEqual(copy.mcpControlContext, copiedContext)
        }
    }

    func testOriginControlLookupSurvivesRetirementAndBindingPreparationButNotNewWork() async throws {
        let f = try await makeFixture()
        let writer = try XCTUnwrap(f.scope.mcp.controlledWriter(sessionID: f.sessionID))
        f.scope.mcp.setFollowUpRunPending(sessionID: f.sessionID, true)
        XCTAssertTrue(f.session.mcpFollowUpRunPending)
        f.scope.beginRetirement()
        f.scope.mcp.setFollowUpRunPending(sessionID: f.sessionID, false)
        XCTAssertFalse(f.session.mcpFollowUpRunPending, "Originating cleanup drains retirement")
        XCTAssertEqual(f.scope.mcp.controlledWriter(sessionID: f.sessionID)?.identity, writer.identity)
        f.scope.mcp.setFollowUpRunPending(sessionID: f.sessionID, true)
        XCTAssertFalse(f.session.mcpFollowUpRunPending)
        _ = f.session.beginPersistentBindingTransition()
        XCTAssertTrue(writer.ownsPersistentClaim)
        f.session.mcpFollowUpRunPending = true
        f.scope.mcp.setFollowUpRunPending(sessionID: f.sessionID, false)
        XCTAssertFalse(f.session.mcpFollowUpRunPending, "Originating cleanup drains binding preparation")
        XCTAssertEqual(f.scope.mcp.controlledWriter(sessionID: f.sessionID)?.identity, writer.identity)
        XCTAssertEqual(
            f.scope.mcp.registration(sessionID: f.sessionID),
            f.registration,
            "An originating control read survives binding preparation"
        )
        XCTAssertEqual(f.scope.mcp.waitCursor(sessionID: f.sessionID)?.registration, f.registration)
        XCTAssertNotNil(f.scope.mcp.mcpReadSnapshot(for: f.session))
        XCTAssertNil(f.scope.mcp.mcpSnapshot(for: f.session), "Publication still requires the current writer")
    }

    func testStagedEpochCleanupUsesOriginatingWriterAndTransitionReceipt() async throws {
        for change in ["retiring", "detached", "reacquired", "rebound", "successor", "prepared"] {
            let f = try await makeFixture()
            guard case let .unique(writer) = f.scope.resolveWriter(sessionID: f.sessionID),
                  case let .success(command) = writer.admitCommand() else { return XCTFail("Expected an admitted writer") }
            let staged = try XCTUnwrap(f.scope.mcp.stageEpochTransition(command: command, kind: .steering))
            XCTAssertEqual(f.session.mcpControlContext?.pendingEpochTransition?.token, staged.token)
            var successorToken: UUID?
            switch change {
            case "retiring": f.scope.beginRetirement()
            case "detached": f.scope.replaceSessions([:])
            case "reacquired":
                f.scope.replaceSessions([:])
                f.scope.replaceSessions([f.session.tabID: f.session])
            case "rebound":
                f.session.installPersistentSessionBinding(.init(tabID: f.session.tabID, sessionID: f.sessionID, workspaceID: writer.identity.workspaceID))
            case "successor":
                successorToken = try XCTUnwrap(f.scope.mcp.stageEpochTransition(command: command, kind: .relatedFollowUp)).token
            default: f.session.mcpControlContext?.preparedEpoch = f.epoch
            }
            f.scope.mcp.clearStagedEpochTransition(staged)
            if change == "retiring" || change == "detached" {
                XCTAssertNil(f.session.mcpControlContext?.pendingEpochTransition, "Admitted cleanup must drain: \(change)")
            } else {
                XCTAssertEqual(f.session.mcpControlContext?.pendingEpochTransition?.token, successorToken ?? staged.token, change)
            }
            if change != "successor", change != "prepared" {
                XCTAssertNil(f.scope.mcp.stageEpochTransition(command: command, kind: .steering), "Stale commands cannot stage: \(change)")
            }
        }
    }

    func testEpochTransitionTaskLocalAndFailureCleanupAreRuntimeOwned() async throws {
        enum Refusal: Error { case refused }
        let f = try await makeFixture()
        guard case let .unique(writer) = f.scope.resolveWriter(sessionID: f.sessionID),
              case let .success(command) = writer.admitCommand() else { return XCTFail("Expected an admitted writer") }
        XCTAssertNil(AgentSessionMCPRuntime.epochTransitionToken.get())
        do {
            try await f.scope.mcp.withEpochTransition(command: command, kind: .steering) {
                let token = try XCTUnwrap(AgentSessionMCPRuntime.epochTransitionToken.get())
                XCTAssertEqual(f.session.mcpControlContext?.pendingEpochTransition?.token, token)
                f.scope.beginRetirement()
                throw Refusal.refused
            }
            XCTFail("Expected the originating error")
        } catch Refusal.refused {}
        XCTAssertNil(f.session.mcpControlContext?.pendingEpochTransition)
        XCTAssertNil(AgentSessionMCPRuntime.epochTransitionToken.get())
        XCTAssertTrue(writer.isCurrent, "Retirement does not suppress originating cleanup")
    }

    func testEpochAdmissionAndAcknowledgementCannotCrossWriterIncarnations() async throws {
        for refusal in ["unrestored", "retiring", "conflict", "reacquired"] {
            let domain = makeCancellationStore()
            let writers = AgentSessionRuntimeStore()
            let scope = writers.makeScope()
            let session = scope.makeSession(tabID: UUID())
            let id = UUID(), workspaceID = UUID()
            session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: id, workspaceID: workspaceID))
            if refusal != "unrestored" { session.recordRestorationAuthoritative(.persistedPayloadApplied) }
            scope.replaceSessions([session.tabID: session])
            let registration = await domain.register(sessionID: id)
            session.mcpControlContext = try .init(
                sessionID: id, activationID: UUID(), writerIdentity: controlWriterIdentity(for: session, scope: scope), registration: registration,
                currentEpoch: nil, preparedEpoch: nil, pendingEpochTransition: nil,
                originatingConnectionID: nil, interactionTransport: .mcp(sessionID: id, originatingConnectionID: nil),
                suppressUserNotifications: true, forceAutoEditEnabled: false, autoEditEnabledBeforeOverride: false, taskLabelKind: nil, autoEditOverride: nil
            )
            let competitor = writers.makeScope()
            if refusal == "retiring" { scope.beginRetirement() }
            if refusal == "conflict" {
                let replica = competitor.makeSession(tabID: UUID())
                // Deliberately model a legacy competing claim; normal binding admission refuses it.
                replica.installPersistentSessionBinding(.init(tabID: replica.tabID, sessionID: id, workspaceID: workspaceID))
                competitor.replaceSessions([replica.tabID: replica])
            }
            var admitted = 0
            await scope.mcp.prepareRunEpoch(
                session: session, stopFence: .init(session: session), transitionToken: nil, store: domain,
                cancelInstalledRun: { _ in XCTFail("An existing registration must not be recovered") },
                afterEpochBegan: {
                    admitted += 1
                    XCTAssertEqual(refusal, "reacquired")
                    let binding = session.currentRestorationBindingToken
                    scope.replaceSessions([:])
                    scope.replaceSessions([session.tabID: session])
                    XCTAssertEqual(session.currentRestorationBindingToken, binding, "Only the runtime claim changed")
                }
            )
            XCTAssertEqual(admitted, refusal == "reacquired" ? 1 : 0, refusal)
            let durableEpoch = await domain.currentEpoch(for: registration)
            XCTAssertEqual(durableEpoch != nil, refusal == "reacquired", refusal)
            XCTAssertNil(session.mcpControlContext?.preparedEpoch, "Never publish into a successor claim: \(refusal)")
            XCTAssertNil(session.mcpControlContext?.currentEpoch)
            XCTAssertFalse(session.mcpFollowUpRunPending)
            withExtendedLifetime(competitor) {}
            await domain.cleanup(registration: registration)
            _ = await domain.shutdown()
        }
    }

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
            guard case let .unique(writer) = try XCTUnwrap(scope).resolveWriter(sessionID: sessionID) else {
                return XCTFail("Expected an exclusive cancellation writer")
            }
            let capability = AgentSessionMCPRuntime.ControlActivationCancellation(
                writer: writer, activationID: activationID
            ) { exact in
                XCTAssertIdentical(exact, session)
                cancellations += 1
            }
            session.hasLoadedPersistedState = true
            session.recordRestorationAuthoritative(.persistedPayloadApplied)
            session.isDirty = true
            XCTAssertTrue(writer.isCurrent, "Hydration/readiness and dirty projections do not rotate the live claim")
            XCTAssertTrue(capability.permitsPublication)
            registration = await store.register(sessionID: sessionID) { await capability.cancel(registration: $0) }
        }
        session.mcpControlContext = try .init(
            sessionID: sessionID, activationID: activationID, writerIdentity: controlWriterIdentity(for: session, scope: scope), registration: registration,
            currentEpoch: nil, preparedEpoch: nil, pendingEpochTransition: nil,
            originatingConnectionID: nil, interactionTransport: .mcp(sessionID: sessionID, originatingConnectionID: nil),
            suppressUserNotifications: true, forceAutoEditEnabled: false, autoEditEnabledBeforeOverride: false, taskLabelKind: nil, autoEditOverride: nil
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

    func testControlCancellationRequiresTheOriginalExclusiveClaim() async throws {
        for introduceConflict in [false, true] {
            let f = try await makeFixture()
            guard case let .unique(writer) = f.scope.resolveWriter(sessionID: f.registration.sessionID) else {
                return XCTFail("Expected original writer")
            }
            var cancellations = 0
            let capability = try AgentSessionMCPRuntime.ControlActivationCancellation(
                writer: writer, activationID: XCTUnwrap(f.session.mcpControlContext).activationID
            ) { _ in cancellations += 1 }
            XCTAssertTrue(capability.permitsPublication)
            let binding = f.session.currentRestorationBindingToken
            let originalSessions = f.scope.sessions
            if introduceConflict {
                // Normal admission refuses this claim. Inject only to exercise legacy corruption.
                let replica = f.scope.makeSession(tabID: UUID())
                XCTAssertEqual(f.scope.bindingRejection(f.registration.sessionID, on: replica), .conflictingWriter)
                replica.installPersistentSessionBinding(.init(
                    tabID: replica.tabID, sessionID: f.registration.sessionID, workspaceID: writer.identity.workspaceID
                ))
                f.scope.replaceSessions(originalSessions.merging([replica.tabID: replica]) { original, _ in original })
            } else {
                let sessions = f.scope.sessions
                f.scope.replaceSessions([:])
                f.scope.replaceSessions(sessions)
            }
            XCTAssertEqual(f.session.currentRestorationBindingToken, binding)
            XCTAssertFalse(capability.permitsPublication)
            f.session.waitingPrompt = "Do not cancel successor work"
            await capability.cancel(registration: f.registration)
            XCTAssertEqual(cancellations, 0)
            XCTAssertEqual(f.session.waitingPrompt, "Do not cancel successor work")
            f.scope.replaceSessions(originalSessions)
        }
    }

    func testPendingActivationCancellationDoesNotCancelPreviouslyInstalledControl() async throws {
        let f = try await makeFixture()
        let previous = f.session.mcpControlContext
        var cancellations = 0
        guard case let .unique(writer) = f.scope.resolveWriter(sessionID: f.registration.sessionID) else {
            return XCTFail("Expected an exclusive cancellation writer")
        }
        let pending = AgentSessionMCPRuntime.ControlActivationCancellation(
            writer: writer, activationID: UUID()
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

    func testObservedQuestionStatePublishesWithoutWindowOrViewModel() async throws {
        let f = try await makeFixture()
        f.scope.observation.install(on: f.session)
        f.session.waitingPrompt = "Published by runtime observation"
        f.session.runState = .waitingForUser
        // Published properties notify before assignment, as in the original pipeline. This
        // subsequent observed field witnesses the fully installed wait state without a VM call.
        f.session.runningStatusText = "Waiting"
        let result = await AgentRunSessionStore.waitUntilInteresting(
            cursor: .init(registration: f.registration, epoch: f.epoch), timeoutSeconds: 3
        )
        guard case let .snapshotReady(snapshot) = result else { return XCTFail("Expected the observed interaction, got \(result)") }
        XCTAssertEqual(snapshot.status, .waitingForInput)
        XCTAssertEqual(snapshot.interaction?.prompt, "Published by runtime observation")
        XCTAssertEqual(snapshot.sessionID, f.sessionID)
        f.session.mcpStateObservationCancellable?.cancel()
        f.session.mcpStateObservationCancellable = nil
        await AgentRunSessionStore.cleanup(registration: f.registration)
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

    private func makeFixture(
        store: AgentSessionRuntimeStore? = nil, autoEditOverride: ApplyEditsApprovalStore.AutoEditOverride? = nil
    ) async throws -> Fixture {
        let fixture = try await Fixture.make(store: store ?? AgentSessionRuntimeStore(), autoEditOverride: autoEditOverride)
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

        static func make(store: AgentSessionRuntimeStore, autoEditOverride: ApplyEditsApprovalStore.AutoEditOverride?) async throws -> Fixture {
            let scope = store.makeScope()
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
            session.mcpControlContext = try .init(sessionID: sessionID, activationID: activationID, writerIdentity: controlWriterIdentity(for: session, scope: scope), registration: registration, currentEpoch: epoch, preparedEpoch: nil, pendingEpochTransition: nil, originatingConnectionID: nil, interactionTransport: .mcp(sessionID: sessionID, originatingConnectionID: nil), suppressUserNotifications: true, forceAutoEditEnabled: autoEditOverride != nil, autoEditEnabledBeforeOverride: false, taskLabelKind: .pair, autoEditOverride: autoEditOverride)
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
    private func questionSession(in scope: AgentSessionRuntimeStore.Scope, tabID: UUID = UUID()) -> AgentTabSession {
        let session = AgentTabSession(tabID: tabID)
        session.installPersistentSessionBinding(.init(tabID: tabID, sessionID: UUID(), workspaceID: UUID()))
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        scope.replaceSessions([tabID: session])
        return session
    }

    private func questionCommand(in scope: AgentSessionRuntimeStore.Scope?, for session: AgentTabSession) throws -> AgentSessionRuntimeStore.Command {
        let scope = try XCTUnwrap(scope)
        let sessionID = try XCTUnwrap(session.activeAgentSessionID)
        guard case let .unique(writer) = scope.resolveWriter(sessionID: sessionID), writer.session === session else {
            throw NSError(domain: "Expected exact question writer", code: 1)
        }
        return try writer.admitCommand().get()
    }

    private func runtimeQuestion() -> AgentAskUserInteraction {
        AgentAskUserInteraction(title: "Runtime question", timeoutSeconds: 600, questions: [
            AgentAskUserQuestion(id: "answer", question: "Which files?", options: [], allowsMultiple: false, allowsCustom: true)
        ])
    }

    private func observeQuestionInstallation(
        scope: AgentSessionRuntimeStore.Scope, session: AgentTabSession, installed: XCTestExpectation
    ) -> AgentSessionPresentationRuntime.Attachment {
        scope.presentation.attach(session, sink: .init(
            activityChanged: { _, _ in }, refresh: { _, _, _ in }, turnComplete: { _ in }, turnFailed: { _, _ in },
            binding: { session in
                if session.pendingAskUser != nil {
                    XCTAssertNotNil(session.askUserContinuation, "Publication must not precede its response/cancellation capability")
                    installed.fulfill()
                }
            }
        ))
    }

    func testProviderSwitchDeclineUsesOnlyItsOriginalLifecycleClaim() async throws {
        for drift in ["none", "released", "reacquired", "replacement", "other-scope"] {
            let scope = AgentSessionRuntimeStore().makeScope()
            let session = questionSession(in: scope)
            let runtime = scope.interactions(routeID: 42, approvalStore: ApplyEditsApprovalStore())
            let command = try questionCommand(in: scope, for: session)
            let target = try XCTUnwrap(scope.submissions.programmaticTarget(command))
            let attempt = AgentComposerSubmitAttempt(
                id: UUID(), target: target, inputRevision: 0, noticeRevision: 0, rawDraftSnapshot: ""
            )
            guard case let .claimed(claim) = scope.submissions.claim(
                attempt, command: command, allowsPendingStartWithdrawal: false
            ) else { return XCTFail("Expected lifecycle claim") }
            let question = runtimeQuestion()
            let installed = expectation(description: "Original question installed: \(drift)")
            let attachment = observeQuestionInstallation(scope: scope, session: session, installed: installed)
            let task = Task { try await runtime.askUser(command: command, interaction: question) }
            addTeardownBlock { @MainActor in
                task.cancel()
                _ = await task.result
                scope.submissions.release(claim)
                await runtime.drainPendingEffects(for: session)
            }
            await fulfillment(of: [installed], timeout: 3)
            scope.presentation.detach(attachment)
            var successorQuestionID: UUID?
            switch drift {
            case "released": scope.submissions.release(claim)
            case "reacquired":
                scope.replaceSessions([:])
                scope.replaceSessions([session.tabID: session])
            case "replacement":
                let successor = questionSession(in: scope, tabID: session.tabID)
                let successorCommand = try questionCommand(in: scope, for: successor)
                let successorQuestion = runtimeQuestion()
                successorQuestionID = successorQuestion.id
                let successorInstalled = expectation(description: "Successor question installed")
                let successorAttachment = observeQuestionInstallation(scope: scope, session: successor, installed: successorInstalled)
                let successorTask = Task { try await runtime.askUser(command: successorCommand, interaction: successorQuestion) }
                addTeardownBlock { @MainActor in
                    successorTask.cancel()
                    _ = await successorTask.result
                    await runtime.drainPendingEffects(for: successor)
                }
                await fulfillment(of: [successorInstalled], timeout: 3)
                scope.presentation.detach(successorAttachment)
            default: break
            }
            let otherScope = AgentSessionRuntimeStore().makeScope()
            let selectedRuntime = drift == "other-scope"
                ? otherScope.interactions(routeID: 43, approvalStore: ApplyEditsApprovalStore()) : runtime
            let accepted = selectedRuntime.declinePendingInteractionsForProviderSwitch(claim: claim)
            XCTAssertEqual(accepted, drift == "none", drift)
            if accepted {
                XCTAssertNil(session.pendingAskUser)
                XCTAssertNil(session.askUserContinuation)
                do { _ = try await task.value
                    XCTFail("Declined question must cancel")
                } catch { XCTAssertTrue(error is CancellationError) }
                XCTAssertTrue(scope.submissions.isCurrent(claim), "Interaction cleanup must not consume the lifecycle claim")
            } else {
                XCTAssertEqual(session.pendingAskUser?.interaction.id, question.id, drift)
                XCTAssertNotNil(session.askUserContinuation, drift)
                if drift == "replacement" {
                    XCTAssertEqual(scope.sessions[session.tabID]?.pendingAskUser?.interaction.id, successorQuestionID)
                    XCTAssertNotNil(scope.sessions[session.tabID]?.askUserContinuation)
                }
            }
            task.cancel()
            _ = await task.result
            scope.submissions.release(claim)
            await runtime.drainPendingEffects(for: session)
        }
    }

    func testMCPQuestionCancellationOwnsInvocationBeforeAndAfterInstallation() async throws {
        let coordinator = MCPAskUserPresentationCoordinator()
        let scope = AgentSessionRuntimeStore().makeScope()
        let session = questionSession(in: scope)
        let runtime = scope.interactions(routeID: 42, approvalStore: ApplyEditsApprovalStore())
        let command = try questionCommand(in: scope, for: session)
        let question = runtimeQuestion()

        let earlyID = UUID()
        _ = await coordinator.cancel(requestID: earlyID)
        do {
            _ = try await MCPAskUserToolProvider.withAgentQuestionPresentation(requestID: earlyID, coordinator: coordinator) {
                XCTFail("A cancelled registration must never begin preparation or publish a question")
                return try await runtime.askUser(command: command, interaction: question)
            }
            XCTFail("Early cancellation must refuse presentation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(session.pendingAskUser)

        // A cancellation during an uncancellable preparation await joins that invocation and
        // reaches the runtime's cancellation check before any pending state can be installed.
        for external in [false, true] {
            let preparingID = UUID()
            let preparing = expectation(description: "question preparation entered")
            var releasePreparation: CheckedContinuation<Void, Never>?
            let cancelled = expectation(description: "exact preparation task cancelled")
            let invocation = Task {
                try await MCPAskUserToolProvider.withAgentQuestionPresentation(requestID: preparingID, coordinator: coordinator) {
                    await withTaskCancellationHandler {
                        await withCheckedContinuation { continuation in
                            releasePreparation = continuation
                            preparing.fulfill()
                        }
                    } onCancel: { cancelled.fulfill() }
                    return try await runtime.askUser(command: command, interaction: question)
                }
            }
            await fulfillment(of: [preparing], timeout: 3)
            var cancellationReturned = false
            let cancellation = Task {
                if external { _ = await coordinator.cancel(requestID: preparingID) }
                else { invocation.cancel()
                    _ = await invocation.result
                }
                cancellationReturned = true
            }
            await fulfillment(of: [cancelled], timeout: 3)
            XCTAssertFalse(cancellationReturned, "Cancellation must join the original preparation")
            releasePreparation?.resume()
            releasePreparation = nil
            await cancellation.value
            do { _ = try await invocation.value
                XCTFail("Cancelled preparation must not present")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertNil(session.pendingAskUser)
            XCTAssertTrue(runtime.questionWaits.isEmpty)
        }

        let installed = expectation(description: "registered question installed")
        let attachment = observeQuestionInstallation(scope: scope, session: session, installed: installed)
        let installedID = UUID()
        let original = Task {
            try await MCPAskUserToolProvider.withAgentQuestionPresentation(requestID: installedID, coordinator: coordinator) {
                try await runtime.askUser(command: command, interaction: question)
            }
        }
        await fulfillment(of: [installed], timeout: 3)
        scope.presentation.detach(attachment)
        let replacement = questionSession(in: scope, tabID: session.tabID)
        let replacementInstalled = expectation(description: "replacement with reused public question ID")
        let replacementAttachment = observeQuestionInstallation(scope: scope, session: replacement, installed: replacementInstalled)
        let successor = Task { try await runtime.askUser(command: questionCommand(in: scope, for: replacement), interaction: question) }
        await fulfillment(of: [replacementInstalled], timeout: 3)
        scope.presentation.detach(replacementAttachment)
        let cancelled = await coordinator.cancel(requestID: installedID)
        XCTAssertTrue(cancelled)
        XCTAssertNil(session.askUserContinuation, "External cancellation joins the exact runtime wait")
        XCTAssertNotNil(replacement.askUserContinuation)
        do { _ = try await original.value
            XCTFail("Original question should be cancelled")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(try runtime.skipAskUser(command: questionCommand(in: scope, for: replacement), interactionID: question.id))
        _ = try await successor.value
        XCTAssertTrue(runtime.questionWaits.isEmpty)
    }

    func testQuestionCreationRetainsScopeUntilResponseWithoutPresentation() async throws {
        var scope: AgentSessionRuntimeStore.Scope? = AgentSessionRuntimeStore().makeScope()
        let session = try questionSession(in: XCTUnwrap(scope))
        let runtime = try XCTUnwrap(scope).interactions(routeID: 42, approvalStore: ApplyEditsApprovalStore())
        let question = runtimeQuestion()
        let installed = expectation(description: "runtime question published")
        let attachment = try observeQuestionInstallation(scope: XCTUnwrap(scope), session: session, installed: installed)
        weak let owner = scope
        let task = Task { try await runtime.askUser(command: questionCommand(in: runtime.scope, for: session), interaction: question) }
        await fulfillment(of: [installed], timeout: 3)
        scope?.presentation.detach(attachment)
        do { _ = try await runtime.askUser(command: questionCommand(in: runtime.scope, for: session), interaction: runtimeQuestion())
            XCTFail("A second question must not replace the admitted request")
        } catch { XCTAssertTrue(String(describing: error).contains("already waiting")) }
        XCTAssertEqual(session.pendingAskUser?.interaction.id, question.id)
        scope = nil
        XCTAssertNotNil(owner, "An admitted question owns its runtime, not its presentation")
        XCTAssertTrue(try runtime.skipAskUser(command: questionCommand(in: runtime.scope, for: session), interactionID: question.id))
        let response = try await task.value
        XCTAssertTrue(response.skipped)
        XCTAssertNil(session.pendingAskUser)
        XCTAssertNil(session.askUserContinuation)
        XCTAssertNil(session.askUserTimeoutTask)
        XCTAssertTrue(runtime.questionWaits.isEmpty)
        XCTAssertNil(owner)
    }

    func testCallerCancellationSettlesOriginalQuestionNotRecycledTabWithSameInteractionID() async throws {
        let scope = AgentSessionRuntimeStore().makeScope()
        let original = questionSession(in: scope)
        let runtime = scope.interactions(routeID: 42, approvalStore: ApplyEditsApprovalStore())
        let question = runtimeQuestion()
        let firstInstalled = expectation(description: "original question")
        let firstAttachment = observeQuestionInstallation(scope: scope, session: original, installed: firstInstalled)
        let first = Task { try await runtime.askUser(command: questionCommand(in: scope, for: original), interaction: question) }
        await fulfillment(of: [firstInstalled], timeout: 3)
        scope.presentation.detach(firstAttachment)
        let replacement = questionSession(in: scope, tabID: original.tabID)
        let secondInstalled = expectation(description: "replacement question")
        let secondAttachment = observeQuestionInstallation(scope: scope, session: replacement, installed: secondInstalled)
        let second = Task { try await runtime.askUser(command: questionCommand(in: scope, for: replacement), interaction: question) }
        await fulfillment(of: [secondInstalled], timeout: 3)
        scope.presentation.detach(secondAttachment)
        first.cancel()
        do { _ = try await first.value
            XCTFail("Cancelled original request must throw")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(original.askUserContinuation)
        XCTAssertEqual(replacement.pendingAskUser?.interaction.id, question.id)
        XCTAssertNotNil(replacement.askUserContinuation)
        XCTAssertTrue(try runtime.skipAskUser(command: questionCommand(in: scope, for: replacement), interactionID: question.id))
        let response = try await second.value
        XCTAssertTrue(response.skipped)
        XCTAssertTrue(runtime.questionWaits.isEmpty)
    }

    func testQuestionResponseRejectsReacquiredAndConflictingWriterCommands() async throws {
        for conflict in [false, true] {
            let writers = AgentSessionRuntimeStore()
            let scope = writers.makeScope()
            let session = questionSession(in: scope)
            let command = try questionCommand(in: scope, for: session)
            let runtime = scope.interactions(routeID: 42, approvalStore: ApplyEditsApprovalStore())
            let question = AgentAskUserInteraction(title: "Writer-fenced question", timeoutSeconds: 600, questions: [
                AgentAskUserQuestion(id: "answer", question: "Which files?", options: [], allowsMultiple: false, allowsCustom: true),
                AgentAskUserQuestion(id: "reason", question: "Why?", options: [], allowsMultiple: false, allowsCustom: true)
            ])
            let installed = expectation(description: "question ready for writer refusal")
            let attachment = observeQuestionInstallation(scope: scope, session: session, installed: installed)
            let task = Task { try await runtime.askUser(command: questionCommand(in: runtime.scope, for: session), interaction: question) }
            addTeardownBlock { task.cancel()
                _ = try? await task.value
            }
            await fulfillment(of: [installed], timeout: 3)
            scope.presentation.detach(attachment)
            let draft = AgentAskUserDraft(customResponse: "Sources only")
            XCTAssertTrue(runtime.updateAskUserDraft(command: command, interactionID: question.id, questionID: "answer", draft: draft))
            XCTAssertTrue(runtime.updateAskUserQuestionIndex(command: command, interactionID: question.id, index: 1))
            XCTAssertTrue(runtime.noteAskUserCardActivity(command: command, interactionID: question.id))
            let timeoutGeneration = session.pendingAskUserTimeoutGeneration
            let timeoutStart = session.pendingAskUser?.timeoutStartedAt
            XCTAssertFalse(runtime.updateAskUserDraft(command: command, interactionID: question.id, questionID: "missing", draft: draft))
            XCTAssertFalse(runtime.updateAskUserQuestionIndex(command: command, interactionID: question.id, index: 2))
            XCTAssertFalse(runtime.noteAskUserCardActivity(command: command, interactionID: UUID()))
            let other = writers.makeScope()
            let foreignRuntime = other.interactions(routeID: 43, approvalStore: ApplyEditsApprovalStore())
            XCTAssertFalse(foreignRuntime.updateAskUserDraft(command: command, interactionID: question.id, questionID: "answer", draft: .init(customResponse: "Foreign scope")))
            XCTAssertFalse(foreignRuntime.updateAskUserQuestionIndex(command: command, interactionID: question.id, index: 0))
            XCTAssertFalse(foreignRuntime.noteAskUserCardActivity(command: command, interactionID: question.id))
            if conflict {
                let copy = AgentTabSession(tabID: UUID())
                other.replaceSessions([copy.tabID: copy])
                XCTAssertEqual(other.bindingRejection(command.identity.sessionID, on: copy), .conflictingWriter)
                copy.installPersistentSessionBinding(.init(tabID: copy.tabID, sessionID: command.identity.sessionID, workspaceID: command.identity.workspaceID))
                guard case .conflicting = scope.resolveWriter(sessionID: command.identity.sessionID) else {
                    return XCTFail("Expected raw conflicting writer claims")
                }
            } else {
                scope.replaceSessions([:])
                scope.replaceSessions([session.tabID: session])
            }
            XCTAssertFalse(runtime.updateAskUserDraft(command: command, interactionID: question.id, questionID: "answer", draft: .init(customResponse: "Stale card")))
            XCTAssertFalse(runtime.updateAskUserQuestionIndex(command: command, interactionID: question.id, index: 0))
            XCTAssertFalse(runtime.noteAskUserCardActivity(command: command, interactionID: question.id))
            XCTAssertEqual(session.pendingAskUser?.draftsByQuestionID["answer"], draft)
            XCTAssertEqual(session.pendingAskUser?.currentQuestionIndex, 1)
            XCTAssertEqual(session.pendingAskUserTimeoutGeneration, timeoutGeneration)
            XCTAssertEqual(session.pendingAskUser?.timeoutStartedAt, timeoutStart)
            XCTAssertFalse(runtime.skipAskUser(command: command, interactionID: question.id))
            let submitted = try runtime.submitAskUserResponse(command: command, interactionID: question.id, draftsByQuestionID: [:])
            XCTAssertFalse(submitted)
            XCTAssertEqual(session.pendingAskUser?.interaction.id, question.id)
            XCTAssertNotNil(session.askUserContinuation)
            other.replaceSessions([:])
            let fresh = try questionCommand(in: scope, for: session)
            if conflict {
                XCTAssertTrue(runtime.skipAskUser(command: fresh, interactionID: question.id))
                let response = try await task.value
                XCTAssertTrue(response.skipped)
            } else {
                XCTAssertTrue(fresh.isCurrent)
                XCTAssertFalse(runtime.skipAskUser(command: fresh, interactionID: question.id), "A new claim cannot answer the old claim's question")
                XCTAssertFalse(runtime.updateAskUserDraft(command: fresh, interactionID: question.id, questionID: "answer", draft: .init(customResponse: "New claim")))
                task.cancel()
                do { _ = try await task.value
                    XCTFail("Only the original cancellation may settle this wait")
                } catch { XCTAssertTrue(error is CancellationError) }
            }
            XCTAssertNil(session.askUserContinuation)
        }
    }

    func testQuestionTimeoutRearmRejectsOldGenerationAndReturnsDraftAfterDetach() async throws {
        let scope = AgentSessionRuntimeStore().makeScope()
        let session = questionSession(in: scope)
        let runtime = scope.interactions(routeID: 42, approvalStore: ApplyEditsApprovalStore())
        let question = runtimeQuestion()
        let installed = expectation(description: "question before timeout rearm")
        let attachment = observeQuestionInstallation(scope: scope, session: session, installed: installed)
        let task = Task { try await runtime.askUser(command: questionCommand(in: runtime.scope, for: session), interaction: question) }
        await fulfillment(of: [installed], timeout: 3)
        scope.presentation.detach(attachment)
        let command = try questionCommand(in: scope, for: session)
        XCTAssertTrue(runtime.updateAskUserDraft(command: command, interactionID: question.id, questionID: "answer", draft: .init(customResponse: "Sources only")))
        let waitID = try XCTUnwrap(runtime.questionWaits[ObjectIdentifier(session)]?.id)
        let oldGeneration = session.pendingAskUserTimeoutGeneration
        XCTAssertTrue(runtime.noteAskUserCardActivity(command: command, interactionID: question.id))
        let currentGeneration = session.pendingAskUserTimeoutGeneration
        XCTAssertNotEqual(oldGeneration, currentGeneration)
        runtime.expireAskUserTimeout(for: session, interactionID: question.id, waitID: waitID, generation: oldGeneration)
        XCTAssertNotNil(session.askUserContinuation)
        scope.replaceSessions([:])
        runtime.expireAskUserTimeout(for: session, interactionID: question.id, waitID: waitID, generation: currentGeneration)
        let response = try await task.value
        XCTAssertTrue(response.timedOut)
        XCTAssertEqual(response.answersByQuestionID["answer"]?.customResponse, "Sources only")
        XCTAssertNil(session.askUserTimeoutTask)
        XCTAssertFalse(runtime.cancelAskUserInteraction(session: session, interactionID: question.id, waitID: waitID))
        XCTAssertTrue(runtime.questionWaits.isEmpty)
        scope.replaceSessions([session.tabID: session])
        let immediate = AgentAskUserInteraction(id: question.id, timeoutSeconds: 0, questions: question.questions)
        let immediateResponse = try await runtime.askUser(command: questionCommand(in: runtime.scope, for: session), interaction: immediate)
        XCTAssertTrue(immediateResponse.timedOut, "Exercise the actual scheduled timer as well as the stale-generation fence")
        XCTAssertNil(session.askUserTimeoutTask)
        XCTAssertTrue(runtime.questionWaits.isEmpty)
    }

    func testOriginQuestionTimeoutRepaintsButCannotReconcileSuccessorRun() async throws {
        for mutation in ["reacquire", "rebind", "attempt"] {
            let scope = AgentSessionRuntimeStore().makeScope()
            let session = questionSession(in: scope)
            let runtime = scope.interactions(routeID: 42, approvalStore: ApplyEditsApprovalStore())
            let command = try questionCommand(in: scope, for: session)
            let question = runtimeQuestion()
            let installed = expectation(description: "question before \(mutation)")
            let attachment = observeQuestionInstallation(scope: scope, session: session, installed: installed)
            let task = Task { try await runtime.askUser(command: command, interaction: question) }
            await fulfillment(of: [installed], timeout: 3)
            scope.presentation.detach(attachment)
            XCTAssertTrue(runtime.updateAskUserDraft(command: command, interactionID: question.id, questionID: "answer", draft: .init(customResponse: "Original draft")))
            let waitID = try XCTUnwrap(runtime.questionWaits[ObjectIdentifier(session)]?.id)
            let generation = session.pendingAskUserTimeoutGeneration
            var bindings = 0
            var interactions = 0
            let repaint = scope.presentation.attach(session, sink: .init(
                activityChanged: { _, _ in }, refresh: { _, _, _ in }, turnComplete: { _ in }, turnFailed: { _, _ in },
                binding: { _ in bindings += 1 }, interaction: { _ in interactions += 1 }
            ))
            if mutation == "reacquire" {
                scope.replaceSessions([:])
                scope.replaceSessions([session.tabID: session])
                let fresh = try questionCommand(in: scope, for: session)
                XCTAssertFalse(runtime.skipAskUser(command: fresh, interactionID: question.id))
            } else if mutation == "rebind" {
                session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: UUID(), workspaceID: command.identity.workspaceID))
                session.runState = .waitingForUser
            } else {
                session.beginRunAttempt(source: "successor question timeout test")
                session.runState = .waitingForUser
            }
            runtime.expireAskUserTimeout(for: session, interactionID: question.id, waitID: waitID, generation: generation)
            let response = try await task.value
            XCTAssertTrue(response.timedOut)
            XCTAssertEqual(response.answersByQuestionID["answer"]?.customResponse, "Original draft")
            XCTAssertNil(session.askUserContinuation)
            XCTAssertEqual(session.runState, mutation == "reacquire" ? .running : .waitingForUser)
            // A new run attempt retains the same writer; a changed claim gets only the narrow,
            // exact-object UI projection, never binding/save publication from the old writer.
            XCTAssertEqual(bindings, mutation == "attempt" ? 1 : 0)
            XCTAssertEqual(interactions, mutation == "attempt" ? 0 : 1)
            scope.presentation.detach(repaint)
        }
    }

    func testQuestionCancellationBeforeAdmissionOrRetirementCannotPublishPendingState() async throws {
        let scope = AgentSessionRuntimeStore().makeScope()
        let session = questionSession(in: scope)
        let runtime = scope.interactions(routeID: 42, approvalStore: ApplyEditsApprovalStore())
        let question = runtimeQuestion()
        let task = Task { try await runtime.askUser(command: questionCommand(in: runtime.scope, for: session), interaction: question) }
        task.cancel()
        do { _ = try await task.value
            XCTFail("An already cancelled request must not be installed")
        } catch { XCTAssertTrue(error is CancellationError) }
        let command = try questionCommand(in: scope, for: session)
        scope.beginRetirement()
        do { _ = try await runtime.askUser(command: command, interaction: question)
            XCTFail("Retiring owner must refuse a new question")
        } catch { XCTAssertTrue(String(describing: error).contains("unavailable")) }
        XCTAssertNil(session.pendingAskUser)
        XCTAssertNil(session.askUserContinuation)
        XCTAssertNil(session.askUserTimeoutTask)
        XCTAssertTrue(runtime.questionWaits.isEmpty)
    }

    func testRetainedInteractionRuntimeDoesNotRetainProviderCommandOwnersThroughTerminalHooks() async throws {
        var viewModel: AgentModeViewModel? = AgentModeViewModel(
            testWindowID: -1406, testWorkspacePath: nil, shouldManageCodexTooling: false,
            codexControllerFactory: { _, _, _, _, _, _ in
                fatalError("Composing terminal hooks must not launch a provider")
            }
        )
        viewModel?.ensureRunServiceMaterializedForRunStart()
        let runtime = try XCTUnwrap(viewModel?.interactionRuntime)
        weak let codex = viewModel?.codexCoordinator
        weak let claude = runtime.claudeCommands
        XCTAssertNotNil(codex)
        XCTAssertNotNil(claude)
        await viewModel?.test_retireAndCancelFixture()
        viewModel = nil
        XCTAssertNil(codex, "The terminal binder retains interaction hooks, not their provider command owners")
        XCTAssertNil(claude)
        XCTAssertNil(runtime.observer, "The remaining provider-state observer must also be weak")
        XCTAssertNil(runtime.claudeCommands)
    }

    func testManagedQuestionResponseOwnsExactScopeAcrossAuthorizationWithoutPresentation() async throws {
        var scope: AgentSessionRuntimeStore.Scope? = AgentSessionRuntimeStore().makeScope()
        let session = try questionSession(in: XCTUnwrap(scope))
        let runtime = try XCTUnwrap(scope).interactions(routeID: 42, approvalStore: ApplyEditsApprovalStore())
        weak let retainedScope = scope
        let question = AgentAskUserInteraction(title: "Scope", questions: [
            AgentAskUserQuestion(id: "scope", question: "Which files?", options: [], allowsMultiple: false, allowsCustom: true)
        ])
        let installed = expectation(description: "question continuation installed")
        let attachment = try observeQuestionInstallation(scope: XCTUnwrap(scope), session: session, installed: installed)
        let answered = Task { try await runtime.askUser(command: questionCommand(in: runtime.scope, for: session), interaction: question) }
        await fulfillment(of: [installed], timeout: 3)
        scope?.presentation.detach(attachment)
        let request = try AgentSessionLinkInteractionResponseRequest(
            interactionID: question.id,
            payload: AgentRunMCPToolService.parseResponsePayload(args: ["skip": .bool(true)])
        )
        XCTAssertEqual(runtime.pendingInteraction(for: session).interaction?.id, question.id)
        let gate = TestReleaseFence(name: "runtime interaction authorization")
        let submitted = Task { await runtime.respondToPendingInteraction(session: session, isCurrent: { true }, request: request) {
            await gate.enterAndWait()
            return true
        } }
        guard await gate.waitUntilEntered() else {
            gate.release()
            runtime.cancelPendingQuestion(for: session)
            _ = try? await answered.value
            _ = await submitted.value
            return
        }
        scope = nil
        XCTAssertNotNil(retainedScope)
        gate.release()
        let outcome = await submitted.value
        XCTAssertEqual(outcome, .submitted(kind: .question, decision: "skip"))
        _ = try await answered.value
        XCTAssertNil(session.askUserContinuation)
        XCTAssertNil(session.pendingAskUser)
        XCTAssertEqual(session.runState, .running)
        XCTAssertNil(retainedScope)
    }

    func testManagedResponseRechecksGrantObjectAndBindingAfterAuthorization() async throws {
        for mutation in ["revoke", "rebind", "replace", "reacquire"] {
            let scope = AgentSessionRuntimeStore().makeScope()
            let session = AgentTabSession(tabID: UUID())
            let sessionID = UUID()
            let workspaceID = UUID()
            session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: sessionID, workspaceID: workspaceID))
            session.recordRestorationAuthoritative(.persistedPayloadApplied)
            scope.replaceSessions([session.tabID: session])
            let runtime = scope.interactions(routeID: 42, approvalStore: ApplyEditsApprovalStore())
            let question = AgentAskUserInteraction(title: "Scope", questions: [
                AgentAskUserQuestion(id: "scope", question: "Which files?", options: [], allowsMultiple: false, allowsCustom: true)
            ])
            let installed = expectation(description: "question installed before \(mutation)")
            let attachment = observeQuestionInstallation(scope: scope, session: session, installed: installed)
            let answered = Task { try await runtime.askUser(command: questionCommand(in: scope, for: session), interaction: question) }
            await fulfillment(of: [installed], timeout: 3)
            scope.presentation.detach(attachment)
            let request = try AgentSessionLinkInteractionResponseRequest(
                interactionID: question.id,
                payload: AgentRunMCPToolService.parseResponsePayload(args: ["skip": .bool(true)])
            )
            let gate = TestReleaseFence(name: "managed response \(mutation)")
            let submitted = Task { await runtime.respondToPendingInteraction(session: session, isCurrent: { true }, request: request) {
                await gate.enterAndWait()
                return mutation != "revoke"
            } }
            guard await gate.waitUntilEntered() else {
                gate.release()
                runtime.cancelPendingQuestion(for: session)
                _ = try? await answered.value
                _ = await submitted.value
                return
            }
            if mutation == "rebind" {
                session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: sessionID, workspaceID: workspaceID))
            } else if mutation == "replace" {
                scope.replaceSessions([session.tabID: AgentTabSession(tabID: session.tabID)])
            } else if mutation == "reacquire" {
                scope.replaceSessions([:])
                scope.replaceSessions([session.tabID: session])
            }
            gate.release()
            let outcome = await submitted.value
            XCTAssertEqual(outcome, .unavailable, mutation)
            XCTAssertNotNil(session.askUserContinuation, mutation)
            runtime.cancelPendingQuestion(for: session)
            do {
                _ = try await answered.value
                XCTFail("A refused response must not consume the original question")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
    }

    func testManagedUserInputDoesNotAcknowledgeMissingProviderRoute() async throws {
        let scope = AgentSessionRuntimeStore().makeScope()
        let session = questionSession(in: scope)
        let runtime = scope.interactions(routeID: 42, approvalStore: ApplyEditsApprovalStore())
        let pending = AgentRequestUserInputRequest(
            receipt: .fixture(.string("input")), method: "item/tool/requestUserInput", threadID: "thread", turnID: "turn", itemID: "item",
            questions: [.init(id: "answer", header: "Answer", question: "Which files?", isOther: true, isSecret: false, options: [])]
        )
        session.pendingUserInputRequest = pending
        let request = try AgentSessionLinkInteractionResponseRequest(
            interactionID: pending.id,
            payload: AgentRunMCPToolService.parseResponsePayload(args: ["answers": .object(["answer": .string("all")])])
        )
        let outcome = await runtime.respondToPendingInteraction(session: session, isCurrent: { true }, request: request, authorize: { true })
        guard case let .invalid(message) = outcome else { return XCTFail("Missing provider commands must not report submitted: \(outcome)") }
        XCTAssertTrue(message.contains("No response was applied"))
        XCTAssertEqual(session.pendingUserInputRequest, pending)
    }

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

    func testApplyEditsDecisionUsesCapturedWriterAndAcknowledgesExactReview() async throws {
        for drift in ["none", "removed", "reacquired", "conflict", "retired", "successorReview"] {
            let writers = AgentSessionRuntimeStore()
            let scope = writers.makeScope()
            let session = AgentTabSession(tabID: UUID())
            let binding = AgentPersistentSessionBindingIdentity(tabID: session.tabID, sessionID: UUID(), workspaceID: UUID())
            session.installPersistentSessionBinding(binding)
            session.recordRestorationAuthoritative(.persistedPayloadApplied)
            scope.replaceSessions([session.tabID: session])
            guard case let .unique(writer) = scope.resolveWriter(sessionID: binding.sessionID) else {
                return XCTFail("Expected the initial unique writer")
            }
            let command = try writer.admitCommand().get()
            let approvals = ApplyEditsApprovalStore()
            let runtime = scope.interactions(routeID: 42, approvalStore: approvals)
            let address = runtime.approvalScope(for: session)
            let (subscription, stream) = await approvals.subscribe(scope: address)
            var snapshots = stream.makeAsyncIterator()
            _ = await snapshots.next()
            let original = Task { await approvals.requestReview(scope: address, path: "original", unifiedDiff: "diff", timeoutSeconds: 60) }
            let firstSnapshot = await snapshots.next()
            let first = try XCTUnwrap(firstSnapshot?.pendingReview)
            session.pendingApplyEditsReview = first
            let gate = TestReleaseFence(name: "writer-routed approval decision")
            runtime.test_beforeApprovalDecision = { await gate.enterAndWait() }
            addTeardownBlock {
                gate.release()
                await runtime.drainPendingEffects()
                await approvals.cleanupScope(address)
                await approvals.unsubscribe(scope: address, id: subscription)
                _ = await original.value
            }
            let submission = Task { await runtime.submitApplyEditsReviewDecision(command: command, reviewID: first.id, decision: .accept) }
            guard await gate.waitUntilEntered() else { return }
            let other = writers.makeScope()
            var successor: Task<ApplyEditsReviewDecision, Never>?
            var expectedReviewID = first.id
            switch drift {
            case "removed":
                scope.replaceSessions([:])
            case "reacquired":
                scope.replaceSessions([:])
                scope.replaceSessions([session.tabID: session])
            case "conflict":
                let duplicate = AgentTabSession(tabID: UUID())
                other.replaceSessions([duplicate.tabID: duplicate])
                XCTAssertEqual(other.bindingRejection(binding.sessionID, on: duplicate), .conflictingWriter)
                duplicate.installPersistentSessionBinding(.init(tabID: duplicate.tabID, sessionID: binding.sessionID, workspaceID: binding.workspaceID))
                guard case .conflicting = writers.resolveWriter(sessionID: binding.sessionID) else {
                    return XCTFail("Raw competing claim must remain conflicting")
                }
            case "retired":
                scope.beginRetirement()
            case "successorReview":
                successor = Task { await approvals.requestReview(scope: address, path: "successor", unifiedDiff: "diff", timeoutSeconds: 60) }
                _ = await snapshots.next() // original cancellation
                let next = await snapshots.next()
                expectedReviewID = try XCTUnwrap(next?.pendingReview?.id)
            // Deliberately leave the local projection stale: the store receipt is authoritative.
            default: break
            }
            gate.release()
            let applied = await submission.value
            XCTAssertEqual(applied, drift == "none", drift)
            await runtime.drainPendingEffects(for: session)
            let (checkID, currentStream) = await approvals.subscribe(scope: address)
            var current = currentStream.makeAsyncIterator()
            let snapshot = await current.next()
            XCTAssertEqual(snapshot?.pendingReview?.id, drift == "none" ? nil : expectedReviewID, drift)
            await approvals.unsubscribe(scope: address, id: checkID)
            if drift != "none" {
                let settled = await approvals.resolveReview(scope: address, reviewID: expectedReviewID, decision: .reject(reason: "test cleanup"))
                XCTAssertTrue(settled, "The stale command must not consume the pending receipt")
            }
            let duplicateSettlement = await approvals.resolveReview(scope: address, reviewID: first.id, decision: .accept)
            XCTAssertFalse(duplicateSettlement)
            let originalResult = await original.value
            if drift == "none" { XCTAssertEqual(originalResult, .accept) }
            if let successor {
                let result = await successor.value
                XCTAssertEqual(result, .reject(reason: "test cleanup"))
            }
        }
    }

    func testApplyEditsCallerCancellationSettlesItsOwnPendingReview() async {
        let store = ApplyEditsApprovalStore()
        let address = ApplyEditsApprovalScope(windowID: -1406, tabID: UUID())
        let (subscription, stream) = await store.subscribe(scope: address)
        let installed = expectation(description: "original review installed")
        let cleared = expectation(description: "cancelled review cleared")
        let completed = expectation(description: "caller cancellation returned")
        let observer = Task {
            var sawReview = false
            for await snapshot in stream {
                if snapshot.pendingReview != nil, !sawReview {
                    sawReview = true
                    installed.fulfill()
                } else if sawReview, snapshot.pendingReview == nil {
                    cleared.fulfill()
                    break
                }
            }
        }
        var decision: ApplyEditsReviewDecision?
        let caller = Task {
            decision = await store.requestReview(scope: address, path: "original", unifiedDiff: "diff", timeoutSeconds: 60)
            completed.fulfill()
        }
        addTeardownBlock {
            await store.cleanupScope(address)
            await store.unsubscribe(scope: address, id: subscription)
            observer.cancel()
            await observer.value
            await caller.value
        }
        await fulfillment(of: [installed], timeout: 5)
        caller.cancel()
        await fulfillment(of: [completed, cleared], timeout: 5)
        XCTAssertEqual(decision, .cancelled(reason: "Cancelled while awaiting apply_edits review"))
    }

    func testApplyEditsCallerCancellationCannotConsumeSuccessorReview() async throws {
        let store = ApplyEditsApprovalStore()
        let address = ApplyEditsApprovalScope(windowID: -1406, tabID: UUID())
        let (subscription, stream) = await store.subscribe(scope: address)
        let installed = expectation(description: "original review installed")
        let replaced = expectation(description: "successor review installed")
        var reviews: [String: PendingApplyEditsReview] = [:]
        let observer = Task {
            for await snapshot in stream {
                guard let review = snapshot.pendingReview, reviews[review.path] == nil else { continue }
                reviews[review.path] = review
                if review.path == "original" { installed.fulfill() }
                if review.path == "successor" { replaced.fulfill() }
            }
        }
        let gate = TestReleaseFence(name: "original approval caller cancellation")
        let settled = expectation(description: "original cancellation dispatched")
        await store.test_setRequestCancellationHooks(
            before: { await gate.enterAndWait() }, after: { settled.fulfill() }
        )
        let original = Task { await store.requestReview(scope: address, path: "original", unifiedDiff: "diff", timeoutSeconds: 60) }
        addTeardownBlock {
            gate.release()
            await store.cleanupScope(address)
            await store.unsubscribe(scope: address, id: subscription)
            observer.cancel()
            await observer.value
            _ = await original.value
        }
        await fulfillment(of: [installed], timeout: 5)
        let first = try XCTUnwrap(reviews["original"])
        original.cancel()
        guard await gate.waitUntilEntered() else { return }
        let successorCompleted = expectation(description: "successor response returned")
        var successorDecision: ApplyEditsReviewDecision?
        let successor = Task {
            successorDecision = await store.requestReview(scope: address, path: "successor", unifiedDiff: "diff", timeoutSeconds: 60)
            successorCompleted.fulfill()
        }
        addTeardownBlock {
            await store.cleanupScope(address)
            await successor.value
        }
        await fulfillment(of: [replaced], timeout: 5)
        let replacement = try XCTUnwrap(reviews["successor"])
        XCTAssertNotEqual(first.id, replacement.id)
        gate.release()
        await fulfillment(of: [settled], timeout: 5)
        let accepted = await store.resolveReview(scope: address, reviewID: replacement.id, decision: .accept)
        XCTAssertTrue(accepted, "An old caller's delayed cancellation must leave the successor review pending")
        await fulfillment(of: [successorCompleted], timeout: 5)
        XCTAssertEqual(successorDecision, .accept)
        let originalResult = await original.value
        XCTAssertEqual(originalResult, .cancelled(reason: "Replaced by newer apply_edits preview"))
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

    func testTerminalCancellationRetainsOnlyItsOriginalCutoffAuthorityAcrossReacquisition() async throws {
        for occupiedAtAdmission in [false, true] {
            let scope = AgentSessionRuntimeStore().makeScope()
            let original = AgentTabSession(tabID: UUID())
            let replacement = AgentTabSession(tabID: original.tabID)
            scope.replaceSessions([original.tabID: occupiedAtAdmission ? original : replacement])
            let store = ApplyEditsApprovalStore()
            let runtime = scope.interactions(routeID: 42, approvalStore: store)
            let address = runtime.approvalScope(for: original)
            let (subscription, stream) = await store.subscribe(scope: address)
            let installed = expectation(description: "review admitted before terminal cutoff")
            var review: PendingApplyEditsReview?
            let observer = Task {
                for await snapshot in stream {
                    if let pending = snapshot.pendingReview {
                        review = pending
                        installed.fulfill()
                        break
                    }
                }
            }
            let caller = Task { await store.requestReview(scope: address, path: "undisplayed", unifiedDiff: "diff", timeoutSeconds: 60) }
            let gate = TestReleaseFence(name: "terminal cancellation before same-object reacquisition")
            runtime.test_beforeApprovalCancellation = { await gate.enterAndWait() }
            addTeardownBlock {
                gate.release()
                await runtime.drainPendingEffects()
                await store.cleanupScope(address)
                await store.unsubscribe(scope: address, id: subscription)
                observer.cancel()
                await observer.value
                _ = await caller.value
            }
            await fulfillment(of: [installed], timeout: 5)
            let pending = try XCTUnwrap(review)
            XCTAssertNil(original.pendingApplyEditsReview, "No exact review receipt has reached this terminal caller")
            runtime.cancelPendingApplyEditsReview(for: original, reason: "Late terminal")
            guard await gate.waitUntilEntered() else { return XCTFail("Terminal cancellation never reached the held effect") }
            scope.replaceSessions([:])
            scope.replaceSessions([original.tabID: original])
            gate.release()
            await runtime.drainPendingEffects(for: original)
            let accepted = await store.resolveReview(scope: address, reviewID: pending.id, decision: .accept)
            XCTAssertEqual(accepted, !occupiedAtAdmission, "Only the original occupant may cancel its undisplayed pre-Stop review")
            if !accepted { await store.cleanupScope(address) }
            let decision = await caller.value
            XCTAssertEqual(decision, occupiedAtAdmission ? .cancelled(reason: "Late terminal") : .accept)
        }
    }

    func testApprovalSyncStoreCASPreservesSuccessorAndConcurrentOverride() async throws {
        let store = ApplyEditsApprovalStore()
        let address = ApplyEditsApprovalScope(windowID: 42, tabID: UUID())
        let stale = await store.prepareSync(scope: address)
        let fresh = await store.prepareSync(scope: address)
        let installed = await store.commitSync(fresh, initialValue: false, replacePayload: true)
        let original = try XCTUnwrap(installed)
        let refused = await store.commitSync(stale, initialValue: true, replacePayload: true)
        XCTAssertNil(refused, "A preparation cannot overwrite a newer committed lease")
        let preparation = await store.prepareSync(scope: address)
        let override = await store.prepareAutoEditOverride(for: address)
        let applied = await store.applyAutoEditOverride(override)
        XCTAssertTrue(applied)
        let renewed = await store.commitSync(preparation, initialValue: false, replacePayload: true)
        let successor = try XCTUnwrap(renewed)
        await store.cleanupSync(scope: address, lease: original.lease, admittedAtOrBefore: .now)
        let oldWrite = await store.setAutoEditEnabled(false, for: address, lease: original.lease, updateGlobalDefault: false)
        XCTAssertFalse(oldWrite)
        let overridden = await store.autoEditEnabled(for: address)
        XCTAssertTrue(overridden, "Initialization and old cleanup must preserve an intervening MCP override")
        await store.releaseAutoEditOverride(override)
        let restored = await store.autoEditEnabled(for: address)
        XCTAssertFalse(restored)
        let beforeCleanup = await store.prepareSync(scope: address)
        await store.cleanupSync(scope: address, lease: successor.lease, admittedAtOrBefore: .now)
        let afterCleanup = await store.commitSync(beforeCleanup, initialValue: true, replacePayload: true)
        XCTAssertNil(afterCleanup, "Returning to an absent entry must not revive a preparation")
        await store.unsubscribe(scope: address, id: original.id)
        await store.unsubscribe(scope: address, id: successor.id)
    }

    func testHydrationRefreshReplacesOnlyItsOwnInitialSeed() async {
        for manualChoice in [false, true] {
            let scope = AgentSessionRuntimeStore().makeScope()
            let session = AgentTabSession(tabID: UUID())
            session.autoEditEnabled = true
            session.hasLoadedPersistedState = false
            scope.replaceSessions([session.tabID: session])
            let store = ApplyEditsApprovalStore()
            let runtime = scope.interactions(routeID: 42, approvalStore: store)
            runtime.ensureApprovalSync(for: session)
            await runtime.drainPendingEffects(for: session)
            if manualChoice {
                await store.setAutoEditEnabled(true, for: runtime.approvalScope(for: session), updateGlobalDefault: false)
            }
            session.autoEditEnabled = false
            session.hasLoadedPersistedState = true
            runtime.adoptReadyApprovalPayload(for: session)
            await runtime.drainPendingEffects(for: session)
            let value = await store.autoEditEnabled(for: runtime.approvalScope(for: session))
            XCTAssertEqual(value, manualChoice, "Payload adoption may replace an initial seed, not an intervening manual choice")
            await runtime.teardownApprovalSync(for: session, cleanupScope: true)
        }
    }

    func testApprovalBeginRecoversAfterTemporaryConflictingMembership() async {
        let store = AgentSessionRuntimeStore()
        let scope = store.makeScope()
        let other = store.makeScope()
        let session = AgentTabSession(tabID: UUID())
        scope.replaceSessions([session.tabID: session])
        let approvals = ApplyEditsApprovalStore()
        let runtime = scope.interactions(routeID: 42, approvalStore: approvals)
        let gate = TestReleaseFence()
        runtime.test_beforeApprovalSyncCommit = { await gate.enterAndWait() }
        addTeardownBlock { @MainActor in
            gate.release()
            other.replaceSessions([:])
            runtime.test_beforeApprovalSyncCommit = nil
            await runtime.teardownApprovalSync(for: session, cleanupScope: true)
        }
        runtime.ensureApprovalSync(for: session)
        guard await gate.waitUntilEntered() else { return XCTFail("Begin was not held") }
        other.replaceSessions([session.tabID: session])
        gate.release()
        await runtime.drainPendingEffects(for: session)
        XCTAssertNil(session.applyEditsApprovalSubscriptionTask, "Refused begin cannot leave a false listening latch")
        XCTAssertNil(runtime.setAutoEditEnabled(false, for: session), "Conflicting membership is not draft command authority")
        other.replaceSessions([:])
        runtime.test_beforeApprovalSyncCommit = nil
        runtime.ensureApprovalSync(for: session)
        await runtime.drainPendingEffects(for: session)
        XCTAssertNotNil(session.applyEditsApprovalSubscriptionID)
    }

    func testHydrationAdoptionSurvivesAnIntermediateBeginThatNeverCommits() async {
        let scope = AgentSessionRuntimeStore().makeScope()
        let session = AgentTabSession(tabID: UUID())
        session.autoEditEnabled = true
        session.hasLoadedPersistedState = false
        scope.replaceSessions([session.tabID: session])
        let approvals = ApplyEditsApprovalStore()
        let runtime = scope.interactions(routeID: 42, approvalStore: approvals)
        runtime.ensureApprovalSync(for: session)
        await runtime.drainPendingEffects(for: session)
        let gate = TestReleaseFence()
        runtime.test_beforeApprovalSyncCommit = { await gate.enterAndWait() }
        addTeardownBlock { @MainActor in
            gate.release()
            runtime.test_beforeApprovalSyncCommit = nil
            await runtime.teardownApprovalSync(for: session, cleanupScope: true)
        }
        scope.replaceSessions([:])
        scope.replaceSessions([session.tabID: session])
        runtime.ensureApprovalSync(for: session)
        guard await gate.waitUntilEntered() else { return XCTFail("Intermediate begin was not held") }
        session.autoEditEnabled = false
        session.hasLoadedPersistedState = true
        session.isDirty = false
        runtime.test_beforeApprovalSyncCommit = nil
        runtime.adoptReadyApprovalPayload(for: session)
        gate.release()
        await runtime.drainPendingEffects(for: session)
        let value = await approvals.autoEditEnabled(for: runtime.approvalScope(for: session))
        XCTAssertFalse(value, "An uncommitted intermediate record must not hide the store's original seed ownership")
        XCTAssertFalse(session.isDirty)
    }

    func testHeldApprovalSeedCannotAdoptReacquiredMembership() async {
        let scope = AgentSessionRuntimeStore().makeScope()
        let session = AgentTabSession(tabID: UUID())
        session.autoEditEnabled = true
        scope.replaceSessions([session.tabID: session])
        let store = ApplyEditsApprovalStore()
        let runtime = scope.interactions(routeID: 42, approvalStore: store)
        let gate = TestReleaseFence()
        runtime.test_beforeApprovalSyncCommit = { await gate.enterAndWait() }
        addTeardownBlock { @MainActor in
            gate.release()
            runtime.test_beforeApprovalSyncCommit = nil
            await runtime.teardownApprovalSync(for: session, cleanupScope: true)
        }
        runtime.ensureApprovalSync(for: session)
        guard await gate.waitUntilEntered() else { return XCTFail("Seed did not reach admission fence") }
        scope.replaceSessions([:])
        scope.replaceSessions([session.tabID: session])
        session.autoEditEnabled = false
        runtime.test_beforeApprovalSyncCommit = nil
        runtime.ensureApprovalSync(for: session)
        gate.release()
        await runtime.drainPendingEffects(for: session)
        let value = await store.autoEditEnabled(for: runtime.approvalScope(for: session))
        XCTAssertFalse(value, "The old true seed must not land on the reacquired draft")
        XCTAssertNotNil(session.applyEditsApprovalSubscriptionID)
    }

    func testBufferedApprovalProjectionCannotDirtyReacquiredObject() async throws {
        let scope = AgentSessionRuntimeStore().makeScope()
        let session = AgentTabSession(tabID: UUID())
        session.autoEditEnabled = true
        scope.replaceSessions([session.tabID: session])
        let store = ApplyEditsApprovalStore()
        let runtime = scope.interactions(routeID: 42, approvalStore: store)
        let gate = TestReleaseFence()
        runtime.test_beforeApprovalSnapshot = { await gate.enterAndWait() }
        addTeardownBlock { @MainActor in
            gate.release()
            runtime.test_beforeApprovalSnapshot = nil
            await runtime.teardownApprovalSync(for: session, cleanupScope: true)
            await store.cleanupScope(runtime.approvalScope(for: session))
        }
        runtime.ensureApprovalSync(for: session)
        guard await gate.waitUntilEntered() else { return XCTFail("Snapshot was not held") }
        let listener = try XCTUnwrap(session.applyEditsApprovalSubscriptionTask)
        scope.replaceSessions([:])
        scope.replaceSessions([session.tabID: session])
        session.autoEditEnabled = false
        session.isDirty = false
        gate.release()
        await listener.value
        XCTAssertFalse(session.autoEditEnabled)
        XCTAssertFalse(session.isDirty, "A stale snapshot cannot schedule a successor save")
    }

    func testManualAutoEditCommandCannotFollowWriterReacquisition() async throws {
        let defaultBefore = ApplyEditsApprovalStore.globalDefaultAutoEditEnabled()
        let scope = AgentSessionRuntimeStore().makeScope()
        let session = questionSession(in: scope)
        session.autoEditEnabled = false
        let store = ApplyEditsApprovalStore()
        let runtime = scope.interactions(routeID: 42, approvalStore: store)
        runtime.ensureApprovalSync(for: session)
        await runtime.drainPendingEffects(for: session)
        let gate = TestReleaseFence()
        runtime.test_beforeAutoEditWrite = { await gate.enterAndWait() }
        addTeardownBlock { @MainActor in
            gate.release()
            runtime.test_beforeAutoEditWrite = nil
            await runtime.teardownApprovalSync(for: session, cleanupScope: true)
            await store.cleanupScope(runtime.approvalScope(for: session))
            ApplyEditsApprovalStore.setGlobalDefaultAutoEditEnabled(defaultBefore)
        }
        let write = try XCTUnwrap(runtime.setAutoEditEnabled(true, for: session))
        guard await gate.waitUntilEntered() else { return XCTFail("Manual command was not held") }
        scope.replaceSessions([:])
        scope.replaceSessions([session.tabID: session])
        gate.release()
        await write.value
        let value = await store.autoEditEnabled(for: runtime.approvalScope(for: session))
        XCTAssertFalse(value)
        XCTAssertEqual(ApplyEditsApprovalStore.globalDefaultAutoEditEnabled(), defaultBefore)
        runtime.test_beforeAutoEditWrite = nil
        let currentWrite = try XCTUnwrap(runtime.setAutoEditEnabled(true, for: session))
        await currentWrite.value
        let currentValue = await store.autoEditEnabled(for: runtime.approvalScope(for: session))
        XCTAssertTrue(currentValue, "The new exact writer retains the real manual action")
    }

    func testApprovalTeardownOrdersBeforeSuccessorBeginWithoutDrainingItsListener() async {
        let scope = AgentSessionRuntimeStore().makeScope()
        let original = AgentTabSession(tabID: UUID())
        original.autoEditEnabled = true
        scope.replaceSessions([original.tabID: original])
        let store = ApplyEditsApprovalStore()
        let runtime = scope.interactions(routeID: 42, approvalStore: store)
        runtime.ensureApprovalSync(for: original)
        await runtime.drainPendingEffects(for: original)
        let gate = TestReleaseFence()
        runtime.test_beforeApprovalSyncCleanup = { await gate.enterAndWait() }
        let teardownDone = expectation(description: "Original cleanup joined finite effects")
        let teardown = Task {
            await runtime.teardownApprovalSync(for: original, cleanupScope: true)
            teardownDone.fulfill()
        }
        let successor = AgentTabSession(tabID: original.tabID)
        successor.autoEditEnabled = false
        addTeardownBlock { @MainActor in
            gate.release()
            runtime.test_beforeApprovalSyncCleanup = nil
            await teardown.value
            await runtime.teardownApprovalSync(for: successor, cleanupScope: true)
        }
        guard await gate.waitUntilEntered() else { return XCTFail("Cleanup was not held") }
        scope.replaceSessions([successor.tabID: successor])
        var successorBegan = false
        runtime.test_beforeApprovalSyncCommit = { successorBegan = true }
        runtime.ensureApprovalSync(for: successor)
        // The begin is queued, but cannot enter the store transaction before cleanup.
        let tailProbe = expectation(description: "Main actor yielded to queued begin")
        Task { tailProbe.fulfill() }
        await fulfillment(of: [tailProbe], timeout: 3)
        XCTAssertFalse(successorBegan)
        gate.release()
        await fulfillment(of: [teardownDone], timeout: 5)
        await runtime.drainPendingEffects(for: successor)
        XCTAssertTrue(successorBegan)
        runtime.test_beforeApprovalSyncCommit = nil
        let value = await store.autoEditEnabled(for: runtime.approvalScope(for: successor))
        XCTAssertFalse(value)
        XCTAssertNotNil(successor.applyEditsApprovalSubscriptionID)
    }

    func testApprovalCleanupJoinsListenerAfterEphemeralStateClearsTaskField() async {
        let scope = AgentSessionRuntimeStore().makeScope()
        let session = AgentTabSession(tabID: UUID())
        scope.replaceSessions([session.tabID: session])
        let store = ApplyEditsApprovalStore()
        let runtime = scope.interactions(routeID: 42, approvalStore: store)
        let listening = expectation(description: "Listener held across cancellation")
        let joining = expectation(description: "Teardown entered listener join")
        var releaseListener: CheckedContinuation<Void, Never>?
        var listenerReleased = false
        var cleanupEntered = false
        runtime.test_beforeApprovalSnapshot = {
            await withCheckedContinuation { releaseListener = $0
                listening.fulfill()
            }
            listenerReleased = true
        }
        runtime.test_onApprovalListenerJoin = { joining.fulfill() }
        runtime.test_beforeApprovalSyncCleanup = {
            cleanupEntered = true
            XCTAssertTrue(listenerReleased, "Resource cleanup must join the runtime-owned listener, not the cleared session alias")
        }
        runtime.ensureApprovalSync(for: session)
        await fulfillment(of: [listening], timeout: 5)
        session.cancelEphemeralRuntimeState()
        XCTAssertNil(session.applyEditsApprovalSubscriptionTask)
        let teardown = Task { await runtime.teardownApprovalSync(for: session, cleanupScope: true) }
        addTeardownBlock { @MainActor in
            releaseListener?.resume()
            releaseListener = nil
            await teardown.value
        }
        await fulfillment(of: [joining], timeout: 5)
        XCTAssertFalse(cleanupEntered)
        releaseListener?.resume()
        releaseListener = nil
        await teardown.value
        let remaining = await store.test_subscriptionCount()
        XCTAssertEqual(remaining, 0)
        XCTAssertTrue(cleanupEntered)
    }

    func testNonoccupantTerminalCutoffCannotHideLaterOwnersBufferedReview() async {
        let scope = AgentSessionRuntimeStore().makeScope()
        let session = AgentTabSession(tabID: UUID())
        let runtime = scope.interactions(routeID: 42, approvalStore: ApplyEditsApprovalStore())
        let review = PendingApplyEditsReview(scope: runtime.approvalScope(for: session), path: "a", unifiedDiff: "diff")
        runtime.cancelPendingApplyEditsReview(for: session, reason: "Detached terminal")
        scope.replaceSessions([session.tabID: session])
        await runtime.drainPendingEffects(for: session)
        runtime.applyApprovalSnapshot(.init(scope: review.scope, autoEditEnabled: false, pendingReview: review), to: session)
        XCTAssertEqual(session.pendingApplyEditsReview?.id, review.id)
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
        await viewModel.test_retireAndCancelFixture()
    }

    private func makeCoordinator(scope: AgentSessionRuntimeStore.Scope) -> CodexAgentModeCoordinator {
        let coordinator = CodexAgentModeCoordinator(
            windowID: -901, runtimeWorkspacePathsProvider: { _ in .uniform(nil) },
            codexControllerFactory: { _, _, _, _, _, _, _, _, _ in fatalError("Event handling must not launch a controller") },
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
        let scope = AgentSessionRuntimeStore.shared.makeScope()
        defer { scope.replaceSessions([:]) }
        let session = AgentTabSession(tabID: UUID())
        scope.replaceSessions([session.tabID: session])
        session.hasLoadedPersistedState = true
        session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: UUID(), workspaceID: UUID()))
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
        let result = await coordinator.test_ensureClaudeNativeSession(session: session, intent: .runAttempt(ownership: owner, runID: runID))
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

@MainActor
final class AgentProviderResponseCommandTests: XCTestCase {
    private enum Kind: CaseIterable {
        case approval, permissions, elicitation, userInput

        @MainActor
        func install(on session: AgentTabSession, receipt: CodexServerRequestReceipt = .fixture(.int(1)), id: UUID? = UUID()) -> UUID {
            switch self {
            case .approval:
                session.pendingApproval = .init(id: id, requestID: .codex(receipt), method: "item/commandExecution/requestApproval", kind: .commandExecution, threadID: "thread", turnID: "turn", itemID: "item")
            case .permissions:
                session.pendingPermissionsRequest = .init(id: id, receipt: receipt, method: "item/permissions/requestApproval", threadID: "thread", turnID: "turn", itemID: "item", cwd: "/tmp", permissionsJSON: "{}")
            case .elicitation:
                session.pendingMCPElicitationRequest = .init(id: id, receipt: receipt, method: "mcpServer/elicitation/request", threadID: "thread", turnID: "turn", itemID: "item", rawParamsJSON: "{}")
            case .userInput:
                session.pendingUserInputRequest = .init(id: id, receipt: receipt, method: "item/tool/requestUserInput", threadID: "thread", turnID: "turn", itemID: "item", questions: [])
            }
            return pendingID(on: session)!
        }

        @MainActor
        func pendingID(on session: AgentTabSession) -> UUID? {
            switch self {
            case .approval: session.pendingApproval?.id
            case .permissions: session.pendingPermissionsRequest?.id
            case .elicitation: session.pendingMCPElicitationRequest?.id
            case .userInput: session.pendingUserInputRequest?.id
            }
        }

        @MainActor
        func submit(_ runtime: AgentSessionInteractionRuntime, command: AgentSessionRuntimeStore.Command, id: UUID) -> Bool {
            switch self {
            case .approval: runtime.submitApprovalDecision(command: command, requestID: id, decision: .cancel)
            case .permissions: runtime.submitPermissionsDecision(command: command, requestID: id, decision: .cancel)
            case .elicitation: runtime.submitMCPElicitationResponse(command: command, requestID: id, response: .init(action: .cancel))
            case .userInput: runtime.submitUserInputResponse(command: command, requestID: id, response: .init(answersByQuestionID: [:]))
            }
        }
    }

    private func install(in scope: AgentSessionRuntimeStore.Scope) -> AgentTabSession {
        let session = AgentTabSession(tabID: UUID())
        session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: UUID(), workspaceID: UUID()))
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        scope.replaceSessions([session.tabID: session])
        return session
    }

    private func command(_ scope: AgentSessionRuntimeStore.Scope, _ session: AgentTabSession) throws -> AgentSessionRuntimeStore.Command {
        guard case let .unique(writer) = try scope.resolveWriter(sessionID: XCTUnwrap(session.activeAgentSessionID)), writer.session === session else {
            throw NSError(domain: "Expected exact response writer", code: 1)
        }
        return try writer.admitCommand().get()
    }

    func testResponseCommandsRejectWriterDriftAndDuplicateConsumption() async throws {
        for kind in Kind.allCases {
            for conflict in [false, true] {
                let store = AgentSessionRuntimeStore()
                let scope = store.makeScope()
                let other = store.makeScope()
                let session = install(in: scope)
                let runtime = scope.interactions(routeID: 1, approvalStore: ApplyEditsApprovalStore())
                let captured = try command(scope, session)
                let controller = ResponseController()
                session.codexController = controller
                let id = kind.install(on: session)
                if conflict {
                    let duplicate = AgentTabSession(tabID: UUID())
                    other.replaceSessions([duplicate.tabID: duplicate])
                    XCTAssertEqual(other.bindingRejection(captured.identity.sessionID, on: duplicate), .conflictingWriter)
                    duplicate.installPersistentSessionBinding(.init(tabID: duplicate.tabID, sessionID: captured.identity.sessionID, workspaceID: captured.identity.workspaceID))
                    duplicate.recordRestorationAuthoritative(.persistedPayloadApplied)
                    guard case .conflicting = scope.resolveWriter(sessionID: captured.identity.sessionID) else {
                        return XCTFail("Expected raw conflicting writer claims")
                    }
                } else {
                    scope.replaceSessions([:])
                    scope.replaceSessions([session.tabID: session])
                }
                XCTAssertFalse(kind.submit(runtime, command: captured, id: id), "\(kind), conflict=\(conflict)")
                XCTAssertEqual(kind.pendingID(on: session), id)
                await runtime.drainPendingEffects()
                let rejectedCount = await controller.receipts.count
                XCTAssertEqual(rejectedCount, 0)
                other.replaceSessions([:])
                let current = try command(scope, session)
                XCTAssertTrue(kind.submit(runtime, command: current, id: id))
                XCTAssertFalse(kind.submit(runtime, command: current, id: id))
                await runtime.drainPendingEffects()
                let sentCount = await controller.receipts.count
                XCTAssertEqual(sentCount, 1)
            }
        }
    }

    func testConsumedResponseDrainsOriginalControllerWithoutInterruptingLaterTurn() async throws {
        for kind in Kind.allCases {
            for turn in ["unknown", "current", "foreignController"] {
                let store = AgentSessionRuntimeStore()
                let scope = store.makeScope()
                let session = install(in: scope)
                let runtime = scope.interactions(routeID: 1, approvalStore: ApplyEditsApprovalStore())
                let entered = expectation(description: "original response entered")
                let controller = ResponseController(entered: entered)
                session.codexController = controller
                session.codexConversationID = "thread"
                session.beginRunAttempt(source: "response command test")
                let foreignController = ResponseController()
                if turn != "unknown" {
                    session.codexAuthoritativeActiveTurn = try .init(threadID: "thread", turnID: "original-turn", turnKind: .user, controllerInstanceID: ObjectIdentifier(turn == "foreignController" ? foreignController : controller), controllerGeneration: session.codexControllerGeneration, runID: session.runID, runAttemptID: XCTUnwrap(session.activeRunAttemptID))
                }
                let id = kind.install(on: session)
                XCTAssertTrue(try kind.submit(runtime, command: command(scope, session), id: id))
                await fulfillment(of: [entered], timeout: 3)
                let successor = kind.install(on: session)
                // A later turn on the same controller must not be discovered by a cancel follow-up.
                session.codexAuthoritativeActiveTurn = try .init(threadID: "thread", turnID: "later-turn", turnKind: .user, controllerInstanceID: ObjectIdentifier(controller), controllerGeneration: session.codexControllerGeneration, runID: session.runID, runAttemptID: XCTUnwrap(session.activeRunAttemptID))
                let replacement = ResponseController()
                session.codexController = replacement
                scope.replaceSessions([:])
                var drained = false
                let drainStarted = expectation(description: "response drain entered")
                let drain = Task {
                    drainStarted.fulfill()
                    await runtime.drainPendingEffects(for: session)
                    drained = true
                }
                await fulfillment(of: [drainStarted], timeout: 3)
                XCTAssertFalse(drained, "Drain must still own the suspended provider send")
                await controller.receipts.release()
                await drain.value
                XCTAssertTrue(drained)
                let completed = await controller.receipts.completed
                XCTAssertEqual(completed, 1, "Drain acknowledges the completed send, not just its admission")
                let count = await controller.receipts.count
                let interrupts = await controller.receipts.interrupts
                let reconciliations = await controller.receipts.reconciliations
                let replacementCount = await replacement.receipts.count
                XCTAssertEqual(count, 1)
                XCTAssertEqual(replacementCount, 0)
                XCTAssertEqual(kind.pendingID(on: session), successor)
                XCTAssertEqual(reconciliations, 0, "Cancellation may not discover a later turn")
                XCTAssertEqual(interrupts, turn == "current" && (kind == .permissions || kind == .elicitation) ? ["original-turn"] : [])
            }
        }
    }

    func testOriginatingInteractionIdentityAndDeliveryFenceCancelFollowUps() async throws {
        for kind in Kind.allCases {
            for delivery in [CodexServerResponseDelivery.written, .refused, .failed] {
                let store = AgentSessionRuntimeStore()
                let scope = store.makeScope()
                let session = install(in: scope)
                let runtime = scope.interactions(routeID: 1, approvalStore: ApplyEditsApprovalStore())
                let controller = ResponseController(delivery: delivery)
                session.codexController = controller
                session.codexConversationID = "thread"
                session.beginRunAttempt(source: "response-origin test")
                session.codexAuthoritativeActiveTurn = try .init(threadID: "thread", turnID: "original-turn", turnKind: .user, controllerInstanceID: ObjectIdentifier(controller), controllerGeneration: session.codexControllerGeneration, runID: session.runID, runAttemptID: XCTUnwrap(session.activeRunAttemptID))
                let captured = try command(scope, session)
                let staleID = kind.install(on: session, receipt: .fixture(.int(1), generation: 1), id: nil)
                let origin = CodexServerRequestReceipt.fixture(.int(1), generation: 2)
                let successorID = kind.install(on: session, receipt: origin, id: nil)
                XCTAssertNotEqual(staleID, successorID)
                XCTAssertFalse(kind.submit(runtime, command: captured, id: staleID), "A current writer must not make a stale card current")
                XCTAssertEqual(kind.pendingID(on: session), successorID)
                XCTAssertTrue(kind.submit(runtime, command: captured, id: successorID), "Acknowledges local consumption, not provider delivery")
                await runtime.drainPendingEffects()
                let sent = await controller.receipts.count
                let interrupts = await controller.receipts.interrupts
                let origins = await controller.receipts.interruptOrigins
                XCTAssertEqual(sent, 1)
                let shouldInterrupt = delivery == .written && (kind == .permissions || kind == .elicitation)
                XCTAssertEqual(interrupts, shouldInterrupt ? ["original-turn"] : [])
                XCTAssertEqual(origins, shouldInterrupt ? [origin] : [])
                XCTAssertNil(kind.pendingID(on: session))
            }
        }
    }

    func testMissingProviderDoesNotAcknowledgePermissionsOrElicitation() throws {
        let store = AgentSessionRuntimeStore()
        let scope = store.makeScope()
        let session = install(in: scope)
        let runtime = scope.interactions(routeID: 1, approvalStore: ApplyEditsApprovalStore())
        let captured = try command(scope, session)
        for kind in [Kind.permissions, .elicitation] {
            let id = kind.install(on: session)
            let resolution: AgentPendingInteractionResolution = switch kind {
            case .permissions: try .permissions(request: XCTUnwrap(session.pendingPermissionsRequest), decision: .decline)
            default: try .mcpElicitation(request: XCTUnwrap(session.pendingMCPElicitationRequest), response: .init(action: .decline))
            }
            XCTAssertThrowsError(try runtime.applyPendingInteractionResolution(resolution, command: captured))
            XCTAssertEqual(kind.pendingID(on: session), id)
        }
    }

    private actor Receipts {
        var count = 0
        var completed = 0
        var interrupts: [String] = []
        var interruptOrigins: [CodexServerRequestReceipt] = []
        var reconciliations = 0
        private var waiter: CheckedContinuation<Void, Never>?
        func respond(entered: XCTestExpectation?) async {
            count += 1
            defer { completed += 1 }
            guard let entered else { return }
            await withCheckedContinuation { waiter = $0
                entered.fulfill()
            }
        }

        func release() {
            waiter?.resume()
            waiter = nil
        }

        func interrupt(_ id: String) {
            interrupts.append(id)
        }

        func interrupt(_ id: String, origin: CodexServerRequestReceipt) {
            interrupts.append(id)
            interruptOrigins.append(origin)
        }

        func reconcile() {
            reconciliations += 1
        }
    }

    private final class ResponseController: CodexSessionControllerPassiveStubDefaults {
        let receipts = Receipts()
        let entered: XCTestExpectation?
        let delivery: CodexServerResponseDelivery
        init(entered: XCTestExpectation? = nil, delivery: CodexServerResponseDelivery = .written) {
            self.entered = entered
            self.delivery = delivery
        }

        var events: AsyncStream<CodexNativeSessionController.Event> {
            AsyncStream { $0.finish() }
        }

        func shutdown() async {}
        func respondToServerRequest(receipt _: CodexServerRequestReceipt, result _: [String: Any]) async -> CodexServerResponseDelivery {
            await receipts.respond(entered: entered)
            return delivery
        }

        func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
            await receipts.interrupt(expectedTurnID)
            return .init(interruptedTurnID: expectedTurnID)
        }

        func interruptUserTurn(expectedThreadID: String, expectedTurnID: String, answering receipt: CodexServerRequestReceipt) async throws -> CodexTurnInterruptReceipt {
            XCTAssertEqual(expectedThreadID, "thread")
            await receipts.interrupt(expectedTurnID, origin: receipt)
            return .init(interruptedTurnID: expectedTurnID)
        }

        func reconcileAndInterruptCurrentTurn() async throws -> CodexTurnInterruptReceipt {
            await receipts.reconcile()
            return .init(interruptedTurnID: "later-turn")
        }
    }
}
