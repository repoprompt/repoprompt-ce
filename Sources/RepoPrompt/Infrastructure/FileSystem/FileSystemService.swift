import Combine
import Dispatch
import Foundation

actor FileSystemService {
    // Internal for FileSystemService same-target extensions only.
    // These are not public API; preserve actor isolation when accessing them.
    let fileManager = FileManager.default
    nonisolated let diagnosticRootToken = UUID()
    nonisolated let watcherIngressMailbox: FileSystemWatcherIngressMailbox
    static let maxPendingRawEvents = 50000
    static let overflowRescanEventFlags = FileSystemWatchEventFlags.overflowRootRescan

    #if DEBUG
        /// Static flag to enable verbose debug logging (default: false)
        static var enableDebugLogging = false
    #endif

    func fileSystemDebugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
            guard Self.enableDebugLogging else { return }
            print(message())
        #endif
    }

    @discardableResult
    func publishFileSystemDeltas(
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
        let publication = FileSystemDeltaPublication(
            servicePublicationSequence: servicePublicationSequence,
            source: source,
            watcherAcceptedWatermark: watcherAcceptedWatermark,
            deltas: deltas
        )
        #if DEBUG || EDIT_FLOW_PERF
            let publicationCorrelation = EditFlowPerf.makeLifecycleCorrelationIfActive()
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.FileSystem.servicePublish,
                correlation: publicationCorrelation,
                EditFlowPerf.Dimensions(
                    status: source.rawValue,
                    changeCount: deltas.count,
                    rootToken: diagnosticRootToken.uuidString,
                    ingressSequence: watcherAcceptedWatermark?.rawValue,
                    barrierSequence: servicePublicationSequence
                )
            )
            guard let publicationCorrelation else {
                changePublisher.send(publication)
                return servicePublicationSequence
            }
            EditFlowPerf.$currentFileSystemPublicationCorrelation.withValue(publicationCorrelation) {
                changePublisher.send(publication)
            }
        #else
            changePublisher.send(publication)
        #endif
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
    var visitedPaths = Set<String>()

    /// True => directory, False => file
    var visitedItems = [String: Bool]()

    /// Injected platform watcher. Core policy stores no native watcher reference.
    let watcherFactory: any FileSystemWatcherCreating
    var watcher: (any FileSystemWatching)?

    /// Publishes ordered delta envelopes whenever changes or watcher progress occur.
    var changePublisher = PassthroughSubject<FileSystemDeltaPublication, Never>()
    var nextServicePublicationSequence: UInt64 = 0
    var lastServicePublicationSequence: UInt64 = 0
    var lastPublishedWatcherAcceptedWatermark = FileSystemWatcherIngressMailbox.Watermark.zero
    #if DEBUG
        var lastPublishedDeltaCoalescingDiagnostics: PublishedDeltaCoalescingDiagnostics?
    #endif

    /// The in-memory IgnoreRules instance for our path
    var ignoreRules: IgnoreRules

    var ignoreCacheStore = IgnoreCacheStore()

    /// Caches the detected encoding for every file we have successfully opened
    var encodingMap = [String: String.Encoding]()

    /// Path we are managing
    let path: String
    let rootURL: URL
    let canonicalRootURL: URL
    var canonicalRootPath: String {
        canonicalRootURL.path
    }

    var standardizedRootPath: String {
        rootURL.path
    }

    var respectGitignore: Bool
    var respectRepoIgnore: Bool
    var respectCursorignore: Bool
    var skipSymlinks: Bool
    var enableHierarchicalIgnores: Bool

    // MARK: - Ignore rules change tracking (revision-based for durability)

    /// Monotonic revision incremented each time ignore files change
    var ignoreRulesRevision: UInt64 = 0
    /// Directories affected by ignore file changes since last consumption
    var pendingIgnoreChangeDirs: Set<String> = []

    // A buffer for semantic watcher events + coalescing logic
    var pendingFSEvents: [PendingFSEvent] = []
    var pendingWatcherAcceptedHighWatermark: FileSystemWatcherIngressMailbox.Watermark?
    var pendingWatcherPublicationSource: FileSystemDeltaPublicationSource = .watcher
    var hasPendingOverflowRescan = false
    var overflowChangedIgnoreDirs: Set<String> = []
    var coalescingTask: Task<Void, Never>?
    var watcherBatchProcessingTask: Task<Void, Never>?
    var watcherBatchProcessingToken: UInt64?
    var nextWatcherBatchProcessingToken: UInt64 = 0
    var watcherIngressGeneration: UInt64 = 0
    let coalescingDelay: TimeInterval = 0.2

    // MARK: - Event ID-based scan coalescing (prevents dropped events while deduping bursts)

    /// Maps folder relative path → highest watcher event ID that requires scanning
    var pendingScanTargets: [String: FileSystemWatchEventID] = [:]
    /// Maps folder relative path → highest watcher event ID that has already been scanned
    var lastScannedEventIdByFolder: [String: FileSystemWatchEventID] = [:]

    /// Short-lived cache
    /// results during a directory walk to avoid repeated allocations.
    var pathCompsCache = PathComponentsCache()

    /// Maximum number of cached ignore rules (default: 4000)
    static let ignoreCacheCapacity = 4000

    /// Cache for per-folder ignore rules (key = directory's relative path, "" for root)
    var perFolderIgnoreCache = LRUCache<String, IgnoreRules>(
        capacity: FileSystemService.ignoreCacheCapacity
    )

    /// Bounded marker cache for directories that have no ignore files.
    /// Eviction is safe: it only causes an extra filesystem recheck.
    var noIgnoreFileCache = LRUCache<String, Bool>(
        capacity: FileSystemService.ignoreCacheCapacity
    )

    // MARK: - Parallelism Throttling

    /// Maximum concurrent directory scans per actor (prevents CPU saturation)
    let maxParallelScansPerActor: Int

    /// Maximum folders to scan in a single batch (bounds per-tick work)
    let maxFoldersPerBatch: Int

    // MARK: - Safety-Net Verification

    /// Minimum interval between safety-net scans for the same folder (seconds)
    let safetyNetMinInterval: TimeInterval = 300 // 5 minutes

    /// Number of file events before triggering a safety-net parent scan
    let safetyNetEventThreshold: Int = 200

    /// Tracks when each folder was last verified via directory scan
    var lastVerifiedAtByFolder: [String: TimeInterval] = [:]

    /// Tracks file event count per folder since last verification
    var fileEventCountSinceLastScan: [String: Int] = [:]

    // MARK: - Init

    /// Initializes the FileSystemService for a given path, applying ignore rules, optionally skipping symlinks,
    /// and preparing an injected watcher to track changes in that path.
    init(
        path: String,
        respectGitignore: Bool = true,
        respectRepoIgnore: Bool = true,
        respectCursorignore: Bool = true,
        skipSymlinks: Bool = true,
        enableHierarchicalIgnores: Bool = true,
        watcherFactory: any FileSystemWatcherCreating = MacOSFSEventsWatcherFactory()
    ) async throws {
        self.path = path
        rootURL = URL(fileURLWithPath: path).standardizedFileURL
        canonicalRootURL = rootURL.resolvingSymlinksInPath()
        self.respectGitignore = respectGitignore
        self.respectRepoIgnore = respectRepoIgnore
        self.respectCursorignore = respectCursorignore
        self.skipSymlinks = skipSymlinks
        self.enableHierarchicalIgnores = enableHierarchicalIgnores
        self.watcherFactory = watcherFactory

        watcherIngressMailbox = FileSystemWatcherIngressMailbox(maxQueuedRawEntries: Self.maxPendingRawEvents)

        // Configure parallelism caps based on available cores
        let cores = ProcessInfo.processInfo.activeProcessorCount
        maxParallelScansPerActor = max(2, min(4, cores / 2))
        maxFoldersPerBatch = 256

        // Load fresh ignore rules from manager, no caching done by manager
        ignoreRules = try await IgnoreRulesManager.shared.getIgnoreRules(
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
            watcherFactory: any FileSystemWatcherCreating = MacOSFSEventsWatcherFactory()
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
            self.watcherFactory = watcherFactory

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
                        await IgnoreRulesManager.shared.setFileManagerOverride(override)
                    }
                #endif
                ignoreRules = try await IgnoreRulesManager.shared.getIgnoreRules(
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
