import Foundation
import RepoPromptFileSystem
import RepoPromptSettingsCore

// Determines how CodeMap definitions are inserted.

/// File tree build result with marker flags
struct FileTreeResult {
    let tree: String
    let usedSelectedMarker: Bool
    let usedCodeMapMarker: Bool
    let wasTruncated: Bool
    let note: String?
    var usesLegend: Bool {
        usedSelectedMarker || usedCodeMapMarker
    }
}

/// Namespace for immutable file-tree presentation.
enum CodeMapExtractor {}
