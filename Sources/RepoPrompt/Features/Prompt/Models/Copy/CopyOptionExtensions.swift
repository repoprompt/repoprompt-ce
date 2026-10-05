import Foundation
import RepoPromptSettingsCore

// MARK: - FileTreeOption Caption Extension

extension FileTreeOption {
    var caption: String {
        switch self {
        case .none:
            "No project structure map"
        case .auto:
            "Automatically include a project structure map for folders"
        case .files:
            "Include all files in the project structure map"
        case .selected:
            "Include only selected files in the project structure map"
        }
    }
}

// MARK: - CodeMapUsage Caption Extension

extension CodeMapUsage {
    var caption: String {
        switch self {
        case .none:
            "No code structure extraction"
        case .selected:
            "Replaces full file contents with codemaps"
        case .auto:
            "Automatically extract for supported languages"
        case .complete:
            "Extract complete structure from all files"
        }
    }
}
