import Foundation
import RepoPromptInstrumentation

/// Reasons the session-index state changed, used by the store to notify the
/// delegate (the view model) so it can trigger sidebar UI sync.
enum SessionIndexStateChangeReason {
    case sessionIndex
    case sortDates
    case sessionList
    /// Coalesced restoration release or baseline-only change (§5.6): exactly one notification after the
    /// final index, dates, readiness and baseline removal are installed together.
    case restoreProjection
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

    /// Captures the metadata-only sidebar restoration baseline for `workspace` (§5.3). Mirrors
    /// `AgentModeViewModel.makeSidebarRestoreBaseline(for:owner:now:calendar:)`.
    func makeSidebarRestoreBaseline(
        for workspace: WorkspaceModel,
        owner: AgentWorkspaceSessionIndexStore.SessionIndexOwner,
        now: Date,
        calendar: Calendar
    ) -> AgentSidebarRestoreBaseline

    /// Called when `sessionIndex`, `sessionListSortDates`, or
    /// `sessionListCacheReady` changes. The delegate dispatches to
    /// `syncSidebarUIState` as appropriate for the reason.
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
    private let perfRecorder: any AgentModePerfRecording

    init(perfRecorder: any AgentModePerfRecording = NoopAgentModePerfRecorder()) {
        self.perfRecorder = perfRecorder
    }

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

    // MARK: - Local overlay (optimistic upserts/removals before refresh completes)

    private(set) var sessionIndexLocalUpserts: [UUID: AgentSessionIndexEntry] = [:]
    private(set) var sessionIndexLocalRemovals: Set<UUID> = []

    // MARK: - Sidebar restoration baseline and join (§5.2)

    /// Positional baseline for the installed owner's restoration; nil once released or abandoned.
    private(set) var sidebarRestoreBaseline: AgentSidebarRestoreBaseline?
    /// Index/selected join gating the baseline's single release.
    private(set) var sidebarRestoreJoin: AgentSidebarRestoreJoin?
    private var sidebarRestoreBaselineRevision: UInt64 = 0

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

    var ownerValidatedSidebarRestoreBaseline: AgentSidebarRestoreBaseline? {
        guard let baseline = sidebarRestoreBaseline,
              isOwnerCurrent(baseline.owner)
        else {
            return nil
        }
        return baseline
    }

