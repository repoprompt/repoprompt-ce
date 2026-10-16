import Foundation
import RepoPromptShared

/// Owns the terminal-response claim for an accepted socket. This is separate from
/// `MCPDomainResponseDeliveryTracker`: that tracker records physical write delivery,
/// while this one retains exact JSON-RPC number-versus-string identities needed to
/// decide which logical response the watchdog owns. Requests are recorded before
/// they are offered to the MCP SDK, so a watchdog can answer every accepted request,
/// including one that has not reached a handler.
///
/// Client cancellations retire delivery ownership before SDK dispatch, while the
/// watchdog seals before terminal errors. Both suppress later SDK completions.
/// A response whose write already began cannot be rewritten safely; the bridge's
/// bounded cancellation ledger is the backstop for that physical-write race.
package final class MCPExecutionWatchdogResponseLedger: @unchecked Sendable {
    package enum PreparedFrameSealPolicy {
        case preemptIfSealed
        case allowAfterSeal
    }

    package struct PreparedFrame {
        package let data: Data
        package let sealPolicy: PreparedFrameSealPolicy
    }

    package enum DeliveryPreparation {
        case frame(PreparedFrame)
        case suppressed(phase: String, terminalReason: String?)
    }

    private let maximumCancelledRequestIDs: Int
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var cancelledRequestIDs = Set<JSONRPCBridgeID>()
    private var ownershipFailure: MCPClientCancellationOwnershipError?
    private var isSealed = false
    private var isTerminalDeliveryPending = false
    private var pendingRequestIDs: [JSONRPCBridgeID] = []
    private var pendingRequestIDSet = Set<JSONRPCBridgeID>()
    private var sealedRequestIDs = Set<JSONRPCBridgeID>()

    package init(maximumCancelledRequestIDs: Int = 1024) {
        self.maximumCancelledRequestIDs = max(1, maximumCancelledRequestIDs)
    }

    package var currentGeneration: UInt64 {
        lock.withLock { generation }
    }

    /// Ingress owns cancellation before offering it to the SDK. Cancellation does
    /// not prove handler settlement, so exact IDs remain retired until reset. The
    /// hard bound never evicts an earlier cancellation or permits ambiguous reuse.
    package func recordAcceptedClientFrame(_ frame: Data, expectedGeneration: UInt64? = nil) throws -> Bool {
        let messages = Self.ingressMessages(in: frame)
        lock.lock()
        defer { lock.unlock() }
        if let expectedGeneration, expectedGeneration != generation { return false }
        if let ownershipFailure { throw ownershipFailure }
        guard !isSealed else { return false }
        for message in messages {
            switch message {
            case let .request(id):
                if cancelledRequestIDs.contains(id) {
                    let error = MCPClientCancellationOwnershipError.cancelledIDReuse(id)
                    ownershipFailure = error
                    throw error
                }
                if pendingRequestIDSet.insert(id).inserted { pendingRequestIDs.append(id) }
            case let .cancellation(id):
                guard pendingRequestIDSet.contains(id) else { continue }
                guard cancelledRequestIDs.count < maximumCancelledRequestIDs else {
                    let error = MCPClientCancellationOwnershipError.retentionCapacityExceeded(maximumCancelledRequestIDs)
                    ownershipFailure = error
                    throw error
                }
                cancelledRequestIDs.insert(id)
                pendingRequestIDSet.remove(id)
                pendingRequestIDs.removeAll { $0 == id }
            }
        }
        return true
    }

    private enum IngressMessage {
        case request(JSONRPCBridgeID)
        case cancellation(JSONRPCBridgeID)
    }

    private static func ingressMessages(in frame: Data) -> [IngressMessage] {
        guard let root = try? JSONSerialization.jsonObject(with: frame) else { return [] }
        let objects = (root as? [Any]) ?? [root]
        return objects.compactMap { object in
            guard let message = object as? [String: Any],
                  let method = message["method"] as? String,
                  message["result"] == nil, message["error"] == nil
            else { return nil }
            if message.keys.contains("id") {
                guard let id = JSONRPCBridgeID.parseJSONValue(message["id"]), id != .null else { return nil }
                return .request(id)
            }
            guard method == "notifications/cancelled",
                  let params = message["params"] as? [String: Any],
                  let id = JSONRPCBridgeID.parseJSONValue(params["requestId"] ?? params["id"]), id != .null
            else { return nil }
            return .cancellation(id)
        }
    }

    /// Atomically freezes ingress before waiting for the transport actor. Pending IDs
    /// remain live until a complete ordinary response is delivered or the watchdog's
    /// actor-isolated terminal writer claims them.
    package func seal() {
        lock.lock()
        guard !isSealed else {
            lock.unlock()
            return
        }
        isSealed = true
        isTerminalDeliveryPending = true
        sealedRequestIDs.formUnion(pendingRequestIDSet)
        lock.unlock()
    }

    /// Marks the terminal writer's actor-isolated error/control attempt complete. Only
    /// after this publication may an unrelated frame prepared after sealing use the
    /// still-open socket.
    package func finishTerminalDelivery() {
        lock.withLock { isTerminalDeliveryPending = false }
    }

    /// Claims the still-outstanding IDs after the watchdog has acquired the transport
    /// actor. A complete ordinary write which won the race retires its ID first.
    package func takeOutstandingRequestIDsAfterSeal() -> [JSONRPCBridgeID] {
        lock.lock()
        defer { lock.unlock() }
        guard isSealed else { return [] }
        let requestIDs = pendingRequestIDs
        pendingRequestIDs.removeAll()
        pendingRequestIDSet.removeAll()
        return requestIDs
    }

    package func shouldPreemptOrdinaryWrite(
        with sealPolicy: PreparedFrameSealPolicy
    ) -> Bool {
        lock.withLock {
            if isTerminalDeliveryPending {
                return true
            }
            guard case .preemptIfSealed = sealPolicy else { return false }
            return isSealed
        }
    }

    package func reset() {
        lock.lock()
        generation &+= 1
        isSealed = false
        isTerminalDeliveryPending = false
        cancelledRequestIDs.removeAll()
        ownershipFailure = nil
        pendingRequestIDs.removeAll()
        pendingRequestIDSet.removeAll()
        sealedRequestIDs.removeAll()
        lock.unlock()
    }

    /// Prepares an SDK frame without retiring any response ID. Ordinary ownership is
    /// committed only after the complete frame passes its final delivery-deadline
    /// check. After terminal sealing, strips every late response while preserving
    /// unrelated notifications or responses from the same batch.
    package func prepareServerFrameForDelivery(_ frame: Data) -> DeliveryPreparation {
        let responseMetadata = JSONRPCBridgeFrameInspector.inspectPermissively(
            frame,
            direction: .serverToClient
        )
        let responseIDs = responseMetadata.compactMap { metadata -> JSONRPCBridgeID? in
            guard case .response = metadata.kind,
                  let id = metadata.id,
                  id != .null
            else {
                return nil
            }
            return id
        }
        let hasExplicitNullResponse = responseMetadata.contains { metadata in
            guard case .response = metadata.kind else { return false }
            return metadata.id == .null
        }

        lock.lock()
        let suppressedIDs = sealedRequestIDs.union(cancelledRequestIDs)
        let isSealed = isSealed
        let hasOwnershipFailure = ownershipFailure != nil
        lock.unlock()

        if hasOwnershipFailure {
            return .suppressed(phase: "client_cancellation_ownership_failure", terminalReason: "client_cancellation_ownership_failure")
        }
        let sealPolicy: PreparedFrameSealPolicy = isSealed ? .allowAfterSeal : .preemptIfSealed
        guard (isSealed && hasExplicitNullResponse) || responseIDs.contains(where: suppressedIDs.contains) else {
            return .frame(PreparedFrame(data: frame, sealPolicy: sealPolicy))
        }
        guard let retained = Self.removingResponses(
            for: suppressedIDs,
            removingExplicitNullResponses: isSealed && hasExplicitNullResponse,
            from: frame
        ) else {
            return isSealed
                ? .suppressed(phase: "watchdog_late_response_suppressed", terminalReason: "tool_execution_watchdog")
                : .suppressed(phase: "client_cancelled_response_suppressed", terminalReason: nil)
        }
        return .frame(PreparedFrame(data: retained, sealPolicy: sealPolicy))
    }

    /// Retires exact response identities only after a complete ordinary frame is on
    /// the wire and its absolute delivery deadline remains valid.
    package func recordDeliveredServerFrame(_ frame: Data) {
        let responseIDs = JSONRPCBridgeFrameInspector.inspectPermissively(
            frame,
            direction: .serverToClient
        ).compactMap { metadata -> JSONRPCBridgeID? in
            guard case .response = metadata.kind,
                  let id = metadata.id,
                  id != .null
            else {
                return nil
            }
            return id
        }
        guard !responseIDs.isEmpty else { return }

        lock.lock()
        pendingRequestIDSet.subtract(responseIDs)
        pendingRequestIDs.removeAll { responseIDs.contains($0) }
        lock.unlock()
    }

    private static func removingResponses(
        for sealedIDs: Set<JSONRPCBridgeID>,
        removingExplicitNullResponses: Bool = false,
        from frame: Data
    ) -> Data? {
        let hadNewline = frame.last == UInt8(ascii: "\n")
        let unframed = hadNewline ? Data(frame.dropLast()) : frame
        guard let root = try? JSONSerialization.jsonObject(with: unframed, options: [.fragmentsAllowed]) else {
            // The SDK only emits valid JSON-RPC frames. Fail closed here rather than
            // letting an uninspectable late response violate the terminal claim.
            return nil
        }

        func isSealedResponse(_ object: Any) -> Bool {
            guard let message = object as? [String: Any],
                  message["result"] != nil || message["error"] != nil,
                  let id = JSONRPCBridgeID.parseJSONValue(message["id"])
            else {
                return false
            }
            return (removingExplicitNullResponses && id == .null) || sealedIDs.contains(id)
        }

        if let message = root as? [String: Any] {
            return isSealedResponse(message) ? nil : frame
        }
        guard let batch = root as? [Any] else { return frame }
        let retained = batch.filter { !isSealedResponse($0) }
        guard !retained.isEmpty,
              var encoded = try? JSONSerialization.data(withJSONObject: retained, options: [.sortedKeys])
        else {
            return nil
        }
        if hadNewline { encoded.append(UInt8(ascii: "\n")) }
        return encoded
    }
}

package enum MCPClientCancellationOwnershipError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case retentionCapacityExceeded(Int)
    case cancelledIDReuse(JSONRPCBridgeID)

    package var description: String {
        switch self {
        case let .retentionCapacityExceeded(limit): "MCP cancelled request retention capacity exceeded (\(limit))"
        case let .cancelledIDReuse(id): "MCP cancelled request ID cannot be reused on this connection: \(id)"
        }
    }

    package var errorDescription: String? {
        description
    }
}
