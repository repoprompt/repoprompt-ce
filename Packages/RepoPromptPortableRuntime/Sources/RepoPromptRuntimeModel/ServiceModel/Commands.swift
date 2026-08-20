import Foundation

private struct ProjectSourceCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        nil
    }
}

public struct CreateProjectInput: Codable, Sendable {
    public struct Root: Codable, Sendable {
        public let logicalName: String
        public let path: String
        public let writable: Bool
        public init(logicalName: String, path: String, writable: Bool) {
            self.logicalName = logicalName
            self.path = path
            self.writable = writable
        }
    }

    public let name: String
    public let roots: [Root]
    public init(name: String, roots: [Root]) {
        self.name = name
        self.roots = roots
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case roots
    }
}

public struct CreateProjectWireInput: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let operationID: UUID
    public let expectedRevision: Int64
    public let name: String

    public init(schemaVersion: Int = 1, operationID: UUID, expectedRevision: Int64 = 0, name: String) {
        self.schemaVersion = schemaVersion
        self.operationID = operationID
        self.expectedRevision = expectedRevision
        self.name = name
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: ProjectSourceCodingKey.self)
        let marker = ProjectSourceCodingKey("schemaVersion")
        guard Set(values.allKeys.map(\.stringValue)) == Set(["schemaVersion", "operationId", "expectedRevision", "name"]) else {
            throw DecodingError.dataCorruptedError(forKey: marker, in: values, debugDescription: "Project creation contains unsupported fields")
        }
        try self.init(
            schemaVersion: values.decode(Int.self, forKey: marker),
            operationID: values.decode(UUID.self, forKey: ProjectSourceCodingKey("operationId")),
            expectedRevision: values.decode(Int64.self, forKey: ProjectSourceCodingKey("expectedRevision")),
            name: values.decode(String.self, forKey: ProjectSourceCodingKey("name"))
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: ProjectSourceCodingKey.self)
        try values.encode(schemaVersion, forKey: ProjectSourceCodingKey("schemaVersion"))
        try values.encode(operationID, forKey: ProjectSourceCodingKey("operationId"))
        try values.encode(expectedRevision, forKey: ProjectSourceCodingKey("expectedRevision"))
        try values.encode(name, forKey: ProjectSourceCodingKey("name"))
    }
}

public struct RenameProjectInput: Codable, Hashable, Sendable {
    public let expectedRevision: Int64
    public let name: String

    public init(expectedRevision: Int64, name: String) {
        self.expectedRevision = expectedRevision
        self.name = name
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: ProjectSourceCodingKey.self)
        let marker = ProjectSourceCodingKey("expectedRevision")
        guard Set(values.allKeys.map(\.stringValue)) == Set(["expectedRevision", "name"]) else {
            throw DecodingError.dataCorruptedError(forKey: marker, in: values, debugDescription: "Project rename contains unsupported fields")
        }
        try self.init(
            expectedRevision: values.decode(Int64.self, forKey: marker),
            name: values.decode(String.self, forKey: ProjectSourceCodingKey("name"))
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: ProjectSourceCodingKey.self)
        try values.encode(expectedRevision, forKey: ProjectSourceCodingKey("expectedRevision"))
        try values.encode(name, forKey: ProjectSourceCodingKey("name"))
    }
}

public struct AddProjectRepositoryInput: Codable, Hashable, Sendable {
    public struct GitSource: Codable, Hashable, Sendable {
        public let remote: String
        public let ref: String

