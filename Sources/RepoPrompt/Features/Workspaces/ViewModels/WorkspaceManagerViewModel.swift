import Combine
import Foundation
import os
import SwiftUI

/// Free helper function not tied to any actor
private func defaultWorkspaceRoot() -> URL {
    WorkspaceStoragePaths.defaultRoot
}

private final class WorkspaceSearchReadinessFence: @unchecked Sendable {
    private let lock = NSLock()
    private var currentTicket: WorkspaceSearchReadinessTicket?

    func publish(_ ticket: WorkspaceSearchReadinessTicket?) {
        lock.lock()
        currentTicket = ticket
        lock.unlock()
    }

    func contains(_ ticket: WorkspaceSearchReadinessTicket) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentTicket == ticket
    }
}

private enum WorkspaceExitPerf {
    #if DEBUG || EDIT_FLOW_PERF
        typealias State = OSSignpostIntervalState
        static let signposter = OSSignposter(subsystem: "com.repoprompt.workspace", category: "exit-perf")
        static var isEnabled: Bool {
            UserDefaults.standard.bool(forKey: "enableWorkspaceExitPerfSignposts")
        }

        static func begin(_ name: StaticString) -> State? {
            guard isEnabled else { return nil }
            return signposter.beginInterval(name)
        }

        static func end(_ name: StaticString, _ state: State?) {
            guard isEnabled, let state else { return }
            signposter.endInterval(name, state)
        }
    #else
        struct State {}
        static var isEnabled: Bool {
            false
        }

        static func begin(_ name: StaticString) -> State? {
            nil
        }

        static func end(_ name: StaticString, _ state: State?) {}
    #endif
}

enum WorkspaceStoragePaths {
    static let defaultRoot: URL = {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("RepoPrompt CE", isDirectory: true)
            .appendingPathComponent("Workspaces", isDirectory: true)
    }()
}

struct WorkspaceFileLoadResult {
    let workspace: WorkspaceModel
    let cacheHit: Bool
    let composeTabsNormalized: Bool

    var normalizationRequiresSave: Bool {
        composeTabsNormalized
    }

    let normalizationSaveTask: Task<Void, Never>?
}

private struct WorkspaceFileDecodeCacheKey: Hashable {
    let standardizedPath: String
    let fileSize: Int64
    let modificationDate: Date
}

private struct WorkspaceFileCachedLoadResult {
    let workspace: WorkspaceModel
    let cacheHit: Bool
    let composeTabsNormalized: Bool

    var normalizationRequiresSave: Bool {
        composeTabsNormalized
    }

    let cacheKey: WorkspaceFileDecodeCacheKey
}

final class WorkspaceFileDecodeCache: @unchecked Sendable {
    static let shared = WorkspaceFileDecodeCache()

    private let lock = NSLock()
    private var cachedWorkspacesByKey: [WorkspaceFileDecodeCacheKey: WorkspaceModel] = [:]
    private var scheduledNormalizationSaveKeys: Set<WorkspaceFileDecodeCacheKey> = []

    private init() {}

    fileprivate func loadWorkspace(at fileURL: URL) throws -> WorkspaceFileCachedLoadResult {
        let keyBeforeRead = try metadataKey(for: fileURL)
        lock.lock()
        if let cached = cachedWorkspacesByKey[keyBeforeRead] {
            lock.unlock()
            return WorkspaceFileCachedLoadResult(
                workspace: cached,
                cacheHit: true,
                composeTabsNormalized: cached.normalizationRequiresSave,
                cacheKey: keyBeforeRead
            )
        }
        lock.unlock()

        let standardizedURL = URL(fileURLWithPath: keyBeforeRead.standardizedPath)
        let data = try Data(contentsOf: standardizedURL)
        var workspace = try JSONDecoder().decode(WorkspaceModel.self, from: data)
        let decodedRequiresSave = workspace.normalizationRequiresSave
        let normalized = workspace.normalizeComposeTabInvariants()
        let normalizationRequiresSave = decodedRequiresSave || normalized || workspace.normalizationRequiresSave
        workspace.normalizationRequiresSave = normalizationRequiresSave

        if let keyAfterRead = try? metadataKey(for: fileURL),
           keyAfterRead == keyBeforeRead
        {
            lock.lock()
            cachedWorkspacesByKey[keyBeforeRead] = workspace
            lock.unlock()
        }

        return WorkspaceFileCachedLoadResult(
            workspace: workspace,
            cacheHit: false,
            composeTabsNormalized: normalizationRequiresSave,
            cacheKey: keyBeforeRead
        )
    }

    fileprivate func metadataKey(for fileURL: URL) throws -> WorkspaceFileDecodeCacheKey {
        let standardizedURL = fileURL.standardizedFileURL
        let values = try standardizedURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let fileSize = values.fileSize,
              let modificationDate = values.contentModificationDate
        else {
            throw CocoaError(.fileReadUnknown)
        }
        return WorkspaceFileDecodeCacheKey(
            standardizedPath: standardizedURL.path,
            fileSize: Int64(fileSize),
            modificationDate: modificationDate
        )
    }

    fileprivate func claimNormalizationSave(for key: WorkspaceFileDecodeCacheKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !scheduledNormalizationSaveKeys.contains(key) else { return false }
        scheduledNormalizationSaveKeys.insert(key)
        return true
    }

    fileprivate func isNormalizationSaveClaimed(for key: WorkspaceFileDecodeCacheKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return scheduledNormalizationSaveKeys.contains(key)
    }

    fileprivate func finishNormalizationSave(for key: WorkspaceFileDecodeCacheKey) {
        lock.lock()
        defer { lock.unlock() }
        scheduledNormalizationSaveKeys.remove(key)
        cachedWorkspacesByKey = cachedWorkspacesByKey.filter { $0.key.standardizedPath != key.standardizedPath }
    }

    func invalidate(url: URL) {
        let standardizedPath = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        cachedWorkspacesByKey = cachedWorkspacesByKey.filter { $0.key.standardizedPath != standardizedPath }
        scheduledNormalizationSaveKeys = scheduledNormalizationSaveKeys.filter { $0.standardizedPath != standardizedPath }
    }

    #if DEBUG
        func removeAllForTesting() {
            lock.lock()
            defer { lock.unlock() }
            cachedWorkspacesByKey.removeAll()
            scheduledNormalizationSaveKeys.removeAll()
        }
    #endif
}

/// Minimal info we keep in the index for each workspace
/// so we can load their details individually from disk.
struct WorkspaceIndexEntry: Codable {
    let id: UUID
    var name: String
    var customStoragePath: URL?
    var isSystemWorkspace: Bool
    var isHiddenInMenus: Bool
}

enum WorkspaceOpenBehavior {
    case addToActiveOrCreateNew
    case createNewWorkspace
    case addToActiveOnly
}

struct WorkspaceMenuQuery {
    var includeSystem: Bool = false
    var includeHidden: Bool = false
    var sortMostRecentFirst: Bool = true
}

enum WorkspaceOpenError: LocalizedError {
    case noActiveWorkspace

    var errorDescription: String? {
        switch self {
        case .noActiveWorkspace:
            "No active workspace. Open or create a workspace first."
        }
    }
}

/// The main WorkspaceManager, refactored to store each WorkspaceModel
/// in its own folder + workspace.json, and maintain an index file for all known workspaces.
@MainActor
class WorkspaceManagerViewModel: ObservableObject {
    private static let logger = Logger(subsystem: "com.repoprompt.workspace", category: "WorkspaceSwitch")

    @Published var workspaces: [WorkspaceModel] = [] {
        didSet {
            // Workspace IDs should be unique, but a corrupted index or
            // migration bug must not SIGTRAP every workspace assignment.
            // Last-wins matches the array-order lookup semantics below.
            workspaceIndexMap = Dictionary(
                workspaces.enumerated().map { ($1.id, $0) },
                uniquingKeysWith: { _, last in last }
            )
            refreshSelectionMirrorContextRevision()
        }
    }

    @Published private(set) var activeWorkspaceID: UUID? = nil {
        didSet {
            guard oldValue != activeWorkspaceID else { return }
            workspaceSearchReadinessFence.publish(nil)
            refreshSelectionMirrorContextRevision()
        }
    }

    #if DEBUG
        private var restoreTokenRecountWatchdogIDs: Set<UUID> = []
    #endif

    /// Per-tab suspension of snapshot commits during UI apply to prevent transient overwrites
    @Published private var suspendedSnapshotCommitTabIDs: Set<UUID> = []
    private var activationSnapshotSuspendedTabIDs: Set<UUID> = []

    // Guard to suppress cross-tab snapshot emissions during MCP tab-context apply
    @Published private var applyingTabContextID: UUID? = nil
    private var applyingTabContextDepthByTabID: [UUID: Int] = [:]

    // MARK: - Versioned dirty-tracking (no equality needed)

    private var stateVersionByWorkspaceID: [UUID: Int] = [:]
    private var lastSavedVersionByWorkspaceID: [UUID: Int] = [:]

    @MainActor
    private static var nextWorkspaceSelectionRevision: UInt64 = 1
    @MainActor
    private static var nextMCPSelectionPropagationRevision: UInt64 = 1
    let mcpSelectionPropagationHostID = UUID()
    private var selectionRevisionByWorkspaceTab: [WorkspaceTabSelectionKey: UInt64] = [:]
    private var revisedSelectionByWorkspaceTab: [WorkspaceTabSelectionKey: StoredSelection] = [:]
    private var latestMCPSelectionRevisionByWorkspaceTab: [WorkspaceTabSelectionKey: UInt64] = [:]

    private struct SelectionMirrorContext: Equatable {
        let workspaceID: UUID
        let tabID: UUID
    }

    private var lastSelectionMirrorContext: SelectionMirrorContext?
    private(set) var selectionMirrorContextRevision: UInt64 = 0

    private func refreshSelectionMirrorContextRevision() {
        let context: SelectionMirrorContext? = if let activeWorkspaceID,
                                                  let workspace = workspaces.first(where: { $0.id == activeWorkspaceID }),
                                                  let tabID = workspace.activeComposeTabID ?? workspace.composeTabs.first?.id
        {
            SelectionMirrorContext(workspaceID: activeWorkspaceID, tabID: tabID)
        } else {
            nil
        }
        guard context != lastSelectionMirrorContext else { return }
        lastSelectionMirrorContext = context
        selectionMirrorContextRevision &+= 1
    }

    private func bumpStateVersion(for id: UUID?) {
        guard let id else { return }
        stateVersionByWorkspaceID[id, default: 0] &+= 1 // wraparound-safe
    }

    private static func allocateWorkspaceSelectionRevision() -> UInt64 {
        let revision = nextWorkspaceSelectionRevision
        nextWorkspaceSelectionRevision &+= 1
        return revision
    }

    func registerMCPSelectionSourceMutation(
        for identity: WorkspaceSelectionIdentity
    ) -> MCPSelectionPropagationRegistration {
        let revision = Self.nextMCPSelectionPropagationRevision
        Self.nextMCPSelectionPropagationRevision &+= 1

        let key = WorkspaceTabSelectionKey(workspaceID: identity.workspaceID, tabID: identity.tabID)
        latestMCPSelectionRevisionByWorkspaceTab[key] = revision

        let peerHostIDs = Set(WindowStatesManager.shared.allWindows.compactMap { window -> UUID? in
            guard !window.isClosing else { return nil }
            let peer = window.workspaceManager
            guard peer !== self,
                  peer.composeTab(for: identity) != nil
            else { return nil }
            return peer.mcpSelectionPropagationHostID
        })
        return MCPSelectionPropagationRegistration(
            sourceRevision: revision,
            peerHostIDs: peerHostIDs
        )
    }

    func acceptMCPPeerSelectionRevision(_ revision: UInt64, for identity: WorkspaceSelectionIdentity) -> Bool {
        let key = WorkspaceTabSelectionKey(workspaceID: identity.workspaceID, tabID: identity.tabID)
        guard revision > latestMCPSelectionRevisionByWorkspaceTab[key, default: 0] else { return false }
        latestMCPSelectionRevisionByWorkspaceTab[key] = revision
        return true
    }

    func canCommitMCPSelectionPeerMutation(_ fence: MCPSelectionPeerMutationFence) -> Bool {
        guard fence.hostID == mcpSelectionPropagationHostID else { return false }
        return WindowStatesManager.shared.allWindows.contains { window in
            !window.isClosing && window.workspaceManager === self
        }
    }

    #if DEBUG
        struct ApplyEditsRebaseProbeSelectionSnapshot: Equatable {
            let workspaceID: UUID
            let tabID: UUID
            let selectionRevision: UInt64
            let ranges: [LineRange]
        }

        func debugStateVersionForWorkspace(_ workspaceID: UUID) -> Int {
            stateVersionByWorkspaceID[workspaceID, default: 0]
        }

        @MainActor
        func debugApplyEditsRebaseProbeSelectionSnapshot(
            workspaceID: UUID?,
            tabID: UUID,
            candidatePaths: [String]
        ) -> ApplyEditsRebaseProbeSelectionSnapshot? {
            guard let workspaceID,
                  let tab = composeTab(for: WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: tabID))
            else { return nil }
            let slices = StoredSelectionPathNormalization.standardizedSlices(tab.selection.slices)
            let candidates = candidatePaths.compactMap(StoredSelectionPathNormalization.standardizedPath)
            let ranges = candidates.lazy.compactMap { slices[$0] }.first ?? []
            return ApplyEditsRebaseProbeSelectionSnapshot(
                workspaceID: workspaceID,
                tabID: tabID,
                selectionRevision: selectionRevisionForMCP(workspaceID: workspaceID, tabID: tabID),
                ranges: ranges
            )
        }
    #endif

    func debugActiveSelectionRevisionForCurrentTab() -> UInt64 {
        let tabID = activeWorkspace?.activeComposeTabID ?? activeWorkspace?.composeTabs.first?.id
        guard let workspaceID = activeWorkspace?.id else { return 0 }
        return selectionRevision(workspaceID: workspaceID, tabID: tabID)
    }

    func selectionRevisionForMCP(workspaceID: UUID, tabID: UUID) -> UInt64 {
        selectionRevision(workspaceID: workspaceID, tabID: tabID)
    }

    private func selectionRevision(workspaceID: UUID, tabID: UUID?) -> UInt64 {
        guard let tabID else { return 0 }
        return selectionRevisionByWorkspaceTab[WorkspaceTabSelectionKey(workspaceID: workspaceID, tabID: tabID), default: 0]
    }

    private func recordSelectionRevisionIfChanged(
        workspaceIndex: Int,
        tabIndex: Int,
        oldSelection: StoredSelection,
        newSelection: StoredSelection,
        reason: String
    ) {
        guard oldSelection != newSelection,
              workspaces.indices.contains(workspaceIndex),
              workspaces[workspaceIndex].composeTabs.indices.contains(tabIndex)
        else { return }
        let workspace = workspaces[workspaceIndex]
        let tabID = workspaces[workspaceIndex].composeTabs[tabIndex].id
        let key = WorkspaceTabSelectionKey(workspaceID: workspace.id, tabID: tabID)
        let revision = Self.allocateWorkspaceSelectionRevision()
        selectionRevisionByWorkspaceTab[key] = revision
        revisedSelectionByWorkspaceTab[key] = newSelection
        #if DEBUG
            var fields: [String: String] = [
                "workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
                "workspaceName": workspace.name,
                "tabID": WorkspaceRestorePerfLog.shortID(tabID),
                "revision": "\(revision)",
                "reason": reason
            ]
            fields.merge(WorkspaceSaveSelectionSummary(tabID: tabID, selection: oldSelection).fields(prefix: "old")) { current, _ in current }
            fields.merge(WorkspaceSaveSelectionSummary(tabID: tabID, selection: newSelection).fields(prefix: "new")) { current, _ in current }
            WorkspaceRestorePerfLog.event("workspaceSave.selectionRevision.recorded", fields: fields)
        #endif
    }

    func markWorkspaceDirty() {
        bumpStateVersion(for: activeWorkspaceID)
    }

    /// Quick lookup cache replaced with index-based lookup
    private var workspaceIndexMap: [UUID: Int] = [:]
    /// Last root-path order this manager loaded from or saved to disk, by workspace.
    /// Used to distinguish local root edits from stale in-memory snapshots during full saves.
    private var lastSyncedRepoPathsByWorkspaceID: [UUID: [String]] = [:]
    private var pendingRepoPathSyncWorkspaceIDs: Set<UUID> = []

    /// Track if the active preset has diverged from its stored file selection
    @Published var activePresetIsDirty: Bool = false

    /// When true, the app will attempt to restore from ~/Downloads/RepoPrompt-Backup folder
    /// Gets set to false after successful restore to prevent future restores
    @AppStorage("shouldAutoRestoreFromDownloadsV2") var shouldAutoRestoreFromDownloads: Bool = true

    // Tracks whether initialization is complete
    private(set) var isInitialized = false
    private var initializationCallbacks: [() -> Void] = []
    private var switchingCompletionCallbacks: [() -> Void] = []

    /// Computed property to get/set the active workspace using the cache
    var activeWorkspace: WorkspaceModel? {
        get { workspace(withID: activeWorkspaceID) }
        set { activeWorkspaceID = newValue?.id }
    }

    /// Returns the workspace with the given identifier, if loaded.
    /// Uses index-based lookup for O(1) performance without duplication.
    func workspace(withID id: UUID?) -> WorkspaceModel? {
        guard let id, let idx = workspaceIndexMap[id], workspaces.indices.contains(idx) else { return nil }
        return workspaces[idx]
    }

    /// Returns the current index for a workspace ID, validating the cached map.
    /// Safe to call after `await` points where `workspaces` may have been mutated.
    private func workspaceIndex(for id: UUID) -> Int? {
        if let idx = workspaceIndexMap[id],
           workspaces.indices.contains(idx),
           workspaces[idx].id == id
        {
            return idx
        }
        // Fallback in case the map is temporarily stale
        return workspaces.firstIndex(where: { $0.id == id })
    }

    nonisolated static func normalizedRepoPathsForComparison(_ paths: [String]) -> [String] {
        paths.map { (($0 as NSString).standardizingPath).lowercased() }
    }

    nonisolated static func repoPathsEquivalent(_ lhs: [String], _ rhs: [String]) -> Bool {
        normalizedRepoPathsForComparison(lhs) == normalizedRepoPathsForComparison(rhs)
    }

    private func recordRepoPathBaseline(for workspace: WorkspaceModel) {
        lastSyncedRepoPathsByWorkspaceID[workspace.id] = workspace.repoPaths
    }

    private func recordRepoPathBaselines(for workspaces: [WorkspaceModel]) {
        for workspace in workspaces {
            recordRepoPathBaseline(for: workspace)
        }
    }

    private func hasLocalRepoPathEdit(for workspace: WorkspaceModel) -> Bool {
        guard let baseline = lastSyncedRepoPathsByWorkspaceID[workspace.id] else { return true }
        return !Self.repoPathsEquivalent(workspace.repoPaths, baseline)
    }

    private func drainPendingRepoPathSyncIfNeeded() {
        guard let activeWorkspaceID,
              pendingRepoPathSyncWorkspaceIDs.remove(activeWorkspaceID) != nil,
              let index = workspaceIndex(for: activeWorkspaceID),
              !isRefreshing,
              !isSwitchingWorkspace
        else { return }
        let workspace = workspaces[index]
        Task { @MainActor [weak self] in
            await self?.syncLoadedRootsWithWorkspace(workspace)
        }
    }

    nonisolated static func workspaceForSavePreservingDiskRepoPaths(
        current: WorkspaceModel,
        diskWorkspace: WorkspaceModel?,
        lastSyncedRepoPaths: [String]?,
        modificationDate: Date = Date()
    ) -> (workspace: WorkspaceModel, preservedDiskRepoPaths: Bool) {
        var merged = current
        let hasLocalRootPathEdit = lastSyncedRepoPaths.map { !repoPathsEquivalent(current.repoPaths, $0) } ?? true
        let diskRepoPathsDiffer = diskWorkspace.map { !repoPathsEquivalent($0.repoPaths, current.repoPaths) } == true
        let shouldPreserveDiskRepoPaths = !hasLocalRootPathEdit && diskRepoPathsDiffer

        if shouldPreserveDiskRepoPaths, let diskWorkspace {
            merged.repoPaths = diskWorkspace.repoPaths
        }
        merged.dateModified = modificationDate
        return (merged, shouldPreserveDiskRepoPaths)
    }

    /// A small sub-view-model (draft) for capturing "in-progress" workspace creation data
    @Published var creationDraft = WorkspaceCreationDraft()

    @Published var globalCustomStorageURL: URL? {
        didSet {
            if let url = globalCustomStorageURL {
                UserDefaults.standard.set(url.path, forKey: "GlobalCustomStorageURL")
            } else {
                UserDefaults.standard.removeObject(forKey: "GlobalCustomStorageURL")
            }
        }
    }

    private var currentBaseRoot: URL {
        globalCustomStorageURL ?? defaultWorkspaceRoot()
    }

    private var cancellables = Set<AnyCancellable>()
    private let composeTabSnapshotSubject = PassthroughSubject<ComposeTabState, Never>()

    let fileManager: WorkspaceFilesViewModel
    let promptViewModel: PromptViewModel
    let workspaceSearchService: WorkspaceSearchService
    private lazy var checkoutRefreshService = WorkspaceCheckoutRefreshService(
        store: fileManager.workspaceFileContextStore,
        searchService: workspaceSearchService
    )
    private weak var selectionCoordinator: WorkspaceSelectionCoordinator?

    var liveUISelectionRevision: UInt64 {
        fileManager.selectionStateRevision
    }

    @Published var isChatBusy: Bool = false
    @Published private(set) var tabsWithActiveChat: Set<UUID> = []
    @Published private(set) var pendingSwitchConfirmation: WorkspaceSwitchConfirmation?
    @Published private(set) var workspaceSwitchOverlayState: WorkspaceSwitchOverlayState?
    @Published private(set) var isWorkspaceSwitchOverlayVisible: Bool = false
    @Published private(set) var activeWorkspaceSwitch: WorkspaceSwitchActivity?
    @Published private(set) var lastWorkspaceSwitchBlockageReport: WorkspaceSwitchBlockageReport?
    @Published private(set) var pendingWorkspaceSwitchBlockedNotice: WorkspaceSwitchBlockedNotice?
    private let instanceID = UUID()

    private struct PendingSwitchConfirmationRequest {
        let operationID: UUID
        let confirmationID: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct WorkspaceSearchReadinessWaiter {
        let ticket: WorkspaceSearchReadinessTicket
        let continuation: CheckedContinuation<WorkspaceSearchReadinessTicket, any Error>
        let timeoutTask: Task<Void, Never>
    }

    private var pendingSwitchConfirmationRequest: PendingSwitchConfirmationRequest?
    private let switchSessionRegistry = WorkspaceSwitchSessionRegistry()
    private let switchTimingPolicy: WorkspaceSwitchTimingPolicy
    #if DEBUG
        private var workspaceSwitchPhaseDidChangeHandlerForTesting: ((WorkspaceSwitchPhase) -> Void)?
        private var workspaceSwitchRecoveryWillBeginHandlerForTesting: (@MainActor () async -> Void)?
        private var workspaceSwitchReadinessDidInvalidateHandlerForTesting: (@MainActor () async -> Void)?
        private var workspaceHydrationGenerationDidAdvanceHandlerForTesting: (@MainActor () -> Void)?
    #endif

    private struct WorkspaceDidSwitchListener {
        let label: String
        let listener: (WorkspaceModel?) -> Void
    }

    private struct WorkspaceRootHydrationResult {
        let request: WorkspaceRootLoadRequest
        let rootRecord: WorkspaceRootRecord?
        let failure: WorkspaceRootLoadFailure?
        let wasCancelled: Bool
    }

    #if DEBUG
        private struct WorkspaceOpenTrace {
            let id: UUID
            let managerID: UUID
            let previousWorkspaceID: UUID?
            let previousWorkspaceName: String
            let targetWorkspaceID: UUID
            let targetWorkspaceName: String
            let direction: String
            let switchStartMS: Double
            let expectedPrimaryRootCount: Int

            var overlayShownMS: Double?
            var loadWorkspaceFoldersStartMS: Double?
            var firstRootShellPossibleMS: Double?
            var allRootShellsPossibleMS: Double?
            var firstPrimaryRootVisibleMS: Double?
            var allPrimaryRootsVisibleMS: Double?
            var overlayHiddenMS: Double?
            var rootShellPossibleByRootID: [UUID: Double] = [:]
            var attachedPrimaryRootCount: Int = 0
            var failureCount: Int = 0
            var hideReason: String?
        }

        private var currentWorkspaceOpenTrace: WorkspaceOpenTrace?
        private var lastWorkspaceOpenTrace: WorkspaceOpenTrace?
    #endif

    private var workspaceDidSwitchListeners: [WorkspaceDidSwitchListener] = []

    /// Multiple callbacks that will be triggered before saving the active workspace
    private var beforeSaveListeners: [(WorkspaceModel) -> Void] = []
    private var composeTabApplyTask: Task<Void, Never>?
    private var composeTabApplyTaskID = UUID()

    func composeTabSnapshotPublisher() -> AnyPublisher<ComposeTabState, Never> {
        composeTabSnapshotSubject.eraseToAnyPublisher()
    }

    /// Returns a publisher that only emits snapshots for the specified tab ID
    func composeTabSnapshotPublisher(for tabID: UUID) -> AnyPublisher<ComposeTabState, Never> {
        composeTabSnapshotSubject
            .filter { $0.id == tabID }
            .eraseToAnyPublisher()
    }

    // ------------------------------------------------------------------
    // MARK: - Last-search-query Helpers

    // ------------------------------------------------------------------

    /// Returns the persisted last search query for the *active* workspace, or `nil`
    /// if none is present.
    func getLastSearchQuery() -> String? {
        activeWorkspace?.lastSearchQuery
    }

    /// Persists the given query string on the currently active workspace.
    /// No disk I/O is triggered here; the regular polling / save cycle will
    /// flush the change later.
    func setLastSearchQuery(_ query: String) {
        guard let activeId = activeWorkspaceID,
              let idx = workspaces.firstIndex(where: { $0.id == activeId })
        else { return }

        // Avoid needless mutations
        if workspaces[idx].lastSearchQuery != query {
            workspaces[idx].lastSearchQuery = query
            workspaces[idx].dateModified = Date()
            bumpStateVersion(for: activeId)
        }
    }

    @MainActor
    func setActiveChatTabs(_ tabIDs: Set<UUID>) {
        guard tabsWithActiveChat != tabIDs else { return }
        tabsWithActiveChat = tabIDs
    }

    var hasPendingSwitchConfirmation: Bool {
        pendingSwitchConfirmationRequest != nil
    }

    func registerSwitchSessionProvider(_ provider: any WorkspaceSwitchSessionProvider) {
        switchSessionRegistry.register(provider)
    }

    @MainActor
    func activeSessionSnapshot() -> WorkspaceSwitchSessionSnapshot {
        switchSessionRegistry.snapshot()
    }

    @MainActor
    func cancelActiveSessions() async {
        await switchSessionRegistry.cancelActiveSessions()
    }

    func addWorkspaceDidSwitchListener(_ listener: @escaping (WorkspaceModel?) -> Void) {
        addWorkspaceDidSwitchListener(label: "unknown", listener)
    }

    func addWorkspaceDidSwitchListener(label: String, _ listener: @escaping (WorkspaceModel?) -> Void) {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        workspaceDidSwitchListeners.append(
            WorkspaceDidSwitchListener(
                label: trimmedLabel.isEmpty ? "unknown" : trimmedLabel,
                listener: listener
            )
        )
    }

    /// Let other components register a "before save" hook
    func addBeforeSaveListener(_ listener: @escaping (WorkspaceModel) -> Void) {
        beforeSaveListeners.append(listener)
    }

    private func notifyWorkspaceDidSwitch(_ workspace: WorkspaceModel?) {
        for (index, listenerRecord) in workspaceDidSwitchListeners.enumerated() {
            #if DEBUG
                let listenerStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            #endif
            listenerRecord.listener(workspace)
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "workspaceSwitch.listener",
                    fields: [
                        "index": "\(index)",
                        "label": listenerRecord.label,
                        "workspaceID": WorkspaceRestorePerfLog.shortID(workspace?.id),
                        "hasWorkspace": "\(workspace != nil)",
                        "duration": listenerStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured",
                        "outcome": "completed"
                    ]
                )
            #endif
        }
    }

    /// Method to register a callback for when initialization is complete
    func onceInitialized(_ callback: @escaping () -> Void) {
        if isInitialized {
            // If already initialized, execute immediately
            callback()
        } else {
            // Store callbacks for later execution
            initializationCallbacks.append(callback)
        }
    }

    private func onceSwitchingComplete(_ callback: @escaping () -> Void) {
        if !isSwitchingWorkspace {
            callback()
        } else {
            switchingCompletionCallbacks.append(callback)
        }
    }

    /// Async helper to await initialization completion.
    func awaitInitialized() async {
        if isInitialized, !isSwitchingWorkspace { return }
        await withCheckedContinuation { continuation in
            onceInitialized { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                if !isSwitchingWorkspace {
                    continuation.resume()
                    return
                }
                onceSwitchingComplete {
                    continuation.resume()
                }
            }
        }
    }

    /// Method to mark initialization as complete and trigger callback
    private func completeInitialization() {
        guard !isInitialized else { return }

        isInitialized = true

        // Execute callbacks if any
        let callbacks = initializationCallbacks
        initializationCallbacks.removeAll()
        for callback in callbacks {
            callback()
        }
    }

    private func notifySwitchingComplete() {
        guard !switchingCompletionCallbacks.isEmpty else { return }
        let callbacks = switchingCompletionCallbacks
        switchingCompletionCallbacks.removeAll()
        for callback in callbacks {
            callback()
        }
    }

    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 30.0

    enum GitDataRootLoadMode {
        case inline
        case deferredAfterSwitch
    }

    private enum WorkspaceFolderInitialUnloadMode {
        case perform
        case skipPreviouslyCompleted
    }

    private(set) var isSwitchingWorkspace = false
    private nonisolated let workspaceSearchReadinessFence = WorkspaceSearchReadinessFence()
    @Published private(set) var workspaceSearchReadinessState: WorkspaceSearchReadinessState = .idle {
        didSet {
            let ticket = workspaceSearchReadinessState.isSearchAdmissible
                ? workspaceSearchReadinessState.ticket
                : nil
            workspaceSearchReadinessFence.publish(ticket)
            reconcileWorkspaceSearchReadinessWaiters()
        }
    }

    private var workspaceHydrationGeneration: UInt64 = 0
    private var workspaceSearchReadinessWaiters: [UUID: WorkspaceSearchReadinessWaiter] = [:]
    private var postCatalogRootWorkTasks: [UInt64: [Task<WorkspaceRootLoadFailure?, Never>]] = [:]
    private var returnToSystemAfterSwitchCancellationOperationID: UUID?
    private var committedWorkspaceSwitchOperationID: UUID?
    private var recoveringWorkspaceSwitchOperationID: UUID?
    private var rootsUnloadedWorkspaceSwitchOperationID: UUID?
    private var postSwitchGitDataLoadTask: Task<Void, Never>?
    private var postSwitchGitDataLoadToken: UUID?
    var isRefreshing: Bool = false
    // Tracked reload tasks and tokens
    private var reloadWorkspacesTask: Task<Void, Never>?
    private var reloadPresetsTask: Task<Void, Never>?
    private var reloadWorkspacesToken: UUID?
    private var reloadPresetsToken: UUID?

    // ------------------------------------------------------------------
    // MARK: - Change tracking / diff helpers

    // ------------------------------------------------------------------

    // MARK: - Files/Directories

    private var workspaceIndexFileURL: URL {
        currentBaseRoot.appendingPathComponent("workspacesIndex.json")
    }

    private func shouldShowWorkspaceSwitchOverlay(for workspace: WorkspaceModel) -> Bool {
        guard isInitialized else { return false }
        return !workspace.isSystemWorkspace
    }

    private func showWorkspaceSwitchOverlay(for workspace: WorkspaceModel) {
        workspaceSwitchOverlayState = WorkspaceSwitchOverlayState(
            targetWorkspaceName: workspace.name,
            startedAt: Date()
        )
        isWorkspaceSwitchOverlayVisible = true
        postWorkspaceSwitchOverlayChangeNotification()
        logWorkspaceSwitch("overlay shown workspace=\"\(workspace.name)\"")
        #if DEBUG
            debugRecordWorkspaceSwitchOverlayShown(for: workspace)
        #endif
    }

    private func hideWorkspaceSwitchOverlay(reason: String) {
        let wasVisible = isWorkspaceSwitchOverlayVisible || workspaceSwitchOverlayState != nil
        workspaceSwitchOverlayState = nil
        isWorkspaceSwitchOverlayVisible = false
        postWorkspaceSwitchOverlayChangeNotification()
        if wasVisible {
            logWorkspaceSwitch("overlay dismissed reason=\(reason)")
            #if DEBUG
                debugRecordWorkspaceSwitchOverlayHidden(reason: reason)
            #endif
        }
    }

    private func postWorkspaceSwitchOverlayChangeNotification() {
        NotificationCenter.default.post(
            name: .workspaceSwitchOverlayDidChange,
            object: self,
            userInfo: ["isVisible": isWorkspaceSwitchOverlayVisible]
        )
    }

    private static var isWorkspaceSwitchLoggingEnabled: Bool {
        UserDefaults.standard.bool(forKey: "enableWorkspaceSwitchLogging")
    }

    private func logWorkspaceSwitch(_ message: String) {
        guard Self.isWorkspaceSwitchLoggingEnabled else { return }
        Self.logger.debug("\(message)")
    }

    #if DEBUG
        private func debugStartWorkspaceOpenTrace(
            targetWorkspace: WorkspaceModel,
            previousWorkspace: WorkspaceModel?,
            switchStartMS: Double
        ) {
            let previousName = previousWorkspace?.name ?? "nil"
            let expectedPrimaryRootCount = uniqueWorkspaceRootLoadRequests(
                for: Self.loadableRepoPaths(for: targetWorkspace)
            ).count
            currentWorkspaceOpenTrace = WorkspaceOpenTrace(
                id: UUID(),
                managerID: instanceID,
                previousWorkspaceID: previousWorkspace?.id,
                previousWorkspaceName: previousName,
                targetWorkspaceID: targetWorkspace.id,
                targetWorkspaceName: targetWorkspace.name,
                direction: "\(previousName)->\(targetWorkspace.name)",
                switchStartMS: switchStartMS,
                expectedPrimaryRootCount: expectedPrimaryRootCount
            )
        }

        private func debugFinishWorkspaceOpenTrace() {
            if let trace = currentWorkspaceOpenTrace {
                lastWorkspaceOpenTrace = trace
            }
            currentWorkspaceOpenTrace = nil
        }

        private func debugWorkspaceOpenTraceFields() -> [String: String] {
            guard let trace = currentWorkspaceOpenTrace else { return [:] }
            return [
                "workspaceSwitchID": trace.id.uuidString,
                "workspaceSwitchDirection": trace.direction,
                "managerID": String(trace.managerID.uuidString.prefix(8)),
                "targetWorkspaceID": WorkspaceRestorePerfLog.shortID(trace.targetWorkspaceID),
                "targetWorkspaceName": trace.targetWorkspaceName,
                "expectedPrimaryRoots": "\(trace.expectedPrimaryRootCount)"
            ]
        }

        private func debugDurationSinceSwitchBegin(_ nowMS: Double, trace: WorkspaceOpenTrace) -> String {
            WorkspaceRestorePerfLog.formatMS(nowMS - trace.switchStartMS)
        }

        private func debugDurationSinceLoadWorkspaceFoldersBegin(_ nowMS: Double, trace: WorkspaceOpenTrace) -> String {
            trace.loadWorkspaceFoldersStartMS.map { WorkspaceRestorePerfLog.formatMS(nowMS - $0) } ?? "notMeasured"
        }

        private func debugWorkspaceSearchReadinessStateName() -> String {
            switch workspaceSearchReadinessState {
            case .idle:
                "idle"
            case .activating:
                "activating"
            case .loadingCatalog:
                "loadingCatalog"
            case .buildingIndexes:
                "buildingIndexes"
            case .ready:
                "ready"
            case .degraded:
                "degraded"
            }
        }

        private func debugRecordWorkspaceSwitchOverlayShown(for workspace: WorkspaceModel) {
            guard var trace = currentWorkspaceOpenTrace else { return }
            let nowMS = WorkspaceRestorePerfLog.timestampMS()
            trace.overlayShownMS = nowMS
            currentWorkspaceOpenTrace = trace
            var fields = debugWorkspaceOpenTraceFields()
            fields["workspaceID"] = WorkspaceRestorePerfLog.shortID(workspace.id)
            fields["workspaceName"] = workspace.name
            fields["durationSinceSwitchBegin"] = debugDurationSinceSwitchBegin(nowMS, trace: trace)
            WorkspaceRestorePerfLog.event("workspaceSwitch.overlay.shown", fields: fields)
        }

        private func debugRecordWorkspaceSwitchOverlayHidden(reason: String) {
            guard var trace = currentWorkspaceOpenTrace else { return }
            let nowMS = WorkspaceRestorePerfLog.timestampMS()
            trace.overlayHiddenMS = nowMS
            trace.hideReason = reason
            currentWorkspaceOpenTrace = trace
            lastWorkspaceOpenTrace = trace
            var fields = debugWorkspaceOpenTraceFields()
            fields["reason"] = reason
            fields["durationSinceSwitchBegin"] = debugDurationSinceSwitchBegin(nowMS, trace: trace)
            fields["visibleDuration"] = trace.overlayShownMS.map { WorkspaceRestorePerfLog.formatMS(nowMS - $0) } ?? "notMeasured"
            fields["durationAfterAllPrimaryRootsVisible"] = trace.allPrimaryRootsVisibleMS.map { WorkspaceRestorePerfLog.formatMS(nowMS - $0) } ?? "notAvailable"
            fields["allPrimaryRootsVisible"] = "\(trace.allPrimaryRootsVisibleMS != nil)"
            fields["attachedPrimaryRoots"] = "\(trace.attachedPrimaryRootCount)"
            fields["failureCount"] = "\(trace.failureCount)"
            fields["readinessState"] = debugWorkspaceSearchReadinessStateName()
            WorkspaceRestorePerfLog.event("workspaceSwitch.overlay.hidden", fields: fields)
        }

        private func debugRecordLoadWorkspaceFoldersStart(for workspace: WorkspaceModel) {
            guard var trace = currentWorkspaceOpenTrace else { return }
            let nowMS = WorkspaceRestorePerfLog.timestampMS()
            trace.loadWorkspaceFoldersStartMS = nowMS
            currentWorkspaceOpenTrace = trace
            var fields = debugWorkspaceOpenTraceFields()
            fields["workspaceID"] = WorkspaceRestorePerfLog.shortID(workspace.id)
            fields["workspaceName"] = workspace.name
            fields["durationSinceSwitchBegin"] = debugDurationSinceSwitchBegin(nowMS, trace: trace)
            WorkspaceRestorePerfLog.event("workspaceSwitch.loadWorkspaceFolders.traceStart", fields: fields)
        }

        private func debugRootLoadContext(
            workspace: WorkspaceModel,
            hydrationGeneration: UInt64,
            request: WorkspaceRootLoadRequest
        ) -> WorkspaceRootLoadDiagnostics.Context? {
            guard let trace = currentWorkspaceOpenTrace else { return nil }
            return WorkspaceRootLoadDiagnostics.Context(
                workspaceSwitchID: trace.id,
                workspaceID: workspace.id,
                generation: hydrationGeneration,
                rootIndex: request.rootIndex,
                rootName: request.rootName,
                switchStartMS: trace.switchStartMS,
                loadWorkspaceFoldersStartMS: trace.loadWorkspaceFoldersStartMS
            )
        }

        private func debugRecordUserRootLoadStart(
            workspace: WorkspaceModel,
            hydrationGeneration: UInt64,
            request: WorkspaceRootLoadRequest
        ) {
            guard let trace = currentWorkspaceOpenTrace else { return }
            let nowMS = WorkspaceRestorePerfLog.timestampMS()
            var fields = debugWorkspaceOpenTraceFields()
            fields["workspaceID"] = WorkspaceRestorePerfLog.shortID(workspace.id)
            fields["workspaceName"] = workspace.name
            fields["generation"] = "\(hydrationGeneration)"
            fields["rootIndex"] = "\(request.rootIndex)"
            fields["rootName"] = request.rootName
            fields["durationSinceSwitchBegin"] = debugDurationSinceSwitchBegin(nowMS, trace: trace)
            fields["durationSinceLoadWorkspaceFoldersBegin"] = debugDurationSinceLoadWorkspaceFoldersBegin(nowMS, trace: trace)
            WorkspaceRestorePerfLog.event("workspaceSwitch.loadWorkspaceFolders.userRootLoad.start", fields: fields)
        }

        private func debugRecordRootShellPossible(
            workspace: WorkspaceModel,
            hydrationGeneration: UInt64,
            request: WorkspaceRootLoadRequest,
            rootRecord: WorkspaceRootRecord
        ) {
            guard var trace = currentWorkspaceOpenTrace else { return }
            let nowMS = WorkspaceRestorePerfLog.timestampMS()
            if trace.firstRootShellPossibleMS == nil {
                trace.firstRootShellPossibleMS = nowMS
            }
            trace.rootShellPossibleByRootID[rootRecord.id] = nowMS
            if trace.rootShellPossibleByRootID.count >= trace.expectedPrimaryRootCount {
                trace.allRootShellsPossibleMS = nowMS
            }
            currentWorkspaceOpenTrace = trace

            var fields = debugWorkspaceOpenTraceFields()
            fields["workspaceID"] = WorkspaceRestorePerfLog.shortID(workspace.id)
            fields["workspaceName"] = workspace.name
            fields["generation"] = "\(hydrationGeneration)"
            fields["rootIndex"] = "\(request.rootIndex)"
            fields["rootName"] = request.rootName
            fields["rootID"] = WorkspaceRestorePerfLog.shortID(rootRecord.id)
            fields["catalogCompleteAtPossible"] = "true"
            fields["possiblePrimaryRoots"] = "\(trace.rootShellPossibleByRootID.count)"
            fields["expectedPrimaryRoots"] = "\(trace.expectedPrimaryRootCount)"
            fields["durationSinceSwitchBegin"] = debugDurationSinceSwitchBegin(nowMS, trace: trace)
            fields["durationSinceLoadWorkspaceFoldersBegin"] = debugDurationSinceLoadWorkspaceFoldersBegin(nowMS, trace: trace)
            WorkspaceRestorePerfLog.event("workspaceSwitch.loadWorkspaceFolders.rootShellPossible", fields: fields)
        }

        private func debugRecordRootShellAttach(
            workspace: WorkspaceModel,
            rootRecord: WorkspaceRootRecord?,
            request: WorkspaceRootLoadRequest,
            attachedPrimaryRoots: Int,
            failureCount: Int,
            attachDurationMS: Double?,
            outcome: String,
            error: String? = nil
        ) {
            guard var trace = currentWorkspaceOpenTrace else { return }
            let nowMS = WorkspaceRestorePerfLog.timestampMS()
            trace.attachedPrimaryRootCount = attachedPrimaryRoots
            trace.failureCount = failureCount
            currentWorkspaceOpenTrace = trace

            var fields = debugWorkspaceOpenTraceFields()
            fields["workspaceID"] = WorkspaceRestorePerfLog.shortID(workspace.id)
            fields["workspaceName"] = workspace.name
            fields["rootIndex"] = "\(request.rootIndex)"
            fields["rootName"] = request.rootName
            fields["rootID"] = WorkspaceRestorePerfLog.shortID(rootRecord?.id)
            fields["attachedPrimaryRoots"] = "\(attachedPrimaryRoots)"
            fields["visibleRootCount"] = "\(fileManager.visibleRootFolders.count)"
            fields["expectedRootCount"] = "\(trace.expectedPrimaryRootCount)"
            fields["failureCount"] = "\(failureCount)"
            fields["durationSinceSwitchBegin"] = debugDurationSinceSwitchBegin(nowMS, trace: trace)
            fields["durationSinceLoadWorkspaceFoldersBegin"] = debugDurationSinceLoadWorkspaceFoldersBegin(nowMS, trace: trace)
            fields["attachDuration"] = attachDurationMS.map(WorkspaceRestorePerfLog.formatMS) ?? "notMeasured"
            fields["attachMode"] = "barrier"
            fields["catalogCompleteAtAttach"] = "true"
            fields["rootShellPossibleGap"] = rootRecord.flatMap { trace.rootShellPossibleByRootID[$0.id] }.map { WorkspaceRestorePerfLog.formatMS(nowMS - $0) } ?? "notMeasured"
            fields["outcome"] = outcome
            if let error {
                fields["error"] = error
            }
            WorkspaceRestorePerfLog.event("workspaceSwitch.loadWorkspaceFolders.rootShellAttach", fields: fields)

            if outcome == "success", trace.firstPrimaryRootVisibleMS == nil {
                trace.firstPrimaryRootVisibleMS = nowMS
                currentWorkspaceOpenTrace = trace
                var firstFields = fields
                firstFields["durationSinceSwitchBegin"] = debugDurationSinceSwitchBegin(nowMS, trace: trace)
                firstFields["durationSinceLoadWorkspaceFoldersBegin"] = debugDurationSinceLoadWorkspaceFoldersBegin(nowMS, trace: trace)
                WorkspaceRestorePerfLog.event("workspaceSwitch.loadWorkspaceFolders.firstPrimaryRootVisible", fields: firstFields)
            }
        }

        private func debugRecordAllPrimaryRootsVisible(
            workspace: WorkspaceModel,
            hydrationGeneration: UInt64,
            attachedPrimaryRoots: Int,
            expectedPrimaryRoots: Int,
            failureCount: Int,
            rootAttachLoopDurationMS: Double?,
            reorderChanged: Bool
        ) {
            guard var trace = currentWorkspaceOpenTrace else { return }
            let nowMS = WorkspaceRestorePerfLog.timestampMS()
            trace.attachedPrimaryRootCount = attachedPrimaryRoots
            trace.failureCount = failureCount
            trace.allPrimaryRootsVisibleMS = nowMS
            currentWorkspaceOpenTrace = trace
            var fields = debugWorkspaceOpenTraceFields()
            fields["workspaceID"] = WorkspaceRestorePerfLog.shortID(workspace.id)
            fields["workspaceName"] = workspace.name
            fields["generation"] = "\(hydrationGeneration)"
            fields["attachedPrimaryRoots"] = "\(attachedPrimaryRoots)"
            fields["expectedPrimaryRoots"] = "\(expectedPrimaryRoots)"
            fields["failureCount"] = "\(failureCount)"
            fields["durationSinceSwitchBegin"] = debugDurationSinceSwitchBegin(nowMS, trace: trace)
            fields["durationSinceLoadWorkspaceFoldersBegin"] = debugDurationSinceLoadWorkspaceFoldersBegin(nowMS, trace: trace)
            fields["rootAttachLoopDuration"] = rootAttachLoopDurationMS.map(WorkspaceRestorePerfLog.formatMS) ?? "notMeasured"
            fields["reorderChanged"] = "\(reorderChanged)"
            fields["outcome"] = (attachedPrimaryRoots == expectedPrimaryRoots && failureCount == 0) ? "success" : "incomplete"
            WorkspaceRestorePerfLog.event("workspaceSwitch.loadWorkspaceFolders.allPrimaryRootsVisible", fields: fields)

            var summaryFields = fields
            summaryFields["firstRootShellPossibleDuration"] = trace.firstRootShellPossibleMS.map { WorkspaceRestorePerfLog.formatMS($0 - trace.switchStartMS) } ?? "notMeasured"
            summaryFields["allRootShellsPossibleDuration"] = trace.allRootShellsPossibleMS.map { WorkspaceRestorePerfLog.formatMS($0 - trace.switchStartMS) } ?? "notMeasured"
            summaryFields["firstRootShellVisibleDuration"] = trace.firstPrimaryRootVisibleMS.map { WorkspaceRestorePerfLog.formatMS($0 - trace.switchStartMS) } ?? "notMeasured"
            summaryFields["allRootShellsVisibleDuration"] = WorkspaceRestorePerfLog.formatMS(nowMS - trace.switchStartMS)
            let firstPossibleToVisibleGap: String = if let possible = trace.firstRootShellPossibleMS, let visible = trace.firstPrimaryRootVisibleMS {
                WorkspaceRestorePerfLog.formatMS(visible - possible)
            } else {
                "notMeasured"
            }
            summaryFields["firstRootShellPossibleToVisibleGap"] = firstPossibleToVisibleGap
            summaryFields["allRootShellsPossibleToVisibleGap"] = trace.allRootShellsPossibleMS.map { WorkspaceRestorePerfLog.formatMS(nowMS - $0) } ?? "notMeasured"
            summaryFields["catalogCompleteAtAllVisible"] = "true"
            summaryFields["attachMode"] = "barrier"
            summaryFields["rootCatalogFailedAfterVisible"] = "false"
            WorkspaceRestorePerfLog.event("workspaceSwitch.loadWorkspaceFolders.rootVisibilitySummary", fields: summaryFields)
        }

        private func debugRebuildSearchIndex(
            from snapshot: WorkspaceSearchCatalogSnapshot,
            workspace: WorkspaceModel,
            hydrationGeneration: UInt64
        ) async -> (generation: UInt64, durationMS: Double?) {
            let startMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            let indexedGeneration = await workspaceSearchService.rebuildIndex(from: snapshot)
            let durationMS = startMS.map { WorkspaceRestorePerfLog.elapsedMS(since: $0) }
            WorkspaceRestorePerfLog.event(
                "workspaceSwitch.searchIndexRebuild.end",
                fields: debugWorkspaceOpenTraceFields().merging([
                    "workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
                    "generation": "\(hydrationGeneration)",
                    "catalogGeneration": "\(snapshot.generation)",
                    "indexedGeneration": "\(indexedGeneration)",
                    "indexedPathCount": "\(snapshot.entries.count)",
                    "duration": durationMS.map(WorkspaceRestorePerfLog.formatMS) ?? "notMeasured"
                ], uniquingKeysWith: { _, new in new })
            )
            return (indexedGeneration, durationMS)
        }

        private func debugWarmPathLookupIndexes(
            workspace: WorkspaceModel,
            hydrationGeneration: UInt64,
            catalogGeneration: UInt64
        ) async -> (generation: UInt64, durationMS: Double?) {
            let startMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            let warmedGeneration = await fileManager.workspaceFileContextStore.warmPathLookupIndexes(rootScope: .visibleWorkspace)
            let durationMS = startMS.map { WorkspaceRestorePerfLog.elapsedMS(since: $0) }
            WorkspaceRestorePerfLog.event(
                "workspaceSwitch.pathLookupWarm.end",
                fields: debugWorkspaceOpenTraceFields().merging([
                    "workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
                    "generation": "\(hydrationGeneration)",
                    "catalogGeneration": "\(catalogGeneration)",
                    "warmedGeneration": "\(warmedGeneration)",
                    "duration": durationMS.map(WorkspaceRestorePerfLog.formatMS) ?? "notMeasured"
                ], uniquingKeysWith: { _, new in new })
            )
            return (warmedGeneration, durationMS)
        }

        func debugWorkspaceOpenTraceSnapshot() -> [String: Any] {
            func optionalValue(_ value: (some Any)?) -> Any {
                value.map { $0 as Any } ?? NSNull()
            }

            func payload(_ trace: WorkspaceOpenTrace?) -> Any {
                guard let trace else { return NSNull() }
                let nowMS = WorkspaceRestorePerfLog.timestampMS()
                let overlayVisibleMS: Any = if let hidden = trace.overlayHiddenMS, let shown = trace.overlayShownMS {
                    WorkspaceRestorePerfLog.formatMS(hidden - shown)
                } else if let shown = trace.overlayShownMS {
                    WorkspaceRestorePerfLog.formatMS(nowMS - shown)
                } else {
                    NSNull()
                }
                let overlayClearAfterAllRootsMS: Any = if let hidden = trace.overlayHiddenMS, let allRoots = trace.allPrimaryRootsVisibleMS {
                    WorkspaceRestorePerfLog.formatMS(hidden - allRoots)
                } else {
                    NSNull()
                }
                return [
                    "workspace_switch_id": trace.id.uuidString,
                    "direction": trace.direction,
                    "previous_workspace_id": optionalValue(trace.previousWorkspaceID?.uuidString),
                    "previous_workspace_name": trace.previousWorkspaceName,
                    "target_workspace_id": trace.targetWorkspaceID.uuidString,
                    "target_workspace_name": trace.targetWorkspaceName,
                    "expected_primary_roots": trace.expectedPrimaryRootCount,
                    "attached_primary_roots": trace.attachedPrimaryRootCount,
                    "failure_count": trace.failureCount,
                    "overlay_visible_ms": overlayVisibleMS,
                    "first_primary_root_visible_ms": optionalValue(trace.firstPrimaryRootVisibleMS.map { WorkspaceRestorePerfLog.formatMS($0 - trace.switchStartMS) }),
                    "all_primary_roots_visible_ms": optionalValue(trace.allPrimaryRootsVisibleMS.map { WorkspaceRestorePerfLog.formatMS($0 - trace.switchStartMS) }),
                    "overlay_clear_after_all_roots_ms": overlayClearAfterAllRootsMS,
                    "hide_reason": optionalValue(trace.hideReason)
                ]
            }

            return [
                "current": payload(currentWorkspaceOpenTrace),
                "last_completed": payload(lastWorkspaceOpenTrace)
            ]
        }
    #endif

    // Removed - now using free function defaultWorkspaceRoot()

    nonisolated func directoryName(for workspace: WorkspaceModel) -> String {
        let safeName = workspace.name
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "Workspace-\(safeName)-\(workspace.id.uuidString)"
    }

    func workspaceDirectory(for workspace: WorkspaceModel) -> URL {
        workspaceDirectory(for: workspace, baseRoot: currentBaseRoot)
    }

    nonisolated func workspaceDirectory(for workspace: WorkspaceModel, baseRoot: URL) -> URL {
        // ➊ Honour per-workspace override first
        if let customRoot = workspace.customStoragePath {
            return customRoot
        }

        // ➋ Fall back to global custom storage set by the user or the default location
        return baseRoot.appendingPathComponent(directoryName(for: workspace))
    }

    func workspaceFileURL(for workspace: WorkspaceModel) -> URL {
        workspaceFileURL(for: workspace, baseRoot: currentBaseRoot)
    }

    nonisolated func workspaceFileURL(for workspace: WorkspaceModel, baseRoot: URL) -> URL {
        workspaceDirectory(for: workspace, baseRoot: baseRoot).appendingPathComponent("workspace.json")
    }

    nonisolated func chatsFolder(for workspace: WorkspaceModel, baseRoot: URL) -> URL {
        workspaceDirectory(for: workspace, baseRoot: baseRoot)
            .appendingPathComponent("Chats", isDirectory: true)
    }

    func gitDataDirectory(for workspace: WorkspaceModel) -> URL {
        gitDataDirectory(for: workspace, baseRoot: currentBaseRoot)
    }

    nonisolated func gitDataDirectory(for workspace: WorkspaceModel, baseRoot: URL) -> URL {
        workspaceDirectory(for: workspace, baseRoot: baseRoot)
            .appendingPathComponent("_git_data", isDirectory: true)
    }

    func gitDataTabDirectory(for workspace: WorkspaceModel, tabID: UUID) -> URL {
        gitDataTabDirectory(for: workspace, tabID: tabID, baseRoot: currentBaseRoot)
    }

    nonisolated func gitDataTabDirectory(for workspace: WorkspaceModel, tabID: UUID, baseRoot: URL) -> URL {
        gitDataDirectory(for: workspace, baseRoot: baseRoot)
            .appendingPathComponent(tabID.uuidString, isDirectory: true)
    }

    private nonisolated func ensureBaseRootExists(at baseRoot: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: baseRoot.path) {
            try fm.createDirectory(at: baseRoot, withIntermediateDirectories: true)
        }
    }

    // MARK: - Init / Deinit

    init(
        fileManager: WorkspaceFilesViewModel,
        promptViewModel: PromptViewModel,
        workspaceSearchService: WorkspaceSearchService = WorkspaceSearchService(),
        switchTimingPolicy: WorkspaceSwitchTimingPolicy = .production,
        performInitialWorkspaceActivation: Bool = true
    ) {
        #if DEBUG
            let initStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        self.fileManager = fileManager
        self.promptViewModel = promptViewModel
        self.workspaceSearchService = workspaceSearchService
        self.switchTimingPolicy = switchTimingPolicy
        self.promptViewModel.attachWorkspaceManager(self)
        self.fileManager.setWorkspaceManager(self)

        if let path = UserDefaults.standard.string(forKey: "GlobalCustomStorageURL") {
            globalCustomStorageURL = URL(fileURLWithPath: path)
        }

        // Track when the file selection changes to detect if active preset is dirty
        fileManager.$selectedFiles
            // Debounce to avoid rapid consecutive events
            .debounce(for: .seconds(0.15), scheduler: DispatchQueue.main)
            .sink { [weak self] newSelection in
                guard let self, !self.isSwitchingWorkspace else { return }
                checkIfActivePresetIsDirty(with: newSelection)
                bumpStateVersion(for: activeWorkspaceID)
                // No disk save here - publish in-memory snapshot for mirroring
                publishActiveComposeTabSnapshot(commitToMemory: true)
            }
            .store(in: &cancellables)

        fileManager.$codemapAutoEnabled
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, !self.isSwitchingWorkspace else { return }
                bumpStateVersion(for: activeWorkspaceID)
                // No disk save here - publish in-memory snapshot for mirroring
                publishActiveComposeTabSnapshot(commitToMemory: true)
            }
            .store(in: &cancellables)

        promptViewModel.$promptText
            .removeDuplicates()
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.isSwitchingWorkspace else { return }
                bumpStateVersion(for: activeWorkspaceID)
                // No disk save here - publish in-memory snapshot for mirroring
                publishActiveComposeTabSnapshot(commitToMemory: true)
            }
            .store(in: &cancellables)

        // Track slice changes so run-scoped MCP "get" sees cleared/updated slices.
        // Without this, clearing slices in the UI wouldn't propagate to the compose-tab
        // snapshot, causing stale slices to reappear in mirrored tab contexts.
        fileManager.$selectionSlicesByFileID
            .removeDuplicates()
            .debounce(for: .milliseconds(60), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.isSwitchingWorkspace else { return }
                bumpStateVersion(for: activeWorkspaceID)
                // Commit to memory so composeTab(with:) reflects the new slice state immediately.
                publishActiveComposeTabSnapshot(commitToMemory: true)
            }
            .store(in: &cancellables)

        #if DEBUG
            let indexLoadStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        let indexEntries = loadWorkspaceIndex()
        #if DEBUG
            let indexLoadDurationMS = indexLoadStartMS.map { WorkspaceRestorePerfLog.elapsedMS(since: $0) }
            let decodeStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            var decodedWorkspaceCount = 0
            var workspaceDecodeCacheHitCount = 0
            var missingWorkspaceFileCount = 0
            var failedWorkspaceDecodeCount = 0
            var composeTabNormalizationCount = 0
            var normalizationSaveBackCount = 0
        #endif
        var loaded = [WorkspaceModel]()
        let base = currentBaseRoot

        for entry in indexEntries {
            do {
                let wURL: URL
                if let customURL = entry.customStoragePath {
                    wURL = customURL.appendingPathComponent("workspace.json")
                } else {
                    let folder = base.appendingPathComponent("Workspace-\(entry.name)-\(entry.id.uuidString)")
                    wURL = folder.appendingPathComponent("workspace.json")
                }

                if FileManager.default.fileExists(atPath: wURL.path) {
                    let loadResult = try Self.loadWorkspaceFromFileResult(at: wURL)
                    let ws = loadResult.workspace
                    #if DEBUG
                        decodedWorkspaceCount += 1
                        if loadResult.cacheHit { workspaceDecodeCacheHitCount += 1 }
                        if loadResult.composeTabsNormalized { composeTabNormalizationCount += 1 }
                        if loadResult.normalizationRequiresSave { normalizationSaveBackCount += 1 }
                    #endif
                    loaded.append(ws)
                } else {
                    #if DEBUG
                        missingWorkspaceFileCount += 1
                    #endif
                    print("No workspace.json found for \(entry.name) at \(wURL.path)")
                }
            } catch {
                #if DEBUG
                    failedWorkspaceDecodeCount += 1
                #endif
                print("Error loading workspace from new scheme: \(error)")
            }
        }
        #if DEBUG
            if let initStartMS {
                let indexDuration = indexLoadDurationMS.map(WorkspaceRestorePerfLog.formatMS) ?? "notMeasured"
                let decodeDuration = decodeStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                WorkspaceRestorePerfLog.log(
                    "workspaceManager.init managerID=\(instanceID.uuidString.prefix(8)) indexEntries=\(indexEntries.count) decoded=\(decodedWorkspaceCount) decodeCacheHits=\(workspaceDecodeCacheHitCount) missingFiles=\(missingWorkspaceFileCount) decodeFailures=\(failedWorkspaceDecodeCount) composeTabNormalizations=\(composeTabNormalizationCount) normalizationSaveBacks=\(normalizationSaveBackCount) indexLoad=\(indexDuration) decodeAndMigration=\(decodeDuration) totalBeforeDefaultSwitch=\(WorkspaceRestorePerfLog.formatElapsedMS(since: initStartMS))"
                )
            }
        #endif
        workspaces = loaded
        recordRepoPathBaselines(for: loaded)

        startPollTimer()

        fileManager.allFoldersUnloadedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleAllFoldersUnloaded()
            }
            .store(in: &cancellables)

        // Listen for workspace list changes from other windows
        NotificationCenter.default.publisher(for: .workspaceListDidChange)
            .sink { [weak self] notification in
                guard
                    let self,
                    let senderID = notification.userInfo?["managerID"] as? UUID,
                    senderID != instanceID
                else { return }
                reloadWorkspacesFromDisk()
            }
            .store(in: &cancellables)

        // Listen for workspace root-path changes from other windows without replacing local unsaved workspace state.
        NotificationCenter.default.publisher(for: .workspaceRepoPathsDidChange)
            .sink { [weak self] notification in
                guard
                    let self,
                    let senderID = notification.userInfo?["managerID"] as? UUID,
                    senderID != instanceID,
                    let workspaceID = notification.userInfo?["workspaceID"] as? UUID
                else { return }
                Task { @MainActor [weak self] in
                    await self?.mergeRepoPathsFromDisk(for: workspaceID)
                }
            }
            .store(in: &cancellables)

        // Listen for preset changes from other windows
        NotificationCenter.default.publisher(for: .workspacePresetsDidChange)
            .sink { [weak self] notification in
                guard
                    let self,
                    let senderID = notification.userInfo?["managerID"] as? UUID,
                    senderID != instanceID
                else { return }
                reloadPresetsFromDisk()
            }
            .store(in: &cancellables)

        self.fileManager.onRequestRefresh = { [weak self] in
            Task {
                guard let self, let activeWS = self.activeWorkspace else { return }
                await self.refreshWorkspace(soft: true, for: activeWS)
            }
        }

        if !performInitialWorkspaceActivation {
            completeInitialization()
        } else if activeWorkspace == nil {
            if let defaultWS = findOrCreateDefaultWorkspace() {
                Task {
                    await switchWorkspace(to: defaultWS, saveState: false)
                    self.completeInitialization()
                }
            }
        } else {
            // Already has an active workspace
            completeInitialization()
        }
    }

    deinit {
        pollTimer?.invalidate()
        pollTimer = nil
        reloadWorkspacesTask?.cancel()
        reloadPresetsTask?.cancel()
        composeTabApplyTask?.cancel()
        for tasks in postCatalogRootWorkTasks.values {
            tasks.forEach { $0.cancel() }
        }
        postCatalogRootWorkTasks.removeAll()
    }

    func prepareForWindowClose() {
        stopPollTimer()
        reloadWorkspacesTask?.cancel()
        reloadWorkspacesTask = nil
        reloadPresetsTask?.cancel()
        reloadPresetsTask = nil
        composeTabApplyTask?.cancel()
        composeTabApplyTask = nil
        postSwitchGitDataLoadTask?.cancel()
        postSwitchGitDataLoadTask = nil
        for tasks in postCatalogRootWorkTasks.values {
            tasks.forEach { $0.cancel() }
        }
        postCatalogRootWorkTasks.removeAll()
        cancellables.removeAll()
    }

    #if DEBUG
        var test_isPollTimerActive: Bool {
            pollTimer?.isValid == true
        }
    #endif

    // MARK: - Private Timer Control

    private func startPollTimer() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }

                // Skip while switching workspaces or performing a refresh
                if isSwitchingWorkspace || isRefreshing { return }

                // Check if multiple windows have the same workspace open
                // Only check if we have a valid activeWorkspaceID
                if let activeWorkspaceID {
                    // Safely access WindowStatesManager
                    let windowCount = WindowStatesManager.shared.countWindowsShowing(workspaceId: activeWorkspaceID)
                    if windowCount > 1 {
                        // Skip auto-save when multiple windows have the same workspace
                        return
                    }
                }

                // Capture current state (expanded folders, selected files, prompt, etc.)
                // and persist it in one atomic call.
                await pollAndSaveStateAsync(source: .pollTimer)
            }
        }
    }

    private func stopPollTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - INDEX LOAD/SAVE

    private func loadWorkspaceIndex() -> [WorkspaceIndexEntry] {
        Self.loadWorkspaceIndex(from: workspaceIndexFileURL)
    }

    private nonisolated static func loadWorkspaceIndex(from indexURL: URL) -> [WorkspaceIndexEntry] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }

        do {
            let data = try Data(contentsOf: indexURL)
            return try JSONDecoder().decode([WorkspaceIndexEntry].self, from: data)
        } catch {
            print("Failed to load workspaceIndex.json: \(error)")
            return []
        }
    }

    private func saveWorkspaceIndex(_ entries: [WorkspaceIndexEntry]) throws {
        try ensureBaseRootExists(at: currentBaseRoot)
        let data = try JSONEncoder().encode(entries)
        try data.write(to: workspaceIndexFileURL, options: .atomic)
    }

    private func saveWorkspaceIndexAsync(_ entries: [WorkspaceIndexEntry]) async throws {
        try ensureBaseRootExists(at: currentBaseRoot)
        let data = try JSONEncoder().encode(entries)
        await WorkspaceDiskWriter.shared.enqueue(data: data, url: workspaceIndexFileURL)
    }

    /// Reloads the workspace list from disk, preserving the active workspace
    func reloadWorkspacesFromDisk() {
        let currentActiveID = activeWorkspaceID
        let base = currentBaseRoot
        let indexURL = workspaceIndexFileURL

        // Cancel any existing task and start a fresh one
        reloadWorkspacesTask?.cancel()
        let token = UUID()
        reloadWorkspacesToken = token

        reloadWorkspacesTask = Task.detached(priority: .utility) { [weak self, indexURL, base, currentActiveID, token] in
            let indexEntries = Self.loadWorkspaceIndex(from: indexURL)
            var loadedMutable: [WorkspaceModel] = []

            for entry in indexEntries {
                if Task.isCancelled { return }

                let wURL: URL
                if let customURL = entry.customStoragePath {
                    wURL = customURL.appendingPathComponent("workspace.json")
                } else {
                    let folder = base.appendingPathComponent("Workspace-\(entry.name)-\(entry.id.uuidString)")
                    wURL = folder.appendingPathComponent("workspace.json")
                }

                if FileManager.default.fileExists(atPath: wURL.path) {
                    do {
                        try loadedMutable.append(Self.loadWorkspaceFromFile(at: wURL))
                    } catch {
                        print("Error loading workspace from new scheme: \(error)")
                    }
                } else {
                    print("No workspace.json found for \(entry.name) at \(wURL.path)")
                }
            }

            // Freeze mutable collection before crossing actor boundary
            let loaded = loadedMutable
            if Task.isCancelled { return }

            await MainActor.run { [weak self, loaded, token, currentActiveID] in
                guard let self else { return }
                // Only apply if this is the latest issued task
                guard reloadWorkspacesToken == token else { return }

                workspaces = loaded
                recordRepoPathBaselines(for: loaded)
                if let currentActiveID,
                   loaded.contains(where: { $0.id == currentActiveID })
                {
                    activeWorkspaceID = currentActiveID
                }

                // Clear running task reference
                reloadWorkspacesTask = nil
            }
        }
    }

    private func postWorkspaceRepoPathsDidChange(for workspaceID: UUID) {
        NotificationCenter.default.post(
            name: .workspaceRepoPathsDidChange,
            object: nil,
            userInfo: [
                "managerID": instanceID,
                "workspaceID": workspaceID
            ]
        )
    }

    private func mergeRepoPathsFromDisk(for workspaceID: UUID) async {
        guard let index = workspaceIndex(for: workspaceID) else { return }
        let fileURL = workspaceFileURL(for: workspaces[index])
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        do {
            let diskWorkspace = try await Self.loadWorkspaceFromFileAsync(at: fileURL)
            guard let latestIndex = workspaceIndex(for: workspaceID) else { return }
            guard !hasLocalRepoPathEdit(for: workspaces[latestIndex]) else { return }
            let previousRepoPaths = workspaces[latestIndex].repoPaths
            workspaces[latestIndex].repoPaths = diskWorkspace.repoPaths
            workspaces[latestIndex].dateModified = diskWorkspace.dateModified
            recordRepoPathBaseline(for: workspaces[latestIndex])

            if activeWorkspaceID == workspaceID,
               !Self.repoPathsEquivalent(previousRepoPaths, diskWorkspace.repoPaths)
            {
                if isRefreshing || isSwitchingWorkspace {
                    pendingRepoPathSyncWorkspaceIDs.insert(workspaceID)
                } else {
                    await syncLoadedRootsWithWorkspace(workspaces[latestIndex])
                }
            }
        } catch {
            print("Failed to merge workspace root paths from disk: \(error)")
        }
    }

    /// Loads a fresh snapshot of all workspaces from workspace storage.
    /// This bypasses this manager's in-memory state and may reuse the process-wide
    /// decode cache when the on-disk file metadata is unchanged.
    /// Use this when you need guaranteed accurate workspace data (e.g., for MCP tool responses).
    func loadWorkspaceSnapshotFromDisk() async -> [WorkspaceModel] {
        let base = currentBaseRoot
        let indexURL = workspaceIndexFileURL

        return await Task.detached(priority: .utility) {
            let indexEntries = Self.loadWorkspaceIndex(from: indexURL)
            var loaded: [WorkspaceModel] = []

            for entry in indexEntries {
                let wURL: URL
                if let customURL = entry.customStoragePath {
                    wURL = customURL.appendingPathComponent("workspace.json")
                } else {
                    let folder = base.appendingPathComponent("Workspace-\(entry.name)-\(entry.id.uuidString)")
                    wURL = folder.appendingPathComponent("workspace.json")
                }

                if FileManager.default.fileExists(atPath: wURL.path) {
                    do {
                        let ws = try Self.loadWorkspaceFromFile(at: wURL)
                        print("[WorkspaceSnapshot] Loaded \(ws.name): \(ws.repoPaths.count) repoPaths")
                        loaded.append(ws)
                    } catch {
                        print("[WorkspaceSnapshot] Failed to load from \(wURL.path): \(error)")
                    }
                } else {
                    print("[WorkspaceSnapshot] File not found: \(wURL.path)")
                }
            }

            return loaded
        }.value
    }

    /// Reloads only the presets for all workspaces from disk
    func reloadPresetsFromDisk() {
        let base = currentBaseRoot
        let indexURL = workspaceIndexFileURL

        // Cancel any prior run and install a new token
        reloadPresetsTask?.cancel()
        let token = UUID()
        reloadPresetsToken = token

        reloadPresetsTask = Task.detached(priority: .utility) { [weak self, indexURL, base, token] in
            let indexEntries = Self.loadWorkspaceIndex(from: indexURL)
            var updatesMutable: [(id: UUID, presets: [WorkspacePreset], activePresetID: UUID?)] = []

            for entry in indexEntries {
                if Task.isCancelled { return }

                let wURL: URL
                if let customURL = entry.customStoragePath {
                    wURL = customURL.appendingPathComponent("workspace.json")
                } else {
                    let folder = base.appendingPathComponent("Workspace-\(entry.name)-\(entry.id.uuidString)")
                    wURL = folder.appendingPathComponent("workspace.json")
                }

                guard FileManager.default.fileExists(atPath: wURL.path) else {
                    continue
                }

                do {
                    let ws = try Self.loadWorkspaceFromFile(at: wURL)
                    updatesMutable.append((entry.id, ws.presets, ws.activePresetID))
                } catch {
                    print("Error reloading presets for workspace \(entry.name): \(error)")
                }
            }

            // Freeze mutable collection before crossing actor boundary
            let updates = updatesMutable
            if Task.isCancelled { return }

            await MainActor.run { [weak self, updates, token] in
                guard let self else { return }
                // Ensure this result is from the latest task
                guard reloadPresetsToken == token else { return }

                // Recompute the current index map (state may have changed since task started)
                // Defensive: workspace IDs should be unique, but use a
                // duplicate-tolerant (last-wins) init so a stray duplicate
                // ID never SIGTRAPs during a background reload. Last-wins
                // matches the array order semantics below.
                let indexMap = Dictionary(
                    workspaces.enumerated().map { ($1.id, $0) },
                    uniquingKeysWith: { _, last in last }
                )

                for update in updates {
                    guard let idx = indexMap[update.id],
                          workspaces.indices.contains(idx) else { continue }
                    workspaces[idx].presets = update.presets
                    workspaces[idx].activePresetID = update.activePresetID
                }

                if activeWorkspace != nil {
                    checkIfActivePresetIsDirty(with: fileManager.selectedFiles)
                }

                // Clear running task reference
                reloadPresetsTask = nil
            }
        }
    }

    /// Legacy synchronous version - only used during initialization
    private func rebuildAndSaveIndex() {
        // Exclude ephemeral workspaces from the index
        let entries: [WorkspaceIndexEntry] = workspaces
            .filter { !$0.isEphemeral }
            .map {
                WorkspaceIndexEntry(
                    id: $0.id,
                    name: $0.name,
                    customStoragePath: $0.customStoragePath,
                    isSystemWorkspace: $0.isSystemWorkspace,
                    isHiddenInMenus: $0.isHiddenInMenus
                )
            }
        do {
            try saveWorkspaceIndex(entries)
        } catch {
            print("Error saving index: \(error)")
        }
    }

    private func rebuildAndSaveIndexAsync() async {
        // Exclude ephemeral workspaces from the index
        let entries: [WorkspaceIndexEntry] = workspaces
            .filter { !$0.isEphemeral }
            .map {
                WorkspaceIndexEntry(
                    id: $0.id,
                    name: $0.name,
                    customStoragePath: $0.customStoragePath,
                    isSystemWorkspace: $0.isSystemWorkspace,
                    isHiddenInMenus: $0.isHiddenInMenus
                )
            }
        do {
            try await saveWorkspaceIndexAsync(entries)
        } catch {
            print("Error saving index: \(error)")
        }
    }

    // MARK: - DRAFT

    func createWorkspaceFromDraft() -> WorkspaceModel? {
        let finalName = creationDraft.name.trimmingCharacters(in: .whitespacesAndNewlines)

        // If name is empty but we have paths, generate a name from the paths
        let workspaceName: String
        if finalName.isEmpty {
            if !creationDraft.selectedRepoPaths.isEmpty {
                // Generate name from last components of paths
                let lastComponents = creationDraft.selectedRepoPaths.map { path in
                    URL(fileURLWithPath: path).lastPathComponent
                }
                workspaceName = lastComponents.joined(separator: ", ")
            } else {
                // No name and no paths - can't create workspace
                return nil
            }
        } else {
            workspaceName = finalName
        }

        let newWorkspace = createWorkspace(
            name: workspaceName,
            repoPaths: creationDraft.selectedRepoPaths
        )
        creationDraft = WorkspaceCreationDraft()
        return newWorkspace
    }

    struct WorkspaceCreationDraft {
        var name: String = ""
        var selectedRepoPaths: [String] = []
    }

    // MARK: - CREATE

    @discardableResult
    func createWorkspace(name: String, repoPaths: [String], ephemeral: Bool = false) -> WorkspaceModel {
        var newWorkspace = WorkspaceModel(name: name, repoPaths: repoPaths)

        // Mark as ephemeral if needed
        newWorkspace.isEphemeral = ephemeral

        workspaces.append(newWorkspace)
        recordRepoPathBaseline(for: newWorkspace)

        // Notify for auto-apply recommendations (non-ephemeral only)
        if !ephemeral {
            NotificationCenter.default.post(
                name: .workspaceDidCreate,
                object: nil,
                userInfo: ["workspaceID": newWorkspace.id]
            )
        }

        // Only save to disk and index if not ephemeral
        if !ephemeral {
            Task {
                do {
                    _ = try ensureWorkspaceDirectoryExists(for: newWorkspace)
                    // Persist this new workspace file and flush before proceeding
                    let finalURL = try await saveWorkspaceToFileAsync(newWorkspace, preserveDiskRepoPathsIfUnchangedSinceBaseline: false, source: .createWorkspace)
                    await WorkspaceDiskWriter.shared.flush(url: finalURL)
                    await MainActor.run { self.recordRepoPathBaseline(for: newWorkspace) }

                    await rebuildAndSaveIndexAsync()
                    await WorkspaceDiskWriter.shared.flush(url: workspaceIndexFileURL)

                    // Notify other windows after disk commits
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: .workspaceListDidChange,
                            object: nil,
                            userInfo: ["managerID": instanceID]
                        )
                    }
                } catch {
                    print("Error creating workspace folder/file: \(error)")
                }
            }
        } else {
            // For ephemeral workspaces, notify immediately since there's no disk write
            NotificationCenter.default.post(
                name: .workspaceListDidChange,
                object: nil,
                userInfo: ["managerID": instanceID]
            )
        }

        return newWorkspace
    }

    // MARK: - Switch

    private func beginWorkspaceSwitchOperation(
        to newWorkspace: WorkspaceModel,
        reason: String
    ) -> UUID? {
        guard activeWorkspaceSwitch == nil else { return nil }
        let operationID = UUID()
        let now = switchTimingPolicy.now()
        activeWorkspaceSwitch = WorkspaceSwitchActivity(
            operationID: operationID,
            previousWorkspaceID: activeWorkspaceID,
            previousWorkspaceName: activeWorkspace?.name,
            targetWorkspaceID: newWorkspace.id,
            targetWorkspaceName: newWorkspace.name,
            reason: reason,
            phase: .preparing,
            startedAt: now,
            phaseStartedAt: now
        )
        isSwitchingWorkspace = true
        return operationID
    }

    private func ownsWorkspaceSwitchOperation(_ operationID: UUID) -> Bool {
        activeWorkspaceSwitch?.operationID == operationID
    }

    private func advanceWorkspaceSwitchOperation(
        _ operationID: UUID,
        to phase: WorkspaceSwitchPhase
    ) {
        guard let activity = activeWorkspaceSwitch,
              activity.operationID == operationID,
              activity.phase != phase
        else { return }
        activeWorkspaceSwitch = WorkspaceSwitchActivity(
            operationID: activity.operationID,
            previousWorkspaceID: activity.previousWorkspaceID,
            previousWorkspaceName: activity.previousWorkspaceName,
            targetWorkspaceID: activity.targetWorkspaceID,
            targetWorkspaceName: activity.targetWorkspaceName,
            reason: activity.reason,
            phase: phase,
            startedAt: activity.startedAt,
            phaseStartedAt: switchTimingPolicy.now()
        )
        #if DEBUG
            workspaceSwitchPhaseDidChangeHandlerForTesting?(phase)
        #endif
    }

    private func finishWorkspaceSwitchOperation(_ operationID: UUID) {
        if let pending = pendingSwitchConfirmationRequest,
           pending.operationID == operationID
        {
            pendingSwitchConfirmationRequest = nil
            pendingSwitchConfirmation = nil
            pending.continuation.resume(returning: false)
        }
        guard ownsWorkspaceSwitchOperation(operationID) else { return }
        if returnToSystemAfterSwitchCancellationOperationID == operationID {
            returnToSystemAfterSwitchCancellationOperationID = nil
        }
        if committedWorkspaceSwitchOperationID == operationID {
            committedWorkspaceSwitchOperationID = nil
        }
        if recoveringWorkspaceSwitchOperationID == operationID {
            recoveringWorkspaceSwitchOperationID = nil
        }
        if rootsUnloadedWorkspaceSwitchOperationID == operationID {
            rootsUnloadedWorkspaceSwitchOperationID = nil
        }
        activeWorkspaceSwitch = nil
        isSwitchingWorkspace = false
        drainPendingRepoPathSyncIfNeeded()
        notifySwitchingComplete()
    }

    private func markWorkspaceSwitchCommitted(_ operationID: UUID) {
        guard ownsWorkspaceSwitchOperation(operationID) else { return }
        committedWorkspaceSwitchOperationID = operationID
    }

    private func markWorkspaceSwitchRootsUnloaded(_ operationID: UUID) {
        guard ownsWorkspaceSwitchOperation(operationID) else { return }
        rootsUnloadedWorkspaceSwitchOperationID = operationID
    }

    private func clearWorkspaceSwitchBlockedNotice(blockedBy operationID: UUID) {
        guard pendingWorkspaceSwitchBlockedNotice?.isBlocked(by: operationID) == true else { return }
        pendingWorkspaceSwitchBlockedNotice = nil
    }

    private func retargetWorkspaceSwitchOperation(
        _ operationID: UUID,
        to workspace: WorkspaceModel,
        reason: String
    ) {
        guard let activity = activeWorkspaceSwitch,
              activity.operationID == operationID
        else { return }
        activeWorkspaceSwitch = WorkspaceSwitchActivity(
            operationID: activity.operationID,
            previousWorkspaceID: activity.previousWorkspaceID,
            previousWorkspaceName: activity.previousWorkspaceName,
            targetWorkspaceID: workspace.id,
            targetWorkspaceName: workspace.name,
            reason: reason,
            phase: .preparing,
            startedAt: activity.startedAt,
            phaseStartedAt: switchTimingPolicy.now()
        )
        #if DEBUG
            workspaceSwitchPhaseDidChangeHandlerForTesting?(.preparing)
        #endif
    }

    private func completeWorkspaceSwitchOperation(
        _ operationID: UUID,
        originalResult: WorkspaceSwitchResult
    ) async -> WorkspaceSwitchResult {
        var finalResult = originalResult
        let originalActivity = activeWorkspaceSwitch
        let explicitlyRequestedRecovery = returnToSystemAfterSwitchCancellationOperationID == operationID
        let crossedDestructiveBoundary = rootsUnloadedWorkspaceSwitchOperationID == operationID
            || activeWorkspaceID != originalActivity?.previousWorkspaceID
        let needsRecovery = !originalResult.didSwitch
            && committedWorkspaceSwitchOperationID != operationID
            && (explicitlyRequestedRecovery || crossedDestructiveBoundary)

        if !originalResult.didSwitch,
           !needsRecovery,
           committedWorkspaceSwitchOperationID != operationID
        {
            invalidateWorkspaceSearchReadiness()
        }

        if needsRecovery, let originalActivity {
            returnToSystemAfterSwitchCancellationOperationID = nil
            let recoveryResult = await recoverWorkspaceSwitch(
                operationID: operationID,
                originalActivity: originalActivity,
                explicitlyReturnToSystem: explicitlyRequestedRecovery
            )
            if !recoveryResult.didSwitch {
                let detail = recoveryResult.message ?? "Unknown recovery failure."
                let message = "Workspace switch recovery could not restore a usable workspace: \(detail)"
                pendingWorkspaceSwitchBlockedNotice = WorkspaceSwitchBlockedNotice(message: message)
                finalResult = .blocked(message)
            }
        }
        if finalResult.didSwitch, committedWorkspaceSwitchOperationID == operationID {
            clearWorkspaceSwitchBlockedNotice(blockedBy: operationID)
        }
        finishWorkspaceSwitchOperation(operationID)
        return finalResult
    }

    private func recoverWorkspaceSwitch(
        operationID: UUID,
        originalActivity: WorkspaceSwitchActivity,
        explicitlyReturnToSystem: Bool
    ) async -> WorkspaceSwitchResult {
        guard ownsWorkspaceSwitchOperation(operationID) else {
            return .blocked("Workspace switch recovery lost operation ownership.")
        }

        let fallback = workspaces.first(where: { $0.isSystemWorkspace }) ?? getOrCreateSystemWorkspace()
        var recoveryTargets: [WorkspaceModel] = []
        if !explicitlyReturnToSystem,
           let previousWorkspaceID = originalActivity.previousWorkspaceID,
           previousWorkspaceID != originalActivity.targetWorkspaceID,
           let previousWorkspace = workspaces.first(where: { $0.id == previousWorkspaceID })
        {
            recoveryTargets.append(previousWorkspace)
        }
        if !recoveryTargets.contains(where: { $0.id == fallback.id }) {
            recoveryTargets.append(fallback)
        }

        recoveringWorkspaceSwitchOperationID = operationID
        defer {
            if recoveringWorkspaceSwitchOperationID == operationID {
                recoveringWorkspaceSwitchOperationID = nil
            }
        }
        committedWorkspaceSwitchOperationID = nil
        #if DEBUG
            if let workspaceSwitchRecoveryWillBeginHandlerForTesting {
                await workspaceSwitchRecoveryWillBeginHandlerForTesting()
            }
        #endif

        var failures: [String] = []
        for recoveryTarget in recoveryTargets {
            guard ownsWorkspaceSwitchOperation(operationID) else {
                return .blocked("Workspace switch recovery was superseded before fallback activation.")
            }
            if activeWorkspaceID == recoveryTarget.id,
               rootsUnloadedWorkspaceSwitchOperationID != operationID
            {
                return .switched
            }

            let recoveryReason = explicitlyReturnToSystem
                ? "returnToSystemAfterCancellation"
                : "recoverAfterPrecommitFailure"
            committedWorkspaceSwitchOperationID = nil
            retargetWorkspaceSwitchOperation(
                operationID,
                to: recoveryTarget,
                reason: recoveryReason
            )
            let recoveryTask = Task { @MainActor [weak self] in
                guard let self else {
                    return WorkspaceSwitchResult.blocked("Workspace switch recovery manager was released.")
                }
                return await performWorkspaceSwitch(
                    to: recoveryTarget,
                    saveState: false,
                    reason: recoveryReason,
                    operationID: operationID
                )
            }
            let result = await recoveryTask.value
            if result.didSwitch {
                return result
            }
            failures.append("\(recoveryTarget.name): \(result.message ?? "unknown failure")")
        }

        return .blocked(failures.joined(separator: "; "))
    }

    private func blockageReport(
        requestedWorkspace: WorkspaceModel,
        activeSwitch: WorkspaceSwitchActivity,
        messageOverride: String? = nil
    ) -> WorkspaceSwitchBlockageReport {
        let now = switchTimingPolicy.now()
        let totalAge = max(0, now.timeIntervalSince(activeSwitch.startedAt))
        let phaseAge = max(0, now.timeIntervalSince(activeSwitch.phaseStartedAt))
        let isStale = totalAge >= switchTimingPolicy.staleThreshold
        let stateLabel = isStale ? "stale" : "active"
        let formattedTotalAge = String(format: "%.1f", totalAge)
        let formattedPhaseAge = String(format: "%.1f", phaseAge)
        let message = messageOverride ??
            "Workspace switch to \"\(requestedWorkspace.name)\" is blocked by a \(stateLabel) switch to \"\(activeSwitch.targetWorkspaceName)\" (reason: \(activeSwitch.reason), phase: \(activeSwitch.phase.displayName), total age: \(formattedTotalAge)s, phase age: \(formattedPhaseAge)s)."
        return WorkspaceSwitchBlockageReport(
            requestedTargetWorkspaceID: requestedWorkspace.id,
            requestedTargetWorkspaceName: requestedWorkspace.name,
            activeSwitch: activeSwitch,
            totalAge: totalAge,
            phaseAge: phaseAge,
            isStale: isStale,
            message: message
        )
    }

    private func publishWorkspaceSwitchBlockage(_ report: WorkspaceSwitchBlockageReport) {
        lastWorkspaceSwitchBlockageReport = report
        if report.isStale {
            Self.logger.error("\(report.message, privacy: .public)")
        } else {
            Self.logger.info("\(report.message, privacy: .public)")
        }
    }

    private func concurrentWorkspaceSwitchResult(
        requestedWorkspace: WorkspaceModel
    ) -> WorkspaceSwitchResult? {
        guard let activeSwitch = activeWorkspaceSwitch else { return nil }
        let report = blockageReport(
            requestedWorkspace: requestedWorkspace,
            activeSwitch: activeSwitch
        )
        publishWorkspaceSwitchBlockage(report)
        return .blocked(report.message)
    }

    private func cancellationResult(
        operationID: UUID,
        targetWorkspace: WorkspaceModel,
        boundary: String
    ) -> WorkspaceSwitchResult? {
        guard ownsWorkspaceSwitchOperation(operationID) else {
            return .cancelled("Workspace switch to \"\(targetWorkspace.name)\" was superseded at \(boundary).")
        }
        if committedWorkspaceSwitchOperationID == operationID
            || recoveringWorkspaceSwitchOperationID == operationID
        {
            return nil
        }
        guard Task.isCancelled || returnToSystemAfterSwitchCancellationOperationID == operationID else { return nil }
        return .cancelled("Workspace switch to \"\(targetWorkspace.name)\" was cancelled at \(boundary).")
    }

    private func waitForChatBusyToClear() async -> Bool {
        guard isChatBusy else { return true }
        var remaining = switchTimingPolicy.chatBusySettleTimeoutNanoseconds
        let pollInterval = max(1, switchTimingPolicy.chatBusyPollIntervalNanoseconds)
        while isChatBusy, remaining > 0 {
            let interval = min(pollInterval, remaining)
            do {
                try await switchTimingPolicy.sleep(interval)
            } catch {
                return false
            }
            if Task.isCancelled { return false }
            remaining -= interval
        }
        return !isChatBusy
    }

    private func remainingSessionSummary() -> String {
        let items = activeSessionSnapshot().items
        guard !items.isEmpty else { return "no reported active sessions" }
        return items.map { $0.formattedCount() }.joined(separator: ", ")
    }

    @MainActor
    func requestWorkspaceSwitch(to newWorkspace: WorkspaceModel, saveState: Bool = true, reason: String = "userOrInternal") async -> WorkspaceSwitchResult {
        if let concurrentResult = concurrentWorkspaceSwitchResult(requestedWorkspace: newWorkspace) {
            return userVisibleWorkspaceSwitchResult(
                concurrentResult,
                blockingOperationID: activeWorkspaceSwitch?.operationID
            )
        }
        if newWorkspace.id == activeWorkspaceID {
            // Benign no-op (launch restore, save-and-exit on the system workspace, MCP
            // switch to the current workspace): stay silent instead of raising the
            // blocked-notice alert reserved for actionable blockages.
            return .blocked("Already on workspace \"\(newWorkspace.name)\".")
        }
        if isRefreshing {
            return userVisibleWorkspaceSwitchResult(
                .blocked("Cannot switch workspaces while refresh is in progress.")
            )
        }
        guard let operationID = beginWorkspaceSwitchOperation(to: newWorkspace, reason: reason) else {
            let result = concurrentWorkspaceSwitchResult(requestedWorkspace: newWorkspace)
                ?? .blocked("Workspace switch already in progress.")
            return userVisibleWorkspaceSwitchResult(
                result,
                blockingOperationID: activeWorkspaceSwitch?.operationID
            )
        }

        let operationResult = await performRequestedWorkspaceSwitch(
            to: newWorkspace,
            saveState: saveState,
            reason: reason,
            operationID: operationID
        )
        let finalResult = await completeWorkspaceSwitchOperation(
            operationID,
            originalResult: operationResult
        )
        return userVisibleWorkspaceSwitchResult(finalResult)
    }

    private func userVisibleWorkspaceSwitchResult(
        _ result: WorkspaceSwitchResult,
        blockingOperationID: UUID? = nil
    ) -> WorkspaceSwitchResult {
        if case let .blocked(message) = result {
            pendingWorkspaceSwitchBlockedNotice = WorkspaceSwitchBlockedNotice(
                message: message,
                blockingOperationID: blockingOperationID
            )
        }
        return result
    }

    private func performRequestedWorkspaceSwitch(
        to newWorkspace: WorkspaceModel,
        saveState: Bool,
        reason: String,
        operationID: UUID
    ) async -> WorkspaceSwitchResult {
        let snapshot = activeSessionSnapshot()
        if snapshot.hasActiveSessions {
            advanceWorkspaceSwitchOperation(operationID, to: .awaitingConfirmation)
            let confirmation = WorkspaceSwitchConfirmation(
                targetWorkspaceName: newWorkspace.name,
                items: snapshot.items
            )
            let approved = await requestSwitchConfirmation(confirmation, operationID: operationID)
            if let cancellation = cancellationResult(
                operationID: operationID,
                targetWorkspace: newWorkspace,
                boundary: "confirmation"
            ) {
                return cancellation
            }
            guard approved else {
                return .cancelled(confirmation.cancelMessage)
            }

            advanceWorkspaceSwitchOperation(operationID, to: .cancellingSessions)
            await cancelActiveSessions()
            if let cancellation = cancellationResult(
                operationID: operationID,
                targetWorkspace: newWorkspace,
                boundary: "session cancellation"
            ) {
                return cancellation
            }

            if isChatBusy {
                advanceWorkspaceSwitchOperation(operationID, to: .waitingForChatIdle)
                let settled = await waitForChatBusyToClear()
                if let cancellation = cancellationResult(
                    operationID: operationID,
                    targetWorkspace: newWorkspace,
                    boundary: "chat busy settling"
                ) {
                    return cancellation
                }
                guard settled, !isChatBusy else {
                    guard let activeSwitch = activeWorkspaceSwitch,
                          activeSwitch.operationID == operationID
                    else {
                        return .blocked("Workspace switch could not verify chat session cleanup.")
                    }
                    let timeoutSeconds = Double(switchTimingPolicy.chatBusySettleTimeoutNanoseconds) / 1_000_000_000
                    let formattedTimeout = String(format: "%.1f", timeoutSeconds)
                    let message = "Workspace switch to \"\(newWorkspace.name)\" is blocked because isChatBusy remained true for \(formattedTimeout)s after session cancellation; remaining sessions: \(remainingSessionSummary())."
                    let report = blockageReport(
                        requestedWorkspace: newWorkspace,
                        activeSwitch: activeSwitch,
                        messageOverride: message
                    )
                    publishWorkspaceSwitchBlockage(report)
                    return .blocked(report.message)
                }
            }
            advanceWorkspaceSwitchOperation(operationID, to: .preparing)
        }

        return await performWorkspaceSwitch(
            to: newWorkspace,
            saveState: saveState,
            reason: reason,
            operationID: operationID
        )
    }

    private func requestSwitchConfirmation(
        _ confirmation: WorkspaceSwitchConfirmation,
        operationID: UUID
    ) async -> Bool {
        guard pendingSwitchConfirmationRequest == nil else { return false }
        return await withTaskCancellationHandler {
            if Task.isCancelled { return false }
            return await withCheckedContinuation { continuation in
                guard ownsWorkspaceSwitchOperation(operationID), !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                pendingSwitchConfirmationRequest = PendingSwitchConfirmationRequest(
                    operationID: operationID,
                    confirmationID: confirmation.id,
                    continuation: continuation
                )
                pendingSwitchConfirmation = confirmation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPendingSwitchConfirmation(
                    operationID: operationID,
                    confirmationID: confirmation.id
                )
            }
        }
    }

    private func cancelPendingSwitchConfirmation(
        operationID: UUID,
        confirmationID: UUID
    ) {
        guard let pending = pendingSwitchConfirmationRequest,
              pending.operationID == operationID,
              pending.confirmationID == confirmationID
        else { return }
        pendingSwitchConfirmationRequest = nil
        pendingSwitchConfirmation = nil
        pending.continuation.resume(returning: false)
    }

    func resolveSwitchConfirmation(id confirmationID: UUID, allow: Bool) {
        guard let pending = pendingSwitchConfirmationRequest,
              pending.confirmationID == confirmationID
        else { return }
        pendingSwitchConfirmationRequest = nil
        pendingSwitchConfirmation = nil
        pending.continuation.resume(returning: allow)
    }

    func dismissWorkspaceSwitchBlockedNotice(id noticeID: UUID) {
        guard pendingWorkspaceSwitchBlockedNotice?.id == noticeID else { return }
        pendingWorkspaceSwitchBlockedNotice = nil
    }

    #if DEBUG
        var workspaceSearchReadinessWaiterCountForTesting: Int {
            workspaceSearchReadinessWaiters.count
        }

        func setWorkspaceSwitchPhaseDidChangeHandlerForTesting(
            _ handler: ((WorkspaceSwitchPhase) -> Void)?
        ) {
            workspaceSwitchPhaseDidChangeHandlerForTesting = handler
        }

        func setWorkspaceSwitchRecoveryWillBeginHandlerForTesting(
            _ handler: (@MainActor () async -> Void)?
        ) {
            workspaceSwitchRecoveryWillBeginHandlerForTesting = handler
        }

        func setWorkspaceSwitchReadinessDidInvalidateHandlerForTesting(
            _ handler: (@MainActor () async -> Void)?
        ) {
            workspaceSwitchReadinessDidInvalidateHandlerForTesting = handler
        }

        func setWorkspaceHydrationGenerationDidAdvanceHandlerForTesting(
            _ handler: (@MainActor () -> Void)?
        ) {
            workspaceHydrationGenerationDidAdvanceHandlerForTesting = handler
        }
    #endif

    func awaitWorkspaceSearchReadiness(
        timeout: Duration
    ) async throws -> WorkspaceSearchReadinessTicket {
        try Task.checkCancellation()
        guard let ticket = workspaceSearchReadinessState.ticket else {
            throw WorkspaceSearchReadinessWaitError.unavailable
        }
        if workspaceSearchReadinessState.isSearchAdmissible {
            try validateWorkspaceSearchReadiness(ticket)
            return ticket
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard workspaceSearchReadinessState.ticket == ticket else {
                    continuation.resume(throwing: WorkspaceSearchReadinessWaitError.superseded)
                    return
                }
                if workspaceSearchReadinessState.isSearchAdmissible {
                    do {
                        try validateWorkspaceSearchReadiness(ticket)
                        continuation.resume(returning: ticket)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                    return
                }

                let timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    self?.failWorkspaceSearchReadinessWaiter(
                        waiterID,
                        throwing: WorkspaceSearchReadinessWaitError.timedOut
                    )
                }
                workspaceSearchReadinessWaiters[waiterID] = WorkspaceSearchReadinessWaiter(
                    ticket: ticket,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                if Task.isCancelled {
                    failWorkspaceSearchReadinessWaiter(waiterID, throwing: CancellationError())
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.failWorkspaceSearchReadinessWaiter(waiterID, throwing: CancellationError())
            }
        }
    }

    nonisolated func validateWorkspaceSearchReadinessSnapshot(
        _ ticket: WorkspaceSearchReadinessTicket
    ) throws {
        guard workspaceSearchReadinessFence.contains(ticket) else {
            throw WorkspaceSearchReadinessWaitError.superseded
        }
    }

    func validateWorkspaceSearchReadiness(
        _ ticket: WorkspaceSearchReadinessTicket
    ) throws {
        guard workspaceSearchReadinessState.isSearchAdmissible,
              workspaceSearchReadinessState.ticket == ticket,
              workspaceHydrationGeneration == ticket.generation,
              activeWorkspaceID == ticket.workspaceID
        else {
            throw WorkspaceSearchReadinessWaitError.superseded
        }
    }

    private func reconcileWorkspaceSearchReadinessWaiters() {
        for waiterID in Array(workspaceSearchReadinessWaiters.keys) {
            guard let waiter = workspaceSearchReadinessWaiters[waiterID] else { continue }
            guard workspaceSearchReadinessState.ticket == waiter.ticket else {
                failWorkspaceSearchReadinessWaiter(
                    waiterID,
                    throwing: WorkspaceSearchReadinessWaitError.superseded
                )
                continue
            }
            guard workspaceSearchReadinessState.isSearchAdmissible else { continue }
            do {
                try validateWorkspaceSearchReadiness(waiter.ticket)
                succeedWorkspaceSearchReadinessWaiter(waiterID, ticket: waiter.ticket)
            } catch {
                failWorkspaceSearchReadinessWaiter(waiterID, throwing: error)
            }
        }
    }

    private func succeedWorkspaceSearchReadinessWaiter(
        _ waiterID: UUID,
        ticket: WorkspaceSearchReadinessTicket
    ) {
        guard let waiter = workspaceSearchReadinessWaiters.removeValue(forKey: waiterID) else { return }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: ticket)
    }

    private func failWorkspaceSearchReadinessWaiter(
        _ waiterID: UUID,
        throwing error: any Error
    ) {
        guard let waiter = workspaceSearchReadinessWaiters.removeValue(forKey: waiterID) else { return }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(throwing: error)
    }

    @discardableResult
    func reactivateWorkspaceAfterReplacement(
        _ workspace: WorkspaceModel,
        reason: String = "restoredWorkspaceReplacement"
    ) async -> WorkspaceSwitchResult {
        guard workspace.id == activeWorkspaceID else {
            return await switchWorkspace(to: workspace, saveState: false, reason: reason)
        }
        if let concurrentResult = concurrentWorkspaceSwitchResult(requestedWorkspace: workspace) {
            return concurrentResult
        }
        if isRefreshing {
            return .blocked("Cannot reload the active workspace while refresh is in progress.")
        }
        guard let operationID = beginWorkspaceSwitchOperation(to: workspace, reason: reason) else {
            return concurrentWorkspaceSwitchResult(requestedWorkspace: workspace)
                ?? .blocked("Workspace reload already in progress.")
        }
        let operationResult = await performWorkspaceSwitch(
            to: workspace,
            saveState: false,
            reason: reason,
            operationID: operationID
        )
        return await completeWorkspaceSwitchOperation(
            operationID,
            originalResult: operationResult
        )
    }

    @discardableResult
    func switchWorkspace(to newWorkspace: WorkspaceModel, saveState: Bool = true, reason: String = "internal") async -> WorkspaceSwitchResult {
        if let concurrentResult = concurrentWorkspaceSwitchResult(requestedWorkspace: newWorkspace) {
            return concurrentResult
        }
        if newWorkspace.id == activeWorkspaceID {
            return .blocked("Already on workspace \"\(newWorkspace.name)\".")
        }
        if isRefreshing {
            return .blocked("Cannot switch workspaces while refresh is in progress.")
        }
        guard let operationID = beginWorkspaceSwitchOperation(to: newWorkspace, reason: reason) else {
            return concurrentWorkspaceSwitchResult(requestedWorkspace: newWorkspace)
                ?? .blocked("Workspace switch already in progress.")
        }
        let operationResult = await performWorkspaceSwitch(
            to: newWorkspace,
            saveState: saveState,
            reason: reason,
            operationID: operationID
        )
        return await completeWorkspaceSwitchOperation(
            operationID,
            originalResult: operationResult
        )
    }

    private func performWorkspaceSwitch(
        to newWorkspace: WorkspaceModel,
        saveState: Bool,
        reason: String,
        operationID: UUID
    ) async -> WorkspaceSwitchResult {
        guard ownsWorkspaceSwitchOperation(operationID) else {
            return .cancelled("Workspace switch to \"\(newWorkspace.name)\" was superseded before preparation.")
        }
        guard !isRefreshing else {
            return .blocked("Cannot switch workspaces while refresh is in progress.")
        }
        guard !isChatBusy else {
            return .blocked("Cannot switch workspaces while chat is busy.")
        }

        let totalStart = switchTimingPolicy.now()
        var shouldSchedulePostSwitchGitDataLoad = false
        var rootsUnloadedBeforeFolderLoad = false
        let previousActiveWorkspace = activeWorkspace
        let effectiveSaveState = Self.effectiveRestoreSaveState(
            requestedSaveState: saveState,
            reason: reason,
            previousWorkspace: previousActiveWorkspace
        )
        #if DEBUG
            let restorePerfStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            let previousWorkspaceID = activeWorkspaceID
            let previousWorkspaceName = previousActiveWorkspace?.name ?? "nil"
            if let restorePerfStartMS {
                debugStartWorkspaceOpenTrace(
                    targetWorkspace: newWorkspace,
                    previousWorkspace: previousActiveWorkspace,
                    switchStartMS: restorePerfStartMS
                )
            }
        #endif
        logWorkspaceSwitch("BEGIN switch to \"\(newWorkspace.name)\" saveState=\(saveState) effectiveSaveState=\(effectiveSaveState)")
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "workspaceSwitch.begin",
                fields: debugWorkspaceOpenTraceFields().merging([
                    "reason": reason,
                    "restored": "\(reason == "restore")",
                    "saveState": "\(saveState)",
                    "effectiveSaveState": "\(effectiveSaveState)",
                    "targetName": newWorkspace.name,
                    "previousWorkspaceID": WorkspaceRestorePerfLog.shortID(previousWorkspaceID),
                    "previousName": previousWorkspaceName,
                    "targetRoots": "\(Self.loadableRepoPaths(for: newWorkspace).count)",
                    "loadedRoots": "\(fileManager.rootFolders.count)"
                ], uniquingKeysWith: { current, _ in current })
            )
        #endif

        let signpost = WorkspaceExitPerf.begin("switchWorkspace")
        defer { WorkspaceExitPerf.end("switchWorkspace", signpost) }

        postSwitchGitDataLoadTask?.cancel()
        postSwitchGitDataLoadTask = nil
        postSwitchGitDataLoadToken = nil
        stopPollTimer()
        if shouldShowWorkspaceSwitchOverlay(for: newWorkspace) {
            showWorkspaceSwitchOverlay(for: newWorkspace)
        }
        defer {
            if ownsWorkspaceSwitchOperation(operationID) {
                let shouldReturnToSystem = returnToSystemAfterSwitchCancellationOperationID == operationID
                hideWorkspaceSwitchOverlay(reason: "switch defer cleanup")
                promptViewModel.startTokenCountUpdateTimer()
                startPollTimer()
                let totalDuration = switchTimingPolicy.now().timeIntervalSince(totalStart)
                logWorkspaceSwitch("END switch to \"\(newWorkspace.name)\" total=\(String(format: "%.3f", totalDuration))s shouldReturnToSystem=\(shouldReturnToSystem)")
                #if DEBUG
                    if let restorePerfStartMS {
                        let counts = fileManager.restorePerfLoadedTreeCounts()
                        WorkspaceRestorePerfLog.event(
                            "workspaceSwitch.end",
                            fields: debugWorkspaceOpenTraceFields().merging([
                                "reason": reason,
                                "restored": "\(reason == "restore")",
                                "saveState": "\(saveState)",
                                "effectiveSaveState": "\(effectiveSaveState)",
                                "activeWorkspaceID": WorkspaceRestorePerfLog.shortID(activeWorkspaceID),
                                "loadedRoots": "\(counts.rootCount)",
                                "loadedFolders": "\(counts.folderCount)",
                                "loadedFiles": "\(counts.fileCount)",
                                "shouldReturnToSystem": "\(shouldReturnToSystem)",
                                "total": WorkspaceRestorePerfLog.formatElapsedMS(since: restorePerfStartMS)
                            ], uniquingKeysWith: { current, _ in current })
                        )
                    }
                    debugFinishWorkspaceOpenTrace()
                #endif
                if shouldSchedulePostSwitchGitDataLoad,
                   let switchedWorkspace = activeWorkspace,
                   switchedWorkspace.id == newWorkspace.id,
                   !switchedWorkspace.isSystemWorkspace,
                   !shouldReturnToSystem
                {
                    schedulePostSwitchGitDataLoad(for: switchedWorkspace, reason: "postSwitch")
                }
            }
        }
        let hydrationGeneration = beginWorkspaceHydration(for: newWorkspace)
        #if DEBUG
            if let workspaceSwitchReadinessDidInvalidateHandlerForTesting {
                await workspaceSwitchReadinessDidInvalidateHandlerForTesting()
            }
        #endif
        await promptViewModel.stopTokenCountUpdateTimer()
        await workspaceSearchService.reset()
        if let cancellation = cancellationResult(
            operationID: operationID,
            targetWorkspace: newWorkspace,
            boundary: "preparation"
        ) {
            return cancellation
        }

        if effectiveSaveState, let oldActive = activeWorkspace {
            advanceWorkspaceSwitchOperation(operationID, to: .savingCurrentWorkspace)
            let saveUnloadStart = Date()
            logWorkspaceSwitch("save/unload BEGIN from \"\(oldActive.name)\"")
            #if DEBUG
                debugSelectionOwnerTraceEvent("switch.saveState.before", workspace: oldActive)
            #endif
            let saveSignpost = WorkspaceExitPerf.begin("switchWorkspace.saveAndUnload")
            defer { WorkspaceExitPerf.end("switchWorkspace.saveAndUnload", saveSignpost) }
            if let index = workspaces.firstIndex(where: { $0.id == oldActive.id }) {
                // Use snapshot to avoid Set→Array conversion on hot path
                let savedPromptIDs = promptViewModel.getSelectedPromptIDsSnapshot()
                workspaces[index].selectedMetaPromptIDs = savedPromptIDs
            }
            await pollAndSaveStateAsync(source: .workspaceSwitchSaveState)
            if let cancellation = cancellationResult(
                operationID: operationID,
                targetWorkspace: newWorkspace,
                boundary: "saving current workspace"
            ) {
                return cancellation
            }
            advanceWorkspaceSwitchOperation(operationID, to: .unloadingRoots)
            #if DEBUG
                let preloadUnloadStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            #endif
            await fileManager.unloadAllRootFolders()
            rootsUnloadedBeforeFolderLoad = true
            markWorkspaceSwitchRootsUnloaded(operationID)
            if let cancellation = cancellationResult(
                operationID: operationID,
                targetWorkspace: newWorkspace,
                boundary: "unloading roots"
            ) {
                return cancellation
            }
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "workspaceSwitch.preloadUnloadRootFolders",
                    fields: [
                        "workspaceID": WorkspaceRestorePerfLog.shortID(oldActive.id),
                        "workspaceName": oldActive.name,
                        "outcome": "completed",
                        "duration": preloadUnloadStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            let saveUnloadDuration = Date().timeIntervalSince(saveUnloadStart)
            logWorkspaceSwitch("save/unload END from \"\(oldActive.name)\" duration=\(String(format: "%.3f", saveUnloadDuration))s")
        }

        advanceWorkspaceSwitchOperation(operationID, to: .loadingTargetWorkspace)
        if let cancellation = cancellationResult(
            operationID: operationID,
            targetWorkspace: newWorkspace,
            boundary: "loading target workspace"
        ) {
            return cancellation
        }
        let diskLoadStart = Date()
        logWorkspaceSwitch("workspace disk load BEGIN target=\"\(newWorkspace.name)\"")
        if let wsIndex = workspaces.firstIndex(where: { $0.id == newWorkspace.id }) {
            let diskURL = workspaceFileURL(for: newWorkspace)
            if FileManager.default.fileExists(atPath: diskURL.path) {
                do {
                    let upgraded = try await Self.loadWorkspaceFromFileAsync(at: diskURL)
                    workspaces[wsIndex] = upgraded
                    recordRepoPathBaseline(for: upgraded)
                } catch {
                    print("Error reloading workspace from disk: \(error)")
                }
            }
            activeWorkspaceID = workspaces[wsIndex].id // Set the active ID
        } else {
            let diskURL = workspaceFileURL(for: newWorkspace)
            guard FileManager.default.fileExists(atPath: diskURL.path) else {
                let message = "Workspace switch could not load \"\(newWorkspace.name)\" because its workspace file is missing at \(diskURL.path)."
                print("‼️ switchWorkspace: \(message)")
                return .blocked(message)
            }

            do {
                let upgraded = try await Self.loadWorkspaceFromFileAsync(at: diskURL)
                workspaces.append(upgraded)
                recordRepoPathBaseline(for: upgraded)
                activeWorkspaceID = upgraded.id
            } catch {
                let message = "Workspace switch could not load \"\(newWorkspace.name)\" from disk: \(error.localizedDescription)"
                print("‼️ switchWorkspace: \(message)")
                return .blocked(message)
            }
        }
        let diskLoadDuration = Date().timeIntervalSince(diskLoadStart)
        logWorkspaceSwitch("workspace disk load END target=\"\(newWorkspace.name)\" duration=\(String(format: "%.3f", diskLoadDuration))s")
        #if DEBUG
            debugSelectionOwnerTraceEvent("switch.diskLoad.after", workspace: activeWorkspace)
            WorkspaceRestorePerfLog.log(
                "workspaceSwitch.diskLoad managerID=\(instanceID.uuidString.prefix(8)) reason=\(reason) restored=\(reason == "restore") workspaceID=\(WorkspaceRestorePerfLog.shortID(newWorkspace.id)) duration=\(WorkspaceRestorePerfLog.formatMS(diskLoadDuration * 1000))"
            )
        #endif

        if let cancellation = cancellationResult(
            operationID: operationID,
            targetWorkspace: newWorkspace,
            boundary: "loading target workspace"
        ) {
            return cancellation
        }

        guard let activeWS = activeWorkspace else {
            return .blocked("Workspace switch to \"\(newWorkspace.name)\" did not produce an active workspace.")
        }
        let loadSignpost = WorkspaceExitPerf.begin("switchWorkspace.loadWorkspace")
        defer { WorkspaceExitPerf.end("switchWorkspace.loadWorkspace", loadSignpost) }
        let restoredHeavyFileState = activeComposeTabHeavyFileStateSnapshot(in: activeWS)
        if let restoredTabID = restoredHeavyFileState?.tabID {
            activationSnapshotSuspendedTabIDs.insert(restoredTabID)
        }
        defer {
            if let restoredTabID = restoredHeavyFileState?.tabID {
                activationSnapshotSuspendedTabIDs.remove(restoredTabID)
            }
        }
        runGitDataMaintenanceOnWorkspaceOpen(activeWS)

        // Restore path-based state before catalog/search hydration. This activation phase
        // must not require root descendant UI projection.
        advanceWorkspaceSwitchOperation(operationID, to: .restoringState)
        await Task.yield()
        if let cancellation = cancellationResult(
            operationID: operationID,
            targetWorkspace: newWorkspace,
            boundary: "restoring state"
        ) {
            return cancellation
        }
        let restoreStart = Date()
        logWorkspaceSwitch("restore state BEGIN workspace=\"\(activeWS.name)\"")
        await restoreWorkspaceState(activeWS)
        let restoreDuration = Date().timeIntervalSince(restoreStart)
        logWorkspaceSwitch("restore state END workspace=\"\(activeWS.name)\" duration=\(String(format: "%.3f", restoreDuration))s")
        #if DEBUG
            WorkspaceRestorePerfLog.log(
                "workspaceSwitch.restoreState managerID=\(instanceID.uuidString.prefix(8)) reason=\(reason) restored=\(reason == "restore") workspaceID=\(WorkspaceRestorePerfLog.shortID(activeWS.id)) duration=\(WorkspaceRestorePerfLog.formatMS(restoreDuration * 1000))"
            )
        #endif
        if let cancellation = cancellationResult(
            operationID: operationID,
            targetWorkspace: newWorkspace,
            boundary: "restoring state"
        ) {
            return cancellation
        }
        guard isHydrationGenerationCurrent(hydrationGeneration, workspaceID: activeWS.id) else {
            return .cancelled("Workspace switch to \"\(newWorkspace.name)\" was superseded during state restoration.")
        }
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "workspaceSwitch.activationReady",
                fields: [
                    "managerID": String(instanceID.uuidString.prefix(8)),
                    "reason": reason,
                    "restored": "\(reason == "restore")",
                    "workspaceID": WorkspaceRestorePerfLog.shortID(activeWS.id),
                    "generation": "\(hydrationGeneration)",
                    "durationSinceSwitchBegin": restorePerfStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured",
                    "restoreStateDuration": WorkspaceRestorePerfLog.formatMS(restoreDuration * 1000),
                    "uiRootShells": "\(fileManager.rootFolders.count)",
                    "uiVisibleRootShells": "\(fileManager.visibleRootFolders.count)"
                ]
            )
        #endif

        // Hydrate primary root catalogs and build search/path lookup indexes. Root shells
        // attach as catalogs complete; watchers, slices and codemap scans are post-catalog work.
        advanceWorkspaceSwitchOperation(operationID, to: .hydratingRoots)
        let folderLoadStart = Date()
        logWorkspaceSwitch("catalog hydration BEGIN workspace=\"\(activeWS.name)\" roots=\(activeWS.repoPaths.count)")
        await loadWorkspaceFolders(
            for: activeWS,
            hydrationGeneration: hydrationGeneration,
            gitDataRootLoadMode: .deferredAfterSwitch,
            initialUnloadMode: rootsUnloadedBeforeFolderLoad ? .skipPreviouslyCompleted : .perform,
            onInitialRootUnloadCompleted: { [weak self] in
                self?.markWorkspaceSwitchRootsUnloaded(operationID)
            },
            onAllPrimaryRootsVisible: { [weak self] in
                guard let self else { return }
                guard !Task.isCancelled else { return }
                guard isHydrationGenerationCurrent(hydrationGeneration, workspaceID: activeWS.id) else { return }
                hideWorkspaceSwitchOverlay(reason: "primary roots visible workspace=\"\(activeWS.name)\"")
            }
        )
        let folderLoadDuration = Date().timeIntervalSince(folderLoadStart)
        logWorkspaceSwitch("catalog hydration END workspace=\"\(activeWS.name)\" duration=\(String(format: "%.3f", folderLoadDuration))s")
        #if DEBUG
            let folderCounts = fileManager.restorePerfLoadedTreeCounts()
            WorkspaceRestorePerfLog.log(
                "workspaceSwitch.folderLoad managerID=\(instanceID.uuidString.prefix(8)) reason=\(reason) restored=\(reason == "restore") workspaceID=\(WorkspaceRestorePerfLog.shortID(activeWS.id)) rootCount=\(activeWS.repoPaths.count) loadedRoots=\(folderCounts.rootCount) loadedFolders=\(folderCounts.folderCount) loadedFiles=\(folderCounts.fileCount) duration=\(WorkspaceRestorePerfLog.formatMS(folderLoadDuration * 1000))"
            )
        #endif
        if let cancellation = cancellationResult(
            operationID: operationID,
            targetWorkspace: newWorkspace,
            boundary: "hydrating roots"
        ) {
            return cancellation
        }
        guard isHydrationGenerationCurrent(hydrationGeneration, workspaceID: activeWS.id) else {
            return .cancelled("Workspace switch to \"\(newWorkspace.name)\" was superseded during root hydration.")
        }

        await replayActiveComposeTabHeavyFileStateAfterHydration(restoredHeavyFileState, workspaceID: activeWS.id)
        if let cancellation = cancellationResult(
            operationID: operationID,
            targetWorkspace: newWorkspace,
            boundary: "replaying hydrated selection"
        ) {
            return cancellation
        }
        guard isHydrationGenerationCurrent(hydrationGeneration, workspaceID: activeWS.id) else {
            return .cancelled("Workspace switch to \"\(newWorkspace.name)\" was superseded while replaying hydrated selection.")
        }

        // Another yield after state restoration
        advanceWorkspaceSwitchOperation(operationID, to: .notifyingListeners)
        await Task.yield()
        if let cancellation = cancellationResult(
            operationID: operationID,
            targetWorkspace: newWorkspace,
            boundary: "notifying listeners"
        ) {
            return cancellation
        }

        // Publishing the activated workspace to listeners is the switch commit boundary.
        // Cancellation observed after this point cannot turn a committed activation into
        // a cancelled result.
        markWorkspaceSwitchCommitted(operationID)

        // Notify listeners that workspace switched.
        #if DEBUG
            let listenerStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        notifyWorkspaceDidSwitch(activeWorkspace)
        #if DEBUG
            if let listenerStartMS {
                WorkspaceRestorePerfLog.event(
                    "workspaceSwitch.listeners",
                    fields: debugWorkspaceOpenTraceFields().merging([
                        "reason": reason,
                        "restored": "\(reason == "restore")",
                        "workspaceID": WorkspaceRestorePerfLog.shortID(activeWS.id),
                        "listenerCount": "\(workspaceDidSwitchListeners.count)",
                        "duration": WorkspaceRestorePerfLog.formatElapsedMS(since: listenerStartMS)
                    ], uniquingKeysWith: { _, new in new })
                )
            }
        #endif
        logWorkspaceSwitch("notifyWorkspaceDidSwitch fired workspace=\"\(activeWS.name)\"")

        // Give post-switch listeners one turn to enqueue their own restore work
        // before exposing the main UI again.
        await Task.yield()
        if let cancellation = cancellationResult(
            operationID: operationID,
            targetWorkspace: newWorkspace,
            boundary: "notifying listeners"
        ) {
            return cancellation
        }
        hideWorkspaceSwitchOverlay(reason: "restore seeded workspace=\"\(activeWS.name)\"")

        // Final yield before marking complete
        advanceWorkspaceSwitchOperation(operationID, to: .finalizing)
        await Task.yield()
        if let cancellation = cancellationResult(
            operationID: operationID,
            targetWorkspace: newWorkspace,
            boundary: "finalizing"
        ) {
            return cancellation
        }

        // Mark as initialized at the end
        completeInitialization()
        shouldSchedulePostSwitchGitDataLoad = true
        logWorkspaceSwitch("completeInitialization called workspace=\"\(activeWS.name)\"")
        return .switched
    }

    @MainActor
    func cancelCurrentWorkspaceSwitchAndReturnToSystem() async {
        if isSwitchingWorkspace {
            hideWorkspaceSwitchOverlay(reason: "user cancel requested")
            let operationID = activeWorkspaceSwitch?.operationID
            if committedWorkspaceSwitchOperationID == operationID
                || recoveringWorkspaceSwitchOperationID == operationID
            {
                return
            }
            returnToSystemAfterSwitchCancellationOperationID = operationID
            if let operationID,
               let pending = pendingSwitchConfirmationRequest,
               pending.operationID == operationID
            {
                cancelPendingSwitchConfirmation(
                    operationID: operationID,
                    confirmationID: pending.confirmationID
                )
            }
            invalidateWorkspaceSearchReadiness()
            await workspaceSearchService.reset()
            fileManager.cancelAllLoadingTasks()
            return
        }
        await exitToSystemWorkspaceAfterCancellation()
    }

    @MainActor
    private func exitToSystemWorkspaceAfterCancellation() async {
        #if DEBUG
            if let workspaceSwitchRecoveryWillBeginHandlerForTesting {
                await workspaceSwitchRecoveryWillBeginHandlerForTesting()
            }
        #endif
        let fallback = workspaces.first(where: { $0.isSystemWorkspace }) ?? getOrCreateSystemWorkspace()
        guard activeWorkspaceID != fallback.id else { return }
        await switchWorkspace(to: fallback, saveState: false)
    }

    /// Runs git data maintenance when a workspace is opened.
    /// This handles version upgrades, legacy purge, and retention enforcement (max 25 snapshots, 7 day expiry).
    private func runGitDataMaintenanceOnWorkspaceOpen(_ workspace: WorkspaceModel) {
        let workspaceDir = workspaceDirectory(for: workspace)
        let workspaceName = workspace.name
        Task.detached(priority: .utility) {
            let result = await GitDiffDataMaintenance.shared.runOnWorkspaceOpen(workspaceDirectory: workspaceDir)
            if result.versionUpgraded || result.legacyPurgePerformed {
                print("[GitDataMaintenance] Upgraded git data for workspace: \(workspaceName)")
            }
            if result.expiredSnapshotsDeleted > 0 || result.excessSnapshotsDeleted > 0 {
                print("[GitDataMaintenance] Cleanup for \(workspaceName): expired=\(result.expiredSnapshotsDeleted), excess=\(result.excessSnapshotsDeleted)")
            }
        }
    }

    private func schedulePostSwitchGitDataLoad(for workspace: WorkspaceModel, reason: String) {
        let token = UUID()
        postSwitchGitDataLoadToken = token
        let workspaceID = workspace.id
        postSwitchGitDataLoadTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            defer {
                if self.postSwitchGitDataLoadToken == token {
                    self.postSwitchGitDataLoadTask = nil
                    self.postSwitchGitDataLoadToken = nil
                }
            }
            await ensureGitDataRootLoadedForActiveWorkspace(
                reason: reason,
                expectedWorkspaceID: workspaceID
            )
        }
    }

    func ensureGitDataRootLoadedForActiveWorkspace(reason: String) async {
        await ensureGitDataRootLoadedForActiveWorkspace(reason: reason, expectedWorkspaceID: nil)
    }

    private func ensureGitDataRootLoadedForActiveWorkspace(reason: String, expectedWorkspaceID: UUID?) async {
        let start = Date()
        #if DEBUG
            let startMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            let expectedIDString = expectedWorkspaceID.map { WorkspaceRestorePerfLog.shortID($0) } ?? "nil"
            let initialWorkspace = activeWorkspace
            var activeWorkspaceIDString = initialWorkspace.map { WorkspaceRestorePerfLog.shortID($0.id) } ?? "nil"
            var activeWorkspaceName = initialWorkspace?.name ?? "nil"
        #endif
        var outcome = "success"
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "workspaceSwitch.gitDataLoad.postSwitch.begin",
                fields: [
                    "workspaceID": activeWorkspaceIDString,
                    "workspaceName": activeWorkspaceName,
                    "expectedWorkspaceID": expectedIDString,
                    "reason": reason
                ]
            )
        #endif
        defer {
            let duration = Date().timeIntervalSince(start)
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "workspaceSwitch.gitDataLoad.postSwitch.end",
                    fields: [
                        "workspaceID": activeWorkspaceIDString,
                        "workspaceName": activeWorkspaceName,
                        "expectedWorkspaceID": expectedIDString,
                        "reason": reason,
                        "outcome": outcome,
                        "duration": startMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? WorkspaceRestorePerfLog.formatMS(duration * 1000)
                    ]
                )
            #endif
        }

        guard !Task.isCancelled else {
            outcome = "cancelled"
            return
        }
        guard let workspace = activeWorkspace else {
            outcome = "noActiveWorkspace"
            return
        }
        #if DEBUG
            activeWorkspaceIDString = WorkspaceRestorePerfLog.shortID(workspace.id)
            activeWorkspaceName = workspace.name
        #endif
        guard workspace.isSystemWorkspace == false else {
            outcome = "systemWorkspace"
            return
        }
        if let expectedWorkspaceID, workspace.id != expectedWorkspaceID {
            outcome = "staleWorkspace"
            return
        }
        guard !isSwitchingWorkspace else {
            outcome = "switchingWorkspace"
            return
        }

        logWorkspaceSwitch("post-switch ensureGitDataRootLoaded BEGIN workspace=\"\(workspace.name)\" reason=\(reason)")
        do {
            _ = try await fileManager.ensureGitDataRootLoaded(
                workspace: workspace,
                workspaceManager: self,
                refreshRootFolderStateAfterLoad: false
            )
            if Task.isCancelled {
                outcome = "cancelled"
            }
        } catch {
            outcome = error is CancellationError ? "cancelled" : "error"
            logWorkspaceSwitch(
                "post-switch ensureGitDataRootLoaded FAILED workspace=\"\(workspace.name)\" " +
                    "reason=\(reason) error=\(error.localizedDescription)"
            )
        }
        logWorkspaceSwitch("post-switch ensureGitDataRootLoaded END workspace=\"\(workspace.name)\" reason=\(reason) duration=\(String(format: "%.3f", Date().timeIntervalSince(start)))s outcome=\(outcome)")
    }

    // MARK: - STATE POLLING

    private func collectWorkspaceState() -> (expandedFolders: [String], selection: StoredSelection, promptText: String, promptIDs: [UUID]) {
        let (name, base) = activeComposeTabContext()
        let snapshot = collectComposeTabSnapshot(name: name, base: base)
        return (snapshot.expandedFolders, snapshot.selection, snapshot.promptText, snapshot.selectedMetaPromptIDs)
    }

    static func selectionForSaveSnapshot(
        liveUISelection: StoredSelection,
        storedSelection: StoredSelection,
        canonicalSelection: StoredSelection?,
        canonicalTabID: UUID?,
        activeTabID: UUID
    ) -> WorkspaceSelectionForSaveDecision {
        if canonicalTabID == activeTabID, let canonicalSelection {
            return WorkspaceSelectionForSaveDecision(selection: canonicalSelection, owner: .canonicalCoordinator)
        }
        _ = liveUISelection // live UI is retained for diagnostics only; stored compose-tab state is canonical fallback.
        return WorkspaceSelectionForSaveDecision(selection: storedSelection, owner: .storedComposeTab)
    }

    private func workspaceSaveMetadata(
        for workspace: WorkspaceModel,
        source: WorkspaceSaveSource,
        owner: WorkspaceSaveOwner? = nil
    ) -> WorkspaceSavePayloadMetadata {
        let activeTabID = workspace.activeComposeTabID ?? workspace.composeTabs.first?.id
        let activeSelection = activeTabID.flatMap { id in workspace.composeTabs.first(where: { $0.id == id })?.selection }
        let key = activeTabID.map { WorkspaceTabSelectionKey(workspaceID: workspace.id, tabID: $0) }
        let candidateRevision = selectionRevision(workspaceID: workspace.id, tabID: activeTabID)
        let recordedSelection = key.flatMap { revisedSelectionByWorkspaceTab[$0] }
        let revision = (candidateRevision > 0 && recordedSelection == activeSelection) ? candidateRevision : 0
        return WorkspaceSavePayloadMetadata(
            source: source,
            owner: owner ?? WorkspaceSaveOwner(windowID: promptViewModel.windowID, managerID: instanceID),
            workspaceID: workspace.id,
            workspaceName: workspace.name,
            workspaceDateModified: workspace.dateModified,
            activeTabID: activeTabID,
            activeSelectionRevision: revision,
            activeSelection: activeSelection
        )
    }

    nonisolated static func metadata(
        for workspace: WorkspaceModel,
        source: WorkspaceSaveSource,
        owner: WorkspaceSaveOwner = .none,
        activeSelectionRevision: UInt64 = 0
    ) -> WorkspaceSavePayloadMetadata {
        let activeTabID = workspace.activeComposeTabID ?? workspace.composeTabs.first?.id
        let activeSelection = activeTabID.flatMap { id in workspace.composeTabs.first(where: { $0.id == id })?.selection }
        return WorkspaceSavePayloadMetadata(
            source: source,
            owner: owner,
            workspaceID: workspace.id,
            workspaceName: workspace.name,
            workspaceDateModified: workspace.dateModified,
            activeTabID: activeTabID,
            activeSelectionRevision: activeSelectionRevision,
            activeSelection: activeSelection
        )
    }

    #if DEBUG
        @MainActor
        private func debugSelectionOwnerTraceEvent(_ phase: String, workspace explicitWorkspace: WorkspaceModel? = nil) {
            guard WorkspaceRestorePerfLog.isEnabled else { return }
            let workspace = explicitWorkspace ?? activeWorkspace
            let workspaceTabID = workspace?.activeComposeTabID ?? workspace?.composeTabs.first?.id
            let workspaceTab = workspaceTabID.flatMap { id in
                workspace?.composeTabs.first(where: { $0.id == id }) ?? composeTab(with: id)
            }
            let coordinatorSnapshot = selectionCoordinator?.activeSelectionSnapshot(flushPendingUI: false)
            let uiSnapshot = fileManager.snapshotSelection()

            var fields: [String: String] = [
                "phase": phase,
                "workspaceID": WorkspaceRestorePerfLog.shortID(workspace?.id),
                "workspaceName": workspace?.name ?? "nil",
                "workspaceTabID": WorkspaceRestorePerfLog.shortID(workspaceTabID),
                "promptTabID": WorkspaceRestorePerfLog.shortID(promptViewModel.activeComposeTabID),
                "coordinatorTabID": WorkspaceRestorePerfLog.shortID(coordinatorSnapshot?.tabID),
                "fileManagerTabID": WorkspaceRestorePerfLog.shortID(fileManager.currentTabIDForDebugOwnerTrace)
            ]
            if let workspaceSelection = workspaceTab?.selection {
                fields.merge(WorkspaceSelectionDebugSignature.fields(for: workspaceSelection, prefix: "workspace")) { current, _ in current }
            }
            if let coordinatorSelection = coordinatorSnapshot?.selection {
                fields.merge(WorkspaceSelectionDebugSignature.fields(for: coordinatorSelection, prefix: "coordinator")) { current, _ in current }
            }
            fields.merge(WorkspaceSelectionDebugSignature.fields(for: uiSnapshot, prefix: "ui")) { current, _ in current }
            WorkspaceRestorePerfLog.event("workspaceSelection.ownerTrace", fields: fields)
        }
    #endif

    private func activeComposeTabContext() -> (String, ComposeTabState?) {
        guard let workspaceID = activeWorkspaceID,
              let index = workspaces.firstIndex(where: { $0.id == workspaceID })
        else {
            return ("Tab", nil)
        }
        let workspace = workspaces[index]
        let activeID = workspace.activeComposeTabID
        let tab = workspace.composeTabs.first(where: { $0.id == activeID }) ?? workspace.composeTabs.first
        let name = tab?.name ?? "Tab"
        return (name, tab)
    }

    func attachSelectionCoordinator(_ coordinator: WorkspaceSelectionCoordinator) {
        selectionCoordinator = coordinator
    }

    func collectComposeTabSnapshot(name: String, base: ComposeTabState? = nil) -> ComposeTabState {
        let resolvedName = name.isEmpty ? (base?.name ?? "Tab") : name
        var snapshot = base ?? ComposeTabState(name: resolvedName)
        snapshot.name = resolvedName
        snapshot.lastModified = Date()

        // Only apply live UI state if this is the currently active tab.
        // For inactive tabs (e.g., when switching workspaces), preserve the base's stored state.
        let isActiveTab = base?.id == promptViewModel.activeComposeTabID

        if isActiveTab {
            // Active tab: capture live state from view models unless a coordinator-driven
            // mirror apply is in progress. During mirror applies the compose-tab
            // StoredSelection is already authoritative; re-snapshotting the UI can
            // create selection feedback loops.
            if selectionCoordinator?.isApplyingSelectionMirror != true {
                let liveUISelection = fileManager.snapshotSelection()
                snapshot.selection = selectionCoordinator?.selectionForActiveUISnapshot(
                    liveUISelection,
                    tabID: snapshot.id
                ) ?? liveUISelection
            }
            snapshot.expandedFolders = fileManager.snapshotExpandedFolderFullPaths()
            snapshot.promptText = promptViewModel.promptText
            snapshot.selectedMetaPromptIDs = promptViewModel.getSelectedPromptIDsSnapshot()
            snapshot.activeSubView = promptViewModel.storedActiveSubView
            snapshot.contextOverrides = promptViewModel.currentContextBuilderOverridesSnapshot()
        }
        // else: keep base's values (already copied when snapshot = base)

        return snapshot
    }

    /// Builds the compose-tab state payload for an MCP tab-context snapshot.
    ///
    /// WorkspaceManager remains the source of persisted compose-tab data. When
    /// `flushPendingUISelection` is requested for the active tab, the selection
    /// coordinator is the only component asked to flush/return active selection;
    /// inactive tabs always return their stored `ComposeTabState` unchanged.
    @MainActor
    func collectMCPTabContextComposeSnapshot(
        tabID: UUID,
        workspaceID requestedWorkspaceID: UUID? = nil,
        captureActiveUIState: Bool,
        flushPendingUISelection: Bool
    ) -> (workspaceID: UUID, snapshot: ComposeTabState)? {
        let workspaceIndex: Int? = if let requestedWorkspaceID {
            workspaces.firstIndex(where: { $0.id == requestedWorkspaceID })
        } else {
            workspaces.firstIndex { workspace in
                workspace.composeTabs.contains(where: { $0.id == tabID })
            }
        }

        guard let workspaceIndex,
              workspaces.indices.contains(workspaceIndex),
              let tabIndex = workspaces[workspaceIndex].composeTabs.firstIndex(where: { $0.id == tabID })
        else {
            return nil
        }

        let workspace = workspaces[workspaceIndex]
        let base = workspace.composeTabs[tabIndex]
        let isActiveTab = workspace.id == activeWorkspaceID && tabID == promptViewModel.activeComposeTabID
        guard isActiveTab, captureActiveUIState else {
            return (workspace.id, base)
        }

        var snapshot = collectComposeTabSnapshot(name: base.name, base: base)
        if flushPendingUISelection,
           let activeSelectionSnapshot = selectionCoordinator?.activeSelectionSnapshot(flushPendingUI: true),
           activeSelectionSnapshot.tabID == tabID
        {
            snapshot.selection = activeSelectionSnapshot.selection
        }
        return (workspace.id, snapshot)
    }

    /// Returns the current expanded folder paths for creating a new tab.
    /// Inherits from live UI if active workspace, otherwise from stored tab state.
    @MainActor
    func expandedFoldersSnapshotForNewTab(workspaceIndex: Int) -> [String] {
        guard workspaces.indices.contains(workspaceIndex) else { return [] }

        let ws = workspaces[workspaceIndex]

        // Active workspace: use live snapshot from file manager
        if ws.id == activeWorkspaceID {
            return fileManager.snapshotExpandedFolderFullPaths()
        }

        // Inactive workspace: use stored tab state
        let activeID = ws.activeComposeTabID
        let tab = ws.composeTabs.first(where: { $0.id == activeID }) ?? ws.composeTabs.first
        return tab?.expandedFolders ?? []
    }

    /// Safely retrieve a tab snapshot by its ID from the active workspace
    /// Returns nil if the tab is not found in the active workspace
    func composeTabSnapshot(for tabID: UUID) -> ComposeTabState? {
        guard let workspaceID = activeWorkspaceID,
              let index = workspaceIndexMap[workspaceID],
              workspaces.indices.contains(index) else { return nil }
        return workspaces[index].composeTabs.first(where: { $0.id == tabID })
    }

    // MARK: - In-memory snapshot publishing (no disk I/O)

    /// In-memory commit of the active tab (no disk save)
    @MainActor
    private func updateComposeTabFastNoDirty(_ tab: ComposeTabState, touchModified: Bool = false) {
        guard let activeWorkspaceID,
              let workspaceIndex = workspaces.firstIndex(where: { $0.id == activeWorkspaceID }),
              let tabIndex = workspaces[workspaceIndex].composeTabs.firstIndex(where: { $0.id == tab.id })
        else { return }

        let oldSelection = workspaces[workspaceIndex].composeTabs[tabIndex].selection
        var updatedTab = tab
        if touchModified { updatedTab.lastModified = Date() }
        workspaces[workspaceIndex].composeTabs[tabIndex] = updatedTab
        recordSelectionRevisionIfChanged(
            workspaceIndex: workspaceIndex,
            tabIndex: tabIndex,
            oldSelection: oldSelection,
            newSelection: updatedTab.selection,
            reason: "updateComposeTabFastNoDirty.uiSnapshotCommit"
        )
    }

    /// Build a fresh snapshot of the active tab, optionally commit to memory, then publish.
    /// This does NOT write to disk.
    @MainActor
    func publishActiveComposeTabSnapshot(commitToMemory: Bool = true, touchModified: Bool = false) {
        let (name, base) = activeComposeTabContext()

        // NEW: Suppress snapshot emissions for non-target tabs while an MCP tab-context apply is running
        if let applyingID = applyingTabContextID, let activeBase = base, activeBase.id != applyingID {
            // Drop transient emission entirely to prevent cross-tab state contamination
            return
        }
        if selectionCoordinator?.isApplyingSelectionMirror == true {
            return
        }
        if let activeBase = base,
           activationSnapshotSuspendedTabIDs.contains(activeBase.id)
        {
            return
        }

        let snapshot = collectComposeTabSnapshot(name: name, base: base)

        // Respect per-tab suspension: avoid mutating composeTabs during UI apply,
        // so mirroring can treat these as transient snapshots.
        let shouldCommit: Bool = commitToMemory && !isSnapshotCommitSuspended(forTabID: snapshot.id)
        let didChange = Self.composeTabSnapshotHasMeaningfulChanges(snapshot, comparedTo: base, touchModified: touchModified)
        guard didChange else { return }
        if shouldCommit {
            updateComposeTabFastNoDirty(snapshot, touchModified: touchModified)
        }
        composeTabSnapshotSubject.send(snapshot)
    }

    private static func composeTabSnapshotHasMeaningfulChanges(
        _ snapshot: ComposeTabState,
        comparedTo base: ComposeTabState?,
        touchModified: Bool
    ) -> Bool {
        guard let baseline = base else { return true }
        var comparableSnapshot = snapshot
        if !touchModified {
            comparableSnapshot.lastModified = baseline.lastModified
        }
        return comparableSnapshot != baseline
    }

    @MainActor
    func setSnapshotsSuspended(_ suspended: Bool, forTabID id: UUID) {
        if suspended {
            suspendedSnapshotCommitTabIDs.insert(id)
        } else {
            suspendedSnapshotCommitTabIDs.remove(id)
        }
    }

    @MainActor
    private func isSnapshotCommitSuspended(forTabID id: UUID) -> Bool {
        suspendedSnapshotCommitTabIDs.contains(id)
            || activationSnapshotSuspendedTabIDs.contains(id)
            || applyingTabContextID == id
            || applyingTabContextDepthByTabID[id, default: 0] > 0
    }

    @MainActor
    func beginApplyingTabContext(forTabID id: UUID) {
        let nextDepth = applyingTabContextDepthByTabID[id, default: 0] + 1
        applyingTabContextDepthByTabID[id] = nextDepth
        applyingTabContextID = id
        if nextDepth == 1 {
            setSnapshotsSuspended(true, forTabID: id)
        }
    }

    @MainActor
    func endApplyingTabContext(forTabID id: UUID) {
        guard let depth = applyingTabContextDepthByTabID[id] else { return }
        if depth > 1 {
            applyingTabContextDepthByTabID[id] = depth - 1
            return
        }
        applyingTabContextDepthByTabID.removeValue(forKey: id)
        if applyingTabContextID == id {
            applyingTabContextID = nil
        }
        setSnapshotsSuspended(false, forTabID: id)
    }

    @MainActor
    func applyComposeTabState(_ tab: ComposeTabState) async {
        await applyComposeTabStateInternal(tabID: tab.id, markWorkspaceDirtyAfterApply: false)
    }

    @MainActor
    func applyComposeTabStateAsync(tab: ComposeTabState, windowID: Int? = nil) async {
        _ = windowID
        composeTabApplyTask?.cancel()
        composeTabApplyTaskID = UUID()
        let taskID = composeTabApplyTaskID
        let tabID = tab.id

        let applyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.composeTabApplyTaskID == taskID {
                    self.composeTabApplyTask = nil
                }
            }
            await applyComposeTabStateInternal(tabID: tabID, markWorkspaceDirtyAfterApply: true)
        }

        composeTabApplyTask = applyTask
        await applyTask.value
    }

    @MainActor
    private func applyComposeTabStateInternal(
        tabID: UUID,
        markWorkspaceDirtyAfterApply: Bool,
        performFinalRecount: Bool = true
    ) async {
        guard let initialTab = composeTab(with: tabID) else { return }
        beginApplyingTabContext(forTabID: tabID)
        promptViewModel.tokenCountingViewModel.suspendAutomaticRecounts()
        defer {
            promptViewModel.tokenCountingViewModel.resumeAutomaticRecounts()
            endApplyingTabContext(forTabID: tabID)
        }

        await applyComposeTabFastUIState(initialTab)
        await Task.yield()
        guard !Task.isCancelled else { return }
        guard let refreshedTab = composeTab(with: tabID) else { return }
        await applyComposeTabHeavyFileState(refreshedTab)
        guard !Task.isCancelled else { return }
        if performFinalRecount {
            await promptViewModel.tokenCountingViewModel.forceImmediateRecount()
        }
        guard markWorkspaceDirtyAfterApply else { return }
        if markWorkspaceDirtyIfTabStillActive(tabID: tabID) {
            pollAndSaveState()
        }
    }

    @MainActor
    private func applyComposeTabFastUIState(_ tab: ComposeTabState) async {
        promptViewModel.promptText = tab.promptText
        // NOTE: We no longer apply tab.selectedMetaPromptIDs here.
        // Prompt selection should follow the copy preset, not be overridden per-tab.
        // The preset's stored prompt selection is managed at the workspace level.

        if let explicit = tab.activeSubView {
            promptViewModel.setFilesTabSelection(.explicit(explicit), source: .workspaceApply)
        } else {
            promptViewModel.setFilesTabSelection(.followDefault, source: .workspaceApply)
        }
        await promptViewModel.applyContextBuilderOverrides(tab.contextOverrides)
        fileManager.onActiveTabChangedFast(tab)
    }

    @MainActor
    private func applyComposeTabHeavyFileState(_ tab: ComposeTabState) async {
        guard !Task.isCancelled else { return }
        guard let active = activeWorkspace, active.activeComposeTabID == tab.id else { return }
        await fileManager.restoreExpansionState(from: tab.expandedFolders)
        await fileManager.onActiveTabChangedHeavy(for: tab.id, selection: tab.selection)
        selectionCoordinator?.refreshDeferredUISelectionFence(forTabID: tab.id)
    }

    private struct ComposeTabHeavyFileStateSnapshot {
        let tabID: UUID
    }

    private func activeComposeTabHeavyFileStateSnapshot(
        in workspace: WorkspaceModel
    ) -> ComposeTabHeavyFileStateSnapshot? {
        guard let activeTabID = workspace.activeComposeTabID,
              workspace.composeTabs.contains(where: { $0.id == activeTabID })
        else { return nil }
        return ComposeTabHeavyFileStateSnapshot(tabID: activeTabID)
    }

    @MainActor
    private func replayActiveComposeTabHeavyFileStateAfterHydration(
        _ snapshot: ComposeTabHeavyFileStateSnapshot?,
        workspaceID: UUID
    ) async {
        guard let snapshot,
              let workspace = activeWorkspace, workspace.id == workspaceID,
              workspace.activeComposeTabID == snapshot.tabID,
              let currentTab = workspace.composeTabs.first(where: { $0.id == snapshot.tabID })
        else { return }

        beginApplyingTabContext(forTabID: snapshot.tabID)
        defer { endApplyingTabContext(forTabID: snapshot.tabID) }
        await fileManager.withDeferredSelectionSliceSnapshotRebuild(reason: "workspaceRestore.postHydrationReplay") {
            await fileManager.restoreExpansionState(from: currentTab.expandedFolders)
            await fileManager.onActiveTabChangedHeavy(for: currentTab.id, selection: currentTab.selection)
            selectionCoordinator?.refreshDeferredUISelectionFence(forTabID: currentTab.id)
        }
    }

    @MainActor
    private func markWorkspaceDirtyIfTabStillActive(tabID: UUID) -> Bool {
        guard
            let active = activeWorkspace,
            active.activeComposeTabID == tabID,
            let index = workspaces.firstIndex(where: { $0.id == active.id })
        else { return false }

        workspaces[index].dateModified = Date()
        markWorkspaceDirty()
        return true
    }

    private static func resolveComposeTabRoutingSnapshot(
        tabID: UUID,
        workspaces: [WorkspaceModel],
        activeWorkspaceID: UUID?,
        activeComposeTabID: UUID?,
        captureActiveUIState: Bool,
        liveSnapshotProvider: (ComposeTabState) -> ComposeTabState
    ) -> (workspaceID: UUID, snapshot: ComposeTabState, usesLiveUIState: Bool)? {
        for workspace in workspaces {
            guard let tab = workspace.composeTabs.first(where: { $0.id == tabID }) else { continue }
            let usesLiveUIState = captureActiveUIState
                && workspace.id == activeWorkspaceID
                && tab.id == activeComposeTabID
            let snapshot = usesLiveUIState ? liveSnapshotProvider(tab) : tab
            return (workspace.id, snapshot, usesLiveUIState)
        }
        return nil
    }

    func resolveComposeTabRoutingSnapshot(
        for tabID: UUID,
        captureActiveUIState: Bool = true
    ) -> (workspaceID: UUID, snapshot: ComposeTabState, usesLiveUIState: Bool)? {
        Self.resolveComposeTabRoutingSnapshot(
            tabID: tabID,
            workspaces: workspaces,
            activeWorkspaceID: activeWorkspaceID,
            activeComposeTabID: promptViewModel.activeComposeTabID,
            captureActiveUIState: captureActiveUIState
        ) { [weak self] base in
            guard let self else { return base }
            return collectComposeTabSnapshot(name: base.name, base: base)
        }
    }

    static func test_resolveComposeTabRoutingSnapshot(
        for tabID: UUID,
        workspaces: [WorkspaceModel],
        activeWorkspaceID: UUID?,
        activeComposeTabID: UUID?,
        captureActiveUIState: Bool = true,
        liveSnapshotProvider: (ComposeTabState) -> ComposeTabState = { $0 }
    ) -> (workspaceID: UUID, snapshot: ComposeTabState, usesLiveUIState: Bool)? {
        resolveComposeTabRoutingSnapshot(
            tabID: tabID,
            workspaces: workspaces,
            activeWorkspaceID: activeWorkspaceID,
            activeComposeTabID: activeComposeTabID,
            captureActiveUIState: captureActiveUIState,
            liveSnapshotProvider: liveSnapshotProvider
        )
    }

    struct ComposeTabBindingCandidate: Equatable {
        let tabID: UUID
        let workspaceID: UUID
        let workspaceName: String
        let isActiveInWorkspace: Bool
        let repoPaths: [String]
    }

    func composeTab(with id: UUID) -> ComposeTabState? {
        for workspace in workspaces {
            if let tab = workspace.composeTabs.first(where: { $0.id == id }) {
                return tab
            }
        }
        return nil
    }

    func composeTab(for identity: WorkspaceSelectionIdentity) -> ComposeTabState? {
        workspaces.first(where: { $0.id == identity.workspaceID })?
            .composeTabs.first(where: { $0.id == identity.tabID })
    }

    func composeTabName(with id: UUID) -> String? {
        composeTab(with: id)?.name
    }

    func bindingCandidate(forContextID id: UUID) -> ComposeTabBindingCandidate? {
        for workspace in workspaces {
            guard let tab = workspace.composeTabs.first(where: { $0.id == id }) else { continue }
            return ComposeTabBindingCandidate(
                tabID: tab.id,
                workspaceID: workspace.id,
                workspaceName: workspace.name,
                isActiveInWorkspace: workspace.activeComposeTabID == tab.id,
                repoPaths: workspace.repoPaths
            )
        }
        return nil
    }

    func bindingCandidates(matchingWorkingDirs dirs: [String], includeHidden: Bool = false) -> [ComposeTabBindingCandidate] {
        Self.bindingCandidates(
            matchingWorkingDirs: dirs,
            workspaces: workspaces,
            activeWorkspaceID: activeWorkspaceID,
            includeHidden: includeHidden
        )
    }

    func hasAnyWorkspaceMatch(matchingWorkingDirs dirs: [String]) -> Bool {
        Self.hasAnyWorkspaceMatch(matchingWorkingDirs: dirs, workspaces: workspaces)
    }

    nonisolated static func test_bindingCandidates(
        matchingWorkingDirs dirs: [String],
        workspaces: [WorkspaceModel],
        activeWorkspaceID: UUID?,
        includeHidden: Bool = false
    ) -> [ComposeTabBindingCandidate] {
        bindingCandidates(
            matchingWorkingDirs: dirs,
            workspaces: workspaces,
            activeWorkspaceID: activeWorkspaceID,
            includeHidden: includeHidden
        )
    }

    nonisolated static func test_hasAnyWorkspaceMatch(
        matchingWorkingDirs dirs: [String],
        workspaces: [WorkspaceModel]
    ) -> Bool {
        hasAnyWorkspaceMatch(matchingWorkingDirs: dirs, workspaces: workspaces)
    }

    nonisolated static func normalizedExactWorkspaceDirectorySet(_ paths: [String]) -> [String] {
        WorkspaceRootSetKey(paths: paths).normalizedPaths
    }

    private nonisolated static func sortedWorkspaceMatches(_ workspaces: [WorkspaceModel]) -> [WorkspaceModel] {
        workspaces.sorted { lhs, rhs in
            let lhsKey = lhs.name.lowercased()
            let rhsKey = rhs.name.lowercased()
            if lhsKey != rhsKey {
                return lhsKey < rhsKey
            }
            if lhs.name != rhs.name {
                return lhs.name < rhs.name
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    nonisolated static func exactWorkspaceMatches(
        forNormalizedWorkingDirs normalizedWorkingDirs: [String],
        workspaces: [WorkspaceModel],
        includeHidden: Bool = true
    ) -> [WorkspaceModel] {
        let requestedRootSetKey = WorkspaceRootSetKey(paths: normalizedWorkingDirs)
        guard !requestedRootSetKey.isEmpty else { return [] }
        return sortedWorkspaceMatches(workspaces.filter { workspace in
            !workspace.isSystemWorkspace
                && (includeHidden || !workspace.isHiddenInMenus)
                && WorkspaceRootSetKey(paths: workspace.repoPaths) == requestedRootSetKey
        })
    }

    nonisolated static func supersetWorkspaceMatches(
        forNormalizedWorkingDirs normalizedWorkingDirs: [String],
        workspaces: [WorkspaceModel],
        includeHidden: Bool = true
    ) -> [WorkspaceModel] {
        let requestedRootSetKey = WorkspaceRootSetKey(paths: normalizedWorkingDirs)
        guard !requestedRootSetKey.isEmpty else { return [] }
        let requestedDirectories = Set(requestedRootSetKey.normalizedPaths.map { $0.lowercased() })
        return sortedWorkspaceMatches(workspaces.filter { workspace in
            guard !workspace.isSystemWorkspace,
                  includeHidden || !workspace.isHiddenInMenus else { return false }
            let workspaceRootSetKey = WorkspaceRootSetKey(paths: workspace.repoPaths)
            let workspaceDirectories = Set(workspaceRootSetKey.normalizedPaths.map { $0.lowercased() })
            return workspaceDirectories.count > requestedDirectories.count
                && workspaceDirectories.isSuperset(of: requestedDirectories)
        })
    }

    nonisolated static func test_exactWorkspaceMatches(
        forWorkingDirs workingDirs: [String],
        workspaces: [WorkspaceModel],
        includeHidden: Bool = true
    ) -> [WorkspaceModel] {
        exactWorkspaceMatches(
            forNormalizedWorkingDirs: workingDirs,
            workspaces: workspaces,
            includeHidden: includeHidden
        )
    }

    nonisolated static func test_supersetWorkspaceMatches(
        forWorkingDirs workingDirs: [String],
        workspaces: [WorkspaceModel],
        includeHidden: Bool = true
    ) -> [WorkspaceModel] {
        supersetWorkspaceMatches(
            forNormalizedWorkingDirs: workingDirs,
            workspaces: workspaces,
            includeHidden: includeHidden
        )
    }

    private nonisolated static func bindingCandidates(
        matchingWorkingDirs dirs: [String],
        workspaces: [WorkspaceModel],
        activeWorkspaceID: UUID?,
        includeHidden: Bool = false
    ) -> [ComposeTabBindingCandidate] {
        let normalizedDirs = normalizedBindingDirs(dirs)
        guard !normalizedDirs.isEmpty,
              let activeWorkspaceID,
              let workspace = workspaces.first(where: { $0.id == activeWorkspaceID }),
              includeHidden || !workspace.isHiddenInMenus,
              workspaceMatchesWorkingDirs(workspace, normalizedDirs: normalizedDirs)
        else {
            return []
        }

        let tab = workspace.composeTabs.first(where: { $0.id == workspace.activeComposeTabID }) ?? workspace.composeTabs.first
        guard let tab else { return [] }
        return [
            ComposeTabBindingCandidate(
                tabID: tab.id,
                workspaceID: workspace.id,
                workspaceName: workspace.name,
                isActiveInWorkspace: workspace.activeComposeTabID == tab.id,
                repoPaths: workspace.repoPaths
            )
        ]
    }

    private nonisolated static func hasAnyWorkspaceMatch(
        matchingWorkingDirs dirs: [String],
        workspaces: [WorkspaceModel]
    ) -> Bool {
        let normalizedDirs = normalizedBindingDirs(dirs)
        guard !normalizedDirs.isEmpty else { return false }
        return workspaces.contains { workspace in
            workspaceMatchesWorkingDirs(workspace, normalizedDirs: normalizedDirs)
        }
    }

    private nonisolated static func normalizedBindingDirs(_ dirs: [String]) -> [String] {
        dirs.map(normalizeBindingPath).filter { !$0.isEmpty }
    }

    private nonisolated static func workspaceMatchesWorkingDirs(
        _ workspace: WorkspaceModel,
        normalizedDirs: [String]
    ) -> Bool {
        let normalizedRoots = workspace.repoPaths.map(Self.normalizeBindingPath).filter { !$0.isEmpty }
        guard !normalizedRoots.isEmpty else { return false }
        return normalizedDirs.allSatisfy { dir in
            normalizedRoots.contains { root in
                Self.bindingPath(dir, isWithinOrEqualTo: root)
            }
        }
    }

    private nonisolated static func normalizeBindingPath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private nonisolated static func bindingPath(_ child: String, isWithinOrEqualTo parent: String) -> Bool {
        if child == parent { return true }
        let normalizedParent = parent.hasSuffix("/") ? parent : parent + "/"
        return child.hasPrefix(normalizedParent)
    }

    func composeTabNameLookup(forWorkspaceID workspaceID: UUID) -> [UUID: String] {
        guard let index = workspaceIndexMap[workspaceID], workspaces.indices.contains(index) else {
            return [:]
        }
        // Compose tab IDs are expected to be unique, but use a
        // duplicate-tolerant (last-wins) init so we never SIGTRAP if a bug
        // ever produces a duplicate — a stale name lookup is strictly
        // better than a crash.
        return Dictionary(
            workspaces[index].composeTabs.map { ($0.id, $0.name) },
            uniquingKeysWith: { _, last in last }
        )
    }

    @MainActor
    func setActiveChatSessionID(_ sessionID: UUID?, forTabID tabID: UUID) {
        guard var tab = composeTab(with: tabID) else { return }
        tab.activeChatSessionID = sessionID
        updateComposeTabStoredOnly(tab)
    }

    @MainActor
    func activeChatSessionID(forTabID tabID: UUID) -> UUID? {
        composeTab(with: tabID)?.activeChatSessionID
    }

    struct ActiveAgentSessionReferenceCleanupResult: Equatable {
        let composeTabIDs: Set<UUID>
        let stashedTabIDs: Set<UUID>

        var didChange: Bool {
            !composeTabIDs.isEmpty || !stashedTabIDs.isEmpty
        }
    }

    @MainActor
    func activeAgentSessionID(forTabID tabID: UUID, inWorkspaceID workspaceID: UUID? = nil) -> UUID? {
        for workspace in workspaces where workspaceID == nil || workspace.id == workspaceID {
            if let tab = workspace.composeTabs.first(where: { $0.id == tabID }) {
                return tab.activeAgentSessionID
            }
            if let stashed = workspace.stashedTabs.first(where: { $0.tab.id == tabID }) {
                return stashed.tab.activeAgentSessionID
            }
        }
        return nil
    }

    @MainActor
    @discardableResult
    func clearActiveAgentSessionIDReferences(
        matching sessionID: UUID,
        inWorkspaceID workspaceID: UUID? = nil
    ) -> ActiveAgentSessionReferenceCleanupResult {
        var composeTabIDs = Set<UUID>()
        var stashedTabIDs = Set<UUID>()
        var changedWorkspaceIDs = Set<UUID>()
        let now = Date()

        for workspaceIndex in workspaces.indices where workspaceID == nil || workspaces[workspaceIndex].id == workspaceID {
            var didChangeWorkspace = false

            for tabIndex in workspaces[workspaceIndex].composeTabs.indices
                where workspaces[workspaceIndex].composeTabs[tabIndex].activeAgentSessionID == sessionID
            {
                let tabID = workspaces[workspaceIndex].composeTabs[tabIndex].id
                workspaces[workspaceIndex].composeTabs[tabIndex].activeAgentSessionID = nil
                workspaces[workspaceIndex].composeTabs[tabIndex].lastModified = now
                composeTabIDs.insert(tabID)
                didChangeWorkspace = true
            }

            for stashedIndex in workspaces[workspaceIndex].stashedTabs.indices
                where workspaces[workspaceIndex].stashedTabs[stashedIndex].tab.activeAgentSessionID == sessionID
            {
                let tabID = workspaces[workspaceIndex].stashedTabs[stashedIndex].tab.id
                workspaces[workspaceIndex].stashedTabs[stashedIndex].tab.activeAgentSessionID = nil
                workspaces[workspaceIndex].stashedTabs[stashedIndex].tab.lastModified = now
                stashedTabIDs.insert(tabID)
                didChangeWorkspace = true
            }

            if didChangeWorkspace {
                workspaces[workspaceIndex].dateModified = now
                changedWorkspaceIDs.insert(workspaces[workspaceIndex].id)
            }
        }

        for id in changedWorkspaceIDs {
            bumpStateVersion(for: id)
        }
        if !changedWorkspaceIDs.isEmpty {
            let workspacesToSave = workspaces.filter { changedWorkspaceIDs.contains($0.id) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for workspace in workspacesToSave {
                    _ = try? await saveWorkspaceToFileAsync(workspace, source: .clearActiveAgentSessionIDReferences)
                }
            }
        }

        return ActiveAgentSessionReferenceCleanupResult(
            composeTabIDs: composeTabIDs,
            stashedTabIDs: stashedTabIDs
        )
    }

    @MainActor
    @discardableResult
    func compareAndSetActiveAgentSessionID(
        expected expectedSessionID: UUID?,
        replacement sessionID: UUID?,
        forTabID tabID: UUID,
        inWorkspaceID workspaceID: UUID? = nil
    ) -> Bool {
        for workspaceIndex in workspaces.indices where workspaceID == nil || workspaces[workspaceIndex].id == workspaceID {
            if let tabIndex = workspaces[workspaceIndex].composeTabs.firstIndex(where: { $0.id == tabID }) {
                guard workspaces[workspaceIndex].composeTabs[tabIndex].activeAgentSessionID == expectedSessionID else { return false }
                workspaces[workspaceIndex].composeTabs[tabIndex].activeAgentSessionID = sessionID
                workspaces[workspaceIndex].composeTabs[tabIndex].lastModified = Date()
                workspaces[workspaceIndex].dateModified = Date()
                markWorkspaceDirty()
                return true
            }

            if let stashedIndex = workspaces[workspaceIndex].stashedTabs.firstIndex(where: { $0.tab.id == tabID }) {
                guard workspaces[workspaceIndex].stashedTabs[stashedIndex].tab.activeAgentSessionID == expectedSessionID else { return false }
                workspaces[workspaceIndex].stashedTabs[stashedIndex].tab.activeAgentSessionID = sessionID
                workspaces[workspaceIndex].stashedTabs[stashedIndex].tab.lastModified = Date()
                workspaces[workspaceIndex].dateModified = Date()
                markWorkspaceDirty()
                return true
            }
        }
        return false
    }

    func updateComposeTab(_ tab: ComposeTabState, markDirty: Bool = true) {
        for workspaceIndex in workspaces.indices {
            if let tabIndex = workspaces[workspaceIndex].composeTabs.firstIndex(where: { $0.id == tab.id }) {
                let oldSelection = workspaces[workspaceIndex].composeTabs[tabIndex].selection
                workspaces[workspaceIndex].composeTabs[tabIndex] = tab
                recordSelectionRevisionIfChanged(
                    workspaceIndex: workspaceIndex,
                    tabIndex: tabIndex,
                    oldSelection: oldSelection,
                    newSelection: tab.selection,
                    reason: "updateComposeTab"
                )
                workspaces[workspaceIndex].dateModified = Date()
                if workspaces[workspaceIndex].id == activeWorkspaceID {
                    // Sync promptText to live UI if updating the active tab
                    let isActiveTab = workspaces[workspaceIndex].activeComposeTabID == tab.id
                    promptViewModel.loadComposeTabsFromWorkspace(workspaces[workspaceIndex], syncPromptText: isActiveTab)
                }
                if markDirty {
                    markWorkspaceDirty()
                }
                return
            }
        }
    }

    /// Performs one selection mirror attempt. The coordinator owns identity fencing and repair.
    @MainActor
    func applySelectionMirrorAttempt(
        _ selection: StoredSelection,
        forTabID tabID: UUID,
        workspaceID: UUID
    ) async {
        guard let active = activeWorkspace,
              active.id == workspaceID,
              active.activeComposeTabID == tabID
        else { return }

        beginApplyingTabContext(forTabID: tabID)
        defer { endApplyingTabContext(forTabID: tabID) }
        await fileManager.applyStoredSelection(selection)
        promptViewModel.tokenCountingViewModel.markDirty(.selection)
    }

    /// Applies the newest stored selection after deferred `read_file` auto-selection.
    @MainActor
    func applyStoredSelectionMirrorForReadFileAutoSelection(tabID: UUID) async {
        guard let active = activeWorkspace,
              active.activeComposeTabID == tabID,
              let tab = composeTab(with: tabID)
        else { return }
        if let selectionCoordinator {
            await selectionCoordinator.mirrorSelectionToActiveUI(tab.selection, forTabID: tabID)
        } else {
            await applySelectionMirrorAttempt(
                tab.selection,
                forTabID: tabID,
                workspaceID: active.id
            )
        }
    }

    func updateComposeTabSelectionPresentation(_ selection: StoredSelection, forTabID tabID: UUID) {
        promptViewModel.updateComposeTabSelectionPresentation(selection, forTabID: tabID)
    }

    func updateComposeTabSelectionPresentation(
        _ selection: StoredSelection,
        for identity: WorkspaceSelectionIdentity
    ) {
        guard activeWorkspaceID == identity.workspaceID else { return }
        promptViewModel.updateComposeTabSelectionPresentation(selection, forTabID: identity.tabID)
    }

    /// Keeps MCP-owned compose-tab selection canonical across the exact peer hosts that were
    /// open when the source mutation registered. Host generations prevent delayed work from
    /// crossing a manager replacement/reopen boundary, and closing windows are rechecked before
    /// any canonical or UI mutation occurs.
    @MainActor
    func propagateMCPSelectionToPeerHosts(_ propagation: MCPSelectionPeerPropagation) async {
        var visitedManagers = Set<ObjectIdentifier>()
        visitedManagers.insert(ObjectIdentifier(self))
        for window in WindowStatesManager.shared.allWindows {
            guard !window.isClosing else { continue }
            let peer = window.workspaceManager
            let peerMutationFence = MCPSelectionPeerMutationFence(
                hostID: peer.mcpSelectionPropagationHostID
            )
            guard propagation.peerHostIDs.contains(peerMutationFence.hostID),
                  peer.canCommitMCPSelectionPeerMutation(peerMutationFence),
                  visitedManagers.insert(ObjectIdentifier(peer)).inserted,
                  let tab = peer.composeTab(for: propagation.identity)
            else { continue }

            if let peerCoordinator = peer.selectionCoordinator {
                _ = await peerCoordinator.persistSelection(
                    propagation.selection,
                    for: propagation.identity,
                    source: .mcpPeerContext,
                    mirrorToUIIfActive: propagation.mirrorToUIIfActive,
                    peerSourceRevision: propagation.sourceRevision,
                    peerMutationFence: peerMutationFence
                )
            } else {
                guard peer.canCommitMCPSelectionPeerMutation(peerMutationFence),
                      peer.acceptMCPPeerSelectionRevision(
                          propagation.sourceRevision,
                          for: propagation.identity
                      ) else { continue }
                if tab.selection != propagation.selection {
                    guard peer.canCommitMCPSelectionPeerMutation(peerMutationFence) else { continue }
                    var updatedTab = tab
                    updatedTab.selection = propagation.selection
                    _ = peer.updateComposeTabStoredOnly(
                        updatedTab,
                        inWorkspaceID: propagation.identity.workspaceID
                    )
                }
                guard peer.canCommitMCPSelectionPeerMutation(peerMutationFence) else { continue }
                peer.updateComposeTabSelectionPresentation(
                    propagation.selection,
                    for: propagation.identity
                )
                if propagation.mirrorToUIIfActive,
                   peer.canCommitMCPSelectionPeerMutation(peerMutationFence),
                   peer.activeWorkspace?.id == propagation.identity.workspaceID,
                   peer.activeWorkspace?.activeComposeTabID == propagation.identity.tabID
                {
                    await peer.applySelectionMirrorAttempt(
                        propagation.selection,
                        forTabID: propagation.identity.tabID,
                        workspaceID: propagation.identity.workspaceID
                    )
                }
            }
        }
    }

    /// Silent "stored-only" update: updates the compose tab in the backing store
    /// without reloading PromptViewModel's compose tabs or publishing snapshots.
    /// Used by MCP virtual context commits to avoid triggering empty live-UI snapshots.
    @MainActor
    func updateComposeTabStoredOnly(_ tab: ComposeTabState) {
        guard let workspaceID = workspaces.first(where: { workspace in
            workspace.composeTabs.contains(where: { $0.id == tab.id })
        })?.id else { return }
        _ = updateComposeTabStoredOnly(tab, inWorkspaceID: workspaceID)
    }

    /// Exact-identity stored update. This avoids duplicate-tab ambiguity and dirties the
    /// workspace that was actually mutated rather than whichever workspace is active.
    @MainActor
    @discardableResult
    func updateComposeTabStoredOnly(_ tab: ComposeTabState, inWorkspaceID workspaceID: UUID) -> Bool {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }),
              let tabIndex = workspaces[workspaceIndex].composeTabs.firstIndex(where: { $0.id == tab.id })
        else { return false }

        let oldSelection = workspaces[workspaceIndex].composeTabs[tabIndex].selection
        var updatedTab = tab
        updatedTab.lastModified = Date()
        workspaces[workspaceIndex].composeTabs[tabIndex] = updatedTab
        recordSelectionRevisionIfChanged(
            workspaceIndex: workspaceIndex,
            tabIndex: tabIndex,
            oldSelection: oldSelection,
            newSelection: updatedTab.selection,
            reason: "updateComposeTabStoredOnly"
        )
        workspaces[workspaceIndex].dateModified = Date()

        // Important: do NOT call promptViewModel.loadComposeTabsFromWorkspace(...)
        // and do NOT publish snapshots here. We only persist the stored tab data.
        bumpStateVersion(for: workspaceID)
        return true
    }

    nonisolated static func rebasedStoredSelectionSlices(
        _ selection: StoredSelection,
        for fullPath: String,
        transform: ([LineRange]) -> [LineRange]
    ) -> StoredSelection? {
        guard let standardizedFullPath = StoredSelectionPathNormalization.standardizedPath(fullPath) else {
            return nil
        }

        let normalizedSlices = StoredSelectionPathNormalization.standardizedSlices(selection.slices)
        guard let existingRanges = normalizedSlices[standardizedFullPath] else {
            return nil
        }

        let nextRanges = SliceRangeMath.normalize(transform(existingRanges))
        var nextSlices = normalizedSlices
        if nextRanges.isEmpty {
            nextSlices.removeValue(forKey: standardizedFullPath)
        } else {
            nextSlices[standardizedFullPath] = nextRanges
        }

        guard nextSlices != selection.slices else { return nil }
        return StoredSelection(
            selectedPaths: selection.selectedPaths,
            manualCodemapPaths: selection.manualCodemapPaths,
            slices: nextSlices,
            codemapAutoEnabled: selection.codemapAutoEnabled
        )
    }

    nonisolated static func normalizedPresetPath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let standardized = StandardizedPath.absolute(trimmed)
        if standardized.hasPrefix("/") {
            return standardized
        }
        return StandardizedPath.relative(trimmed)
    }

    nonisolated static func isPresetSelectionDirty(
        presetPaths: [String],
        selectionPaths: [(absolute: String, relative: String)]
    ) -> Bool {
        let selAbs = Set(selectionPaths.map(\.absolute))
        let selRel = Set(selectionPaths.map(\.relative))
        let presetStd = Set(presetPaths.compactMap(normalizedPresetPath))

        let presetCovered = presetStd.allSatisfy { path in
            if path.hasPrefix("/") {
                return selAbs.contains(path)
            }
            return selRel.contains(path)
        }

        let selectionCovered = selectionPaths.allSatisfy { path in
            presetStd.contains(path.absolute) || presetStd.contains(path.relative)
        }

        return !(presetCovered && selectionCovered)
    }

    @MainActor
    func dropSlicesForFileAcrossTabs(fullPath: String) {
        rebaseSlicesForFileAcrossTabs(fullPath: fullPath) { _ in [] }
    }

    @MainActor
    func rebaseSlicesForFileAcrossTabs(
        fullPath: String,
        transform: ([LineRange]) -> [LineRange]
    ) {
        guard let workspaceID = activeWorkspaceID,
              let wi = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }

        let tabs = workspaces[wi].composeTabs
        guard !tabs.isEmpty else { return }

        for var tab in tabs {
            #if DEBUG
                MCPApplyEditsRebaseProbeRecorder.recordTabInspection(fullPath: fullPath)
            #endif
            guard !tab.selection.slices.isEmpty,
                  let nextSelection = Self.rebasedStoredSelectionSlices(tab.selection, for: fullPath, transform: transform)
            else { continue }

            tab.selection = nextSelection
            tab.lastModified = Date()
            #if DEBUG
                MCPApplyEditsRebaseProbeRecorder.recordTabWrite(fullPath: fullPath)
            #endif
            updateComposeTabStoredOnly(tab)
        }
    }

    @MainActor
    func rebaseSlicesForFileAcrossTabs(
        fullPath: String,
        asyncTransform: @Sendable (UUID, [LineRange]) async -> [LineRange]
    ) async {
        guard let standardizedFullPath = StoredSelectionPathNormalization.standardizedPath(fullPath),
              let workspaceID = activeWorkspaceID,
              let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        let targets = workspace.composeTabs.map {
            (identity: WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: $0.id), fullPath: standardizedFullPath)
        }
        await rebaseSlicesForFilesAcrossTabs(targets: targets) { identity, _, ranges in
            await asyncTransform(identity.tabID, ranges)
        }
    }

    @MainActor
    func rebaseSlicesForFilesAcrossTabs(
        targets: [(identity: WorkspaceSelectionIdentity, fullPath: String)],
        asyncTransform: @Sendable (WorkspaceSelectionIdentity, String, [LineRange]) async -> [LineRange]
    ) async {
        var seen = Set<String>()
        for target in targets {
            guard let standardizedFullPath = StoredSelectionPathNormalization.standardizedPath(target.fullPath) else {
                continue
            }
            let dedupeKey = "\(target.identity.workspaceID.uuidString):\(target.identity.tabID.uuidString):\(standardizedFullPath)"
            guard seen.insert(dedupeKey).inserted else { continue }
            #if DEBUG
                MCPApplyEditsRebaseProbeRecorder.recordTabInspection(fullPath: standardizedFullPath)
            #endif
            for _ in 0 ..< 3 {
                guard let currentTab = composeTab(for: target.identity),
                      !currentTab.selection.slices.isEmpty
                else { break }
                let currentSlices = StoredSelectionPathNormalization.standardizedSlices(currentTab.selection.slices)
                guard let currentRanges = currentSlices[standardizedFullPath] else { break }

                let nextRanges = await SliceRangeMath.normalize(
                    asyncTransform(target.identity, standardizedFullPath, currentRanges)
                )
                guard var latestTab = composeTab(for: target.identity) else { break }
                let latestSlices = StoredSelectionPathNormalization.standardizedSlices(latestTab.selection.slices)
                guard let latestRanges = latestSlices[standardizedFullPath] else { break }
                guard latestRanges == currentRanges else { continue }

                var nextSlices = latestSlices
                if nextRanges.isEmpty {
                    nextSlices.removeValue(forKey: standardizedFullPath)
                } else {
                    nextSlices[standardizedFullPath] = nextRanges
                }
                guard nextSlices != latestTab.selection.slices else { break }

                let expectedSelection = latestTab.selection
                let nextSelection = StoredSelection(
                    selectedPaths: expectedSelection.selectedPaths,
                    manualCodemapPaths: expectedSelection.manualCodemapPaths,
                    slices: nextSlices,
                    codemapAutoEnabled: expectedSelection.codemapAutoEnabled
                )
                let persistedSelection: StoredSelection
                if let selectionCoordinator {
                    persistedSelection = await selectionCoordinator.persistSelection(
                        nextSelection,
                        for: target.identity,
                        source: .mcpTabContext,
                        mirrorToUIIfActive: true,
                        expectedCurrentSelection: expectedSelection
                    )
                } else {
                    latestTab.selection = nextSelection
                    latestTab.lastModified = Date()
                    persistedSelection = updateComposeTabStoredOnly(
                        latestTab,
                        inWorkspaceID: target.identity.workspaceID
                    ) ? nextSelection : expectedSelection
                }
                guard persistedSelection == nextSelection else { continue }
                #if DEBUG
                    MCPApplyEditsRebaseProbeRecorder.recordTabWrite(fullPath: standardizedFullPath)
                #endif
                break
            }
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: - State helpers

    /// ─────────────────────────────────────────────────────────────
    /// Updates the cached "working" state for a workspace *iff* something actually
    /// changed, and returns `true` when a mutation occurs.
    private func updateWorkspaceState(
        at index: Int,
        with state: (
            expandedFolders: [String],
            selection: StoredSelection,
            promptText: String,
            promptIDs: [UUID]
        )
    ) -> Bool {
        workspaces[index].currentPromptText = state.promptText
        workspaces[index].selectedMetaPromptIDs = state.promptIDs
        // NEW: Persist preset selections and customizations
        workspaces[index].copyPresetId = promptViewModel.selectedCopyPresetID
        workspaces[index].copyCustomizations = promptViewModel.workingCopyCustomizations
        workspaces[index].chatPresetId = promptViewModel.selectedChatPresetID
        workspaces[index].dateModified = Date()
        return true
    }

    @discardableResult
    private func captureActiveTabSnapshotForWorkspaceIndex(_ index: Int, source: WorkspaceSaveSource = .pollAndSaveState) -> ComposeTabState? {
        guard workspaces.indices.contains(index) else { return nil }
        let (name, _) = activeComposeTabContext()
        if let activeTabID = workspaces[index].activeComposeTabID,
           let tabIndex = workspaces[index].composeTabs.firstIndex(where: { $0.id == activeTabID })
        {
            guard !isSnapshotCommitSuspended(forTabID: activeTabID) else { return nil }
            #if DEBUG
                debugSelectionOwnerTraceEvent("save.capture.before", workspace: workspaces[index])
            #endif
            let storedSelection = workspaces[index].composeTabs[tabIndex].selection
            var snapshot = collectComposeTabSnapshot(name: name, base: workspaces[index].composeTabs[tabIndex])
            let liveUISelection = snapshot.selection
            let canonical = selectionCoordinator?.activeSelectionSnapshot(flushPendingUI: false)
            let saveSelection = Self.selectionForSaveSnapshot(
                liveUISelection: liveUISelection,
                storedSelection: storedSelection,
                canonicalSelection: canonical?.selection,
                canonicalTabID: canonical?.tabID,
                activeTabID: activeTabID
            )
            snapshot.selection = saveSelection.selection
            workspaces[index].composeTabs[tabIndex] = snapshot
            workspaces[index].dateModified = Date()
            _ = updateWorkspaceState(
                at: index,
                with: (snapshot.expandedFolders, snapshot.selection, snapshot.promptText, snapshot.selectedMetaPromptIDs)
            )
            let metadata = workspaceSaveMetadata(for: workspaces[index], source: source)
            WorkspaceSaveTracer.capture(
                metadata: metadata,
                url: workspaceFileURL(for: workspaces[index]),
                liveUI: liveUISelection,
                stored: storedSelection,
                canonical: canonical?.selection,
                chosenOwner: saveSelection.owner
            )
            #if DEBUG
                debugSelectionOwnerTraceEvent("save.capture.after", workspace: workspaces[index])
            #endif
            return snapshot
        } else {
            let legacy = collectWorkspaceState()
            _ = updateWorkspaceState(at: index, with: legacy)
            return nil
        }
    }

    func pollAndSaveState(source: WorkspaceSaveSource = .pollAndSaveState) {
        guard let active = activeWorkspace,
              let index = workspaces.firstIndex(where: { $0.id == active.id }) else { return }

        // Post notification to allow SwiftUI views to flush pending state
        NotificationCenter.default.post(
            name: .workspaceWillSave,
            object: nil,
            userInfo: [
                "windowID": promptViewModel.windowID,
                "workspaceID": active.id
            ]
        )

        // 1) Call all "beforeSave" listeners, passing the active workspace
        if let active = activeWorkspace {
            for listener in beforeSaveListeners {
                listener(active)
            }
        }

        let snapshot = captureActiveTabSnapshotForWorkspaceIndex(index, source: source)
        promptViewModel.loadComposeTabsFromWorkspace(workspaces[index])
        if let snapshot {
            composeTabSnapshotSubject.send(snapshot)
        }
        scheduleSave(source: source)
    }

    func pollAndSaveStateAsync(source: WorkspaceSaveSource = .pollAndSaveStateAsync) async {
        guard let active = activeWorkspace,
              let index = workspaces.firstIndex(where: { $0.id == active.id }) else { return }

        let wsID = active.id
        let cur = stateVersionByWorkspaceID[wsID, default: 0]
        let last = lastSavedVersionByWorkspaceID[wsID, default: -1]

        guard cur != last else { return } // not dirty → nothing to do

        // Post notification to allow SwiftUI views to flush pending state
        NotificationCenter.default.post(
            name: .workspaceWillSave,
            object: nil,
            userInfo: [
                "windowID": promptViewModel.windowID,
                "workspaceID": active.id
            ]
        )

        // Call before-save listeners on the active
        if let active = activeWorkspace {
            for listener in beforeSaveListeners {
                listener(active)
            }
        }

        let snapshot = captureActiveTabSnapshotForWorkspaceIndex(index, source: source)
        promptViewModel.loadComposeTabsFromWorkspace(workspaces[index])
        if let snapshot {
            composeTabSnapshotSubject.send(snapshot)
        }
        await saveWorkspaceAsync(source: source) // see change below to avoid big reassign
        if let savedWorkspace = workspace(withID: wsID) {
            await WorkspaceDiskWriter.shared.flush(url: workspaceFileURL(for: savedWorkspace))
        }

        lastSavedVersionByWorkspaceID[wsID] = cur
    }

    func restoreWorkspaceState(_ workspace: WorkspaceModel) async {
        let wsID = workspace.id
        #if DEBUG
            let restoreStateStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        // If another workspace is active, don't apply UI state for this one.
        if let active = activeWorkspaceID, active != wsID {
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "workspaceSwitch.restoreState.abort",
                    fields: [
                        "workspaceID": WorkspaceRestorePerfLog.shortID(wsID),
                        "reason": "inactiveWorkspace",
                        "durationSinceRestoreStart": restoreStateStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            return
        }
        guard let index = workspaceIndex(for: wsID) else {
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "workspaceSwitch.restoreState.abort",
                    fields: [
                        "workspaceID": WorkspaceRestorePerfLog.shortID(wsID),
                        "reason": "missingWorkspaceIndex",
                        "durationSinceRestoreStart": restoreStateStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            return
        }

        // Work off a local copy so we don't rely on `index` after awaits.
        var upgraded = workspaces[index]
        #if DEBUG
            let normalizationStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            let composeTabsBeforeNormalization = upgraded.composeTabs.count
        #endif
        upgraded.normalizeComposeTabInvariants()
        workspaces[index] = upgraded
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "workspaceSwitch.restoreState.normalization",
                fields: [
                    "workspaceID": WorkspaceRestorePerfLog.shortID(wsID),
                    "composeTabsBefore": "\(composeTabsBeforeNormalization)",
                    "composeTabsAfter": "\(upgraded.composeTabs.count)",
                    "composeTabsNormalized": "\(upgraded.normalizationRequiresSave)",
                    "activeComposeTabID": WorkspaceRestorePerfLog.shortID(upgraded.activeComposeTabID),
                    "duration": normalizationStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif

        #if DEBUG
            let loadComposeTabsStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        promptViewModel.loadComposeTabsFromWorkspace(upgraded)
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "workspaceSwitch.restoreState.loadComposeTabs",
                fields: [
                    "workspaceID": WorkspaceRestorePerfLog.shortID(wsID),
                    "composeTabs": "\(upgraded.composeTabs.count)",
                    "stashedTabs": "\(upgraded.stashedTabs.count)",
                    "activeComposeTabID": WorkspaceRestorePerfLog.shortID(upgraded.activeComposeTabID),
                    "duration": loadComposeTabsStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif

        guard let activeID = upgraded.activeComposeTabID,
              let activeTab = upgraded.composeTabs.first(where: { $0.id == activeID }) ?? upgraded.composeTabs.first
        else {
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "workspaceSwitch.restoreState.abort",
                    fields: [
                        "workspaceID": WorkspaceRestorePerfLog.shortID(wsID),
                        "reason": "missingActiveTab",
                        "durationSinceRestoreStart": restoreStateStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            return
        }

        promptViewModel.tokenCountingViewModel.suspendAutomaticRecounts()
        defer {
            promptViewModel.tokenCountingViewModel.resumeAutomaticRecounts()
        }

        #if DEBUG
            let applyComposeTabStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        #if DEBUG
            debugSelectionOwnerTraceEvent("restore.applyComposeTab.before", workspace: upgraded)
        #endif
        await fileManager.withDeferredSelectionSliceSnapshotRebuild(reason: "workspaceRestore.applyComposeTab") {
            await applyComposeTabStateInternal(
                tabID: activeTab.id,
                markWorkspaceDirtyAfterApply: false,
                performFinalRecount: false
            )
        }
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "workspaceSwitch.restoreState.applyComposeTab",
                fields: [
                    "workspaceID": WorkspaceRestorePerfLog.shortID(wsID),
                    "tabID": WorkspaceRestorePerfLog.shortID(activeTab.id),
                    "selectedPaths": "\(activeTab.selection.selectedPaths.count)",
                    "sliceFiles": "\(activeTab.selection.slices.count)",
                    "expandedFolders": "\(activeTab.expandedFolders.count)",
                    "selectedPromptIDs": "\(activeTab.selectedMetaPromptIDs.count)",
                    "duration": applyComposeTabStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
        let latestAppliedTab = composeTab(with: activeID) ?? activeTab
        #if DEBUG
            debugSelectionOwnerTraceEvent("restore.applyComposeTab.after", workspace: activeWorkspace)
        #endif

        // Workspace may have been deleted/reordered while we were awaiting.
        if let active = activeWorkspaceID, active != wsID {
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "workspaceSwitch.restoreState.abort",
                    fields: [
                        "workspaceID": WorkspaceRestorePerfLog.shortID(wsID),
                        "reason": "switchedDuringApply",
                        "durationSinceRestoreStart": restoreStateStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            return
        }
        guard let idx2 = workspaceIndex(for: wsID) else {
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "workspaceSwitch.restoreState.abort",
                    fields: [
                        "workspaceID": WorkspaceRestorePerfLog.shortID(wsID),
                        "reason": "deletedDuringApply",
                        "durationSinceRestoreStart": restoreStateStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            return
        }

        #if DEBUG
            let legacyMirrorStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        workspaces[idx2].currentPromptText = latestAppliedTab.promptText
        workspaces[idx2].selectedMetaPromptIDs = latestAppliedTab.selectedMetaPromptIDs
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "workspaceSwitch.restoreState.legacyWorkspaceMirror",
                fields: [
                    "workspaceID": WorkspaceRestorePerfLog.shortID(wsID),
                    "tabID": WorkspaceRestorePerfLog.shortID(latestAppliedTab.id),
                    "selectedPaths": "\(latestAppliedTab.selection.selectedPaths.count)",
                    "expandedFolders": "\(latestAppliedTab.expandedFolders.count)",
                    "duration": legacyMirrorStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif

        // Yield after prompt updates
        await Task.yield()

        // Workspace might have been deleted/switched during yield.
        if let active = activeWorkspaceID, active != wsID {
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "workspaceSwitch.restoreState.abort",
                    fields: [
                        "workspaceID": WorkspaceRestorePerfLog.shortID(wsID),
                        "reason": "switchedDuringYield",
                        "durationSinceRestoreStart": restoreStateStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            return
        }
        guard workspaceIndex(for: wsID) != nil else {
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "workspaceSwitch.restoreState.abort",
                    fields: [
                        "workspaceID": WorkspaceRestorePerfLog.shortID(wsID),
                        "reason": "deletedDuringYield",
                        "durationSinceRestoreStart": restoreStateStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            return
        }

        // 3️⃣.5 Restore preset selections and customizations (with safe fallbacks for migration)
        // IMPORTANT: Set workspace ID on fileManager BEFORE selectCopyPreset so GlobalSettings uses correct workspace
        #if DEBUG
            let copyPresetStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        fileManager.setCurrentWorkspaceID(wsID)

        if let savedCopyPreset = workspace.copyPresetId {
            promptViewModel.selectCopyPreset(savedCopyPreset)
        } else {
            promptViewModel.selectCopyPreset(BuiltInCopyPresets.standard.id)
        }

        let activeCopyPreset = promptViewModel.currentCopyPreset()
        let storedWorkspaceCustomizations = workspaces[idx2].copyCustomizations
        if activeCopyPreset.builtInKind == .manual {
            let sanitizedWorkspaceCustomizations = storedWorkspaceCustomizations?
                .removingCodeMapUsageOverride()
            let persistedWorkspaceCustomizations = sanitizedWorkspaceCustomizations?.hasCustomizations == true
                ? sanitizedWorkspaceCustomizations
                : nil
            promptViewModel.workingCopyCustomizations = persistedWorkspaceCustomizations ?? .init()
            if workspaces[idx2].copyCustomizations != persistedWorkspaceCustomizations {
                workspaces[idx2].copyCustomizations = persistedWorkspaceCustomizations
                markWorkspaceDirty()
            }
        } else {
            promptViewModel.workingCopyCustomizations = storedWorkspaceCustomizations ?? .init()
        }
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "workspaceSwitch.restoreState.copyPreset",
                fields: [
                    "workspaceID": WorkspaceRestorePerfLog.shortID(wsID),
                    "savedCopyPreset": workspace.copyPresetId?.uuidString ?? "nil",
                    "activeCopyPreset": activeCopyPreset.id.uuidString,
                    "manualPreset": "\(activeCopyPreset.builtInKind == .manual)",
                    "customizationsDirty": "\(workspaces[idx2].copyCustomizations != storedWorkspaceCustomizations)",
                    "duration": copyPresetStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
        let restoredChatPresetID = workspace.chatPresetId ?? ChatPreset.BuiltIn.chat.id
        #if DEBUG
            let chatPresetStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        promptViewModel.selectChatPreset(restoredChatPresetID)
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "workspaceSwitch.restoreState.chatPreset",
                fields: [
                    "workspaceID": WorkspaceRestorePerfLog.shortID(wsID),
                    "chatPresetID": restoredChatPresetID.uuidString,
                    "duration": chatPresetStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif

        // Yield after prompt updates
        await Task.yield()

        if let active = activeWorkspaceID, active != wsID {
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "workspaceSwitch.restoreState.abort",
                    fields: [
                        "workspaceID": WorkspaceRestorePerfLog.shortID(wsID),
                        "reason": "switchedDuringPresetYield",
                        "durationSinceRestoreStart": restoreStateStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            return
        }
        guard workspaceIndex(for: wsID) != nil else {
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "workspaceSwitch.restoreState.abort",
                    fields: [
                        "workspaceID": WorkspaceRestorePerfLog.shortID(wsID),
                        "reason": "deletedDuringPresetYield",
                        "durationSinceRestoreStart": restoreStateStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            return
        }

        // 4️⃣ Ensure folder checkbox state is consistent
        #if DEBUG
            let refreshRootFolderStateStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        fileManager.refreshRootFolderState()
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "workspaceSwitch.restoreState.refreshRootFolderState",
                fields: [
                    "workspaceID": WorkspaceRestorePerfLog.shortID(wsID),
                    "rootCount": "\(fileManager.rootFolders.count)",
                    "duration": refreshRootFolderStateStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif

        // 5️⃣ Update dirty-preset indicator
        #if DEBUG
            let activePresetDirtyCheckStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        checkIfActivePresetIsDirty(with: fileManager.selectedFiles)
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "workspaceSwitch.restoreState.activePresetDirtyCheck",
                fields: [
                    "workspaceID": WorkspaceRestorePerfLog.shortID(wsID),
                    "selectedFiles": "\(fileManager.selectedFiles.count)",
                    "duration": activePresetDirtyCheckStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif

        #if DEBUG
            let settingsSyncStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        promptViewModel.syncSettingsFromSettingsManager()
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "workspaceSwitch.restoreState.settingsSync",
                fields: [
                    "workspaceID": WorkspaceRestorePerfLog.shortID(wsID),
                    "duration": settingsSyncStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif

        if let active = activeWorkspaceID, active != wsID {
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "workspaceSwitch.restoreState.abort",
                    fields: [
                        "workspaceID": WorkspaceRestorePerfLog.shortID(wsID),
                        "reason": "switchedBeforeTokenRecount",
                        "durationSinceRestoreStart": restoreStateStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            return
        }
        guard workspaceIndex(for: wsID) != nil else {
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "workspaceSwitch.restoreState.abort",
                    fields: [
                        "workspaceID": WorkspaceRestorePerfLog.shortID(wsID),
                        "reason": "deletedBeforeTokenRecount",
                        "durationSinceRestoreStart": restoreStateStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            return
        }

        #if DEBUG
            let tokenRecountStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            let tokenRecountWatchdogID = UUID()
            let tokenRecountTabID = latestAppliedTab.id
            let tokenRecountSelection = latestAppliedTab.selection
            let tokenRecountSelectedPaths = tokenRecountSelection.selectedPaths.count
            let tokenRecountSliceFiles = tokenRecountSelection.slices.count
            let tokenRecountSelectionFields = WorkspaceSelectionDebugSignature.unprefixedFields(for: tokenRecountSelection)
            debugSelectionOwnerTraceEvent("restore.tokenRecount.begin", workspace: activeWorkspace)
            restoreTokenRecountWatchdogIDs.insert(tokenRecountWatchdogID)
            var tokenRecountBeginFields = tokenRecountSelectionFields
            tokenRecountBeginFields["workspaceID"] = WorkspaceRestorePerfLog.shortID(wsID)
            tokenRecountBeginFields["tabID"] = WorkspaceRestorePerfLog.shortID(tokenRecountTabID)
            tokenRecountBeginFields["rootCount"] = "\(fileManager.rootFolders.count)"
            tokenRecountBeginFields["selectedFiles"] = "\(fileManager.selectedFiles.count)"
            WorkspaceRestorePerfLog.event(
                "workspaceSwitch.restoreState.tokenRecount.begin",
                fields: tokenRecountBeginFields
            )
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self,
                      restoreTokenRecountWatchdogIDs.contains(tokenRecountWatchdogID)
                else { return }
                var fields = promptViewModel.tokenCountingViewModel.debugTokenRecountStateFields()
                fields["workspaceID"] = WorkspaceRestorePerfLog.shortID(wsID)
                fields["tabID"] = WorkspaceRestorePerfLog.shortID(tokenRecountTabID)
                fields["duration"] = tokenRecountStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                fields["rootCount"] = "\(fileManager.rootFolders.count)"
                fields["selectedFiles"] = "\(fileManager.selectedFiles.count)"
                fields["tabSelectedPaths"] = "\(tokenRecountSelectedPaths)"
                fields["tabSliceFiles"] = "\(tokenRecountSliceFiles)"
                for (key, value) in tokenRecountSelectionFields {
                    fields[key] = value
                }
                WorkspaceRestorePerfLog.event("workspaceSwitch.restoreState.tokenRecount.watchdog", fields: fields)
            }
        #endif
        await promptViewModel.tokenCountingViewModel.forceImmediateRecount()
        #if DEBUG
            restoreTokenRecountWatchdogIDs.remove(tokenRecountWatchdogID)
            var tokenRecountEndFields = tokenRecountSelectionFields
            tokenRecountEndFields["workspaceID"] = WorkspaceRestorePerfLog.shortID(wsID)
            tokenRecountEndFields["duration"] = tokenRecountStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
            WorkspaceRestorePerfLog.event(
                "workspaceSwitch.restoreState.tokenRecount",
                fields: tokenRecountEndFields
            )
        #endif
    }

    // MARK: - Duplicate Workspace Cleanup

    private struct WorkspaceDuplicateWindowSnapshot: Equatable {
        let windowID: Int
        let workspaceID: UUID
        let hasActiveWork: Bool
        let isFocused: Bool
    }

    private struct WorkspaceDuplicateGroupPlan {
        let normalizedRepoPaths: [String]
        let workspaces: [WorkspaceModel]
        let canonical: WorkspaceModel
        let duplicates: [WorkspaceModel]
        let summary: WorkspaceDuplicateGroupSummary
    }

    private struct WorkspaceDuplicateDeletionDecision: Equatable {
        let deletableWorkspaceIDs: Set<UUID>
        let skippedWorkspaceIDs: Set<UUID>
    }

    @MainActor
    func duplicateWorkspaceGroups(windowStates: WindowStatesManager? = nil) -> [WorkspaceDuplicateGroupSummary] {
        let windowStates = windowStates ?? WindowStatesManager.shared
        let windowSnapshots = Self.duplicateWindowSnapshots(from: windowStates)
        return Self.duplicateWorkspaceGroupPlans(
            workspaces: workspaces,
            windowSnapshots: windowSnapshots
        ).map(\.summary)
    }

    @MainActor
    func consolidateDuplicateWorkspaces(windowStates: WindowStatesManager? = nil) async -> WorkspaceDuplicateCleanupResult {
        let windowStates = windowStates ?? WindowStatesManager.shared
        let initialWindowSnapshots = Self.duplicateWindowSnapshots(from: windowStates)
        let initialPlans = Self.duplicateWorkspaceGroupPlans(
            workspaces: workspaces,
            windowSnapshots: initialWindowSnapshots
        )
        let groupsDetected = initialPlans.count
        guard !initialPlans.isEmpty else {
            return WorkspaceDuplicateCleanupResult(
                groupsDetected: 0,
                groupsConsolidated: 0,
                reassignedWindowIDs: [],
                deletedWorkspaceIDs: [],
                skipped: [],
                backupURL: nil
            )
        }

        let backupURL: URL
        do {
            backupURL = try Self.writeDuplicateCleanupBackup(for: initialPlans)
        } catch {
            let skipped = initialPlans.flatMap { plan in
                plan.duplicates.map { duplicate in
                    WorkspaceDuplicateCleanupSkippedItem(
                        workspaceID: duplicate.id,
                        workspaceName: duplicate.name,
                        windowID: nil,
                        reason: "backup_failed: \(error.localizedDescription)"
                    )
                }
            }
            return WorkspaceDuplicateCleanupResult(
                groupsDetected: groupsDetected,
                groupsConsolidated: 0,
                reassignedWindowIDs: [],
                deletedWorkspaceIDs: [],
                skipped: skipped,
                backupURL: nil
            )
        }

        var reassignedWindowIDs: Set<Int> = []
        var deletedWorkspaceIDs: Set<UUID> = []
        var skipped: [WorkspaceDuplicateCleanupSkippedItem] = []
        var protectedWorkspaceIDs: Set<UUID> = []

        for plan in initialPlans {
            let canonical = plan.canonical
            let duplicateIDs = Set(plan.duplicates.map(\.id))
            let duplicateWindows = windowStates.allWindows.filter { window in
                guard let activeID = window.workspaceManager.activeWorkspace?.id else { return false }
                return duplicateIDs.contains(activeID)
            }

            for window in duplicateWindows {
                guard let activeWorkspace = window.workspaceManager.activeWorkspace,
                      duplicateIDs.contains(activeWorkspace.id) else { continue }
                let impact = window.makeCloseImpactSnapshot()
                if Self.closeImpactHasActiveWork(impact) {
                    protectedWorkspaceIDs.insert(activeWorkspace.id)
                    skipped.append(
                        WorkspaceDuplicateCleanupSkippedItem(
                            workspaceID: activeWorkspace.id,
                            workspaceName: activeWorkspace.name,
                            windowID: window.windowID,
                            reason: "active_work"
                        )
                    )
                    continue
                }

                await window.workspaceManager.pollAndSaveStateAsync(source: .duplicateCleanupPreSwitch)
                let switchResult = await window.workspaceManager.requestWorkspaceSwitch(to: canonical, saveState: true)
                if switchResult.didSwitch {
                    reassignedWindowIDs.insert(window.windowID)
                } else {
                    protectedWorkspaceIDs.insert(activeWorkspace.id)
                    skipped.append(
                        WorkspaceDuplicateCleanupSkippedItem(
                            workspaceID: activeWorkspace.id,
                            workspaceName: activeWorkspace.name,
                            windowID: window.windowID,
                            reason: switchResult.message ?? "switch_failed"
                        )
                    )
                }
            }
        }

        let diskSnapshot = await loadWorkspaceSnapshotFromDisk()
        if !diskSnapshot.isEmpty {
            workspaces = diskSnapshot
        }

        let activeWorkspaceIDs = Set(windowStates.allWindows.compactMap { $0.workspaceManager.activeWorkspace?.id })
        let postSwitchWindowSnapshots = Self.duplicateWindowSnapshots(from: windowStates)
        let postSwitchPlans = Self.duplicateWorkspaceGroupPlans(
            workspaces: workspaces,
            windowSnapshots: postSwitchWindowSnapshots
        )

        var groupsConsolidated = 0
        for plan in postSwitchPlans {
            guard let canonicalIndex = workspaceIndex(for: plan.canonical.id) else {
                for duplicate in plan.duplicates {
                    skipped.append(
                        WorkspaceDuplicateCleanupSkippedItem(
                            workspaceID: duplicate.id,
                            workspaceName: duplicate.name,
                            windowID: nil,
                            reason: "canonical_missing"
                        )
                    )
                }
                continue
            }

            let decision = Self.duplicateDeletionDecision(
                duplicateWorkspaceIDs: Set(plan.duplicates.map(\.id)),
                protectedWorkspaceIDs: protectedWorkspaceIDs,
                activeWorkspaceIDs: activeWorkspaceIDs
            )
            let duplicatesToMerge = plan.duplicates.filter { decision.deletableWorkspaceIDs.contains($0.id) }
            guard !duplicatesToMerge.isEmpty else {
                for duplicate in plan.duplicates where decision.skippedWorkspaceIDs.contains(duplicate.id) {
                    skipped.append(
                        WorkspaceDuplicateCleanupSkippedItem(
                            workspaceID: duplicate.id,
                            workspaceName: duplicate.name,
                            windowID: nil,
                            reason: activeWorkspaceIDs.contains(duplicate.id) ? "still_active" : "protected"
                        )
                    )
                }
                continue
            }

            let activeWorkspaceIDsBeforeCommit = Set(windowStates.allWindows.compactMap { $0.workspaceManager.activeWorkspace?.id })
            let commitDuplicates = duplicatesToMerge.filter { duplicate in
                let stillActive = activeWorkspaceIDsBeforeCommit.contains(duplicate.id)
                if stillActive {
                    skipped.append(
                        WorkspaceDuplicateCleanupSkippedItem(
                            workspaceID: duplicate.id,
                            workspaceName: duplicate.name,
                            windowID: nil,
                            reason: "still_active"
                        )
                    )
                }
                return !stillActive
            }
            guard !commitDuplicates.isEmpty else { continue }

            let merged = Self.mergedCanonicalWorkspace(
                canonical: workspaces[canonicalIndex],
                duplicates: commitDuplicates
            )

            do {
                await WorkspaceDiskWriter.shared.flush(url: workspaceFileURL(for: workspaces[canonicalIndex]))
                for duplicate in commitDuplicates {
                    await WorkspaceDiskWriter.shared.flush(url: workspaceFileURL(for: duplicate))
                }
                let mergedURL = try await saveWorkspaceToFileAsync(merged, preserveDiskRepoPathsIfUnchangedSinceBaseline: false, source: .duplicateCleanupCanonicalMerge)
                await WorkspaceDiskWriter.shared.flush(url: mergedURL)
            } catch {
                for duplicate in commitDuplicates {
                    skipped.append(
                        WorkspaceDuplicateCleanupSkippedItem(
                            workspaceID: duplicate.id,
                            workspaceName: duplicate.name,
                            windowID: nil,
                            reason: "persist_failed: \(error.localizedDescription)"
                        )
                    )
                }
                continue
            }

            guard let commitCanonicalIndex = workspaceIndex(for: plan.canonical.id) else {
                for duplicate in commitDuplicates {
                    skipped.append(
                        WorkspaceDuplicateCleanupSkippedItem(
                            workspaceID: duplicate.id,
                            workspaceName: duplicate.name,
                            windowID: nil,
                            reason: "canonical_missing"
                        )
                    )
                }
                continue
            }
            workspaces[commitCanonicalIndex] = merged
            let committedDuplicateIDs = Set(commitDuplicates.map(\.id))
            workspaces.removeAll { committedDuplicateIDs.contains($0.id) }

            for duplicate in commitDuplicates {
                await preserveDuplicateWorkspaceStorage(duplicate)
                deletedWorkspaceIDs.insert(duplicate.id)
            }
            groupsConsolidated += 1

            for duplicate in plan.duplicates where decision.skippedWorkspaceIDs.contains(duplicate.id) {
                skipped.append(
                    WorkspaceDuplicateCleanupSkippedItem(
                        workspaceID: duplicate.id,
                        workspaceName: duplicate.name,
                        windowID: nil,
                        reason: activeWorkspaceIDs.contains(duplicate.id) ? "still_active" : "protected"
                    )
                )
            }
        }

        if groupsConsolidated > 0 {
            await rebuildAndSaveIndexAsync()
            await WorkspaceDiskWriter.shared.flush(url: workspaceIndexFileURL)
            for window in windowStates.allWindows {
                window.workspaceManager.reloadWorkspacesFromDisk()
            }
            NotificationCenter.default.post(
                name: .workspaceListDidChange,
                object: nil,
                userInfo: ["managerID": instanceID]
            )
        }

        return WorkspaceDuplicateCleanupResult(
            groupsDetected: groupsDetected,
            groupsConsolidated: groupsConsolidated,
            reassignedWindowIDs: reassignedWindowIDs.sorted(),
            deletedWorkspaceIDs: deletedWorkspaceIDs.sorted { $0.uuidString < $1.uuidString },
            skipped: Self.deduplicatedSkippedItems(skipped),
            backupURL: backupURL
        )
    }

    private static func duplicateWindowSnapshots(from windowStates: WindowStatesManager) -> [WorkspaceDuplicateWindowSnapshot] {
        windowStates.allWindows.compactMap { window in
            guard let workspaceID = window.workspaceManager.activeWorkspace?.id else { return nil }
            return WorkspaceDuplicateWindowSnapshot(
                windowID: window.windowID,
                workspaceID: workspaceID,
                hasActiveWork: closeImpactHasActiveWork(window.makeCloseImpactSnapshot()),
                isFocused: window.isCurrentlyFocused
            )
        }
    }

    private nonisolated static func duplicateWorkspaceGroupPlans(
        workspaces: [WorkspaceModel],
        windowSnapshots: [WorkspaceDuplicateWindowSnapshot]
    ) -> [WorkspaceDuplicateGroupPlan] {
        let eligible = workspaces.filter { workspace in
            let key = WorkspaceRootSetKey(paths: workspace.repoPaths)
            return !workspace.isSystemWorkspace && !workspace.isEphemeral && !key.isEmpty
        }
        let grouped = Dictionary(grouping: eligible) { workspace in
            WorkspaceRootSetKey(paths: workspace.repoPaths)
        }

        return grouped.compactMap { key, groupWorkspaces -> WorkspaceDuplicateGroupPlan? in
            guard groupWorkspaces.count > 1,
                  let canonical = cleanupCanonicalWorkspace(
                      in: groupWorkspaces,
                      windowSnapshots: windowSnapshots
                  ) else { return nil }
            let sortedWorkspaces = groupWorkspaces.sorted(by: cleanupWorkspaceSort)
            let duplicates = sortedWorkspaces.filter { $0.id != canonical.id }
            // Defensive: workspace IDs inside a duplicate group should be
            // unique, but use a duplicate-tolerant (last-wins) init so the
            // cleanup planner cannot SIGTRAP during recovery.
            let windowIDsByWorkspaceID = Dictionary(
                sortedWorkspaces.map { workspace -> (UUID, [Int]) in
                    let windowIDs = windowSnapshots
                        .filter { $0.workspaceID == workspace.id }
                        .map(\.windowID)
                        .sorted()
                    return (workspace.id, windowIDs)
                },
                uniquingKeysWith: { _, last in last }
            )
            let summary = WorkspaceDuplicateGroupSummary(
                id: key.normalizedPaths.joined(separator: " | "),
                normalizedRepoPaths: key.normalizedPaths,
                canonicalWorkspaceID: canonical.id,
                canonicalWorkspaceName: canonical.name,
                duplicateWorkspaceIDs: duplicates.map(\.id),
                duplicateWorkspaceNames: duplicates.map(\.name),
                windowIDsByWorkspaceID: windowIDsByWorkspaceID
            )
            return WorkspaceDuplicateGroupPlan(
                normalizedRepoPaths: key.normalizedPaths,
                workspaces: sortedWorkspaces,
                canonical: canonical,
                duplicates: duplicates,
                summary: summary
            )
        }
        .sorted { lhs, rhs in
            cleanupWorkspaceSort(lhs.canonical, rhs.canonical)
        }
    }

    private nonisolated static func cleanupCanonicalWorkspace(
        in workspaces: [WorkspaceModel],
        windowSnapshots: [WorkspaceDuplicateWindowSnapshot]
    ) -> WorkspaceModel? {
        guard !workspaces.isEmpty else { return nil }
        let snapshotsByWorkspaceID = Dictionary(grouping: windowSnapshots) { $0.workspaceID }

        func activeWork(_ workspace: WorkspaceModel) -> Bool {
            snapshotsByWorkspaceID[workspace.id]?.contains { $0.hasActiveWork } == true
        }

        func focused(_ workspace: WorkspaceModel) -> Bool {
            snapshotsByWorkspaceID[workspace.id]?.contains { $0.isFocused } == true
        }

        func lowestWindowID(_ workspace: WorkspaceModel) -> Int? {
            snapshotsByWorkspaceID[workspace.id]?.map(\.windowID).min()
        }

        return workspaces.sorted { lhs, rhs in
            let lhsActiveWork = activeWork(lhs)
            let rhsActiveWork = activeWork(rhs)
            if lhsActiveWork != rhsActiveWork { return lhsActiveWork }

            let lhsFocused = focused(lhs)
            let rhsFocused = focused(rhs)
            if lhsFocused != rhsFocused { return lhsFocused }

            switch (lowestWindowID(lhs), lowestWindowID(rhs)) {
            case let (.some(lhsWindowID), .some(rhsWindowID)) where lhsWindowID != rhsWindowID:
                return lhsWindowID < rhsWindowID
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                break
            }

            let lhsVisible = !lhs.isHiddenInMenus
            let rhsVisible = !rhs.isHiddenInMenus
            if lhsVisible != rhsVisible { return lhsVisible }
            if lhs.lastUsed != rhs.lastUsed { return lhs.lastUsed > rhs.lastUsed }
            if lhs.dateModified != rhs.dateModified { return lhs.dateModified > rhs.dateModified }
            return cleanupWorkspaceSort(lhs, rhs)
        }.first
    }

    private nonisolated static func cleanupWorkspaceSort(_ lhs: WorkspaceModel, _ rhs: WorkspaceModel) -> Bool {
        let nameComparison = lhs.name.localizedStandardCompare(rhs.name)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private nonisolated static func closeImpactHasActiveWork(_ impact: WindowCloseImpactSnapshot) -> Bool {
        impact.activeItems.contains { $0.count > 0 } || impact.mcp.activeExecutionCount > 0
    }

    private nonisolated static func duplicateDeletionDecision(
        duplicateWorkspaceIDs: Set<UUID>,
        protectedWorkspaceIDs: Set<UUID>,
        activeWorkspaceIDs: Set<UUID>
    ) -> WorkspaceDuplicateDeletionDecision {
        let skipped = duplicateWorkspaceIDs.intersection(protectedWorkspaceIDs.union(activeWorkspaceIDs))
        return WorkspaceDuplicateDeletionDecision(
            deletableWorkspaceIDs: duplicateWorkspaceIDs.subtracting(skipped),
            skippedWorkspaceIDs: skipped
        )
    }

    nonisolated static func mergedCanonicalWorkspace(
        canonical: WorkspaceModel,
        duplicates: [WorkspaceModel],
        now: Date = Date()
    ) -> WorkspaceModel {
        var merged = canonical
        let allWorkspaces = [canonical] + duplicates

        merged.isSystemWorkspace = false
        merged.isHiddenInMenus = canonical.isHiddenInMenus && duplicates.allSatisfy(\.isHiddenInMenus)
        merged.lastUsed = allWorkspaces.map(\.lastUsed).max() ?? canonical.lastUsed
        merged.dateModified = now

        var presetIDs = Set(merged.presets.map(\.id))
        for duplicate in duplicates {
            for preset in duplicate.presets where presetIDs.insert(preset.id).inserted {
                merged.presets.append(preset)
            }
        }
        if merged.activePresetID == nil {
            merged.activePresetID = duplicates.lazy.compactMap(\.activePresetID).first
        }

        var composeTabIDs = Set(merged.composeTabs.map(\.id))
        for duplicate in duplicates {
            for tab in duplicate.composeTabs where composeTabIDs.insert(tab.id).inserted {
                merged.composeTabs.append(tab)
            }
        }
        if merged.activeComposeTabID == nil {
            merged.activeComposeTabID = duplicates.lazy.compactMap(\.activeComposeTabID).first
        }

        var stashedTabIDs = Set(merged.stashedTabs.map(\.id))
        for duplicate in duplicates {
            for stashedTab in duplicate.stashedTabs where stashedTabIDs.insert(stashedTab.id).inserted {
                merged.stashedTabs.append(stashedTab)
            }
        }
        merged.normalizeComposeTabInvariants()

        merged.selectedMetaPromptIDs = Array(Set(allWorkspaces.flatMap(\.selectedMetaPromptIDs)))
            .sorted { $0.uuidString < $1.uuidString }

        if merged.copyPresetId == nil {
            merged.copyPresetId = duplicates.lazy.compactMap(\.copyPresetId).first
        }
        if merged.copyCustomizations == nil {
            merged.copyCustomizations = duplicates.lazy.compactMap(\.copyCustomizations).first
        }
        if merged.chatPresetId == nil {
            merged.chatPresetId = duplicates.lazy.compactMap(\.chatPresetId).first
        }

        return merged
    }

    private nonisolated static func writeDuplicateCleanupBackup(for plans: [WorkspaceDuplicateGroupPlan]) throws -> URL {
        let backup = WorkspaceDuplicateCleanupBackup(
            createdAt: Date(),
            groups: plans.map { plan in
                WorkspaceDuplicateCleanupBackup.BackupGroup(
                    canonicalBeforeMerge: plan.canonical,
                    duplicatesBeforeDelete: plan.duplicates
                )
            }
        )

        let directory = try duplicateCleanupBackupDirectoryURL()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let fileURL = directory.appendingPathComponent("workspace-dedup-\(formatter.string(from: backup.createdAt)).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(backup).write(to: fileURL, options: .atomic)
        return fileURL
    }

    private nonisolated static func duplicateCleanupBackupDirectoryURL() throws -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NSError(
                domain: "WorkspaceDuplicateCleanup",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Application Support directory is unavailable."]
            )
        }
        let directory = appSupport
            .appendingPathComponent("RepoPrompt CE", isDirectory: true)
            .appendingPathComponent("workspace-cleanup-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func preserveDuplicateWorkspaceStorage(_ workspace: WorkspaceModel) async {
        // Phase 2 removes duplicate records from the index, but intentionally keeps
        // the backing workspace directory/file in place. Sidecar data such as Chats/
        // is not merged yet, so deleting the folder here would be destructive.
        await WorkspaceDiskWriter.shared.flush(url: workspaceFileURL(for: workspace))
    }

    nonisolated static func test_duplicateWorkspaceGroups(
        workspaces: [WorkspaceModel],
        activeWindows: [(windowID: Int, workspaceID: UUID, hasActiveWork: Bool, isFocused: Bool)] = []
    ) -> [WorkspaceDuplicateGroupSummary] {
        let snapshots = activeWindows.map {
            WorkspaceDuplicateWindowSnapshot(
                windowID: $0.windowID,
                workspaceID: $0.workspaceID,
                hasActiveWork: $0.hasActiveWork,
                isFocused: $0.isFocused
            )
        }
        return duplicateWorkspaceGroupPlans(workspaces: workspaces, windowSnapshots: snapshots).map(\.summary)
    }

    nonisolated static func test_duplicateDeletionDecision(
        duplicateWorkspaceIDs: Set<UUID>,
        protectedWorkspaceIDs: Set<UUID>,
        activeWorkspaceIDs: Set<UUID>
    ) -> (deletableWorkspaceIDs: Set<UUID>, skippedWorkspaceIDs: Set<UUID>) {
        let decision = duplicateDeletionDecision(
            duplicateWorkspaceIDs: duplicateWorkspaceIDs,
            protectedWorkspaceIDs: protectedWorkspaceIDs,
            activeWorkspaceIDs: activeWorkspaceIDs
        )
        return (decision.deletableWorkspaceIDs, decision.skippedWorkspaceIDs)
    }

    private nonisolated static func deduplicatedSkippedItems(
        _ items: [WorkspaceDuplicateCleanupSkippedItem]
    ) -> [WorkspaceDuplicateCleanupSkippedItem] {
        var seen = Set<String>()
        return items.filter { item in
            let key = [
                item.workspaceID.uuidString,
                item.windowID.map(String.init) ?? "nil",
                item.reason
            ].joined(separator: "|")
            return seen.insert(key).inserted
        }
    }

    // MARK: - CRUD

    func deleteWorkspace(_ workspace: WorkspaceModel) {
        workspaces.removeAll { $0.id == workspace.id }
        if activeWorkspaceID == workspace.id {
            activeWorkspaceID = nil
        }

        let workspaceDir = workspaceDirectory(for: workspace)

        // Always delete git data (even for custom storage workspaces)
        Task.detached(priority: .utility) {
            await GitDiffDataMaintenance.shared.deleteAllGitData(workspaceDirectory: workspaceDir)
        }

        if workspace.customStoragePath == nil {
            // For default storage, delete the entire workspace folder
            do {
                if FileManager.default.fileExists(atPath: workspaceDir.path) {
                    try FileManager.default.removeItem(at: workspaceDir)
                }
            } catch {
                print("Failed to remove workspace folder: \(error)")
            }
        }

        // Schedule async index save and notify after completion and flush
        Task {
            await rebuildAndSaveIndexAsync()
            await WorkspaceDiskWriter.shared.flush(url: workspaceIndexFileURL)
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .workspaceListDidChange,
                    object: nil,
                    userInfo: ["managerID": instanceID]
                )
            }
        }
    }

    func renameWorkspace(_ workspace: WorkspaceModel, newName: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        let finalName = newName.trimmingCharacters(in: .whitespaces)
        guard !finalName.isEmpty else { return }

        workspaces[index].name = finalName
        workspaces[index].dateModified = Date()

        if workspaces[index].customStoragePath == nil {
            // Preserve the original base location (global or default)
            let baseLocation = currentBaseRoot
            // 'workspace' param still holds the old name – use it to locate old folder
            let oldFolder = workspaceDirectory(for: workspace)
            let newFolder = baseLocation.appendingPathComponent(
                "Workspace-\(finalName)-\(workspace.id.uuidString)"
            )
            do {
                if FileManager.default.fileExists(atPath: oldFolder.path) {
                    try FileManager.default.moveItem(at: oldFolder, to: newFolder)
                }
            } catch {
                print("Failed to rename workspace folder: \(error)")
            }
        }

        // Schedule async save of the specific workspace and index update, with flushes before notify
        Task {
            do {
                let finalURL = try await saveWorkspaceToFileAsync(workspaces[index], source: .renameWorkspace)
                await WorkspaceDiskWriter.shared.flush(url: finalURL)

                await rebuildAndSaveIndexAsync()
                await WorkspaceDiskWriter.shared.flush(url: workspaceIndexFileURL)

                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .workspaceListDidChange,
                        object: nil,
                        userInfo: ["managerID": instanceID]
                    )
                }
            } catch {
                print("Error saving renamed workspace: \(error)")
            }
        }
    }

    func setWorkspaceHidden(_ workspace: WorkspaceModel, hidden: Bool) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces[index].isHiddenInMenus = hidden
        workspaces[index].dateModified = Date()

        Task {
            do {
                let finalURL = try await saveWorkspaceToFileAsync(workspaces[index], source: .setWorkspaceHidden)
                await WorkspaceDiskWriter.shared.flush(url: finalURL)

                await rebuildAndSaveIndexAsync()
                await WorkspaceDiskWriter.shared.flush(url: workspaceIndexFileURL)

                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .workspaceListDidChange,
                        object: nil,
                        userInfo: ["managerID": instanceID]
                    )
                }
            } catch {
                print("Error saving hidden state for workspace: \(error)")
            }
        }
    }

    func setWorkspaceHiddenFromSnapshot(_ workspace: WorkspaceModel, hidden: Bool) async throws -> WorkspaceModel {
        var updated = workspace
        updated.isHiddenInMenus = hidden
        updated.dateModified = Date()

        if let index = workspaces.firstIndex(where: { $0.id == updated.id }) {
            workspaces[index].isHiddenInMenus = hidden
            workspaces[index].dateModified = updated.dateModified
        } else {
            workspaces.append(updated)
        }

        let finalURL = try await saveWorkspaceToFileAsync(updated, source: .setWorkspaceHiddenFromSnapshot)
        await WorkspaceDiskWriter.shared.flush(url: finalURL)

        await rebuildAndSaveIndexAsync()
        await WorkspaceDiskWriter.shared.flush(url: workspaceIndexFileURL)

        NotificationCenter.default.post(
            name: .workspaceListDidChange,
            object: nil,
            userInfo: ["managerID": instanceID]
        )

        return updated
    }

    func applyWorkspaceHiddenStateInMemory(workspaceID: UUID, hidden: Bool, dateModified: Date) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        workspaces[index].isHiddenInMenus = hidden
        workspaces[index].dateModified = dateModified
    }

    // MARK: - FOLDER LOAD

    nonisolated static func loadableRepoPaths(for workspace: WorkspaceModel) -> [String] {
        guard workspace.isSystemWorkspace == false else { return [] }
        return workspace.repoPaths
    }

    nonisolated static func isSyntheticFallbackWorkspace(_ workspace: WorkspaceModel) -> Bool {
        workspace.isSystemWorkspace && workspace.repoPaths.isEmpty
    }

    nonisolated static func effectiveRestoreSaveState(
        requestedSaveState: Bool,
        reason: String,
        previousWorkspace: WorkspaceModel?
    ) -> Bool {
        guard requestedSaveState else { return false }
        guard reason == "restore", let previousWorkspace else { return true }
        return !isSyntheticFallbackWorkspace(previousWorkspace)
    }

    private struct WorkspaceRootLoadRequest {
        let rootIndex: Int
        let canonicalPath: String
        let rootName: String
    }

    private nonisolated static var maxConcurrentWorkspaceRootLoads: Int {
        3
    }

    nonisolated static func boundedWorkspaceRootLoadLimit(forRootCount rootCount: Int) -> Int {
        guard rootCount > 0 else { return 0 }
        return min(rootCount, maxConcurrentWorkspaceRootLoads)
    }

    private func beginWorkspaceHydration(for workspace: WorkspaceModel) -> UInt64 {
        let generation = advanceWorkspaceHydrationGeneration()
        cancelPostCatalogRootWorkTasks()
        workspaceSearchReadinessState = .activating(workspaceID: workspace.id, generation: generation)
        return generation
    }

    private func invalidateWorkspaceSearchReadiness() {
        advanceWorkspaceHydrationGeneration()
        workspaceSearchReadinessState = .idle
        cancelPostCatalogRootWorkTasks()
    }

    @discardableResult
    private func advanceWorkspaceHydrationGeneration() -> UInt64 {
        workspaceSearchReadinessFence.publish(nil)
        workspaceHydrationGeneration &+= 1
        #if DEBUG
            workspaceHydrationGenerationDidAdvanceHandlerForTesting?()
        #endif
        return workspaceHydrationGeneration
    }

    private func isHydrationGenerationCurrent(_ generation: UInt64, workspaceID: UUID?) -> Bool {
        workspaceHydrationGeneration == generation && activeWorkspaceID == workspaceID && returnToSystemAfterSwitchCancellationOperationID == nil
    }

    private func cancelPostCatalogRootWorkTasks(generation: UInt64? = nil) {
        let keys: [UInt64] = if let generation {
            [generation]
        } else {
            Array(postCatalogRootWorkTasks.keys)
        }
        for key in keys {
            let tasks = postCatalogRootWorkTasks.removeValue(forKey: key) ?? []
            for task in tasks {
                task.cancel()
            }
        }
    }

    func refreshAfterCheckoutMutation(rootPath: String) async -> WorkspaceCheckoutRefreshResult {
        await checkoutRefreshService.refreshAfterCheckoutMutation(rootPath: rootPath)
    }

    private func schedulePostCatalogRootWork(
        for rootRecord: WorkspaceRootRecord,
        workspace: WorkspaceModel,
        generation: UInt64
    ) {
        let task: Task<WorkspaceRootLoadFailure?, Never> = Task { @MainActor [weak self] in
            guard let self,
                  isHydrationGenerationCurrent(generation, workspaceID: workspace.id) else { return nil }
            do {
                try await fileManager.performPostCatalogRootWork(
                    for: rootRecord,
                    workspace: workspace,
                    rootKind: .user
                )
                return nil
            } catch is CancellationError {
                return nil
            } catch {
                guard isHydrationGenerationCurrent(generation, workspaceID: workspace.id) else { return nil }
                return WorkspaceRootLoadFailure(
                    rootPath: rootRecord.standardizedFullPath,
                    kind: rootRecord.kind,
                    errorDescription: error.localizedDescription
                )
            }
        }
        postCatalogRootWorkTasks[generation, default: []].append(task)
    }

    private func awaitPostCatalogRootWorkFailures(generation: UInt64) async -> [WorkspaceRootLoadFailure] {
        let tasks = postCatalogRootWorkTasks.removeValue(forKey: generation) ?? []
        var failures: [WorkspaceRootLoadFailure] = []
        failures.reserveCapacity(tasks.count)
        for task in tasks {
            if let failure = await task.value {
                failures.append(failure)
            }
        }
        return failures
    }

    private func loadWorkspaceFolders(
        for workspace: WorkspaceModel,
        hydrationGeneration: UInt64,
        skipSecurityScope: Bool = false,
        gitDataRootLoadMode: GitDataRootLoadMode = .inline,
        initialUnloadMode: WorkspaceFolderInitialUnloadMode = .perform,
        onInitialRootUnloadCompleted: (() -> Void)? = nil,
        onAllPrimaryRootsVisible: (() -> Void)? = nil
    ) async {
        logWorkspaceSwitch("loadWorkspaceFolders BEGIN workspace=\"\(workspace.name)\" skipSecurityScope=\(skipSecurityScope) gitDataRootLoadMode=\(gitDataRootLoadMode)")
        #if DEBUG
            let loadWorkspaceFoldersStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            debugRecordLoadWorkspaceFoldersStart(for: workspace)
            WorkspaceRestorePerfLog.event(
                "workspaceSwitch.loadWorkspaceFolders.begin",
                fields: debugWorkspaceOpenTraceFields().merging([
                    "workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
                    "workspaceName": workspace.name,
                    "userRoots": "\(Self.loadableRepoPaths(for: workspace).count)",
                    "skipSecurityScope": "\(skipSecurityScope)",
                    "gitDataRootLoadMode": "\(gitDataRootLoadMode)"
                ], uniquingKeysWith: { _, new in new })
            )
        #endif
        switch initialUnloadMode {
        case .perform:
            #if DEBUG
                let initialUnloadStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            #endif
            await fileManager.unloadAllRootFolders()
            onInitialRootUnloadCompleted?()
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "workspaceSwitch.loadWorkspaceFolders.initialUnload",
                    fields: [
                        "workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
                        "mode": "performed",
                        "outcome": "completed",
                        "duration": initialUnloadStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
        case .skipPreviouslyCompleted:
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "workspaceSwitch.loadWorkspaceFolders.initialUnload",
                    fields: [
                        "workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
                        "mode": "skippedPreviouslyCompleted",
                        "outcome": "skipped",
                        "duration": "0.0ms"
                    ]
                )
            #endif
        }

        guard isHydrationGenerationCurrent(hydrationGeneration, workspaceID: workspace.id) else { return }
        let pathsToLoad = Self.loadableRepoPaths(for: workspace)
        let rootLoadRequests = uniqueWorkspaceRootLoadRequests(for: pathsToLoad)
        let maxConcurrentLoads = Self.boundedWorkspaceRootLoadLimit(forRootCount: rootLoadRequests.count)
        var loadedRootCount = 0
        var failures: [WorkspaceRootLoadFailure] = []
        workspaceSearchReadinessState = .loadingCatalog(
            workspaceID: workspace.id,
            generation: hydrationGeneration,
            loadedRootCount: loadedRootCount,
            expectedRootCount: rootLoadRequests.count,
            failures: failures
        )
        logWorkspaceSwitch("loadWorkspaceFolders user roots BEGIN workspace=\"\(workspace.name)\" roots=\(rootLoadRequests.count) concurrency=\(maxConcurrentLoads)")
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "workspaceSwitch.loadWorkspaceFolders.userRoots.begin",
                fields: debugWorkspaceOpenTraceFields().merging([
                    "workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
                    "rootCount": "\(rootLoadRequests.count)",
                    "concurrency": "\(maxConcurrentLoads)"
                ], uniquingKeysWith: { _, new in new })
            )
        #endif
        #if DEBUG
            let hydrationBatchStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        let hydrationResults = await hydrateWorkspaceUserRootsBounded(
            rootLoadRequests,
            workspace: workspace,
            hydrationGeneration: hydrationGeneration,
            maxConcurrentLoads: maxConcurrentLoads
        )
        #if DEBUG
            if let hydrationBatchStartMS {
                let hydrationCatalogDiagnostics = await fileManager.workspaceFileContextStore.catalogDiagnostics(rootScope: .visibleWorkspace)
                WorkspaceRestorePerfLog.event(
                    "workspaceSwitch.loadWorkspaceFolders.userRoots.catalogHydration.end",
                    fields: debugWorkspaceOpenTraceFields().merging([
                        "workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
                        "workspaceName": workspace.name,
                        "rootCount": "\(rootLoadRequests.count)",
                        "concurrency": "\(maxConcurrentLoads)",
                        "catalogGeneration": "\(hydrationCatalogDiagnostics.generation)",
                        "catalogRoots": "\(hydrationCatalogDiagnostics.rootCount)",
                        "catalogFolders": "\(hydrationCatalogDiagnostics.folderCount)",
                        "catalogFiles": "\(hydrationCatalogDiagnostics.fileCount)",
                        "duration": WorkspaceRestorePerfLog.formatElapsedMS(since: hydrationBatchStartMS)
                    ], uniquingKeysWith: { _, new in new })
                )
            }
        #endif
        guard !Task.isCancelled,
              isHydrationGenerationCurrent(hydrationGeneration, workspaceID: workspace.id)
        else {
            for rootRecord in hydrationResults.compactMap(\.rootRecord) {
                await fileManager.workspaceFileContextStore.unloadRoot(id: rootRecord.id)
            }
            return
        }
        #if DEBUG
            let rootAttachLoopStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        for result in hydrationResults.sorted(by: { $0.request.rootIndex < $1.request.rootIndex }) {
            if result.wasCancelled {
                continue
            }
            guard isHydrationGenerationCurrent(hydrationGeneration, workspaceID: workspace.id) else {
                if let rootRecord = result.rootRecord {
                    await fileManager.workspaceFileContextStore.unloadRoot(id: rootRecord.id)
                }
                continue
            }
            if let failure = result.failure {
                failures.append(failure)
            }
            guard let rootRecord = result.rootRecord else {
                workspaceSearchReadinessState = .loadingCatalog(
                    workspaceID: workspace.id,
                    generation: hydrationGeneration,
                    loadedRootCount: loadedRootCount,
                    expectedRootCount: rootLoadRequests.count,
                    failures: failures
                )
                continue
            }
            do {
                #if DEBUG
                    let rootAttachStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
                #endif
                try fileManager.attachRootShell(for: rootRecord, workspaceID: workspace.id)
                loadedRootCount += 1
                #if DEBUG
                    debugRecordRootShellAttach(
                        workspace: workspace,
                        rootRecord: rootRecord,
                        request: result.request,
                        attachedPrimaryRoots: loadedRootCount,
                        failureCount: failures.count,
                        attachDurationMS: rootAttachStartMS.map { WorkspaceRestorePerfLog.elapsedMS(since: $0) },
                        outcome: "success"
                    )
                #endif
                workspaceSearchReadinessState = .loadingCatalog(
                    workspaceID: workspace.id,
                    generation: hydrationGeneration,
                    loadedRootCount: loadedRootCount,
                    expectedRootCount: rootLoadRequests.count,
                    failures: failures
                )
                schedulePostCatalogRootWork(for: rootRecord, workspace: workspace, generation: hydrationGeneration)
            } catch {
                failures.append(WorkspaceRootLoadFailure(
                    rootPath: result.request.canonicalPath,
                    kind: .primaryWorkspace,
                    errorDescription: String(describing: error)
                ))
                await fileManager.workspaceFileContextStore.unloadRoot(id: rootRecord.id)
                #if DEBUG
                    debugRecordRootShellAttach(
                        workspace: workspace,
                        rootRecord: rootRecord,
                        request: result.request,
                        attachedPrimaryRoots: loadedRootCount,
                        failureCount: failures.count,
                        attachDurationMS: nil,
                        outcome: "error",
                        error: String(describing: error)
                    )
                #endif
            }
        }
        guard isHydrationGenerationCurrent(hydrationGeneration, workspaceID: workspace.id) else { return }
        let reorderChanged = fileManager.reorderRootFolders(to: pathsToLoad)
        let allPrimaryRootsVisibleSuccessfully = loadedRootCount == rootLoadRequests.count && failures.isEmpty
        #if DEBUG
            debugRecordAllPrimaryRootsVisible(
                workspace: workspace,
                hydrationGeneration: hydrationGeneration,
                attachedPrimaryRoots: loadedRootCount,
                expectedPrimaryRoots: rootLoadRequests.count,
                failureCount: failures.count,
                rootAttachLoopDurationMS: rootAttachLoopStartMS.map { WorkspaceRestorePerfLog.elapsedMS(since: $0) },
                reorderChanged: reorderChanged
            )
        #endif

        guard isHydrationGenerationCurrent(hydrationGeneration, workspaceID: workspace.id) else { return }
        if allPrimaryRootsVisibleSuccessfully, !Task.isCancelled {
            onAllPrimaryRootsVisible?()
        }
        await failures.append(contentsOf: awaitPostCatalogRootWorkFailures(generation: hydrationGeneration))
        guard isHydrationGenerationCurrent(hydrationGeneration, workspaceID: workspace.id) else { return }
        await workspaceSearchService.startKeepingFresh(with: fileManager.workspaceFileContextStore)
        guard isHydrationGenerationCurrent(hydrationGeneration, workspaceID: workspace.id) else { return }
        #if DEBUG
            let searchCatalogSnapshotStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        var snapshot = await fileManager.workspaceFileContextStore.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        guard isHydrationGenerationCurrent(hydrationGeneration, workspaceID: workspace.id) else { return }
        #if DEBUG
            let initialSearchCatalogSnapshotDurationMS = searchCatalogSnapshotStartMS.map { WorkspaceRestorePerfLog.elapsedMS(since: $0) }
            if let initialSearchCatalogSnapshotDurationMS {
                WorkspaceRestorePerfLog.event(
                    "workspaceSwitch.searchCatalogSnapshot.end",
                    fields: debugWorkspaceOpenTraceFields().merging([
                        "workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
                        "generation": "\(hydrationGeneration)",
                        "catalogGeneration": "\(snapshot.generation)",
                        "catalogRoots": "\(snapshot.diagnostics.rootCount)",
                        "catalogFolders": "\(snapshot.diagnostics.folderCount)",
                        "catalogFiles": "\(snapshot.diagnostics.fileCount)",
                        "duration": WorkspaceRestorePerfLog.formatMS(initialSearchCatalogSnapshotDurationMS)
                    ], uniquingKeysWith: { _, new in new })
                )
            }
        #endif
        workspaceSearchReadinessState = .buildingIndexes(
            workspaceID: workspace.id,
            generation: hydrationGeneration,
            catalogGeneration: snapshot.generation,
            failures: failures
        )
        let initialSearchSnapshot = snapshot
        #if DEBUG
            let searchIndexBuildStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            var searchIndexRebuildCount = 1
            var totalSearchCatalogSnapshotDurationMS = initialSearchCatalogSnapshotDurationMS ?? 0
            var totalSearchIndexRebuildDurationMS: Double = 0
            var totalPathLookupWarmDurationMS: Double = 0
        #endif
        #if DEBUG
            async let indexedResult = debugRebuildSearchIndex(
                from: initialSearchSnapshot,
                workspace: workspace,
                hydrationGeneration: hydrationGeneration
            )
            async let warmedResult = debugWarmPathLookupIndexes(
                workspace: workspace,
                hydrationGeneration: hydrationGeneration,
                catalogGeneration: initialSearchSnapshot.generation
            )
            let initialIndexedResult = await indexedResult
            let initialWarmedResult = await warmedResult
            var indexGeneration = initialIndexedResult.generation
            if let duration = initialIndexedResult.durationMS { totalSearchIndexRebuildDurationMS += duration }
            if let duration = initialWarmedResult.durationMS { totalPathLookupWarmDurationMS += duration }
        #else
            async let indexedGeneration = workspaceSearchService.rebuildIndex(from: initialSearchSnapshot)
            async let warmedGeneration = fileManager.workspaceFileContextStore.warmPathLookupIndexes(rootScope: .visibleWorkspace)
            var indexGeneration = await indexedGeneration
            _ = await warmedGeneration
        #endif
        guard isHydrationGenerationCurrent(hydrationGeneration, workspaceID: workspace.id) else { return }
        while true {
            let currentCatalogGeneration = await fileManager.workspaceFileContextStore.catalogGeneration(rootScope: .visibleWorkspace)
            guard isHydrationGenerationCurrent(hydrationGeneration, workspaceID: workspace.id) else { return }
            guard currentCatalogGeneration != indexGeneration else { break }
            #if DEBUG
                let loopSearchCatalogSnapshotStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            #endif
            snapshot = await fileManager.workspaceFileContextStore.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            guard isHydrationGenerationCurrent(hydrationGeneration, workspaceID: workspace.id) else { return }
            #if DEBUG
                if let loopSearchCatalogSnapshotStartMS {
                    let duration = WorkspaceRestorePerfLog.elapsedMS(since: loopSearchCatalogSnapshotStartMS)
                    totalSearchCatalogSnapshotDurationMS += duration
                    WorkspaceRestorePerfLog.event(
                        "workspaceSwitch.searchCatalogSnapshot.end",
                        fields: debugWorkspaceOpenTraceFields().merging([
                            "workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
                            "generation": "\(hydrationGeneration)",
                            "catalogGeneration": "\(snapshot.generation)",
                            "catalogRoots": "\(snapshot.diagnostics.rootCount)",
                            "catalogFolders": "\(snapshot.diagnostics.folderCount)",
                            "catalogFiles": "\(snapshot.diagnostics.fileCount)",
                            "duration": WorkspaceRestorePerfLog.formatMS(duration)
                        ], uniquingKeysWith: { _, new in new })
                    )
                }
            #endif
            #if DEBUG
                searchIndexRebuildCount += 1
            #endif
            workspaceSearchReadinessState = .buildingIndexes(
                workspaceID: workspace.id,
                generation: hydrationGeneration,
                catalogGeneration: snapshot.generation,
                failures: failures
            )
            #if DEBUG
                let rebuildResult = await debugRebuildSearchIndex(
                    from: snapshot,
                    workspace: workspace,
                    hydrationGeneration: hydrationGeneration
                )
                indexGeneration = rebuildResult.generation
                if let duration = rebuildResult.durationMS { totalSearchIndexRebuildDurationMS += duration }
            #else
                indexGeneration = await workspaceSearchService.rebuildIndex(from: snapshot)
            #endif
            guard isHydrationGenerationCurrent(hydrationGeneration, workspaceID: workspace.id) else { return }
        }
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "workspaceSwitch.searchIndexBuild.end",
                fields: [
                    "workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
                    "generation": "\(hydrationGeneration)",
                    "catalogGeneration": "\(snapshot.generation)",
                    "indexedGeneration": "\(indexGeneration)",
                    "catalogRoots": "\(snapshot.diagnostics.rootCount)",
                    "catalogFolders": "\(snapshot.diagnostics.folderCount)",
                    "catalogFiles": "\(snapshot.diagnostics.fileCount)",
                    "rebuildCount": "\(searchIndexRebuildCount)",
                    "failureCount": "\(failures.count)",
                    "catalogSnapshotDuration": WorkspaceRestorePerfLog.formatMS(totalSearchCatalogSnapshotDurationMS),
                    "searchRebuildDuration": WorkspaceRestorePerfLog.formatMS(totalSearchIndexRebuildDurationMS),
                    "pathLookupWarmDuration": WorkspaceRestorePerfLog.formatMS(totalPathLookupWarmDurationMS),
                    "barrierDuration": searchIndexBuildStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured",
                    "duration": searchIndexBuildStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ].merging(debugWorkspaceOpenTraceFields(), uniquingKeysWith: { current, _ in current })
            )
        #endif
        guard isHydrationGenerationCurrent(hydrationGeneration, workspaceID: workspace.id) else { return }
        if failures.isEmpty {
            workspaceSearchReadinessState = .ready(
                workspaceID: workspace.id,
                generation: hydrationGeneration,
                catalogGeneration: snapshot.generation,
                indexedGeneration: indexGeneration,
                diagnostics: snapshot.diagnostics
            )
        } else {
            workspaceSearchReadinessState = .degraded(
                workspaceID: workspace.id,
                generation: hydrationGeneration,
                catalogGeneration: snapshot.generation,
                indexedGeneration: indexGeneration,
                failures: failures,
                diagnostics: snapshot.diagnostics
            )
        }

        switch gitDataRootLoadMode {
        case .inline:
            let gitDataStart = Date()
            #if DEBUG
                let gitDataStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            #endif
            logWorkspaceSwitch("ensureGitDataRootLoaded BEGIN workspace=\"\(workspace.name)\" mode=inline")
            var gitDataOutcome = "success"
            do {
                _ = try await fileManager.ensureGitDataRootLoaded(
                    workspace: workspace,
                    workspaceManager: self,
                    refreshRootFolderStateAfterLoad: false
                )
            } catch {
                gitDataOutcome = error is CancellationError ? "cancelled" : "error"
                logWorkspaceSwitch(
                    "ensureGitDataRootLoaded FAILED workspace=\"\(workspace.name)\" " +
                        "mode=inline error=\(error.localizedDescription)"
                )
            }
            let gitDataDuration = Date().timeIntervalSince(gitDataStart)
            logWorkspaceSwitch("ensureGitDataRootLoaded END workspace=\"\(workspace.name)\" mode=inline duration=\(String(format: "%.3f", gitDataDuration))s outcome=\(gitDataOutcome)")
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "workspaceSwitch.gitDataLoad",
                    fields: [
                        "workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
                        "isSystemWorkspace": "\(workspace.isSystemWorkspace)",
                        "mode": "inline",
                        "outcome": gitDataOutcome,
                        "duration": gitDataStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
        case .deferredAfterSwitch:
            logWorkspaceSwitch("ensureGitDataRootLoaded SKIP workspace=\"\(workspace.name)\" mode=deferredAfterSwitch")
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "workspaceSwitch.gitDataLoad",
                    fields: [
                        "workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
                        "isSystemWorkspace": "\(workspace.isSystemWorkspace)",
                        "mode": "deferredAfterSwitch",
                        "outcome": "skippedInline",
                        "duration": "0.0ms"
                    ]
                )
            #endif
        }

        logWorkspaceSwitch("loadWorkspaceFolders END workspace=\"\(workspace.name)\"")
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "workspaceSwitch.loadWorkspaceFolders.end",
                fields: [
                    "workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
                    "userRoots": "\(pathsToLoad.count)",
                    "duration": loadWorkspaceFoldersStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
    }

    private func uniqueWorkspaceRootLoadRequests(for paths: [String]) -> [WorkspaceRootLoadRequest] {
        var seen = Set<String>()
        var requests: [WorkspaceRootLoadRequest] = []
        requests.reserveCapacity(paths.count)
        for (rootIndex, path) in paths.enumerated() {
            let stdURL = fileManager.canonicalURL(for: path, assumingDirectory: true)
            let canonicalPath = stdURL.path
            guard seen.insert(canonicalPath).inserted else { continue }
            requests.append(WorkspaceRootLoadRequest(
                rootIndex: rootIndex,
                canonicalPath: canonicalPath,
                rootName: stdURL.lastPathComponent
            ))
        }
        return requests
    }

    private func hydrateWorkspaceUserRootsBounded(
        _ requests: [WorkspaceRootLoadRequest],
        workspace: WorkspaceModel,
        hydrationGeneration: UInt64,
        maxConcurrentLoads: Int
    ) async -> [WorkspaceRootHydrationResult] {
        guard !requests.isEmpty, maxConcurrentLoads > 0 else { return [] }

        var nextRequestIndex = 0
        var results: [WorkspaceRootHydrationResult] = []
        results.reserveCapacity(requests.count)
        await withTaskGroup(of: WorkspaceRootHydrationResult.self) { group in
            func enqueueNext() {
                guard !Task.isCancelled, nextRequestIndex < requests.count else { return }
                let request = requests[nextRequestIndex]
                nextRequestIndex += 1
                group.addTask { @MainActor in
                    await self.hydrateWorkspaceUserRoot(
                        request,
                        workspace: workspace,
                        hydrationGeneration: hydrationGeneration
                    )
                }
            }

            let initialCount = min(maxConcurrentLoads, requests.count)
            for _ in 0 ..< initialCount {
                enqueueNext()
            }

            while let result = await group.next() {
                results.append(result)
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                enqueueNext()
            }
        }
        return results
    }

    @MainActor
    private func hydrateWorkspaceUserRoot(
        _ request: WorkspaceRootLoadRequest,
        workspace: WorkspaceModel,
        hydrationGeneration: UInt64
    ) async -> WorkspaceRootHydrationResult {
        let perRootStart = Date()
        #if DEBUG
            let perRootStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        logWorkspaceSwitch("hydrateRoot BEGIN root=\"\(request.canonicalPath)\"")

        do {
            try Task.checkCancellation()
            #if DEBUG
                debugRecordUserRootLoadStart(workspace: workspace, hydrationGeneration: hydrationGeneration, request: request)
                let rootLoadDebugContext = debugRootLoadContext(
                    workspace: workspace,
                    hydrationGeneration: hydrationGeneration,
                    request: request
                )
                let rootRecord = try await WorkspaceRootLoadDiagnostics.withContext(
                    rootLoadDebugContext,
                    path: request.canonicalPath
                ) {
                    try await fileManager.workspaceFileContextStore.loadRoot(
                        path: request.canonicalPath,
                        isSystemRoot: false,
                        kind: .primaryWorkspace,
                        respectRepoIgnore: fileManager.respectRepoIgnore,
                        respectCursorignore: fileManager.respectCursorignore,
                        skipSymlinks: fileManager.skipSymlinks,
                        enableHierarchicalIgnores: fileManager.enableHierarchicalIgnores,
                        cancelUnderlyingLoadOnCallerCancellation: true
                    )
                }
            #else
                let rootRecord = try await fileManager.workspaceFileContextStore.loadRoot(
                    path: request.canonicalPath,
                    isSystemRoot: false,
                    kind: .primaryWorkspace,
                    respectRepoIgnore: fileManager.respectRepoIgnore,
                    respectCursorignore: fileManager.respectCursorignore,
                    skipSymlinks: fileManager.skipSymlinks,
                    enableHierarchicalIgnores: fileManager.enableHierarchicalIgnores,
                    cancelUnderlyingLoadOnCallerCancellation: true
                )
            #endif
            if Task.isCancelled || !isHydrationGenerationCurrent(hydrationGeneration, workspaceID: workspace.id) {
                await fileManager.workspaceFileContextStore.unloadRoot(id: rootRecord.id)
                throw CancellationError()
            }
            #if DEBUG
                debugRecordRootShellPossible(
                    workspace: workspace,
                    hydrationGeneration: hydrationGeneration,
                    request: request,
                    rootRecord: rootRecord
                )
            #endif
            let perRootDuration = Date().timeIntervalSince(perRootStart)
            logWorkspaceSwitch("hydrateRoot END root=\"\(request.canonicalPath)\" duration=\(String(format: "%.3f", perRootDuration))s")
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "workspaceSwitch.loadWorkspaceFolders.userRootCatalogHydration",
                    fields: [
                        "workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
                        "rootIndex": "\(request.rootIndex)",
                        "rootName": request.rootName,
                        "rootID": WorkspaceRestorePerfLog.shortID(rootRecord.id),
                        "outcome": "success",
                        "duration": perRootStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            return WorkspaceRootHydrationResult(
                request: request,
                rootRecord: rootRecord,
                failure: nil,
                wasCancelled: false
            )
        } catch is CancellationError {
            let perRootDuration = Date().timeIntervalSince(perRootStart)
            logWorkspaceSwitch("hydrateRoot CANCELLED root=\"\(request.canonicalPath)\" duration=\(String(format: "%.3f", perRootDuration))s")
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "workspaceSwitch.loadWorkspaceFolders.userRootCatalogHydration",
                    fields: [
                        "workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
                        "rootIndex": "\(request.rootIndex)",
                        "rootName": request.rootName,
                        "outcome": "cancelled",
                        "duration": perRootStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            return WorkspaceRootHydrationResult(
                request: request,
                rootRecord: nil,
                failure: nil,
                wasCancelled: true
            )
        } catch {
            let perRootDuration = Date().timeIntervalSince(perRootStart)
            Self.logger.error("hydrateRoot ERROR root=\"\(request.canonicalPath)\" duration=\(String(format: "%.3f", perRootDuration))s error=\(error)")
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "workspaceSwitch.loadWorkspaceFolders.userRootCatalogHydration",
                    fields: [
                        "workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
                        "rootIndex": "\(request.rootIndex)",
                        "rootName": request.rootName,
                        "outcome": "error",
                        "duration": perRootStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            return WorkspaceRootHydrationResult(
                request: request,
                rootRecord: nil,
                failure: WorkspaceRootLoadFailure(
                    rootPath: request.canonicalPath,
                    kind: .primaryWorkspace,
                    errorDescription: String(describing: error)
                ),
                wasCancelled: false
            )
        }
    }

    nonisolated static func workspaceByApplyingSelection(
        _ selection: StoredSelection,
        toActiveTab activeTabID: UUID,
        in workspace: WorkspaceModel
    ) -> (workspace: WorkspaceModel, applied: Bool) {
        guard let tabIndex = workspace.composeTabs.firstIndex(where: { $0.id == activeTabID }) else {
            return (workspace, false)
        }
        var updated = workspace
        updated.composeTabs[tabIndex].selection = selection
        return (updated, true)
    }

    // MARK: - Global disk-writer

    /// Shared actor for serialized workspace disk writes across all windows
    actor WorkspaceDiskWriter {
        // MARK: internal model

        private struct Pending {
            var newestData: Data
            var newestMetadata: WorkspaceSavePayloadMetadata?
            var newestLifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?
            var task: Task<Void, Never>?
        }

        private struct LatestSelectionRecord {
            let revision: UInt64
            let selection: StoredSelection
            let metadata: WorkspaceSavePayloadMetadata
        }

        private struct EffectiveWritePayload {
            let data: Data
            let metadata: WorkspaceSavePayloadMetadata?
            let selectionKey: WorkspaceTabSelectionKey?
            let effectiveSelectionRevision: UInt64
            let shouldWrite: Bool
        }

        private var pendingByURL: [URL: Pending] = [:]
        private var waitersByURL: [URL: [CheckedContinuation<Void, Never>]] = [:]
        private var latestSelectionByWorkspaceTab: [WorkspaceTabSelectionKey: LatestSelectionRecord] = [:]
        private var lastWrittenSelectionRevisionByWorkspaceTab: [WorkspaceTabSelectionKey: UInt64] = [:]
        #if DEBUG
            private var atomicWriteGateForTesting: (@Sendable () async -> Void)?
        #endif

        // MARK: public API

        static let shared = WorkspaceDiskWriter()

        func enqueue(data: Data, url: URL) {
            enqueue(data: data, url: url, metadata: nil)
        }

        func enqueueWorkspace(data: Data, url: URL, metadata: WorkspaceSavePayloadMetadata) {
            enqueue(data: data, url: url, metadata: metadata)
        }

        private func enqueue(data: Data, url: URL, metadata: WorkspaceSavePayloadMetadata?) {
            let lifecycleCorrelation = EditFlowPerf.currentLifecycleCorrelation
            WorkspaceSaveTracer.event("workspaceSave.enqueue", metadata: metadata, url: url)
            recordLatestSelectionIfNeeded(metadata)

            if var pending = pendingByURL[url] {
                let decision: String
                if let metadata,
                   let existingMetadata = pending.newestMetadata,
                   metadata.activeSelectionRevision > existingMetadata.activeSelectionRevision
                {
                    pending.newestData = data
                    pending.newestMetadata = metadata
                    pending.newestLifecycleCorrelation = lifecycleCorrelation ?? pending.newestLifecycleCorrelation
                    decision = "replacedExistingNewerSelectionRevision"
                } else if Self.shouldKeepExistingWorkspacePayload(existing: pending.newestData, incoming: data, url: url) {
                    decision = "keptExistingNewerDate"
                    WorkspaceSaveTracer.event("workspaceSave.coalesce", metadata: metadata, url: url, extra: ["decision": decision])
                    return
                } else {
                    pending.newestData = data
                    pending.newestMetadata = metadata
                    pending.newestLifecycleCorrelation = lifecycleCorrelation ?? pending.newestLifecycleCorrelation
                    decision = "storedAsNewest"
                }
                pendingByURL[url] = pending
                WorkspaceSaveTracer.event("workspaceSave.coalesce", metadata: metadata, url: url, extra: ["decision": decision])
                return
            }

            pendingByURL[url] = Pending(
                newestData: data,
                newestMetadata: metadata,
                newestLifecycleCorrelation: lifecycleCorrelation,
                task: nil
            )
            runNext(for: url)
        }

        func enqueueAndWait(data: Data, url: URL) async {
            enqueue(data: data, url: url)
            await flush(url: url)
        }

        func writeNormalizationIfUnchanged(
            data: Data,
            url: URL,
            expectedFileSize: Int64,
            expectedModificationDate: Date,
            metadata: WorkspaceSavePayloadMetadata? = nil
        ) -> Bool {
            guard pendingByURL[url] == nil else { return false }
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard Int64(values.fileSize ?? -1) == expectedFileSize,
                      values.contentModificationDate == expectedModificationDate
                else {
                    return false
                }
                WorkspaceSaveTracer.event("workspaceSave.syncWrite.begin", metadata: metadata, url: url, extra: ["path": "normalization"])
                let writeState = EditFlowPerf.begin(EditFlowPerf.Stage.WorkspaceDurability.atomicWrite)
                EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.WorkspaceDurability.writeBegan)
                defer {
                    EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.WorkspaceDurability.writeEnded)
                    EditFlowPerf.end(EditFlowPerf.Stage.WorkspaceDurability.atomicWrite, writeState)
                }
                try data.write(to: url, options: .atomic)
                recordLatestSelectionIfNeeded(metadata)
                WorkspaceSaveTracer.event("workspaceSave.syncWrite.success", metadata: metadata, url: url, extra: ["path": "normalization"])
                return true
            } catch {
                WorkspaceSaveTracer.event("workspaceSave.syncWrite.failure", metadata: metadata, url: url, extra: ["error": error.localizedDescription, "path": "normalization"])
                print("💾 Normalization write skipped \(url.lastPathComponent): \(error)")
                return false
            }
        }

        func flush(url: URL) async {
            if pendingByURL[url] == nil { return }
            let lifecycleCorrelation = EditFlowPerf.currentLifecycleCorrelation
            let flushState = EditFlowPerf.begin(EditFlowPerf.Stage.WorkspaceDurability.flushWait)
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.WorkspaceDurability.flushBegan,
                correlation: lifecycleCorrelation
            )
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                waitersByURL[url, default: []].append(cont)
            }
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.WorkspaceDurability.flushEnded,
                correlation: lifecycleCorrelation
            )
            EditFlowPerf.end(EditFlowPerf.Stage.WorkspaceDurability.flushWait, flushState)
        }

        #if DEBUG
            func setAtomicWriteGateForTesting(_ gate: (@Sendable () async -> Void)?) {
                atomicWriteGateForTesting = gate
            }

            func removeAllForTesting() {
                for (_, pending) in pendingByURL {
                    pending.task?.cancel()
                }
                pendingByURL.removeAll()
                latestSelectionByWorkspaceTab.removeAll()
                lastWrittenSelectionRevisionByWorkspaceTab.removeAll()
                atomicWriteGateForTesting = nil
                let allWaiters = waitersByURL.values.flatMap(\.self)
                waitersByURL.removeAll()
                for waiter in allWaiters {
                    waiter.resume()
                }
            }
        #endif

        // MARK: private helpers

        private static func decodedWorkspacePayload(_ data: Data) -> WorkspaceModel? {
            guard !data.isEmpty else { return nil }
            return try? JSONDecoder().decode(WorkspaceModel.self, from: data)
        }

        private func recordLatestSelectionIfNeeded(_ metadata: WorkspaceSavePayloadMetadata?) {
            guard let metadata,
                  let key = metadata.selectionKey,
                  let selection = metadata.activeSelection,
                  metadata.activeSelectionRevision > 0
            else { return }
            if let existing = latestSelectionByWorkspaceTab[key], existing.revision >= metadata.activeSelectionRevision {
                return
            }
            latestSelectionByWorkspaceTab[key] = LatestSelectionRecord(
                revision: metadata.activeSelectionRevision,
                selection: selection,
                metadata: metadata
            )
        }

        private static func shouldKeepExistingWorkspacePayload(existing: Data, incoming: Data, url: URL) -> Bool {
            guard let existingWorkspace = decodedWorkspacePayload(existing),
                  let incomingWorkspace = decodedWorkspacePayload(incoming),
                  existingWorkspace.id == incomingWorkspace.id,
                  existingWorkspace.dateModified > incomingWorkspace.dateModified
            else {
                return false
            }
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "workspaceDiskWriter.skipStaleCoalescedPayload",
                    fields: [
                        "workspaceID": WorkspaceRestorePerfLog.shortID(incomingWorkspace.id),
                        "workspaceName": incomingWorkspace.name,
                        "url": url.lastPathComponent
                    ]
                )
            #endif
            return true
        }

        private static func effectivePayloadForWrite(
            payload: Data,
            url: URL,
            metadata: WorkspaceSavePayloadMetadata?,
            latestRecord: LatestSelectionRecord?,
            lastWrittenRevision: UInt64
        ) -> EffectiveWritePayload {
            guard let metadata,
                  let incomingWorkspace = decodedWorkspacePayload(payload),
                  incomingWorkspace.id == metadata.workspaceID
            else {
                let shouldWrite = !shouldSkipStaleWorkspaceDiskWrite(payload: payload, url: url, metadata: metadata)
                return EffectiveWritePayload(data: payload, metadata: metadata, selectionKey: metadata?.selectionKey, effectiveSelectionRevision: metadata?.activeSelectionRevision ?? 0, shouldWrite: shouldWrite)
            }

            let key = metadata.selectionKey
            let incomingRevision = metadata.activeSelectionRevision
            let latestRevision = latestRecord?.revision ?? incomingRevision
            let latestSelection = latestRecord?.selection ?? metadata.activeSelection
            let latestMetadata = latestRecord?.metadata ?? metadata
            let diskWorkspace: WorkspaceModel? = if FileManager.default.fileExists(atPath: url.path),
                                                    let diskData = try? Data(contentsOf: url),
                                                    let decoded = decodedWorkspacePayload(diskData),
                                                    decoded.id == incomingWorkspace.id
            {
                decoded
            } else {
                nil
            }

            if let diskWorkspace, diskWorkspace.dateModified > incomingWorkspace.dateModified {
                if latestRevision > lastWrittenRevision,
                   let latestSelection,
                   let activeTabID = metadata.activeTabID
                {
                    let applied = WorkspaceManagerViewModel.workspaceByApplyingSelection(latestSelection, toActiveTab: activeTabID, in: diskWorkspace)
                    if applied.applied {
                        var merged = applied.workspace
                        merged.dateModified = Date()
                        if let encoded = try? JSONEncoder().encode(merged) {
                            WorkspaceSaveTracer.event(
                                "workspaceSave.write.newerSelectionMergedIntoNewerDisk",
                                metadata: metadata,
                                url: url,
                                extra: [
                                    "latestSelectionRevision": "\(latestRevision)",
                                    "lastWrittenSelectionRevision": "\(lastWrittenRevision)",
                                    "latestPayloadID": latestMetadata.payloadID.uuidString
                                ]
                            )
                            return EffectiveWritePayload(data: encoded, metadata: latestMetadata, selectionKey: key, effectiveSelectionRevision: latestRevision, shouldWrite: true)
                        }
                    }
                }
                WorkspaceSaveTracer.event("workspaceSave.write.skipStaleDiskPayload", metadata: metadata, url: url)
                return EffectiveWritePayload(data: payload, metadata: metadata, selectionKey: key, effectiveSelectionRevision: incomingRevision, shouldWrite: false)
            }

            if latestRevision > incomingRevision,
               let latestSelection,
               let activeTabID = metadata.activeTabID
            {
                let applied = WorkspaceManagerViewModel.workspaceByApplyingSelection(latestSelection, toActiveTab: activeTabID, in: incomingWorkspace)
                if applied.applied,
                   let encoded = try? JSONEncoder().encode(applied.workspace)
                {
                    WorkspaceSaveTracer.event(
                        "workspaceSave.write.selectionPreservedFromLatest",
                        metadata: metadata,
                        url: url,
                        extra: [
                            "incomingSelectionRevision": "\(incomingRevision)",
                            "latestSelectionRevision": "\(latestRevision)",
                            "latestPayloadID": latestMetadata.payloadID.uuidString
                        ]
                    )
                    return EffectiveWritePayload(data: encoded, metadata: latestMetadata, selectionKey: key, effectiveSelectionRevision: latestRevision, shouldWrite: true)
                }
            }

            return EffectiveWritePayload(data: payload, metadata: metadata, selectionKey: key, effectiveSelectionRevision: incomingRevision, shouldWrite: true)
        }

        private static func shouldSkipStaleWorkspaceDiskWrite(payload: Data, url: URL, metadata: WorkspaceSavePayloadMetadata?) -> Bool {
            guard FileManager.default.fileExists(atPath: url.path),
                  let incomingWorkspace = decodedWorkspacePayload(payload),
                  let diskData = try? Data(contentsOf: url),
                  let diskWorkspace = decodedWorkspacePayload(diskData),
                  diskWorkspace.id == incomingWorkspace.id,
                  diskWorkspace.dateModified > incomingWorkspace.dateModified
            else {
                return false
            }
            WorkspaceSaveTracer.event("workspaceSave.write.skipStaleDiskPayload", metadata: metadata, url: url)
            return true
        }

        private func runNext(for url: URL) {
            guard var slot = pendingByURL[url] else { return }
            let payload = slot.newestData
            let metadata = slot.newestMetadata
            let lifecycleCorrelation = slot.newestLifecycleCorrelation
            slot.newestData = Data()
            slot.newestMetadata = nil
            slot.newestLifecycleCorrelation = nil
            pendingByURL[url] = slot
            let latestRecord = metadata?.selectionKey.flatMap { latestSelectionByWorkspaceTab[$0] }
            let lastWrittenRevision = metadata?.selectionKey.map { lastWrittenSelectionRevisionByWorkspaceTab[$0, default: 0] } ?? 0
            #if DEBUG
                let atomicWriteGateForTesting = atomicWriteGateForTesting
            #endif

            let task = Task.detached(priority: .utility) { [weak self] in
                let effective = Self.effectivePayloadForWrite(
                    payload: payload,
                    url: url,
                    metadata: metadata,
                    latestRecord: latestRecord,
                    lastWrittenRevision: lastWrittenRevision
                )
                WorkspaceSaveTracer.event("workspaceSave.write.begin", metadata: effective.metadata, url: url, extra: ["shouldWrite": "\(effective.shouldWrite)"])
                var writeSucceeded = false
                do {
                    if effective.shouldWrite {
                        #if DEBUG
                            await atomicWriteGateForTesting?()
                        #endif
                        let writeState = EditFlowPerf.begin(EditFlowPerf.Stage.WorkspaceDurability.atomicWrite)
                        EditFlowPerf.lifecycleEvent(
                            EditFlowPerf.Lifecycle.WorkspaceDurability.writeBegan,
                            correlation: lifecycleCorrelation
                        )
                        defer {
                            EditFlowPerf.lifecycleEvent(
                                EditFlowPerf.Lifecycle.WorkspaceDurability.writeEnded,
                                correlation: lifecycleCorrelation,
                                EditFlowPerf.Dimensions(outcome: writeSucceeded ? "success" : "failed")
                            )
                            EditFlowPerf.end(
                                EditFlowPerf.Stage.WorkspaceDurability.atomicWrite,
                                writeState,
                                EditFlowPerf.Dimensions(outcome: writeSucceeded ? "success" : "failed")
                            )
                        }
                        try effective.data.write(to: url, options: .atomic)
                        writeSucceeded = true
                        WorkspaceSaveTracer.event("workspaceSave.write.success", metadata: effective.metadata, url: url)
                    }
                } catch {
                    WorkspaceSaveTracer.event("workspaceSave.write.failure", metadata: effective.metadata, url: url, extra: ["error": error.localizedDescription])
                    print("💾 Write failed \(url.lastPathComponent): \(error)")
                }
                WorkspaceSaveTracer.event("workspaceSave.write.finish", metadata: effective.metadata, url: url, extra: ["writeSucceeded": "\(writeSucceeded)"])
                await self?.writerFinished(for: url, effective: effective, writeSucceeded: writeSucceeded)
            }
            if var current = pendingByURL[url] {
                current.task = task
                pendingByURL[url] = current
            }
        }

        private func writerFinished(for url: URL, effective: EffectiveWritePayload, writeSucceeded: Bool) {
            if writeSucceeded,
               let key = effective.selectionKey,
               effective.effectiveSelectionRevision > 0
            {
                lastWrittenSelectionRevisionByWorkspaceTab[key] = max(
                    lastWrittenSelectionRevisionByWorkspaceTab[key, default: 0],
                    effective.effectiveSelectionRevision
                )
            }
            guard var slot = pendingByURL[url] else { return }
            if slot.newestData.isEmpty {
                pendingByURL.removeValue(forKey: url)
                if let waiters = waitersByURL.removeValue(forKey: url) {
                    for w in waiters {
                        w.resume()
                    }
                }
            } else {
                slot.task = nil
                pendingByURL[url] = slot
                runNext(for: url)
            }
        }
    }

    // MARK: - Save/Load Single Workspace

    private func saveWorkspaceAsync(source: WorkspaceSaveSource = .saveWorkspaceAsync) async {
        guard let active = activeWorkspace,
              let idx = workspaces.firstIndex(where: { $0.id == active.id })
        else {
            print("No active workspace to save.")
            return
        }

        let current = workspaces[idx]
        let capturedStateVersion = stateVersionByWorkspaceID[current.id, default: 0]
        let baseRoot = currentBaseRoot
        let customStoragePath = current.customStoragePath
        let workspaceDirName = directoryName(for: current)
        let lastSyncedRepoPaths = lastSyncedRepoPathsByWorkspaceID[current.id]
        await WorkspaceDiskWriter.shared.flush(url: workspaceFileURL(for: current))

        do {
            let (merged, data, indexFieldsChanged, preservedDiskRepoPaths, url) = try await Task.detached(priority: .utility) {
                let workspaceDir: URL = if let customStoragePath {
                    customStoragePath
                } else {
                    baseRoot.appendingPathComponent(workspaceDirName)
                }
                let chatsDir = workspaceDir.appendingPathComponent("Chats", isDirectory: true)
                let fm = FileManager.default

                if !fm.fileExists(atPath: workspaceDir.path) {
                    do {
                        try fm.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
                    } catch CocoaError.fileWriteFileExists {
                        // Directory was created concurrently; safe to ignore
                    }
                }

                if !fm.fileExists(atPath: chatsDir.path) {
                    do {
                        try fm.createDirectory(at: chatsDir, withIntermediateDirectories: true)
                    } catch CocoaError.fileWriteFileExists {
                        // Directory was created concurrently; safe to ignore
                    }
                }

                let url = workspaceDir.appendingPathComponent("workspace.json")
                let diskWorkspace: WorkspaceModel? = if fm.fileExists(atPath: url.path) {
                    try? Self.loadWorkspaceFromFile(at: url)
                } else {
                    nil
                }

                let mergeResult = Self.workspaceForSavePreservingDiskRepoPaths(
                    current: current,
                    diskWorkspace: diskWorkspace,
                    lastSyncedRepoPaths: lastSyncedRepoPaths
                )
                let merged = mergeResult.workspace
                let data = try JSONEncoder().encode(merged)
                let indexFieldsChanged =
                    (merged.name != current.name) ||
                    (merged.customStoragePath != current.customStoragePath) ||
                    (merged.isSystemWorkspace != current.isSystemWorkspace) ||
                    (merged.isHiddenInMenus != current.isHiddenInMenus)

                return (merged, data, indexFieldsChanged, mergeResult.preservedDiskRepoPaths, url)
            }.value

            let latestStateVersion = stateVersionByWorkspaceID[current.id, default: 0]
            if latestStateVersion != capturedStateVersion {
                #if DEBUG
                    WorkspaceRestorePerfLog.event(
                        "workspaceSave.stalePayload.retry",
                        fields: [
                            "workspaceID": WorkspaceRestorePerfLog.shortID(current.id),
                            "capturedVersion": "\(capturedStateVersion)",
                            "latestVersion": "\(latestStateVersion)"
                        ]
                    )
                #endif
                await saveWorkspaceAsync(source: source)
                return
            }

            // IMPORTANT: Do NOT assign `workspaces[idx] = merged` here.
            // Our in-memory `workspaces[idx]` already contains our working state.
            // If index-visible fields changed, update them *individually* to avoid a huge copy.
            if indexFieldsChanged {
                // Mutate only the few small fields that affect the index
                workspaces[idx].name = merged.name
                workspaces[idx].customStoragePath = merged.customStoragePath
                workspaces[idx].isSystemWorkspace = merged.isSystemWorkspace
                workspaces[idx].isHiddenInMenus = merged.isHiddenInMenus
                // (These in-place field writes don't rebuild the entire array)
            }
            if preservedDiskRepoPaths {
                workspaces[idx].repoPaths = merged.repoPaths
            }
            recordRepoPathBaseline(for: merged)

            let metadata = workspaceSaveMetadata(for: merged, source: source)
            WorkspaceFileDecodeCache.shared.invalidate(url: url)
            await WorkspaceDiskWriter.shared.enqueueWorkspace(data: data, url: url, metadata: metadata)

            if indexFieldsChanged {
                await rebuildAndSaveIndexAsync()
            }
        } catch {
            print("💾 Failed to serialize workspace: \(error)")
        }
    }

    private func scheduleSave(source: WorkspaceSaveSource) {
        // Use async version
        Task {
            await saveWorkspaceAsync(source: source)
        }
    }

    // File I/O queue removed - now using async/await for non-blocking operations

    /// Persists a workspace to disk and returns the final file URL.
    /// Async version for non-blocking disk I/O using shared disk writer
    ///
    /// - Throws: `JSONEncoder` / `FileManager` errors.
    /// Async version for non-blocking disk I/O using shared disk writer
    func saveWorkspaceToFileAsync(
        _ workspace: WorkspaceModel,
        preserveDiskRepoPathsIfUnchangedSinceBaseline: Bool = true,
        source: WorkspaceSaveSource = .directUnknown
    ) async throws -> URL {
        let targetURL = workspaceFileURL(for: workspace)
        let capturedStateVersion = stateVersionByWorkspaceID[workspace.id, default: 0]
        await WorkspaceDiskWriter.shared.flush(url: targetURL)

        var workspaceToSave = workspace
        if preserveDiskRepoPathsIfUnchangedSinceBaseline,
           FileManager.default.fileExists(atPath: targetURL.path)
        {
            let diskWorkspace = try? Self.loadWorkspaceFromFile(at: targetURL)
            let mergeResult = Self.workspaceForSavePreservingDiskRepoPaths(
                current: workspace,
                diskWorkspace: diskWorkspace,
                lastSyncedRepoPaths: lastSyncedRepoPathsByWorkspaceID[workspace.id],
                modificationDate: workspace.dateModified
            )
            workspaceToSave = mergeResult.workspace
            if mergeResult.preservedDiskRepoPaths,
               let index = workspaceIndex(for: workspace.id),
               !hasLocalRepoPathEdit(for: workspaces[index])
            {
                workspaces[index].repoPaths = workspaceToSave.repoPaths
            }
        }

        let latestStateVersion = stateVersionByWorkspaceID[workspace.id, default: 0]
        if latestStateVersion != capturedStateVersion,
           let index = workspaceIndex(for: workspace.id)
        {
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "workspaceSave.direct.stalePayload.retry",
                    fields: [
                        "workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
                        "capturedVersion": "\(capturedStateVersion)",
                        "latestVersion": "\(latestStateVersion)"
                    ]
                )
            #endif
            return try await saveWorkspaceToFileAsync(workspaces[index], preserveDiskRepoPathsIfUnchangedSinceBaseline: preserveDiskRepoPathsIfUnchangedSinceBaseline, source: source)
        }

        let metadata = workspaceSaveMetadata(for: workspaceToSave, source: source)
        WorkspaceSaveTracer.event("workspaceSave.direct.enqueue", metadata: metadata, url: targetURL)
        let finalURL = try await saveWorkspaceToFileAsync(workspaceToSave, baseRoot: currentBaseRoot, metadata: metadata)
        recordRepoPathBaseline(for: workspaceToSave)
        return finalURL
    }

    nonisolated func saveWorkspaceToFileAsync(_ workspace: WorkspaceModel, baseRoot: URL, metadata: WorkspaceSavePayloadMetadata? = nil) async throws -> URL {
        // Encode JSON
        let encoded = try JSONEncoder().encode(workspace)

        // Prepare file path
        let folder = try ensureWorkspaceDirectoryExists(for: workspace, baseRoot: baseRoot)
        let finalURL = folder.appendingPathComponent("workspace.json")

        // Enqueue write to shared disk writer for serialization
        WorkspaceFileDecodeCache.shared.invalidate(url: finalURL)
        if let metadata {
            await WorkspaceDiskWriter.shared.enqueueWorkspace(data: encoded, url: finalURL, metadata: metadata)
        } else {
            await WorkspaceDiskWriter.shared.enqueue(data: encoded, url: finalURL)
        }

        return finalURL
    }

    /// Synchronous workspace write used by focused tests and direct save paths.
    func saveWorkspaceToFile(_ workspace: WorkspaceModel, source: WorkspaceSaveSource = .directUnknown) throws -> URL {
        // Encode JSON and prepare file path
        let encoded = try JSONEncoder().encode(workspace)
        let folder = try ensureWorkspaceDirectoryExists(for: workspace)
        let finalURL = folder.appendingPathComponent("workspace.json")
        let metadata = workspaceSaveMetadata(for: workspace, source: source)

        // Write synchronously for direct save paths.
        WorkspaceFileDecodeCache.shared.invalidate(url: finalURL)
        WorkspaceSaveTracer.event("workspaceSave.syncWrite.begin", metadata: metadata, url: finalURL)
        do {
            try encoded.write(to: finalURL, options: .atomic)
            WorkspaceSaveTracer.event("workspaceSave.syncWrite.success", metadata: metadata, url: finalURL)
        } catch {
            WorkspaceSaveTracer.event("workspaceSave.syncWrite.failure", metadata: metadata, url: finalURL, extra: ["error": error.localizedDescription])
            throw error
        }

        return finalURL
    }

    nonisolated static func loadWorkspaceFromFileResult(at fileURL: URL) throws -> WorkspaceFileLoadResult {
        let cachedResult = try WorkspaceFileDecodeCache.shared.loadWorkspace(at: fileURL)
        let normalizationSaveTask: Task<Void, Never>?
        if cachedResult.normalizationRequiresSave,
           WorkspaceFileDecodeCache.shared.claimNormalizationSave(for: cachedResult.cacheKey)
        {
            let workspaceToSave = cachedResult.workspace
            let saveURL = URL(fileURLWithPath: cachedResult.cacheKey.standardizedPath)
            let cacheKey = cachedResult.cacheKey
            normalizationSaveTask = Task.detached(priority: .utility) {
                do {
                    guard WorkspaceFileDecodeCache.shared.isNormalizationSaveClaimed(for: cacheKey),
                          let currentKey = try? WorkspaceFileDecodeCache.shared.metadataKey(for: saveURL),
                          currentKey == cacheKey
                    else {
                        WorkspaceFileDecodeCache.shared.finishNormalizationSave(for: cacheKey)
                        return
                    }
                    let encoded = try JSONEncoder().encode(workspaceToSave)
                    let metadata = WorkspaceManagerViewModel.metadata(for: workspaceToSave, source: .normalizationWriteback)
                    _ = await WorkspaceDiskWriter.shared.writeNormalizationIfUnchanged(
                        data: encoded,
                        url: saveURL,
                        expectedFileSize: cacheKey.fileSize,
                        expectedModificationDate: cacheKey.modificationDate,
                        metadata: metadata
                    )
                } catch {
                    print("💾 Failed to persist normalized workspace \(saveURL.lastPathComponent): \(error)")
                }
                WorkspaceFileDecodeCache.shared.finishNormalizationSave(for: cacheKey)
            }
        } else {
            normalizationSaveTask = nil
        }

        return WorkspaceFileLoadResult(
            workspace: cachedResult.workspace,
            cacheHit: cachedResult.cacheHit,
            composeTabsNormalized: cachedResult.composeTabsNormalized,
            normalizationSaveTask: normalizationSaveTask
        )
    }

    nonisolated static func loadWorkspaceFromFile(at fileURL: URL) throws -> WorkspaceModel {
        try loadWorkspaceFromFileResult(at: fileURL).workspace
    }

    nonisolated static func loadWorkspaceFromFileAsync(at fileURL: URL) async throws -> WorkspaceModel {
        try await Task.detached(priority: .utility) {
            try Self.loadWorkspaceFromFile(at: fileURL)
        }.value
    }

    /// Async version for directory creation with race condition handling
    func ensureWorkspaceDirectoryExists(for workspace: WorkspaceModel) throws -> URL {
        try ensureWorkspaceDirectoryExists(for: workspace, baseRoot: currentBaseRoot)
    }

    nonisolated func ensureWorkspaceDirectoryExists(for workspace: WorkspaceModel, baseRoot: URL) throws -> URL {
        let dir = workspaceDirectory(for: workspace, baseRoot: baseRoot)
        let chats = chatsFolder(for: workspace, baseRoot: baseRoot)
        let fm = FileManager.default

        // Create the main directory if missing
        if !fm.fileExists(atPath: dir.path) {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch CocoaError.fileWriteFileExists {
                // Directory was created concurrently; safe to ignore
            }
        }

        // Create the Chats sub-directory if missing
        if !fm.fileExists(atPath: chats.path) {
            do {
                try fm.createDirectory(at: chats, withIntermediateDirectories: true)
            } catch CocoaError.fileWriteFileExists {
                // Directory was created concurrently; safe to ignore
            }
        }

        return dir
    }

    // MARK: - Reset to Default

    func resetGlobalStorageToDefault(migrate: Bool = true) throws {
        guard let currentGlobal = globalCustomStorageURL else {
            print("Already using default storage.")
            return
        }

        for ws in workspaces {
            let oldFolder = currentGlobal.appendingPathComponent(directoryName(for: ws))
            let newFolder = defaultWorkspaceRoot().appendingPathComponent(directoryName(for: ws))

            if !FileManager.default.fileExists(atPath: newFolder.path) {
                try FileManager.default.createDirectory(
                    at: newFolder,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            }

            if FileManager.default.fileExists(atPath: oldFolder.path) {
                if migrate {
                    try moveFolderContents(from: oldFolder, to: newFolder)
                }
                try? FileManager.default.removeItem(at: oldFolder)
            }

            if let idx = workspaces.firstIndex(where: { $0.id == ws.id }) {
                workspaces[idx].customStoragePath = nil
            }
        }
        globalCustomStorageURL = nil

        // Schedule async index save
        Task {
            await rebuildAndSaveIndexAsync()
        }
    }

    private func moveFolderContents(from oldFolder: URL, to newFolder: URL) throws {
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(atPath: oldFolder.path)
        for item in items {
            let srcURL = oldFolder.appendingPathComponent(item)
            let dstURL = newFolder.appendingPathComponent(item)
            if fm.fileExists(atPath: dstURL.path) {
                try fm.removeItem(at: dstURL)
            }
            try fm.moveItem(at: srcURL, to: dstURL)
        }
    }

    // MARK: - Folder Management

    func unloadAllFolders(from workspace: WorkspaceModel) async {
        if workspace.id == activeWorkspace?.id {
            await fileManager.unloadAllRootFolders()
        }
    }

    func updateGlobalStoragePath(_ newURL: URL) throws {
        let oldBase = currentBaseRoot
        for ws in workspaces {
            let oldFolder = oldBase.appendingPathComponent(directoryName(for: ws))
            let newFolder = newURL.appendingPathComponent(directoryName(for: ws))
            if FileManager.default.fileExists(atPath: oldFolder.path) {
                try FileManager.default.moveItem(at: oldFolder, to: newFolder)
            }
        }

        globalCustomStorageURL = newURL

        // Schedule async index save
        Task {
            await rebuildAndSaveIndexAsync()
        }
    }

    @MainActor
    func refreshWorkspace(soft: Bool, for workspace: WorkspaceModel) async {
        let wsID = workspace.id
        guard wsID == activeWorkspaceID else { return }
        guard !isRefreshing, !isSwitchingWorkspace else { return }

        stopPollTimer()
        isRefreshing = true

        // Track which tab we suspended so we can ALWAYS resume even if we early-return.
        var suspendedTabID: UUID?

        defer {
            if let tabID = suspendedTabID {
                setSnapshotsSuspended(false, forTabID: tabID)
            }
            isRefreshing = false
            drainPendingRepoPathSyncIfNeeded()
            startPollTimer()
            promptViewModel.startTokenCountUpdateTimer()
        }

        await promptViewModel.stopTokenCountUpdateTimer()

        // Helper: refetch workspace after each await to avoid stale indices.
        func currentWorkspaceForRefresh() -> WorkspaceModel? {
            guard !isSwitchingWorkspace else { return nil }
            guard activeWorkspaceID == wsID else { return nil } // deleted or switched
            guard let idx = workspaceIndex(for: wsID) else { return nil }
            return workspaces[idx]
        }

        // Capture snapshot with a fresh index (workspace could be deleted during the await above).
        guard let snapIdx = workspaceIndex(for: wsID) else { return }
        let snapshot = captureActiveTabSnapshotForWorkspaceIndex(snapIdx)

        // Suspend snapshot commits during refresh to prevent $selectedFiles subscriber
        // from overwriting the captured selection when dropSelections clears it.
        if let tabID = snapshot?.id {
            setSnapshotsSuspended(true, forTabID: tabID)
            suspendedTabID = tabID
        }

        // Reconcile loaded roots with desired workspace repoPaths
        guard let ws0 = currentWorkspaceForRefresh() else { return }
        await syncLoadedRootsWithWorkspace(ws0)

        // Refresh watchers/filters for roots that are already loaded
        guard let ws1 = currentWorkspaceForRefresh() else { return }
        await fileManager.refreshContents(model: ws1, forceRefresh: !soft)

        // Enforce final order after any reloads
        guard let ws2 = currentWorkspaceForRefresh() else { return }
        let desiredPaths = Self.loadableRepoPaths(for: ws2)
        fileManager.reorderRootFolders(to: desiredPaths)

        // Restore UI state (selection, expanded folders, presets, etc)
        guard let ws3 = currentWorkspaceForRefresh() else { return }
        await restoreWorkspaceState(ws3)

        // Final save only if still the same active workspace.
        guard activeWorkspaceID == wsID, !isSwitchingWorkspace else { return }
        await saveWorkspaceAsync(source: .refreshWorkspace)
    }

    @MainActor
    private func syncLoadedRootsWithWorkspace(_ workspace: WorkspaceModel) async {
        let wsID = workspace.id
        guard activeWorkspaceID == wsID, workspaceIndex(for: wsID) != nil else { return }

        func norm(_ p: String) -> String {
            ((p as NSString).expandingTildeInPath as NSString).standardizingPath
        }
        var seen = Set<String>()
        var desiredOrdered: [String] = []
        var desiredCanonicalMap: [String: String] = [:]
        for rawPath in Self.loadableRepoPaths(for: workspace) {
            let normalized = norm(rawPath)
            let key = normalized.lowercased()
            if seen.insert(key).inserted {
                desiredOrdered.append(normalized)
                desiredCanonicalMap[key] = normalized
            }
        }

        let loadedCanonicalMap = fileManager.rootFolders
            .filter { !$0.isSystemRoot }
            .reduce(into: [String: String]()) { result, folder in
                let normalized = (folder.fullPath as NSString).standardizingPath
                let key = normalized.lowercased()
                if result[key] == nil {
                    result[key] = normalized
                }
            }

        let desiredKeys = Set(desiredCanonicalMap.keys)
        let loadedKeys = Set(loadedCanonicalMap.keys)

        // Unload anything no longer desired (order doesn't matter for unload)
        let toUnloadKeys = loadedKeys.subtracting(desiredKeys)
        for key in toUnloadKeys {
            guard activeWorkspaceID == wsID, workspaceIndex(for: wsID) != nil else { return }
            if let path = loadedCanonicalMap[key] {
                await fileManager.unloadRootFolderPath(path)
            }
        }

        // Load in the same order as workspace.repoPaths
        let toLoadOrdered = desiredOrdered.filter { loadedCanonicalMap[$0.lowercased()] == nil }
        for p in toLoadOrdered {
            guard activeWorkspaceID == wsID, workspaceIndex(for: wsID) != nil else { return }
            let url = fileManager.canonicalURL(for: p, assumingDirectory: true)
            do {
                try await fileManager.loadFolder(at: url, for: workspace, freshStart: false)
            } catch {
                // Silently continue - failed loads are handled by the fileManager
            }
        }

        // Enforce order immediately after reconciliation
        guard activeWorkspaceID == wsID, workspaceIndex(for: wsID) != nil else { return }
        fileManager.reorderRootFolders(to: desiredOrdered)
    }

    private func handleAllFoldersUnloaded() {
        guard let active = activeWorkspace else { return }
        if isRefreshing { return }

        if active.repoPaths.isEmpty {
            if let fallback = findOrCreateDefaultWorkspace(),
               fallback.id != active.id,
               !fallback.repoPaths.isEmpty
            {
                Task {
                    await switchWorkspace(to: fallback, saveState: false)
                }
            }
        }
    }

    @MainActor
    func removeActiveWorkspaceRoot(path: String) async {
        if isRefreshing { return }
        await removeFolder(path)
    }

    @MainActor
    func moveActiveWorkspaceRoot(
        path: String,
        direction: WorkspaceRootMoveDirection,
        visibleRootOrder: [String]
    ) async {
        guard !isRefreshing,
              let activeWS = activeWorkspace,
              let index = workspaces.firstIndex(where: { $0.id == activeWS.id }) else { return }

        let reorderedRepoPaths = WorkspaceRootActions.movedRepoPaths(
            repoPaths: workspaces[index].repoPaths,
            movingRootPath: path,
            direction: direction,
            visibleRootPaths: visibleRootOrder
        )
        guard !Self.repoPathsEquivalent(workspaces[index].repoPaths, reorderedRepoPaths) else { return }

        workspaces[index].repoPaths = reorderedRepoPaths
        workspaces[index].dateModified = Date()
        fileManager.reorderRootFolders(to: reorderedRepoPaths)

        do {
            let workspaceToSave = workspaces[index]
            let finalURL = try await saveWorkspaceToFileAsync(
                workspaceToSave,
                preserveDiskRepoPathsIfUnchangedSinceBaseline: false,
                source: .rootReorder
            )
            await WorkspaceDiskWriter.shared.flush(url: finalURL)
            recordRepoPathBaseline(for: workspaceToSave)
            postWorkspaceRepoPathsDidChange(for: workspaceToSave.id)
        } catch {
            print("Failed to save workspace after reordering: \(error)")
        }
    }

    func removeFolder(_ folderPath: String) async {
        guard let activeWS = activeWorkspace else { return }
        await removeFolder(folderPath, from: activeWS)
    }

    func removeFolder(_ folderPath: String, from workspace: WorkspaceModel) async {
        // Normalise both sides before comparison so we match identical paths
        // that differ only by redundant "/", "." segments, etc.
        let normalisedTarget = (folderPath as NSString).standardizingPath
        let oldPaths = workspace.repoPaths
        let newPaths = oldPaths.filter {
            let candidate = ($0 as NSString).standardizingPath
            return candidate != normalisedTarget
        }

        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        if newPaths.isEmpty {
            if let fallback = findOrCreateDefaultWorkspace() {
                await switchWorkspace(to: fallback)
            }
            return
        }

        pollAndSaveState(source: .rootRemove)
        workspaces[index].repoPaths = newPaths

        // Save and wait for completion before unloading folder—but persist this workspace, not just the active one
        do {
            let workspaceToSave = workspaces[index]
            let finalURL = try await saveWorkspaceToFileAsync(workspaceToSave, preserveDiskRepoPathsIfUnchangedSinceBaseline: false, source: .rootRemove)
            await WorkspaceDiskWriter.shared.flush(url: finalURL)
            recordRepoPathBaseline(for: workspaceToSave)
            postWorkspaceRepoPathsDidChange(for: workspaceToSave.id)
            await fileManager.unloadRootFolderPath(folderPath)
        } catch {
            print("Error saving workspace after removing folder: \(error)")
        }
    }

    @MainActor
    func addFolder(_ folderURL: URL, to workspace: WorkspaceModel) async throws {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }

        let path = (folderURL.path as NSString).standardizingPath
        try validateNewRootPath(path, against: workspaces[index].repoPaths)
        let alreadyHas = workspaces[index].repoPaths.contains {
            let normalized = ($0 as NSString).standardizingPath
            return normalized.caseInsensitiveCompare(path) == .orderedSame
        }
        if !alreadyHas {
            workspaces[index].repoPaths.append(path)
            workspaces[index].dateModified = Date()

            // Save asynchronously and flush for cross-window consistency
            do {
                let workspaceToSave = workspaces[index]
                let finalURL = try await saveWorkspaceToFileAsync(workspaceToSave, preserveDiskRepoPathsIfUnchangedSinceBaseline: false, source: .rootAdd)
                await WorkspaceDiskWriter.shared.flush(url: finalURL)
                recordRepoPathBaseline(for: workspaceToSave)
                await rebuildAndSaveIndexAsync()
                await WorkspaceDiskWriter.shared.flush(url: workspaceIndexFileURL)
                postWorkspaceRepoPathsDidChange(for: workspaceToSave.id)
            } catch {
                print("Error saving workspace after adding folder: \(error)")
                throw error
            }
        }

        if workspace.id == activeWorkspace?.id {
            do {
                try await fileManager.loadFolder(at: folderURL, for: workspace, freshStart: false)
            } catch {
                print("Error loading folder \(folderURL.path): \(error)")
                throw error
            }
        }
    }

    enum AddFolderError: LocalizedError {
        case nestedWithinExisting(candidate: String, existing: String)
        case containsExisting(candidate: String, existing: String)

        var agentMessage: String {
            switch self {
            case let .nestedWithinExisting(candidate, existing):
                "Cannot add folder. Candidate '\(candidate)' is inside existing workspace root '\(existing)'. Remove the existing root or choose a different folder."
            case let .containsExisting(candidate, existing):
                "Cannot add folder. Candidate '\(candidate)' contains existing workspace root '\(existing)'. Remove the existing root or choose a different folder."
            }
        }

        var errorDescription: String? {
            switch self {
            case let .nestedWithinExisting(candidate, existing):
                "Folder \"\(candidate)\" is inside existing workspace root \"\(existing)\". Choose a different folder or remove the existing root first."
            case let .containsExisting(candidate, existing):
                "Folder \"\(candidate)\" contains existing workspace root \"\(existing)\". Remove the existing root first or choose a different folder."
            }
        }
    }

    private func validateNewRootPath(_ path: String, against existingPaths: [String]) throws {
        let candidate = normalizedRootPath(path)
        for existing in existingPaths {
            let normalizedExisting = normalizedRootPath(existing)
            if candidate.caseInsensitiveCompare(normalizedExisting) == .orderedSame {
                continue
            }
            if isDescendantPath(candidate, of: normalizedExisting) {
                throw AddFolderError.nestedWithinExisting(candidate: candidate, existing: normalizedExisting)
            }
            if isDescendantPath(normalizedExisting, of: candidate) {
                throw AddFolderError.containsExisting(candidate: candidate, existing: normalizedExisting)
            }
        }
    }

    private func normalizedRootPath(_ path: String) -> String {
        var normalized = (path as NSString).standardizingPath
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private func isDescendantPath(_ path: String, of ancestor: String) -> Bool {
        let normalizedPath = normalizedRootPath(path)
        let normalizedAncestor = normalizedRootPath(ancestor)
        if normalizedPath.caseInsensitiveCompare(normalizedAncestor) == .orderedSame {
            return false
        }
        let ancestorPrefix = normalizedAncestor.hasSuffix("/") ? normalizedAncestor : normalizedAncestor + "/"
        return normalizedPath.lowercased().hasPrefix(ancestorPrefix.lowercased())
    }

    @MainActor
    func addFolder(_ folderURL: URL) async throws {
        if activeWorkspace == nil ||
            (activeWorkspace?.name == "Default" && activeWorkspace?.repoPaths.isEmpty == true)
        {
            let folderName = folderURL.lastPathComponent
            let finalName = uniqueWorkspaceName(baseName: folderName)
            let normalizedPath = (folderURL.path as NSString).standardizingPath
            let newWS = createWorkspace(name: finalName, repoPaths: [normalizedPath])
            await switchWorkspace(to: newWS, saveState: false)
            return
        }

        guard let activeWS = activeWorkspace else { return }
        try await addFolder(folderURL, to: activeWS)
    }

    @MainActor
    func workspacesForMenu(_ query: WorkspaceMenuQuery = .init()) -> [WorkspaceModel] {
        var items = workspaces
        if !query.includeSystem {
            items = items.filter { !$0.isSystemWorkspace }
        }
        if !query.includeHidden {
            items = items.filter { !$0.isHiddenInMenus }
        }
        if query.sortMostRecentFirst {
            items = items.sorted { $0.dateModified > $1.dateModified }
        }
        return items
    }

    @MainActor
    func pickFolderAndOpenWorkspace(
        title: String,
        message: String,
        behavior: WorkspaceOpenBehavior = .addToActiveOrCreateNew
    ) async throws {
        guard let url = await OpenPanelService.shared.pickFolder(title: title, message: message) else { return }
        try await openWorkspace(fromFolderURL: url, behavior: behavior)
    }

    @MainActor
    func openWorkspace(
        fromFolderURL url: URL,
        behavior: WorkspaceOpenBehavior
    ) async throws {
        let normalizedPath = (url.path as NSString).standardizingPath
        let isFallback = (activeWorkspace == nil || activeWorkspace?.isSystemWorkspace == true)

        switch behavior {
        case .addToActiveOrCreateNew:
            if isFallback {
                let newName = uniqueWorkspaceName(baseName: url.lastPathComponent)
                let newWS = createWorkspace(name: newName, repoPaths: [normalizedPath])
                await switchWorkspace(to: newWS, saveState: false)
            } else {
                try await addFolder(url)
            }
        case .createNewWorkspace:
            let newName = uniqueWorkspaceName(baseName: url.lastPathComponent)
            let newWS = createWorkspace(name: newName, repoPaths: [normalizedPath])
            await switchWorkspace(to: newWS, saveState: false)
        case .addToActiveOnly:
            guard !isFallback else { throw WorkspaceOpenError.noActiveWorkspace }
            try await addFolder(url)
        }
    }

    func uniqueWorkspaceName(baseName: String) -> String {
        if !workspaces.contains(where: { $0.name == baseName }) {
            return baseName
        }
        var counter = 1
        var attempt = "\(baseName) (\(counter))"
        while workspaces.contains(where: { $0.name == attempt }) {
            counter += 1
            attempt = "\(baseName) (\(counter))"
        }
        return attempt
    }

    @MainActor
    func getOrCreateSystemWorkspace() -> WorkspaceModel {
        if let existing = workspaces.first(where: { $0.isSystemWorkspace }) {
            return existing
        }
        if let fallback = findOrCreateDefaultWorkspace() {
            return fallback
        }
        var ws = WorkspaceModel(name: "Default", repoPaths: [])
        ws.isSystemWorkspace = true
        workspaces.append(ws)
        return ws
    }

    private func findOrCreateDefaultWorkspace() -> WorkspaceModel? {
        if let existing = workspaces.first(where: { $0.name == "Default" }) {
            return existing
        }
        var ws = WorkspaceModel(name: "Default", repoPaths: [])
        ws.isSystemWorkspace = true
        workspaces.append(ws)

        do {
            _ = try ensureWorkspaceDirectoryExists(for: ws)
            _ = try saveWorkspaceToFile(ws, source: .createDefaultWorkspace)
        } catch {
            print("Error while creating default workspace: \(error)")
        }
        rebuildAndSaveIndex()
        return ws
    }

    // MARK: - Preset Operations

    func createPreset(for workspace: WorkspaceModel, name: String) async {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }

        let selectedPaths = fileManager.selectedFiles.map(\.fullPath)
        let newPreset = WorkspacePreset(
            name: name,
            capturesFileSelection: true,
            capturesFileTreeExpansion: false,
            capturesSelectedPrompts: false,
            selectedFilePaths: selectedPaths,
            expandedFolders: [],
            selectedPromptIDs: [],
            lastUpdated: Date()
        )

        workspaces[index].presets.append(newPreset)
        workspaces[index].activePresetID = newPreset.id
        workspaces[index].dateModified = Date()

        // Save asynchronously and notify after disk commit
        do {
            let finalURL = try await saveWorkspaceToFileAsync(workspaces[index], source: .createPreset)
            await WorkspaceDiskWriter.shared.flush(url: finalURL)

            // The selection now matches the preset; not dirty.
            activePresetIsDirty = false

            NotificationCenter.default.post(
                name: .workspacePresetsDidChange,
                object: nil,
                userInfo: ["managerID": instanceID]
            )
        } catch {
            print("Error saving workspace after creating preset: \(error)")
        }
    }

    func createPreset(for workspace: WorkspaceModel, name: String, selectedPaths: [String]) async {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }

        let newPreset = WorkspacePreset(
            name: name,
            capturesFileSelection: true,
            capturesFileTreeExpansion: false,
            capturesSelectedPrompts: false,
            selectedFilePaths: selectedPaths,
            expandedFolders: [],
            selectedPromptIDs: [],
            lastUpdated: Date()
        )

        workspaces[index].presets.append(newPreset)
        workspaces[index].activePresetID = newPreset.id
        workspaces[index].dateModified = Date()

        // Save this workspace (not only the active one), flush, then notify
        do {
            let finalURL = try await saveWorkspaceToFileAsync(workspaces[index], source: .createPresetWithPaths)
            await WorkspaceDiskWriter.shared.flush(url: finalURL)

            // The selection now matches the preset; not dirty.
            activePresetIsDirty = false

            NotificationCenter.default.post(
                name: .workspacePresetsDidChange,
                object: nil,
                userInfo: ["managerID": instanceID]
            )
        } catch {
            print("Error saving workspace after creating preset: \(error)")
        }
    }

    /// Creates a new preset with auto-numbered name (Preset #1, #2, etc.)
    func createNumericPreset(for workspace: WorkspaceModel) async {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }

        // Find the next available number
        var highestNumber = 0
        for preset in workspaces[index].presets {
            if preset.name.hasPrefix("Preset #") {
                let numStr = preset.name.dropFirst(8).description
                if let num = Int(numStr) {
                    highestNumber = max(highestNumber, num)
                }
            }
        }

        let nextNumber = highestNumber + 1
        let presetName = "Preset #\(nextNumber)"

        await createPreset(for: workspace, name: presetName)
        // Notification is already sent by createPreset after disk write
    }

    func applyPreset(_ presetID: UUID) async {
        guard let active = activeWorkspace,
              let wsIndex = workspaces.firstIndex(where: { $0.id == active.id }),
              let preset = workspaces[wsIndex].presets.first(where: { $0.id == presetID })
        else {
            print("No such preset or no active workspace")
            return
        }

        workspaces[wsIndex].activePresetID = presetID

        if preset.capturesFileSelection {
            await fileManager.selectFiles(withPaths: preset.selectedFilePaths, allowEmpty: true)
        }

        // Save the workspace state
        await saveWorkspaceAsync(source: .applyPreset)

        // Reset the dirty flag since we just applied exactly this preset
        activePresetIsDirty = false
    }

    func saveCurrentPreset() async {
        guard let active = activeWorkspace,
              let wsIndex = workspaces.firstIndex(where: { $0.id == active.id }),
              let pid = workspaces[wsIndex].activePresetID,
              let presetIdx = workspaces[wsIndex].presets.firstIndex(where: { $0.id == pid })
        else {
            return
        }

        // Always save full, absolute paths
        let selectedPaths = fileManager.selectedFiles.map(\.fullPath)
        workspaces[wsIndex].presets[presetIdx].selectedFilePaths = selectedPaths
        workspaces[wsIndex].presets[presetIdx].lastUpdated = Date()

        // Save, flush, and notify other windows so they reload presets immediately
        do {
            let finalURL = try await saveWorkspaceToFileAsync(workspaces[wsIndex], source: .saveCurrentPreset)
            await WorkspaceDiskWriter.shared.flush(url: finalURL)

            // The selection now matches the preset; not dirty
            activePresetIsDirty = false
            NotificationCenter.default.post(
                name: .workspacePresetsDidChange,
                object: nil,
                userInfo: ["managerID": instanceID]
            )
        } catch {
            print("Error saving preset: \(error)")
        }
    }

    func updatePromptText(_ newText: String) {
        guard let active = activeWorkspace,
              let index = workspaces.firstIndex(where: { $0.id == active.id })
        else {
            return
        }
        workspaces[index].currentPromptText = newText
        scheduleSave(source: .updatePromptText)
        bumpStateVersion(for: active.id)
    }

    func updateSelectedMetaPromptIDs(_ newIDs: [UUID]) {
        guard let active = activeWorkspace,
              let index = workspaces.firstIndex(where: { $0.id == active.id })
        else {
            return
        }
        workspaces[index].selectedMetaPromptIDs = newIDs
        scheduleSave(source: .updateSelectedMetaPromptIDs)
        bumpStateVersion(for: active.id)
    }

    /// Sets a workspace's ephemeral property by ID
    func setWorkspaceEphemeral(_ workspaceID: UUID, _ value: Bool) {
        if let idx = workspaces.firstIndex(where: { $0.id == workspaceID }) {
            workspaces[idx].isEphemeral = value
        }
    }

    // MARK: - Workspace and Preset Convenience Methods

    /// Creates a new workspace from a name and repo paths, then immediately switches to it.
    /// Optionally performs a closure (e.g., close a sheet) before switching.
    @MainActor
    func createAndActivateWorkspace(
        name: String,
        repoPaths: [String],
        beforeSwitch: (() -> Void)? = nil
    ) async {
        // (Optional) do something UI-related before switching, e.g. close a sheet
        beforeSwitch?()

        let newWS = createWorkspace(name: name, repoPaths: repoPaths)
        _ = await requestWorkspaceSwitch(to: newWS, saveState: false)
    }

    /// Switches to a preset by index (1-based).
    /// This was moved from ContentView so the UI only calls this in one place.
    @MainActor
    func switchToPreset(_ index: Int, isWindowFocused: Bool) async {
        guard isWindowFocused else { return }
        guard let ws = activeWorkspace,
              index > 0,
              index <= ws.presets.count
        else { return }

        let preset = ws.presets[index - 1]
        await applyPreset(preset.id)
    }

    /// Saves the current selection to a preset by index (1-based).
    /// Previously in ContentView; now resides in the manager.
    @MainActor
    func saveToPreset(_ index: Int, isWindowFocused: Bool) {
        guard isWindowFocused else { return }
        guard let ws = activeWorkspace else { return }

        let presets = ws.presets
        if index <= presets.count, index > 0 {
            // Overwrite existing preset
            let oldPreset = presets[index - 1]
            // Store absolute full paths to avoid cross-root ambiguity
            let selection = fileManager.selectedFiles.map(\.fullPath)

            guard let i = ws.presets.firstIndex(where: { $0.id == oldPreset.id }),
                  let wsIndex = workspaces.firstIndex(where: { $0.id == ws.id }) else { return }

            workspaces[wsIndex].presets[i].selectedFilePaths = selection
            workspaces[wsIndex].presets[i].lastUpdated = Date()

            // Save, flush, and notify other windows so they reload presets
            Task {
                do {
                    let finalURL = try await saveWorkspaceToFileAsync(workspaces[wsIndex], source: .savePresetShortcut)
                    await WorkspaceDiskWriter.shared.flush(url: finalURL)
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: .workspacePresetsDidChange,
                            object: nil,
                            userInfo: ["managerID": instanceID]
                        )
                    }
                } catch {
                    print("Error saving workspace after updating preset: \(error)")
                }
            }
        } else {
            // Create a new preset if there's no preset at this index
            Task {
                await createNumericPreset(for: ws)
            }
        }
    }

    /// Creates an ephemeral workspace (non-persisted)
    func createEphemeralWorkspace(name: String, repoPaths: [String]) -> WorkspaceModel {
        var ws = createWorkspace(name: name, repoPaths: repoPaths)
        if let idx = workspaces.firstIndex(where: { $0.id == ws.id }) {
            workspaces[idx].isEphemeral = true
            ws = workspaces[idx] // re-fetch the mutated copy
        }
        return ws
    }

    @MainActor
    @discardableResult
    func saveAndExitToFallback() async -> WorkspaceSwitchResult {
        let signpost = WorkspaceExitPerf.begin("saveAndExitToFallback")
        defer { WorkspaceExitPerf.end("saveAndExitToFallback", signpost) }
        guard let fallback = workspaces.first(where: { $0.isSystemWorkspace }) else {
            return .blocked("No fallback workspace is available.")
        }
        return await requestWorkspaceSwitch(to: fallback, reason: "saveAndExitToFallback")
    }

    func checkIfActivePresetIsDirty(with newSelection: [FileViewModel]) {
        guard let ws = activeWorkspace,
              let pid = ws.activePresetID,
              let preset = ws.presets.first(where: { $0.id == pid })
        else {
            activePresetIsDirty = false
            return
        }

        let selectionPaths = newSelection.map {
            (absolute: $0.standardizedFullPath, relative: $0.standardizedRelativePath)
        }
        activePresetIsDirty = Self.isPresetSelectionDirty(
            presetPaths: preset.selectedFilePaths,
            selectionPaths: selectionPaths
        )
    }

    func restoreChatSessionState(_ session: ChatSession, restoreSelection: Bool = true) async {
        // File selection is gated by restoreSelection flag
        if restoreSelection {
            await fileManager.selectFiles(
                withPaths: session.selectedFilePaths,
                allowEmpty: true, // tolerate empty selections
                clear: true // start from a clean slate
            )
        }

        // Restore per-session chat preset (overrides workspace-level selection)
        if let selectedChatPreset = session.selectedChatPresetID {
            promptViewModel.selectChatPreset(selectedChatPreset)
        }

        promptViewModel.restorePreferredModelForSession(session.preferredAIModel)

        // Always restore per-session prompt selection (independent of file restore)
        // This ensures the Prompts button and UI reflect the correct session state
        promptViewModel.restoreChatPromptSelectionFromSession(session.selectedPromptIDs)
    }

    func deletePreset(_ preset: WorkspacePreset, from workspace: WorkspaceModel) {
        guard let widx = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces[widx].presets.removeAll { $0.id == preset.id }

        // Schedule async save of the mutated workspace and notify after flush
        Task {
            do {
                let finalURL = try await saveWorkspaceToFileAsync(workspaces[widx], source: .deletePreset)
                await WorkspaceDiskWriter.shared.flush(url: finalURL)
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .workspacePresetsDidChange,
                        object: nil,
                        userInfo: ["managerID": instanceID]
                    )
                }
            } catch {
                print("Error saving workspace after deleting preset: \(error)")
            }
        }
    }

    func renamePreset(_ preset: WorkspacePreset, newName: String, in workspace: WorkspaceModel) {
        guard let widx = workspaces.firstIndex(where: { $0.id == workspace.id }),
              let pidx = workspaces[widx].presets.firstIndex(where: { $0.id == preset.id })
        else {
            return
        }
        workspaces[widx].presets[pidx].name = newName
        workspaces[widx].presets[pidx].lastUpdated = Date()

        // Schedule async save of the mutated workspace and notify after flush
        Task {
            do {
                let finalURL = try await saveWorkspaceToFileAsync(workspaces[widx], source: .renamePreset)
                await WorkspaceDiskWriter.shared.flush(url: finalURL)
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .workspacePresetsDidChange,
                        object: nil,
                        userInfo: ["managerID": instanceID]
                    )
                }
            } catch {
                print("Error saving workspace after renaming preset: \(error)")
            }
        }
    }

    /// Reorders presets in a workspace
    func reorderPresets(for workspace: WorkspaceModel, newPresets: [WorkspacePreset]) {
        // Find the workspace in our array
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else {
            return
        }

        // Update presets and modify timestamp in place
        workspaces[index].presets = newPresets
        workspaces[index].dateModified = Date()

        // Persist this workspace and notify other windows to reload presets
        Task {
            do {
                let finalURL = try await saveWorkspaceToFileAsync(workspaces[index], source: .reorderPresets)
                await WorkspaceDiskWriter.shared.flush(url: finalURL)
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .workspacePresetsDidChange,
                        object: nil,
                        userInfo: ["managerID": instanceID]
                    )
                }
            } catch {
                print("Error saving workspace after preset reorder: \(error)")
            }
        }
    }

    // MARK: - Public API to handle user data migration

    /// =========================================================================
    /// Called by AppDelegate *after* security checks, etc.
    /// Loads prompts into memory, then runs export + optional restore if user toggled it.
    @MainActor
    func handleUserDataExportAndRestore() async {
        /*
         // 1) Ensure we have the latest stored prompts in memory.
         promptViewModel.loadStoredPrompts()

         // 2) Perform the export
         do {
         try await exportUserDataToDownloadsFolderIfNeeded()
         print("Data exported to ~/Downloads/RepoPrompt-Backup successfully.")
         } catch {
         print("Warning: Failed to export user data to Downloads folder: \(error)")
         }
         */

        // 3) Check if user toggled "shouldAutoRestoreFromDownloads"; if so, restore
        if shouldAutoRestoreFromDownloads {
            do {
                try await restoreUserDataFromDownloadsFolder()
                print("Auto-restore from ~/Downloads/RepoPrompt-Backup completed.")

                // Reload prompts if they were overwritten
                promptViewModel.loadStoredPrompts()

                // Set to false after successful restore to skip in the future
                shouldAutoRestoreFromDownloads = false
            } catch {
                print("Warning: Auto-restore from ~/Downloads/RepoPrompt-Backup failed: \(error)")
            }
        }
    }

    // MARK: - Exports

    @MainActor
    func exportUserDataToDownloadsFolderIfNeeded() async throws {
        // 1) Check if we have any workspaces
        guard !workspaces.isEmpty else {
            print("No workspaces found; skipping export.")
            return
        }
        // 2) Check if we have stored prompts
        guard let promptData = UserDefaults.standard.data(forKey: "StoredPrompts"),
              !promptData.isEmpty
        else {
            print("No stored prompts found; skipping export.")
            return
        }

        let localWorkspaceIndexFileURL = workspaceIndexFileURL
        let localWorkspaces = Array(workspaces)

        let localWorkspaceDirs: [(wsId: UUID, workspaceDir: URL)] = localWorkspaces.map { ws in
            (ws.id, self.workspaceDirectory(for: ws))
        }

        try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
                throw NSError(domain: "WorkspaceManager", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Could not find the user's Downloads folder."
                ])
            }
            let exportFolder = downloads.appendingPathComponent("RepoPrompt-Backup", isDirectory: true)

            if !fm.fileExists(atPath: exportFolder.path) {
                try fm.createDirectory(
                    at: exportFolder,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            }

            // 1) Export stored prompts
            let promptsDest = exportFolder.appendingPathComponent("StoredPrompts.json")
            try promptData.write(to: promptsDest)

            // 2) Export workspace index
            let workspaceIndexDest = exportFolder.appendingPathComponent("workspacesIndex.json")
            if fm.fileExists(atPath: localWorkspaceIndexFileURL.path) {
                if fm.fileExists(atPath: workspaceIndexDest.path) {
                    try fm.removeItem(at: workspaceIndexDest)
                }
                try fm.copyItem(at: localWorkspaceIndexFileURL, to: workspaceIndexDest)
            }

            // 3) Export each workspace folder
            for info in localWorkspaceDirs {
                let backupDir = exportFolder.appendingPathComponent("Workspace-\(info.wsId)")
                if fm.fileExists(atPath: info.workspaceDir.path) {
                    if fm.fileExists(atPath: backupDir.path) {
                        try fm.removeItem(at: backupDir)
                    }
                    try fm.copyItem(at: info.workspaceDir, to: backupDir)
                }
            }

        }.value
    }

    // MARK: - RESTORE LOGIC

    // =========================================================================
    // CHANGED: Always restore from backup; remove skip logic. Then reload workspaces,
    // and re-activate whichever was active (if still present). Finally, remove the backup folder.
    @MainActor
    func restoreUserDataFromDownloadsFolder() async throws {
        let fm = FileManager.default
        guard let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw NSError(
                domain: "WorkspaceManager",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not find the user's Downloads folder."]
            )
        }
        let exportFolder = downloads.appendingPathComponent("RepoPrompt-Backup", isDirectory: true)
        guard fm.fileExists(atPath: exportFolder.path) else {
            print("No RepoPrompt-Backup folder found in ~/Downloads. Nothing to restore.")
            return
        }

        try ensureBaseRootExists(at: currentBaseRoot)

        // 1) Always restore StoredPrompts if found
        let promptsFile = exportFolder.appendingPathComponent("StoredPrompts.json")
        if fm.fileExists(atPath: promptsFile.path) {
            let data = try Data(contentsOf: promptsFile)
            UserDefaults.standard.set(data, forKey: "StoredPrompts")
            print("Restored stored prompts from backup.")
        }

        // 2) Attempt to restore workspace index if it exists
        let indexSource = exportFolder.appendingPathComponent("workspacesIndex.json")
        if fm.fileExists(atPath: indexSource.path) {
            if fm.fileExists(atPath: workspaceIndexFileURL.path) {
                try fm.removeItem(at: workspaceIndexFileURL)
            }
            try fm.copyItem(at: indexSource, to: workspaceIndexFileURL)
            print("Restored workspace index from backup.")

            // Validate that the restored index file can be parsed
            do {
                let data = try Data(contentsOf: workspaceIndexFileURL)
                _ = try JSONDecoder().decode([WorkspaceIndexEntry].self, from: data)
            } catch {
                print("Warning: Could not parse newly restored index file. \(error)")
            }
        } else {
            print("No workspacesIndex.json found in backup; skipping workspace index restore.")
        }

        // 3) Keep track of old active so we can attempt to restore that
        let oldActiveID = activeWorkspaceID

        // 4) In parallel, copy each "Workspace-<Name>-<UUID>" subfolder from the backup folder into local storage
        //    Also parse them into memory.
        let workspaceDirectories = try fm.contentsOfDirectory(at: exportFolder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Workspace-") && $0.hasDirectoryPath }

        // We'll hold onto newly loaded workspaces in memory
        var newlyLoadedWorkspaces: [WorkspaceModel] = []

        for backupWsDir in workspaceDirectories {
            // Inside this folder, we expect a "workspace.json"
            let potentialWorkspaceFile = backupWsDir.appendingPathComponent("workspace.json")
            guard fm.fileExists(atPath: potentialWorkspaceFile.path) else {
                print("No workspace.json in \(backupWsDir.path). Skipping.")
                continue
            }

            // We read workspace.json to figure out the workspace's ID, name, etc.
            let data = try Data(contentsOf: potentialWorkspaceFile)
            let workspace = try JSONDecoder().decode(WorkspaceModel.self, from: data)

            // Build the local folder path, e.g. ~/Library/Application Support/RepoPrompt CE/Workspaces/Workspace-Name-UUID
            let localWsDir: URL = if let customURL = workspace.customStoragePath {
                customURL
            } else {
                defaultWorkspaceRoot()
                    .appendingPathComponent("Workspace-\(workspace.name)-\(workspace.id)")
            }

            // If it already exists, remove it to avoid partial merges
            if fm.fileExists(atPath: localWsDir.path) {
                try fm.removeItem(at: localWsDir)
            }

            // Copy the entire folder from backup into local
            try fm.copyItem(at: backupWsDir, to: localWsDir)

            // Now load the final workspace from disk again
            // (We do this so we confirm it's in the correct location + we store it with local paths).
            let finalWorkspaceFile = localWsDir.appendingPathComponent("workspace.json")
            let finalData = try Data(contentsOf: finalWorkspaceFile)
            let finalWorkspace = try JSONDecoder().decode(WorkspaceModel.self, from: finalData)

            newlyLoadedWorkspaces.append(finalWorkspace)
        }

        // 5) Replace your in-memory array with newly loaded (or appended) ones
        //    or you can union them if you want to keep older existing ones.
        workspaces = newlyLoadedWorkspaces

        // Rebuild and save the index to reflect the newly loaded sets
        await rebuildAndSaveIndexAsync()
        print("Finished restoring and reloading workspace list from backup.")

        // Notify that workspace list has changed
        NotificationCenter.default.post(
            name: .workspaceListDidChange,
            object: nil,
            userInfo: ["managerID": instanceID]
        )

        // 6) Restore a usable active workspace. Replacing the active model with the same
        // ID must still unload and hydrate its restored root/model state.
        let workspaceToActivate: WorkspaceModel
        let shouldReloadSameID: Bool
        if let oldID = oldActiveID,
           let restoredActive = workspaces.first(where: { $0.id == oldID })
        {
            workspaceToActivate = restoredActive
            shouldReloadSameID = activeWorkspaceID == restoredActive.id
        } else if let firstWorkspace = workspaces.first {
            workspaceToActivate = firstWorkspace
            shouldReloadSameID = activeWorkspaceID == firstWorkspace.id
        } else {
            let fallback = getOrCreateSystemWorkspace()
            workspaceToActivate = fallback
            shouldReloadSameID = activeWorkspaceID == fallback.id
        }

        let activationResult = if shouldReloadSameID {
            await reactivateWorkspaceAfterReplacement(
                workspaceToActivate,
                reason: "backupRestoreSameIDReload"
            )
        } else {
            await switchWorkspace(
                to: workspaceToActivate,
                saveState: false,
                reason: "backupRestoreActivation"
            )
        }
        guard activationResult.didSwitch,
              activeWorkspaceID == workspaceToActivate.id
        else {
            throw NSError(
                domain: "WorkspaceManager.BackupRestore",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey: activationResult.message
                        ?? "The restored workspace could not be activated."
                ]
            )
        }

        // 7) If you have chat sessions you want to restore, do it now per workspace
        // e.g.: for ws in self.workspaces {
        //          chatManager.loadChats(for: ws)
        //      }

        // 8) Finally, remove the entire backup folder if you want
        do {
            try fm.removeItem(at: exportFolder)
            print("Removed RepoPrompt-Backup folder after successful restore.")

            // Mark restoration as complete by setting flag to false
            // This prevents auto-restoring in future launches
            shouldAutoRestoreFromDownloads = false
        } catch {
            print("Warning: Could not remove RepoPrompt-Backup folder: \(error)")
        }
    }
}
