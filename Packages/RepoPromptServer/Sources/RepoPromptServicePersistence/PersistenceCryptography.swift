import Crypto
import Foundation
import RepoPromptRuntimeModel

public struct PersistenceEventSigningKey: Sendable {
    public let keyID: String
    public let secret: Data

    public init(keyID: String, secret: Data) {
        self.keyID = keyID
        self.secret = secret
    }
}

enum PersistenceCryptography {
    static func bodyDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hmacSHA256(message: String, key: Data) -> String {
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: key)
        )
        return Data(code).map { String(format: "%02x", $0) }.joined()
    }
}

private struct PersistenceUnsignedEventEnvelope: Encodable {
    let event: EventEnvelope

    init(_ event: EventEnvelope) {
        self.event = event
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
        case payload
        case keyID = "keyId"
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(event.protocolVersion, forKey: .protocolVersion)
        try values.encode(event.eventID, forKey: .eventID)
        try values.encode(event.storeID, forKey: .storeID)
        try values.encode(event.globalSequence, forKey: .globalSequence)
        try values.encode(event.cursor, forKey: .cursor)
        try values.encode(event.timestamp, forKey: .timestamp)
        try values.encode(event.projectID, forKey: .projectID)
        try values.encodeIfPresent(event.sessionID, forKey: .sessionID)
        try values.encodeIfPresent(event.agentID, forKey: .agentID)
        try values.encodeIfPresent(event.parentAgentID, forKey: .parentAgentID)
        try values.encodeIfPresent(event.rootSessionID, forKey: .rootSessionID)
        try values.encodeIfPresent(event.runID, forKey: .runID)
        try values.encodeIfPresent(event.sessionSequence, forKey: .sessionSequence)
        try values.encode(event.eventType, forKey: .eventType)
        try values.encode(event.payloadVersion, forKey: .payloadVersion)
        try values.encodeIfPresent(event.generation, forKey: .generation)
        try values.encodeIfPresent(event.turnEpoch, forKey: .turnEpoch)
        try values.encodeIfPresent(event.actor, forKey: .actor)
        try values.encode(event.correlationID, forKey: .correlationID)
        try values.encodeIfPresent(event.causationID, forKey: .causationID)
        try values.encode(event.payload, forKey: .payload)
        try values.encode(event.keyID, forKey: .keyID)
    }
}

extension EventEnvelope {
    func persistenceSigningData() throws -> Data {
        try JSONEncoder.serviceEncoder.encode(PersistenceUnsignedEventEnvelope(self))
    }
}