        public init(remote: String, ref: String) {
            self.remote = remote
            self.ref = ref
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: ProjectSourceCodingKey.self)
            let marker = ProjectSourceCodingKey("type")
            guard Set(values.allKeys.map(\.stringValue)) == Set(["type", "remote", "ref"]),
                  try values.decode(String.self, forKey: marker) == "gitClone"
            else {
                throw DecodingError.dataCorruptedError(forKey: marker, in: values, debugDescription: "Repository source must be a Git clone")
            }
            try self.init(
                remote: values.decode(String.self, forKey: ProjectSourceCodingKey("remote")),
                ref: values.decode(String.self, forKey: ProjectSourceCodingKey("ref"))
            )
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: ProjectSourceCodingKey.self)
            try values.encode("gitClone", forKey: ProjectSourceCodingKey("type"))
            try values.encode(remote, forKey: ProjectSourceCodingKey("remote"))
            try values.encode(ref, forKey: ProjectSourceCodingKey("ref"))
        }
    }

    public let schemaVersion: Int
    public let expectedRevision: Int64
    public let logicalName: String
    public let source: GitSource

    public init(schemaVersion: Int = 1, expectedRevision: Int64, logicalName: String, source: GitSource) {
        self.schemaVersion = schemaVersion
        self.expectedRevision = expectedRevision
        self.logicalName = logicalName
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: ProjectSourceCodingKey.self)
        let marker = ProjectSourceCodingKey("schemaVersion")
        guard Set(values.allKeys.map(\.stringValue)) == Set(["schemaVersion", "expectedRevision", "logicalName", "source"]) else {
            throw DecodingError.dataCorruptedError(forKey: marker, in: values, debugDescription: "Repository addition contains unsupported fields")
        }
        try self.init(
            schemaVersion: values.decode(Int.self, forKey: marker),
            expectedRevision: values.decode(Int64.self, forKey: ProjectSourceCodingKey("expectedRevision")),
            logicalName: values.decode(String.self, forKey: ProjectSourceCodingKey("logicalName")),
            source: values.decode(GitSource.self, forKey: ProjectSourceCodingKey("source"))
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: ProjectSourceCodingKey.self)
        try values.encode(schemaVersion, forKey: ProjectSourceCodingKey("schemaVersion"))
        try values.encode(expectedRevision, forKey: ProjectSourceCodingKey("expectedRevision"))
        try values.encode(logicalName, forKey: ProjectSourceCodingKey("logicalName"))
        try values.encode(source, forKey: ProjectSourceCodingKey("source"))
    }
}

/// Internal/admin source-acquisition primitive. Public clients use the
/// project-scoped `AddProjectRepositoryInput` contract and cannot submit a
/// configured-root alias, physical path, executable, environment, or secret.
public struct ProjectSourceOperationInput: Codable, Hashable, Sendable {
    public enum Source: Codable, Hashable, Sendable {
        case configuredRoot(alias: String)
        case gitClone(remote: String, ref: String)

        private enum Kind: String, Codable {
            case configuredRoot
            case gitClone
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: ProjectSourceCodingKey.self)
            let type = ProjectSourceCodingKey("type")
            switch try values.decode(Kind.self, forKey: type) {
            case .configuredRoot:
                guard Set(values.allKeys.map(\.stringValue)) == Set(["type", "alias"]) else {
                    throw DecodingError.dataCorruptedError(forKey: type, in: values, debugDescription: "Configured root source contains unsupported fields")
                }
                self = try .configuredRoot(alias: values.decode(String.self, forKey: ProjectSourceCodingKey("alias")))
            case .gitClone:
                guard Set(values.allKeys.map(\.stringValue)) == Set(["type", "remote", "ref"]) else {
                    throw DecodingError.dataCorruptedError(forKey: type, in: values, debugDescription: "Git clone source contains unsupported fields")
                }
                self = try .gitClone(
                    remote: values.decode(String.self, forKey: ProjectSourceCodingKey("remote")),
                    ref: values.decode(String.self, forKey: ProjectSourceCodingKey("ref"))
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: ProjectSourceCodingKey.self)
            switch self {
            case let .configuredRoot(alias):
                try values.encode(Kind.configuredRoot, forKey: ProjectSourceCodingKey("type"))
                try values.encode(alias, forKey: ProjectSourceCodingKey("alias"))
            case let .gitClone(remote, ref):
                try values.encode(Kind.gitClone, forKey: ProjectSourceCodingKey("type"))
                try values.encode(remote, forKey: ProjectSourceCodingKey("remote"))
                try values.encode(ref, forKey: ProjectSourceCodingKey("ref"))
            }
        }
    }

    public let schemaVersion: Int
    public let operationID: UUID
    public let expectedRevision: Int64
    public let name: String
    public let logicalName: String
    public let source: Source

