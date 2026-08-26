import Foundation
import os
@testable import RepoPromptDomainRuntime
import XCTest

final class OracleGroupRuntimeTests: XCTestCase {
    func testStartPersistsPrepareBeforeCallbacksAndReturnsExactWhitespace() async throws {
        let fixture = try makeRuntime()
        defer { fixture.cleanup() }
        let preparedSeen = OSAllocatedUnfairLock(initialState: false)
        let laneStarted = OSAllocatedUnfairLock(initialState: false)
        let start = try makeStart(count: 3, seed: "start", models: ["alpha", "alpha", "beta"])
        let input = try OracleInput(mode: .chat, userMessage: "ask")
        let store = fixture.store

        let completion = try await fixture.runtime.execute(
            Request(
                invocationID: UUID(),
                runID: UUID(),
                claimID: UUID(),
                input: input,
                intent: .start(start)
            ),
            callbacks: .init(
                prepared: { document in
                    XCTAssertEqual(document.revision, 1)
                    XCTAssertEqual(document.turns.last?.state, .prepared)
                    let loaded = try await store.load(
                        groupID: document.group.id,
                        owner: document.owner
                    )
                    XCTAssertEqual(loaded, document)
                    XCTAssertFalse(laneStarted.withLock { $0 })
                    preparedSeen.withLock { $0 = true }
                },
                executeLane: { invocation in
                    XCTAssertTrue(preparedSeen.withLock { $0 })
                    laneStarted.withLock { $0 = true }
                    XCTAssertEqual(invocation.context.input.userMessage, "ask")
                    return OracleLaneExecutionResponse(response: "  lane-\(invocation.member.laneID.index)  ")
                }
            )
        )

        XCTAssertEqual(completion.result.status, .completed)
        XCTAssertEqual(completion.result.oracleResults.map(\.modelID), ["alpha", "alpha", "beta"])
        XCTAssertEqual(
            completion.result.oracleResults.compactMap(\.response),
            ["  lane-0  ", "  lane-1  ", "  lane-2  "]
        )
        XCTAssertEqual(completion.terminalDocument.turns.last?.state, .terminal)
        XCTAssertEqual(completion.terminalDocument.revision, 2)
    }

    func testContinuationRecoversInterruptedTurn() async throws {
        let fixture = try makeRuntime()
        defer { fixture.cleanup() }
        let owner = try OracleConversationOwner(kind: "runtime", identifier: "recover")
        let prepared = try makePreparedGroup(count: 2, seed: "recover", owner: owner)
        try await fixture.store.create(prepared)

        let completion = try await fixture.runtime.execute(
            Request(
                invocationID: UUID(),
                runID: UUID(),
                claimID: UUID(),
                input: try OracleInput(mode: .chat, userMessage: "next"),
                intent: .continuation(
                    Continuation(
                        group: prepared.group,
                        owner: owner,
                        observedRevision: prepared.revision,
                        expectedRoster: prepared.roster
                    )
                )
            ),
            callbacks: .init(
                executeLane: { invocation in
                    XCTAssertEqual(invocation.priorTerminalTurns.count, 1)
                    XCTAssertEqual(invocation.priorTerminalTurns[0].status, .failed)
                    return OracleLaneExecutionResponse(response: "continued-\(invocation.member.laneID.index)")
                }
            )
        )

        XCTAssertEqual(completion.terminalDocument.revision, 4)
        XCTAssertEqual(completion.terminalDocument.turns.count, 2)
        XCTAssertEqual(completion.terminalDocument.turns[0].state, .terminal)
        XCTAssertEqual(completion.terminalDocument.turns[0].results.map(\.error?.code), ["interrupted", "interrupted"])
        XCTAssertEqual(completion.result.status, .completed)
        XCTAssertEqual(
            completion.result.oracleResults.compactMap(\.response),
            ["continued-0", "continued-1"]
        )
    }

