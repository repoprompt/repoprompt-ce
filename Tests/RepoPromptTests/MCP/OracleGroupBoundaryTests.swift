import Combine
import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
@testable import RepoPromptMCPCore
import RepoPromptSettingsCore
import XCTest

#if DEBUG
    /// Lane/group mutual exclusion (F1) and in-app cancellation of owned Oracle sends (F2), driven
    /// through the real `MCPOracleToolService` → configured-roster dispatch with a held provider.
    @MainActor
    final class OracleGroupLaneConflictTests: XCTestCase {
        private typealias Harness = OracleTicketExecutionHarness

        private static let laneBusyMessage = "Oracle lane is busy with an active conversation or group turn. Wait for it to finish before continuing this chat."

        // MARK: - F1: explicit member continuation vs. group turn

        func testExplicitMemberContinuationConflictsWhileGroupTurnIsInFlight() async throws {
            try await Harness.withControlledFixture(additionalModels: [.gpt54]) { ctx in
                let (groupID, lanes) = try await self.createGroup(ctx)
                ctx.provider.behavior = { _ in .hold }
                let groupTurn = Task { try await self.continueGroup(ctx, message: "Held group turn") }
                try await ctx.awaitSends(4)
                XCTAssertTrue(lanes.allSatisfy { ctx.oracle.isSessionStreaming($0.id) })
                let inFlight = try await ctx.loadGroup(groupID)
                XCTAssertEqual(inFlight.turns.last?.state, .prepared)
                let transcripts = lanes.map { ctx.oracle.messagesSnapshot(for: $0.id).map(\.id) }

                // Primary and additional lane, on both entry paths.
                for lane in lanes {
                    for entry in Harness.EntryPath.allCases {
                        try await self.assertLaneBusy(ctx, chatID: lane.shortID, groupID: groupID, via: entry)
                    }
                }
                XCTAssertEqual(ctx.provider.sendCount, 4, "A rejected continuation never reaches the provider")
                XCTAssertTrue(lanes.allSatisfy { ctx.oracle.isSessionStreaming($0.id) }, "The group turn was not cancelled")
                XCTAssertEqual(lanes.map { ctx.oracle.messagesSnapshot(for: $0.id).map(\.id) }, transcripts)
                let unchanged = try await ctx.loadGroup(groupID)
                XCTAssertEqual(unchanged, inFlight)

                ctx.provider.releaseHeld()
                let settled = try await groupTurn.value
                XCTAssertEqual(settled.objectValue?["oracle_group_id"]?.stringValue, groupID)
                XCTAssertEqual(settled.objectValue?["status"]?.stringValue, "completed")
                XCTAssertEqual(settled.objectValue?["oracle_count"]?.intValue, 2)

                // Rejection did not retain anything: a valid retry succeeds on each path.
                ctx.provider.behavior = { _ in .complete }
                for (lane, entry) in zip(lanes, Harness.EntryPath.allCases) {
                    let reply = try await self.continueLane(ctx, chatID: lane.shortID, via: entry, message: "Retry \(entry)")
                    self.assertCompletedLaneReply(reply, chatID: lane.shortID, via: entry)
                }
                XCTAssertEqual(ctx.provider.sendCount, 6)
            }
        }

        /// ask_oracle's omitted-op explicit `chat_id` continuation shares the roster busy check.
        func testAskOracleExplicitMemberContinuationConflictsWhileGroupTurnIsInFlight() async throws {
            try await Harness.withControlledFixture(additionalModels: [.gpt54]) { ctx in
                let (groupID, lanes) = try await self.createGroup(ctx)
                ctx.provider.behavior = { _ in .hold }
                let groupTurn = Task { try await self.continueGroup(ctx, message: "Held group turn") }
                try await ctx.awaitSends(4)
                let inFlight = try await ctx.loadGroup(groupID)
                XCTAssertEqual(inFlight.turns.last?.state, .prepared)

                do {
                    _ = try await self.askOracleLane(ctx, chatID: lanes[1].shortID, message: "Rejected ask_oracle lane")
                    XCTFail("ask_oracle explicit member continuation must conflict")
                } catch let error as ChatToolError {
                    XCTAssertEqual(error.code, .conflict)
                    XCTAssertEqual(error.message, Self.laneBusyMessage)
                    XCTAssertEqual(error.details?["oracle_group_id"], groupID)
                }
                XCTAssertEqual(ctx.provider.sendCount, 4, "No third lane dispatch")
                XCTAssertTrue(lanes.allSatisfy { ctx.oracle.isSessionStreaming($0.id) }, "The group turn was not cancelled")
                let unchanged = try await ctx.loadGroup(groupID)
                XCTAssertEqual(unchanged, inFlight)

                ctx.provider.releaseHeld()
                let settled = try await groupTurn.value
                XCTAssertEqual(settled.objectValue?["status"]?.stringValue, "completed")

                ctx.provider.behavior = { _ in .complete }
                let reply = try await self.askOracleLane(ctx, chatID: lanes[1].shortID, message: "Lane after settlement")
                self.assertCompletedLaneReply(reply, chatID: lanes[1].shortID, via: .blocking)
                XCTAssertEqual(ctx.provider.sendCount, 5, "Lane-only: exactly the addressed member sent")
            }
        }

        func testExplicitMemberContinuationConflictsWhenTargetStreamsTurnIsUnsettledOrClaimIsHeld() async throws {
            try await Harness.withControlledFixture(additionalModels: [.gpt54]) { ctx in
                let (groupID, lanes) = try await self.createGroup(ctx)
                let target = lanes[1]

                // Terminal turn, but the target is streaming an ordinary UI send.
                ctx.provider.behavior = { _ in .hold }
                let loaded = await ctx.oracle.ensureSessionMessagesLoaded(target.id)
                XCTAssertTrue(loaded)
                let sent = await ctx.oracle.sendMessage("UI turn", sessionID: target.id, overrideModel: .gpt54)
                XCTAssertNotNil(sent, "The UI send admitted a query")
                try await ctx.awaitSends(3)
                XCTAssertTrue(ctx.oracle.isSessionStreaming(target.id))
                let terminal = try await ctx.loadGroup(groupID)
                XCTAssertEqual(terminal.turns.last?.state, .terminal)
                for entry in Harness.EntryPath.allCases {
                    try await self.assertLaneBusy(ctx, chatID: target.shortID, groupID: groupID, via: entry)
                }
                XCTAssertEqual(ctx.provider.sendCount, 3)
                XCTAssertTrue(ctx.oracle.isSessionStreaming(target.id), "The current producer stays alive")
                let finalized = XCTestExpectation(description: "UI turn finalized")
                finalized.assertForOverFulfill = false
                let streamingObservation = ctx.oracle.$streamingSessions.sink { if !$0.contains(target.id) { finalized.fulfill() } }
                ctx.provider.releaseHeld()
                try await ctx.driver.fixture.awaitGateEvent(finalized)
                streamingObservation.cancel()

                // Terminal and idle, but another invocation (any runtime) holds the group claim.
                let idle = try await ctx.loadGroup(groupID)
                let foreignClaim = try await AppDomainRuntimeComposition.shared.oracleGroupClaimManager.acquire(
                    group: idle, owner: idle.owner, invocationID: UUID(), runID: UUID()
                )
                for entry in Harness.EntryPath.allCases {
                    try await self.assertLaneBusy(ctx, chatID: target.shortID, groupID: groupID, via: entry)
                }
                foreignClaim.release()
                XCTAssertEqual(ctx.provider.sendCount, 3)
                let afterClaim = try await ctx.loadGroup(groupID)
                XCTAssertEqual(afterClaim, idle)
                ctx.provider.behavior = { _ in .complete }
                let retry = try await self.continueLane(ctx, chatID: target.shortID, via: .blocking, message: "After claim")
                self.assertCompletedLaneReply(retry, chatID: target.shortID, via: .blocking)
                XCTAssertEqual(ctx.provider.sendCount, 4)

                // Canonical latest turn is nonterminal (another runtime's prepared turn); target idle.
                let settled = try await ctx.loadGroup(groupID)
                let foreignTurn = try OracleTurnRecord(
                    input: OracleInput(mode: .chat, userMessage: "Foreign in-flight turn"),
                    state: .prepared, startedAt: max(Date(), settled.updatedAt)
                )
                let prepared = try OracleGroupDocument(
                    schemaVersion: settled.schemaVersion, group: settled.group, owner: settled.owner, name: settled.name,
                    revision: settled.revision &+ 1, createdAt: settled.createdAt, updatedAt: foreignTurn.startedAt,
                    roster: settled.roster, members: settled.members, turns: settled.turns + [foreignTurn]
                )
                let liveClaim = try await AppDomainRuntimeComposition.shared.oracleGroupClaimManager.acquire(
                    group: settled, owner: settled.owner, invocationID: UUID(), runID: UUID()
                )
                defer { liveClaim.release() }
                try await AppDomainRuntimeComposition.shared.oracleConversationStore.save(prepared, expectedRevision: settled.revision)
                let targetMessages = try await self.persistedMessageCount(ctx, target.id)
                for entry in Harness.EntryPath.allCases {
                    try await self.assertLaneBusy(ctx, chatID: target.shortID, groupID: groupID, via: entry)
                }
                XCTAssertEqual(ctx.provider.sendCount, 4)
                XCTAssertFalse(ctx.oracle.isSessionStreaming(target.id))
                let rejectedMessages = try await self.persistedMessageCount(ctx, target.id)
                XCTAssertEqual(rejectedMessages, targetMessages, "Rejected before any session mutation")
                let afterPrepared = try await ctx.loadGroup(groupID)
                XCTAssertEqual(afterPrepared.revision, prepared.revision)
                XCTAssertEqual(afterPrepared.turns.map(\.id), prepared.turns.map(\.id))
                XCTAssertEqual(afterPrepared.turns.last?.state, .prepared)
            }
        }

        func testExplicitMemberContinuationRecoversCrashStalePreparedTurnWithoutSendingSiblings() async throws {
            for entry in Harness.EntryPath.allCases {
                try await Harness.withControlledFixture(additionalModels: [.gpt54]) { ctx in
                    let (groupID, lanes) = try await self.createGroup(ctx)
                    let target = lanes[1]
                    let sibling = lanes[0]
                    let settled = try await ctx.loadGroup(groupID)
                    let staleTurn = try OracleTurnRecord(
                        input: OracleInput(mode: .chat, userMessage: "Crash-interrupted group turn"),
                        state: .prepared, startedAt: max(Date(), settled.updatedAt)
                    )
                    let prepared = try OracleGroupDocument(
                        schemaVersion: settled.schemaVersion, group: settled.group, owner: settled.owner, name: settled.name,
                        revision: settled.revision &+ 1, createdAt: settled.createdAt, updatedAt: staleTurn.startedAt,
                        roster: settled.roster, members: settled.members, turns: settled.turns + [staleTurn]
                    )
                    try await AppDomainRuntimeComposition.shared.oracleConversationStore.save(prepared, expectedRevision: settled.revision)
                    XCTAssertFalse(ctx.oracle.isSessionStreaming(target.id))
                    let targetMessages = try await self.persistedMessageCount(ctx, target.id)
                    let siblingMessages = try await self.persistedMessageCount(ctx, sibling.id)

                    let reply = try await self.continueLane(ctx, chatID: target.shortID, via: entry, message: "Continue after crash")
                    self.assertCompletedLaneReply(reply, chatID: target.shortID, via: entry)
                    XCTAssertEqual(ctx.provider.sendCount, 3, "Exactly one lane continuation send")
                    let targetAfter = try await self.persistedMessageCount(ctx, target.id)
                    let siblingAfter = try await self.persistedMessageCount(ctx, sibling.id)
                    XCTAssertEqual(targetAfter, targetMessages + 2)
                    XCTAssertEqual(siblingAfter, siblingMessages, "The sibling receives no new send")
                    let recovered = try await ctx.loadGroup(groupID)
                    XCTAssertEqual(recovered.revision, prepared.revision + 1)
                    XCTAssertEqual(recovered.turns.map(\.id), prepared.turns.map(\.id))
                    XCTAssertEqual(Array(recovered.turns.dropLast()), settled.turns)
                    XCTAssertEqual(recovered.turns.last?.state, .terminal)
                    XCTAssertEqual(recovered.turns.last?.results.map(\.status), [.failed, .failed])
                    XCTAssertEqual(recovered.turns.last?.results.map(\.error?.code), ["interrupted", "interrupted"])
                }
            }
        }

        /// The reverse direction: a lane-only continuation owns the shared claim until its producer
        /// drains, so a whole-group turn cannot start beside it. Same case for both entry paths.
        func testExplicitLaneContinuationExcludesWholeGroupTurnUntilItsProducerDrains() async throws {
            try await Harness.withControlledFixture(additionalModels: [.gpt54]) { ctx in
                let (groupID, lanes) = try await self.createGroup(ctx)
                var sends = 2
                for entry in Harness.EntryPath.allCases {
                    let laneMessages = try await self.persistedMessageCount(ctx, lanes[0].id)
                    let siblingMessages = try await self.persistedMessageCount(ctx, lanes[1].id)
                    let before = try await ctx.loadGroup(groupID)
                    ctx.provider.behavior = { _ in .hold }
                    let held = try await self.startHeldLaneContinuation(ctx, chatID: lanes[0].shortID, via: entry)
                    try await ctx.awaitSends(sends + 1)
                    sends += 1
                    XCTAssertTrue(ctx.oracle.isSessionStreaming(lanes[0].id))

                    await self.assertGroupClaimConflict(groupID: groupID) { try await self.continueGroup(ctx, message: "Whole group beside \(entry) lane") }
                    XCTAssertEqual(ctx.provider.sendCount, sends, "\(entry): no group lane started")
                    XCTAssertTrue(ctx.oracle.isSessionStreaming(lanes[0].id), "\(entry): lane producer remains alive")
                    XCTAssertFalse(ctx.oracle.isSessionStreaming(lanes[1].id))

                    ctx.provider.releaseHeld()
                    let reply = try await held.settle()
                    self.assertCompletedLaneReply(reply, chatID: lanes[0].shortID, via: entry)
                    XCTAssertEqual(ctx.provider.sendCount, sends, "\(entry): exactly the addressed lane sent once")
                    let laneAfter = try await self.persistedMessageCount(ctx, lanes[0].id)
                    let siblingAfter = try await self.persistedMessageCount(ctx, lanes[1].id)
                    let after = try await ctx.loadGroup(groupID)
                    XCTAssertEqual(laneAfter, laneMessages + 2, "\(entry)")
                    XCTAssertEqual(siblingAfter, siblingMessages, "\(entry): sibling unchanged")
                    XCTAssertEqual(after.turns, before.turns, "\(entry): historical group turns unchanged")
                }

                // Both lane continuations released the claim after draining.
                ctx.provider.behavior = { _ in .complete }
                let turnsBefore = try await ctx.loadGroup(groupID).turns.count
                let group = try await self.continueGroup(ctx, message: "Whole group after lanes")
                XCTAssertEqual(group.objectValue?["oracle_group_id"]?.stringValue, groupID)
                XCTAssertEqual(group.objectValue?["oracle_count"]?.intValue, 2)
                XCTAssertEqual(ctx.provider.sendCount, sends + 2)
                let turnsAfter = try await ctx.loadGroup(groupID).turns.count
                XCTAssertEqual(turnsAfter, turnsBefore + 1)
            }
        }

        // MARK: - F2: in-app stop of an owned send

        func testInAppStopOfExplicitLaneContinuationIsCancellationAndReleasesClaim() async throws {
            try await Harness.withControlledFixture(additionalModels: [.gpt54]) { ctx in
                let (groupID, lanes) = try await self.createGroup(ctx)
                var sends = 2
                for entry in Harness.EntryPath.allCases {
                    ctx.provider.behavior = { _ in .hold }
                    let held = try await self.startHeldLaneContinuation(ctx, chatID: lanes[0].shortID, via: entry)
                    try await ctx.awaitSends(sends + 1)
                    sends += 1

                    // UI Stop: the exact scoped query, not the ticket worker's parent task.
                    await ctx.oracle.cancelAIResponse(in: lanes[0].id)
                    XCTAssertFalse(ctx.oracle.isSessionStreaming(lanes[0].id), "\(entry): producer drained by the stop")
                    switch entry {
                    case .blocking:
                        do {
                            _ = try await held.settle()
                            XCTFail("A stopped blocking continuation must not return a reply")
                        } catch is CancellationError {
                        } catch {
                            XCTFail("Expected CancellationError, got \(error)")
                        }
                    case .ticket:
                        let terminal = try await held.settle()
                        XCTAssertEqual(self.job(terminal)?["status"]?.stringValue, "cancelled")
                        XCTAssertEqual(self.job(terminal)?["chat_id"]?.stringValue, lanes[0].shortID)
                    }

                    // Cleanup released the claim: a whole-group retry now succeeds.
                    ctx.provider.behavior = { _ in .complete }
                    let group = try await self.continueGroup(ctx, message: "Group after \(entry) stop")
                    XCTAssertEqual(group.objectValue?["oracle_group_id"]?.stringValue, groupID)
                    XCTAssertEqual(group.objectValue?["oracle_count"]?.intValue, 2)
                    sends += 2
                    XCTAssertEqual(ctx.provider.sendCount, sends)
                }
            }
        }

        func testInAppStopOfTicketedSingletonEndsCancelledKeepsRecoveryAndDoesNotResend() async throws {
            try await Harness.withControlledFixture(additionalModels: []) { ctx in
                var sends = 0
                for tool in ["ask_oracle", "oracle_send"] {
                    ctx.provider.behavior = { _ in .hold }
                    let start = try await Harness.execute(tool, args: [
                        "op": .string("start"), "detach": .bool(true), "new_chat": .bool(true), "message": .string("Stop me")
                    ], service: ctx.service, invocation: ctx.invocation)
                    let jobID = try XCTUnwrap(start.objectValue?["job_id"]?.stringValue)
                    try await ctx.awaitSends(sends + 1)
                    sends += 1
                    let running = try await Harness.execute(tool, args: ["op": .string("poll"), "job_id": .string(jobID)], service: ctx.service, invocation: ctx.invocation)
                    XCTAssertEqual(self.job(running)?["status"]?.stringValue, "running", tool)
                    let chatID = try XCTUnwrap(self.job(running)?["chat_id"]?.stringValue, "\(tool): recovery chat_id is published before the send")
                    let session = try XCTUnwrap(ctx.oracle.resolveSession(id: chatID))
                    XCTAssertTrue(ctx.oracle.isSessionStreaming(session.id))

                    await ctx.oracle.cancelAIResponse(in: session.id)
                    XCTAssertFalse(ctx.oracle.isSessionStreaming(session.id), "\(tool): producer drained before terminal observation")

                    let terminal = try await Harness.execute(tool, args: ["op": .string("wait"), "job_id": .string(jobID), "timeout": .int(5)], service: ctx.service, invocation: ctx.invocation)
                    XCTAssertEqual(self.job(terminal)?["status"]?.stringValue, "cancelled", tool)
                    XCTAssertEqual(self.job(terminal)?["chat_id"]?.stringValue, chatID, tool)
                    let errorMessage = self.job(terminal)?["error"]?.objectValue?["message"]?.stringValue ?? ""
                    XCTAssertFalse(errorMessage.contains("OracleLaneCancellation"), errorMessage)
                    for _ in 0 ..< 2 {
                        let poll = try await Harness.execute(tool, args: ["op": .string("poll"), "job_id": .string(jobID)], service: ctx.service, invocation: ctx.invocation)
                        XCTAssertEqual(self.job(poll)?["status"]?.stringValue, "cancelled", tool)
                    }
                    XCTAssertEqual(ctx.provider.sendCount, sends, "\(tool): polling a cancelled ticket never resends")
                    let log = try await ctx.oracle.tool_chatGetLog(args: ["chat_id": .string(chatID)])
                    XCTAssertEqual(log["chat_id"]?.stringValue, chatID, tool)

                    // A genuine provider failure is still a failed job, not a cancellation.
                    ctx.provider.behavior = { _ in .fail }
                    let failing = try await Harness.execute(tool, args: [
                        "op": .string("start"), "detach": .bool(true), "new_chat": .bool(true), "message": .string("Fail me")
                    ], service: ctx.service, invocation: ctx.invocation)
                    let failingID = try XCTUnwrap(failing.objectValue?["job_id"]?.stringValue)
                    let failed = try await Harness.execute(tool, args: ["op": .string("wait"), "job_id": .string(failingID), "timeout": .int(5)], service: ctx.service, invocation: ctx.invocation)
                    sends += 1
                    XCTAssertEqual(self.job(failed)?["status"]?.stringValue, "failed", tool)
                    XCTAssertNotNil(self.job(failed)?["chat_id"]?.stringValue, tool)
                    XCTAssertEqual(ctx.provider.sendCount, sends)
                }
            }
        }

        // MARK: - Helpers

        /// A held lane continuation started through one entry path; `settle()` returns its reply
        /// (blocking) or terminal ticket snapshot (ticket).
        private struct HeldContinuation {
            let settle: () async throws -> Value
        }

        private func createGroup(_ ctx: Harness.Context) async throws -> (groupID: String, lanes: [ChatSession]) {
            ctx.provider.behavior = { _ in .complete }
            let initial = try await ctx.service.executeOracleSend(
                args: ["message": .string("Create group"), "new_chat": .bool(true)], invocationContext: ctx.invocation
            )
            let groupID = try XCTUnwrap(initial.objectValue?["oracle_group_id"]?.stringValue)
            await ctx.oracle.drainTrackedAutosaves(for: ctx.driver.fixture.workspace.id)
            let lanes = ctx.lanes(ofGroup: groupID)
            XCTAssertEqual(lanes.map(\.oracleLaneIndex), [0, 1])
            XCTAssertEqual(ctx.provider.sendCount, 2)
            // Implicit continuation resumes the whole group through this selection.
            ctx.driver.manager.setActiveChatSessionID(lanes[0].id, forTabID: ctx.driver.tabID)
            return (groupID, lanes)
        }

        private func continueGroup(_ ctx: Harness.Context, message: String) async throws -> Value {
            try await ctx.service.executeOracleSend(args: ["message": .string(message)], invocationContext: ctx.invocation)
        }

        /// Blocking returns the reply; ticket uses a non-detached start that returns the terminal snapshot.
        private func continueLane(_ ctx: Harness.Context, chatID: String, via entry: Harness.EntryPath, message: String) async throws -> Value {
            var args: [String: Value] = ["message": .string(message), "chat_id": .string(chatID)]
            if entry == .ticket {
                args["op"] = .string("start")
                args["timeout"] = .int(5)
            }
            return try await ctx.service.executeOracleSend(args: args, invocationContext: ctx.invocation)
        }

        private func askOracleLane(_ ctx: Harness.Context, chatID: String, message: String) async throws -> Value {
            try await ctx.service.executeAskOracle(
                args: ["message": .string(message), "chat_id": .string(chatID)], invocationContext: ctx.invocation
            )
        }

        private func startHeldLaneContinuation(_ ctx: Harness.Context, chatID: String, via entry: Harness.EntryPath) async throws -> HeldContinuation {
            let message = "Held \(entry) lane"
            switch entry {
            case .blocking:
                let task = Task { try await self.continueLane(ctx, chatID: chatID, via: .blocking, message: message) }
                return HeldContinuation { try await task.value }
            case .ticket:
                let start = try await ctx.service.executeOracleSend(args: [
                    "op": .string("start"), "detach": .bool(true), "message": .string(message), "chat_id": .string(chatID)
                ], invocationContext: ctx.invocation)
                let jobID = try XCTUnwrap(start.objectValue?["job_id"]?.stringValue)
                return HeldContinuation {
                    try await ctx.service.executeOracleSend(
                        args: ["op": .string("wait"), "job_id": .string(jobID), "timeout": .int(5)], invocationContext: ctx.invocation
                    )
                }
            }
        }

        private func assertLaneBusy(
            _ ctx: Harness.Context, chatID: String, groupID: String, via entry: Harness.EntryPath,
            file: StaticString = #filePath, line: UInt = #line
        ) async throws {
            switch entry {
            case .blocking:
                do {
                    _ = try await continueLane(ctx, chatID: chatID, via: .blocking, message: "Rejected lane")
                    XCTFail("Explicit member continuation must conflict", file: file, line: line)
                } catch let error as ChatToolError {
                    XCTAssertEqual(error.code, .conflict, file: file, line: line)
                    XCTAssertEqual(error.message, Self.laneBusyMessage, file: file, line: line)
                    XCTAssertEqual(error.details?["oracle_group_id"], groupID, file: file, line: line)
                } catch {
                    XCTFail("Expected lane conflict, got \(error)", file: file, line: line)
                }
            case .ticket:
                let terminal = try await continueLane(ctx, chatID: chatID, via: .ticket, message: "Rejected lane")
                XCTAssertEqual(job(terminal)?["status"]?.stringValue, "failed", file: file, line: line)
                XCTAssertEqual(job(terminal)?["error"]?.objectValue?["message"]?.stringValue, Self.laneBusyMessage, file: file, line: line)
                XCTAssertNil(job(terminal)?["chat_id"], "Rejected before the send published recovery", file: file, line: line)
            }
        }

        /// The whole-group runtime surfaces the shared claim's conflict.
        private func assertGroupClaimConflict(
            groupID: String,
            file: StaticString = #filePath, line: UInt = #line,
            _ operation: () async throws -> Value
        ) async {
            do {
                _ = try await operation()
                XCTFail("Whole-group turn must not start while a lane owns the claim", file: file, line: line)
            } catch let error as ChatToolError {
                XCTAssertEqual(error.code, .conflict, file: file, line: line)
                XCTAssertEqual(error.message, Self.laneBusyMessage, file: file, line: line)
                XCTAssertEqual(error.details?["oracle_group_id"], groupID, file: file, line: line)
            } catch {
                XCTFail("Expected mapped Oracle lane busy conflict, got \(error)", file: file, line: line)
            }
        }

        private func assertCompletedLaneReply(_ reply: Value, chatID: String, via entry: Harness.EntryPath, file: StaticString = #filePath, line: UInt = #line) {
            if entry == .ticket {
                XCTAssertEqual(job(reply)?["status"]?.stringValue, "completed", file: file, line: line)
            }
            XCTAssertEqual(reply.objectValue?["chat_id"]?.stringValue, chatID, file: file, line: line)
            XCTAssertNil(reply.objectValue?["oracle_group_id"], "A lane continuation never fans out", file: file, line: line)
            XCTAssertTrue(reply.objectValue?["response"]?.stringValue?.contains(ControlledOracleProvider.completedText) == true, file: file, line: line)
        }

        private func persistedMessageCount(_ ctx: Harness.Context, _ sessionID: UUID) async throws -> Int {
            await ctx.oracle.drainTrackedAutosaves(for: ctx.driver.fixture.workspace.id)
            let session = try XCTUnwrap(ctx.oracle.sessions.first { $0.id == sessionID })
            return try await ctx.oracle.chatData.loadChatSession(from: XCTUnwrap(session.fileURL)).messages.count
        }

        private func job(_ value: Value) -> [String: Value]? {
            value.objectValue?["job"]?.objectValue
        }
    }
