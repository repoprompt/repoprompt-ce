import Foundation
import MCP

package enum OracleGroupContractError: Error, LocalizedError, Equatable {
    case invalidLaneIndex(Int)
    case invalidModelIdentifier
    case modelIdentifierTooLong(Int)
    case invalidProviderIdentifier
    case invalidRosterCount(Int)
    case invalidGroupSize(Int)
    case invalidConversationOwner
    case invalidPublicChatID
    case modelOverrideOnContinuation
    case invalidLaneResult(Int)
    case invalidExecutionProfile
    case invalidGroupResult
    case invalidTerminalPublicationIntent
    case invalidFrozenPackReference
    case invalidFrozenPack
    case invalidUserMessage

    package var errorDescription: String? {
        switch self {
        case let .invalidLaneIndex(index):
            "Oracle lane index must be non-negative; received \(index)."
        case .invalidModelIdentifier:
            "Oracle model identifiers must be non-empty after trimming."
        case let .modelIdentifierTooLong(maximum):
            "Oracle model identifiers must not exceed \(maximum) characters."
        case .invalidProviderIdentifier:
            "Oracle provider identifiers must be non-empty when supplied."
        case let .invalidRosterCount(count):
            "Oracle rosters require 1...5 models; received \(count)."
        case let .invalidGroupSize(size):
            "Oracle groups require 2...5 lanes; received \(size)."
        case .invalidConversationOwner:
            "Oracle conversation owners require non-empty kind and identifier values."
        case .invalidPublicChatID:
            "Oracle public chat identifiers must be non-empty."
        case .modelOverrideOnContinuation:
            "Oracle model overrides are valid only when starting a new conversation."
        case let .invalidLaneResult(index):
            "Oracle lane \(index) has an invalid role, status, or payload."
        case .invalidExecutionProfile:
            "Oracle execution profiles require non-empty provider and model identifiers and a non-empty effort when supplied."
        case .invalidGroupResult:
            "Oracle group results require one ordered outcome for every declared lane."
        case .invalidTerminalPublicationIntent:
            "Oracle terminal publication intents require one exact, structurally valid terminal transition."
        case .invalidFrozenPackReference:
            "Oracle frozen-pack references must use oracle-pack:sha256:<64 lowercase hexadecimal characters>."
        case .invalidFrozenPack:
            "Oracle frozen context packs must use the current canonical schema and contain non-empty content."
        case .invalidUserMessage:
            "Oracle messages must be non-empty after trimming."
        }
    }
}

/// Product limits and canonical settings keys. Lane identity itself remains unbounded.
package enum OracleRosterContract {
    package static let minimumCount = 1
    package static let maximumCount = 5
    package static let maximumAdditionalCount = maximumCount - minimumCount
    package static let maximumModelIdentifierLength = 512
    package static let primarySettingKey = "models.planning_model"
    package static let additionalSettingKey = "models.additional_oracle_models"

    package static func normalizedModelID(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw OracleGroupContractError.invalidModelIdentifier }
        guard value.count <= maximumModelIdentifierLength else {
            throw OracleGroupContractError.modelIdentifierTooLong(maximumModelIdentifierLength)
        }
        return value
    }

    package static func normalizedAdditionalModelIDs(_ raws: [String]) throws -> [String] {
        guard raws.count <= maximumAdditionalCount else {
            throw OracleGroupContractError.invalidRosterCount(raws.count + 1)
        }
        return try raws.map(normalizedModelID)
    }

    package static func sanitizedAdditionalModelIDs(_ raws: [String]) -> [String] {
        Array(raws.compactMap { try? normalizedModelID($0) }.prefix(maximumAdditionalCount))
    }

    /// User-facing lane title. Index 0 is "Oracle"; later lanes are "Oracle 2"…"Oracle 5".
    package static func displayLabel(laneIndex: Int) -> String {
        laneIndex <= 0 ? "Oracle" : "Oracle \(laneIndex + 1)"
    }
}

