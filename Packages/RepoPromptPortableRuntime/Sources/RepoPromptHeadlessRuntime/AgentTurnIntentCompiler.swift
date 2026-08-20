import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel

public struct ResolvedTaggedFile: Hashable, Sendable {
    public let reference: ComposerTaggedFileReferenceWire
    public let logicalLabel: String
    public let content: String

    public init(reference: ComposerTaggedFileReferenceWire, logicalLabel: String, content: String) {
        self.reference = reference
        self.logicalLabel = logicalLabel
        self.content = content
    }
}

public protocol AgentTurnTaggedFileResolving: Sendable {
    func resolve(_ reference: ComposerTaggedFileReferenceWire, projectID: UUID, sessionID: UUID?) async throws -> ResolvedTaggedFile
}

public struct UnavailableAgentTurnTaggedFileResolver: AgentTurnTaggedFileResolving {
    public init() {}
    public func resolve(_: ComposerTaggedFileReferenceWire, projectID _: UUID, sessionID _: UUID?) async throws -> ResolvedTaggedFile {
        throw ServiceAPIError(code: .rootUnauthorized, message: "Tagged file resolution is unavailable")
    }
}

public struct AuthorityAgentTurnTaggedFileResolver: AgentTurnTaggedFileResolving {
    private let authority: RepoPromptHeadlessAuthority

    public init(authority: RepoPromptHeadlessAuthority) {
        self.authority = authority
    }

    public func resolve(_ reference: ComposerTaggedFileReferenceWire, projectID: UUID, sessionID: UUID?) async throws -> ResolvedTaggedFile {
        if let sessionID {
            let session = try await authority.authoritySessionSnapshot(sessionID: sessionID)
            guard session.session.projectID == projectID else { throw ServiceAPIError(code: .rootUnauthorized, message: "Tagged file context is invalid") }
            if let bindingID = reference.worktreeBindingID {
                guard session.worktrees.contains(where: { $0.bindingID == bindingID && $0.rootID == reference.rootID && $0.ownershipState == .active }) else {
                    throw ServiceAPIError(code: .rootUnauthorized, message: "Tagged file worktree binding is stale")
                }
            }
        }
        let request = ProjectFileRequest(rootID: reference.rootID, logicalPath: reference.logicalPath, maximumBytes: 1_048_576)
        let file = if let sessionID {
            try await authority.sessionProjectFile(sessionID: sessionID, request: request)
        } else {
            try await authority.projectFile(projectID: projectID, request: request)
        }
        guard !file.truncated else { throw ServiceAPIError(code: .invalidRequest, message: "Tagged file exceeds its per-file bound") }
        return .init(reference: reference, logicalLabel: reference.logicalPath, content: file.content)
    }
}

public struct ResolvedComposerSuggestion: Hashable, Sendable {
    public let token: ComposerResolvedSuggestionTokenWire
    public let expansion: String?
    public let nativeInvocation: String?

    public init(token: ComposerResolvedSuggestionTokenWire, expansion: String? = nil, nativeInvocation: String? = nil) {
        self.token = token
        self.expansion = expansion
        self.nativeInvocation = nativeInvocation
    }
}

public protocol AgentTurnSuggestionResolving: Sendable {
    func resolve(_ token: ComposerResolvedSuggestionTokenWire, providerID: ProviderSettingsID, catalogRevision: String) async throws -> ResolvedComposerSuggestion
}

public struct RejectingAgentTurnSuggestionResolver: AgentTurnSuggestionResolving {
    public init() {}
    public func resolve(_: ComposerResolvedSuggestionTokenWire, providerID _: ProviderSettingsID, catalogRevision _: String) async throws -> ResolvedComposerSuggestion {
        throw ServiceAPIError(code: .staleRevision, message: "Suggestion is no longer available")
    }
}

public struct StaticAgentTurnSuggestionResolver: AgentTurnSuggestionResolving {
    private let descriptors: [ComposerSuggestionDescriptor]

    public init(descriptors: [ComposerSuggestionDescriptor]) {
        self.descriptors = descriptors
    }

