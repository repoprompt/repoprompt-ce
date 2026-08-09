import Foundation
import MCP
import RepoPromptDomainRuntime

/// App physical backend for the shared domain-owned `history` provider.
@MainActor
final class MCPHistoryToolProvider {
    private let scanner: any HistorySessionScanning

    init(
        runtime _: MCPAppToolBinder,
        scannerFactory: @escaping @Sendable () -> any HistorySessionScanning = { HistorySessionScanner() }
    ) {
        scanner = scannerFactory()
    }

    func executeDomainRead(
        context _: DomainReadInvocationContext,
        args: [String: Value]
    ) async throws -> Value {
        try await execute(args: args)
    }

    func execute(args: [String: Value]) async throws -> Value {
        let reply = try await HistoryMCPToolService.execute(args: args, scanner: scanner)
        return try Self.encode(reply)
    }

    // MARK: - Reply Encoding

    private nonisolated static func encode(_ reply: HistoryToolReply) throws -> Value {
        switch reply {
        case let .listSessions(dto): try Value(dto)
        case let .search(dto): try Value(dto)
        case let .time(dto): try Value(dto)
        case let .getSession(dto): try Value(dto)
        case let .error(dto): try Value(dto)
        }
    }
}