/// Canonical settings descriptors consumed by both app-backed and direct adapters.
package enum OracleRosterSettingsDescriptor {
    package static let primary = DomainSettingDescriptor(
        key: OracleRosterContract.primarySettingKey,
        group: "models",
        valueKind: .string,
        defaultValue: .null,
        description: "Primary Oracle model identifier, if set.",
        optionsAvailable: true,
        allowsNull: true,
        maximumStringLength: OracleRosterContract.maximumModelIdentifierLength
    )

    package static let additional = DomainSettingDescriptor(
        key: OracleRosterContract.additionalSettingKey,
        group: "models",
        valueKind: .stringArray,
        defaultValue: .stringArray([]),
        description: "Ordered list of up to four additional Oracle model identifiers. Grouped requests run each model independently, preserve duplicates, and return results in roster order.",
        optionsAvailable: true,
        allowsNull: false,
        maximumArrayCount: OracleRosterContract.maximumAdditionalCount,
        maximumStringLength: OracleRosterContract.maximumModelIdentifierLength
    )
}

package struct OracleLaneID: Hashable, Codable, Comparable {
    package let index: Int

    package init(index: Int) throws {
        guard index >= 0 else { throw OracleGroupContractError.invalidLaneIndex(index) }
        self.index = index
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(index: container.decode(Int.self, forKey: .index))
    }

    package static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.index < rhs.index
    }
}

package struct OracleModelReference: Hashable, Codable {
    package let providerID: String?
    package let modelID: String

    package init(providerID: String? = nil, modelID: String) throws {
        if let providerID {
            let normalized = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { throw OracleGroupContractError.invalidProviderIdentifier }
            self.providerID = normalized
        } else {
            self.providerID = nil
        }
        self.modelID = try OracleRosterContract.normalizedModelID(modelID)
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            providerID: container.decodeIfPresent(String.self, forKey: .providerID),
            modelID: container.decode(String.self, forKey: .modelID)
        )
    }
}

package struct OracleRoster: Codable, Equatable {
    package let primary: OracleModelReference
    package let additional: [OracleModelReference]

    package init(primary: OracleModelReference, additional: [OracleModelReference] = []) throws {
        let count = 1 + additional.count
        guard (OracleRosterContract.minimumCount ... OracleRosterContract.maximumCount).contains(count) else {
            throw OracleGroupContractError.invalidRosterCount(count)
        }
        self.primary = primary
        self.additional = additional
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            primary: container.decode(OracleModelReference.self, forKey: .primary),
            additional: container.decode([OracleModelReference].self, forKey: .additional)
        )
    }

    package init(
        primaryModelID: String,
        additionalModelIDs: [String] = [],
        providerID: String? = nil
    ) throws {
        let additional = try OracleRosterContract.normalizedAdditionalModelIDs(additionalModelIDs)
            .map { try OracleModelReference(providerID: providerID, modelID: $0) }
        try self.init(
            primary: OracleModelReference(providerID: providerID, modelID: primaryModelID),
            additional: additional
        )
    }

    package var orderedModels: [OracleModelReference] {
        [primary] + additional
    }

    package var count: Int {
        orderedModels.count
    }
}

package struct OracleGroupID: Hashable, Codable {
    package let rawValue: UUID
    package init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    package init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

package struct OracleMemberID: Hashable, Codable {
    package let rawValue: UUID
    package init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    package init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

package struct OracleTurnID: Hashable, Codable {
    package let rawValue: UUID
    package init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    package init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

package struct OracleConversationOwner: Hashable, Codable {
    package let kind: String
    package let identifier: String

    package init(kind: String, identifier: String) throws {
        let kind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kind.isEmpty, !identifier.isEmpty else {
            throw OracleGroupContractError.invalidConversationOwner
        }
        self.kind = kind
        self.identifier = identifier
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(String.self, forKey: .kind),
            identifier: container.decode(String.self, forKey: .identifier)
        )
    }
}

package struct OracleGroupDescriptor: Hashable, Codable {
    package let id: OracleGroupID
    package let size: Int

    package init(id: OracleGroupID = OracleGroupID(), size: Int) throws {
        guard (2 ... OracleRosterContract.maximumCount).contains(size) else {
            throw OracleGroupContractError.invalidGroupSize(size)
        }
        self.id = id
        self.size = size
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(OracleGroupID.self, forKey: .id),
            size: container.decode(Int.self, forKey: .size)
        )
    }
}

package struct OracleLaneDescriptor: Hashable, Codable {
    package let group: OracleGroupDescriptor
    package let laneID: OracleLaneID
    package let model: OracleModelReference

    package init(group: OracleGroupDescriptor, laneID: OracleLaneID, model: OracleModelReference) throws {
        guard laneID.index < group.size else { throw OracleGroupContractError.invalidLaneIndex(laneID.index) }
        self.group = group
        self.laneID = laneID
        self.model = model
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            group: container.decode(OracleGroupDescriptor.self, forKey: .group),
            laneID: container.decode(OracleLaneID.self, forKey: .laneID),
            model: container.decode(OracleModelReference.self, forKey: .model)
        )
    }
}

