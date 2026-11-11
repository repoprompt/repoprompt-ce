import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import XCTest

final class CodexHookReviewCardStateTests: XCTestCase {
    func testSelectionStartsEmpty() {
        let state = CodexHookReviewCardState(interactionID: UUID())

        XCTAssertTrue(state.selectedHookKeys.isEmpty)
    }

    func testSelectionIsPreservedForPhaseOrErrorUpdatesWithSameInteractionID() {
        let interactionID = UUID()
        var state = CodexHookReviewCardState(interactionID: interactionID)
        state.selectedHookKeys = ["hook-a"]
        state.actionErrorMessage = "write failed"

        state.synchronize(interactionID: interactionID)

        XCTAssertEqual(state.selectedHookKeys, ["hook-a"])
        XCTAssertEqual(state.actionErrorMessage, "write failed")
    }

    func testSelectionResetsWhenInteractionIDChanges() {
        var state = CodexHookReviewCardState(interactionID: UUID())
        state.selectedHookKeys = ["hook-a"]
        state.isContinueConfirmationPresented = true
        state.actionErrorMessage = "stale"

        state.synchronize(interactionID: UUID())

        XCTAssertTrue(state.selectedHookKeys.isEmpty)
        XCTAssertFalse(state.isContinueConfirmationPresented)
        XCTAssertNil(state.actionErrorMessage)
    }

    func testLiveStrictModeToggleHidesAndShowsContinueAndDismissesConfirmation() {
        var state = CodexHookReviewCardState(interactionID: UUID())
        var isStrictModeEnabled = false
        XCTAssertTrue(!isStrictModeEnabled)
        XCTAssertEqual(
            CodexHookApprovalWorkspaceSetting.allCases.map {
                $0.label(globalStrictModeEnabled: isStrictModeEnabled)
            },
            [
                "App default (currently: not required)",
                "Always require approval",
                "Don't require approval"
            ]
        )
        state.isContinueConfirmationPresented = true

        isStrictModeEnabled = true
        state.strictModeDidChange(isEnabled: isStrictModeEnabled)

        XCTAssertFalse(!isStrictModeEnabled)
        XCTAssertEqual(
            CodexHookApprovalWorkspaceSetting.appDefault.label(
                globalStrictModeEnabled: isStrictModeEnabled
            ),
            "App default (currently: required)"
        )
        XCTAssertFalse(state.isContinueConfirmationPresented)

        isStrictModeEnabled = false
        state.strictModeDidChange(isEnabled: isStrictModeEnabled)

        XCTAssertTrue(!isStrictModeEnabled)
        XCTAssertEqual(
            CodexHookApprovalWorkspaceSetting.appDefault.label(
                globalStrictModeEnabled: isStrictModeEnabled
            ),
            "App default (currently: not required)"
        )
    }
}

