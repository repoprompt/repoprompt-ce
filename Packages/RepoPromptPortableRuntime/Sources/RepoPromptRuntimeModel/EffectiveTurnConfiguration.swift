import Foundation

public enum AgentControlValue: Codable, Hashable, Sendable {
    case boolean(Bool)
    case choice(String)
    case choices([String])

    private enum CodingKeys: String, CodingKey { case type, value }
    private enum Kind: String, Codable { case boolean, choice, choices }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .type) {
        case .boolean: self = try .boolean(values.decode(Bool.self, forKey: .value))
        case .choice: self = try .choice(values.decode(String.self, forKey: .value))
        case .choices: self = try .choices(values.decode([String].self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .boolean(value): try values.encode(Kind.boolean, forKey: .type)
            try values.encode(value, forKey: .value)
        case let .choice(value): try values.encode(Kind.choice, forKey: .type)
            try values.encode(value, forKey: .value)
        case let .choices(value): try values.encode(Kind.choices, forKey: .type)
            try values.encode(value, forKey: .value)
        }
    }
}

public struct EffectiveTurnConfigurationRecord: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let catalogRevision: String
    public let providerID: ProviderSettingsID
    public let modelID: String
    public let providerRawModelValue: String
    public let effortID: String?
    public let workflowID: String?
    public let permissionID: String?
    public let toolValues: [String: AgentControlValue]
    public let capabilityDigest: String
    public let actorID: String
    public let acceptedAt: Date

    public init(
        schemaVersion: Int = 1,
        catalogRevision: String,
        providerID: ProviderSettingsID,
        modelID: String,
        providerRawModelValue: String,
        effortID: String? = nil,
        workflowID: String? = nil,
        permissionID: String? = nil,
        toolValues: [String: AgentControlValue] = [:],
        capabilityDigest: String,
        actorID: String,
        acceptedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.catalogRevision = catalogRevision
        self.providerID = providerID
        self.modelID = modelID
        self.providerRawModelValue = providerRawModelValue
        self.effortID = effortID
        self.workflowID = workflowID
        self.permissionID = permissionID
        self.toolValues = toolValues
        self.capabilityDigest = capabilityDigest
        self.actorID = actorID
        self.acceptedAt = acceptedAt
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1,
              !catalogRevision.isEmpty,
              !modelID.isEmpty,
              modelID.lowercased() != "default",
              !providerRawModelValue.isEmpty,
              !capabilityDigest.isEmpty,
              !actorID.isEmpty,
              toolValues.keys.allSatisfy({ $0.contains(".") })
        else {
            throw ServiceAPIError(code: .invalidRequest, message: "Effective turn configuration is invalid")
        }
        return self
    }
}

public struct SessionNextTurnDefaultsRecord: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let sessionID: UUID
    public let revision: Int64
    public let configuration: EffectiveTurnConfigurationRecord
    public let updatedAt: Date

    public init(schemaVersion: Int = 1, sessionID: UUID, revision: Int64, configuration: EffectiveTurnConfigurationRecord, updatedAt: Date) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.revision = revision
        self.configuration = configuration
        self.updatedAt = updatedAt
    }
}

public extension EffectiveTurnConfigurationWireSnapshot {
    init(_ record: EffectiveTurnConfigurationRecord) {
        self.init(
            schemaVersion: record.schemaVersion,
            configuration: AgentTurnConfigurationWire(
                catalogRevision: record.catalogRevision,
                providerID: record.providerID,
                modelID: record.modelID,
                effortID: record.effortID,
                workflowID: record.workflowID,
                permissionID: record.permissionID,
                toolValues: record.toolValues.mapValues { value in
                    switch value {
                    case let .boolean(value): .boolean(value)
                    case let .choice(value): .choice(value)
                    case let .choices(value): .choices(value)
                    }
                }
            ),
            capabilityDigest: record.capabilityDigest,
            actorID: record.actorID,
            acceptedAt: record.acceptedAt
        )
    }
}

public extension SessionNextTurnDefaultsWireSnapshot {
    init(_ record: SessionNextTurnDefaultsRecord) {
        self.init(
            schemaVersion: record.schemaVersion,
            sessionID: record.sessionID,
            revision: record.revision,
            configuration: .init(record.configuration),
            updatedAt: record.updatedAt
        )
    }
}

public struct CanonicalTurnIdentity: Codable, Hashable, Sendable {
    public let requestAnchorID: UUID
    public let runID: UUID
    public let generation: Int64
    public let turnEpoch: Int64
    public let turnID: UUID
    public let responseSpanID: UUID