    func testPreparedCallbackFailureSettlesBeforeLaneExecution() async throws {
        let fixture = try makeRuntime()
        defer { fixture.cleanup() }
        let start = try makeStart(count: 2, seed: "prepared-fail")
        let laneCalls = OSAllocatedUnfairLock(initialState: 0)

        await XCTAssertOracleRuntimeThrowsErrorAsync {
            _ = try await fixture.runtime.execute(
                Request(
                    invocationID: UUID(),
                    runID: UUID(),
                    claimID: UUID(),
                    input: try OracleInput(mode: .chat, userMessage: "ask"),
                    intent: .start(start)
                ),
                callbacks: .init(
                    prepared: { _ in throw CancellationError() },
                    executeLane: { _ in
                        laneCalls.withLock { $0 += 1 }
                        return OracleLaneExecutionResponse(response: "should-not-run")
                    }
                )
            )
        } verify: {
            XCTAssertTrue($0 is CancellationError)
        }

        XCTAssertEqual(laneCalls.withLock { $0 }, 0)
        let loaded = try await fixture.store.load(groupID: start.group.id, owner: start.owner)
        XCTAssertEqual(loaded?.turns.last?.state, .terminal)
        XCTAssertEqual(loaded?.turns.last?.results.map(\.status), [.cancelled, .cancelled])
    }

    func testSuccessfulCoordinationPublisherFailureLeavesPreparedTurnRecoverable() async throws {
        let fixture = try makeRuntime()
        defer { fixture.cleanup() }
        let start = try makeStart(count: 2, seed: "publish-fail")
        await fixture.store.failNextTerminalStages(2)

        await XCTAssertOracleRuntimeThrowsErrorAsync {
            _ = try await fixture.runtime.execute(
                Request(
                    invocationID: UUID(),
                    runID: UUID(),
                    claimID: UUID(),
                    input: try OracleInput(mode: .chat, userMessage: "ask"),
                    intent: .start(start)
                ),
                callbacks: .init(executeLane: { invocation in
                    OracleLaneExecutionResponse(response: "lane-\(invocation.member.laneID.index)")
                })
            )
        } verify: {
            XCTAssertEqual(
                $0 as? OraclePersistenceError,
                .invalidDocument("debug_forced_terminal_stage_failure")
            )
        }

        let loaded = try await fixture.store.load(groupID: start.group.id, owner: start.owner)
        XCTAssertEqual(loaded?.revision, 1)
        XCTAssertEqual(loaded?.turns.last?.state, .prepared)
    }

    func testSettlementPublisherFailureReportsExecutionAndSettlementErrors() async throws {
        let fixture = try makeRuntime()
        defer { fixture.cleanup() }
        let start = try makeStart(count: 2, seed: "settlement-fail")
        await fixture.store.failNextTerminalStages(2)

        await XCTAssertOracleRuntimeThrowsErrorAsync {
            _ = try await fixture.runtime.execute(
                Request(
                    invocationID: UUID(),
                    runID: UUID(),
                    claimID: UUID(),
                    input: try OracleInput(mode: .chat, userMessage: "ask"),
                    intent: .start(start)
                ),
                callbacks: .init(
                    prepared: { _ in throw RuntimeFixtureError.execution },
                    executeLane: { _ in OracleLaneExecutionResponse(response: "unused") }
                )
            )
        } verify: {
            guard case let .settlementFailed(execution, settlement) = $0 as? OracleGroupRuntime.RuntimeError else {
                return XCTFail("Expected settlementFailed, got \($0)")
            }
            XCTAssertEqual(execution, "execution")
            XCTAssertTrue(settlement.contains("debug_forced_terminal_stage_failure"), settlement)
        }

        let loaded = try await fixture.store.load(groupID: start.group.id, owner: start.owner)
        XCTAssertEqual(loaded?.turns.last?.state, .prepared)
    }