    public init(
        schemaVersion: Int = 1,
        operationID: UUID,
        expectedRevision: Int64,
        name: String,
        logicalName: String,
        source: Source
    ) {
        self.schemaVersion = schemaVersion
        self.operationID = operationID
        self.expectedRevision = expectedRevision
        self.name = name
        self.logicalName = logicalName
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: ProjectSourceCodingKey.self)
        let expected = Set(["schemaVersion", "operationId", "expectedRevision", "name", "logicalName", "source"])
        let marker = ProjectSourceCodingKey("schemaVersion")
        guard Set(values.allKeys.map(\.stringValue)) == expected else {
            throw DecodingError.dataCorruptedError(forKey: marker, in: values, debugDescription: "Project source operation contains unsupported fields")
        }
        try self.init(
            schemaVersion: values.decode(Int.self, forKey: marker),
            operationID: values.decode(UUID.self, forKey: ProjectSourceCodingKey("operationId")),
            expectedRevision: values.decode(Int64.self, forKey: ProjectSourceCodingKey("expectedRevision")),
            name: values.decode(String.self, forKey: ProjectSourceCodingKey("name")),
            logicalName: values.decode(String.self, forKey: ProjectSourceCodingKey("logicalName")),
            source: values.decode(Source.self, forKey: ProjectSourceCodingKey("source"))
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: ProjectSourceCodingKey.self)
        try values.encode(schemaVersion, forKey: ProjectSourceCodingKey("schemaVersion"))
        try values.encode(operationID, forKey: ProjectSourceCodingKey("operationId"))
        try values.encode(expectedRevision, forKey: ProjectSourceCodingKey("expectedRevision"))
        try values.encode(name, forKey: ProjectSourceCodingKey("name"))
        try values.encode(logicalName, forKey: ProjectSourceCodingKey("logicalName"))
        try values.encode(source, forKey: ProjectSourceCodingKey("source"))
    }
}

public struct UpdateProjectInput: Codable, Sendable {
    public let expectedRevision: Int64
    public let name: String
    public let roots: [CreateProjectInput.Root]
    public init(expectedRevision: Int64, name: String, roots: [CreateProjectInput.Root]) {
        self.expectedRevision = expectedRevision
        self.name = name
        self.roots = roots
    }

    private enum CodingKeys: String, CodingKey {
        case expectedRevision
        case name
        case roots
    }
}

public struct RemoveProjectInput: Codable, Sendable {
    public let expectedRevision: Int64
    public init(expectedRevision: Int64) {
        self.expectedRevision = expectedRevision
    }

    private enum CodingKeys: String, CodingKey {
        case expectedRevision
    }
}

public struct SelectedMessageContext: Codable, Hashable, Sendable {
    public struct Message: Codable, Hashable, Sendable {
        public let roomID: String
        public let messageID: String
        public let text: String
        public let senderID: String
        public let timestamp: String
        public let revision: String
        public let threadID: String?

        public init(roomID: String, messageID: String, text: String, senderID: String, timestamp: String, revision: String, threadID: String? = nil) {
            self.roomID = roomID
            self.messageID = messageID
            self.text = text
            self.senderID = senderID
            self.timestamp = timestamp
            self.revision = revision
            self.threadID = threadID
        }

        private enum CodingKeys: String, CodingKey {
            case roomID = "roomId"
            case messageID = "messageId"
            case text
            case senderID = "senderId"
            case timestamp, revision
            case threadID = "threadId"
        }
    }

    public let schemaVersion: Int
    public let source: String
    public let messages: [Message]

    public init(schemaVersion: Int = 1, source: String, messages: [Message]) {
        self.schemaVersion = schemaVersion
        self.source = source
        self.messages = messages
    }

    public static let explicitSelectionSource = "explicit-selection"

    public func validated() throws -> Self {
        guard schemaVersion == 1, source == Self.explicitSelectionSource, !messages.isEmpty, messages.count <= 50 else {
            throw ServiceAPIError(code: .invalidRequest, message: "Selected message context is invalid")
        }
        var totalBytes = 0
        for message in messages {
            guard !message.roomID.isEmpty, !message.messageID.isEmpty, !message.senderID.isEmpty,
                  message.roomID.utf8.count <= 256, message.messageID.utf8.count <= 256,
                  message.senderID.utf8.count <= 256, message.text.utf8.count <= 8000,
                  message.timestamp.utf8.count <= 64, message.revision.utf8.count <= 64,
                  (message.threadID?.utf8.count ?? 0) <= 256
            else { throw ServiceAPIError(code: .invalidRequest, message: "Selected message context exceeds its bounds") }
            totalBytes += message.text.utf8.count
        }
        guard totalBytes <= 64000 else { throw ServiceAPIError(code: .invalidRequest, message: "Selected message context exceeds its total bound") }
        return self
    }

