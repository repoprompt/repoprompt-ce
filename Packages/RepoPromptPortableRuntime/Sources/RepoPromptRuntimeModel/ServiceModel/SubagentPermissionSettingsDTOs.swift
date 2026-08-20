import Foundation

public enum SubagentPermissionPolicy: String, Codable, CaseIterable, Sendable {
    case safeManaged
    case inheritProviderSettings
    case custom
}

public enum SubagentCodexPermissionMode: String, Codable, CaseIterable, Sendable {
    case readOnly
    case defaultPermission
    case autoReview
    case fullAccess
}

public enum SubagentClaudePermissionMode: String, Codable, CaseIterable, Sendable {
    case requireApproval
    case autoApproveEdits
    case auto
    case fullAccess
}

public enum SubagentManagedPermissionMode: String, Codable, CaseIterable, Sendable {
    case managedDefault
    case fullAccess
}

public struct SubagentPermissionSettings: Codable, Hashable, Sendable {
    public let policy: SubagentPermissionPolicy
    public let codex: SubagentCodexPermissionMode
    public let claude: SubagentClaudePermissionMode
    public let openCode: SubagentManagedPermissionMode
    public let cursor: SubagentManagedPermissionMode
    public let grokBuild: SubagentManagedPermissionMode

    public init(
        policy: SubagentPermissionPolicy = .safeManaged,
        codex: SubagentCodexPermissionMode = .defaultPermission,
        claude: SubagentClaudePermissionMode = .requireApproval,
        openCode: SubagentManagedPermissionMode = .managedDefault,
        cursor: SubagentManagedPermissionMode = .managedDefault,
        grokBuild: SubagentManagedPermissionMode = .managedDefault
    ) {
        self.policy = policy
        self.codex = codex
        self.claude = claude
        self.openCode = openCode
        self.cursor = cursor
        self.grokBuild = grokBuild
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        policy = try container.decodeIfPresent(SubagentPermissionPolicy.self, forKey: .policy) ?? .safeManaged
        codex = try container.decodeIfPresent(SubagentCodexPermissionMode.self, forKey: .codex) ?? .defaultPermission
        claude = try container.decodeIfPresent(SubagentClaudePermissionMode.self, forKey: .claude) ?? .requireApproval
        openCode = try container.decodeIfPresent(SubagentManagedPermissionMode.self, forKey: .openCode) ?? .managedDefault
        cursor = try container.decodeIfPresent(SubagentManagedPermissionMode.self, forKey: .cursor) ?? .managedDefault
        grokBuild = try container.decodeIfPresent(SubagentManagedPermissionMode.self, forKey: .grokBuild) ?? .managedDefault
    }

    public static let safeManaged = SubagentPermissionSettings()
}

public struct SubagentPermissionSettingsSnapshot: Codable, Hashable, Sendable {
    public let settings: SubagentPermissionSettings
    public let revision: Int64
    public let updatedAt: Date

    public init(settings: SubagentPermissionSettings, revision: Int64, updatedAt: Date) {
        self.settings = settings
        self.revision = revision
        self.updatedAt = updatedAt
    }
}

public struct ReplaceSubagentPermissionSettingsRequest: Codable, Hashable, Sendable {
    public let expectedRevision: Int64
    public let settings: SubagentPermissionSettings

    public init(expectedRevision: Int64, settings: SubagentPermissionSettings) {
        self.expectedRevision = expectedRevision
        self.settings = settings
    }
}