package enum OracleMode: String, Codable {
    case chat
    case plan
    case review
}

package enum OracleContentReference: Codable, Equatable {
    case inline(String)
    case durableArtifact(id: String)
}

package struct OracleEvidenceReference: Codable, Equatable {
    package let path: String

    package init(path: String) {
        self.path = path
    }
}

package struct OracleContextEnvelope: Codable, Equatable {
    package let content: OracleContentReference
    package let sha256: String
    package let provenance: [OracleEvidenceReference]

    package init(
        content: OracleContentReference,
        sha256: String,
        provenance: [OracleEvidenceReference] = []
    ) {
        self.content = content
        self.sha256 = sha256
        self.provenance = provenance
    }
}

package struct OracleFrozenPackReference: Codable, Equatable, Hashable {
    package static let prefix = "oracle-pack:sha256:"

    package let artifactID: String

    package init(artifactID: String) throws {
        guard artifactID.count == 64,
              artifactID.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) })
        else {
            throw OracleGroupContractError.invalidFrozenPackReference
        }
        self.artifactID = artifactID
    }

    package init(rawValue: String) throws {
        guard rawValue.hasPrefix(Self.prefix) else {
            throw OracleGroupContractError.invalidFrozenPackReference
        }
        try self.init(artifactID: String(rawValue.dropFirst(Self.prefix.count)))
    }

    package var rawValue: String {
        Self.prefix + artifactID
    }

    package init(from decoder: Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Versioned provider-neutral Context Builder output consumed by app and direct group adapters.
/// The encoded bytes are canonical only when produced by `canonicalData()`.
package struct OracleFrozenContextPack: Codable, Equatable {
    package static let currentSchemaVersion = 1

    package let schemaVersion: Int
    package let mode: OracleMode
    package let content: String
    package let provenance: [OracleEvidenceReference]

    package init(
        schemaVersion: Int = Self.currentSchemaVersion,
        mode: OracleMode,
        content: String,
        provenance: [OracleEvidenceReference] = []
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw OracleGroupContractError.invalidFrozenPack
        }
        self.schemaVersion = schemaVersion
        self.mode = mode
        self.content = content
        self.provenance = provenance
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            mode: container.decode(OracleMode.self, forKey: .mode),
            content: container.decode(String.self, forKey: .content),
            provenance: container.decode([OracleEvidenceReference].self, forKey: .provenance)
        )
    }

    package func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    package static func decodeCanonical(_ data: Data) throws -> Self {
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        guard try decoded.canonicalData() == data else {
            throw OracleGroupContractError.invalidFrozenPack
        }
        return decoded
    }
}

package struct OracleInput: Codable, Equatable {
    package let mode: OracleMode
    package let userMessage: String
    package let context: OracleContextEnvelope?

    package init(mode: OracleMode, userMessage: String, context: OracleContextEnvelope? = nil) throws {
        let message = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw OracleGroupContractError.invalidUserMessage }
        self.mode = mode
        self.userMessage = message
        self.context = context
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            mode: container.decode(OracleMode.self, forKey: .mode),
            userMessage: container.decode(String.self, forKey: .userMessage),
            context: container.decodeIfPresent(OracleContextEnvelope.self, forKey: .context)
        )
    }
}

package enum OracleLaneRole: String, Codable {
    case primary
    case additional
}

package enum OracleLaneResultStatus: String, Codable {
    case completed
    case failed
    case cancelled
}