    public func frozenPrompt(userPrompt: String?) -> String {
        let rendered = messages.map { message in
            let thread = message.threadID.map { " threadId=\($0)" } ?? ""
            return "[roomId=\(message.roomID) messageId=\(message.messageID) senderId=\(message.senderID) timestamp=\(message.timestamp) revision=\(message.revision)\(thread)]\n\(message.text)"
        }.joined(separator: "\n\n")
        let context = "<selected-message-context schemaVersion=\"1\" source=\"\(Self.explicitSelectionSource)\">\n\(rendered)\n</selected-message-context>"
        guard let userPrompt, !userPrompt.isEmpty else { return context }
        return "\(context)\n\n<user-request>\n\(userPrompt)\n</user-request>"
    }
}

public struct CreateSessionInput: Codable, Sendable {
    public let projectID: UUID
    public let parentSessionID: UUID?
    public let provider: ProviderKind
    public let providerSettingsID: ProviderSettingsID?
    public let model: String?
    public let visibility: Visibility
    public let initialPrompt: String?
    public let selectedMessageContext: SelectedMessageContext?
    public let startImmediately: Bool?
    public let initialPermissionMode: String?
    public let initialProviderSettings: [String: String]?

    public init(projectID: UUID, parentSessionID: UUID? = nil, provider: ProviderKind, providerSettingsID: ProviderSettingsID? = nil, model: String? = nil, visibility: Visibility, initialPrompt: String? = nil, selectedMessageContext: SelectedMessageContext? = nil, startImmediately: Bool = false, initialPermissionMode: String? = nil, initialProviderSettings: [String: String]? = nil) {
        self.projectID = projectID
        self.parentSessionID = parentSessionID
        self.provider = provider
        self.providerSettingsID = providerSettingsID
        self.model = model
        self.visibility = visibility
        self.initialPrompt = initialPrompt
        self.selectedMessageContext = selectedMessageContext
        self.startImmediately = startImmediately
        self.initialPermissionMode = initialPermissionMode
        self.initialProviderSettings = initialProviderSettings
    }

    public var hasInitialProviderIntent: Bool {
        startImmediately == true && (!(initialPrompt ?? "").isEmpty || selectedMessageContext != nil)
    }

    public func frozenForExecution() throws -> Self {
        guard (initialPrompt?.utf8.count ?? 0) <= 64000 else { throw ServiceAPIError(code: .invalidRequest, message: "Initial prompt exceeds its bound") }
        let context = try selectedMessageContext?.validated()
        return CreateSessionInput(
            projectID: projectID,
            parentSessionID: parentSessionID,
            provider: provider,
            providerSettingsID: providerSettingsID,
            model: model,
            visibility: visibility,
            initialPrompt: context?.frozenPrompt(userPrompt: initialPrompt) ?? initialPrompt,
            selectedMessageContext: nil,
            startImmediately: startImmediately == true,
            initialPermissionMode: initialPermissionMode,
            initialProviderSettings: initialProviderSettings
        )
    }

    private enum CodingKeys: String, CodingKey {
        case projectID = "projectId"
        case parentSessionID = "parentSessionId"
        case provider
        case providerSettingsID = "providerSettingsId"
        case model
        case visibility
        case initialPrompt
        case selectedMessageContext
        case startImmediately
        case initialPermissionMode
        case initialProviderSettings
    }
}

/// Internal `POST /internal/v1/sessions` body. Explicit provider/model stays a
/// composer/legacy path. Omitted provider resolves `routingTarget` (default Pair).
public struct CreateSessionRequest: Codable, Sendable {
    public let projectID: UUID
    public let parentSessionID: UUID?
    public let routingTarget: AgentRoutingTarget?
    public let provider: ProviderKind?
    public let providerSettingsID: ProviderSettingsID?
    public let model: String?
    public let visibility: Visibility
    public let initialPrompt: String?
    public let selectedMessageContext: SelectedMessageContext?
    public let startImmediately: Bool?
    public let initialPermissionMode: String?
    public let initialProviderSettings: [String: String]?

    public init(
        projectID: UUID,
        parentSessionID: UUID? = nil,
        routingTarget: AgentRoutingTarget? = nil,
        provider: ProviderKind? = nil,
        providerSettingsID: ProviderSettingsID? = nil,
        model: String? = nil,
        visibility: Visibility,
        initialPrompt: String? = nil,
        selectedMessageContext: SelectedMessageContext? = nil,
        startImmediately: Bool? = nil,
        initialPermissionMode: String? = nil,
        initialProviderSettings: [String: String]? = nil
    ) {
        self.projectID = projectID
        self.parentSessionID = parentSessionID
        self.routingTarget = routingTarget
        self.provider = provider
        self.providerSettingsID = providerSettingsID
        self.model = model
        self.visibility = visibility
        self.initialPrompt = initialPrompt
        self.selectedMessageContext = selectedMessageContext
        self.startImmediately = startImmediately
        self.initialPermissionMode = initialPermissionMode
        self.initialProviderSettings = initialProviderSettings
    }

