import Foundation

struct ClaudeCodeFigmaMCPLoginDescriptor: FigmaMCPProviderLoginDescribing {
    static let targetIdentifier = "plugin:figma:figma"
    static let evidenceID = "claude-code-figma-mcp-login"
    static let capabilityRevision = "2026-08-30"

    let provider: ExternalMCPRuntimeProvider = .claudeCode
    let executableProfile: CLILaunchProfile = CLILaunchProfiles.claudeCode
    let minimumSupportedVersion: String? = "2.1.186"
    let evidence = FigmaMCPProviderCapabilityEvidence(provider: .claudeCode, evidenceID: evidenceID, capabilityRevision: capabilityRevision)

    func loginArguments(targetIdentifier: String) -> [String] {
        ["mcp", "login", targetIdentifier]
    }
}

enum ClaudeCodeFigmaMCPLogoutDescriptor {
    static let evidenceID = "claude-code-figma-mcp-logout"
    static let capabilityRevision = "2026-09-01"
    static let evidence = FigmaMCPProviderCapabilityEvidence(
        provider: .claudeCode,
        evidenceID: evidenceID,
        capabilityRevision: capabilityRevision
    )
}

struct ClaudeCodeFigmaMCPTargetResolver: FigmaMCPProviderTargetResolving {
    let runtimeProvider: ExternalMCPRuntimeProvider = .claudeCode

    func resolveTarget(for target: ExternalMCPIntegrationTarget) async -> FigmaMCPProviderTargetResolution {
        guard target == .figma else { return .missing(reason: .unsupportedProviderContext) }
        return .resolved(providerTargetIdentifier: ClaudeCodeFigmaMCPLoginDescriptor.targetIdentifier, source: .reviewedFixedIdentifier, credentialContext: .providerDefaultUserProfile)
    }
}