package struct OracleLaneError: Codable, Equatable {
    package let code: String
    package let message: String
    package let partialResponse: String?

    package init(code: String, message: String, partialResponse: String? = nil) {
        self.code = code
        self.message = message
        self.partialResponse = partialResponse
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case partialResponse = "partial_response"
    }
}

package struct OracleExecutionProfile: Codable, Equatable {
    package let providerID: String
    package let modelID: String
    package let effectiveReasoningEffort: String?

    package init(
        providerID: String,
        modelID: String,
        effectiveReasoningEffort: String? = nil
    ) throws {
        let providerID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let effort = effectiveReasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerID.isEmpty,
              (try? OracleRosterContract.normalizedModelID(modelID)) != nil,
              effort.map({ !$0.isEmpty }) ?? true
        else {
            throw OracleGroupContractError.invalidExecutionProfile
        }
        self.providerID = providerID
        self.modelID = modelID
        self.effectiveReasoningEffort = effort
    }

    private enum CodingKeys: String, CodingKey {
        case providerID = "provider_id"
        case modelID = "model_id"
        case effectiveReasoningEffort = "effective_reasoning_effort"
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            providerID: container.decode(String.self, forKey: .providerID),
            modelID: container.decode(String.self, forKey: .modelID),
            effectiveReasoningEffort: container.decodeIfPresent(String.self, forKey: .effectiveReasoningEffort)
        )
    }
}

package struct OracleLaneResult: Codable, Equatable {
    package let laneIndex: Int
    package let role: OracleLaneRole
    package let chatID: String
    package let providerID: String?
    package let modelID: String
    package let status: OracleLaneResultStatus
    package let executionProfile: OracleExecutionProfile?
    package let response: String?
    package let error: OracleLaneError?

    package init(
        laneIndex: Int,
        chatID: String,
        providerID: String?,
        modelID: String,
        status: OracleLaneResultStatus,
        executionProfile: OracleExecutionProfile? = nil,
        response: String? = nil,
        error: OracleLaneError? = nil
    ) throws {
        let role: OracleLaneRole = laneIndex == 0 ? .primary : .additional
        try Self.validate(
            laneIndex: laneIndex,
            role: role,
            chatID: chatID,
            providerID: providerID,
            modelID: modelID,
            status: status,
            response: response,
            error: error
        )
        self.laneIndex = laneIndex
        self.role = role
        self.chatID = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.providerID = providerID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelID = try OracleRosterContract.normalizedModelID(modelID)
        self.status = status
        self.executionProfile = executionProfile
        self.response = response
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case laneIndex = "lane_index"
        case role
        case chatID = "chat_id"
        case providerID = "provider_id"
        case modelID = "model_id"
        case status
        case executionProfile = "execution_profile"
        case response
        case error
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let laneIndex = try container.decode(Int.self, forKey: .laneIndex)
        let role = try container.decode(OracleLaneRole.self, forKey: .role)
        let chatID = try container.decode(String.self, forKey: .chatID)
        let providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
        let modelID = try container.decode(String.self, forKey: .modelID)
        let status = try container.decode(OracleLaneResultStatus.self, forKey: .status)
        let executionProfile = try container.decodeIfPresent(OracleExecutionProfile.self, forKey: .executionProfile)
        let response = try container.decodeIfPresent(String.self, forKey: .response)
        let error = try container.decodeIfPresent(OracleLaneError.self, forKey: .error)
        try Self.validate(
            laneIndex: laneIndex,
            role: role,
            chatID: chatID,
            providerID: providerID,
            modelID: modelID,
            status: status,
            response: response,
            error: error
        )
        self.laneIndex = laneIndex
        self.role = role
        self.chatID = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.providerID = providerID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelID = try OracleRosterContract.normalizedModelID(modelID)
        self.status = status
        self.executionProfile = executionProfile
        self.response = response
        self.error = error
    }

    private static func validate(
        laneIndex: Int,
        role: OracleLaneRole,
        chatID: String,
        providerID: String?,
        modelID: String,
        status: OracleLaneResultStatus,
        response: String?,
        error: OracleLaneError?
    ) throws {
        guard laneIndex >= 0,
              role == (laneIndex == 0 ? .primary : .additional),
              !chatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              providerID.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true,
              (try? OracleRosterContract.normalizedModelID(modelID)) != nil
        else {
            throw OracleGroupContractError.invalidLaneResult(laneIndex)
        }
        switch status {
        case .completed:
            guard let response,
                  !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  error == nil
            else {
                throw OracleGroupContractError.invalidLaneResult(laneIndex)
            }
        case .failed, .cancelled:
            guard response == nil,
                  let error,
                  !error.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !error.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw OracleGroupContractError.invalidLaneResult(laneIndex)
            }
        }
    }
}

