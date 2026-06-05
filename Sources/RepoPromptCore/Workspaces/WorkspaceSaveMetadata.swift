import Foundation

package struct WorkspaceSaveSource: Equatable, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    package let rawValue: String

    package init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    package init(stringLiteral value: StringLiteralType) {
        rawValue = value
    }

    package var description: String {
        rawValue
    }
}

package struct WorkspaceSaveOwner: Equatable, Hashable {
    package let windowID: Int?
    package let managerID: UUID?

    package init(windowID: Int?, managerID: UUID?) {
        self.windowID = windowID
        self.managerID = managerID
    }

    package static let none = WorkspaceSaveOwner(windowID: nil, managerID: nil)
}

package struct WorkspaceTabSelectionKey: Hashable {
    package let workspaceID: UUID
    package let tabID: UUID

    package init(workspaceID: UUID, tabID: UUID) {
        self.workspaceID = workspaceID
        self.tabID = tabID
    }
}

package struct WorkspaceSaveSelectionRecord: Equatable {
    package let tabID: UUID
    package let revision: UInt64
    package let selection: StoredSelection

    package init(tabID: UUID, revision: UInt64, selection: StoredSelection) {
        self.tabID = tabID
        self.revision = revision
        self.selection = selection
    }

    package func key(workspaceID: UUID) -> WorkspaceTabSelectionKey {
        WorkspaceTabSelectionKey(workspaceID: workspaceID, tabID: tabID)
    }
}

package struct WorkspaceSaveSelectionSummary: Equatable {
    package let tabID: UUID?
    package let selectedPaths: Int
    package let autoCodemapPaths: Int
    package let sliceFiles: Int
    package let sliceRanges: Int
    package let codemapAutoEnabled: Bool

    package init(tabID: UUID?, selection: StoredSelection?) {
        self.tabID = tabID
        selectedPaths = selection?.selectedPaths.count ?? 0
        autoCodemapPaths = selection?.autoCodemapPaths.count ?? 0
        sliceFiles = selection?.slices.count ?? 0
        sliceRanges = selection?.slices.values.reduce(0) { $0 + $1.count } ?? 0
        codemapAutoEnabled = selection?.codemapAutoEnabled ?? true
    }
}

package struct WorkspaceSavePayloadMetadata: Equatable {
    package let payloadID: UUID
    package let source: WorkspaceSaveSource
    package let owner: WorkspaceSaveOwner
    package let workspaceID: UUID
    package let workspaceName: String
    package let workspaceDateModified: Date
    package let activeTabID: UUID?
    package let activeSelectionRevision: UInt64
    package let activeSelection: StoredSelection?
    package let selectionRecords: [WorkspaceSaveSelectionRecord]
    package let selectionSummary: WorkspaceSaveSelectionSummary
    package let createdAt: Date

    package init(
        payloadID: UUID = UUID(),
        source: WorkspaceSaveSource,
        owner: WorkspaceSaveOwner,
        workspaceID: UUID,
        workspaceName: String,
        workspaceDateModified: Date,
        activeTabID: UUID?,
        activeSelectionRevision: UInt64,
        activeSelection: StoredSelection?,
        selectionRecords: [WorkspaceSaveSelectionRecord]? = nil,
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
        self.selectionRecords = selectionRecords ?? {
            guard let activeTabID, let activeSelection else { return [] }
            return [WorkspaceSaveSelectionRecord(
                tabID: activeTabID,
                revision: activeSelectionRevision,
                selection: activeSelection
            )]
        }()
        selectionSummary = WorkspaceSaveSelectionSummary(tabID: activeTabID, selection: activeSelection)
        self.createdAt = createdAt
    }

    package var selectionKey: WorkspaceTabSelectionKey? {
        guard let activeTabID else { return nil }
        return WorkspaceTabSelectionKey(workspaceID: workspaceID, tabID: activeTabID)
    }
}

package enum WorkspaceSelectionSaveOwner: String, Equatable {
    case canonicalCoordinator
    case storedComposeTab
    case legacyLiveUI
}

package struct WorkspaceSelectionForSaveDecision: Equatable {
    package let selection: StoredSelection
    package let owner: WorkspaceSelectionSaveOwner

    package init(selection: StoredSelection, owner: WorkspaceSelectionSaveOwner) {
        self.selection = selection
        self.owner = owner
    }
}
