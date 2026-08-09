import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

/// Contract tests for the neutral Agent run execution vocabulary shared by the
/// app-hosted runtime and the direct/headless composition.
final class DomainAgentRunExecutionContractsTests: XCTestCase {
    // MARK: - Command/cancellation contracts

    func testCancellationIntentCanonicalReasonStringsAreStable() {
        XCTAssertEqual(DomainAgentRunCancellationIntent.userStop.cancellationReason, "user_stop")
        XCTAssertEqual(
            DomainAgentRunCancellationIntent.executionLocationChange.cancellationReason,
            "execution_location_change"
        )
        XCTAssertEqual(
            DomainAgentRunCancellationIntent.runtimeShutdown.cancellationReason,
            "runtime_shutdown"
        )
    }

    func testAttachmentTurnDispositionCasesAreDistinctAndExhaustivelyHandled() {
        let dispositions: [DomainAgentRunAttachmentTurnDisposition] = [
            .restoreToPending,
            .deleteFiles,
            .keepFiles
        ]

        XCTAssertEqual(Set(dispositions).count, 3)
        XCTAssertEqual(
            dispositions.map(attachmentDispositionCaseName),
            ["restoreToPending", "deleteFiles", "keepFiles"]
        )
    }

    func testExecutionContractTypesAreSendableValueTypes() {
        // Compile-time Sendable checks: these calls fail to compile if any
        // contract type loses Sendable conformance or value semantics.
        assertSendable(DomainAgentRunCancellationIntent.userStop)
        assertSendable(DomainAgentRunCancellationCompletion.terminalPublished)
        assertSendable(DomainAgentRunAttachmentTurnDisposition.restoreToPending)
        assertSendable(DomainAgentRunTerminalOutcome.completed(assistantText: "done"))
    }

    // MARK: - Terminal outcome result contracts

    func testTerminalOutcomeMapsToCanonicalSnapshotStatus() {
        XCTAssertEqual(DomainAgentRunTerminalOutcome.completed(assistantText: "ok").snapshotStatus, .completed)
        XCTAssertEqual(DomainAgentRunTerminalOutcome.cancelled().snapshotStatus, .cancelled)
        XCTAssertEqual(
            DomainAgentRunTerminalOutcome.failed(assistantText: "boom").snapshotStatus,
            .failed
        )
    }

    func testTerminalOutcomeCarriesExplicitFailureClassification() {
        XCTAssertNil(DomainAgentRunTerminalOutcome.completed(assistantText: nil).failureReason)
        XCTAssertEqual(DomainAgentRunTerminalOutcome.cancelled().failureReason, .cancelled)
        XCTAssertEqual(
            DomainAgentRunTerminalOutcome.failed(assistantText: "agent exploded").failureReason,
            .agentError
        )
        // Hosts preserve their own diagnosis; the contract must not re-derive
        // classification from display text.
        XCTAssertEqual(
            DomainAgentRunTerminalOutcome.failed(assistantText: "timed out", reason: .timeout).failureReason,
            .timeout
        )
    }

    // MARK: - Compatibility with the store's pre-existing exactly-once settlement

    // The exactly-once-per-epoch guarantee is pre-existing
    // `DomainAgentRunSessionStore` behavior, not something the outcome mapping
    // introduces; this test only verifies that outcome-mapped publication
    // composes with that store behavior unchanged.
    func testOutcomeMappedTerminalPublicationRemainsCompatibleWithStoreExactlyOnceSemantics() async {
        let identity = makeIdentity()
        let store = makeSessionStore(identity: identity, profile: "execution-contracts-once")
        let sessionID = UUID()
        let registration = await store.register(sessionID: sessionID)
        let epoch: DomainAgentRunTurnEpoch
        switch await store.beginEpoch(
            registration: registration,
            activationID: UUID(),
            expectedCurrentEpoch: nil,
            transitionKind: .initial
        ) {
        case let .accepted(value):
            epoch = value
        case let .stale(current):
            XCTFail("unexpected stale epoch begin: \(String(describing: current))")
            return
        case let .rejected(reason):
            XCTFail("unexpected rejected epoch begin: \(reason)")
            return
        }

        let outcome = DomainAgentRunTerminalOutcome.failed(assistantText: "provider failed", reason: .agentError)
        let terminal = makeSnapshot(sessionID: sessionID, outcome: outcome)
        let envelope = DomainAgentRunTerminalPublicationEnvelope(epoch: epoch, snapshot: terminal)
        let commitID = UUID()

        let first = await store.publishTerminal(
            envelope,
            registration: registration,
            commitID: commitID,
            successorKind: nil
        )
        XCTAssertEqual(first, .accepted(successorEpoch: nil))

        // Same commit replays idempotently without re-publishing.
        let replay = await store.publishTerminal(
            envelope,
            registration: registration,
            commitID: commitID,
            successorKind: nil
        )
        XCTAssertEqual(replay, .accepted(successorEpoch: nil))

        // A different terminal commit for the same epoch must be rejected.
        let competing = await store.publishTerminal(
            envelope,
            registration: registration,
            commitID: UUID(),
            successorKind: nil
        )
        XCTAssertEqual(competing, .rejected(reason: "different_commit_already_published"))

        let settled = await store.snapshot(for: registration)
        XCTAssertEqual(settled?.status, .failed)
        XCTAssertEqual(settled?.failureReason, .agentError)
    }

    // MARK: - Helpers

    private func assertSendable(_ value: some Sendable & Equatable) {
        XCTAssertEqual(value, value)
    }

    private func attachmentDispositionCaseName(
        _ disposition: DomainAgentRunAttachmentTurnDisposition
    ) -> String {
        switch disposition {
        case .restoreToPending: "restoreToPending"
        case .deleteFiles: "deleteFiles"
        case .keepFiles: "keepFiles"
        }
    }

    private func makeSnapshot(
        sessionID: UUID,
        outcome: DomainAgentRunTerminalOutcome
    ) -> DomainAgentRunSnapshot {
        DomainAgentRunSnapshot(
            sessionID: sessionID,
            runID: sessionID,
            tabID: nil,
            sessionName: nil,
            agentRaw: "codexExec",
            agentDisplayName: "Codex CLI",
            modelRaw: nil,
            reasoningEffortRaw: nil,
            status: outcome.snapshotStatus,
            statusText: outcome.assistantText,
            latestAssistantPreview: outcome.assistantText,
            interaction: nil,
            transcriptItemCount: outcome.assistantText == nil ? 0 : 1,
            updatedAt: Date(),
            parentSessionID: nil,
            failureReason: outcome.failureReason,
            worktreeBindings: [],
            activeWorktreeMerges: []
        )
    }

    private func makeIdentity() -> DomainRuntimeIdentity {
        DomainRuntimeIdentity(
            runtimeID: UUID(),
            lifecycleGeneration: 1,
            processID: 42,
            mode: .standalone,
            createdAt: Date()
        )
    }

    private func makeSessionStore(
        identity: DomainRuntimeIdentity,
        profile: String
    ) -> DomainAgentRunSessionStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpce-execution-contracts-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configuration = DomainRuntimeConfiguration(
            mode: identity.mode,
            profileIdentifier: profile,
            storageDirectory: root,
            eventDirectory: root.appendingPathComponent("Events"),
            temporaryDirectory: root.appendingPathComponent("Temporary"),
            externalReloadInterval: nil
        )
        return DomainAgentRunSessionStore(
            identity: identity,
            persistence: DomainPersistenceCoordinator(configuration: configuration, identity: identity),
            profileIdentifier: profile
        )
    }
}
