import Foundation

package enum FileAction: String, Sendable {
    case modify
    case create
    case delete
    case rewrite
}
