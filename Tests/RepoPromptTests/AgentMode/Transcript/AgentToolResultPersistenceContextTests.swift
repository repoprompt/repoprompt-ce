import Foundation
@testable import RepoPromptApp
import XCTest

/// `sanitizeTranscriptForPersistenceWithMetrics` uses a fresh per-pass
/// `AgentToolResultProcessingContext` for JSON-parse memoization, but its item-ID-keyed
/// execution cache is disabled: a later activity that shares an earlier activity's ID
/// must be normalized from its own content, never from a cached execution — including
/// one already transformed by this same pass. These tests pin equivalence to the
/// `context: nil` baseline for exactly that input shape.
final class AgentToolResultPersistenceContextTests: XCTestCase {
    private func makeToolCallActivity(
        id: UUID,
        sequenceIndex: Int,
        toolExecution: AgentTranscriptToolExecution?
    ) -> AgentTranscriptActivity {
        AgentTranscriptActivity(
            id: id,
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequenceIndex)),
            sequenceIndex: sequenceIndex,
            role: .assistant,
            itemKind: .toolCall,
            text: "",
            toolExecution: toolExecution
        )
    }

    private func makeExecution(name: String, resultJSON: String?) -> AgentTranscriptToolExecution {
        AgentTranscriptToolExecution(
            stableExecutionID: "exec-\(name)",
            toolName: name,
            invocationID: UUID(),
            argsJSON: nil,
            resultJSON: resultJSON,
            toolIsError: false,
            status: .success
        )
    }

    private func makeTranscript(activities: [AgentTranscriptActivity]) -> AgentTranscript {
        let startedAt = Date(timeIntervalSince1970: 0)
        let user = AgentChatItem.user("request", sequenceIndex: 0)
        return AgentTranscript(
            turns: [
                AgentTranscriptTurn(
                    id: UUID(),
                    request: AgentTranscriptRequestAnchor(from: user),
                    responseSpans: [
                        AgentTranscriptProviderResponseSpan(
                            lifecycle: .completed,
                            startedAt: startedAt,
                            lastActivityAt: startedAt.addingTimeInterval(1),
                            completedAt: startedAt.addingTimeInterval(1),
                            activities: activities
                        )
                    ],
                    retentionTier: .full,
                    terminalState: .completed,
                    startedAt: startedAt,
                    lastActivityAt: startedAt.addingTimeInterval(1),
                    completedAt: startedAt.addingTimeInterval(1)
                )
            ],
            nextSequenceIndex: activities.count + 1
        )
    }

    private func baseline(_ transcript: AgentTranscript) -> AgentTranscript {
        AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
            transcript,
            context: nil,
            purpose: .persistentStorage
        ).transcript
    }

    func testRepeatedActivityIDWithMissingExecutionMatchesNilContextBaseline() {
        let sharedID = UUID()
        let transcript = makeTranscript(activities: [
            makeToolCallActivity(
                id: sharedID,
                sequenceIndex: 1,
                toolExecution: makeExecution(name: "read_file", resultJSON: "{\"ok\":true}")
            ),
            makeToolCallActivity(id: sharedID, sequenceIndex: 2, toolExecution: nil)
        ])

        let optimized = AgentToolResultPersistencePolicy
            .sanitizeTranscriptForPersistenceWithMetrics(transcript).transcript

        XCTAssertEqual(optimized, baseline(transcript))
    }

    func testRepeatedActivityIDWithDistinctExecutionsMatchesNilContextBaseline() {
        let sharedID = UUID()
        let transcript = makeTranscript(activities: [
            makeToolCallActivity(
                id: sharedID,
                sequenceIndex: 1,
                toolExecution: makeExecution(name: "read_file", resultJSON: "{\"a\":1}")
            ),
            makeToolCallActivity(
                id: sharedID,
                sequenceIndex: 2,
                toolExecution: makeExecution(name: "write_file", resultJSON: "{\"b\":2}")
            )
        ])

        let optimized = AgentToolResultPersistencePolicy
            .sanitizeTranscriptForPersistenceWithMetrics(transcript).transcript

        XCTAssertEqual(optimized, baseline(transcript))
    }

    /// Non-vacuity guard: with the fully-caching context the missing-execution fixture
    /// *does* diverge from the nil-context baseline (the second activity inherits the
    /// first's transformed execution), proving the fixtures exercise the hazard the
    /// disabled cache exists to prevent.
    func testFullyCachingContextWouldDivergeOnMissingExecutionFixture() {
        let sharedID = UUID()
        let transcript = makeTranscript(activities: [
            makeToolCallActivity(
                id: sharedID,
                sequenceIndex: 1,
                toolExecution: makeExecution(name: "read_file", resultJSON: "{\"ok\":true}")
            ),
            makeToolCallActivity(id: sharedID, sequenceIndex: 2, toolExecution: nil)
        ])

        let cached = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
            transcript,
            context: AgentToolResultProcessingContext(),
            purpose: .persistentStorage
        ).transcript

        XCTAssertNotEqual(cached, baseline(transcript))
    }
}
