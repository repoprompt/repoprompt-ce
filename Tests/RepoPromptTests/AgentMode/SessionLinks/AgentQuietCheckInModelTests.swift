import Foundation
import RepoPromptDomainRuntime
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// Identity-based reference: debts are ordinary attempt identities, delivery is a frozen identity
/// prefix, and display exclusion is the set of rows belonging to positively quiet attempts. The
/// oracle does not run the reducer's counter comparisons or inspect its pending representation.
@MainActor
final class AgentQuietCheckInModelTests: XCTestCase {
    private struct Event {
        let identity: UUID
        let operation: Int
    }

    private struct FrozenDelivery {
        let claim: AgentSessionLinkOutboundPromptClaim
        let identities: Set<UUID>
    }

    private func trace(seed: UInt64) -> [Event] {
        var state = seed &+ 1
        return (0 ..< 12).map { index in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Event(
                identity: UUID(uuidString: String(format: "C5000000-0000-0000-%04X-%012X", seed, index + 1))!,
                operation: Int((state >> 32) % 11)
            )
        }
    }

    private func replay(_ events: [Event], harness: AgentSessionLinkRunnerHarness) async -> String? {
        typealias Notices = AgentSessionLinkPassiveStatusNotices
        let session = harness.makeSession(agent: .codexExec)
        session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: UUID()))
        session.appendItem(.user("Existing ordinary request", sequenceIndex: 0))
        session.appendItem(.assistant("Existing ordinary conclusion", sequenceIndex: 1))
        session.runState = .completed
        harness.host.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)
        let observer = AgentSessionLinkIdentityTestSupport.endpoint(sessionID: UUID())
        let target = AgentSessionLinkIdentityTestSupport.endpoint(sessionID: UUID(), windowID: 2)
        let reference = DomainAgentSessionLinkReference(linkID: UUID(), generation: 1)
        let inventory = AgentSessionLinkPromptInventory(observerSessionID: observer.sessionID, linkSetRevision: 1, items: [
            .init(targetSessionID: target.sessionID, displayName: "Target", capabilityNames: ["poll", "send_when_idle"], reference: reference)
        ])
        let store = AgentSessionLinkOutboundPromptClaimStore()
        let epoch = AgentSessionLinkPromptEpoch(endpoint: observer, allowsSupplement: true, providerContext: .claudeCode)
        var reducer = Notices(observerEndpoint: observer)
        var attempts: [UUID] = []
        var ordinary = Set<UUID>()
        var paid = Set<UUID>()
        var quietRows = Set<UUID>()
        var lastReported: [UUID] = []
        var frozen: [FrozenDelivery] = []
        var fresh = true
        func sample() -> Notices.Sample {
            .init(reference: reference, targetEndpoint: target, targetSessionID: target.sessionID, displayName: "Target", status: .idle, runFacts: fresh ? session.quietLedger.facts : nil)
        }
        reducer.enable(samples: [sample()], linkSetRevision: 1, observedAt: .distantPast)
        func observe() {
            reducer.reconcile(samples: [sample()], linkSetRevision: 1, deliverable: true, observedAt: .distantPast)
        }
        for event in events {
            switch event.operation {
            case 0 ... 5:
                let previousIDs = session.liveItemIDs
                if event.operation < 2 {
                    if let failure = await settleCertified(session, harness: harness, closingText: event.operation == 1, wakeID: event.identity) {
                        return failure
                    }
                } else {
                    _ = await AgentQuietCheckInReplay.settle(session, harness: harness, form: event.operation, wakeID: event.identity)
                }
                attempts.append(event.identity)
                if event.operation < 2 {
                    quietRows.formUnion(session.liveItemIDs.subtracting(previousIDs))
                } else {
                    ordinary.insert(event.identity)
                }
                fresh = true
                lastReported = attempts
                observe()
            case 6:
                if let claim = store.claim(dispatchID: .autoWake(wakeID: event.identity), epoch: epoch, inventory: inventory, passiveNotices: reducer.snapshot, routineQuietCheckIn: true, render: AgentSessionLinkPrompts.rendered) {
                    frozen.append(.init(claim: claim, identities: Set(lastReported)))
                }
            case 7:
                if !frozen.isEmpty {
                    let delivery = frozen.removeFirst()
                    store.accept(delivery.claim)
                    if let receipt = delivery.claim.passive?.receipt {
                        reducer.apply(receipt)
                        if !receipt.deliveredStatuses.isEmpty { paid.formUnion(delivery.identities) }
                    }
                }
            case 8:
                fresh = false
                observe()
            case 9:
                fresh = true
                lastReported = attempts
                observe()
            default:
                let before = reducer.snapshot
                observe()
                if before != reducer.snapshot { return "unchanged observation published/overflowed" }
            }
            if session.quietLedger.facts?.settledThrough != UInt64(attempts.count) { return "settled identities lost or duplicated" }
            let lastOrdinary = attempts.lastIndex(where: { ordinary.contains($0) }).map { UInt64($0 + 1) } ?? 0
            if session.quietLedger.facts?.ordinaryThrough != lastOrdinary { return "ordinary occurrence identity lost" }
            if fresh {
                let eligible = reducer.snapshot.entries.contains(where: \.isRoutineWakeEligible)
                if eligible != !ordinary.subtracting(paid).isEmpty { return "unpaid ordinary identity != routine eligibility" }
            }
            if let position = reducer.deliveredRunThrough(for: reference) {
                let representedPaid = Set(attempts.prefix(Int(position)))
                if representedPaid != paid { return "receipt paid other than its frozen identity prefix" }
            } else { return "known baseline position lost" }
            let base = AgentTranscriptProjectionBuilder.build(from: AgentTranscriptIO.buildTranscript(from: session.items, compact: false))
            let snapshot = AgentTranscriptPresentationSnapshot(revision: 1, visibleBlocks: base.workingBlocks, workingBlocks: base.workingBlocks, visibleRows: base.workingRows, workingRows: base.workingRows, rowAnchorIndex: base.rowAnchorIndex, anchorBlockIndex: base.anchorBlockIndex)
            // Saved certification owns exact member rows; the ledger's hiddenSourceIDs now
            // tracks host-marker producers, not those member identities. Keep this component
            // oracle independent: expected membership comes from the event's appended IDs.
            let certifiedRows = Set(session.items.filter { $0.quietCheckInWakeID != nil }.map(\.id))
            if certifiedRows != quietRows { return "certified members differ from quiet-attempt row identities" }
            let mask = AgentTranscriptProjectionBuilder.maskForLocalDisplay(snapshot, archivedBlocks: [], hiddenSourceIDs: certifiedRows)
            let expectedVisible = Set(base.workingRows.map(\.id)).subtracting(quietRows)
            if Set(mask.presentation.visibleRows.map(\.id)) != expectedVisible { return "display differs from quiet-attempt row identities" }
        }
        fresh = true
        observe()
        if let claim = store.claim(dispatchID: .autoWake(wakeID: UUID()), epoch: epoch, inventory: inventory, passiveNotices: reducer.snapshot, routineQuietCheckIn: true, render: AgentSessionLinkPrompts.rendered), let receipt = claim.passive?.receipt {
            store.accept(claim)
            reducer.apply(receipt)
        }
        if !reducer.snapshot.entries.isEmpty { return "successful final drain left represented work" }
        return nil
    }

    /// Model events use the explicit declaration seam, not the retired silence/ack heuristic.
    /// The registered-body route has separate integration coverage; this model supplies an exact
    /// accepted origin/canonical pair and lets the real terminal barrier certify (or reject) it.
    private func settleCertified(
        _ session: AgentTabSession,
        harness: AgentSessionLinkRunnerHarness,
        closingText: Bool,
        wakeID: UUID
    ) async -> String? {
        if session.runID == nil { session.installRunID(UUID()) }
        harness.host.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)
        // Like the authoritative dispatch owner, capture the completed ordinary baseline
        // before publishing running state; an active turn cannot furnish that baseline.
        let owner = session.beginRunAttempt(source: "certified-model-replay")
        guard session.quietLedger.baseline(owner: owner) != nil else { return "completed model baseline unavailable" }
        session.runState = .running
        session.quietLedger.recordPhysicalDispatch(owner: owner, wakeID: wakeID, routineQuietCheckIn: true, alreadyAcquired: false, sourceRevision: session.sourceItemsRevision)
        guard let binding = session.persistentSessionBindingIdentity, let runID = session.runID,
              let endpoint = try? DomainAgentSessionLinkEndpointIdentity(
                  windowID: 1, workspaceID: UUID(), tabID: session.tabID, sessionID: binding.sessionID,
                  persistentBindingGeneration: binding.generation, bindingTransitionGeneration: session.bindingTransitionGeneration
              )
        else { return "explicit declaration origin unavailable" }
        let invocationID = UUID()
        guard session.quietLedger.enterDeclarationBody(owner: owner, hostInvocationID: invocationID),
              session.quietLedger.acceptDeclarationBody(
                  owner: owner, hostInvocationID: invocationID, wakeID: wakeID,
                  origin: .init(endpoint: endpoint, runID: runID, runAttemptID: owner.attemptID),
                  currentEndpoint: endpoint, currentRunID: runID
              )
        else { return "explicit declaration body rejected" }
        session.appendItem(.toolCall(name: "self_noop", invocationID: invocationID, argsJSON: "{}", sequenceIndex: session.nextSequenceIndex))
        session.appendItem(.toolResult(name: "self_noop", invocationID: invocationID, resultJSON: "{\"result\":\"done\"}", isError: false, sequenceIndex: session.nextSequenceIndex))
        if closingText {
            session.noteAcceptedStream(.init(type: "content", text: "Certified closing"), owner: owner)
            session.appendItem(.assistant("Certified closing", sequenceIndex: session.nextSequenceIndex))
        }
        _ = await AgentRunTerminalCommitBarrier().commit(.init(
            binding: harness.hooks.bindTerminalSession(session), ownership: owner, expectedRunID: runID,
            terminalState: .completed, source: "certified-model-replay", attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: false, supportsFollowUp: false, notifyTurnComplete: true, classifiesQuietCheckIn: true
        ))
        return nil
    }

    /// Chunk deletion replays the same event identities. It is exercised on a synthetic predicate
    /// too, so a green random run does not leave the failure minimizer itself untested.
    private func shrink(_ trace: [Event], fails: ([Event]) async -> Bool) async -> [Event] {
        var result = trace
        var width = max(1, result.count / 2)
        while width > 0 {
            var offset = 0
            while offset + width <= result.count {
                var candidate = result
                candidate.removeSubrange(offset ..< offset + width)
                if await fails(candidate) { result = candidate } else { offset += width }
            }
            width /= 2
        }
        return result
    }

    func testTwoThousandBoundedIdentityTracesAndFailureShrinking() async throws {
        let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() }, replayTranscript: true)
        for seed in 0 ..< 2000 {
            let events = trace(seed: UInt64(seed))
            if let failure = await replay(events, harness: harness) {
                let minimal = await shrink(events) { await self.replay($0, harness: harness) != nil }
                return XCTFail("seed=\(seed) failure=\(failure) minimized=\(minimal.map(\.operation))")
            }
        }
        let diagnostic = trace(seed: 1)
        let required = try XCTUnwrap(diagnostic.first)
        let shrunk = await shrink(diagnostic) { $0.contains(where: { $0.identity == required.identity }) }
        XCTAssertEqual(shrunk.map(\.identity), [required.identity])
        print("QUIET_C5_MODEL seedRange=0..<2000 traceLength=12 oracle=attempt-and-row-identities shrink=chunk-deletion")
    }
}
