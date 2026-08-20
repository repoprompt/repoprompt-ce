import Foundation

/// Desktop-shaped Direct Agents persist. Codex keeps sandbox / approval / reviewer
/// as independent fields; permission level is derived the same way Desktop does.
public enum CodexSandboxMode: String, Codable, CaseIterable, Sendable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
    case dangerFullAccess = "danger-full-access"
}

public enum CodexApprovalPolicy: String, Codable, CaseIterable, Sendable {
    case onRequest = "on-request"
    case unlessTrusted = "unless-trusted"
    case never
}

public enum CodexApprovalReviewer: String, Codable, CaseIterable, Sendable {
    case user
    case autoReview = "auto-review"
}

public enum ClaudeDirectPermissionMode: String, Codable, CaseIterable, Sendable {
    case requireApproval = "default"
    case autoApproveEdits = "acceptEdits"
    case auto
    case fullAccess = "bypassPermissions"
}

/// Desktop UserDefaults `claudeCodeAgentModePromptDelivery`. Missing/invalid
/// raw defaults to `nativeSystemPrompt`. Linux has no
/// `nullBuiltInSystemPromptEnabled` legacy flag.
public enum ClaudeAgentModePromptDelivery: String, Codable, CaseIterable, Sendable {
    case userMessageXML
    case userMessageXMLWithEmptySystemPrompt
    case nativeSystemPrompt

    public static let `default` = ClaudeAgentModePromptDelivery.nativeSystemPrompt
    public static let instructionsTag = "claude_code_instructions"

    public static func resolved(rawValue: String?) -> ClaudeAgentModePromptDelivery {
        rawValue.flatMap(Self.init(rawValue:)) ?? .nativeSystemPrompt
    }

    /// Composer/toolValues are not durable. Missing store → Desktop default.
    public static func liveRead(stored: ClaudeAgentModePromptDelivery?) -> ClaudeAgentModePromptDelivery {
        stored ?? .nativeSystemPrompt
    }

    public var sendsRepoPromptAsUserMessage: Bool {
        switch self {
        case .userMessageXML, .userMessageXMLWithEmptySystemPrompt: true
        case .nativeSystemPrompt: false
        }
    }

    public func nativeSystemPromptOverride(instructions: String) -> String? {
        switch self {
        case .userMessageXML: nil
        case .userMessageXMLWithEmptySystemPrompt: ""
        case .nativeSystemPrompt: instructions
        }
    }

    public static func decoratedUserMessage(_ userMessage: String, instructions: String) -> String {
        let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstructions.isEmpty else { return userMessage }
        let instructionsBlock = """
        <\(instructionsTag)>
        \(trimmedInstructions)
        </\(instructionsTag)>
        """
        let trimmedUserMessage = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserMessage.isEmpty else { return instructionsBlock }
        return """
        \(instructionsBlock)

        \(userMessage)
        """
    }

    public func packagedUserMessage(_ userMessage: String, instructions: String) -> String {
        sendsRepoPromptAsUserMessage
            ? Self.decoratedUserMessage(userMessage, instructions: instructions)
            : userMessage
    }

    public func appendingSystemPrompt(to arguments: [String], instructions: String) -> [String] {
        var arguments = arguments
        if let override = nativeSystemPromptOverride(instructions: instructions) {
            arguments += ["--system-prompt", override]
        }
        return arguments
    }
}

public enum ManagedDirectPermissionLevel: String, Codable, CaseIterable, Sendable {
    case managedDefault
    case fullAccess
}

public struct DirectCodexAgentPermissions: Codable, Hashable, Sendable {
    public var sandboxMode: CodexSandboxMode
    public var approvalPolicy: CodexApprovalPolicy
    public var approvalReviewer: CodexApprovalReviewer
    public var bashEnabled: Bool

    public init(
        sandboxMode: CodexSandboxMode = .workspaceWrite,
        approvalPolicy: CodexApprovalPolicy = .onRequest,
        approvalReviewer: CodexApprovalReviewer = .autoReview,
        bashEnabled: Bool = true
    ) {
        self.sandboxMode = sandboxMode
        self.approvalPolicy = approvalPolicy
        self.approvalReviewer = approvalReviewer
        self.bashEnabled = bashEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sandboxMode = try container.decodeIfPresent(CodexSandboxMode.self, forKey: .sandboxMode) ?? .workspaceWrite
        approvalPolicy = try container.decodeIfPresent(CodexApprovalPolicy.self, forKey: .approvalPolicy) ?? .onRequest
        approvalReviewer = try container.decodeIfPresent(CodexApprovalReviewer.self, forKey: .approvalReviewer) ?? .autoReview
        bashEnabled = try container.decodeIfPresent(Bool.self, forKey: .bashEnabled) ?? true
    }

