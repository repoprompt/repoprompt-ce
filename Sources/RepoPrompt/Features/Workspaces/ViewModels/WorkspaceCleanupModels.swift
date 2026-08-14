import Foundation

enum WorkspaceBulkDeletePolicy {
    static let maximumWorkspaceCount = 500
}

enum WorkspaceLeakedTestFixtureIdentity {
    private static let workspaceNamePrefix = "Agent Mode Chat Switch "
    private static let fixtureDirectoryPrefix = "AgentModeChatSwitchActivationTests-"

    static func matches(
        isEphemeral: Bool,
        name: String,
        repoPaths: [String]
    ) -> Bool {
        guard isEphemeral,
              hasUppercaseHexSuffix(name, prefix: workspaceNamePrefix, count: 8)
        else { return false }
        return repoPaths.contains { path in
            URL(fileURLWithPath: path).pathComponents.contains(where: isFixtureDirectoryComponent)
        }
    }

    private static func hasUppercaseHexSuffix(
        _ value: String,
        prefix: String,
        count: Int
    ) -> Bool {
        guard value.hasPrefix(prefix) else { return false }
        let suffix = value.dropFirst(prefix.count)
        guard suffix.utf8.count == count else { return false }
        return suffix.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70)
        }
    }

    private static func isFixtureDirectoryComponent(_ component: String) -> Bool {
        guard component.hasPrefix(fixtureDirectoryPrefix) else { return false }
        let suffix = String(component.dropFirst(fixtureDirectoryPrefix.count))
        guard let uuid = UUID(uuidString: suffix) else { return false }
        return uuid.uuidString == suffix
    }
}

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
    var requestFailureReason: String?
    var deletedWorkspaceIDs: [UUID] = []
    var alreadyAbsentWorkspaceIDs: [UUID] = []
    var skippedReasonsByWorkspaceID: [UUID: String] = [:]
    var failedReasonsByWorkspaceID: [UUID: String] = [:]
    var artifactCleanupWarningsByWorkspaceID: [UUID: String] = [:]

    var retryableWorkspaceIDs: Set<UUID> {
        Set(skippedReasonsByWorkspaceID.keys).union(failedReasonsByWorkspaceID.keys)
    }

    var isCompleteSuccess: Bool {
        requestFailureReason == nil
            && skippedReasonsByWorkspaceID.isEmpty
            && failedReasonsByWorkspaceID.isEmpty
    }
}

enum WorkspaceSelectionMutationResult: Equatable {
    case changed
    case unchanged
    case limitExceeded(maximum: Int, attemptedCount: Int)
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

    @discardableResult
    mutating func toggle(_ workspaceID: UUID, isDeletable: Bool) -> WorkspaceSelectionMutationResult {
        guard isSelecting, isDeletable else { return .unchanged }
        if selectedWorkspaceIDs.remove(workspaceID) != nil {
            return .changed
        }
        guard selectedWorkspaceIDs.count < WorkspaceBulkDeletePolicy.maximumWorkspaceCount else {
            return .limitExceeded(
                maximum: WorkspaceBulkDeletePolicy.maximumWorkspaceCount,
                attemptedCount: selectedWorkspaceIDs.count + 1
            )
        }
        selectedWorkspaceIDs.insert(workspaceID)
        return .changed
    }

    @discardableResult
    mutating func selectAllResults(_ workspaceIDs: [UUID]) -> WorkspaceSelectionMutationResult {
        guard isSelecting else { return .unchanged }
        let combined = selectedWorkspaceIDs.union(workspaceIDs)
        guard combined.count <= WorkspaceBulkDeletePolicy.maximumWorkspaceCount else {
            return .limitExceeded(
                maximum: WorkspaceBulkDeletePolicy.maximumWorkspaceCount,
                attemptedCount: combined.count
            )
        }
        guard combined != selectedWorkspaceIDs else { return .unchanged }
        selectedWorkspaceIDs = combined
        return .changed
    }

    mutating func retainWorkspaceIDs(_ workspaceIDs: Set<UUID>) {
        selectedWorkspaceIDs.formIntersection(workspaceIDs)
    }

    mutating func removeUnavailableWorkspaceIDs(_ availableWorkspaceIDs: Set<UUID>) {
        selectedWorkspaceIDs.formIntersection(availableWorkspaceIDs)
    }

    func selectedCount(in matchingWorkspaceIDs: Set<UUID>) -> Int {
        selectedWorkspaceIDs.intersection(matchingWorkspaceIDs).count
    }
}