    func testSettlementUsesInjectedClockAndPreservesNonblankFailureText() async throws {
        let fixture = try makeRuntime()
        defer { fixture.cleanup() }
        let start = try makeStart(count: 2, seed: "settlement-clock")
        let timestamp = Date(timeIntervalSince1970: 12_345)
        let runtime = OracleGroupRuntime(
            store: fixture.store,
            claimManager: fixture.claimManager,
            now: { timestamp }
        )

        await XCTAssertOracleRuntimeThrowsErrorAsync {
            _ = try await runtime.execute(
                Request(
                    invocationID: UUID(),
                    runID: UUID(),
                    claimID: UUID(),
                    input: try OracleInput(mode: .chat, userMessage: "ask"),
                    intent: .start(start)
                ),
                callbacks: .init(
                    prepared: { _ in throw RuntimeFixtureError.paddedExecution },
                    executeLane: { _ in OracleLaneExecutionResponse(response: "unused") }
                )
            )
        } verify: {
            XCTAssertEqual($0 as? RuntimeFixtureError, .paddedExecution)
        }

        let loadedDocument = try await fixture.store.load(groupID: start.group.id, owner: start.owner)
        let loaded = try XCTUnwrap(loadedDocument)
        XCTAssertEqual(loaded.turns.last?.finishedAt, timestamp)
        XCTAssertEqual(loaded.turns.last?.results.map(\.error?.message), ["  execution  ", "  execution  "])
    }

    func testMissingContinuationAndSingleLaneStartFailBeforeMutation() async throws {
        let fixture = try makeRuntime()
        defer { fixture.cleanup() }
        let missing = try makeStart(count: 2, seed: "missing")
        await XCTAssertOracleRuntimeThrowsErrorAsync {
            _ = try await fixture.runtime.execute(
                Request(
                    invocationID: UUID(),
                    runID: UUID(),
                    claimID: UUID(),
                    input: try OracleInput(mode: .chat, userMessage: "ask"),
                    intent: .continuation(
                        Continuation(
                            group: missing.group,
                            owner: missing.owner,
                            observedRevision: 1,
                            expectedRoster: missing.roster
                        )
                    )
                ),
                callbacks: .init(executeLane: { _ in OracleLaneExecutionResponse(response: "unused") })
            )
        } verify: {
            XCTAssertEqual($0 as? OracleGroupRuntime.RuntimeError, .continuationMissing)
        }

        let model = try OracleModelReference(providerID: "fixture", modelID: "single")
        let roster = try OracleRoster(primary: model, additional: [])
        let member = try OracleGroupMember(
            laneID: OracleLaneID(index: 0),
            publicChatID: "single-chat",
            model: model
        )
        let invalidStart = OracleGroupRuntime.Start(
            group: try OracleGroupDescriptor(size: 2),
            owner: try OracleConversationOwner(kind: "runtime", identifier: "single"),
            name: "single",
            roster: roster,
            members: [member]
        )
        await XCTAssertOracleRuntimeThrowsErrorAsync {
            _ = try await fixture.runtime.execute(
                Request(
                    invocationID: UUID(),
                    runID: UUID(),
                    claimID: UUID(),
                    input: try OracleInput(mode: .chat, userMessage: "ask"),
                    intent: .start(invalidStart)
                ),
                callbacks: .init(executeLane: { _ in OracleLaneExecutionResponse(response: "unused") })
            )
        } verify: {
            XCTAssertEqual($0 as? OracleGroupRuntime.RuntimeError, .singleLaneBypassRequired)
        }
        let stored = try await fixture.store.load(groupID: invalidStart.group.id, owner: invalidStart.owner)
        XCTAssertNil(stored)
    }

    func testClaimConflictLeavesPreparedDocumentUnchanged() async throws {
        let fixture = try makeRuntime()
        defer { fixture.cleanup() }
        let start = try makeStart(count: 2, seed: "conflict")
        let gate = ClaimHoldGate()
        let runtime = fixture.runtime
        let store = fixture.store

        async let first = runtime.execute(
            Request(
                invocationID: UUID(),
                runID: UUID(),
                claimID: UUID(),
                input: try OracleInput(mode: .chat, userMessage: "ask"),
                intent: .start(start)
            ),
            callbacks: .init(
                prepared: { _ in
                    await gate.markHeld()
                    await gate.waitForRelease()
                },
                executeLane: { invocation in
                    OracleLaneExecutionResponse(response: "lane-\(invocation.member.laneID.index)")
                }
            )
        )

        await gate.waitUntilHeld()
        await XCTAssertOracleRuntimeThrowsErrorAsync {
            _ = try await runtime.execute(
                Request(
                    invocationID: UUID(),
                    runID: UUID(),
                    claimID: UUID(),
                    input: try OracleInput(mode: .chat, userMessage: "other"),
                    intent: .continuation(
                        Continuation(
                            group: start.group,
                            owner: start.owner,
                            observedRevision: 1,
                            expectedRoster: start.roster
                        )
                    )
                ),
                callbacks: .init(executeLane: { _ in
                    OracleLaneExecutionResponse(response: "should-not-run")
                })
            )
        } verify: {
            XCTAssertEqual($0 as? OracleGroupClaimError, .conflict)
        }

        let duringConflict = try await store.load(groupID: start.group.id, owner: start.owner)
        XCTAssertEqual(duringConflict?.revision, 1)
        XCTAssertEqual(duringConflict?.turns.last?.state, .prepared)
        await gate.releaseHold()
        _ = try await first
    }

