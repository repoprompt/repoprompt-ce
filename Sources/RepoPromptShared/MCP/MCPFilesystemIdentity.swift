import Darwin
import Foundation

/// Shared filesystem and stable-name authority for RepoPrompt MCP products.
///
/// Callers select their build flavor locally and pass it explicitly so this
/// shared target never depends on compile-configuration conditionals.
public struct MCPFilesystemIdentity: Equatable, Sendable {
    public enum Product: String, Sendable {
        case repoPromptCE
    }

    public enum BuildFlavor: String, Sendable {
        case debug
        case release
    }

    public static let currentProtocolVersion = 7

    public let product: Product
    public let buildFlavor: BuildFlavor
    public let protocolVersion: Int

    public init(
        product: Product,
        buildFlavor: BuildFlavor,
        protocolVersion: Int = Self.currentProtocolVersion
    ) {
        self.product = product
        self.buildFlavor = buildFlavor
        self.protocolVersion = protocolVersion
    }

    public static func repoPromptCE(_ buildFlavor: BuildFlavor) -> Self {
        Self(product: .repoPromptCE, buildFlavor: buildFlavor)
    }

    public var socketDirectoryName: String {
        switch product {
        case .repoPromptCE:
            "repoprompt-ce-mcp"
        }
    }

    public var bootstrapSocketName: String {
        switch (product, buildFlavor) {
        case (.repoPromptCE, .debug):
            "repoprompt-ce-D-\(protocolVersion).sock"
        case (.repoPromptCE, .release):
            "repoprompt-ce-\(protocolVersion).sock"
        }
    }

    public var externalEventsDirectoryName: String {
        switch (product, buildFlavor) {
        case (.repoPromptCE, .debug):
            "MCPEvents-CE-D-\(protocolVersion)"
        case (.repoPromptCE, .release):
            "MCPEvents-CE-\(protocolVersion)"
        }
    }

    public var applicationSupportDirectoryName: String {
        switch product {
        case .repoPromptCE:
            "RepoPrompt CE"
        }
    }

    public var killSignalsDirectoryName: String {
        switch (product, buildFlavor) {
        case (.repoPromptCE, .debug):
            "MCPKillSignals-CE-D-\(protocolVersion)"
        case (.repoPromptCE, .release):
            "MCPKillSignals-CE-\(protocolVersion)"
        }
    }

    public var stableWrapperConfigFileName: String {
        switch buildFlavor {
        case .debug:
            "discovery_debug.json"
        case .release:
            "discovery.json"
        }
    }

    public var networkConfigFileName: String {
        switch buildFlavor {
        case .debug:
            "mcp-config_debug.json"
        case .release:
            "mcp-config.json"
        }
    }

    public var routingStateFileName: String {
        switch buildFlavor {
        case .debug:
            "mcp-routing_debug.json"
        case .release:
            "mcp-routing.json"
        }
    }

    public var userSpaceCLIFileName: String {
        switch buildFlavor {
        case .debug:
            "repoprompt_ce_cli_debug"
        case .release:
            "repoprompt_ce_cli"
        }
    }

    public var pathCLICommandName: String {
        switch buildFlavor {
        case .debug:
            "rpce-cli-debug"
        case .release:
            "rpce-cli"
        }
    }

    public var claudeWrapperCommandName: String {
        switch buildFlavor {
        case .debug:
            "claude-rpce-debug"
        case .release:
            "claude-rpce"
        }
    }

    public func socketDirectoryURL(userID: uid_t = getuid()) -> URL {
        URL(fileURLWithPath: "/tmp/\(socketDirectoryName)-\(userID)", isDirectory: true)
    }

    public func bootstrapSocketURL(userID: uid_t = getuid()) -> URL {
        socketDirectoryURL(userID: userID).appendingPathComponent(bootstrapSocketName, isDirectory: false)
    }

    public func applicationSupportRootURL(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
    }

    public func configDirectoryURL(fileManager: FileManager = .default) -> URL {
        applicationSupportRootURL(fileManager: fileManager)
            .appendingPathComponent("MCP", isDirectory: true)
    }

    public func stableWrapperConfigURL(fileManager: FileManager = .default) -> URL {
        configDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(stableWrapperConfigFileName, isDirectory: false)
    }

    public func launchConfigDirectoryURL(fileManager: FileManager = .default) -> URL {
        configDirectoryURL(fileManager: fileManager)
            .appendingPathComponent("LaunchConfigs", isDirectory: true)
    }

    public func externalEventsDirectoryURL(fileManager: FileManager = .default) -> URL {
        applicationSupportRootURL(fileManager: fileManager)
            .appendingPathComponent(externalEventsDirectoryName, isDirectory: true)
    }

    public func killSignalsDirectoryURL(fileManager: FileManager = .default) -> URL {
        applicationSupportRootURL(fileManager: fileManager)
            .appendingPathComponent(killSignalsDirectoryName, isDirectory: true)
    }

    public func networkConfigURL(fileManager: FileManager = .default) -> URL {
        configDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(networkConfigFileName, isDirectory: false)
    }

    public func routingStateURL(fileManager: FileManager = .default) -> URL {
        configDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(routingStateFileName, isDirectory: false)
    }

    public func userSpaceCLIURL(fileManager: FileManager = .default) -> URL {
        applicationSupportRootURL(fileManager: fileManager)
            .appendingPathComponent(userSpaceCLIFileName, isDirectory: false)
    }
}
