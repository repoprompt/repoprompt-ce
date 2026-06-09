import Foundation

/// Persisted file-selection surface for workspace compose-tab state.
package enum FilesTab: String, Codable {
    case selected = "Selected Files"
    case context = "Context Builder"

    private static let legacyApplyXMLRawValue = "Apply XML"

    package init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        if rawValue == Self.legacyApplyXMLRawValue {
            self = .context
            return
        }
        self = FilesTab(rawValue: rawValue) ?? .context
    }
}
