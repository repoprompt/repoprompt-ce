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
        assertSendable(DomainAgentRunExecutionOperationResult.completed(assistantText: "done"))
        assertSendable(DomainAgentRunExecutionResult.superseded)
        assertSendable(DomainAgentRunExecutionTraceEvent.executionStarted)
        assertSendable(DomainAgentRunExecutionReport(
            result: .superseded,
            trace: [.executionStarted, .executionSuperseded]
        ))
    }

    // MARK: - Shared transient execution core

    func testExecutionCoreClassifiesCompletionAndInvokesOperationOnce() async {
        var invocationCount = 0

        let report = await DomainAgentRunExecutionCore.execute {
            invocationCount += 1
            return .completed(assistantText: "done")
        }

        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(
            report,
            DomainAgentRunExecutionReport(
                result: .terminal(.completed(assistantText: "done")),
                trace: [.executionStarted, .terminalOutcomeProduced(.completed)]
            )
        )
    }

    func testExecutionCoreClassifiesCancellationWithoutCallingFailureMapper() async {
        var failureMapperCallCount = 0

        let report = await DomainAgentRunExecutionCore.execute(failureText: { _ in
            failureMapperCallCount += 1
            return "unexpected"
        }) {
            throw CancellationError()
        }

        XCTAssertEqual(failureMapperCallCount, 0)
        XCTAssertEqual(
            report,
            DomainAgentRunExecutionReport(
                result: .terminal(.cancelled()),
                trace: [.executionStarted, .terminalOutcomeProduced(.cancelled)]
            )
        )
    }

    func testExecutionCorePreservesFailureMappingAndClassification() async {
        var failureMapperCallCount = 0

        let report = await DomainAgentRunExecutionCore.execute(
            failureReason: .timeout,
            failureText: { _ in
                failureMapperCallCount += 1
                return "mapped failure"
            }
        ) {
            throw ExecutionFixtureError.failed
        }

        XCTAssertEqual(failureMapperCallCount, 1)
        XCTAssertEqual(
            report,
            DomainAgentRunExecutionReport(
                result: .terminal(.failed(assistantText: "mapped failure", reason: .timeout)),
                trace: [.executionStarted, .terminalOutcomeProduced(.failed)]
            )
        )
    }

    func testExecutionCoreKeepsSupersessionExplicitAndNonterminal() async {
        var failureMapperCallCount = 0

        let report = await DomainAgentRunExecutionCore.execute(failureText: { _ in
            failureMapperCallCount += 1
            return "unexpected"
        }) {
            .superseded
        }

        XCTAssertEqual(failureMapperCallCount, 0)
        XCTAssertEqual(
            report,
            DomainAgentRunExecutionReport(
                result: .superseded,
                trace: [.executionStarted, .executionSuperseded]
            )
        )
    }

    func testOneShotAndStreamingFixturesHaveDeterministicLifecycleParity() async {
        for scenario in ExecutionFixtureScenario.allCases {
            let oneShot = await executionFixtureReport(style: .oneShot, scenario: scenario)
            let streaming = await executionFixtureReport(style: .streaming, scenario: scenario)

            XCTAssertEqual(streaming, oneShot, "scenario: \(scenario)")
        }
    }

    func testExecutionCorePreservesCallerActorIsolation() async {
        let mainActorProbe = await MainActorExecutionProbe()
        let mainActorReport = await mainActorProbe.execute()
        let actorProbe = ExecutionActorProbe()
        let actorReport = await actorProbe.execute()
        let mainActorInvocationCount = await mainActorProbe.invocationCount
        let actorInvocationCount = await actorProbe.invocationCount

        XCTAssertEqual(mainActorInvocationCount, 1)
        XCTAssertEqual(actorInvocationCount, 1)
        XCTAssertEqual(mainActorReport.trace, [.executionStarted, .terminalOutcomeProduced(.completed)])
        XCTAssertEqual(actorReport.trace, mainActorReport.trace)
    }

    func testExecutionCoreDoesNotReinterpretAlreadyCancelledTask() async {
        let report = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await DomainAgentRunExecutionCore.execute {
                .completed(assistantText: "provider returned normally")
            }
        }.value

        XCTAssertEqual(
            report.result,
            .terminal(.completed(assistantText: "provider returned normally"))
        )
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

    private enum ExecutionFixtureError: Error {
        case failed
    }

    private enum ExecutionFixtureStyle {
        case oneShot
        case streaming
    }

    private enum ExecutionFixtureScenario: CaseIterable {
        case completed
        case cancelled
        case failed
        case superseded
    }

    private func executionFixtureReport(
        style: ExecutionFixtureStyle,
        scenario: ExecutionFixtureScenario
    ) async -> DomainAgentRunExecutionReport {
        await DomainAgentRunExecutionCore.execute(failureText: { _ in "fixture failure" }) {
            switch scenario {
            case .completed:
                if style == .streaming {
                    let events = AsyncStream<Int> { continuation in
                        continuation.yield(1)
                        continuation.yield(2)
                        continuation.finish()
                    }
                    var consumed: [Int] = []
                    for await event in events {
                        consumed.append(event)
                    }
                    XCTAssertEqual(consumed, [1, 2])
                }
                return .completed(assistantText: "fixture complete")
            case .cancelled:
                throw CancellationError()
            case .failed:
                throw ExecutionFixtureError.failed
            case .superseded:
                return .superseded
            }
        }
    }

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

@MainActor
private final class MainActorExecutionProbe {
    private(set) var invocationCount = 0

    func execute() async -> DomainAgentRunExecutionReport {
        await DomainAgentRunExecutionCore.execute {
            invocationCount += 1
            return .completed(assistantText: nil)
        }
    }
}

private actor ExecutionActorProbe {
    private(set) var invocationCount = 0

    func execute() async -> DomainAgentRunExecutionReport {
        await DomainAgentRunExecutionCore.execute {
            invocationCount += 1
            return .completed(assistantText: nil)
        }
    }
}
