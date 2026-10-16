import Foundation
import RepoPromptSettingsCore

/// Stores user overrides for built-in chat presets
/// Only non-nil fields represent changes from the base preset
struct ChatPresetOverrides: Codable, Equatable {
    let presetID: UUID
    var modelPresetName: String?
    var fileTreeMode: FileTreeOption?
    var codeMapUsage: CodeMapUsage?
    var gitInclusion: GitInclusion?
    var storedPromptIds: [UUID]?
    var updatedAt: Date?
    var useStoredPromptsAsSystem: Bool?

    private enum CodingKeys: String, CodingKey {
        case presetID
        case modelPresetName
        case fileTreeMode
        case codeMapUsage
        case gitInclusion
        case storedPromptIds
        case updatedAt
        case useStoredPromptsAsSystem
    }

    /// Returns true if no overrides are set
    var isEmpty: Bool {
        modelPresetName == nil &&
            fileTreeMode == nil &&
            codeMapUsage == nil &&
            gitInclusion == nil &&
            storedPromptIds == nil &&
            useStoredPromptsAsSystem == nil &&
            updatedAt == nil
    }

    /// Returns a copy with only fields that differ from the base preset
    func trimmed(against base: ChatPreset) -> ChatPresetOverrides {
        var trimmed = self

        // Set fields to nil if they match the base
        if trimmed.modelPresetName == base.modelPresetName {
            trimmed.modelPresetName = nil
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
        if trimmed.useStoredPromptsAsSystem == base.useStoredPromptsAsSystem {
            trimmed.useStoredPromptsAsSystem = nil
        }

        return trimmed
    }

    /// Creates an empty override for a preset
    static func empty(for presetID: UUID) -> ChatPresetOverrides {
        ChatPresetOverrides(
            presetID: presetID,
            modelPresetName: nil,
            fileTreeMode: nil,
            codeMapUsage: nil,
            gitInclusion: nil,
            storedPromptIds: nil,
            updatedAt: nil,
            useStoredPromptsAsSystem: nil
        )
    }
}
