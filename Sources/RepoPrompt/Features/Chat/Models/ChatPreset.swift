import Foundation
import RepoPromptFileSystem
import RepoPromptSettingsCore

/// Chat modes available for Oracle/chat presets.
enum ChatPresetMode: String, CaseIterable {
    case chat
    case plan
    case review // Code review mode with git diff context

    var displayName: String {
        switch self {
        case .chat: "Chat"
        case .plan: "Plan"
        case .review: "Review"
        }
    }

    var description: String {
        switch self {
        case .chat: "General discussion and queries"
        case .plan: "Architecture and implementation planning"
        case .review: "Code review with git diff context"
        }
    }
}

extension ChatPresetMode: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case Self.chat.rawValue:
            self = .chat
        case Self.plan.rawValue:
            self = .plan
        case Self.review.rawValue:
            self = .review
        case "edit", "proEdit":
            // Legacy Oracle edit modes are no longer supported; load old presets as Chat.
            self = .chat
        default:
            self = .chat
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Chat preset configuration linking chat mode, model preset, and context strategy
struct ChatPreset: Identifiable, Equatable {
    let id: UUID
    let name: String
    let mode: ChatPresetMode

    /// Optional model specification - can be AIModel rawValue or model preset name
    /// If set, this model will be used when the preset is active
    var modelPresetName: String?

    let description: String?
    let icon: String?
    let isBuiltIn: Bool

    /// File tree, code map, and git settings
    var fileTreeMode: FileTreeOption?
    var codeMapUsage: CodeMapUsage?
    var gitInclusion: GitInclusion?

    /// Stored prompt IDs for meta-instructions
    var storedPromptIds: [UUID]?

    /// NEW: When true and there is exactly one stored prompt ID available (directly or via override),
    /// that stored prompt will be injected as the <system prompt> instead of as meta.
    var useStoredPromptsAsSystem: Bool? // default nil -> treated as false

    // MARK: - Initializer

    init(
        id: UUID = UUID(),
        name: String,
        mode: ChatPresetMode,
        modelPresetName: String? = nil,
        description: String? = nil,
        icon: String? = nil,
        isBuiltIn: Bool = false,
        fileTreeMode: FileTreeOption? = nil,
        codeMapUsage: CodeMapUsage? = nil,
        gitInclusion: GitInclusion? = nil,
        storedPromptIds: [UUID]? = nil,
        useStoredPromptsAsSystem: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.modelPresetName = modelPresetName
        self.description = description
        self.icon = icon
        self.isBuiltIn = isBuiltIn
        self.fileTreeMode = fileTreeMode
        self.codeMapUsage = codeMapUsage
        self.gitInclusion = gitInclusion
        self.storedPromptIds = storedPromptIds
        self.useStoredPromptsAsSystem = useStoredPromptsAsSystem
    }
}

// MARK: - Codable Conformance

extension ChatPreset: Codable {
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case mode
        case modelPresetName
        case description
        case icon
        case isBuiltIn
        case fileTreeMode
        case codeMapUsage
        case gitInclusion
        case storedPromptIds
        case useStoredPromptsAsSystem
    }
}

// MARK: - Built-in Chat Presets

extension ChatPreset {
    /// Built-in chat presets with stable UUIDs
    enum BuiltIn {
        // Stable UUIDs for built-in chat presets
        private static let manualUUID = UUID(uuidString: "A0000000-0000-0000-0000-000000000000")!
        private static let chatUUID = UUID(uuidString: "A1111111-1111-1111-1111-111111111111")!
        private static let planUUID = UUID(uuidString: "A2222222-2222-2222-2222-222222222222")!
        static let reviewUUID = UUID(uuidString: "A4444444-4444-4444-4444-444444444444")!
        private static let reviewPromptId = UUID(uuidString: "D7F1B2E4-3C5A-6B8D-CF8E-1F5D0E2A4C6B")!
        private static let mcpAgentUUID = UUID(uuidString: "A5555555-5555-5555-5555-555555555555")!
        private static let mcpPairUUID = UUID(uuidString: "A6666666-6666-6666-6666-666666666666")!
        private static let mcpPlanUUID = UUID(uuidString: "A7777777-7777-7777-7777-777777777777")!

        /// Manual preset - Full UI control
        static let manual = ChatPreset(
            id: manualUUID,
            name: "Manual",
            mode: ChatPresetMode.chat,
            description: "Full control - all settings visible",
            icon: "⚙️",
            isBuiltIn: true,
            fileTreeMode: nil, // nil = use current UI settings
            codeMapUsage: nil, // nil = use current UI settings
            gitInclusion: nil // nil = use current UI settings
        )

        /// General chat preset
        static let chat = ChatPreset(
            id: chatUUID,
            name: "Chat",
            mode: ChatPresetMode.chat,
            description: "General discussion, Q&A, and code exploration",
            icon: "💬",
            isBuiltIn: true,
            fileTreeMode: .auto,
            codeMapUsage: .auto,
            gitInclusion: GitInclusion.none
        )

        /// Planning preset
        static let plan = ChatPreset(
            id: planUUID,
            name: "Plan",
            mode: ChatPresetMode.plan,
            description: "Design architecture and plan implementation steps",
            icon: "📋",
            isBuiltIn: true,
            fileTreeMode: .auto,
            codeMapUsage: .auto,
            gitInclusion: GitInclusion.none,
            storedPromptIds: [] // Plan mode uses hardcoded architect system prompt
        )

        /// Code review preset - uses stored [Review] prompt as the system prompt (configured, not hard-coded)
        static let review = ChatPreset(
            id: reviewUUID,
            name: "Review",
            mode: ChatPresetMode.review,
            description: "Review code changes with git diff context",
            icon: "🔍",
            isBuiltIn: true,
            fileTreeMode: .auto,
            codeMapUsage: .auto,
            gitInclusion: .selected, // Include selected git diffs for review
            storedPromptIds: [reviewPromptId],
            useStoredPromptsAsSystem: true
        )

        /// All built-in chat presets
        static func all() -> [ChatPreset] {
            [manual, chat, plan, review]
        }
    }
}
