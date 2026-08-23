import Foundation

public extension JSONEncoder {
    static var serviceEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

public extension JSONDecoder {
    static var serviceDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum AgentSubmissionState: String, Codable, Hashable, Sendable {
    case preparing
    case accepted
    case rejected
}

public struct AgentSubmissionRecord: Codable, Hashable, Sendable {
    public let submissionID: UUID
    public let actorID: String
    public let targetKey: String
    public let operation: String
    public let publicKey: String
    public let requestDigest: String
    public let state: AgentSubmissionState
    public let sessionID: UUID?
    public let identity: CanonicalTurnIdentity
    public let preparedJSON: Data?
    public let compiledInputJSON: Data?
    public let receiptJSON: Data?
    public let rejectionCode: String?
    public let dispatchState: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(submissionID: UUID, actorID: String, targetKey: String, operation: String, publicKey: String, requestDigest: String, state: AgentSubmissionState, sessionID: UUID?, identity: CanonicalTurnIdentity, preparedJSON: Data? = nil, compiledInputJSON: Data? = nil, receiptJSON: Data? = nil, rejectionCode: String? = nil, dispatchState: String = "pending", createdAt: Date, updatedAt: Date) {
        self.submissionID = submissionID
        self.actorID = actorID
        self.targetKey = targetKey
        self.operation = operation
        self.publicKey = publicKey
        self.requestDigest = requestDigest
        self.state = state
        self.sessionID = sessionID
        self.identity = identity
        self.preparedJSON = preparedJSON
        self.compiledInputJSON = compiledInputJSON
        self.receiptJSON = receiptJSON
        self.rejectionCode = rejectionCode
        self.dispatchState = dispatchState
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum SemanticActivityKind: String, Codable, Hashable, Sendable {
    case assistant, reasoning, progress, tool, note, error, conclusion
}

public enum SemanticInteractionAnchor: Codable, Hashable, Sendable {
    case activity(turnID: UUID, activityID: UUID?)
    case liveTail(turnID: UUID)

    private enum CodingKeys: String, CodingKey { case type, turnID, activityID }
    private enum Kind: String, Codable { case activity, liveTail }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let turnID = try values.decode(UUID.self, forKey: .turnID)
        switch try values.decode(Kind.self, forKey: .type) {
        case .activity: self = try .activity(turnID: turnID, activityID: values.decodeIfPresent(UUID.self, forKey: .activityID))
        case .liveTail: self = .liveTail(turnID: turnID)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .activity(turnID, activityID):
            try values.encode(Kind.activity, forKey: .type)
            try values.encode(turnID, forKey: .turnID)
            try values.encodeIfPresent(activityID, forKey: .activityID)
        case let .liveTail(turnID):
            try values.encode(Kind.liveTail, forKey: .type)
            try values.encode(turnID, forKey: .turnID)
        }
    }
}

public struct SemanticTurnRecord: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let sessionID: UUID
    public let identity: CanonicalTurnIdentity
    public let providerTurnID: String?
    public let firstSequence: Int64
    public let lastSequence: Int64
    public let terminalState: String?
    public let canonicalUserTurnJSON: Data
    public let effectiveConfiguration: EffectiveTurnConfigurationRecord
    public let attachmentManifestJSON: Data
    public let taggedFiles: [ComposerTaggedFileReferenceWire]
    public let createdAt: Date
    public let acceptedAt: Date
    public let settledAt: Date?

    public init(schemaVersion: Int = 1, sessionID: UUID, identity: CanonicalTurnIdentity, providerTurnID: String? = nil, firstSequence: Int64, lastSequence: Int64, terminalState: String? = nil, canonicalUserTurnJSON: Data, effectiveConfiguration: EffectiveTurnConfigurationRecord, attachmentManifestJSON: Data = Data("[]".utf8), taggedFiles: [ComposerTaggedFileReferenceWire] = [], createdAt: Date, acceptedAt: Date, settledAt: Date? = nil) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.identity = identity
        self.providerTurnID = providerTurnID
        self.firstSequence = firstSequence
        self.lastSequence = lastSequence
        self.terminalState = terminalState
        self.canonicalUserTurnJSON = canonicalUserTurnJSON
        self.effectiveConfiguration = effectiveConfiguration
        self.attachmentManifestJSON = attachmentManifestJSON
        self.taggedFiles = taggedFiles
        self.createdAt = createdAt
        self.acceptedAt = acceptedAt
        self.settledAt = settledAt
    }
}

public struct SemanticActivityRecord: Codable, Hashable, Sendable {
    public let activityID: UUID
    public let sessionID: UUID
    public let identity: CanonicalTurnIdentity
    public let canonicalSequence: Int64
    public let revision: Int64
    public let kind: SemanticActivityKind
    public let content: String?
    public let summary: String?
    public let status: String?
    public let interactionAnchor: SemanticInteractionAnchor?
    public let createdAt: Date
    public let updatedAt: Date