    func testParentCancellationDrainsLanesBeforeClaimRelease() async throws {
        let fixture = try makeRuntime()
        defer { fixture.cleanup() }
        let start = try makeStart(count: 2, seed: "cancel")
        let started = expectation(description: "all lanes started")
        started.expectedFulfillmentCount = 2
        let cancelled = expectation(description: "all lanes observed cancellation")
        cancelled.expectedFulfillmentCount = 2
        let drainGate = ClaimHoldGate()
        let runtime = fixture.runtime
        let claimManager = fixture.claimManager

        let task = Task {
            try await runtime.execute(
                Request(
                    invocationID: UUID(),
                    runID: UUID(),
                    claimID: UUID(),
                    input: try OracleInput(mode: .chat, userMessage: "ask"),
                    intent: .start(start)
                ),
                callbacks: .init(
                    executeLane: { invocation in
                        started.fulfill()
                        do {
                            try await Task.sleep(for: .seconds(5))
                            return OracleLaneExecutionResponse(response: "late-\(invocation.member.laneID.index)")
                        } catch {
                            cancelled.fulfill()
                            await drainGate.waitForRelease()
                            throw error
                        }
                    }
                )
            )
        }

        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        let preparedDocument = try await fixture.store.load(groupID: start.group.id, owner: start.owner)
        let prepared = try XCTUnwrap(preparedDocument)
        await XCTAssertOracleRuntimeThrowsErrorAsync {
            _ = try await claimManager.acquire(
                group: prepared,
                owner: start.owner,
                invocationID: UUID(),
                runID: UUID()
            )
        } verify: {
            XCTAssertEqual($0 as? OracleGroupClaimError, .conflict)
        }

        await drainGate.releaseHold()
        let completion = try await task.value
        XCTAssertEqual(completion.result.oracleResults.map(\.status), [.cancelled, .cancelled])
        let claim = try await claimManager.acquire(
            group: completion.terminalDocument,
            owner: start.owner,
            invocationID: UUID(),
            runID: UUID()
        )
        claim.release()
    }

    func testRosterConflictDoesNotMutateHistory() async throws {
        let fixture = try makeRuntime()
        defer { fixture.cleanup() }
        let start = try makeStart(count: 2, seed: "roster")
        let first = try await fixture.runtime.execute(
            Request(
                invocationID: UUID(),
                runID: UUID(),
                claimID: UUID(),
                input: try OracleInput(mode: .chat, userMessage: "ask"),
                intent: .start(start)
            ),
            callbacks: .init(executeLane: { invocation in
                OracleLaneExecutionResponse(response: "lane-\(invocation.member.laneID.index)")
            })
        )
        let otherRoster = try OracleRoster(
            primaryModelID: "other-a",
            additionalModelIDs: ["other-b"]
        )
        let heldClaim = try await fixture.claimManager.acquire(
            group: first.terminalDocument,
            owner: start.owner,
            invocationID: UUID(),
            runID: UUID()
        )
        defer { heldClaim.release() }

        await XCTAssertOracleRuntimeThrowsErrorAsync {
            _ = try await fixture.runtime.execute(
                Request(
                    invocationID: UUID(),
                    runID: UUID(),
                    claimID: UUID(),
                    input: try OracleInput(mode: .chat, userMessage: "next"),
                    intent: .continuation(
                        Continuation(
                            group: first.terminalDocument.group,
                            owner: start.owner,
                            observedRevision: first.terminalDocument.revision,
                            expectedRoster: otherRoster
                        )
                    )
                ),
                callbacks: .init(executeLane: { _ in
                    OracleLaneExecutionResponse(response: "should-not-run")
                })
            )
        } verify: {
            XCTAssertEqual($0 as? OracleGroupRuntime.RuntimeError, .rosterConflict)
        }

        let loaded = try await fixture.store.load(groupID: start.group.id, owner: start.owner)
        XCTAssertEqual(loaded?.revision, first.terminalDocument.revision)
    }
}

