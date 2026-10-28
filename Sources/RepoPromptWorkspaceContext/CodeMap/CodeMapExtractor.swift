import Foundation
import RepoPromptFileSystem
import RepoPromptSettingsCore

// Determines how CodeMap definitions are inserted.

/// File tree build result with marker flags
package struct FileTreeResult {
    package let tree: String
    package let usedSelectedMarker: Bool
    package let usedCodeMapMarker: Bool
    package let wasTruncated: Bool
    package let note: String?
    package var usesLegend: Bool {
        usedSelectedMarker || usedCodeMapMarker
    }

    package init(
        tree: String,
        usedSelectedMarker: Bool,
        usedCodeMapMarker: Bool,
        wasTruncated: Bool,
        note: String?
    ) {
        self.tree = tree
        self.usedSelectedMarker = usedSelectedMarker
        self.usedCodeMapMarker = usedCodeMapMarker
        self.wasTruncated = wasTruncated
        self.note = note
    }
}

/// Namespace for immutable file-tree presentation.
package enum CodeMapExtractor {}