    public init(activityID: UUID, sessionID: UUID, identity: CanonicalTurnIdentity, canonicalSequence: Int64, revision: Int64, kind: SemanticActivityKind, content: String? = nil, summary: String? = nil, status: String? = nil, interactionAnchor: SemanticInteractionAnchor? = nil, createdAt: Date, updatedAt: Date) {
        self.activityID = activityID
        self.sessionID = sessionID
        self.identity = identity
        self.canonicalSequence = canonicalSequence
        self.revision = revision
        self.kind = kind
        self.content = content
        self.summary = summary
        self.status = status
        self.interactionAnchor = interactionAnchor
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct SemanticToolRecord: Codable, Hashable, Sendable {
    public let executionID: String
    public let activityID: UUID
    public let turnID: UUID
    public let sessionID: UUID
    public let canonicalSequence: Int64
    public let revision: Int64
    public let normalizedName: String
    public let status: AgentPresentationToolStatus
    public let displayArguments: String?
    public let displayResult: String?
    public let summary: String?
    public let keyPaths: [String]
    public let processID: Int?
    public let exitCode: Int?
    public let errorCode: String?
    public let argumentDigest: String?
    public let resultDigest: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(executionID: String, activityID: UUID, turnID: UUID, sessionID: UUID, canonicalSequence: Int64, revision: Int64, normalizedName: String, status: AgentPresentationToolStatus, displayArguments: String? = nil, displayResult: String? = nil, summary: String? = nil, keyPaths: [String] = [], processID: Int? = nil, exitCode: Int? = nil, errorCode: String? = nil, argumentDigest: String? = nil, resultDigest: String? = nil, createdAt: Date, updatedAt: Date) {
        self.executionID = executionID
        self.activityID = activityID
        self.turnID = turnID
        self.sessionID = sessionID
        self.canonicalSequence = canonicalSequence
        self.revision = revision
        self.normalizedName = normalizedName
        self.status = status
        self.displayArguments = displayArguments
        self.displayResult = displayResult
        self.summary = summary
        self.keyPaths = keyPaths
        self.processID = processID
        self.exitCode = exitCode
        self.errorCode = errorCode
        self.argumentDigest = argumentDigest
        self.resultDigest = resultDigest
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PreparedNewAgentSession: Hashable, Sendable {
    public let snapshot: SessionSnapshot
    public let agent: AgentSnapshot
    public let initialSelection: SelectionSnapshot
    public let initialPermissions: ExecutionPermissionSnapshot
    public let initialCollaboration: CollaborationMetadataSnapshot
    public let initialWorktrees: [WorktreeBindingSnapshot]
    public let expectedProjectRevision: Int64
    public let expectedProjectRootIDs: [UUID]
    public let sessionCorrelationID: UUID
    public let agentCorrelationID: UUID

    public init(snapshot: SessionSnapshot, agent: AgentSnapshot, initialSelection: SelectionSnapshot, initialPermissions: ExecutionPermissionSnapshot, initialCollaboration: CollaborationMetadataSnapshot, initialWorktrees: [WorktreeBindingSnapshot] = [], expectedProjectRevision: Int64, expectedProjectRootIDs: [UUID], sessionCorrelationID: UUID, agentCorrelationID: UUID) {
        self.snapshot = snapshot
        self.agent = agent
        self.initialSelection = initialSelection
        self.initialPermissions = initialPermissions
        self.initialCollaboration = initialCollaboration
        self.initialWorktrees = initialWorktrees
        self.expectedProjectRevision = expectedProjectRevision
        self.expectedProjectRootIDs = expectedProjectRootIDs
        self.sessionCorrelationID = sessionCorrelationID
        self.agentCorrelationID = agentCorrelationID
    }

    public func replacingSnapshot(_ snapshot: SessionSnapshot) -> Self {
        .init(snapshot: snapshot, agent: agent, initialSelection: initialSelection, initialPermissions: initialPermissions, initialCollaboration: initialCollaboration, initialWorktrees: initialWorktrees, expectedProjectRevision: expectedProjectRevision, expectedProjectRootIDs: expectedProjectRootIDs, sessionCorrelationID: sessionCorrelationID, agentCorrelationID: agentCorrelationID)
    }
}

public struct NewAgentSessionAcceptanceEvents: Sendable {
    public let session: EventEnvelope
    public let agent: EventEnvelope
    public let worktrees: [EventEnvelope]

    public init(session: EventEnvelope, agent: EventEnvelope, worktrees: [EventEnvelope]) {
        self.session = session
        self.agent = agent
        self.worktrees = worktrees
    }
}

public struct SemanticIngestionWatermark: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let lastLegacySequence: Int64
    public let lastSemanticSequence: Int64
    public let presentationRevision: Int64
    public let gapDetected: Bool
    public let updatedAt: Date

    public init(sessionID: UUID, lastLegacySequence: Int64, lastSemanticSequence: Int64, presentationRevision: Int64, gapDetected: Bool, updatedAt: Date) {
        self.sessionID = sessionID
        self.lastLegacySequence = lastLegacySequence
        self.lastSemanticSequence = lastSemanticSequence
        self.presentationRevision = presentationRevision
        self.gapDetected = gapDetected
        self.updatedAt = updatedAt
    }
}

public struct StoredComposerAttachment: Codable, Hashable, Sendable {
    public let wire: ComposerAttachmentWire
    public let actorID: String
    public let projectID: UUID
    public let sessionID: UUID?
    public let turnID: UUID?
    public let stagedPath: String?
    public let persistentPath: String?
    public let leaseSubmissionID: UUID?
    public let createdAt: Date
    public let updatedAt: Date

    public init(wire: ComposerAttachmentWire, actorID: String, projectID: UUID, sessionID: UUID? = nil, turnID: UUID? = nil, stagedPath: String? = nil, persistentPath: String? = nil, leaseSubmissionID: UUID? = nil, createdAt: Date, updatedAt: Date) {
        self.wire = wire
        self.actorID = actorID
        self.projectID = projectID
        self.sessionID = sessionID
        self.turnID = turnID
        self.stagedPath = stagedPath
        self.persistentPath = persistentPath
        self.leaseSubmissionID = leaseSubmissionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct StoredSettingsDocument<Value: Codable & Sendable>: Codable, Sendable {
    public let value: Value
    public let revision: Int64
    public let updatedAt: Date

    public init(value: Value, revision: Int64, updatedAt: Date) {
        self.value = value
        self.revision = revision
        self.updatedAt = updatedAt
    }
}

public struct IdempotencyInput: Sendable {
    public let actorID: String
    public let operation: String
    public let key: String
    public let requestDigest: String
    public init(actorID: String, operation: String, key: String, requestDigest: String) {
        self.actorID = actorID
        self.operation = operation
        self.key = key
        self.requestDigest = requestDigest
    }
}

public struct ExistingIdempotency: Error, Sendable { public let response: Data
    public let status: Int
    public init(_ value: (Data, Int)) {
        response = value.0
        status = value.1
    }
}

public struct StoredComposerProviderCatalog: Codable, Hashable, Sendable {
    public let providerID: ProviderSettingsID
    public let models: [ProviderModelCatalogEntry]
    public let observedAt: Date

    public init(providerID: ProviderSettingsID, models: [ProviderModelCatalogEntry], observedAt: Date) {
        self.providerID = providerID
        self.models = models
        self.observedAt = observedAt
    }
}

public struct StoredProviderConnection: Sendable {
    public let record: ProviderConnectionRecord
    public let credentialReference: UUID?

    public init(record: ProviderConnectionRecord, credentialReference: UUID?) {
        self.record = record
        self.credentialReference = credentialReference
    }
}

public struct ProviderConnectionAuditMutation: Sendable {
    public let operation: String
    public let attribution: ProviderMutationAttribution
    public let authenticationMethod: ProviderAuthenticationMethod?
    public let result: String

    public init(operation: String, attribution: ProviderMutationAttribution, authenticationMethod: ProviderAuthenticationMethod?, result: String) {
        self.operation = operation
        self.attribution = attribution
        self.authenticationMethod = authenticationMethod
        self.result = result
    }
}