final class CodexHookReviewRuntimeTests: XCTestCase {
    /// Characterize the shared admission helpers through this pilot's real hook-command fixture.
    @MainActor
    func testAdmissionKeepsResolutionOwnershipAndCommandRefusalsDistinct() throws {
        let fixture = try Fixture(strict: true)
        defer { fixture.cleanup() }
        let foreign = fixture.store.makeScope()
        let session = fixture.session
        let command = try fixture.scope.admit(session: session)
        XCTAssertEqual(command.identity, fixture.command.identity)
        XCTAssertNil(command.rejection)
        try command.requireCurrent()
        for failure in ["absent", "workspace", "foreign", "conflict", "retiring"] {
            if failure == "conflict" { foreign.replaceSessions([session.tabID: session]) }
            if failure == "retiring" { fixture.scope.beginRetirement() }
            defer { foreign.replaceSessions([:]) }
            do {
                _ = try (failure == "foreign" ? foreign : fixture.scope).admit(
                    session: failure == "absent" ? AgentTabSession(tabID: UUID()) : session,
                    expectedWorkspaceID: failure == "workspace" ? UUID() : nil
                )
                XCTFail("Expected \(failure) refusal")
            } catch {
                switch (failure, error) {
                case ("absent", .unavailable(.absent)), ("workspace", .conflicting),
                     ("conflict", .conflicting), ("foreign", .foreignOwner): break
                case let ("retiring", .command(writer, reason)):
                    XCTAssertEqual(writer.identity, command.identity)
                    XCTAssertEqual(reason, .retiring)
                default: XCTFail("Wrong failure for \(failure): \(error)")
                }
            }
        }
        XCTAssertEqual(command.rejection, .retiring)
        XCTAssertThrowsError(try command.requireCurrent()) { error in
            XCTAssertEqual(error as? AgentSessionRuntimeStore.CommandRejection, .retiring)
        }
        XCTAssertTrue(command.writer.isCurrent, "Retirement blocks commands, not originating cleanup")
        XCTAssertTrue(command.writer.ownsPersistentClaim)
        XCTAssertTrue(command.writer.isCurrentOrSlotReplaced)
        XCTAssertThrowsError(try fixture.runtime.codexHookCommand(for: session)) { error in
            XCTAssertEqual(error as? AgentCodexHookReviewResolutionError, .staleWriter)
        }
    }

    @MainActor
    func testBindingTransitionIsAResolutionFailureNotACommandRefusal() throws {
        let fixture = try Fixture(strict: true)
        defer { fixture.cleanup() }
        let generation = fixture.session.beginPersistentBindingTransition()
        defer { fixture.session.finishPersistentBindingTransition(generation: generation) }
        do {
            _ = try fixture.scope.admit(session: fixture.session)
            XCTFail("An in-flight rebind cannot admit a command")
        } catch {
            guard case .unavailable(.bindingTransition) = error else {
                return XCTFail("Expected binding-transition resolution failure: \(error)")
            }
        }
        XCTAssertEqual(fixture.command.rejection, .staleWriter)
        XCTAssertThrowsError(try fixture.runtime.codexHookCommand(for: fixture.session)) { error in
            XCTAssertEqual(error as? AgentCodexHookReviewResolutionError, .staleWriter)
        }
    }

    @MainActor
    func testCleanupPredicateDistinguishesDetachmentFromSameObjectReacquisition() throws {
        let fixture = try Fixture(strict: true)
        defer { fixture.cleanup() }
        let command = fixture.command
        fixture.scope.replaceSessions([:])
        XCTAssertEqual(command.rejection, .staleWriter)
        XCTAssertFalse(command.writer.ownsPersistentClaim)
        XCTAssertTrue(command.writer.isCurrentOrSlotReplaced)
        fixture.scope.replaceSessions([fixture.session.tabID: fixture.session])
        XCTAssertEqual(command.rejection, .staleWriter)
        XCTAssertFalse(command.writer.isCurrentOrSlotReplaced)
        let successor = try fixture.runtime.codexHookCommand(for: fixture.session)
        XCTAssertNotEqual(successor.identity, command.identity)
        let replacement = AgentTabSession(tabID: fixture.session.tabID)
        fixture.scope.replaceSessions([replacement.tabID: replacement])
        XCTAssertTrue(command.writer.isCurrentOrSlotReplaced)
        XCTAssertTrue(successor.writer.isCurrentOrSlotReplaced)
        XCTAssertEqual(successor.rejection, .staleWriter)
    }