    /// Desktop `PermissionLevel.from(sandbox:approvalReviewer:)`.
    public var permissionLevel: String {
        switch sandboxMode {
        case .readOnly: "readOnly"
        case .dangerFullAccess: "fullAccess"
        case .workspaceWrite: approvalReviewer == .autoReview ? "autoReview" : "defaultPermission"
        }
    }

    public static func from(permissionLevel: String, bashEnabled: Bool = true) -> DirectCodexAgentPermissions {
        switch permissionLevel {
        case "readOnly":
            .init(sandboxMode: .readOnly, approvalPolicy: .onRequest, approvalReviewer: .user, bashEnabled: bashEnabled)
        case "defaultPermission":
            .init(sandboxMode: .workspaceWrite, approvalPolicy: .onRequest, approvalReviewer: .user, bashEnabled: bashEnabled)
        case "fullAccess":
            .init(sandboxMode: .dangerFullAccess, approvalPolicy: .never, approvalReviewer: .user, bashEnabled: bashEnabled)
        default:
            .init(sandboxMode: .workspaceWrite, approvalPolicy: .onRequest, approvalReviewer: .autoReview, bashEnabled: bashEnabled)
        }
    }
}

public struct DirectClaudeAgentPermissions: Codable, Hashable, Sendable {
    public var permissionMode: ClaudeDirectPermissionMode
    public var bashEnabled: Bool
    public var mcpStrictModeEnabled: Bool
    public var promptDelivery: ClaudeAgentModePromptDelivery

    public init(
        permissionMode: ClaudeDirectPermissionMode = .requireApproval,
        bashEnabled: Bool = true,
        mcpStrictModeEnabled: Bool = true,
        promptDelivery: ClaudeAgentModePromptDelivery = .nativeSystemPrompt
    ) {
        self.permissionMode = permissionMode
        self.bashEnabled = bashEnabled
        self.mcpStrictModeEnabled = mcpStrictModeEnabled
        self.promptDelivery = promptDelivery
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        permissionMode = try container.decodeIfPresent(ClaudeDirectPermissionMode.self, forKey: .permissionMode) ?? .requireApproval
        bashEnabled = try container.decodeIfPresent(Bool.self, forKey: .bashEnabled) ?? true
        mcpStrictModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .mcpStrictModeEnabled) ?? true
        if let raw = try container.decodeIfPresent(String.self, forKey: .promptDelivery) {
            promptDelivery = ClaudeAgentModePromptDelivery.resolved(rawValue: raw)
        } else {
            promptDelivery = .nativeSystemPrompt
        }
    }

    public var permissionLevel: String {
        switch permissionMode {
        case .requireApproval: "requireApproval"
        case .autoApproveEdits: "autoApproveEdits"
        case .auto: "auto"
        case .fullAccess: "fullAccess"
        }
    }

    public static func from(permissionLevel: String, bashEnabled: Bool = true, mcpStrictModeEnabled: Bool = true) -> DirectClaudeAgentPermissions {
        let mode: ClaudeDirectPermissionMode = switch permissionLevel {
        case "autoApproveEdits", "acceptEdits": .autoApproveEdits
        case "auto": .auto
        case "fullAccess", "bypassPermissions": .fullAccess
        default: .requireApproval
        }
        return .init(permissionMode: mode, bashEnabled: bashEnabled, mcpStrictModeEnabled: mcpStrictModeEnabled)
    }
}

public struct DirectManagedAgentPermissions: Codable, Hashable, Sendable {
    public var permissionLevel: ManagedDirectPermissionLevel

    public init(permissionLevel: ManagedDirectPermissionLevel = .managedDefault) {
        self.permissionLevel = permissionLevel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        permissionLevel = try container.decodeIfPresent(ManagedDirectPermissionLevel.self, forKey: .permissionLevel) ?? .managedDefault
    }
}

public struct DirectAgentRuntimeProjection: Hashable, Sendable {
    public let mode: String
    public let providerSettings: [String: String]

    public init(mode: String, providerSettings: [String: String]) {
        self.mode = mode
        self.providerSettings = providerSettings
    }
}

public struct DirectAgentPermissionsSettings: Codable, Hashable, Sendable {
    public var codex: DirectCodexAgentPermissions
    public var claude: DirectClaudeAgentPermissions
    public var openCode: DirectManagedAgentPermissions
    public var cursor: DirectManagedAgentPermissions
    public var grokBuild: DirectManagedAgentPermissions

