import Foundation

struct CursorFigmaMCPLoginDescriptor: FigmaMCPProviderLoginDescribing {
    static let remoteURL = "https://mcp.figma.com/mcp"
    static let evidenceID = "cursor-figma-mcp-login"
    static let capabilityRevision = "2026-08-30"
    let provider: ExternalMCPRuntimeProvider = .cursor
    let executableProfile: CLILaunchProfile = CLILaunchProfiles.cursor
    let minimumSupportedVersion: String? = nil
    let evidence = FigmaMCPProviderCapabilityEvidence(provider: .cursor, evidenceID: evidenceID, capabilityRevision: capabilityRevision)
    func loginArguments(targetIdentifier: String) -> [String] {
        ["mcp", "login", targetIdentifier]
    }
}

enum CursorFigmaMCPConfigParser {
    static func matchingServerNames(in data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any]
        else { return [] }

        var matches: [String] = []
        for (name, rawEntry) in servers {
            guard !name.isEmpty,
                  let entry = rawEntry as? [String: Any],
                  entry["command"] == nil,
                  entry["args"] == nil
            else { return [] }
            if let rawURL = entry["url"] {
                guard let url = rawURL as? String else { return [] }
                if url == CursorFigmaMCPLoginDescriptor.remoteURL {
                    matches.append(name)
                }
            }
        }
        return matches.sorted()
    }
}

struct CursorFigmaMCPTargetResolver: FigmaMCPProviderTargetResolving {
    typealias DataLoader = @Sendable (URL) -> Data?

    let runtimeProvider: ExternalMCPRuntimeProvider = .cursor
    let configURL: URL
    private let dataLoader: DataLoader

    init(
        configURL: URL? = nil,
        dataLoader: @escaping DataLoader = { try? Data(contentsOf: $0) }
    ) {
        self.configURL = configURL ?? Self.standardUserProfileConfigURL
        self.dataLoader = dataLoader
    }

    private static var standardUserProfileConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor/mcp.json")
    }

    func resolveTarget(for target: ExternalMCPIntegrationTarget) async -> FigmaMCPProviderTargetResolution {
        guard target == .figma else { return .missing(reason: .unsupportedProviderContext) }
        guard configURL.standardizedFileURL.resolvingSymlinksInPath()
            == Self.standardUserProfileConfigURL.standardizedFileURL.resolvingSymlinksInPath()
        else { return .untrustedCredentialContext(reason: .customHomeOrConfig) }
        guard let data = dataLoader(configURL) else { return .missing(reason: .unavailableProviderMetadata) }
        let names = CursorFigmaMCPConfigParser.matchingServerNames(in: data)
        switch names.count {
        case 0: return .missing(reason: .noCanonicalMatch)
        case 1: return .resolved(providerTargetIdentifier: names[0], source: .providerStandardUserMetadata, credentialContext: .providerDefaultUserProfile)
        default: return .ambiguous(matchCount: names.count)
        }
    }
}
