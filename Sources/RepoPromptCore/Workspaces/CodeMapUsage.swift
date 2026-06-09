import Foundation

/// Determines how code-map definitions are inserted.
package enum CodeMapUsage: String, CaseIterable, Codable {
    case auto
    case complete
    case selected
    case none
}
