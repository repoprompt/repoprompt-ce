import Foundation

struct OpenCodeFigmaMCPLoginDescriptor: FigmaMCPProviderLoginDescribing {
    static let remoteURL = "https://mcp.figma.com/mcp"
    static let evidenceID = "opencode-figma-mcp-login"
    static let capabilityRevision = "2026-08-30"
    let provider: ExternalMCPRuntimeProvider = .openCode
    let executableProfile: CLILaunchProfile = CLILaunchProfiles.openCode
    let minimumSupportedVersion: String? = nil
    let evidence = FigmaMCPProviderCapabilityEvidence(provider: .openCode, evidenceID: evidenceID, capabilityRevision: capabilityRevision)
    func loginArguments(targetIdentifier: String) -> [String] {
        ["mcp", "auth", targetIdentifier]
    }
}

enum OpenCodeFigmaMCPConfigParser {
    static func matchingServerNames(in data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcp"] as? [String: Any]
        else { return [] }

        var matches: [String] = []
        for (name, rawEntry) in servers {
            guard !name.isEmpty,
                  let entry = rawEntry as? [String: Any],
                  entry["type"] as? String == "remote"
            else { return [] }
            if let rawURL = entry["url"] {
                guard let url = rawURL as? String else { return [] }
                if url == OpenCodeFigmaMCPLoginDescriptor.remoteURL {
                    matches.append(name)
                }
            }
        }
        return matches.sorted()
    }
}

struct OpenCodeFigmaMCPTargetResolver: FigmaMCPProviderTargetResolving {
    let runtimeProvider: ExternalMCPRuntimeProvider = .openCode
    let configURL: URL
    init(configURL: URL? = nil) {
        self.configURL = configURL ?? OpenCodeIntegrationConfiguration.configURL()
    }

    func resolveTarget(for target: ExternalMCPIntegrationTarget) async -> FigmaMCPProviderTargetResolution {
        guard target == .figma else { return .missing(reason: .unsupportedProviderContext) }
        guard configURL.standardizedFileURL.resolvingSymlinksInPath()
            == OpenCodeIntegrationConfiguration.configURL().standardizedFileURL.resolvingSymlinksInPath()
        else { return .untrustedCredentialContext(reason: .customHomeOrConfig) }
        guard let data = try? Data(contentsOf: configURL) else { return .missing(reason: .unavailableProviderMetadata) }
        let names = OpenCodeFigmaMCPConfigParser.matchingServerNames(in: data)
        switch names.count {
        case 0: return .missing(reason: .noCanonicalMatch)
        case 1: return .resolved(providerTargetIdentifier: names[0], source: .providerStandardUserMetadata, credentialContext: .providerDefaultUserProfile)
        default: return .ambiguous(matchCount: names.count)
        }
    }
}