    public func resolve(_ token: ComposerResolvedSuggestionTokenWire, providerID: ProviderSettingsID, catalogRevision _: String) async throws -> ResolvedComposerSuggestion {
        let matches = descriptors.filter {
            $0.available && $0.kind.rawValue == token.kind.rawValue && $0.id == token.id && $0.insertionText == token.insertionText && ($0.providerIDs.isEmpty || $0.providerIDs.contains(providerID))
        }
        guard matches.count == 1 else { throw ServiceAPIError(code: .staleRevision, message: "Suggestion changed or collides with another entry") }
        let value = matches[0]
        switch token.kind {
        case .skill: return .init(token: token, expansion: value.expansion)
        case .nativeCommand: return .init(token: token, nativeInvocation: value.expansion ?? value.insertionText)
        case .file: throw ServiceAPIError(code: .invalidRequest, message: "File suggestions must be submitted as tagged file references")
        }
    }
}

public struct AgentTurnAttachmentManifest: Codable, Hashable, Sendable {
    public let attachments: [ComposerAttachmentWire]
    public let nativeImages: [ProviderNativeImageDescriptor]

    public init(attachments: [ComposerAttachmentWire] = [], nativeImages: [ProviderNativeImageDescriptor] = []) {
        self.attachments = attachments
        self.nativeImages = nativeImages
    }
}

public struct CanonicalUserTurn: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let identity: CanonicalTurnIdentity
    public let text: String
    public let suggestionTokens: [ComposerResolvedSuggestionTokenWire]
    public let taggedFiles: [ComposerTaggedFileReferenceWire]
    public let attachments: [ComposerAttachmentWire]
    public let effectiveConfiguration: EffectiveTurnConfigurationRecord

    public init(schemaVersion: Int = 1, identity: CanonicalTurnIdentity, text: String, suggestionTokens: [ComposerResolvedSuggestionTokenWire], taggedFiles: [ComposerTaggedFileReferenceWire], attachments: [ComposerAttachmentWire], effectiveConfiguration: EffectiveTurnConfigurationRecord) {
        self.schemaVersion = schemaVersion
        self.identity = identity
        self.text = text
        self.suggestionTokens = suggestionTokens
        self.taggedFiles = taggedFiles
        self.attachments = attachments
        self.effectiveConfiguration = effectiveConfiguration
    }
}

public struct AgentTurnCompilationInput: Sendable {
    public let projectID: UUID
    public let sessionID: UUID?
    public let identity: CanonicalTurnIdentity
    public let content: AgentTurnContentWire
    public let selectedMessageContext: SelectedMessageContext?
    public let effectiveConfiguration: EffectiveTurnConfigurationRecord
    public let providerConfiguration: CompiledProviderTurnConfiguration
    public let attachmentManifest: AgentTurnAttachmentManifest
    public let continuationContext: String?
    public let providerPromptWrapper: String?
    public let workflowGuidance: String?
    public let goalGuidance: String?
    public let userTextConsumedByWorkflow: Bool

    public init(projectID: UUID, sessionID: UUID?, identity: CanonicalTurnIdentity, content: AgentTurnContentWire, selectedMessageContext: SelectedMessageContext? = nil, effectiveConfiguration: EffectiveTurnConfigurationRecord, providerConfiguration: CompiledProviderTurnConfiguration, attachmentManifest: AgentTurnAttachmentManifest = .init(), continuationContext: String? = nil, providerPromptWrapper: String? = nil, workflowGuidance: String? = nil, goalGuidance: String? = nil, userTextConsumedByWorkflow: Bool = false) {
        self.projectID = projectID
        self.sessionID = sessionID
        self.identity = identity
        self.content = content
        self.selectedMessageContext = selectedMessageContext
        self.effectiveConfiguration = effectiveConfiguration
        self.providerConfiguration = providerConfiguration
        self.attachmentManifest = attachmentManifest
        self.continuationContext = continuationContext
        self.providerPromptWrapper = providerPromptWrapper
        self.workflowGuidance = workflowGuidance
        self.goalGuidance = goalGuidance
        self.userTextConsumedByWorkflow = userTextConsumedByWorkflow
    }
}