    public init(requestAnchorID: UUID, runID: UUID, generation: Int64, turnEpoch: Int64, turnID: UUID, responseSpanID: UUID) {
        self.requestAnchorID = requestAnchorID
        self.runID = runID
        self.generation = generation
        self.turnEpoch = turnEpoch
        self.turnID = turnID
        self.responseSpanID = responseSpanID
    }
}

public enum RunPresentationPhase: String, Codable, CaseIterable, Hashable, Sendable {
    case preparing
    case thinking
    case working
    case waiting
    case cancelling
}

public struct RunPresentationSnapshot: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let sessionID: UUID
    public let runID: UUID
    public let generation: Int64
    public let turnEpoch: Int64
    public let phase: RunPresentationPhase?
    public let phaseRevision: Int64
    public let runningStatusCode: String?
    public let runningStatusText: String?
    public let runStartedAt: Date
    public let priorActivePhase: RunPresentationPhase?
    public let terminalSettlementCode: String?
    public let terminalSettledAt: Date?

    public init(
        schemaVersion: Int = 1,
        sessionID: UUID,
        runID: UUID,
        generation: Int64,
        turnEpoch: Int64,
        phase: RunPresentationPhase?,
        phaseRevision: Int64,
        runningStatusCode: String? = nil,
        runningStatusText: String? = nil,
        runStartedAt: Date,
        priorActivePhase: RunPresentationPhase? = nil,
        terminalSettlementCode: String? = nil,
        terminalSettledAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.runID = runID
        self.generation = generation
        self.turnEpoch = turnEpoch
        self.phase = phase
        self.phaseRevision = phaseRevision
        self.runningStatusCode = runningStatusCode
        self.runningStatusText = runningStatusText
        self.runStartedAt = runStartedAt
        self.priorActivePhase = priorActivePhase
        self.terminalSettlementCode = terminalSettlementCode
        self.terminalSettledAt = terminalSettledAt
    }

    public var wireSnapshot: RunPresentationWireSnapshot {
        .init(
            schemaVersion: schemaVersion,
            sessionID: sessionID,
            runID: runID,
            generation: generation,
            turnEpoch: turnEpoch,
            phase: phase.flatMap { RunPresentationPhaseWire(rawValue: $0.rawValue) },
            phaseRevision: phaseRevision,
            runningStatusCode: runningStatusCode,
            runningStatusText: runningStatusText,
            runStartedAt: runStartedAt,
            priorActivePhase: priorActivePhase.flatMap { RunPresentationPhaseWire(rawValue: $0.rawValue) },
            terminalSettlementCode: terminalSettlementCode,
            terminalSettledAt: terminalSettledAt
        )
    }

    public func transitioning(to next: RunPresentationPhase, statusCode: String? = nil, statusText: String? = nil) throws -> Self {
        guard terminalSettlementCode == nil else {
            throw ServiceAPIError(code: .staleRevision, message: "Terminal run presentation cannot transition")
        }
        let legal = switch (phase, next) {
        case (nil, .preparing), (.preparing, .thinking), (.preparing, .working), (.thinking, .thinking), (.thinking, .working), (.thinking, .waiting), (.working, .working), (.working, .thinking), (.working, .waiting), (.waiting, .waiting), (.waiting, .thinking), (.waiting, .working), (.preparing, .cancelling), (.thinking, .cancelling), (.working, .cancelling), (.waiting, .cancelling), (.cancelling, .cancelling): true
        default: false
        }
        guard legal else { throw ServiceAPIError(code: .staleRevision, message: "Illegal run presentation phase transition") }
        let previous = next == .waiting ? phase : (phase == .waiting ? priorActivePhase : nil)
        return .init(
            sessionID: sessionID,
            runID: runID,
            generation: generation,
            turnEpoch: turnEpoch,
            phase: next,
            phaseRevision: phaseRevision + 1,
            runningStatusCode: statusCode,
            runningStatusText: statusText,
            runStartedAt: runStartedAt,
            priorActivePhase: previous
        )
    }

    public func settling(code: String, at date: Date) -> Self {
        .init(
            sessionID: sessionID,
            runID: runID,
            generation: generation,
            turnEpoch: turnEpoch,
            phase: nil,
            phaseRevision: phaseRevision + 1,
            runStartedAt: runStartedAt,
            priorActivePhase: priorActivePhase,
            terminalSettlementCode: code,
            terminalSettledAt: date
        )
    }
}
