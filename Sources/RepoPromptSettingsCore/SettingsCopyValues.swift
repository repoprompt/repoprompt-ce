import Foundation

// Persisted option values only; their UI/runtime consumers remain app-owned.

package enum FileTreeOption: String, CaseIterable, Identifiable, Codable {
    case auto = "Auto"
    case files = "Full"
    case selected = "Selected"
    case none = "None"

    package var id: String {
        rawValue
    }
}

package enum CodeMapUsage: String, CaseIterable, Codable {
    case auto
    case complete
    /// Include code-map for selected files only (handled at injection sites;
    /// returning it here would duplicate).
    case selected
    case none
}

package enum GitDiffInclusionMode: String, CaseIterable, Codable {
    case none
    case selectedFiles
    case all

    package var displayName: String {
        switch self {
        case .none: "None"
        case .selectedFiles: "Selected"
        case .all: "All"
        }
    }
}

package enum GitInclusion: String, Codable, CaseIterable {
    case none
    case selected
    case complete
}
