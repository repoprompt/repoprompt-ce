import Foundation
import MCP

enum DirectHeadlessInvocationProgress {
    @TaskLocal static var reporter: (@Sendable (String) async -> Void)?

    static func report(_ message: String) async {
        await reporter?(String(message.prefix(512)))
    }
}

actor DirectHeadlessMCPProgressTransport {
    private let server: Server
    private let token: ProgressToken
    private var sequence: Double = 0
    private var isTerminal = false

    init(server: Server, token: ProgressToken) {
        self.server = server
        self.token = token
    }

    func send(_ message: String) async {
        guard !isTerminal else { return }
        sequence += 1
        do {
            try await server.notify(ProgressNotification.message(.init(
                progressToken: token,
                progress: sequence,
                message: String(message.prefix(512))
            )))
        } catch {
            // Progress is advisory; tool execution continues when delivery fails.
        }
    }

    func markTerminal() {
        isTerminal = true
    }
}
