import Foundation

struct MCPServerCatalog: Equatable {
    struct Server: Equatable {
        let name: String
        let transport: Transport
        let policy: Policy

        init(name: String, transport: Transport, policy: Policy? = nil) {
            self.name = name
            self.transport = transport
            self.policy = policy ?? (
                MCPServerCatalog.isRepoPrompt(name)
                    ? Policy(enabled: true, required: true)
                    : Policy()
            )
        }
    }

    struct Policy: Equatable {
        let enabled: Bool?
        let required: Bool?
        let enabledTools: [String]?
        let tools: [String]?
        let supportsParallelToolCalls: Bool?
        let toolTimeoutSeconds: Int?

        init(
            enabled: Bool? = nil,
            required: Bool? = nil,
            enabledTools: [String]? = nil,
            tools: [String]? = nil,
            supportsParallelToolCalls: Bool? = nil,
            toolTimeoutSeconds: Int? = nil
        ) {
            self.enabled = enabled
            self.required = required
            self.enabledTools = enabledTools
            self.tools = tools
            self.supportsParallelToolCalls = supportsParallelToolCalls
            self.toolTimeoutSeconds = toolTimeoutSeconds
        }
    }

    enum Transport: Equatable {
        case stdio(command: String, args: [String], environment: [String: String])
        case http(url: String)
    }

    enum MigrationError: Error, Equatable {
        case malformedHeader(String)
        case malformedValue(server: String, key: String)
        case duplicateValue(server: String, key: String)
        case duplicateServer(String)
        case invalidDefinition(String)
    }

    let servers: [Server]

    init(servers: [Server]) throws {
        var normalizedNames = Set<String>()
        for server in servers {
            let normalized = Self.normalizedName(server.name)
            guard !normalized.isEmpty, normalizedNames.insert(normalized).inserted else {
                throw MigrationError.duplicateServer(server.name)
            }
            try Self.validate(server)
        }
        self.servers = servers.sorted {
            Self.normalizedName($0.name) < Self.normalizedName($1.name)
        }
    }

    func selectedServers(enabledNames: Set<String>) -> [Server] {
        let selected = Set(enabledNames.map(Self.normalizedName))
        return servers.filter { server in
            Self.isRepoPrompt(server.name)
                || server.policy.required == true
                || selected.contains(Self.normalizedName(server.name))
        }
    }

    func selectedServers(enabledNames: [String]) -> [Server] {
        selectedServers(enabledNames: Set(enabledNames))
    }

    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isRepoPrompt(_ name: String) -> Bool {
        normalizedName(name) == normalizedName(RepoPromptMCPServerConfiguration.defaultServerName)
    }

    private static func validate(_ server: Server) throws {
        switch server.transport {
        case let .stdio(command, _, _):
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MigrationError.invalidDefinition(server.name)
            }
        case let .http(url):
            guard let components = URLComponents(string: url),
                  let scheme = components.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  components.host?.isEmpty == false,
                  !url.contains(where: \.isWhitespace)
            else {
                throw MigrationError.invalidDefinition(server.name)
            }
        }
    }
}
