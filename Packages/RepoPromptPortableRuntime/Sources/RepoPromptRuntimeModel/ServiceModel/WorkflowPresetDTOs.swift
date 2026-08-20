import Foundation

public enum FileTreeOption: String, Codable, Sendable {
    case auto = "Auto"
    case files = "Full"
    case selected = "Selected"
    case none = "None"
}

public enum CodeMapUsage: String, Codable, Sendable {
    case auto
    case complete
    case selected
    case none
}

public enum GitInclusion: String, Codable, Sendable {
    case none
    case selected
    case complete
}

public enum CopyPresetKind: String, Codable, Sendable {
    case standard
    case plan
    case manual
    case diffFollowUp
    case codeReview

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "proEdit" || raw == "editXML" || raw.hasPrefix("mcp") {
            self = .standard
            return
        }
        self = CopyPresetKind(rawValue: raw) ?? .standard
    }
}

public enum ChatPresetMode: String, Codable, Sendable {
    case chat
    case plan
    case review

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "plan": self = .plan
        case "review": self = .review
        default: self = .chat
        }
    }
}

public enum PromptPackagingPurpose: String, Sendable {
    case copy
    case chat
}

public struct CopyPresetRecord: Codable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let builtInKind: CopyPresetKind?
    public let isBuiltIn: Bool
    public let includeFiles: Bool?
    public let includeUserPrompt: Bool?
    public let includeMetaPrompts: Bool?
    public let includeFileTree: Bool?
    public let fileTreeMode: FileTreeOption?
    public let codeMapUsage: CodeMapUsage?
    public let gitInclusion: GitInclusion?
    public let storedPromptIds: [UUID]?

    public init(
        id: UUID,
        name: String,
        builtInKind: CopyPresetKind? = nil,
        isBuiltIn: Bool = false,
        includeFiles: Bool? = nil,
        includeUserPrompt: Bool? = nil,
        includeMetaPrompts: Bool? = nil,
        includeFileTree: Bool? = nil,
        fileTreeMode: FileTreeOption? = nil,
        codeMapUsage: CodeMapUsage? = nil,
        gitInclusion: GitInclusion? = nil,
        storedPromptIds: [UUID]? = nil
    ) {
        self.id = id
        self.name = name
        self.builtInKind = builtInKind
        self.isBuiltIn = isBuiltIn
        self.includeFiles = includeFiles
        self.includeUserPrompt = includeUserPrompt
        self.includeMetaPrompts = includeMetaPrompts
        self.includeFileTree = includeFileTree
        self.fileTreeMode = fileTreeMode
        self.codeMapUsage = codeMapUsage
        self.gitInclusion = gitInclusion
        self.storedPromptIds = storedPromptIds
    }

    public static let standardID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    public static let planID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    public static let manualID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    public static let diffFollowUpID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    public static let codeReviewID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!

    public static let standard = CopyPresetRecord(
        id: standardID,
        name: "Standard",
        builtInKind: .standard,
        isBuiltIn: true,
        includeFiles: true,
        includeUserPrompt: true,
        includeMetaPrompts: false,
        includeFileTree: true,
        fileTreeMode: .auto,
        codeMapUsage: .auto,
        gitInclusion: GitInclusion.none,
        storedPromptIds: []
    )

    public static let diffFollowUp = CopyPresetRecord(
        id: diffFollowUpID,
        name: "Diff Follow-Up",
        builtInKind: .diffFollowUp,
        isBuiltIn: true,
        includeFiles: false,
        includeUserPrompt: true,
        includeMetaPrompts: false,
        includeFileTree: false,
        fileTreeMode: FileTreeOption.none,
        codeMapUsage: CodeMapUsage.none,
        gitInclusion: .selected
    )

    public static let builtIns: [CopyPresetRecord] = [
        standard,
        CopyPresetRecord(id: planID, name: "Plan", builtInKind: .plan, isBuiltIn: true, includeFiles: true, includeUserPrompt: true, includeMetaPrompts: true, includeFileTree: true, fileTreeMode: .auto, codeMapUsage: .auto, gitInclusion: GitInclusion.none, storedPromptIds: [SavedPromptRecord.architectID]),
        diffFollowUp,
        CopyPresetRecord(id: codeReviewID, name: "Review", builtInKind: .codeReview, isBuiltIn: true, includeFiles: true, includeUserPrompt: true, includeMetaPrompts: true, includeFileTree: true, fileTreeMode: .auto, codeMapUsage: .auto, gitInclusion: .selected, storedPromptIds: [SavedPromptRecord.reviewID]),
        CopyPresetRecord(id: manualID, name: "Manual", builtInKind: .manual, isBuiltIn: true)
    ]

    public static func builtIn(id: UUID) -> CopyPresetRecord? {
        builtIns.first { $0.id == id }
    }

    public func applying(_ override: CopyPresetOverrideRecord) -> CopyPresetRecord {
        CopyPresetRecord(
            id: id,
            name: name,
            builtInKind: builtInKind,
            isBuiltIn: isBuiltIn,
            includeFiles: override.includeFiles ?? includeFiles,
            includeUserPrompt: override.includeUserPrompt ?? includeUserPrompt,
            includeMetaPrompts: override.includeMetaPrompts ?? includeMetaPrompts,
            includeFileTree: override.includeFileTree ?? includeFileTree,
            fileTreeMode: override.fileTreeMode ?? fileTreeMode,
            codeMapUsage: override.codeMapUsage ?? codeMapUsage,
            gitInclusion: override.gitInclusion ?? gitInclusion,
            storedPromptIds: override.storedPromptIds ?? storedPromptIds
        )
    }
}

