import Foundation

package enum ACPSupportResult: Equatable {
    case supported
    case unsupported(reason: String)

    package var reason: String? {
        switch self {
        case .supported:
            nil
        case let .unsupported(reason):
            reason
        }
    }
}
