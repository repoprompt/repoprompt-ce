import Foundation

/// Persisted routing state for MCP client connections.
/// Allows routing to survive app restarts and connection churn.
struct MCPRoutingState: Codable {
    struct ClientRecord: Codable {
        /// MCP clientInfo.name – canonical identity string
        var clientID: String

        /// Last known transport for this client (for debugging)
        enum Transport: String, Codable {
            case network
            case filesystem
        }

        var lastTransport: Transport

        /// Optional "session key" to disambiguate multiple instances of same client.
        /// Correlates CLI sessions across reconnections.
        var sessionKey: String?

        /// Last known RepoPrompt window ID for this client (if still valid)
        var lastWindowID: Int?

        /// Last known workspace UUID - stable across restarts
        var lastWorkspaceID: UUID?

        /// Last known workspace instance number - deterministic after restore
        /// Used as fallback when workspace UUID doesn't match (e.g., user didn't restore workspaces)
        var lastWorkspaceInstanceNumber: Int?

        /// For debugging / dashboards
        var lastConnectionUUID: UUID?

        /// Last time this record was confirmed by a live connection
        var lastSeenAt: Date
    }

    /// Keyed by clientID (and refined by sessionKey in helpers)
    var records: [String: [ClientRecord]] = [:]
}

/// Storage helper for MCPRoutingState persistence.
enum MCPRoutingStateStore {
    /// Set to true to enable debug logging for MCP routing state operations
    static var debugLoggingEnabled = false
    private static var url: URL {
        MCPFilesystemConstants.identity.routingStateURL()
    }

    static func load() -> MCPRoutingState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard
            let data = try? Data(contentsOf: url),
            let state = try? decoder.decode(MCPRoutingState.self, from: data)
        else {
            #if DEBUG
                if debugLoggingEnabled {
                    print("[MCPRoutingStateStore] load() - no existing state or decode failed at \(url.path)")
                }
            #endif
            return MCPRoutingState()
        }
        #if DEBUG
            if debugLoggingEnabled {
                print("[MCPRoutingStateStore] load() - loaded \(state.records.count) clients from \(url.path)")
                for (clientID, records) in state.records {
                    for r in records {
                        print("[MCPRoutingStateStore]   client='\(clientID)' sessionKey=\(r.sessionKey?.prefix(8) ?? "nil") wsID=\(r.lastWorkspaceID?.uuidString.prefix(8) ?? "nil") inst=\(r.lastWorkspaceInstanceNumber ?? -1) window=\(r.lastWindowID ?? -1)")
                    }
                }
            }
        #endif
        return state
    }

    static func save(_ state: MCPRoutingState) {
        // Ensure directory exists
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
