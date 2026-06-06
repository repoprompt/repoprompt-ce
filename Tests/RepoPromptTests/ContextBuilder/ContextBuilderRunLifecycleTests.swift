import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class ContextBuilderRunLifecycleTests: XCTestCase {
    func testTerminalClaimAndContinuationAreExactlyOnce() async throws {
        let tabID = UUID()
        let session = ContextBuilderAgentViewModel.TabSession(tabID: tabID)
        let ownership = session.beginRunAttempt(source: "test")
        var capturedRecord: ContextBuilderRunRecord?

        let waiter = Task<ContextBuilderAgentViewModel.ContextBuilderRunSnapshot, Error> { @MainActor in
            try await withCheckedThrowingContinuation { continuation in
                capturedRecord = ContextBuilderRunRecord(
                    runID: UUID(),
                    tabID: tabID,
                    session: session,
                    ownership: ownership,
                    origin: .mcp(controlToken: UUID()),
                    agentKind: .claudeCode,
                    modelRaw: AgentModel.defaultModel.rawValue,
                    continuation: continuation
                )
            }
        }

        await Task.yield()
        let record = try XCTUnwrap(capturedRecord)
        XCTAssertTrue(record.claimTerminal(.completed))
        XCTAssertFalse(record.claimTerminal(.cancelled))

        let continuation = try XCTUnwrap(record.takeContinuation())
        XCTAssertNil(record.takeContinuation())
        continuation.resume(
            returning: ContextBuilderAgentViewModel.ContextBuilderRunSnapshot(
                runID: record.runID,
                tabID: tabID,
                finalState: nil,
                runState: .completed,
                agentOutput: "done",
                usedAgentOutputAsPrompt: false
            )
        )

        let snapshot = try await waiter.value
        XCTAssertEqual(snapshot.runID, record.runID)
        XCTAssertEqual(snapshot.agentOutput, "done")
    }

    func testLogicalReleaseAdmitsSuccessorAndRejectsOldEvents() {
        let registry = ContextBuilderRunRegistry()
        let tabID = UUID()
        let session = ContextBuilderAgentViewModel.TabSession(tabID: tabID)
        let firstOwnership = session.beginRunAttempt(source: "first")
        let first = makeRecord(tabID: tabID, session: session, ownership: firstOwnership)

        XCTAssertTrue(registry.register(first))
        XCTAssertTrue(registry.acceptsEvents(from: first, currentSession: session))
        let blocked = makeRecord(tabID: tabID, session: session, ownership: firstOwnership)
        XCTAssertFalse(registry.register(blocked))
        XCTAssertTrue(first.claimTerminal(.cancelled))
        XCTAssertTrue(registry.releaseActiveSlot(for: first))

        let secondOwnership = session.beginRunAttempt(source: "second")
        let second = makeRecord(tabID: tabID, session: session, ownership: secondOwnership)
        XCTAssertTrue(registry.register(second))
        XCTAssertFalse(registry.acceptsEvents(from: first, currentSession: session))
        XCTAssertTrue(registry.acceptsEvents(from: second, currentSession: session))
    }

    func testPendingTeardownDoesNotRetainActiveRunSlot() {
        let registry = ContextBuilderRunRegistry()
        let tabID = UUID()
        let session = ContextBuilderAgentViewModel.TabSession(tabID: tabID)
        let first = makeRecord(
            tabID: tabID,
            session: session,
            ownership: session.beginRunAttempt(source: "first")
        )
        let provider = LifecycleTestProvider()

        XCTAssertTrue(registry.register(first))
        XCTAssertTrue(first.installProvider(provider))
        XCTAssertTrue(first.claimTerminal(.cancelled))
        XCTAssertTrue(registry.releaseActiveSlot(for: first))

        let teardown = try? XCTUnwrap(first.beginTeardown())
        XCTAssertNotNil(teardown)
        XCTAssertTrue((teardown?.provider as AnyObject?) === provider)
        XCTAssertNil(first.beginTeardown())
        XCTAssertTrue(first.isTeardownPending)

        let second = makeRecord(
            tabID: tabID,
            session: session,
            ownership: session.beginRunAttempt(source: "second")
        )
        XCTAssertTrue(registry.register(second))

        first.markProviderDisposalFinished()
        XCTAssertTrue(first.isTeardownPending)
        first.markExecutionTaskFinished()
        XCTAssertFalse(first.isTeardownPending)
        XCTAssertTrue(registry.removeAfterTeardown(first))
        XCTAssertTrue(registry.acceptsEvents(from: second, currentSession: session))
    }

    private func makeRecord(
        tabID: UUID,
        session: ContextBuilderAgentViewModel.TabSession,
        ownership: AgentRunOwnership
    ) -> ContextBuilderRunRecord {
        ContextBuilderRunRecord(
            runID: UUID(),
            tabID: tabID,
            session: session,
            ownership: ownership,
            origin: .ui,
            agentKind: .claudeCode,
            modelRaw: AgentModel.defaultModel.rawValue
        )
    }
}

private final class LifecycleTestProvider: HeadlessAgentProvider {
    func streamAgentMessage(
        _ message: AgentMessage,
        runID: UUID?
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func dispose() async {}
}
