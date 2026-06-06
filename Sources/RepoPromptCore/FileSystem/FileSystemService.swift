import Dispatch
import Foundation

package actor FileSystemService {
    // Internal for FileSystemService same-target extensions only.
    // These are not public API; preserve actor isolation when accessing them.
    package let fileManager = FileManager.default
    package nonisolated let diagnosticRootToken = UUID()
    package nonisolated let watcherIngressMailbox: FileSystemWatcherIngressMailbox
    package static let maxPendingRawEvents = 50000
    package static let overflowRescanEventFlags = FileSystemWatchEventFlags.overflowRootRescan

    #if DEBUG
        /// Static flag to enable verbose debug logging (default: false)
        static var enableDebugLogging = false
    #endif

    package func fileSystemDebugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
            guard Self.enableDebugLogging else { return }
            print(message())
        #endif
    }

    @discardableResult
    package func publishFileSystemDeltas(
        _ deltas: [FileSystemDelta],
        source: FileSystemDeltaPublicationSource,
        watcherAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark? = nil
    ) -> UInt64 {
        guard !deltas.isEmpty || watcherAcceptedWatermark != nil || source == .watcherBarrierNoop else {
            return lastServicePublicationSequence
        }
        nextServicePublicationSequence &+= 1
        let servicePublicationSequence = nextServicePublicationSequence
        lastServicePublicationSequence = servicePublicationSequence
        if let watcherAcceptedWatermark {
            lastPublishedWatcherAcceptedWatermark = max(lastPublishedWatcherAcceptedWatermark, watcherAcceptedWatermark)
        }
        let publicationCorrelation = WorkspaceRuntimePerf.makeLifecycleCorrelationIfActive()
        let publication = FileSystemDeltaPublication(
            servicePublicationSequence: servicePublicationSequence,
            source: source,
            watcherAcceptedWatermark: watcherAcceptedWatermark,
            correlationID: publicationCorrelation?.id,
            deltas: deltas
        )
        WorkspaceRuntimePerf.lifecycleEvent(
            WorkspaceRuntimePerf.Lifecycle.FileSystem.servicePublish,
            correlation: publicationCorrelation,
            WorkspaceRuntimePerf.Dimensions(
                status: source.rawValue,
                changeCount: deltas.count,
                rootToken: diagnosticRootToken.uuidString,
                ingressSequence: watcherAcceptedWatermark?.rawValue,
                barrierSequence: servicePublicationSequence
            )
        )
        _ = publicationHub.publish(publication)
        return servicePublicationSequence
    }

    #if DEBUG
        /// Debug override for filesystem operations
        var fileManagerOverride: (any FileSystemProviding)?

        /// Returns the appropriate filesystem provider (debug override or default)
        var fm: any FileSystemProviding {
            fileManagerOverride ?? fileManager
        }
    #else
        /// In release builds, always use FileManager.default
        var fm: FileManager {
            fileManager
        }
    #endif

    #if DEBUG
        /// Flag to enable test mode
        var isTestMode = false

        /// Test-only tracking of processed events
        var processedFolders: Set<String> = []

        /// Test-only method to mock directory contents
        var mockDirectoryContents: ((String) -> [String])?

        /// Test-only gate after a watcher batch leaves the pending buffer but before processing.
        var watcherBatchWillProcessHandler: (@Sendable () async -> Void)?

        /// Test-only hook invoked inside the real-filesystem off-actor content worker before each read.
        var contentReadChunkHandler: (@Sendable (String) async -> Void)?
    #endif

    /// Tracks paths we know about, to detect additions/removals
    package var visitedPaths = Set<String>()

    /// True => directory, False => file
    package var visitedItems = [String: Bool]()

    /// Injected platform and runtime dependencies.
    package let watcherFactory: any FileSystemWatcherCreating
    package nonisolated let directoryListingBackend: any WorkspaceDirectoryListingBackend
    package let mutationBackend: (any WorkspaceFileMutationBackend)?
    package let diagnostics: any WorkspaceRuntimeDiagnosticsSink
    package let ignoreRulesManager: IgnoreRulesManager
    package var watcher: (any FileSystemWatching)?

    /// Synchronous callback publication preserves accepted-ingress ordering.
    package nonisolated let publicationHub = FileSystemDeltaPublicationHub()
    package var nextServicePublicationSequence: UInt64 = 0
    package var lastServicePublicationSequence: UInt64 = 0
    package var lastPublishedWatcherAcceptedWatermark = FileSystemWatcherIngressMailbox.Watermark.zero
    #if DEBUG
        var lastPublishedDeltaCoalescingDiagnostics: PublishedDeltaCoalescingDiagnostics?
    #endif

    /// The in-memory IgnoreRules instance for our path
    package var ignoreRules: IgnoreRules

    package var ignoreCacheStore = IgnoreCacheStore()

    /// Caches the detected encoding for every file we have successfully opened
    package var encodingMap = [String: String.Encoding]()

    /// Path we are managing
    package let path: String
    package let rootURL: URL
    package let canonicalRootURL: URL
    package var canonicalRootPath: String {
        canonicalRootURL.path
    }

    package var standardizedRootPath: String {
        rootURL.path
    }

    package var respectGitignore: Bool
    package var respectRepoIgnore: Bool
    package var respectCursorignore: Bool
    package var skipSymlinks: Bool
    package var enableHierarchicalIgnores: Bool

    // MARK: - Ignore rules change tracking (revision-based for durability)

    /// Monotonic revision incremented each time ignore files change
    package var ignoreRulesRevision: UInt64 = 0
    /// Directories affected by ignore file changes since last consumption
    package var pendingIgnoreChangeDirs: Set<String> = []

    // A buffer for semantic watcher events + coalescing logic
    package var pendingFSEvents: [PendingFSEvent] = []
    package var pendingWatcherAcceptedHighWatermark: FileSystemWatcherIngressMailbox.Watermark?
    package var pendingWatcherPublicationSource: FileSystemDeltaPublicationSource = .watcher
    package var hasPendingOverflowRescan = false
    package var overflowChangedIgnoreDirs: Set<String> = []
    package var coalescingTask: Task<Void, Never>?
    package var watcherBatchProcessingTask: Task<Void, Never>?
    package var watcherBatchProcessingToken: UInt64?
    package var nextWatcherBatchProcessingToken: UInt64 = 0
    package var watcherIngressGeneration: UInt64 = 0
    package var watcherLifecycleEpoch: UInt64 = 0
    package let coalescingDelay: TimeInterval = 0.2

    // MARK: - Event ID-based scan coalescing (prevents dropped events while deduping bursts)

    /// Maps folder relative path → highest watcher event ID that requires scanning
    package var pendingScanTargets: [String: FileSystemWatchEventID] = [:]
    /// Maps folder relative path → highest watcher event ID that has already been scanned
    package var lastScannedEventIdByFolder: [String: FileSystemWatchEventID] = [:]

    /// Short-lived cache
    /// results during a directory walk to avoid repeated allocations.
    package var pathCompsCache = PathComponentsCache()

    /// Maximum number of cached ignore rules (default: 4000)
    package static let ignoreCacheCapacity = 4000

    /// Cache for per-folder ignore rules (key = directory's relative path, "" for root)
    package var perFolderIgnoreCache = LRUCache<String, IgnoreRules>(
        capacity: FileSystemService.ignoreCacheCapacity
    )

    /// Bounded marker cache for directories that have no ignore files.
    /// Eviction is safe: it only causes an extra filesystem recheck.
    package var noIgnoreFileCache = LRUCache<String, Bool>(
        capacity: FileSystemService.ignoreCacheCapacity
    )

    // MARK: - Parallelism Throttling

    /// Maximum concurrent directory scans per actor (prevents CPU saturation)
    package let maxParallelScansPerActor: Int

    /// Maximum folders to scan in a single batch (bounds per-tick work)
    package let maxFoldersPerBatch: Int

    // MARK: - Safety-Net Verification

    /// Minimum interval between safety-net scans for the same folder (seconds)
    package let safetyNetMinInterval: TimeInterval = 300 // 5 minutes

    /// Number of file events before triggering a safety-net parent scan
    package let safetyNetEventThreshold: Int = 200

    /// Tracks when each folder was last verified via directory scan
    package var lastVerifiedAtByFolder: [String: TimeInterval] = [:]

    /// Tracks file event count per folder since last verification
    package var fileEventCountSinceLastScan: [String: Int] = [:]

    // MARK: - Init

    /// Initializes the FileSystemService for a given path, applying ignore rules, optionally skipping symlinks,
    /// and preparing an injected watcher to track changes in that path.
    package init(
        path: String,
        respectGitignore: Bool = true,
        respectRepoIgnore: Bool = true,
        respectCursorignore: Bool = true,
        skipSymlinks: Bool = true,
        enableHierarchicalIgnores: Bool = true,
        dependencies: WorkspaceRuntimeDependencies
    ) async throws {
        self.path = path
        rootURL = URL(fileURLWithPath: path).standardizedFileURL
        canonicalRootURL = rootURL.resolvingSymlinksInPath()
        self.respectGitignore = respectGitignore
        self.respectRepoIgnore = respectRepoIgnore
        self.respectCursorignore = respectCursorignore
        self.skipSymlinks = skipSymlinks
        self.enableHierarchicalIgnores = enableHierarchicalIgnores
        watcherFactory = dependencies.watcherFactory
        directoryListingBackend = dependencies.directoryListingBackend
        mutationBackend = dependencies.mutationBackend
        diagnostics = dependencies.diagnostics
        ignoreRulesManager = IgnoreRulesManager(globalIgnoreDefaults: dependencies.configuration.globalIgnoreDefaults)

        watcherIngressMailbox = FileSystemWatcherIngressMailbox(maxQueuedRawEntries: dependencies.configuration.maxPendingWatcherEntries)

        let cores = ProcessInfo.processInfo.activeProcessorCount
        maxParallelScansPerActor = dependencies.configuration.maxParallelScans ?? max(2, min(4, cores / 2))
        maxFoldersPerBatch = dependencies.configuration.maxFoldersPerBatch

        ignoreRules = try await ignoreRulesManager.getIgnoreRules(
            for: path,
            respectGitignore: respectGitignore,
            respectRepoIgnore: respectRepoIgnore,
            respectCursorignore: respectCursorignore
        )

        // Initialize root-level ignore rules in per-folder cache
        cacheIgnoreRules(ignoreRules, for: "")
    }

    #if DEBUG
        /// Test-only initializer that allows injecting initial state
        init(
            path: String,
            respectGitignore: Bool = true,
            respectRepoIgnore: Bool = true,
            respectCursorignore: Bool = true,
            skipSymlinks: Bool = true,
            enableHierarchicalIgnores: Bool = true,
            testVisitedPaths: Set<String>? = nil,
            testVisitedItems: [String: Bool]? = nil,
            testIgnoreRules: IgnoreRules? = nil,
            isTestMode: Bool = false,
            fileManagerOverride: (any FileSystemProviding)? = nil,
            maxParallelScansOverride: Int? = nil,
            maxFoldersPerBatchOverride: Int? = nil,
            maxPendingWatcherIngressEntriesOverride: Int? = nil,
            dependencies: WorkspaceRuntimeDependencies
        ) async throws {
            self.path = path
            rootURL = URL(fileURLWithPath: path).standardizedFileURL
            canonicalRootURL = rootURL.resolvingSymlinksInPath()
            self.respectGitignore = respectGitignore
            self.respectRepoIgnore = respectRepoIgnore
            self.respectCursorignore = respectCursorignore
            self.skipSymlinks = skipSymlinks
            self.enableHierarchicalIgnores = enableHierarchicalIgnores
            self.isTestMode = isTestMode
            self.fileManagerOverride = fileManagerOverride
            watcherFactory = dependencies.watcherFactory
            directoryListingBackend = dependencies.directoryListingBackend
            mutationBackend = dependencies.mutationBackend
            diagnostics = dependencies.diagnostics
            ignoreRulesManager = IgnoreRulesManager(globalIgnoreDefaults: dependencies.configuration.globalIgnoreDefaults)

            watcherIngressMailbox = FileSystemWatcherIngressMailbox(
                maxQueuedRawEntries: maxPendingWatcherIngressEntriesOverride ?? Self.maxPendingRawEvents
            )

            // Configure parallelism caps (allow test overrides)
            let cores = ProcessInfo.processInfo.activeProcessorCount
            maxParallelScansPerActor = maxParallelScansOverride ?? max(2, min(4, cores / 2))
            maxFoldersPerBatch = maxFoldersPerBatchOverride ?? 256

            // Use test data if provided
            if let paths = testVisitedPaths {
                visitedPaths = paths
            }
            if let items = testVisitedItems {
                visitedItems = items
            }

            // Use test ignore rules or load fresh ones
            if let rules = testIgnoreRules {
                ignoreRules = rules
            } else {
                #if DEBUG
                    // Pass the fileManagerOverride to IgnoreRulesManager if we have one
                    if let override = fileManagerOverride {
                        await ignoreRulesManager.setFileManagerOverride(override)
                    }
                #endif
                ignoreRules = try await ignoreRulesManager.getIgnoreRules(
                    for: path,
                    respectGitignore: respectGitignore,
                    respectRepoIgnore: respectRepoIgnore,
                    respectCursorignore: respectCursorignore
                )
            }

            // Initialize root-level ignore rules in per-folder cache
            cacheIgnoreRules(ignoreRules, for: "")
        }

    #endif
}