public struct ChatPresetRecord: Codable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let mode: ChatPresetMode
    public let isBuiltIn: Bool
    public let modelPresetName: String?
    public let fileTreeMode: FileTreeOption?
    public let codeMapUsage: CodeMapUsage?
    public let gitInclusion: GitInclusion?
    public let storedPromptIds: [UUID]?
    public let useStoredPromptsAsSystem: Bool?

    public init(
        id: UUID,
        name: String,
        mode: ChatPresetMode,
        isBuiltIn: Bool = false,
        modelPresetName: String? = nil,
        fileTreeMode: FileTreeOption? = nil,
        codeMapUsage: CodeMapUsage? = nil,
        gitInclusion: GitInclusion? = nil,
        storedPromptIds: [UUID]? = nil,
        useStoredPromptsAsSystem: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.isBuiltIn = isBuiltIn
        self.modelPresetName = modelPresetName
        self.fileTreeMode = fileTreeMode
        self.codeMapUsage = codeMapUsage
        self.gitInclusion = gitInclusion
        self.storedPromptIds = storedPromptIds
        self.useStoredPromptsAsSystem = useStoredPromptsAsSystem
    }

    public static let manualID = UUID(uuidString: "A0000000-0000-0000-0000-000000000000")!
    public static let chatID = UUID(uuidString: "A1111111-1111-1111-1111-111111111111")!
    public static let planID = UUID(uuidString: "A2222222-2222-2222-2222-222222222222")!
    public static let reviewID = UUID(uuidString: "A4444444-4444-4444-4444-444444444444")!

    public static let chat = ChatPresetRecord(
        id: chatID,
        name: "Chat",
        mode: .chat,
        isBuiltIn: true,
        fileTreeMode: .auto,
        codeMapUsage: .auto,
        gitInclusion: GitInclusion.none
    )

    public static let builtIns: [ChatPresetRecord] = [
        ChatPresetRecord(id: manualID, name: "Manual", mode: .chat, isBuiltIn: true),
        chat,
        ChatPresetRecord(id: planID, name: "Plan", mode: .plan, isBuiltIn: true, fileTreeMode: .auto, codeMapUsage: .auto, gitInclusion: GitInclusion.none, storedPromptIds: []),
        ChatPresetRecord(id: reviewID, name: "Review", mode: .review, isBuiltIn: true, fileTreeMode: .auto, codeMapUsage: .auto, gitInclusion: .selected, storedPromptIds: [SavedPromptRecord.reviewID], useStoredPromptsAsSystem: true)
    ]

    public static func builtIn(id: UUID) -> ChatPresetRecord? {
        builtIns.first { $0.id == id }
    }

    public func applying(_ override: ChatPresetOverrideRecord) -> ChatPresetRecord {
        ChatPresetRecord(
            id: id,
            name: name,
            mode: mode,
            isBuiltIn: isBuiltIn,
            modelPresetName: override.modelPresetName ?? modelPresetName,
            fileTreeMode: override.fileTreeMode ?? fileTreeMode,
            codeMapUsage: override.codeMapUsage ?? codeMapUsage,
            gitInclusion: override.gitInclusion ?? gitInclusion,
            storedPromptIds: override.storedPromptIds ?? storedPromptIds,
            useStoredPromptsAsSystem: override.useStoredPromptsAsSystem ?? useStoredPromptsAsSystem
        )
    }
}

