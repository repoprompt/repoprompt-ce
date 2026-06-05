import Foundation

/// Workspace-specific customization overrides for a copy preset.
package struct CopyCustomizations: Codable, Equatable {
    package var selectedPromptIDs: [UUID]?
    package var fileTreeMode: FileTreeOption?
    package var codeMapUsage: CodeMapUsage?
    package var gitInclusion: GitInclusion?
    package var includeFiles: Bool?
    package var includeUserPrompt: Bool?
    package var includeMetaPrompts: Bool?
    package var includeFileTree: Bool?

    package init(
        selectedPromptIDs: [UUID]? = nil,
        fileTreeMode: FileTreeOption? = nil,
        codeMapUsage: CodeMapUsage? = nil,
        gitInclusion: GitInclusion? = nil,
        includeFiles: Bool? = nil,
        includeUserPrompt: Bool? = nil,
        includeMetaPrompts: Bool? = nil,
        includeFileTree: Bool? = nil
    ) {
        self.selectedPromptIDs = selectedPromptIDs
        self.fileTreeMode = fileTreeMode
        self.codeMapUsage = codeMapUsage
        self.gitInclusion = gitInclusion
        self.includeFiles = includeFiles
        self.includeUserPrompt = includeUserPrompt
        self.includeMetaPrompts = includeMetaPrompts
        self.includeFileTree = includeFileTree
    }

    package var hasCustomizations: Bool {
        selectedPromptIDs != nil || fileTreeMode != nil || codeMapUsage != nil || gitInclusion != nil ||
            includeFiles != nil || includeUserPrompt != nil || includeMetaPrompts != nil || includeFileTree != nil
    }

    package mutating func clear() {
        selectedPromptIDs = nil
        fileTreeMode = nil
        codeMapUsage = nil
        gitInclusion = nil
        includeFiles = nil
        includeUserPrompt = nil
        includeMetaPrompts = nil
        includeFileTree = nil
    }

    package func removingCodeMapUsageOverride() -> CopyCustomizations {
        var copy = self
        copy.codeMapUsage = nil
        return copy
    }
}
