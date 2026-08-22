import Foundation

enum WorkspaceBulkDeletePolicy {
    static let maximumWorkspaceCount = 500
}

enum WorkspaceLeakedTestFixtureIdentity {
    enum Match: Equatable {
        case chatSwitch
        case persistentRead

        var evidence: [String] {
            switch self {
            case .chatSwitch:
                [
                    "ephemeralFlag=true",
                    "name matches Agent Mode Chat Switch <8 uppercase hex>",
                    "repo path contains AgentModeChatSwitchActivationTests-<UUID>"
                ]
            case .persistentRead:
                [
                    "ephemeralFlag=true",
                    "name is Persistent Agent Mode MCP Read",
                    "repo path contains PersistentAgentModeMCPReadFileConnectionTests/<UUID>"
                ]
            }
        }
    }

    private static let chatSwitchWorkspaceNamePrefix = "Agent Mode Chat Switch "
    private static let chatSwitchFixtureDirectoryPrefix = "AgentModeChatSwitchActivationTests-"
    private static let persistentReadWorkspaceName = "Persistent Agent Mode MCP Read"
    private static let persistentReadFixtureDirectory = "PersistentAgentModeMCPReadFileConnectionTests"

    static func match(
        isEphemeral: Bool,
        name: String,
        repoPaths: [String]
    ) -> Match? {
        guard isEphemeral else { return nil }

        if hasUppercaseHexSuffix(name, prefix: chatSwitchWorkspaceNamePrefix, count: 8),
           repoPaths.contains(where: containsChatSwitchFixtureIdentity)
        {
            return .chatSwitch
        }

        guard name == persistentReadWorkspaceName,
              repoPaths.contains(where: containsPersistentReadFixtureIdentity)
        else { return nil }
        return .persistentRead
    }

    static func matches(
        isEphemeral: Bool,
        name: String,
        repoPaths: [String]
    ) -> Bool {
        match(isEphemeral: isEphemeral, name: name, repoPaths: repoPaths) != nil
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

    private static func containsChatSwitchFixtureIdentity(_ path: String) -> Bool {
        URL(fileURLWithPath: path).pathComponents.contains(where: isChatSwitchFixtureDirectoryComponent)
    }

    private static func isChatSwitchFixtureDirectoryComponent(_ component: String) -> Bool {
        guard component.hasPrefix(chatSwitchFixtureDirectoryPrefix) else { return false }
        let suffix = String(component.dropFirst(chatSwitchFixtureDirectoryPrefix.count))
        return isCanonicalUppercaseUUID(suffix)
    }

    private static func containsPersistentReadFixtureIdentity(_ path: String) -> Bool {
        let components = URL(fileURLWithPath: path).pathComponents
        guard let directoryIndex = components.lastIndex(of: persistentReadFixtureDirectory) else {
            return false
        }
        let uuidIndex = components.index(after: directoryIndex)
        guard uuidIndex < components.endIndex else { return false }
        return isCanonicalUppercaseUUID(components[uuidIndex])
    }

    private static func isCanonicalUppercaseUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString == value
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
