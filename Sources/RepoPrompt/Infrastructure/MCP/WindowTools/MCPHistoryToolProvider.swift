import Foundation
import MCP
import RepoPromptDomainRuntime

/// App physical backend for the shared domain-owned `history` provider.
@MainActor
final class MCPHistoryToolProvider {
    private let scanner: any HistorySessionScanning

    init(
        runtime _: MCPAppToolBinder,
        workspaceStore: DomainWorkspaceStore? = nil,
        scannerFactory: (@Sendable () -> any HistorySessionScanning)? = nil
    ) {
        scanner = scannerFactory?() ?? HistorySessionScanner(
            workspaceLocations: HistoryWorkspaceLocationResolver(workspaceStore: workspaceStore)
        )
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

/// Translates the existing workspace owner's location evidence; it creates no new authority.
extension HistoryWorkspaceLocationResolver {
    init(workspaceStore: DomainWorkspaceStore?) {
        self.init(workspaceStore: { workspaceStore })
    }

    /// Resolve the store for every read so a retained app service cannot capture a replaced runtime.
    init(workspaceStore: @escaping @Sendable () -> DomainWorkspaceStore?) {
        self.init { selector in
            guard let store = workspaceStore() else { return .unavailable }
            let domainSelector: DomainWorkspaceReadSelector = switch selector {
            case let .id(id): .id(id)
            case let .exactName(name): .exactName(name)
            }
            switch await store.readLocation(matching: domainSelector) {
            case let .matched(location):
                return .matched(HistoryWorkspaceLocation(
                    runtimeID: location.runtimeID,
                    lifecycleGeneration: location.lifecycleGeneration,
                    locationGeneration: location.locationGeneration,
                    workspaceID: location.workspaceID,
                    name: location.name,
                    directory: location.directory
                ))
            case .ambiguous: return .ambiguous
            case .unavailable: return .unavailable
            case .notReady: return .notReady
            case .notRegistered: return .notRegistered
            }
        }
    }
}
