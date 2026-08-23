import Foundation

public enum JSONValue: Codable, Hashable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case boolean(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .boolean(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct EventPayload: Codable, Hashable, Sendable {
    public let object: [String: JSONValue]

    public init(object: [String: JSONValue]) {
        self.object = Self.sanitized(object)
    }

    public init(jsonData: Data) throws {
        let decoded = try JSONDecoder().decode(JSONValue.self, from: jsonData)
        guard case let .object(object) = decoded else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Event payload must be a JSON object"))
        }
        self.object = Self.sanitized(object)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let object = try? container.decode([String: JSONValue].self) {
            self.init(object: object)
            return
        }
        // Schema-v1/v2 compatibility: Data synthesized as a base64 JSON string.
        let legacy = try container.decode(String.self)
        guard let data = Data(base64Encoded: legacy) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Legacy event payload is not base64")
        }
        try self.init(jsonData: data)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(object)
    }

    private static func sanitized(_ object: [String: JSONValue]) -> [String: JSONValue] {
        object.reduce(into: [:]) { output, element in
            guard !["canonicalPath", "physicalPath", "executablePath", "storageReference"].contains(element.key) else { return }
            output[element.key] = sanitized(element.value)
        }
    }

    private static func sanitized(_ value: JSONValue) -> JSONValue {
        switch value {
        case let .object(object): .object(sanitized(object))
        case let .array(values): .array(values.map(sanitized))
        default: value
        }
    }
}

public enum EventType: String, Codable, CaseIterable, Sendable {
    case projectCreated = "project.created", projectUpdated = "project.updated", projectRemoved = "project.removed", projectRefreshed = "project.refreshed", workflowUpdated = "workflow.updated"
    case sessionCreated = "session.created", sessionUpdated = "session.updated", sessionWaiting = "session.waiting", sessionCompleted = "session.completed", sessionFailed = "session.failed", sessionCanceled = "session.canceled", sessionInterrupted = "session.interrupted", sessionResumed = "session.resumed", sessionArchived = "session.archived"
    case agentStarted = "agent.started", agentUpdated = "agent.updated", agentCompleted = "agent.completed", agentFailed = "agent.failed"
    case transcriptMessage = "transcript.message", transcriptProgress = "transcript.progress"
    case toolStarted = "tool.started", toolUpdated = "tool.updated", toolCompleted = "tool.completed", toolFailed = "tool.failed"
    case selectionUpdated = "selection.updated", contextUpdated = "context.updated", artifactCreated = "artifact.created", diffUpdated = "diff.updated"
    case interactionRequested = "interaction.requested", interactionResolved = "interaction.resolved"
    case permissionUpdated = "permission.updated", controllerUpdated = "controller.updated", visibilityUpdated = "visibility.updated"
    case worktreeCreated = "worktree.created", worktreeUpdated = "worktree.updated", worktreeFailed = "worktree.failed"
    case serviceRecovery = "service.recovery", serviceDiagnostic = "service.diagnostic"
}

public struct EventEnvelope: Codable, Hashable, Sendable {
    public let protocolVersion: Int
    public let eventID: UUID
    public let storeID: UUID
    public let globalSequence: Int64
    public let timestamp: Date
    public let projectID: UUID
    public let sessionID: UUID?
    public let agentID: UUID?
    public let parentAgentID: UUID?
    public let rootSessionID: UUID?
    public let runID: UUID?
    public let sessionSequence: Int64?
    public let eventType: EventType
    public let payloadVersion: Int
    public let generation: Int64?
    public let turnEpoch: Int64?
    public let actor: ExternalActor?
    public let correlationID: UUID
    public let causationID: UUID?
    public let payload: EventPayload
    public let digest: String
    public let keyID: String
    public let signature: String

    public var cursor: ServiceCursor {
        ServiceCursor(storeID: storeID, globalSequence: globalSequence)
    }

    public init(protocolVersion: Int = 1, eventID: UUID, storeID: UUID, globalSequence: Int64, timestamp: Date, projectID: UUID, sessionID: UUID?, agentID: UUID?, parentAgentID: UUID?, rootSessionID: UUID?, runID: UUID?, sessionSequence: Int64?, eventType: EventType, payloadVersion: Int = 1, generation: Int64?, turnEpoch: Int64?, actor: ExternalActor?, correlationID: UUID, causationID: UUID?, payload: EventPayload, digest: String, keyID: String, signature: String) {
        self.protocolVersion = protocolVersion
        self.eventID = eventID
        self.storeID = storeID
        self.globalSequence = globalSequence
        self.timestamp = timestamp
        self.projectID = projectID
        self.sessionID = sessionID
        self.agentID = agentID
        self.parentAgentID = parentAgentID
        self.rootSessionID = rootSessionID
        self.runID = runID
        self.sessionSequence = sessionSequence
        self.eventType = eventType
        self.payloadVersion = payloadVersion
        self.generation = generation
        self.turnEpoch = turnEpoch
        self.actor = actor
        self.correlationID = correlationID
        self.causationID = causationID
        self.payload = payload
        self.digest = digest
        self.keyID = keyID
        self.signature = signature
    }