    /// The current owner's unreleased join, if any.
    var ownerValidatedSidebarRestoreJoin: AgentSidebarRestoreJoin? {
        guard let join = sidebarRestoreJoin, ownerValidatedSidebarRestoreBaseline != nil else { return nil }
        return join
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

    /// Installs a new owner, clearing all data and overlay state, and captures its restoration
    /// baseline/join together with the cleared index before one delegate notification (§5.3). The caller
    /// (the view model) is responsible for calling `cancelSessionIndexRefresh()` before this and
    /// resetting `lastSidebarContentFingerprint` after.
    func installOwner(
        _ owner: SessionIndexOwner,
        workspace: WorkspaceModel?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
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
        if let workspace, var baseline = delegate?.makeSidebarRestoreBaseline(
            for: workspace,
            owner: owner,
            now: now,
            calendar: calendar
        ) {
            sidebarRestoreBaselineRevision &+= 1
            baseline.revision = sidebarRestoreBaselineRevision
            sidebarRestoreBaseline = baseline
            let selectedTabID = workspace.activeComposeTabID
            sidebarRestoreJoin = AgentSidebarRestoreJoin(
                initialTabID: selectedTabID,
                initialBindingID: selectedTabID.flatMap { tabID in
                    workspace.composeTabs.first { $0.id == tabID }?.activeAgentSessionID
                },
                index: .pending(generation: nil),
                // No selection has nothing to restore: settle immediately (§5.5).
                selected: selectedTabID == nil ? .settled(.restoration(.noSelection)) : .discovering
            )
        } else {
            sidebarRestoreBaseline = nil
            sidebarRestoreJoin = nil
        }
    }

    // MARK: - Restoration join operations (all owner/token checked)

    private func currentJoin(for owner: SessionIndexOwner) -> AgentSidebarRestoreJoin? {
        guard let join = sidebarRestoreJoin,
              sidebarRestoreBaseline?.owner == owner,
              isOwnerCurrent(owner)
        else { return nil }
        return join
    }

    /// The owner's refresh with `generation` started; a pending, deferred or staged-but-unreleased
    /// index side transfers to it without releasing the baseline. No-op after release.
    func beginSidebarRestoreIndex(generation: UInt64, owner: SessionIndexOwner) {
        guard currentJoin(for: owner) != nil else { return }
        sidebarRestoreJoin?.index = .pending(generation: generation)
    }

    /// Index work stopped without a terminal outcome (Agent Mode inactive, deferred System launch). A
    /// staged-but-unreleased terminal projection is discarded too: deactivation is never a release, and
    /// the same owner's replacement refresh restages it on reactivation (§5.5).
    func deferSidebarRestoreIndex(_ reason: AgentSidebarRestoreJoin.DeferralReason, owner: SessionIndexOwner) {
        guard currentJoin(for: owner) != nil else { return }
        sidebarRestoreJoin?.index = .deferred(reason)
    }

    /// Stages the owner's terminal index projection. Returns true when the active join absorbed it
    /// (the caller must not publish entries/readiness itself); false when no join is active.
    @discardableResult
    func recordSidebarRestoreIndexTerminal(
        generation: UInt64?,
        owner: SessionIndexOwner,
        outcome: AgentSidebarRestoreJoin.IndexOutcome,
        entries: [UUID: AgentSessionIndexEntry],
        ready: Bool
    ) -> Bool {
        guard let join = currentJoin(for: owner) else { return false }
        switch join.index {
        case let .pending(pendingGeneration):
            // A replacement refresh owns the transaction; a stale token cannot stage it.
            if let pendingGeneration, pendingGeneration != generation { return true }
        case .deferred:
            break
        case .terminal:
            // Duplicate terminal callbacks are idempotent.
            return true
        }
        sidebarRestoreJoin?.index = .terminal(generation: generation, outcome: outcome, entries: entries, ready: ready)
        releaseSidebarRestoreIfSettled()
        return true
    }

    /// Records the initially selected restoration's progress; once settled it never re-arms.
    func recordSidebarRestoreSelected(_ side: AgentSidebarRestoreJoin.SelectedSide, owner: SessionIndexOwner) {
        guard let join = currentJoin(for: owner),
              !join.selected.isSettled,
              join.selected != side
        else { return }
        sidebarRestoreJoin?.selected = side
        releaseSidebarRestoreIfSettled()
    }

    /// Admits rows the baseline does not cover (new chats, late tabs) in the given order, appending
    /// ordinals without renumbering. Called on the VM synchronization path before row publication;
    /// it never notifies, but advances the baseline revision consumers fingerprint.
    @discardableResult
    func admitSidebarRestoreCoverage(_ tabs: [ComposeTabState]) -> Bool {
        guard var baseline = ownerValidatedSidebarRestoreBaseline,
              tabs.contains(where: { baseline.entries[$0.id] == nil })
        else { return false }
        guard baseline.admit(tabs) else { return false }
        sidebarRestoreBaselineRevision &+= 1
        baseline.revision = sidebarRestoreBaselineRevision
        sidebarRestoreBaseline = baseline
        return true
    }

    /// Drops the restoration transaction for `owner` (nil: any) without publishing into a successor:
    /// teardown, mismatched restart or owner abandonment. Baseline removal notifies once.
    func abandonSidebarRestore(owner: SessionIndexOwner?) {
        guard sidebarRestoreBaseline != nil || sidebarRestoreJoin != nil else { return }
        if let owner, sidebarRestoreBaseline?.owner != owner { return }
        let hadBaseline = sidebarRestoreBaseline != nil
        sidebarRestoreBaseline = nil
        sidebarRestoreJoin = nil
        guard hadBaseline, !suppressDelegateNotifications else { return }
        delegate?.sessionIndexStore(self, didChangeStateWithReason: .restoreProjection)
    }

    /// One non-suspending release once both sides are terminal (§5.6): revalidate the owner, apply the
    /// latest local overlay to the staged entries, install index, dates, readiness and baseline
    /// removal under suppression, then notify exactly once.
    private func releaseSidebarRestoreIfSettled() {
        guard let join = sidebarRestoreJoin,
              join.isReleasable,
              let owner = sidebarRestoreBaseline?.owner,
              isOwnerCurrent(owner),
              case let .terminal(_, _, entries, ready) = join.index
        else { return }
        do {
            let wasSuppressed = suppressDelegateNotifications
            suppressDelegateNotifications = true
            defer { suppressDelegateNotifications = wasSuppressed }
            let final = sessionIndexEntriesApplyingLocalOverlay(to: entries)
            if sessionIndex != final {
                sessionIndex = final
            }
            rebuildSessionSortDatesFromIndex()
            sessionListCacheReadyOwner = owner
            sessionListCacheReady = ready
            sidebarRestoreBaseline = nil
            sidebarRestoreJoin = nil
        }
        guard !suppressDelegateNotifications else { return }
        delegate?.sessionIndexStore(self, didChangeStateWithReason: .restoreProjection)
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
        let indexChanged = sessionIndex != replacement
        let previousSortDates = sessionListSortDates

        // The index and its derived sort dates are one logical sidebar state.
        // Publishing their didSet notifications separately exposed an
        // intermediate index/new + dates/old fingerprint and rebuilt every row
        // twice per restore batch. Settle both values first, then notify once.
        do {
            suppressDelegateNotifications = true
            defer { suppressDelegateNotifications = false }
            if indexChanged {
                sessionIndex = replacement
            }
            rebuildSessionSortDatesFromIndex()
        }

        let sortDatesChanged = previousSortDates != sessionListSortDates
        guard indexChanged || sortDatesChanged else { return }
        delegate?.sessionIndexStore(
            self,
            didChangeStateWithReason: indexChanged ? .sessionIndex : .sortDates
        )
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
            let rebuildStartMS = perfRecorder.timestampMSIfEnabled()
            let debugSessionIndexCount = sessionIndex.count
        #endif
        var sortDates = AgentSessionRestoreSupport.sidebarSortDates(from: sessionIndex)
        sessionListSortDatesOwner = sessionIndexOwner
        if sessionListSortDates != sortDates {
            sessionListSortDates = sortDates
        }
        #if DEBUG
            perfRecorder.durationEvent(
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