    public var hasExplicitProviderRoute: Bool {
        if provider != nil || providerSettingsID != nil { return true }
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmed.isEmpty
    }

    public func explicitCreateSessionInput() throws -> CreateSessionInput {
        let provider: ProviderKind
        if let explicit = self.provider {
            provider = explicit
        } else if let settingsID = providerSettingsID, let kind = settingsID.runtimeKind {
            provider = kind
        } else {
            throw ServiceAPIError(code: .invalidRequest, message: "Session start with an explicit model requires a provider")
        }
        return CreateSessionInput(
            projectID: projectID,
            parentSessionID: parentSessionID,
            provider: provider,
            providerSettingsID: providerSettingsID,
            model: model,
            visibility: visibility,
            initialPrompt: initialPrompt,
            selectedMessageContext: selectedMessageContext,
            startImmediately: startImmediately ?? false,
            initialPermissionMode: initialPermissionMode,
            initialProviderSettings: initialProviderSettings
        )
    }

    private enum CodingKeys: String, CodingKey {
        case projectID = "projectId"
        case parentSessionID = "parentSessionId"
        case routingTarget
        case provider
        case providerSettingsID = "providerSettingsId"
        case model
        case visibility
        case initialPrompt
        case selectedMessageContext
        case startImmediately
        case initialPermissionMode
        case initialProviderSettings
    }
}

public enum ProviderResumeMode: String, Codable, CaseIterable, Sendable {
    case fresh, resume, auto
}

public enum SessionCommand: Codable, Sendable {
    case resumeSession(expectedRunID: UUID?, providerResumeMode: ProviderResumeMode)
    case sendFollowup(text: String, expectedSessionRevision: Int64)
    case steerSession(text: String, targetTurnEpoch: Int64)
    case cancelSession(expectedRunID: UUID?, expectedGeneration: Int64)
    case retrySession(sourceRunID: UUID, fromTranscriptEntryID: UUID?)
    case answerInteraction(interactionID: UUID, expectedRevision: Int64, payload: Data)
    case updateExecutionPermissions(expectedRevision: Int64, executionMode: String, providerSettings: [String: String])
    case setSessionVisibility(expectedPolicyRevision: Int64, visibility: Visibility, collaborativeSteeringEnabled: Bool, controllerUserID: String)
    case updateSelection(mode: String, expectedRevision: Int64, operations: [String])
    case buildContext(expectedSelectionRevision: Int64, include: [String])
    case runContextBuilder(expectedSelectionRevision: Int64, instructions: String, budget: Int)
    case askOracle(chatID: UUID?, prompt: String, contextMode: String)
    case createWorktree(rootID: UUID, baseRef: String, branchName: String)
    case bindWorktree(bindingID: UUID, expectedRevision: Int64)
    case mergeWorktree(bindingID: UUID, strategy: String, expectedRevision: Int64)
    case abortConflictedMerge(bindingID: UUID, leaseID: UUID, expectedRevision: Int64)
    case archiveSession(expectedRevision: Int64)

