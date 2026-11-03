import Foundation

/// JSON structure for application/DSPy datasets whose fields are opaque to RPCE.
enum PromptExperimentExampleValue: Codable, Equatable {
    case null, boolean(Bool), number(Double), string(String), array([Self]), object([String: Self])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let boolean = try? value.decode(Bool.self) { self = .boolean(boolean) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let text = try? value.decode(String.self) { self = .string(text) }
        else if let array = try? value.decode([Self].self) { self = .array(array) }
        else { self = try .object(value.decode([String: Self].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case let .boolean(boolean): try value.encode(boolean)
        case let .number(number): try value.encode(number)
        case let .string(text): try value.encode(text)
        case let .array(array): try value.encode(array)
        case let .object(object): try value.encode(object)
        }
    }

    var foundationValue: Any {
        switch self {
        case .null: NSNull()
        case let .boolean(value): value
        case let .number(value): value
        case let .string(value): value
        case let .array(value): value.map(\.foundationValue)
        case let .object(value): value.mapValues(\.foundationValue)
        }
    }
}
