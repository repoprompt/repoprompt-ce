import Foundation

/// Exact saved-carrier lookup, independent of window/prompt/workspace view models.
/// The result is evidence, not a writer or permission. The host revalidates it at
/// mutation admission and supplies live metadata without retaining a census across IO.
@MainActor
enum AgentSavedSessionTargetLoader {
    enum Failure: String, Error {
        case missing = "target_missing"
        case ambiguous = "target_ambiguous"
        case changed = "target_binding_changed"
        case unreadable = "target_saved_state_unreadable"
    }

    struct Target {
        let workspace: WorkspaceModel
        let tab: ComposeTabState
        let stashedTabID: UUID?
        let entry: AgentSessionIndexEntry
    }

    struct LiveMetadata {
        let entry: AgentSessionIndexEntry
        let isAuthoritative: Bool
    }

    /// `workspaces` is a unique catalog snapshot, not selected-window state. Reads are
    /// UUID point reads through the existing data service; no directory enumeration,
    /// provider reconnect, payload hydration, or filesystem writes are introduced.
    static func load(
        sessionID: UUID,
        workspaces: [WorkspaceModel],
        readRecord: (UUID, WorkspaceModel) async throws -> AgentSessionMetadataRecord?,
        currentMetadata: (UUID) -> LiveMetadata?,
        currentWorkspace: (UUID) -> WorkspaceModel?,
        isAvailable: () -> Bool,
        isCurrent: (Target) -> Bool
    ) async -> Result<Target, Failure> {
        guard !Task.isCancelled else { return .failure(.changed) }
        guard isAvailable() else { return .failure(.missing) }
        guard Set(workspaces.map(\.id)).count == workspaces.count else { return .failure(.ambiguous) }
        var found: Target?
        for workspace in workspaces {
            let entry: AgentSessionIndexEntry?
            if let live = currentMetadata(workspace.id), live.isAuthoritative {
                // Saving failure does not veto an already authoritative live runtime.
                entry = live.entry
            } else {
                let record: AgentSessionMetadataRecord?
                do {
                    record = try await readRecord(sessionID, workspace)
                } catch {
                    return .failure(error is CancellationError || Task.isCancelled || !isAvailable() ? .changed : .unreadable)
                }
                guard !Task.isCancelled, isAvailable() else { return .failure(.changed) }
                if let record,
                   record.id != sessionID || (record.workspaceID != nil && record.workspaceID != workspace.id)
                { return .failure(.ambiguous) }
                // Never use the pre-await live observation as a fallback. After a compatible
                // read, a newly bound runtime wins; conflicting disk identity still fails closed.
                let live = currentMetadata(workspace.id)
                entry = live?.isAuthoritative == true ? live?.entry : record?.sidebarEntry() ?? live?.entry
            }
            guard let entry else { continue }
            guard entry.id == sessionID else { return .failure(.ambiguous) }
            guard let current = currentWorkspace(workspace.id), current.id == workspace.id else { return .failure(.changed) }
            let tabs = current.composeTabs.filter { $0.id == entry.tabID }
            let stashes = current.stashedTabs.filter { $0.tab.id == entry.tabID }
            guard tabs.count + stashes.count == 1 else {
                return .failure(tabs.isEmpty && stashes.isEmpty ? .missing : .ambiguous)
            }
            let target = Target(
                workspace: current, tab: tabs.first ?? stashes[0].tab,
                stashedTabID: stashes.first?.id, entry: entry
            )
            guard isAvailable(), isCurrent(target) else { return .failure(.changed) }
            guard found == nil else { return .failure(.ambiguous) }
            found = target
        }
        guard let found else { return .failure(.missing) }
        // A later workspace read may have suspended after the first match was captured.
        guard !Task.isCancelled, isAvailable(), isCurrent(found),
              let current = currentWorkspace(found.workspace.id), current.id == found.workspace.id
        else { return .failure(.changed) }
        let tabs = current.composeTabs.filter { $0.id == found.tab.id }
        let stashes = current.stashedTabs.filter { $0.tab.id == found.tab.id }
        guard tabs.count + stashes.count == 1, stashes.first?.id == found.stashedTabID else { return .failure(.changed) }
        return .success(found)
    }
}
