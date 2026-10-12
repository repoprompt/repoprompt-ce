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

    nonisolated static func encode(_ reply: HistoryToolReply) throws -> Value {
        let value = switch reply {
        case let .listSessions(dto): try Value(dto)
        case let .search(dto): try Value(dto)
        case let .time(dto): try Value(dto)
        case let .getSession(dto): try Value(dto)
        case let .error(dto): try Value(dto)
        }
        guard var object = value.objectValue,
              object["scan_truncated"]?.boolValue == true
              || object["skipped_workspaces"]?.arrayValue?.isEmpty == false
        else { return value }
        object["scan_complete"] = .bool(false)
        if object["total_sessions"] != nil || object["total_matches"] != nil {
            object["totals_are_lower_bounds"] = .bool(true)
        }
        object["scan_note"] = .string(
            "Incomplete scan: reported totals are lower bounds. No matches does not prove there are no sessions or matches; narrow the workspace/session/date scope or refresh skipped indexes before concluding it is empty."
        )
        return .object(object)
    }
}