private enum RuntimeFixtureError: Error, Equatable, CustomStringConvertible {
    case execution
    case paddedExecution

    var description: String {
        switch self {
        case .execution:
            "execution"
        case .paddedExecution:
            "  execution  "
        }
    }
}

private func XCTAssertOracleRuntimeThrowsErrorAsync(
    _ expression: () async throws -> some Any,
    verify: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        verify(error)
    }
}

private actor ClaimHoldGate {
    private var held = false
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markHeld() {
        held = true
        heldWaiters.forEach { $0.resume() }
        heldWaiters.removeAll()
    }

    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func releaseHold() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private extension OracleGroupRuntimeTests {
    typealias Request = OracleGroupRuntime.Request
    typealias Continuation = OracleGroupRuntime.Continuation

    func makeRuntime() throws -> (
        root: URL,
        store: DomainOracleConversationStore,
        claimManager: OracleGroupClaimManager,
        runtime: OracleGroupRuntime,
        cleanup: () -> Void
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OracleGroupRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        let identity = DomainRuntimeIdentity(
            runtimeID: UUID(),
            lifecycleGeneration: 1,
            processID: 42,
            mode: .standalone,
            createdAt: Date()
        )
        let persistence = DomainPersistenceCoordinator(
            configuration: DomainRuntimeConfiguration(
                mode: .standalone,
                profileIdentifier: "runtime-tests",
                storageDirectory: root,
                eventDirectory: root.appendingPathComponent("Events"),
                temporaryDirectory: root.appendingPathComponent("Temporary"),
                externalReloadInterval: nil
            ),
            identity: identity
        )
        let store = DomainOracleConversationStore(persistence: persistence, identity: identity)
        let claimManager = OracleGroupClaimManager(persistence: persistence, identity: identity)
        let runtime = OracleGroupRuntime(store: store, claimManager: claimManager)
        return (root, store, claimManager, runtime, { try? FileManager.default.removeItem(at: root) })
    }

    func makeStart(
        count: Int,
        seed: String,
        models: [String]? = nil
    ) throws -> OracleGroupRuntime.Start {
        let owner = try OracleConversationOwner(kind: "runtime", identifier: seed)
        let modelIDs = models ?? (0 ..< count).map { "model-\($0)" }
        let references = try modelIDs.map {
            try OracleModelReference(providerID: "fixture", modelID: $0)
        }
        let roster = try OracleRoster(primary: references[0], additional: Array(references.dropFirst()))
        let group = try OracleGroupDescriptor(size: count)
        let members = try references.enumerated().map { index, model in
            try OracleGroupMember(
                laneID: OracleLaneID(index: index),
                publicChatID: "\(seed)-chat-\(index)",
                model: model
            )
        }
        return OracleGroupRuntime.Start(
            group: group,
            owner: owner,
            name: seed,
            roster: roster,
            members: members
        )
    }

    func makePreparedGroup(
        count: Int,
        seed: String,
        owner: OracleConversationOwner
    ) throws -> OracleGroupDocument {
        let start = try makeStart(count: count, seed: seed)
        let timestamp = Date(timeIntervalSince1970: 1000)
        return try OracleGroupDocument(
            group: start.group,
            owner: owner,
            name: start.name,
            revision: 1,
            createdAt: timestamp,
            updatedAt: timestamp,
            roster: start.roster,
            members: start.members,
            turns: [OracleTurnRecord(
                input: try OracleInput(mode: .chat, userMessage: "first"),
                state: .prepared,
                startedAt: timestamp
            )]
        )
    }
}
