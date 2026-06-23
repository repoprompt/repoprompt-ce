import Foundation

package struct WorkspacePreset: Codable, Identifiable, Equatable {
    package let id: UUID
    package var name: String

    package var capturesFileSelection: Bool
    package var capturesFileTreeExpansion: Bool
    package var capturesSelectedPrompts: Bool

    package var selectedFilePaths: [String]
    package var expandedFolders: [String]
    package var selectedPromptIDs: [UUID]

    package var lastUpdated: Date

    /// Default init used by code
    package init(
        id: UUID = UUID(),
        name: String,
        capturesFileSelection: Bool = true,
        capturesFileTreeExpansion: Bool = true,
        capturesSelectedPrompts: Bool = true,
        selectedFilePaths: [String] = [],
        expandedFolders: [String] = [],
        selectedPromptIDs: [UUID] = [],
        lastUpdated: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.capturesFileSelection = capturesFileSelection
        self.capturesFileTreeExpansion = capturesFileTreeExpansion
        self.capturesSelectedPrompts = capturesSelectedPrompts
        self.selectedFilePaths = selectedFilePaths
        self.expandedFolders = expandedFolders
        self.selectedPromptIDs = selectedPromptIDs
        self.lastUpdated = lastUpdated
    }

    /// Partial decoding approach to skip errors for mismatch or missing fields.
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Unnamed Preset"
        capturesFileSelection = (try? c.decode(Bool.self, forKey: .capturesFileSelection)) ?? true
        capturesFileTreeExpansion = (try? c.decode(Bool.self, forKey: .capturesFileTreeExpansion)) ?? true
        capturesSelectedPrompts = (try? c.decode(Bool.self, forKey: .capturesSelectedPrompts)) ?? true
        selectedFilePaths = (try? c.decode([String].self, forKey: .selectedFilePaths)) ?? []
        expandedFolders = (try? c.decode([String].self, forKey: .expandedFolders)) ?? []
        selectedPromptIDs = (try? c.decode([UUID].self, forKey: .selectedPromptIDs)) ?? []
        lastUpdated = (try? c.decode(Date.self, forKey: .lastUpdated)) ?? Date()
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case capturesFileSelection
        case capturesFileTreeExpansion
        case capturesSelectedPrompts
        case selectedFilePaths
        case expandedFolders
        case selectedPromptIDs
        case lastUpdated
    }
}

package struct StoredSelection: Codable, Equatable, Hashable {
    package let selectedPaths: [String]
    package let autoCodemapPaths: [String]
    package let slices: [String: [LineRange]]
    package let codemapAutoEnabled: Bool

    package init(
        selectedPaths: [String] = [],
        autoCodemapPaths: [String] = [],
        slices: [String: [LineRange]] = [:],
        codemapAutoEnabled: Bool = true
    ) {
        self.selectedPaths = selectedPaths
        self.autoCodemapPaths = autoCodemapPaths
        self.slices = slices
        self.codemapAutoEnabled = codemapAutoEnabled
    }
}

// Per-tab overrides for Context Builder (prompt overrides only for now)

package struct ContextBuilderOverrides: Codable, Equatable {
    package var useOverridePrompt: Bool
    package var overridePromptText: String

    package init(useOverridePrompt: Bool = false, overridePromptText: String = "") {
        self.useOverridePrompt = useOverridePrompt
        self.overridePromptText = overridePromptText
    }
}