public struct CopyPresetOverrideRecord: Codable, Hashable, Sendable {
    public let presetID: UUID
    public let includeFiles: Bool?
    public let includeUserPrompt: Bool?
    public let includeMetaPrompts: Bool?
    public let includeFileTree: Bool?
    public let fileTreeMode: FileTreeOption?
    public let codeMapUsage: CodeMapUsage?
    public let gitInclusion: GitInclusion?
    public let storedPromptIds: [UUID]?

    public init(
        presetID: UUID,
        includeFiles: Bool? = nil,
        includeUserPrompt: Bool? = nil,
        includeMetaPrompts: Bool? = nil,
        includeFileTree: Bool? = nil,
        fileTreeMode: FileTreeOption? = nil,
        codeMapUsage: CodeMapUsage? = nil,
        gitInclusion: GitInclusion? = nil,
        storedPromptIds: [UUID]? = nil
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
    }
}

public struct ChatPresetOverrideRecord: Codable, Hashable, Sendable {
    public let presetID: UUID
    public let modelPresetName: String?
    public let fileTreeMode: FileTreeOption?
    public let codeMapUsage: CodeMapUsage?
    public let gitInclusion: GitInclusion?
    public let storedPromptIds: [UUID]?
    public let useStoredPromptsAsSystem: Bool?

    public init(
        presetID: UUID,
        modelPresetName: String? = nil,
        fileTreeMode: FileTreeOption? = nil,
        codeMapUsage: CodeMapUsage? = nil,
        gitInclusion: GitInclusion? = nil,
        storedPromptIds: [UUID]? = nil,
        useStoredPromptsAsSystem: Bool? = nil
    ) {
        self.presetID = presetID
        self.modelPresetName = modelPresetName
        self.fileTreeMode = fileTreeMode
        self.codeMapUsage = codeMapUsage
        self.gitInclusion = gitInclusion
        self.storedPromptIds = storedPromptIds
        self.useStoredPromptsAsSystem = useStoredPromptsAsSystem
    }
}

public struct WorkflowPresetDocument: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let copyUserPresets: [CopyPresetRecord]
    public let copyVisibilityByPresetID: [String: Bool]
    public let copyOverrides: [CopyPresetOverrideRecord]
    public let chatUserPresets: [ChatPresetRecord]
    public let chatVisibilityByPresetID: [String: Bool]
    public let chatOverrides: [ChatPresetOverrideRecord]

    public init(
        schemaVersion: Int = 1,
        copyUserPresets: [CopyPresetRecord] = [],
        copyVisibilityByPresetID: [String: Bool] = [:],
        copyOverrides: [CopyPresetOverrideRecord] = [],
        chatUserPresets: [ChatPresetRecord] = [],
        chatVisibilityByPresetID: [String: Bool] = [:],
        chatOverrides: [ChatPresetOverrideRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.copyUserPresets = copyUserPresets
        self.copyVisibilityByPresetID = copyVisibilityByPresetID
        self.copyOverrides = copyOverrides
        self.chatUserPresets = chatUserPresets
        self.chatVisibilityByPresetID = chatVisibilityByPresetID
        self.chatOverrides = chatOverrides
    }

    public static let empty = WorkflowPresetDocument()

    public func resolvedCopyPreset(selectedID: UUID?) -> CopyPresetRecord {
        if let selectedID, let user = copyUserPresets.first(where: { $0.id == selectedID }) {
            return user
        }
        if let selectedID, var builtin = CopyPresetRecord.builtIn(id: selectedID) {
            if let override = copyOverrides.first(where: { $0.presetID == selectedID }) {
                builtin = builtin.applying(override)
            }
            return builtin
        }
        return .standard
    }

    public func resolvedChatPreset(selectedID: UUID?) -> ChatPresetRecord {
        if let selectedID, let user = chatUserPresets.first(where: { $0.id == selectedID }) {
            return user
        }
        if let selectedID, var builtin = ChatPresetRecord.builtIn(id: selectedID) {
            if let override = chatOverrides.first(where: { $0.presetID == selectedID }) {
                builtin = builtin.applying(override)
            }
            return builtin
        }
        return .chat
    }
}
