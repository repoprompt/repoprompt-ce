import Foundation

public struct ProviderPermissionID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct ResolvedProviderPermissions: Codable, Hashable, Sendable {
    public let executionMode: ProviderExecutionMode
    public let filesystemRead: Bool
    public let filesystemWrite: Bool
    public let worktreeAccess: Bool
    public let artifactRead: Bool
    public let projectSourceRead: Bool
    public let scopedResources: Set<OwnedResourceReference>

    public init(
        executionMode: ProviderExecutionMode,
        filesystemRead: Bool,
        filesystemWrite: Bool,
        worktreeAccess: Bool,
        artifactRead: Bool,
        projectSourceRead: Bool,
        scopedResources: Set<OwnedResourceReference> = []
    ) {
        self.executionMode = executionMode
        self.filesystemRead = filesystemRead
        self.filesystemWrite = filesystemWrite
        self.worktreeAccess = worktreeAccess
        self.artifactRead = artifactRead
        self.projectSourceRead = projectSourceRead
        self.scopedResources = scopedResources
    }

    public static func readOnly(scopedResources: Set<OwnedResourceReference> = []) -> Self {
        .init(
            executionMode: .readOnly,
            filesystemRead: true,
            filesystemWrite: false,
            worktreeAccess: false,
            artifactRead: true,
            projectSourceRead: true,
            scopedResources: scopedResources
        )
    }

    public static func workspaceWrite(scopedResources: Set<OwnedResourceReference> = []) -> Self {
        .init(
            executionMode: .workspaceWrite,
            filesystemRead: true,
            filesystemWrite: true,
            worktreeAccess: true,
            artifactRead: true,
            projectSourceRead: true,
            scopedResources: scopedResources
        )
    }

    public static func fullAccess(scopedResources: Set<OwnedResourceReference> = []) -> Self {
        .init(
            executionMode: .fullAccess,
            filesystemRead: true,
            filesystemWrite: true,
            worktreeAccess: true,
            artifactRead: true,
            projectSourceRead: true,
            scopedResources: scopedResources
        )
    }
}

public struct CodexTurnSettings: Codable, Hashable, Sendable {
    public let bashEnabled: Bool
    public let searchEnabled: Bool
    public let goalsEnabled: Bool
    public let reasoningSummariesEnabled: Bool
    public let memoriesEnabled: Bool
    public let mcpServerIDs: Set<String>

    public init(
        bashEnabled: Bool = true,
        searchEnabled: Bool = true,
        goalsEnabled: Bool = true,
        reasoningSummariesEnabled: Bool = false,
        memoriesEnabled: Bool = false,
        mcpServerIDs: Set<String> = ["repoprompt"]
    ) {
        self.bashEnabled = bashEnabled
        self.searchEnabled = searchEnabled
        self.goalsEnabled = goalsEnabled
        self.reasoningSummariesEnabled = reasoningSummariesEnabled
        self.memoriesEnabled = memoriesEnabled
        self.mcpServerIDs = mcpServerIDs.union(["repoprompt"])
    }
}

public enum ClaudePromptDelivery: String, Codable, CaseIterable, Sendable {
    case nativeSystemPrompt
    case userMessageXMLWithEmptySystemPrompt
    case userMessageXML
}

public struct ClaudeTurnSettings: Codable, Hashable, Sendable {
    public let bashEnabled: Bool
    public let strictMCPEnabled: Bool
    public let toolSearchEnabled: Bool
    public let promptDelivery: ClaudePromptDelivery

    public init(
        bashEnabled: Bool = true,
        strictMCPEnabled: Bool = true,
        toolSearchEnabled: Bool = false,
        promptDelivery: ClaudePromptDelivery = .nativeSystemPrompt
    ) {
        self.bashEnabled = bashEnabled
        self.strictMCPEnabled = strictMCPEnabled
        self.toolSearchEnabled = toolSearchEnabled
        self.promptDelivery = promptDelivery
    }
}

public enum ProviderTurnSettings: Codable, Hashable, Sendable {
    case codex(CodexTurnSettings)
    case claudeCompatible(ClaudeTurnSettings)
    case acp
    case directAPI
}
