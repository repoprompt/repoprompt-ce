import Foundation

struct WorkspaceLeakCleanupRecord: Identifiable, Equatable {
    let workspace: WorkspaceModel
    let fileURL: URL
    let evidence: [String]
    let deletionBlockReason: String?

    var id: UUID {
        workspace.id
    }

    var isDeletable: Bool {
        deletionBlockReason == nil
    }
}

struct WorkspaceLeakCleanupPreview: Equatable {
    let catalogRevision: UInt64
    let records: [WorkspaceLeakCleanupRecord]

    static let empty = WorkspaceLeakCleanupPreview(catalogRevision: 0, records: [])

    var deletableRecords: [WorkspaceLeakCleanupRecord] {
        records.filter(\.isDeletable)
    }
}

struct WorkspaceBulkDeleteResult: Equatable {
    var deletedWorkspaceIDs: [UUID] = []
    var alreadyAbsentWorkspaceIDs: [UUID] = []
    var skippedReasonsByWorkspaceID: [UUID: String] = [:]
    var failedReasonsByWorkspaceID: [UUID: String] = [:]

    var isCompleteSuccess: Bool {
        skippedReasonsByWorkspaceID.isEmpty && failedReasonsByWorkspaceID.isEmpty
    }
}

struct WorkspaceManagementSelectionState: Equatable {
    private(set) var isSelecting = false
    private(set) var selectedWorkspaceIDs: Set<UUID> = []

    mutating func begin() {
        isSelecting = true
    }

    mutating func cancel() {
        isSelecting = false
        selectedWorkspaceIDs.removeAll()
    }

    mutating func clear() {
        selectedWorkspaceIDs.removeAll()
    }

    mutating func toggle(_ workspaceID: UUID, isDeletable: Bool) {
        guard isSelecting, isDeletable else { return }
        if !selectedWorkspaceIDs.insert(workspaceID).inserted {
            selectedWorkspaceIDs.remove(workspaceID)
        }
    }

    mutating func selectAllResults(_ workspaceIDs: [UUID]) {
        guard isSelecting else { return }
        selectedWorkspaceIDs.formUnion(workspaceIDs)
    }

    mutating func removeUnavailableWorkspaceIDs(_ availableWorkspaceIDs: Set<UUID>) {
        selectedWorkspaceIDs.formIntersection(availableWorkspaceIDs)
    }

    func selectedCount(in matchingWorkspaceIDs: Set<UUID>) -> Int {
        selectedWorkspaceIDs.intersection(matchingWorkspaceIDs).count
    }
}
