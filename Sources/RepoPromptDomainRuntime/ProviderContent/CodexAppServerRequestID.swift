import Foundation

package enum CodexAppServerRequestID: Hashable {
    case int(Int)
    case string(String)

    package init?(raw: Any) {
        if let value = raw as? Int {
            self = .int(value)
            return
        }
        if let value = raw as? NSNumber {
            self = .int(value.intValue)
            return
        }
        if let value = raw as? String {
            self = .string(value)
            return
        }
        return nil
    }

    package var jsonValue: Any {
        switch self {
        case let .int(value): value
        case let .string(value): value
        }
    }

    package var displayValue: String {
        switch self {
        case let .int(value): String(value)
        case let .string(value): value
        }
    }
}
