import Foundation

/// Speed capabilities published by the signed-in Codex model catalog.
package struct CodexModelServiceTier: Codable, Hashable {
    let id: String
    let name: String
    let description: String

    package init(id: String, name: String, description: String) {
        self.id = id
        self.name = name
        self.description = description
    }
}

enum CodexModelIdentity {
    static func key(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

package struct CodexDynamicReasoningRecord: Codable, Hashable {
    let reasoningEffort: String
    let description: String

    package init(reasoningEffort: String, description: String) {
        self.reasoningEffort = reasoningEffort
        self.description = description
    }
}

struct CodexDynamicModelRecord: Codable, Hashable {
    let id: String
    let model: String
    let displayName: String
    let description: String
    let isDefault: Bool
    let supportedReasoningEfforts: [CodexDynamicReasoningRecord]
    let defaultReasoningEffort: String?
    let serviceTiers: [CodexModelServiceTier]

    init(
        id: String,
        model: String,
        displayName: String,
        description: String,
        isDefault: Bool,
        supportedReasoningEfforts: [CodexDynamicReasoningRecord] = [],
        defaultReasoningEffort: String? = nil,
        serviceTiers: [CodexModelServiceTier] = []
    ) {
        self.id = id
        self.model = model
        self.displayName = displayName
        self.description = description
        self.isDefault = isDefault
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
        self.serviceTiers = serviceTiers
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case model
        case displayName
        case description
        case isDefault
        case supportedReasoningEfforts
        case defaultReasoningEffort
        case serviceTiers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        model = try container.decode(String.self, forKey: .model)
        displayName = try container.decode(String.self, forKey: .displayName)
        description = try container.decode(String.self, forKey: .description)
        isDefault = try container.decode(Bool.self, forKey: .isDefault)
        supportedReasoningEfforts = try container.decodeIfPresent([CodexDynamicReasoningRecord].self, forKey: .supportedReasoningEfforts) ?? []
        defaultReasoningEffort = try container.decodeIfPresent(String.self, forKey: .defaultReasoningEffort)
        serviceTiers = try container.decodeIfPresent([CodexModelServiceTier].self, forKey: .serviceTiers) ?? []
    }
}

struct CodexDynamicModelOption: Hashable {
    let id: String
    let displayName: String
    let description: String
    let isDefault: Bool
    let baseID: String
    let reasoningEffort: CodexReasoningEffort?
    let supportedReasoningEffortRawValues: [String]
    let defaultReasoningEffortRawValue: String?
    let defaultReasoningEffort: CodexReasoningEffort?

    init(
        id: String,
        displayName: String,
        description: String,
        isDefault: Bool,
        baseID: String,
        reasoningEffort: CodexReasoningEffort?,
        supportedReasoningEffortRawValues: [String] = [],
        defaultReasoningEffortRawValue: String? = nil,
        defaultReasoningEffort: CodexReasoningEffort? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.isDefault = isDefault
        self.baseID = baseID
        self.reasoningEffort = reasoningEffort
        self.supportedReasoningEffortRawValues = supportedReasoningEffortRawValues
        self.defaultReasoningEffortRawValue = defaultReasoningEffortRawValue
        self.defaultReasoningEffort = defaultReasoningEffort
    }
}
