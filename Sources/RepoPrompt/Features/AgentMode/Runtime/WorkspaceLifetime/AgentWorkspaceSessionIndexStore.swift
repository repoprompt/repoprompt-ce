import Foundation

/// Reasons the session-index state changed, used by the store to notify the
/// delegate (the view model) so it can trigger sidebar UI sync.
enum SessionIndexStateChangeReason {
    case sessionIndex
    case sortDates
    case sessionList
}

/// Delegate protocol for `AgentWorkspaceSessionIndexStore`. The view model
/// conforms to provide workspace queries and receive change notifications.
@MainActor
protocol AgentWorkspaceSessionIndexStoreDelegate: AnyObject {
    /// The active workspace ID used for owner-validation. Mirrors
    /// `AgentModeViewModel.activeWorkspaceIDForSessionIndexOwnership`.
    var activeWorkspaceIDForSessionIndexOwnership: UUID? { get }

    /// The manager's active workspace ID without last-known snapshot fallback.
    /// Used to validate an explicit nil workspace activation so unload cleanup
    /// is not rejected by a stale snapshot from the previous workspace.
    var activeWorkspaceIDForWorkspaceUnloadValidation: UUID? { get }

    /// Whether the active-workspace-ID check should be enforced for non-nil
    /// workspace activations. Mirrors the pre-extraction behavior: the check
    /// is enforced only when a workspace manager is present or a DEBUG test
    /// override is set. Without either (e.g. tests that drive
    /// `handleWorkspaceSwitch` directly with no manager), the check is skipped
    /// so owner validation does not fall back to a stale or nil
    /// `lastKnownWorkspaceSnapshot`.
    var enforcesActiveWorkspaceIDForSessionIndexOwnership: Bool { get }

    /// Builds the frozen sidebar restore order for a workspace. Mirrors
    /// `AgentModeViewModel.makeSidebarRestoreFrozenOrder(for:)`.
    func makeSidebarRestoreFrozenOrder(for workspace: WorkspaceModel) -> [UUID: Int]

    /// Called when `sessionIndex`, `sessionListSortDates`, or
    /// `sessionListCacheReady` changes. The delegate dispatches to
    /// `syncSidebarUIState` and `scheduleSidebarAutoArchiveIfReady` as
    /// appropriate for the reason.
    func sessionIndexStore(
        _ store: AgentWorkspaceSessionIndexStore,
        didChangeStateWithReason reason: SessionIndexStateChangeReason
    )
}

/// Owns the session-index data and workspace-owner epoch machinery previously
/// embedded in `AgentModeViewModel`. The store publishes the three data
/// properties (`sessionIndex`, `sessionListSortDates`, `sessionListCacheReady`)
/// and validates owner currency before exposing them via `ownerValidated*`
/// projections.
///
/// The refresh-token machinery and the `refreshSessionListCache` flow remain on
/// the view model because they are deeply coupled to the refresh pipeline
/// (~500 lines, 107 references). The store owns the DATA and OWNER VALIDATION;
/// the view model owns the REFRESH FLOW that populates the data.
@MainActor
final class AgentWorkspaceSessionIndexStore: ObservableObject {
    /// Owner epoch tracking which workspace activation produced the current
    /// session index. Moved out of `AgentModeViewModel` to reduce
    /// workspace-specific state on the view model. The VM retains a typealias
    /// for backward compatibility.
    struct SessionIndexOwner: Equatable {
        let workspaceID: UUID?
        let activationEpoch: UInt64
    }

    weak var delegate: AgentWorkspaceSessionIndexStoreDelegate?

    private var suppressDelegateNotifications = false

    // MARK: - Published data (formerly @Published on AgentModeViewModel)

    @Published private(set) var sessionIndex: [UUID: AgentSessionIndexEntry] = [:] {
        didSet {
            guard !suppressDelegateNotifications else { return }
            delegate?.sessionIndexStore(self, didChangeStateWithReason: .sessionIndex)
        }
    }

    @Published private(set) var sessionListSortDates: [UUID: Date] = [:] {
        didSet {
            guard !suppressDelegateNotifications else { return }
            delegate?.sessionIndexStore(self, didChangeStateWithReason: .sortDates)
        }
    }

    @Published private(set) var sessionListCacheReady: Bool = false {
        didSet {
            guard sessionListCacheReady != oldValue else { return }
            guard !suppressDelegateNotifications else { return }
            delegate?.sessionIndexStore(self, didChangeStateWithReason: .sessionList)
        }
    }

    // MARK: - Owner / epoch state

    private(set) var sessionIndexActivationEpoch: UInt64 = 0
    private(set) var latestSessionIndexOwner: SessionIndexOwner?
    private(set) var sessionIndexOwner: SessionIndexOwner?
    private(set) var sessionListSortDatesOwner: SessionIndexOwner?
    private(set) var sessionListCacheReadyOwner: SessionIndexOwner?
    private(set) var sidebarRestoreFrozenOrderOwner: SessionIndexOwner?