package enum OracleGroupStatus: String, Codable {
    case completed
    case partialFailure = "partial_failure"
    case failed
}

package struct OracleGroupWarning: Codable, Equatable {
    package let code: String
    package let message: String

    package init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// Canonical ordered N>1 result. App and direct adapters append their existing Primary projection.
package struct OracleGroupResult: Codable, Equatable {
    package let groupID: OracleGroupID
    package let status: OracleGroupStatus
    package let oracleResults: [OracleLaneResult]
    package let warnings: [OracleGroupWarning]

    package init(
        groupID: OracleGroupID,
        status: OracleGroupStatus,
        oracleResults: [OracleLaneResult],
        warnings: [OracleGroupWarning] = []
    ) throws {
        try Self.validate(status: status, results: oracleResults, warnings: warnings)
        self.groupID = groupID
        self.status = status
        self.oracleResults = oracleResults
        self.warnings = warnings
    }

    package var oracleCount: Int {
        oracleResults.count
    }

    package var primary: OracleLaneResult {
        oracleResults[0]
    }

    private enum CodingKeys: String, CodingKey {
        case groupID = "oracle_group_id"
        case status
        case oracleCount = "oracle_count"
        case oracleResults = "oracle_results"
        case warnings
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let groupID = try container.decode(OracleGroupID.self, forKey: .groupID)
        let status = try container.decode(OracleGroupStatus.self, forKey: .status)
        let declaredCount = try container.decode(Int.self, forKey: .oracleCount)
        let results = try container.decode([OracleLaneResult].self, forKey: .oracleResults)
        let warnings = try container.decodeIfPresent([OracleGroupWarning].self, forKey: .warnings) ?? []
        guard declaredCount == results.count else { throw OracleGroupContractError.invalidGroupResult }
        try Self.validate(status: status, results: results, warnings: warnings)
        self.groupID = groupID
        self.status = status
        oracleResults = results
        self.warnings = warnings
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(groupID, forKey: .groupID)
        try container.encode(status, forKey: .status)
        try container.encode(oracleCount, forKey: .oracleCount)
        try container.encode(oracleResults, forKey: .oracleResults)
        if !warnings.isEmpty { try container.encode(warnings, forKey: .warnings) }
    }

    private static func validate(
        status: OracleGroupStatus,
        results: [OracleLaneResult],
        warnings: [OracleGroupWarning]
    ) throws {
        guard (2 ... OracleRosterContract.maximumCount).contains(results.count),
              results.map(\.laneIndex) == Array(results.indices)
        else {
            throw OracleGroupContractError.invalidGroupResult
        }
        let primaryCompleted = results[0].status == .completed
        let allCompleted = results.allSatisfy { $0.status == .completed }
        let validStatus = switch status {
        case .completed:
            allCompleted && warnings.isEmpty
        case .partialFailure:
            primaryCompleted && (!allCompleted || !warnings.isEmpty)
        case .failed:
            !primaryCompleted
        }
        guard validStatus else { throw OracleGroupContractError.invalidGroupResult }
    }
}

/// Canonical MCP fields shared by app, Context Builder, and direct-headless adapters.
package enum OracleGroupMCPCodec {
    package static func groupFields(_ result: OracleGroupResult) -> [String: Value] {
        var fields: [String: Value] = [
            "oracle_group_id": .string(result.groupID.rawValue.uuidString),
            "status": .string(result.status.rawValue),
            "oracle_count": .int(result.oracleCount),
            "oracle_results": .array(result.oracleResults.map(laneValue))
        ]
        if !result.warnings.isEmpty {
            fields["warnings"] = .array(result.warnings.map {
                .object(["code": .string($0.code), "message": .string($0.message)])
            })
        }
        return fields
    }

    package static func laneValue(_ result: OracleLaneResult) -> Value {
        var fields: [String: Value] = [
            "lane_index": .int(result.laneIndex),
            "role": .string(result.role.rawValue),
            "chat_id": .string(result.chatID),
            "model_id": .string(result.modelID),
            "status": .string(result.status.rawValue)
        ]
        if let providerID = result.providerID { fields["provider_id"] = .string(providerID) }
        if let profile = result.executionProfile {
            var profileFields: [String: Value] = [
                "provider_id": .string(profile.providerID),
                "model_id": .string(profile.modelID)
            ]
            if let effort = profile.effectiveReasoningEffort {
                profileFields["effective_reasoning_effort"] = .string(effort)
            }
            fields["execution_profile"] = .object(profileFields)
        }
        if let response = result.response { fields["response"] = .string(response) }
        if let error = result.error {
            var errorFields: [String: Value] = [
                "code": .string(error.code),
                "message": .string(error.message)
            ]
            if let partialResponse = error.partialResponse {
                errorFields["partial_response"] = .string(partialResponse)
            }
            fields["error"] = .object(errorFields)
        }
        return .object(fields)
    }
}

package enum OracleProgressKind: String, Codable {
    case groupPrepared = "group_prepared"
    case laneStarted = "lane_started"
    case laneDelta = "lane_delta"
    case laneSettled = "lane_settled"
    case groupSettled = "group_settled"
}

package struct OracleProgressEvent: Codable, Equatable {
    package let kind: OracleProgressKind
    package let groupID: OracleGroupID
    package let turnID: OracleTurnID
    package let laneID: OracleLaneID?
    package let sequence: UInt64?
    package let text: String?

    package init(
        kind: OracleProgressKind,
        groupID: OracleGroupID,
        turnID: OracleTurnID,
        laneID: OracleLaneID? = nil,
        sequence: UInt64? = nil,
        text: String? = nil
    ) {
        self.kind = kind
        self.groupID = groupID
        self.turnID = turnID
        self.laneID = laneID
        self.sequence = sequence
        self.text = text
    }
}

package struct OracleGroupMember: Codable, Equatable {
    package let laneID: OracleLaneID
    package let memberID: OracleMemberID
    package let publicChatID: String
    package let model: OracleModelReference
    package let providerConversationID: String?

    package init(
        laneID: OracleLaneID,
        memberID: OracleMemberID = OracleMemberID(),
        publicChatID: String,
        model: OracleModelReference,
        providerConversationID: String? = nil
    ) throws {
        let publicChatID = publicChatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !publicChatID.isEmpty else { throw OracleGroupContractError.invalidPublicChatID }
        self.laneID = laneID
        self.memberID = memberID
        self.publicChatID = publicChatID
        self.model = model
        self.providerConversationID = providerConversationID
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            laneID: container.decode(OracleLaneID.self, forKey: .laneID),
            memberID: container.decode(OracleMemberID.self, forKey: .memberID),
            publicChatID: container.decode(String.self, forKey: .publicChatID),
            model: container.decode(OracleModelReference.self, forKey: .model),
            providerConversationID: container.decodeIfPresent(String.self, forKey: .providerConversationID)
        )
    }
}

