import Foundation

public enum ContextBuilderEnhancementMode: String, Codable, CaseIterable, Sendable {
    case rewrite
    case augment
    case preserve
}

public enum ContextBuilderFollowUpAnalysis: String, Codable, CaseIterable, Sendable {
    case disabled
    case plan
    case review
    case question
}

public enum ContextBuilderInvocationOrigin: String, Codable, Sendable {
    case portal
    case mcp
    case `internal`
}

public struct ContextBuilderSettingsProfile: Codable, Hashable, Sendable {
    public let budget: Int
    public let enhancementMode: ContextBuilderEnhancementMode
    public let questionTimeoutSeconds: Int
    public let portalClarifyingQuestions: Bool
    public let mcpClarifyingQuestions: Bool
    public let followUpAnalysis: ContextBuilderFollowUpAnalysis
    public let followUpBudget: Int

    public init(
        budget: Int = 160_000,
        enhancementMode: ContextBuilderEnhancementMode = .rewrite,
        questionTimeoutSeconds: Int = 60,
        portalClarifyingQuestions: Bool = true,
        mcpClarifyingQuestions: Bool = false,
        followUpAnalysis: ContextBuilderFollowUpAnalysis = .disabled,
        followUpBudget: Int = 40000
    ) {
        self.budget = budget
        self.enhancementMode = enhancementMode
        self.questionTimeoutSeconds = questionTimeoutSeconds
        self.portalClarifyingQuestions = portalClarifyingQuestions
        self.mcpClarifyingQuestions = mcpClarifyingQuestions
        self.followUpAnalysis = followUpAnalysis
        self.followUpBudget = followUpBudget
    }

    public static let `default` = ContextBuilderSettingsProfile()
}

public enum ContextBuilderSettingsScopeMode: String, Codable, Sendable {
    case inheritGlobal
    case projectOverride
}

public struct ContextBuilderScopeDocument: Codable, Hashable, Sendable {
    public let mode: ContextBuilderSettingsScopeMode
    public let profile: ContextBuilderSettingsProfile?

    public init(mode: ContextBuilderSettingsScopeMode, profile: ContextBuilderSettingsProfile?) {
        self.mode = mode
        self.profile = profile
    }
}

public struct ContextBuilderSettingsSnapshot: Codable, Hashable, Sendable {
    public let globalProfile: ContextBuilderSettingsProfile
    public let globalRevision: Int64
    public let projectID: UUID?
    public let projectMode: ContextBuilderSettingsScopeMode
    public let projectProfile: ContextBuilderSettingsProfile?
    public let projectRevision: Int64
    public let effectiveProfile: ContextBuilderSettingsProfile
    public let updatedAt: Date

    public init(
        globalProfile: ContextBuilderSettingsProfile,
        globalRevision: Int64,
        projectID: UUID?,
        projectMode: ContextBuilderSettingsScopeMode,
        projectProfile: ContextBuilderSettingsProfile?,
        projectRevision: Int64,
        effectiveProfile: ContextBuilderSettingsProfile,
        updatedAt: Date
    ) {
        self.globalProfile = globalProfile
        self.globalRevision = globalRevision
        self.projectID = projectID
        self.projectMode = projectMode
        self.projectProfile = projectProfile
        self.projectRevision = projectRevision
        self.effectiveProfile = effectiveProfile
        self.updatedAt = updatedAt
    }
}

public struct ReplaceGlobalContextBuilderSettingsRequest: Codable, Hashable, Sendable {
    public let expectedRevision: Int64
    public let profile: ContextBuilderSettingsProfile

    public init(expectedRevision: Int64, profile: ContextBuilderSettingsProfile) {
        self.expectedRevision = expectedRevision
        self.profile = profile
    }
}

public struct ReplaceProjectContextBuilderSettingsRequest: Codable, Hashable, Sendable {
    public let expectedRevision: Int64
    public let mode: ContextBuilderSettingsScopeMode
    public let profile: ContextBuilderSettingsProfile?

    public init(expectedRevision: Int64, mode: ContextBuilderSettingsScopeMode, profile: ContextBuilderSettingsProfile?) {
        self.expectedRevision = expectedRevision
        self.mode = mode
        self.profile = profile
    }
}

public struct CopyGlobalContextBuilderToProjectRequest: Codable, Hashable, Sendable {
    public let expectedGlobalRevision: Int64
    public let expectedProjectRevision: Int64

    public init(expectedGlobalRevision: Int64, expectedProjectRevision: Int64) {
        self.expectedGlobalRevision = expectedGlobalRevision
        self.expectedProjectRevision = expectedProjectRevision
    }
}

public struct ContextBuilderInvocationOverrides: Codable, Hashable, Sendable {
    public let budget: Int?
    public let enhancementMode: ContextBuilderEnhancementMode?
    public let allowClarifyingQuestions: Bool?
    public let questionTimeoutSeconds: Int?
    public let followUpAnalysis: ContextBuilderFollowUpAnalysis?
    public let followUpBudget: Int?

    public init(
        budget: Int? = nil,
        enhancementMode: ContextBuilderEnhancementMode? = nil,
        allowClarifyingQuestions: Bool? = nil,
        questionTimeoutSeconds: Int? = nil,
        followUpAnalysis: ContextBuilderFollowUpAnalysis? = nil,
        followUpBudget: Int? = nil
    ) {
        self.budget = budget
        self.enhancementMode = enhancementMode
        self.allowClarifyingQuestions = allowClarifyingQuestions
        self.questionTimeoutSeconds = questionTimeoutSeconds
        self.followUpAnalysis = followUpAnalysis
        self.followUpBudget = followUpBudget
    }
}

public struct EffectiveContextBuilderSettings: Codable, Hashable, Sendable {
    public let budget: Int
    public let enhancementMode: ContextBuilderEnhancementMode
    public let allowClarifyingQuestions: Bool
    public let questionTimeoutSeconds: Int
    public let followUpAnalysis: ContextBuilderFollowUpAnalysis
    public let followUpBudget: Int

    public init(
        budget: Int,
        enhancementMode: ContextBuilderEnhancementMode,
        allowClarifyingQuestions: Bool,
        questionTimeoutSeconds: Int,
        followUpAnalysis: ContextBuilderFollowUpAnalysis,
        followUpBudget: Int
    ) {
        self.budget = budget
        self.enhancementMode = enhancementMode
        self.allowClarifyingQuestions = allowClarifyingQuestions
        self.questionTimeoutSeconds = questionTimeoutSeconds
        self.followUpAnalysis = followUpAnalysis
        self.followUpBudget = followUpBudget
    }
}