#endif

#if DEBUG
    @MainActor
    final class OracleGroupBoundaryTests: XCTestCase {
        func testRequestDiagnosticsReachBothOracleAdaptersWithoutForwardingPublicKnobs() async throws {
            for ask in [false, true] {
                for ticket in [false, true] {
                    for control in [["debug_primary_only": Value.bool(true)], ["debug_lane_timeout_seconds": Value.double(1.5)]] {
                        var captured: OracleViewModel.OracleRequestDiagnostics?
                        let fixture = makeOracleSendFixture(stopAfterRoute: false, connectionID: UUID(), sendOperation: { args, _, context in
                            captured = context?.requestDiagnostics
                            XCTAssertNil(args["debug_primary_only"])
                            XCTAssertNil(args["debug_lane_timeout_seconds"])
                            return ["response": .string("retained"), "chat_id": .string("fixture")]
                        })
                        defer { fixture.cleanup() }
                        var args = control
                        args["message"] = .string("fixture")
                        args["new_chat"] = .bool(true)
                        if ticket { args["op"] = .string("start")
                            args["timeout"] = .int(5)
                        }
                        let result = try await (
                            ask
                                ? fixture.service.executeAskOracle(args: args, invocationContext: fixture.invocationContext)
                                : fixture.service.executeOracleSend(args: args, invocationContext: fixture.invocationContext)
                        )
                        XCTAssertEqual(result.objectValue?["response"], .string("retained"))
                        XCTAssertEqual(captured, try OracleViewModel.OracleRequestDiagnostics.parse(args))
                        XCTAssertEqual(fixture.sendRecorder.calls.count, 1)
                    }
                }
            }
        }

        func testInvalidRequestDiagnosticsRejectBeforeJobAdmissionOrSend() async throws {
            let invalid: [[String: Value]] = [
                ["debug_primary_only": .bool(true)],
                ["debug_primary_only": .bool(true), "chat_id": .string("old"), "new_chat": .bool(true)],
                ["debug_primary_only": .string("true"), "new_chat": .bool(true)],
                ["debug_lane_timeout_seconds": .double(.infinity), "new_chat": .bool(true)],
                ["debug_lane_timeout_seconds": .double(.nan), "new_chat": .bool(true)],
                ["debug_lane_timeout_seconds": .int(0), "new_chat": .bool(true)],
                ["debug_lane_timeout_seconds": .int(301), "new_chat": .bool(true)],
                ["debug_lane_timeout_seconds": .string("30"), "new_chat": .bool(true)],
                ["debug_primary_only": .bool(true), "debug_lane_timeout_seconds": .int(30), "new_chat": .bool(true)]
            ]
            for ask in [false, true] {
                for ticket in [false, true] {
                    for control in invalid {
                        let fixture = makeOracleSendFixture(stopAfterRoute: false, connectionID: UUID())
                        defer { fixture.cleanup() }
                        var args = control
                        args["message"] = .string("must not launch")
                        if ticket { args["op"] = .string("start")
                            args["detach"] = .bool(true)
                        }
                        do {
                            _ = try await (
                                ask
                                    ? fixture.service.executeAskOracle(args: args, invocationContext: fixture.invocationContext)
                                    : fixture.service.executeOracleSend(args: args, invocationContext: fixture.invocationContext)
                            )
                            XCTFail("Invalid diagnostics admitted: \(args)")
                        } catch let MCPError.invalidParams(rawDetail) {
                            let detail = try XCTUnwrap(rawDetail)
                            XCTAssertTrue(detail.contains("Oracle diagnostics") || detail.contains("debug_primary_only") || detail.contains("debug_lane_timeout_seconds"), detail)
                        } catch { XCTFail("Reached later work: \(error)") }
                        XCTAssertEqual(fixture.sendRecorder.calls.count, 0)
                        XCTAssertEqual(fixture.rebindRecorder.count, 0)
                    }
                }
            }
        }

        func testOracleSendStartWithChatIDDoesNotRebind() async {
            let fixture = makeOracleSendFixture()
            defer { fixture.cleanup() }

            await assertStopsAfterRoute(
                fixture,
                args: [
                    "message": .string("start fresh"),
                    "chat_id": .string("existing-chat"),
                    "new_chat": .bool(true)
                ]
            )
            XCTAssertEqual(fixture.rebindRecorder.count, 0)
        }

        func testOracleSendInvalidContinuationModelDoesNotRebind() async throws {
            let fixture = makeOracleSendFixture()
            defer { fixture.cleanup() }

            do {
                _ = try await fixture.service.executeOracleSend(args: [
                    "message": .string("continue"),
                    "chat_id": .string("existing-chat"),
                    "model": .string("override-model")
                ], invocationContext: fixture.invocationContext)
                XCTFail("Expected invalid continuation route")
            } catch OracleBoundaryTestStop.afterRoute {
                XCTFail("Invalid route reached tab resolution")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("model"), error.localizedDescription)
            }
            XCTAssertEqual(fixture.rebindRecorder.count, 0)
        }

        func testStartRejectsInvalidRouteAsInvalidParamsWithoutAdmittingTicket() async throws {
            let start: [String: Value] = ["op": .string("start"), "detach": .bool(true), "message": .string("continue"), "model": .string("override-model")]
            var explicit = start
            explicit["chat_id"] = .string("existing-chat")
            // ask_oracle starts fresh without a chat_id, so only oracle_send has an implicit continuation.
            let cases: [(tool: String, args: [String: Value])] = [
                ("ask_oracle", explicit), ("oracle_send", explicit), ("oracle_send", start)
            ]
            for (tool, args) in cases {
                let fixture = makeOracleSendFixture(stopAfterRoute: false, connectionID: UUID())
                defer { fixture.cleanup() }
                fixture.service.jobCenter.admissionDidRegister = { _ in XCTFail("Invalid route admitted a ticket") }
                do {
                    _ = try await executeOracleTool(tool, args: args, fixture: fixture)
                    XCTFail("Expected invalid route (\(tool), chat_id: \(args["chat_id"] != nil))")
                } catch let MCPError.invalidParams(rawDetail) {
                    XCTAssertEqual(rawDetail, OracleGroupContractError.modelOverrideOnContinuation.localizedDescription, tool)
                } catch {
                    XCTFail("Route error must be invalidParams, got \(error) (\(tool))")
                }
                XCTAssertEqual(fixture.sendRecorder.calls.count, 0, tool)
                XCTAssertEqual(fixture.rebindRecorder.count, 0, tool)
            }
        }

        func testOracleSendValidContinuationRebindsOnce() async {
            let fixture = makeOracleSendFixture()
            defer { fixture.cleanup() }

            await assertStopsAfterRoute(
                fixture,
                args: [
                    "message": .string("continue"),
                    "chat_id": .string("  existing-chat  ")
                ]
            )
            XCTAssertEqual(fixture.rebindRecorder.chatIDs, ["existing-chat"])
        }

        func testOracleSendMessageOnlyUsesImplicitSelectionWithoutRebind() async {
            let fixture = makeOracleSendFixture()
            defer { fixture.cleanup() }

            await assertStopsAfterRoute(
                fixture,
                args: ["message": .string("continue selected")]
            )
            XCTAssertEqual(fixture.rebindRecorder.count, 0)
        }

        func testOracleSendMessageOnlyRejectsModelBeforeTabResolution() async {
            let fixture = makeOracleSendFixture()
            defer { fixture.cleanup() }

            do {
                _ = try await fixture.service.executeOracleSend(args: [
                    "message": .string("continue selected"),
                    "model": .string("override-model")
                ], invocationContext: fixture.invocationContext)
                XCTFail("Expected implicit continuation model rejection")
            } catch OracleBoundaryTestStop.afterRoute {
                XCTFail("Invalid route reached tab resolution")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("model"), error.localizedDescription)
            }
            XCTAssertEqual(fixture.rebindRecorder.count, 0)
        }

        func testOracleSendExplicitStartAllowsModelWithoutRebind() async {
            let fixture = makeOracleSendFixture()
            defer { fixture.cleanup() }

            await assertStopsAfterRoute(
                fixture,
                args: [
                    "message": .string("start"),
                    "new_chat": .bool(true),
                    "model": .string("override-model")
                ]
            )
            XCTAssertEqual(fixture.rebindRecorder.count, 0)
        }

        func testOracleSendMessageOnlyForwardingDoesNotSynthesizeStartArguments() async throws {
            let fixture = makeOracleSendFixture(stopAfterRoute: false)
            defer { fixture.cleanup() }

            _ = try await fixture.service.executeOracleSend(args: [
                "message": .string("continue selected")
            ], invocationContext: fixture.invocationContext)

            XCTAssertEqual(fixture.sendRecorder.calls.count, 1)
            XCTAssertEqual(fixture.sendRecorder.calls[0]["message"], .string("continue selected"))
            XCTAssertNil(fixture.sendRecorder.calls[0]["chat_id"])
            XCTAssertNil(fixture.sendRecorder.calls[0]["new_chat"])
            XCTAssertNil(fixture.sendRecorder.calls[0]["model"])
            XCTAssertEqual(fixture.rebindRecorder.count, 0)
        }

        func testAskOracleDisconnectReconnectCompletesSamePipelineExactlyOnce() async throws {
            let availability = OracleConnectionAvailability()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-ticket-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let gate = AsyncStream<Void>.makeStream()
            var exports = 0
            let fixture = makeOracleSendFixture(stopAfterRoute: false, connectionID: UUID(), exportOperation: { _ in
                exports += 1
                return OracleExportFile(path: "/tmp/ask-ticket-fixture.md", instruction: "read fixture")
            }, sendOperation: { _, _, context in
                XCTAssertNotNil(context?.jobProgress)
                for await _ in gate.stream {
                    break
                }
                return ["chat_id": .string("fixture-chat"), "response": .string("  retained answer\n")]
            }, contextAvailable: { availability.connected })
            defer { fixture.cleanup() }
            await fixture.window.workspaceManager.awaitInitialized()
            let workspace = try WorkspaceModel(id: XCTUnwrap(fixture.context.workspaceID), name: "Ask ticket fixture", repoPaths: [root.path], ephemeralFlag: true)
            fixture.window.workspaceManager.workspaces = [workspace]
            fixture.window.workspaceManager.activeWorkspace = workspace
            let start = try await fixture.service.executeAskOracle(args: ["op": .string("start"), "detach": .bool(true), "message": .string("fixture"), "export_response": .bool(true)], invocationContext: fixture.invocationContext)
            let id = try XCTUnwrap(start.objectValue?["job_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
            availability.connected = false
            let observer = Task { await fixture.service.jobCenter.store.wait(id: id, timeout: 60) }
            observer.cancel()
            _ = await observer.value
            let running = await fixture.service.jobCenter.store.wait(id: id, timeout: 0)
            XCTAssertEqual(running?.status, .running)
            gate.continuation.yield(())
            gate.continuation.finish()
            let terminal = await fixture.service.jobCenter.store.wait(id: id, timeout: 5)
            XCTAssertEqual(terminal?.status, .completed)
            availability.connected = true
            for op in ["poll", "wait", "cancel"] {
                let result = try await fixture.service.executeAskOracle(args: ["op": .string(op), "job_id": .string(id.uuidString)], invocationContext: fixture.invocationContext)
                XCTAssertEqual(result.objectValue?["response"], .string("  retained answer\n"))
                XCTAssertEqual(result.objectValue?["oracle_export_path"], .string("/tmp/ask-ticket-fixture.md"))
            }
            XCTAssertEqual(fixture.sendRecorder.calls.count, 1)
            XCTAssertEqual(exports, 1)
            XCTAssertEqual(fixture.sendRecorder.calls.first?["new_chat"], .bool(true))
            XCTAssertNil(fixture.sendRecorder.calls.first?["op"])
        }

        func testAskOracleTicketCancellationSkipsExportAndRetainsCanonicalGroup() async throws {
            let group = try OracleGroupResult(groupID: OracleGroupID(rawValue: UUID()), status: .partialFailure, oracleResults: [
                OracleLaneResult(laneIndex: 0, chatID: "done", providerID: nil, modelID: "m", status: .completed, response: "retained"),
                OracleLaneResult(laneIndex: 1, chatID: "cancelled", providerID: nil, modelID: "n", status: .cancelled, error: OracleLaneError(code: "cancelled", message: "Cancelled", partialResponse: "partial"))
            ])
            let payload = ContextBuilderOracleGroupReply(result: group).toMCPFields()
            let entered = expectation(description: "ticket send entered")
            let gate = AsyncStream<Void>.makeStream()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-cancel-export-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = makeOracleSendFixture(stopAfterRoute: false, connectionID: UUID(), exportOperation: { _ in
                XCTFail("Cancelled ticket must not start export")
                throw CancellationError()
            }, sendOperation: { _, _, _ in
                entered.fulfill()
                for await _ in gate.stream {}
                return payload
            })
            defer { fixture.cleanup()
                gate.continuation.finish()
            }
            await fixture.window.workspaceManager.awaitInitialized()
            let workspace = try WorkspaceModel(id: XCTUnwrap(fixture.context.workspaceID), name: "Ask cancellation export", repoPaths: [root.path], ephemeralFlag: true)
            fixture.window.workspaceManager.workspaces = [workspace]
            fixture.window.workspaceManager.activeWorkspace = workspace
            let start = try await fixture.service.executeAskOracle(args: ["op": .string("start"), "detach": .bool(true), "message": .string("fixture"), "export_response": .bool(true)], invocationContext: fixture.invocationContext)
            let id = try XCTUnwrap(start.objectValue?["job_id"]?.stringValue)
            await fulfillment(of: [entered], timeout: 2)
            _ = try await fixture.service.executeAskOracle(args: ["op": .string("cancel"), "job_id": .string(id)], invocationContext: fixture.invocationContext)
            let result = try await fixture.service.executeAskOracle(args: ["op": .string("wait"), "job_id": .string(id), "timeout": .int(5)], invocationContext: fixture.invocationContext)
            XCTAssertEqual(result.objectValue?["job"]?.objectValue?["status"], .string("cancelled"))
            XCTAssertEqual(result.objectValue?["oracle_results"], payload["oracle_results"])
            XCTAssertNotNil(result.objectValue?["oracle_export_error"])
            XCTAssertNil(result.objectValue?["oracle_export_path"])
            XCTAssertEqual(fixture.sendRecorder.calls.count, 1)
        }

        func testAskOracleLegacyPayloadAndTicketPartialFailureAreIdentical() async throws {
            let group = try OracleGroupResult(groupID: OracleGroupID(rawValue: UUID()), status: .partialFailure, oracleResults: [
                OracleLaneResult(laneIndex: 0, chatID: "a", providerID: nil, modelID: "m", status: .completed, response: "answer"),
                OracleLaneResult(laneIndex: 1, chatID: "b", providerID: nil, modelID: "n", status: .failed, error: OracleLaneError(code: "provider_failed", message: "failed", partialResponse: "partial"))
            ])
            let payload = ContextBuilderOracleGroupReply(result: group).toMCPFields()
            let fixture = makeOracleSendFixture(stopAfterRoute: false, connectionID: UUID(), settledReply: payload)
            defer { fixture.cleanup() }
            let args: [String: Value] = ["message": .string("fixture")]
            let legacy = try await fixture.service.executeAskOracle(args: args, invocationContext: fixture.invocationContext)
            XCTAssertEqual(legacy, .object(payload))
            var startArgs = args
            startArgs["op"] = .string("start")
            startArgs["timeout"] = .int(5)
            let terminal = try await fixture.service.executeAskOracle(args: startArgs, invocationContext: fixture.invocationContext)
            var fields = try XCTUnwrap(terminal.objectValue)
            fields.removeValue(forKey: "job")
            fields.removeValue(forKey: "job_id")
            XCTAssertEqual(fields, payload)
            XCTAssertEqual(fixture.sendRecorder.calls[0], fixture.sendRecorder.calls[1])
            let legacyBlocks = ToolOutputFormatter.formatAskOracle(args: args, value: legacy, emitResources: false)
            let jobBlocks = ToolOutputFormatter.formatAskOracle(args: args, value: terminal, emitResources: false)
            XCTAssertEqual(String(describing: legacyBlocks), String(describing: jobBlocks))
        }

        func testAskOracleLegacyCancellationCancelsSendButTicketObserverDoesNot() async throws {
            let entered = expectation(description: "legacy send entered")
            let fixture = makeOracleSendFixture(stopAfterRoute: false, connectionID: UUID(), sendOperation: { _, _, _ in
                entered.fulfill()
                try await Task.sleep(for: .seconds(60))
                return [:]
            })
            defer { fixture.cleanup() }
            let request = Task { try await fixture.service.executeAskOracle(args: ["message": .string("fixture")], invocationContext: fixture.invocationContext) }
            await fulfillment(of: [entered], timeout: 2)
            request.cancel()
            do { _ = try await request.value
                XCTFail("Legacy send must cancel")
            } catch is CancellationError {}
            XCTAssertEqual(fixture.sendRecorder.calls.count, 1)
        }

        func testAskOracleControlsRejectWrongToolAndOriginWithoutSending() async throws {
            let fixture = makeOracleSendFixture(stopAfterRoute: false, connectionID: UUID())
            defer { fixture.cleanup() }
            for tool in ["oracle_send", "ask_oracle"] {
                let id = UUID()
                let owner = DomainLongRunningJobStore.Owner(windowID: fixture.window.windowID, workspaceID: fixture.context.workspaceID, tabID: fixture.context.tabID, sessionID: UUID(), runID: UUID())
                _ = try await fixture.service.jobCenter.store.register(id: id, tool: tool, owner: owner)
                for op in ["poll", "wait", "cancel"] {
                    do {
                        _ = try await fixture.service.executeAskOracle(args: ["op": .string(op), "job_id": .string(id.uuidString)], invocationContext: fixture.invocationContext)
                        XCTFail("Wrong tool/origin must be rejected")
                    } catch { XCTAssertTrue(error.localizedDescription.contains(tool == "ask_oracle" ? "different Agent session/run" : "different tool")) }
                }
                await fixture.service.jobCenter.store.finish(id: id, error: "fixture complete")
            }
            XCTAssertTrue(fixture.sendRecorder.calls.isEmpty)
        }

        func testTicketCancellationDuringAdmissionNeverExecutesBody() async throws {
            for cancelByOwner in [false, true] {
                let center = MCPLongRunningJobCenter()
                let owner = DomainLongRunningJobStore.Owner(windowID: 1, workspaceID: UUID(), tabID: UUID(), sessionID: nil, runID: nil)
                let admitted = expectation(description: "ticket registered before worker installation")
                let gate = AsyncStream<Void>.makeStream()
                var ticketID: UUID?
                var executed = false
                center.admissionDidRegister = { id in
                    ticketID = id
                    admitted.fulfill()
                    for await _ in gate.stream {
                        break
                    }
                }
                let start = Task {
                    try await center.start(tool: "oracle_send", owner: owner) { _ in
                        executed = true
                        return .object(["response": .string("must not run")])
                    }
                }
                await fulfillment(of: [admitted], timeout: 2)
                let id = try XCTUnwrap(ticketID)
                if cancelByOwner {
                    center.cancel { $0 == owner }
                } else {
                    let acknowledgement = try await center.control(operation: .cancel(id), tool: "oracle_send", authorize: { _ in })
                    XCTAssertEqual(acknowledgement.objectValue?["job"]?.objectValue?["status"], .string("cancelling"))
                }
                gate.continuation.yield(())
                gate.continuation.finish()
                _ = try await start.value
                let terminal = await center.store.wait(id: id, timeout: 5)
                XCTAssertEqual(terminal?.status, .cancelled)
                XCTAssertFalse(executed)
                // Admission cancellation must release the context's busy slot.
                try await center.store.checkAdmission(owner: owner)
            }
        }

        func testOracleSendPreparesInputsBeforeTicketAdmission() async throws {
            var prepared = false
            var preparations = 0
            var exported = false
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("frozen-export-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = makeOracleSendFixture(stopAfterRoute: false, exportOperation: { request in
                XCTAssertEqual(request.destination?.primaryRootPath, root.path)
                exported = true
                return OracleExportFile(path: "/tmp/frozen-export.md", instruction: "read fixture")
            }, sendOperation: { _, _, context in
                XCTAssertTrue(prepared)
                XCTAssertEqual(preparations, 1)
                XCTAssertNotNil(context?.jobProgress)
                return ["chat_id": .string("frozen-chat"), "response": .string("answer")]
            }, stabilizeContext: { context in
                preparations += 1
                prepared = true
                return context
            })
            defer {
                fixture.service.jobCenter.admissionDidRegister = nil
                fixture.cleanup()
            }
            await fixture.window.workspaceManager.awaitInitialized()
            let workspace = try WorkspaceModel(id: XCTUnwrap(fixture.context.workspaceID), name: "Frozen export destination", repoPaths: [root.path], ephemeralFlag: true)
            fixture.window.workspaceManager.workspaces = [workspace]
            fixture.window.workspaceManager.activeWorkspace = workspace
            fixture.service.jobCenter.admissionDidRegister = { _ in
                XCTAssertTrue(prepared, "Packaging must finish before a ticket becomes observable")
                // A post-admission workspace change must not redirect or invalidate export.
                fixture.window.workspaceManager.workspaces = []
                fixture.window.workspaceManager.activeWorkspace = nil
            }
            let start = try await fixture.service.executeOracleSend(args: ["op": .string("start"), "detach": .bool(true), "new_chat": .bool(true), "mode": .string("review"), "message": .string("review admission inputs"), "export_response": .bool(true)], invocationContext: fixture.invocationContext)
            XCTAssertTrue(prepared)
            let id = try XCTUnwrap(start.objectValue?["job_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
            let terminal = await fixture.service.jobCenter.store.wait(id: id, timeout: 5)
            XCTAssertEqual(terminal?.status, .completed)
            XCTAssertEqual(preparations, 1)
            XCTAssertTrue(exported)
            XCTAssertEqual(terminal?.result?.objectValue?["oracle_export_path"], .string("/tmp/frozen-export.md"))
        }

        func testSingleOracleTicketRetainsSettledResponseWhenExportIsCancelled() async throws {
            for ask in [false, true] {
                let exporting = expectation(description: "single reply settled and export entered")
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("single-cancel-export-\(UUID())")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let fixture = makeOracleSendFixture(stopAfterRoute: false, connectionID: UUID(), exportOperation: { _ in
                    exporting.fulfill()
                    try await Task.sleep(for: .seconds(60))
                    throw CancellationError()
                }, settledReply: ["chat_id": .string("single-completed"), "response": .string("  retained answer\n")])
                defer { fixture.cleanup() }
                await fixture.window.workspaceManager.awaitInitialized()
                let workspace = try WorkspaceModel(id: XCTUnwrap(fixture.context.workspaceID), name: "Single export cancellation", repoPaths: [root.path], ephemeralFlag: true)
                fixture.window.workspaceManager.workspaces = [workspace]
                fixture.window.workspaceManager.activeWorkspace = workspace
                let args: [String: Value] = ["op": .string("start"), "detach": .bool(true), "new_chat": .bool(true), "message": .string("fixture"), "export_response": .bool(true)]
                let start = if ask {
                    try await fixture.service.executeAskOracle(args: args, invocationContext: fixture.invocationContext)
                } else {
                    try await fixture.service.executeOracleSend(args: args, invocationContext: fixture.invocationContext)
                }
                let id = try XCTUnwrap(start.objectValue?["job_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
                await fulfillment(of: [exporting], timeout: 2)
                fixture.service.jobCenter.cancel(id: id)
                let terminal = await fixture.service.jobCenter.store.wait(id: id, timeout: 5)
                XCTAssertEqual(terminal?.status, .cancelled)
                XCTAssertEqual(terminal?.result?.objectValue?["response"], .string("  retained answer\n"))
                XCTAssertEqual(terminal?.result?.objectValue?["chat_id"], .string("single-completed"))
                XCTAssertNotNil(terminal?.result?.objectValue?["oracle_export_error"])
                XCTAssertNil(terminal?.result?.objectValue?["oracle_export_path"])
                XCTAssertEqual(fixture.sendRecorder.calls.count, 1)
            }
        }

        func testOracleSendTicketExecutesOnceAndPollingDoesNotRebindOrSend() async throws {
            let fixture = makeOracleSendFixture(stopAfterRoute: false)
            defer { fixture.cleanup() }
            let start = try await fixture.service.executeOracleSend(args: ["op": .string("start"), "detach": .bool(true), "message": .string("fixture"), "new_chat": .bool(true)], invocationContext: fixture.invocationContext)
            let id = try XCTUnwrap(start.objectValue?["job_id"]?.stringValue)
            let settled = try await fixture.service.executeOracleSend(args: ["op": .string("wait"), "job_id": .string(id), "timeout": .int(5)], invocationContext: fixture.invocationContext)
            XCTAssertEqual(settled.objectValue?["response"], .string("response"))
            XCTAssertEqual(settled.objectValue?["job"]?.objectValue?["status"], .string("completed"))
            let poll = try await fixture.service.executeOracleSend(args: ["op": .string("poll"), "job_id": .string(id)], invocationContext: fixture.invocationContext)
            XCTAssertEqual(poll, settled)
            XCTAssertEqual(fixture.sendRecorder.calls.count, 1)
            XCTAssertEqual(fixture.rebindRecorder.count, 0)
            XCTAssertNil(fixture.sendRecorder.calls[0]["op"])
        }

        /// A non-Agent compose tab closed while ticket preparation is suspended (before admission)
        /// is invisible to the close sweep; admission must reject it rather than dispatch paid work.
        func testTicketStartRejectsTabClosedDuringPreparationAndUnclosedTabStillAdmits() async throws {
            for tool in ["ask_oracle", "oracle_send"] {
                try await OracleTicketExecutionHarness.withControlledFixture(additionalModels: [], allowsRebind: false) { ctx in
                    let args: [String: Value] = ["op": .string("start"), "detach": .bool(true), "new_chat": .bool(true), "message": .string("Gated preparation")]
                    let tabID = ctx.driver.tabID

                    // Control: the same gated real preparation admits while the tab stays open.
                    let controlEntered = ctx.preparation.arm()
                    let control = Task { try await OracleTicketExecutionHarness.execute(tool, args: args, service: ctx.service, invocation: ctx.invocation) }
                    try await ctx.driver.fixture.awaitGateEvent(controlEntered)
                    ctx.preparation.open()
                    let controlStart = try await control.value
                    let controlID = try XCTUnwrap(controlStart.objectValue?["job_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
                    let controlTerminal = await ctx.service.jobCenter.store.wait(id: controlID, timeout: 5)
                    XCTAssertEqual(controlTerminal?.status, .completed, tool)
                    XCTAssertEqual(ctx.provider.sendCount, 1, tool)

                    // Close the exact tab while preparation is suspended, then release preparation.
                    let entered = ctx.preparation.arm()
                    let rejected = Task { try await OracleTicketExecutionHarness.execute(tool, args: args, service: ctx.service, invocation: ctx.invocation) }
                    try await ctx.driver.fixture.awaitGateEvent(entered)
                    let report = await ctx.driver.window.promptManager.closeComposeTab(tabID)
                    XCTAssertTrue(report.removedComposeTabIDs.contains(tabID), tool)
                    let sessionsBefore = Set(ctx.oracle.sessions.map(\.id))
                    ctx.service.jobCenter.admissionDidRegister = { _ in XCTFail("\(tool): a closed tab must not register a job") }
                    defer { ctx.service.jobCenter.admissionDidRegister = nil }
                    ctx.preparation.open()
                    do {
                        _ = try await rejected.value
                        XCTFail("\(tool): start must fail for a tab closed during preparation")
                    } catch let error as MCPError {
                        guard case .invalidRequest = error else { return XCTFail("\(tool): unexpected \(error)") }
                        XCTAssertTrue(error.localizedDescription.contains("closed before the job was admitted"), "\(tool): \(error)")
                    }
                    XCTAssertEqual(ctx.provider.sendCount, 1, "\(tool): no worker or provider dispatch")
                    XCTAssertTrue(Set(ctx.oracle.sessions.map(\.id)).subtracting(sessionsBefore).isEmpty, "\(tool): no chat created")
                    XCTAssertNil(ctx.driver.manager.composeTab(with: tabID), "\(tool): never rebound or resurrected")
                }
            }
        }

        func testOracleSendTicketSurvivesOriginDisconnectAndAuthorizedReconnect() async throws {
            let availability = OracleConnectionAvailability()
            let fixture = makeOracleSendFixture(stopAfterRoute: false, contextAvailable: { availability.connected })
            defer { fixture.cleanup() }
            let start = try await fixture.service.executeOracleSend(args: ["op": .string("start"), "detach": .bool(true), "message": .string("fixture"), "new_chat": .bool(true)], invocationContext: fixture.invocationContext)
            let id = try XCTUnwrap(start.objectValue?["job_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
            availability.connected = false
            let terminal = await fixture.service.jobCenter.store.wait(id: id, timeout: 5)
            XCTAssertEqual(terminal?.result?.objectValue?["response"], .string("response"))
            XCTAssertEqual(fixture.sendRecorder.calls.count, 1)
            XCTAssertEqual(fixture.sendRecorder.progressContexts, [true])
            availability.connected = true
            let poll = try await fixture.service.executeOracleSend(args: ["op": .string("poll"), "job_id": .string(id.uuidString)], invocationContext: fixture.invocationContext)
            XCTAssertEqual(poll.objectValue?["response"], .string("response"))
            XCTAssertEqual(fixture.sendRecorder.calls.count, 1)
        }

        func testTicketRejectsUnresolvedAgentOriginBeforeWorkOrObservation() async throws {
            let fixture = makeOracleSendFixture(stopAfterRoute: false, connectionID: UUID(), livePurpose: .agentModeRun)
            defer { fixture.cleanup() }
            do {
                _ = try await fixture.service.executeOracleSend(args: ["op": .string("start"), "detach": .bool(true), "message": .string("fixture")], invocationContext: fixture.invocationContext)
                XCTFail("An unresolved Agent origin must not admit a ticket")
            } catch { XCTAssertTrue(error.localizedDescription.contains("active Agent session/run context")) }
            let id = UUID()
            let owner = DomainLongRunningJobStore.Owner(windowID: fixture.window.windowID, workspaceID: fixture.context.workspaceID, tabID: fixture.context.tabID, sessionID: nil, runID: nil)
            _ = try await fixture.service.jobCenter.store.register(id: id, tool: "oracle_send", owner: owner)
            do {
                _ = try await fixture.service.executeOracleSend(args: ["op": .string("poll"), "job_id": .string(id.uuidString)], invocationContext: fixture.invocationContext)
                XCTFail("An unresolved Agent origin must not match a non-agent origin")
            } catch { XCTAssertTrue(error.localizedDescription.contains("active Agent session/run context")) }
            XCTAssertTrue(fixture.sendRecorder.calls.isEmpty)
        }

        func testExternalCallerCannotControlAgentOwnedJobInSameContext() async throws {
            let fixture = makeOracleSendFixture(stopAfterRoute: false)
            defer { fixture.cleanup() }
            let id = UUID()
            let owner = DomainLongRunningJobStore.Owner(windowID: fixture.window.windowID, workspaceID: fixture.context.workspaceID, tabID: fixture.context.tabID, sessionID: UUID(), runID: UUID())
            _ = try await fixture.service.jobCenter.store.register(id: id, tool: "oracle_send", owner: owner)
            for op in ["poll", "wait", "cancel"] {
                do {
                    _ = try await fixture.service.executeOracleSend(args: ["op": .string(op), "job_id": .string(id.uuidString)], invocationContext: fixture.invocationContext)
                    XCTFail("Non-agent origin must not control agent-owned ticket")
                } catch { XCTAssertTrue(error.localizedDescription.contains("different Agent session/run")) }
            }
            let snapshot = await fixture.service.jobCenter.store.snapshot(id: id)
            XCTAssertEqual(snapshot?.status, .running)
        }

        func testAgentModeOracleSendDoesNotCompatibilityRebind() async {
            let fixture = makeOracleSendFixture(connectionID: UUID(), livePurpose: .agentModeRun)
            defer { fixture.cleanup() }

            await assertStopsAfterRoute(
                fixture,
                args: [
                    "message": .string("continue"),
                    "chat_id": .string("existing-chat")
                ]
            )
            XCTAssertEqual(fixture.rebindRecorder.count, 0)
        }

        func testSingleOracleExportRemainsByteCompatible() {
            let request = OracleExportRequest(
                sourceTool: "oracle_send",
                mode: "plan",
                message: "Plan it",
                chatID: "primary-chat",
                response: "Primary answer"
            )
            XCTAssertEqual(AgentOracleExport.oracleMarkdown(request: request), "# Oracle Plan\n\nPrimary answer")
        }

        func testExportBoundaryDecodesCanonicalGroupAndRejectsMalformedEnvelope() throws {
            let group = try OracleGroupResult(
                groupID: OracleGroupID(rawValue: UUID()),
                status: .partialFailure,
                oracleResults: [
                    OracleLaneResult(
                        laneIndex: 0,
                        chatID: "chat-0",
                        providerID: "provider-0",
                        modelID: "model-0",
                        status: .completed,
                        response: "response-0"
                    ),
                    OracleLaneResult(
                        laneIndex: 1,
                        chatID: "chat-1",
                        providerID: "provider-1",
                        modelID: "model-1",
                        status: .failed,
                        error: OracleLaneError(
                            code: "failed",
                            message: "lane failed",
                            partialResponse: "partial-1"
                        )
                    )
                ],
                warnings: [OracleGroupWarning(code: "warning", message: "group warning")]
            )
            var fields = OracleGroupMCPCodec.groupFields(group)
            fields["chat_id"] = .string(group.primary.chatID)
            fields["response"] = try .string(XCTUnwrap(group.primary.response))

            XCTAssertEqual(try MCPOracleToolService.decodeOracleGroupResultForExport(fields), group)
            XCTAssertNil(try MCPOracleToolService.decodeOracleGroupResultForExport([
                "chat_id": .string("legacy"),
                "response": .string("legacy response")
            ]))

            fields["oracle_count"] = .int(3)
            XCTAssertThrowsError(try MCPOracleToolService.decodeOracleGroupResultForExport(fields))
        }

        func testTwoOracleExportRetainsCanonicalGroupDetails() throws {
            let groupID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
            let group = try OracleGroupResult(
                groupID: OracleGroupID(rawValue: groupID),
                status: .partialFailure,
                oracleResults: [
                    OracleLaneResult(
                        laneIndex: 0,
                        chatID: "primary-chat",
                        providerID: "configured-primary-provider",
                        modelID: "configured-primary-model",
                        status: .completed,
                        executionProfile: OracleExecutionProfile(
                            providerID: "executed-primary-provider",
                            modelID: "executed-primary-model",
                            effectiveReasoningEffort: "high"
                        ),
                        response: "Primary lane answer"
                    ),
                    OracleLaneResult(
                        laneIndex: 1,
                        chatID: "secondary-chat",
                        providerID: "configured-secondary-provider",
                        modelID: "configured-secondary-model",
                        status: .failed,
                        error: OracleLaneError(
                            code: "provider_failed",
                            message: "Secondary provider failed",
                            partialResponse: "Secondary partial answer"
                        )
                    )
                ],
                warnings: [
                    OracleGroupWarning(code: "lane_failure", message: "One lane failed")
                ]
            )
            let request = OracleExportRequest(
                sourceTool: "oracle_send",
                mode: "review",
                message: "Review it",
                chatID: "primary-chat",
                response: "Primary lane answer",
                groupResult: group
            )

            let markdown = AgentOracleExport.oracleMarkdown(request: request)

            XCTAssertTrue(markdown.hasPrefix("# Oracle Review\n\n"))
            XCTAssertTrue(markdown.contains("- Group ID: `\(groupID.uuidString)`"))
            XCTAssertTrue(markdown.contains("- Status: `partial_failure`"))
            XCTAssertTrue(markdown.contains("- Oracle count: 2"))
            XCTAssertTrue(markdown.contains("- `lane_failure`: One lane failed"))
            XCTAssertTrue(markdown.contains("### Oracle (Primary)"))
            XCTAssertTrue(markdown.contains("### Oracle 2"))
            XCTAssertTrue(markdown.contains("- Chat ID: `primary-chat`"))
            XCTAssertTrue(markdown.contains("- Provider: `configured-primary-provider`"))
            XCTAssertTrue(markdown.contains("- Model: `configured-primary-model`"))
            XCTAssertTrue(markdown.contains("- Execution provider: `executed-primary-provider`"))
            XCTAssertTrue(markdown.contains("- Execution model: `executed-primary-model`"))
            XCTAssertTrue(markdown.contains("- Effective reasoning effort: `high`"))
            XCTAssertTrue(markdown.contains("Primary lane answer"))
            XCTAssertTrue(markdown.contains("Secondary partial answer"))
            XCTAssertTrue(markdown.contains("- Code: `provider_failed`"))
            XCTAssertTrue(markdown.contains("- Message: Secondary provider failed"))
            XCTAssertLessThan(
                try XCTUnwrap(markdown.range(of: "### Oracle (Primary)")?.lowerBound),
                try XCTUnwrap(markdown.range(of: "### Oracle 2")?.lowerBound)
            )
            XCTAssertFalse(markdown.localizedCaseInsensitiveContains("combined answer"))
            XCTAssertFalse(markdown.localizedCaseInsensitiveContains("synthesized answer"))
        }

        func testFiveOracleExportRetainsEveryLaneInOrder() throws {
            let lanes = try (0 ..< 5).map { index -> OracleLaneResult in
                if index == 2 {
                    return try OracleLaneResult(
                        laneIndex: index,
                        chatID: "chat-\(index)",
                        providerID: "provider-\(index)",
                        modelID: "model-\(index)",
                        status: .completed,
                        response: "response-\(index)"
                    )
                }
                let status: OracleLaneResultStatus = index.isMultiple(of: 2) ? .failed : .cancelled
                return try OracleLaneResult(
                    laneIndex: index,
                    chatID: "chat-\(index)",
                    providerID: "provider-\(index)",
                    modelID: "model-\(index)",
                    status: status,
                    error: OracleLaneError(
                        code: "error-\(index)",
                        message: "message-\(index)",
                        partialResponse: "partial-\(index)"
                    )
                )
            }
            let group = try OracleGroupResult(
                groupID: OracleGroupID(rawValue: UUID()),
                status: .failed,
                oracleResults: lanes
            )
            let markdown = AgentOracleExport.oracleMarkdown(request: OracleExportRequest(
                sourceTool: "ask_oracle",
                mode: "chat",
                message: "Compare",
                chatID: "chat-0",
                response: nil,
                groupResult: group
            ))

            XCTAssertTrue(markdown.contains("- Status: `failed`"))
            XCTAssertTrue(markdown.contains("- Oracle count: 5"))
            var priorHeadingIndex = markdown.startIndex
            for index in 0 ..< 5 {
                let label = OracleRosterContract.displayLabel(laneIndex: index)
                let heading = index == 0 ? "### \(label) (Primary)" : "### \(label)"
                let headingIndex = try XCTUnwrap(markdown.range(of: heading)?.lowerBound)
                XCTAssertGreaterThanOrEqual(headingIndex, priorHeadingIndex)
                priorHeadingIndex = headingIndex
                XCTAssertTrue(markdown.contains("- Chat ID: `chat-\(index)`"))
                if index == 2 {
                    XCTAssertTrue(markdown.contains("response-\(index)"))
                } else {
                    XCTAssertTrue(markdown.contains("partial-\(index)"))
                    XCTAssertTrue(markdown.contains("- Code: `error-\(index)`"))
                    XCTAssertTrue(markdown.contains("- Message: message-\(index)"))
                }
            }
        }

        func testGroupExportCancellationPreservesSettledLaneHandlesBeforeAndDuringExport() async throws {
            let lanes = try [
                OracleLaneResult(
                    laneIndex: 0, chatID: "completed-chat", providerID: "fixture", modelID: "primary",
                    status: .completed, response: "sum 81"
                ),
                OracleLaneResult(
                    laneIndex: 1, chatID: "cancelled-chat", providerID: "fixture", modelID: "additional",
                    status: .cancelled, error: OracleLaneError(code: "cancelled", message: "Cancelled")
                )
            ]
            let group = try OracleGroupResult(groupID: OracleGroupID(rawValue: UUID()), status: .partialFailure, oracleResults: lanes)
            let payload = ContextBuilderOracleGroupReply(result: group).toMCPFields()
            for cancelBeforeExport in [true, false] {
                let fixture = makeOracleSendFixture(exportOperation: { _ in
                    XCTAssertFalse(cancelBeforeExport, "A cancelled request must not begin exporting")
                    withUnsafeCurrentTask { $0?.cancel() }
                    throw CancellationError()
                })
                defer { fixture.cleanup() }
                let request = OracleExportRequest(
                    sourceTool: "ask_oracle", mode: "chat",
                    message: "Read only fixture.txt. Write a 400-word essay about the fixture values, then give the sum.",
                    chatID: "completed-chat", response: nil, groupResult: group
                )
                let task = Task {
                    if cancelBeforeExport { withUnsafeCurrentTask { $0?.cancel() } }
                    return try await fixture.service.exportSettledOracleResponse(payload, request: request)
                }
                let reply = try await task.value
                XCTAssertEqual(reply["oracle_group_id"], payload["oracle_group_id"])
                XCTAssertEqual(reply["status"], .string("partial_failure"))
                XCTAssertEqual(reply["oracle_results"], payload["oracle_results"])
                XCTAssertNotNil(reply["oracle_export_error"])
                XCTAssertNil(reply["oracle_export_path"])
            }
        }

        func testOrdinaryExportFailurePreservesSettledGroupedAndSingleRepliesOnBlockingAndTicketPaths() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("oracle-export-fixture-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let group = try OracleGroupResult(
                groupID: OracleGroupID(rawValue: UUID()), status: .partialFailure,
                oracleResults: [
                    OracleLaneResult(
                        laneIndex: 0, chatID: "primary-chat", providerID: "fixture", modelID: "primary",
                        status: .completed, response: "Primary answer"
                    ),
                    OracleLaneResult(
                        laneIndex: 1, chatID: "additional-chat", providerID: "fixture", modelID: "additional",
                        status: .failed, error: OracleLaneError(code: "provider_error", message: "Additional failed", partialResponse: "Partial answer")
                    )
                ]
            )
            var grouped = OracleGroupMCPCodec.groupFields(group)
            grouped["chat_id"] = .string(group.primary.chatID)
            grouped["response"] = .string("Primary answer")
            let capturedGuidance = "  Retain each material disagreement.\nDo not vote.  "
            grouped["oracle_reconciliation_guidance"] = .string(capturedGuidance)
            let single: [String: Value] = ["chat_id": .string("single-chat"), "response": .string("Single answer")]
            for (sourceTool, payload) in [grouped, single].flatMap({ payload in
                ["oracle_send", "ask_oracle"].map { ($0, payload) }
            }) {
                for ticket in [false, true] {
                    let fixture = makeOracleSendFixture(stopAfterRoute: false, connectionID: UUID(), exportOperation: { request in
                        XCTAssertEqual(request.chatID, payload["chat_id"]?.stringValue)
                        XCTAssertEqual(request.reconciliationGuidance, payload["oracle_reconciliation_guidance"]?.stringValue)
                        let markdown = AgentOracleExport.oracleMarkdown(request: request)
                        if request.groupResult != nil {
                            XCTAssertTrue(markdown.contains(capturedGuidance))
                            XCTAssertFalse(markdown.contains(OracleGroupDeliveryContract.defaultReconciliationGuidance))
                        } else {
                            XCTAssertEqual(markdown, "# Oracle Response\n\nSingle answer")
                        }
                        throw NSError(domain: "OracleExportFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Private export diagnostic"])
                    }, settledReply: payload)
                    defer { fixture.cleanup() }
                    await fixture.window.workspaceManager.awaitInitialized()
                    let workspace = try WorkspaceModel(
                        id: XCTUnwrap(fixture.context.workspaceID), name: "Oracle export fixture",
                        repoPaths: [root.path], ephemeralFlag: true
                    )
                    fixture.window.workspaceManager.workspaces = [workspace]
                    fixture.window.workspaceManager.activeWorkspace = workspace
                    var args: [String: Value] = ["message": .string("fixture"), "new_chat": .bool(true), "export_response": .bool(true)]
                    if ticket { args["op"] = .string("start") }
                    let reply: Value
                    do {
                        reply = if sourceTool == "ask_oracle" {
                            try await fixture.service.executeAskOracle(args: args, invocationContext: fixture.invocationContext)
                        } else {
                            try await fixture.service.executeOracleSend(args: args, invocationContext: fixture.invocationContext)
                        }
                    } catch {
                        XCTFail("Optional export failure discarded settled reply: \(error)")
                        XCTAssertEqual(fixture.sendRecorder.calls.count, 1)
                        continue
                    }
                    var fields = try XCTUnwrap(reply.objectValue)
                    guard let notice = fields.removeValue(forKey: "oracle_export_error")?.stringValue else {
                        XCTFail("Export failure erased the settled ticket payload: \(reply)")
                        XCTAssertEqual(fixture.sendRecorder.calls.count, 1)
                        continue
                    }
                    XCTAssertTrue(notice.contains("returned chat IDs"))
                    XCTAssertFalse(notice.contains("Private export diagnostic"))
                    XCTAssertNil(fields["oracle_export_path"])
                    XCTAssertNil(fields["oracle_export_instruction"])
                    if ticket {
                        XCTAssertEqual(fields.removeValue(forKey: "job")?.objectValue?["status"], .string("completed"))
                        XCTAssertNotNil(fields.removeValue(forKey: "job_id"))
                    }
                    XCTAssertEqual(fields, payload)
                    XCTAssertEqual(fixture.sendRecorder.calls.count, 1, "Recovery must not rerun paid work")
                }
            }
        }

        func testMalformedGroupExportDegradesToNoticeOnTicketsAndStillThrowsWhenBlocking() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("oracle-malformed-export-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let payload = try malformedGroupPayload()
            XCTAssertThrowsError(try MCPOracleToolService.decodeOracleGroupResultForExport(payload))
            for sourceTool in ["oracle_send", "ask_oracle"] {
                for path in ["ticket", "ticket-without-export", "blocking"] {
                    let label = "\(sourceTool) \(path)"
                    let fixture = makeOracleSendFixture(stopAfterRoute: false, connectionID: UUID(), exportOperation: { _ in
                        XCTFail("A malformed group payload must not reach the exporter")
                        throw CancellationError()
                    }, settledReply: payload)
                    defer { fixture.cleanup() }
                    try await installWorkspace(root, in: fixture)
                    var args: [String: Value] = ["new_chat": .bool(true), "message": .string("fixture")]
                    if path != "ticket-without-export" { args["export_response"] = .bool(true) }
                    if path != "blocking" { args["op"] = .string("start") }

                    if path == "blocking" {
                        do {
                            _ = try await executeOracleTool(sourceTool, args: args, fixture: fixture)
                            XCTFail("Blocking export must keep the strict decoder's throwing contract (\(label))")
                        } catch let MCPError.internalError(detail) {
                            XCTAssertTrue(detail?.contains("invalid grouped result") == true, "\(label): \(detail ?? "")")
                        } catch {
                            XCTFail("Unexpected error \(error) (\(label))")
                        }
                        XCTAssertEqual(fixture.sendRecorder.calls.count, 1, label)
                        continue
                    }

                    let reply = try await executeOracleTool(sourceTool, args: args, fixture: fixture)
                    var fields = try XCTUnwrap(reply.objectValue)
                    XCTAssertEqual(fields.removeValue(forKey: "job")?.objectValue?["status"], .string("completed"), "\(label): \(reply)")
                    let jobID = try XCTUnwrap(fields.removeValue(forKey: "job_id")?.stringValue)
                    if path == "ticket" {
                        XCTAssertEqual(
                            fields.removeValue(forKey: "oracle_export_error"),
                            .string("Oracle export failed; output may remain. Recover the settled result using the returned chat IDs."),
                            label
                        )
                    }
                    XCTAssertNil(fields["oracle_export_path"], label)
                    XCTAssertNil(fields["oracle_export_instruction"], label)
                    XCTAssertEqual(fields, payload, "\(label) must retain the settled reply unchanged")
                    for op in ["poll", "wait"] {
                        let observed = try await executeOracleTool(sourceTool, args: ["op": .string(op), "job_id": .string(jobID)], fixture: fixture)
                        XCTAssertEqual(
                            observed.objectValue?.filter { $0.key != "job" }, reply.objectValue?.filter { $0.key != "job" }, "\(label) \(op)"
                        )
                    }
                    XCTAssertEqual(fixture.sendRecorder.calls.count, 1, "\(label): observation must not rerun paid work")
                }
            }
        }

        func testCancelledTicketWithMalformedGroupRetainsReplyWithoutDecodingOrExport() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("oracle-malformed-cancel-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let payload = try malformedGroupPayload()
            for sourceTool in ["oracle_send", "ask_oracle"] {
                let entered = expectation(description: "\(sourceTool) send entered")
                let gate = AsyncStream<Void>.makeStream()
                let fixture = makeOracleSendFixture(stopAfterRoute: false, connectionID: UUID(), exportOperation: { _ in
                    XCTFail("A cancelled ticket must not start export")
                    throw CancellationError()
                }, sendOperation: { _, _, _ in
                    entered.fulfill()
                    for await _ in gate.stream {}
                    return payload
                })
                defer {
                    gate.continuation.finish()
                    fixture.cleanup()
                }
                try await installWorkspace(root, in: fixture)
                let start = try await executeOracleTool(sourceTool, args: [
                    "op": .string("start"), "detach": .bool(true), "new_chat": .bool(true),
                    "message": .string("fixture"), "export_response": .bool(true)
                ], fixture: fixture)
                let id = try XCTUnwrap(start.objectValue?["job_id"]?.stringValue)
                await fulfillment(of: [entered], timeout: 2)
                _ = try await executeOracleTool(sourceTool, args: ["op": .string("cancel"), "job_id": .string(id)], fixture: fixture)
                let result = try await executeOracleTool(
                    sourceTool, args: ["op": .string("wait"), "job_id": .string(id), "timeout": .int(5)], fixture: fixture
                )
                var fields = try XCTUnwrap(result.objectValue)
                XCTAssertEqual(fields.removeValue(forKey: "job")?.objectValue?["status"], .string("cancelled"), sourceTool)
                fields.removeValue(forKey: "job_id")
                XCTAssertEqual(
                    fields.removeValue(forKey: "oracle_export_error"),
                    .string("Oracle export cancelled; output may remain. Recover the settled result using the returned chat IDs."),
                    sourceTool
                )
                XCTAssertEqual(fields, payload, "\(sourceTool) must retain the settled reply")
                XCTAssertEqual(fixture.sendRecorder.calls.count, 1, sourceTool)
            }
        }

        func testNonGroupExportCancellationStillThrows() async {
            let fixture = makeOracleSendFixture(exportOperation: { _ in throw CancellationError() })
            defer { fixture.cleanup() }
            do {
                _ = try await fixture.service.exportSettledOracleResponse(
                    ["chat_id": .string("single-chat")],
                    request: OracleExportRequest(sourceTool: "ask_oracle", mode: "chat", message: "fixture", chatID: "single-chat", response: nil)
                )
                XCTFail("Expected ordinary non-group cancellation")
            } catch is CancellationError {
                // Expected.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        private func executeOracleTool(
            _ tool: String, args: [String: Value], fixture: OracleSendBoundaryFixture
        ) async throws -> Value {
            if tool == "ask_oracle" {
                return try await fixture.service.executeAskOracle(args: args, invocationContext: fixture.invocationContext)
            }
            return try await fixture.service.executeOracleSend(args: args, invocationContext: fixture.invocationContext)
        }

        private func installWorkspace(_ root: URL, in fixture: OracleSendBoundaryFixture) async throws {
            await fixture.window.workspaceManager.awaitInitialized()
            let workspace = try WorkspaceModel(
                id: XCTUnwrap(fixture.context.workspaceID), name: "Oracle export fixture",
                repoPaths: [root.path], ephemeralFlag: true
            )
            fixture.window.workspaceManager.workspaces = [workspace]
            fixture.window.workspaceManager.activeWorkspace = workspace
        }

        /// Canonical two-lane group fields whose declared `oracle_count` disagrees with its lanes.
        private func malformedGroupPayload() throws -> [String: Value] {
            let group = try OracleGroupResult(
                groupID: OracleGroupID(rawValue: UUID()), status: .completed,
                oracleResults: [
                    OracleLaneResult(laneIndex: 0, chatID: "primary-chat", providerID: "fixture", modelID: "primary", status: .completed, response: "Primary answer"),
                    OracleLaneResult(laneIndex: 1, chatID: "additional-chat", providerID: "fixture", modelID: "additional", status: .completed, response: "Additional answer")
                ]
            )
            var payload = OracleGroupMCPCodec.groupFields(group)
            payload["chat_id"] = .string(group.primary.chatID)
            payload["response"] = .string("Primary answer")
            payload["oracle_count"] = .int(3)
            return payload
        }

        private func assertStopsAfterRoute(
            _ fixture: OracleSendBoundaryFixture,
            args: [String: Value]
        ) async {
            do {
                _ = try await fixture.service.executeOracleSend(args: args, invocationContext: fixture.invocationContext)
                XCTFail("Expected test stop after route validation")
            } catch OracleBoundaryTestStop.afterRoute {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        private func makeOracleSendFixture(
            stopAfterRoute: Bool = true,
            connectionID: UUID? = nil,
            livePurpose: MCPRunPurpose = .unknown,
            exportOperation: MCPOracleToolService.ExportOracleResponse? = nil,
            settledReply: [String: Value]? = nil,
            sendOperation: MCPOracleToolService.SendChat? = nil,
            contextAvailable: @escaping @MainActor () -> Bool = { true },
            stabilizeContext: @escaping MCPOracleToolService.StabilizedVirtualContext = { $0 }
        ) -> OracleSendBoundaryFixture {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

            let snapshot = MCPTabContextSnapshot(
                tabID: UUID(),
                windowID: window.windowID,
                workspaceID: UUID(),
                promptText: "",
                selection: StoredSelection(),
                selectedMetaPromptIDs: [],
                tabName: "Oracle boundary",
                runID: nil,
                frozenLookupContext: .visibleWorkspace,
                explicitlyBound: true
            )
            let metadata = MCPRequestMetadata(
                connectionID: connectionID,
                clientName: "oracle-boundary-test",
                windowID: window.windowID
            )
            let recorder = OracleRebindRecorder()
            let sendRecorder = OracleSendArgsRecorder()
            var service = MCPOracleToolService(
                askOracleToolName: "ask_oracle",
                oracleSendToolName: "oracle_send",
                oracleChatLogToolName: "oracle_chat_log",
                promptVM: window.promptManager,
                oracleVM: window.oracleViewModel,
                liveRunPurpose: { requestedConnectionID in
                    requestedConnectionID == connectionID ? livePurpose : .unknown
                },
                resolveTabContextSnapshot: { _ in .init(snapshot: snapshot) },
                requireCurrentTabContext: { _ in
                    if stopAfterRoute || !contextAvailable() { throw OracleBoundaryTestStop.afterRoute }
                    return snapshot
                },
                stabilizedVirtualContext: stabilizeContext,
                resolveDelegatedReviewPackaging: { _, _, _, _ in nil },
                rebindChatSessionIfNeeded: { _, chatID in recorder.record(chatID) },
                resolveTabIDForAgentMode: { _, _ in snapshot.tabID },
                requireTargetWindow: { window },
                rawExplicitTabID: { _ in nil },
                sendStageProgress: { _, _, _, _ in },
                withHeartbeat: { _, _, _, _, operation in
                    guard contextAvailable() else { throw OracleBoundaryTestStop.afterRoute }
                    return try await operation()
                },
                resolveStartExecution: { mode, model, _ in
                    let snapshot = OracleSelectionSnapshot(
                        origin: .mcp,
                        agentModelsProfile: .init(planningModelRaw: AIModel.gpt54Mini.rawValue),
                        modelPresets: [], modelPresetsExposed: false, modelPresetsTemporarilyDisabled: false,
                        chatPresets: [ChatPreset.BuiltIn.chat, ChatPreset.BuiltIn.plan, ChatPreset.BuiltIn.review],
                        defaultChatPresets: [.chat: ChatPreset.BuiltIn.chat, .plan: ChatPreset.BuiltIn.plan, .review: ChatPreset.BuiltIn.review]
                    )
                    return try OracleExecutionResolver(
                        resolveModel: AIModel.fromModelName, isModelAvailable: { _ in true },
                        capturePromptConfiguration: { preset, mode in
                            try window.promptManager.captureOraclePromptConfiguration(chatPreset: preset, mode: mode)
                        }
                    ).resolve(choice: model.map(OracleStartChoice.oracleSend) ?? .automatic, mode: mode, snapshot: snapshot)
                },
                sendChat: { args, _, tabContext in
                    sendRecorder.record(args)
                    sendRecorder.progressContexts.append(tabContext?.jobProgress != nil)
                    if let sendOperation { return try await sendOperation(args, window.promptManager, tabContext) }
                    return settledReply ?? [
                        "chat_id": .string("selected-chat"),
                        "response": .string("response")
                    ]
                },
                exportOracleResponse: exportOperation ?? { _ in throw OracleBoundaryTestStop.unexpectedExport },
                jobCenter: MCPLongRunningJobCenter()
            )
            // Synthetic tab identity: admission-target closure is covered by the real-tab fixture tests.
            service.admissionTargetExists = { _, _ in true }
            return OracleSendBoundaryFixture(
                window: window,
                service: service,
                invocationContext: .trustedLocal(toolName: "oracle_send", metadata: metadata),
                rebindRecorder: recorder,
                sendRecorder: sendRecorder,
                context: snapshot
            )
        }
    }

    final class OracleContextBuilderCommandRunnerTests: XCTestCase {
        func testJobControlsAndDetachedAliasReachSessionWithoutDiscoveryInputs() async throws {
            let fixture = try await makeCommandRunnerFixture()
            addTeardownBlock { await fixture.cleanup() }
            let id = UUID().uuidString
            for op in ["poll", "wait", "cancel"] {
                let result = await fixture.runner.runLine("call context_builder {\"op\":\"\(op)\",\"job_id\":\"\(id)\"}")
                XCTAssertTrue(result.succeeded)
            }
            let alias = await fixture.runner.runLine("builder --detach --timeout 20 Inspect the workspace")
            XCTAssertTrue(alias.succeeded)
            let calls = await fixture.recorder.recordedCalls()
            XCTAssertEqual(calls.count, 4)
            XCTAssertEqual(calls.last?.arguments?["op"], .string("start"))
            XCTAssertEqual(calls.last?.arguments?["detach"], .bool(true))
            XCTAssertEqual(calls.last?.arguments?["timeout"], .int(20))
        }

        func testBuilderDetachPreservesPositionalInstructions() async throws {
            let fixture = try await makeCommandRunnerFixture()
            addTeardownBlock { await fixture.cleanup() }
            let commands: [(String, Bool)] = [
                ("builder --detach Inspect the workspace", true),
                ("builder --detach true Inspect the workspace", true),
                ("builder --detach false Inspect the workspace", false),
                ("builder --detach=true Inspect the workspace", true),
                ("builder --detach=false Inspect the workspace", false)
            ]
            for (command, _) in commands {
                let result = await fixture.runner.runLine(command)
                XCTAssertTrue(result.succeeded, command)
            }
            let calls = await fixture.recorder.recordedCalls()
            XCTAssertEqual(calls.count, commands.count)
            for (call, command) in zip(calls, commands) {
                XCTAssertEqual(call.arguments?["instructions"], .string("Inspect the workspace"), command.0)
                XCTAssertEqual(call.arguments?["op"], .string("start"), command.0)
                XCTAssertEqual(call.arguments?["detach"], .bool(command.1), command.0)
            }
        }

        func testInstructionsOnlyAndPackOnlyReachSession() async throws {
            let fixture = try await makeCommandRunnerFixture()
            addTeardownBlock { await fixture.cleanup() }

            let instructionsResult = await fixture.runner.runLine(
                #"call context_builder {"instructions":"Inspect the workspace"}"#
            )
            let packResult = await fixture.runner.runLine(
                #"call context_builder {"context_pack_ref":"oracle-pack:sha256:fixture"}"#
            )

            XCTAssertTrue(instructionsResult.succeeded)
            XCTAssertTrue(packResult.succeeded)
            let calls = await fixture.recorder.recordedCalls()
            guard calls.count == 2 else {
                XCTFail("Expected two forwarded calls, got \(calls.count)")
                return
            }
            XCTAssertEqual(calls[0].arguments?["instructions"], .string("Inspect the workspace"))
            XCTAssertEqual(calls[1].arguments?["context_pack_ref"], .string("oracle-pack:sha256:fixture"))
        }

        func testOraclePresetIsForwardedToAppBackedBoundary() async throws {
            let fixture = try await makeCommandRunnerFixture()
            addTeardownBlock { await fixture.cleanup() }

            let result = await fixture.runner.runLine(
                #"call context_builder {"instructions":"Inspect","response_type":"plan","oracle_preset":"Deep"}"#
            )

            XCTAssertTrue(result.succeeded)
            let calls = await fixture.recorder.recordedCalls()
            XCTAssertEqual(calls.first?.arguments?["oracle_preset"], .string("Deep"))
        }

        func testAliasNormalizesToInstructionsBeforeExclusiveInputValidation() async throws {
            let fixture = try await makeCommandRunnerFixture()
            addTeardownBlock { await fixture.cleanup() }

            let result = await fixture.runner.runLine(
                #"call context_builder {"task":"Inspect aliases"}"#
            )

            XCTAssertTrue(result.succeeded)
            let calls = await fixture.recorder.recordedCalls()
            XCTAssertEqual(calls.first?.arguments?["instructions"], .string("Inspect aliases"))
            XCTAssertNil(calls.first?.arguments?["task"])
        }

        func testEmptyInputIsAbsentWhenOtherInputIsNonempty() async throws {
            let fixture = try await makeCommandRunnerFixture()
            addTeardownBlock { await fixture.cleanup() }

            let packResult = await fixture.runner.runLine(
                #"call context_builder {"instructions":"  ","context_pack_ref":"oracle-pack:sha256:fixture"}"#
            )
            let instructionsResult = await fixture.runner.runLine(
                #"call context_builder {"instructions":"Inspect","context_pack_ref":"\n"}"#
            )

            XCTAssertTrue(packResult.succeeded)
            XCTAssertTrue(instructionsResult.succeeded)
            let calls = await fixture.recorder.recordedCalls()
            XCTAssertEqual(calls.count, 2)
        }

        func testBothNeitherAndEmptyInputsFailBeforeSession() async throws {
            let fixture = try await makeCommandRunnerFixture()
            addTeardownBlock { await fixture.cleanup() }
            let invalidLines = [
                "call context_builder",
                #"call context_builder {}"#,
                #"call context_builder {"instructions":"inspect","context_pack_ref":"oracle-pack:sha256:fixture"}"#,
                #"call context_builder {"instructions":"  ","context_pack_ref":"\n"}"#
            ]

            for line in invalidLines {
                let result = await fixture.runner.runLine(line)
                XCTAssertFalse(result.succeeded, line)
            }
            let calls = await fixture.recorder.recordedCalls()
            XCTAssertTrue(calls.isEmpty)
        }

        private func makeCommandRunnerFixture() async throws -> OracleCommandRunnerFixture {
            let transports = await InMemoryTransport.createConnectedPair()
            let recorder = OracleCommandRunnerRecorder()
            let server = Server(
                name: "Oracle command runner boundary server",
                version: "1.0",
                capabilities: .init(tools: .init())
            )
            await server.withMethodHandler(CallTool.self) { params in
                await recorder.record(params)
                return .init(content: [.text(text: "ok", annotations: nil, _meta: nil)], isError: false)
            }
            try await server.start(transport: transports.server)

            let requestSendBarrier = MCPRequestSendBarrier()
            let clientTransport = OrderedMCPTransport(
                underlying: transports.client,
                requestSendBarrier: requestSendBarrier,
                logger: transports.client.logger
            )
            let client = Client(name: "Oracle command runner boundary client", version: "1.0")
            _ = try await client.connect(transport: clientTransport)
            let session = InteractiveMCPClientSession(
                connectedClientForTesting: client,
                requestSendBarrier: requestSendBarrier
            )
            let runner = MCPCommandRunner(
                session: session,
                initialDirectory: FileManager.default.currentDirectoryPath,
                settings: RunnerSettings(),
                outputHandler: { _, _ in }
            )
            return OracleCommandRunnerFixture(
                client: client,
                server: server,
                runner: runner,
                recorder: recorder
            )
        }
    }

    @MainActor
    private enum OracleBoundaryTestStop: Error {
        case afterRoute
        case unexpectedSend
        case unexpectedExport
    }

    @MainActor
    private final class OracleRebindRecorder {
        private(set) var chatIDs: [String] = []

        var count: Int {
            chatIDs.count
        }

        func record(_ chatID: String) {
            chatIDs.append(chatID)
        }
    }

    @MainActor
    private final class OracleSendArgsRecorder {
        private(set) var calls: [[String: Value]] = []
        var progressContexts: [Bool] = []

        func record(_ args: [String: Value]) {
            calls.append(args)
        }
    }

    @MainActor
    private final class OracleConnectionAvailability {
        var connected = true
    }

    @MainActor
    private struct OracleSendBoundaryFixture {
        let window: WindowState
        let service: MCPOracleToolService
        let invocationContext: ToolInvocationContext
        let rebindRecorder: OracleRebindRecorder
        let sendRecorder: OracleSendArgsRecorder
        let context: MCPTabContextSnapshot

        func cleanup() {
            WindowStatesManager.shared.unregisterWindowState(window)
        }
    }

    private struct OracleRecordedCommandCall {
        let arguments: [String: Value]?
    }

    private actor OracleCommandRunnerRecorder {
        private var calls: [OracleRecordedCommandCall] = []

        func record(_ params: CallTool.Parameters) {
            calls.append(.init(arguments: params.arguments))
        }

        func recordedCalls() -> [OracleRecordedCommandCall] {
            calls
        }
    }

    private struct OracleCommandRunnerFixture {
        let client: Client
        let server: Server
        let runner: MCPCommandRunner
        let recorder: OracleCommandRunnerRecorder

        func cleanup() async {
            await client.disconnect()
            await server.stop()
        }
    }
#endif

@MainActor
final class OracleImageContractTests: XCTestCase {
    func testParserAcceptsOnlyBoundedPathAndOptionalTitleObjects() throws {
        XCTAssertEqual(try MCPOracleToolService.parseOracleImageRequests(nil), [])
        XCTAssertEqual(try MCPOracleToolService.parseOracleImageRequests(.array([])), [])

        let parsed = try MCPOracleToolService.parseOracleImageRequests(.array([
            .object([
                "path": .string("  /workspace/diagram.png  "),
                "title": .string("  Architecture  ")
            ]),
            .object(["path": .string("/workspace/photo.jpg")])
        ]))

        XCTAssertEqual(parsed, [
            .init(index: 0, path: "  /workspace/diagram.png  ", title: "Architecture"),
            .init(index: 1, path: "/workspace/photo.jpg", title: nil)
        ])
    }

    func testParserRejectsOversizedAndExpandedAttachmentShapes() {
        XCTAssertThrowsError(try MCPOracleToolService.parseOracleImageRequests(.array([
            .object(["path": .string("/workspace/image.png"), "_meta": .string("ignored")])
        ])))
        XCTAssertThrowsError(try MCPOracleToolService.parseOracleImageRequests(.array(
            (0 ... 10).map { .object(["path": .string("/workspace/\($0).png")]) }
        )))
        XCTAssertThrowsError(try MCPOracleToolService.parseOracleImageRequests(.array([
            .object([
                "path": .string("/workspace/image.png"),
                "url": .string("https://example.com/image.png")
            ])
        ])))
        XCTAssertThrowsError(try MCPOracleToolService.parseOracleImageRequests(.array([
            .object([
                "path": .string("/workspace/image.png"),
                "title": .string(String(repeating: "x", count: 201))
            ])
        ])))
    }

    func testAskOracleImageDocumentationIsProviderNeutralAndMatchesLimits() throws {
        XCTAssertEqual(OracleImageAttachmentLimits.production.maxCount, 10)
        XCTAssertEqual(OracleImageAttachmentLimits.production.maxBytesPerImage, 20 * 1024 * 1024)
        XCTAssertEqual(OracleImageAttachmentLimits.production.maxTotalBytes, 50 * 1024 * 1024)
        let canonical = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: "ask_oracle"))
        let schema = try XCTUnwrap(canonical.inputSchema.objectValue)
        let properties = try XCTUnwrap(schema["properties"]?.objectValue)
        let canonicalArgument = try XCTUnwrap(properties["images"]?.objectValue?["description"]?.stringValue)
        let headlessDisclaimer = " Requires the app backend; the direct headless backend rejects `images`."
        XCTAssertEqual(canonicalArgument, MCPOracleToolProvider.askOracleImagesArgumentDescription + headlessDisclaimer)
        XCTAssertTrue(canonical.description.contains(MCPOracleToolProvider.askOracleImageUsageDescription + headlessDisclaimer))

        let documentation = [
            MCPOracleToolProvider.askOracleImageUsageDescription,
            MCPOracleToolProvider.askOracleImagesArgumentDescription
        ].joined(separator: " ")

        XCTAssertFalse(documentation.lowercased().contains("anthropic"))
        XCTAssertTrue(documentation.contains("10 images"))
        XCTAssertTrue(documentation.contains("20 MiB each"))
        XCTAssertTrue(documentation.contains("50 MiB total"))
        for description in [
            MCPOracleToolProvider.askOracleImageUsageDescription,
            MCPOracleToolProvider.askOracleImagesArgumentDescription
        ] {
            XCTAssertTrue(description.contains("raw attachment-file bytes before provider encoding"))
            XCTAssertTrue(description.contains("provider or model may impose additional restrictions"))
            XCTAssertTrue(description.contains("do not guarantee full-request or model-context fit"))
        }
        let usage = MCPOracleToolProvider.askOracleImageUsageDescription
        XCTAssertTrue(usage.contains("additional to pre-send text estimates and Context Builder text-selection budgets"))
        XCTAssertTrue(usage.contains("Originals, not transcript thumbnails, are sent to each Oracle lane"))
        XCTAssertTrue(usage.contains("group fan-out multiplies image usage/cost, not any one request's attachment cap"))
        XCTAssertTrue(usage.contains("Provider-reported input totals may already include image usage"))
        XCTAssertTrue(usage.contains("this-turn-only"))
        XCTAssertTrue(usage.contains("continuations do not automatically reattach prior images or send saved thumbnails"))
        XCTAssertTrue(documentation.contains("PNG"))
        XCTAssertTrue(documentation.lowercased().contains("rejected"))

        // Images the user attached to the agent session are accepted at their exact path, so every
        // surface (app tool, canonical/headless definition, path field) must say so.
        for description in [
            MCPOracleToolProvider.askOracleImageUsageDescription,
            MCPOracleToolProvider.askOracleImagesArgumentDescription
        ] {
            XCTAssertTrue(description.contains("image the user attached to this agent session"))
            XCTAssertTrue(description.contains("sibling attachments"))
            XCTAssertTrue(description.contains("arbitrary"))
        }
        let items = try XCTUnwrap(properties["images"]?.objectValue?["items"]?.objectValue)
        let pathDescription = try XCTUnwrap(
            items["properties"]?.objectValue?["path"]?.objectValue?["description"]?.stringValue
        )
        XCTAssertTrue(pathDescription.contains("image attached to this agent session"))
    }

    func testRawImagesAtOracleDispatchAreAnInternalInvariantFailure() {
        XCTAssertNoThrow(try OracleViewModel.validateRawImageDispatchInvariant([
            "message": .string("inspect")
        ]))
        XCTAssertThrowsError(try OracleViewModel.validateRawImageDispatchInvariant([
            "images": .array([.object(["path": .string("/workspace/image.png")])])
        ])) { error in
            guard let toolError = error as? ChatToolError else {
                return XCTFail("Expected ChatToolError, got \(error)")
            }
            XCTAssertEqual(toolError.code, .internalError)
            XCTAssertTrue(toolError.message.contains("must be consumed before Oracle dispatch"))
        }
    }

    func testAskOracleToolArgumentsAreRedactedBeforePersistence() throws {
        let raw = #"{"message":"inspect","images":[{"path":"/Users/secret.png","title":"Secret"}]}"#
        let item = AgentChatItem.toolCall(
            name: "mcp__RepoPromptCE__ask_oracle",
            argsJSON: raw
        )

        let sanitized = try XCTUnwrap(item.toolArgsJSON)
        XCTAssertTrue(sanitized.contains("inspect"))
        XCTAssertFalse(sanitized.contains("images"))
        XCTAssertFalse(sanitized.contains("/Users/secret.png"))
        XCTAssertFalse(try String(decoding: JSONEncoder().encode(item), as: UTF8.self).contains("secret.png"))

        let unrelated = AgentChatItem.toolCall(name: "read_file", argsJSON: raw)
        XCTAssertEqual(unrelated.toolArgsJSON, raw)
    }

    func testMalformedOracleArgumentsFailClosed() {
        // Every malformed or truncated ask_oracle payload fails closed — a partial prefix
        // might yet grow an "images" key, and an impossible prefix may already carry one.
        let malformed = [
            #"{"message":"partial""#,
            #"{"message":"say \"images\": hi""#,
            #"{"message":"\ud83d"#,
            #"{"message":"x","m"#,
            #"{"message":"x",""#,
            #"{"message":"x","ima"#,
            #"{"images":[{"path":"/Users/secret.png""#,
            #"{"\u0069mages":[{"path":"/Users/secret.png""#,
            #"{"i\u006Dages":[{"path":"/Users/secret.png""#,
            #"{"message":"x" "images":[{"path":"/Users/secret.png""#,
            #"{"message":"x" "ima"#,
            #"{"message":1 "images""#,
            #"{"message":"x"}{"images":[]"#,
            #"{"message":"x","other""#,
            // Syntactically impossible nested content still carrying image material.
            #"{"message":["x","images":[{"path":"/Users/secret.png","title":"Secret"#,
            // Complete non-object values cannot carry a top-level images key, but fail
            // closed anyway — tool arguments are always objects.
            #"[{"images":[]}]"#,
            #""images""#
        ]

        for raw in malformed {
            XCTAssertNil(
                AgentToolArgumentPersistencePolicy.sanitizedArgsJSON(
                    toolName: "ask_oracle",
                    argsJSON: raw
                ),
                raw
            )
            XCTAssertEqual(
                AgentToolArgumentPersistencePolicy.sanitizedArgsJSON(
                    toolName: "read_file",
                    argsJSON: raw
                ),
                raw,
                raw
            )
        }
    }

    func testNamespacedAndAliasedOracleToolNamesAreRedacted() throws {
        let raw = #"{"message":"inspect","images":[{"path":"/Users/secret.png"}]}"#
        let oracleNames = [
            "ask_oracle",
            "mcp__RepoPromptCE__ask_oracle",
            "RepoPromptCE__ask_oracle",
            "RepoPromptCE_ask_oracle",
            "functions.ask_oracle",
            "other_server:ask_oracle",
            "mcp__other__ask_oracle"
        ]
        for name in oracleNames {
            let sanitized = try XCTUnwrap(
                AgentToolArgumentPersistencePolicy.sanitizedArgsJSON(toolName: name, argsJSON: raw),
                name
            )
            XCTAssertFalse(sanitized.contains("secret.png"), name)
            XCTAssertTrue(sanitized.contains("inspect"), name)
        }

        // Non-oracle tools keep their arguments untouched.
        let unrelated = #"{"images":[{"path":"/tmp/not-an-oracle-image.png"}]}"#
        for name in ["ask_oracle_extended", "oracle_send", "read_file"] {
            XCTAssertEqual(
                AgentToolArgumentPersistencePolicy.sanitizedArgsJSON(
                    toolName: name,
                    argsJSON: unrelated
                ),
                unrelated,
                name
            )
        }
    }

    func testEscapedImagesKeysAndPersistedItemsAreSanitized() throws {
        let raw = #"{"\u0069mages":[{"path":"/Users/secret.png"}],"message":"inspect"}"#
        let sanitized = try XCTUnwrap(AgentToolArgumentPersistencePolicy.sanitizedArgsJSON(
            toolName: "ask_oracle",
            argsJSON: raw
        ))
        XCTAssertTrue(sanitized.contains("inspect"))
        XCTAssertFalse(sanitized.contains("secret.png"))

        let source = AgentChatItem.toolCall(name: "read_file", argsJSON: raw)
        var persisted = AgentChatItemPersist(from: source, sanitizeToolResults: false)
        persisted.toolName = "mcp__RepoPromptCE__ask_oracle"
        let encoded = try JSONEncoder().encode(persisted)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("secret.png"))
        let decoded = try JSONDecoder().decode(AgentChatItemPersist.self, from: encoded)
        XCTAssertFalse(decoded.toolArgsJSON?.contains("secret.png") == true)
    }

    func testLegacyImageArgumentsAreSanitizedOnDecode() throws {
        let raw = #"{"message":"inspect","images":[{"path":"/Users/legacy-secret.png"}]}"#
        let source = AgentChatItem.toolCall(name: "read_file", argsJSON: raw)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any]
        )
        object["toolName"] = "ask_oracle"
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AgentChatItem.self, from: legacyData)
        XCTAssertFalse(decoded.toolArgsJSON?.contains("legacy-secret") == true)
        XCTAssertFalse(try String(decoding: JSONEncoder().encode(decoded), as: UTF8.self).contains("legacy-secret"))
    }

    func testUnrelatedAndImageFreeArgumentsRoundTripUnchanged() throws {
        let unrelatedRaw = #"{"images":[{"path":"/tmp/not-an-oracle-image.png"}]}"#
        let unrelated = AgentChatItem.toolCall(name: "read_file", argsJSON: unrelatedRaw)
        let unrelatedRoundTrip = try JSONDecoder().decode(
            AgentChatItem.self,
            from: JSONEncoder().encode(unrelated)
        )
        XCTAssertEqual(unrelatedRoundTrip.toolArgsJSON, unrelatedRaw)

        let oracleRaw = #"{"message":"hi","mode":"plan"}"#
        let oracle = AgentChatItem.toolCall(name: "ask_oracle", argsJSON: oracleRaw)
        let oracleRoundTrip = try JSONDecoder().decode(
            AgentChatItem.self,
            from: JSONEncoder().encode(oracle)
        )
        XCTAssertEqual(oracleRoundTrip.toolArgsJSON, oracleRaw)
    }

    func testLateToolArgumentsRedactImagesAndFailClosed() throws {
        let raw = #"{"message":"inspect","images":[{"path":"/Users/late-secret.png"}]}"#
        var item = AgentChatItem.toolCall(name: "read_file", argsJSON: nil)
        item.toolName = "ask_oracle"
        item.toolArgsJSON = raw

        let sanitized = try XCTUnwrap(item.toolArgsJSON)
        XCTAssertFalse(sanitized.contains("images"))
        XCTAssertFalse(sanitized.contains("late-secret"))

        item.toolArgsJSON = #"{"message":"partial"#
        XCTAssertNil(item.toolArgsJSON)
        item.toolArgsJSON = #"{"images":[{"path":"/Users/partial-secret.png"#
        XCTAssertNil(item.toolArgsJSON)
    }
}

final class OracleGroupDeliveryContractTests: XCTestCase {
    func testContractIsSilentForSingleLaneAndDescribesEveryLaneOtherwise() throws {
        let single = [OracleGroupDeliveryContract.Lane(laneIndex: 0, modelID: "m", chatID: "chat-0", status: "Completed", response: "x")]
        XCTAssertNil(OracleGroupDeliveryContract.preamble(lanes: single))
        XCTAssertNil(OracleGroupDeliveryContract.endMarker(laneCount: 1))
        XCTAssertNil(OracleGroupDeliveryContract.followUpReminder(laneCount: 1))
        XCTAssertNil(OracleGroupDeliveryContract.exportReadingRequirement(laneCount: 1))

        let preamble = OracleGroupDeliveryContract.preamble(lanes: [
            .init(laneIndex: 2, modelID: nil, chatID: "chat-2", status: "Failed", response: nil),
            .init(laneIndex: 1, modelID: "model-b", chatID: "chat-1", status: "Failed", response: " \n", partialResponse: "part\r\nial\n"),
            .init(laneIndex: 0, modelID: "model-a", chatID: "chat-0", status: "Completed", response: "one\ntwo\nthree\n")
        ])
        let text = try XCTUnwrap(preamble)
        XCTAssertTrue(text.contains(
            "3 independent answers to the same request follow. Lane order is not a ranking; "
                + "the first lane supplies the top-level continuation handle."
        ), text)
        XCTAssertFalse(text.contains("re-runs every lane"), text)
        XCTAssertFalse(text.contains("continues only the addressed Oracle lane"), text)
        XCTAssertTrue(text.contains("Read every lane through the end-of-group marker (`End of Oracle group: 3 lanes above.`)"), text)
        XCTAssertTrue(text.contains("read-only `oracle_chat_log` with that lane's chat ID"), text)
        XCTAssertTrue(text.contains("Do not start a follow-up just to retrieve prior text."), text)
        XCTAssertTrue(text.contains(
            "Begin your answer with `**Oracle reconciliation**`, "
                + "state how many lanes completed and name any that did not."
        ), text)
        XCTAssertTrue(text.contains("exactly one disposition: `accepted`, `rejected`, or `unresolved`."), text)
        XCTAssertTrue(text.hasSuffix("""
        Lanes (3):
        - Oracle — `model-a` — Completed — chat ID `chat-0`
        - Oracle 2 — `model-b` — Failed (partial) — chat ID `chat-1`
        - Oracle 3 — model unspecified — Failed — chat ID `chat-2`
        """), text)
    }

    func testPreambleKeepsCompleteInventoryGuidanceCompactAcrossSupportedLaneCounts() throws {
        for count in 2 ... OracleRosterContract.maximumCount {
            let lanes = (0 ..< count).map { index in
                OracleGroupDeliveryContract.Lane(
                    laneIndex: index, modelID: "model-\(index)", chatID: "chat-\(index)", status: "Completed", response: "answer"
                )
            }
            let text = try XCTUnwrap(OracleGroupDeliveryContract.preamble(lanes: lanes))
            XCTAssertTrue(text.contains(
                "Before synthesizing, inventory every material claim from every lane, including single-lane claims."
            ), text)
            XCTAssertTrue(text.contains("exactly one disposition"), text)
            XCTAssertTrue(text.contains("Never silently omit an item."), text)
            XCTAssertTrue(text.contains("\(count) independent answers to the same request follow."), text)
            XCTAssertTrue(try text.contains("`\(XCTUnwrap(OracleGroupDeliveryContract.endMarker(laneCount: count)))`"), text)

            let lines = text.components(separatedBy: "\n")
            let manifestRows = lines.filter { $0.hasPrefix("- Oracle") }
            XCTAssertEqual(manifestRows, (0 ..< count).map { index in
                let label = index == 0 ? "Oracle" : "Oracle \(index + 1)"
                return "- \(label) — `model-\(index)` — Completed — chat ID `chat-\(index)`"
            }, text)
            let guidance = lines.filter { !$0.hasPrefix("- Oracle") }.joined(separator: "\n")
            XCTAssertLessThanOrEqual(guidance.utf8.count, 1400, "\(count) lanes: \(guidance.utf8.count) guidance bytes")
        }
    }

    func testLaneIsPartialOnlyWhenResponseIsBlankAndPartialIsNot() {
        let cases: [(response: String?, partial: String?, expected: Bool)] = [
            ("answer", nil, false),
            ("answer", "partial", false),
            (nil, "partial", true),
            (" \n\t", "partial", true),
            (nil, nil, false),
            (" \n", " \r\n", false)
        ]
        for (response, partial, expected) in cases {
            let lane = OracleGroupDeliveryContract.Lane(
                laneIndex: 0, modelID: nil, chatID: "chat-0", status: "Failed", response: response, partialResponse: partial
            )
            XCTAssertEqual(lane.isPartial, expected, "response: \(String(describing: response)), partial: \(String(describing: partial))")
        }
    }

    func testInlineGroupPutsGuidanceBeforeLanesAndEndMarkerLast() throws {
        let fields = try groupFields(lanes: [
            lane(index: 0, response: "primary answer"),
            lane(index: 1, response: "adviser answer\nsecond line")
        ], warnings: [OracleGroupWarning(code: "slow_lane", message: "Lane was slow")])
        let text = joinedText(ToolOutputFormatter.formatAskOracle(args: [:], value: .object(fields), emitResources: false))

        let guidance = try XCTUnwrap(text.range(of: "**Reconciling these Oracle lanes**"))
        let firstLane = try XCTUnwrap(text.range(of: "\n### Oracle\n"))
        let warning = try XCTUnwrap(text.range(of: "Warning [slow_lane]"))
        XCTAssertLessThan(guidance.lowerBound, firstLane.lowerBound)
        XCTAssertLessThan(firstLane.lowerBound, warning.lowerBound)
        XCTAssertTrue(text.contains("- Oracle 2 — `model-1` — Completed — chat ID `chat-1`\n"), text)
        XCTAssertTrue(text.hasSuffix("\n\nEnd of Oracle group: 2 lanes above.\n"), text)
        XCTAssertEqual(
            text.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init),
            "End of Oracle group: 2 lanes above."
        )
        XCTAssertFalse(text.localizedCaseInsensitiveContains("synthesis"))
    }

    func testGroupedAskOracleEndMarkerStaysOnItsOwnLineWhenBlocksAreConcatenated() throws {
        var fields = try groupFields(lanes: [
            lane(index: 0, response: "primary answer"),
            lane(index: 1, response: "adviser answer")
        ])
        fields["oracle_export_path"] = .string("/tmp/prompt-exports/oracle.md")
        let blocks = texts(ToolOutputFormatter.formatAskOracle(args: [:], value: .object(fields), emitResources: false))
        XCTAssertGreaterThanOrEqual(blocks.count, 2)

        let concatenated = blocks.joined()
        XCTAssertTrue(
            concatenated.contains("\nEnd of Oracle group: 2 lanes above.\n### Oracle export"),
            concatenated
        )
        XCTAssertFalse(concatenated.contains("lanes above.###"), concatenated)
    }

    func testGroupedExportFileFramesLanesWithManifestAndEndMarker() throws {
        let group = try OracleGroupResult(
            groupID: OracleGroupID(rawValue: UUID()),
            status: .partialFailure,
            oracleResults: [
                lane(index: 0, response: "primary answer"),
                OracleLaneResult(
                    laneIndex: 1,
                    chatID: "chat-1",
                    providerID: "provider-1",
                    modelID: "model-1",
                    status: .failed,
                    error: OracleLaneError(code: "provider_failed", message: "failed", partialResponse: "partial")
                )
            ]
        )
        let markdown = AgentOracleExport.oracleMarkdown(request: OracleExportRequest(
            sourceTool: "ask_oracle",
            mode: "review",
            message: "Review it",
            chatID: "chat-0",
            response: "primary answer",
            groupResult: group
        ))

        XCTAssertLessThan(
            try XCTUnwrap(markdown.range(of: "**Reconciling these Oracle lanes**")).lowerBound,
            try XCTUnwrap(markdown.range(of: "## Oracle results")).lowerBound
        )
        XCTAssertTrue(markdown.contains("- Oracle 2 — `model-1` — failed (partial) — chat ID `chat-1`"), markdown)
        XCTAssertTrue(markdown.hasSuffix("\n\nEnd of Oracle group: 2 lanes above."), markdown)
    }

    func testExportInstructionAddsReadingRequirementOnlyForGroups() {
        let path = "/tmp/prompt-exports/oracle \"review\".md"
        let single = AgentOracleExport.instruction(path: path)
        XCTAssertEqual(AgentOracleExport.instruction(path: path, oracleLaneCount: 1), single)
        XCTAssertFalse(single.contains("End of Oracle group"))

        let grouped = AgentOracleExport.instruction(path: path, oracleLaneCount: 3)
        XCTAssertTrue(grouped.hasPrefix(single + " "), grouped)
        XCTAssertTrue(grouped.contains("The file contains 3 independent Oracle lanes"), grouped)
        XCTAssertTrue(grouped.contains("read through the \"End of Oracle group\" marker"), grouped)
    }

    func testCapturedGuidanceSurvivesReplyRoundTripAndNestedPlanReviewDelivery() throws {
        let group = try OracleGroupResult(
            groupID: OracleGroupID(rawValue: UUID()), status: .completed,
            oracleResults: [lane(index: 0, response: "primary"), lane(index: 1, response: "additional")]
        )
        let guidance = "  Compare evidence.\nPreserve disagreements verbatim.  "
        let reply = ChatSendReply(
            chatId: UUID(), shortId: "chat-0", mode: "plan", response: "primary", errors: nil,
            oracleGroup: ContextBuilderOracleGroupReply(result: group, reconciliationGuidance: guidance)
        )
        let roundTrip = try JSONDecoder().decode(ChatSendReply.self, from: JSONEncoder().encode(reply))
        let value = roundTrip.toMCPValue()
        XCTAssertEqual(value.objectValue?["oracle_reconciliation_guidance"]?.stringValue, guidance)
        for blocks in [
            ToolOutputFormatter.formatAskOracle(args: [:], value: value, emitResources: false),
            ToolOutputFormatter.formatChatSend(args: [:], value: value, emitResources: false),
            ToolOutputFormatter.formatDiscoverContext(value: .object(["plan": value])),
            ToolOutputFormatter.formatDiscoverContext(value: .object(["review": value]))
        ] {
            let text = joinedText(blocks)
            XCTAssertTrue(text.contains(guidance), text)
            XCTAssertFalse(text.contains(OracleGroupDeliveryContract.defaultReconciliationGuidance), text)
            XCTAssertTrue(text.contains("Lanes (2):"), text)
            XCTAssertTrue(text.contains("End of Oracle group: 2 lanes above."), text)
        }

        let legacyFields = OracleGroupMCPCodec.groupFields(group)
        let defaultText = joinedText(ToolOutputFormatter.formatChatSend(args: [:], value: .object(legacyFields), emitResources: false))
        for override in [nil, " \n\t"] as [String?] {
            let fields = ContextBuilderOracleGroupReply(result: group, reconciliationGuidance: override).toMCPFields()
            XCTAssertEqual(fields, legacyFields)
        }
        let explicitDefault = OracleGroupDeliveryContract.defaultReconciliationGuidance
        let explicitReply = ContextBuilderOracleGroupReply(result: group, reconciliationGuidance: explicitDefault)
        let explicitRoundTrip = try JSONDecoder().decode(ContextBuilderOracleGroupReply.self, from: JSONEncoder().encode(explicitReply))
        XCTAssertEqual(explicitRoundTrip.toMCPFields()["oracle_reconciliation_guidance"]?.stringValue, explicitDefault)
        XCTAssertEqual(joinedText(ToolOutputFormatter.formatChatSend(args: [:], value: .object(explicitRoundTrip.toMCPFields()), emitResources: false)), defaultText)
        for raw in [Value.null, .string(" \n")] {
            var fields = legacyFields
            fields["oracle_reconciliation_guidance"] = raw
            XCTAssertEqual(joinedText(ToolOutputFormatter.formatChatSend(args: [:], value: .object(fields), emitResources: false)), defaultText)
        }
        let single = ChatSendReply(chatId: UUID(), shortId: "single", mode: "chat", response: "single answer", errors: nil)
        XCTAssertEqual(single.toMCPValue(), .object([
            "chat_id": .string("single"), "mode": .string("chat"), "response": .string("single answer")
        ]))
    }

    func testGroupedAppFollowUpHintIsLaneLocalAndSingleLaneHintIsUnchanged() {
        let continuation = "Continue this plan conversation with ask_oracle(chat_id: \"chat-0\", new_chat: false)"
        for count in [nil, 1] as [Int?] {
            XCTAssertEqual(
                MCPContextBuilderToolProvider.generatedResponseFollowUpHint(modeLabel: "plan", chatID: "chat-0", oracleCount: count),
                continuation
            )
        }

        let grouped = MCPContextBuilderToolProvider.generatedResponseFollowUpHint(modeLabel: "plan", chatID: "chat-0", oracleCount: 3)
        XCTAssertTrue(grouped.hasPrefix("The 3 Oracle lanes above are independent answers"), grouped)
        XCTAssertTrue(grouped.contains("This explicit chat_id continues only the addressed Oracle lane; other lanes are not re-run."), grouped)
        XCTAssertTrue(grouped.hasSuffix("\n\nOptional later follow-up: " + continuation), grouped)
    }

    func testTerminalTicketHeaderPreservesPayloadBlocksPartialResultsAndRawBypass() throws {
        let group = try OracleGroupMCPCodec.groupFields(OracleGroupResult(
            groupID: OracleGroupID(rawValue: UUID()), status: .partialFailure, oracleResults: [
                lane(index: 0, response: "Paid primary answer"),
                OracleLaneResult(
                    laneIndex: 1, chatID: "chat-1", providerID: "provider-1", modelID: "model-1",
                    status: .failed, error: OracleLaneError(
                        code: "provider_error", message: "Provider stopped", partialResponse: "Paid partial answer"
                    )
                )
            ]
        ))
        let id = UUID().uuidString
        for tool in ["ask_oracle", "oracle_send", "context_builder"] {
            var payload = tool == "context_builder" ? [
                "status": Value.string("success"), "prompt": .string("Frozen prompt"),
                "response_type": .string("review"), "review": .object(group),
                "oracle_export_error": .string("Oracle export cancelled; recover settled results.")
            ] : group
            payload["oracle_export_path"] = .string("/tmp/oracle.md")
            payload["diffs"] = .array([.object(["path": .string("file.swift"), "patch": .string("+ retained patch")])])
            for status in ["completed", "cancelled"] {
                var ticket = payload
                ticket["job_id"] = .string(id)
                ticket["job"] = .object(["id": .string(id), "status": .string(status)])
                for resources in [false, true] {
                    let expected = ToolOutputFormatter.buildContentBlocks(
                        toolName: tool, args: [:], result: .object(payload), emitResources: resources
                    )
                    let blocks = ToolOutputFormatter.buildContentBlocks(
                        toolName: tool, args: [:], result: .object(ticket), emitResources: resources
                    )
                    XCTAssertEqual(texts(Array(blocks.prefix(1))), [
                        "## Long-running job\n- **Job ID**: `\(id)`\n- **Status**: \(status)\n\n"
                    ])
                    XCTAssertEqual(String(describing: Array(blocks.dropFirst())), String(describing: expected))
                    let text = joinedText(blocks)
                    XCTAssertTrue(text.contains("Paid primary answer"), text)
                    XCTAssertTrue(text.contains("Paid partial answer"), text)
                    if tool == "context_builder" {
                        XCTAssertTrue(text.contains("Oracle export cancelled; recover settled results."), text)
                    } else if resources {
                        XCTAssertTrue(text.contains("Patch for `file.swift`"), text)
                    }
                    let raw = ToolOutputFormatter.buildContentBlocks(
                        toolName: tool, args: ["_rawJSON": .bool(true)], result: .object(ticket), emitResources: resources
                    )
                    XCTAssertEqual(texts(raw), [ToolOutputFormatter.rawJSONString(.object(ticket))])
                }
            }
        }
    }

    func testNonTerminalAndResultlessTicketsRenderExactSummaries() {
        let id = UUID().uuidString
        let context = UUID().uuidString
        let next = "Call ask_oracle op=wait or poll with job_id=\(id)."
        // Nonterminal snapshots must never render result bodies, even when unexpected fields are present.
        let leaked: [String: Value] = ["response": .string("LEAKED_RESPONSE_BODY"), "prompt": .string("LEAKED_PROMPT_BODY")]
        let cases: [(status: String, extra: [String: Value], payload: [String: Value], expected: String)] = [
            (
                "running", ["phase": .string("discovery"), "context_id": .string(context), "chat_id": .string("chat-9")],
                leaked.merging(["next_action": .string(next)]) { _, new in new },
                "## Long-running job\n- **Job ID**: `\(id)`\n- **Status**: running\n- **Phase**: discovery\n- **Context ID**: `\(context)`\n- **Oracle chat**: `chat-9`\n\(next)"
            ),
            (
                "cancelling", ["message": .string("Cancellation requested")],
                leaked.merging(["next_action": .string(next)]) { _, new in new },
                "## Long-running job\n- **Job ID**: `\(id)`\n- **Status**: cancelling\nCancellation requested\n\(next)"
            ),
            (
                "failed", ["error": .object(["code": .string("failed"), "message": .string("Provider stopped")])],
                [:],
                "## Long-running job\n- **Job ID**: `\(id)`\n- **Status**: failed\nProvider stopped"
            ),
            (
                "expired", ["message": .string("Ticket expired on app restart")],
                [:],
                "## Long-running job\n- **Job ID**: `\(id)`\n- **Status**: expired\nTicket expired on app restart"
            )
        ]
        for tool in ["ask_oracle", "oracle_send", "context_builder"] {
            for item in cases {
                var job: [String: Value] = ["id": .string(id), "status": .string(item.status)]
                job.merge(item.extra) { _, new in new }
                var ticket = item.payload
                ticket["job_id"] = .string(id)
                ticket["job"] = .object(job)
                let blocks = ToolOutputFormatter.buildContentBlocks(
                    toolName: tool, args: [:], result: .object(ticket), emitResources: false
                )
                XCTAssertEqual(texts(blocks), [item.expected], "\(tool) \(item.status)")
            }
        }
    }

    func testTerminalTicketPayloadRendersAfterHeaderThatKeepsRecoveryText() {
        let id = UUID().uuidString
        let answered: [String: Value] = ["chat_id": .string("single"), "mode": .string("chat"), "response": .string("Single settled answer")]
        // A settled singleton can carry only recovery/error fields (no response, oracle_results, or prompt).
        let errorsOnly: [String: Value] = ["chat_id": .string("single"), "errors": .array([.string("Provider stopped mid-reply")])]
        let cases: [(status: String, job: [String: Value], recovery: [String])] = [
            ("completed", [:], []),
            ("cancelled", ["message": .string("Cancelled by owner")], ["Cancelled by owner"]),
            ("failed", ["error": .object(["code": .string("failed"), "message": .string("Provider stopped")])], ["Provider stopped"]),
            ("expired", ["message": .string("Ticket expired")], ["Ticket expired"])
        ]
        for tool in ["ask_oracle", "oracle_send"] {
            for reply in [answered, errorsOnly] {
                for item in cases {
                    var job = item.job
                    job["id"] = .string(id)
                    job["status"] = .string(item.status)
                    var ticket = reply
                    ticket["job_id"] = .string(id)
                    ticket["job"] = .object(job)
                    ticket["next_action"] = .string("Recover with chat_id single.")
                    let expected = ToolOutputFormatter.buildContentBlocks(
                        toolName: tool, args: [:], result: .object(reply), emitResources: false
                    )
                    let blocks = ToolOutputFormatter.buildContentBlocks(
                        toolName: tool, args: [:], result: .object(ticket), emitResources: false
                    )
                    let header = (
                        ["## Long-running job", "- **Job ID**: `\(id)`", "- **Status**: \(item.status)"]
                            + item.recovery + ["Recover with chat_id single."]
                    ).joined(separator: "\n") + "\n\n"
                    XCTAssertEqual(texts(Array(blocks.prefix(1))), [header], "\(tool) \(item.status)")
                    XCTAssertEqual(texts(Array(blocks.dropFirst())), texts(expected), "\(tool) \(item.status)")
                }
            }
            let errorsText = joinedText(ToolOutputFormatter.buildContentBlocks(
                toolName: tool, args: [:],
                result: .object(errorsOnly.merging(["job_id": .string(id), "job": .object(["id": .string(id), "status": .string("completed")])]) { _, new in new }),
                emitResources: false
            ))
            XCTAssertTrue(errorsText.contains("### Errors\n- Provider stopped mid-reply"), errorsText)
        }
    }

    func testTicketBranchIgnoresMismatchedIDsAndForeignTools() {
        let id = UUID().uuidString
        let reply: [String: Value] = ["chat_id": .string("single"), "mode": .string("chat"), "response": .string("Plain answer")]
        var mismatched = reply
        mismatched["job_id"] = .string(id)
        mismatched["job"] = .object(["id": .string(UUID().uuidString), "status": .string("completed")])
        var foreign = reply
        foreign["job_id"] = .string(id)
        foreign["job"] = .object(["id": .string(id), "status": .string("running")])

        let mismatchedText = joinedText(ToolOutputFormatter.buildContentBlocks(
            toolName: "ask_oracle", args: [:], result: .object(mismatched), emitResources: false
        ))
        XCTAssertFalse(mismatchedText.contains("Long-running job"), mismatchedText)
        XCTAssertTrue(mismatchedText.contains("Plain answer"), mismatchedText)

        let foreignText = joinedText(ToolOutputFormatter.buildContentBlocks(
            toolName: "oracle_chat_log", args: [:], result: .object(foreign), emitResources: false
        ))
        XCTAssertFalse(foreignText.contains("Long-running job"), foreignText)
    }

    func testExportNoticeRendersOnceForSingleAndGroupedOracleReplies() throws {
        let notice = "Oracle export failed; output may remain. Recover the settled result using the returned chat IDs."
        let section = "### Oracle export notice\n- \(notice)\n"
        let id = UUID().uuidString
        let single: [String: Value] = [
            "chat_id": .string("single"), "mode": .string("chat"), "response": .string("Paid single answer"),
            "oracle_export_error": .string(notice)
        ]
        var grouped = try groupFields(lanes: [lane(index: 0, response: "primary answer"), lane(index: 1, response: "adviser answer")])
        grouped["oracle_export_error"] = .string(notice)
        for tool in ["ask_oracle", "oracle_send"] {
            for reply in [single, grouped] {
                var ticket = reply
                ticket["job_id"] = .string(id)
                ticket["job"] = .object(["id": .string(id), "status": .string("completed")])
                for value in [reply, ticket] {
                    let text = texts(ToolOutputFormatter.buildContentBlocks(
                        toolName: tool, args: [:], result: .object(value), emitResources: false
                    )).joined()
                    XCTAssertEqual(text.components(separatedBy: "### Oracle export notice").count, 2, "\(tool): \(text)")
                    XCTAssertTrue(text.contains(section), text)
                    XCTAssertFalse(text.contains("### Oracle export\n"), "No handoff without a path: \(text)")
                    XCTAssertFalse(text.contains("❌"), "An export notice is not a generation failure: \(text)")
                }
            }
            let singleText = texts(ToolOutputFormatter.buildContentBlocks(
                toolName: tool, args: [:], result: .object(single), emitResources: false
            )).joined()
            XCTAssertTrue(singleText.contains("### Response\nPaid single answer\n### Oracle export notice"), singleText)

            // Grouped delivery keeps its lanes and end-marker line, then the notice, then a handoff that
            // can legitimately accompany it.
            var withPath = grouped
            withPath["oracle_export_path"] = .string("/tmp/prompt-exports/oracle.md")
            let groupedText = texts(ToolOutputFormatter.buildContentBlocks(
                toolName: tool, args: [:], result: .object(withPath), emitResources: false
            )).joined()
            XCTAssertLessThan(
                try XCTUnwrap(groupedText.range(of: "primary answer")).lowerBound,
                try XCTUnwrap(groupedText.range(of: "adviser answer")).lowerBound
            )
            XCTAssertTrue(
                groupedText.contains("\nEnd of Oracle group: 2 lanes above.\n\n\(section)### Oracle export\n- Path: `/tmp/prompt-exports/oracle.md`"),
                groupedText
            )

            for blankNotice in [Value.string(" \n"), .null] {
                var blank = single
                blank["oracle_export_error"] = blankNotice
                let blankText = joinedText(ToolOutputFormatter.buildContentBlocks(
                    toolName: tool, args: [:], result: .object(blank), emitResources: false
                ))
                XCTAssertFalse(blankText.contains("Oracle export notice"), blankText)
            }
        }
    }

    // MARK: - Helpers

    private func lane(index: Int, response: String) throws -> OracleLaneResult {
        try OracleLaneResult(
            laneIndex: index,
            chatID: "chat-\(index)",
            providerID: "provider-\(index)",
            modelID: "model-\(index)",
            status: .completed,
            response: response
        )
    }

    private func groupFields(lanes: [OracleLaneResult], warnings: [OracleGroupWarning] = []) throws -> [String: Value] {
        let result = try OracleGroupResult(
            groupID: OracleGroupID(rawValue: UUID()),
            status: warnings.isEmpty ? .completed : .partialFailure,
            oracleResults: lanes,
            warnings: warnings
        )
        return ContextBuilderOracleGroupReply(result: result).toMCPFields()
    }

    private func texts(_ blocks: [MCP.Tool.Content]) -> [String] {
        blocks.compactMap { block -> String? in
            guard case let .text(text, _, _) = block else { return nil }
            return text
        }
    }

    private func joinedText(_ blocks: [MCP.Tool.Content]) -> String {
        texts(blocks).joined(separator: "\n")
    }
}

final class MCPToolHeartbeatTests: XCTestCase {
    private enum OperationFailure: Error { case expected }

    private actor HeartbeatGate {
        private var entered = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?
        private(set) var exited = false

        func send() async {
            guard !entered else { return }
            entered = true
            entryWaiters.forEach { $0.resume() }
            entryWaiters.removeAll()
            await withCheckedContinuation { releaseContinuation = $0 }
            exited = true
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    func testSuccessAndFailureDrainInFlightHeartbeatBeforeReturning() async {
        for shouldThrow in [false, true] {
            let gate = HeartbeatGate()
            let operationFinished = expectation(description: "operation finished")
            let returnedBeforeCleanup = expectation(description: "request returned before heartbeat cleanup")
            returnedBeforeCleanup.isInverted = true
            let task = Task { () -> Result<String, Error> in
                let outcome: Result<String, Error>
                do {
                    let value = try await MCPToolHeartbeat.run(interval: .milliseconds(1), heartbeat: { await gate.send() }) {
                        await gate.waitUntilEntered()
                        operationFinished.fulfill()
                        if shouldThrow { throw OperationFailure.expected }
                        return "settled"
                    }
                    outcome = .success(value)
                } catch {
                    outcome = .failure(error)
                }
                if await !gate.exited { returnedBeforeCleanup.fulfill() }
                return outcome
            }
            await fulfillment(of: [operationFinished], timeout: 2)
            await fulfillment(of: [returnedBeforeCleanup], timeout: 0.1)
            await gate.release()
            let outcome = await task.value
            let heartbeatExited = await gate.exited
            XCTAssertTrue(heartbeatExited)
            switch outcome {
            case let .success(value):
                XCTAssertFalse(shouldThrow)
                XCTAssertEqual(value, "settled")
            case let .failure(error):
                XCTAssertTrue(shouldThrow)
                XCTAssertTrue(error is OperationFailure)
            }
        }
    }

    func testCancellationPreservesSettledPartialOperationResult() async throws {
        let entered = expectation(description: "operation entered")
        let task = Task {
            try await MCPToolHeartbeat.run(interval: .milliseconds(1), heartbeat: {}) {
                entered.fulfill()
                do {
                    try await Task.sleep(for: .seconds(60))
                    XCTFail("Expected cancellation")
                } catch is CancellationError {
                    // Oracle settles its completed and cancelled lanes before returning.
                }
                return "partial_failure"
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        let result = try await task.value
        XCTAssertEqual(result, "partial_failure")
    }

    func testCancellationStillPropagatesWhenOperationThrows() async throws {
        let entered = expectation(description: "operation entered")
        let task = Task {
            try await MCPToolHeartbeat.run(interval: .milliseconds(1), heartbeat: {}) {
                entered.fulfill()
                try await Task.sleep(for: .seconds(60))
                return "unexpected"
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Operation cancellation must not be suppressed")
        } catch is CancellationError {
            // Expected.
        }
    }
}

#if DEBUG
    @MainActor
    final class LongRunningJobTests: XCTestCase {
        private func owner(tabID: UUID = UUID()) -> DomainLongRunningJobStore.Owner {
            .init(windowID: 987_654, workspaceID: UUID(), tabID: tabID, sessionID: nil, runID: nil)
        }

        func testDetachedWorkerSurvivesObserverCancellationAndDeliversExactPayloadOnce() async throws {
            let center = MCPLongRunningJobCenter()
            let gate = AsyncStream<Void>.makeStream()
            var calls = 0
            let payload: Value = .object(["status": .string("partial_failure"), "response": .string("  unchanged\n"), "extension_field": .int(73)])
            let snapshot = try await center.start(tool: "oracle_send", owner: owner()) { _ in
                calls += 1
                for await _ in gate.stream {
                    break
                }
                return payload
            }
            let waiter = Task { await center.store.wait(id: snapshot.id, timeout: 60) }
            waiter.cancel()
            _ = await waiter.value
            let running = await center.store.snapshot(id: snapshot.id)
            XCTAssertEqual(running?.status, .running)
            gate.continuation.yield(())
            gate.continuation.finish()
            let terminal = await center.store.wait(id: snapshot.id, timeout: 5)
            XCTAssertEqual(terminal?.result, payload)
            XCTAssertEqual(terminal?.status, .completed)
            let readAgain = await center.store.wait(id: snapshot.id, timeout: 0)
            XCTAssertEqual(readAgain?.result, payload)
            XCTAssertEqual(calls, 1)
            let fields = try XCTUnwrap(terminal?.value().objectValue)
            XCTAssertEqual(fields["status"], .string("partial_failure"))
            XCTAssertEqual(fields["response"], .string("  unchanged\n"))
            XCTAssertEqual(fields["extension_field"], .int(73))
        }

        func testWaitTimeoutIsNotWorkerTimeoutAndContextReservationLastsThroughCancellationDrain() async throws {
            let center = MCPLongRunningJobCenter()
            let target = owner()
            let gate = AsyncStream<Void>.makeStream()
            let snapshot = try await center.start(tool: "oracle_send", owner: target) { _ in
                for await _ in gate.stream {
                    break
                }
                return .object(["response": .string("settled despite cancellation")])
            }
            let timedOut = await center.store.wait(id: snapshot.id, timeout: 0.001)
            XCTAssertEqual(timedOut?.status, .running)
            do {
                _ = try await center.start(tool: "ask_oracle", owner: target) { _ in .null }
                XCTFail("Expected busy context")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("context_job_busy"))
                XCTAssertTrue(error.localizedDescription.contains(snapshot.id.uuidString))
                XCTAssertTrue(error.localizedDescription.contains(target.tabID.uuidString))
            }
            center.cancel(id: snapshot.id)
            gate.continuation.finish()
            let terminal = await center.store.wait(id: snapshot.id, timeout: 5)
            XCTAssertTrue(terminal?.isTerminal == true)
            _ = try await center.start(tool: "oracle_send", owner: target) { _ in .object([:]) }
        }

        func testCancellationAcknowledgementRetainsPartialLaneCoverage() async throws {
            let center = MCPLongRunningJobCenter()
            let gate = AsyncStream<Void>.makeStream()
            let result = Value.object(["status": .string("partial_failure"), "oracle_results": .array([.object(["lane_index": .int(0), "status": .string("completed"), "response": .string("paid result")]), .object(["lane_index": .int(1), "status": .string("cancelled")])])])
            let snapshot = try await center.start(tool: "oracle_send", owner: owner()) { _ in
                for await _ in gate.stream {
                    break
                }
                return result
            }
            await Task.yield()
            center.cancel(id: snapshot.id)
            gate.continuation.finish()
            let terminal = await center.store.wait(id: snapshot.id, timeout: 5)
            XCTAssertEqual(terminal?.status, .cancelled)
            XCTAssertEqual(terminal?.result, result)
            XCTAssertEqual(terminal?.value().objectValue?["status"], .string("partial_failure"))
        }

        func testControlRejectsWrongKindAndOwnerBeforeCancellation() async throws {
            let center = MCPLongRunningJobCenter()
            let target = owner()
            let gate = AsyncStream<Void>.makeStream()
            let snapshot = try await center.start(tool: "oracle_send", owner: target) { _ in
                for await _ in gate.stream {
                    break
                }
                return .object([:])
            }
            do {
                _ = try await center.control(operation: .poll(snapshot.id), tool: "ask_oracle", authorize: { _ in })
                XCTFail("Expected kind mismatch")
            } catch { XCTAssertTrue(error.localizedDescription.contains("different tool")) }
            do {
                _ = try await center.control(operation: .cancel(snapshot.id), tool: "oracle_send", authorize: { _ in throw MCPError.invalidParams("wrong owner") })
                XCTFail("Expected authorization failure")
            } catch { XCTAssertTrue(error.localizedDescription.contains("wrong owner")) }
            let stillRunning = await center.store.snapshot(id: snapshot.id)
            XCTAssertEqual(stillRunning?.status, .running)
            gate.continuation.finish()
            _ = await center.store.wait(id: snapshot.id, timeout: 5)
            let expired = try await center.control(operation: .poll(UUID()), tool: "oracle_send", authorize: { _ in XCTFail("Unknown job has no owner") })
            XCTAssertEqual(expired.objectValue?["job"]?.objectValue?["status"], .string("expired"))
        }

        func testLaneSnapshotsNeverExposeEarlyBodiesAndIgnoreOlderEvents() async throws {
            let store = DomainLongRunningJobStore()
            let id = UUID()
            _ = try await store.register(id: id, tool: "oracle_send", owner: owner())
            let progress = MCPLongRunningJobProgress(id: id, store: store)
            let group = OracleGroupID(rawValue: UUID())
            let turn = OracleTurnID(rawValue: UUID())
            let member = try OracleGroupMember(laneID: OracleLaneID(index: 0), publicChatID: "lane-0", model: OracleModelReference(modelID: "model"))
            await progress.prepared(group: group, turn: turn, members: [member])
            await progress.progress(.init(kind: .laneStarted, groupID: group, turnID: turn, laneID: member.laneID, sequence: 0))
            await progress.progress(.init(kind: .laneDelta, groupID: group, turnID: turn, laneID: member.laneID, sequence: 1, text: "secret early response"))
            await progress.progress(.init(kind: .laneSettled, groupID: group, turnID: turn, laneID: member.laneID, sequence: 2, text: "completed"))
            await progress.progress(.init(kind: .laneStarted, groupID: group, turnID: turn, laneID: member.laneID, sequence: 0))
            let snapshot = await store.snapshot(id: id)
            let json = try ToolOutputFormatter.rawJSONString(XCTUnwrap(snapshot?.value()))
            XCTAssertFalse(json.contains("secret early response"))
            XCTAssertEqual(snapshot?.progress["oracle_lanes"]?.arrayValue?.first?.objectValue?["status"], .string("settled"))
            XCTAssertFalse(json.contains("completed"))
            XCTAssertFalse(json.contains("streaming"))
            await progress.progress(.init(kind: .laneStarted, groupID: group, turnID: turn, laneID: member.laneID, sequence: 3))
            let stillSettled = await store.snapshot(id: id)
            XCTAssertEqual(stillSettled?.progress["oracle_lanes"], snapshot?.progress["oracle_lanes"])
            await progress.settled(.object(["oracle_results": .array([.object([
                "lane_index": .int(0), "chat_id": .string("lane-0"), "status": .string("failed"),
                "error": .object(["code": .string("provider_error")])
            ])])]))
            await progress.progress(.init(kind: .laneStarted, groupID: group, turnID: turn, laneID: member.laneID, sequence: 4))
            let published = await store.snapshot(id: id)
            XCTAssertEqual(published?.progress["oracle_lanes"]?.arrayValue?.first?.objectValue?["status"], .string("failed"))
        }

        func testTerminalRecordsAreImmutableAndBoundedByRetention() async throws {
            let store = DomainLongRunningJobStore(maximumRetained: 1)
            let first = UUID()
            _ = try await store.register(id: first, tool: "oracle_send", owner: owner())
            await store.finish(id: first, result: .object(["response": .string("first")]))
            await store.update(id: first, fields: ["phase": .string("late")])
            await store.finish(id: first, error: "late failure")
            let terminal = await store.snapshot(id: first)
            XCTAssertEqual(terminal?.status, .completed)
            XCTAssertNil(terminal?.progress["phase"])
            let second = UUID()
            _ = try await store.register(id: second, tool: "oracle_send", owner: owner())
            await store.finish(id: second, result: .object(["response": .string("second")]))
            let evicted = await store.snapshot(id: first)
            XCTAssertNil(evicted)
            let expiring = DomainLongRunningJobStore(retention: 0)
            let id = UUID()
            _ = try await expiring.register(id: id, tool: "oracle_send", owner: owner())
            await expiring.finish(id: id, result: .object([:]))
            let expired = await expiring.snapshot(id: id)
            XCTAssertNil(expired)
        }

        func testLifecycleParserUsesAgentTimeoutResolversAndRejectsMixedControls() throws {
            guard case .blocking = try MCPLongRunningJobOperation.parse(["message": .string("legacy")]) else { return XCTFail("Expected blocking") }
            for args: [String: Value] in [["detach": .bool(true)], ["op": .string("poll"), "job_id": .string(UUID().uuidString), "message": .string("never send")]] {
                XCTAssertThrowsError(try MCPLongRunningJobOperation.parse(args))
            }
            guard case let .wait(_, timeout) = try MCPLongRunningJobOperation.parse(["op": .string("wait"), "job_id": .string(UUID().uuidString), "timeout": .int(0)]) else { return XCTFail("Expected wait") }
            XCTAssertEqual(timeout, 0)
        }
    }
#endif