package enum OracleTurnState: String, Codable {
    case prepared
    case terminal
}

package struct OracleTurnRecord: Codable, Equatable {
    package let id: OracleTurnID
    package let input: OracleInput
    package let state: OracleTurnState
    package let startedAt: Date
    package let finishedAt: Date?
    package let status: OracleGroupStatus?
    package let warnings: [OracleGroupWarning]
    package let results: [OracleLaneResult]

    package init(
        id: OracleTurnID = OracleTurnID(),
        input: OracleInput,
        state: OracleTurnState,
        startedAt: Date,
        finishedAt: Date? = nil,
        status: OracleGroupStatus? = nil,
        warnings: [OracleGroupWarning] = [],
        results: [OracleLaneResult] = []
    ) {
        self.id = id
        self.input = input
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.warnings = warnings
        self.results = results
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case input
        case state
        case startedAt
        case finishedAt
        case status
        case warnings
        case results
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(OracleTurnID.self, forKey: .id),
            input: try container.decode(OracleInput.self, forKey: .input),
            state: try container.decode(OracleTurnState.self, forKey: .state),
            startedAt: try container.decode(Date.self, forKey: .startedAt),
            finishedAt: try container.decodeIfPresent(Date.self, forKey: .finishedAt),
            status: try container.decodeIfPresent(OracleGroupStatus.self, forKey: .status),
            warnings: try container.decodeIfPresent([OracleGroupWarning].self, forKey: .warnings) ?? [],
            results: try container.decode([OracleLaneResult].self, forKey: .results)
        )
    }
}