    @MainActor
    func testCommandRejectionRetainsCreationRequirement() throws {
        let store = AgentSessionRuntimeStore()
        let scope = store.makeScope()
        let workspaceID = UUID()
        let claim = AgentSessionCreationClaim(workspaceID: workspaceID)
        let session = scope.makeSession(tabID: UUID())
        defer { session.saveDebounceTask?.cancel() }
        session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: claim.sessionID, workspaceID: workspaceID))
        let handle = try XCTUnwrap(session.acceptFreshCreation(claim, workspaceID: workspaceID))
        scope.replaceSessions([session.tabID: session])
        let command = try scope.admit(session: session, requirement: .creation(handle))
        XCTAssertNil(command.rejection)
        try command.requireCurrent()
        XCTAssertThrowsError(try scope.admit(session: session)) { error in
            guard case let AgentSessionRuntimeStore.AdmissionRejection.command(writer, reason) = error else {
                return XCTFail("Expected readiness refusal, not resolution failure: \(error)")
            }
            XCTAssertEqual(writer.identity, command.identity)
            XCTAssertEqual(reason, .restorationUnavailable)
        }
        session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: UUID(), workspaceID: workspaceID))
        XCTAssertEqual(command.rejection, .staleWriter)
        XCTAssertThrowsError(try command.requireCurrent())
    }

    @MainActor
    func testExactGateConsentAndDuplicateResponse() async throws {
        for strict in [false, true] {
            let fixture = try Fixture(strict: strict)
            let ready = expectation(description: "gate waiter installed")
            fixture.onRefresh = {
                if fixture.session.pendingCodexHookReview?.phase == .reviewRequired {
                    XCTAssertNotNil(fixture.session.codexHookReviewContinuation)
                    ready.fulfill()
                }
            }
            let gate = Task { try await fixture.start() }
            defer { gate.cancel()
                fixture.cleanup()
            }
            await fulfillment(of: [ready], timeout: 3)
            fixture.onRefresh = nil
            let request = try XCTUnwrap(fixture.session.pendingCodexHookReview)
            if strict {
                do {
                    try await fixture.runtime.submitCodexHookReviewDecision(command: fixture.command, requestID: request.id, decision: .continueWithoutHooks)
                    XCTFail("Strict mode must not be bypassed")
                } catch {
                    XCTAssertEqual(error as? AgentCodexHookReviewResolutionError, .strictModeRequiresApproval)
                }
                XCTAssertEqual(fixture.trustCalls, 0)
            }
            try await fixture.runtime.submitCodexHookReviewDecision(
                command: fixture.command, requestID: request.id,
                decision: strict ? .approveAll : .continueWithoutHooks
            )
            let completedToken = try await gate.value
            let token = try XCTUnwrap(completedToken)
            XCTAssertEqual(fixture.trustCalls, strict ? 1 : 0)
            XCTAssertEqual(fixture.session.codexHookGateAudit?.status, strict ? .approvedAll : .continuedWithoutHooks)
            XCTAssertEqual(fixture.session.saveRequestGeneration, 1)
            XCTAssertNil(fixture.session.pendingCodexHookReview)
            XCTAssertNotNil(fixture.session.codexHookGateOrigin)
            do {
                try await fixture.runtime.submitCodexHookReviewDecision(command: fixture.command, requestID: request.id, decision: .approveAll)
                XCTFail("Duplicate response must fail")
            } catch {
                XCTAssertEqual(error as? AgentCodexHookReviewResolutionError, .noPendingReview)
            }
            fixture.session.finishCodexHookGateOwnerDispatch(token: token, succeeded: true)
            XCTAssertNil(fixture.session.codexHookGateOrigin)
        }
    }

    @MainActor
    func testTrustCompletionCannotPublishToLostWriterOrSuccessorGate() async throws {
        for drift in ["detached", "reacquired", "rebound", "newRun", "newGate", "conflicting"] {
            let fixture = try Fixture(strict: true)
            let ready = expectation(description: "review ready \(drift)")
            fixture.onRefresh = {
                if fixture.session.pendingCodexHookReview?.phase == .reviewRequired { ready.fulfill() }
            }
            let gate = Task { try await fixture.start() }
            await fulfillment(of: [ready], timeout: 3)
            fixture.onRefresh = nil
            let request = try XCTUnwrap(fixture.session.pendingCodexHookReview)
            let submitted = expectation(description: "trust admitted")
            var release: CheckedContinuation<Void, Never>?
            fixture.beforeTrust = {
                await withCheckedContinuation { continuation in
                    release = continuation
                    submitted.fulfill()
                }
            }
            let response = Task {
                try await fixture.runtime.submitCodexHookReviewDecision(command: fixture.command, requestID: request.id, decision: .approveAll)
            }
            await fulfillment(of: [submitted], timeout: 3)
            var baselineRefreshes = fixture.refreshes
            let baselineItems = fixture.session.items.count
            let conflictScope = fixture.store.makeScope()
            var successorOrigin: AgentTabSession.CodexHookGateOrigin?
            var successor: Task<UUID?, Error>?
            var successorReview: AgentCodexHookReviewRequest?
            var successorGeneration: UInt64?
            switch drift {
            case "detached": fixture.scope.replaceSessions([:])
            case "reacquired":
                fixture.scope.replaceSessions([:])
                fixture.scope.replaceSessions([fixture.session.tabID: fixture.session])
                let fresh = try fixture.runtime.codexHookCommand(for: fixture.session)
                do {
                    try await fixture.runtime.submitCodexHookReviewDecision(command: fresh, requestID: request.id, decision: .approveAll)
                    XCTFail("Fresh claim must not answer the old review")
                } catch { XCTAssertEqual(error as? AgentCodexHookReviewResolutionError, .staleWriter) }
            case "rebound":
                fixture.session.installPersistentSessionBinding(.init(tabID: fixture.session.tabID, sessionID: UUID(), workspaceID: fixture.command.identity.workspaceID))
                fixture.session.recordRestorationAuthoritative(.persistedPayloadApplied)
            case "newRun": fixture.session.installRunID(UUID())
            case "newGate":
                fixture.session.resetCodexHookGateBinding()
                let nextReady = expectation(description: "real successor gate")
                fixture.onRefresh = {
                    if fixture.session.pendingCodexHookReview?.phase == .reviewRequired { nextReady.fulfill() }
                }
                successor = Task { try await fixture.start() }
                await fulfillment(of: [nextReady], timeout: 3)
                fixture.onRefresh = nil
                successorOrigin = fixture.session.codexHookGateOrigin
                successorReview = fixture.session.pendingCodexHookReview
                successorGeneration = fixture.session.codexHookGateGeneration
                baselineRefreshes = fixture.refreshes
            case "conflicting":
                let copy = AgentTabSession(tabID: UUID())
                conflictScope.replaceSessions([copy.tabID: copy])
                copy.installPersistentSessionBinding(.init(tabID: copy.tabID, sessionID: fixture.command.identity.sessionID, workspaceID: fixture.command.identity.workspaceID))
            default: XCTFail("Unexpected fixture")
            }
            release?.resume()
            do {
                try await response.value
                XCTFail("Supersession must not return success")
            } catch { XCTAssertEqual(error as? AgentCodexHookReviewResolutionError, .superseded(trustWriteAttempted: true)) }
            do {
                _ = try await gate.value
                XCTFail("Superseded startup must not dispatch")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(fixture.trustCalls, 1)
            XCTAssertEqual(fixture.session.items.count, baselineItems)
            XCTAssertEqual(fixture.session.saveRequestGeneration, 0)
            XCTAssertNil(fixture.session.codexHookGateAudit)
            XCTAssertNil(fixture.session.codexHookGateBindingMemo)
            XCTAssertEqual(fixture.session.codexHookGateOrigin, successorOrigin)
            XCTAssertEqual(fixture.refreshes, baselineRefreshes)
            XCTAssertEqual(fixture.interactionRefreshes, ["reacquired", "rebound", "newRun", "conflicting"].contains(drift) ? 1 : 0)
            if let successor {
                XCTAssertEqual(fixture.session.pendingCodexHookReview, successorReview)
                XCTAssertEqual(fixture.session.codexHookGateGeneration, successorGeneration)
                XCTAssertNotNil(fixture.session.codexHookReviewContinuation)
                XCTAssertNil(fixture.session.codexHookGateAttemptToken)
                fixture.cleanup()
                do { _ = try await successor.value
                    XCTFail("Cleanup cancels successor")
                } catch { XCTAssertTrue(error is CancellationError) }
            } else {
                fixture.cleanup()
            }
        }
    }

    @MainActor
    func testInitialDiscoveryAndStaleAdmissionHaveNoSuccessorPublication() async throws {
        let fixture = try Fixture(strict: true)
        let entered = expectation(description: "discovery entered")
        var release: CheckedContinuation<Void, Never>?
        fixture.beforeList = {
            await withCheckedContinuation { continuation in release = continuation
                entered.fulfill()
            }
        }
        let gate = Task { try await fixture.start() }
        await fulfillment(of: [entered], timeout: 3)
        fixture.scope.replaceSessions([:])
        fixture.scope.replaceSessions([fixture.session.tabID: fixture.session])
        release?.resume()
        do { _ = try await gate.value
            XCTFail("Old discovery must fail")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(fixture.session.pendingCodexHookReview)
        XCTAssertNil(fixture.session.codexHookGateOrigin)
        XCTAssertEqual(fixture.refreshes, 0)
        XCTAssertEqual(fixture.session.saveRequestGeneration, 0)
        do { _ = try await fixture.start()
            XCTFail("Old command must fail before another discovery")
        } catch { XCTAssertEqual(error as? AgentCodexHookReviewResolutionError, .staleWriter) }
        XCTAssertEqual(fixture.listCalls, 1)
        fixture.cleanup()
    }

    @MainActor
    func testCoalescedGateWaitsForDispatchAndStopJoinsAdmittedTrust() async throws {
        for stop in [false, true] {
            let fixture = try Fixture(strict: true)
            let ready = expectation(description: "review ready")
            fixture.onRefresh = {
                if fixture.session.pendingCodexHookReview?.phase == .reviewRequired { ready.fulfill() }
            }
            let owner = Task { try await fixture.start() }
            await fulfillment(of: [ready], timeout: 3)
            fixture.onRefresh = nil
            let coalesced = expectation(description: "coalesced waiter installed")
            fixture.runtime.test_onHookGateCoalescedWaiterInstalled = { coalesced.fulfill() }
            let follower = Task { try await fixture.start() }
            await fulfillment(of: [coalesced], timeout: 3)
            fixture.runtime.test_onHookGateCoalescedWaiterInstalled = nil
            let request = try XCTUnwrap(fixture.session.pendingCodexHookReview)
            let submitted = expectation(description: "trust submitted")
            var release: CheckedContinuation<Void, Never>?
            fixture.beforeTrust = {
                await withCheckedContinuation { continuation in release = continuation
                    submitted.fulfill()
                }
            }
            let response = Task {
                try await fixture.runtime.submitCodexHookReviewDecision(command: fixture.command, requestID: request.id, decision: .approveAll)
            }
            await fulfillment(of: [submitted], timeout: 3)
            if stop { fixture.runtime.cancelPendingApproval(for: fixture.session) }
            var drained = false
            let draining = expectation(description: "runtime drain entered")
            let drain = Task {
                draining.fulfill()
                await fixture.runtime.drainPendingEffects(for: fixture.session)
                drained = true
            }
            await fulfillment(of: [draining], timeout: 3)
            XCTAssertFalse(drained, "An admitted trust write must join, not disappear on Stop")
            release?.resume()
            if stop {
                do { try await response.value
                    XCTFail("Stop supersedes response")
                } catch { XCTAssertEqual(error as? AgentCodexHookReviewResolutionError, .superseded(trustWriteAttempted: true)) }
                for task in [owner, follower] {
                    do { _ = try await task.value
                        XCTFail("Stop must cancel all gate waiters")
                    } catch { XCTAssertTrue(error is CancellationError) }
                }
                XCTAssertEqual(fixture.session.saveRequestGeneration, 0)
            } else {
                try await response.value
                let token = try await owner.value
                XCTAssertEqual(fixture.session.codexHookGateCoalescedContinuations.count, 1, "Approval alone must not release a second dispatch")
                try fixture.session.finishCodexHookGateOwnerDispatch(token: XCTUnwrap(token), succeeded: true)
                let followerToken = try await follower.value
                XCTAssertNil(followerToken)
            }
            await drain.value
            XCTAssertTrue(drained)
            XCTAssertEqual(fixture.trustCalls, 1)
            XCTAssertTrue(fixture.session.codexHookGateCoalescedContinuations.isEmpty)
            fixture.cleanup()
        }
    }

    @MainActor
    func testDiscoveryRetryAndInventoryDriftRemainBoundToOriginalGate() async throws {
        for retry in [false, true] {
            let fixture = try Fixture(strict: true)
            if retry { fixture.listError = CodexHookTrustError.discoveryFailed(cwdErrors: ["fixture discovery failure"]) }
            let ready = expectation(description: "initial review including failure has waiter")
            fixture.onRefresh = {
                XCTAssertNotNil(fixture.session.codexHookReviewContinuation)
                ready.fulfill()
            }
            let gate = Task { try await fixture.start() }
            await fulfillment(of: [ready], timeout: 3)
            fixture.onRefresh = nil
            let request = try XCTUnwrap(fixture.session.pendingCodexHookReview)
            if retry {
                XCTAssertEqual(request.phase, .discoveryFailed)
                fixture.listError = nil
                let entered = expectation(description: "retry discovery held")
                var release: CheckedContinuation<Void, Never>?
                fixture.beforeList = {
                    await withCheckedContinuation { continuation in release = continuation
                        entered.fulfill()
                    }
                }
                let response = Task {
                    try await fixture.runtime.submitCodexHookReviewDecision(command: fixture.command, requestID: request.id, decision: .retryDiscovery)
                }
                await fulfillment(of: [entered], timeout: 3)
                fixture.scope.replaceSessions([:])
                release?.resume()
                do { try await response.value
                    XCTFail("Detached retry must not refresh review")
                } catch { XCTAssertEqual(error as? AgentCodexHookReviewResolutionError, .superseded(trustWriteAttempted: false)) }
                XCTAssertNil(fixture.session.pendingCodexHookReview)
            } else {
                fixture.trustError = CodexHookTrustError.inventoryChanged(replacement: fixture.unresolved)
                try await fixture.runtime.submitCodexHookReviewDecision(command: fixture.command, requestID: request.id, decision: .approveAll)
                XCTAssertEqual(fixture.session.pendingCodexHookReview?.phase, .reviewRequired)
                XCTAssertNotNil(fixture.session.codexHookReviewContinuation)
                XCTAssertNil(fixture.session.codexHookGateAttemptToken)
                fixture.runtime.cancelPendingApproval(for: fixture.session)
            }
            do { _ = try await gate.value
                XCTFail("Cancelled gate must settle")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(fixture.session.saveRequestGeneration, 0)
            XCTAssertNil(fixture.session.codexHookGateAudit)
            fixture.cleanup()
        }
    }

    @MainActor
    private final class Fixture {
        let store = AgentSessionRuntimeStore()
        let scope: AgentSessionRuntimeStore.Scope
        let session = AgentTabSession(tabID: UUID())
        let runtime: AgentSessionInteractionRuntime
        let command: AgentSessionRuntimeStore.Command
        let unresolved: CodexHookInventory
        let trusted: CodexHookInventory
        var controller: Controller!
        var onRefresh: (() -> Void)?
        var beforeTrust: (() async -> Void)?
        var beforeList: (() async -> Void)?
        var listError: Error?
        var trustError: Error?
        var trustCalls = 0
        var listCalls = 0
        var refreshes = 0
        var interactionRefreshes = 0

        init(strict: Bool) throws {
            scope = store.makeScope()
            session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: UUID(), workspaceID: UUID()))
            session.recordRestorationAuthoritative(.persistedPayloadApplied)
            scope.replaceSessions([session.tabID: session])
            runtime = scope.interactions(routeID: 42, approvalStore: ApplyEditsApprovalStore())
            runtime.codexHookApprovalSettings = Policy(strict: strict)
            command = try runtime.codexHookCommand(for: session)
            unresolved = try Self.inventory(status: .untrusted)
            trusted = try Self.inventory(status: .trusted)
            scope.persistence.composition = .init(
                workspace: { nil }, workspaceWithID: { _ in nil }, displayName: { _ in "Hook runtime" },
                isSuppressed: { false }, bypassesSuppression: { false }, isPreparedSavedHost: { true },
                saveAdmission: { _ in nil }, creationIsCurrent: { _ in false }, admitBinding: { _ in nil }
            )
            controller = Controller(list: { [unowned self] in
                listCalls += 1
                await beforeList?()
                if let listError { throw listError }
                return unresolved
            }, trust: { [unowned self] candidates, fingerprint in
                trustCalls += 1
                XCTAssertEqual(candidates, unresolved.unresolvedProjectHooks.map { CodexHookTrustCandidate(key: $0.key, currentHash: $0.currentHash) })
                XCTAssertEqual(fingerprint, unresolved.fingerprint)
                await beforeTrust?()
                if let trustError { throw trustError }
                return trusted
            })
            session.codexController = controller
            _ = scope.presentation.attach(session, sink: .init(
                activityChanged: { _, _ in }, refresh: { [weak self] _, _, _ in
                    self?.refreshes += 1
                    self?.onRefresh?()
                }, turnComplete: { _ in }, turnFailed: { _, _ in },
                interaction: { [weak self] _ in self?.interactionRefreshes += 1 }
            ))
        }

        func start() async throws -> UUID? {
            try await runtime.gateFirstTurnForProjectHooks(command: command, controller: controller, executionCWD: "/tmp/hooks")
        }

        func cleanup() {
            session.resetCodexHookGateBinding()
            session.saveDebounceTask?.cancel()
        }

        private static func inventory(status: CodexHookTrustStatus) throws -> CodexHookInventory {
            try CodexHookInventory(executionCWD: "/tmp/hooks", hooks: [CodexHookMetadata(
                eventName: "Stop", source: "project", sourcePath: "/tmp/hooks/.codex/config.toml", key: "hook-a",
                currentHash: "hash-a", enabled: true, handlerType: "command", trustStatus: status, commandOrHandler: "echo test"
            )])
        }
    }

    private struct Policy: CodexHookApprovalSettingsProviding {
        let strict: Bool
        func codexHookApprovalStrictModeEnabled(workspaceID _: UUID?) -> Bool {
            strict
        }
    }

    private final class Controller: CodexSessionControllerPassiveStubDefaults {
        let list: @MainActor () async throws -> CodexHookInventory
        let trust: @MainActor ([CodexHookTrustCandidate], String) async throws -> CodexHookInventory
        var events: AsyncStream<CodexNativeSessionController.Event> {
            AsyncStream { $0.finish() }
        }

        init(
            list: @escaping @MainActor () async throws -> CodexHookInventory,
            trust: @escaping @MainActor ([CodexHookTrustCandidate], String) async throws -> CodexHookInventory
        ) {
            self.list = list
            self.trust = trust
        }

        func listHooksForCurrentWorkspace() async throws -> CodexHookInventory {
            try await list()
        }

        func trustHooksForCurrentWorkspace(expectedCandidates: [CodexHookTrustCandidate], expectedInventoryFingerprint: String) async throws -> CodexHookInventory {
            try await trust(expectedCandidates, expectedInventoryFingerprint)
        }

        func shutdown() async {}
    }
}
