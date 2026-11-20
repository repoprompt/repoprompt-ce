import Foundation

/// Canonical model identity for ACP providers whose IDs are case-insensitive.
/// Cursor's configured alias policy remains owned by the settings boundary.
package enum ACPModelIdentityNormalization {
    package static func caseInsensitive(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
