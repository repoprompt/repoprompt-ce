import Foundation

public enum CodexReasoningEffort: Hashable, Codable, Sendable, CaseIterable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra
    case custom(String)

    static let displayOrder: [CodexReasoningEffort] = [
        .none,
        .minimal,
        .low,
        .medium,
        .high,
        .xhigh,
        .max,
        .ultra
    ]

    public static var allCases: [CodexReasoningEffort] {
        displayOrder
    }

    public var rawValue: String {
        switch self {
        case .none: "none"
        case .minimal: "minimal"
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        case .xhigh: "xhigh"
        case .max: "max"
        case .ultra: "ultra"
        case let .custom(value): value
        }
    }

    public init?(rawValue: String) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        switch normalized {
        case "none": self = .none
        case "minimal": self = .minimal
        case "low": self = .low
        case "medium": self = .medium
        case "high": self = .high
        case "xhigh", "x-high": self = .xhigh
        case "max", "maximum": self = .max
        case "ultra": self = .ultra
        default: self = .custom(normalized)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Reasoning effort must not be empty."
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func parse(_ raw: String?) -> CodexReasoningEffort? {
        guard let raw else { return nil }
        return Self(rawValue: raw)
    }

    static func parseKnown(_ raw: String?) -> CodexReasoningEffort? {
        guard let effort = parse(raw), !effort.isCustom else { return nil }
        return effort
    }

    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    static func ordered(_ efforts: some Sequence<CodexReasoningEffort>) -> [CodexReasoningEffort] {
        var unique: [CodexReasoningEffort] = []
        var seen = Set<CodexReasoningEffort>()
        for effort in efforts where seen.insert(effort).inserted {
            unique.append(effort)
        }

        let known = displayOrder.filter { seen.contains($0) }
        let unknown = unique.filter { !displayOrder.contains($0) }
        return known + unknown
    }

    static func rank(_ effort: CodexReasoningEffort?) -> Int {
        guard let effort else { return -1 }
        if let knownRank = displayOrder.firstIndex(of: effort) {
            return knownRank
        }
        return displayOrder.count
    }

    var displayName: String {
        switch self {
        case .none:
            "None"
        case .minimal:
            "Minimal"
        case .low:
            "Low"
        case .medium:
            "Medium"
        case .high:
            "High"
        case .xhigh:
            "XHigh"
        case .max:
            "Max"
        case .ultra:
            "Ultra"
        case let .custom(rawValue):
            Self.humanizedCustomName(rawValue)
        }
    }

    private static func humanizedCustomName(_ rawValue: String) -> String {
        rawValue
            .split { !$0.isLetter && !$0.isNumber }
            .map { token in
                let value = String(token)
                guard let first = value.first else { return value }
                return String(first).uppercased() + value.dropFirst()
            }
            .joined(separator: " ")
    }
}