package struct ContextBuilderTabConfig: Codable, Equatable {
    package var instructions: String = ""

    /// Auto-generate a plan after Context Builder completes (nil = use workspace default)
    package var autoGeneratePlan: Bool? = nil
    /// Selected follow-up type for auto-generate (plan/review/question) - defaults to "plan"
    package var followUpTypeRaw: String? = nil
    /// Selected context builder prompt IDs for this tab
    package var selectedContextBuilderPromptIDs: [UUID] = []

    private enum CodingKeys: String, CodingKey {
        case instructions
        case autoGeneratePlan
        case followUpTypeRaw
        case selectedContextBuilderPromptIDs
    }

    package init(
        instructions: String = "",
        autoGeneratePlan: Bool? = nil,
        followUpTypeRaw: String? = nil,
        selectedContextBuilderPromptIDs: [UUID] = []
    ) {
        self.instructions = instructions
        self.autoGeneratePlan = autoGeneratePlan
        self.followUpTypeRaw = followUpTypeRaw
        self.selectedContextBuilderPromptIDs = selectedContextBuilderPromptIDs
    }
}

// A stashed compose tab (stored for later retrieval)

package struct StashedTab: Codable, Identifiable, Equatable {
    package var id: UUID
    package var tab: ComposeTabState
    package var stashedAt: Date

    package init(id: UUID = UUID(), tab: ComposeTabState, stashedAt: Date = Date()) {
        self.id = id
        self.tab = tab
        self.stashedAt = stashedAt
    }
}

// A single Compose tab (auto-saved working state)

package struct ComposeTabState: Codable, Identifiable, Equatable {
    package var id: UUID
    package var name: String
    package var lastModified: Date
    package var isPinned: Bool
    package var activeChatSessionID: UUID?
    package var activeAgentSessionID: UUID?

    package var selection: StoredSelection
    package var expandedFolders: [String]

    package var promptText: String
    package var selectedMetaPromptIDs: [UUID]
    package var activeSubView: FilesTab?
    package var contextOverrides: ContextBuilderOverrides
    /// Active Context Builder tab config. Encodes/decodes under the legacy JSON key `discover`.
    package var contextBuilder: ContextBuilderTabConfig

    package init(
        id: UUID = UUID(),
        name: String = "T1",
        lastModified: Date = Date(),
        isPinned: Bool = false,
        activeChatSessionID: UUID? = nil,
        activeAgentSessionID: UUID? = nil,
        selection: StoredSelection = .init(),
        expandedFolders: [String] = [],
        promptText: String = "",
        selectedMetaPromptIDs: [UUID] = [],
        activeSubView: FilesTab? = nil,
        contextOverrides: ContextBuilderOverrides = .init(),
        contextBuilder: ContextBuilderTabConfig = .init()
    ) {
        self.id = id
        self.name = name
        self.lastModified = lastModified
        self.isPinned = isPinned
        self.activeChatSessionID = activeChatSessionID
        self.activeAgentSessionID = activeAgentSessionID
        self.selection = selection
        self.expandedFolders = expandedFolders
        self.promptText = promptText
        self.selectedMetaPromptIDs = selectedMetaPromptIDs
        self.activeSubView = activeSubView
        self.contextOverrides = contextOverrides
        self.contextBuilder = contextBuilder
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "T1"
        lastModified = try c.decodeIfPresent(Date.self, forKey: .lastModified) ?? Date()
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        activeChatSessionID = try c.decodeIfPresent(UUID.self, forKey: .activeChatSessionID)
        activeAgentSessionID = try c.decodeIfPresent(UUID.self, forKey: .activeAgentSessionID)
        selection = try c.decodeIfPresent(StoredSelection.self, forKey: .selection) ?? .init()
        expandedFolders = try c.decodeIfPresent([String].self, forKey: .expandedFolders) ?? []
        promptText = try c.decodeIfPresent(String.self, forKey: .promptText) ?? ""
        selectedMetaPromptIDs = try c.decodeIfPresent([UUID].self, forKey: .selectedMetaPromptIDs) ?? []
        activeSubView = try c.decodeIfPresent(FilesTab.self, forKey: .activeSubView)
        contextOverrides = try c.decodeIfPresent(ContextBuilderOverrides.self, forKey: .contextOverrides) ?? .init()
        contextBuilder = try c.decodeIfPresent(ContextBuilderTabConfig.self, forKey: .discover) ?? .init()
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(lastModified, forKey: .lastModified)
        try c.encode(isPinned, forKey: .isPinned)
        try c.encodeIfPresent(activeChatSessionID, forKey: .activeChatSessionID)
        try c.encodeIfPresent(activeAgentSessionID, forKey: .activeAgentSessionID)
        try c.encode(selection, forKey: .selection)
        try c.encode(expandedFolders, forKey: .expandedFolders)
        try c.encode(promptText, forKey: .promptText)
        try c.encode(selectedMetaPromptIDs, forKey: .selectedMetaPromptIDs)
        try c.encodeIfPresent(activeSubView, forKey: .activeSubView)
        try c.encode(contextOverrides, forKey: .contextOverrides)
        try c.encode(contextBuilder, forKey: .discover)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case lastModified
        case isPinned
        case activeChatSessionID
        case activeAgentSessionID
        case selection
        case expandedFolders
        case promptText
        case selectedMetaPromptIDs
        case activeSubView
        case contextOverrides
        case discover
    }
}

