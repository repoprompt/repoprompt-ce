import Foundation
import RepoPromptRuntimeModel

public actor SessionSelectionAuthority {
    public let sessionID: UUID
    private var entries: [LogicalSelectionEntry]
    private var revisionValue: Int64
    private var bindingRevisionValue: Int64
    public init(sessionID: UUID, template: [LogicalSelectionEntry] = [], revision: Int64 = 1, bindingRevision: Int64 = 1) {
        self.sessionID = sessionID
        entries = template
        revisionValue = revision
        bindingRevisionValue = bindingRevision
    }

    public func snapshot() -> SelectionSnapshot {
        SelectionSnapshot(sessionID: sessionID, entries: entries, revision: revisionValue, bindingRevision: bindingRevisionValue)
    }

    public func replace(_ next: [LogicalSelectionEntry], expectedRevision: Int64) throws -> SelectionSnapshot {
        guard revisionValue == expectedRevision else { throw ServiceAPIError(code: .staleRevision, message: "Selection revision is stale", currentRevision: revisionValue) }
        entries = Self.normalized(next)
        revisionValue += 1
        return snapshot()
    }

    public func add(_ additions: [LogicalSelectionEntry], expectedRevision: Int64) throws -> SelectionSnapshot {
        try replace(entries + additions, expectedRevision: expectedRevision)
    }

    public func remove(rootID: UUID, logicalPaths: Set<String>, expectedRevision: Int64) throws -> SelectionSnapshot {
        try replace(entries.filter { $0.rootID != rootID || !logicalPaths.contains($0.logicalPath) }, expectedRevision: expectedRevision)
    }

    public func rebind(expectedBindingRevision: Int64) throws -> SelectionSnapshot {
        guard bindingRevisionValue == expectedBindingRevision else { throw ServiceAPIError(code: .staleRevision, message: "Selection binding revision is stale", currentRevision: bindingRevisionValue) }
        bindingRevisionValue += 1
        return snapshot()
    }

    private static func normalized(_ values: [LogicalSelectionEntry]) -> [LogicalSelectionEntry] {
        Array(Set(values)).sorted {
            if $0.rootID != $1.rootID { return $0.rootID.uuidString < $1.rootID.uuidString }
            if $0.logicalPath != $1.logicalPath { return $0.logicalPath < $1.logicalPath }
            return $0.mode.rawValue < $1.mode.rawValue
        }
    }
}