    // MARK: - Local overlay (optimistic upserts/removals before refresh completes)

    private(set) var sessionIndexLocalUpserts: [UUID: AgentSessionIndexEntry] = [:]
    private(set) var sessionIndexLocalRemovals: Set<UUID> = []

    // MARK: - Frozen sidebar restore order

    private(set) var sidebarRestoreFrozenOrderByTabID: [UUID: Int] = [:]

    // MARK: - Workspace switch / owner creation

    @discardableResult
    func receiveWorkspaceSwitchNotification(_ workspace: WorkspaceModel?) -> SessionIndexOwner {
        sessionIndexActivationEpoch &+= 1
        let owner = SessionIndexOwner(
            workspaceID: workspace?.id,
            activationEpoch: sessionIndexActivationEpoch
        )
        latestSessionIndexOwner = owner
        return owner
    }

    // MARK: - Owner validation

    func isWorkspaceActivationCurrent(
        _ owner: SessionIndexOwner,
        workspace: WorkspaceModel?
    ) -> Bool {
        guard latestSessionIndexOwner == owner,
              owner.workspaceID == workspace?.id
        else {
            return false
        }
        if let delegate {
            if owner.workspaceID == nil, workspace == nil {
                return delegate.activeWorkspaceIDForWorkspaceUnloadValidation == nil
            }
            // Mirror the pre-extraction behavior: only enforce the
            // active-workspace-ID check when a workspace manager is present
            // or a DEBUG test override is set. Otherwise (e.g. tests that
            // drive `handleWorkspaceSwitch` with no manager) skip the check
            // so a stale/nil `lastKnownWorkspaceSnapshot` cannot reject a
            // fresh owner.
            guard delegate.enforcesActiveWorkspaceIDForSessionIndexOwnership else { return true }
            return delegate.activeWorkspaceIDForSessionIndexOwnership == owner.workspaceID
        }
        return true
    }

    func isOwnerCurrent(_ owner: SessionIndexOwner) -> Bool {
        guard latestSessionIndexOwner == owner,
              sessionIndexOwner == owner
        else {
            return false
        }
        return delegate?.activeWorkspaceIDForSessionIndexOwnership == owner.workspaceID
    }

    // MARK: - Owner-validated projections

    var ownerValidatedSessionIndex: [UUID: AgentSessionIndexEntry] {
        guard let owner = sessionIndexOwner,
              isOwnerCurrent(owner)
        else {
            return [:]
        }
        return sessionIndex
    }

    var ownerValidatedSessionListSortDates: [UUID: Date] {
        guard let owner = sessionListSortDatesOwner,
              isOwnerCurrent(owner)
        else {
            return [:]
        }
        return sessionListSortDates
    }

    var ownerValidatedSessionListCacheReady: Bool {
        guard let owner = sessionListCacheReadyOwner,
              isOwnerCurrent(owner)
        else {
            return false
        }
        return sessionListCacheReady
    }

    var ownerValidatedSidebarRestoreFrozenOrderByTabID: [UUID: Int] {
        guard let owner = sidebarRestoreFrozenOrderOwner,
              isOwnerCurrent(owner)
        else {
            return [:]
        }
        return sidebarRestoreFrozenOrderByTabID
    }

    func sidebarAutoArchiveOwner(workspaceID: UUID) -> SessionIndexOwner? {
        guard sessionListCacheReady,
              let owner = sessionListCacheReadyOwner,
              owner.workspaceID == workspaceID,
              isOwnerCurrent(owner)
        else {
            return nil
        }
        return owner
    }

    // MARK: - Mutation

    /// Installs a new owner, clearing all data and overlay state. The caller
    /// (the view model) is responsible for calling
    /// `cancelSessionIndexRefresh(releaseFrozenOrder: false)` before this and
    /// resetting `lastSidebarContentFingerprint` after.
    func installOwner(_ owner: SessionIndexOwner, workspace: WorkspaceModel?) {
        suppressDelegateNotifications = true
        defer {
            suppressDelegateNotifications = false
            delegate?.sessionIndexStore(self, didChangeStateWithReason: .sessionIndex)
        }
        sessionIndexOwner = owner
        sessionListSortDatesOwner = owner
        sessionListCacheReadyOwner = owner
        sessionIndexLocalUpserts.removeAll()
        sessionIndexLocalRemovals.removeAll()
        sessionIndex.removeAll()
        sessionListSortDates.removeAll()
        sessionListCacheReady = false
        if let workspace {
            sidebarRestoreFrozenOrderByTabID = delegate?.makeSidebarRestoreFrozenOrder(for: workspace) ?? [:]
            sidebarRestoreFrozenOrderOwner = owner
        } else {
            sidebarRestoreFrozenOrderByTabID.removeAll()
            sidebarRestoreFrozenOrderOwner = nil
        }
    }