// A single workspace's data, describing a workspace: name, repo paths, presets, etc.

package struct WorkspaceModel: Codable, Identifiable, Equatable {
    package let id: UUID

    package var schemaVersion: Int
    package var dateModified: Date
    package var customStoragePath: URL?

    package var isSystemWorkspace: Bool
    package var isHiddenInMenus: Bool

    /// When true, the workspace is temporary and should not be persisted to disk
    package var ephemeralFlag: Bool?

    package var name: String
    package var repoPaths: [String]

    package var presets: [WorkspacePreset]
    package var activePresetID: UUID?
    package var lastUsed: Date

    // Optional custom fields
    package var customPath: String?
    package var currentPromptText: String?
    /// The last search query typed in the file-search panel (persisted per workspace)
    package var lastSearchQuery: String?
    package var selectedMetaPromptIDs: [UUID]

    // Copy and Chat Preset Fields
    package var copyPresetId: UUID?
    package var copyCustomizations: CopyCustomizations?
    package var chatPresetId: UUID?

    // Compose tabs (auto-saved working contexts)
    package var composeTabs: [ComposeTabState]
    package var activeComposeTabID: UUID?

    /// Stashed tabs (stored for later retrieval)
    package var stashedTabs: [StashedTab]

    /// Transient decode-time signal used by workspace loaders to persist current
    /// compose-tab invariant normalization once. Excluded from CodingKeys/Equatable.
    package var normalizationRequiresSave: Bool

    private static var composeTabsDecodeWarningEmitted = false

    private static func logComposeTabsDecodeFailure(error: Error, workspaceID: UUID) {
        guard !composeTabsDecodeWarningEmitted else { return }
        composeTabsDecodeWarningEmitted = true
        let message = "Failed to decode composeTabs for workspace \(workspaceID.uuidString); falling back to empty array. Error: \(error.localizedDescription)"
        NSLog("%@", message)
    }

    /// Default init used by code
    package init(
        id: UUID = UUID(),
        schemaVersion: Int = 1,
        dateModified: Date = Date(),
        name: String,
        repoPaths: [String],
        presets: [WorkspacePreset] = [],
        activePresetID: UUID? = nil,
        lastUsed: Date = Date(),
        customPath: String? = nil,
        currentPromptText: String? = nil,
        lastSearchQuery: String? = nil,
        selectedMetaPromptIDs: [UUID] = [],
        isSystemWorkspace: Bool = false,
        customStoragePath: URL? = nil,
        ephemeralFlag: Bool? = nil,
        isHiddenInMenus: Bool = false,
        copyPresetId: UUID? = nil,
        copyCustomizations: CopyCustomizations? = nil,
        chatPresetId: UUID? = nil,
        composeTabs: [ComposeTabState] = [],
        activeComposeTabID: UUID? = nil,
        stashedTabs: [StashedTab] = []
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.dateModified = dateModified
        self.name = name
        self.repoPaths = repoPaths
        self.presets = presets
        self.activePresetID = activePresetID
        self.lastUsed = lastUsed
        self.customPath = customPath
        self.currentPromptText = currentPromptText
        self.selectedMetaPromptIDs = selectedMetaPromptIDs
        self.lastSearchQuery = lastSearchQuery
        self.isSystemWorkspace = isSystemWorkspace
        self.customStoragePath = customStoragePath
        self.ephemeralFlag = ephemeralFlag
        self.isHiddenInMenus = isHiddenInMenus
        self.copyPresetId = copyPresetId
        self.copyCustomizations = copyCustomizations
        self.chatPresetId = chatPresetId
        self.composeTabs = composeTabs
        self.activeComposeTabID = activeComposeTabID
        self.stashedTabs = stashedTabs
        normalizationRequiresSave = false
        normalizeComposeTabInvariants()
        normalizationRequiresSave = false
    }

    /// **Partial decoding** to handle missing fields and type mismatches gracefully.
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
        dateModified = (try? c.decode(Date.self, forKey: .dateModified)) ?? Date()
        customStoragePath = (try? c.decode(URL.self, forKey: .customStoragePath))
        isSystemWorkspace = (try? c.decode(Bool.self, forKey: .isSystemWorkspace)) ?? false
        isHiddenInMenus = (try? c.decode(Bool.self, forKey: .isHiddenInMenus)) ?? false
        ephemeralFlag = (try? c.decode(Bool?.self, forKey: .ephemeralFlag)) ?? nil
        name = (try? c.decode(String.self, forKey: .name)) ?? "Untitled Workspace"
        repoPaths = (try? c.decode([String].self, forKey: .repoPaths)) ?? []
        presets = (try? c.decode([WorkspacePreset].self, forKey: .presets)) ?? []
        activePresetID = (try? c.decode(UUID.self, forKey: .activePresetID))
        lastUsed = (try? c.decode(Date.self, forKey: .lastUsed)) ?? Date()
        customPath = (try? c.decode(String.self, forKey: .customPath))
        currentPromptText = (try? c.decode(String.self, forKey: .currentPromptText))
        lastSearchQuery = (try? c.decode(String.self, forKey: .lastSearchQuery))
        selectedMetaPromptIDs = (try? c.decode([UUID].self, forKey: .selectedMetaPromptIDs)) ?? []
        copyPresetId = (try? c.decode(UUID.self, forKey: .copyPresetId))
        copyCustomizations = (try? c.decode(CopyCustomizations.self, forKey: .copyCustomizations))
        chatPresetId = (try? c.decode(UUID.self, forKey: .chatPresetId))
        do {
            composeTabs = try c.decodeIfPresent([ComposeTabState].self, forKey: .composeTabs) ?? []
        } catch {
            Self.logComposeTabsDecodeFailure(error: error, workspaceID: id)
            composeTabs = []
        }
        activeComposeTabID = (try? c.decode(UUID.self, forKey: .activeComposeTabID))
        stashedTabs = (try? c.decode([StashedTab].self, forKey: .stashedTabs)) ?? []
        normalizationRequiresSave = false
        normalizeComposeTabInvariants()
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(dateModified, forKey: .dateModified)
        try c.encodeIfPresent(customStoragePath, forKey: .customStoragePath)
        try c.encode(isSystemWorkspace, forKey: .isSystemWorkspace)
        try c.encode(isHiddenInMenus, forKey: .isHiddenInMenus)
        try c.encode(name, forKey: .name)
        try c.encode(repoPaths, forKey: .repoPaths)
        try c.encode(presets, forKey: .presets)
        try c.encodeIfPresent(activePresetID, forKey: .activePresetID)
        try c.encode(lastUsed, forKey: .lastUsed)
        try c.encodeIfPresent(customPath, forKey: .customPath)
        try c.encodeIfPresent(currentPromptText, forKey: .currentPromptText)
        try c.encodeIfPresent(lastSearchQuery, forKey: .lastSearchQuery)
        try c.encode(selectedMetaPromptIDs, forKey: .selectedMetaPromptIDs)
        try c.encodeIfPresent(ephemeralFlag, forKey: .ephemeralFlag)
        try c.encodeIfPresent(copyPresetId, forKey: .copyPresetId)
        try c.encodeIfPresent(copyCustomizations, forKey: .copyCustomizations)
        try c.encodeIfPresent(chatPresetId, forKey: .chatPresetId)
        try c.encode(composeTabs, forKey: .composeTabs)
        try c.encodeIfPresent(activeComposeTabID, forKey: .activeComposeTabID)
        try c.encode(stashedTabs, forKey: .stashedTabs)
    }

    package static func == (lhs: WorkspaceModel, rhs: WorkspaceModel) -> Bool {
        lhs.id == rhs.id &&
            lhs.schemaVersion == rhs.schemaVersion &&
            lhs.dateModified == rhs.dateModified &&
            lhs.name == rhs.name &&
            lhs.repoPaths == rhs.repoPaths &&
            lhs.presets == rhs.presets &&
            lhs.activePresetID == rhs.activePresetID &&
            lhs.lastUsed == rhs.lastUsed &&
            lhs.customPath == rhs.customPath &&
            lhs.currentPromptText == rhs.currentPromptText &&
            lhs.lastSearchQuery == rhs.lastSearchQuery &&
            lhs.selectedMetaPromptIDs == rhs.selectedMetaPromptIDs &&
            lhs.isHiddenInMenus == rhs.isHiddenInMenus &&
            lhs.isSystemWorkspace == rhs.isSystemWorkspace &&
            lhs.customStoragePath == rhs.customStoragePath &&
            lhs.ephemeralFlag == rhs.ephemeralFlag &&
            lhs.copyPresetId == rhs.copyPresetId &&
            lhs.copyCustomizations == rhs.copyCustomizations &&
            lhs.chatPresetId == rhs.chatPresetId &&
            lhs.composeTabs == rhs.composeTabs &&
            lhs.activeComposeTabID == rhs.activeComposeTabID &&
            lhs.stashedTabs == rhs.stashedTabs
    }

    enum CodingKeys: String, CodingKey {
        case id
        case schemaVersion
        case dateModified
        case customStoragePath
        case isSystemWorkspace
        case isHiddenInMenus
        case name
        case repoPaths
        case presets
        case activePresetID
        case lastUsed
        case customPath
        case currentPromptText
        case lastSearchQuery
        case selectedMetaPromptIDs
        case ephemeralFlag
        case copyPresetId
        case copyCustomizations
        case chatPresetId
        case composeTabs
        case activeComposeTabID
        case stashedTabs
    }
}

package extension WorkspaceModel {
    /// Indicates whether this workspace should not be persisted to disk
    var isEphemeral: Bool {
        get { ephemeralFlag ?? false }
        set { ephemeralFlag = newValue }
    }

    @discardableResult
    mutating func normalizeComposeTabInvariants() -> Bool {
        var mutated = false

        if composeTabs.isEmpty {
            let tab = ComposeTabState(
                name: "T1",
                promptText: currentPromptText ?? "",
                selectedMetaPromptIDs: selectedMetaPromptIDs,
                activeSubView: nil // nil = use CE default files tab
            )
            composeTabs = [tab]
            activeComposeTabID = tab.id
            mutated = true
        }

        let activeTabIDs = Set(composeTabs.map(\.id))
        if activeComposeTabID.map({ !activeTabIDs.contains($0) }) ?? true {
            activeComposeTabID = composeTabs.first?.id
            mutated = true
        }

        let originalCount = stashedTabs.count
        stashedTabs.removeAll { activeTabIDs.contains($0.tab.id) }
        if stashedTabs.count != originalCount {
            mutated = true
        }

        if mutated {
            normalizationRequiresSave = true
        }
        return mutated
    }
}
