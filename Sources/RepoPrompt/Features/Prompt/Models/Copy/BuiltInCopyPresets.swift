import Foundation
import RepoPromptSettingsCore

/// Built-in copy preset definitions with stable UUIDs
enum BuiltInCopyPresets {
    // MARK: - Stored Prompt UUIDs (from PromptViewModel)

    // These are the UUIDs of the stored prompts we want to reference
    private static let architectPromptId = UUID(uuidString: "8E81AAC2-79CE-4897-A59E-EFD81EEBB7E9")!
    private static let reviewPromptId = UUID(uuidString: "D7F1B2E4-3C5A-6B8D-CF8E-1F5D0E2A4C6B")!

    // MARK: - Stable UUID constants

    // These UUIDs are generated once and kept stable for migration purposes
    private static let standardUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    private static let planUUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let manualUUID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private static let diffFollowUpUUID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    private static let codeReviewUUID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!

    // MARK: - Built-in Preset Definitions

    /// Standard preset - Default balanced configuration
    static let standard = CopyPreset(
        id: standardUUID,
        name: "Standard",
        builtInKind: .standard,
        description: "Balanced configuration for general use",
        icon: "📄",
        isBuiltIn: true,
        includeFiles: true,
        includeUserPrompt: true,
        includeMetaPrompts: false, // No stored prompts
        includeFileTree: true,
        fileTreeMode: .auto,
        codeMapUsage: .auto,
        gitInclusion: GitInclusion.none,
        storedPromptIds: [] // No stored prompts
    )

    /// Plan preset - Architecture & design
    static let plan = CopyPreset(
        id: planUUID,
        name: "Plan",
        builtInKind: .plan,
        description: "Architecture design and implementation planning",
        icon: "🏗️",
        isBuiltIn: true,
        includeFiles: true,
        includeUserPrompt: true,
        includeMetaPrompts: true,
        includeFileTree: true,
        fileTreeMode: .auto,
        codeMapUsage: .auto,
        gitInclusion: GitInclusion.none,
        storedPromptIds: [architectPromptId] // Reference the [Architect] stored prompt
    )

    /// Manual preset - Full control (uses current UI state)
    static let manual = CopyPreset(
        id: manualUUID,
        name: "Manual",
        builtInKind: .manual,
        description: "Full control - use current settings",
        icon: "⚙️",
        isBuiltIn: true,
        includeFiles: nil, // All nil = use current UI state
        includeUserPrompt: nil,
        includeMetaPrompts: nil,
        includeFileTree: nil,
        fileTreeMode: nil,
        codeMapUsage: nil,
        gitInclusion: nil // nil = use current UI state
    )

    /// Diff Follow-Up preset - Git-only context for follow-up discussions
    static let diffFollowUp = CopyPreset(
        id: diffFollowUpUUID,
        name: "Diff Follow-Up",
        builtInKind: .diffFollowUp,
        description: "Git diff only - discuss recent changes",
        icon: "↪︎",
        isBuiltIn: true,
        includeFiles: false, // No files
        includeUserPrompt: true, // Include user instructions
        includeMetaPrompts: false,
        includeFileTree: false,
        fileTreeMode: FileTreeOption.none,
        codeMapUsage: CodeMapUsage.none,
        gitInclusion: .selected // Git diff is the focus
    )

    /// Code Review preset - Review with git diff
    static let codeReview = CopyPreset(
        id: codeReviewUUID,
        name: "Review",
        builtInKind: .codeReview,
        description: "Thorough code review focusing on quality and regressions",
        icon: "🔍",
        isBuiltIn: true,
        includeFiles: true,
        includeUserPrompt: true,
        includeMetaPrompts: true,
        includeFileTree: true,
        fileTreeMode: .auto,
        codeMapUsage: .auto,
        gitInclusion: .selected, // Include git diff for review
        storedPromptIds: [reviewPromptId] // Reference the [Review] stored prompt
    )

    // MARK: - Collection of all built-in presets

    /// All built-in presets in a logical order
    static var all: [CopyPreset] {
        [standard, plan, diffFollowUp, codeReview, manual]
    }

    /// Find a built-in preset by its kind
    static func preset(for kind: CopyPresetKind) -> CopyPreset? {
        all.first { $0.builtInKind == kind }
    }

    /// Find a built-in preset by ID
    static func preset(with id: UUID) -> CopyPreset? {
        all.first { $0.id == id }
    }
}
