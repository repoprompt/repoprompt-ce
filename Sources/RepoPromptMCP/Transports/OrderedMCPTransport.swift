import Foundation
import Logging
import MCP

/// Tracks completion of the actual transport send for registered JSON-RPC request IDs.
/// The SDK's `Client.send` returns before its internally spawned request task necessarily starts.
actor MCPRequestSendBarrier {
    private enum Completion {
        case sent
        case failed(String)
    }

    private struct State {
        var completion: Completion?
        var waiters: [CheckedContinuation<Completion, Never>] = []
    }

    private var states: [ID: State] = [:]

    func register(requestID: ID) {
        states[requestID] = State()
    }

    func waitUntilSent(requestID: ID) async throws {
        let completion = await withCheckedContinuation { (continuation: CheckedContinuation<Completion, Never>) in
            guard var state = states[requestID] else {
                continuation.resume(returning: .failed("MCP request send barrier was not registered"))
                return
            }
            if let completion = state.completion {
                states.removeValue(forKey: requestID)
                continuation.resume(returning: completion)
            } else {
                state.waiters.append(continuation)
                states[requestID] = state
            }
        }

        switch completion {
        case .sent:
            return
        case let .failed(reason):
            throw MCPRequestSendBarrierError.sendFailed(reason)
        }
    }

    func cancel(requestID: ID) {
        guard let state = states.removeValue(forKey: requestID) else { return }
        for waiter in state.waiters {
            waiter.resume(returning: .failed("MCP request send was abandoned before delivery"))
        }
    }

    func didSend(requestIDs: [ID]) {
        complete(requestIDs: requestIDs, with: .sent)
    }

    func didFailToSend(requestIDs: [ID], error: Error) {
        complete(requestIDs: requestIDs, with: .failed(String(describing: error)))
    }

    private func complete(requestIDs: [ID], with completion: Completion) {
        for requestID in requestIDs {
            guard var state = states[requestID] else { continue }
            if state.waiters.isEmpty {
                state.completion = completion
                states[requestID] = state
            } else {
                states.removeValue(forKey: requestID)
                state.waiters.forEach { $0.resume(returning: completion) }
            }
        }
    }
}

enum MCPRequestSendBarrierError: Error {
    case sendFailed(String)
}

/// Observes request writes through the SDK's public transport seam so cancellation can be ordered after them.
actor OrderedMCPTransport: Transport {
    nonisolated let logger: Logger

    private struct OutboundEnvelope: Decodable {
        let id: ID?
        let method: String?
    }

    private let underlying: any Transport
    private let requestSendBarrier: MCPRequestSendBarrier
    private var receiveStream: AsyncThrowingStream<Data, Error>?

    init(
        underlying: any Transport,
        requestSendBarrier: MCPRequestSendBarrier,
        logger: Logger
    ) {
        self.underlying = underlying
        self.requestSendBarrier = requestSendBarrier
        self.logger = logger
    }

    func connect() async throws {
        try await underlying.connect()
        receiveStream = await underlying.receive()
    }

    func disconnect() async {
        await underlying.disconnect()
    }

    func send(_ data: Data) async throws {
        let requestIDs = Self.requestIDs(in: data)
        do {
            try await underlying.send(data)
            await requestSendBarrier.didSend(requestIDs: requestIDs)
        } catch {
            await requestSendBarrier.didFailToSend(requestIDs: requestIDs, error: error)
            throw error
        }
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        guard let receiveStream else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: MCPError.internalError("Ordered MCP transport is not connected"))
            }
        }
        return receiveStream
    }

    private nonisolated static func requestIDs(in data: Data) -> [ID] {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(OutboundEnvelope.self, from: data),
           envelope.method != nil,
           let id = envelope.id
        {
            return [id]
        }
        if let envelopes = try? decoder.decode([OutboundEnvelope].self, from: data) {
            return envelopes.compactMap { envelope in
                guard envelope.method != nil else { return nil }
                return envelope.id
            }
        }
        return []
    }
}
