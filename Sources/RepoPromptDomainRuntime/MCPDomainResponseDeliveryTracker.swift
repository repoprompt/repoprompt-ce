import Foundation

// swiftformat:disable:next redundantSendable
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

/// Tracks response obligations from accepted requests through complete writes or explicit cancellation.
/// Framing and physical I/O remain transport-owned; this lock-based tracker is synchronous so
/// ingress and post-write record points do not acquire an actor hop or change delivery ordering.
package final class MCPDomainResponseDeliveryTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingRequestIDs: Set<String> = []
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var isTerminal = false
    private var generation: UInt64 = 0

    package init() {}

    package var currentGeneration: UInt64 {
        lock.withLock { generation }
    }

    /// Explicit client cancellation abandons a response-delivery obligation; it
    /// does not certify that the handler or its cleanup has physically settled.
    package func recordAcceptedClientFrame(_ frame: Data, expectedGeneration: UInt64? = nil) {
        _ = publishClientFrame(frame, expectedGeneration: expectedGeneration) { true }
    }

    /// Registers delivery debt before the synchronous publisher can expose a frame.
    /// Return true only for accepted publication; rejection rolls back just this frame's
    /// changes. The callback runs under the tracker lock and must not suspend, perform
    /// physical I/O, or reenter this tracker. Delivery and reset cannot interleave with rollback.
    package func publishClientFrame(
        _ frame: Data,
        expectedGeneration: UInt64? = nil,
        publish: () -> Bool
    ) -> Bool {
        enum Acceptance {
            case request(String)
            case cancellation(String)
        }
        let accepted = Self.messageObjects(in: frame).compactMap { message -> Acceptance? in
            guard let method = message["method"] as? String else { return nil }
            if let id = Self.identifier(in: message), id != "null" {
                return .request(id)
            }
            guard message["id"] == nil,
                  method == "notifications/cancelled",
                  let params = message["params"] as? [String: Any],
                  let id = Self.identifier(params["requestId"] ?? params["id"]), id != "null"
            else { return nil }
            return .cancellation(id)
        }
        let continuations: [CheckedContinuation<Bool, Never>]
        lock.lock()
        guard !isTerminal, expectedGeneration == nil || expectedGeneration == generation else {
            lock.unlock()
            return false
        }
        var rollback: [(id: String, wasPending: Bool)] = []
        for message in accepted {
            switch message {
            case let .request(id):
                if pendingRequestIDs.insert(id).inserted {
                    rollback.append((id, false))
                }
            case let .cancellation(id):
                if pendingRequestIDs.remove(id) != nil {
                    rollback.append((id, true))
                }
            }
        }
        let wasPublished = publish()
        if !wasPublished {
            for change in rollback.reversed() {
                if change.wasPending {
                    pendingRequestIDs.insert(change.id)
                } else {
                    pendingRequestIDs.remove(change.id)
                }
            }
        }
        if wasPublished, pendingRequestIDs.isEmpty {
            continuations = waiters
            waiters.removeAll()
        } else {
            continuations = []
        }
        lock.unlock()
        continuations.forEach { $0.resume(returning: true) }
        return wasPublished
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
        generation &+= 1
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
        identifier(message["id"])
    }

    private static func identifier(_ value: Any?) -> String? {
        guard let id = value else { return nil }
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
