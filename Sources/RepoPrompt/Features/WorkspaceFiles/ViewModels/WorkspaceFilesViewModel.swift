import AppKit
import Combine
import Foundation
import SwiftUI
#if DEBUG || EDIT_FLOW_PERF
    import os
#endif

#if DEBUG
    private var workspaceFilesDebugLoggingEnabled = false
    private func workspaceFilesDebugLog(_ message: @autoclosure () -> String) {
        guard workspaceFilesDebugLoggingEnabled else { return }
        print("[WorkspaceFilesVM] \(message())")
    }
#else
    private func workspaceFilesDebugLog(_ message: @autoclosure () -> String) {}
#endif

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

private struct RemovedFolderPathMatcher {
    let removedFolderPaths: Set<String>

    func containsPathEqualToOrInsideRemovedFolder(_ standardizedPath: String) -> Bool {
        guard !removedFolderPaths.isEmpty else { return false }
        if removedFolderPaths.contains(standardizedPath) {
            return true
        }

        var current = standardizedPath
        while true {
            let parent = (current as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != current else {
                return false
            }
            if removedFolderPaths.contains(parent) {
                return true
            }
            current = parent
        }
    }
}

/// Holds direct references
struct FileHierarchyIndex {
    struct OwnedDescendantPathsResult {
        let folderPaths: Set<String>
        let filePaths: Set<String>
        let usedFallbackGlobalScan: Bool
        let scanInvocationCount: Int
    }

    // Store file & folder ViewModels by canonical path and store-backed identity.
    var filesByFullPath: [String: FileViewModel] = [:]
    var foldersByFullPath: [String: FolderViewModel] = [:]
    var filesByID: [UUID: FileViewModel] = [:]
    var foldersByID: [UUID: FolderViewModel] = [:]
    var filePathsByRoot: [String: Set<String>] = [:]
    var folderPathsByRoot: [String: Set<String>] = [:]

    mutating func clearAll() {
        filesByFullPath.removeAll()
        foldersByFullPath.removeAll()
        filesByID.removeAll()
        foldersByID.removeAll()
        filePathsByRoot.removeAll()
        folderPathsByRoot.removeAll()
    }

    private static func removePath(
        _ path: String,
        from ownership: inout [String: Set<String>],
        rootKey: String,
        preserveEmptyEntry: Bool = false
    ) {
        guard ownership[rootKey] != nil else { return }
        ownership[rootKey, default: []].remove(path)
        guard ownership[rootKey]?.isEmpty == true else { return }
        if preserveEmptyEntry {
            ownership[rootKey] = []
        } else {
            ownership.removeValue(forKey: rootKey)
        }
    }

    mutating func insertFolder(_ folder: FolderViewModel, rootKey: String? = nil) {
        let path = folder.standardizedFullPath
        let ownerRootKey = rootKey.map(StandardizedPath.absolute) ?? StandardizedPath.absolute(folder.rootPath)
        if let existing = foldersByFullPath.updateValue(folder, forKey: path) {
            if foldersByID[existing.id] === existing {
                foldersByID.removeValue(forKey: existing.id)
            }
            let previousRootKey = StandardizedPath.absolute(existing.rootPath)
            if previousRootKey != ownerRootKey {
                Self.removePath(path, from: &folderPathsByRoot, rootKey: previousRootKey)
            }
        }
        foldersByID[folder.id] = folder
        folderPathsByRoot[ownerRootKey, default: []].insert(path)
        if path == ownerRootKey {
            _ = filePathsByRoot[ownerRootKey, default: []]
        }
    }

    mutating func rekeyFolder(_ folder: FolderViewModel, from oldID: UUID) {
        if foldersByID[oldID] === folder {
            foldersByID.removeValue(forKey: oldID)
        }
        foldersByID[folder.id] = folder
    }

    @discardableResult
    mutating func removeFolder(forKey path: String, expectedRootKey: String? = nil) -> FolderViewModel? {
        let standardizedPath = StandardizedPath.absolute(path)
        let removed = foldersByFullPath.removeValue(forKey: standardizedPath)
        if let removed, foldersByID[removed.id] === removed {
            foldersByID.removeValue(forKey: removed.id)
        }
        let ownerRootKey = removed.map { StandardizedPath.absolute($0.rootPath) }
            ?? expectedRootKey.map(StandardizedPath.absolute)
        if let ownerRootKey {
            Self.removePath(standardizedPath, from: &folderPathsByRoot, rootKey: ownerRootKey)
        }
        return removed
    }

    mutating func insertFile(_ file: FileViewModel, rootKey: String? = nil) {
        let path = file.standardizedFullPath
        let ownerRootKey = rootKey.map(StandardizedPath.absolute) ?? file.standardizedRootFolderPath
        if let existing = filesByFullPath.updateValue(file, forKey: path) {
            if filesByID[existing.id] === existing {
                filesByID.removeValue(forKey: existing.id)
            }
            let previousRootKey = existing.standardizedRootFolderPath
            if previousRootKey != ownerRootKey {
                Self.removePath(path, from: &filePathsByRoot, rootKey: previousRootKey)
            }
        }
        filesByID[file.id] = file
        filePathsByRoot[ownerRootKey, default: []].insert(path)
    }

    @discardableResult
    mutating func removeFile(forKey path: String, expectedRootKey: String? = nil) -> FileViewModel? {
        let standardizedPath = StandardizedPath.absolute(path)
        let removed = filesByFullPath.removeValue(forKey: standardizedPath)
        if let removed, filesByID[removed.id] === removed {
            filesByID.removeValue(forKey: removed.id)
        }
        let ownerRootKey = removed?.standardizedRootFolderPath
            ?? expectedRootKey.map(StandardizedPath.absolute)
        if let ownerRootKey {
            let preserveEmptyEntry = folderPathsByRoot[ownerRootKey] != nil
            Self.removePath(
                standardizedPath,
                from: &filePathsByRoot,
                rootKey: ownerRootKey,
                preserveEmptyEntry: preserveEmptyEntry
            )
        }
        return removed
    }

    mutating func removeOwnedEntries(
        forRootKey rootKey: String,
        folderPaths: Set<String>,
        filePaths: Set<String>
    ) {
        folderPathsByRoot.removeValue(forKey: rootKey)
        filePathsByRoot.removeValue(forKey: rootKey)
        for folderPath in folderPaths {
            if let removed = foldersByFullPath.removeValue(forKey: folderPath),
               foldersByID[removed.id] === removed
            {
                foldersByID.removeValue(forKey: removed.id)
            }
        }
        for filePath in filePaths {
            if let removed = filesByFullPath.removeValue(forKey: filePath),
               filesByID[removed.id] === removed
            {
                filesByID.removeValue(forKey: removed.id)
            }
        }
    }

    func ownedDescendantPaths(
        forRootKey rootKey: String,
        underFolderPaths folderPaths: Set<String>
    ) -> OwnedDescendantPathsResult {
        let standardizedRootKey = StandardizedPath.absolute(rootKey)
        let standardizedFolderPaths = Set(folderPaths.map { StandardizedPath.absolute($0) })
        guard !standardizedFolderPaths.isEmpty else {
            return OwnedDescendantPathsResult(
                folderPaths: [],
                filePaths: [],
                usedFallbackGlobalScan: false,
                scanInvocationCount: 0
            )
        }

        let matcher = RemovedFolderPathMatcher(removedFolderPaths: standardizedFolderPaths)
        let folderCandidates: Set<String>
        let fileCandidates: Set<String>
        let usedFallbackGlobalScan: Bool

        if let ownedFolderPaths = folderPathsByRoot[standardizedRootKey] {
            folderCandidates = ownedFolderPaths
            if let ownedFilePaths = filePathsByRoot[standardizedRootKey] {
                fileCandidates = ownedFilePaths
                usedFallbackGlobalScan = false
            } else {
                fileCandidates = Set(filesByFullPath.keys)
                usedFallbackGlobalScan = true
            }
        } else {
            folderCandidates = Set(foldersByFullPath.keys)
            fileCandidates = Set(filesByFullPath.keys)
            usedFallbackGlobalScan = true
        }

        let descendantFolderPaths = Set(folderCandidates.lazy.filter {
            matcher.containsPathEqualToOrInsideRemovedFolder($0)
        })
        let descendantFilePaths = Set(fileCandidates.lazy.filter {
            matcher.containsPathEqualToOrInsideRemovedFolder($0)
        })

        return OwnedDescendantPathsResult(
            folderPaths: descendantFolderPaths,
            filePaths: descendantFilePaths,
            usedFallbackGlobalScan: usedFallbackGlobalScan,
            scanInvocationCount: 1
        )
    }

    func ownedDescendantPaths(
        forRootKey rootKey: String,
        underFolderPath folderPath: String
    ) -> (folderPaths: Set<String>, filePaths: Set<String>, usedFallbackGlobalScan: Bool) {
        let result = ownedDescendantPaths(
            forRootKey: rootKey,
            underFolderPaths: [folderPath]
        )
        return (
            folderPaths: result.folderPaths,
            filePaths: result.filePaths,
            usedFallbackGlobalScan: result.usedFallbackGlobalScan
        )
    }

    mutating func removeSubtreeEntries(
        forRootKey rootKey: String,
        folderPaths: Set<String>,
        filePaths: Set<String>
    ) {
        let standardizedRootKey = StandardizedPath.absolute(rootKey)
        if var ownedFolderPaths = folderPathsByRoot[standardizedRootKey] {
            ownedFolderPaths.subtract(folderPaths)
            folderPathsByRoot[standardizedRootKey] = ownedFolderPaths
        }
        let preserveEmptyFileEntry = folderPathsByRoot[standardizedRootKey] != nil
        if var ownedFilePaths = filePathsByRoot[standardizedRootKey] {
            ownedFilePaths.subtract(filePaths)
            if ownedFilePaths.isEmpty, !preserveEmptyFileEntry {
                filePathsByRoot.removeValue(forKey: standardizedRootKey)
            } else {
                filePathsByRoot[standardizedRootKey] = ownedFilePaths
            }
        } else if preserveEmptyFileEntry {
            filePathsByRoot[standardizedRootKey] = []
        }
        for folderPath in folderPaths {
            if let removed = foldersByFullPath.removeValue(forKey: folderPath),
               foldersByID[removed.id] === removed
            {
                foldersByID.removeValue(forKey: removed.id)
            }
        }
        for filePath in filePaths {
            if let removed = filesByFullPath.removeValue(forKey: filePath),
               filesByID[removed.id] === removed
            {
                filesByID.removeValue(forKey: removed.id)
            }
        }
    }
}

private struct RootCleanupPlan {
    let rootKey: String
    let folderPaths: Set<String>
    let filePaths: Set<String>
    let usedFallbackGlobalScan: Bool
}

private struct WorkspaceRootShellPersistenceKey: Hashable {
    let workspaceID: UUID?
    let standardizedRootPath: String
    let kind: WorkspaceRootKind
}

private struct RootShellAttachment {
    let folder: FolderViewModel
    let didAppend: Bool
}

enum WorkspaceRootShellError: LocalizedError {
    case conflictingRootShell(path: String, existingID: UUID, incomingID: UUID)

    var errorDescription: String? {
        switch self {
        case let .conflictingRootShell(path, existingID, incomingID):
            "A root shell is already attached for \(path) with id \(existingID); cannot attach root id \(incomingID)."
        }
    }
}

private struct RemovedFolderSubtree {
    let removedFolder: FolderViewModel
    let formerParentFolder: FolderViewModel?
    let removedFolderFullPath: String
}

private struct IncrementalRemovedSubtreeCleanupOutcome {
    let succeeded: Bool
    let removedFolderCount: Int
    let removedFileCount: Int
    let usedFallbackGlobalScan: Bool
    let descendantLookupCount: Int
}

private struct FileAdditionApplyOutcome {
    let file: FileViewModel
    let parentFolderForStateRecompute: FolderViewModel?
}

private struct FolderTopologyApplyOutcome {
    let parentFolderForStateRecompute: FolderViewModel?
}

private struct ReplaySliceRebaseRequest {
    let file: FileViewModel
    let relativePath: String
}

private struct ReplayRootPassAccumulator {
    let rootKey: String
    var processedDigests: [WorkspaceFilesViewModel.FileSystemDeltaDigest] = []
    var topologyChanged = false
    var codeScanFilesByID: [UUID: FileViewModel] = [:]
    var sliceRebasesByFullPath: [String: ReplaySliceRebaseRequest] = [:]
}

@MainActor
class WorkspaceFilesViewModel: ObservableObject {
    let allFoldersUnloadedPublisher = PassthroughSubject<Void, Never>()

    /// New: O(1) lookup cache
    private var fileHierarchyIndex = FileHierarchyIndex()

    // Track window focus
    private var isWindowFocused: Bool = true
    private var deferredReplayRoutingVersion: UInt64 = 0

    // ─────────────────────────────────────────────────────────────
    // MARK: ‑ Deferred replay routing

    // ─────────────────────────────────────────────────────────────
    // MARK: - Root-keyed storage (stable string keys instead of URL to avoid key instability)

    private typealias RootKey = String

    private struct RootLoadToken: Equatable {
        let rootKey: RootKey
        let lifecycleGeneration: UInt64
        let rootGeneration: UInt64
    }

    /// Bumped whenever all in-flight root loads should become obsolete (workspace unload,
    /// explicit load cancellation). Per-root generations let one root be invalidated without
    /// making independent root loads stale.
    private var rootLoadLifecycleGeneration: UInt64 = 0
    private var rootLoadGenerationByRootKey: [RootKey: UInt64] = [:]
    private var rootReplayIngressGenerationByRoot: [RootKey: UInt64] = [:]
    #if DEBUG
        private var rootLoadDidAttachRootShellHandler: (@Sendable (_ standardizedRootPath: String, _ rootID: UUID) async -> Void)?
    #endif

    /// True while `flushPendingDeltas()` is actively replaying queued bursts.
    /// Incoming live FSEvents are re-queued when this is set, guaranteeing that
    /// only a single writer mutates the file-tree at any given time.
    private var isReplayingDeltas = false

    /// The currently running delta replay task, if any. Used to await completion
    /// instead of spin-waiting with Task.yield().
    private var deltaReplayTask: Task<Void, Never>?
    /// Run ID to safely clear deltaReplayTask only if it matches the current run.
    private var deltaReplayRunID: UUID?

    // ─────────────────────────────────────────────────────────────
    // MARK: - Child insertion coalescer (same-tick batching)

    /// ─────────────────────────────────────────────────────────────
    /// Coalesces repeated child insertions (typically bursts of `.fileAdded`)
    /// into a single `addChildrenBatch` per parent folder.
    @MainActor private var pendingChildInserts: [UUID: [FileSystemItemType]] = [:]
    /// Stores the actual parent instances to avoid re-walking the tree / index by UUID.
    @MainActor private var pendingInsertParents: [UUID: FolderViewModel] = [:]
    @MainActor private var isInsertFlushScheduled: Bool = false

    let fileTogglePublisher = PassthroughSubject<FileViewModel, Never>()
    let folderDidFinishLoadingPublisher = PassthroughSubject<FolderViewModel, Never>()
    var cancellables = Set<AnyCancellable>()
    let folderRefreshPublisher = PassthroughSubject<FolderViewModel, Never>()
    let selectionClearedPublisher = PassthroughSubject<Void, Never>()
    let codeMapUpdatePublisher = PassthroughSubject<Void, Never>() // New publisher
    let fileSystemChangedPublisher = PassthroughSubject<Void, Never>() // Publisher for file system changes

    /// Emitted once after a prepared root delta pass is finalized.
    /// Provides path context so consumers can filter for specific concerns (e.g. skill files).
    let fileSystemDeltasAppliedPublisher = PassthroughSubject<FileSystemDeltasAppliedEvent, Never>()

    /// Summary of a coalesced delta batch applied to a single root.
    struct FileSystemDeltasAppliedEvent {
        let rootKey: String // standardized root full path
        let deltas: [FileSystemDeltaDigest] // minimal path-only summaries
    }

    /// Lightweight, path-only digest of a `FileSystemDelta` for consumer filtering.
    enum FileSystemDeltaDigest {
        case fileAdded(String)
        case fileRemoved(String)
        case folderAdded(String)
        case folderRemoved(String)
        case fileModified(String)
        case folderModified(String)

        /// The relative path carried by this digest entry.
        var relativePath: String {
            switch self {
            case let .fileAdded(p), let .fileRemoved(p),
                 let .folderAdded(p), let .folderRemoved(p),
                 let .fileModified(p), let .folderModified(p):
                p
            }
        }
    }

    /// Monotonic signature for "any root changed".
    private var hierarchyGenerationSignature: UInt64 = 0

    /// Per-root hierarchy generations, keyed by standardized root path.
    /// Only topology changes for that root bump its generation.
    @MainActor
    private var rootHierarchyGenerations: [String: UInt64] = [:]

    /// Snapshot of per-root generation values keyed by standardized root full path.
    @MainActor
    var hierarchyGenerationByRoot: [String: UInt64] {
        rootHierarchyGenerations
    }

    /// Monotonic signature that bumps whenever workspace file hierarchy changes.
    @MainActor
    func currentHierarchyGenerationSignature() -> UInt64 {
        hierarchyGenerationSignature
    }

    private var newlyCreatedFilePaths = Set<String>()
    private weak var workspaceManager: WorkspaceManagerViewModel?
    private(set) var currentWorkspaceID: UUID?
    private var currentTabID: UUID?

    /// Tracks root shells currently attached in `rootFolders`; descendants remain store-owned.
    private var rootShellLoadedPaths = Set<String>()

    /// A simple computed property to check if *any* folder is being loaded
    var isAnyFolderLoading: Bool {
        isLoading
    }

    @Published private(set) var rootFolders: [FolderViewModel] = []

    enum RootKind {
        case user
        case supplementalSystem
    }

    private func workspaceRootKind(for rootKind: RootKind, url: URL) -> WorkspaceRootKind {
        switch rootKind {
        case .user:
            .primaryWorkspace
        case .supplementalSystem:
            url.lastPathComponent == "_git_data" ? .workspaceGitData : .supplementalSystem
        }
    }

    typealias LookupRootScope = WorkspaceLookupRootScope

    // Cache expanded folder paths to avoid recursive traversal
    private var expandedFolderPaths: Set<String> = []
    private var expansionSubscriptions: [UUID: AnyCancellable] = [:]
    private var isApplyingExpansionState = false

    // No longer using ExpansionManager - expansion state is stored directly in FolderViewModel

    @AppStorage("fileTreeSortMethod") private var storedSortMethod: String = SortMethod.nameAscending.rawValue

    /// Use a published property that syncs with the AppStorage value.
    @Published var currentSortMethod: SortMethod = .nameAscending {
        didSet {
            // Guard against redundant UserDefaults writes (and cross-window ping-pong)
            let raw = currentSortMethod.rawValue
            if storedSortMethod != raw {
                storedSortMethod = raw
            }
        }
    }

    @MainActor
    func addRootFolder(_ folder: FolderViewModel) {
        rootFolders.append(folder)
        registerExpansionTracking(for: folder)
        // Mark snapshot cache as dirty
        invalidateStaticSnapshot(forRootFullPath: folder.standardizedFullPath)
    }

    @MainActor
    func removeRootFolder(_ folder: FolderViewModel) {
        let stdPath = folder.standardizedFullPath
        let rootKey = rootKey(forPath: folder.fullPath)
        appliedIndexProjectionHandledGenerationByRootID.removeValue(forKey: folder.id)
        unregisterExpansionTracking(for: folder)
        rootFolders.removeAll { $0.id == folder.id }
        rootShellPersistenceKeysByRootKey.removeValue(forKey: rootKey)
        if workspaceFileContextRootsByRootKey[rootKey]?.id == folder.id {
            workspaceFileContextRootsByRootKey.removeValue(forKey: rootKey)
        }
        if preloadedWorkspaceFileContextRootsByRootKey[rootKey]?.id == folder.id {
            preloadedWorkspaceFileContextRootsByRootKey.removeValue(forKey: rootKey)
        }

        // Topology: root disappeared - remove per-root generation entry
        removeHierarchyGenerationEntry(forRootFullPath: stdPath)
        // Mark global path snapshot dirty (don't bump removed root)
        invalidateStaticSnapshot(forRootFullPath: nil)

        if rootFolders.isEmpty {
            allFoldersUnloadedPublisher.send(())
        }
    }

    @MainActor
    func refreshSortingIfNeeded(_ method: SortMethod) {
        for root in rootFolders {
            root.markDirtyRecursively() // Mark entire hierarchy as needing resort
            root.sortChildrenIfNeeded(method)
        }
    }

    /// Single entry point for changing the file tree sort method.
    /// Sets the method and reorders the tree without recomputing checkbox state.
    @MainActor
    func setFileTreeSortMethod(_ method: SortMethod) {
        guard currentSortMethod != method else { return }
        currentSortMethod = method
        for root in rootFolders {
            root.markDirtyRecursively()
            root.sortChildrenIfNeeded(method, recomputeCheckbox: false)
        }
    }

    private(set) var selectionStateRevision: UInt64 = 0

    @Published private(set) var selectedFiles: [FileViewModel] = [] {
        didSet {
            guard selectedFiles.map(\.id) != oldValue.map(\.id) else { return }
            selectionStateRevision &+= 1
        }
    }

    @Published private(set) var autoCodemapFiles: [FileViewModel] = [] {
        didSet {
            guard autoCodemapFiles.map(\.id) != oldValue.map(\.id) else { return }
            selectionStateRevision &+= 1
        }
    }

    private var autoCodemapFileIDs: Set<UUID> = []
    @Published var codemapAutoEnabled: Bool = true {
        didSet {
            guard codemapAutoEnabled != oldValue else { return }
            selectionStateRevision &+= 1
            if codemapAutoEnabled {
                scheduleAutoCodemapSync()
            } else {
                autoCodemapSyncTask?.cancel()
                autoCodemapSyncTask = nil
            }
        }
    }

    private var autoCodemapSyncTask: Task<Void, Never>?

    @Published private(set) var isLoading: Bool = false
    @Published private(set) var error: FileManagerError?

    var showEmptyFolders: Bool = false
    var skipSymlinks: Bool = true
    var respectGitignore: Bool = true
    var respectRepoIgnore: Bool = true
    var respectCursorignore: Bool = true
    var enableHierarchicalIgnores: Bool = true

    var onRootFoldersChanged: (() -> Void)?

    @Published private var selectedFileIDs: Set<UUID> = []
    private var isSelectionBatching = false
    private var pendingSelectionAdds = [FileViewModel]()
    private var pendingSelectionRemoves = [FileViewModel]()
    @Published private var folderBeingAdded: FolderViewModel?

    let workspaceFileContextStore: WorkspaceFileContextStore
    private weak var selectionCoordinator: WorkspaceSelectionCoordinator?
    private var selectionCoordinatorCancellable: AnyCancellable?
    private var workspaceFileContextRootsByRootKey: [RootKey: WorkspaceRootRecord] = [:]
    private var preloadedWorkspaceFileContextRootsByRootKey: [RootKey: WorkspaceRootRecord] = [:]
    private var rootShellPersistenceKeysByRootKey: [RootKey: WorkspaceRootShellPersistenceKey] = [:]
    private var partitionStoreSaveCancellable: AnyCancellable?
    private var fileSystemSettingsCancellable: AnyCancellable?
    private var forceReloadOnNextFileSystemSettingsRefresh = false

    private let selectionSliceCoordinator = SelectionSliceCoordinator()
    private var currentSlicesByRoot: [String: [String: PartitionStore.StoredSlices]] = [:]
    @Published private(set) var selectionSlicesByFileID: [UUID: [LineRange]] = [:] {
        didSet {
            guard selectionSlicesByFileID != oldValue else { return }
            selectionStateRevision &+= 1
        }
    }

    private var sliceSnapshotRebuildDeferralDepth = 0
    private var sliceSnapshotRebuildPending = false
    #if DEBUG
        private var sliceSnapshotRebuildPendingReasons = Set<String>()
    #endif
    private var sliceRebaseTasksByFullPath: [String: Task<Void, Never>] = [:]
    private var sliceRebaseTaskIDsByFullPath: [String: UUID] = [:]
    /// Monotonic revision incremented for any partition save seen in the current workspace.
    /// Used to avoid re-checking files already confirmed as "no slices" until new saves occur.
    private var partitionSliceSaveRevision: UInt64 = 0
    /// Cache of files confirmed to have no slices at `partitionSliceSaveRevision`.
    private var noSlicesKnownRevisionByFullPath: [String: UInt64] = [:]
    private var workspaceSaveDebounceTask: Task<Void, Never>?

    private var isInitialRootLoadScanDeferralActive = false
    private var deferredInitialRootLoadScanRoots = Set<String>()
    private var deferredInitialRootLoadScanFlushTask: Task<Void, Never>?
    private var deferredInitialRootLoadScanFlushTaskID: UUID?

    // MARK: - Path Search Caches

    private struct MarkdownPathSearchEntry {
        let queryPath: String
        let fileFullPath: String
    }

    private var markdownPathSearchIndex: PathSearchIndex?
    private var markdownPathSearchEntries: [MarkdownPathSearchEntry] = []
    private var markdownPathSearchGeneration: UInt64?

    @MainActor
    private func bumpHierarchyGeneration(forRootFullPath rootFullPath: String?) {
        if let path = rootFullPath {
            // Bump only this root
            rootHierarchyGenerations[path, default: 0] &+= 1
        } else {
            // Unknown / multi-root change: conservatively bump all known roots
            for key in rootHierarchyGenerations.keys {
                rootHierarchyGenerations[key]! &+= 1
            }
        }
        // Always bump global signature
        hierarchyGenerationSignature &+= 1
    }

    @MainActor
    private func removeHierarchyGenerationEntry(forRootFullPath rootFullPath: String) {
        if rootHierarchyGenerations.removeValue(forKey: rootFullPath) != nil {
            // Root disappearing is also a topology change for external consumers.
            hierarchyGenerationSignature &+= 1
        }
    }

    @MainActor
    private func clearPathResolutionCaches() async {
        markdownPathSearchIndex = nil
        markdownPathSearchEntries.removeAll(keepingCapacity: false)
        markdownPathSearchGeneration = nil
    }

    @discardableResult
    private func beginRootLoadToken(forRootKey rootKey: RootKey) -> RootLoadToken {
        let nextRootGeneration = (rootLoadGenerationByRootKey[rootKey] ?? 0) &+ 1
        rootLoadGenerationByRootKey[rootKey] = nextRootGeneration
        return RootLoadToken(
            rootKey: rootKey,
            lifecycleGeneration: rootLoadLifecycleGeneration,
            rootGeneration: nextRootGeneration
        )
    }

    private func invalidateRootLoadToken(forRootKey rootKey: RootKey) {
        rootLoadGenerationByRootKey[rootKey, default: 0] &+= 1
    }

    private func invalidateAllRootLoadTokens() {
        rootLoadLifecycleGeneration &+= 1
        rootLoadGenerationByRootKey.removeAll(keepingCapacity: true)
    }

    private func isRootLoadTokenCurrent(_ token: RootLoadToken) -> Bool {
        rootLoadLifecycleGeneration == token.lifecycleGeneration
            && rootLoadGenerationByRootKey[token.rootKey] == token.rootGeneration
    }

    private func validateRootLoadToken(_ token: RootLoadToken) throws {
        try Task.checkCancellation()
        guard isRootLoadTokenCurrent(token) else {
            throw CancellationError()
        }
    }

    #if DEBUG
        func setRootLoadDidAttachRootShellHandler(
            _ handler: (@Sendable (_ standardizedRootPath: String, _ rootID: UUID) async -> Void)?
        ) {
            rootLoadDidAttachRootShellHandler = handler
        }
    #endif

    #if DEBUG
        private func debugPerfTimestampMS() -> Double {
            CFAbsoluteTimeGetCurrent() * 1000
        }

        private func debugPerfElapsedMS(since startMS: Double) -> Double {
            debugPerfTimestampMS() - startMS
        }

        private func restorePerfRootKindName(_ rootKind: RootKind) -> String {
            switch rootKind {
            case .user:
                "user"
            case .supplementalSystem:
                "supplementalSystem"
            }
        }

        /// Secondary UI projection counts for workspace-loading diagnostics; canonical workspace size
        /// comes from `WorkspaceFileContextStore.catalogDiagnostics(...)`.
        func restorePerfLoadedTreeCounts() -> (rootCount: Int, folderCount: Int, fileCount: Int) {
            (
                rootFolders.count,
                fileHierarchyIndex.foldersByFullPath.count,
                fileHierarchyIndex.filesByFullPath.count
            )
        }

        private static var isRootCleanupOwnershipIntegrityValidationEnabled: Bool {
            UserDefaults.standard.bool(forKey: "enableWorkspaceFilesOwnershipIntegrityValidation")
        }

        @MainActor
        private func invalidateStaticSnapshot(forRootFullPath rootFullPath: String? = nil) {
            bumpHierarchyGeneration(forRootFullPath: rootFullPath)
            // Notify subscribers that file system has changed
            fileSystemChangedPublisher.send()
        }
    #else
        @MainActor
        private func invalidateStaticSnapshot(forRootFullPath rootFullPath: String? = nil) {
            bumpHierarchyGeneration(forRootFullPath: rootFullPath)
            // Notify subscribers that file system has changed
            fileSystemChangedPublisher.send()
        }
    #endif

    /// Shared instance to avoid recreating a search actor for every query
    private let fileSearchActor = FileSearchActor()
    private let deltaReplayPreparationActor = DeltaReplayPreparationActor()

    @Published var remainingScanCount: Int = 0
    @Published var totalFilesSeen: Int = 0

    // We'll keep your existing references to isLoading, selectedFiles, etc.
    // If you don't need these placeholders, remove them.
    private var currentFolderLoadingTask: Task<Void, Error>?
    private var currentFolderLoadingTaskID: UUID?

    private var scanProgressTask: Task<Void, Never>?

    #if !DEBUG
        typealias RootReplayPassPerfSample = Never
    #endif

    private var appliedIndexProjectionHandledGenerationByRootID: [UUID: UInt64] = [:]

    #if DEBUG
        struct IndexRebuildPerfSample: Equatable {
            let rootKey: String
            let totalFolderKeysBefore: Int
            let totalFileKeysBefore: Int
            let ownedFolderKeysBefore: Int
            let ownedFileKeysBefore: Int
            let cleanupCandidateFolderKeys: Int
            let cleanupCandidateFileKeys: Int
            let usedOwnershipFallback: Bool
            let cleanupCandidateSelectionDurationMS: Double
            let cleanupFolderRemovalDurationMS: Double
            let cleanupFileRemovalDurationMS: Double
            let reindexTraversalDurationMS: Double
            let reindexVisitedFolderCount: Int
            let reindexVisitedFileCount: Int
            let totalDurationMS: Double
        }

        struct RootReplayPerfSample: Equatable {
            let rootKey: String
            var passIndex: Int = 0
            var chunkIndexInPass: Int = 0
            var chunkCountInPass: Int = 0
            var coalesceDurationMS: Double = 0
            var preparationDurationMS: Double = 0
            var applyAwaitDurationMS: Double = 0
            var yieldedAfterChunk = false
            var yieldDurationMSAfterChunk: Double = 0
            var interChunkSleepDurationMSAfterChunk: Double = 0
            let batchQueuedDeltaCount: Int
            let batchCoalescedDeltaCount: Int
            let batchDiscardedDeltaCount: Int
            let chunkDeltaCount: Int
            let fileAddedCount: Int
            let fileRemovedCount: Int
            let folderAddedCount: Int
            let folderRemovedCount: Int
            let modifiedCount: Int
            let folderModifiedCount: Int
            let folderModifiedCarriedDateCount: Int
            let folderModifiedFallbackStatSuccessCount: Int
            let folderModifiedSkippedNoDateCount: Int
            let parentLookupCount: Int
            let removedSubtreeDescendantLookupCount: Int
            let deltaLoopDurationMS: Double
            let pendingInsertRootCountBeforeFlush: Int
            let pendingInsertEntryCountBeforeFlush: Int
            let pendingInsertEntryCountForReplayedRootBeforeFlush: Int
            let pendingInsertEntryCountRemainingAfterFlush: Int
            let flushPendingInsertsDurationMS: Double
            let updateFolderStatesDurationMS: Double
            let usedFullRootFolderStateRefresh: Bool
            let dirtyFolderStateStartCount: Int
            let onRootFoldersChangedDurationMS: Double
            let usedIncrementalIndexCleanup: Bool
            let incrementalIndexCleanupDurationMS: Double
            let incrementalRemovedFolderCount: Int
            let incrementalRemovedFileCount: Int
            let incrementalIndexCleanupFallbackToRebuild: Bool
            let rebuildDurationMS: Double?
            let rebuildCleanupCandidateSelectionDurationMS: Double?
            let rebuildCleanupFolderRemovalDurationMS: Double?
            let rebuildCleanupFileRemovalDurationMS: Double?
            let rebuildTraversalDurationMS: Double?
            let rebuildCleanupCandidateFolderKeys: Int?
            let rebuildCleanupCandidateFileKeys: Int?
            let rebuildUsedOwnershipFallback: Bool?
            let codeScanBatchInvocationCount: Int
            let codeScanBatchFileCount: Int
            let sliceRebaseBatchInvocationCount: Int
            let sliceRebaseCandidateCount: Int
            let invalidateSnapshotDurationMS: Double
            let totalApplyDurationMS: Double
        }

        struct RootReplayPassPerfSample: Equatable {
            let rootKey: String
            let passIndex: Int
            let chunkCount: Int
            let digestCount: Int
            let topologyChanged: Bool
            let onRootFoldersChangedInvocationCount: Int
            let snapshotInvalidationCount: Int
            let deltaAppliedPublisherInvocationCount: Int
            let codeScanBatchInvocationCount: Int
            let codeScanBatchFileCount: Int
            let sliceRebaseBatchInvocationCount: Int
            let sliceRebaseCandidateCount: Int
            let onRootFoldersChangedDurationMS: Double
            let invalidateSnapshotDurationMS: Double
            let finalizeDurationMS: Double
        }

        struct ImmediateReplayPerfSample: Equatable {
            let rootKey: String
            let passIndex: Int
            let chunkCount: Int
            let totalDeltaCount: Int
            let queuedDeltaCount: Int
            let coalescedDeltaCount: Int
            let discardedDeltaCount: Int
            let replayedChunks: [RootReplayPerfSample]
            let rootPass: RootReplayPassPerfSample?
            let totalDurationMS: Double
        }

        struct DeltaReplayPerfSample: Equatable {
            struct ServiceFlushSample: Equatable {
                let rootKey: String
                let pendingRawEventCountBeforeFlush: Int
            }

            let aggressive: Bool
            let pendingRootCountAtStart: Int
            let pendingDeltaCountAtStart: Int
            let whileLoopPassCount: Int
            let totalRootPassCount: Int
            let totalChunkCount: Int
            let totalRootPassFinalizeDurationMS: Double
            let totalCoalescedDeltaCount: Int
            let totalDiscardedDeltaCount: Int
            let totalCoalesceDurationMS: Double
            let totalPreparationDurationMS: Double
            let totalApplyAwaitDurationMS: Double
            let totalYieldDurationMS: Double
            let totalInterChunkSleepDurationMS: Double
            let totalDeltaLoopDurationMS: Double
            let totalFlushPendingInsertsDurationMS: Double
            let totalUpdateFolderStatesDurationMS: Double
            let totalIncrementalIndexCleanupDurationMS: Double
            let totalOnRootFoldersChangedDurationMS: Double
            let totalOnRootFoldersChangedInvocationCount: Int
            let totalSnapshotInvalidationCount: Int
            let totalDeltaAppliedPublisherInvocationCount: Int
            let totalReplayCodeScanBatchInvocationCount: Int
            let totalReplaySliceRebaseBatchInvocationCount: Int
            let totalRebuildDurationMS: Double
            let totalCodeScanBatchFileCount: Int
            let totalSliceRebaseCandidateCount: Int
            let totalInvalidateSnapshotDurationMS: Double
            let preReplayServiceFlushes: [ServiceFlushSample]
            let postReplayServiceFlushes: [ServiceFlushSample]
            let replayedRoots: [RootReplayPerfSample]
            let rootPasses: [RootReplayPassPerfSample]
            let totalDurationMS: Double
        }

        private struct PendingInsertPerfSnapshot {
            let rootCount: Int
            let entryCount: Int
            let entryCountForRoot: Int
        }

        private var lastIndexRebuildPerfSample: IndexRebuildPerfSample?
        private var lastDeltaReplayPerfSample: DeltaReplayPerfSample?
        private var lastImmediateReplayPerfSample: ImmediateReplayPerfSample?
        private var currentRootReplayPerfSample: RootReplayPerfSample?
        private var currentReplayParentLookupCount = 0
        private var deltaReplayChunkSizeOverride: Int?
        private var deltaReplayInterChunkDelayNanosecondsOverride: UInt64?

        struct AppliedIndexProjectionDiagnosticsSnapshot: Equatable {
            let handledEventCount: Int
            let handledGenerationByRootID: [UUID: UInt64]
            let directFileIDLookupCount: Int
            let directFolderIDLookupCount: Int
            let directIDLookupMissCount: Int
            let canonicalResyncCount: Int
            let indexRebuildCount: Int
            let indexRebuildTotalDurationMS: Double
            let indexRebuildTraversalDurationMS: Double
            let indexRebuildVisitedFolderCount: Int
            let indexRebuildVisitedFileCount: Int
        }

        private var appliedIndexProjectionHandledEventCount = 0
        private var appliedIndexProjectionDirectFileIDLookupCount = 0
        private var appliedIndexProjectionDirectFolderIDLookupCount = 0
        private var appliedIndexProjectionDirectIDLookupMissCount = 0
        private var appliedIndexProjectionCanonicalResyncCount = 0
        private var appliedIndexProjectionIndexRebuildCount = 0
        private var appliedIndexProjectionIndexRebuildTotalDurationMS: Double = 0
        private var appliedIndexProjectionIndexRebuildTraversalDurationMS: Double = 0
        private var appliedIndexProjectionIndexRebuildVisitedFolderCount = 0
        private var appliedIndexProjectionIndexRebuildVisitedFileCount = 0
        private var appliedIndexProjectionWillHandleHandler: (@Sendable (UUID, UInt64) async -> Void)?
        private var appliedIndexProjectionStateObserver: ((AppliedIndexProjectionDiagnosticsSnapshot) -> Void)?

        func setAppliedIndexProjectionWillHandleHandlerForTesting(
            _ handler: (@Sendable (UUID, UInt64) async -> Void)?
        ) {
            appliedIndexProjectionWillHandleHandler = handler
        }

        func setAppliedIndexProjectionStateObserverForTesting(
            _ observer: ((AppliedIndexProjectionDiagnosticsSnapshot) -> Void)?
        ) {
            appliedIndexProjectionStateObserver = observer
            observer?(appliedIndexProjectionDiagnosticsSnapshot())
        }

        func appliedIndexProjectionDiagnosticsSnapshot() -> AppliedIndexProjectionDiagnosticsSnapshot {
            AppliedIndexProjectionDiagnosticsSnapshot(
                handledEventCount: appliedIndexProjectionHandledEventCount,
                handledGenerationByRootID: appliedIndexProjectionHandledGenerationByRootID,
                directFileIDLookupCount: appliedIndexProjectionDirectFileIDLookupCount,
                directFolderIDLookupCount: appliedIndexProjectionDirectFolderIDLookupCount,
                directIDLookupMissCount: appliedIndexProjectionDirectIDLookupMissCount,
                canonicalResyncCount: appliedIndexProjectionCanonicalResyncCount,
                indexRebuildCount: appliedIndexProjectionIndexRebuildCount,
                indexRebuildTotalDurationMS: appliedIndexProjectionIndexRebuildTotalDurationMS,
                indexRebuildTraversalDurationMS: appliedIndexProjectionIndexRebuildTraversalDurationMS,
                indexRebuildVisitedFolderCount: appliedIndexProjectionIndexRebuildVisitedFolderCount,
                indexRebuildVisitedFileCount: appliedIndexProjectionIndexRebuildVisitedFileCount
            )
        }

        private func notifyAppliedIndexProjectionStateChanged() {
            appliedIndexProjectionStateObserver?(appliedIndexProjectionDiagnosticsSnapshot())
        }

        func resetAppliedIndexProjectionLookupDiagnosticsForTesting() {
            appliedIndexProjectionDirectFileIDLookupCount = 0
            appliedIndexProjectionDirectFolderIDLookupCount = 0
            appliedIndexProjectionDirectIDLookupMissCount = 0
        }
    #endif
    private var workspaceStoreDeltaBridgeTask: Task<Void, Never>?
    private var workspaceStoreCodemapBridgeTask: Task<Void, Never>?
    private let alwaysReadableHomeDirectoryURL: URL

    init(
        alwaysReadableHomeDirectoryURL: URL? = nil,
        workspaceFileContextStore: WorkspaceFileContextStore
    ) {
        self.alwaysReadableHomeDirectoryURL = (alwaysReadableHomeDirectoryURL ?? FileManager.default.homeDirectoryForCurrentUser).standardizedFileURL
        self.workspaceFileContextStore = workspaceFileContextStore
        // If you store sortMethod in user defaults, do that here
        if let loaded = SortMethod(rawValue: storedSortMethod) {
            currentSortMethod = loaded
        } else {
            currentSortMethod = .nameAscending
        }

        // Initialize runtime file-system flags from the JSON-backed source of truth
        // before any FileSystemService instances can be created for loaded folders.
        syncFileSystemPreferencesFromGlobalSettings()

        subscribeToScanProgress()
        subscribeToWorkspaceStoreDeltaEvents()
        subscribeToWorkspaceStoreCodemapUpdates()
        subscribeToPartitionStoreSaves()
        subscribeToFileSystemPreferenceChanges()
    }

    #if DEBUG
        convenience init(alwaysReadableHomeDirectoryURL: URL? = nil) {
            self.init(
                alwaysReadableHomeDirectoryURL: alwaysReadableHomeDirectoryURL,
                workspaceFileContextStore: WorkspaceFileContextStore()
            )
        }
    #endif

    deinit {
        // Cancel the subscriptions if this VM goes away
        scanProgressTask?.cancel()
        workspaceStoreDeltaBridgeTask?.cancel()
        workspaceStoreCodemapBridgeTask?.cancel()
        autoCodemapSyncTask?.cancel()
        for task in sliceRebaseTasksByFullPath.values {
            task.cancel()
        }
        sliceRebaseTasksByFullPath.removeAll()
        sliceRebaseTaskIDsByFullPath.removeAll()
        workspaceSaveDebounceTask?.cancel()
        selectionCoordinatorCancellable?.cancel()
        partitionStoreSaveCancellable?.cancel()
        fileSystemSettingsCancellable?.cancel()
    }

    func attachSelectionCoordinator(_ coordinator: WorkspaceSelectionCoordinator) {
        selectionCoordinator = coordinator
        selectionCoordinatorCancellable?.cancel()
        selectionCoordinatorCancellable = coordinator.changes
            .sink { [weak self, weak coordinator] change in
                guard change.source != .uiFlush, !change.source.isMCPSelectionSource else { return }
                Task { @MainActor [weak self, weak coordinator] in
                    guard let self, let coordinator else { return }
                    if let changeTabID = change.tabID {
                        guard let activeIdentity = coordinator.activeSelectionIdentity(),
                              activeIdentity.tabID == changeTabID,
                              coordinator.selectionSnapshot(
                                  for: activeIdentity,
                                  flushPendingUIIfActive: false
                              )?.selection == change.selection
                        else { return }
                    }
                    let current = snapshotSelection()
                    guard current != change.selection else { return }
                    await coordinator.withApplyingSelectionMirror {
                        await self.applyStoredSelection(change.selection)
                    }
                }
            }
    }

    func setWorkspaceManager(_ manager: WorkspaceManagerViewModel) {
        workspaceManager = manager
        currentWorkspaceID = manager.activeWorkspaceID
        manager.addWorkspaceDidSwitchListener(label: "fileManager") { [weak self] workspace in
            guard let self else { return }
            Task { @MainActor in
                await self.handleWorkspaceSwitch(to: workspace)
            }
        }
        if let activeWorkspace = manager.activeWorkspace {
            Task { @MainActor in
                await self.handleWorkspaceSwitch(to: activeWorkspace)
            }
        } else {
            currentSlicesByRoot.removeAll()
            requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")
        }
    }

    /// Explicitly set the current workspace ID (used during workspace restoration to ensure timing)
    @MainActor
    func setCurrentWorkspaceID(_ id: UUID?) {
        currentWorkspaceID = id
    }

    @MainActor
    private func handleWorkspaceSwitch(to workspace: WorkspaceModel?) async {
        #if DEBUG
            let switchSlicesStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        currentWorkspaceID = workspace?.id
        currentTabID = nil
        guard let workspaceID = workspace?.id else {
            currentSlicesByRoot.removeAll()
            requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "workspaceFiles.workspaceSwitchSlices.clear",
                    fields: [
                        "duration": switchSlicesStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            return
        }

        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "workspaceFiles.workspaceSwitchSlices.begin",
                fields: [
                    "workspaceID": WorkspaceRestorePerfLog.shortID(workspaceID),
                    "rootCount": "\(rootFolders.count)"
                ]
            )
        #endif
        var refreshed: [String: [String: PartitionStore.StoredSlices]] = [:]
        for root in rootFolders {
            let rootPath = root.standardizedFullPath
            let data = await selectionSliceCoordinator.loadSlices(
                forRootPath: rootPath,
                scope: PartitionScope(workspaceID: workspaceID)
            )
            if !data.isEmpty {
                refreshed[rootPath] = data
            }
        }
        currentSlicesByRoot = refreshed
        requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "workspaceFiles.workspaceSwitchSlices.end",
                fields: [
                    "workspaceID": WorkspaceRestorePerfLog.shortID(workspaceID),
                    "rootCount": "\(rootFolders.count)",
                    "rootsWithSlices": "\(refreshed.count)",
                    "duration": switchSlicesStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
    }

    @MainActor
    func setActiveTabID(_ id: UUID?) {
        currentTabID = id
    }

    #if DEBUG
        @MainActor
        var currentTabIDForDebugOwnerTrace: UUID? {
            currentTabID
        }
    #endif

    /// Subscribes to store-owned codemap scan progress.
    private func subscribeToScanProgress() {
        scanProgressTask = Task { [weak self] in
            guard let self else { return }
            let stream = await workspaceFileContextStore.codemapScanProgressUpdates()
            for await (remaining, total) in stream {
                await MainActor.run {
                    self.updateScanProgress(remaining: remaining, total: total)
                }
            }
        }
    }

    private func updateScanProgress(remaining: Int, total: Int) {
        remainingScanCount = remaining
        totalFilesSeen = total
        // No extra counter needed – updating the two @Published props is enough
    }

    private func subscribeToWorkspaceStoreDeltaEvents() {
        workspaceStoreDeltaBridgeTask = Task { [weak self] in
            guard let self else { return }
            let stream = await workspaceFileContextStore.appliedIndexEvents()
            for await event in stream {
                await handleWorkspaceAppliedIndexEvent(event)
            }
        }
    }

    private func subscribeToWorkspaceStoreCodemapUpdates() {
        workspaceStoreCodemapBridgeTask = Task { [weak self] in
            guard let self else { return }
            let stream = await workspaceFileContextStore.codemapUpdates()
            for await event in stream {
                handleWorkspaceStoreCodemapUpdateEvent(event)
            }
        }
    }

    private struct WorkspaceAppliedIndexModificationTargets {
        let filesByID: [UUID: FileViewModel]
        let foldersByID: [UUID: FolderViewModel]
    }

    private enum WorkspaceAppliedIndexModificationResolution {
        case targets(WorkspaceAppliedIndexModificationTargets)
        case requiresCanonicalResync
        case rootNoLongerCurrent
    }

    @MainActor
    private func handleWorkspaceAppliedIndexEvent(_ event: WorkspaceAppliedIndexBatchEvent) async {
        #if DEBUG
            if let appliedIndexProjectionWillHandleHandler {
                await appliedIndexProjectionWillHandleHandler(event.rootID, event.generation)
            }
        #endif

        guard !Task.isCancelled,
              let (rootKey, targetRootVM) = currentWorkspaceAppliedIndexRoot(for: event)
        else { return }
        let handledGeneration = appliedIndexProjectionHandledGenerationByRootID[event.rootID] ?? 0
        guard event.generation > handledGeneration else { return }

        if event.isRootUnload {
            _ = detachRootShellReferences(targetRootVM)
            recordHandledWorkspaceAppliedIndexEvent()
            return
        }

        let nextExpectedGeneration = handledGeneration &+ 1
        if event.requiresFullResync || event.generation != nextExpectedGeneration {
            _ = await resyncAndRecordWorkspaceAppliedIndexProjection(
                for: event,
                rootKey: rootKey,
                targetRootVM: targetRootVM
            )
            return
        }

        let modificationTargets: WorkspaceAppliedIndexModificationTargets
        switch await resolveContiguousWorkspaceAppliedIndexModificationTargets(
            for: event,
            rootKey: rootKey,
            targetRootVM: targetRootVM
        ) {
        case let .targets(resolvedTargets):
            modificationTargets = resolvedTargets
        case .requiresCanonicalResync:
            _ = await resyncAndRecordWorkspaceAppliedIndexProjection(
                for: event,
                rootKey: rootKey,
                targetRootVM: targetRootVM
            )
            return
        case .rootNoLongerCurrent:
            return
        }

        guard await applyWorkspaceAppliedIndexEvent(
            event,
            rootKey: rootKey,
            targetRootVM: targetRootVM,
            useCanonicalSnapshotMetadata: false,
            modificationTargets: modificationTargets
        ) else { return }
        appliedIndexProjectionHandledGenerationByRootID[event.rootID] = event.generation
        recordHandledWorkspaceAppliedIndexEvent()
    }

    @MainActor
    private func currentWorkspaceAppliedIndexRoot(
        for event: WorkspaceAppliedIndexBatchEvent
    ) -> (rootKey: RootKey, root: FolderViewModel)? {
        let rootKey = rootKey(forPath: event.rootPath)
        guard workspaceFileContextRootsByRootKey[rootKey]?.id == event.rootID,
              let root = rootFolders.first(where: { $0.id == event.rootID }),
              root.standardizedFullPath == rootKey,
              fileHierarchyIndex.foldersByID[event.rootID] === root
        else {
            return nil
        }
        return (rootKey, root)
    }

    @MainActor
    private func isCurrentWorkspaceAppliedIndexRoot(
        for event: WorkspaceAppliedIndexBatchEvent,
        targetRootVM: FolderViewModel
    ) -> Bool {
        guard !Task.isCancelled,
              let current = currentWorkspaceAppliedIndexRoot(for: event)
        else {
            return false
        }
        return current.root === targetRootVM
    }

    @MainActor
    private func isCurrentAttachedRoot(
        _ root: FolderViewModel,
        expectedRootID: UUID? = nil
    ) -> Bool {
        guard !Task.isCancelled else { return false }
        let rootKey = StandardizedPath.absolute(root.standardizedFullPath)
        let rootID = expectedRootID ?? root.id
        return root.id == rootID
            && workspaceFileContextRootsByRootKey[rootKey]?.id == rootID
            && rootFolders.contains(where: { $0 === root })
            && fileHierarchyIndex.foldersByID[rootID] === root
            && fileHierarchyIndex.foldersByFullPath[rootKey] === root
    }

    @MainActor
    private func recordHandledWorkspaceAppliedIndexEvent() {
        #if DEBUG
            appliedIndexProjectionHandledEventCount += 1
            notifyAppliedIndexProjectionStateChanged()
        #endif
    }

    @MainActor
    private func resyncAndRecordWorkspaceAppliedIndexProjection(
        for event: WorkspaceAppliedIndexBatchEvent,
        rootKey: RootKey,
        targetRootVM: FolderViewModel
    ) async -> Bool {
        guard let resyncedGeneration = await resyncWorkspaceAppliedIndexProjection(
            for: event,
            rootKey: rootKey,
            targetRootVM: targetRootVM
        ) else {
            return false
        }
        appliedIndexProjectionHandledGenerationByRootID[event.rootID] = resyncedGeneration
        #if DEBUG
            appliedIndexProjectionCanonicalResyncCount += 1
        #endif
        recordHandledWorkspaceAppliedIndexEvent()
        return true
    }

    @MainActor
    private func resolveContiguousWorkspaceAppliedIndexModificationTargets(
        for event: WorkspaceAppliedIndexBatchEvent,
        rootKey: RootKey,
        targetRootVM: FolderViewModel
    ) async -> WorkspaceAppliedIndexModificationResolution {
        var filesByID: [UUID: FileViewModel] = [:]
        filesByID.reserveCapacity(event.modifiedFileIDs.count)
        var missingFileIDs: [UUID] = []
        missingFileIDs.reserveCapacity(event.modifiedFileIDs.count)
        for fileID in event.modifiedFileIDs {
            guard let file = projectedFileForAppliedIndexModification(id: fileID) else {
                missingFileIDs.append(fileID)
                continue
            }
            guard isConsistentProjectedFile(file, id: fileID, rootKey: rootKey) else {
                return .requiresCanonicalResync
            }
            filesByID[fileID] = file
        }

        var foldersByID: [UUID: FolderViewModel] = [:]
        foldersByID.reserveCapacity(event.modifiedFolderIDs.count)
        var missingFolderIDs: [UUID] = []
        missingFolderIDs.reserveCapacity(event.modifiedFolderIDs.count)
        for folderID in event.modifiedFolderIDs {
            guard let folder = projectedFolderForAppliedIndexModification(id: folderID) else {
                missingFolderIDs.append(folderID)
                continue
            }
            guard isConsistentProjectedFolder(folder, id: folderID, rootKey: rootKey) else {
                return .requiresCanonicalResync
            }
            foldersByID[folderID] = folder
        }

        guard !missingFileIDs.isEmpty || !missingFolderIDs.isEmpty else {
            return .targets(WorkspaceAppliedIndexModificationTargets(
                filesByID: filesByID,
                foldersByID: foldersByID
            ))
        }

        guard let snapshot = await workspaceFileContextStore.appliedIndexRootSnapshot(rootID: event.rootID),
              snapshot.root.id == event.rootID,
              snapshot.root.standardizedFullPath == rootKey,
              snapshot.generation >= event.generation
        else {
            return .requiresCanonicalResync
        }
        guard !Task.isCancelled,
              let current = currentWorkspaceAppliedIndexRoot(for: event),
              current.root === targetRootVM
        else {
            return .rootNoLongerCurrent
        }

        for (fileID, file) in filesByID {
            guard isConsistentProjectedFile(file, id: fileID, rootKey: rootKey) else {
                return .requiresCanonicalResync
            }
        }
        for (folderID, folder) in foldersByID {
            guard isConsistentProjectedFolder(folder, id: folderID, rootKey: rootKey) else {
                return .requiresCanonicalResync
            }
        }

        let canonicalFilesByID = Dictionary(uniqueKeysWithValues: snapshot.files.map { ($0.id, $0) })
        for fileID in missingFileIDs {
            guard let record = canonicalFilesByID[fileID] else {
                return .requiresCanonicalResync
            }
            let fileByID = fileHierarchyIndex.filesByID[fileID]
            let fileByPath = fileHierarchyIndex.filesByFullPath[record.standardizedFullPath]
            switch (fileByID, fileByPath) {
            case (nil, nil):
                continue
            case let (idFile?, pathFile?) where idFile === pathFile
                && isConsistentProjectedFile(
                    idFile,
                    id: fileID,
                    rootKey: rootKey,
                    expectedFullPath: record.standardizedFullPath
                ):
                filesByID[fileID] = idFile
            default:
                return .requiresCanonicalResync
            }
        }

        let canonicalFoldersByID = Dictionary(uniqueKeysWithValues: snapshot.folders.map { ($0.id, $0) })
        for folderID in missingFolderIDs {
            guard let record = canonicalFoldersByID[folderID] else {
                return .requiresCanonicalResync
            }
            let folderByID = fileHierarchyIndex.foldersByID[folderID]
            let folderByPath = fileHierarchyIndex.foldersByFullPath[record.standardizedFullPath]
            switch (folderByID, folderByPath) {
            case (nil, nil):
                continue
            case let (idFolder?, pathFolder?) where idFolder === pathFolder
                && isConsistentProjectedFolder(
                    idFolder,
                    id: folderID,
                    rootKey: rootKey,
                    expectedFullPath: record.standardizedFullPath
                ):
                foldersByID[folderID] = idFolder
            default:
                return .requiresCanonicalResync
            }
        }

        return .targets(WorkspaceAppliedIndexModificationTargets(
            filesByID: filesByID,
            foldersByID: foldersByID
        ))
    }

    @MainActor
    private func resolveStrictWorkspaceAppliedIndexModificationTargets(
        for event: WorkspaceAppliedIndexBatchEvent,
        rootKey: RootKey
    ) -> WorkspaceAppliedIndexModificationTargets? {
        var filesByID: [UUID: FileViewModel] = [:]
        filesByID.reserveCapacity(event.modifiedFileIDs.count)
        for fileID in event.modifiedFileIDs {
            guard let file = projectedFileForAppliedIndexModification(id: fileID),
                  isConsistentProjectedFile(file, id: fileID, rootKey: rootKey)
            else {
                return nil
            }
            filesByID[fileID] = file
        }

        var foldersByID: [UUID: FolderViewModel] = [:]
        foldersByID.reserveCapacity(event.modifiedFolderIDs.count)
        for folderID in event.modifiedFolderIDs {
            guard let folder = projectedFolderForAppliedIndexModification(id: folderID),
                  isConsistentProjectedFolder(folder, id: folderID, rootKey: rootKey)
            else {
                return nil
            }
            foldersByID[folderID] = folder
        }
        return WorkspaceAppliedIndexModificationTargets(filesByID: filesByID, foldersByID: foldersByID)
    }

    @MainActor
    private func isConsistentProjectedFile(
        _ file: FileViewModel,
        id: UUID,
        rootKey: RootKey,
        expectedFullPath: String? = nil
    ) -> Bool {
        file.id == id
            && file.standardizedRootFolderPath == rootKey
            && (expectedFullPath.map { file.standardizedFullPath == $0 } ?? true)
            && fileHierarchyIndex.filesByID[id] === file
            && fileHierarchyIndex.filesByFullPath[file.standardizedFullPath] === file
    }

    @MainActor
    private func isConsistentProjectedFolder(
        _ folder: FolderViewModel,
        id: UUID,
        rootKey: RootKey,
        expectedFullPath: String? = nil
    ) -> Bool {
        folder.id == id
            && StandardizedPath.absolute(folder.rootPath) == rootKey
            && (expectedFullPath.map { folder.standardizedFullPath == $0 } ?? true)
            && fileHierarchyIndex.foldersByID[id] === folder
            && fileHierarchyIndex.foldersByFullPath[folder.standardizedFullPath] === folder
    }

    @MainActor
    private func resyncWorkspaceAppliedIndexProjection(
        for event: WorkspaceAppliedIndexBatchEvent,
        rootKey: RootKey,
        targetRootVM: FolderViewModel
    ) async -> UInt64? {
        guard let snapshot = await workspaceFileContextStore.appliedIndexRootSnapshot(rootID: event.rootID),
              snapshot.root.id == event.rootID,
              snapshot.root.standardizedFullPath == rootKey,
              snapshot.generation >= event.generation,
              let current = currentWorkspaceAppliedIndexRoot(for: event),
              current.root === targetRootVM
        else {
            return nil
        }

        rebuildFileHierarchyIndex(for: targetRootVM)

        let canonicalFilePaths = Set(snapshot.files.map(\.standardizedFullPath))
        let canonicalFolderPaths = Set(snapshot.folders.map(\.standardizedFullPath)).union([rootKey])
        let currentFilePaths = fileHierarchyIndex.filePathsByRoot[rootKey]
            ?? Set(fileHierarchyIndex.filesByFullPath.keys.filter { StandardizedPath.isDescendant($0, of: rootKey) })
        let currentFolderPaths = fileHierarchyIndex.folderPathsByRoot[rootKey]
            ?? Set(fileHierarchyIndex.foldersByFullPath.keys.filter { StandardizedPath.isDescendant($0, of: rootKey) })

        let upsertedFiles = snapshot.files.filter { record in
            fileHierarchyIndex.filesByFullPath[record.standardizedFullPath]?.id != record.id
        }
        let upsertedFolders = snapshot.folders.filter { record in
            !record.standardizedRelativePath.isEmpty
                && fileHierarchyIndex.foldersByFullPath[record.standardizedFullPath]?.id != record.id
        }
        let modifiedFileIDs = snapshot.files.compactMap { record -> UUID? in
            guard let modificationDate = record.modificationDate,
                  let currentFile = fileHierarchyIndex.filesByFullPath[record.standardizedFullPath],
                  currentFile.id == record.id,
                  currentFile.modificationDate != modificationDate
            else {
                return nil
            }
            return record.id
        }
        let modifiedFolderIDs = snapshot.folders.compactMap { record -> UUID? in
            guard !record.standardizedRelativePath.isEmpty,
                  let modificationDate = record.modificationDate,
                  let currentFolder = fileHierarchyIndex.foldersByFullPath[record.standardizedFullPath],
                  currentFolder.id == record.id,
                  currentFolder.modificationDate != modificationDate
            else {
                return nil
            }
            return record.id
        }
        let removedFilePaths = currentFilePaths.subtracting(canonicalFilePaths).map {
            StandardizedPath.relative(String($0.dropFirst(rootKey.count)))
        }
        let removedFolderPaths = currentFolderPaths.subtracting(canonicalFolderPaths).map {
            StandardizedPath.relative(String($0.dropFirst(rootKey.count)))
        }

        guard !upsertedFiles.isEmpty || !upsertedFolders.isEmpty
            || !removedFilePaths.isEmpty || !removedFolderPaths.isEmpty
            || !modifiedFileIDs.isEmpty || !modifiedFolderIDs.isEmpty
        else {
            return snapshot.generation
        }

        let resyncEvent = WorkspaceAppliedIndexBatchEvent(
            rootID: event.rootID,
            rootPath: rootKey,
            generation: snapshot.generation,
            upsertedFiles: upsertedFiles,
            upsertedFolders: upsertedFolders,
            removedFilePaths: removedFilePaths,
            removedFolderPaths: removedFolderPaths,
            modifiedFileIDs: modifiedFileIDs,
            modifiedFolderIDs: modifiedFolderIDs
        )
        guard let modificationTargets = resolveStrictWorkspaceAppliedIndexModificationTargets(
            for: resyncEvent,
            rootKey: rootKey
        ), await applyWorkspaceAppliedIndexEvent(
            resyncEvent,
            rootKey: rootKey,
            targetRootVM: targetRootVM,
            useCanonicalSnapshotMetadata: true,
            modificationTargets: modificationTargets
        ) else {
            return nil
        }
        return snapshot.generation
    }

    @MainActor
    private func applyWorkspaceAppliedIndexEvent(
        _ event: WorkspaceAppliedIndexBatchEvent,
        rootKey: RootKey,
        targetRootVM: FolderViewModel,
        useCanonicalSnapshotMetadata: Bool,
        modificationTargets: WorkspaceAppliedIndexModificationTargets
    ) async -> Bool {
        guard isCurrentWorkspaceAppliedIndexRoot(for: event, targetRootVM: targetRootVM) else {
            return false
        }

        var topologyChanged = false
        var dirtyFolders: [UUID: FolderViewModel] = [:]
        var removedSubtrees: [RemovedFolderSubtree] = []
        let sortedFolders = event.upsertedFolders.sorted { lhs, rhs in
            let lhsDepth = lhs.standardizedRelativePath.split(separator: "/").count
            let rhsDepth = rhs.standardizedRelativePath.split(separator: "/").count
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            return lhs.standardizedRelativePath < rhs.standardizedRelativePath
        }
        for folder in sortedFolders where folder.rootID == event.rootID && !folder.standardizedRelativePath.isEmpty {
            if let outcome = handleNewFolder(record: folder, onRootFolder: targetRootVM) {
                topologyChanged = true
                if let parent = outcome.parentFolderForStateRecompute {
                    dirtyFolders[parent.id] = parent
                }
            }
        }
        for file in event.upsertedFiles where file.rootID == event.rootID {
            guard isCurrentWorkspaceAppliedIndexRoot(for: event, targetRootVM: targetRootVM) else {
                return false
            }
            let outcome = await handleNewFile(
                record: file,
                onRootFolder: targetRootVM,
                useRecordModificationDateForExistingFile: useCanonicalSnapshotMetadata
            )
            guard isCurrentWorkspaceAppliedIndexRoot(for: event, targetRootVM: targetRootVM) else {
                return false
            }
            if let outcome {
                topologyChanged = true
                if let parent = outcome.parentFolderForStateRecompute {
                    dirtyFolders[parent.id] = parent
                }
            }
        }

        var removedFileFullPaths = Set(event.removedFilePaths.map {
            StandardizedPath.join(standardizedRoot: rootKey, standardizedRelativePath: $0)
        })
        for fileID in event.removedFileIDs {
            if let file = fileHierarchyIndex.filesByID[fileID], file.standardizedRootFolderPath == rootKey {
                removedFileFullPaths.insert(file.standardizedFullPath)
            }
        }
        for fullPath in removedFileFullPaths {
            guard let fileVM = findFileByFullPath(fullPath) else { continue }
            let formerParent = fileVM.parentFolder ?? parentFolderForRelativePath(fileVM.relativePath, under: targetRootVM)
            removeFileFromParentChildrenArray(fileVM)
            fileHierarchyIndex.removeFile(forKey: fullPath, expectedRootKey: rootKey)
            topologyChanged = true
            if let formerParent { dirtyFolders[formerParent.id] = formerParent }
        }

        var removedFolderRelativePaths = Set(event.removedFolderPaths.map(StandardizedPath.relative))
        for folderID in event.removedFolderIDs {
            if let folder = fileHierarchyIndex.foldersByID[folderID],
               folder !== targetRootVM,
               StandardizedPath.absolute(folder.rootPath) == rootKey
            {
                removedFolderRelativePaths.insert(folder.relativePath)
            }
        }
        for path in removedFolderRelativePaths.sorted(by: { $0.count > $1.count }) where !path.isEmpty {
            if let removed = removeFolderRecursive(in: targetRootVM, relativePath: path) {
                removedSubtrees.append(removed)
                topologyChanged = true
                if let parent = removed.formerParentFolder ?? parentFolderForRelativePath(path, under: targetRootVM) {
                    dirtyFolders[parent.id] = parent
                }
            }
        }
        if !removedSubtrees.isEmpty {
            _ = performBatchedIncrementalRemovedSubtreeCleanup(removedSubtrees, rootKey: rootKey)
        }

        for fileID in event.modifiedFileIDs {
            guard let fileVM = modificationTargets.filesByID[fileID] else { continue }
            let date: Date
            do {
                date = try await workspaceFileContextStore.fileModificationDate(
                    rootID: event.rootID,
                    relativePath: fileVM.relativePath
                )
            } catch {
                date = Date()
            }
            guard isCurrentWorkspaceAppliedIndexRoot(for: event, targetRootVM: targetRootVM) else {
                return false
            }
            await fileVM.setModificationDate(date, forceInvalidation: true)
            guard isCurrentWorkspaceAppliedIndexRoot(for: event, targetRootVM: targetRootVM) else {
                return false
            }
            requestCodeScan(for: fileVM)
            scheduleSliceRebasesForModifiedFiles([
                ReplaySliceRebaseRequest(file: fileVM, relativePath: fileVM.relativePath)
            ])
        }
        for folderID in event.modifiedFolderIDs {
            guard let folderVM = modificationTargets.foldersByID[folderID] else { continue }
            let date = try? await workspaceFileContextStore.itemModificationDateIfAvailable(
                rootID: event.rootID,
                relativePath: folderVM.relativePath
            )
            guard isCurrentWorkspaceAppliedIndexRoot(for: event, targetRootVM: targetRootVM) else {
                return false
            }
            if let date {
                folderVM.setModificationDate(date)
            }
        }

        guard isCurrentWorkspaceAppliedIndexRoot(for: event, targetRootVM: targetRootVM) else {
            return false
        }
        flushPendingInserts()
        if topologyChanged {
            if dirtyFolders.isEmpty {
                _ = updateFolderStateRecursive(targetRootVM)
            } else {
                recomputeAncestorStates(startingAtFolders: Array(dirtyFolders.values))
            }
            rebuildFileHierarchyIndex(for: targetRootVM)
        }
        onRootFoldersChanged?()
        fileSystemDeltasAppliedPublisher.send(FileSystemDeltasAppliedEvent(rootKey: rootKey, deltas: []))
        invalidateStaticSnapshot(forRootFullPath: targetRootVM.standardizedFullPath)
        return true
    }

    @MainActor
    private func projectedFileForAppliedIndexModification(id: UUID) -> FileViewModel? {
        #if DEBUG
            appliedIndexProjectionDirectFileIDLookupCount += 1
        #endif
        let file = fileHierarchyIndex.filesByID[id]
        #if DEBUG
            if file == nil { appliedIndexProjectionDirectIDLookupMissCount += 1 }
        #endif
        return file
    }

    @MainActor
    private func projectedFolderForAppliedIndexModification(id: UUID) -> FolderViewModel? {
        #if DEBUG
            appliedIndexProjectionDirectFolderIDLookupCount += 1
        #endif
        let folder = fileHierarchyIndex.foldersByID[id]
        #if DEBUG
            if folder == nil { appliedIndexProjectionDirectIDLookupMissCount += 1 }
        #endif
        return folder
    }

    @MainActor
    private func handleWorkspaceStoreCodemapUpdateEvent(_ event: WorkspaceCodemapUpdateEvent) {
        var updated = false
        var shouldScheduleAutoSync = false

        for snapshot in event.snapshots {
            guard let fileVM = findFileByFullPath(snapshot.fullPath) else { continue }
            let currentApi = validatedFileAPI(for: fileVM)
            let wasTracked = currentApi != nil
            let isSelected = selectedFileIDs.contains(fileVM.id)
            fileVM.setCodeMap(snapshot.fileAPI)
            let acceptedApi = validatedFileAPI(for: fileVM)
            guard !codeMapAPIsMatch(currentApi, acceptedApi) else { continue }
            if acceptedApi != nil {
                if !wasTracked || !isSelected {
                    shouldScheduleAutoSync = true
                }
            } else if wasTracked {
                shouldScheduleAutoSync = true
            }
            updated = true
        }

        if !event.removedFileIDs.isEmpty || event.isRootUnload {
            let removedFileIDs = Set(event.removedFileIDs)
            let removedFiles = allFilesSnapshot(sorted: false).filter { file in
                removedFileIDs.contains(file.id)
                    || (event.isRootUnload && file.standardizedRootFolderPath == event.rootPath)
            }
            for file in removedFiles where validatedFileAPI(for: file) != nil {
                file.setCodeMap(nil)
                shouldScheduleAutoSync = true
                updated = true
            }
        }

        guard updated else { return }
        codeMapUpdatePublisher.send(())
        if shouldScheduleAutoSync {
            scheduleAutoCodemapSync()
        }
    }

    private func codeMapAPIsMatch(_ lhs: FileAPI?, _ rhs: FileAPI?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (left?, right?):
            standardizedAPIFilePath(left) == standardizedAPIFilePath(right)
                && left.apiDescription == right.apiDescription
        case (nil, _?), (_?, nil):
            false
        }
    }

    func cancelAllLoadingTasks() {
        discardDeferredInitialRootLoadScans()
        invalidateAllRootLoadTokens()
        // Cancel the currently running folder loading task, if any.
        currentFolderLoadingTask?.cancel()
        currentFolderLoadingTask = nil
        currentFolderLoadingTaskID = nil

        // Remove any partially added folder.
        removeFolderBeingAdded()

        // Update the loading state.
        isLoading = false
    }

    func waitForAllLoadsToFinish() async {
        print("waitForAllLoadsToFinish() is now a no-op in the absence of tracked tasks.")
        await MainActor.run {
            self.isLoading = false
        }
    }

    // MARK: - Expansion Management

    /// Current set of expanded folders is kept in `expandedFolderPaths`
    /// Return snapshot of all expanded folders from the cached set
    func snapshotExpandedFolderFullPaths() -> [String] {
        Array(expandedFolderPaths)
    }

    /// Legacy name kept for call sites
    func gatherExpandedFolderPaths() -> [String] {
        snapshotExpandedFolderFullPaths()
    }

    /// Return cached expanded folder paths relative to their roots
    func gatherExpandedFolderPathsRelative() -> [String] {
        var results: [String] = []
        for path in expandedFolderPaths {
            if let root = rootFolders.first(where: { path.hasPrefix($0.standardizedFullPath) }) {
                var rel = String(path.dropFirst(root.standardizedFullPath.count))
                if rel.hasPrefix("/") { rel.removeFirst() }
                results.append(rel)
            }
        }
        return results
    }

    /// Recursively register expansion tracking for the given folder and its subtree.
    private func registerExpansionTracking(for folder: FolderViewModel) {
        var visitedFolderIDs = Set<UUID>()
        registerExpansionTracking(for: folder, visitedFolderIDs: &visitedFolderIDs)
    }

    private func registerExpansionTracking(
        for folder: FolderViewModel,
        visitedFolderIDs: inout Set<UUID>
    ) {
        guard visitedFolderIDs.insert(folder.id).inserted else { return }
        if expansionSubscriptions[folder.id] == nil {
            if folder.isExpanded {
                expandedFolderPaths.insert(folder.standardizedFullPath)
            }
            expansionSubscriptions[folder.id] = folder.$isExpanded.sink { [weak self, weak folder] expanded in
                guard let self, let folder else { return }
                if expanded {
                    let inserted = expandedFolderPaths.insert(folder.standardizedFullPath).inserted
                    if inserted, !isApplyingExpansionState {
                        workspaceManager?.markWorkspaceDirty()
                    }
                } else if expandedFolderPaths.remove(folder.standardizedFullPath) != nil {
                    if !isApplyingExpansionState {
                        workspaceManager?.markWorkspaceDirty()
                    }
                }
            }
        }
        for child in folder.children {
            if case let .folder(subFolder) = child {
                registerExpansionTracking(for: subFolder, visitedFolderIDs: &visitedFolderIDs)
            }
        }
    }

    /// Remove any expansion tracking for the given folder subtree.
    private func unregisterExpansionTracking(for folder: FolderViewModel) {
        var visitedFolderIDs = Set<UUID>()
        unregisterExpansionTracking(for: folder, visitedFolderIDs: &visitedFolderIDs)
    }

    @MainActor
    private func adoptCanonicalFolderIDForStoreCorrelation(_ folder: FolderViewModel, canonicalID: UUID) {
        let oldID = folder.id
        guard oldID != canonicalID else { return }
        if let subscription = expansionSubscriptions.removeValue(forKey: oldID) {
            subscription.cancel()
        }
        let pendingChildren = pendingChildInserts.removeValue(forKey: oldID)
        let pendingParent = pendingInsertParents.removeValue(forKey: oldID)
        folder.adoptCanonicalIDForStoreCorrelation(canonicalID)
        fileHierarchyIndex.rekeyFolder(folder, from: oldID)
        if let pendingChildren {
            pendingChildInserts[canonicalID, default: []].append(contentsOf: pendingChildren)
        }
        if let pendingParent {
            pendingInsertParents[canonicalID] = pendingParent
        }
        registerExpansionTracking(for: folder)
    }

    private func unregisterExpansionTracking(
        for folder: FolderViewModel,
        visitedFolderIDs: inout Set<UUID>
    ) {
        guard visitedFolderIDs.insert(folder.id).inserted else { return }
        expansionSubscriptions[folder.id]?.cancel()
        expansionSubscriptions.removeValue(forKey: folder.id)
        expandedFolderPaths.remove(folder.standardizedFullPath)
        for child in folder.children {
            if case let .folder(subFolder) = child {
                unregisterExpansionTracking(for: subFolder, visitedFolderIDs: &visitedFolderIDs)
            }
        }
    }

    /// Initialize expansion state from saved paths
    @MainActor
    func restoreExpansionState(from paths: [String]) async {
        #if DEBUG
            let restoreExpansionStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            var restoreExpansionOutcome = "completed"
            var restoreExpansionTargetFolders = 0
            var restoreExpansionCollapseCount = 0
            var restoreExpansionExpandCount = 0
            var restoreExpansionDidChange = false
            defer {
                WorkspaceRestorePerfLog.event(
                    "selection.restoreExpansion",
                    fields: [
                        "requestedPaths": "\(paths.count)",
                        "normalizedPaths": "\(paths.map { normalizeUserInputPath($0) }.count(where: { !$0.isEmpty }))",
                        "targetFolders": "\(restoreExpansionTargetFolders)",
                        "collapseCount": "\(restoreExpansionCollapseCount)",
                        "expandCount": "\(restoreExpansionExpandCount)",
                        "didChange": "\(restoreExpansionDidChange)",
                        "outcome": restoreExpansionOutcome,
                        "duration": restoreExpansionStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            }
        #endif
        let normalizedPaths = paths.map { normalizeUserInputPath($0) }.filter { !$0.isEmpty }
        var targetFullPaths = Set<String>()

        for path in normalizedPaths {
            let standardized = (path as NSString).standardizingPath
            if path.hasPrefix("/") {
                if fileHierarchyIndex.foldersByFullPath[standardized] != nil {
                    targetFullPaths.insert(standardized)
                }
            } else if let folder = findFolderByRelativePath(standardized) {
                targetFullPaths.insert(folder.standardizedFullPath)
            }
        }

        let currentExpanded = Set(expandedFolderPaths.map { ($0 as NSString).standardizingPath })
        let toCollapse = currentExpanded.subtracting(targetFullPaths)
        let toExpand = targetFullPaths.subtracting(currentExpanded)
        #if DEBUG
            restoreExpansionTargetFolders = targetFullPaths.count
            restoreExpansionCollapseCount = toCollapse.count
            restoreExpansionExpandCount = toExpand.count
        #endif
        guard !toCollapse.isEmpty || !toExpand.isEmpty else {
            #if DEBUG
                restoreExpansionOutcome = "noChange"
            #endif
            return
        }

        let chunkSize = 500
        let foldersByFullPath = fileHierarchyIndex.foldersByFullPath

        isApplyingExpansionState = true
        defer { isApplyingExpansionState = false }

        var didChange = false
        let collapseList = Array(toCollapse)
        if !collapseList.isEmpty {
            var index = 0
            while index < collapseList.count {
                guard !Task.isCancelled else {
                    #if DEBUG
                        restoreExpansionOutcome = "cancelled"
                    #endif
                    return
                }
                let end = min(index + chunkSize, collapseList.count)
                for path in collapseList[index ..< end] {
                    if let folder = foldersByFullPath[path], folder.isExpanded {
                        folder.setExpanded(false)
                        didChange = true
                    }
                }
                index = end
                await Task.yield()
            }
        }

        let expandList = Array(toExpand)
        if !expandList.isEmpty {
            var index = 0
            while index < expandList.count {
                guard !Task.isCancelled else {
                    #if DEBUG
                        restoreExpansionOutcome = "cancelled"
                    #endif
                    return
                }
                let end = min(index + chunkSize, expandList.count)
                for path in expandList[index ..< end] {
                    if let folder = foldersByFullPath[path] {
                        if expandParentChain(of: folder) {
                            didChange = true
                        }
                    }
                }
                index = end
                await Task.yield()
            }
        }

        #if DEBUG
            restoreExpansionDidChange = didChange
        #endif
        if didChange {
            workspaceManager?.markWorkspaceDirty()
        }
    }

    /// Helper method to ensure all parent folders are expanded
    private func expandParentChain(of folder: FolderViewModel) -> Bool {
        var didChange = false
        var current: FolderViewModel? = folder
        var seen = Set<UUID>()
        while let parentFolder = current, seen.insert(parentFolder.id).inserted {
            if !parentFolder.isExpanded {
                parentFolder.setExpanded(true)
                didChange = true
            }
            current = parentFolder.parent
        }
        return didChange
    }

    /// Attaches a lightweight root shell for an already-loaded store root without materializing descendants.
    /// The shell identity tracks `WorkspaceRootRecord.id`; persisted UI state remains keyed by
    /// workspace/path/kind through `rootShellPersistenceKeysByRootKey` and existing path-based state.
    @MainActor
    @discardableResult
    func attachRootShell(for rootRecord: WorkspaceRootRecord, workspaceID: UUID?) throws -> FolderViewModel {
        try attachRootShellInternal(for: rootRecord, workspaceID: workspaceID, notifyRootChange: true).folder
    }

    @MainActor
    private func attachRootShellInternal(
        for rootRecord: WorkspaceRootRecord,
        workspaceID: UUID?,
        notifyRootChange: Bool
    ) throws -> RootShellAttachment {
        let rootKey = rootKey(forPath: rootRecord.standardizedFullPath)
        if let existing = rootFolders.first(where: { $0.standardizedFullPath == rootKey }) {
            guard existing.id == rootRecord.id else {
                throw WorkspaceRootShellError.conflictingRootShell(
                    path: rootKey,
                    existingID: existing.id,
                    incomingID: rootRecord.id
                )
            }
            workspaceFileContextRootsByRootKey[rootKey] = rootRecord
            commitRootShellPersistenceKey(rootRecord: rootRecord, workspaceID: workspaceID, rootKey: rootKey)
            if preloadedWorkspaceFileContextRootsByRootKey[rootKey]?.id == rootRecord.id {
                preloadedWorkspaceFileContextRootsByRootKey.removeValue(forKey: rootKey)
            }
            rootShellLoadedPaths.insert(rootKey)
            fileHierarchyIndex.insertFolder(existing, rootKey: rootKey)
            registerExpansionTracking(for: existing)
            invalidateStaticSnapshot(forRootFullPath: rootKey)
            return RootShellAttachment(folder: existing, didAppend: false)
        }

        let rootFolder = Folder(
            id: rootRecord.id,
            name: rootRecord.name,
            path: rootRecord.fullPath,
            modificationDate: Date()
        )
        let sortOverride: SortMethod? = rootRecord.kind == .workspaceGitData ? .dateNewest : nil
        let rootFolderVM = FolderViewModel(
            folder: rootFolder,
            rootPath: rootRecord.fullPath,
            isExpanded: true,
            sortMethod: currentSortMethod,
            sortMethodOverride: sortOverride,
            isSystemRoot: rootRecord.isSystemRoot
        )

        rootFolders.append(rootFolderVM)
        workspaceFileContextRootsByRootKey[rootKey] = rootRecord
        commitRootShellPersistenceKey(rootRecord: rootRecord, workspaceID: workspaceID, rootKey: rootKey)
        if preloadedWorkspaceFileContextRootsByRootKey[rootKey]?.id == rootRecord.id {
            preloadedWorkspaceFileContextRootsByRootKey.removeValue(forKey: rootKey)
        }
        rootShellLoadedPaths.insert(rootKey)
        fileHierarchyIndex.insertFolder(rootFolderVM, rootKey: rootKey)
        registerExpansionTracking(for: rootFolderVM)
        invalidateStaticSnapshot(forRootFullPath: rootKey)
        if let workspaceID {
            currentWorkspaceID = workspaceID
        }
        if notifyRootChange {
            onRootFoldersChanged?()
        }
        return RootShellAttachment(folder: rootFolderVM, didAppend: true)
    }

    @MainActor
    private func commitRootShellPersistenceKey(
        rootRecord: WorkspaceRootRecord,
        workspaceID: UUID?,
        rootKey: RootKey
    ) {
        rootShellPersistenceKeysByRootKey[rootKey] = WorkspaceRootShellPersistenceKey(
            workspaceID: workspaceID,
            standardizedRootPath: rootKey,
            kind: rootRecord.kind
        )
    }

    /// Detaches only the root shell/projection state. Store unloading is optional so later workspace
    /// switch code can separate UI shell lifecycle from catalog ownership.
    @MainActor
    @discardableResult
    func detachRootShell(forRootPath path: String, unloadStoreRoot: Bool = true) async -> Bool {
        let rootKey = rootKey(forPath: path)
        guard let folder = rootFolders.first(where: { $0.standardizedFullPath == rootKey }) else { return false }
        let detachedRoot = detachRootShellReferences(folder)
        if unloadStoreRoot {
            invalidateRootLoadToken(forRootKey: rootKey)
            _ = advanceRootReplayIngressGeneration(forRootKey: rootKey)
            await workspaceFileContextStore.unregisterDeferredReplayRootGeneration(forRootKey: rootKey)
            if let detachedRoot {
                await workspaceFileContextStore.unloadRoot(id: detachedRoot.id)
            }
        }
        return true
    }

    @MainActor
    private func detachRootShellReferences(_ folder: FolderViewModel) -> WorkspaceRootRecord? {
        let stdRoot = folder.standardizedFullPath
        let rootKey = rootKey(forPath: folder.fullPath)
        appliedIndexProjectionHandledGenerationByRootID.removeValue(forKey: folder.id)
        removeDeferredInitialRootLoadScanRoot(stdRoot)
        unregisterExpansionTracking(for: folder)
        dropSelections(underFolderFullPath: folder.fullPath)
        normalizeSelectionState()
        removeRootFolderReferences(folder)
        rootFolders.removeAll { $0.id == folder.id }
        rootShellLoadedPaths.remove(stdRoot)
        rootShellLoadedPaths.remove(rootKey)
        rootShellPersistenceKeysByRootKey.removeValue(forKey: rootKey)
        let detachedRoot: WorkspaceRootRecord? = if workspaceFileContextRootsByRootKey[rootKey]?.id == folder.id {
            workspaceFileContextRootsByRootKey.removeValue(forKey: rootKey)
        } else {
            nil
        }
        if preloadedWorkspaceFileContextRootsByRootKey[rootKey]?.id == folder.id {
            preloadedWorkspaceFileContextRootsByRootKey.removeValue(forKey: rootKey)
        }
        invalidateStaticSnapshot(forRootFullPath: stdRoot)
        removeHierarchyGenerationEntry(forRootFullPath: stdRoot)
        onRootFoldersChanged?()
        if rootFolders.isEmpty {
            allFoldersUnloadedPublisher.send(())
        }
        return detachedRoot
    }

    @MainActor
    private func resetRootShellToUnmaterializedProjection(_ folder: FolderViewModel) {
        let rootKey = rootKey(forPath: folder.fullPath)
        unregisterExpansionTracking(for: folder)
        removeRootFolderReferences(folder)
        folder.setChildren([])
        fileHierarchyIndex.insertFolder(folder, rootKey: rootKey)
        registerExpansionTracking(for: folder)
        invalidateStaticSnapshot(forRootFullPath: folder.standardizedFullPath)
        onRootFoldersChanged?()
    }

    /// When refreshRootFolderStateAfterLoad is false, the caller must perform a later
    /// refreshRootFolderState() after any restored selection state has been applied.
    @MainActor
    func loadFolder(
        at url: URL,
        for workspace: WorkspaceModel,
        freshStart: Bool = false,
        rootKind: RootKind = .user,
        refreshRootFolderStateAfterLoad: Bool = true
    ) async throws {
        // Use stable string key for root/service mirrors (avoids URL key instability)
        let rootKey = rootKey(forPath: url.path)
        #if DEBUG
            let loadFolderTotalStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            let restorePerfRootKind = restorePerfRootKindName(rootKind)
            let restorePerfRootName = url.lastPathComponent
        #endif

        if freshStart {
            await unloadAllRootFolders()
        }

        workspaceFilesDebugLog("Loading folder root shell (async): \(url.path)")
        isLoading = true

        let hadRootShellBeforeLoad = isFolderAlreadyLoaded(url)
        if hadRootShellBeforeLoad {
            workspaceFilesDebugLog("Root shell already loaded: \(url.path)")
            isLoading = false
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "folderLoad.total",
                    fields: [
                        "workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
                        "rootKind": restorePerfRootKind,
                        "rootName": restorePerfRootName,
                        "outcome": "alreadyLoaded",
                        "duration": loadFolderTotalStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            return
        }

        let loadToken = beginRootLoadToken(forRootKey: rootKey)
        let loadTaskID = UUID()
        let loadRootPath = url.path
        currentFolderLoadingTaskID = loadTaskID

        let loadTask = Task {
            let rootPath = url.path
            let stdRootPath = (rootPath as NSString).standardizingPath
            var loadedWorkspaceRootRecord: WorkspaceRootRecord?
            var appendedRootFolder: FolderViewModel?
            var attachedRootFolder: FolderViewModel?
            do {
                try validateRootLoadToken(loadToken)
                self.currentWorkspaceID = workspace.id
                await workspaceFileContextStore.clearDeferredReplayRoot(rootKey)
                try validateRootLoadToken(loadToken)

                #if DEBUG
                    let storeLoadStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
                #endif
                let workspaceRootRecord = try await workspaceFileContextStore.loadRoot(
                    path: rootPath,
                    isSystemRoot: rootKind == .supplementalSystem,
                    kind: workspaceRootKind(for: rootKind, url: url),
                    respectGitignore: self.respectGitignore,
                    respectRepoIgnore: self.respectRepoIgnore,
                    respectCursorignore: self.respectCursorignore,
                    skipSymlinks: self.skipSymlinks,
                    enableHierarchicalIgnores: self.enableHierarchicalIgnores,
                    cancelUnderlyingLoadOnCallerCancellation: true
                )
                #if DEBUG
                    WorkspaceRestorePerfLog.event(
                        "folderLoad.storeLoad",
                        fields: [
                            "workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
                            "rootKind": restorePerfRootKind,
                            "rootName": restorePerfRootName,
                            "rootID": WorkspaceRestorePerfLog.shortID(workspaceRootRecord.id),
                            "wasPreloadedCandidate": "\(preloadedWorkspaceFileContextRootsByRootKey[rootKey] != nil)",
                            "outcome": "success",
                            "duration": storeLoadStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                        ]
                    )
                #endif
                loadedWorkspaceRootRecord = workspaceRootRecord
                try validateRootLoadToken(loadToken)

                #if DEBUG
                    let rootVMInitStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
                #endif
                let rootShellAttachment = try attachRootShellInternal(
                    for: workspaceRootRecord,
                    workspaceID: workspace.id,
                    notifyRootChange: false
                )
                let rootFolderVM = rootShellAttachment.folder
                attachedRootFolder = rootFolderVM
                if rootShellAttachment.didAppend {
                    folderBeingAdded = rootFolderVM
                    appendedRootFolder = rootFolderVM
                }
                #if DEBUG
                    WorkspaceRestorePerfLog.event(
                        "folderLoad.rootShellAttach",
                        fields: [
                            "workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
                            "rootKind": restorePerfRootKind,
                            "rootName": restorePerfRootName,
                            "duration": rootVMInitStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                        ]
                    )
                    if let rootLoadDidAttachRootShellHandler {
                        await rootLoadDidAttachRootShellHandler(stdRootPath, workspaceRootRecord.id)
                    }
                #endif
                try validateRootLoadToken(loadToken)

                if rootKind == .user {
                    reorderRootFolders(to: workspace.repoPaths)
                }
                try validateRootLoadToken(loadToken)
                rootShellLoadedPaths.insert(stdRootPath)
                invalidateStaticSnapshot(forRootFullPath: rootFolderVM.standardizedFullPath)

                try await performPostCatalogRootWork(
                    for: workspaceRootRecord,
                    workspace: workspace,
                    rootKind: rootKind
                )
                try validateRootLoadToken(loadToken)

                if refreshRootFolderStateAfterLoad {
                    refreshRootFolderState()
                }

                isLoading = false
                folderBeingAdded = nil
                folderDidFinishLoadingPublisher.send(rootFolderVM)
                #if DEBUG
                    WorkspaceRestorePerfLog.event(
                        "folderLoad.total",
                        fields: [
                            "workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
                            "rootKind": restorePerfRootKind,
                            "rootName": restorePerfRootName,
                            "outcome": "success",
                            "duration": loadFolderTotalStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                        ]
                    )
                #endif
            } catch {
                let tokenIsCurrent = isRootLoadTokenCurrent(loadToken)
                let loadedRootIsCurrent = loadedWorkspaceRootRecord.map {
                    workspaceFileContextRootsByRootKey[rootKey]?.id == $0.id
                } ?? false
                let shouldRetainLoadedRoot = error is FileSystemWatcherActivationError
                    && tokenIsCurrent
                    && loadedRootIsCurrent
                    && attachedRootFolder != nil
                if shouldRetainLoadedRoot, let attachedRootFolder {
                    if refreshRootFolderStateAfterLoad {
                        refreshRootFolderState()
                    }
                    isLoading = false
                    folderBeingAdded = nil
                    folderDidFinishLoadingPublisher.send(attachedRootFolder)
                    #if DEBUG
                        WorkspaceRestorePerfLog.event(
                            "folderLoad.total",
                            fields: [
                                "workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
                                "rootKind": restorePerfRootKind,
                                "rootName": restorePerfRootName,
                                "outcome": "watcherErrorRetained",
                                "duration": loadFolderTotalStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                            ]
                        )
                    #endif
                    print("Loaded folder without active watcher: \(error)")
                    self.error = .failedToLoadFolder(error)
                    throw error
                }

                let lifecycleIsCurrent = rootLoadLifecycleGeneration == loadToken.lifecycleGeneration
                let currentRootGeneration = rootLoadGenerationByRootKey[rootKey]
                let hasNewerRootLoadForKey = if lifecycleIsCurrent {
                    currentRootGeneration != nil && currentRootGeneration != loadToken.rootGeneration
                } else {
                    currentRootGeneration != nil
                }
                let canCleanSharedRootState = tokenIsCurrent || !hasNewerRootLoadForKey
                let loadOwnsRootShell = appendedRootFolder != nil || !hadRootShellBeforeLoad
                if canCleanSharedRootState {
                    await workspaceFileContextStore.cancelRootLoad(path: rootPath)
                    removeDeferredInitialRootLoadScanRoot(stdRootPath)
                }
                if let loadedWorkspaceRootRecord {
                    if canCleanSharedRootState, loadOwnsRootShell {
                        if workspaceFileContextRootsByRootKey[rootKey]?.id == loadedWorkspaceRootRecord.id {
                            workspaceFileContextRootsByRootKey.removeValue(forKey: rootKey)
                        }
                        if preloadedWorkspaceFileContextRootsByRootKey[rootKey]?.id == loadedWorkspaceRootRecord.id {
                            preloadedWorkspaceFileContextRootsByRootKey.removeValue(forKey: rootKey)
                        }
                        rootShellPersistenceKeysByRootKey.removeValue(forKey: rootKey)
                        await workspaceFileContextStore.unloadRoot(id: loadedWorkspaceRootRecord.id)
                    }
                } else if canCleanSharedRootState, loadOwnsRootShell, let workspaceRoot = workspaceFileContextRootsByRootKey.removeValue(forKey: rootKey) {
                    rootShellPersistenceKeysByRootKey.removeValue(forKey: rootKey)
                    await workspaceFileContextStore.unloadRoot(id: workspaceRoot.id)
                }
                if canCleanSharedRootState {
                    await workspaceFileContextStore.unregisterDeferredReplayRootGeneration(forRootKey: rootKey)
                    self.currentSlicesByRoot.removeValue(forKey: stdRootPath)
                    self.requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")
                }

                if let appendedRootFolder {
                    removePartiallyLoadedRoot(
                        appendedRootFolder,
                        notifyWorkspaceManager: false,
                        cleanupSharedRootState: canCleanSharedRootState
                    )
                } else if let attachedRootFolder, !loadOwnsRootShell {
                    resetRootShellToUnmaterializedProjection(attachedRootFolder)
                } else if canCleanSharedRootState {
                    removeFolderBeingAdded()
                }

                #if DEBUG
                    WorkspaceRestorePerfLog.event(
                        "folderLoad.total",
                        fields: [
                            "workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
                            "rootKind": restorePerfRootKind,
                            "rootName": restorePerfRootName,
                            "outcome": error is CancellationError ? "cancelled" : "error",
                            "duration": loadFolderTotalStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                        ]
                    )
                #endif
                if error is CancellationError {
                    print("Load folder cancelled for: \(url.path)")
                } else {
                    print("Failed to load folder: \(error)")
                    self.error = .failedToLoadFolder(error)
                }
                isLoading = false
                throw error
            }
        }
        currentFolderLoadingTask = loadTask

        defer {
            if currentFolderLoadingTaskID == loadTaskID {
                currentFolderLoadingTask = nil
                currentFolderLoadingTaskID = nil
            }
        }
        try await withTaskCancellationHandler {
            try await loadTask.value
        } onCancel: {
            Task { @MainActor in
                guard self.isRootLoadTokenCurrent(loadToken) else { return }
                loadTask.cancel()
                if self.currentFolderLoadingTaskID == loadTaskID {
                    self.currentFolderLoadingTask?.cancel()
                }
                await self.workspaceFileContextStore.cancelRootLoad(path: loadRootPath)
            }
        }
    }

    func onAllFoldersLoaded() async {
        await rescanAllFilesIfLoaded()
    }

    @MainActor
    func performPostCatalogRootWork(
        for rootRecord: WorkspaceRootRecord,
        workspace: WorkspaceModel,
        rootKind: RootKind
    ) async throws {
        let rootKey = rootKey(forPath: rootRecord.standardizedFullPath)
        guard workspaceFileContextRootsByRootKey[rootKey]?.id == rootRecord.id else { return }
        currentWorkspaceID = workspace.id

        let rootReplayIngressGeneration = advanceRootReplayIngressGeneration(forRootKey: rootKey)
        await workspaceFileContextStore.registerDeferredReplayRootGeneration(rootReplayIngressGeneration, forRootKey: rootKey)
        // A watcher activation failure must still be surfaced to the caller, but it must not
        // skip persisted selection-slice hydration or codemap kickoff for an otherwise loaded
        // root, so the throw is deferred until the remaining post-catalog work completes.
        var deferredWatcherStartError: Error?
        do {
            try await workspaceFileContextStore.startWatchingRoot(id: rootRecord.id)
        } catch {
            if error is CancellationError { throw error }
            deferredWatcherStartError = error
        }
        guard workspaceFileContextRootsByRootKey[rootKey]?.id == rootRecord.id else { return }

        let partitionData = await selectionSliceCoordinator.loadSlices(
            forRootPath: rootRecord.standardizedFullPath,
            scope: PartitionScope(workspaceID: workspace.id, tabID: currentTabID)
        )
        guard workspaceFileContextRootsByRootKey[rootKey]?.id == rootRecord.id else { return }
        if partitionData.isEmpty {
            currentSlicesByRoot.removeValue(forKey: rootRecord.standardizedFullPath)
        } else {
            currentSlicesByRoot[rootRecord.standardizedFullPath] = partitionData
        }
        requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")

        if codeScanEnabled, rootKind == .user {
            if isInitialRootLoadScanDeferralActive {
                deferredInitialRootLoadScanRoots.insert(rootRecord.standardizedFullPath)
            } else {
                enqueueInitialRootLoadRequests(
                    rootRecords: [rootRecord],
                    purgeCachesOnEmptyInitialRequests: true
                )
            }
        }

        if let deferredWatcherStartError {
            throw deferredWatcherStartError
        }
    }

    @MainActor
    func registerPreloadedWorkspaceRoot(_ root: WorkspaceRootRecord) {
        let rootKey = root.standardizedFullPath
        guard workspaceFileContextRootsByRootKey[rootKey]?.id != root.id else { return }
        preloadedWorkspaceFileContextRootsByRootKey[rootKey] = root
    }

    @MainActor
    func unloadUncommittedPreloadedWorkspaceRoots() async {
        let roots = Array(preloadedWorkspaceFileContextRootsByRootKey.values)
        preloadedWorkspaceFileContextRootsByRootKey.removeAll()
        await workspaceFileContextStore.unloadRoots(ids: roots.map(\.id))
    }

    @MainActor
    func loadSupplementalRoot(
        at url: URL,
        for workspace: WorkspaceModel,
        refreshRootFolderStateAfterLoad: Bool = true
    ) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        try await loadFolder(
            at: url,
            for: workspace,
            freshStart: false,
            rootKind: .supplementalSystem,
            refreshRootFolderStateAfterLoad: refreshRootFolderStateAfterLoad
        )
    }

    @MainActor
    func ensureGitDataRootLoaded(
        workspace: WorkspaceModel,
        workspaceManager: WorkspaceManagerViewModel,
        refreshRootFolderStateAfterLoad: Bool = true
    ) async {
        guard workspace.isSystemWorkspace == false else {
            return
        }
        let gitDataURL = workspaceManager.gitDataDirectory(for: workspace)
        if isFolderAlreadyLoaded(gitDataURL) {
            return
        }
        do {
            try await loadSupplementalRoot(
                at: gitDataURL,
                for: workspace,
                refreshRootFolderStateAfterLoad: refreshRootFolderStateAfterLoad
            )
        } catch {
            print("Failed to load _git_data root: \(error)")
        }
    }

    private func removeFolderBeingAdded() {
        if let folder = folderBeingAdded {
            removePartiallyLoadedRoot(folder, notifyWorkspaceManager: true)
        }
    }

    private func removePartiallyLoadedRoot(
        _ folder: FolderViewModel,
        notifyWorkspaceManager: Bool,
        cleanupSharedRootState: Bool = true
    ) {
        let stdPath = folder.standardizedFullPath
        if cleanupSharedRootState {
            removeDeferredInitialRootLoadScanRoot(stdPath)
        }
        unregisterExpansionTracking(for: folder)
        if cleanupSharedRootState {
            removeRootFolderReferences(folder)
        }
        // Remove only this captured partial VM. A newer same-path load can reuse the
        // stable store root ID, so ID-based removal can detach the new owner.
        rootFolders.removeAll { $0 === folder }
        if let currentFolderBeingAdded = folderBeingAdded, currentFolderBeingAdded === folder {
            folderBeingAdded = nil
        }
        if notifyWorkspaceManager {
            // Notify WorkspaceManager so it drops the path from the workspace model
            // and persists the change. This prevents a user-cancelled folder from
            // re-appearing on next launch / save.
            let folderPath = folder.fullPath
            let manager = workspaceManager
            Task { [weak manager] in
                await manager?.removeActiveWorkspaceRoot(path: folderPath)
            }
        }

        if cleanupSharedRootState {
            // Remove the root from the absolute-path index to avoid stale entries
            fileHierarchyIndex.removeFolder(forKey: stdPath, expectedRootKey: stdPath)
            let rootKey = rootKey(forPath: folder.fullPath)
            rootShellPersistenceKeysByRootKey.removeValue(forKey: rootKey)
            if workspaceFileContextRootsByRootKey[rootKey]?.id == folder.id {
                workspaceFileContextRootsByRootKey.removeValue(forKey: rootKey)
            }
            if preloadedWorkspaceFileContextRootsByRootKey[rootKey]?.id == folder.id {
                preloadedWorkspaceFileContextRootsByRootKey.removeValue(forKey: rootKey)
            }
            rootShellLoadedPaths.remove(stdPath)

            // Clean up per-root generation entry and invalidate snapshot
            removeHierarchyGenerationEntry(forRootFullPath: stdPath)
        }
        invalidateStaticSnapshot(forRootFullPath: nil)
    }

    private func unloadRootFolder(for url: URL) async {
        let standardizedPath = (url.path as NSString).standardizingPath
        guard let folder = rootFolders.first(where: { $0.standardizedFullPath == standardizedPath }) else {
            return
        }
        await unloadRootFolder(folder)
    }

    /*
     @MainActor
     public func fullRefresh() async {
     	self.error = nil
     	let rootURLs = self.rootFolders.map { URL(fileURLWithPath: $0.fullPath) }

     	for url in rootURLs {
     		await self.unloadRootFolder(for: url)
     	}

     	for url in rootURLs {
     		try? await self.loadFolder(at: url, for: nil, freshStart: false)
     	}

     	//self.refreshRootFolderState()
     	self.onRootFoldersChanged?()
     }
     */

    /// Place this property along with other publishers near the top of the class
    var onRequestRefresh: (() -> Void)?

    func requestRefresh() {
        onRequestRefresh?()
    }

    @MainActor
    func requestFileSystemSettingsRefresh() {
        forceReloadOnNextFileSystemSettingsRefresh = true
        requestRefresh()
    }

    @discardableResult
    func refreshContents(model: WorkspaceModel, forceRefresh: Bool = false) async -> Bool {
        error = nil
        var didStructurallyRefreshRoots = false

        let forceReloadForSettings = forceReloadOnNextFileSystemSettingsRefresh
        forceReloadOnNextFileSystemSettingsRefresh = false

        // Iterate in deterministic order: user roots (in rootFolders order) then system roots
        // This prevents non-deterministic ordering from dictionary iteration
        let orderedRoots = rootFolders.filter { !$0.isSystemRoot } + rootFolders.filter(\.isSystemRoot)

        for rootFolder in orderedRoots {
            let rootKey = rootKey(forPath: rootFolder.fullPath)
            let workspaceRoot = workspaceFileContextRootsByRootKey[rootKey]

            do {
                let shouldForceReload = forceRefresh || forceReloadForSettings
                if shouldForceReload {
                    didStructurallyRefreshRoots = true
                    let rootKind: RootKind = rootFolder.isSystemRoot ? .supplementalSystem : .user
                    let rootURL = URL(fileURLWithPath: rootFolder.fullPath)
                    await unloadRootFolder(for: rootURL)
                    try await loadFolder(at: rootURL, for: model, freshStart: false, rootKind: rootKind)
                    continue
                }

                var ignoreRulesChanged = false
                if let workspaceRoot {
                    let storeIgnoreRulesChanged = try await workspaceFileContextStore.refreshFileSystemSettings(
                        rootID: workspaceRoot.id,
                        respectGitignore: respectGitignore,
                        respectRepoIgnore: respectRepoIgnore,
                        respectCursorignore: respectCursorignore,
                        skipSymlinks: skipSymlinks,
                        enableHierarchicalIgnores: enableHierarchicalIgnores
                    )
                    ignoreRulesChanged = ignoreRulesChanged || storeIgnoreRulesChanged
                }

                if ignoreRulesChanged {
                    didStructurallyRefreshRoots = true
                    let rootKind: RootKind = rootFolder.isSystemRoot ? .supplementalSystem : .user
                    let rootURL = URL(fileURLWithPath: rootFolder.fullPath)
                    await unloadRootFolder(for: rootURL)
                    try await loadFolder(at: rootURL, for: model, freshStart: false, rootKind: rootKind)
                }
            } catch {
                print("Error updating workspace file-system settings: \(error)")
            }
        }

        // Keep UI and internal order in sync with the workspace config.
        let didReorderRoots = reorderRootFolders(to: model.repoPaths)

        // If this refresh genuinely unloaded/reloaded roots, emit one final broad
        // invalidation after the in-place work settles. Pure soft refreshes and
        if didStructurallyRefreshRoots && !didReorderRoots {
            onRootFoldersChanged?()
        }
        await rescanAllFilesIfLoaded()
        return didStructurallyRefreshRoots || didReorderRoots
    }

    // ------------------------------------------------------------------
    // MARK: Mention support

    /// ------------------------------------------------------------------
    /// Toggles selection for a file or *entire* folder by relative path.
    /// Called by the "@-mention" text editor when a token is committed.
    @MainActor
    func togglePath(_ relativePath: String) {
        if let file = findFileByRelativePath(relativePath) {
            toggleFile(file, fromSearch: true)
            refreshRootFolderState()
            return
        }
        if let folder = findFolderByRelativePath(relativePath) {
            folder.forceCheckRecursive()
            refreshRootFolderState()
        }
    }

    // ------------------------------------------------------------------
    // MARK: Explicit helpers for mention tokens (add / remove)

    /// ------------------------------------------------------------------
    /// Ensures the given path is **selected/checked**.
    /// If it is already selected nothing happens.
    @MainActor
    func selectPath(_ relativePath: String, kind: MentionKind?) {
        let normalizedPath = normalizeUserInputPath(relativePath)
        let standardizedPath = (normalizedPath as NSString).standardizingPath
        let isAbsolute = standardizedPath.hasPrefix("/")

        // Resolve candidate VMs depending on path kind
        let fileVM: FileViewModel? = isAbsolute
            ? findFileByFullPath(standardizedPath)
            : findFileByRelativePath(standardizedPath)
        let folderVM: FolderViewModel? = isAbsolute
            ? findFolderByFullPath(standardizedPath)
            : findFolderByRelativePath(standardizedPath)

        // 1️⃣ Explicit kind supplied ------------------------------------------------
        if let kind {
            switch kind {
            case .folder:
                if let folder = folderVM, folder.checkboxState != .checked {
                    folder.forceCheckRecursive()
                    refreshRootFolderState()
                }
                return
            case .file:
                if let file = fileVM, !file.isChecked {
                    setFileToggled(file, isToggled: true)
                    refreshRootFolderState()
                }
                return
            case .skill:
                return
            }
        }

        // 2️⃣ Kind not supplied – best-effort inference -----------------------------
        if let file = fileVM, !file.isChecked {
            setFileToggled(file, isToggled: true)
            refreshRootFolderState()
        } else if let folder = folderVM, folder.checkboxState != .checked {
            folder.forceCheckRecursive()
            refreshRootFolderState()
        }
    }

    /// Removes the selection for the given path when it is currently selected.
    @MainActor
    func deselectPath(_ relativePath: String, kind: MentionKind?) {
        let normalizedPath = normalizeUserInputPath(relativePath)
        let standardizedPath = (normalizedPath as NSString).standardizingPath
        let isAbsolute = standardizedPath.hasPrefix("/")

        let fileVM: FileViewModel? = isAbsolute
            ? findFileByFullPath(standardizedPath)
            : findFileByRelativePath(standardizedPath)
        let folderVM: FolderViewModel? = isAbsolute
            ? findFolderByFullPath(standardizedPath)
            : findFolderByRelativePath(standardizedPath)

        // 1️⃣ Explicit kind supplied ------------------------------------------------
        if let kind {
            switch kind {
            case .folder:
                if let folder = folderVM, folder.checkboxState != .unchecked {
                    setFolderStateOnSubtree(folder, newState: .unchecked)
                    refreshRootFolderState()
                }
                return
            case .file:
                if let file = fileVM, file.isChecked {
                    setFileToggled(file, isToggled: false)
                    refreshRootFolderState()
                }
                return
            case .skill:
                return
            }
        }

        // 2️⃣ Kind not supplied – inference ----------------------------------------
        if let file = fileVM, file.isChecked {
            setFileToggled(file, isToggled: false)
            refreshRootFolderState()
        } else if let folder = folderVM, folder.checkboxState != .unchecked {
            setFolderStateOnSubtree(folder, newState: .unchecked)
            refreshRootFolderState()
        }
    }

    /// Rebuilds the UI projection index *only* for the given root folder: removes old references,
    /// then re-walks the already-materialized UI tree to add fresh entries.
    ///
    /// This is not a canonical workspace index rebuild; `WorkspaceFileContextStore` owns that.
    /// Keep calls exceptional: root load/unload, store applied-index recovery/resync, or local
    /// UI projection repair after incremental child identity-preserving updates.
    @MainActor
    private func rebuildFileHierarchyIndex(for rootFolder: FolderViewModel) {
        let signpost = RepoFileReplayPerf.begin("rebuildFileHierarchyIndex")
        defer { RepoFileReplayPerf.end("rebuildFileHierarchyIndex", signpost) }
        let rootKey = rootFolder.standardizedFullPath
        #if DEBUG
            let totalStartMS = debugPerfTimestampMS()
            let totalFolderKeysBefore = fileHierarchyIndex.foldersByFullPath.count
            let totalFileKeysBefore = fileHierarchyIndex.filesByFullPath.count
            let ownedFolderKeysBefore = fileHierarchyIndex.folderPathsByRoot[rootKey]?.count ?? 0
            let ownedFileKeysBefore = fileHierarchyIndex.filePathsByRoot[rootKey]?.count ?? 0

            let candidateStartMS = debugPerfTimestampMS()
        #endif
        let cleanup = rootReferenceCleanupPlan(for: rootFolder)
        #if DEBUG
            let cleanupCandidateSelectionDurationMS = debugPerfElapsedMS(since: candidateStartMS)
            let fileRemovalStartMS = debugPerfTimestampMS()
        #endif
        #if DEBUG
            let cleanupFileRemovalDurationMS = debugPerfElapsedMS(since: fileRemovalStartMS)

            let folderRemovalStartMS = debugPerfTimestampMS()
        #endif
        fileHierarchyIndex.removeOwnedEntries(
            forRootKey: cleanup.rootKey,
            folderPaths: cleanup.folderPaths,
            filePaths: cleanup.filePaths
        )
        #if DEBUG
            let cleanupFolderRemovalDurationMS = debugPerfElapsedMS(since: folderRemovalStartMS)

            var stats = ReindexTraversalStats()
            let traversalStartMS = debugPerfTimestampMS()
            reindexFolderRecursively(rootFolder, into: &fileHierarchyIndex, rootKey: rootKey, stats: &stats)
            let reindexTraversalDurationMS = debugPerfElapsedMS(since: traversalStartMS)

            let totalDurationMS = debugPerfElapsedMS(since: totalStartMS)
            appliedIndexProjectionIndexRebuildCount += 1
            appliedIndexProjectionIndexRebuildTotalDurationMS += totalDurationMS
            appliedIndexProjectionIndexRebuildTraversalDurationMS += reindexTraversalDurationMS
            appliedIndexProjectionIndexRebuildVisitedFolderCount += stats.visitedFolderCount
            appliedIndexProjectionIndexRebuildVisitedFileCount += stats.visitedFileCount
            lastIndexRebuildPerfSample = IndexRebuildPerfSample(
                rootKey: rootKey,
                totalFolderKeysBefore: totalFolderKeysBefore,
                totalFileKeysBefore: totalFileKeysBefore,
                ownedFolderKeysBefore: ownedFolderKeysBefore,
                ownedFileKeysBefore: ownedFileKeysBefore,
                cleanupCandidateFolderKeys: cleanup.folderPaths.count,
                cleanupCandidateFileKeys: cleanup.filePaths.count,
                usedOwnershipFallback: cleanup.usedFallbackGlobalScan,
                cleanupCandidateSelectionDurationMS: cleanupCandidateSelectionDurationMS,
                cleanupFolderRemovalDurationMS: cleanupFolderRemovalDurationMS,
                cleanupFileRemovalDurationMS: cleanupFileRemovalDurationMS,
                reindexTraversalDurationMS: reindexTraversalDurationMS,
                reindexVisitedFolderCount: stats.visitedFolderCount,
                reindexVisitedFileCount: stats.visitedFileCount,
                totalDurationMS: totalDurationMS
            )
        #else
            reindexFolderRecursively(rootFolder, into: &fileHierarchyIndex, rootKey: rootKey)
        #endif
    }

    #if DEBUG
        private struct ReindexTraversalStats {
            var visitedFolderCount: Int = 0
            var visitedFileCount: Int = 0
        }

        /// Recursively inserts folder/files into 'fileHierarchyIndex'.
        @MainActor
        private func reindexFolderRecursively(
            _ folder: FolderViewModel,
            into index: inout FileHierarchyIndex,
            rootKey: String,
            stats: inout ReindexTraversalStats
        ) {
            var visitedFolderIDs = Set<UUID>()
            reindexFolderRecursively(
                folder,
                into: &index,
                rootKey: rootKey,
                visitedFolderIDs: &visitedFolderIDs,
                stats: &stats
            )
        }

        @MainActor
        private func reindexFolderRecursively(
            _ folder: FolderViewModel,
            into index: inout FileHierarchyIndex,
            rootKey: String,
            visitedFolderIDs: inout Set<UUID>,
            stats: inout ReindexTraversalStats
        ) {
            guard visitedFolderIDs.insert(folder.id).inserted else { return }
            stats.visitedFolderCount += 1
            index.insertFolder(folder, rootKey: rootKey)

            for child in folder.children {
                switch child {
                case let .folder(subFolder):
                    reindexFolderRecursively(
                        subFolder,
                        into: &index,
                        rootKey: rootKey,
                        visitedFolderIDs: &visitedFolderIDs,
                        stats: &stats
                    )
                case let .file(fileVM):
                    stats.visitedFileCount += 1
                    index.insertFile(fileVM, rootKey: rootKey)
                }
            }
        }
    #else
        @MainActor
        private func reindexFolderRecursively(
            _ folder: FolderViewModel,
            into index: inout FileHierarchyIndex,
            rootKey: String
        ) {
            var visitedFolderIDs = Set<UUID>()
            reindexFolderRecursively(
                folder,
                into: &index,
                rootKey: rootKey,
                visitedFolderIDs: &visitedFolderIDs
            )
        }

        @MainActor
        private func reindexFolderRecursively(
            _ folder: FolderViewModel,
            into index: inout FileHierarchyIndex,
            rootKey: String,
            visitedFolderIDs: inout Set<UUID>
        ) {
            guard visitedFolderIDs.insert(folder.id).inserted else { return }
            index.insertFolder(folder, rootKey: rootKey)

            for child in folder.children {
                switch child {
                case let .folder(subFolder):
                    reindexFolderRecursively(
                        subFolder,
                        into: &index,
                        rootKey: rootKey,
                        visitedFolderIDs: &visitedFolderIDs
                    )
                case let .file(fileVM):
                    index.insertFile(fileVM, rootKey: rootKey)
                }
            }
        }
    #endif

    // MARK: – Delta replay (public entry point)

    @MainActor
    private func applyFileSystemDeltas(
        _ deltas: [FileSystemDelta],
        forRootKey rootKey: RootKey,
        deferIfUnfocused: Bool = true
    ) async {
        guard !deltas.isEmpty else { return }
        if deferIfUnfocused {
            await syncDeferredReplayRoutingState()
            let ingress = await workspaceFileContextStore.ingestDeferredReplayLiveDeltas(
                deltas,
                forRootKey: rootKey
            )
            await handleDeferredReplayIngressResult(ingress)
            return
        }
        let chunkSize: Int
        #if DEBUG
            chunkSize = max(deltaReplayChunkSizeOverride ?? max(deltas.count, 1), 1)
        #else
            chunkSize = max(deltas.count, 1)
        #endif
        let preparedBatch = await deltaReplayPreparationActor.prepare(
            rootKey: rootKey,
            deltas: deltas,
            chunkSize: chunkSize
        )
        await applyPreparedReplayBatch(preparedBatch, passIndex: 0)
    }

    @MainActor
    @discardableResult
    private func applyPreparedReplayBatch(
        _ preparedBatch: PreparedFileSystemReplayBatch,
        passIndex: Int,
        expectedRootGeneration: UInt64? = nil,
        expectedRoutingVersion: UInt64? = nil
    ) async -> Bool {
        guard !preparedBatch.chunks.isEmpty else { return true }
        #if DEBUG
            let totalStartMS = debugPerfTimestampMS()
            var replayedChunks: [RootReplayPerfSample] = []
        #endif
        var accumulator = ReplayRootPassAccumulator(rootKey: preparedBatch.rootKey)
        let chunkCount = preparedBatch.chunks.count
        for (chunkIndex, chunk) in preparedBatch.chunks.enumerated() {
            if let expectedRootGeneration,
               currentRootReplayIngressGeneration(forRootKey: preparedBatch.rootKey) != expectedRootGeneration
            {
                return false
            }
            if let expectedRoutingVersion,
               expectedRoutingVersion != deferredReplayRoutingVersion || !isWindowFocused
            {
                return false
            }
            #if DEBUG
                let applyAwaitStartMS = debugPerfTimestampMS()
            #endif
            await applyPreparedFileSystemDeltas(
                chunk: chunk,
                from: preparedBatch,
                forRootKey: preparedBatch.rootKey,
                accumulator: &accumulator
            )
            #if DEBUG
                let applyAwaitDurationMS = debugPerfElapsedMS(since: applyAwaitStartMS)
                var yieldedAfterChunk = false
                var yieldDurationMS = 0.0
            #endif
            if chunkIndex < chunkCount - 1 {
                #if DEBUG
                    let yieldStartMS = debugPerfTimestampMS()
                #endif
                await Task.yield()
                #if DEBUG
                    yieldedAfterChunk = true
                    yieldDurationMS = debugPerfElapsedMS(since: yieldStartMS)
                #endif
            }
            #if DEBUG
                if var sample = currentRootReplayPerfSample {
                    sample.passIndex = passIndex
                    sample.chunkIndexInPass = chunkIndex
                    sample.chunkCountInPass = chunkCount
                    sample.applyAwaitDurationMS = applyAwaitDurationMS
                    sample.yieldedAfterChunk = yieldedAfterChunk
                    sample.yieldDurationMSAfterChunk = yieldDurationMS
                    replayedChunks.append(sample)
                    currentRootReplayPerfSample = nil
                }
            #endif
        }
        #if DEBUG
            let rootPass = finalizeReplayRootPass(
                accumulator,
                passIndex: passIndex,
                chunkCount: chunkCount
            )
            lastImmediateReplayPerfSample = ImmediateReplayPerfSample(
                rootKey: preparedBatch.rootKey,
                passIndex: passIndex,
                chunkCount: chunkCount,
                totalDeltaCount: preparedBatch.preparedDeltas.count,
                queuedDeltaCount: preparedBatch.queuedDeltaCount,
                coalescedDeltaCount: preparedBatch.coalescedDeltaCount,
                discardedDeltaCount: preparedBatch.discardedDeltaCount,
                replayedChunks: replayedChunks,
                rootPass: rootPass,
                totalDurationMS: debugPerfElapsedMS(since: totalStartMS)
            )
        #else
            _ = finalizeReplayRootPass(
                accumulator,
                passIndex: passIndex,
                chunkCount: chunkCount
            )
        #endif
        return true
    }

    @MainActor
    @discardableResult
    private func advanceDeferredReplayRoutingVersion() -> UInt64 {
        deferredReplayRoutingVersion &+= 1
        return deferredReplayRoutingVersion
    }

    @MainActor
    @discardableResult
    private func advanceRootReplayIngressGeneration(forRootKey rootKey: RootKey) -> UInt64 {
        rootReplayIngressGenerationByRoot[rootKey, default: 0] &+= 1
        return rootReplayIngressGenerationByRoot[rootKey] ?? 0
    }

    @MainActor
    private func currentRootReplayIngressGeneration(forRootKey rootKey: RootKey) -> UInt64? {
        rootReplayIngressGenerationByRoot[rootKey]
    }

    @MainActor
    private func syncDeferredReplayRoutingState() async {
        await workspaceFileContextStore.updateDeferredReplayRoutingState(
            isWindowFocused: isWindowFocused,
            isReplayActive: isReplayingDeltas,
            routingVersion: deferredReplayRoutingVersion
        )
        #if DEBUG
            await workspaceFileContextStore.updateDeferredReplayImmediateChunkSizeOverride(deltaReplayChunkSizeOverride)
        #endif
    }

    @MainActor
    private func handleDeferredReplayIngressResult(
        _ result: DeferredReplayIngressResult
    ) async {
        switch result {
        case let .preparedImmediate(immediate):
            guard currentRootReplayIngressGeneration(forRootKey: immediate.rootKey) == immediate.rootGeneration else {
                await workspaceFileContextStore.finishDeferredReplayPreparedImmediateIngress(immediate)
                return
            }
            guard immediate.routingVersion == deferredReplayRoutingVersion,
                  isWindowFocused,
                  !isReplayingDeltas
            else {
                await workspaceFileContextStore.finishDeferredReplayPreparedImmediateIngress(immediate)
                switch await workspaceFileContextStore.enqueueDeferredReplayDeltas(
                    immediate.sourceDeltas,
                    forRootKey: immediate.rootKey
                ) {
                case .queued, .droppedWhileOverflowed, .droppedStaleGeneration:
                    return
                case let .overflowRequiresRefresh(overflowedRootKey):
                    handleDeferredReplayOverflow(forRootKey: overflowedRootKey)
                case .preparedImmediate:
                    assertionFailure("enqueueDeferredDeltas should not produce prepared immediate work")
                }
                return
            }
            isReplayingDeltas = true
            _ = advanceDeferredReplayRoutingVersion()
            await syncDeferredReplayRoutingState()
            let activeRoutingVersion = deferredReplayRoutingVersion
            let completed = await applyPreparedReplayBatch(
                immediate.preparedBatch,
                passIndex: 0,
                expectedRootGeneration: immediate.rootGeneration,
                expectedRoutingVersion: activeRoutingVersion
            )
            isReplayingDeltas = false
            _ = advanceDeferredReplayRoutingVersion()
            await syncDeferredReplayRoutingState()
            await workspaceFileContextStore.finishDeferredReplayPreparedImmediateIngress(immediate)
            guard completed else {
                handleDeferredReplayOverflow(forRootKey: immediate.rootKey)
                return
            }
            if isWindowFocused,
               !isReplayingDeltas,
               await workspaceFileContextStore.hasDeferredReplayPendingWork()
            {
                await flushPendingDeltas()
            }
        case .queued, .droppedWhileOverflowed, .droppedStaleGeneration:
            return
        case let .overflowRequiresRefresh(overflowedRootKey):
            handleDeferredReplayOverflow(forRootKey: overflowedRootKey)
        }
    }

    @MainActor
    private func handleDeferredReplayOverflow(forRootKey rootKey: RootKey) {
        if Self.isLoggingEnabled {
            print("Δ-queue overflow for root \((rootKey as NSString).lastPathComponent); scheduling full refresh")
        }
        requestRefresh()
    }

    /// Pure delta-handler for already prepared deltas – **never** checks window focus.
    @MainActor
    private func applyPreparedFileSystemDeltas(
        chunk: PreparedFileSystemReplayChunk,
        from batch: PreparedFileSystemReplayBatch,
        forRootKey rootKey: RootKey,
        accumulator: inout ReplayRootPassAccumulator
    ) async {
        let signpost = RepoFileReplayPerf.begin("applyReplayChunk")
        defer { RepoFileReplayPerf.end("applyReplayChunk", signpost) }
        #if DEBUG
            let totalStartMS = debugPerfTimestampMS()
        #endif
        guard let targetRootVM = rootFolders.first(where: { $0.standardizedFullPath == rootKey }) else { return }
        let workspaceRoot = workspaceFileContextRootsByRootKey[rootKey]

        let deltas = batch.preparedDeltas[chunk.range]
        var needsIndexRebuild = false
        var topologyChanged = false
        let shouldFlushPendingInserts = chunk.summary.fileAddedCount > 0
        var dirtyFolderStateStarts: [UUID: FolderViewModel] = [:]
        var requiresFullRootFolderStateRefresh = false
        var batchedCodeScanFiles: [UUID: FileViewModel] = [:]
        var batchedSliceRebases: [String: ReplaySliceRebaseRequest] = [:]
        #if DEBUG
            let fileAddedCount = chunk.summary.fileAddedCount
            let fileRemovedCount = chunk.summary.fileRemovedCount
            let folderAddedCount = chunk.summary.folderAddedCount
            let folderRemovedCount = chunk.summary.folderRemovedCount
            let modifiedCount = chunk.summary.modifiedCount
            var folderModifiedCount = 0
            var folderModifiedCarriedDateCount = 0
            var folderModifiedFallbackStatSuccessCount = 0
            var folderModifiedSkippedNoDateCount = 0
            var removedSubtreeDescendantLookupCount = 0
            currentReplayParentLookupCount = 0
            var deltaLoopDurationMS = 0.0
            var pendingInsertRootCountBeforeFlush = 0
            var pendingInsertEntryCountBeforeFlush = 0
            var pendingInsertEntryCountForReplayedRootBeforeFlush = 0
            var pendingInsertEntryCountRemainingAfterFlush = 0
            var flushPendingInsertsDurationMS = 0.0
            var updateFolderStatesDurationMS = 0.0
            var usedFullRootFolderStateRefresh = false
            var dirtyFolderStateStartCount = 0
            var onRootFoldersChangedDurationMS = 0.0
            var usedIncrementalIndexCleanup = false
            var incrementalIndexCleanupDurationMS = 0.0
            var incrementalRemovedFolderCount = 0
            var incrementalRemovedFileCount = 0
            var incrementalIndexCleanupFallbackToRebuild = false
            var rebuildDurationMS: Double?
            var rebuildCleanupCandidateSelectionDurationMS: Double?
            var rebuildCleanupFolderRemovalDurationMS: Double?
            var rebuildCleanupFileRemovalDurationMS: Double?
            var rebuildTraversalDurationMS: Double?
            var rebuildCleanupCandidateFolderKeys: Int?
            var rebuildCleanupCandidateFileKeys: Int?
            var rebuildUsedOwnershipFallback: Bool?
            var codeScanBatchInvocationCount = 0
            var codeScanBatchFileCount = 0
            var sliceRebaseBatchInvocationCount = 0
            var sliceRebaseCandidateCount = 0
            var invalidateSnapshotDurationMS = 0.0
        #endif

        for transfer in chunk.renameTransfers {
            transferExpandedStateOnRename(
                oldAbs: transfer.oldAbsolutePath,
                newAbs: transfer.newAbsolutePath
            )
        }

        var removedSubtreesForCleanup: [RemovedFolderSubtree] = []
        var removedSubtreeRootPathsForCleanup = Set<String>()

        func flushRemovedSubtreesForCleanup() {
            guard !removedSubtreesForCleanup.isEmpty else { return }
            #if DEBUG
                let incrementalCleanupStartMS = debugPerfTimestampMS()
            #endif
            let cleanupOutcome = performBatchedIncrementalRemovedSubtreeCleanup(
                removedSubtreesForCleanup,
                rootKey: rootKey
            )
            removedSubtreesForCleanup.removeAll(keepingCapacity: true)
            removedSubtreeRootPathsForCleanup.removeAll(keepingCapacity: true)
            #if DEBUG
                usedIncrementalIndexCleanup = true
                incrementalIndexCleanupDurationMS += debugPerfElapsedMS(since: incrementalCleanupStartMS)
                incrementalRemovedFolderCount += cleanupOutcome.removedFolderCount
                incrementalRemovedFileCount += cleanupOutcome.removedFileCount
                removedSubtreeDescendantLookupCount += cleanupOutcome.descendantLookupCount
            #endif
            if !cleanupOutcome.succeeded {
                needsIndexRebuild = true
                #if DEBUG
                    incrementalIndexCleanupFallbackToRebuild = true
                #endif
            }
        }

        func flushRemovedSubtreesForCleanupIfNeeded(beforeAddingPath standardizedPath: String) {
            let matcher = RemovedFolderPathMatcher(removedFolderPaths: removedSubtreeRootPathsForCleanup)
            if matcher.containsPathEqualToOrInsideRemovedFolder(standardizedPath) {
                flushRemovedSubtreesForCleanup()
            }
        }

        func materializeStoreFolderAncestors(for relativePath: String) async {
            guard let rootID = workspaceRoot?.id else { return }
            let parentRel = StandardizedPath.relative((relativePath as NSString).deletingLastPathComponent)
            guard !parentRel.isEmpty else { return }

            var current = ""
            for component in parentRel.split(separator: "/") {
                current = current.isEmpty ? String(component) : "\(current)/\(component)"
                if let record = await workspaceFileContextStore.folder(rootID: rootID, relativePath: current) {
                    _ = handleNewFolder(record: record, onRootFolder: targetRootVM)
                }
            }
        }

        var processedDigests: [FileSystemDeltaDigest] = []
        processedDigests.reserveCapacity(chunk.deltaCount)
        var observedStoreDeltas: [PreparedFileSystemDelta] = []
        observedStoreDeltas.reserveCapacity(chunk.deltaCount)
        #if DEBUG
            let deltaLoopStartMS = debugPerfTimestampMS()
        #endif
        for prepared in deltas {
            let delta = prepared.delta
            let rel = prepared.relativePath
            let fullPath = prepared.absolutePath

            switch delta {
            case .fileAdded:
                flushRemovedSubtreesForCleanupIfNeeded(beforeAddingPath: fullPath)
                await materializeStoreFolderAncestors(for: rel)
                let replayPathMetadata = FileViewModel.PrecomputedPathMetadata.preparedReplay(
                    standardizedAbsolutePath: fullPath,
                    standardizedRelativePath: rel,
                    standardizedRootFolderPath: targetRootVM.standardizedFullPath
                )
                let fileRecordID: UUID?
                let parentFolderID: UUID?
                if let rootID = workspaceRoot?.id,
                   let record = await workspaceFileContextStore.file(rootID: rootID, relativePath: rel)
                {
                    fileRecordID = record.id
                    parentFolderID = record.parentFolderID
                } else {
                    fileRecordID = nil
                    parentFolderID = nil
                }
                if let outcome = await handleNewFile(
                    relativePath: rel,
                    onRootFolder: targetRootVM,
                    requestCodeScanImmediately: false,
                    preparedReplayPathMetadata: replayPathMetadata,
                    recordID: fileRecordID,
                    parentFolderID: parentFolderID
                ) {
                    observedStoreDeltas.append(prepared)
                    batchedCodeScanFiles[outcome.file.id] = outcome.file
                    if let parentFolder = outcome.parentFolderForStateRecompute {
                        dirtyFolderStateStarts[parentFolder.id] = parentFolder
                    } else {
                        requiresFullRootFolderStateRefresh = true
                    }
                } else {
                    requiresFullRootFolderStateRefresh = true
                }
                topologyChanged = true
                processedDigests.append(.fileAdded(rel))

            case .folderAdded:
                flushRemovedSubtreesForCleanupIfNeeded(beforeAddingPath: fullPath)
                await materializeStoreFolderAncestors(for: rel)
                let folderOutcome: FolderTopologyApplyOutcome? = if let rootID = workspaceRoot?.id,
                                                                    let record = await workspaceFileContextStore.folder(rootID: rootID, relativePath: rel)
                {
                    handleNewFolder(record: record, onRootFolder: targetRootVM)
                } else {
                    handleNewFolder(relativePath: rel, onRootFolder: targetRootVM)
                }
                if let outcome = folderOutcome {
                    observedStoreDeltas.append(prepared)
                    if let parentFolder = outcome.parentFolderForStateRecompute {
                        dirtyFolderStateStarts[parentFolder.id] = parentFolder
                    } else {
                        requiresFullRootFolderStateRefresh = true
                    }
                } else {
                    requiresFullRootFolderStateRefresh = true
                }
                topologyChanged = true
                processedDigests.append(.folderAdded(rel))

            case .fileRemoved:
                let fileVM = findFileByFullPath(fullPath)
                let formerParentFolder = fileVM?.parentFolder ?? parentFolderForRelativePath(rel, under: targetRootVM)
                if let fileVM {
                    removeFileFromParentChildrenArray(fileVM)
                    fileHierarchyIndex.removeFile(forKey: fullPath, expectedRootKey: rootKey)
                    observedStoreDeltas.append(prepared)
                    topologyChanged = true
                    if let formerParentFolder {
                        dirtyFolderStateStarts[formerParentFolder.id] = formerParentFolder
                    } else {
                        requiresFullRootFolderStateRefresh = true
                    }
                } else {
                    #if DEBUG
                        if Self.isLoggingEnabled {
                            print("Skipping removal for missing index entry: \(rel) under root \((rootKey as NSString).lastPathComponent)")
                        }
                    #endif
                }
                processedDigests.append(.fileRemoved(rel))

            case .folderRemoved:
                let removedSubtree: RemovedFolderSubtree? = if let folderVM = findFolderByFullPath(fullPath) {
                    removeFolderRecursive(in: targetRootVM, relativePath: folderVM.relativePath)
                } else {
                    removeFolderRecursive(in: targetRootVM, relativePath: rel)
                }
                if let removedSubtree {
                    observedStoreDeltas.append(prepared)
                    topologyChanged = true
                    if let formerParentFolder = removedSubtree.formerParentFolder ?? parentFolderForRelativePath(rel, under: targetRootVM) {
                        dirtyFolderStateStarts[formerParentFolder.id] = formerParentFolder
                    } else {
                        requiresFullRootFolderStateRefresh = true
                    }
                    removedSubtreesForCleanup.append(removedSubtree)
                    removedSubtreeRootPathsForCleanup.insert(removedSubtree.removedFolderFullPath)
                } else {
                    #if DEBUG
                        if Self.isLoggingEnabled {
                            print("Skipping folder removal for missing index entry: \(rel) under root \((rootKey as NSString).lastPathComponent)")
                        }
                    #endif
                }
                processedDigests.append(.folderRemoved(rel))

            case let .fileModified(_, maybeDate):
                if let fileVM = findFileByFullPath(fullPath) {
                    observedStoreDeltas.append(prepared)
                    if let date = maybeDate {
                        await fileVM.setModificationDate(date, forceInvalidation: true)
                    } else {
                        do {
                            guard let workspaceRoot else {
                                throw FileManagerError.fileSystemServiceNotFoundWithContext("Workspace store root unavailable for '\(rootKey)'.")
                            }
                            let diskDate = try await workspaceFileContextStore.fileModificationDate(rootID: workspaceRoot.id, relativePath: rel)
                            await fileVM.setModificationDate(diskDate, forceInvalidation: true)
                        } catch {
                            await fileVM.setModificationDate(Date(), forceInvalidation: true)
                        }
                    }
                    batchedCodeScanFiles[fileVM.id] = fileVM
                    batchedSliceRebases[fileVM.standardizedFullPath] = ReplaySliceRebaseRequest(
                        file: fileVM,
                        relativePath: rel
                    )
                }
                processedDigests.append(.fileModified(rel))

            case let .folderModified(_, maybeDate):
                #if DEBUG
                    folderModifiedCount += 1
                    if maybeDate != nil {
                        folderModifiedCarriedDateCount += 1
                    }
                #endif
                if let folderVM = findFolderByFullPath(fullPath) {
                    observedStoreDeltas.append(prepared)
                    if let date = maybeDate {
                        folderVM.setModificationDate(date)
                    } else {
                        let diskDate: Date? = if let workspaceRoot {
                            try? await workspaceFileContextStore.itemModificationDateIfAvailable(rootID: workspaceRoot.id, relativePath: rel)
                        } else {
                            nil
                        }
                        if let diskDate {
                            #if DEBUG
                                folderModifiedFallbackStatSuccessCount += 1
                            #endif
                            folderVM.setModificationDate(diskDate)
                        } else {
                            #if DEBUG
                                folderModifiedSkippedNoDateCount += 1
                            #endif
                        }
                    }
                } else if maybeDate == nil {
                    #if DEBUG
                        folderModifiedSkippedNoDateCount += 1
                    #endif
                }
                processedDigests.append(.folderModified(rel))
            }
        }
        #if DEBUG
            deltaLoopDurationMS = debugPerfElapsedMS(since: deltaLoopStartMS)
        #endif

        flushRemovedSubtreesForCleanup()

        // Canonical store indexes are mutated by WorkspaceFileContextStore's watcher replay.
        // This path now only maintains the WorkspaceFiles UI projection.

        if shouldFlushPendingInserts {
            #if DEBUG
                let pendingInsertSnapshotBeforeFlush = pendingInsertPerfSnapshot(forRootKey: rootKey)
                pendingInsertRootCountBeforeFlush = pendingInsertSnapshotBeforeFlush.rootCount
                pendingInsertEntryCountBeforeFlush = pendingInsertSnapshotBeforeFlush.entryCount
                pendingInsertEntryCountForReplayedRootBeforeFlush = pendingInsertSnapshotBeforeFlush.entryCountForRoot
                let flushPendingInsertsStartMS = debugPerfTimestampMS()
            #endif
            flushPendingInserts()
            #if DEBUG
                flushPendingInsertsDurationMS = debugPerfElapsedMS(since: flushPendingInsertsStartMS)
                pendingInsertEntryCountRemainingAfterFlush = pendingInsertPerfSnapshot(forRootKey: rootKey).entryCount
            #endif
        }

        if topologyChanged {
            #if DEBUG
                let updateFolderStatesStartMS = debugPerfTimestampMS()
                dirtyFolderStateStartCount = dirtyFolderStateStarts.count
            #endif
            if requiresFullRootFolderStateRefresh {
                _ = updateFolderStateRecursive(targetRootVM)
                #if DEBUG
                    usedFullRootFolderStateRefresh = true
                #endif
            } else {
                recomputeAncestorStates(startingAtFolders: Array(dirtyFolderStateStarts.values))
            }
            #if DEBUG
                updateFolderStatesDurationMS = debugPerfElapsedMS(since: updateFolderStatesStartMS)
            #endif
        }

        if needsIndexRebuild {
            #if DEBUG
                let rebuildStartMS = debugPerfTimestampMS()
            #endif
            rebuildFileHierarchyIndex(for: targetRootVM)
            #if DEBUG
                rebuildDurationMS = debugPerfElapsedMS(since: rebuildStartMS)
                if let rebuildSample = lastIndexRebuildPerfSample, rebuildSample.rootKey == rootKey {
                    rebuildCleanupCandidateSelectionDurationMS = rebuildSample.cleanupCandidateSelectionDurationMS
                    rebuildCleanupFolderRemovalDurationMS = rebuildSample.cleanupFolderRemovalDurationMS
                    rebuildCleanupFileRemovalDurationMS = rebuildSample.cleanupFileRemovalDurationMS
                    rebuildTraversalDurationMS = rebuildSample.reindexTraversalDurationMS
                    rebuildCleanupCandidateFolderKeys = rebuildSample.cleanupCandidateFolderKeys
                    rebuildCleanupCandidateFileKeys = rebuildSample.cleanupCandidateFileKeys
                    rebuildUsedOwnershipFallback = rebuildSample.usedOwnershipFallback
                }
            #endif
        }

        accumulator.processedDigests.append(contentsOf: processedDigests)
        if topologyChanged {
            accumulator.topologyChanged = true
        }
        for (fileID, file) in batchedCodeScanFiles {
            accumulator.codeScanFilesByID[fileID] = file
        }
        for (fullPath, request) in batchedSliceRebases {
            accumulator.sliceRebasesByFullPath[fullPath] = request
        }

        #if DEBUG
            currentRootReplayPerfSample = RootReplayPerfSample(
                rootKey: rootKey,
                coalesceDurationMS: batch.coalesceDurationMS,
                preparationDurationMS: batch.preparationDurationMS,
                batchQueuedDeltaCount: batch.queuedDeltaCount,
                batchCoalescedDeltaCount: batch.coalescedDeltaCount,
                batchDiscardedDeltaCount: batch.discardedDeltaCount,
                chunkDeltaCount: chunk.deltaCount,
                fileAddedCount: fileAddedCount,
                fileRemovedCount: fileRemovedCount,
                folderAddedCount: folderAddedCount,
                folderRemovedCount: folderRemovedCount,
                modifiedCount: modifiedCount,
                folderModifiedCount: folderModifiedCount,
                folderModifiedCarriedDateCount: folderModifiedCarriedDateCount,
                folderModifiedFallbackStatSuccessCount: folderModifiedFallbackStatSuccessCount,
                folderModifiedSkippedNoDateCount: folderModifiedSkippedNoDateCount,
                parentLookupCount: currentReplayParentLookupCount,
                removedSubtreeDescendantLookupCount: removedSubtreeDescendantLookupCount,
                deltaLoopDurationMS: deltaLoopDurationMS,
                pendingInsertRootCountBeforeFlush: pendingInsertRootCountBeforeFlush,
                pendingInsertEntryCountBeforeFlush: pendingInsertEntryCountBeforeFlush,
                pendingInsertEntryCountForReplayedRootBeforeFlush: pendingInsertEntryCountForReplayedRootBeforeFlush,
                pendingInsertEntryCountRemainingAfterFlush: pendingInsertEntryCountRemainingAfterFlush,
                flushPendingInsertsDurationMS: flushPendingInsertsDurationMS,
                updateFolderStatesDurationMS: updateFolderStatesDurationMS,
                usedFullRootFolderStateRefresh: usedFullRootFolderStateRefresh,
                dirtyFolderStateStartCount: dirtyFolderStateStartCount,
                onRootFoldersChangedDurationMS: onRootFoldersChangedDurationMS,
                usedIncrementalIndexCleanup: usedIncrementalIndexCleanup,
                incrementalIndexCleanupDurationMS: incrementalIndexCleanupDurationMS,
                incrementalRemovedFolderCount: incrementalRemovedFolderCount,
                incrementalRemovedFileCount: incrementalRemovedFileCount,
                incrementalIndexCleanupFallbackToRebuild: incrementalIndexCleanupFallbackToRebuild,
                rebuildDurationMS: rebuildDurationMS,
                rebuildCleanupCandidateSelectionDurationMS: rebuildCleanupCandidateSelectionDurationMS,
                rebuildCleanupFolderRemovalDurationMS: rebuildCleanupFolderRemovalDurationMS,
                rebuildCleanupFileRemovalDurationMS: rebuildCleanupFileRemovalDurationMS,
                rebuildTraversalDurationMS: rebuildTraversalDurationMS,
                rebuildCleanupCandidateFolderKeys: rebuildCleanupCandidateFolderKeys,
                rebuildCleanupCandidateFileKeys: rebuildCleanupCandidateFileKeys,
                rebuildUsedOwnershipFallback: rebuildUsedOwnershipFallback,
                codeScanBatchInvocationCount: 0,
                codeScanBatchFileCount: 0,
                sliceRebaseBatchInvocationCount: 0,
                sliceRebaseCandidateCount: 0,
                invalidateSnapshotDurationMS: invalidateSnapshotDurationMS,
                totalApplyDurationMS: debugPerfElapsedMS(since: totalStartMS)
            )
        #endif
    }

    @MainActor
    private func finalizeReplayRootPass(
        _ accumulator: ReplayRootPassAccumulator,
        passIndex: Int,
        chunkCount: Int
    ) -> RootReplayPassPerfSample? {
        guard !accumulator.processedDigests.isEmpty else { return nil }
        let signpost = RepoFileReplayPerf.begin("finalizeReplayRootPass")
        defer { RepoFileReplayPerf.end("finalizeReplayRootPass", signpost) }
        #if DEBUG
            let finalizeStartMS = debugPerfTimestampMS()
            var onRootFoldersChangedDurationMS = 0.0
            var invalidateSnapshotDurationMS = 0.0
        #endif
        if accumulator.topologyChanged {
            #if DEBUG
                let invalidateSnapshotStartMS = debugPerfTimestampMS()
            #endif
            invalidateStaticSnapshot(forRootFullPath: accumulator.rootKey)
            #if DEBUG
                invalidateSnapshotDurationMS = debugPerfElapsedMS(since: invalidateSnapshotStartMS)
            #endif
        }
        #if DEBUG
            let onRootsChangedStartMS = debugPerfTimestampMS()
        #endif
        onRootFoldersChanged?()
        #if DEBUG
            onRootFoldersChangedDurationMS = debugPerfElapsedMS(since: onRootsChangedStartMS)
        #endif
        fileSystemDeltasAppliedPublisher.send(
            FileSystemDeltasAppliedEvent(rootKey: accumulator.rootKey, deltas: accumulator.processedDigests)
        )
        let codeScanFiles = Array(accumulator.codeScanFilesByID.values)
        let sliceRebases = Array(accumulator.sliceRebasesByFullPath.values)
        flushReplayChunkCodeScanBatch(codeScanFiles)
        scheduleSliceRebasesForModifiedFiles(sliceRebases)
        #if DEBUG
            return RootReplayPassPerfSample(
                rootKey: accumulator.rootKey,
                passIndex: passIndex,
                chunkCount: chunkCount,
                digestCount: accumulator.processedDigests.count,
                topologyChanged: accumulator.topologyChanged,
                onRootFoldersChangedInvocationCount: 1,
                snapshotInvalidationCount: accumulator.topologyChanged ? 1 : 0,
                deltaAppliedPublisherInvocationCount: 1,
                codeScanBatchInvocationCount: codeScanFiles.isEmpty ? 0 : 1,
                codeScanBatchFileCount: codeScanFiles.count,
                sliceRebaseBatchInvocationCount: sliceRebases.isEmpty ? 0 : 1,
                sliceRebaseCandidateCount: sliceRebases.count,
                onRootFoldersChangedDurationMS: onRootFoldersChangedDurationMS,
                invalidateSnapshotDurationMS: invalidateSnapshotDurationMS,
                finalizeDurationMS: debugPerfElapsedMS(since: finalizeStartMS)
            )
        #else
            return nil
        #endif
    }

    /// Update the cached expansion set when a folder is renamed (simple parent‐preserving rename).
    @MainActor
    private func transferExpandedStateOnRename(oldAbs: String, newAbs: String) {
        let oldStd = (oldAbs as NSString).standardizingPath
        let newStd = (newAbs as NSString).standardizingPath
        var toRemove: [String] = []
        var toAdd: [String] = []
        for path in expandedFolderPaths {
            if path == oldStd || path.hasPrefix(oldStd.hasSuffix("/") ? oldStd : oldStd + "/") {
                let suffix = String(path.dropFirst(oldStd.count))
                let mapped = newStd + suffix
                toRemove.append(path)
                toAdd.append((mapped as NSString).standardizingPath)
            }
        }
        for p in toRemove {
            expandedFolderPaths.remove(p)
        }
        for p in toAdd {
            expandedFolderPaths.insert(p)
        }
    }

    @MainActor
    private func applyCachedExpansionStateIfNeeded(to folder: FolderViewModel) {
        guard expandedFolderPaths.contains(folder.standardizedFullPath) else { return }
        let wasApplying = isApplyingExpansionState
        isApplyingExpansionState = true
        _ = expandParentChain(of: folder)
        isApplyingExpansionState = wasApplying
    }

    @MainActor
    private func handleNewFolder(record: WorkspaceFolderRecord, onRootFolder root: FolderViewModel) -> FolderTopologyApplyOutcome? {
        handleNewFolder(
            relativePath: record.standardizedRelativePath,
            onRootFolder: root,
            recordID: record.id,
            modificationDate: record.modificationDate ?? Date()
        )
    }

    @MainActor
    private func handleNewFolder(
        relativePath: String,
        onRootFolder root: FolderViewModel,
        recordID: UUID? = nil,
        modificationDate: Date = Date()
    ) -> FolderTopologyApplyOutcome? {
        let parentFolderForStateRecompute = parentFolderForRelativePath(relativePath, under: root)
        // Build the absolute path for this folder under the given root
        let absPath = (root.fullPath as NSString).appendingPathComponent(relativePath)
        let standardizedAbsPath = (absPath as NSString).standardizingPath

        // ──────────────────────────────────────────────────────────────────
        // A) Folder already in the index?
        // ──────────────────────────────────────────────────────────────────
        if let found = findFolderByFullPath(standardizedAbsPath) {
            if let recordID, found.id != recordID {
                adoptCanonicalFolderIDForStoreCorrelation(found, canonicalID: recordID)
            }

            // 1️⃣ Always refresh the timestamp
            found.setModificationDate(Date())

            // 2️⃣ If it is currently *detached* (parent == nil and not a root),
            //     make sure it is linked back into the visible hierarchy.
            let isRoot = rootFolders.contains { $0.id == found.id }
            let isLinked = (found.parent != nil) || isRoot
            if !isLinked {
                // Ensure the ancestor chain exists, then attach
                createMissingParentFolder(
                    parentPath: (relativePath as NSString)
                        .deletingLastPathComponent,
                    under: root
                )
                insertFolder(
                    found,
                    under: root,
                    relativePath: relativePath
                )
            }
            applyCachedExpansionStateIfNeeded(to: found)
            return FolderTopologyApplyOutcome(
                parentFolderForStateRecompute: found.parent ?? parentFolderForStateRecompute
            )
        }

        // ──────────────────────────────────────────────────────────────────
        // B) Brand new folder – create, index, attach
        // ──────────────────────────────────────────────────────────────────
        let folder = Folder(
            id: recordID ?? UUID(),
            name: (relativePath as NSString).lastPathComponent,
            path: standardizedAbsPath,
            modificationDate: modificationDate
        )
        // For _git_data subtree: use dateNewest sort override so newest items appear first
        let isGitDataRoot = root.isSystemRoot && root.name == "_git_data"
        let sortOverride: SortMethod? = isGitDataRoot ? .dateNewest : nil
        let folderVM = FolderViewModel(
            folder: folder,
            rootPath: root.fullPath,
            sortMethodOverride: sortOverride
        )

        // Index before attaching so later incremental file materialization can reuse the store-ID folder.
        fileHierarchyIndex.insertFolder(folderVM, rootKey: root.standardizedFullPath)
        // Attach (creating any missing ancestors)
        insertFolder(folderVM, under: root, relativePath: relativePath)
        applyCachedExpansionStateIfNeeded(to: folderVM)
        return FolderTopologyApplyOutcome(
            parentFolderForStateRecompute: folderVM.parent ?? parentFolderForStateRecompute
        )
    }

    private func removeFolder(atRelativePath relativePath: String, from root: FolderViewModel) {
        _ = removeFolderRecursive(in: root, relativePath: relativePath)
    }

    /// Insert a FolderViewModel under the correct parent in the tree, creating
    /// intermediate parent folders if needed.
    @MainActor
    private func insertFolder(
        _ folderVM: FolderViewModel,
        under root: FolderViewModel,
        relativePath: String
    ) {
        let comps = relativePath.split(separator: "/").map(String.init)
        guard comps.count > 1 else {
            guard canAttachFolder(folderVM, to: root) else {
                logInvalidFolderAttach(child: folderVM, parent: root, root: root, reason: "invalid-root-attachment")
                return
            }
            root.addChild(.folder(folderVM))
            registerExpansionTracking(for: folderVM)
            return
        }

        let parentRel = comps.dropLast().joined(separator: "/")
        let rootFull = root.standardizedFullPath
        let parentFull = (
            (rootFull as NSString)
                .appendingPathComponent(parentRel) as NSString
        )
        .standardizingPath

        if let parent = fileHierarchyIndex.foldersByFullPath[parentFull] {
            let isRoot = rootFolders.contains { $0.id == parent.id }
            let isLinked = (parent.parent != nil) || isRoot
            if !isLinked { createMissingParentFolder(parentPath: parentRel, under: root) }

            guard canAttachFolder(folderVM, to: parent) else {
                logInvalidFolderAttach(child: folderVM, parent: parent, root: root, reason: "invalid-parent-attachment")
                return
            }
            parent.addChild(.folder(folderVM))
            registerExpansionTracking(for: folderVM)
            return
        }

        // Parent chain missing → build once, *then* attach
        createMissingParentFolder(parentPath: parentRel, under: root)
        if let parent = fileHierarchyIndex.foldersByFullPath[parentFull] {
            guard canAttachFolder(folderVM, to: parent) else {
                logInvalidFolderAttach(child: folderVM, parent: parent, root: root, reason: "invalid-parent-attachment")
                return
            }
            parent.addChild(.folder(folderVM))
            registerExpansionTracking(for: folderVM)
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: - Insert batching helpers

    /// ─────────────────────────────────────────────────────────────
    @MainActor
    private func canAttachFolder(_ child: FolderViewModel, to parent: FolderViewModel) -> Bool {
        if child.id == parent.id { return false }
        let parentPath = parent.standardizedFullPath
        let childPath = child.standardizedFullPath
        if childPath == parentPath { return false }
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return childPath.hasPrefix(prefix)
    }

    @MainActor
    private func logInvalidFolderAttach(
        child: FolderViewModel,
        parent: FolderViewModel,
        root: FolderViewModel,
        reason: String
    ) {
        guard Self.isLoggingEnabled else { return }
        print("Skipped folder attach (\(reason)): child=\(child.standardizedFullPath) parent=\(parent.standardizedFullPath) root=\(root.standardizedFullPath)")
    }

    @MainActor
    private func enqueueInsert(child: FileSystemItemType, into parent: FolderViewModel) {
        pendingChildInserts[parent.id, default: []].append(child)
        pendingInsertParents[parent.id] = parent

        guard !isInsertFlushScheduled else { return }
        isInsertFlushScheduled = true

        // Flush on the next turn (same tick/next tick), coalescing multiple inserts.
        Task { [weak self] in
            await Task.yield()
            await MainActor.run {
                self?.flushPendingInserts()
            }
        }
    }

    #if DEBUG
        @MainActor
        private func pendingInsertPerfSnapshot(forRootKey rootKey: RootKey) -> PendingInsertPerfSnapshot {
            let parentsByID = pendingInsertParents
            var rootKeys: Set<String> = []
            var totalEntryCount = 0
            var entryCountForRoot = 0
            for (parentID, children) in pendingChildInserts {
                totalEntryCount += children.count
                guard let parent = parentsByID[parentID] else { continue }
                let parentRootKey = StandardizedPath.absolute(parent.rootPath)
                rootKeys.insert(parentRootKey)
                if parentRootKey == rootKey {
                    entryCountForRoot += children.count
                }
            }
            return PendingInsertPerfSnapshot(
                rootCount: rootKeys.count,
                entryCount: totalEntryCount,
                entryCountForRoot: entryCountForRoot
            )
        }
    #endif

    @MainActor
    private func flushPendingInserts() {
        // Always clear the schedule flag so new enqueues can schedule another flush.
        isInsertFlushScheduled = false

        guard !pendingChildInserts.isEmpty else {
            pendingInsertParents.removeAll(keepingCapacity: true)
            return
        }

        let pending = pendingChildInserts
        pendingChildInserts.removeAll(keepingCapacity: true)

        let largeBatchThreshold = 500
        for (parentID, children) in pending {
            guard let parent = pendingInsertParents[parentID], !children.isEmpty else { continue }

            // Defensive dedupe in case identical inserts land in the same tick.
            var seen = Set<UUID>()
            let uniqueChildren: [FileSystemItemType] = children.filter { item in
                switch item {
                case let .file(file):
                    seen.insert(file.id).inserted
                case let .folder(folder):
                    seen.insert(folder.id).inserted
                }
            }
            guard !uniqueChildren.isEmpty else { continue }

            // One parent mutation per tick, per parent.
            if uniqueChildren.count == 1, let onlyChild = uniqueChildren.first {
                parent.addChild(onlyChild)
            } else if uniqueChildren.count <= largeBatchThreshold {
                parent.addChildrenBatch(uniqueChildren, recomputeCheckbox: true)
            } else {
                parent.addChildrenBatch(
                    uniqueChildren,
                    options: .init(
                        recomputeCheckbox: false,
                        ensureSorted: false,
                        rebuildChildren: true
                    )
                )
                parent.sortChildrenIfNeeded(currentSortMethod, recomputeCheckbox: true, recursion: .depth(0))
            }
        }

        pendingInsertParents.removeAll(keepingCapacity: true)
    }

    /// Create the intermediate parent folder if it doesn’t exist,
    /// plus recursively ensure that folder is inserted in the tree.
    @MainActor
    private func createMissingParentFolder(
        parentPath: String,
        under root: FolderViewModel
    ) {
        // 0️⃣ Nothing to create
        guard !parentPath.isEmpty else { return }

        let rootFull = root.standardizedFullPath
        let parentFull = (
            (rootFull as NSString)
                .appendingPathComponent(parentPath) as NSString
        )
        .standardizingPath

        // 1️⃣ Folder already in the index?
        if let existing = fileHierarchyIndex.foldersByFullPath[parentFull] {
            // ── If it is *not yet* inside the tree, attach it now ────────────
            let isRoot = rootFolders.contains { $0.id == existing.id }
            let isLinked = (existing.parent != nil) || isRoot

            if !isLinked {
                // Ensure its own parent chain exists first
                let grandRel = (parentPath as NSString).deletingLastPathComponent
                if !grandRel.isEmpty {
                    createMissingParentFolder(parentPath: grandRel, under: root)
                }
                // Finally hook it into the hierarchy
                insertFolder(existing, under: root, relativePath: parentPath)
            }
            return // ✅ done
        }

        // 2️⃣ Build and register a brand‑new FolderViewModel
        let folder = Folder(
            name: (parentPath as NSString).lastPathComponent,
            path: parentFull,
            modificationDate: Date()
        )
        // For _git_data subtree: use dateNewest sort override so newest items appear first
        let isGitDataRoot = root.isSystemRoot && root.name == "_git_data"
        let sortOverride: SortMethod? = isGitDataRoot ? .dateNewest : nil
        let parentVM = FolderViewModel(
            folder: folder,
            rootPath: root.fullPath,
            sortMethodOverride: sortOverride
        )
        fileHierarchyIndex.insertFolder(parentVM, rootKey: root.standardizedFullPath)

        // 3️⃣ Make sure *its* parent exists
        let grandRel = (parentPath as NSString).deletingLastPathComponent
        if !grandRel.isEmpty {
            createMissingParentFolder(parentPath: grandRel, under: root)
        }

        // 4️⃣ Attach to the tree
        insertFolder(parentVM, under: root, relativePath: parentPath)
    }

    // ============================================================
    // MARK: - File insertion

    /// ============================================================
    @MainActor
    private func parentFolderForRelativePath(
        _ relativePath: String,
        under root: FolderViewModel
    ) -> FolderViewModel? {
        #if DEBUG
            currentReplayParentLookupCount += 1
        #endif
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        let parentRelativePath = StandardizedPath.relative(
            (standardizedRelativePath as NSString).deletingLastPathComponent
        )
        guard !parentRelativePath.isEmpty else { return root }
        let parentFullPath = StandardizedPath.join(
            standardizedRoot: root.standardizedFullPath,
            standardizedRelativePath: parentRelativePath
        )
        return fileHierarchyIndex.foldersByFullPath[parentFullPath]
    }

    private func storeContentProvider(
        for root: FolderViewModel,
        relativePath: String,
        fallbackFullPath: String
    ) -> (any FileViewModelContentProvider)? {
        guard let workspaceRoot = workspaceFileContextRootsByRootKey[root.standardizedFullPath] else {
            return nil
        }
        return StoreFileViewModelContentProvider(
            store: workspaceFileContextStore,
            rootID: workspaceRoot.id,
            relativePath: relativePath,
            fallbackFullPath: fallbackFullPath
        )
    }

    @MainActor
    private func handleNewFile(
        record: WorkspaceFileRecord,
        onRootFolder root: FolderViewModel,
        requestCodeScanImmediately: Bool = true,
        useRecordModificationDateForExistingFile: Bool = false
    ) async -> FileAdditionApplyOutcome? {
        let metadata = FileViewModel.PrecomputedPathMetadata.preparedReplay(
            standardizedAbsolutePath: record.standardizedFullPath,
            standardizedRelativePath: record.standardizedRelativePath,
            standardizedRootFolderPath: root.standardizedFullPath
        )
        return await handleNewFile(
            relativePath: record.standardizedRelativePath,
            onRootFolder: root,
            requestCodeScanImmediately: requestCodeScanImmediately,
            preparedReplayPathMetadata: metadata,
            recordID: record.id,
            parentFolderID: record.parentFolderID,
            modificationDate: record.modificationDate ?? Date(),
            useProvidedModificationDateForExistingFile: useRecordModificationDateForExistingFile,
            expectedRootID: record.rootID
        )
    }

    @MainActor
    private func materializeStoreFolderAncestors(
        for relativePath: String,
        onRootFolder root: FolderViewModel,
        rootID: UUID
    ) async {
        let parentRel = StandardizedPath.relative((relativePath as NSString).deletingLastPathComponent)
        guard !parentRel.isEmpty else { return }

        var current = ""
        for component in parentRel.split(separator: "/") {
            guard !Task.isCancelled else { return }
            current = current.isEmpty ? String(component) : "\(current)/\(component)"
            if let record = await workspaceFileContextStore.folder(rootID: rootID, relativePath: current) {
                let rootKey = StandardizedPath.absolute(root.standardizedFullPath)
                guard workspaceFileContextRootsByRootKey[rootKey]?.id == rootID,
                      rootFolders.contains(where: { $0.id == root.id })
                else {
                    return
                }
                _ = handleNewFolder(record: record, onRootFolder: root)
            }
        }
    }

    @MainActor
    private func materializeFileViewModel(
        record: WorkspaceFileRecord,
        requestCodeScanImmediately: Bool = false
    ) async -> FileViewModel? {
        guard !Task.isCancelled else { return nil }
        guard let currentRecord = await workspaceFileContextStore.file(
            rootID: record.rootID,
            relativePath: record.standardizedRelativePath
        ) else {
            return nil
        }

        guard let rootRecord = workspaceFileContextRootsByRootKey.values.first(where: { $0.id == currentRecord.rootID }) else {
            return nil
        }
        let rootKey = rootKey(forPath: rootRecord.standardizedFullPath)
        guard workspaceFileContextRootsByRootKey[rootKey]?.id == currentRecord.rootID else {
            return nil
        }
        guard let rootFolder = rootFolders.first(where: { $0.id == currentRecord.rootID || $0.standardizedFullPath == rootKey }) else {
            return nil
        }

        await materializeStoreFolderAncestors(
            for: currentRecord.standardizedRelativePath,
            onRootFolder: rootFolder,
            rootID: currentRecord.rootID
        )
        guard !Task.isCancelled,
              workspaceFileContextRootsByRootKey[rootKey]?.id == currentRecord.rootID,
              rootFolders.contains(where: { $0.id == rootFolder.id })
        else {
            return nil
        }

        guard let outcome = await handleNewFile(
            record: currentRecord,
            onRootFolder: rootFolder,
            requestCodeScanImmediately: requestCodeScanImmediately
        ) else {
            return nil
        }
        guard workspaceFileContextRootsByRootKey[rootKey]?.id == currentRecord.rootID,
              rootFolders.contains(where: { $0.id == rootFolder.id })
        else {
            fileHierarchyIndex.removeFile(forKey: currentRecord.standardizedFullPath, expectedRootKey: rootKey)
            return nil
        }
        flushPendingInserts()
        if let parent = outcome.parentFolderForStateRecompute {
            recomputeAncestorStates(startingAt: parent)
        }
        invalidateStaticSnapshot(forRootFullPath: rootKey)
        await clearPathResolutionCaches()
        onRootFoldersChanged?()
        return outcome.file
    }

    @MainActor
    private func handleNewFile(
        relativePath: String,
        onRootFolder root: FolderViewModel,
        requestCodeScanImmediately: Bool = true,
        preparedReplayPathMetadata: FileViewModel.PrecomputedPathMetadata? = nil,
        recordID: UUID? = nil,
        parentFolderID: UUID? = nil,
        modificationDate: Date = Date(),
        useProvidedModificationDateForExistingFile: Bool = false,
        expectedRootID: UUID? = nil
    ) async -> FileAdditionApplyOutcome? {
        guard isCurrentAttachedRoot(root, expectedRootID: expectedRootID) else { return nil }

        let stdAbs: String
        if let preparedReplayPathMetadata {
            stdAbs = preparedReplayPathMetadata.standardizedFullPath
        } else {
            let absPath = (root.standardizedFullPath as NSString).appendingPathComponent(relativePath)
            stdAbs = (absPath as NSString).standardizingPath
        }
        let creationKey = makeCreationKey(rootFullPath: root.standardizedFullPath, relPath: relativePath)
        let intendedParentFolder = parentFolderForRelativePath(relativePath, under: root)
        let parentRelativePath = StandardizedPath.relative((relativePath as NSString).deletingLastPathComponent)
        if let intendedParentFolder,
           let parentFolderID,
           intendedParentFolder.id != parentFolderID
        {
            adoptCanonicalFolderIDForStoreCorrelation(intendedParentFolder, canonicalID: parentFolderID)
        } else if !parentRelativePath.isEmpty,
                  let intendedParentFolder,
                  let workspaceRoot = workspaceFileContextRootsByRootKey[root.standardizedFullPath]
        {
            let parentRecord = await workspaceFileContextStore.folder(
                rootID: workspaceRoot.id,
                relativePath: parentRelativePath
            )
            guard isCurrentAttachedRoot(root, expectedRootID: expectedRootID) else { return nil }
            if let parentRecord, intendedParentFolder.id != parentRecord.id {
                adoptCanonicalFolderIDForStoreCorrelation(intendedParentFolder, canonicalID: parentRecord.id)
            }
        }

        // If already tracked, only refresh m-date & scan. If store replay later supplies
        // the canonical record ID, replace an optimistic UUID-backed VM so UI identity
        // stays correlated with WorkspaceFileRecord.id.
        if let existing = findFileByFullPath(stdAbs) {
            if let recordID, existing.id != recordID {
                removeFileFromParentChildrenArray(existing)
                fileHierarchyIndex.removeFile(forKey: stdAbs, expectedRootKey: root.standardizedFullPath)
            } else {
                let resolvedModificationDate: Date
                if useProvidedModificationDateForExistingFile {
                    resolvedModificationDate = modificationDate
                } else {
                    do {
                        guard let workspaceRoot = workspaceFileContextRootsByRootKey[root.standardizedFullPath] else {
                            throw FileManagerError.fileSystemServiceNotFoundWithContext("Workspace store root unavailable for '\(root.standardizedFullPath)'.")
                        }
                        resolvedModificationDate = try await workspaceFileContextStore.fileModificationDate(
                            rootID: workspaceRoot.id,
                            relativePath: relativePath
                        )
                    } catch {
                        resolvedModificationDate = Date()
                    }
                }
                guard isCurrentAttachedRoot(root, expectedRootID: expectedRootID) else { return nil }
                await existing.setModificationDate(resolvedModificationDate, forceInvalidation: true)
                guard isCurrentAttachedRoot(root, expectedRootID: expectedRootID) else { return nil }
                if requestCodeScanImmediately {
                    requestCodeScan(for: existing)
                }
                if newlyCreatedFilePaths.remove(creationKey) != nil {
                    performSelectionBatch { existing.setIsChecked(true) }
                }
                return FileAdditionApplyOutcome(
                    file: existing,
                    parentFolderForStateRecompute: existing.parentFolder ?? intendedParentFolder
                )
            }
        }

        guard isCurrentAttachedRoot(root, expectedRootID: expectedRootID) else { return nil }

        let newFile = File(
            id: recordID ?? UUID(),
            name: (relativePath as NSString).lastPathComponent,
            path: stdAbs,
            modificationDate: modificationDate
        )

        let fileVM = if let preparedReplayPathMetadata {
            FileViewModel(
                file: newFile,
                rootIdentifier: root.id,
                rootFolderPath: root.fullPath,
                fileSystemService: nil,
                precomputedPathMetadata: preparedReplayPathMetadata,
                contentProvider: storeContentProvider(
                    for: root,
                    relativePath: relativePath,
                    fallbackFullPath: stdAbs
                )
            )
        } else {
            FileViewModel(
                file: newFile,
                rootPath: root.fullPath,
                rootIdentifier: root.id,
                rootFolderPath: root.fullPath,
                fileSystemService: nil,
                contentProvider: storeContentProvider(
                    for: root,
                    relativePath: relativePath,
                    fallbackFullPath: stdAbs
                )
            )
        }

        attachSelectionCallback(to: fileVM) // ← lightweight

        fileHierarchyIndex.insertFile(fileVM, rootKey: root.standardizedFullPath)

        if requestCodeScanImmediately {
            requestCodeScan(for: fileVM)
        }
        insertFile(fileVM, under: root, relativePath: relativePath)

        if newlyCreatedFilePaths.remove(creationKey) != nil {
            performSelectionBatch { fileVM.setIsChecked(true) }
        }

        return FileAdditionApplyOutcome(
            file: fileVM,
            parentFolderForStateRecompute: parentFolderForRelativePath(relativePath, under: root) ?? intendedParentFolder
        )
    }

    @MainActor
    private func insertFile(
        _ fileVM: FileViewModel,
        under root: FolderViewModel,
        relativePath: String
    ) {
        let comps = relativePath.split(separator: "/").map(String.init)
        guard comps.count > 1 else {
            enqueueInsert(child: .file(fileVM), into: root)
            return
        }

        let parentRel = comps.dropLast().joined(separator: "/")
        let rootFull = root.standardizedFullPath
        let parentFull = (
            (rootFull as NSString)
                .appendingPathComponent(parentRel) as NSString
        )
        .standardizingPath

        if let parent = fileHierarchyIndex.foldersByFullPath[parentFull] {
            // ⚠️ If parent is detached, fix the chain first
            let isRoot = rootFolders.contains { $0.id == parent.id }
            let isLinked = (parent.parent != nil) || isRoot
            if !isLinked {
                createMissingParentFolder(parentPath: parentRel, under: root)
            }
            // Mutate the same instance we enqueue into (avoid "re-read then update old ref").
            let targetParent = fileHierarchyIndex.foldersByFullPath[parentFull] ?? parent
            enqueueInsert(child: .file(fileVM), into: targetParent)
            return // ✅ done
        }

        // Parent chain missing – create once, then enqueue under the now-materialized parent
        createMissingParentFolder(parentPath: parentRel, under: root)
        if let parent = fileHierarchyIndex.foldersByFullPath[parentFull] {
            enqueueInsert(child: .file(fileVM), into: parent)
        } else {
            // Defensive fallback; should be unreachable but avoids dropping inserts.
            enqueueInsert(child: .file(fileVM), into: root)
        }
    }

    @MainActor
    @discardableResult
    private func removeFolderRecursive(in folder: FolderViewModel, relativePath: String) -> RemovedFolderSubtree? {
        var visitedFolderIDs = Set<UUID>()
        return removeFolderRecursive(in: folder, relativePath: relativePath, visitedFolderIDs: &visitedFolderIDs)
    }

    @MainActor
    @discardableResult
    private func removeFolderRecursive(
        in folder: FolderViewModel,
        relativePath: String,
        visitedFolderIDs: inout Set<UUID>
    ) -> RemovedFolderSubtree? {
        guard visitedFolderIDs.insert(folder.id).inserted else { return nil }
        for child in folder.children {
            switch child {
            case let .folder(subFolder):
                if subFolder.relativePath == relativePath {
                    let removed = RemovedFolderSubtree(
                        removedFolder: subFolder,
                        formerParentFolder: folder,
                        removedFolderFullPath: subFolder.standardizedFullPath
                    )
                    unregisterExpansionTracking(for: subFolder)
                    folder.removeSubfolder(subFolder)
                    return removed
                }
                if let removed = removeFolderRecursive(in: subFolder, relativePath: relativePath, visitedFolderIDs: &visitedFolderIDs) {
                    return removed
                }
            case .file:
                continue
            }
        }
        return nil
    }

    @MainActor
    private func collectSubtreeSnapshot(from folder: FolderViewModel) -> (
        folderPaths: Set<String>,
        filePaths: Set<String>,
        fileViewModels: [FileViewModel]
    ) {
        var folderPaths: Set<String> = []
        var filePaths: Set<String> = []
        var fileViewModels: [FileViewModel] = []
        var visitedFolderIDs: Set<UUID> = []
        var stack: [FolderViewModel] = [folder]
        while let current = stack.popLast() {
            guard visitedFolderIDs.insert(current.id).inserted else { continue }
            folderPaths.insert(current.standardizedFullPath)
            for child in current.children {
                switch child {
                case let .folder(subFolder):
                    stack.append(subFolder)
                case let .file(fileVM):
                    filePaths.insert(fileVM.standardizedFullPath)
                    fileViewModels.append(fileVM)
                }
            }
        }
        return (folderPaths, filePaths, fileViewModels)
    }

    @MainActor
    private func pruneRemovedFilesFromSelectionAndCodemap(_ files: [FileViewModel]) {
        guard !files.isEmpty else { return }
        var uniqueFilesByID: [UUID: FileViewModel] = [:]
        for file in files {
            uniqueFilesByID[file.id] = file
        }
        let uniqueFiles = Array(uniqueFilesByID.values)
        let fileIDs = Set(uniqueFiles.map(\.id))
        var shouldRebuildSelectionSliceSnapshot = removeSelectedIDs(fileIDs)
        if !fileIDs.isDisjoint(with: autoCodemapFileIDs) {
            autoCodemapFileIDs.subtract(fileIDs)
            autoCodemapFiles.removeAll { fileIDs.contains($0.id) }
            codeMapUpdatePublisher.send(())
        }
        for file in uniqueFiles {
            if selectionSlicesByFileID.removeValue(forKey: file.id) != nil {
                shouldRebuildSelectionSliceSnapshot = true
            }
            let rootKey = file.standardizedRootFolderPath
            let relativeKey = file.standardizedRelativePath
            if currentSlicesByRoot[rootKey]?[relativeKey] != nil {
                currentSlicesByRoot[rootKey]?[relativeKey] = nil
                if currentSlicesByRoot[rootKey]?.isEmpty == true {
                    currentSlicesByRoot.removeValue(forKey: rootKey)
                }
                shouldRebuildSelectionSliceSnapshot = true
            }
            sliceRebaseTasksByFullPath[file.standardizedFullPath]?.cancel()
            sliceRebaseTasksByFullPath.removeValue(forKey: file.standardizedFullPath)
            sliceRebaseTaskIDsByFullPath.removeValue(forKey: file.standardizedFullPath)
            noSlicesKnownRevisionByFullPath.removeValue(forKey: file.standardizedFullPath)
        }
        if shouldRebuildSelectionSliceSnapshot {
            requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")
        }
    }

    @MainActor
    private func performBatchedIncrementalRemovedSubtreeCleanup(
        _ removedSubtrees: [RemovedFolderSubtree],
        rootKey: String
    ) -> IncrementalRemovedSubtreeCleanupOutcome {
        guard !removedSubtrees.isEmpty else {
            return IncrementalRemovedSubtreeCleanupOutcome(
                succeeded: true,
                removedFolderCount: 0,
                removedFileCount: 0,
                usedFallbackGlobalScan: false,
                descendantLookupCount: 0
            )
        }

        let signpost = RepoFileReplayPerf.begin("batchedRemovedSubtreeCleanup")
        defer { RepoFileReplayPerf.end("batchedRemovedSubtreeCleanup", signpost) }

        var snapshotFolderPaths: Set<String> = []
        var snapshotFilePaths: Set<String> = []
        var snapshotFileViewModels: [FileViewModel] = []
        var removedRootFolderPaths: Set<String> = []

        for removed in removedSubtrees {
            let subtreeSnapshot = collectSubtreeSnapshot(from: removed.removedFolder)
            snapshotFolderPaths.formUnion(subtreeSnapshot.folderPaths)
            snapshotFilePaths.formUnion(subtreeSnapshot.filePaths)
            snapshotFileViewModels.append(contentsOf: subtreeSnapshot.fileViewModels)
            removedRootFolderPaths.insert(removed.removedFolderFullPath)
        }

        let indexedDescendants = fileHierarchyIndex.ownedDescendantPaths(
            forRootKey: rootKey,
            underFolderPaths: removedRootFolderPaths
        )
        guard snapshotFolderPaths == indexedDescendants.folderPaths,
              snapshotFilePaths == indexedDescendants.filePaths
        else {
            let indexedFileViewModels = indexedDescendants.filePaths.compactMap {
                fileHierarchyIndex.filesByFullPath[$0]
            }
            pruneRemovedFilesFromSelectionAndCodemap(snapshotFileViewModels + indexedFileViewModels)
            return IncrementalRemovedSubtreeCleanupOutcome(
                succeeded: false,
                removedFolderCount: max(snapshotFolderPaths.count, indexedDescendants.folderPaths.count),
                removedFileCount: max(snapshotFilePaths.count, indexedDescendants.filePaths.count),
                usedFallbackGlobalScan: indexedDescendants.usedFallbackGlobalScan,
                descendantLookupCount: indexedDescendants.scanInvocationCount
            )
        }
        pruneRemovedFilesFromSelectionAndCodemap(snapshotFileViewModels)
        fileHierarchyIndex.removeSubtreeEntries(
            forRootKey: rootKey,
            folderPaths: snapshotFolderPaths,
            filePaths: snapshotFilePaths
        )
        return IncrementalRemovedSubtreeCleanupOutcome(
            succeeded: true,
            removedFolderCount: snapshotFolderPaths.count,
            removedFileCount: snapshotFilePaths.count,
            usedFallbackGlobalScan: indexedDescendants.usedFallbackGlobalScan,
            descendantLookupCount: indexedDescendants.scanInvocationCount
        )
    }

    @MainActor
    private func performIncrementalRemovedSubtreeCleanup(
        _ removed: RemovedFolderSubtree,
        rootKey: String
    ) -> IncrementalRemovedSubtreeCleanupOutcome {
        performBatchedIncrementalRemovedSubtreeCleanup([removed], rootKey: rootKey)
    }

    @MainActor
    private func flushReplayChunkCodeScanBatch(_ files: [FileViewModel]) {
        guard !files.isEmpty else { return }
        enqueueReplayScanRequests(forFiles: files)
    }

    @MainActor
    private func scheduleSliceRebasesForModifiedFiles(_ requests: [ReplaySliceRebaseRequest]) {
        guard !requests.isEmpty else { return }
        for request in requests {
            scheduleSliceRebaseForModifiedFile(
                request.file,
                relativePath: request.relativePath
            )
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: – Helpers for expanding relative paths into absolute candidates

    /// ─────────────────────────────────────────────────────────────────────────────
    @MainActor
    private func absolutePathCandidates(forRelativePath relPath: String) -> [String] {
        absolutePathCandidates(forRelativePath: relPath, scope: .allLoaded)
    }

    @MainActor
    private func absolutePathCandidates(
        forRelativePath relPath: String,
        scope: LookupRootScope
    ) -> [String] {
        let standardizedRelativePath = StandardizedPath.relative(relPath)
        let roots = roots(in: scope)
        return roots.map { root in
            StandardizedPath.join(
                standardizedRoot: root.standardizedFullPath,
                standardizedRelativePath: standardizedRelativePath
            )
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - Selection Management Helpers

    /// ─────────────────────────────────────────────────────────────────────────────
    /// Unified helper to drop all selections under a given folder path.
    /// Keeps selectedFiles and selectedFileIDs in sync.
    @MainActor
    private func dropSelections(underFolderFullPath folderFullPath: String) {
        guard !selectedFiles.isEmpty else { return }
        let standardizedFolderFullPath = StandardizedPath.absolute(folderFullPath)
        let toRemoveIDs = Set(
            selectedFiles
                .lazy
                .filter { StandardizedPath.isDescendant($0.standardizedFullPath, of: standardizedFolderFullPath) }
                .map(\.id)
        )
        guard !toRemoveIDs.isEmpty else { return }
        _ = removeSelectedIDs(toRemoveIDs)
    }

    // MARK: - Path resolution helpers

    // ─────────────────────────────────────────────────────────────────────────────

    // MARK: - Helper for AI Response Processing

    /// Refreshes a specific path in our index by checking disk.
    /// `relativePath`     – path **relative to `root`** (no leading "/")
    /// If the folder hierarchy or the file is not yet represented in the UI it
    /// gets created and inserted on-the-fly.
    @MainActor
    private func refreshSpecificPath(
        _ relativePath: String,
        inRoot root: FolderViewModel
    ) async {
        // ────────────────────── sanity checks ──────────────────────
        let trimmedRel = relativePath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRel.isEmpty else { return }

        // Split once, we need both the folder path & file name.
        let comps = trimmedRel.split(separator: "/").map(String.init)
        guard comps.last != nil else { return }
        let folderPath = comps.dropLast().joined(separator: "/") // may be ""

        // Absolute path on disk (standardised for *all* map look-ups)
        let absPathRaw = (root.fullPath as NSString).appendingPathComponent(trimmedRel)
        let absPath = (absPathRaw as NSString).standardizingPath

        // ────────────────────── 1) Ensure folder chain ──────────────
        if !folderPath.isEmpty {
            // createMissingParentFolder builds *all* missing ancestors and
            // attaches them to the tree as needed.
            createMissingParentFolder(parentPath: folderPath, under: root)
        }

        // Retrieve the (now guaranteed) owner folder
        let ownerFolderAbs = folderPath.isEmpty
            ? root.fullPath
            : (
                (root.fullPath as NSString).appendingPathComponent(folderPath)
                    as NSString
            ).standardizingPath

        guard fileHierarchyIndex.foldersByFullPath[ownerFolderAbs] != nil else {
            // Defensive – creation failed for some reason; bail out.
            return
        }

        // ────────────────────── 2) Ensure file VM exists ────────────
        if fileHierarchyIndex.filesByFullPath[absPath] == nil,
           FileManager.default.fileExists(atPath: absPath)
        {
            // Delegates to the same helper used by live FSEvent handling so all
            // bookkeeping (indexing, auto-scan, selection batch, etc.) is performed
            // exactly once in a single place.
            await handleNewFile(
                relativePath: trimmedRel,
                onRootFolder: root
            )
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: – FileSystemService lookup by user path

    // ─────────────────────────────────────────────────────────────────────────────

    /// Resolves a user-provided path to a PathLocation through the store-owned path matcher.
    @MainActor
    func pathLocation(
        _ userPath: String,
        exactMatchOnly: Bool = false,
        profile: PathLocateProfile? = nil,
        rootScopeOverride: LookupRootScope? = nil
    ) async -> PathLocation? {
        let normalizedUserPath = normalizeUserInputPath(userPath)
        let resolvedProfile = exactMatchOnly ? PathLocateProfile.moveSourceExact : (profile ?? .uiAssisted)
        let lookupScope = effectiveLookupRootScope(for: resolvedProfile, override: rootScopeOverride)
        if allowsExplicitSystemPathResolution(for: resolvedProfile),
           let explicitLocation = explicitSystemPathLocation(normalizedUserPath)
        {
            return explicitLocation
        }
        if !exactMatchOnly,
           resolvedProfile == .mcpRead || resolvedProfile == .mcpSearchScope,
           let explicitLocation = explicitSystemPathLocation(normalizedUserPath)
        {
            return explicitLocation
        }
        if shouldPreflightDeterministicLookup(for: resolvedProfile),
           exactPathResolutionIssue(for: normalizedUserPath, kind: .either, rootScope: lookupScope) != nil
        {
            return nil
        }

        let selectedPaths = Set(selectedFiles.map(\.fullPath))
        guard let result = await workspaceFileContextStore.lookupPath(
            WorkspacePathLookupRequest(
                userPath: normalizedUserPath,
                profile: resolvedProfile,
                rootScope: lookupScope,
                selectedFileFullPaths: selectedPaths
            )
        ) else {
            return nil
        }

        let standardizedLocationRoot = (result.location.rootPath as NSString).standardizingPath
        let rootIdentifier = rootFolders.first { folder in
            folder.standardizedFullPath == standardizedLocationRoot
        }?.id

        return PathLocation(
            rootPath: result.location.rootPath,
            correctedPath: result.location.correctedPath,
            rootIdentifier: rootIdentifier
        )
    }

    private func shouldPreflightDeterministicLookup(for profile: PathLocateProfile) -> Bool {
        switch profile {
        case .uiAssisted, .createBestEffort, .createRequireUnambiguous:
            false
        case .mcpRead, .mcpSelection, .mcpSearchScope, .moveSourceExact:
            true
        }
    }

    private func absolutePath(rootPath: String, correctedPath: String) -> String {
        PathLocation(rootPath: rootPath, correctedPath: correctedPath, rootIdentifier: nil).absolutePath
    }

    private func absolutePath(for location: PathLocation) -> String {
        absolutePath(rootPath: location.rootPath, correctedPath: location.correctedPath)
    }

    private func resolveFile(rootPath: String, correctedPath: String) -> FileViewModel? {
        findFileByFullPath(absolutePath(rootPath: rootPath, correctedPath: correctedPath))
    }

    private func resolveFile(at location: PathLocation) -> FileViewModel? {
        resolveFile(rootPath: location.rootPath, correctedPath: location.correctedPath)
    }

    private func resolveFolder(rootPath: String, correctedPath: String) -> FolderViewModel? {
        findFolderByFullPath(absolutePath(rootPath: rootPath, correctedPath: correctedPath))
    }

    private func resolveFolder(at location: PathLocation) -> FolderViewModel? {
        resolveFolder(rootPath: location.rootPath, correctedPath: location.correctedPath)
    }

    private func makeServiceResult(
        folder: FolderViewModel?,
        file: FileViewModel?
    ) -> PathLocation? {
        let itemFullPath = folder?.fullPath ?? file?.fullPath ?? ""
        let standardizedPath = (itemFullPath as NSString).standardizingPath

        // Find the matching root by checking if the path is under any loaded store root.
        let matchingRoot = workspaceFileContextRootsByRootKey.keys
            .filter { standardizedPath.isDescendant(of: $0) || standardizedPath == $0 }
            .max(by: { $0.count < $1.count })

        guard let rootKey = matchingRoot, workspaceFileContextRootsByRootKey[rootKey] != nil else {
            print("Error: WorkspaceFileContextStore root not found for \(itemFullPath)")
            return nil
        }

        let rootIdentifier = rootFolders.first { $0.standardizedFullPath == rootKey }?.id

        if let f = file {
            return PathLocation(rootPath: rootKey, correctedPath: f.relativePath, rootIdentifier: rootIdentifier)
        } else if let f = folder {
            return PathLocation(rootPath: rootKey, correctedPath: f.relativePath, rootIdentifier: rootIdentifier)
        }
        return nil
    }

    @MainActor
    private func findExactFileMatch(for relativePath: String) -> FileViewModel? {
        let standardizedRel = (relativePath as NSString).standardizingPath
        for absPath in absolutePathCandidates(forRelativePath: standardizedRel) {
            if let vm = fileHierarchyIndex.filesByFullPath[absPath] {
                return vm
            }
        }
        return nil
    }

    /// Provides baseline file content for a given path.
    /// This is a "back door" method that subclasses can override to provide
    /// content without needing full FileViewModel infrastructure (e.g., for benchmarks).
    /// Default implementation returns nil.
    @MainActor
    func getBaselineContent(forPath relativePath: String, rootIdentifier: UUID?) async -> String? {
        nil
    }

    private func findFilesByName(_ fileName: String, in folder: FolderViewModel) -> [FileViewModel] {
        let normalizedFileName = (fileName as NSString).lastPathComponent
        let standardizedFileName = (normalizedFileName as NSString).standardizingPath
        let lowercaseFileName = standardizedFileName.lowercased()

        var matches: [FileViewModel] = []
        let directFiles: [FileViewModel] = folder.children.compactMap { child in
            if case let .file(file) = child {
                return file
            }
            return nil
        }
        var visitedFolderIDs = Set<UUID>()
        var stack: [FolderViewModel] = [folder]
        while let current = stack.popLast() {
            guard visitedFolderIDs.insert(current.id).inserted else { continue }
            for child in current.children {
                switch child {
                case let .file(file):
                    let fileNameToCompare = (file.name as NSString).lastPathComponent
                    let standardizedFileNameToCompare = (fileNameToCompare as NSString).standardizingPath
                    if standardizedFileNameToCompare.lowercased() == lowercaseFileName {
                        matches.append(file)
                    }
                case let .folder(subFolder):
                    stack.append(subFolder)
                }
            }
        }

        if matches.isEmpty {
            for file in directFiles {
                let fileNameToCompare = (file.name as NSString).lastPathComponent
                let standardizedFileNameToCompare = (fileNameToCompare as NSString).standardizingPath
                if standardizedFileNameToCompare.isSimilar(to: standardizedFileName, threshold: 0.9) {
                    matches.append(file)
                }
            }
        }

        return matches
    }

    /// Toggles a single file while routing the change through the batching
    /// helpers, guaranteeing no duplicate IDs end up in `selectedFiles`.
    func setFileToggled(_ file: FileViewModel, isToggled: Bool) {
        performSelectionBatch {
            // Skip work when the file is already in the requested state
            guard file.isChecked != isToggled else { return }
            file.setIsChecked(isToggled) // onCheckStateChanged updates Sets
        }
    }

    // MARK: - Lightweight ancestor recompute (O(depth), non-recursive)

    @MainActor
    func recomputeAncestorStates(startingAt start: FolderViewModel) {
        var current: FolderViewModel? = start
        var seen = Set<UUID>() // defensive against cycles
        while let folder = current, seen.insert(folder.id).inserted {
            // Recompute based on *direct* children only. This is cheap and
            // correct because leaf states (files / immediate subfolders) were
            // already set during the batch.
            folder.updateCheckboxStateImmediately()
            current = folder.parent
        }
    }

    @MainActor
    private func recomputeAncestorStates(startingAtFolders folders: [FolderViewModel]) {
        guard !folders.isEmpty else { return }
        var seen = Set<UUID>()
        for start in folders {
            var current: FolderViewModel? = start
            while let folder = current, seen.insert(folder.id).inserted {
                folder.updateCheckboxStateImmediately()
                current = folder.parent
            }
        }
    }

    @MainActor
    func toggleFile(_ file: FileViewModel, fromSearch: Bool = false) {
        // Compute the target state once
        let target = !file.isChecked

        // Centralized toggle that coalesces selection updates via performSelectionBatch
        performSelectionBatch {
            // Use the setter that does NOT bubble on each file to avoid repeated recomputes
            setFileToggled(file, isToggled: target)
        }

        // Recompute ancestor checkbox states once (fast local recompute at each level)
        if !fromSearch, let parent = file.parentFolder {
            recomputeAncestorStates(startingAt: parent)
        }
    }

    func getSelectedFiles() -> [FileViewModel] {
        rootFolders.flatMap { folder in
            getAllFiles(in: folder).filter { selectedFileIDs.contains($0.id) }
        }
    }

    private func getAllFiles(in folder: FolderViewModel) -> [FileViewModel] {
        gatherAllFileViewModels(in: folder)
    }

    @MainActor
    func unloadRootFolder(_ folder: FolderViewModel) async {
        let signpost = WorkspaceExitPerf.begin("unloadRootFolder")
        appliedIndexProjectionHandledGenerationByRootID.removeValue(forKey: folder.id)
        defer { WorkspaceExitPerf.end("unloadRootFolder", signpost) }
        let stdRoot = folder.standardizedFullPath
        removeDeferredInitialRootLoadScanRoot(stdRoot)
        unregisterExpansionTracking(for: folder)
        // Folder expansion state is now stored in the FolderViewModel itself
        // No need to unregister from ExpansionManager

        // Remove selections under this folder before removing hierarchy
        dropSelections(underFolderFullPath: folder.fullPath)
        normalizeSelectionState() // Ensure no orphan IDs remain after subtree removal

        removeRootFolderReferences(folder)

        // Drop any queued events for this root and invalidate stale watcher ingress.
        let rootKey = rootKey(forPath: folder.fullPath)
        invalidateRootLoadToken(forRootKey: rootKey)
        _ = advanceRootReplayIngressGeneration(forRootKey: rootKey)
        await workspaceFileContextStore.unregisterDeferredReplayRootGeneration(forRootKey: rootKey)

        // Prune the stale loaded-root cache
        rootShellLoadedPaths.remove(stdRoot)

        // Remove the root folder from the list
        rootFolders.removeAll { $0.id == folder.id }
        rootShellPersistenceKeysByRootKey.removeValue(forKey: rootKey)
        if preloadedWorkspaceFileContextRootsByRootKey[rootKey]?.id == folder.id {
            preloadedWorkspaceFileContextRootsByRootKey.removeValue(forKey: rootKey)
        }

        // Mark snapshot cache as dirty and bump that root gen
        invalidateStaticSnapshot(forRootFullPath: stdRoot)
        await clearPathResolutionCaches()

        if let workspaceRoot = workspaceFileContextRootsByRootKey.removeValue(forKey: rootKey) {
            await workspaceFileContextStore.unloadRoot(id: workspaceRoot.id)
        }

        onRootFoldersChanged?()

        if currentSlicesByRoot.removeValue(forKey: stdRoot) != nil {
            requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")
        }
        // Remove per-root generation entry once the root is fully gone
        removeHierarchyGenerationEntry(forRootFullPath: stdRoot)
    }

    @MainActor
    private func rootReferenceCleanupPlan(for folder: FolderViewModel) -> RootCleanupPlan {
        let rootKey = folder.standardizedFullPath
        let rootPrefix = folder.standardizedFullPath
        if let ownedFolderPaths = fileHierarchyIndex.folderPathsByRoot[rootKey] {
            if let ownedFilePaths = fileHierarchyIndex.filePathsByRoot[rootKey] {
                #if DEBUG
                    if Self.isRootCleanupOwnershipIntegrityValidationEnabled {
                        let descendantFolderPaths = Set(fileHierarchyIndex.foldersByFullPath.keys.filter {
                            StandardizedPath.isDescendant($0, of: rootPrefix)
                        })
                        let descendantFilePaths = Set(fileHierarchyIndex.filesByFullPath.keys.filter {
                            StandardizedPath.isDescendant($0, of: rootPrefix)
                        })
                        if descendantFolderPaths != ownedFolderPaths || descendantFilePaths != ownedFilePaths {
                            return RootCleanupPlan(
                                rootKey: rootKey,
                                folderPaths: descendantFolderPaths,
                                filePaths: descendantFilePaths,
                                usedFallbackGlobalScan: true
                            )
                        }
                    }
                #endif
                return RootCleanupPlan(
                    rootKey: rootKey,
                    folderPaths: ownedFolderPaths,
                    filePaths: ownedFilePaths,
                    usedFallbackGlobalScan: false
                )
            }

            let descendantFolderPaths = Set(fileHierarchyIndex.foldersByFullPath.keys.filter {
                StandardizedPath.isDescendant($0, of: rootPrefix)
            })
            let descendantFilePaths = Set(fileHierarchyIndex.filesByFullPath.keys.filter {
                StandardizedPath.isDescendant($0, of: rootPrefix)
            })
            if descendantFilePaths.isEmpty {
                guard descendantFolderPaths == ownedFolderPaths else {
                    return RootCleanupPlan(
                        rootKey: rootKey,
                        folderPaths: descendantFolderPaths,
                        filePaths: descendantFilePaths,
                        usedFallbackGlobalScan: true
                    )
                }
                fileHierarchyIndex.filePathsByRoot[rootKey] = []
                return RootCleanupPlan(
                    rootKey: rootKey,
                    folderPaths: ownedFolderPaths,
                    filePaths: [],
                    usedFallbackGlobalScan: false
                )
            }
        }

        return RootCleanupPlan(
            rootKey: rootKey,
            folderPaths: Set(fileHierarchyIndex.foldersByFullPath.keys.filter {
                StandardizedPath.isDescendant($0, of: rootPrefix)
            }),
            filePaths: Set(fileHierarchyIndex.filesByFullPath.keys.filter {
                StandardizedPath.isDescendant($0, of: rootPrefix)
            }),
            usedFallbackGlobalScan: true
        )
    }

    /// Removes all index references for a given root folder's entire subtree.
    @MainActor
    private func removeRootFolderReferences(_ folder: FolderViewModel) {
        let cleanup = rootReferenceCleanupPlan(for: folder)
        fileHierarchyIndex.removeOwnedEntries(
            forRootKey: cleanup.rootKey,
            folderPaths: cleanup.folderPaths,
            filePaths: cleanup.filePaths
        )
    }

    private func removeFileHierarchyIndexEntries(for folder: FolderViewModel) {
        var visitedFolderIDs = Set<UUID>()
        removeFileHierarchyIndexEntries(for: folder, visitedFolderIDs: &visitedFolderIDs)
    }

    private func removeFileHierarchyIndexEntries(
        for folder: FolderViewModel,
        visitedFolderIDs: inout Set<UUID>
    ) {
        guard visitedFolderIDs.insert(folder.id).inserted else { return }

        // Remove this folder from index
        fileHierarchyIndex.removeFolder(forKey: folder.standardizedFullPath)

        // Recurse through all children
        for child in folder.children {
            switch child {
            case let .folder(subFolder):
                removeFileHierarchyIndexEntries(for: subFolder, visitedFolderIDs: &visitedFolderIDs)
            case let .file(fileViewModel):
                fileHierarchyIndex.removeFile(forKey: fileViewModel.standardizedFullPath)
            }
        }
    }

    /// Snapshot of all file view models from the index (no tree traversal).
    func allFilesSnapshot(sorted: Bool = true) -> [FileViewModel] {
        let values = Array(fileHierarchyIndex.filesByFullPath.values)
        guard sorted else { return values }
        return values.sorted { $0.standardizedFullPath < $1.standardizedFullPath }
    }

    /// Recursively collect all FileViewModels from all root folders.
    func getAllFileViewModels() -> [FileViewModel] {
        var allFiles: [FileViewModel] = []
        for root in rootFolders {
            allFiles.append(contentsOf: gatherAllFileViewModels(in: root))
        }
        return allFiles
    }

    func getAllFileViewModels(in scope: LookupRootScope) -> [FileViewModel] {
        switch scope {
        case .allLoaded:
            return getAllFileViewModels()
        case .visibleWorkspace, .visibleWorkspacePlusGitData, .sessionBoundWorkspace:
            let allowedRoots = allowedRootPaths(in: scope)
            return allFilesSnapshot(sorted: false).filter {
                allowedRoots.contains($0.standardizedRootFolderPath)
            }
        }
    }

    /// Collect all files that have codemaps available
    @MainActor
    func collectAllFilesWithCodemaps() -> [FileViewModel] {
        let indexedFiles = allFilesSnapshot(sorted: true)
        if !indexedFiles.isEmpty || rootFolders.isEmpty {
            return indexedFiles.filter { $0.fileAPI != nil }
        }
        return getAllFileViewModels().filter { $0.fileAPI != nil }
    }

    /// 4) Helper to gather FileViewModels recursively
    private func gatherAllFileViewModels(in folder: FolderViewModel) -> [FileViewModel] {
        var visitedFolderIDs = Set<UUID>()
        return gatherAllFileViewModels(in: folder, visitedFolderIDs: &visitedFolderIDs)
    }

    private func gatherAllFileViewModels(
        in folder: FolderViewModel,
        visitedFolderIDs: inout Set<UUID>
    ) -> [FileViewModel] {
        guard visitedFolderIDs.insert(folder.id).inserted else { return [] }
        var collected: [FileViewModel] = []
        // Walk the folder's children
        for child in folder.children {
            switch child {
            case let .folder(subFolder):
                collected.append(contentsOf: gatherAllFileViewModels(in: subFolder, visitedFolderIDs: &visitedFolderIDs))
            case let .file(fileVM):
                collected.append(fileVM)
            }
        }
        return collected
    }

    @MainActor
    func getFilesRecursively(under folder: FolderViewModel) -> [FileViewModel] {
        gatherAllFileViewModels(in: folder)
    }

    /// Public API to handle window focus changes
    @MainActor
    func setWindowFocused(_ focused: Bool) {
        isWindowFocused = focused
        let routingVersion = advanceDeferredReplayRoutingVersion()
        let isReplayActive = isReplayingDeltas
        let store = workspaceFileContextStore
        Task { [weak self, store, focused, isReplayActive, routingVersion] in
            await store.updateDeferredReplayRoutingState(
                isWindowFocused: focused,
                isReplayActive: isReplayActive,
                routingVersion: routingVersion
            )
            guard focused, let self else { return }
            await flushPendingDeltas()
        }
    }

    // Helper to replay queued deltas once the app regains focus
    // MARK: – Window-focus replay

    @MainActor
    func flushPendingDeltas() async {
        guard !isReplayingDeltas else { return }
        await flushPendingDeltas(aggressive: false)
    }

    @MainActor
    func flushPendingDeltas(aggressive: Bool) async {
        while true {
            // If another replay is running:
            while true {
                if let existingTask = deltaReplayTask {
                    if aggressive {
                        // Wait for the existing replay to finish (no spin-wait)
                        await existingTask.value
                        continue // Re-check in case another started
                    } else {
                        // Non-aggressive path: do nothing if a replay is in progress
                        return
                    }
                }
                break
            }

            guard isWindowFocused || aggressive else { return }
            guard await workspaceFileContextStore.hasDeferredReplayPendingWork() || aggressive else { return }

            // Start a new replay
            let runID = UUID()
            deltaReplayRunID = runID
            isReplayingDeltas = true
            _ = advanceDeferredReplayRoutingVersion()
            await syncDeferredReplayRoutingState()

            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await runDeltaReplay(aggressive: aggressive)
                // Only clear if this is still our run
                if deltaReplayRunID == runID {
                    deltaReplayTask = nil
                    deltaReplayRunID = nil
                    isReplayingDeltas = false
                    _ = advanceDeferredReplayRoutingVersion()
                    await syncDeferredReplayRoutingState()
                }
            }
            deltaReplayTask = task
            await task.value

            guard isWindowFocused, await workspaceFileContextStore.hasDeferredReplayPendingWork() else { return }
        }
    }

    /// Internal implementation of delta replay logic.
    @MainActor
    private func runDeltaReplay(aggressive: Bool) async {
        let signpost = RepoFileReplayPerf.begin("runDeltaReplay")
        defer { RepoFileReplayPerf.end("runDeltaReplay", signpost) }
        let pendingSnapshotAtStart = await workspaceFileContextStore.deferredReplayPendingWorkSnapshot()
        let pendingRootCountAtStart = pendingSnapshotAtStart.pendingRootCount
        let pendingDeltaCountAtStart = pendingSnapshotAtStart.pendingDeltaCount
        let baseChunkSize = aggressive ? 10000 : 100
        let baseInterChunkDelay: UInt64 = aggressive ? 0 : 32_000_000 // 32 ms
        let chunkSize: Int
        let interChunkDelay: UInt64
        #if DEBUG
            let totalStartMS = debugPerfTimestampMS()
            var preReplayServiceFlushes: [DeltaReplayPerfSample.ServiceFlushSample] = []
            var postReplayServiceFlushes: [DeltaReplayPerfSample.ServiceFlushSample] = []
            var replayedRoots: [RootReplayPerfSample] = []
            var rootPasses: [RootReplayPassPerfSample] = []
            var totalRootPassCount = 0
            var totalChunkCount = 0
            var totalRootPassFinalizeDurationMS = 0.0
            var totalCoalescedDeltaCount = 0
            var totalDiscardedDeltaCount = 0
            var totalCoalesceDurationMS = 0.0
            var totalPreparationDurationMS = 0.0
            var totalApplyAwaitDurationMS = 0.0
            var totalYieldDurationMS = 0.0
            var totalInterChunkSleepDurationMS = 0.0
            var totalDeltaLoopDurationMS = 0.0
            var totalFlushPendingInsertsDurationMS = 0.0
            var totalUpdateFolderStatesDurationMS = 0.0
            var totalIncrementalIndexCleanupDurationMS = 0.0
            var totalOnRootFoldersChangedDurationMS = 0.0
            var totalOnRootFoldersChangedInvocationCount = 0
            var totalSnapshotInvalidationCount = 0
            var totalDeltaAppliedPublisherInvocationCount = 0
            var totalReplayCodeScanBatchInvocationCount = 0
            var totalReplaySliceRebaseBatchInvocationCount = 0
            var totalRebuildDurationMS = 0.0
            var totalCodeScanBatchFileCount = 0
            var totalSliceRebaseCandidateCount = 0
            var totalInvalidateSnapshotDurationMS = 0.0
            chunkSize = max(deltaReplayChunkSizeOverride ?? baseChunkSize, 1)
            interChunkDelay = deltaReplayInterChunkDelayNanosecondsOverride ?? baseInterChunkDelay
        #else
            chunkSize = baseChunkSize
            interChunkDelay = baseInterChunkDelay
        #endif
        var replayPassCount = 0

        #if DEBUG
            func recordCurrentReplaySample(
                passIndex: Int,
                chunkIndex: Int,
                chunkCount: Int,
                applyAwaitDurationMS: Double,
                yieldDurationMS: Double,
                yieldedAfterChunk: Bool,
                interChunkSleepDurationMS: Double
            ) {
                guard var sample = currentRootReplayPerfSample else { return }
                sample.passIndex = passIndex
                sample.chunkIndexInPass = chunkIndex
                sample.chunkCountInPass = chunkCount
                sample.applyAwaitDurationMS = applyAwaitDurationMS
                sample.yieldedAfterChunk = yieldedAfterChunk
                sample.yieldDurationMSAfterChunk = yieldDurationMS
                sample.interChunkSleepDurationMSAfterChunk = interChunkSleepDurationMS
                replayedRoots.append(sample)
                totalDeltaLoopDurationMS += sample.deltaLoopDurationMS
                totalFlushPendingInsertsDurationMS += sample.flushPendingInsertsDurationMS
                totalUpdateFolderStatesDurationMS += sample.updateFolderStatesDurationMS
                totalIncrementalIndexCleanupDurationMS += sample.incrementalIndexCleanupDurationMS
                totalRebuildDurationMS += sample.rebuildDurationMS ?? 0
                currentRootReplayPerfSample = nil
            }

            func recordReplayRootPassSample(_ sample: RootReplayPassPerfSample) {
                rootPasses.append(sample)
                totalRootPassFinalizeDurationMS += sample.finalizeDurationMS
                totalOnRootFoldersChangedDurationMS += sample.onRootFoldersChangedDurationMS
                totalOnRootFoldersChangedInvocationCount += sample.onRootFoldersChangedInvocationCount
                totalSnapshotInvalidationCount += sample.snapshotInvalidationCount
                totalDeltaAppliedPublisherInvocationCount += sample.deltaAppliedPublisherInvocationCount
                totalReplayCodeScanBatchInvocationCount += sample.codeScanBatchInvocationCount
                totalReplaySliceRebaseBatchInvocationCount += sample.sliceRebaseBatchInvocationCount
                totalCodeScanBatchFileCount += sample.codeScanBatchFileCount
                totalSliceRebaseCandidateCount += sample.sliceRebaseCandidateCount
                totalInvalidateSnapshotDurationMS += sample.invalidateSnapshotDurationMS
            }
        #endif

        @MainActor
        func replayPreparedBatch(
            _ preparedBatch: PreparedFileSystemReplayBatch,
            passIndex: Int,
            allowInterChunkDelay: Bool
        ) async {
            #if DEBUG
                totalCoalescedDeltaCount += preparedBatch.coalescedDeltaCount
                totalDiscardedDeltaCount += preparedBatch.discardedDeltaCount
                totalCoalesceDurationMS += preparedBatch.coalesceDurationMS
                totalPreparationDurationMS += preparedBatch.preparationDurationMS
            #endif
            let chunkCountInPass = preparedBatch.chunks.count
            #if DEBUG
                totalChunkCount += chunkCountInPass
            #endif
            var accumulator = ReplayRootPassAccumulator(rootKey: preparedBatch.rootKey)
            for (chunkIndex, chunk) in preparedBatch.chunks.enumerated() {
                #if DEBUG
                    let applyAwaitStartMS = debugPerfTimestampMS()
                #endif
                await applyPreparedFileSystemDeltas(
                    chunk: chunk,
                    from: preparedBatch,
                    forRootKey: preparedBatch.rootKey,
                    accumulator: &accumulator
                )
                #if DEBUG
                    let applyAwaitDurationMS = debugPerfElapsedMS(since: applyAwaitStartMS)
                    totalApplyAwaitDurationMS += applyAwaitDurationMS
                    var yieldDurationMS = 0.0
                    var yieldedAfterChunk = false
                    var interChunkSleepDurationMS = 0.0
                #endif
                let hasMoreChunksInPass = chunkIndex < chunkCountInPass - 1
                #if DEBUG
                    let yieldStartMS = debugPerfTimestampMS()
                #endif
                await Task.yield()
                #if DEBUG
                    yieldedAfterChunk = true
                    yieldDurationMS = debugPerfElapsedMS(since: yieldStartMS)
                    totalYieldDurationMS += yieldDurationMS
                #endif
                if allowInterChunkDelay, hasMoreChunksInPass, interChunkDelay > 0 {
                    #if DEBUG
                        let sleepStartMS = debugPerfTimestampMS()
                    #endif
                    try? await Task.sleep(nanoseconds: interChunkDelay)
                    #if DEBUG
                        interChunkSleepDurationMS = debugPerfElapsedMS(since: sleepStartMS)
                        totalInterChunkSleepDurationMS += interChunkSleepDurationMS
                    #endif
                }
                #if DEBUG
                    recordCurrentReplaySample(
                        passIndex: passIndex,
                        chunkIndex: chunkIndex,
                        chunkCount: chunkCountInPass,
                        applyAwaitDurationMS: applyAwaitDurationMS,
                        yieldDurationMS: yieldDurationMS,
                        yieldedAfterChunk: yieldedAfterChunk,
                        interChunkSleepDurationMS: interChunkSleepDurationMS
                    )
                #endif
            }
            if let passSample = finalizeReplayRootPass(
                accumulator,
                passIndex: passIndex,
                chunkCount: chunkCountInPass
            ) {
                #if DEBUG
                    recordReplayRootPassSample(passSample)
                #endif
            }
        }

        if aggressive {
            let flushSamples = await workspaceFileContextStore.awaitAppliedIngressForAllRoots()
            #if DEBUG
                preReplayServiceFlushes.append(contentsOf: flushSamples.map {
                    .init(rootKey: $0.rootPath, pendingRawEventCountBeforeFlush: $0.pendingRawEventCountBeforeFlush)
                })
            #endif
            await Task.yield()
        }

        while true {
            replayPassCount += 1
            let preparedBatches = await workspaceFileContextStore.drainDeferredReplayPreparedBatches(
                preferredRootOrder: rootFolders.map(\.standardizedFullPath),
                chunkSize: chunkSize
            )
            if preparedBatches.isEmpty {
                await Task.yield()
                if await workspaceFileContextStore.hasDeferredReplayPendingWork() {
                    continue
                }
                break
            }
            for preparedBatch in preparedBatches {
                #if DEBUG
                    totalRootPassCount += 1
                #endif
                await replayPreparedBatch(
                    preparedBatch,
                    passIndex: replayPassCount,
                    allowInterChunkDelay: true
                )
            }
        }

        if aggressive {
            let flushSamples = await workspaceFileContextStore.awaitAppliedIngressForAllRoots()
            #if DEBUG
                postReplayServiceFlushes.append(contentsOf: flushSamples.map {
                    .init(rootKey: $0.rootPath, pendingRawEventCountBeforeFlush: $0.pendingRawEventCountBeforeFlush)
                })
            #endif
            await Task.yield()

            while true {
                replayPassCount += 1
                let preparedBatches = await workspaceFileContextStore.drainDeferredReplayPreparedBatches(
                    preferredRootOrder: rootFolders.map(\.standardizedFullPath),
                    chunkSize: chunkSize
                )
                if preparedBatches.isEmpty {
                    await Task.yield()
                    if await workspaceFileContextStore.hasDeferredReplayPendingWork() {
                        continue
                    }
                    break
                }
                for preparedBatch in preparedBatches {
                    #if DEBUG
                        totalRootPassCount += 1
                    #endif
                    await replayPreparedBatch(
                        preparedBatch,
                        passIndex: replayPassCount,
                        allowInterChunkDelay: false
                    )
                }
            }
        }

        #if DEBUG
            lastDeltaReplayPerfSample = DeltaReplayPerfSample(
                aggressive: aggressive,
                pendingRootCountAtStart: pendingRootCountAtStart,
                pendingDeltaCountAtStart: pendingDeltaCountAtStart,
                whileLoopPassCount: replayPassCount,
                totalRootPassCount: totalRootPassCount,
                totalChunkCount: totalChunkCount,
                totalRootPassFinalizeDurationMS: totalRootPassFinalizeDurationMS,
                totalCoalescedDeltaCount: totalCoalescedDeltaCount,
                totalDiscardedDeltaCount: totalDiscardedDeltaCount,
                totalCoalesceDurationMS: totalCoalesceDurationMS,
                totalPreparationDurationMS: totalPreparationDurationMS,
                totalApplyAwaitDurationMS: totalApplyAwaitDurationMS,
                totalYieldDurationMS: totalYieldDurationMS,
                totalInterChunkSleepDurationMS: totalInterChunkSleepDurationMS,
                totalDeltaLoopDurationMS: totalDeltaLoopDurationMS,
                totalFlushPendingInsertsDurationMS: totalFlushPendingInsertsDurationMS,
                totalUpdateFolderStatesDurationMS: totalUpdateFolderStatesDurationMS,
                totalIncrementalIndexCleanupDurationMS: totalIncrementalIndexCleanupDurationMS,
                totalOnRootFoldersChangedDurationMS: totalOnRootFoldersChangedDurationMS,
                totalOnRootFoldersChangedInvocationCount: totalOnRootFoldersChangedInvocationCount,
                totalSnapshotInvalidationCount: totalSnapshotInvalidationCount,
                totalDeltaAppliedPublisherInvocationCount: totalDeltaAppliedPublisherInvocationCount,
                totalReplayCodeScanBatchInvocationCount: totalReplayCodeScanBatchInvocationCount,
                totalReplaySliceRebaseBatchInvocationCount: totalReplaySliceRebaseBatchInvocationCount,
                totalRebuildDurationMS: totalRebuildDurationMS,
                totalCodeScanBatchFileCount: totalCodeScanBatchFileCount,
                totalSliceRebaseCandidateCount: totalSliceRebaseCandidateCount,
                totalInvalidateSnapshotDurationMS: totalInvalidateSnapshotDurationMS,
                preReplayServiceFlushes: preReplayServiceFlushes,
                postReplayServiceFlushes: postReplayServiceFlushes,
                replayedRoots: replayedRoots,
                rootPasses: rootPasses,
                totalDurationMS: debugPerfElapsedMS(since: totalStartMS)
            )
        #endif
    }

    @MainActor
    func unloadRootFolderPath(_ path: String) async {
        let stdURL = canonicalURL(for: path, assumingDirectory: true)
        await unloadRootFolder(for: stdURL)
    }

    func unloadAllRootFolders(cancelScans: Bool = true) async {
        let signpost = WorkspaceExitPerf.begin("unloadAllRootFolders")
        defer { WorkspaceExitPerf.end("unloadAllRootFolders", signpost) }
        await unloadAllRootFoldersFast(cancelScans: cancelScans)
    }

    @MainActor
    private func unloadAllRootFoldersFast(cancelScans: Bool) async {
        clearDeferredInitialRootLoadScanState(keepingActiveDeferral: isInitialRootLoadScanDeferralActive)
        invalidateAllRootLoadTokens()
        currentFolderLoadingTask?.cancel()
        currentFolderLoadingTask = nil
        currentFolderLoadingTaskID = nil
        isLoading = false

        // No longer need to clear ExpansionManager
        // Expansion state is stored directly in each FolderViewModel
        let roots = rootFolders
        let hadRoots = !roots.isEmpty
        let rootPaths = roots.map(\.fullPath)
        let workspaceRoots = Array(workspaceFileContextRootsByRootKey.values)
        let preloadedWorkspaceRoots = Array(preloadedWorkspaceFileContextRootsByRootKey.values)
        let storeRootsToUnload = workspaceRoots + preloadedWorkspaceRoots

        for rootPath in rootPaths {
            _ = advanceRootReplayIngressGeneration(forRootKey: rootKey(forPath: rootPath))
        }

        // Stop any replay/coalescing work before tearing down roots.
        deltaReplayTask?.cancel()
        deltaReplayTask = nil
        deltaReplayRunID = nil
        isReplayingDeltas = false
        _ = advanceDeferredReplayRoutingVersion()
        await syncDeferredReplayRoutingState()
        await workspaceFileContextStore.clearDeferredReplayBuffer()
        pendingChildInserts.removeAll()
        pendingInsertParents.removeAll()
        isInsertFlushScheduled = false

        for folder in roots {
            unregisterExpansionTracking(for: folder)
        }

        // Detach visible UI roots and clear UI-owned state before slow actor-store
        // teardown (watcher stop, index/codemap unload). This avoids the window where
        // rootFolders still reference roots whose store records are already gone.
        workspaceFileContextRootsByRootKey.removeAll()
        preloadedWorkspaceFileContextRootsByRootKey.removeAll()
        rootShellPersistenceKeysByRootKey.removeAll()
        rootFolders.removeAll()
        folderBeingAdded = nil
        currentSlicesByRoot.removeAll()
        resetSelection() // Atomic selection reset
        error = nil
        fileHierarchyIndex.clearAll()
        fileHierarchyIndex = FileHierarchyIndex()
        appliedIndexProjectionHandledGenerationByRootID.removeAll(keepingCapacity: true)
        autoCodemapSyncTask?.cancel()
        autoCodemapSyncTask = nil
        resetAutoCodemapFiles([])
        rootShellLoadedPaths.removeAll()
        rootHierarchyGenerations.removeAll()
        hierarchyGenerationSignature &+= 1
        invalidateStaticSnapshot(forRootFullPath: nil)
        await clearPathResolutionCaches()
        await Task.yield()

        await workspaceFileContextStore.unloadRoots(ids: storeRootsToUnload.map(\.id))

        if cancelScans {
            await cancelAllScans()
        }

        // Preserve a clean final state after actor cleanup and any unload events that
        // raced in from the store bridge.
        workspaceFileContextRootsByRootKey.removeAll()
        preloadedWorkspaceFileContextRootsByRootKey.removeAll()
        rootShellPersistenceKeysByRootKey.removeAll()
        rootFolders.removeAll()
        folderBeingAdded = nil
        pendingChildInserts.removeAll()
        pendingInsertParents.removeAll()
        isInsertFlushScheduled = false
        currentSlicesByRoot.removeAll()
        resetSelection()
        fileHierarchyIndex.clearAll()
        fileHierarchyIndex = FileHierarchyIndex()
        appliedIndexProjectionHandledGenerationByRootID.removeAll(keepingCapacity: true)
        rootShellLoadedPaths.removeAll()
        rootHierarchyGenerations.removeAll()
        invalidateStaticSnapshot(forRootFullPath: nil)
        await clearPathResolutionCaches()
        if hadRoots {
            allFoldersUnloadedPublisher.send(())
        }
        onRootFoldersChanged?()
    }

    @MainActor
    func toggleFolder(_ folder: FolderViewModel, fromSearch: Bool = false) {
        guard !isLoading, folder.isValid else { return }

        // Flip the entire subtree in a single main-actor pass; no yielding.
        performSelectionBatch {
            let newState: CheckboxState = (folder.checkboxState == .unchecked) ? .checked : .unchecked
            setFolderStateOnSubtree(folder, newState: newState)
        }

        // One cheap recompute from this folder up to the root (O(depth)).
        recomputeAncestorStates(startingAt: folder)

        // Notify any listeners that the folder row can refresh UI affordances.
        folderRefreshPublisher.send(folder)
    }

    /**
     @MainActor
     private func setFolderStateOnSubtree(_ folder: FolderViewModel, newState: CheckboxState) {
     	var stack = [folder]
     	while let current = stack.popLast() {
     		for child in current.children {
     			switch child {
     			case .file(let fileVM):
     				fileVM.setIsChecked(newState == .checked)
     			case .folder(let subFolder):
     				stack.append(subFolder)
     			}
     		}
     		current.updateCheckboxStateImmediately(newState: newState)
     	}
     }
     */
    @MainActor
    private func setFolderStateOnSubtree(
        _ folder: FolderViewModel,
        newState: CheckboxState
    ) {
        var stack = [folder]
        while let current = stack.popLast() {
            for child in current.children {
                switch child {
                case let .file(fileVM):
                    let target = (newState == .checked)
                    // Avoid emitting onCheckStateChanged when the state is already correct
                    if fileVM.isChecked != target {
                        fileVM.setIsChecked(target)
                    }
                case let .folder(subFolder):
                    stack.append(subFolder)
                }
            }
            current.updateCheckboxStateImmediately(newState: newState)
        }
    }

    @MainActor
    private func setFolderStateToUncheckedOnlyWhereChecked(_ folder: FolderViewModel) {
        // Batch uncheck all checked files in the subtree
        performSelectionBatch {
            var stack: [FolderViewModel] = [folder]
            while let current = stack.popLast() {
                for child in current.children {
                    switch child {
                    case let .folder(subFolder):
                        stack.append(subFolder)
                    case let .file(childFile):
                        if childFile.isChecked {
                            childFile.setIsChecked(false)
                        }
                    }
                }
            }
        }

        // Fast O(depth) recompute up the chain instead of full recursive walk
        recomputeAncestorStates(startingAt: folder)
    }

    @MainActor
    private func updateFolderStates() {
        for rootFolder in rootFolders {
            _ = updateFolderStateRecursive(rootFolder)
        }
    }

    @MainActor
    private func updateFolderStateRecursive(_ folder: FolderViewModel) -> CheckboxState {
        var visitedFolderIDs = Set<UUID>()
        return updateFolderStateRecursive(folder, visitedFolderIDs: &visitedFolderIDs)
    }

    @MainActor
    private func updateFolderStateRecursive(
        _ folder: FolderViewModel,
        visitedFolderIDs: inout Set<UUID>
    ) -> CheckboxState {
        guard visitedFolderIDs.insert(folder.id).inserted else { return folder.checkboxState }
        var checkedCount = 0
        var uncheckedCount = 0
        var mixedCount = 0
        let totalCount = folder.children.count

        for child in folder.children {
            switch child {
            case let .file(fileVM):
                if fileVM.isChecked {
                    checkedCount += 1
                } else {
                    uncheckedCount += 1
                }
            case let .folder(folderVM):
                let childState = updateFolderStateRecursive(folderVM, visitedFolderIDs: &visitedFolderIDs)
                switch childState {
                case .checked:
                    checkedCount += 1
                case .unchecked:
                    uncheckedCount += 1
                case .mixed:
                    mixedCount += 1
                }
            }
        }

        let newState: CheckboxState = if mixedCount > 0 || (checkedCount > 0 && uncheckedCount > 0) {
            .mixed
        } else if checkedCount == totalCount, totalCount > 0 {
            .checked
        } else if uncheckedCount == totalCount, totalCount > 0 {
            .unchecked
        } else {
            .unchecked
        }

        folder.updateCheckboxStateImmediately(newState: newState)
        return newState
    }

    @MainActor
    func clearSelection(persistWorkspace: Bool = false) async {
        _ = try? await setSelectionSlices(entries: [], mode: .set, persistWorkspace: false)
        clearCheckedFilesOnly()
        finalizeSelectionClear(persistWorkspace: persistWorkspace)
    }

    @MainActor
    private func clearCheckedFilesOnly() {
        let filesToUncheck = selectedFiles

        // Batch all deselections into a single mutation & cache update
        performSelectionBatch {
            for file in filesToUncheck {
                file.setIsChecked(false)
            }
        }

        // Recompute only affected ancestor chains (unique parents)
        var seen = Set<UUID>()
        var parents: [FolderViewModel] = []
        for file in filesToUncheck {
            if let p = file.parentFolder, seen.insert(p.id).inserted {
                parents.append(p)
            }
        }
        for parent in parents {
            recomputeAncestorStates(startingAt: parent)
        }
    }

    @MainActor
    private func finalizeSelectionClear(persistWorkspace: Bool) {
        selectionClearedPublisher.send()
        autoCodemapSyncTask?.cancel()
        resetAutoCodemapFiles([])
        codemapAutoEnabled = true

        guard persistWorkspace else { return }
        requestWorkspaceSaveDebounced()
    }

    @MainActor
    private func requestWorkspaceSaveDebounced(delayNanoseconds: UInt64 = 150_000_000) {
        workspaceManager?.markWorkspaceDirty()
        workspaceSaveDebounceTask?.cancel()
        workspaceSaveDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard let self else { return }
            guard !Task.isCancelled else { return }
            workspaceManager?.pollAndSaveState(source: .workspaceFilesDebouncedSelectionSave)
            workspaceSaveDebounceTask = nil
        }
    }

    func findFullPath(for relativePath: String) -> String? {
        for rootFolder in rootFolders {
            if let fullPath = searchForFile(withRelativePath: relativePath, in: rootFolder, currentPath: rootFolder.fullPath) {
                return fullPath
            }
        }
        return nil
    }

    private func searchForFile(
        withRelativePath relativePath: String,
        in folder: FolderViewModel,
        currentPath: String
    ) -> String? {
        var visitedFolderIDs = Set<UUID>()
        return searchForFile(
            withRelativePath: relativePath,
            in: folder,
            currentPath: currentPath,
            visitedFolderIDs: &visitedFolderIDs
        )
    }

    private func searchForFile(
        withRelativePath relativePath: String,
        in folder: FolderViewModel,
        currentPath: String,
        visitedFolderIDs: inout Set<UUID>
    ) -> String? {
        guard visitedFolderIDs.insert(folder.id).inserted else { return nil }
        for child in folder.children {
            switch child {
            case let .file(file):
                if file.relativePath == relativePath {
                    return file.fullPath
                }
            case let .folder(subFolder):
                let newPath = (currentPath as NSString).appendingPathComponent(subFolder.name)
                if let path = searchForFile(
                    withRelativePath: relativePath,
                    in: subFolder,
                    currentPath: newPath,
                    visitedFolderIDs: &visitedFolderIDs
                ) {
                    return path
                }
            }
        }
        return nil
    }

    @MainActor
    private func clearFolderSelectionRecursive(_ folder: FolderViewModel) {
        var visitedFolderIDs = Set<UUID>()
        var stack: [FolderViewModel] = [folder]
        while let current = stack.popLast() {
            guard visitedFolderIDs.insert(current.id).inserted else { continue }
            for child in current.children {
                switch child {
                case let .folder(childFolder):
                    stack.append(childFolder)
                case let .file(childFile):
                    childFile.setIsChecked(false)
                }
            }
        }
    }

    private func updateSelectedFiles() async {
        let selected = await withTaskGroup(of: [FileViewModel].self) { group in
            for folder in self.rootFolders {
                group.addTask {
                    await self.getAllSelectedFiles(in: folder)
                }
            }

            var allSelected: [FileViewModel] = []
            for await folderSelected in group {
                allSelected.append(contentsOf: folderSelected)
            }
            return allSelected
        }

        // Keep both collections consistent
        let newIDs = Set(selected.map(\.id))
        commitSelectionState(selected, newIDs)
    }

    func isFileSelected(_ requestedPath: String) -> Bool {
        let trimmedRequest = requestedPath.trimmingCharacters(in: .whitespacesAndNewlines)

        // Gather the fullPaths of all currently selected files
        let selectedFullPaths = selectedFiles.map(\.fullPath)

        // Use your String extension’s findClosestPath method to see if any match
        if let _ = String.findClosestPath(trimmedRequest, among: selectedFullPaths) {
            return true
        }
        return false
    }

    @MainActor
    private func getAllSelectedFiles(in folder: FolderViewModel) async -> [FileViewModel] {
        var files: [FileViewModel] = []
        var visitedFolderIDs = Set<UUID>()
        var stack: [FolderViewModel] = [folder]
        while let current = stack.popLast() {
            guard visitedFolderIDs.insert(current.id).inserted else { continue }
            for child in current.children {
                switch child {
                case let .file(file) where file.isChecked:
                    files.append(file)
                case let .folder(subFolder):
                    stack.append(subFolder)
                default:
                    break
                }
            }
        }
        return files
    }

    @MainActor
    func updateParentFolders(for item: any FileSystemItemViewModel) async {
        if let fileVM = item as? FileViewModel {
            var curFolder = fileVM.parentFolder
            while let folder = curFolder {
                folder.updateCheckboxStateImmediately()
                curFolder = folder.parent
            }
        } else if let folderVM = item as? FolderViewModel {
            var curFolder = folderVM.parent
            while let parentFolder = curFolder {
                parentFolder.updateCheckboxStateImmediately()
                curFolder = parentFolder.parent
            }
        }
    }

    func findParentFolder(for item: any FileSystemItemViewModel) async -> FolderViewModel? {
        for rootFolder in rootFolders {
            if let parent = await findParentFolderRecursive(rootFolder, item) {
                return parent
            }
        }
        return nil
    }

    private func findParentFolderRecursive(_ folder: FolderViewModel, _ item: any FileSystemItemViewModel) async -> FolderViewModel? {
        var visitedFolderIDs = Set<UUID>()
        var stack: [FolderViewModel] = [folder]
        while let current = stack.popLast() {
            guard visitedFolderIDs.insert(current.id).inserted else { continue }
            for child in current.children {
                switch child {
                case let .folder(childFolder):
                    if childFolder.id == item.id {
                        return current
                    }
                    stack.append(childFolder)
                case let .file(childFile):
                    if childFile.id == item.id {
                        return current
                    }
                }
            }
        }
        return nil
    }

    private func createFileThroughWorkspaceStore(
        rootFolder: FolderViewModel,
        correctedPath: String,
        content: String
    ) async throws {
        guard let workspaceRoot = workspaceFileContextRootsByRootKey[rootFolder.standardizedFullPath] else {
            throw FileManagerError.fileSystemServiceNotFoundWithContext("Workspace store root unavailable for '\(rootFolder.standardizedFullPath)'.")
        }
        try await workspaceFileContextStore.createFile(
            rootID: workspaceRoot.id,
            relativePath: correctedPath,
            content: content
        )
    }

    private func editFileThroughWorkspaceStore(
        rootPath: String,
        correctedPath: String,
        newContent: String
    ) async throws {
        let rootKey = StandardizedPath.absolute(rootPath)
        guard let workspaceRoot = workspaceFileContextRootsByRootKey[rootKey] else {
            throw FileManagerError.fileSystemServiceNotFoundWithContext("Workspace store root unavailable for '\(rootKey)'.")
        }
        try await workspaceFileContextStore.editFile(
            rootID: workspaceRoot.id,
            relativePath: correctedPath,
            newContent: newContent
        )
    }

    private func moveFileThroughWorkspaceStore(
        rootFolder: FolderViewModel,
        oldRel: String,
        newRel: String
    ) async throws {
        guard let workspaceRoot = workspaceFileContextRootsByRootKey[rootFolder.standardizedFullPath] else {
            throw FileManagerError.fileSystemServiceNotFoundWithContext("Workspace store root unavailable for '\(rootFolder.standardizedFullPath)'.")
        }
        try await workspaceFileContextStore.moveFile(
            rootID: workspaceRoot.id,
            from: oldRel,
            to: newRel
        )
    }

    private func deleteFileThroughWorkspaceStore(
        rootPath: String,
        correctedPath: String
    ) async throws {
        let rootKey = StandardizedPath.absolute(rootPath)
        guard let workspaceRoot = workspaceFileContextRootsByRootKey[rootKey] else {
            throw FileManagerError.fileSystemServiceNotFoundWithContext("Workspace store root unavailable for '\(rootKey)'.")
        }
        try await workspaceFileContextStore.deleteFile(rootID: workspaceRoot.id, relativePath: correctedPath)
    }

    private func moveItemToTrashThroughWorkspaceStore(
        rootPath: String,
        correctedPath: String
    ) async throws {
        let rootKey = StandardizedPath.absolute(rootPath)
        guard let workspaceRoot = workspaceFileContextRootsByRootKey[rootKey] else {
            throw FileManagerError.fileSystemServiceNotFoundWithContext("Workspace store root unavailable for '\(rootKey)'.")
        }
        try await workspaceFileContextStore.moveItemToTrash(rootID: workspaceRoot.id, relativePath: correctedPath)
    }

    func createFile(atRelativePath userPath: String, content: String, selectAfterCreate: Bool = true) async throws {
        let selectedPaths = Set(selectedFiles.map(\.fullPath))
        guard let creationResult = await workspaceFileContextStore.findCreationPath(
            userPath: userPath,
            selectedFileFullPaths: selectedPaths
        ) else {
            // Provide workspace-aware context
            let msg: String
            if visibleRootFolders.isEmpty {
                msg = "No workspace is currently loaded in this window. Use the 'manage_workspaces' tool with action: 'list' to see available workspaces, then action: 'switch' to load one."
            } else {
                let roots = visibleRootFolders.map(\.name).joined(separator: ", ")
                msg = "Could not resolve a destination within the current workspace for '\(userPath)'. Loaded roots: \(roots). Use 'manage_workspaces' to switch to a workspace containing this path, or ensure the path is inside one of these folders."
            }
            throw FileManagerError.fileSystemServiceNotFoundWithContext(msg)
        }

        // Find the actual root folder from our list
        let standardizedCreationRootPath = (creationResult.rootFolder.fullPath as NSString).standardizingPath
        guard let rootFolder = rootFolders.first(where: { $0.standardizedFullPath == standardizedCreationRootPath }) else {
            let msg = "Internal error: computed creation root is not currently loaded."
            throw FileManagerError.fileSystemServiceNotFoundWithContext(msg)
        }

        let correctedPath = creationResult.componentsToCreate.joined(separator: "/")

        // Insert canonical key BEFORE the FS operation to avoid race with incoming FSEvents.
        let creationKey = makeCreationKey(rootFullPath: rootFolder.fullPath, relPath: correctedPath)
        if selectAfterCreate {
            newlyCreatedFilePaths.insert(creationKey)
        }
        do {
            try await createFileThroughWorkspaceStore(
                rootFolder: rootFolder,
                correctedPath: correctedPath,
                content: content
            )
        } catch {
            // Roll back the marker on failure to avoid stale selection entries.
            if selectAfterCreate {
                newlyCreatedFilePaths.remove(creationKey)
            }
            throw error
        }
    }

    enum CreatePathResolutionPolicy {
        case literalPreferredIfStronger
        case canonicalAliasFirst
    }

    @MainActor
    func writeFileFromTool(
        userPath: String,
        content: String,
        ifExists: String,
        selectAfterCreate: Bool,
        pathResolutionPolicy: CreatePathResolutionPolicy = .literalPreferredIfStronger
    ) async throws {
        let resolverRoots = visibleRootFolders.map {
            CreatePathPreflight.Root(id: $0.id, name: $0.name, fullPath: $0.fullPath)
        }

        let preflight: CreatePathPreflight.Result
        do {
            // Use relaxed mode: allow relative paths without alias if they can be resolved unambiguously
            preflight = try CreatePathPreflight.validate(
                userPath: userPath,
                visibleRoots: resolverRoots,
                mode: .allowImplicitRootIfUnambiguous
            )
        } catch let error as CreatePathPreflight.Error {
            switch error {
            case .emptyPath:
                throw FileManagerError.fileSystemServiceNotFoundWithContext("path is required for file creation.")
            case let .ambiguousAlias(alias, matchingRoots):
                let rendered = matchingRoots.map(\.renderedLabel).joined(separator: "; ")
                throw FileManagerError.fileSystemServiceNotFoundWithContext(
                    "Ambiguous root alias '\(alias)'. It matches multiple loaded roots: \(rendered). " +
                        "Use an absolute path or rename roots so aliases are unique."
                )
            case let .missingAliasWithMultipleRoots(loadedRoots):
                // This case should no longer be thrown in relaxed mode, but keep for safety
                let rootsList = loadedRoots.map(\.renderedLabel).joined(separator: "; ")
                throw FileManagerError.fileSystemServiceNotFoundWithContext(
                    "Multiple workspace roots are loaded; new files must use either an absolute path inside a loaded root " +
                        "(e.g., '/path/to/root/new_file.swift') or a root-alias prefixed path 'RootName/...'. " +
                        "Loaded roots: \(rootsList)"
                )
            }
        }

        let standardizedInput = preflight.normalizedPath
        let policy = ifExists.lowercased()
        if policy != "overwrite", policy != "error" {
            throw FileManagerError.fileSystemServiceNotFoundWithContext(
                "Invalid if_exists value '\(ifExists)'. Use 'error' or 'overwrite'."
            )
        }

        if pathResolutionPolicy == .literalPreferredIfStronger, let literalCreateResult = resolvedLiteralCreateResult(
            for: standardizedInput,
            preflight: preflight
        ) {
            try await writeFileFromTool(
                usingResolvedCreationResult: literalCreateResult,
                userPath: userPath,
                content: content,
                ifExistsPolicy: policy,
                selectAfterCreate: selectAfterCreate
            )
            return
        }

        // Safety: if the target is an existing folder, fail fast.
        if findFolder(atPath: standardizedInput) != nil {
            throw FileManagerError.fileSystemServiceNotFoundWithContext("'\(userPath)' resolves to a folder. Provide a file path.")
        }

        // Existing file: overwrite or error.
        if await fileExistsStrictly(atPath: standardizedInput) {
            if policy == "overwrite" {
                try await editFile(atRelativePath: standardizedInput, newContent: content)
                return
            }
            throw FileManagerError.fileSystemServiceNotFoundWithContext("path already exists: \(userPath)")
        }

        // Check if we need unambiguous resolution (multi-root + relative + no alias prefix)
        let needsUnambiguousResolution =
            !preflight.isAbsolute &&
            preflight.aliasCheck == .notPrefixed &&
            visibleRootFolders.count > 1

        if needsUnambiguousResolution {
            // Use the new unambiguous resolution path
            try await createFileFromToolUnambiguously(
                atUserPath: standardizedInput,
                content: content,
                selectAfterCreate: selectAfterCreate
            )
        } else {
            // Standard creation path (single root, absolute path, or alias-prefixed)
            try await createFile(atRelativePath: standardizedInput, content: content, selectAfterCreate: selectAfterCreate)
        }
    }

    @MainActor
    private func writeFileFromTool(
        usingResolvedCreationResult creationResult: FileCreationResult,
        userPath: String,
        content: String,
        ifExistsPolicy: String,
        selectAfterCreate: Bool
    ) async throws {
        let correctedPath = creationResult.componentsToCreate.joined(separator: "/")
        let absolutePath = StandardizedPath.join(
            standardizedRoot: creationResult.rootFolder.rootPath,
            standardizedRelativePath: correctedPath
        )

        switch existingItemKind(atAbsolutePath: absolutePath) {
        case .folder:
            throw FileManagerError.fileSystemServiceNotFoundWithContext("'\(userPath)' resolves to a folder. Provide a file path.")
        case .file:
            if ifExistsPolicy == "overwrite" {
                try await editFileFromTool(atPath: absolutePath, newContent: content)
                return
            }
            throw FileManagerError.fileSystemServiceNotFoundWithContext("path already exists: \(userPath)")
        case nil:
            break
        }

        try await performCreateFromResult(
            creationResult: creationResult,
            content: content,
            selectAfterCreate: selectAfterCreate
        )
    }

    /// Creates a file with unambiguous root resolution for multi-root workspaces.
    /// Used when the user provides a relative path without a root alias.
    @MainActor
    private func createFileFromToolUnambiguously(
        atUserPath userPath: String,
        content: String,
        selectAfterCreate: Bool
    ) async throws {
        let selectedPaths = Set(selectedFiles.map(\.fullPath))
        guard let resolution = await workspaceFileContextStore.resolveCreationPath(
            userPath: userPath,
            rootScope: .visibleWorkspace,
            selectedFileFullPaths: selectedPaths,
            mode: .requireUnambiguous
        ) else {
            // Could not resolve within workspace
            let roots = visibleRootFolders.map(\.name).joined(separator: ", ")
            let msg = "Could not resolve a destination within the current workspace for '\(userPath)'. " +
                "Loaded roots: \(roots). Use 'manage_workspaces' to switch to a workspace containing this path, " +
                "or ensure the path is inside one of these folders."
            throw FileManagerError.fileSystemServiceNotFoundWithContext(msg)
        }

        switch resolution {
        case let .ambiguous(candidateRootPaths):
            // Multiple roots match equally - ask user to disambiguate
            let rootNames = candidateRootPaths.compactMap { path -> String? in
                visibleRootFolders.first { $0.fullPath == path }?.name
            }
            let candidates = rootNames.isEmpty
                ? candidateRootPaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
                : rootNames.joined(separator: ", ")

            throw FileManagerError.fileSystemServiceNotFoundWithContext(
                "Path '\(userPath)' could match multiple workspace roots: \(candidates). " +
                    "Please disambiguate using 'RootName/\(userPath)' or provide an absolute path."
            )

        case let .unique(creationResult):
            // Unambiguous - proceed with creation using the resolved result
            try await performCreateFromResult(
                creationResult: creationResult,
                content: content,
                selectAfterCreate: selectAfterCreate
            )
        }
    }

    /// Executes file creation using a pre-resolved FileCreationResult.
    @MainActor
    private func performCreateFromResult(
        creationResult: FileCreationResult,
        content: String,
        selectAfterCreate: Bool
    ) async throws {
        // Find the actual root folder from our list
        let standardizedCreationRootPath = (creationResult.rootFolder.fullPath as NSString).standardizingPath
        guard let rootFolder = rootFolders.first(where: { $0.standardizedFullPath == standardizedCreationRootPath }) else {
            let msg = "Internal error: computed creation root is not currently loaded."
            throw FileManagerError.fileSystemServiceNotFoundWithContext(msg)
        }

        let correctedPath = creationResult.componentsToCreate.joined(separator: "/")

        // Insert canonical key BEFORE the FS operation to avoid race with incoming FSEvents.
        let creationKey = makeCreationKey(rootFullPath: rootFolder.fullPath, relPath: correctedPath)
        if selectAfterCreate {
            newlyCreatedFilePaths.insert(creationKey)
        }
        do {
            try await createFileThroughWorkspaceStore(
                rootFolder: rootFolder,
                correctedPath: correctedPath,
                content: content
            )
        } catch {
            // Roll back the marker on failure to avoid stale selection entries.
            if selectAfterCreate {
                newlyCreatedFilePaths.remove(creationKey)
            }
            throw error
        }
    }

    // MARK: - Public file‑rename API

    @MainActor
    func renameFile(from oldPath: String, to newPath: String) async throws {
        let context = try await resolveMoveContext(oldPath: oldPath, newPath: newPath)
        let selectionKey = makeCreationKey(rootFullPath: context.rootFolder.fullPath, relPath: context.newRel)
        let oldAbs = StandardizedPath.join(
            standardizedRoot: context.rootFolder.standardizedFullPath,
            standardizedRelativePath: StandardizedPath.relative(context.oldRel)
        )
        let wasSelected = selectedFiles.contains { $0.standardizedFullPath == oldAbs }
        if wasSelected {
            newlyCreatedFilePaths.insert(selectionKey)
        }

        do {
            try await moveFileThroughWorkspaceStore(
                rootFolder: context.rootFolder,
                oldRel: context.oldRel,
                newRel: context.newRel
            )
        } catch {
            if wasSelected {
                newlyCreatedFilePaths.remove(selectionKey)
            }
            throw error
        }

        let standardizedRoot = context.rootFolder.standardizedFullPath
        await migrateSlicesForRename(rootPath: standardizedRoot, from: context.oldRel, to: context.newRel)
    }

    @MainActor
    func renameFileFromTool(oldPath: String, newPath: String) async throws {
        let context = try await resolveMoveContext(oldPath: oldPath, newPath: newPath)
        let selectionKey = makeCreationKey(rootFullPath: context.rootFolder.fullPath, relPath: context.newRel)
        let oldAbs = StandardizedPath.join(
            standardizedRoot: context.rootFolder.standardizedFullPath,
            standardizedRelativePath: StandardizedPath.relative(context.oldRel)
        )
        let wasSelected = selectedFiles.contains { $0.standardizedFullPath == oldAbs }
        if wasSelected {
            newlyCreatedFilePaths.insert(selectionKey)
        }

        let destAbs = StandardizedPath.join(
            standardizedRoot: context.rootFolder.standardizedFullPath,
            standardizedRelativePath: StandardizedPath.relative(context.newRel)
        )
        if fileHierarchyIndex.filesByFullPath[destAbs] != nil ||
            fileHierarchyIndex.foldersByFullPath[destAbs] != nil
        {
            if wasSelected {
                newlyCreatedFilePaths.remove(selectionKey)
            }
            throw FileManagerError.fileSystemServiceNotFoundWithContext("destination already exists: \(newPath)")
        }

        do {
            try await moveFileThroughWorkspaceStore(
                rootFolder: context.rootFolder,
                oldRel: context.oldRel,
                newRel: context.newRel
            )
        } catch {
            if wasSelected {
                newlyCreatedFilePaths.remove(selectionKey)
            }
            throw error
        }

        let standardizedRoot = context.rootFolder.standardizedFullPath
        await migrateSlicesForRename(rootPath: standardizedRoot, from: context.oldRel, to: context.newRel)
    }

    @MainActor
    private func resolveMoveContext(
        oldPath: String,
        newPath: String
    ) async throws -> (rootFolder: FolderViewModel, oldRel: String, newRel: String) {
        // 1) Locate the source file through the store-owned path lookup
        let normalizedOld = normalizeUserInputPath(oldPath)
        if let issue = exactPathResolutionIssue(for: normalizedOld, kind: .file) {
            throw FileManagerError.fileSystemServiceNotFoundWithContext(
                PathResolutionIssueRenderer.message(for: issue)
            )
        }
        guard let oldLocation = await pathLocation(
            normalizedOld,
            exactMatchOnly: true
        ) else {
            let msg: String
            if visibleRootFolders.isEmpty {
                msg = "No workspace is currently loaded in this window. Use the 'manage_workspaces' tool with action: 'list' to see available workspaces, then action: 'switch' to load one."
            } else {
                let roots = visibleRootFolders.map(\.name).joined(separator: ", ")
                msg = "Cannot move/rename '\(oldPath)' because it is not inside any loaded folder in this window. Loaded roots: \(roots). Use 'manage_workspaces' to switch to a workspace containing this path."
            }
            throw FileManagerError.fileSystemServiceNotFoundWithContext(msg)
        }

        let standardizedRoot = (oldLocation.rootPath as NSString).standardizingPath
        guard let rootFolder = rootFolders.first(where: { $0.standardizedFullPath == standardizedRoot }) else {
            throw FileManagerError.fileSystemServiceNotFoundWithContext("Internal error: computed move root is not currently loaded.")
        }

        let normalizedNew = normalizeUserInputPath(newPath)
        let newRel = try resolveRelativePathInRootForMove(userPath: normalizedNew, root: rootFolder)

        return (rootFolder: rootFolder, oldRel: oldLocation.correctedPath, newRel: newRel)
    }

    // MARK: - Case‑insensitive helpers

    private func folderForFullPathCaseInsensitive(_ path: String) -> FolderViewModel? {
        let std = (path as NSString).standardizingPath
        // 1) fast exact hit
        if let exact = fileHierarchyIndex.foldersByFullPath[std] { return exact }
        // 2) fallback O(n) ‑ single pass, case‑folded compare
        let lower = std.lowercased()
        return fileHierarchyIndex
            .foldersByFullPath
            .first(where: { $0.key.lowercased() == lower })?
            .value
    }

    /// Checks if a root folder contains a real subfolder with the given name.
    /// Used to disambiguate alias resolution: if `RootName/...` is given and the root
    /// actually contains a subfolder named `RootName`, we should NOT strip the first component.
    private func rootHasRealSubfolder(named alias: String, under root: FolderViewModel) -> Bool {
        let subfolderPath = StandardizedPath.join(
            standardizedRoot: root.standardizedFullPath,
            standardizedRelativePath: StandardizedPath.relative(alias)
        )
        // Check in-memory index first (fast path)
        if folderForFullPathCaseInsensitive(subfolderPath) != nil {
            return true
        }
        // Fallback: check disk for folders not yet indexed (conservative)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: subfolderPath, isDirectory: &isDir) && isDir.boolValue
    }

    private enum ExistingPathItemKind {
        case file
        case folder
    }

    private func existingItemKind(atAbsolutePath path: String) -> ExistingPathItemKind? {
        let standardized = StandardizedPath.absolute(path)
        if folderForFullPathCaseInsensitive(standardized) != nil {
            return .folder
        }
        if fileHierarchyIndex.filesByFullPath[standardized] != nil {
            return .file
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized, isDirectory: &isDir) else {
            return nil
        }
        return isDir.boolValue ? .folder : .file
    }

    private func deepestExistingFolderPrefixDepth(
        for components: [String],
        under root: FolderViewModel,
        baseRelativePath: String = ""
    ) -> Int {
        guard !components.isEmpty else { return 0 }
        var matchedDepth = 0
        var currentRelativePath = StandardizedPath.relative(baseRelativePath)
        for component in components {
            let nextRelativePath = currentRelativePath.isEmpty
                ? component
                : currentRelativePath + "/" + component
            let nextAbsolutePath = StandardizedPath.join(
                standardizedRoot: root.standardizedFullPath,
                standardizedRelativePath: nextRelativePath
            )
            guard case .folder = existingItemKind(atAbsolutePath: nextAbsolutePath) else {
                break
            }
            matchedDepth += 1
            currentRelativePath = nextRelativePath
        }
        return matchedDepth
    }

    /// Tool-create-specific literal-vs-alias override used by `writeFileFromTool`.
    /// This is intentionally richer than `WorkspaceAliasResolver.disambiguateRealSubpath`:
    /// it compares full existing directory-chain depth for alias-stripped and literal paths.
    /// Alias wins ties; literal only wins when structurally stronger.
    /// This protects `file_actions create` while letting other callers select
    /// `.canonicalAliasFirst` when they need historical behavior.
    private func resolvedLiteralCreateResult(
        for normalizedUserPath: String,
        preflight: CreatePathPreflight.Result
    ) -> FileCreationResult? {
        guard !preflight.isAbsolute else { return nil }
        guard case let .uniqueRoot(root, alias) = preflight.aliasCheck else { return nil }
        guard let rootVM = visibleRootFolders.first(where: { $0.id == root.id }) else { return nil }
        guard rootHasRealSubfolder(named: alias, under: rootVM) else { return nil }
        let literalBaseAbsolutePath = StandardizedPath.join(
            standardizedRoot: rootVM.standardizedFullPath,
            standardizedRelativePath: StandardizedPath.relative(alias)
        )
        let literalBaseRelativePath = folderForFullPathCaseInsensitive(literalBaseAbsolutePath)?.relativePath
            ?? StandardizedPath.relative(alias)

        let components = StandardizedPath.relative(normalizedUserPath)
            .split(separator: "/")
            .map(String.init)
        guard components.count >= 2 else { return nil }
        let remainderDirComponents = Array(components.dropFirst().dropLast())

        let aliasDepth = deepestExistingFolderPrefixDepth(
            for: remainderDirComponents,
            under: rootVM
        )
        let literalDepth = 1 + deepestExistingFolderPrefixDepth(
            for: remainderDirComponents,
            under: rootVM,
            baseRelativePath: literalBaseRelativePath
        )
        guard literalDepth > aliasDepth else { return nil }

        let literalPrefixComponents = StandardizedPath.relative(literalBaseRelativePath)
            .split(separator: "/")
            .map(String.init)
        let literalComponents = literalPrefixComponents + Array(components.dropFirst())
        return FileCreationResult(
            rootFolder: FrozenFolderRecord(from: rootVM),
            componentsToCreate: literalComponents
        )
    }

    @MainActor
    private func resolveRelativePathInRootForMove(
        userPath: String,
        root: FolderViewModel
    ) throws -> String {
        let normalized = normalizeUserInputPath(userPath)
        let sourceRoot = MovePathResolver.Root(id: root.id, name: root.name, fullPath: root.fullPath)
        let visibleRoots = visibleRootFolders.map {
            MovePathResolver.Root(id: $0.id, name: $0.name, fullPath: $0.fullPath)
        }

        do {
            return try MovePathResolver.resolveRelativePathInRoot(
                userPath: normalized,
                sourceRoot: sourceRoot,
                visibleRoots: visibleRoots
            )
        } catch let error as MovePathResolver.Error {
            switch error {
            case .emptyDestination:
                throw FileManagerError.fileSystemServiceNotFoundWithContext("Destination path is required for move/rename.")
            case .destinationOutsideRoot:
                throw FileManagerError.fileSystemServiceNotFoundWithContext(
                    "Move destination must remain inside the source root: \(root.name) → \(root.fullPath)."
                )
            case let .ambiguousAlias(alias, matchingRoots):
                let rendered = matchingRoots.map(\.renderedLabel).joined(separator: "; ")
                throw FileManagerError.fileSystemServiceNotFoundWithContext(
                    "Ambiguous root alias '\(alias)'. It matches multiple loaded roots: \(rendered). " +
                        "Use an absolute path or rename roots so aliases are unique."
                )
            case let .crossRootAlias(alias, resolvedRoot):
                throw FileManagerError.fileSystemServiceNotFoundWithContext(
                    "Move destinations must remain in the source root. You provided an alias for a different root: '\(alias)' → \(resolvedRoot.fullPath)."
                )
            }
        }
    }

    // Static flag to control logging
    #if DEBUG
        private static var isLoggingEnabled: Bool = true
    #else
        private static var isLoggingEnabled: Bool = false
    #endif

    private func makeCreationKey(rootFullPath: String, relPath: String) -> String {
        let rootStd = StandardizedPath.absolute(rootFullPath).lowercased()
        let relStd = StandardizedPath.relative(relPath).lowercased()
        return rootStd + "|" + relStd
    }

    /// Returns the *top‑level* root folder that should own the new file,
    /// together with the **relative path components** that still need to be
    /// created inside that root.
    ///
    /// The routine now performs *two* scans per root:
    ///   1. starting at component‑index 0 (the normal case)
    ///   2. starting at component‑index 1  ➜  "ignore the 1st component"
    ///
    /// Whichever of the two yields the deeper match is kept.
    /// Finally, all roots are compared and the best overall candidate is
    /// returned.  If two (or more) roots tie after all heuristics, `nil` is
    /// returned so the caller can ask the user to disambiguate.
    /// Optimised lookup: try the absolute-path index first (O(1));
    /// fall back to the legacy DFS only if the index misses.
    ///
    /// - Parameter relativePath: path **relative to the repo root** (no leading "/").
    private func findFolderRecursive(
        in folder: FolderViewModel,
        relativePath: String
    ) -> FolderViewModel? {
        // ❶ Fast path – absolute-path index
        if !relativePath.isEmpty {
            let absPath = (
                (folder.rootPath as NSString)
                    .appendingPathComponent(relativePath) as NSString
            )
            .standardizingPath
            if let hit = fileHierarchyIndex.foldersByFullPath[absPath] {
                return hit // ✅ O(1)
            }
        }

        // ❷ Slow path – depth-first search (only during early loads)
        var visitedFolderIDs = Set<UUID>()
        var stack: [FolderViewModel] = [folder]
        while let current = stack.popLast() {
            guard visitedFolderIDs.insert(current.id).inserted else { continue }
            if current.relativePath == relativePath { return current }
            for child in current.children {
                if case let .folder(sub) = child {
                    stack.append(sub)
                }
            }
        }
        return nil
    }

    /// Search for a folder path among all root folders
    private func findFolderRecursive(inAnyRoot path: String) -> FolderViewModel? {
        for root in rootFolders {
            if let foundFolder = findFolderRecursive(in: root, relativePath: path) {
                return foundFolder
            }
        }
        return nil
    }

    func editFile(atRelativePath relativePath: String, newContent: String) async throws {
        try await editFileInternal(
            atPath: relativePath,
            newContent: newContent,
            profile: .uiAssisted,
            exactMatchOnly: false
        )
    }

    @MainActor
    func editFileFromTool(atPath path: String, newContent: String) async throws {
        try await editFileInternal(
            atPath: path,
            newContent: newContent,
            profile: .mcpRead,
            exactMatchOnly: true
        )
    }

    @MainActor
    private func editFileInternal(
        atPath path: String,
        newContent: String,
        profile: PathLocateProfile,
        exactMatchOnly: Bool
    ) async throws {
        let normalizedPath = normalizeUserInputPath(path)
        if case .uiAssisted = profile {
            // Keep UI flows permissive.
        } else if isExplicitSystemPath(normalizedPath) {
            let msg: String
            if visibleRootFolders.isEmpty {
                msg = "No workspace is currently loaded in this window. Use the 'manage_workspaces' tool with action: 'list' to see available workspaces, then action: 'switch' to load one."
            } else {
                let roots = visibleRootFolders.map(\.name).joined(separator: ", ")
                msg = "Cannot edit '\(path)' because it is not inside any loaded folder in this window. Loaded roots: \(roots). Use 'manage_workspaces' to switch to a workspace containing this path."
            }
            throw FileManagerError.fileSystemServiceNotFoundWithContext(msg)
        } else if let issue = exactPathResolutionIssue(for: normalizedPath, kind: .file) {
            throw FileManagerError.fileSystemServiceNotFoundWithContext(
                PathResolutionIssueRenderer.message(for: issue)
            )
        }
        guard let location = await pathLocation(
            normalizedPath,
            exactMatchOnly: exactMatchOnly,
            profile: profile
        ) else {
            let msg: String
            if visibleRootFolders.isEmpty {
                msg = "No workspace is currently loaded in this window. Use the 'manage_workspaces' tool with action: 'list' to see available workspaces, then action: 'switch' to load one."
            } else {
                let roots = visibleRootFolders.map(\.name).joined(separator: ", ")
                msg = "Cannot edit '\(path)' because it is not inside any loaded folder in this window. Loaded roots: \(roots). Use 'manage_workspaces' to switch to a workspace containing this path."
            }
            throw FileManagerError.fileSystemServiceNotFoundWithContext(msg)
        }

        let correctedPath = location.correctedPath

        do {
            try await editFileThroughWorkspaceStore(
                rootPath: location.rootPath,
                correctedPath: correctedPath,
                newContent: newContent
            )
            if let file = await findFile(
                atPath: correctedPath,
                rootIdentifier: location.rootIdentifier
            ) {
                await file.updateContent(newContent)
            } else {
                throw FileSystemError.fileNotFound
            }
        } catch {
            throw FileSystemError.failedToEditFile(error)
        }
    }

    func deleteFile(atRelativePath relativePath: String) async throws {
        let context = try await resolveDeleteContext(userPath: relativePath)
        do {
            try await deleteFileThroughWorkspaceStore(
                rootPath: context.rootPath,
                correctedPath: context.correctedPath
            )
        } catch {
            throw FileSystemError.failedToDeleteFile(error)
        }
    }

    func trashFileFromTool(atPath path: String) async throws {
        let context = try await resolveDeleteContext(userPath: path, requiresAbsoluteForToolDelete: true)
        do {
            try await moveItemToTrashThroughWorkspaceStore(
                rootPath: context.rootPath,
                correctedPath: context.correctedPath
            )
        } catch {
            throw FileSystemError.failedToDeleteFile(error)
        }
    }

    private func resolveDeleteContext(
        userPath: String,
        requiresAbsoluteForToolDelete: Bool = false
    ) async throws -> (rootPath: String, correctedPath: String) {
        let normalizedPath = normalizeUserInputPath(userPath)
        guard !requiresAbsoluteForToolDelete || normalizedPath.hasPrefix("/") else {
            throw FileManagerError.fileSystemServiceNotFoundWithContext(
                deletePathRejectionMessage(for: userPath, normalizedPath: normalizedPath)
            )
        }
        guard let location = await pathLocation(normalizedPath, exactMatchOnly: true) else {
            throw FileManagerError.fileSystemServiceNotFoundWithContext(
                deletePathRejectionMessage(for: userPath, normalizedPath: normalizedPath)
            )
        }

        return (rootPath: location.rootPath, correctedPath: location.correctedPath)
    }

    @MainActor
    func deleteAbsolutePathRequiredMessage(for userPath: String) -> String {
        deletePathRejectionMessage(for: userPath, normalizedPath: normalizeUserInputPath(userPath))
    }

    @MainActor
    private func deletePathRejectionMessage(for userPath: String, normalizedPath: String) -> String {
        let trimmedInput = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            return "Path is required for file deletion. file_actions.delete requires a true absolute filesystem path."
        }
        if StandardizedPath.containsNUL(trimmedInput) {
            return PathResolutionIssueRenderer.message(for: .invalidPathCharacters(
                input: trimmedInput,
                reason: "embedded NUL (\\0) characters are not allowed"
            ))
        }

        let standardizedPath = (normalizedPath as NSString).standardizingPath
        let loadedRootRefs = allWorkspaceRoots()
        guard !loadedRootRefs.isEmpty else {
            return "No workspace is currently loaded in this window. Use the 'manage_workspaces' tool with action: 'list' to see available workspaces, then action: 'switch' to load one."
        }

        func absolutePath(root: WorkspaceRootRef, relativePath: String) -> String {
            StandardizedPath.join(
                standardizedRoot: root.standardizedFullPath,
                standardizedRelativePath: StandardizedPath.relative(relativePath)
            )
        }

        func exactOnlySuffix() -> String {
            " file_actions.delete is exact and non-fuzzy; it does not accept relative, root-qualified, leading-slash root-alias, or _git_data alias paths for deletion."
        }

        func absoluteOnlyMessage(kind: String, suggestion: String? = nil) -> String {
            var message = "Cannot delete '\(userPath)' because \(kind). file_actions.delete requires a true absolute filesystem path inside a loaded root."
            if let suggestion, !suggestion.isEmpty {
                message += " Use: \(suggestion)"
            } else {
                message += " Use get_file_tree with type='roots' to list loaded root absolute paths, then pass the full absolute path to the item."
            }
            message += exactOnlySuffix()
            return message
        }

        if !standardizedPath.hasPrefix("/") {
            if let explicitSystemPath = resolveExplicitSystemPath(trimmedInput) {
                return absoluteOnlyMessage(
                    kind: "it is a supplemental/system-root alias, not a true absolute path",
                    suggestion: explicitSystemPath.standardizedAbsolutePath
                )
            }

            switch WorkspaceAliasResolver.resolve(
                userPath: standardizedPath,
                roots: loadedRootRefs,
                options: RootAliasOptions(
                    requireRemainder: false,
                    allowCompatibilityAlias: true,
                    disambiguateRealSubpath: false
                )
            ) {
            case let .ambiguous(alias, matchingRoots):
                return PathResolutionIssueRenderer.message(for: .ambiguousAlias(alias: alias, matchingRoots: matchingRoots)) + " file_actions.delete requires a true absolute filesystem path."
            case let .bareRoot(root, _):
                return absoluteOnlyMessage(
                    kind: "it is a root-qualified display alias, not a true absolute path",
                    suggestion: root.standardizedFullPath
                )
            case let .prefixed(root, _, remainder):
                return absoluteOnlyMessage(
                    kind: "it is a root-qualified display alias, not a true absolute path",
                    suggestion: absolutePath(root: root, relativePath: remainder)
                )
            case .notAliasPrefixed:
                if visibleRootFolders.count == 1, let root = visibleWorkspaceRoots().first {
                    return absoluteOnlyMessage(
                        kind: "it is a relative/display path, not a true absolute path",
                        suggestion: absolutePath(root: root, relativePath: standardizedPath)
                    )
                }
                return absoluteOnlyMessage(kind: "it is a relative/display path, not a true absolute path")
            }
        }

        if let leadingSlashAlias = resolveLeadingSlashRootAlias(from: standardizedPath, requireRemainder: false) {
            switch leadingSlashAlias {
            case let .ambiguous(alias, matchingRoots):
                return PathResolutionIssueRenderer.message(for: .ambiguousAlias(alias: alias, matchingRoots: matchingRoots)) + " file_actions.delete requires a true absolute filesystem path, not a leading-slash root alias."
            case let .bareRoot(root, _):
                return absoluteOnlyMessage(
                    kind: "it looks like a leading-slash root alias ('/RootName/...'), not a true absolute filesystem path",
                    suggestion: root.standardizedFullPath
                )
            case let .prefixed(root, _, remainder):
                return absoluteOnlyMessage(
                    kind: "it looks like a leading-slash root alias ('/RootName/...'), not a true absolute filesystem path",
                    suggestion: absolutePath(root: root, relativePath: remainder)
                )
            case .notAliasPrefixed:
                break
            }
        }

        if let loadedRoot = loadedRootRefs
            .filter({ root in
                standardizedPath == root.standardizedFullPath
                    || standardizedPath.hasPrefix(root.standardizedFullPath.hasSuffix("/") ? root.standardizedFullPath : root.standardizedFullPath + "/")
            })
            .max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count })
        {
            let rootKind = rootFolders.first(where: { $0.id == loadedRoot.id })?.isSystemRoot == true
                ? "loaded supplemental/system root"
                : "loaded root"
            let existsOnDisk = FileManager.default.fileExists(atPath: standardizedPath)
            let existenceDetail = existsOnDisk
                ? "The path appears to exist on disk, but it is not indexed/resolved in this workspace window."
                : "No indexed file or folder exists at that exact path."
            return "Cannot delete '\(userPath)' because it is inside \(rootKind) \(loadedRoot.renderedLabel), but RepoPrompt could not resolve an exact file or folder there. \(existenceDetail) Verify the true absolute path, refresh/reload the workspace if the item was just created, and retry. file_actions.delete is exact and non-fuzzy."
        }

        return PathResolutionIssueRenderer.message(for: .pathOutsideWorkspace(input: userPath, visibleRoots: loadedRootRefs)) + " file_actions.delete only deletes true absolute paths inside loaded roots."
    }

    /// Bulk version that efficiently handles multiple paths
    @MainActor
    func findFiles(
        atPaths relativePaths: [String],
        profile: PathLocateProfile = .uiAssisted,
        rootScopeOverride: LookupRootScope? = nil,
        materializeMissing: Bool = true
    ) async -> [String: FileViewModel] {
        var results: [String: FileViewModel] = [:]
        var pathsNeedingMatcher: [(original: String, normalized: String)] = []
        let lookupScope = effectiveLookupRootScope(for: profile, override: rootScopeOverride)

        for original in relativePaths {
            let normalized = normalizeUserInputPath(original)
            guard !normalized.isEmpty else { continue }
            if allowsExplicitSystemPathResolution(for: profile),
               let explicitResolution = resolveExplicitSystemPath(normalized)
            {
                if let hit = fileHierarchyIndex.filesByFullPath[explicitResolution.standardizedAbsolutePath] {
                    results[original] = hit
                } else if materializeMissing,
                          let record = await workspaceFileContextStore.file(
                              rootID: explicitResolution.root.id,
                              relativePath: explicitResolution.standardizedRelativePath
                          ),
                          let materialized = await materializeFileViewModel(record: record)
                {
                    results[original] = materialized
                }
                continue
            }
            if profile == .mcpRead || profile == .mcpSearchScope,
               let explicitResolution = resolveExplicitSystemPath(normalized)
            {
                if let hit = fileHierarchyIndex.filesByFullPath[explicitResolution.standardizedAbsolutePath] {
                    results[original] = hit
                } else if materializeMissing,
                          let record = await workspaceFileContextStore.file(
                              rootID: explicitResolution.root.id,
                              relativePath: explicitResolution.standardizedRelativePath
                          ),
                          let materialized = await materializeFileViewModel(record: record)
                {
                    results[original] = materialized
                }
                continue
            }
            if shouldPreflightDeterministicLookup(for: profile),
               exactPathResolutionIssue(for: normalized, kind: .file, rootScope: lookupScope) != nil
            {
                continue
            }

            if !normalized.hasPrefix("/") {
                switch resolveVisibleRootAlias(normalized, requireRemainder: true, disambiguateRealSubpath: false) {
                case let .prefixed(root, _, remainder):
                    let abs = ((root.standardizedFullPath as NSString).appendingPathComponent(remainder) as NSString).standardizingPath
                    if let hit = fileHierarchyIndex.filesByFullPath[abs] {
                        results[original] = hit
                        continue
                    }
                    let literalMatches = literalRelativeFileMatches(for: normalized)
                    if literalMatches.count == 1, let hit = literalMatches.first {
                        results[original] = hit
                        continue
                    }
                    pathsNeedingMatcher.append((original: original, normalized: normalized))
                    continue
                case .ambiguous:
                    if shouldPreflightDeterministicLookup(for: profile) {
                        continue
                    }
                    pathsNeedingMatcher.append((original: original, normalized: normalized))
                    continue
                case .notAliasPrefixed, .bareRoot:
                    break
                }

                if let hit = findFileByRelativePath(normalized, scope: lookupScope) {
                    results[original] = hit
                    continue
                }
            }

            if normalized.hasPrefix("/") {
                let stdAbs = (normalized as NSString).standardizingPath
                if let hit = fileHierarchyIndex.filesByFullPath[stdAbs] {
                    results[original] = hit
                    continue
                }
            }

            pathsNeedingMatcher.append((original: original, normalized: normalized))
        }

        guard !pathsNeedingMatcher.isEmpty else { return results }

        let selectedPaths = Set(selectedFiles.map(\.fullPath))
        let lookupRequests = pathsNeedingMatcher.map { pair in
            WorkspacePathLookupRequest(
                userPath: pair.normalized,
                profile: profile,
                rootScope: lookupScope,
                selectedFileFullPaths: selectedPaths
            )
        }
        let lookupResults = await workspaceFileContextStore.lookupPaths(lookupRequests)

        for (originalPath, normalizedPath) in pathsNeedingMatcher {
            guard let lookup = lookupResults[normalizedPath], let lookupFile = lookup.file else { continue }
            if let fileVM = fileHierarchyIndex.filesByFullPath[lookupFile.standardizedFullPath] {
                results[originalPath] = fileVM
            } else if materializeMissing,
                      let materialized = await materializeFileViewModel(record: lookupFile)
            {
                results[originalPath] = materialized
            }
        }

        return results
    }

    /// Convenience method for backward compatibility
    @MainActor
    func findFile(atPath relativePath: String) async -> FileViewModel? {
        await findFile(atPath: relativePath, rootIdentifier: nil)
    }

    @MainActor
    private func resolveExactExistingFileForToolEdit(atPath path: String) -> FileViewModel? {
        let normalized = normalizeUserInputPath(path).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let standardized = (normalized as NSString).standardizingPath

        if let issue = exactPathResolutionIssue(for: standardized, kind: .file) {
            switch issue {
            case .ambiguousAlias, .ambiguousRootMatch:
                return nil
            default:
                break
            }
        }

        if standardized.hasPrefix("/") {
            if let exact = fileHierarchyIndex.filesByFullPath[standardized] {
                return exact
            }
            if let aliasResolution = resolveLeadingSlashRootAlias(from: standardized, requireRemainder: false) {
                switch aliasResolution {
                case let .prefixed(root, _, remainder):
                    let abs = ((root.standardizedFullPath as NSString).appendingPathComponent(remainder) as NSString).standardizingPath
                    return fileHierarchyIndex.filesByFullPath[abs]
                case .bareRoot, .ambiguous, .notAliasPrefixed:
                    return nil
                }
            }
            return nil
        }

        switch resolveVisibleRootAlias(standardized, requireRemainder: true, disambiguateRealSubpath: false) {
        case let .prefixed(root, _, remainder):
            let abs = ((root.standardizedFullPath as NSString).appendingPathComponent(remainder) as NSString).standardizingPath
            if let exact = fileHierarchyIndex.filesByFullPath[abs] {
                return exact
            }
            let literalMatches = literalRelativeFileMatches(for: standardized)
            return literalMatches.count == 1 ? literalMatches.first : nil
        case .ambiguous:
            return nil
        case .notAliasPrefixed, .bareRoot:
            break
        }

        let literalMatches = literalRelativeFileMatches(for: standardized)
        return literalMatches.count == 1 ? literalMatches.first : nil
    }

    @MainActor
    func fileExistsStrictly(atPath path: String) async -> Bool {
        await resolveExistingFileForToolEdit(atPath: path) != nil
    }

    @MainActor
    func resolveExistingFileForToolEdit(atPath path: String) async -> FileViewModel? {
        if let exact = resolveExactExistingFileForToolEdit(atPath: path) {
            return exact
        }
        return await materializeFileForUserInput(path, profile: .moveSourceExact)
    }

    /// Finds a file view-model for the given path.
    ///
    /// This method now uses the bulk findFiles implementation for consistency.
    /// When a rootIdentifier is provided, it tries to construct an absolute path
    /// for more efficient lookup before falling back to the general search.
    ///
    /// - Parameters:
    ///   - relativePath: A relative **or** absolute path supplied by the caller.
    ///   - rootIdentifier: Optional UUID constraining the search to one repo
    ///                     root.  Pass `nil` for the old global behaviour.
    /// - Returns: The `FileViewModel` if found; otherwise `nil`.
    @MainActor
    func findFile(atPath relativePath: String, rootIdentifier: UUID?) async -> FileViewModel? {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // If we have a root identifier and a relative path, try to construct the absolute path first
        if let rootID = rootIdentifier, !trimmed.hasPrefix("/") {
            if let root = rootFolders.first(where: { $0.id == rootID }) {
                // Construct absolute path for this specific root
                let absolutePath = (root.fullPath as NSString).appendingPathComponent(trimmed)

                // Try finding with the absolute path first (more efficient)
                let results = await findFiles(atPaths: [absolutePath], profile: .mcpRead)
                if let fileVM = results[absolutePath] {
                    return fileVM
                }
            }
        }

        // Fall back to regular search
        let results = await findFiles(atPaths: [relativePath], profile: .mcpRead)
        guard let fileVM = results[relativePath] else { return nil }

        // If a root identifier is specified, ensure the file belongs to that root
        if let rootID = rootIdentifier {
            return fileVM.rootIdentifier == rootID ? fileVM : nil
        }

        return fileVM
    }

    private func removeFile(atRelativePath relativePath: String) {
        let standardizedRel = (relativePath as NSString).standardizingPath
        for absPath in absolutePathCandidates(forRelativePath: standardizedRel) {
            if let removedFile = fileHierarchyIndex.removeFile(forKey: absPath) {
                removeFileFromParentChildrenArray(removedFile)
                return
            }
        }
        print("failed to remove file \(relativePath)")
    }

    func parentDirectory(of relativePath: String) -> String {
        guard let slashIndex = relativePath.lastIndex(of: "/") else {
            return ""
        }
        return String(relativePath[..<slashIndex])
    }

    /// Remove the file VM from its parent’s children array, using full paths instead of relative paths.
    private func removeFileFromParentChildrenArray(_ fileVM: FileViewModel) {
        pruneRemovedFilesFromSelectionAndCodemap([fileVM])

        // Compute the parent folder's absolute path
        let parentFullPath = (fileVM.fullPath as NSString).deletingLastPathComponent
        let standardizedParent = (parentFullPath as NSString).standardizingPath

        // Look up the parent FolderViewModel by absolute path
        if let parentFolder = fileHierarchyIndex.foldersByFullPath[standardizedParent] {
            parentFolder.removeFile(fileVM)
            return
        }

        // Fallback: if the FileViewModel still has a parentFolder reference, use it
        if let directParent = fileVM.parentFolder {
            directParent.removeFile(fileVM)
            return
        }

        // Improved last resort: reconstruct chain if the parent VM is missing, then retry
        if let owningRoot = rootFolders.first(where: { standardizedParent.isDescendant(of: $0.standardizedFullPath) }) {
            let relParent = String(standardizedParent.dropFirst(owningRoot.standardizedFullPath.count).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            if !relParent.isEmpty {
                createMissingParentFolder(parentPath: relParent, under: owningRoot)
                if let parentFolder = fileHierarchyIndex.foldersByFullPath[standardizedParent] {
                    parentFolder.removeFile(fileVM)
                    return
                }
            }
        }

        // Fallback: nothing to do
    }

    private func updateParentFoldersAfterRemoval(_ folder: FolderViewModel) {
        var visitedFolderIDs = Set<UUID>()
        var current: FolderViewModel? = folder
        while let folderVM = current, visitedFolderIDs.insert(folderVM.id).inserted {
            folderVM.updateCheckboxStateImmediately()
            current = findParentFolder(for: folderVM)
        }
    }

    private func findParentFolder(for folder: FolderViewModel) -> FolderViewModel? {
        for rootFolder in rootFolders {
            if let parent = findParentFolderRecursive(rootFolder, folder) {
                return parent
            }
        }
        return nil
    }

    private func findParentFolderRecursive(_ currentFolder: FolderViewModel, _ targetFolder: FolderViewModel) -> FolderViewModel? {
        var visitedFolderIDs = Set<UUID>()
        var stack: [FolderViewModel] = [currentFolder]
        while let current = stack.popLast() {
            guard visitedFolderIDs.insert(current.id).inserted else { continue }
            for child in current.children {
                if case let .folder(childFolder) = child {
                    if childFolder.id == targetFolder.id {
                        return current
                    }
                    stack.append(childFolder)
                }
            }
        }
        return nil
    }

    private func findParentFolder(forRelativePath relativePath: String) -> FolderViewModel? {
        let components = relativePath.split(separator: "/")
        guard components.count > 1 else { return nil }

        let parentPath = components.dropLast().joined(separator: "/")

        for rootFolder in rootFolders {
            if let folder = findFolderRecursive(in: rootFolder, relativePath: parentPath) {
                return folder
            }
        }
        return nil
    }

    private func isFolderAlreadyLoaded(_ url: URL) -> Bool {
        let standardizedPath = (url.path as NSString).standardizingPath
        return rootFolders.contains { $0.standardizedFullPath == standardizedPath }
    }

    func expandAllChildren(of folder: FolderViewModel) {
        setExpandedStateRecursively(folder, expanded: true)
    }

    func collapseAllChildren(of folder: FolderViewModel) {
        setExpandedStateRecursively(folder, expanded: false)
    }

    /// Reorder root folders to match the desired order from workspace configuration.
    @MainActor
    @discardableResult
    func reorderRootFolders(to desiredOrder: [String]) -> Bool {
        let canonical: (String) -> String = { (($0 as NSString).standardizingPath).lowercased() }
        let systemRoots = orderedSystemRoots(rootFolders.filter(\.isSystemRoot))
        var userRoots = rootFolders.filter { !$0.isSystemRoot }

        var seen = Set<String>()
        var desiredCanonicalOrder: [String] = []
        for path in desiredOrder {
            let key = canonical(path)
            if seen.insert(key).inserted {
                desiredCanonicalOrder.append(key)
            }
        }

        var indexByCanonical: [String: Int] = [:]
        for (idx, key) in desiredCanonicalOrder.enumerated() {
            indexByCanonical[key] = idx
        }

        var originalIndex: [String: Int] = [:]
        for (idx, folder) in userRoots.enumerated() {
            let key = canonical(folder.fullPath)
            if originalIndex[key] == nil {
                originalIndex[key] = idx
            }
        }

        userRoots.sort { a, b in
            let aKey = canonical(a.fullPath)
            let bKey = canonical(b.fullPath)
            let aFound = indexByCanonical[aKey] != nil
            let bFound = indexByCanonical[bKey] != nil
            if aFound != bFound { return aFound }
            let ai = indexByCanonical[aKey] ?? Int.max
            let bi = indexByCanonical[bKey] ?? Int.max
            if ai != bi { return ai < bi }
            let ao = originalIndex[aKey] ?? Int.max
            let bo = originalIndex[bKey] ?? Int.max
            return ao < bo
        }
        let reorderedRoots = userRoots + systemRoots
        guard rootFolders.map(\.id) != reorderedRoots.map(\.id) else { return false }
        rootFolders = reorderedRoots
        onRootFoldersChanged?()
        return true
    }

    /// Keep _git_data pinned to the end of system roots (stable order for others).
    private func orderedSystemRoots(_ roots: [FolderViewModel]) -> [FolderViewModel] {
        guard !roots.isEmpty else { return roots }
        let gitDataRoots = roots.filter { $0.name == "_git_data" }
        guard !gitDataRoots.isEmpty else { return roots }
        let otherRoots = roots.filter { $0.name != "_git_data" }
        return otherRoots + gitDataRoots
    }

    /// Helper used by expand/collapse "all" operations.
    private func setExpandedStateRecursively(_ folder: FolderViewModel, expanded: Bool) {
        // Recurse into children first so we don't lose references if the parent prunes `subfolders` on collapse.
        var visitedFolderIDs = Set<UUID>()
        var stack: [(FolderViewModel, Bool)] = [(folder, false)]
        while let (current, didVisitChildren) = stack.popLast() {
            if didVisitChildren {
                current.setExpanded(expanded)
                continue
            }
            guard visitedFolderIDs.insert(current.id).inserted else { continue }
            stack.append((current, true))
            let children = current.subfolders
            for sub in children {
                stack.append((sub, false))
            }
        }
    }

    func refreshRootFolderState() {
        for rootFolder in rootFolders {
            _ = updateFolderStateRecursive(rootFolder)
        }
    }

    private func removeEmptyFolders(in folder: FolderViewModel, allowSorting: Bool = true) {
        if !showEmptyFolders {
            let isRoot = rootFolders.contains { $0.id == folder.id }
            let removed = folder.removeEmptyFoldersRecursively(isRoot: isRoot, allowSorting: allowSorting)

            // Cancel expansion tracking per removed folder VM *before* removing from index
            for (fullPath, _) in removed {
                let standardizedFull = (fullPath as NSString).standardizingPath
                if let vm = fileHierarchyIndex.foldersByFullPath[standardizedFull] {
                    unregisterExpansionTracking(for: vm) // Avoid leaks & stale expansion cache
                }
                fileHierarchyIndex.removeFolder(forKey: standardizedFull, expectedRootKey: folder.rootPath)
            }
        }
    }

    func normalizeUserInputPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return trimmed
        }
        // Expand tilde for home-directory absolute shorthand
        let expanded = (trimmed as NSString).expandingTildeInPath
        // For relative paths, standardize separators, ".", "..", etc.
        return (expanded as NSString).standardizingPath
    }

    /// Stable key for root folders/services - avoids URL key instability issues.
    /// Uses pure string normalization to match `FolderViewModel.standardizedFullPath` exactly.
    /// - Expands "~"
    /// - Standardizes ".", "..", duplicate slashes
    /// - Strips trailing "/" (except for "/")
    private func rootKey(forPath path: String) -> RootKey {
        // Use same normalization as standardizedFullPath to ensure key matches
        var trimmed = (normalizeUserInputPath(path) as NSString).standardizingPath
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    // MARK: - Root Alias Resolution

    enum RootAliasResolutionError: LocalizedError {
        case issue(PathResolutionIssue)

        var errorDescription: String? {
            switch self {
            case let .issue(issue):
                PathResolutionIssueRenderer.message(for: issue)
            }
        }
    }

    enum VisibleAliasResolution {
        case notAliasPrefixed
        case resolved(String)
        case ambiguous(alias: String, matchingRoots: [String])
    }

    struct VisibleRootSnapshot: Hashable {
        let id: UUID
        let name: String
        let fullPath: String
        let standardizedFullPath: String
    }

    struct FolderInputResolution {
        let files: [FileViewModel]
        let handled: Bool
        let displayPath: String?
        let issue: PathResolutionIssue?
    }

    struct ExternalReadableFile: Equatable {
        let absolutePath: String
        let displayPath: String
    }

    private struct ExplicitSystemPathResolution {
        let root: FolderViewModel
        let standardizedAbsolutePath: String
        let standardizedRelativePath: String
    }

    enum ReadableFileHandle {
        case workspace(FileViewModel)
        case external(ExternalReadableFile)
    }

    enum RootAliasPrefixCheck {
        case notPrefixed
        case uniqueRoot(root: VisibleRootSnapshot, alias: String)
        case ambiguous(alias: String, matchingRoots: [String])
    }

    private func visibleWorkspaceRoots() -> [WorkspaceRootRef] {
        visibleRootFolders.map { WorkspaceRootRef(id: $0.id, name: $0.name, fullPath: $0.fullPath) }
    }

    private func allWorkspaceRoots() -> [WorkspaceRootRef] {
        rootFolders.map { WorkspaceRootRef(id: $0.id, name: $0.name, fullPath: $0.fullPath) }
    }

    private func supplementalSystemRoots() -> [FolderViewModel] {
        rootFolders.filter(\.isSystemRoot)
    }

    private func gitDataRootFolders() -> [FolderViewModel] {
        supplementalSystemRoots().filter { $0.name == "_git_data" }
    }

    private func roots(in scope: LookupRootScope) -> [FolderViewModel] {
        switch scope {
        case .visibleWorkspace:
            visibleRootFolders
        case .visibleWorkspacePlusGitData:
            visibleRootFolders + gitDataRootFolders()
        case .allLoaded:
            rootFolders
        case let .sessionBoundWorkspace(canonicalRootPaths, physicalRootPaths):
            rootFolders.filter { root in
                if physicalRootPaths.contains(root.standardizedFullPath) { return true }
                return visibleRootFolders.contains(where: { $0.id == root.id })
                    && canonicalRootPaths.contains(root.standardizedFullPath)
            }
        }
    }

    private func allowedRootPaths(in scope: LookupRootScope) -> Set<String> {
        Set(roots(in: scope).map(\.standardizedFullPath))
    }

    private func lookupRootScope(for profile: PathLocateProfile) -> LookupRootScope {
        switch profile {
        case .mcpRead, .mcpSelection, .mcpSearchScope:
            .visibleWorkspace
        case .uiAssisted, .moveSourceExact, .createBestEffort, .createRequireUnambiguous:
            .allLoaded
        }
    }

    private func effectiveLookupRootScope(
        for profile: PathLocateProfile,
        override: LookupRootScope?
    ) -> LookupRootScope {
        override ?? lookupRootScope(for: profile)
    }

    private func allowsExplicitSystemPathResolution(for profile: PathLocateProfile) -> Bool {
        switch profile {
        case .mcpSelection:
            true
        case .mcpRead, .mcpSearchScope, .uiAssisted, .moveSourceExact, .createBestEffort, .createRequireUnambiguous:
            false
        }
    }

    private func visibleRootSnapshot(_ root: WorkspaceRootRef) -> VisibleRootSnapshot {
        VisibleRootSnapshot(
            id: root.id,
            name: root.name,
            fullPath: root.fullPath,
            standardizedFullPath: root.standardizedFullPath
        )
    }

    private func workspaceRootRef(for root: FolderViewModel) -> WorkspaceRootRef {
        WorkspaceRootRef(id: root.id, name: root.name, fullPath: root.fullPath)
    }

    private func visibleWorkspaceRoot(forStandardizedFullPath path: String) -> WorkspaceRootRef? {
        visibleWorkspaceRoots().first { $0.standardizedFullPath == path }
    }

    private func clientDisplayPath(root: WorkspaceRootRef, relativePath: String) -> String {
        ClientPathFormatter.displayPath(root: root, relativePath: relativePath, visibleRoots: visibleWorkspaceRoots())
    }

    @MainActor
    private func resolveExplicitSystemPath(_ userPath: String) -> ExplicitSystemPathResolution? {
        let normalized = normalizeUserInputPath(userPath).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let standardized = (normalized as NSString).standardizingPath
        let systemRoots = gitDataRootFolders()
        guard !systemRoots.isEmpty else { return nil }

        if standardized.hasPrefix("/") {
            guard let root = systemRoots
                .filter({
                    let rootPath = $0.standardizedFullPath
                    return standardized == rootPath
                        || standardized.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
                })
                .max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count })
            else {
                return nil
            }
            return ExplicitSystemPathResolution(
                root: root,
                standardizedAbsolutePath: standardized,
                standardizedRelativePath: RelativePath.fromStandardized(
                    standardizedAbsolutePath: standardized,
                    standardizedRootPath: root.standardizedFullPath
                )
            )
        }

        let systemRootRefs = systemRoots.map(workspaceRootRef(for:))
        switch WorkspaceAliasResolver.resolve(
            userPath: standardized,
            roots: systemRootRefs,
            options: RootAliasOptions(
                requireRemainder: false,
                allowCompatibilityAlias: true,
                disambiguateRealSubpath: false
            )
        ) {
        case let .bareRoot(rootRef, _):
            guard let root = systemRoots.first(where: { $0.id == rootRef.id }) else { return nil }
            return ExplicitSystemPathResolution(
                root: root,
                standardizedAbsolutePath: root.standardizedFullPath,
                standardizedRelativePath: ""
            )
        case let .prefixed(rootRef, _, remainder):
            guard let root = systemRoots.first(where: { $0.id == rootRef.id }) else { return nil }
            return ExplicitSystemPathResolution(
                root: root,
                standardizedAbsolutePath: StandardizedPath.join(
                    standardizedRoot: root.standardizedFullPath,
                    standardizedRelativePath: remainder
                ),
                standardizedRelativePath: StandardizedPath.relative(remainder)
            )
        case .ambiguous, .notAliasPrefixed:
            return nil
        }
    }

    @MainActor
    private func isExplicitSystemPath(_ userPath: String) -> Bool {
        resolveExplicitSystemPath(userPath) != nil
    }

    @MainActor
    private func explicitSystemPathLocation(_ userPath: String) -> PathLocation? {
        guard let resolution = resolveExplicitSystemPath(userPath),
              existingItemKind(atAbsolutePath: resolution.standardizedAbsolutePath) != nil
        else {
            return nil
        }
        return PathLocation(
            rootPath: resolution.root.fullPath,
            correctedPath: resolution.standardizedRelativePath,
            rootIdentifier: resolution.root.id
        )
    }

    @MainActor
    private func resolveExplicitSystemFile(_ userPath: String) -> FileViewModel? {
        guard let resolution = resolveExplicitSystemPath(userPath) else { return nil }
        return fileHierarchyIndex.filesByFullPath[resolution.standardizedAbsolutePath]
    }

    @MainActor
    func mcpDisplayPath(forAbsolutePath path: String) -> String {
        Self.mcpDisplayPath(
            fullPath: path,
            visibleRoots: visibleWorkspaceRoots(),
            allRoots: allWorkspaceRoots()
        )
    }

    @MainActor
    func mcpDisplayPath(for file: FileViewModel) -> String {
        mcpDisplayPath(forAbsolutePath: file.standardizedFullPath)
    }

    @MainActor
    func mcpDisplayPath(for folder: FolderViewModel) -> String {
        mcpDisplayPath(forAbsolutePath: folder.standardizedFullPath)
    }

    @MainActor
    func mcpUnresolvedDisplayPath(for userPath: String) -> String? {
        if let resolution = resolveExplicitSystemPath(userPath) {
            return mcpDisplayPath(forAbsolutePath: resolution.standardizedAbsolutePath)
        }
        return unresolvedWorkspaceDisplayPath(for: userPath)
    }

    nonisolated static func mcpDisplayPath(
        fullPath: String,
        visibleRoots: [WorkspaceRootRef],
        allRoots: [WorkspaceRootRef]
    ) -> String {
        let standardized = StandardizedPath.absolute(fullPath)
        let visibleDisplay = ClientPathFormatter.displayAbsolutePath(
            fullPath: standardized,
            visibleRoots: visibleRoots
        )
        if visibleDisplay != standardized {
            return visibleDisplay
        }

        let systemRoots = allRoots.filter { root in
            !visibleRoots.contains(root)
        }
        guard let matchingSystemRoot = systemRoots
            .filter({
                standardized == $0.standardizedFullPath
                    || standardized.hasPrefix($0.standardizedFullPath.hasSuffix("/") ? $0.standardizedFullPath : $0.standardizedFullPath + "/")
            })
            .max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count })
        else {
            return standardized
        }
        let relative = RelativePath.fromStandardized(
            standardizedAbsolutePath: standardized,
            standardizedRootPath: matchingSystemRoot.standardizedFullPath
        )
        return relative.isEmpty ? matchingSystemRoot.name : "\(matchingSystemRoot.name)/\(relative)"
    }

    @MainActor
    func clientDisplayPath(for file: FileViewModel) -> String {
        let root = WorkspaceRootRef(id: file.rootIdentifier, name: file.rootFolderName, fullPath: file.rootFolderPath)
        return clientDisplayPath(root: root, relativePath: file.relativePath)
    }

    @MainActor
    func clientDisplayPath(for folder: FolderViewModel) -> String {
        let root = workspaceRootRef(for: folder)
        return clientDisplayPath(root: root, relativePath: folder.relativePath)
    }

    @MainActor
    func unresolvedWorkspaceDisplayPath(for userPath: String) -> String? {
        let trimmedInput = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return nil }

        let standardized = (normalizeUserInputPath(trimmedInput) as NSString).standardizingPath
        let roots = visibleWorkspaceRoots()
        guard !roots.isEmpty else { return nil }

        func hasExistingAncestor(relativePath: String, root: WorkspaceRootRef) -> Bool {
            let standardizedRelative = (relativePath as NSString)
                .standardizingPath
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !standardizedRelative.isEmpty else { return true }

            var ancestor = ((standardizedRelative as NSString).deletingLastPathComponent as NSString)
                .standardizingPath
            while !ancestor.isEmpty, ancestor != "." {
                let absolute = ((root.standardizedFullPath as NSString).appendingPathComponent(ancestor) as NSString).standardizingPath
                if findFolderByFullPath(absolute) != nil {
                    return true
                }
                ancestor = ((ancestor as NSString).deletingLastPathComponent as NSString).standardizingPath
            }
            return false
        }

        if standardized.hasPrefix("/") {
            guard let root = roots
                .filter({ standardized == $0.standardizedFullPath || standardized.hasPrefix($0.standardizedFullPath.hasSuffix("/") ? $0.standardizedFullPath : $0.standardizedFullPath + "/") })
                .max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count })
            else {
                return nil
            }
            let relative = RelativePath.fromStandardized(
                standardizedAbsolutePath: standardized,
                standardizedRootPath: root.standardizedFullPath
            )
            return hasExistingAncestor(relativePath: relative, root: root)
                ? clientDisplayPath(root: root, relativePath: relative)
                : nil
        }

        switch resolveVisibleRootAlias(standardized, requireRemainder: false, disambiguateRealSubpath: false) {
        case let .bareRoot(root, _):
            return clientDisplayPath(root: root, relativePath: "")
        case let .prefixed(root, _, remainder):
            return hasExistingAncestor(relativePath: remainder, root: root)
                ? clientDisplayPath(root: root, relativePath: remainder)
                : nil
        case .ambiguous, .notAliasPrefixed:
            break
        }

        guard roots.count == 1, let root = roots.first else { return nil }
        return hasExistingAncestor(relativePath: standardized, root: root)
            ? clientDisplayPath(root: root, relativePath: standardized)
            : nil
    }

    enum ExactPathLookupKind {
        case file
        case folder
        case either
    }

    @MainActor
    private func literalRelativeFileMatches(for relativePath: String) -> [FileViewModel] {
        let standardizedRel = (relativePath as NSString).standardizingPath
        return visibleRootFolders.compactMap { root in
            let abs = ((root.standardizedFullPath as NSString).appendingPathComponent(standardizedRel) as NSString).standardizingPath
            return fileHierarchyIndex.filesByFullPath[abs]
        }
    }

    @MainActor
    private func literalRelativeFolderMatches(for relativePath: String) -> [FolderViewModel] {
        let standardizedRel = (relativePath as NSString).standardizingPath
        return visibleRootFolders.compactMap { root in
            let abs = ((root.standardizedFullPath as NSString).appendingPathComponent(standardizedRel) as NSString).standardizingPath
            return fileHierarchyIndex.foldersByFullPath[abs]
        }
    }

    @MainActor
    func exactPathResolutionIssue(
        for userPath: String,
        kind: ExactPathLookupKind,
        rootScope: LookupRootScope = .visibleWorkspace
    ) -> PathResolutionIssue? {
        let trimmedInput = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            return .emptyInput
        }
        if StandardizedPath.containsNUL(trimmedInput) {
            return .invalidPathCharacters(
                input: trimmedInput,
                reason: "embedded NUL (\\0) characters are not allowed"
            )
        }
        if isExplicitSystemPath(trimmedInput) {
            return nil
        }

        let standardized = (normalizeUserInputPath(trimmedInput) as NSString).standardizingPath
        guard !standardized.hasPrefix("/") else {
            return nil
        }

        let roots = visibleWorkspaceRoots()
        guard !roots.isEmpty else {
            return nil
        }

        switch WorkspaceAliasResolver.resolve(
            userPath: standardized,
            roots: roots,
            options: RootAliasOptions(
                requireRemainder: false,
                allowCompatibilityAlias: true,
                disambiguateRealSubpath: false
            )
        ) {
        case let .ambiguous(alias, matchingRoots):
            return .ambiguousAlias(alias: alias, matchingRoots: matchingRoots)
        case let .bareRoot(root, _):
            switch kind {
            case .folder, .either:
                if visibleRootFolders.contains(where: { $0.id == root.id }) {
                    return nil
                }
            case .file:
                break
            }
        case let .prefixed(root, _, remainder):
            let standardizedRemainder = StandardizedPath.relative(remainder)
            let abs = StandardizedPath.absolute(StandardizedPath.join(
                standardizedRoot: root.standardizedFullPath,
                standardizedRelativePath: standardizedRemainder
            ))
            switch kind {
            case .file:
                if findFileByFullPath(abs) != nil { return nil }
            case .folder:
                if findFolderByFullPath(abs) != nil { return nil }
            case .either:
                if findFileByFullPath(abs) != nil || findFolderByFullPath(abs) != nil { return nil }
            }
        case .notAliasPrefixed:
            break
        }

        let relative = StandardizedPath.relative(standardized.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        guard !relative.isEmpty else {
            return nil
        }

        let matchingRoots = roots.filter { root in
            let abs = StandardizedPath.absolute(StandardizedPath.join(
                standardizedRoot: root.standardizedFullPath,
                standardizedRelativePath: relative
            ))
            switch kind {
            case .file:
                return findFileByFullPath(abs) != nil
            case .folder:
                return findFolderByFullPath(abs) != nil
            case .either:
                return findFileByFullPath(abs) != nil || findFolderByFullPath(abs) != nil
            }
        }

        guard matchingRoots.count > 1 else {
            return nil
        }
        return .ambiguousRootMatch(input: trimmedInput, candidateRoots: matchingRoots)
    }

    private func resolveVisibleRootAlias(
        _ userPath: String,
        requireRemainder: Bool,
        disambiguateRealSubpath: Bool
    ) -> RootAliasResolution {
        WorkspaceAliasResolver.resolve(
            userPath: normalizeUserInputPath(userPath),
            roots: visibleWorkspaceRoots(),
            options: RootAliasOptions(
                requireRemainder: requireRemainder,
                allowCompatibilityAlias: true,
                disambiguateRealSubpath: requireRemainder && disambiguateRealSubpath
            ),
            rootHasRealSubpath: { root, alias in
                guard let rootVM = self.visibleRootFolders.first(where: { $0.id == root.id }) else { return false }
                return self.rootHasRealSubfolder(named: alias, under: rootVM)
            }
        )
    }

    func checkVisibleRootAliasPrefix(
        _ userPath: String,
        requireRemainder: Bool
    ) -> RootAliasPrefixCheck {
        switch resolveVisibleRootAlias(userPath, requireRemainder: requireRemainder, disambiguateRealSubpath: false) {
        case .notAliasPrefixed:
            .notPrefixed
        case .bareRoot where requireRemainder:
            .notPrefixed
        case let .bareRoot(root, alias):
            .uniqueRoot(root: visibleRootSnapshot(root), alias: alias)
        case let .prefixed(root, alias, _):
            .uniqueRoot(root: visibleRootSnapshot(root), alias: alias)
        case let .ambiguous(alias, matchingRoots):
            .ambiguous(alias: alias, matchingRoots: matchingRoots.map(\.renderedLabel))
        }
    }

    func resolveVisibleAliasPrefixedAbsolutePathResolution(
        _ userPath: String,
        requireRemainder: Bool
    ) -> VisibleAliasResolution {
        switch resolveVisibleRootAlias(userPath, requireRemainder: requireRemainder, disambiguateRealSubpath: false) {
        case .notAliasPrefixed, .bareRoot:
            return .notAliasPrefixed
        case let .prefixed(root, _, remainder):
            let standardizedRemainder = StandardizedPath.relative(remainder)
            let abs = StandardizedPath.absolute(StandardizedPath.join(
                standardizedRoot: root.standardizedFullPath,
                standardizedRelativePath: standardizedRemainder
            ))
            return .resolved(abs)
        case let .ambiguous(alias, matchingRoots):
            return .ambiguous(alias: alias, matchingRoots: matchingRoots.map(\.renderedLabel))
        }
    }

    func resolveVisibleAliasPrefixedAbsolutePathIfPossible(
        _ userPath: String,
        requireRemainder: Bool
    ) throws -> String? {
        switch resolveVisibleAliasPrefixedAbsolutePathResolution(userPath, requireRemainder: requireRemainder) {
        case .notAliasPrefixed:
            return nil
        case let .resolved(abs):
            return abs
        case let .ambiguous(alias, matchingRoots):
            let matchingRootsRefs = matchingRoots.compactMap { label in
                visibleWorkspaceRoots().first(where: { $0.renderedLabel == label })
            }
            throw RootAliasResolutionError.issue(.ambiguousAlias(alias: alias, matchingRoots: matchingRootsRefs))
        }
    }

    private func findDeepestMatchingSubfolder(_ fullOrRelativePath: String) -> FolderViewModel? {
        let standardizedPath = (fullOrRelativePath as NSString).standardizingPath
        let pathComponents = standardizedPath
            .split(separator: "/")
            .map(String.init)

        var currentFolder: FolderViewModel? = nil
        for root in rootFolders {
            if standardizedPath.hasPrefix(root.standardizedFullPath) || root.name == pathComponents.first {
                currentFolder = root
                break
            }
        }

        for component in pathComponents {
            guard let folderSoFar = currentFolder else { break }
            if let childFolder = folderSoFar.children
                .compactMap({ item -> FolderViewModel? in
                    if case let .folder(f) = item { return f }
                    return nil
                })
                .first(where: { $0.name == component })
            {
                currentFolder = childFolder
            } else {
                break
            }
        }

        return currentFolder
    }

    func applyPresetFileSelections(_ filePaths: [String]) async {
        await clearSelection()

        // Use bulk lookup for efficiency
        let fileVMs = await findFiles(atPaths: filePaths)

        // Batch-toggle files in original order with a single flush
        await MainActor.run {
            self.performSelectionBatch {
                for path in filePaths {
                    if let fileVM = fileVMs[path], !fileVM.isChecked {
                        fileVM.setIsChecked(true)
                    }
                }
            }
        }
    }

    func applyWorkspaceState(_ workspace: WorkspaceModel) async {
        // Clear previous expansion state
        for rootFolder in rootFolders {
            rootFolder.collapseRecursively()
        }

        let activeTab = workspace.composeTabs.first { $0.id == workspace.activeComposeTabID } ?? workspace.composeTabs.first
        let expandedFolders = activeTab?.expandedFolders ?? []
        let selectedPaths = activeTab?.selection.selectedPaths ?? []

        // Apply new expansion state
        for folderPath in expandedFolders {
            if let folderVM = findFolderByFullPath(folderPath) {
                folderVM.setExpanded(true)
            }
        }

        await clearSelection()

        // Use bulk lookup for efficiency
        let fileVMs = await findFiles(atPaths: selectedPaths)

        // Batch toggle all target files once
        await MainActor.run {
            self.performSelectionBatch {
                for filePath in selectedPaths {
                    if let fileVM = fileVMs[filePath], !fileVM.isChecked {
                        fileVM.setIsChecked(true)
                    }
                }
            }
        }
        refreshRootFolderState()
    }

    func noteFoldersLoaded(paths: [String]) {
        for p in paths {
            rootShellLoadedPaths.insert((p as NSString).standardizingPath)
        }
    }

    func isRootFolderLoaded(_ path: String) -> Bool {
        let stdPath = (path as NSString).standardizingPath
        return rootShellLoadedPaths.contains(stdPath)
    }

    @MainActor
    private func refreshSlicesFromDisk(forRootURL rootURL: URL) async {
        guard let scope = try? currentPartitionScope() else { return }
        let rootPath = StandardizedPath.absolute(rootURL.path)
        let data = await selectionSliceCoordinator.loadSlices(forRootPath: rootPath, scope: scope)
        if data.isEmpty {
            if currentSlicesByRoot.removeValue(forKey: rootPath) != nil {
                requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")
            }
            return
        }
        currentSlicesByRoot[rootPath] = data
        requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")
    }

    @MainActor
    private func migrateSlicesForRename(rootPath: String, from oldRelativePath: String, to newRelativePath: String) async {
        guard let scope = try? currentPartitionScope() else { return }

        let normalizedRoot = StandardizedPath.absolute(rootPath)
        let normalizedOld = StandardizedPath.relative(oldRelativePath)
        let normalizedNew = StandardizedPath.relative(newRelativePath)
        guard normalizedOld != normalizedNew else { return }

        guard currentSlicesByRoot[normalizedRoot]?[normalizedOld] != nil else { return }

        do {
            let postAddition = try await selectionSliceCoordinator.moveSliceState(
                rootPath: normalizedRoot,
                oldRelativePath: normalizedOld,
                newRelativePath: normalizedNew,
                scope: scope
            )
            if postAddition.isEmpty {
                currentSlicesByRoot.removeValue(forKey: normalizedRoot)
            } else {
                currentSlicesByRoot[normalizedRoot] = postAddition
            }
            requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")
        } catch {
            if Self.isLoggingEnabled {
                print("Failed to migrate selection slices from \(normalizedOld) to \(normalizedNew): \(error)")
            }
        }
    }

    // MARK: - Δ‑set coalescing  (file & folder events)

    private func coalesceDeltas(_ deltas: [FileSystemDelta], inRoot standardizedRoot: String? = nil) -> [FileSystemDelta] {
        FileSystemDeltaPreparation.coalesce(deltas, inRoot: standardizedRoot)
    }

    #if DEBUG
        struct RootReferenceCleanupMetrics: Equatable {
            let totalFolderKeys: Int
            let matchedFolderKeys: Int
            let cleanupCandidateFolderKeys: Int
            let totalFileKeys: Int
            let matchedFileKeys: Int
            let cleanupCandidateFileKeys: Int
            let usedFallbackGlobalScan: Bool
        }

        struct AppliedIndexProjectionIndexSnapshot: Equatable {
            let filePathsByID: [UUID: String]
            let folderPathsByID: [UUID: String]
            let fileIDsByPath: [String: UUID]
            let folderIDsByPath: [String: UUID]
        }

        @MainActor
        func currentSlicesByRootForTesting() -> [String: [String: PartitionStore.StoredSlices]] {
            currentSlicesByRoot
        }

        @MainActor
        func applyWorkspaceAppliedIndexEventForTesting(_ event: WorkspaceAppliedIndexBatchEvent) async {
            await handleWorkspaceAppliedIndexEvent(event)
        }

        @MainActor
        func appliedIndexProjectedFileForTesting(id: UUID) -> FileViewModel? {
            fileHierarchyIndex.filesByID[id]
        }

        func appliedIndexProjectionIndexSnapshotForTesting() -> AppliedIndexProjectionIndexSnapshot {
            AppliedIndexProjectionIndexSnapshot(
                filePathsByID: fileHierarchyIndex.filesByID.mapValues(\.standardizedFullPath),
                folderPathsByID: fileHierarchyIndex.foldersByID.mapValues(\.standardizedFullPath),
                fileIDsByPath: fileHierarchyIndex.filesByFullPath.mapValues(\.id),
                folderIDsByPath: fileHierarchyIndex.foldersByFullPath.mapValues(\.id)
            )
        }

        @MainActor
        func coalesceDeltasForTesting(_ deltas: [FileSystemDelta], inRoot standardizedRoot: String? = nil) -> [FileSystemDelta] {
            coalesceDeltas(deltas, inRoot: standardizedRoot)
        }

        @MainActor
        func rootReferenceCleanupMetricsForTesting(_ folder: FolderViewModel) -> RootReferenceCleanupMetrics {
            let rootPrefix = folder.standardizedFullPath
            let folderKeys = Array(fileHierarchyIndex.foldersByFullPath.keys)
            let fileKeys = Array(fileHierarchyIndex.filesByFullPath.keys)
            let cleanup = rootReferenceCleanupPlan(for: folder)
            return RootReferenceCleanupMetrics(
                totalFolderKeys: folderKeys.count,
                matchedFolderKeys: folderKeys.count(where: { StandardizedPath.isDescendant($0, of: rootPrefix) }),
                cleanupCandidateFolderKeys: cleanup.folderPaths.count,
                totalFileKeys: fileKeys.count,
                matchedFileKeys: fileKeys.count(where: { StandardizedPath.isDescendant($0, of: rootPrefix) }),
                cleanupCandidateFileKeys: cleanup.filePaths.count,
                usedFallbackGlobalScan: cleanup.usedFallbackGlobalScan
            )
        }

        @MainActor
        func latestIndexRebuildPerfSampleForTesting() -> IndexRebuildPerfSample? {
            lastIndexRebuildPerfSample
        }

        @MainActor
        func latestDeltaReplayPerfSampleForTesting() -> DeltaReplayPerfSample? {
            lastDeltaReplayPerfSample
        }

        @MainActor
        func latestImmediateReplayPerfSampleForTesting() -> ImmediateReplayPerfSample? {
            lastImmediateReplayPerfSample
        }

        func resetReplayPerfSamplesForTesting() {
            lastIndexRebuildPerfSample = nil
            lastDeltaReplayPerfSample = nil
            lastImmediateReplayPerfSample = nil
            currentRootReplayPerfSample = nil
        }

        @MainActor
        func seedSelectionSlicesForTesting(_ ranges: [LineRange], for file: FileViewModel) {
            selectionSlicesByFileID[file.id] = ranges
        }

        @MainActor
        func setDeltaReplayTuningForTesting(
            chunkSize: Int?,
            interChunkDelayNanoseconds: UInt64?
        ) {
            deltaReplayChunkSizeOverride = chunkSize
            deltaReplayInterChunkDelayNanosecondsOverride = interChunkDelayNanoseconds
            let store = workspaceFileContextStore
            Task { [store] in
                await store.updateDeferredReplayImmediateChunkSizeOverride(chunkSize)
            }
        }

        @MainActor
        func registerRootFolderForTesting(_ folder: FolderViewModel, service: FileSystemService? = nil) {
            if !rootFolders.contains(where: { $0.id == folder.id }) {
                addRootFolder(folder)
            }
            if service != nil {
                // RFM intentionally no longer owns FileSystemService/watch subscriptions, even for tests.
                // Tests that need replay ingress should feed deltas through receiveWatcherFileSystemDeltasForTesting.
                let rootKey = folder.standardizedFullPath
                let replayIngressGeneration = advanceRootReplayIngressGeneration(forRootKey: rootKey)
                let store = workspaceFileContextStore
                Task { [store] in
                    await store.registerDeferredReplayRootGeneration(replayIngressGeneration, forRootKey: rootKey)
                }
            }
            rebuildFileHierarchyIndex(for: folder)
        }

        @MainActor
        @discardableResult
        func ensureReplayIngressRegistrationForTesting(forRootFolder folder: FolderViewModel) async -> UInt64 {
            let rootKey = folder.standardizedFullPath
            let generation = currentRootReplayIngressGeneration(forRootKey: rootKey)
                ?? advanceRootReplayIngressGeneration(forRootKey: rootKey)
            await workspaceFileContextStore.registerDeferredReplayRootGeneration(generation, forRootKey: rootKey)
            return generation
        }

        @MainActor
        func receiveWatcherFileSystemDeltasForTesting(
            _ deltas: [FileSystemDelta],
            forRootFolder folder: FolderViewModel,
            capturedGeneration: UInt64
        ) async {
            let ingress = await workspaceFileContextStore.ingestDeferredReplayLiveDeltas(
                deltas,
                forRootKey: folder.standardizedFullPath,
                rootGeneration: capturedGeneration
            )
            await handleDeferredReplayIngressResult(ingress)
        }

        @MainActor
        func injectIndexedFileForTesting(_ file: FileViewModel) {
            fileHierarchyIndex.insertFile(file, rootKey: file.standardizedRootFolderPath)
        }

        /// Attach the selection callback and toggle a file into `selectedFiles`
        /// through the normal commit path. Mirrors what `attachSelectionCallback`
        /// does for fresh view models so tests can exercise code paths that read
        /// `selectedFiles` (e.g. Agent Mode file-tag suggestions).
        @MainActor
        func selectFileForTesting(_ file: FileViewModel) {
            file.onCheckStateChanged = { [weak self] changed, isChecked in
                self?.handleCheckStateChanged(changed, isChecked: isChecked)
            }
            setFileToggled(file, isToggled: true)
        }

        @MainActor
        func cachedCodeMapAPIForTesting(fullPath: String) -> FileAPI? {
            guard let file = findFileByFullPath(StandardizedPath.absolute(fullPath)) else { return nil }
            return validatedFileAPI(for: file)
        }

        @MainActor
        func enqueuePendingDeltasForTesting(_ deltas: [FileSystemDelta], forRootFolder folder: FolderViewModel) async {
            _ = await workspaceFileContextStore.enqueueDeferredReplayDeltas(deltas, forRootKey: folder.standardizedFullPath)
        }

        @MainActor
        func applyFileSystemDeltasForTesting(
            _ deltas: [FileSystemDelta],
            forRootFolder folder: FolderViewModel
        ) async {
            await applyFileSystemDeltas(
                deltas,
                forRootKey: folder.standardizedFullPath,
                deferIfUnfocused: false
            )
        }

        @MainActor
        func receiveLiveFileSystemDeltasForTesting(
            _ deltas: [FileSystemDelta],
            forRootFolder folder: FolderViewModel
        ) async {
            await applyFileSystemDeltas(
                deltas,
                forRootKey: folder.standardizedFullPath,
                deferIfUnfocused: true
            )
        }

        @MainActor
        func pendingDeltaCountForTesting(forRootFolder folder: FolderViewModel) async -> Int {
            await workspaceFileContextStore.pendingDeferredReplayDeltaCount(forRootKey: folder.standardizedFullPath)
        }

        #if DEBUG
            @MainActor
            func deferredReplayBufferDiagnosticsForTesting() async -> DeferredReplayBufferDiagnostics {
                await workspaceFileContextStore.deferredReplayDiagnosticsSnapshot()
            }

            @MainActor
            func debugCodemapMemoryCounters() async -> CodeScanActor.CodemapMemoryCounters {
                await workspaceFileContextStore.codemapMemoryCounters()
            }
        #endif

        @MainActor
        func waitForDeltaReplayCompletionForTesting() async {
            while true {
                if let task = deltaReplayTask {
                    await task.value
                    continue
                }
                if await !(workspaceFileContextStore.hasDeferredReplayPendingWork()), !isReplayingDeltas {
                    return
                }
                await Task.yield()
            }
        }
    #endif
    /// Bulk select operation - explicitly @MainActor for consistency with deselectFiles
    /// and to ensure selectedFiles mutations are always on the main thread
    @MainActor
    func selectFiles(withPaths paths: [String], allowEmpty: Bool = false, clear: Bool = true) async {
        if paths.isEmpty, !allowEmpty {
            return
        }

        if clear {
            // Clear the current file selection
            await clearSelection()
        }

        // Normalize all paths using the unified helper (keeps absolute paths absolute)
        let normalizedPaths = paths.map { normalizeUserInputPath($0) }

        // Use bulk lookup for efficiency
        let foundFiles = await findFiles(atPaths: normalizedPaths)

        // Batch all additions (already on MainActor, no need to hop)
        performSelectionBatch {
            for (_, fileVM) in foundFiles {
                if !fileVM.isChecked {
                    fileVM.setIsChecked(true)
                }
            }
        }

        // NEW: recompute only branches touched by this batch
        let parentFolders = Array(Set(foundFiles.values.compactMap(\.parentFolder)))
        for parent in parentFolders {
            recomputeAncestorStates(startingAt: parent)
        }
    }

    /// Bulk deselect operation that mirrors selectFiles
    @MainActor
    func deselectFiles(withPaths paths: [String]) async {
        guard !paths.isEmpty else { return }

        // Normalize all paths using the unified helper (keeps absolute paths absolute)
        let normalizedPaths = paths.map { normalizeUserInputPath($0) }

        // Resolve to FileViewModels in bulk
        let foundFiles = await findFiles(atPaths: normalizedPaths)

        // Batch all deselections into a single mutation & cache update (already on MainActor)
        performSelectionBatch {
            for (_, fileVM) in foundFiles {
                if fileVM.isChecked {
                    fileVM.setIsChecked(false)
                }
            }
        }

        // Recompute only affected ancestors (O(depth) each)
        var seen = Set<UUID>()
        for fileVM in foundFiles.values {
            if let parent = fileVM.parentFolder, seen.insert(parent.id).inserted {
                recomputeAncestorStates(startingAt: parent)
            }
        }
    }

    private var codeScanEnabled = true

    // Add at the class level in WorkspaceFilesViewModel
    private var codeScanTasks: [UUID: Task<Void, Never>] = [:]
    private var currentBatchScanTask: Task<Void, Never>?

    // NEW: holds the most recent ad-hoc "enqueue scans for files" task
    private var currentAdhocScanEnqueueTask: Task<Void, Never>?
    private var replayScanEnqueueTasks: [UUID: Task<Void, Never>] = [:]

    @MainActor private var cachedSearchFolderSuffixIndexByScope: [LookupRootScope: (generation: UInt64, index: SearchFolderSuffixIndex<FolderViewModel>)] = [:]

    private struct InitialRootEnqueueTask {
        let id: UUID
        let task: Task<Void, Never>
    }

    // NEW: per-root initial-load enqueue tasks (avoid cross-root cancellation)
    private var initialRootScanEnqueueTasks: [String: InitialRootEnqueueTask] = [:]

    /// Cancels any currently queued/active scans in the actor, plus any local tasks
    func setCodeScanEnabled(_ isEnabled: Bool) async {
        let wasEnabled = codeScanEnabled
        codeScanEnabled = isEnabled
        if !wasEnabled, isEnabled {
            // Just got enabled, rescan if needed
            await rescanAllFilesIfLoaded()
        } else if !isEnabled {
            // Disabled state should always perform comprehensive VM-level cancellation,
            // even if callers repeat the request while already disabled.
            await cancelAllScans()
        }
    }

    // ------------------------------------------------------------------
    // MARK: Unified bulk path selection helpers (files and folders)

    // ------------------------------------------------------------------

    /// Convert absolute path to the canonical client-facing workspace path.
    private func toAliasPrefixedPath(_ absPath: String) -> String? {
        let stdPath = (absPath as NSString).standardizingPath
        guard let root = visibleWorkspaceRoots()
            .filter({
                let rootPath = $0.standardizedFullPath
                return stdPath == rootPath || stdPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
            })
            .max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count })
        else {
            return nil
        }
        let relative = String(stdPath.dropFirst(root.standardizedFullPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return clientDisplayPath(root: root, relativePath: relative)
    }

    struct SelectionResult {
        let addedFiles: [String] // Alias-prefixed relative paths of added files (e.g., "RootName/path/to/file")
        let removedFiles: [String] // Alias-prefixed relative paths of removed files (e.g., "RootName/path/to/file")
        let invalidPaths: [String] // User input paths that couldn't be resolved
        let resolvedMap: [String: String] // Map from user input to resolved path
    }

    struct SelectionSliceInput {
        let path: String
        let ranges: [LineRange]
    }

    struct SelectionSlicesMutationResult {
        let invalidPaths: [String]
        let resolvedMap: [String: String]
        let snapshot: [UUID: [LineRange]]
    }

    private struct SliceMutationPayload {
        let file: FileViewModel
        let relativePath: String
        let ranges: [LineRange]
        let modificationTime: Double
    }

    enum SelectionSliceError: LocalizedError {
        case workspaceUnavailable
        case noWorkspaceLoaded

        var errorDescription: String? {
            switch self {
            case .workspaceUnavailable:
                "Workspace context unavailable – cannot persist selection slices."
            case .noWorkspaceLoaded:
                "No workspace folders are currently loaded."
            }
        }
    }

    private func currentPartitionScope() throws -> PartitionScope {
        guard let workspaceID = currentWorkspaceID else {
            throw SelectionSliceError.workspaceUnavailable
        }
        return PartitionScope(workspaceID: workspaceID, tabID: currentTabID)
    }

    /// Bulk select by resolving input paths (files or folders), supporting
    /// relative or absolute inputs. Fuzzy matches are allowed when `exact=false`.
    /// - Parameters:
    ///   - paths: Input file and/or folder paths (relative or absolute)
    ///   - clear: If true, clears current selection before applying additions
    ///   - expandFolders: When true, expands matched folders to all descendant files
    ///   - exact: When true, bypass fuzzy matching for strict selection
    @MainActor
    func selectPaths(
        withPaths paths: [String],
        clear: Bool = false,
        expandFolders: Bool = true,
        exact: Bool = false
    ) async -> SelectionResult {
        let normInputs = paths
            .map { normalizeUserInputPath($0) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var resolvedFiles: [FileViewModel] = []
        var resolvedMap: [String: String] = [:]
        var invalid: [String] = []
        var issuesByInput: [String: PathResolutionIssue] = [:]

        let candidateInputs = normInputs.filter { input in
            if let issue = exactPathResolutionIssue(for: input, kind: .either) {
                issuesByInput[input] = issue
                return false
            }
            return true
        }

        let fileHits = await findFiles(atPaths: candidateInputs, profile: .mcpSelection)
        var satisfiedInputs = Set<String>(fileHits.keys)
        resolvedFiles.append(contentsOf: fileHits.values)
        for (inp, vm) in fileHits {
            resolvedMap[inp] = mcpDisplayPath(for: vm)
        }

        let remaining = candidateInputs.filter { !satisfiedInputs.contains($0) }
        var matchedFolders: [FolderViewModel] = []
        var folderResolvedInputs: [String: FolderViewModel] = [:]
        for p in remaining {
            let resolution = resolveFolderInput(p)
            if let folder = resolution.folder {
                matchedFolders.append(folder)
                folderResolvedInputs[p] = folder
            } else if let issue = resolution.issue {
                issuesByInput[p] = issue
            }
        }

        if !exact {
            let unresolved = remaining.filter { folderResolvedInputs[$0] == nil && issuesByInput[$0] == nil }
            if !unresolved.isEmpty {
                let lookupRequests = unresolved.map {
                    WorkspacePathLookupRequest(userPath: $0, profile: .mcpSelection, rootScope: .visibleWorkspace)
                }
                let lookupResults = await workspaceFileContextStore.lookupPaths(lookupRequests)
                for raw in unresolved {
                    guard let lookup = lookupResults[raw] else { continue }
                    let loc = lookup.location
                    if let folder = resolveFolder(rootPath: loc.rootPath, correctedPath: loc.correctedPath) {
                        matchedFolders.append(folder)
                        folderResolvedInputs[raw] = folder
                    } else if let file = resolveFile(rootPath: loc.rootPath, correctedPath: loc.correctedPath) {
                        resolvedFiles.append(file)
                        resolvedMap[raw] = mcpDisplayPath(for: file)
                        satisfiedInputs.insert(raw)
                    }
                }
            }
        }

        if expandFolders, !matchedFolders.isEmpty {
            for folder in matchedFolders {
                resolvedFiles.append(contentsOf: getFilesRecursively(under: folder))
            }
            for (inp, folder) in folderResolvedInputs {
                resolvedMap[inp] = mcpDisplayPath(for: folder)
                satisfiedInputs.insert(inp)
            }
        }

        for p in normInputs where !satisfiedInputs.contains(p) && folderResolvedInputs[p] == nil {
            if let issue = issuesByInput[p] {
                invalid.append(PathResolutionIssueRenderer.message(for: issue))
            } else {
                invalid.append(p)
            }
        }

        let beforeSelectedIDs = Set(selectedFiles.map(\.id))

        if clear {
            await clearSelection()
        }

        await MainActor.run {
            self.performSelectionBatch {
                for file in resolvedFiles where !file.isChecked {
                    file.setIsChecked(true)
                }
            }
        }

        let parentFolders = Array(Set(resolvedFiles.compactMap(\.parentFolder)))
        for parent in parentFolders {
            recomputeAncestorStates(startingAt: parent)
        }

        let afterSelectedIDs = Set(selectedFiles.map(\.id))
        let addedIDs = afterSelectedIDs.subtracting(beforeSelectedIDs)
        let addedAbsPaths = selectedFiles
            .filter { addedIDs.contains($0.id) }
            .map(\.standardizedFullPath)
        let addedPaths = addedAbsPaths.compactMap { toAliasPrefixedPath($0) }

        return SelectionResult(
            addedFiles: addedPaths,
            removedFiles: [],
            invalidPaths: invalid,
            resolvedMap: resolvedMap
        )
    }

    /// Bulk deselect by resolving input paths (files or folders), supporting
    /// relative or absolute inputs. Fuzzy matches are allowed when `exact=false`.
    @MainActor
    func deselectPaths(
        withPaths paths: [String],
        expandFolders: Bool = true,
        exact: Bool = false
    ) async -> SelectionResult {
        let normInputs = paths
            .map { normalizeUserInputPath($0) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var resolvedFiles: [FileViewModel] = []
        var resolvedMap: [String: String] = [:]
        var invalid: [String] = []
        var issuesByInput: [String: PathResolutionIssue] = [:]

        let candidateInputs = normInputs.filter { input in
            if let issue = exactPathResolutionIssue(for: input, kind: .either) {
                issuesByInput[input] = issue
                return false
            }
            return true
        }

        let fileHits = await findFiles(atPaths: candidateInputs, profile: .mcpSelection)
        var satisfiedInputs = Set<String>(fileHits.keys)
        resolvedFiles.append(contentsOf: fileHits.values)
        for (inp, vm) in fileHits {
            resolvedMap[inp] = mcpDisplayPath(for: vm)
        }

        let remaining = candidateInputs.filter { !satisfiedInputs.contains($0) }
        var matchedFolders: [FolderViewModel] = []
        var folderResolvedInputs: [String: FolderViewModel] = [:]
        for p in remaining {
            let resolution = resolveFolderInput(p)
            if let folder = resolution.folder {
                matchedFolders.append(folder)
                folderResolvedInputs[p] = folder
            } else if let issue = resolution.issue {
                issuesByInput[p] = issue
            }
        }

        if !exact {
            let unresolved = remaining.filter { folderResolvedInputs[$0] == nil && issuesByInput[$0] == nil }
            if !unresolved.isEmpty {
                let lookupRequests = unresolved.map {
                    WorkspacePathLookupRequest(userPath: $0, profile: .mcpSelection, rootScope: .visibleWorkspace)
                }
                let lookupResults = await workspaceFileContextStore.lookupPaths(lookupRequests)
                for raw in unresolved {
                    guard let lookup = lookupResults[raw] else { continue }
                    let loc = lookup.location
                    if let folder = resolveFolder(rootPath: loc.rootPath, correctedPath: loc.correctedPath) {
                        matchedFolders.append(folder)
                        folderResolvedInputs[raw] = folder
                    } else if let file = resolveFile(rootPath: loc.rootPath, correctedPath: loc.correctedPath) {
                        resolvedFiles.append(file)
                        resolvedMap[raw] = mcpDisplayPath(for: file)
                        satisfiedInputs.insert(raw)
                    }
                }
            }
        }

        if expandFolders, !matchedFolders.isEmpty {
            for folder in matchedFolders {
                resolvedFiles.append(contentsOf: getFilesRecursively(under: folder))
            }
            for (inp, folder) in folderResolvedInputs {
                resolvedMap[inp] = mcpDisplayPath(for: folder)
                satisfiedInputs.insert(inp)
            }
        }

        for p in normInputs where !satisfiedInputs.contains(p) && folderResolvedInputs[p] == nil {
            if let issue = issuesByInput[p] {
                invalid.append(PathResolutionIssueRenderer.message(for: issue))
            } else {
                invalid.append(p)
            }
        }

        let beforeSelectedIDs = Set(selectedFiles.map(\.id))
        let beforeAbs: [UUID: String] = {
            var m: [UUID: String] = [:]
            for f in selectedFiles {
                m[f.id] = f.standardizedFullPath
            }
            return m
        }()

        await MainActor.run {
            self.performSelectionBatch {
                for file in resolvedFiles where file.isChecked {
                    file.setIsChecked(false)
                }
            }
        }

        var seen = Set<UUID>()
        for file in resolvedFiles {
            if let parent = file.parentFolder, seen.insert(parent.id).inserted {
                recomputeAncestorStates(startingAt: parent)
            }
        }

        let afterSelectedIDs = Set(selectedFiles.map(\.id))
        let removedIDs = beforeSelectedIDs.subtracting(afterSelectedIDs)
        let removedAbsPaths = removedIDs.compactMap { beforeAbs[$0] }
        let removedPaths = removedAbsPaths.compactMap { toAliasPrefixedPath($0) }

        return SelectionResult(
            addedFiles: [],
            removedFiles: removedPaths,
            invalidPaths: invalid,
            resolvedMap: resolvedMap
        )
    }

    private struct SliceHydrationMetadata {
        let rootKey: String
        let relativeKey: String
        let ranges: [LineRange]
        let modificationTime: Double
    }

    private func standardizedStoredSelectionPath(_ path: String) -> String {
        StandardizedPath.absolute(path)
    }

    private func standardizedStoredSelectionPaths(_ paths: [String]) -> [String] {
        paths.map(standardizedStoredSelectionPath)
    }

    /// Normalizes persisted slice keys once at ingestion so downstream consumers stay on the
    /// canonical fast path. If legacy data contains both canonical and non-canonical keys for
    /// the same file, the canonical key wins; multiple non-canonical variants are merged.
    private func standardizedStoredSelectionSlices(_ slices: [String: [LineRange]]) -> [String: [LineRange]] {
        guard !slices.isEmpty else { return [:] }

        var canonical: [String: [LineRange]] = [:]
        var legacyFallbacks: [String: [LineRange]] = [:]

        for (path, ranges) in slices where !ranges.isEmpty {
            let standardized = standardizedStoredSelectionPath(path)
            let normalizedRanges = SliceRangeMath.normalize(ranges)
            guard !normalizedRanges.isEmpty else { continue }
            if path == standardized {
                canonical[standardized] = normalizedRanges
                continue
            }

            if var existing = legacyFallbacks[standardized] {
                existing.append(contentsOf: normalizedRanges)
                legacyFallbacks[standardized] = SliceRangeMath.normalize(existing)
            } else {
                legacyFallbacks[standardized] = normalizedRanges
            }
        }

        for (path, ranges) in legacyFallbacks where canonical[path] == nil {
            canonical[path] = ranges
        }
        return canonical
    }

    @MainActor
    private func replaceInMemorySliceMirror(from stored: StoredSelection) {
        #if DEBUG
            let currentSlicesBefore = sliceStoreCounts(currentSlicesByRoot)
            let requestedSlices = standardizedStoredSelectionSlices(stored.slices)
            let requestedRangeCount = requestedSlices.values.reduce(0) { $0 + $1.count }
        #else
            let requestedSlices = standardizedStoredSelectionSlices(stored.slices)
        #endif
        var nextSlicesByRoot: [String: [String: PartitionStore.StoredSlices]] = [:]

        for (path, ranges) in requestedSlices {
            guard let file = fileHierarchyIndex.filesByFullPath[path] else { continue }
            let normalizedRanges = SliceRangeMath.normalize(ranges)
            guard !normalizedRanges.isEmpty else { continue }
            nextSlicesByRoot[file.standardizedRootFolderPath, default: [:]][file.standardizedRelativePath] = PartitionStore.StoredSlices(
                ranges: normalizedRanges,
                fileModificationTime: file.modificationDate.timeIntervalSince1970,
                anchors: nil
            )
        }

        currentSlicesByRoot = nextSlicesByRoot
        let projection: [UUID: [LineRange]] = if selectedFiles.isEmpty {
            [:]
        } else {
            SelectionSliceCoordinator.buildFileIDProjection(
                from: currentSlicesByRoot,
                files: selectedFiles.map(workspaceFileRecordForSliceProjection)
            )
        }
        if projection != selectionSlicesByFileID {
            selectionSlicesByFileID = projection
        }

        #if DEBUG
            let currentSlicesAfter = sliceStoreCounts(currentSlicesByRoot)
            let projectionRangeCount = projection.values.reduce(0) { $0 + $1.count }
            WorkspaceRestorePerfLog.event(
                "selection.applyStoredSelection.sliceMirror",
                fields: [
                    "requestedSliceFiles": "\(requestedSlices.count)",
                    "requestedSliceRanges": "\(requestedRangeCount)",
                    "currentSlicesBeforeFiles": "\(currentSlicesBefore.files)",
                    "currentSlicesBeforeRanges": "\(currentSlicesBefore.ranges)",
                    "currentSlicesAfterFiles": "\(currentSlicesAfter.files)",
                    "currentSlicesAfterRanges": "\(currentSlicesAfter.ranges)",
                    "projectionAfterFiles": "\(projection.count)",
                    "projectionAfterRanges": "\(projectionRangeCount)",
                    "selectedFiles": "\(selectedFiles.count)",
                    "currentTabID": WorkspaceRestorePerfLog.shortID(currentTabID)
                ]
            )
        #endif
    }

    #if DEBUG
        private func sliceStoreCounts(_ store: [String: [String: PartitionStore.StoredSlices]]) -> (files: Int, ranges: Int) {
            let files = store.values.reduce(0) { $0 + $1.count }
            let ranges = store.values.reduce(0) { total, root in
                total + root.values.reduce(0) { $0 + $1.ranges.count }
            }
            return (files, ranges)
        }
    #endif

    private func standardizedAPIFilePath(_ api: FileAPI) -> String {
        StandardizedPath.absolute(api.filePath)
    }

    @MainActor
    func hydrateSlicesForActiveTab(from tabSelection: StoredSelection) async {
        #if DEBUG
            let hydrateSlicesStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            var hydrateSlicesOutcome = "completed"
            var hydrateSlicesRootCount = rootFolders.count
            var hydrateSlicesRequestedFiles = tabSelection.slices.count
            var hydrateSlicesResolvedFiles = 0
            var hydrateSlicesLoadedPartitionFiles = 0
            var hydrateSlicesPendingPersistRoots = 0
            var hydrateSlicesPendingPersistFiles = 0
            defer {
                WorkspaceRestorePerfLog.event(
                    "selection.hydrateSlices",
                    fields: [
                        "rootCount": "\(hydrateSlicesRootCount)",
                        "requestedSliceFiles": "\(hydrateSlicesRequestedFiles)",
                        "resolvedSliceFiles": "\(hydrateSlicesResolvedFiles)",
                        "loadedPartitionFiles": "\(hydrateSlicesLoadedPartitionFiles)",
                        "pendingPersistRoots": "\(hydrateSlicesPendingPersistRoots)",
                        "pendingPersistFiles": "\(hydrateSlicesPendingPersistFiles)",
                        "outcome": hydrateSlicesOutcome,
                        "duration": hydrateSlicesStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            }
        #endif
        guard !rootFolders.isEmpty else {
            #if DEBUG
                hydrateSlicesOutcome = "noRoots"
            #endif
            currentSlicesByRoot.removeAll()
            requestSelectionSliceSnapshotRebuild(reason: "hydrateSlices.noRoots")
            return
        }

        guard let scope = try? currentPartitionScope() else {
            #if DEBUG
                hydrateSlicesOutcome = "noScope"
            #endif
            currentSlicesByRoot.removeAll()
            requestSelectionSliceSnapshotRebuild(reason: "hydrateSlices.noScope")
            return
        }

        let rootPaths = rootFolders.map(\.standardizedFullPath)
        #if DEBUG
            hydrateSlicesRootCount = rootPaths.count
        #endif
        let normalizedSlices = standardizedStoredSelectionSlices(tabSelection.slices)
        if !normalizedSlices.isEmpty {
            _ = await findFiles(atPaths: Array(normalizedSlices.keys), profile: .mcpSelection)
        }
        let sliceMetadata: [SliceHydrationMetadata] = normalizedSlices.compactMap { entry in
            let standardizedFull = entry.key
            guard let vm = fileHierarchyIndex.filesByFullPath[standardizedFull] else { return nil }
            let rootKey = vm.standardizedRootFolderPath
            let relKey = vm.standardizedRelativePath
            let normalized = SliceRangeMath.normalize(entry.value)
            return SliceHydrationMetadata(
                rootKey: rootKey,
                relativeKey: relKey,
                ranges: normalized,
                modificationTime: vm.modificationDate.timeIntervalSince1970
            )
        }
        #if DEBUG
            hydrateSlicesResolvedFiles = sliceMetadata.count
        #endif

        let selectionSliceCoordinator = selectionSliceCoordinator
        let loadTask = Task.detached(priority: .utility) { () -> (
            [String: [String: PartitionStore.StoredSlices]],
            [String: [String: PartitionStore.SliceUpdate]]
        ) in
            var next: [String: [String: PartitionStore.StoredSlices]] = [:]
            var loadedByRoot: [String: [String: PartitionStore.StoredSlices]] = [:]

            for rootPath in rootPaths {
                let data = await selectionSliceCoordinator.loadSlices(forRootPath: rootPath, scope: scope)
                next[rootPath] = data
                loadedByRoot[rootPath] = data
            }

            var toPersist: [String: [String: PartitionStore.SliceUpdate]] = [:]
            let desiredByRoot = Dictionary(grouping: sliceMetadata, by: \.rootKey)

            for rootPath in rootPaths {
                let desiredRoot = Dictionary(
                    uniqueKeysWithValues: (desiredByRoot[rootPath] ?? []).map { ($0.relativeKey, $0) }
                )
                let existingRoot = loadedByRoot[rootPath] ?? [:]

                for relativeKey in existingRoot.keys where desiredRoot[relativeKey] == nil {
                    var stored = next[rootPath] ?? [:]
                    stored.removeValue(forKey: relativeKey)
                    next[rootPath] = stored

                    var updates = toPersist[rootPath] ?? [:]
                    updates[relativeKey] = PartitionStore.SliceUpdate(
                        ranges: [],
                        fileModificationTime: nil,
                        anchors: []
                    )
                    toPersist[rootPath] = updates
                }

                for payload in desiredRoot.values {
                    guard !payload.ranges.isEmpty else { continue }

                    let existing = existingRoot[payload.relativeKey]
                    let existingRanges = existing.map { SliceRangeMath.normalize($0.ranges) } ?? []
                    let shouldInsert = existing == nil
                    let shouldReplace = existing != nil && existingRanges != payload.ranges
                    guard shouldInsert || shouldReplace else { continue }

                    var stored = next[rootPath] ?? [:]
                    stored[payload.relativeKey] = PartitionStore.StoredSlices(
                        ranges: payload.ranges,
                        fileModificationTime: payload.modificationTime,
                        anchors: shouldReplace ? nil : existing?.anchors
                    )
                    next[rootPath] = stored

                    var updates = toPersist[rootPath] ?? [:]
                    updates[payload.relativeKey] = PartitionStore.SliceUpdate(
                        ranges: payload.ranges,
                        fileModificationTime: payload.modificationTime,
                        anchors: shouldReplace ? [] : nil
                    )
                    toPersist[rootPath] = updates
                }
            }
            return (next, toPersist)
        }

        let (snapshot, pendingPersist) = await loadTask.value
        #if DEBUG
            hydrateSlicesLoadedPartitionFiles = snapshot.values.reduce(0) { $0 + $1.count }
            hydrateSlicesPendingPersistRoots = pendingPersist.count
            hydrateSlicesPendingPersistFiles = pendingPersist.values.reduce(0) { $0 + $1.count }
        #endif

        guard !Task.isCancelled else {
            #if DEBUG
                hydrateSlicesOutcome = "cancelled"
            #endif
            return
        }
        guard currentTabID == scope.tabID else {
            #if DEBUG
                hydrateSlicesOutcome = "staleTab"
            #endif
            return
        }

        await applySlicesSnapshot(snapshot: snapshot, pendingPersist: pendingPersist, scope: scope)
    }

    @MainActor
    private func applySlicesSnapshot(
        snapshot: [String: [String: PartitionStore.StoredSlices]],
        pendingPersist: [String: [String: PartitionStore.SliceUpdate]],
        scope: PartitionScope
    ) async {
        #if DEBUG
            let applySlicesSnapshotStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            defer {
                WorkspaceRestorePerfLog.event(
                    "selection.applySlicesSnapshot",
                    fields: [
                        "rootCount": "\(snapshot.count)",
                        "snapshotFiles": "\(snapshot.values.reduce(0) { $0 + $1.count })",
                        "pendingPersistRoots": "\(pendingPersist.count)",
                        "pendingPersistFiles": "\(pendingPersist.values.reduce(0) { $0 + $1.count })",
                        "duration": applySlicesSnapshotStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            }
        #endif
        currentSlicesByRoot = snapshot
        requestSelectionSliceSnapshotRebuild(reason: "applySlicesSnapshot")

        guard !pendingPersist.isEmpty else { return }

        for (rootPath, updates) in pendingPersist {
            do {
                _ = try await selectionSliceCoordinator.applyPartitionUpdates(
                    forRootPath: rootPath,
                    scope: scope,
                    updates: updates,
                    mode: .setPaths
                )
            } catch {
                if Self.isLoggingEnabled {
                    print("Failed to persist slices during hydrate for root \(rootPath): \(error)")
                }
            }
        }
    }

    private static let sliceTimestampTolerance: Double = 0.000_5

    @MainActor
    func onActiveTabChangedFast(_ tab: ComposeTabState) {
        #if DEBUG
            let activeTabFastStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        setActiveTabID(tab.id)
        selectionSlicesByFileID.removeAll()
        requestSelectionSliceSnapshotRebuild(reason: "activeTabChanged.fast")
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "selection.activeTabChanged.fast",
                fields: [
                    "tabID": WorkspaceRestorePerfLog.shortID(tab.id),
                    "duration": activeTabFastStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
    }

    @MainActor
    func onActiveTabChangedHeavy(
        for tabID: UUID,
        selection: StoredSelection
    ) async {
        #if DEBUG
            let activeTabHeavyStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            var activeTabHeavyOutcome = "completed"
            defer {
                WorkspaceRestorePerfLog.event(
                    "selection.activeTabChanged.heavy",
                    fields: [
                        "tabID": WorkspaceRestorePerfLog.shortID(tabID),
                        "selectedPaths": "\(selection.selectedPaths.count)",
                        "sliceFiles": "\(selection.slices.count)",
                        "outcome": activeTabHeavyOutcome,
                        "duration": activeTabHeavyStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            }
        #endif
        guard currentTabID == tabID else {
            #if DEBUG
                activeTabHeavyOutcome = "staleTab"
            #endif
            return
        }
        await applyStoredSelection(selection)
        guard !Task.isCancelled else {
            #if DEBUG
                activeTabHeavyOutcome = "cancelled"
            #endif
            return
        }
        guard currentTabID == tabID else {
            #if DEBUG
                activeTabHeavyOutcome = "staleTab"
            #endif
            return
        }
        await hydrateSlicesForActiveTab(from: selection)
    }

    @MainActor
    func onActiveTabChanged(_ tab: ComposeTabState) async {
        onActiveTabChangedFast(tab)
        await onActiveTabChangedHeavy(for: tab.id, selection: tab.selection)
    }

    @MainActor
    private func sliceAnchorContent(for file: FileViewModel) async -> String? {
        let snapshot = await file.cachedContentSnapshot()
        if let content = snapshot.content {
            return content
        }

        let rootKey = file.standardizedRootFolderPath
        let relKey = file.standardizedRelativePath
        guard let workspaceRoot = workspaceFileContextRootsByRootKey[rootKey] else { return nil }
        return try? await workspaceFileContextStore.readContent(rootID: workspaceRoot.id, relativePath: relKey)
    }

    @MainActor
    private func buildAnchorsByRelativePath(
        for payloads: [SliceMutationPayload]
    ) async -> [String: [SliceAnchor]] {
        guard !payloads.isEmpty else { return [:] }

        var mergedRangesByPath: [String: [LineRange]] = [:]
        var fileByPath: [String: FileViewModel] = [:]

        for payload in payloads {
            mergedRangesByPath[payload.relativePath, default: []].append(contentsOf: payload.ranges)
            fileByPath[payload.relativePath] = payload.file
        }

        var result: [String: [SliceAnchor]] = [:]
        for (relativePath, ranges) in mergedRangesByPath {
            let normalized = SliceRangeMath.normalize(ranges)
            guard !normalized.isEmpty else { continue }
            guard let file = fileByPath[relativePath] else { continue }
            guard let content = await sliceAnchorContent(for: file) else { continue }

            let anchors = await Task.detached(priority: .utility) {
                SliceRebaseEngine.buildAnchors(content: content, ranges: normalized)
            }.value
            if !anchors.isEmpty {
                result[relativePath] = anchors
            }
        }

        return result
    }

    @MainActor
    func setSelectionSlices(
        entries: [SelectionSliceInput],
        mode: SliceMutationMode,
        persistWorkspace: Bool = true
    ) async throws -> SelectionSlicesMutationResult {
        guard !rootFolders.isEmpty else {
            throw SelectionSliceError.noWorkspaceLoaded
        }

        let scope = try currentPartitionScope()

        if entries.isEmpty {
            if mode == .set {
                let roots = Set(rootFolders.map(\.standardizedFullPath))
                for rootPath in roots {
                    let post = try await selectionSliceCoordinator.applyPartitionUpdates(
                        forRootPath: rootPath,
                        scope: scope,
                        updates: [:],
                        mode: .set
                    )
                    if post.isEmpty {
                        currentSlicesByRoot.removeValue(forKey: rootPath)
                    } else {
                        currentSlicesByRoot[rootPath] = post
                    }
                }
                requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")
                if persistWorkspace {
                    requestWorkspaceSaveDebounced()
                }
            }

            return SelectionSlicesMutationResult(
                invalidPaths: [],
                resolvedMap: [:],
                snapshot: selectionSlicesByFileID
            )
        }

        let normalizedInputs = entries.map { normalizeUserInputPath($0.path) }
        let lookup = await findFiles(atPaths: normalizedInputs, profile: .mcpSelection)

        var invalid: [String] = []
        var resolved: [String: String] = [:]

        var grouped: [String: [SliceMutationPayload]] = [:]

        for (index, entry) in entries.enumerated() {
            let normalized = normalizedInputs[index]
            guard let fileVM = lookup[normalized] else {
                invalid.append(entry.path)
                continue
            }

            let rootKey = fileVM.standardizedRootFolderPath
            let relKey = fileVM.standardizedRelativePath
            let payload = SliceMutationPayload(
                file: fileVM,
                relativePath: relKey,
                ranges: entry.ranges,
                modificationTime: fileVM.modificationDate.timeIntervalSince1970
            )
            grouped[rootKey, default: []].append(payload)
            resolved[entry.path] = mcpDisplayPath(for: fileVM)
        }

        if grouped.isEmpty {
            if mode == .set {
                let roots = Set(rootFolders.map(\.standardizedFullPath))
                for rootPath in roots {
                    let post = try await selectionSliceCoordinator.applyPartitionUpdates(
                        forRootPath: rootPath,
                        scope: scope,
                        updates: [:],
                        mode: .set
                    )
                    if post.isEmpty {
                        currentSlicesByRoot.removeValue(forKey: rootPath)
                    } else {
                        currentSlicesByRoot[rootPath] = post
                    }
                }
                requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")
                if persistWorkspace {
                    requestWorkspaceSaveDebounced()
                }
            }

            return SelectionSlicesMutationResult(
                invalidPaths: invalid,
                resolvedMap: resolved,
                snapshot: selectionSlicesByFileID
            )
        }

        var filesToSelect = Set<FileViewModel>()
        var anchorsByRoot: [String: [String: [SliceAnchor]]] = [:]
        if mode != .remove {
            for (rootPath, payloads) in grouped {
                anchorsByRoot[rootPath] = await buildAnchorsByRelativePath(for: payloads)
            }
        }

        switch mode {
        case .set:
            let rootPaths = Set(rootFolders.map(\.standardizedFullPath))
            var newMap: [String: [String: PartitionStore.StoredSlices]] = [:]

            for rootPath in rootPaths {
                let payloads = grouped[rootPath] ?? []
                let anchorMap = anchorsByRoot[rootPath] ?? [:]
                var updates: [String: PartitionStore.SliceUpdate] = [:]
                for payload in payloads {
                    if payload.ranges.isEmpty {
                        updates[payload.relativePath] = PartitionStore.SliceUpdate(
                            ranges: [],
                            fileModificationTime: payload.modificationTime,
                            anchors: nil
                        )
                    } else {
                        var update = updates[payload.relativePath] ?? PartitionStore.SliceUpdate(
                            ranges: [],
                            fileModificationTime: payload.modificationTime,
                            anchors: anchorMap[payload.relativePath]
                        )
                        update.ranges.append(contentsOf: payload.ranges)
                        update.fileModificationTime = payload.modificationTime
                        update.anchors = anchorMap[payload.relativePath]
                        updates[payload.relativePath] = update
                    }
                }

                let post = try await selectionSliceCoordinator.applyPartitionUpdates(
                    forRootPath: rootPath,
                    scope: scope,
                    updates: updates,
                    mode: .set
                )

                if !post.isEmpty {
                    newMap[rootPath] = post
                }

                if !payloads.isEmpty {
                    for payload in payloads {
                        if let entry = post[payload.relativePath], !entry.ranges.isEmpty {
                            if !payload.file.isChecked {
                                filesToSelect.insert(payload.file)
                            }
                            // Clean transition from codemap → selected
                            removeCodemapFile(payload.file)
                        }
                    }
                }
            }

            currentSlicesByRoot = newMap

        case .setPaths:
            // File-scoped replacement: replace slices only for specified files
            var map = currentSlicesByRoot

            for (rootPath, payloads) in grouped {
                let anchorMap = anchorsByRoot[rootPath] ?? [:]
                var updates: [String: PartitionStore.SliceUpdate] = [:]
                for payload in payloads {
                    if payload.ranges.isEmpty {
                        updates[payload.relativePath] = PartitionStore.SliceUpdate(
                            ranges: [],
                            fileModificationTime: payload.modificationTime,
                            anchors: nil
                        )
                    } else {
                        var update = updates[payload.relativePath] ?? PartitionStore.SliceUpdate(
                            ranges: [],
                            fileModificationTime: payload.modificationTime,
                            anchors: anchorMap[payload.relativePath]
                        )
                        update.ranges.append(contentsOf: payload.ranges)
                        update.fileModificationTime = payload.modificationTime
                        update.anchors = anchorMap[payload.relativePath]
                        updates[payload.relativePath] = update
                    }
                }

                let post = try await selectionSliceCoordinator.applyPartitionUpdates(
                    forRootPath: rootPath,
                    scope: scope,
                    updates: updates,
                    mode: .setPaths
                )

                if post.isEmpty {
                    map.removeValue(forKey: rootPath)
                } else {
                    map[rootPath] = post
                }

                for payload in payloads {
                    if let entry = post[payload.relativePath], !entry.ranges.isEmpty {
                        if !payload.file.isChecked {
                            filesToSelect.insert(payload.file)
                        }
                        // Clean transition from codemap → selected
                        removeCodemapFile(payload.file)
                    }
                }
            }

            currentSlicesByRoot = map

        case .add, .remove:
            var map = currentSlicesByRoot
            for (rootPath, payloads) in grouped {
                let anchorMap = anchorsByRoot[rootPath] ?? [:]
                var updates: [String: PartitionStore.SliceUpdate] = [:]
                for payload in payloads {
                    if payload.ranges.isEmpty {
                        updates[payload.relativePath] = PartitionStore.SliceUpdate(
                            ranges: [],
                            fileModificationTime: payload.modificationTime,
                            anchors: nil
                        )
                    } else {
                        var update = updates[payload.relativePath] ?? PartitionStore.SliceUpdate(
                            ranges: [],
                            fileModificationTime: payload.modificationTime,
                            anchors: anchorMap[payload.relativePath]
                        )
                        update.ranges.append(contentsOf: payload.ranges)
                        update.fileModificationTime = payload.modificationTime
                        if mode != .remove {
                            update.anchors = anchorMap[payload.relativePath]
                        } else {
                            update.anchors = nil
                        }
                        updates[payload.relativePath] = update
                    }
                }

                let post = try await selectionSliceCoordinator.applyPartitionUpdates(
                    forRootPath: rootPath,
                    scope: scope,
                    updates: updates,
                    mode: mode
                )

                if post.isEmpty {
                    map.removeValue(forKey: rootPath)
                } else {
                    map[rootPath] = post
                }

                if mode != .remove {
                    for payload in payloads {
                        if let entry = post[payload.relativePath], !entry.ranges.isEmpty {
                            if !payload.file.isChecked {
                                filesToSelect.insert(payload.file)
                            }
                            // Clean transition from codemap → selected
                            removeCodemapFile(payload.file)
                        }
                    }
                }
            }

            currentSlicesByRoot = map
        }

        if persistWorkspace {
            requestWorkspaceSaveDebounced()
        }

        if !filesToSelect.isEmpty {
            let pending = filesToSelect.filter { !$0.isChecked }
            if !pending.isEmpty {
                let parents = Array(Set(pending.compactMap(\.parentFolder)))
                performSelectionBatch {
                    for file in pending where !file.isChecked {
                        file.setIsChecked(true)
                    }
                }
                for parent in parents {
                    recomputeAncestorStates(startingAt: parent)
                }
            }
        }

        requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")

        return SelectionSlicesMutationResult(
            invalidPaths: invalid,
            resolvedMap: resolved,
            snapshot: selectionSlicesByFileID
        )
    }

    @MainActor
    func clearSelectionSlices(for file: FileViewModel) async throws {
        guard !rootFolders.isEmpty else {
            throw SelectionSliceError.noWorkspaceLoaded
        }

        let scope = try currentPartitionScope()
        let rootKey = file.standardizedRootFolderPath
        let relKey = file.standardizedRelativePath

        let storedBefore = currentSlicesByRoot[rootKey]?[relKey]
        let selectionBefore = selectionSlicesByFileID[file.id]

        // Exit early when there's nothing to remove
        if storedBefore == nil, selectionBefore == nil {
            return
        }

        let updates: [String: PartitionStore.SliceUpdate] = [
            relKey: PartitionStore.SliceUpdate(
                ranges: [],
                fileModificationTime: file.modificationDate.timeIntervalSince1970
            )
        ]

        let post = try await selectionSliceCoordinator.applyPartitionUpdates(
            forRootPath: rootKey,
            scope: scope,
            updates: updates,
            mode: .remove
        )

        if post.isEmpty {
            currentSlicesByRoot.removeValue(forKey: rootKey)
        } else {
            currentSlicesByRoot[rootKey] = post
        }

        requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")

        requestWorkspaceSaveDebounced()
    }

    @MainActor
    func getSelectionSlicesSnapshot() -> [UUID: [LineRange]] {
        selectionSlicesByFileID
    }

    @MainActor
    func selectionSlices(for file: FileViewModel) -> [LineRange]? {
        selectionSlicesByFileID[file.id]
    }

    @MainActor
    func selectionSlicesDisplayMap(filePathDisplay: FilePathDisplay) -> [String: [LineRange]] {
        guard !selectionSlicesByFileID.isEmpty else { return [:] }

        let multipleRoots = Set(selectedFiles.map(\.rootFolderPath)).count > 1
        var result: [String: [LineRange]] = [:]

        for file in selectedFiles {
            guard let ranges = selectionSlicesByFileID[file.id], !ranges.isEmpty else { continue }
            let key: String = switch filePathDisplay {
            case .full:
                file.fullPath
            case .relative:
                multipleRoots ? file.uniqueRelativePath : file.relativePath
            }
            result[key] = ranges
        }

        return result
    }

    @MainActor
    func withDeferredSelectionSliceSnapshotRebuild<T>(
        reason: String,
        operation: () async throws -> T
    ) async rethrows -> T {
        sliceSnapshotRebuildDeferralDepth += 1
        defer {
            sliceSnapshotRebuildDeferralDepth = max(0, sliceSnapshotRebuildDeferralDepth - 1)
            if sliceSnapshotRebuildDeferralDepth == 0 {
                flushDeferredSelectionSliceSnapshotRebuildIfNeeded(reason: reason)
            }
        }
        return try await operation()
    }

    @MainActor
    private func requestSelectionSliceSnapshotRebuild(reason: String) {
        guard sliceSnapshotRebuildDeferralDepth == 0 else {
            sliceSnapshotRebuildPending = true
            #if DEBUG
                sliceSnapshotRebuildPendingReasons.insert(reason)
                WorkspaceRestorePerfLog.event(
                    "selection.rebuildSlicesSnapshot",
                    fields: [
                        "mode": "deferredRequest",
                        "reason": reason,
                        "deferralDepth": "\(sliceSnapshotRebuildDeferralDepth)",
                        "pendingReasons": sliceSnapshotRebuildPendingReasons.sorted().joined(separator: ",")
                    ]
                )
            #endif
            return
        }

        performSelectionSlicesSnapshotRebuild(
            reason: reason,
            mode: "immediate",
            pendingReasons: []
        )
    }

    @MainActor
    private func flushDeferredSelectionSliceSnapshotRebuildIfNeeded(reason: String) {
        guard sliceSnapshotRebuildDeferralDepth == 0 else { return }
        guard sliceSnapshotRebuildPending else { return }
        #if DEBUG
            let pendingReasons = sliceSnapshotRebuildPendingReasons
            sliceSnapshotRebuildPendingReasons.removeAll()
        #else
            let pendingReasons = Set<String>()
        #endif
        sliceSnapshotRebuildPending = false
        performSelectionSlicesSnapshotRebuild(
            reason: reason,
            mode: "deferredFlush",
            pendingReasons: pendingReasons
        )
    }

    @MainActor
    private func performSelectionSlicesSnapshotRebuild(
        reason: String,
        mode: String,
        pendingReasons: Set<String>
    ) {
        #if DEBUG
            let rebuildStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            var snapshotFiles = 0
            defer {
                WorkspaceRestorePerfLog.event(
                    "selection.rebuildSlicesSnapshot",
                    fields: [
                        "mode": mode,
                        "reason": reason,
                        "pendingReasons": pendingReasons.sorted().joined(separator: ","),
                        "selectedFiles": "\(selectedFiles.count)",
                        "snapshotFiles": "\(snapshotFiles)",
                        "duration": rebuildStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            }
        #endif
        guard !selectedFiles.isEmpty else {
            if !selectionSlicesByFileID.isEmpty {
                selectionSlicesByFileID = [:]
            }
            return
        }

        let snapshot = SelectionSliceCoordinator.buildFileIDProjection(
            from: currentSlicesByRoot,
            files: selectedFiles.map(workspaceFileRecordForSliceProjection)
        )
        #if DEBUG
            snapshotFiles = snapshot.count
        #endif

        if snapshot != selectionSlicesByFileID {
            selectionSlicesByFileID = snapshot
        }
    }

    private nonisolated func workspaceFileRecordForSliceProjection(_ file: FileViewModel) -> WorkspaceFileRecord {
        WorkspaceFileRecord(
            id: file.id,
            rootID: file.rootIdentifier,
            name: file.name,
            relativePath: file.relativePath,
            fullPath: file.fullPath,
            parentFolderID: file.parentFolder?.id,
            modificationDate: file.modificationDate
        )
    }

    func initCodeScanState(_ isEnabled: Bool) {
        codeScanEnabled = isEnabled
    }

    @MainActor
    func beginDeferringInitialRootLoadScans() {
        clearDeferredInitialRootLoadScanState(keepingActiveDeferral: false)
        isInitialRootLoadScanDeferralActive = true
    }

    @MainActor
    func discardDeferredInitialRootLoadScans() {
        clearDeferredInitialRootLoadScanState(keepingActiveDeferral: false)
    }

    @MainActor
    func flushDeferredInitialRootLoadScans() {
        guard isInitialRootLoadScanDeferralActive else {
            clearDeferredInitialRootLoadScanState(keepingActiveDeferral: false)
            return
        }

        isInitialRootLoadScanDeferralActive = false
        let rootPaths = deferredInitialRootLoadScanRoots
        deferredInitialRootLoadScanRoots.removeAll()
        deferredInitialRootLoadScanFlushTask?.cancel()
        deferredInitialRootLoadScanFlushTask = nil
        deferredInitialRootLoadScanFlushTaskID = nil

        guard codeScanEnabled, !rootPaths.isEmpty else { return }
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "codemap.deferredInitialScanFlush.begin",
                fields: [
                    "workspaceID": WorkspaceRestorePerfLog.shortID(currentWorkspaceID),
                    "rootPathCount": "\(rootPaths.count)"
                ]
            )
        #endif

        let taskID = UUID()
        deferredInitialRootLoadScanFlushTaskID = taskID
        deferredInitialRootLoadScanFlushTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.deferredInitialRootLoadScanFlushTaskID == taskID {
                    self.deferredInitialRootLoadScanFlushTask = nil
                    self.deferredInitialRootLoadScanFlushTaskID = nil
                }
            }

            guard codeScanEnabled else { return }
            #if DEBUG
                let flushTotalStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
                let rootRecordsStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            #endif
            let rootRecords = await workspaceFileContextStore.rootRecords(
                forRootFolderPaths: rootPaths.sorted(),
                includeSystemRoots: false
            )
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "codemap.deferredInitialScanFlush.rootRecords",
                    fields: [
                        "workspaceID": WorkspaceRestorePerfLog.shortID(currentWorkspaceID),
                        "rootPathCount": "\(rootPaths.count)",
                        "rootRecordCount": "\(rootRecords.count)",
                        "duration": rootRecordsStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            guard !Task.isCancelled, codeScanEnabled, !rootRecords.isEmpty else {
                #if DEBUG
                    WorkspaceRestorePerfLog.event(
                        "codemap.deferredInitialScanFlush.end",
                        fields: [
                            "workspaceID": WorkspaceRestorePerfLog.shortID(currentWorkspaceID),
                            "rootPathCount": "\(rootPaths.count)",
                            "rootRecordCount": "\(rootRecords.count)",
                            "outcome": Task.isCancelled ? "cancelled" : "skipped",
                            "duration": flushTotalStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                        ]
                    )
                #endif
                return
            }
            enqueueInitialRootLoadRequests(
                rootRecords: rootRecords,
                purgeCachesOnEmptyInitialRequests: true
            )
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "codemap.deferredInitialScanFlush.end",
                    fields: [
                        "workspaceID": WorkspaceRestorePerfLog.shortID(currentWorkspaceID),
                        "rootPathCount": "\(rootPaths.count)",
                        "rootRecordCount": "\(rootRecords.count)",
                        "outcome": "enqueued",
                        "duration": flushTotalStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
        }
    }

    @MainActor
    private func clearDeferredInitialRootLoadScanState(keepingActiveDeferral: Bool) {
        deferredInitialRootLoadScanFlushTask?.cancel()
        deferredInitialRootLoadScanFlushTask = nil
        deferredInitialRootLoadScanFlushTaskID = nil
        deferredInitialRootLoadScanRoots.removeAll()
        if !keepingActiveDeferral {
            isInitialRootLoadScanDeferralActive = false
        }
    }

    @MainActor
    private func removeDeferredInitialRootLoadScanRoot(_ rootPath: String) {
        let standardizedRootPath = (rootPath as NSString).standardizingPath
        deferredInitialRootLoadScanRoots.remove(standardizedRootPath)
    }

    @MainActor
    private func loadedUserRootFolder(for rootPath: String) -> FolderViewModel? {
        let standardizedRootPath = (rootPath as NSString).standardizingPath
        guard rootShellLoadedPaths.contains(standardizedRootPath) else { return nil }
        return rootFolders.first {
            !$0.isSystemRoot && $0.standardizedFullPath == standardizedRootPath
        }
    }

    @MainActor
    private func enqueueOrDeferInitialRootLoadScan(for rootFolder: FolderViewModel) {
        #if DEBUG
            let enqueueScanStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        let rootPath = rootFolder.standardizedFullPath
        guard !rootFolder.isSystemRoot else {
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "folderLoad.enqueueScan",
                    fields: [
                        "workspaceID": WorkspaceRestorePerfLog.shortID(currentWorkspaceID),
                        "rootName": rootFolder.name,
                        "outcome": "skipped",
                        "duration": enqueueScanStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            return
        }
        if isInitialRootLoadScanDeferralActive {
            deferredInitialRootLoadScanRoots.insert(rootPath)
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "folderLoad.enqueueScan",
                    fields: [
                        "workspaceID": WorkspaceRestorePerfLog.shortID(currentWorkspaceID),
                        "rootName": rootFolder.name,
                        "outcome": "deferred",
                        "duration": enqueueScanStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            return
        }
        let filesToScan = getFilesRecursively(under: rootFolder)
        requestScans(
            forFiles: filesToScan,
            isInitialRootLoad: true,
            rootFolderPaths: [rootPath]
        )
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "folderLoad.enqueueScan",
                fields: [
                    "workspaceID": WorkspaceRestorePerfLog.shortID(currentWorkspaceID),
                    "rootName": rootFolder.name,
                    "outcome": "enqueued",
                    "files": "\(filesToScan.count)",
                    "duration": enqueueScanStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
    }

    // New: Request scans for a set of files in bulk with minimal MainActor work
    @MainActor
    private func requestScans(
        forFiles files: [FileViewModel],
        isInitialRootLoad: Bool = false,
        rootFolderPaths: [String] = []
    ) {
        guard codeScanEnabled else { return }

        let rootPaths = Set(
            files.map(\.standardizedRootFolderPath) +
                rootFolderPaths.map { ($0 as NSString).standardizingPath }
        )
        // Filter supported files up-front
        let supported = files.compactMap { f -> FileViewModel? in
            guard let ext = f.fileExtension, SyntaxManager.isSupportedFileExtension(ext) else { return nil }
            return f
        }
        guard !supported.isEmpty else {
            guard isInitialRootLoad, !rootPaths.isEmpty else { return }
            enqueueInitialRootLoadRequests(
                rootPaths: rootPaths,
                purgeCachesOnEmptyInitialRequests: true
            )
            return
        }

        if isInitialRootLoad {
            enqueueInitialRootLoadRequests(rootPaths: rootPaths)
            return
        }

        // Cancel any previous enqueue task so only one builder runs at a time
        let fileIDs = supported.map(\.id)
        currentAdhocScanEnqueueTask?.cancel()
        currentAdhocScanEnqueueTask = Task { [weak self] in
            guard let self else { return }
            for fileID in fileIDs {
                guard !Task.isCancelled else { return }
                do {
                    try await workspaceFileContextStore.requestCodemapScan(fileID: fileID)
                } catch {
                    continue
                }
            }
        }
    }

    @MainActor
    private func enqueueReplayScanRequests(forFiles files: [FileViewModel]) {
        guard codeScanEnabled else { return }
        let supported = files.compactMap { file -> FileViewModel? in
            guard let ext = file.fileExtension, SyntaxManager.isSupportedFileExtension(ext) else { return nil }
            return file
        }
        guard !supported.isEmpty else { return }
        let fileIDs = supported.map(\.id)
        let taskID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor [weak self] in
                    self?.replayScanEnqueueTasks[taskID] = nil
                }
            }
            for fileID in fileIDs {
                guard !Task.isCancelled else { return }
                do {
                    try await workspaceFileContextStore.requestCodemapScan(fileID: fileID)
                } catch {
                    continue
                }
            }
        }
        replayScanEnqueueTasks[taskID] = task
    }

    @MainActor
    private func enqueueInitialRootLoadRequests(
        rootPaths: Set<String>,
        purgeCachesOnEmptyInitialRequests: Bool = false
    ) {
        enqueueInitialRootLoadRequests(
            rootPaths: rootPaths,
            rootIDs: nil,
            purgeCachesOnEmptyInitialRequests: purgeCachesOnEmptyInitialRequests
        )
    }

    @MainActor
    private func enqueueInitialRootLoadRequests(
        rootRecords: [WorkspaceRootRecord],
        purgeCachesOnEmptyInitialRequests: Bool = false
    ) {
        let currentRootRecords = rootRecords.filter { record in
            workspaceFileContextRootsByRootKey[record.standardizedFullPath]?.id == record.id
        }
        let rootPaths = Set(currentRootRecords.map(\.standardizedFullPath))
        let rootIDs = currentRootRecords.map(\.id)
        enqueueInitialRootLoadRequests(
            rootPaths: rootPaths,
            rootIDs: rootIDs,
            purgeCachesOnEmptyInitialRequests: purgeCachesOnEmptyInitialRequests
        )
    }

    @MainActor
    private func enqueueInitialRootLoadRequests(
        rootPaths: Set<String>,
        rootIDs: [UUID]?,
        purgeCachesOnEmptyInitialRequests: Bool
    ) {
        guard !rootPaths.isEmpty else { return }

        for root in rootPaths {
            if let existing = initialRootScanEnqueueTasks[root] {
                existing.task.cancel()
                initialRootScanEnqueueTasks[root] = nil
            }
        }

        let taskID = UUID()
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            func clearInitialRootTasksIfCurrent() async {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    for root in rootPaths {
                        if initialRootScanEnqueueTasks[root]?.id == taskID {
                            initialRootScanEnqueueTasks[root] = nil
                        }
                    }
                }
            }

            do {
                if let rootIDs {
                    try await workspaceFileContextStore.requestInitialRootCodemapScans(
                        rootIDs: rootIDs,
                        purgeCachesOnEmptyInitialRequests: purgeCachesOnEmptyInitialRequests
                    )
                } else {
                    try await workspaceFileContextStore.requestInitialRootCodemapScans(
                        rootFolderPaths: Array(rootPaths),
                        purgeCachesOnEmptyInitialRequests: purgeCachesOnEmptyInitialRequests
                    )
                }
            } catch {
                // Root unloads or file read failures during initial load are non-fatal; future
                // scans and store updates will reconcile codemap state.
            }

            await clearInitialRootTasksIfCurrent()
        }

        let entry = InitialRootEnqueueTask(id: taskID, task: task)
        for root in rootPaths {
            initialRootScanEnqueueTasks[root] = entry
        }
    }

    private func requestCodeScan(for fileVM: FileViewModel) {
        guard codeScanEnabled else { return }
        guard let fileExt = fileVM.fileExtension,
              SyntaxManager.isSupportedFileExtension(fileExt) else { return }

        let id = fileVM.id
        let scanTask = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor [weak self] in
                    self?.clearCodeScanTask(id: id)
                }
            }
            guard !Task.isCancelled else { return }
            do {
                try await workspaceFileContextStore.requestCodemapScan(fileID: id)
            } catch {
                return
            }
        }

        codeScanTasks[id] = scanTask
    }

    @MainActor
    private func clearCodeScanTask(id: UUID) {
        codeScanTasks[id] = nil
    }

    /// Force a codemap scan across all loaded roots through the store-owned scanner.
    func rescanAllFilesIfLoaded() async {
        guard codeScanEnabled else { return }
        currentBatchScanTask?.cancel()
        currentBatchScanTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await workspaceFileContextStore.requestCodemapScansForAllRoots()
            } catch {
                return
            }
        }
    }

    @MainActor
    func cancelCodeMapScans() async {
        await cancelAllScans()
    }

    /// Cancel all scanning tasks
    func cancelAllScans() async {
        clearDeferredInitialRootLoadScanState(keepingActiveDeferral: isInitialRootLoadScanDeferralActive)
        // Cancel the batch scan task if one exists
        currentBatchScanTask?.cancel()
        currentBatchScanTask = nil

        // Cancel any individual file scan tasks
        for task in codeScanTasks.values {
            task.cancel()
        }
        codeScanTasks.removeAll()

        // NEW: Cancel the ad-hoc enqueue task if present
        currentAdhocScanEnqueueTask?.cancel()
        currentAdhocScanEnqueueTask = nil
        for task in replayScanEnqueueTasks.values {
            task.cancel()
        }
        replayScanEnqueueTasks.removeAll()

        for entry in initialRootScanEnqueueTasks.values {
            entry.task.cancel()
        }
        initialRootScanEnqueueTasks.removeAll()

        await workspaceFileContextStore.cancelAllCodemapScans()
        remainingScanCount = 0
        totalFilesSeen = 0
    }

    /// Clear all code map caches and triggers a rescan
    @MainActor
    func clearCodeMapCaches() async {
        // Cancel any ongoing scans first
        await cancelAllScans()

        // Get all root folder paths
        let rootPaths = rootFolders.map(\.fullPath)

        await workspaceFileContextStore.clearAllCodemapCaches(rootFolders: rootPaths)

        // Clear the in-memory file APIs and reset scan state
        for file in getAllFileViewModels() {
            file.setCodeMap(nil)
        }

        // Reset scan tracking variables
        remainingScanCount = 0
        totalFilesSeen = 0

        // Notify that code map needs update
        codeMapUpdatePublisher.send()

        // Add a small delay to ensure state is properly reset
        // try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        // Force a rescan by calling rescanAllFilesIfLoaded
        // This will re-trigger scans for all files if code scanning is enabled
        await rescanAllFilesIfLoaded()
    }

    @MainActor
    func purgeStaleCodeMapCaches(keepingRoots roots: [String]) async {
        let normalized = Set(roots.map { ($0 as NSString).standardizingPath })
        await workspaceFileContextStore.purgeStaleCodemapCaches(keepingRootPaths: Array(normalized))
    }

    func searchFiles(
        pattern: String,
        isRegex: Bool = false,
        caseInsensitive: Bool = false
    ) async throws -> [SearchMatch] {
        try await fileSearchActor.search(
            pattern: pattern,
            isRegex: isRegex,
            options: SearchOptions(caseInsensitive: caseInsensitive),
            in: getAllFileViewModels()
        )
    }

    // MARK: – Unified search facade –––––––––––––––––––––––––––––––––––––

    private static func searchAutoCorrectionWarning(isRegex: Bool) -> String {
        if isRegex {
            return "The content-search pattern was auto-corrected before running. Results may reflect a repaired or escaped version of the requested regex rather than the exact pattern you entered."
        }
        return "The content-search pattern was auto-corrected before running. Results may reflect a de-escaped literal interpretation of the text you entered."
    }

    private func pathSearchAliasByRootPath(for rootScope: LookupRootScope) -> [String: String]? {
        let scopedRootPaths = Set(roots(in: rootScope).map(\.standardizedFullPath))
        let visibleRoots = visibleWorkspaceRoots().filter { scopedRootPaths.contains($0.standardizedFullPath) }
        guard visibleRoots.count > 1 else { return nil }

        let nameCounts = Dictionary(grouping: visibleRoots, by: { $0.name.lowercased() })
        var aliasByRootPath: [String: String] = [:]
        for root in visibleRoots {
            guard !root.name.isEmpty,
                  nameCounts[root.name.lowercased()]?.count == 1 else { continue }
            aliasByRootPath[root.standardizedFullPath] = root.name
        }
        return aliasByRootPath.isEmpty ? nil : aliasByRootPath
    }

    func search(
        pattern: String,
        mode: SearchMode = .auto,
        isRegex: Bool = false,
        caseInsensitive: Bool = false,
        maxPaths: Int = 100,
        maxMatches: Int = 250,
        paths: [String]? = nil,
        includeExtensions: [String] = [],
        excludePatterns: [String] = [],
        contextLines: Int = 0,
        wholeWord: Bool = false,
        countOnly: Bool = false,
        fuzzySpaceMatching: Bool = true,
        allowLiteralUnescapeFallback: Bool = true,
        rootScope: LookupRootScope = .allLoaded
    ) async throws -> SearchResults {
        if rootFolders.isEmpty {
            let msg = "No workspace is currently loaded in this window. Use the 'manage_workspaces' tool with action: 'list' to see available workspaces, then action: 'switch' to load one."
            throw FileManagerError.fileSystemServiceNotFoundWithContext(msg)
        }

        return try await StoreBackedWorkspaceSearch.search(
            pattern: pattern,
            mode: mode,
            isRegex: isRegex,
            caseInsensitive: caseInsensitive,
            maxPaths: maxPaths,
            maxMatches: maxMatches,
            paths: paths,
            includeExtensions: includeExtensions,
            excludePatterns: excludePatterns,
            contextLines: contextLines,
            wholeWord: wholeWord,
            countOnly: countOnly,
            fuzzySpaceMatching: fuzzySpaceMatching,
            allowLiteralUnescapeFallback: allowLiteralUnescapeFallback,
            rootScope: rootScope,
            store: workspaceFileContextStore,
            workspaceManager: workspaceManager
        )
    }
}

// MARK: - Path utilities (new helper)

extension WorkspaceFilesViewModel {
    struct SearchScopeParseResult {
        let spec: SearchPathFilterSpec
        let issues: [PathResolutionIssue]
    }

    func canonicalURL(for path: String, assumingDirectory: Bool = false) -> URL {
        let normalized = normalizeUserInputPath(path)
        return URL(fileURLWithPath: normalized, isDirectory: assumingDirectory)
    }

    func canonicalURL(for url: URL, assumingDirectory: Bool = false) -> URL {
        canonicalURL(for: url.path, assumingDirectory: assumingDirectory)
    }

    @MainActor
    private func searchFolderSuffixIndex(
        for scope: LookupRootScope
    ) -> SearchFolderSuffixIndex<FolderViewModel> {
        let generation = currentHierarchyGenerationSignature()
        if let cached = cachedSearchFolderSuffixIndexByScope[scope], cached.generation == generation {
            return cached.index
        }
        let roots = roots(in: scope)
        let allowedRootPaths = Set(roots.map(\.standardizedFullPath))
        let folders: [String: FolderViewModel] = if scope == .allLoaded {
            fileHierarchyIndex.foldersByFullPath
        } else {
            fileHierarchyIndex.foldersByFullPath.filter {
                allowedRootPaths.contains(StandardizedPath.absolute($0.value.rootPath))
            }
        }
        let index = buildFolderSuffixIndex(
            in: folders,
            relativePath: { $0.relativePath },
            caseInsensitive: true
        )
        cachedSearchFolderSuffixIndexByScope[scope] = (generation, index)
        return index
    }

    private static let protectedLiteralTopLevelAbsoluteComponents: Set<String> = [
        "applications", "bin", "cores", "dev", "etc", "home", "library", "opt",
        "private", "sbin", "system", "tmp", "users", "usr", "var", "volumes"
    ]

    @MainActor
    private func resolveLeadingSlashRootAlias(
        from standardizedPath: String,
        requireRemainder: Bool
    ) -> RootAliasResolution? {
        guard standardizedPath.hasPrefix("/") else { return nil }
        let candidate = String(standardizedPath.dropFirst())
        guard !candidate.isEmpty else { return nil }
        let resolution = resolveVisibleRootAlias(
            candidate,
            requireRemainder: requireRemainder,
            disambiguateRealSubpath: false
        )
        switch resolution {
        case .bareRoot, .prefixed, .ambiguous:
            return resolution
        case .notAliasPrefixed:
            if let firstComponent = candidate.split(separator: "/").first,
               !firstComponent.isEmpty,
               Self.protectedLiteralTopLevelAbsoluteComponents.contains(firstComponent.lowercased())
            {
                return nil
            }
            return nil
        }
    }

    @MainActor
    private func unmatchedAbsolutePathIssue(
        for standardizedAbsolutePath: String,
        rawInput: String
    ) -> PathResolutionIssue {
        let roots = visibleWorkspaceRoots()

        let isInsideLoadedRoot = roots.contains { root in
            let rootPath = root.standardizedFullPath
            return standardizedAbsolutePath == rootPath
                || standardizedAbsolutePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
        }

        if isInsideLoadedRoot {
            return .unresolved(input: rawInput)
        }

        if let aliasResolution = resolveLeadingSlashRootAlias(from: standardizedAbsolutePath, requireRemainder: false) {
            switch aliasResolution {
            case let .ambiguous(alias, matchingRoots):
                return .ambiguousAlias(alias: alias, matchingRoots: matchingRoots)
            case .bareRoot, .prefixed:
                return .unresolved(input: rawInput)
            case .notAliasPrefixed:
                break
            }
        }

        return .pathOutsideWorkspace(input: rawInput, visibleRoots: roots)
    }

    @MainActor
    private func parseSearchScopePaths(
        _ rawPaths: [String],
        caseInsensitive: Bool,
        rootScope: LookupRootScope = .allLoaded
    ) async -> SearchScopeParseResult {
        let normalizedEntries = rawPaths.compactMap { raw -> (raw: String, normalized: String, hadTrailingSlash: Bool)? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return (raw, normalizeUserInputPath(trimmed), trimmed.hasSuffix("/"))
        }
        guard !normalizedEntries.isEmpty else {
            return SearchScopeParseResult(spec: SearchPathFilterSpec(caseInsensitive: caseInsensitive, clauses: []), issues: [])
        }

        var clauses: [SearchPathClause] = []
        var issues: [PathResolutionIssue] = []
        var seenClauses = Set<String>()
        let suffixIndex = searchFolderSuffixIndex(for: rootScope)

        func appendClause(_ clause: SearchPathClause) {
            let key = String(describing: clause)
            if seenClauses.insert(key).inserted {
                clauses.append(clause)
            }
        }

        for entry in normalizedEntries {
            let normalized = entry.normalized
            let isWildcard = normalized.contains("*") || normalized.contains("?") || normalized.contains("[")
            if isWildcard {
                let aliasResolution = resolveLeadingSlashRootAlias(from: normalized, requireRemainder: true)
                switch aliasResolution ?? resolveVisibleRootAlias(normalized, requireRemainder: true, disambiguateRealSubpath: false) {
                case let .prefixed(root, _, remainder):
                    appendClause(.glob(pattern: remainder, restrictedRootPath: root.standardizedFullPath))
                case let .ambiguous(alias, matchingRoots):
                    issues.append(.ambiguousAlias(alias: alias, matchingRoots: matchingRoots))
                case .notAliasPrefixed, .bareRoot:
                    appendClause(.glob(pattern: normalized, restrictedRootPath: nil))
                }
                continue
            }

            let standardized = (normalized as NSString).standardizingPath
            if !standardized.hasPrefix("/") {
                if let issue = exactPathResolutionIssue(for: entry.raw, kind: .either, rootScope: rootScope) {
                    issues.append(issue)
                    continue
                }
            }
            if standardized.hasPrefix("/") {
                if let file = findFileByFullPath(standardized) {
                    appendClause(.exactFile(absPath: file.standardizedFullPath, relPath: file.standardizedRelativePath, restrictedRootPath: file.standardizedRootFolderPath))
                    continue
                }
                if let folder = findFolderByFullPath(standardized) {
                    appendClause(.exactFolder(
                        absLower: folder.standardizedFullPath.lowercased(),
                        relLower: (folder.relativePath as NSString).standardizingPath.lowercased(),
                        restrictedRootPath: (folder.rootPath as NSString).standardizingPath
                    ))
                    continue
                }
                if let aliasResolution = resolveLeadingSlashRootAlias(from: standardized, requireRemainder: false) {
                    switch aliasResolution {
                    case let .bareRoot(root, _):
                        if let folder = rootFolders.first(where: { $0.id == root.id }) {
                            appendClause(.exactFolder(
                                absLower: folder.standardizedFullPath.lowercased(),
                                relLower: (folder.relativePath as NSString).standardizingPath.lowercased(),
                                restrictedRootPath: (folder.rootPath as NSString).standardizingPath
                            ))
                            continue
                        }
                    case let .prefixed(root, _, remainder):
                        let abs = ((root.standardizedFullPath as NSString).appendingPathComponent(remainder) as NSString).standardizingPath
                        if let file = findFileByFullPath(abs) {
                            appendClause(.exactFile(absPath: file.standardizedFullPath, relPath: file.standardizedRelativePath, restrictedRootPath: file.standardizedRootFolderPath))
                            continue
                        }
                        if let folder = findFolderByFullPath(abs) {
                            appendClause(.exactFolder(
                                absLower: folder.standardizedFullPath.lowercased(),
                                relLower: (folder.relativePath as NSString).standardizingPath.lowercased(),
                                restrictedRootPath: (folder.rootPath as NSString).standardizingPath
                            ))
                            continue
                        }
                    case let .ambiguous(alias, matchingRoots):
                        issues.append(.ambiguousAlias(alias: alias, matchingRoots: matchingRoots))
                        continue
                    case .notAliasPrefixed:
                        break
                    }
                }
                issues.append(unmatchedAbsolutePathIssue(for: standardized, rawInput: entry.raw))
                continue
            }

            if !entry.hadTrailingSlash {
                if let file = findFileByRelativePath(standardized, scope: rootScope) {
                    appendClause(.exactFile(absPath: file.standardizedFullPath, relPath: file.standardizedRelativePath, restrictedRootPath: file.standardizedRootFolderPath))
                    continue
                }
                switch resolveVisibleRootAlias(standardized, requireRemainder: true, disambiguateRealSubpath: false) {
                case let .prefixed(root, _, remainder):
                    let abs = ((root.standardizedFullPath as NSString).appendingPathComponent(remainder) as NSString).standardizingPath
                    if let file = findFileByFullPath(abs) {
                        appendClause(.exactFile(absPath: file.standardizedFullPath, relPath: file.standardizedRelativePath, restrictedRootPath: file.standardizedRootFolderPath))
                        continue
                    }
                    if let folder = findFolderByFullPath(abs) {
                        appendClause(.exactFolder(
                            absLower: folder.standardizedFullPath.lowercased(),
                            relLower: (folder.relativePath as NSString).standardizingPath.lowercased(),
                            restrictedRootPath: (folder.rootPath as NSString).standardizingPath
                        ))
                        continue
                    }
                case let .ambiguous(alias, matchingRoots):
                    issues.append(.ambiguousAlias(alias: alias, matchingRoots: matchingRoots))
                    continue
                case .notAliasPrefixed, .bareRoot:
                    break
                }
            }

            if let folder = resolveFolderInput(entry.raw, rootScope: rootScope).folder {
                appendClause(.exactFolder(
                    absLower: folder.standardizedFullPath.lowercased(),
                    relLower: (folder.relativePath as NSString).standardizingPath.lowercased(),
                    restrictedRootPath: (folder.rootPath as NSString).standardizingPath
                ))
                continue
            }

            if !standardized.hasPrefix("/") {
                let suffixMatches = resolveFoldersBySuffixFragment(standardized, using: suffixIndex, caseInsensitive: true)
                if !suffixMatches.isEmpty {
                    for folder in suffixMatches {
                        appendClause(.exactFolder(
                            absLower: folder.standardizedFullPath.lowercased(),
                            relLower: (folder.relativePath as NSString).standardizingPath.lowercased(),
                            restrictedRootPath: (folder.rootPath as NSString).standardizingPath
                        ))
                    }
                    continue
                }
            }

            if !entry.hadTrailingSlash {
                if let lookup = await workspaceFileContextStore.lookupPath(
                    WorkspacePathLookupRequest(userPath: standardized, profile: .mcpSearchScope, rootScope: rootScope)
                ) {
                    let abs = lookup.location.absolutePath
                    if let folder = findFolderByFullPath(abs) {
                        appendClause(.exactFolder(
                            absLower: folder.standardizedFullPath.lowercased(),
                            relLower: (folder.relativePath as NSString).standardizingPath.lowercased(),
                            restrictedRootPath: (folder.rootPath as NSString).standardizingPath
                        ))
                        continue
                    }
                    if let file = findFileByFullPath(abs) {
                        appendClause(.exactFile(absPath: file.standardizedFullPath, relPath: file.standardizedRelativePath, restrictedRootPath: file.standardizedRootFolderPath))
                        continue
                    }
                }
            }

            appendClause(.legacyPrefix(candidateLower: standardized.lowercased()))
        }

        return SearchScopeParseResult(
            spec: SearchPathFilterSpec(caseInsensitive: caseInsensitive, clauses: clauses),
            issues: issues
        )
    }

    func normalizeFilterPaths(_ paths: [String]) async -> [String] {
        let selectedPaths = Set(selectedFiles.map(\.fullPath))
        var normalized: [String] = []
        normalized.reserveCapacity(paths.count)

        for path in paths {
            let rawTrimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            let hadTrailingSlash = rawTrimmed.hasSuffix("/")

            let standardized = normalizeUserInputPath(path)
            if standardized.hasPrefix("/") {
                normalized.append(standardized)
                continue
            }

            if let issue = exactPathResolutionIssue(for: standardized, kind: .either) {
                switch issue {
                case .ambiguousAlias, .ambiguousRootMatch:
                    normalized.append((standardized as NSString).standardizingPath)
                    continue
                default:
                    break
                }
            }

            // Check for bare root alias (e.g., "RepoPrompt" or "RepoPrompt/")
            if let rootAbs = resolveBareVisibleRootAliasAbsolutePath(standardized) {
                normalized.append(rootAbs)
                continue
            }

            // Check for alias-prefixed path with remainder (e.g., "RepoPrompt/src")
            switch resolveVisibleAliasPrefixedAbsolutePathResolution(standardized, requireRemainder: true) {
            case let .resolved(abs):
                normalized.append(abs)
                continue
            default:
                break
            }

            // Respect explicit directory intent and avoid file-path fuzzy resolution.
            if hadTrailingSlash {
                normalized.append(standardized)
                continue
            }

            if let lookup = await workspaceFileContextStore.lookupPath(
                WorkspacePathLookupRequest(
                    userPath: standardized,
                    profile: .uiAssisted,
                    selectedFileFullPaths: selectedPaths
                )
            ) {
                normalized.append(lookup.location.absolutePath)
            } else {
                normalized.append(standardized)
            }
        }

        return normalized
    }

    /// Resolves a bare root alias (just the root name, no subpath) to its absolute path.
    /// Returns `nil` if the input is not a bare root alias or is ambiguous.
    ///
    /// Examples:
    /// - "RepoPrompt/" → "/Users/.../RepoPrompt" (trailing slash is stripped)
    /// - "RepoPrompt/src" → nil (has remainder, use resolveVisibleAliasPrefixedAbsolutePathResolution instead)
    /// - "/absolute/path" → nil (absolute paths are not aliases)
    @MainActor
    private func resolveBareVisibleRootAliasAbsolutePath(_ userPath: String) -> String? {
        let standardized = normalizeUserInputPath(userPath)

        // Absolute paths are not aliases
        guard !standardized.hasPrefix("/") else { return nil }

        // Trim leading/trailing slashes to get the bare alias
        let trimmed = standardized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return nil }

        // Must be a single component (no "/" inside) to be a bare root alias
        guard !trimmed.contains("/") else { return nil }

        // Use existing alias classification
        switch checkVisibleRootAliasPrefix(trimmed, requireRemainder: false) {
        case let .uniqueRoot(root, _):
            return root.standardizedFullPath
        default:
            return nil
        }
    }
}

@inline(__always)
private func isUnder(_ path: String, root: String) -> Bool {
    path.isDescendant(of: root)
}

private func relativePath(from userPath: String, rootPath: String) throws -> String {
    let standard = (userPath as NSString).standardizingPath
    if standard.hasPrefix("/") {
        // absolute – must lie under the same root
        guard standard.hasPrefix(rootPath) else {
            throw FileSystemError.invalidRelativePath
        }
        return String(
            standard.dropFirst(rootPath.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        )
    }
    return standard
}

private extension String {
    /// `true` if the receiver is *equal* to `parent` **or** lies *inside* it.
    /// Standardizes once at the boundary, then uses cheap string prefix checks.
    func isDescendant(of parent: String) -> Bool {
        StandardizedPath.isDescendant(
            StandardizedPath.absolute(self),
            of: StandardizedPath.absolute(parent)
        )
    }
}

// MARK: - Batch selection helpers

extension WorkspaceFilesViewModel {
    /// Atomically commit selection state changes to both selectedFiles and selectedFileIDs.
    /// Ensures both collections stay in sync with one assignment point.
    @MainActor
    private func commitSelectionState(_ newFiles: [FileViewModel], _ newIDs: Set<UUID>) {
        // Fast-exit if nothing changes (preserves @Published churn)
        let idsUnchanged = (newIDs == selectedFileIDs)
        let filesUnchanged: Bool = {
            if newFiles.count != selectedFiles.count { return false }
            // Compare by stable identity (UUID)
            let lhs = newFiles.map(\.id)
            let rhs = selectedFiles.map(\.id)
            return lhs == rhs
        }()
        if idsUnchanged, filesUnchanged {
            return
        }

        #if DEBUG
            assert(Set(newFiles.map(\.id)) == newIDs, "Selection state mismatch: files vs. IDs")
        #endif

        selectedFileIDs = newIDs
        selectedFiles = newFiles
        requestSelectionSliceSnapshotRebuild(reason: "commitSelectionState")

        // Only clear auto-codemap files automatically when auto mode is ON.
        // In manual mode, keep codemap files even if selection becomes empty.
        if newFiles.isEmpty {
            if codemapAutoEnabled {
                resetAutoCodemapFiles([])
            }
            // Do not flip codemapAutoEnabled here; explicit flows (clearSelection, tools) decide that.
        }

        // Only run auto-codemap sync when in auto mode and there are selected files to infer from.
        if codemapAutoEnabled, !selectedFiles.isEmpty {
            scheduleAutoCodemapSync()
        }
    }

    /// Clear both selected files and IDs in one atomic operation.
    @MainActor
    private func resetSelection() {
        commitSelectionState([], [])
    }

    /// Remove a single file from selection state if present. Returns true if a change occurred.
    @MainActor
    @discardableResult
    private func removeSelectedFileIfPresent(_ file: FileViewModel) -> Bool {
        var newIDs = selectedFileIDs
        let removed = (newIDs.remove(file.id) != nil)
        if removed {
            var newFiles = selectedFiles
            newFiles.removeAll { $0.id == file.id }
            commitSelectionState(newFiles, newIDs)
        }
        return removed
    }

    /// Remove a set of selected IDs along with their corresponding files. Returns true if any change occurred.
    @MainActor
    @discardableResult
    private func removeSelectedIDs(_ idsToRemove: Set<UUID>) -> Bool {
        guard !idsToRemove.isEmpty else { return false }
        let intersection = selectedFileIDs.intersection(idsToRemove)
        guard !intersection.isEmpty else { return false }
        let newIDs = selectedFileIDs.subtracting(idsToRemove)
        let newFiles = selectedFiles.filter { !idsToRemove.contains($0.id) }
        commitSelectionState(newFiles, newIDs)
        return true
    }

    /// Rebuild the ID set from the current selectedFiles array to guarantee consistency.
    @MainActor
    private func normalizeSelectionState() {
        let recomputed = Set(selectedFiles.map(\.id))
        commitSelectionState(selectedFiles, recomputed)
    }

    /// Centralised callback used by every FileViewModel.
    @MainActor
    private func handleCheckStateChanged(
        _ file: FileViewModel,
        isChecked: Bool
    ) {
        if isSelectionBatching {
            if isChecked {
                pendingSelectionAdds.append(file)
            } else {
                pendingSelectionRemoves.append(file)
            }
            return
        }
        updateSelection(for: file, isChecked: isChecked)
    }

    /// O(1) selection update – never touches UI except the single publisher.
    @MainActor
    private func updateSelection(
        for file: FileViewModel,
        isChecked: Bool
    ) {
        var newIDs = selectedFileIDs
        var newFiles = selectedFiles

        if isChecked {
            if newIDs.insert(file.id).inserted {
                newFiles.append(file)
            }
        } else {
            if newIDs.remove(file.id) != nil {
                newFiles.removeAll { $0.id == file.id }
            }
        }

        commitSelectionState(newFiles, newIDs)
        fileTogglePublisher.send(file)
    }

    /// Execute `work` while coalescing per-file callbacks into a single flush.
    @MainActor
    func performSelectionBatch(_ work: () -> Void) {
        guard !isSelectionBatching else { work()
            return
        }
        isSelectionBatching = true
        work()
        isSelectionBatching = false
        flushPendingSelectionChanges()
    }

    @MainActor
    private func flushPendingSelectionChanges() {
        // Fast-exit ─ nothing queued
        if pendingSelectionAdds.isEmpty, pendingSelectionRemoves.isEmpty { return }

        // Start from the current snapshot
        var newArray = selectedFiles
        var newIDSet = selectedFileIDs

        // ➊ Removals ---------------------------------------------------------
        if !pendingSelectionRemoves.isEmpty {
            let removeIDs = Set(pendingSelectionRemoves.map(\.id))
            newArray.removeAll { removeIDs.contains($0.id) }
            newIDSet.subtract(removeIDs)

            // Notify listeners once per removed file (keeps UI in sync)
            for file in pendingSelectionRemoves {
                fileTogglePublisher.send(file)
            }
            pendingSelectionRemoves.removeAll()
        }

        // ➋ Additions --------------------------------------------------------
        if !pendingSelectionAdds.isEmpty {
            let toAppend = pendingSelectionAdds.filter { newIDSet.insert($0.id).inserted }
            newArray.append(contentsOf: toAppend)

            for file in toAppend {
                fileTogglePublisher.send(file)
            }
            pendingSelectionAdds.removeAll()
        }

        // ➌ Deduplicate (safety) then commit – single @Published write
        let unique: [FileViewModel]
        if newArray.count == newIDSet.count {
            unique = newArray
        } else {
            var seen = Set<UUID>()
            unique = newArray.filter { seen.insert($0.id).inserted }
        }

        // Atomic commit
        commitSelectionState(unique, newIDSet)
    }

    /// Installs the lightweight callback on a freshly created FileViewModel.
    /// The closure fires on the MainActor already (setIsChecked is @MainActor),
    /// so we call the helper directly—no extra Task hop that would escape the
    /// current selection batch.
    @MainActor
    private func attachSelectionCallback(to file: FileViewModel) {
        file.onCheckStateChanged = { [weak self] changed, isChecked in
            self?.handleCheckStateChanged(changed, isChecked: isChecked)
        }
    }

    // MARK: - Auto Codemap Support

    @MainActor
    private func resetAutoCodemapFiles(_ files: [FileViewModel]) {
        autoCodemapFiles = files
        autoCodemapFileIDs = Set(files.map(\.id))
        // Notify that codemap files changed so token counts can update
        codeMapUpdatePublisher.send(())
    }

    @MainActor
    func clearAutoCodemapFiles(disableAuto: Bool = true) {
        guard !autoCodemapFiles.isEmpty else { return }
        if disableAuto, codemapAutoEnabled {
            codemapAutoEnabled = false
        }
        resetAutoCodemapFiles([])
    }

    @MainActor
    func flushAutoCodemapSyncNowIfNeeded() async {
        // Cancel any pending debounced task
        autoCodemapSyncTask?.cancel()
        autoCodemapSyncTask = nil
        // Only sync when auto mode is enabled
        if codemapAutoEnabled {
            // Recompute the auto-codemap set immediately from the store codemap mirror.
            let allFileAPIs = await workspaceFileContextStore.allCodemapFileAPIs()
            syncAutoCodemaps(allFileAPIs: allFileAPIs)
        }
    }

    @MainActor
    private func addAutoCodemapFile(_ file: FileViewModel) {
        if autoCodemapFileIDs.insert(file.id).inserted {
            autoCodemapFiles.append(file)
            // Notify that codemap files changed so token counts can update
            codeMapUpdatePublisher.send(())
        }
    }

    @MainActor
    private func removeAutoCodemapFile(_ file: FileViewModel) {
        if autoCodemapFileIDs.remove(file.id) != nil {
            autoCodemapFiles.removeAll { $0.id == file.id }
            // Notify that codemap files changed so token counts can update
            codeMapUpdatePublisher.send(())
        }
    }

    @MainActor
    func isAutoCodemapFile(_ file: FileViewModel) -> Bool {
        autoCodemapFileIDs.contains(file.id)
    }

    @MainActor
    func enterManualCodemapMode() {
        if codemapAutoEnabled {
            // Preserve the current auto-codemap set; just stop auto-syncing.
            codemapAutoEnabled = false
            autoCodemapSyncTask?.cancel()
            autoCodemapSyncTask = nil
        } else {
            autoCodemapSyncTask?.cancel()
            autoCodemapSyncTask = nil
        }
    }

    @MainActor
    func validatedFileAPI(for file: FileViewModel) -> FileAPI? {
        guard file.hasAcceptedCodeMap, let api = file.fileAPI else { return nil }
        return api
    }

    @MainActor
    func validatedCurrentFileAPIs(from apis: [FileAPI]) -> [FileAPI] {
        guard !apis.isEmpty else { return [] }

        var seen = Set<String>()
        var validated: [FileAPI] = []
        validated.reserveCapacity(apis.count)

        for api in apis {
            let standardized = standardizedAPIFilePath(api)
            guard seen.insert(standardized).inserted,
                  let file = findFileByFullPath(standardized),
                  let attachedAPI = validatedFileAPI(for: file),
                  standardizedAPIFilePath(attachedAPI) == standardized
            else { continue }

            validated.append(attachedAPI)
        }

        return validated
    }

    @MainActor
    private func scheduleAutoCodemapSync() {
        guard codemapAutoEnabled else { return }
        autoCodemapSyncTask?.cancel()
        autoCodemapSyncTask = Task(priority: .utility) { [weak self] in
            // Debounce to coalesce rapid selection churn without blocking the main actor
            try? await Task.sleep(nanoseconds: 400_000_000) // 400ms debounce
            guard let self else { return }
            defer { self.autoCodemapSyncTask = nil }
            guard !Task.isCancelled else { return }
            guard codemapAutoEnabled else { return }
            let allFileAPIs = await workspaceFileContextStore.allCodemapFileAPIs()
            guard !Task.isCancelled else { return }
            syncAutoCodemaps(allFileAPIs: allFileAPIs)
        }
    }

    @MainActor
    private func syncAutoCodemaps(allFileAPIs: [FileAPI]) {
        guard codemapAutoEnabled else {
            resetAutoCodemapFiles([])
            return
        }

        guard true else {
            resetAutoCodemapFiles([])
            return
        }

        let selectedFilesSnapshot = selectedFiles
        guard !selectedFilesSnapshot.isEmpty else {
            resetAutoCodemapFiles([])
            return
        }

        let selectedPaths = Set(selectedFilesSnapshot.map(\.standardizedFullPath))
        guard !allFileAPIs.isEmpty else {
            resetAutoCodemapFiles([])
            return
        }

        let referencedPaths = CodeMapExtractor.resolveReferencedFilePaths(
            from: selectedFilesSnapshot,
            among: allFileAPIs
        )

        if referencedPaths.isEmpty {
            resetAutoCodemapFiles([])
            return
        }

        var unique = Set<UUID>()
        let resolved = referencedPaths.compactMap { standardizedPath -> FileViewModel? in
            guard !selectedPaths.contains(standardizedPath),
                  let vm = fileHierarchyIndex.filesByFullPath[standardizedPath],
                  unique.insert(vm.id).inserted
            else { return nil }
            return vm
        }

        resetAutoCodemapFiles(resolved)
    }

    /// UI/test compatibility snapshot of the current checkbox/slice/codemap mirror.
    /// Runtime consumers should read compose-tab `StoredSelection` through
    /// `WorkspaceSelectionCoordinator`, which flushes this pending UI mirror first.
    @MainActor
    func snapshotSelection() -> StoredSelection {
        let selectedPaths = selectedFiles.map(\.standardizedFullPath)
        let autoPaths = autoCodemapFiles.map(\.standardizedFullPath)
        var slicesByPath: [String: [LineRange]] = [:]
        for file in selectedFiles {
            if let ranges = selectionSlicesByFileID[file.id], !ranges.isEmpty {
                slicesByPath[file.standardizedFullPath] = ranges
            }
        }
        return StoredSelection(
            selectedPaths: selectedPaths,
            autoCodemapPaths: autoPaths,
            slices: slicesByPath,
            codemapAutoEnabled: codemapAutoEnabled
        )
    }

    @MainActor
    private func applySelectionSnapshot(paths: [String], allowEmpty: Bool) async {
        if paths.isEmpty && !allowEmpty { return }
        let foundFiles = await findFiles(atPaths: paths)
        let targetFiles = Array(foundFiles.values)
        let targetIDs = Set(targetFiles.map(\.id))
        let currentIDs = selectedFileIDs
        let idsToDeselect = currentIDs.subtracting(targetIDs)
        let idsToSelect = targetIDs.subtracting(currentIDs)
        guard !idsToDeselect.isEmpty || !idsToSelect.isEmpty else { return }

        let filesToDeselect = selectedFiles.filter { idsToDeselect.contains($0.id) }
        let filesToSelect = targetFiles.filter { idsToSelect.contains($0.id) }

        await applySelectionDelta(filesToDeselect, selecting: false)
        await applySelectionDelta(filesToSelect, selecting: true)
        guard !Task.isCancelled else { return }

        var parentIDs = Set<UUID>()
        var parents: [FolderViewModel] = []
        for file in filesToDeselect {
            if let parent = file.parentFolder, parentIDs.insert(parent.id).inserted {
                parents.append(parent)
            }
        }
        for file in filesToSelect {
            if let parent = file.parentFolder, parentIDs.insert(parent.id).inserted {
                parents.append(parent)
            }
        }

        guard !parents.isEmpty else { return }
        let chunkSize = 500
        var index = 0
        while index < parents.count {
            guard !Task.isCancelled else { return }
            let end = min(index + chunkSize, parents.count)
            for parent in parents[index ..< end] {
                recomputeAncestorStates(startingAt: parent)
            }
            index = end
            await Task.yield()
        }
    }

    @MainActor
    private func applySelectionDelta(_ files: [FileViewModel], selecting: Bool) async {
        guard !files.isEmpty else { return }
        let chunkSize = 500
        var index = 0
        while index < files.count {
            guard !Task.isCancelled else { return }
            let end = min(index + chunkSize, files.count)
            let chunk = files[index ..< end]
            performSelectionBatch {
                for file in chunk {
                    if selecting {
                        if !file.isChecked {
                            file.setIsChecked(true)
                        }
                    } else if file.isChecked {
                        file.setIsChecked(false)
                    }
                }
            }
            index = end
            await Task.yield()
        }
    }

    @MainActor
    func applyStoredSelection(_ stored: StoredSelection) async {
        #if DEBUG
            let applyStoredSelectionStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            var applySelectionSnapshotDuration = "notMeasured"
        #endif
        autoCodemapSyncTask?.cancel()
        codemapAutoEnabled = false

        #if DEBUG
            let applySelectionSnapshotStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        await applySelectionSnapshot(paths: stored.selectedPaths, allowEmpty: true)
        #if DEBUG
            applySelectionSnapshotDuration = applySelectionSnapshotStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
            WorkspaceRestorePerfLog.event(
                "selection.applyStoredSelection.selectionSnapshot",
                fields: [
                    "selectedPaths": "\(stored.selectedPaths.count)",
                    "duration": applySelectionSnapshotDuration
                ]
            )
        #endif

        let autoCodemapPaths = standardizedStoredSelectionPaths(stored.autoCodemapPaths)
        let restoredAutoCodemapLookup = await findFiles(atPaths: autoCodemapPaths, profile: .mcpSelection)
        let restoredAutoCodemapFiles = autoCodemapPaths.compactMap { path in
            restoredAutoCodemapLookup[path] ?? fileHierarchyIndex.filesByFullPath[path]
        }
        resetAutoCodemapFiles(restoredAutoCodemapFiles)

        let storedSlicePaths = Array(standardizedStoredSelectionSlices(stored.slices).keys)
        if !storedSlicePaths.isEmpty {
            _ = await findFiles(atPaths: storedSlicePaths, profile: .mcpSelection)
        }
        replaceInMemorySliceMirror(from: stored)

        codemapAutoEnabled = stored.codemapAutoEnabled
        if codemapAutoEnabled {
            scheduleAutoCodemapSync()
        }
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "selection.applyStoredSelection",
                fields: [
                    "selectedPaths": "\(stored.selectedPaths.count)",
                    "autoCodemapPaths": "\(stored.autoCodemapPaths.count)",
                    "sliceFiles": "\(stored.slices.count)",
                    "restoredAutoCodemapFiles": "\(restoredAutoCodemapFiles.count)",
                    "codemapAutoEnabled": "\(stored.codemapAutoEnabled)",
                    "selectionSnapshotDuration": applySelectionSnapshotDuration,
                    "duration": applyStoredSelectionStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
    }

    @MainActor
    func computeSelectedIDs(from stored: StoredSelection) -> Set<UUID> {
        var ids = Set<UUID>()
        for rawPath in stored.selectedPaths {
            let standardized = standardizedStoredSelectionPath(rawPath)
            if let file = fileHierarchyIndex.filesByFullPath[standardized] {
                ids.insert(file.id)
            }
        }
        return ids
    }

    @MainActor
    func setFileAsFullContent(_ file: FileViewModel) {
        // If switching from codemap to full content, disable auto mode
        if isAutoCodemapFile(file) {
            codemapAutoEnabled = false
        }

        performSelectionBatch {
            if !file.isChecked {
                file.setIsChecked(true)
            }
        }

        selectionSlicesByFileID.removeValue(forKey: file.id)
        removeAutoCodemapFile(file)
        requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")
    }

    @MainActor
    func setFileAsCodemap(_ file: FileViewModel) {
        guard true else { return }
        // Only allow files with codemap support to be added as codemaps
        guard file.supportsCodeMap else { return }

        performSelectionBatch {
            if file.isChecked {
                file.setIsChecked(false)
            }
        }

        selectionSlicesByFileID.removeValue(forKey: file.id)
        let wasAlreadyCodemap = isAutoCodemapFile(file)
        if !wasAlreadyCodemap {
            addAutoCodemapFile(file)
        }
        codemapAutoEnabled = false
        requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")
    }

    @MainActor
    func removeCodemapFile(_ file: FileViewModel) {
        removeAutoCodemapFile(file)
    }

    @MainActor
    func removeFileFromAllSelections(_ file: FileViewModel) {
        // If auto-mode is on and the user is removing an auto-added file,
        // interpret this as a switch to manual mode.
        if codemapAutoEnabled, isAutoCodemapFile(file) {
            codemapAutoEnabled = false
        }

        performSelectionBatch {
            // Remove from selected files if present
            if file.isChecked {
                file.setIsChecked(false)
            }
            // Remove from auto-codemap files
            removeAutoCodemapFile(file)
            // Remove any slices for this file
            selectionSlicesByFileID.removeValue(forKey: file.id)
        }

        // Update parent folder states for UI consistency
        if let parent = file.parentFolder {
            recomputeAncestorStates(startingAt: parent)
        }
    }

    // MARK: - Incremental Cache Management
}

@MainActor
extension WorkspaceFilesViewModel {
    /// O(1) lookup for files based on absolute-path index
    func findFileByRelativePath(_ relativePath: String) -> FileViewModel? {
        findFileByRelativePath(relativePath, scope: .allLoaded)
    }

    func findFileByRelativePath(
        _ relativePath: String,
        scope: LookupRootScope
    ) -> FileViewModel? {
        let standardizedRel = StandardizedPath.relative(relativePath)
        for absPath in absolutePathCandidates(forRelativePath: standardizedRel, scope: scope) {
            if let vm = fileHierarchyIndex.filesByFullPath[absPath] {
                return vm
            }
        }
        return nil
    }

    /// O(1) lookup for folders based on absolute-path index
    func findFolderByRelativePath(_ relativePath: String) -> FolderViewModel? {
        findFolderByRelativePath(relativePath, scope: .allLoaded)
    }

    func findFolderByRelativePath(
        _ relativePath: String,
        scope: LookupRootScope
    ) -> FolderViewModel? {
        let standardizedRel = StandardizedPath.relative(relativePath)
        for absPath in absolutePathCandidates(forRelativePath: standardizedRel, scope: scope) {
            if let vm = fileHierarchyIndex.foldersByFullPath[absPath] {
                return vm
            }
        }
        return nil
    }

    /// Unchanged: direct full-path lookup for files
    func findFileByFullPath(_ fullPath: String) -> FileViewModel? {
        let key = StandardizedPath.absolute(fullPath)
        return fileHierarchyIndex.filesByFullPath[key]
    }

    func resolveWorkspaceFileForTaggedPath(_ rawPath: String) -> FileViewModel? {
        let normalizedPath = normalizeUserInputPath(rawPath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else { return nil }

        let standardizedPath = (normalizedPath as NSString).standardizingPath
        if standardizedPath.hasPrefix("/") {
            return findFileByFullPath(standardizedPath)
        }

        if taggedPathLooksRootQualified(standardizedPath),
           let exactUnique = findFileByUniqueRelativePath(standardizedPath)
        {
            return exactUnique
        }

        if let exactRelative = findFileByRelativePath(standardizedPath) {
            return exactRelative
        }

        return findFileByUniqueRelativePath(standardizedPath)
    }

    /// Unchanged: direct full-path lookup for folders
    func findFolderByFullPath(_ fullPath: String) -> FolderViewModel? {
        let key = StandardizedPath.absolute(fullPath)
        return fileHierarchyIndex.foldersByFullPath[key]
    }

    private func findFileByUniqueRelativePath(_ path: String) -> FileViewModel? {
        let standardizedPath = StandardizedPath.relative(path)
        let matches = fileHierarchyIndex.filesByFullPath.values.filter {
            ($0.uniqueRelativePath as NSString).standardizingPath == standardizedPath
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private func taggedPathLooksRootQualified(_ path: String) -> Bool {
        guard let firstComponent = StandardizedPath.relative(path).split(separator: "/").first else {
            return false
        }
        let rootAlias = String(firstComponent)
        return visibleRootFolders.contains { $0.name == rootAlias }
    }

    @MainActor
    func findFolder(atPath path: String) -> FolderViewModel? {
        let normalized = normalizeUserInputPath(path)
        let standardized = (normalized as NSString).standardizingPath
        let isAbsolute = standardized.hasPrefix("/")
        if isAbsolute {
            return findFolderByFullPath(standardized)
        } else {
            return findFolderByRelativePath(standardized)
        }
    }

    @MainActor
    func materializeFileForUserInput(
        _ userPath: String,
        profile: PathLocateProfile = .mcpRead,
        rootScopeOverride: LookupRootScope? = nil
    ) async -> FileViewModel? {
        let trimmed = normalizeUserInputPath(userPath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let hits = await findFiles(
            atPaths: [trimmed],
            profile: profile,
            rootScopeOverride: rootScopeOverride,
            materializeMissing: true
        )
        return hits[trimmed]
    }

    @MainActor
    func resolveFileForUserInput(
        _ userPath: String,
        profile: PathLocateProfile = .mcpRead,
        rootScopeOverride: LookupRootScope? = nil
    ) async -> FileViewModel? {
        await materializeFileForUserInput(
            userPath,
            profile: profile,
            rootScopeOverride: rootScopeOverride
        )
    }

    @MainActor
    func resolveReadableFileForUserInput(
        _ userPath: String,
        profile: PathLocateProfile = .mcpRead,
        rootScopeOverride: LookupRootScope? = nil
    ) async -> ReadableFileHandle? {
        let trimmed = normalizeUserInputPath(userPath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if profile == .mcpRead, let explicitSystemFile = resolveExplicitSystemFile(trimmed) {
            return .workspace(explicitSystemFile)
        }

        if let workspaceFile = await resolveFileForUserInput(
            trimmed,
            profile: profile,
            rootScopeOverride: rootScopeOverride
        ) {
            return .workspace(workspaceFile)
        }

        guard trimmed.hasPrefix("/") else { return nil }
        return resolveAlwaysReadableExternalFile(atAbsolutePath: trimmed).map { .external($0) }
    }

    @MainActor
    func resolveAlwaysReadableExternalFolderDisplayPath(_ userPath: String) -> String? {
        let normalized = normalizeUserInputPath(userPath).trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix("/") else { return nil }
        guard isAlwaysReadableExternalPath(normalized) else { return nil }

        let absolutePath = normalizedAlwaysReadableAbsolutePath(for: normalized)
        guard isAlwaysReadableExternalPath(absolutePath) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return AgentSupportDirectoryCatalog.displayPath(
            for: absolutePath,
            homeDirectoryURL: alwaysReadableHomeDirectoryURL
        )
    }

    @MainActor
    func displayPath(forExternalPath userPath: String) -> String {
        AgentSupportDirectoryCatalog.displayPath(
            for: normalizeUserInputPath(userPath),
            homeDirectoryURL: alwaysReadableHomeDirectoryURL
        )
    }

    @MainActor
    func isAlwaysReadableExternalPath(_ userPath: String) -> Bool {
        let normalized = normalizeUserInputPath(userPath).trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix("/") else { return false }
        let directories = AgentSupportDirectoryCatalog.effectiveAlwaysReadableDirectories(
            homeDirectoryURL: alwaysReadableHomeDirectoryURL
        )
        return directories.contains {
            AgentSupportDirectoryCatalog.contains(
                absolutePath: normalized,
                in: $0
            )
        }
    }

    func readAlwaysReadableExternalFile(_ file: ExternalReadableFile) async throws -> String {
        let path = file.absolutePath
        return try await Task.detached(priority: .userInitiated) {
            let url = URL(fileURLWithPath: path)
            let data = try Data(contentsOf: url)
            if let decoded = String(data: data, encoding: .utf8) {
                return decoded
            }
            if let decoded = String(data: data, encoding: .unicode) {
                return decoded
            }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    @MainActor
    private func resolveAlwaysReadableExternalFile(atAbsolutePath path: String) -> ExternalReadableFile? {
        guard isAlwaysReadableExternalPath(path) else { return nil }
        let absolutePath = normalizedAlwaysReadableAbsolutePath(for: path)
        guard isAlwaysReadableExternalPath(absolutePath) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        return ExternalReadableFile(
            absolutePath: absolutePath,
            displayPath: AgentSupportDirectoryCatalog.displayPath(
                for: absolutePath,
                homeDirectoryURL: alwaysReadableHomeDirectoryURL
            )
        )
    }

    @MainActor
    private func normalizedAlwaysReadableAbsolutePath(for path: String) -> String {
        let normalized = AgentSupportDirectoryCatalog.normalizedPath(for: path)
        if FileManager.default.fileExists(atPath: normalized) {
            return AgentSupportDirectoryCatalog.normalizedPath(
                for: URL(fileURLWithPath: normalized).resolvingSymlinksInPath().standardizedFileURL.path
            )
        }
        return normalized
    }

    @MainActor
    func openFileForMarkdownLink(_ target: MarkdownFileLinkTarget) async -> Bool {
        if let file = await resolveFileForMarkdownLink(target) {
            file.openInDefaultApp()
            return true
        }

        let standardizedPath = (target.normalizedPath as NSString).standardizingPath
        guard standardizedPath.hasPrefix("/") else { return false }

        let fileURL = URL(fileURLWithPath: standardizedPath)
        return NSWorkspace.shared.open(fileURL)
    }

    @MainActor
    private func resolveFileForMarkdownLink(_ target: MarkdownFileLinkTarget) async -> FileViewModel? {
        let normalizedPath = normalizeUserInputPath(target.normalizedPath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else { return nil }

        if let selected = resolveSelectedFileFirst(normalizedPath) {
            return selected
        }

        if normalizedPath.hasPrefix("/") {
            let standardizedPath = (normalizedPath as NSString).standardizingPath
            if let exact = findFileByFullPath(standardizedPath) {
                return exact
            }
        } else if let exact = findFileByRelativePath(normalizedPath) {
            return exact
        }

        if let matched = await resolveFileForUserInput(normalizedPath, profile: .uiAssisted) {
            return matched
        }

        guard !normalizedPath.hasPrefix("/") else { return nil }
        return await searchFallbackCandidates(for: normalizedPath).first
    }

    @MainActor
    private func resolveSelectedFileFirst(_ normalizedPath: String) -> FileViewModel? {
        let standardizedPath = (normalizedPath as NSString).standardizingPath

        if standardizedPath.hasPrefix("/") {
            if let exact = selectedFiles.first(where: { $0.standardizedFullPath == standardizedPath }) {
                return exact
            }
        } else {
            if let exactRelative = selectedFiles.first(where: { $0.standardizedRelativePath == standardizedPath }) {
                return exactRelative
            }
            if let exactUnique = selectedFiles.first(where: {
                ($0.uniqueRelativePath as NSString).standardizingPath == standardizedPath
            }) {
                return exactUnique
            }
        }

        let basename = URL(fileURLWithPath: standardizedPath).lastPathComponent
        guard !basename.isEmpty else { return nil }

        let basenameMatches = selectedFiles.filter { $0.name.caseInsensitiveCompare(basename) == .orderedSame }
        return basenameMatches.count == 1 ? basenameMatches[0] : nil
    }

    @MainActor
    private func ensureMarkdownPathSearchIndex() async {
        let generation = currentHierarchyGenerationSignature()
        guard markdownPathSearchGeneration != generation || markdownPathSearchIndex == nil else {
            return
        }

        let files = fileHierarchyIndex.filesByFullPath.values.sorted {
            $0.standardizedFullPath.localizedStandardCompare($1.standardizedFullPath) == .orderedAscending
        }

        var entries: [MarkdownPathSearchEntry] = []
        entries.reserveCapacity(files.count * 2)

        for file in files {
            let relativePath = file.standardizedRelativePath
            entries.append(MarkdownPathSearchEntry(queryPath: relativePath, fileFullPath: file.standardizedFullPath))

            let uniqueRelativePath = (file.uniqueRelativePath as NSString).standardizingPath
            if uniqueRelativePath != relativePath {
                entries.append(MarkdownPathSearchEntry(queryPath: uniqueRelativePath, fileFullPath: file.standardizedFullPath))
            }
        }

        markdownPathSearchEntries = entries
        markdownPathSearchIndex = await PathSearchIndex.build(paths: entries.map(\.queryPath))
        markdownPathSearchGeneration = generation
    }

    @MainActor
    private func searchFallbackCandidates(for normalizedPath: String) async -> [FileViewModel] {
        await ensureMarkdownPathSearchIndex()
        guard let markdownPathSearchIndex else { return [] }

        var queries: [String] = []
        let standardizedPath = (normalizedPath as NSString).standardizingPath
        if !standardizedPath.isEmpty {
            queries.append(standardizedPath)
        }

        let basename = URL(fileURLWithPath: standardizedPath).lastPathComponent
        if !basename.isEmpty, !queries.contains(basename) {
            queries.append(basename)
        }

        var bestRankByFullPath: [String: Int] = [:]
        for query in queries {
            let results = await markdownPathSearchIndex.search(query, limit: 64)
            for (rank, candidate) in results.enumerated() {
                guard candidate.index >= 0, candidate.index < markdownPathSearchEntries.count else { continue }
                let entry = markdownPathSearchEntries[candidate.index]
                let currentRank = bestRankByFullPath[entry.fileFullPath] ?? .max
                if rank < currentRank {
                    bestRankByFullPath[entry.fileFullPath] = rank
                }
            }
        }

        let selectedPaths = Set(selectedFiles.map(\.standardizedFullPath))
        let selectedRootIDs = Set(selectedFiles.map(\.rootIdentifier))
        let rankedCandidates: [(file: FileViewModel, isSelected: Bool, inSelectedRoot: Bool, rank: Int)] = bestRankByFullPath.compactMap { fullPath, rank in
            guard let file = fileHierarchyIndex.filesByFullPath[fullPath] else { return nil }
            return (
                file: file,
                isSelected: selectedPaths.contains(file.standardizedFullPath),
                inSelectedRoot: selectedRootIDs.contains(file.rootIdentifier),
                rank: rank
            )
        }

        return rankedCandidates
            .sorted { lhs, rhs in
                if lhs.isSelected != rhs.isSelected {
                    return lhs.isSelected && !rhs.isSelected
                }
                if lhs.inSelectedRoot != rhs.inSelectedRoot {
                    return lhs.inSelectedRoot && !rhs.inSelectedRoot
                }
                if lhs.rank != rhs.rank {
                    return lhs.rank < rhs.rank
                }
                return lhs.file.standardizedFullPath.localizedStandardCompare(rhs.file.standardizedFullPath) == .orderedAscending
            }
            .map(\.file)
    }

    @MainActor
    func resolveFolderForUserInput(
        _ userPath: String,
        rootScope: LookupRootScope = .visibleWorkspace
    ) -> FolderViewModel? {
        resolveFolderInput(userPath, rootScope: rootScope).folder
    }

    @MainActor
    private func resolveFolderInput(
        _ path: String,
        rootScope: LookupRootScope = .visibleWorkspace
    ) -> (folder: FolderViewModel?, displayPath: String?, issue: PathResolutionIssue?) {
        let normalized = normalizeUserInputPath(path)
        let cleaned = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return (nil, nil, .emptyInput) }

        if let explicitResolution = resolveExplicitSystemPath(cleaned),
           let folder = findFolderByFullPath(explicitResolution.standardizedAbsolutePath)
        {
            return (folder, mcpDisplayPath(for: folder), nil)
        }

        if let issue = exactPathResolutionIssue(for: cleaned, kind: .folder, rootScope: rootScope) {
            return (nil, nil, issue)
        }

        if cleaned.hasPrefix("/") {
            let standardized = (cleaned as NSString).standardizingPath
            if let folder = findFolderByFullPath(standardized) {
                return (folder, clientDisplayPath(for: folder), nil)
            }
            if let aliasResolution = resolveLeadingSlashRootAlias(from: standardized, requireRemainder: false) {
                switch aliasResolution {
                case let .bareRoot(root, _):
                    if let folder = rootFolders.first(where: { $0.id == root.id }) {
                        return (folder, clientDisplayPath(root: root, relativePath: ""), nil)
                    }
                case let .prefixed(root, _, remainder):
                    let abs = ((root.standardizedFullPath as NSString).appendingPathComponent(remainder) as NSString).standardizingPath
                    if let folder = findFolderByFullPath(abs) {
                        return (folder, clientDisplayPath(root: root, relativePath: folder.relativePath), nil)
                    }
                case let .ambiguous(alias, matchingRoots):
                    return (nil, nil, .ambiguousAlias(alias: alias, matchingRoots: matchingRoots))
                case .notAliasPrefixed:
                    break
                }
            }
            let absoluteIssue = unmatchedAbsolutePathIssue(for: standardized, rawInput: path)
            switch absoluteIssue {
            case .pathOutsideWorkspace:
                return (nil, nil, absoluteIssue)
            case .ambiguousAlias, .unresolved, .unsupportedPseudoAbsoluteAlias:
                break
            default:
                break
            }
        }

        switch resolveVisibleRootAlias(cleaned, requireRemainder: false, disambiguateRealSubpath: false) {
        case let .bareRoot(root, _):
            if let folder = rootFolders.first(where: { $0.id == root.id }) {
                return (folder, clientDisplayPath(root: root, relativePath: ""), nil)
            }
        case let .prefixed(root, _, remainder):
            let abs = ((root.standardizedFullPath as NSString).appendingPathComponent(remainder) as NSString).standardizingPath
            if let folder = findFolderByFullPath(abs) {
                return (folder, clientDisplayPath(root: root, relativePath: folder.relativePath), nil)
            }
            let literalMatches = literalRelativeFolderMatches(for: cleaned)
            if literalMatches.count == 1, let folder = literalMatches.first {
                return (folder, clientDisplayPath(for: folder), nil)
            }
        case let .ambiguous(alias, matchingRoots):
            return (nil, nil, .ambiguousAlias(alias: alias, matchingRoots: matchingRoots))
        case .notAliasPrefixed:
            break
        }

        if let folder = findFolderByRelativePath(cleaned, scope: rootScope) {
            return (folder, mcpDisplayPath(for: folder), nil)
        }

        return (nil, nil, nil)
    }

    @MainActor
    func resolveFilesForFolderInput(
        _ path: String,
        rootScope: LookupRootScope = .visibleWorkspace
    ) async -> FolderInputResolution {
        let direct = resolveFolderInput(path, rootScope: rootScope)
        if let folder = direct.folder {
            return FolderInputResolution(
                files: getFilesRecursively(under: folder),
                handled: true,
                displayPath: direct.displayPath,
                issue: nil
            )
        }
        if let issue = direct.issue {
            return FolderInputResolution(files: [], handled: false, displayPath: nil, issue: issue)
        }

        let cleaned = normalizeUserInputPath(path).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return FolderInputResolution(files: [], handled: false, displayPath: nil, issue: .emptyInput)
        }

        if let issue = exactPathResolutionIssue(for: cleaned, kind: .folder, rootScope: rootScope) {
            return FolderInputResolution(files: [], handled: false, displayPath: nil, issue: issue)
        }

        if let loc = await pathLocation(
            cleaned,
            exactMatchOnly: false,
            profile: .mcpSelection,
            rootScopeOverride: rootScope
        ),
            let folder = resolveFolder(at: loc)
        {
            return FolderInputResolution(
                files: getFilesRecursively(under: folder),
                handled: true,
                displayPath: mcpDisplayPath(for: folder),
                issue: nil
            )
        }

        return FolderInputResolution(files: [], handled: false, displayPath: nil, issue: .unresolved(input: path))
    }

    @MainActor
    func applyCodemapOnlySelection(paths: [String]) async {
        guard !paths.isEmpty else { return }

        var filesToScan: [FileViewModel] = []
        var seen = Set<UUID>()
        var didResolveAny = false

        for raw in paths {
            var handled = false
            if let file = await resolveFileForUserInput(raw) {
                handled = true
                if !didResolveAny {
                    enterManualCodemapMode()
                    didResolveAny = true
                }
                if seen.insert(file.id).inserted {
                    if file.fileAPI == nil {
                        filesToScan.append(file)
                    }
                    setFileAsCodemap(file)
                }
            } else {
                let folderResolution = await resolveFilesForFolderInput(raw, rootScope: .visibleWorkspace)
                if folderResolution.handled {
                    handled = true
                    if !didResolveAny {
                        enterManualCodemapMode()
                        didResolveAny = true
                    }
                }
                for file in folderResolution.files {
                    if seen.insert(file.id).inserted {
                        if file.fileAPI == nil {
                            filesToScan.append(file)
                        }
                        setFileAsCodemap(file)
                    }
                }
            }

            if !handled {
                continue
            }
        }

        await requestStoreCodemapScans(for: filesToScan)
    }

    private func requestStoreCodemapScans(for files: [FileViewModel]) async {
        guard !files.isEmpty else { return }
        var seen = Set<UUID>()
        for file in files where seen.insert(file.id).inserted {
            do {
                try await workspaceFileContextStore.requestCodemapScan(fileID: file.id)
            } catch {
                continue
            }
        }
    }
}

enum FileManagerError: Error, LocalizedError {
    case failedToLoadFolder(Error)
    case failedToLoadFile(Error)
    case fileSystemServiceNotFound
    case failedToLoadContent
    // New: richer, contextual variant used by MCP tools and FS ops
    case fileSystemServiceNotFoundWithContext(String)

    var errorDescription: String? {
        switch self {
        case let .failedToLoadFolder(err):
            "Failed to load folder: \(err.localizedDescription)"
        case let .failedToLoadFile(err):
            "Failed to load file: \(err.localizedDescription)"
        case .fileSystemServiceNotFound:
            "No matching workspace folder for the requested path."
        case .failedToLoadContent:
            "Failed to load content."
        case let .fileSystemServiceNotFoundWithContext(context):
            context
        }
    }
}

struct PathLocation {
    let rootPath: String
    let correctedPath: String
    let rootIdentifier: UUID?
}

extension PathLocation {
    var absolutePath: String {
        let stdRoot = (rootPath as NSString).standardizingPath
        if correctedPath.hasPrefix("/") {
            return (correctedPath as NSString).standardizingPath
        }
        return ((stdRoot as NSString).appendingPathComponent(correctedPath) as NSString).standardizingPath
    }
}

extension Array {
    func chunks(ofCount count: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: self.count, by: count).map {
            self[$0 ..< Swift.min($0 + count, self.count)]
        }
    }
}

@MainActor
extension WorkspaceFilesViewModel {
    /// Appends `fullPath` (converted to a root-relative path) to the owning
    /// folder’s **.repo_ignore** file, creating it when necessary.
    /// The operation is carried out by the workspace file context store;
    /// the UI layer never touches the file-system directly.
    @MainActor
    func ignorePath(fullPath: String, isDirectory: Bool) async {
        let standardizedFullPath = StandardizedPath.absolute(fullPath)

        // (1) Find the *deepest* root that owns this path
        guard let root = rootFolders
            .filter({ StandardizedPath.isDescendant(standardizedFullPath, of: $0.standardizedFullPath) })
            .sorted(by: { $0.standardizedFullPath.count > $1.standardizedFullPath.count })
            .first
        else { return }

        let rel = StandardizedPath.relative(
            String(standardizedFullPath.dropFirst(root.standardizedFullPath.count))
        )

        // If empty, user tried to ignore the root itself – bail out
        guard !rel.isEmpty else { return }

        let finalLine = isDirectory ? rel + "/" : rel
        let svcRelPath = ".repo_ignore"

        let rootKey = root.standardizedFullPath
        guard let workspaceRoot = workspaceFileContextRootsByRootKey[rootKey] else { return }

        do {
            let ignoreExists = try await workspaceFileContextStore.fileExistsOnDisk(rootID: workspaceRoot.id, relativePath: svcRelPath)

            if ignoreExists {
                // Read current content (might be nil for binary / empty)
                let existing = try await (workspaceFileContextStore.readContent(rootID: workspaceRoot.id, relativePath: svcRelPath)) ?? ""
                // Check duplication
                let alreadyPresent = existing
                    .components(separatedBy: .newlines)
                    .contains { $0.trimmingCharacters(in: .whitespaces) == finalLine }

                if alreadyPresent { return } // nothing to do

                let needsNL = existing.isEmpty ? "" :
                    (existing.hasSuffix("\n") ? "" : "\n")

                let newContent = existing + needsNL + finalLine + "\n"
                try await workspaceFileContextStore.editFile(rootID: workspaceRoot.id, relativePath: svcRelPath, newContent: newContent)

            } else {
                let newContent = finalLine + "\n"
                try await workspaceFileContextStore.createFile(rootID: workspaceRoot.id, relativePath: svcRelPath, content: newContent)
            }

            // Refresh ignore rules for this root immediately through the store-owned service.
            try await workspaceFileContextStore.refreshIgnoreRules(rootID: workspaceRoot.id)
            // Let the rest of the app know something changed
            requestRefresh()

        } catch {
            print("Failed to update .repo_ignore – \(error)")
        }
    }

    @MainActor
    private func scheduleSliceRebaseForModifiedFile(
        _ file: FileViewModel,
        relativePath: String
    ) {
        let fullPath = file.standardizedFullPath
        guard shouldScheduleSliceRebase(for: file, fullPath: fullPath) else { return }
        sliceRebaseTasksByFullPath[fullPath]?.cancel()

        let taskID = UUID()
        sliceRebaseTaskIDsByFullPath[fullPath] = taskID

        let task = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.sliceRebaseTaskIDsByFullPath[fullPath] == taskID else { return }
                    self.sliceRebaseTasksByFullPath.removeValue(forKey: fullPath)
                    self.sliceRebaseTaskIDsByFullPath.removeValue(forKey: fullPath)
                }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self else { return }
            guard !Task.isCancelled else { return }
            let hasSlices = await hasAnySlicesForFile(file)
            guard !Task.isCancelled else { return }
            guard sliceRebaseTaskIDsByFullPath[fullPath] == taskID else { return }
            guard hasSlices else {
                noSlicesKnownRevisionByFullPath[fullPath] = partitionSliceSaveRevision
                return
            }
            noSlicesKnownRevisionByFullPath.removeValue(forKey: fullPath)
            await rebaseSlicesForModifiedFile(
                file,
                relativePath: relativePath,
                expectedTaskID: taskID
            )
        }

        sliceRebaseTasksByFullPath[fullPath] = task
    }

    /// Waits for pending slice-rebase tasks that affect currently selected files.
    /// Used by selection/reporting paths so line-range metadata reflects post-edit rebases.
    @MainActor
    func waitForPendingSliceRebasesAffectingSelection() async {
        let selectedFullPaths = Set(selectedFiles.map(\.standardizedFullPath))
        await waitForPendingSliceRebases(affectingFullPaths: selectedFullPaths)
    }

    /// Waits for pending slice-rebase tasks affecting candidate file paths.
    /// Candidates can be absolute full paths or relative paths.
    @MainActor
    func waitForPendingSliceRebases(affectingCandidatePaths candidatePaths: [String]) async {
        let fullPaths = normalizedFullPathsForSliceRebaseWait(from: candidatePaths)
        await waitForPendingSliceRebases(affectingFullPaths: fullPaths)
    }

    @MainActor
    private func waitForPendingSliceRebases(affectingFullPaths fullPaths: Set<String>) async {
        guard !fullPaths.isEmpty else { return }
        let pending = sliceRebaseTasksByFullPath.compactMap { path, task -> Task<Void, Never>? in
            fullPaths.contains(path) ? task : nil
        }
        guard !pending.isEmpty else { return }

        for task in pending {
            await task.value
        }
    }

    @MainActor
    private func normalizedFullPathsForSliceRebaseWait(from candidatePaths: [String]) -> Set<String> {
        var result: Set<String> = []
        for raw in candidatePaths {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let standardized = (trimmed as NSString).standardizingPath

            if standardized.hasPrefix("/") {
                result.insert(standardized)
                continue
            }

            if let file = findFileByRelativePath(standardized) {
                result.insert(file.standardizedFullPath)
                continue
            }

            if let full = findFullPath(for: standardized) {
                result.insert((full as NSString).standardizingPath)
            }
        }
        return result
    }

    @MainActor
    private func shouldScheduleSliceRebase(for file: FileViewModel, fullPath: String) -> Bool {
        if hasLikelySlicesForFile(file) {
            return true
        }

        // Conservative skip: only skip when this exact file was already confirmed
        // as "no slices" and no partition save has happened since.
        if noSlicesKnownRevisionByFullPath[fullPath] == partitionSliceSaveRevision {
            return false
        }
        return true
    }

    @MainActor
    private func scopesForSliceRebase(workspaceID: UUID) -> [PartitionScope] {
        var scopes: [PartitionScope] = []

        if let activeScope = try? currentPartitionScope() {
            scopes.append(activeScope)
        }
        scopes.append(PartitionScope(workspaceID: workspaceID))
        if let tabs = workspaceManager?.activeWorkspace?.composeTabs {
            for tab in tabs {
                scopes.append(PartitionScope(workspaceID: workspaceID, tabID: tab.id))
            }
        }

        var deduped: [PartitionScope] = []
        for scope in scopes where !deduped.contains(where: { $0 == scope }) {
            deduped.append(scope)
        }
        return deduped
    }

    @MainActor
    private func hasLikelySlicesForFile(_ file: FileViewModel) -> Bool {
        let rootKey = file.standardizedRootFolderPath
        let relKey = file.standardizedRelativePath
        let fullPath = file.standardizedFullPath

        if let inMemory = currentSlicesByRoot[rootKey]?[relKey], !inMemory.ranges.isEmpty {
            return true
        }

        if let tabs = workspaceManager?.activeWorkspace?.composeTabs {
            for tab in tabs {
                if let slices = tab.selection.slices.first(where: { (($0.key as NSString).standardizingPath) == fullPath })?.value,
                   !slices.isEmpty
                {
                    return true
                }
            }
        }

        return false
    }

    @MainActor
    private func hasAnySlicesForFile(_ file: FileViewModel) async -> Bool {
        if hasLikelySlicesForFile(file) {
            return true
        }

        guard let workspaceID = currentWorkspaceID else { return false }
        let rootKey = file.standardizedRootFolderPath
        let relKey = file.standardizedRelativePath

        for scope in scopesForSliceRebase(workspaceID: workspaceID) {
            guard !Task.isCancelled else { return false }
            let data = await selectionSliceCoordinator.loadSlices(forRootPath: rootKey, scope: scope)
            if let stored = data[relKey], !stored.ranges.isEmpty {
                return true
            }
        }

        return false
    }

    @MainActor
    private func rebaseSlicesForModifiedFile(
        _ file: FileViewModel,
        relativePath: String,
        expectedTaskID: UUID
    ) async {
        guard let workspaceID = currentWorkspaceID else { return }

        let rootKey = file.standardizedRootFolderPath
        let relKey = file.standardizedRelativePath
        let fullPath = file.standardizedFullPath
        guard sliceRebaseTaskIDsByFullPath[fullPath] == expectedTaskID else { return }
        let activeScope = try? currentPartitionScope()
        let fileModificationTime = file.modificationDate.timeIntervalSince1970

        let oldSnapshot = await file.cachedContentSnapshot()
        let oldText = oldSnapshot.content
        let loadedNewText: String? = if let workspaceRoot = workspaceFileContextRootsByRootKey[rootKey] {
            try? await workspaceFileContextStore.readContent(
                rootID: workspaceRoot.id,
                relativePath: relativePath
            )
        } else {
            nil
        }
        let canRebase = (loadedNewText != nil)
        let newText = loadedNewText ?? ""

        var activeScopeChanged = false

        for scope in scopesForSliceRebase(workspaceID: workspaceID) {
            guard !Task.isCancelled else { return }
            guard sliceRebaseTaskIDsByFullPath[fullPath] == expectedTaskID else { return }
            let data = await selectionSliceCoordinator.loadSlices(forRootPath: rootKey, scope: scope)
            guard let stored = data[relKey], !stored.ranges.isEmpty else { continue }

            let storedRanges = stored.ranges
            let storedAnchors = stored.anchors
            let oldTextSnapshot = oldText
            let newTextSnapshot = newText
            let canRebaseSnapshot = canRebase

            let computed: (ranges: [LineRange], anchors: [SliceAnchor]?) = await Task.detached(priority: .utility) { [storedRanges, storedAnchors, oldTextSnapshot, newTextSnapshot, canRebaseSnapshot] in
                if Task.isCancelled {
                    return (storedRanges, storedAnchors)
                }
                let nextRanges: [LineRange]
                if canRebaseSnapshot {
                    let result = SliceRebaseEngine.rebase(
                        oldText: oldTextSnapshot,
                        newText: newTextSnapshot,
                        oldRanges: storedRanges,
                        anchors: storedAnchors
                    )
                    nextRanges = result.rebased
                } else {
                    nextRanges = []
                }

                let normalizedRanges = SliceRangeMath.normalize(nextRanges)
                let nextAnchors: [SliceAnchor]? = {
                    guard canRebaseSnapshot, !normalizedRanges.isEmpty else { return nil }
                    if Task.isCancelled { return storedAnchors }
                    return SliceRebaseEngine.buildAnchors(content: newTextSnapshot, ranges: normalizedRanges)
                }()

                return (normalizedRanges, nextAnchors)
            }.value

            guard !Task.isCancelled else { return }
            guard sliceRebaseTaskIDsByFullPath[fullPath] == expectedTaskID else { return }

            let normalizedRanges = computed.ranges
            let nextAnchors = computed.anchors
            if normalizedRanges == storedRanges, nextAnchors == storedAnchors {
                continue
            }
            do {
                let post = try await selectionSliceCoordinator.applyPartitionUpdates(
                    forRootPath: rootKey,
                    scope: scope,
                    updates: [
                        relKey: PartitionStore.SliceUpdate(
                            ranges: normalizedRanges,
                            fileModificationTime: fileModificationTime,
                            anchors: nextAnchors
                        )
                    ],
                    mode: .setPaths
                )

                if let activeScope, scope == activeScope {
                    activeScopeChanged = true
                    if post.isEmpty {
                        currentSlicesByRoot.removeValue(forKey: rootKey)
                    } else {
                        currentSlicesByRoot[rootKey] = post
                    }
                }
            } catch {
                if Self.isLoggingEnabled {
                    print("Failed to rebase slices for \(relKey) in scope \(String(describing: scope.tabID)) – \(error)")
                }
            }
        }

        if activeScopeChanged {
            requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")
        }

        // Always rebase tab-stored slices when this file has any slices.
        // Virtual/background tabs can carry slice state in tab selection storage
        // before partition entries exist for that tab scope.
        if canRebase {
            guard !Task.isCancelled else { return }
            guard sliceRebaseTaskIDsByFullPath[fullPath] == expectedTaskID else { return }
            await workspaceManager?.rebaseSlicesForFileAcrossTabs(
                fullPath: fullPath,
                asyncTransform: { current in
                    await Task.detached(priority: .utility) { [oldText, newText, current] in
                        SliceRebaseEngine.rebase(
                            oldText: oldText,
                            newText: newText,
                            oldRanges: current,
                            anchors: nil
                        ).rebased
                    }.value
                }
            )
        } else {
            guard !Task.isCancelled else { return }
            guard sliceRebaseTaskIDsByFullPath[fullPath] == expectedTaskID else { return }
            workspaceManager?.rebaseSlicesForFileAcrossTabs(fullPath: fullPath) { _ in [] }
        }
    }

    private func subscribeToFileSystemPreferenceChanges() {
        fileSystemSettingsCancellable = NotificationCenter.default
            .publisher(for: .appSettingsFileSystemPreferencesDidChange)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.syncFileSystemPreferencesFromGlobalSettings()
                    self.requestFileSystemSettingsRefresh()
                }
            }
    }

    @MainActor
    private func syncFileSystemPreferencesFromGlobalSettings() {
        let settings = GlobalSettingsStore.shared.fileSystemSettingsSnapshot()
        respectGitignore = settings.respectGitignore
        respectRepoIgnore = settings.respectRepoIgnore
        respectCursorignore = settings.respectCursorignore
        enableHierarchicalIgnores = settings.enableHierarchicalIgnores
        skipSymlinks = settings.skipSymlinks
        showEmptyFolders = settings.showEmptyFolders
    }

    private func subscribeToPartitionStoreSaves() {
        partitionStoreSaveCancellable = NotificationCenter.default
            .publisher(for: PartitionStore.didSaveNotification)
            .sink { [weak self] note in
                guard let self else { return }
                Task { @MainActor in
                    // Workspace must match
                    guard let wsAny = note.userInfo?[PartitionStore.notifWorkspaceIDKey],
                          let ws = wsAny as? UUID else { return }
                    guard ws == self.currentWorkspaceID else { return }
                    self.partitionSliceSaveRevision &+= 1

                    // Ignore our own writes to avoid redundant reload churn in this VM.
                    if let sourceAny = note.userInfo?[PartitionStore.notifSourceIDKey],
                       let sourceID = sourceAny as? UUID,
                       sourceID == self.selectionSliceCoordinator.notificationSourceID
                    {
                        return
                    }

                    guard let rootAny = note.userInfo?[PartitionStore.notifRootPathKey],
                          let nsRoot = rootAny as? String else { return }
                    let stdRoot = (nsRoot as NSString).standardizingPath
                    // Only refresh if this root folder is actually loaded in this window
                    guard self.isRootFolderLoaded(stdRoot) else { return }

                    // Tab must match (nil == nil is fine)
                    let tabAny = note.userInfo?[PartitionStore.notifTabIDKey]
                    let eventTab = tabAny as? UUID
                    guard eventTab == self.currentTabID else { return }

                    await self.refreshSlicesFromDisk(forRootURL: URL(fileURLWithPath: stdRoot))
                }
            }
    }

    #if DEBUG
        @MainActor
        func _testHasAnySlicesForFile(_ file: FileViewModel) async -> Bool {
            await hasAnySlicesForFile(file)
        }

        @MainActor
        func _testShouldScheduleSliceRebase(_ file: FileViewModel) -> Bool {
            let fullPath = file.standardizedFullPath
            return shouldScheduleSliceRebase(for: file, fullPath: fullPath)
        }

        @MainActor
        func _testMarkKnownNoSlices(_ file: FileViewModel) {
            let fullPath = file.standardizedFullPath
            noSlicesKnownRevisionByFullPath[fullPath] = partitionSliceSaveRevision
        }

        @MainActor
        func _testBumpPartitionSliceSaveRevision() {
            partitionSliceSaveRevision &+= 1
        }

        @MainActor
        func _testPersistSlicesForScope(
            rootPath: String,
            scope: PartitionScope,
            relativePath: String,
            ranges: [LineRange]
        ) async throws {
            _ = try await selectionSliceCoordinator.applyPartitionUpdates(
                forRootPath: rootPath,
                scope: scope,
                updates: [
                    relativePath: PartitionStore.SliceUpdate(
                        ranges: ranges,
                        fileModificationTime: nil,
                        anchors: nil
                    )
                ],
                mode: .setPaths
            )
        }
    #endif
}
