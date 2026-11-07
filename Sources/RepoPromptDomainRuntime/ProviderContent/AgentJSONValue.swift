import Foundation

package enum AgentJSONValue: Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AgentJSONValue])
    case object([String: AgentJSONValue])

    package func toAny() -> Any {
        switch self {
        case .null:
            NSNull()
        case let .bool(value):
            value
        case let .int(value):
            value
        case let .double(value):
            value
        case let .string(value):
            value
        case let .array(values):
            values.map { $0.toAny() }
        case let .object(values):
            values.reduce(into: [String: Any]()) { partialResult, entry in
                partialResult[entry.key] = entry.value.toAny()
            }
        }
    }
}
