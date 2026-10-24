import Foundation

@MainActor
final class ContextBuilderRouteSettlementCoordinator {
    enum Settlement: Equatable {
        case routed
        case completedWithoutRoute
        case failedWithoutRoute(String)
        case routingOwnershipLost
        case cancelled
    }

    struct BufferedEvents {
        let events: [AIStreamResult]
        let droppedTextCharacterCount: Int
        let droppedNonterminalEventCount: Int
    }

    private let maxBufferedTextCharacters: Int
    private let maxBufferedEventCount: Int
    private var bufferedEvents: [AIStreamResult] = []
    private var bufferedTextCharacterCount = 0
    private var droppedTextCharacterCount = 0
    private var droppedNonterminalEventCount = 0
    private var settlement: Settlement?
    private var settlementContinuation: CheckedContinuation<Settlement, Never>?

    init(maxBufferedTextCharacters: Int, maxBufferedEventCount: Int) {
        self.maxBufferedTextCharacters = max(0, maxBufferedTextCharacters)
        self.maxBufferedEventCount = max(0, maxBufferedEventCount)
    }

    var isPending: Bool {
        settlement == nil
    }

    var isRouted: Bool {
        settlement == .routed
    }

    @discardableResult
    func settle(_ candidate: Settlement) -> Bool {
        guard settlement == nil else { return false }
        settlement = candidate
        settlementContinuation?.resume(returning: candidate)
        settlementContinuation = nil
        return true
    }

    func waitForSettlement() async -> Settlement {
        if let settlement {
            return settlement
        }
        precondition(
            settlementContinuation == nil,
            "ContextBuilderRouteSettlementCoordinator supports exactly one settlement waiter."
        )
        return await withCheckedContinuation { continuation in
            if let settlement {
                continuation.resume(returning: settlement)
            } else {
                settlementContinuation = continuation
            }
        }
    }

    func appendWhilePending(_ event: AIStreamResult) {
        guard settlement == nil else { return }

        if isCoalescibleProgressEvent(event),
           let existingIndex = bufferedEvents.lastIndex(where: {
               $0.type == event.type && isCoalescibleProgressEvent($0)
           })
        {
            removeBufferedEvent(at: existingIndex)
        }

        bufferedEvents.append(event)
        bufferedTextCharacterCount += stringPayloadCharacterCount(event)
        trimBufferedEventsIfNeeded()
    }

    func drainBufferedEvents() -> BufferedEvents {
        let result = BufferedEvents(
            events: bufferedEvents,
            droppedTextCharacterCount: droppedTextCharacterCount,
            droppedNonterminalEventCount: droppedNonterminalEventCount
        )
        bufferedEvents.removeAll(keepingCapacity: false)
        bufferedTextCharacterCount = 0
        droppedTextCharacterCount = 0
        droppedNonterminalEventCount = 0
        return result
    }

    private func trimBufferedEventsIfNeeded() {
        while bufferedTextCharacterCount > maxBufferedTextCharacters,
              let index = nextPayloadEvictionIndex()
        {
            removeBufferedEvent(at: index)
        }
        while bufferedEvents.count > maxBufferedEventCount,
              let index = nextCountEvictionIndex()
        {
            removeBufferedEvent(at: index)
        }
    }

    /// Prefer ordinary content when reducing payload size so compact diagnostics survive. Fall back
    /// to the oldest protected event so oversized tool, error, result, or terminal payloads cannot win.
    private func nextPayloadEvictionIndex() -> Int? {
        bufferedEvents.firstIndex(where: { $0.type == "content" })
            ?? bufferedEvents.firstIndex(where: isRedundantNonterminalEvent)
            ?? bufferedEvents.indices.first
    }

    /// Prefer redundant progress when reducing event count, then ordinary content, then the oldest
    /// protected event so tool, error, result, or terminal-only streams remain hard bounded.
    private func nextCountEvictionIndex() -> Int? {
        bufferedEvents.firstIndex(where: isRedundantNonterminalEvent)
            ?? bufferedEvents.firstIndex(where: { $0.type == "content" })
            ?? bufferedEvents.indices.first
    }

    private func removeBufferedEvent(at index: Int) {
        let removed = bufferedEvents.remove(at: index)
        let removedCount = stringPayloadCharacterCount(removed)
        bufferedTextCharacterCount -= removedCount
        droppedTextCharacterCount += removedCount
        droppedNonterminalEventCount += 1
    }

    /// Counts every retained provider-supplied string value, including the event type discriminator.
    private func stringPayloadCharacterCount(_ event: AIStreamResult) -> Int {
        [
            event.type,
            event.text,
            event.reasoning,
            event.toolName,
            event.toolArgs,
            event.toolOutput,
            event.toolResultJSON,
            event.toolArgsJSON,
            event.providerSessionID,
            event.stopReason,
            event.contentMessageID
        ].compactMap(\.self).reduce(0) { $0 + $1.count }
    }

    private func isCoalescibleProgressEvent(_ event: AIStreamResult) -> Bool {
        switch event.type {
        case AIStreamResult.lifecycleType, "event", "status":
            true
        default:
            false
        }
    }

    private func isRedundantNonterminalEvent(_ event: AIStreamResult) -> Bool {
        isCoalescibleProgressEvent(event)
            || event.type == "content" && (event.text?.isEmpty ?? true)
    }
}