public struct AgentTurnCompilationResult: Sendable {
    public let canonicalUserTurn: CanonicalUserTurn
    public let providerInput: CompiledProviderTurnInput
    public let resolvedTaggedFiles: [ResolvedTaggedFile]

    public init(canonicalUserTurn: CanonicalUserTurn, providerInput: CompiledProviderTurnInput, resolvedTaggedFiles: [ResolvedTaggedFile]) {
        self.canonicalUserTurn = canonicalUserTurn
        self.providerInput = providerInput
        self.resolvedTaggedFiles = resolvedTaggedFiles
    }
}

public actor AgentTurnIntentCompiler {
    public struct Limits: Hashable, Sendable {
        public let maximumTextBytes: Int
        public let maximumTaggedFiles: Int
        public let maximumTaggedFileBytes: Int
        public let maximumTaggedAggregateBytes: Int
        public let maximumTaggedAggregateTokens: Int
        public let maximumSuggestions: Int
        public let maximumAttachments: Int

        public init(maximumTextBytes: Int = 64000, maximumTaggedFiles: Int = 16, maximumTaggedFileBytes: Int = 1_048_576, maximumTaggedAggregateBytes: Int = 2_097_152, maximumTaggedAggregateTokens: Int = 500_000, maximumSuggestions: Int = 16, maximumAttachments: Int = 4) {
            self.maximumTextBytes = maximumTextBytes
            self.maximumTaggedFiles = maximumTaggedFiles
            self.maximumTaggedFileBytes = maximumTaggedFileBytes
            self.maximumTaggedAggregateBytes = maximumTaggedAggregateBytes
            self.maximumTaggedAggregateTokens = maximumTaggedAggregateTokens
            self.maximumSuggestions = maximumSuggestions
            self.maximumAttachments = maximumAttachments
        }
    }

    private let taggedFiles: any AgentTurnTaggedFileResolving
    private let suggestions: any AgentTurnSuggestionResolving
    private let limits: Limits

    public init(taggedFiles: any AgentTurnTaggedFileResolving = UnavailableAgentTurnTaggedFileResolver(), suggestions: any AgentTurnSuggestionResolving = RejectingAgentTurnSuggestionResolver(), limits: Limits = .init()) {
        self.taggedFiles = taggedFiles
        self.suggestions = suggestions
        self.limits = limits
    }

    public func compile(_ input: AgentTurnCompilationInput) async throws -> AgentTurnCompilationResult {
        guard input.content.schemaVersion == 1, input.effectiveConfiguration.schemaVersion == 1 else {
            throw ServiceAPIError(code: .invalidRequest, message: "Turn intent schema is unsupported")
        }
        let selectedMessageContext = try input.selectedMessageContext?.validated()
        let canonicalText = selectedMessageContext?.frozenPrompt(userPrompt: input.content.text) ?? input.content.text
        guard input.content.text.utf8.count <= limits.maximumTextBytes,
              canonicalText.utf8.count <= limits.maximumTextBytes * 2,
              input.content.taggedFiles.count <= limits.maximumTaggedFiles,
              input.content.resolvedSuggestionTokens.count <= limits.maximumSuggestions,
              input.attachmentManifest.attachments.count <= limits.maximumAttachments
        else { throw ServiceAPIError(code: .invalidRequest, message: "Turn intent exceeds its bounded limits") }
        guard Set(input.content.attachmentIDs) == Set(input.attachmentManifest.attachments.map(\.attachmentID)),
              Set(input.content.attachmentIDs) == Set(input.attachmentManifest.nativeImages.map(\.attachmentID))
        else { throw ServiceAPIError(code: .invalidRequest, message: "Attachment manifest does not match the accepted turn") }
        if !input.attachmentManifest.attachments.isEmpty, !input.providerConfiguration.supportsNativeImages {
            throw ServiceAPIError(code: .capabilityMissing, message: "Selected model does not support native image input")
        }
        guard !canonicalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !input.attachmentManifest.attachments.isEmpty else {
            throw ServiceAPIError(code: .invalidRequest, message: "A turn requires text or a native image")
        }

        var resolvedFiles: [ResolvedTaggedFile] = []
        var aggregateBytes = 0
        var estimatedTokens = 0
        for reference in input.content.taggedFiles {
            guard !reference.logicalPath.isEmpty, !reference.logicalPath.hasPrefix("/"), !reference.logicalPath.split(separator: "/").contains("..") else {
                throw ServiceAPIError(code: .rootUnauthorized, message: "Tagged file reference is invalid")
            }
            let resolved = try await taggedFiles.resolve(reference, projectID: input.projectID, sessionID: input.sessionID)
            let bytes = resolved.content.utf8.count
            guard bytes <= limits.maximumTaggedFileBytes else { throw ServiceAPIError(code: .invalidRequest, message: "Tagged file exceeds its per-file bound") }
            aggregateBytes += bytes
            estimatedTokens += max(1, bytes / 4)
            guard aggregateBytes <= limits.maximumTaggedAggregateBytes, estimatedTokens <= limits.maximumTaggedAggregateTokens else {
                throw ServiceAPIError(code: .invalidRequest, message: "Tagged file content exceeds its aggregate bound")
            }
            resolvedFiles.append(resolved)
        }

        var resolvedSuggestions: [ResolvedComposerSuggestion] = []
        for token in input.content.resolvedSuggestionTokens {
            guard !token.id.isEmpty, token.insertionText.utf8.count <= 512 else {
                throw ServiceAPIError(code: .invalidRequest, message: "Suggestion token is invalid")
            }
            try await resolvedSuggestions.append(suggestions.resolve(token, providerID: input.effectiveConfiguration.providerID, catalogRevision: input.effectiveConfiguration.catalogRevision))
        }

        var sections: [String] = []
        appendSection("Continuation context", input.continuationContext, to: &sections)
        appendSection("Provider instructions", input.providerPromptWrapper, to: &sections)
        appendSection("Workflow guidance", input.workflowGuidance, to: &sections)
        appendSection("Goal guidance", input.goalGuidance, to: &sections)
        for suggestion in resolvedSuggestions {
            if let expansion = suggestion.expansion { appendSection("Skill \(suggestion.token.id)", expansion, to: &sections) }
            if let invocation = suggestion.nativeInvocation { appendSection("Native command \(suggestion.token.id)", invocation, to: &sections) }
        }
        for file in resolvedFiles {
            sections.append("<tagged-file label=\"\(escapeAttribute(file.logicalLabel))\">\n\(file.content)\n</tagged-file>")
        }
        if !canonicalText.isEmpty, !input.userTextConsumedByWorkflow {
            sections.append(selectedMessageContext == nil ? "<user-request>\n\(canonicalText)\n</user-request>" : canonicalText)
        }
        let prompt = sections.joined(separator: "\n\n")
        guard prompt.utf8.count <= limits.maximumTextBytes + limits.maximumTaggedAggregateBytes + 1_048_576 else {
            throw ServiceAPIError(code: .invalidRequest, message: "Compiled provider prompt exceeds its bound")
        }
        let canonical = CanonicalUserTurn(identity: input.identity, text: canonicalText, suggestionTokens: input.content.resolvedSuggestionTokens, taggedFiles: input.content.taggedFiles, attachments: input.attachmentManifest.attachments, effectiveConfiguration: input.effectiveConfiguration)
        return .init(canonicalUserTurn: canonical, providerInput: .init(prompt: prompt, nativeImages: input.attachmentManifest.nativeImages, identity: input.identity), resolvedTaggedFiles: resolvedFiles)
    }

    private func appendSection(_ title: String, _ value: String?, to sections: inout [String]) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        sections.append("<\(title.lowercased().replacingOccurrences(of: " ", with: "-"))>\n\(value)\n</\(title.lowercased().replacingOccurrences(of: " ", with: "-"))>")
    }

    private func escapeAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
    }
}
