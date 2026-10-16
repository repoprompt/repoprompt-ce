import Foundation
import RepoPromptDomainRuntime

actor ChangeApplier {
    private var manager: ChangeManager

    init(manager: ChangeManager) {
        self.manager = manager
    }

    /// Fast path – one change
    func apply(_ change: FileChange) -> (updated: [String], applied: Set<UUID>, err: Error?) {
        let result = manager.applyChange(change)
        return (result.updatedContent, result.appliedChangeIds, result.error)
    }

    /// Batched version used by "accept all"
    func apply(_ changes: [FileChange]) -> (updated: [String], newlyApplied: Set<UUID>, failedIDs: [UUID]) {
        var union = Set<UUID>()
        var failures: [UUID] = []
        var last = manager.currentContentLines()

        for ch in changes {
            let r = manager.applyChange(ch)
            if let _ = r.error {
                failures.append(ch.id)
            } else {
                union.formUnion(r.appliedChangeIds)
                last = r.updatedContent
            }
        }
        return (last, union, failures)
    }

    func revert(_ change: FileChange) -> (updated: [String], applied: Set<UUID>, err: Error?) {
        let result = manager.revertChange(change)
        return (result.updatedContent, result.appliedChangeIds, result.error)
    }
}
