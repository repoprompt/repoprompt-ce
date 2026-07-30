import Foundation

struct WorkspaceSaveSource: Equatable, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: StringLiteralType) {
        rawValue = value
    }

    var description: String {
        rawValue
    }

    static let pollTimer = WorkspaceSaveSource("pollTimer")
    static let pollAndSaveState = WorkspaceSaveSource("pollAndSaveState")
    static let pollAndSaveStateAsync = WorkspaceSaveSource("pollAndSaveStateAsync")
    static let workspaceSwitchSaveState = WorkspaceSaveSource("workspaceSwitchSaveState")
    static let workspaceFilesDebouncedSelectionSave = WorkspaceSaveSource("workspaceFilesDebouncedSelectionSave")
    static let saveWorkspaceAsync = WorkspaceSaveSource("saveWorkspaceAsync")
    static let createWorkspace = WorkspaceSaveSource("createWorkspace")
    static let renameWorkspace = WorkspaceSaveSource("renameWorkspace")
    static let setWorkspaceHidden = WorkspaceSaveSource("setWorkspaceHidden")
    static let setWorkspaceHiddenFromSnapshot = WorkspaceSaveSource("setWorkspaceHiddenFromSnapshot")
    static let rootReorder = WorkspaceSaveSource("rootReorder")
    static let rootRemove = WorkspaceSaveSource("rootRemove")
    static let rootAdd = WorkspaceSaveSource("rootAdd")
    static let applyPreset = WorkspaceSaveSource("applyPreset")
    static let createPreset = WorkspaceSaveSource("createPreset")
    static let createPresetWithPaths = WorkspaceSaveSource("createPresetWithPaths")
    static let saveCurrentPreset = WorkspaceSaveSource("saveCurrentPreset")
    static let savePresetShortcut = WorkspaceSaveSource("savePresetShortcut")
    static let deletePreset = WorkspaceSaveSource("deletePreset")
    static let renamePreset = WorkspaceSaveSource("renamePreset")
    static let reorderPresets = WorkspaceSaveSource("reorderPresets")
    static let updatePromptText = WorkspaceSaveSource("updatePromptText")
    static let updateSelectedMetaPromptIDs = WorkspaceSaveSource("updateSelectedMetaPromptIDs")
    static let clearActiveAgentSessionIDReferences = WorkspaceSaveSource("clearActiveAgentSessionIDReferences")
    static let duplicateCleanupPreSwitch = WorkspaceSaveSource("duplicateCleanupPreSwitch")
    static let duplicateCleanupCanonicalMerge = WorkspaceSaveSource("duplicateCleanupCanonicalMerge")
    static let createDefaultWorkspace = WorkspaceSaveSource("createDefaultWorkspace")
    static let normalizationWriteback = WorkspaceSaveSource("normalizationWriteback")
    static let refreshWorkspace = WorkspaceSaveSource("refreshWorkspace")
    static let mcpTabContextEndOfRun = WorkspaceSaveSource("mcpTabContextEndOfRun")
    #if DEBUG
        /// DEBUG diagnostics/fixture save attribution for workspace selection fixture apply flows.
        static let debugWorkspaceSelectionFixtureApply = WorkspaceSaveSource("debugWorkspaceSelectionFixtureApply")
    #endif
    static let directUnknown = WorkspaceSaveSource("directUnknown")
}

struct WorkspaceSaveOwner: Equatable, Hashable {
    let windowID: Int?
    let managerID: UUID?

    static let none = WorkspaceSaveOwner(windowID: nil, managerID: nil)
}

struct WorkspaceTabSelectionKey: Hashable {
    let workspaceID: UUID
    let tabID: UUID
}

struct WorkspaceSaveSelectionSummary: Equatable {
    let tabID: UUID?
    let signature: String?
    let selectedPaths: Int
    let sliceFiles: Int
    let sliceRanges: Int
    let codemapAutoEnabled: Bool

    init(tabID: UUID?, selection: StoredSelection?) {
        self.tabID = tabID
        selectedPaths = selection?.selectedPaths.count ?? 0
        sliceFiles = selection?.slices.count ?? 0
        sliceRanges = selection?.slices.values.reduce(0) { $0 + $1.count } ?? 0
        codemapAutoEnabled = selection?.codemapAutoEnabled ?? true
        #if DEBUG
            signature = selection.map { WorkspaceSelectionDebugSignature.signature(for: $0) }
        #else
            signature = nil
        #endif
    }

    func fields(prefix: String = "selection") -> [String: String] {
        var result: [String: String] = [
            "\(prefix)TabID": tabID.map { String($0.uuidString.prefix(8)) } ?? "<none>",
            "\(prefix)SelectedPaths": "\(selectedPaths)",
            "\(prefix)SliceFiles": "\(sliceFiles)",
            "\(prefix)SliceRanges": "\(sliceRanges)",
            "\(prefix)CodemapAutoEnabled": "\(codemapAutoEnabled)"
        ]
        if let signature {
            result["\(prefix)Signature"] = signature
        }
        return result
    }
}

