import Foundation

private extension CodingUserInfoKey {
    static let workspaceDecodeCollector = CodingUserInfoKey(rawValue: "RepoPromptCore.WorkspaceDecodeCollector")!
}

final class WorkspaceDecodeCollector {
    var warnings: [WorkspaceCodecWarning] = []
    var requiresRewrite = false

    func record(code: String, message: String) {
        warnings.append(WorkspaceCodecWarning(code: code, message: message))
    }
}

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
}

package struct StoredSelection: Codable, Equatable {
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

package struct ContextBuilderOverrides: Codable, Equatable {
    package var useOverridePrompt: Bool
    package var overridePromptText: String

    package init(useOverridePrompt: Bool = false, overridePromptText: String = "") {
        self.useOverridePrompt = useOverridePrompt
        self.overridePromptText = overridePromptText
    }
}

package struct ContextBuilderTabConfig: Codable, Equatable {
    package var instructions: String
    package var autoGeneratePlan: Bool?
    package var followUpTypeRaw: String?
    package var selectedContextBuilderPromptIDs: [UUID]

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
    /// Encodes and decodes under the legacy app-v1 JSON key `discover`.
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

    private enum CodingKeys: String, CodingKey {
        case id, name, lastModified, isPinned, activeChatSessionID, activeAgentSessionID
        case selection, expandedFolders, promptText, selectedMetaPromptIDs, activeSubView, contextOverrides
        case discover
    }
}

package struct WorkspaceModel: Codable, Identifiable, Equatable {
    package let id: UUID
    package var schemaVersion: Int
    package var dateModified: Date
    package var customStoragePath: URL?
    package var isSystemWorkspace: Bool
    package var isHiddenInMenus: Bool
    package var ephemeralFlag: Bool?
    package var name: String
    package var repoPaths: [String]
    package var presets: [WorkspacePreset]
    package var activePresetID: UUID?
    package var lastUsed: Date
    package var customPath: String?
    package var currentPromptText: String?
    package var lastSearchQuery: String?
    package var selectedMetaPromptIDs: [UUID]
    package var copyPresetId: UUID?
    package var copyCustomizations: CopyCustomizations?
    package var chatPresetId: UUID?
    package var composeTabs: [ComposeTabState]
    package var activeComposeTabID: UUID?
    package var stashedTabs: [StashedTab]

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
        self.lastSearchQuery = lastSearchQuery
        self.selectedMetaPromptIDs = selectedMetaPromptIDs
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
        _ = normalizeComposeTabInvariants()
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
        dateModified = (try? c.decode(Date.self, forKey: .dateModified)) ?? Date()
        customStoragePath = try? c.decode(URL.self, forKey: .customStoragePath)
        isSystemWorkspace = (try? c.decode(Bool.self, forKey: .isSystemWorkspace)) ?? false
        isHiddenInMenus = (try? c.decode(Bool.self, forKey: .isHiddenInMenus)) ?? false
        ephemeralFlag = (try? c.decode(Bool?.self, forKey: .ephemeralFlag)) ?? nil
        name = (try? c.decode(String.self, forKey: .name)) ?? "Untitled Workspace"
        repoPaths = (try? c.decode([String].self, forKey: .repoPaths)) ?? []
        presets = (try? c.decode([WorkspacePreset].self, forKey: .presets)) ?? []
        activePresetID = try? c.decode(UUID.self, forKey: .activePresetID)
        lastUsed = (try? c.decode(Date.self, forKey: .lastUsed)) ?? Date()
        customPath = try? c.decode(String.self, forKey: .customPath)
        currentPromptText = try? c.decode(String.self, forKey: .currentPromptText)
        lastSearchQuery = try? c.decode(String.self, forKey: .lastSearchQuery)
        selectedMetaPromptIDs = (try? c.decode([UUID].self, forKey: .selectedMetaPromptIDs)) ?? []
        copyPresetId = try? c.decode(UUID.self, forKey: .copyPresetId)
        copyCustomizations = try? c.decode(CopyCustomizations.self, forKey: .copyCustomizations)
        chatPresetId = try? c.decode(UUID.self, forKey: .chatPresetId)
        do {
            composeTabs = try c.decodeIfPresent([ComposeTabState].self, forKey: .composeTabs) ?? []
        } catch {
            composeTabs = []
            (decoder.userInfo[.workspaceDecodeCollector] as? WorkspaceDecodeCollector)?.record(
                code: "compose_tabs_decode_failed",
                message: "Failed to decode composeTabs for workspace \(id.uuidString); used an empty array before normalization."
            )
        }
        activeComposeTabID = try? c.decode(UUID.self, forKey: .activeComposeTabID)
        stashedTabs = (try? c.decode([StashedTab].self, forKey: .stashedTabs)) ?? []
        if normalizeComposeTabInvariants() {
            (decoder.userInfo[.workspaceDecodeCollector] as? WorkspaceDecodeCollector)?.requiresRewrite = true
        }
    }

    package var isEphemeral: Bool {
        get { ephemeralFlag ?? false }
        set { ephemeralFlag = newValue }
    }

    @discardableResult
    package mutating func normalizeComposeTabInvariants() -> Bool {
        var mutated = false
        if composeTabs.isEmpty {
            let tab = ComposeTabState(
                name: "T1",
                promptText: currentPromptText ?? "",
                selectedMetaPromptIDs: selectedMetaPromptIDs,
                activeSubView: nil
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
        return mutated
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, dateModified, customStoragePath, isSystemWorkspace, isHiddenInMenus
        case name, repoPaths, presets, activePresetID, lastUsed, customPath, currentPromptText
        case lastSearchQuery, selectedMetaPromptIDs, ephemeralFlag, copyPresetId, copyCustomizations
        case chatPresetId, composeTabs, activeComposeTabID, stashedTabs
    }
}

extension WorkspaceModel {
    static func decodeAppV1(_ data: Data) throws -> WorkspaceDocumentDecodeResult<WorkspaceModel> {
        let decoder = JSONDecoder()
        let collector = WorkspaceDecodeCollector()
        decoder.userInfo[.workspaceDecodeCollector] = collector
        let workspace = try decoder.decode(WorkspaceModel.self, from: data)
        return WorkspaceDocumentDecodeResult(
            document: workspace,
            sourceVersion: WorkspaceDocumentFormatVersion(family: "embedded-app", version: 1),
            warnings: collector.warnings,
            requiresRewrite: collector.requiresRewrite
        )
    }
}
