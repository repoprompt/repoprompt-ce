import Foundation

package struct MCPDomainResponseDeliverySnapshot: Equatable, Sendable {
    package let pendingRequestCount: Int
    package let waiterCount: Int
    package let isTerminal: Bool

    package init(
        pendingRequestCount: Int,
        waiterCount: Int,
        isTerminal: Bool
    ) {
        self.pendingRequestCount = pendingRequestCount
        self.waiterCount = waiterCount
        self.isTerminal = isTerminal
    }

    package var acceptedRequestsFullyResponded: Bool {
        pendingRequestCount == 0
    }
}

/// Tracks one transport hop from accepted JSON-RPC requests through completed response writes.
/// Framing and physical I/O remain transport-owned; this lock-based tracker is synchronous so
/// ingress and post-write record points do not acquire an actor hop or change delivery ordering.
package final class MCPDomainResponseDeliveryTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingRequestIDs: Set<String> = []
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var isTerminal = false

    package init() {}

    package func recordAcceptedClientFrame(_ frame: Data) {
        let requestIDs = Self.messageObjects(in: frame).compactMap { message -> String? in
            guard message["method"] is String,
                  let id = Self.identifier(in: message),
                  id != "null"
            else { return nil }
            return id
        }
        guard !requestIDs.isEmpty else { return }

        lock.lock()
        if !isTerminal {
            pendingRequestIDs.formUnion(requestIDs)
        }
        lock.unlock()
    }

    package func recordDeliveredServerFrame(_ frame: Data) {
        let responseIDs = Self.messageObjects(in: frame).compactMap { message -> String? in
            guard message["method"] == nil,
                  message["result"] != nil || message["error"] != nil,
                  let id = Self.identifier(in: message),
                  id != "null"
            else { return nil }
            return id
        }
        guard !responseIDs.isEmpty else { return }

        let continuations: [CheckedContinuation<Bool, Never>]
        lock.lock()
        pendingRequestIDs.subtract(responseIDs)
        if !isTerminal, pendingRequestIDs.isEmpty {
            continuations = waiters
            waiters.removeAll()
        } else {
            continuations = []
        }
        lock.unlock()
        continuations.forEach { $0.resume(returning: true) }
    }

    package func waitUntilDrained() async -> Bool {
        await withCheckedContinuation { continuation in
            let immediateResult: Bool?
            lock.lock()
            if isTerminal {
                immediateResult = false
            } else if pendingRequestIDs.isEmpty {
                immediateResult = true
            } else {
                waiters.append(continuation)
                immediateResult = nil
            }
            lock.unlock()

            if let immediateResult {
                continuation.resume(returning: immediateResult)
            }
        }
    }

    package func reset() {
        let continuations: [CheckedContinuation<Bool, Never>]
        lock.lock()
        continuations = waiters
        waiters.removeAll()
        pendingRequestIDs.removeAll()
        isTerminal = false
        lock.unlock()
        continuations.forEach { $0.resume(returning: false) }
    }

    package func close() {
        let continuations: [CheckedContinuation<Bool, Never>]
        lock.lock()
        guard !isTerminal else {
            lock.unlock()
            return
        }
        isTerminal = true
        continuations = waiters
        waiters.removeAll()
        lock.unlock()
        continuations.forEach { $0.resume(returning: false) }
    }

    package func snapshot() -> MCPDomainResponseDeliverySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return MCPDomainResponseDeliverySnapshot(
            pendingRequestCount: pendingRequestIDs.count,
            waiterCount: waiters.count,
            isTerminal: isTerminal
        )
    }

    private static func messageObjects(in frame: Data) -> [[String: Any]] {
        guard let object = try? JSONSerialization.jsonObject(with: frame) else { return [] }
        if let message = object as? [String: Any] {
            return [message]
        }
        return object as? [[String: Any]] ?? []
    }

    private static func identifier(in message: [String: Any]) -> String? {
        guard let id = message["id"] else { return nil }
        switch id {
        case is NSNull:
            return "null"
        case let string as String:
            return "s:\(string)"
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return "n:\(number.stringValue)"
        default:
            return nil
        }
    }
}