struct WorkspaceSavePayloadMetadata: Equatable {
    let payloadID: UUID
    let source: WorkspaceSaveSource
    let owner: WorkspaceSaveOwner
    let workspaceID: UUID
    let workspaceName: String
    let workspaceDateModified: Date
    let activeTabID: UUID?
    let activeSelectionRevision: UInt64
    let activeSelection: StoredSelection?
    let selectionSummary: WorkspaceSaveSelectionSummary
    let createdAt: Date

    init(
        payloadID: UUID = UUID(),
        source: WorkspaceSaveSource,
        owner: WorkspaceSaveOwner,
        workspaceID: UUID,
        workspaceName: String,
        workspaceDateModified: Date,
        activeTabID: UUID?,
        activeSelectionRevision: UInt64,
        activeSelection: StoredSelection?,
        createdAt: Date = Date()
    ) {
        self.payloadID = payloadID
        self.source = source
        self.owner = owner
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.workspaceDateModified = workspaceDateModified
        self.activeTabID = activeTabID
        self.activeSelectionRevision = activeSelectionRevision
        self.activeSelection = activeSelection
        selectionSummary = WorkspaceSaveSelectionSummary(tabID: activeTabID, selection: activeSelection)
        self.createdAt = createdAt
    }

    var selectionKey: WorkspaceTabSelectionKey? {
        guard let activeTabID else { return nil }
        return WorkspaceTabSelectionKey(workspaceID: workspaceID, tabID: activeTabID)
    }
}

enum WorkspaceSaveTracer {
    static func event(
        _ name: String,
        metadata: WorkspaceSavePayloadMetadata?,
        url: URL? = nil,
        extra fields: [String: String] = [:]
    ) {
        #if DEBUG
            guard WorkspaceRestorePerfLog.isEnabled else { return }
            var payload = fields
            if let metadata {
                payload.merge(baseFields(for: metadata)) { current, _ in current }
            }
            if let url {
                payload["url"] = url.lastPathComponent
            }
            WorkspaceRestorePerfLog.event(name, fields: payload)
        #endif
    }

    static func capture(
        metadata: WorkspaceSavePayloadMetadata,
        url: URL? = nil,
        liveUI: StoredSelection?,
        stored: StoredSelection?,
        canonical: StoredSelection?,
        chosenOwner: WorkspaceSelectionSaveOwner
    ) {
        #if DEBUG
            var fields: [String: String] = ["chosenOwner": chosenOwner.rawValue]
            fields.merge(WorkspaceSaveSelectionSummary(tabID: metadata.activeTabID, selection: liveUI).fields(prefix: "liveUI")) { current, _ in current }
            fields.merge(WorkspaceSaveSelectionSummary(tabID: metadata.activeTabID, selection: stored).fields(prefix: "stored")) { current, _ in current }
            fields.merge(WorkspaceSaveSelectionSummary(tabID: metadata.activeTabID, selection: canonical).fields(prefix: "canonical")) { current, _ in current }
            event("workspaceSave.capture", metadata: metadata, url: url, extra: fields)
        #endif
    }

    #if DEBUG
        private static func baseFields(for metadata: WorkspaceSavePayloadMetadata) -> [String: String] {
            var fields: [String: String] = [
                "payloadID": WorkspaceRestorePerfLog.shortID(metadata.payloadID),
                "source": metadata.source.rawValue,
                "windowID": metadata.owner.windowID.map(String.init) ?? "<none>",
                "managerID": metadata.owner.managerID.map { WorkspaceRestorePerfLog.shortID($0) } ?? "<none>",
                "workspaceID": WorkspaceRestorePerfLog.shortID(metadata.workspaceID),
                "workspaceName": metadata.workspaceName,
                "workspaceDateModified": String(format: "%.6f", metadata.workspaceDateModified.timeIntervalSince1970),
                "activeTabID": metadata.activeTabID.map { WorkspaceRestorePerfLog.shortID($0) } ?? "<none>",
                "activeSelectionRevision": "\(metadata.activeSelectionRevision)",
                "createdAt": String(format: "%.6f", metadata.createdAt.timeIntervalSince1970)
            ]
            fields.merge(metadata.selectionSummary.fields()) { current, _ in current }
            return fields
        }
    #endif
}

enum WorkspaceSelectionSaveOwner: String, Equatable {
    case canonicalCoordinator
    case storedComposeTab
    case legacyLiveUI
}

struct WorkspaceSelectionForSaveDecision: Equatable {
    let selection: StoredSelection
    let owner: WorkspaceSelectionSaveOwner
}