    public func replacingIntegrity(keyID: String, digest: String, signature: String) -> EventEnvelope {
        EventEnvelope(
            protocolVersion: protocolVersion,
            eventID: eventID,
            storeID: storeID,
            globalSequence: globalSequence,
            timestamp: timestamp,
            projectID: projectID,
            sessionID: sessionID,
            agentID: agentID,
            parentAgentID: parentAgentID,
            rootSessionID: rootSessionID,
            runID: runID,
            sessionSequence: sessionSequence,
            eventType: eventType,
            payloadVersion: payloadVersion,
            generation: generation,
            turnEpoch: turnEpoch,
            actor: actor,
            correlationID: correlationID,
            causationID: causationID,
            payload: payload,
            digest: digest,
            keyID: keyID,
            signature: signature
        )
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case eventID = "eventId"
        case storeID = "storeId"
        case globalSequence, cursor, timestamp
        case projectID = "projectId"
        case sessionID = "sessionId"
        case agentID = "agentId"
        case parentAgentID = "parentAgentId"
        case rootSessionID = "rootSessionId"
        case runID = "runId"
        case sessionSequence, eventType, payloadVersion, generation, turnEpoch, actor
        case correlationID = "correlationId"
        case causationID = "causationId"
        case payload, digest
        case keyID = "keyId"
        case signature
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(protocolVersion, forKey: .protocolVersion)
        try values.encode(eventID, forKey: .eventID)
        try values.encode(storeID, forKey: .storeID)
        try values.encode(globalSequence, forKey: .globalSequence)
        try values.encode(cursor, forKey: .cursor)
        try values.encode(timestamp, forKey: .timestamp)
        try values.encode(projectID, forKey: .projectID)
        try values.encodeIfPresent(sessionID, forKey: .sessionID)
        try values.encodeIfPresent(agentID, forKey: .agentID)
        try values.encodeIfPresent(parentAgentID, forKey: .parentAgentID)
        try values.encodeIfPresent(rootSessionID, forKey: .rootSessionID)
        try values.encodeIfPresent(runID, forKey: .runID)
        try values.encodeIfPresent(sessionSequence, forKey: .sessionSequence)
        try values.encode(eventType, forKey: .eventType)
        try values.encode(payloadVersion, forKey: .payloadVersion)
        try values.encodeIfPresent(generation, forKey: .generation)
        try values.encodeIfPresent(turnEpoch, forKey: .turnEpoch)
        try values.encodeIfPresent(actor, forKey: .actor)
        try values.encode(correlationID, forKey: .correlationID)
        try values.encodeIfPresent(causationID, forKey: .causationID)
        try values.encode(payload, forKey: .payload)
        try values.encode(digest, forKey: .digest)
        try values.encode(keyID, forKey: .keyID)
        try values.encode(signature, forKey: .signature)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
        eventID = try values.decode(UUID.self, forKey: .eventID)
        storeID = try values.decode(UUID.self, forKey: .storeID)
        globalSequence = try values.decode(Int64.self, forKey: .globalSequence)
        timestamp = try values.decode(Date.self, forKey: .timestamp)
        projectID = try values.decode(UUID.self, forKey: .projectID)
        sessionID = try values.decodeIfPresent(UUID.self, forKey: .sessionID)
        agentID = try values.decodeIfPresent(UUID.self, forKey: .agentID)
        parentAgentID = try values.decodeIfPresent(UUID.self, forKey: .parentAgentID)
        rootSessionID = try values.decodeIfPresent(UUID.self, forKey: .rootSessionID)
        runID = try values.decodeIfPresent(UUID.self, forKey: .runID)
        sessionSequence = try values.decodeIfPresent(Int64.self, forKey: .sessionSequence)
        eventType = try values.decode(EventType.self, forKey: .eventType)
        payloadVersion = try values.decode(Int.self, forKey: .payloadVersion)
        generation = try values.decodeIfPresent(Int64.self, forKey: .generation)
        turnEpoch = try values.decodeIfPresent(Int64.self, forKey: .turnEpoch)
        actor = try values.decodeIfPresent(ExternalActor.self, forKey: .actor)
        correlationID = try values.decode(UUID.self, forKey: .correlationID)
        causationID = try values.decodeIfPresent(UUID.self, forKey: .causationID)
        payload = try values.decode(EventPayload.self, forKey: .payload)
        digest = try values.decode(String.self, forKey: .digest)
        keyID = try values.decode(String.self, forKey: .keyID)
        signature = try values.decode(String.self, forKey: .signature)
    }
}

public struct EventPage: Codable, Sendable {
    public let storeID: UUID
    public let events: [EventEnvelope]
    public let nextCursor: ServiceCursor
    public let replayFloor: Int64
    public init(storeID: UUID, events: [EventEnvelope], nextCursor: ServiceCursor, replayFloor: Int64) {
        self.storeID = storeID
        self.events = events
        self.nextCursor = nextCursor
        self.replayFloor = replayFloor
    }

    private enum CodingKeys: String, CodingKey {
        case storeID = "storeId"
        case events, nextCursor, replayFloor
    }
}

public struct CursorExpiredResponse: Codable, Sendable {
    public let code: ServiceErrorCode
    public let storeID: UUID
    public let replayFloor: Int64
    public let snapshotURL: String

    public init(storeID: UUID, replayFloor: Int64, snapshotURL: String = "/internal/v1/snapshot") {
        code = .cursorExpired
        self.storeID = storeID
        self.replayFloor = replayFloor
        self.snapshotURL = snapshotURL
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case storeID = "storeId"
        case replayFloor
        case snapshotURL = "snapshotUrl"
    }
}