    public init(
        codex: DirectCodexAgentPermissions = .init(),
        claude: DirectClaudeAgentPermissions = .init(),
        openCode: DirectManagedAgentPermissions = .init(),
        cursor: DirectManagedAgentPermissions = .init(),
        grokBuild: DirectManagedAgentPermissions = .init()
    ) {
        self.codex = codex
        self.claude = claude
        self.openCode = openCode
        self.cursor = cursor
        self.grokBuild = grokBuild
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        codex = try container.decodeIfPresent(DirectCodexAgentPermissions.self, forKey: .codex) ?? .init()
        claude = try container.decodeIfPresent(DirectClaudeAgentPermissions.self, forKey: .claude) ?? .init()
        openCode = try container.decodeIfPresent(DirectManagedAgentPermissions.self, forKey: .openCode) ?? .init()
        cursor = try container.decodeIfPresent(DirectManagedAgentPermissions.self, forKey: .cursor) ?? .init()
        grokBuild = try container.decodeIfPresent(DirectManagedAgentPermissions.self, forKey: .grokBuild) ?? .init()
    }

    public static let `default` = DirectAgentPermissionsSettings()

    public func projection(for providerID: ProviderSettingsID) -> DirectAgentRuntimeProjection {
        switch providerID {
        case .codex:
            let approval = switch codex.approvalPolicy {
            case .onRequest: "on-request"
            case .unlessTrusted: "untrusted"
            case .never: "never"
            }
            let reviewer = codex.approvalReviewer == .autoReview ? "auto_review" : "user"
            return .init(mode: Self.executionMode(sandbox: codex.sandboxMode), providerSettings: [
                "codex.sandbox": codex.sandboxMode.rawValue,
                "codex.approvalPolicy": approval,
                "codex.approvalsReviewer": reviewer,
                "codex.bashEnabled": codex.bashEnabled ? "true" : "false",
                "provider.permissionId": "codex.\(codex.permissionLevel)"
            ])
        case .claudeCompatible, .claudeGLM, .claudeKimi, .claudeCustom:
            return .init(
                mode: claude.permissionMode == .fullAccess ? "fullAccess" : "workspaceWrite",
                providerSettings: [
                    "claude.permissionMode": claude.permissionMode.rawValue,
                    "claude.bashEnabled": claude.bashEnabled ? "true" : "false",
                    "claude.strictMCPEnabled": claude.mcpStrictModeEnabled ? "true" : "false",
                    "claude.promptDelivery": claude.promptDelivery.rawValue,
                    "provider.permissionId": "claude.\(claude.permissionLevel)"
                ]
            )
        case .openCodeACP:
            return .init(
                mode: openCode.permissionLevel == .fullAccess ? "fullAccess" : "workspaceWrite",
                providerSettings: ["provider.permissionId": "opencode.\(openCode.permissionLevel.rawValue)"]
            )
        case .cursorACP:
            return .init(
                mode: cursor.permissionLevel == .fullAccess ? "fullAccess" : "workspaceWrite",
                providerSettings: ["provider.permissionId": "cursor.\(cursor.permissionLevel.rawValue)"]
            )
        case .grokBuildACP:
            return .init(
                mode: grokBuild.permissionLevel == .fullAccess ? "fullAccess" : "workspaceWrite",
                providerSettings: ["provider.permissionId": "grok.\(grokBuild.permissionLevel.rawValue)"]
            )
        case .openAIAPI, .anthropicAPI, .openRouter, .customOpenAICompatible,
             .gemini, .azure, .deepseek, .fireworks, .xAI, .groq, .zAI, .ollama:
            return .init(mode: "workspaceWrite", providerSettings: [:])
        }
    }

    public static func executionMode(sandbox: CodexSandboxMode) -> String {
        switch sandbox {
        case .readOnly: "readOnly"
        case .workspaceWrite: "workspaceWrite"
        case .dangerFullAccess: "fullAccess"
        }
    }
}

public struct DirectAgentPermissionsSettingsSnapshot: Codable, Hashable, Sendable {
    public let settings: DirectAgentPermissionsSettings
    public let revision: Int64
    public let updatedAt: Date

    public init(settings: DirectAgentPermissionsSettings, revision: Int64, updatedAt: Date) {
        self.settings = settings
        self.revision = revision
        self.updatedAt = updatedAt
    }
}

public struct ReplaceDirectAgentPermissionsSettingsRequest: Codable, Hashable, Sendable {
    public let expectedRevision: Int64
    public let settings: DirectAgentPermissionsSettings

    public init(expectedRevision: Int64, settings: DirectAgentPermissionsSettings) {
        self.expectedRevision = expectedRevision
        self.settings = settings
    }
}