package struct OracleGroupDocument: Codable, Equatable {
    package static let currentSchemaVersion = 2

    package let schemaVersion: Int
    package let group: OracleGroupDescriptor
    package let owner: OracleConversationOwner
    package let name: String
    package let revision: UInt64
    package let createdAt: Date
    package let updatedAt: Date
    package let roster: OracleRoster
    package let members: [OracleGroupMember]
    package let turns: [OracleTurnRecord]

    package init(
        schemaVersion: Int = Self.currentSchemaVersion,
        group: OracleGroupDescriptor,
        owner: OracleConversationOwner,
        name: String,
        revision: UInt64,
        createdAt: Date,
        updatedAt: Date,
        roster: OracleRoster,
        members: [OracleGroupMember],
        turns: [OracleTurnRecord] = []
    ) throws {
        guard group.size == roster.count,
              members.count == group.size,
              members.map(\.laneID.index) == Array(members.indices),
              Set(turns.map(\.id)).count == turns.count
        else {
            throw OracleGroupContractError.invalidGroupResult
        }
        self.schemaVersion = schemaVersion
        self.group = group
        self.owner = owner
        self.name = name
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.roster = roster
        self.members = members
        self.turns = turns
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case group
        case owner
        case name
        case revision
        case createdAt
        case updatedAt
        case roster
        case members
        case turns
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            group: container.decode(OracleGroupDescriptor.self, forKey: .group),
            owner: container.decode(OracleConversationOwner.self, forKey: .owner),
            name: container.decode(String.self, forKey: .name),
            revision: container.decode(UInt64.self, forKey: .revision),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            updatedAt: container.decode(Date.self, forKey: .updatedAt),
            roster: container.decode(OracleRoster.self, forKey: .roster),
            members: container.decode([OracleGroupMember].self, forKey: .members),
            turns: container.decodeIfPresent([OracleTurnRecord].self, forKey: .turns) ?? []
        )
    }
}

package struct OracleMemberLookup: Codable, Equatable {
    package let publicChatID: String

    package init(publicChatID: String) throws {
        let value = publicChatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw OracleGroupContractError.invalidPublicChatID }
        self.publicChatID = value
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(publicChatID: container.decode(String.self, forKey: .publicChatID))
    }
}

package extension OracleGroupDocument {
    func settling(_ result: OracleGroupResult, finishedAt: Date = Date()) throws -> Self {
        guard result.groupID == group.id,
              let turn = turns.last,
              turn.state == .prepared
        else {
            throw OracleGroupContractError.invalidGroupResult
        }
        let terminalTurn = OracleTurnRecord(
            id: turn.id,
            input: turn.input,
            state: .terminal,
            startedAt: turn.startedAt,
            finishedAt: finishedAt,
            status: result.status,
            warnings: result.warnings,
            results: result.oracleResults
        )
        return try Self(
            schemaVersion: schemaVersion,
            group: group,
            owner: owner,
            name: name,
            revision: revision &+ 1,
            createdAt: createdAt,
            updatedAt: finishedAt,
            roster: roster,
            members: members,
            turns: Array(turns.dropLast()) + [terminalTurn]
        )
    }

    func settlingInterrupted(
        status: OracleLaneResultStatus,
        code: String,
        message: String,
        finishedAt: Date = Date()
    ) throws -> Self {
        let results = try members.map { member in
            try OracleLaneResult(
                laneIndex: member.laneID.index,
                chatID: member.publicChatID,
                providerID: member.model.providerID,
                modelID: member.model.modelID,
                status: status,
                error: OracleLaneError(code: code, message: message)
            )
        }
        return try settling(
            OracleGroupResult(groupID: group.id, status: .failed, oracleResults: results),
            finishedAt: finishedAt
        )
    }
}

