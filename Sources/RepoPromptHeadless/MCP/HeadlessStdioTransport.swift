import Foundation

final class HeadlessStdioTransport {
    private let server: HeadlessMCPServer
    private let writer: HeadlessStdoutWriter
    private let responseTracker = HeadlessTransportResponseTracker()
    private var decoder = HeadlessNewlineFrameDecoder()
    private var terminated = false

    init(server: HeadlessMCPServer, writer: HeadlessStdoutWriter) {
        self.server = server
        self.writer = writer
    }

    func run() async throws {
        while !terminated {
            let chunk = FileHandle.standardInput.availableData
            if chunk.isEmpty {
                await finish()
                return
            }
            if await receive(chunk) {
                await waitForPendingResponses()
                return
            }
        }
    }

    /// Feeds bytes into the newline-delimited transport without waiting for long-running
    /// request work. This is also the deterministic test seam for lifecycle interleaving.
    @discardableResult
    func receive(_ chunk: Data) async -> Bool {
        guard !terminated else { return true }
        return await handle(events: decoder.append(chunk))
    }

    func finish() async {
        guard !terminated else {
            await waitForPendingResponses()
            return
        }
        _ = await handle(events: decoder.finish())
        await server.cancelActiveRequests()
        await waitForPendingResponses()
        terminated = true
    }

    func waitForPendingResponses() async {
        await responseTracker.waitForAll()
    }

    private func handle(events: [HeadlessNewlineFrameDecoder.Event]) async -> Bool {
        for event in events {
            switch event {
            case let .frame(frame):
                let submission = await server.submit(frame: frame)
                switch submission {
                case let .completed(action):
                    if let responseData = action.responseData {
                        await writer.write(responseData)
                    }
                    if action.shouldExit {
                        terminated = true
                        return true
                    }
                case let .pending(task):
                    await responseTracker.track(requestTask: task, writer: writer)
                }
            case let .parseError(message):
                await writer.write(
                    HeadlessJSONRPC.errorResponse(
                        id: NSNull(),
                        code: -32700,
                        message: message
                    )
                )
            }
        }
        return false
    }
}

private actor HeadlessTransportResponseTracker {
    private var deliveries: [UUID: Task<Void, Never>] = [:]

    func track(requestTask: Task<HeadlessRPCAction, Never>, writer: HeadlessStdoutWriter) {
        let deliveryID = UUID()
        let delivery = Task { [weak self] in
            let action = await requestTask.value
            if let responseData = action.responseData {
                await writer.write(responseData)
            }
            await self?.finished(deliveryID)
        }
        deliveries[deliveryID] = delivery
    }

    func waitForAll() async {
        while let delivery = deliveries.values.first {
            await delivery.value
        }
    }

    private func finished(_ deliveryID: UUID) {
        deliveries.removeValue(forKey: deliveryID)
    }
}
