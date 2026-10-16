import Foundation
import RepoPromptSettingsCore

/// Stores user overrides for built-in copy presets
/// Only non-nil fields represent changes from the base preset
struct CopyPresetOverrides: Codable, Equatable {
    let presetID: UUID
    var includeFiles: Bool?
    var includeUserPrompt: Bool?
    var includeMetaPrompts: Bool?
    var includeFileTree: Bool?
    var fileTreeMode: FileTreeOption?
    var codeMapUsage: CodeMapUsage?
    var gitInclusion: GitInclusion?
    var storedPromptIds: [UUID]?
    var updatedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case presetID
        case includeFiles
        case includeUserPrompt
        case includeMetaPrompts
        case includeFileTree
        case fileTreeMode
        case codeMapUsage
        case gitInclusion
        case storedPromptIds
        case updatedAt
    }

    init(
        presetID: UUID,
        includeFiles: Bool? = nil,
        includeUserPrompt: Bool? = nil,
        includeMetaPrompts: Bool? = nil,
        includeFileTree: Bool? = nil,
        fileTreeMode: FileTreeOption? = nil,
        codeMapUsage: CodeMapUsage? = nil,
        gitInclusion: GitInclusion? = nil,
        storedPromptIds: [UUID]? = nil,
        updatedAt: Date? = nil
    ) {
        self.presetID = presetID
        self.includeFiles = includeFiles
        self.includeUserPrompt = includeUserPrompt
        self.includeMetaPrompts = includeMetaPrompts
        self.includeFileTree = includeFileTree
        self.fileTreeMode = fileTreeMode
        self.codeMapUsage = codeMapUsage
        self.gitInclusion = gitInclusion
        self.storedPromptIds = storedPromptIds
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        presetID = try container.decode(UUID.self, forKey: .presetID)
        includeFiles = try container.decodeIfPresent(Bool.self, forKey: .includeFiles)
        includeUserPrompt = try container.decodeIfPresent(Bool.self, forKey: .includeUserPrompt)
        includeMetaPrompts = try container.decodeIfPresent(Bool.self, forKey: .includeMetaPrompts)
        includeFileTree = try container.decodeIfPresent(Bool.self, forKey: .includeFileTree)
        fileTreeMode = try container.decodeIfPresent(FileTreeOption.self, forKey: .fileTreeMode)
        codeMapUsage = try container.decodeIfPresent(CodeMapUsage.self, forKey: .codeMapUsage)
        gitInclusion = try container.decodeIfPresent(GitInclusion.self, forKey: .gitInclusion)
        storedPromptIds = try container.decodeIfPresent([UUID].self, forKey: .storedPromptIds)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    /// Returns true if no overrides are set
    var isEmpty: Bool {
        includeFiles == nil &&
            includeUserPrompt == nil &&
            includeMetaPrompts == nil &&
            includeFileTree == nil &&
            fileTreeMode == nil &&
            codeMapUsage == nil &&
            gitInclusion == nil &&
            storedPromptIds == nil
    }

    /// Returns a copy with only fields that differ from the base preset
    func trimmed(against base: CopyPreset) -> CopyPresetOverrides {
        var trimmed = self

        // Set fields to nil if they match the base
        if trimmed.includeFiles == base.includeFiles {
            trimmed.includeFiles = nil
        }
        if trimmed.includeUserPrompt == base.includeUserPrompt {
            trimmed.includeUserPrompt = nil
        }
        if trimmed.includeMetaPrompts == base.includeMetaPrompts {
            trimmed.includeMetaPrompts = nil
        }
        if trimmed.includeFileTree == base.includeFileTree {
            trimmed.includeFileTree = nil
        }
        if trimmed.fileTreeMode == base.fileTreeMode {
            trimmed.fileTreeMode = nil
        }
        if trimmed.codeMapUsage == base.codeMapUsage {
            trimmed.codeMapUsage = nil
        }
        if trimmed.gitInclusion == base.gitInclusion {
            trimmed.gitInclusion = nil
        }
        if trimmed.storedPromptIds == base.storedPromptIds {
            trimmed.storedPromptIds = nil
        }
        return trimmed
    }

    /// Creates an empty override for a preset
    static func empty(for presetID: UUID) -> CopyPresetOverrides {
        CopyPresetOverrides(presetID: presetID)
    }
}