    func releaseSidebarRestoreFrozenOrder(for owner: SessionIndexOwner) {
        guard sidebarRestoreFrozenOrderOwner == owner else { return }
        sidebarRestoreFrozenOrderByTabID.removeAll()
        sidebarRestoreFrozenOrderOwner = nil
    }

    func invalidateSidebarRestoreOrdering() {
        sidebarRestoreFrozenOrderByTabID.removeAll()
        sidebarRestoreFrozenOrderOwner = nil
    }

    func setSessionListCacheReady(_ ready: Bool, for owner: SessionIndexOwner) {
        guard isOwnerCurrent(owner) else { return }
        sessionListCacheReadyOwner = owner
        sessionListCacheReady = ready
    }

    func sessionIndexEntriesApplyingLocalOverlay(
        to base: [UUID: AgentSessionIndexEntry]
    ) -> [UUID: AgentSessionIndexEntry] {
        var result = base
        for (sessionID, entry) in sessionIndexLocalUpserts {
            result[sessionID] = entry
        }
        for sessionID in sessionIndexLocalRemovals {
            result.removeValue(forKey: sessionID)
        }
        return result
    }

    /// Sets `sessionIndex` to the replacement value (if different) and
    /// rebuilds sort dates. Used by the view model's
    /// `publishSessionIndexReplacement` after checking the refresh token.
    func setSessionIndexAndRebuildSortDates(_ replacement: [UUID: AgentSessionIndexEntry]) {
        if sessionIndex != replacement {
            sessionIndex = replacement
        }
        rebuildSessionSortDatesFromIndex()
    }

    func applyLocalUpsert(_ entry: AgentSessionIndexEntry) {
        guard let owner = sessionIndexOwner,
              isOwnerCurrent(owner)
        else {
            return
        }
        sessionIndexLocalRemovals.remove(entry.id)
        sessionIndexLocalUpserts[entry.id] = entry
        var updated = sessionIndex
        updated[entry.id] = entry
        if sessionIndex != updated {
            sessionIndex = updated
        }
        rebuildSessionSortDatesFromIndex()
    }

    func applyLocalRemoval(sessionID: UUID) {
        guard let owner = sessionIndexOwner,
              isOwnerCurrent(owner)
        else {
            return
        }
        sessionIndexLocalUpserts.removeValue(forKey: sessionID)
        sessionIndexLocalRemovals.insert(sessionID)
        if sessionIndex.removeValue(forKey: sessionID) != nil {
            rebuildSessionSortDatesFromIndex()
        }
    }

    func rebuildSessionSortDatesFromIndex() {
        #if DEBUG
            let rebuildStartMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
            let debugSessionIndexCount = sessionIndex.count
        #endif
        var sortDates = AgentSessionRestoreSupport.sidebarSortDates(from: sessionIndex)
        sessionListSortDatesOwner = sessionIndexOwner
        if sessionListSortDates != sortDates {
            sessionListSortDates = sortDates
        }
        #if DEBUG
            AgentModePerfDiagnostics.durationEvent(
                "cleanup.vm.rebuildSessionSortDates",
                startMS: rebuildStartMS,
                fields: [
                    "sessionIndexCount": String(debugSessionIndexCount),
                    "sortDateCount": String(sortDates.count)
                ]
            )
        #endif
    }

    // MARK: - Direct data setters (for refresh flow + test helpers)

    /// Sets `sessionIndex` directly, bypassing the local overlay. Used by the
    /// view model's `publishSessionIndexReplacement` after it has already
    /// applied the overlay and validated the refresh token.
    func setSessionIndex(_ entries: [UUID: AgentSessionIndexEntry]) {
        sessionIndex = entries
    }

    /// Removes a sort-date entry for a tab. Used by session teardown paths
    /// that previously called `sessionListSortDates.removeValue(forKey:)`.
    func removeSortDate(forTabID tabID: UUID) {
        sessionListSortDates.removeValue(forKey: tabID)
    }

    /// Sets a sort-date entry for a tab. Used by session hydration paths
    /// that previously called `sessionListSortDates[tabID] = date`.
    func setSortDate(_ date: Date, forTabID tabID: UUID) {
        guard sessionListSortDates[tabID] != date else { return }
        sessionListSortDates[tabID] = date
    }

    /// Sets `sessionListCacheReady` directly without owner validation. Used by
    /// test helpers.
    func setSessionListCacheReadyDirectly(_ ready: Bool) {
        sessionListCacheReady = ready
    }

    /// Directly installs owner state for test helpers.
    func test_installOwnerState(
        owner: SessionIndexOwner,
        latestOwner: SessionIndexOwner
    ) {
        latestSessionIndexOwner = latestOwner
        sessionIndexOwner = owner
        sessionListSortDatesOwner = owner
        sessionListCacheReadyOwner = owner
    }
}
