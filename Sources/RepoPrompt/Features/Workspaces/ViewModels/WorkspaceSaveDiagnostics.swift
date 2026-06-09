import Foundation
import RepoPromptCore

typealias WorkspaceSaveSource = RepoPromptCore.WorkspaceSaveSource
typealias WorkspaceSaveOwner = RepoPromptCore.WorkspaceSaveOwner
typealias WorkspaceTabSelectionKey = RepoPromptCore.WorkspaceTabSelectionKey
typealias WorkspaceSaveSelectionSummary = RepoPromptCore.WorkspaceSaveSelectionSummary
typealias WorkspaceSavePayloadMetadata = RepoPromptCore.WorkspaceSavePayloadMetadata
typealias WorkspaceSelectionSaveOwner = RepoPromptCore.WorkspaceSelectionSaveOwner
typealias WorkspaceSelectionForSaveDecision = RepoPromptCore.WorkspaceSelectionForSaveDecision

extension WorkspaceSaveSource {
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
    static let refreshWorkspace = WorkspaceSaveSource("refreshWorkspace")
    static let mcpTabContextEndOfRun = WorkspaceSaveSource("mcpTabContextEndOfRun")
    #if DEBUG
        static let debugWorkspaceSelectionFixtureApply = WorkspaceSaveSource("debugWorkspaceSelectionFixtureApply")
    #endif
    static let directUnknown = WorkspaceSaveSource("directUnknown")
}

extension WorkspaceSaveSelectionSummary {
    func fields(prefix: String = "selection", selection: StoredSelection? = nil) -> [String: String] {
        var result: [String: String] = [
            "\(prefix)TabID": tabID.map { String($0.uuidString.prefix(8)) } ?? "<none>",
            "\(prefix)SelectedPaths": "\(selectedPaths)",
            "\(prefix)AutoCodemapPaths": "\(autoCodemapPaths)",
            "\(prefix)SliceFiles": "\(sliceFiles)",
            "\(prefix)SliceRanges": "\(sliceRanges)",
            "\(prefix)CodemapAutoEnabled": "\(codemapAutoEnabled)"
        ]
        #if DEBUG
            if let selection {
                result["\(prefix)Signature"] = WorkspaceSelectionDebugSignature.signature(for: selection)
            }
        #endif
        return result
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
            if let url { payload["url"] = url.lastPathComponent }
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
            fields.merge(WorkspaceSaveSelectionSummary(tabID: metadata.activeTabID, selection: liveUI).fields(prefix: "liveUI", selection: liveUI)) { current, _ in current }
            fields.merge(WorkspaceSaveSelectionSummary(tabID: metadata.activeTabID, selection: stored).fields(prefix: "stored", selection: stored)) { current, _ in current }
            fields.merge(WorkspaceSaveSelectionSummary(tabID: metadata.activeTabID, selection: canonical).fields(prefix: "canonical", selection: canonical)) { current, _ in current }
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
            fields.merge(metadata.selectionSummary.fields(selection: metadata.activeSelection)) { current, _ in current }
            return fields
        }
    #endif
}
