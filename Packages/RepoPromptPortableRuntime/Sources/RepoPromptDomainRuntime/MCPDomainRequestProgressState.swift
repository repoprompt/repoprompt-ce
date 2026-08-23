import Foundation
import MCP

public enum MCPProgressDeliveryResult: Equatable, Sendable {
    case delivered
    case failed
    case connectionTerminal
}

/// Physical transport capability required by protocol-neutral request progress.
public protocol MCPDomainProgressTransport: Actor {
    func deliverMCPProgress(
        token: ProgressToken,
        progress: Double,
        message: String?
    ) async -> MCPProgressDeliveryResult
}

public struct MCPDomainRequestProgressHandle: Hashable, Sendable {
    public let stateID: UUID
    public let connectionID: UUID
    public let invocationID: UUID

    public init(stateID: UUID, connectionID: UUID, invocationID: UUID) {
        self.stateID = stateID
        self.connectionID = connectionID
        self.invocationID = invocationID
    }
}

/// Request-scoped standard MCP progress state. Progress is advisory: one delivery
/// may be in flight and one latest-wins update may be pending. Finalization stops
/// admission and discards the pending update without waiting for transport I/O;
/// the already in-flight notification may therefore trail the final result.
public actor MCPRequestProgressState {
    private struct PendingDelivery {
        let connection: any MCPDomainProgressTransport
        let message: String?
    }

    private let token: ProgressToken
    private var sequence: Double = 0
    private var acceptsProgress = true
    private var pendingDelivery: PendingDelivery?
    private var deliveryWorker: Task<Void, Never>?
    #if DEBUG
        private var quiescenceContinuations: [CheckedContinuation<Void, Never>] = []
    #endif

    public init(token: ProgressToken) {
        self.token = token
    }

    public func send(
        through connection: any MCPDomainProgressTransport,
        message: String?
    ) {
        guard acceptsProgress else { return }
        pendingDelivery = PendingDelivery(connection: connection, message: message)
        guard deliveryWorker == nil else { return }

        deliveryWorker = Task { [weak self] in
            await self?.deliverBurst()
        }
    }

    public func invalidate() {
        acceptsProgress = false
        pendingDelivery = nil
    }

    private func deliverBurst() async {
        while acceptsProgress, let delivery = pendingDelivery {
            pendingDelivery = nil
            sequence += 1
            let progress = sequence

            let result = await delivery.connection.deliverMCPProgress(
                token: token,
                progress: progress,
                message: delivery.message
            )
            if result == .connectionTerminal {
                acceptsProgress = false
                pendingDelivery = nil
                break
            }
        }

        deliveryWorker = nil
        #if DEBUG
            let continuations = quiescenceContinuations
            quiescenceContinuations = []
            continuations.forEach { $0.resume() }
        #endif
    }

    #if DEBUG
        public struct Snapshot: Equatable, Sendable {
            public let acceptsProgress: Bool
            public let pendingDeliveryCount: Int
            public let workerActive: Bool
            public let assignedSequence: Double
        }

        public func snapshot() -> Snapshot {
            Snapshot(
                acceptsProgress: acceptsProgress,
                pendingDeliveryCount: pendingDelivery == nil ? 0 : 1,
                workerActive: deliveryWorker != nil,
                assignedSequence: sequence
            )
        }

        public func waitUntilQuiescent() async {
            guard deliveryWorker != nil else { return }
            await withCheckedContinuation { continuation in
                quiescenceContinuations.append(continuation)
            }
        }
    #endif
}
