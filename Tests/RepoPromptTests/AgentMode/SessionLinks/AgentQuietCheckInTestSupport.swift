import Foundation
@_spi(TestSupport) @testable import RepoPromptApp

/// Small source/lifecycle fixture shared by pure quiet tests and later native replay fixtures.
@MainActor
struct AgentQuietCheckInFixture {
    var ledger = AgentRunQuietLedger()
    let owner = AgentRunOwnership(binding: AgentRunBindingIdentity(tabID: UUID(), persistentSessionID: UUID()))
    let wakeID = UUID()
    let startKey = 10

    mutating func begin(provider: AgentSessionLinkPromptProviderContext = .codexExec, routine: Bool = true) {
        ledger.begin(owner: owner, startKey: startKey, provider: provider)
        if routine { ledger.markRoutineWake(owner: owner, wakeID: wakeID) }
    }

    func rows(_ texts: [String], kind: AgentChatItemKind = .assistant) -> [AgentChatItem] {
        texts.enumerated().map { offset, text in
            AgentChatItem(kind: kind, text: text, sequenceIndex: startKey + offset)
        }
    }

    @discardableResult
    mutating func seal(
        _ rows: [AgentChatItem] = [],
        state: AgentSessionRunState = .completed,
        normal: Bool = true,
        successor: Bool = false,
        complete: Bool = true
    ) -> AgentRunQuietLedger.Seal? {
        ledger.settle(
            owner: owner,
            terminalState: state,
            classifiesQuietCheckIn: normal,
            hasSuccessor: successor,
            endKey: rows.last?.sequenceIndex ?? startKey - 1,
            rangeIsComplete: complete,
            rows: rows
        )
    }
}

/// The same real source/barrier replay used by the model and scale fixtures. No provider process,
/// replacement classifier, or final-row insertion: input passes the accepted stream seam.
@MainActor
enum AgentQuietCheckInReplay {
    static func settle(
        _ session: AgentTabSession,
        harness: AgentSessionLinkRunnerHarness,
        form: Int,
        wakeID: UUID
    ) async -> AgentRunOwnership {
        session.runState = .running
        if session.runID == nil { session.installRunID(UUID()) }
        let owner = session.beginRunAttempt(source: "quiet-model-replay")
        let routine = form != 4
        session.quietLedger.recordPhysicalDispatch(owner: owner, wakeID: wakeID, routineQuietCheckIn: routine, alreadyAcquired: false)
        if form == 3 { session.noteAcceptedTaskInput() }
        if form == 5 {
            _ = session.recordRunProgress(ownership: owner, kind: .toolActivity, stage: .running)
        }
        if form != 0 {
            await harness.host.test_handleStreamResult(
                .init(type: "content", text: form == 2 ? "ordinary work" : "[ack]"),
                session: session, runID: session.runID!, runAttemptID: owner.attemptID
            )
        }
        _ = await AgentRunTerminalCommitBarrier().commit(.init(
            binding: harness.hooks.bindTerminalSession(session), ownership: owner, expectedRunID: session.runID,
            terminalState: .completed, source: "quiet-model-replay", attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: false, supportsFollowUp: false, notifyTurnComplete: true, classifiesQuietCheckIn: true
        ))
        return owner
    }

    static func toolHeavyTurn(date: Date) -> AgentTranscriptTurn {
        var rows: [AgentChatItem] = []
        for index in 0 ..< 24 {
            let invocation = UUID()
            rows.append(.init(
                timestamp: date,
                kind: .toolCall,
                text: "Read source",
                toolName: "read_file",
                toolInvocationID: invocation,
                toolArgsJSON: "{\"path\":\"Source.swift\"}",
                sequenceIndex: rows.count
            ))
            let body = "result-\(index):" + String(repeating: "generic source line\n", count: 3500)
            let json = "{\"content\":\"" + body.replacingOccurrences(of: "\n", with: "\\n") + "\"}"
            rows.append(.init(
                timestamp: date,
                kind: .toolResult,
                text: body,
                toolName: "read_file",
                toolInvocationID: invocation,
                toolResultJSON: json,
                toolIsError: false,
                sequenceIndex: rows.count
            ))
        }
        rows.append(.init(timestamp: date, kind: .assistant, text: String(repeating: "ordinary explanation ", count: 800), sequenceIndex: rows.count))
        rows.append(.init(timestamp: date, kind: .thinking, text: String(repeating: "retired reasoning ", count: 14000), sequenceIndex: rows.count))
        return .init(
            responseSpans: [.init(
                lifecycle: .completed,
                startedAt: date,
                completedAt: date,
                activities: rows.map { .init(from: $0, toolExecution: AgentTranscriptToolNormalizer.toolExecution(for: $0)) }
            )],
            retentionTier: .condensed,
            terminalState: .completed,
            startedAt: date,
            completedAt: date
        )
    }
}