    public var operation: String {
        switch self {
        case .resumeSession: "resumeSession"
        case .sendFollowup: "sendFollowup"
        case .steerSession: "steerSession"
        case .cancelSession: "cancelSession"
        case .retrySession: "retrySession"
        case .answerInteraction: "answerInteraction"
        case .updateExecutionPermissions: "updateExecutionPermissions"
        case .setSessionVisibility: "setSessionVisibility"
        case .updateSelection: "updateSelection"
        case .buildContext: "buildContext"
        case .runContextBuilder: "runContextBuilder"
        case .askOracle: "askOracle"
        case .createWorktree: "createWorktree"
        case .bindWorktree: "bindWorktree"
        case .mergeWorktree: "mergeWorktree"
        case .abortConflictedMerge: "abortConflictedMerge"
        case .archiveSession: "archiveSession"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case operation, providerResumeMode, text, expectedSessionRevision, targetTurnEpoch, expectedGeneration
        case expectedRunID = "expectedRunId"
        case sourceRunID = "sourceRunId"
        case fromTranscriptEntryID = "fromTranscriptEntryId"
        case interactionID = "interactionId"
        case expectedRevision, payload, executionMode, providerSettings, expectedPolicyRevision, visibility, collaborativeSteeringEnabled
        case controllerUserID = "controllerUserId"
        case mode, operations, expectedSelectionRevision, include, instructions, budget, prompt, contextMode, baseRef, branchName, strategy
        case chatID = "chatId"
        case rootID = "rootId"
        case bindingID = "bindingId"
        case leaseID = "leaseId"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let operation = try values.decode(String.self, forKey: .operation)
        switch operation {
        case "resumeSession": self = try .resumeSession(expectedRunID: values.decodeIfPresent(UUID.self, forKey: .expectedRunID), providerResumeMode: values.decode(ProviderResumeMode.self, forKey: .providerResumeMode))
        case "sendFollowup": self = try .sendFollowup(text: values.decode(String.self, forKey: .text), expectedSessionRevision: values.decode(Int64.self, forKey: .expectedSessionRevision))
        case "steerSession": self = try .steerSession(text: values.decode(String.self, forKey: .text), targetTurnEpoch: values.decode(Int64.self, forKey: .targetTurnEpoch))
        case "cancelSession": self = try .cancelSession(expectedRunID: values.decodeIfPresent(UUID.self, forKey: .expectedRunID), expectedGeneration: values.decode(Int64.self, forKey: .expectedGeneration))
        case "retrySession": self = try .retrySession(sourceRunID: values.decode(UUID.self, forKey: .sourceRunID), fromTranscriptEntryID: values.decodeIfPresent(UUID.self, forKey: .fromTranscriptEntryID))
        case "answerInteraction": self = try .answerInteraction(interactionID: values.decode(UUID.self, forKey: .interactionID), expectedRevision: values.decode(Int64.self, forKey: .expectedRevision), payload: values.decode(Data.self, forKey: .payload))
        case "updateExecutionPermissions": self = try .updateExecutionPermissions(expectedRevision: values.decode(Int64.self, forKey: .expectedRevision), executionMode: values.decode(String.self, forKey: .executionMode), providerSettings: values.decode([String: String].self, forKey: .providerSettings))
        case "setSessionVisibility": self = try .setSessionVisibility(expectedPolicyRevision: values.decode(Int64.self, forKey: .expectedPolicyRevision), visibility: values.decode(Visibility.self, forKey: .visibility), collaborativeSteeringEnabled: values.decode(Bool.self, forKey: .collaborativeSteeringEnabled), controllerUserID: values.decode(String.self, forKey: .controllerUserID))
        case "updateSelection": self = try .updateSelection(mode: values.decode(String.self, forKey: .mode), expectedRevision: values.decode(Int64.self, forKey: .expectedRevision), operations: values.decode([String].self, forKey: .operations))
        case "buildContext": self = try .buildContext(expectedSelectionRevision: values.decode(Int64.self, forKey: .expectedSelectionRevision), include: values.decode([String].self, forKey: .include))
        case "runContextBuilder": self = try .runContextBuilder(expectedSelectionRevision: values.decode(Int64.self, forKey: .expectedSelectionRevision), instructions: values.decode(String.self, forKey: .instructions), budget: values.decode(Int.self, forKey: .budget))
        case "askOracle": self = try .askOracle(chatID: values.decodeIfPresent(UUID.self, forKey: .chatID), prompt: values.decode(String.self, forKey: .prompt), contextMode: values.decode(String.self, forKey: .contextMode))
        case "createWorktree": self = try .createWorktree(rootID: values.decode(UUID.self, forKey: .rootID), baseRef: values.decode(String.self, forKey: .baseRef), branchName: values.decode(String.self, forKey: .branchName))
        case "bindWorktree": self = try .bindWorktree(bindingID: values.decode(UUID.self, forKey: .bindingID), expectedRevision: values.decode(Int64.self, forKey: .expectedRevision))
        case "mergeWorktree": self = try .mergeWorktree(bindingID: values.decode(UUID.self, forKey: .bindingID), strategy: values.decode(String.self, forKey: .strategy), expectedRevision: values.decode(Int64.self, forKey: .expectedRevision))
        case "abortConflictedMerge": self = try .abortConflictedMerge(bindingID: values.decode(UUID.self, forKey: .bindingID), leaseID: values.decode(UUID.self, forKey: .leaseID), expectedRevision: values.decode(Int64.self, forKey: .expectedRevision))
        case "archiveSession": self = try .archiveSession(expectedRevision: values.decode(Int64.self, forKey: .expectedRevision))
        default: throw DecodingError.dataCorruptedError(forKey: .operation, in: values, debugDescription: "Unsupported v1 session operation")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(operation, forKey: .operation)
        switch self {
        case let .resumeSession(expectedRunID, providerResumeMode): try values.encodeIfPresent(expectedRunID, forKey: .expectedRunID)
            try values.encode(providerResumeMode, forKey: .providerResumeMode)
        case let .sendFollowup(text, revision): try values.encode(text, forKey: .text)
            try values.encode(revision, forKey: .expectedSessionRevision)
        case let .steerSession(text, epoch): try values.encode(text, forKey: .text)
            try values.encode(epoch, forKey: .targetTurnEpoch)
        case let .cancelSession(runID, generation): try values.encodeIfPresent(runID, forKey: .expectedRunID)
            try values.encode(generation, forKey: .expectedGeneration)
        case let .retrySession(runID, entryID): try values.encode(runID, forKey: .sourceRunID)
            try values.encodeIfPresent(entryID, forKey: .fromTranscriptEntryID)
        case let .answerInteraction(id, revision, payload): try values.encode(id, forKey: .interactionID)
            try values.encode(revision, forKey: .expectedRevision)
            try values.encode(payload, forKey: .payload)
        case let .updateExecutionPermissions(revision, mode, settings): try values.encode(revision, forKey: .expectedRevision)
            try values.encode(mode, forKey: .executionMode)
            try values.encode(settings, forKey: .providerSettings)
        case let .setSessionVisibility(revision, visibility, steering, controller): try values.encode(revision, forKey: .expectedPolicyRevision)
            try values.encode(visibility, forKey: .visibility)
            try values.encode(steering, forKey: .collaborativeSteeringEnabled)
            try values.encode(controller, forKey: .controllerUserID)
        case let .updateSelection(mode, revision, operations): try values.encode(mode, forKey: .mode)
            try values.encode(revision, forKey: .expectedRevision)
            try values.encode(operations, forKey: .operations)
        case let .buildContext(revision, include): try values.encode(revision, forKey: .expectedSelectionRevision)
            try values.encode(include, forKey: .include)
        case let .runContextBuilder(revision, instructions, budget): try values.encode(revision, forKey: .expectedSelectionRevision)
            try values.encode(instructions, forKey: .instructions)
            try values.encode(budget, forKey: .budget)
        case let .askOracle(chatID, prompt, mode): try values.encodeIfPresent(chatID, forKey: .chatID)
            try values.encode(prompt, forKey: .prompt)
            try values.encode(mode, forKey: .contextMode)
        case let .createWorktree(rootID, baseRef, branch): try values.encode(rootID, forKey: .rootID)
            try values.encode(baseRef, forKey: .baseRef)
            try values.encode(branch, forKey: .branchName)
        case let .bindWorktree(id, revision): try values.encode(id, forKey: .bindingID)
            try values.encode(revision, forKey: .expectedRevision)
        case let .mergeWorktree(id, strategy, revision): try values.encode(id, forKey: .bindingID)
            try values.encode(strategy, forKey: .strategy)
            try values.encode(revision, forKey: .expectedRevision)
        case let .abortConflictedMerge(bindingID, leaseID, revision): try values.encode(bindingID, forKey: .bindingID)
            try values.encode(leaseID, forKey: .leaseID)
            try values.encode(revision, forKey: .expectedRevision)
        case let .archiveSession(revision): try values.encode(revision, forKey: .expectedRevision)
        }
    }
}

public struct CommandReceipt: Codable, Hashable, Sendable {
    public let commandID: UUID
    public let sessionID: UUID
    public let operation: String
    public let acceptedCursor: ServiceCursor
    public let status: String
    public init(commandID: UUID, sessionID: UUID, operation: String, acceptedCursor: ServiceCursor, status: String) {
        self.commandID = commandID
        self.sessionID = sessionID
        self.operation = operation
        self.acceptedCursor = acceptedCursor
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case commandID = "commandId"
        case sessionID = "sessionId"
        case operation
        case acceptedCursor
        case status
    }
}
