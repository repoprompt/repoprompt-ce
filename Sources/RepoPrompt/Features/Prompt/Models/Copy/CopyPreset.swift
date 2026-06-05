import Foundation

// MARK: - Enums

/// Built-in option labels (stable IDs for migration & referencing)
enum CopyPresetKind: String, CaseIterable {
    case standard // Standard default preset
    case plan // Architect planning copy
    case manual // Manual current behavior
    case diffFollowUp // Git-selected only; no files/prompts/tree
    case codeReview // Review w/ git diff
}

extension CopyPresetKind: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        if rawValue == "proEdit" || rawValue == "editXML" || rawValue.hasPrefix("mcp") {
            self = .standard
            return
        }
        self = CopyPresetKind(rawValue: rawValue) ?? .standard
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Copy Preset Model

/// Copy preset describes behavior at a high level.
/// Some fields are optional overrides; unspecified means "use current workspace/UI state".
struct CopyPreset: Identifiable, Equatable {
    let id: UUID
    let name: String
    let builtInKind: CopyPresetKind?
    let description: String?
    let icon: String? // e.g. "🏗️", "📝", "⚡", etc.
    let isBuiltIn: Bool

    // Behavior flags - nil means use current UI state
    var includeFiles: Bool?
    var includeUserPrompt: Bool?
    var includeMetaPrompts: Bool?
    var includeFileTree: Bool?

    // Content shaping - nil means use current UI state
    var fileTreeMode: FileTreeOption? // overrides PromptViewModel.fileTreeOption
    var codeMapUsage: CodeMapUsage? // overrides PromptViewModel.codeMapUsage
    var gitInclusion: GitInclusion? // git diff policy

    // Special prompt behaviors
    var storedPromptIds: [UUID]? // IDs of stored prompts to include
    var notes: String? // Additional notes for user reference

    // MARK: - Initializer

    init(
        id: UUID = UUID(),
        name: String,
        builtInKind: CopyPresetKind? = nil,
        description: String? = nil,
        icon: String? = nil,
        isBuiltIn: Bool = false,
        includeFiles: Bool? = nil,
        includeUserPrompt: Bool? = nil,
        includeMetaPrompts: Bool? = nil,
        includeFileTree: Bool? = nil,
        fileTreeMode: FileTreeOption? = nil,
        codeMapUsage: CodeMapUsage? = nil,
        gitInclusion: GitInclusion? = nil,
        storedPromptIds: [UUID]? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.builtInKind = builtInKind
        self.description = description
        self.icon = icon
        self.isBuiltIn = isBuiltIn
        self.includeFiles = includeFiles
        self.includeUserPrompt = includeUserPrompt
        self.includeMetaPrompts = includeMetaPrompts
        self.includeFileTree = includeFileTree
        self.fileTreeMode = fileTreeMode
        self.codeMapUsage = codeMapUsage
        self.gitInclusion = gitInclusion
        self.storedPromptIds = storedPromptIds
        self.notes = notes
    }
}

// MARK: - Codable Conformance

extension CopyPreset: Codable {
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case builtInKind
        case description
        case icon
        case isBuiltIn
        case includeFiles
        case includeUserPrompt
        case includeMetaPrompts
        case includeFileTree
        case fileTreeMode
        case codeMapUsage
        case gitInclusion
        case storedPromptIds
        case notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        builtInKind = try container.decodeIfPresent(CopyPresetKind.self, forKey: .builtInKind)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
        includeFiles = try container.decodeIfPresent(Bool.self, forKey: .includeFiles)
        includeUserPrompt = try container.decodeIfPresent(Bool.self, forKey: .includeUserPrompt)
        includeMetaPrompts = try container.decodeIfPresent(Bool.self, forKey: .includeMetaPrompts)
        includeFileTree = try container.decodeIfPresent(Bool.self, forKey: .includeFileTree)

        fileTreeMode = try container.decodeIfPresent(FileTreeOption.self, forKey: .fileTreeMode)
        codeMapUsage = try container.decodeIfPresent(CodeMapUsage.self, forKey: .codeMapUsage)

        gitInclusion = try container.decodeIfPresent(GitInclusion.self, forKey: .gitInclusion)
        storedPromptIds = try container.decodeIfPresent([UUID].self, forKey: .storedPromptIds)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(builtInKind, forKey: .builtInKind)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encode(isBuiltIn, forKey: .isBuiltIn)
        try container.encodeIfPresent(includeFiles, forKey: .includeFiles)
        try container.encodeIfPresent(includeUserPrompt, forKey: .includeUserPrompt)
        try container.encodeIfPresent(includeMetaPrompts, forKey: .includeMetaPrompts)
        try container.encodeIfPresent(includeFileTree, forKey: .includeFileTree)
        try container.encodeIfPresent(fileTreeMode, forKey: .fileTreeMode)
        try container.encodeIfPresent(codeMapUsage, forKey: .codeMapUsage)
        try container.encodeIfPresent(gitInclusion, forKey: .gitInclusion)
        try container.encodeIfPresent(storedPromptIds, forKey: .storedPromptIds)
        try container.encodeIfPresent(notes, forKey: .notes)
    }
}

// MARK: - Resolved Configuration

/// A resolved, runtime config after merging preset + workspace overrides + capability checks.
/// Used by both copy and chat prompt builders.
struct PromptContextResolved {
    var includeFiles: Bool
    var includeUserPrompt: Bool
    var includeMetaPrompts: Bool
    var includeFileTree: Bool

    var fileTreeMode: FileTreeOption
    var codeMapUsage: CodeMapUsage
    var gitInclusion: GitInclusion

    var storedPromptIds: [UUID]? // IDs of stored prompts to include

    var rendersFileTree: Bool {
        includeFileTree && fileTreeMode != .none
    }

    var effectiveFileTreeMode: FileTreeOption {
        rendersFileTree ? fileTreeMode : .none
    }
}