package struct OracleTerminalPublicationIntent: Equatable {
    package let terminal: OracleGroupDocument
    package let expectedRevision: UInt64

    package init(terminal: OracleGroupDocument, expectedRevision: UInt64) throws {
        guard expectedRevision < UInt64.max,
              terminal.schemaVersion == OracleGroupDocument.currentSchemaVersion,
              terminal.revision == expectedRevision + 1,
              let finalTurn = terminal.turns.last,
              finalTurn.state == .terminal,
              finalTurn.finishedAt != nil,
              let status = finalTurn.status
        else {
            throw OracleGroupContractError.invalidTerminalPublicationIntent
        }
        do {
            _ = try OracleGroupResult(
                groupID: terminal.group.id,
                status: status,
                oracleResults: finalTurn.results,
                warnings: finalTurn.warnings
            )
        } catch {
            throw OracleGroupContractError.invalidTerminalPublicationIntent
        }
        self.terminal = terminal
        self.expectedRevision = expectedRevision
    }
}

package protocol OracleGroupStore: Sendable {
    func create(_ group: OracleGroupDocument) async throws
    func load(member: OracleMemberLookup, owner: OracleConversationOwner) async throws -> OracleGroupDocument?
    func load(groupID: OracleGroupID, owner: OracleConversationOwner) async throws -> OracleGroupDocument?
    func save(_ group: OracleGroupDocument, expectedRevision: UInt64) async throws
    func stageTerminalPublication(_ intent: OracleTerminalPublicationIntent) async throws
    func reconcileTerminalPublication(
        _ intent: OracleTerminalPublicationIntent
    ) async throws -> OracleGroupDocument
    func rename(groupID: OracleGroupID, owner: OracleConversationOwner, name: String, expectedRevision: UInt64) async throws
    func delete(groupID: OracleGroupID, owner: OracleConversationOwner, expectedRevision: UInt64) async throws
    func retainMostRecentGroups(_ maximumCount: Int, owner: OracleConversationOwner) async throws -> [OracleGroupID]
    func recoverPreparedGroups(owner: OracleConversationOwner) async throws -> [OracleGroupDocument]
}

package protocol OracleArtifactStore: Sendable {
    func storeArtifact(_ data: Data) async throws -> String
    func loadArtifact(id: String) async throws -> Data
}

package enum OracleMissingConversationBehavior {
    case startNew
    case continueCurrent
}

package enum OracleConversationRoute: Equatable {
    case start(primaryModelOverride: String?)
    case continuation(chatID: String)
    case implicitContinuation

    package static func resolve(
        chatID: String?,
        newChat: Bool,
        modelOverride: String?,
        whenMissingChatID: OracleMissingConversationBehavior
    ) throws -> Self {
        let chatID = chatID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if chatID?.isEmpty == true { throw OracleGroupContractError.invalidPublicChatID }
        let modelOverride = try modelOverride.map(OracleRosterContract.normalizedModelID)
        if newChat { return .start(primaryModelOverride: modelOverride) }
        if let chatID {
            guard modelOverride == nil else {
                throw OracleGroupContractError.modelOverrideOnContinuation
            }
            return .continuation(chatID: chatID)
        }
        switch whenMissingChatID {
        case .startNew:
            return .start(primaryModelOverride: modelOverride)
        case .continueCurrent:
            guard modelOverride == nil else {
                throw OracleGroupContractError.modelOverrideOnContinuation
            }
            return .implicitContinuation
        }
    }
}

package struct OracleRosterResolutionRequest: Codable, Equatable {
    package let primaryModelOverride: String?
    package let newChat: Bool

    package init(primaryModelOverride: String? = nil, newChat: Bool) {
        self.primaryModelOverride = primaryModelOverride
        self.newChat = newChat
    }
}

package protocol OracleRosterResolver: Sendable {
    func resolveRoster(for request: OracleRosterResolutionRequest) async throws -> OracleRoster
}
