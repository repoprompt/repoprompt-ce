import Combine
import CoreServices
import Dispatch
import Foundation
import RepoPromptDomainRuntime
#if DEBUG || EDIT_FLOW_PERF
    import os
#endif
import CoreFoundation
import Cuchardet
import UniversalCharsetDetection
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    import Darwin
#else
    import Glibc
#endif

package enum FileSystemUncancellableMutation: Equatable {
    case create
    case edit
    case move
    case delete
    case trash
}

/// Callback-owned invalidation that cannot be erased by a later actor stop/restart.
/// FSEvents may report EventIdsWrapped while the actor is suspended in an activation
/// cut; this gate records that fact synchronously on the callback side and also
/// serializes the synchronous seeded-publication linearization point.
package final class FileSystemServiceFSEventRecoveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var required = false
    private var handler: (@Sendable () -> Void)?

    /// Marks callback invalidation and removes the owner signal while holding the
    /// same lock used by publication permits. `whileLocked` is synchronous and
    /// must not perform actor hops or await work.
    package func markRequiredAndTakeHandler(
        whileLocked: (() -> Void)? = nil
    ) -> (@Sendable () -> Void)? {
        lock.lock()
        required = true
        whileLocked?()
        let handler = handler
        self.handler = nil
        lock.unlock()
        return handler
    }

    package func installHandler(_ handler: (@Sendable () -> Void)?) -> (@Sendable () -> Void)? {
        lock.lock()
        self.handler = handler
        let handlerToSignal: (@Sendable () -> Void)?
        if required {
            self.handler = nil
            handlerToSignal = handler
        } else {
            handlerToSignal = nil
        }
        lock.unlock()
        return handlerToSignal
    }

    package func clearHandler() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    package func takeHandler() -> (@Sendable () -> Void)? {
        lock.lock()
        let handler = handler
        self.handler = nil
        lock.unlock()
        return handler
    }

    package func acquirePublicationPermit() -> FileSystemServiceFSEventRecoveryPublicationPermit? {
        lock.lock()
        guard !required else {
            lock.unlock()
            return nil
        }
        return FileSystemServiceFSEventRecoveryPublicationPermit(gate: self)
    }

    fileprivate func releasePublicationPermit() {
        lock.unlock()
    }

    /// Serializes stream-generation invalidation with publication permits.
    /// The closure is synchronous and must not perform actor hops or await work.
    @discardableResult
    package func withRecoveryLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Starts a stream-local generation transition only if callback recovery has
    /// not already won the service cut.
    package func withRecoveryLockIfClear<T>(_ body: () -> T) -> T? {
        lock.lock()
        guard !required else {
            lock.unlock()
            return nil
        }
        defer { lock.unlock() }
        return body()
    }

    package var isRequired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return required
    }
}

/// Owns one service's recovery lock until the synchronous publication assignment
/// has completed. Locks are acquired by the owning store in deterministic token
/// order and released in reverse order.
package final class FileSystemServiceFSEventRecoveryPublicationPermit: @unchecked Sendable {
    private let gate: FileSystemServiceFSEventRecoveryGate
    private var released = false

    fileprivate init(gate: FileSystemServiceFSEventRecoveryGate) {
        self.gate = gate
    }

    package func release() {
        guard !released else { return }
        released = true
        gate.releasePublicationPermit()
    }

    deinit {
        release()
    }
}

/// A one-shot callback-side signal for the owning store. The handler is held by
/// the same recovery coordinator as the publication permit, so installation,
/// callback invalidation, and clearing cannot cross the publication cut.
package final class FileSystemServiceFSEventRecoverySignal: @unchecked Sendable {
    private let gate: FileSystemServiceFSEventRecoveryGate

    package init(gate: FileSystemServiceFSEventRecoveryGate) {
        self.gate = gate
    }

    package func install(_ handler: (@Sendable () -> Void)?) {
        let handlerToSignal = gate.installHandler(handler)
        // A handler installed after callback invalidation must not miss the
        // sticky recovery notification. Signal only after releasing the lock.
        handlerToSignal?()
    }

    package func clear() {
        gate.clearHandler()
    }

    package func signalOnce() {
        let handler = gate.takeHandler()
        handler?()
    }
}

package struct FileSystemMutationWaiter {
    package let continuation: CheckedContinuation<Void, any Error>
    package init(continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }
}

package struct FileSystemInFlightMutation {
    package let relativePaths: Set<String>
    package init(relativePaths: Set<String>) {
        self.relativePaths = relativePaths
    }
}

package struct FileSystemMutationDrainWaiter {
    package let relativePaths: Set<String>
    package let continuation: CheckedContinuation<Void, Never>
    package init(relativePaths: Set<String>, continuation: CheckedContinuation<Void, Never>) {
        self.relativePaths = relativePaths
        self.continuation = continuation
    }
}

package struct FileSystemExplicitlyManagedIgnoredRegistrationState {
    package let priorVisitedPathMembership: Bool
    package let priorVisitedItem: Bool?
    package let priorCatalogOwnership: Bool
    package let priorWatcherOwnership: Bool
    package var pendingOwnerIDs: Set<UUID>
    package var hasCommittedIgnoredOwner: Bool
    package var hasCommittedEligibleOwner: Bool
    package init(priorVisitedPathMembership: Bool, priorVisitedItem: Bool?, priorCatalogOwnership: Bool, priorWatcherOwnership: Bool, pendingOwnerIDs: Set<UUID>, hasCommittedIgnoredOwner: Bool, hasCommittedEligibleOwner: Bool) {
        self.priorVisitedPathMembership = priorVisitedPathMembership
        self.priorVisitedItem = priorVisitedItem
        self.priorCatalogOwnership = priorCatalogOwnership
        self.priorWatcherOwnership = priorWatcherOwnership
        self.pendingOwnerIDs = pendingOwnerIDs
        self.hasCommittedIgnoredOwner = hasCommittedIgnoredOwner
        self.hasCommittedEligibleOwner = hasCommittedEligibleOwner
    }
}

package enum FileSystemMutationCompletion {
    case success
    case failure(any Error)

    package func get() throws {
        switch self {
        case .success:
            return
        case let .failure(error):
            throw error
        }
    }
}

package final class FileSystemServiceFSEventCallbackContext: @unchecked Sendable {
    package let deliveryGeneration: FSEventAsyncDeliveryBarrier.Generation
    package let streamGeneration: UInt64
    package let ingressGeneration: UInt64

    private let lock = NSLock()
    private weak var storedService: FileSystemService?

    package init(
        service: FileSystemService,
        deliveryGeneration: FSEventAsyncDeliveryBarrier.Generation,
        streamGeneration: UInt64,
        ingressGeneration: UInt64
    ) {
        storedService = service
        self.deliveryGeneration = deliveryGeneration
        self.streamGeneration = streamGeneration
        self.ingressGeneration = ingressGeneration
    }

    package var service: FileSystemService? {
        lock.withLock { storedService }
    }

    package func detach() {
        lock.withLock { storedService = nil }
    }
}

package final class FileSystemServiceFSEventCallbackReleaseHandle: @unchecked Sendable {
    private let callbackContextPointer: UnsafeMutableRawPointer

    package init(callbackContextPointer: UnsafeMutableRawPointer) {
        self.callbackContextPointer = callbackContextPointer
    }

    package func finish() {
        Unmanaged<FileSystemServiceFSEventCallbackContext>
            .fromOpaque(callbackContextPointer)
            .release()
    }
}

package final class FileSystemServiceFSEventTeardownHandle: @unchecked Sendable {
    private let stream: FSEventStreamRef
    private let callbackContextPointer: UnsafeMutableRawPointer?

    package init(
        stream: FSEventStreamRef,
        callbackContextPointer: UnsafeMutableRawPointer?
    ) {
        self.stream = stream
        self.callbackContextPointer = callbackContextPointer
    }

    package func finish() {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        if let callbackContextPointer {
            Unmanaged<FileSystemServiceFSEventCallbackContext>
                .fromOpaque(callbackContextPointer)
                .release()
        }
    }
}

package actor FileSystemService {
    // Internal for FileSystemService same-target extensions only.
    // These are not public API; preserve actor isolation when accessing them.
    package let fileManager = FileManager.default
    package nonisolated let diagnosticRootToken = UUID()
    package nonisolated let watcherIngressMailbox: FileSystemWatcherIngressMailbox
    package nonisolated let watcherEarlyFilter: FileSystemWatcherEarlyFilter
    package nonisolated let fseventDeliveryBarrier = FSEventAsyncDeliveryBarrier()
    package nonisolated let fseventRecoveryGate = FileSystemServiceFSEventRecoveryGate()
    package nonisolated var fseventRecoverySignal: FileSystemServiceFSEventRecoverySignal {
        FileSystemServiceFSEventRecoverySignal(gate: fseventRecoveryGate)
    }

    package nonisolated let fseventCallbackQueue = DispatchQueue(
        label: "com.repoprompt.filesystem.fsevents.\(UUID().uuidString)",
        qos: .utility
    )
    package static let maxPendingRawEvents = 50000
    package static let overflowRescanEventFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
    )

    #if DEBUG
        /// Static flag to enable verbose debug logging (default: false)
        package static var enableDebugLogging = false
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
        watcherAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark? = nil,
        requiresFullResync: Bool = false
    ) -> UInt64 {
        guard !deltas.isEmpty || watcherAcceptedWatermark != nil || requiresFullResync || source == .watcherBarrierNoop else {
            return lastServicePublicationSequence
        }
        nextServicePublicationSequence &+= 1
        let servicePublicationSequence = nextServicePublicationSequence
        lastServicePublicationSequence = servicePublicationSequence
        if let watcherAcceptedWatermark {
            lastPublishedWatcherAcceptedWatermark = max(lastPublishedWatcherAcceptedWatermark, watcherAcceptedWatermark)
        }
        recordSeedReplayPublication(
            source: source,
            watcherAcceptedWatermark: watcherAcceptedWatermark,
            requiresFullResync: requiresFullResync,
            deltas: deltas,
            servicePublicationSequence: servicePublicationSequence
        )
        let publication = FileSystemDeltaPublication(
            servicePublicationSequence: servicePublicationSequence,
            source: source,
            watcherAcceptedWatermark: watcherAcceptedWatermark,
            requiresFullResync: requiresFullResync,
            deltas: deltas
        )
        #if DEBUG
            FileSystemRuntimeHooks.current.servicePublication(
                diagnosticRootToken,
                source,
                deltas
            )
        #endif
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
        package var fileManagerOverride: (any FileSystemProviding)?

        /// Returns the appropriate filesystem provider (debug override or default)
        package var fm: any FileSystemProviding {
            fileManagerOverride ?? fileManager
        }
    #else
        /// In release builds, always use FileManager.default
        package var fm: FileManager {
            fileManager
        }
    #endif

    #if DEBUG
        /// Flag to enable test mode
        package var isTestMode = false

        /// Test-only tracking of processed events
        package var processedFolders: Set<String> = []
        package var processedFolderBatches: [[String]] = []

        /// Test-only method to mock directory contents
        package var mockDirectoryContents: ((String) -> [String])?

        /// Test-only gate after a watcher batch leaves the pending buffer but before processing.
        package var watcherBatchWillProcessHandler: (@Sendable () async -> Void)?

        /// Test-only hook invoked inside the real-filesystem off-actor content worker before each read.
        package var contentReadChunkHandler: (@Sendable (String) async -> Void)?
        /// Test-only synchronous gate immediately before fingerprint validation begins.
        package var contentPhysicalReadHandler: (@Sendable () throws -> Void)?
        /// Test-only asynchronous gate immediately before a decoded-content cache commit.
        package var contentReadCacheCommitHandler: (@Sendable () async -> Void)?
        package var contentFingerprintRequestCountForTesting = 0
        package var cachedSearchContentWatcherActiveOverrideForTesting: Bool?

        /// Test-only hook invoked inside each real-filesystem parallel folder enumeration worker.
        package var parallelFolderEnumerationHookForTesting: (@Sendable (String) async throws -> Void)?

        /// Test-only barrier immediately before namespace-manifest authority fencing.
        package var workspaceRootNamespaceEnumerationWillFinishHandler: (@Sendable () async -> Void)?

        /// Test-only gate invoked before a mutation is submitted to the blocking-I/O queue.
        package var mutationIOWillBeginHandler: (@Sendable (FileSystemUncancellableMutation) async -> Void)?

        /// Test-only synchronous gate invoked on the blocking-I/O queue immediately before filesystem I/O.
        package var mutationIOWillExecuteHandler: (@Sendable (FileSystemUncancellableMutation) -> Void)?

        /// Test-only gate immediately before the request installs its mutation waiter.
        package var mutationWaiterWillRegisterHandler: (@Sendable (FileSystemUncancellableMutation) async -> Void)?

        /// Test-only replacement for UTF-8 materialization inside the detached create worker.
        package var createFileDataPreparationForTesting: (@Sendable (String) async throws -> Data)?

        /// Test-only result override for the exclusive create publication primitive.
        /// Zero reports success; a non-zero value is the simulated errno.
        package var createFileExclusiveRenameForTesting: (@Sendable (String, String) -> Int32)?

        /// Test-only errno injected after a successful POSIX create open and before writing.
        package var createFilePOSIXFailureAfterOpenForTesting: Int32?

        /// Test-only failure/replacement hook invoked after the fallback destination O_EXCL open.
        package var createFileFallbackPOSIXFailureAfterOpenForTesting: (@Sendable (String) -> Int32)?

        /// Test-only replacement for the real Finder Trash operation.
        package var moveItemToTrashIOForTesting: (@Sendable (URL) throws -> Void)?

        package enum WatcherActivationFailurePoint {
            case streamCreation
            case streamStart
        }

        package var watcherActivationFailurePointForTesting: WatcherActivationFailurePoint?
        package var seededPublicationActivationShouldFailForTesting = false
        package var folderScanFailuresRemainingForTesting: [String: Int] = [:]
    #endif

    /// Request waiters are actor-owned and may be cancelled independently from detached filesystem I/O.
    package var mutationWaiters: [UUID: FileSystemMutationWaiter] = [:]
    /// In-flight records retain normalized path authority until the sole detached reconciler completes.
    package var inFlightMutations: [UUID: FileSystemInFlightMutation] = [:]
    package var mutationDrainWaiters: [UUID: FileSystemMutationDrainWaiter] = [:]
    /// A detached mutation may reconcile before its request installs a waiter. Retain that
    /// terminal result so the request consumes it instead of waiting forever.
    package var mutationCompletionMailbox: [UUID: FileSystemMutationCompletion] = [:]
    /// Cancellation wins over a later uncancellable I/O completion, which must still reconcile
    /// but must not leave an unconsumed mailbox entry.
    package var cancelledMutationWaiterIDs: Set<UUID> = []
    /// Finder Trash can remove the source promptly but keep `trashItem` blocked for tens of
    /// seconds. The first terminal observer owns reconciliation for each trash mutation.
    package var trashMutationsAwaitingReconciliation: Set<UUID> = []
    package var deferredEditPublicationsByMutationID: [UUID: FileSystemDeferredEditPublication] = [:]
    #if DEBUG
        package var completedMutationMonitorCountForTesting = 0
    #endif

    /// Tracks paths we know about, to detect additions/removals. Ordinary roots
    /// keep the legacy in-memory representation; seeded roots retain their
    /// authenticated spill manifest and only overlay post-cut mutations.
    package let visitedInventory = FileSystemVisitedInventory()
    package lazy var visitedPaths = visitedInventory.paths

    /// Ignored regular files retained only because an explicit app/MCP request manages them.
    /// Ordinary catalog files that later become ignored must not acquire this provenance.
    package var explicitlyManagedIgnoredFilePaths = Set<String>()
    package var explicitlyManagedIgnoredRegistrationStates: [String: FileSystemExplicitlyManagedIgnoredRegistrationState] = [:]

    /// True => directory, False => file
    package lazy var visitedItems = visitedInventory.items

    /// The FSEvent stream reference
    package var fseventStreamRef: FSEventStreamRef?
    package var fseventStreamGeneration: UInt64 = 0
    /// The last durable FSEvents journal cut. Captured before the initial crawl so
    /// watcher startup can replay mutations that happen while the crawl is running.
    package var nextFSEventStreamStartEventID: FSEventStreamEventId

    /// Publishes ordered delta envelopes whenever changes or watcher progress occur.
    package var changePublisher = PassthroughSubject<FileSystemDeltaPublication, Never>()
    package var nextServicePublicationSequence: UInt64 = 0
    package var lastServicePublicationSequence: UInt64 = 0
    package var lastPublishedWatcherAcceptedWatermark = FileSystemWatcherIngressMailbox.Watermark.zero
    package var seedInitializationState: FileSystemSeedInitializationState?
    #if DEBUG
        package struct FreshnessWorkDiagnosticsSnapshot: Equatable {
            package let flushCallCount: Int
            package let noopFlushCount: Int
            package let debounceCancellationCount: Int
            package let watcherBatchCount: Int
            package let watcherBatchEventCount: Int
            package let lastWatcherBatchSize: Int
            package let maxWatcherBatchSize: Int
        }

        package var lastPublishedDeltaCoalescingDiagnostics: PublishedDeltaCoalescingDiagnostics?
        package var freshnessFlushCallCount = 0
        package var freshnessNoopFlushCount = 0
        package var freshnessDebounceCancellationCount = 0
        package var freshnessWatcherBatchCount = 0
        package var freshnessWatcherBatchEventCount = 0
        package var freshnessLastWatcherBatchSize = 0
        package var freshnessMaxWatcherBatchSize = 0
    #endif

    /// Retained FSEvent callback context. The context holds the service weakly so an
    /// un-stopped stream cannot keep the actor alive forever.
    package var fseventCallbackContextPointer: UnsafeMutableRawPointer?

    /// The in-memory IgnoreRules instance for our path
    package var ignoreRules: IgnoreRules
    package var catalogPolicyIdentity: WorkspaceRootCatalogPolicyIdentity

    package var ignoreCacheStore = IgnoreCacheStore()

    /// Caches the detected encoding for every file we have successfully opened
    package var encodingMap = [String: String.Encoding]()
    /// A read may cache its detected encoding only while no newer filesystem invalidation is known.
    package var contentReadCacheRevision: UInt64 = 0

    /// Path we are managing
    package nonisolated let path: String
    package nonisolated let rootURL: URL
    package nonisolated let canonicalRootURL: URL
    package nonisolated let mutationAuthorityUsesCaseSensitiveNames: Bool
    package nonisolated let ignoreRulePolicy: IgnoreRulePolicy
    package let ignoreRulesManager: IgnoreRulesManager
    package var canonicalRootPath: String {
        canonicalRootURL.path
    }

    package var standardizedRootPath: String {
        rootURL.path
    }

    deinit {
        stopFSEventStream()
    }

    package var respectRepoIgnore: Bool
    package var respectCursorignore: Bool
    package var skipSymlinks: Bool
    package var enableHierarchicalIgnores: Bool

    // MARK: - Ignore rules change tracking (revision-based for durability)

    /// Monotonic revision incremented each time ignore files change
    package var ignoreRulesRevision: UInt64 = 0
    package var pendingIgnoreRulesRebuildCount = 0
    /// Directories affected by ignore file changes since last consumption
    package var pendingIgnoreChangeDirs: Set<String> = []

    // A buffer for raw FSEvents + coalescing logic
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
    /// Once FSEvents reports EventIdsWrapped, this service cannot establish a
    /// valid continuation of its existing stream. Keep it unavailable until a
    /// fresh service/root activation establishes a new stream-scoped cut.
    package var fseventRecoveryRequired = false
    package let coalescingDelay: TimeInterval = 0.2

    // MARK: - Event ID-based scan coalescing (prevents dropped events while deduping bursts)

    /// Maps folder relative path → highest FSEvent ID that requires scanning
    package var pendingScanTargets: [String: FSEventStreamEventId] = [:]
    /// Maps folder relative path → highest FSEvent ID that has already been scanned
    package var lastScannedEventIdByFolder: [String: FSEventStreamEventId] = [:]
    /// Cap-omitted folders that must be scanned by quiet follow-up watcher batches.
    package var pendingQuietFolderScanTargets: Set<String> = []
    /// Recovery targets that failed both parallel and immediate serial scanning.
    /// Their accepted watcher cut remains unpublished until retry or full resync.
    package var dirtyRecoveryScanTargets: Set<String> = []
    package var recoveryScanFailureCountByFolder: [String: Int] = [:]
    package var recoveryScanRetryTask: Task<Void, Never>?

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
    package let maxRecoveryScanAttempts: Int
    package let recoveryScanRetryBaseNanoseconds: UInt64
    package let recoveryScanSleep: @Sendable (UInt64) async -> Void

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

    /// Initializes the FileSystemService for a given path, applying ignore rules and capturing
    /// an FSEvents replay cut before the caller begins the initial crawl.
    package init(
        path: String,
        respectRepoIgnore: Bool = true,
        respectCursorignore: Bool = true,
        skipSymlinks: Bool = true,
        enableHierarchicalIgnores: Bool = true,
        ignoreRulesManager: IgnoreRulesManager
    ) async throws {
        self.path = path
        let resolvedRootURL = URL(fileURLWithPath: path).standardizedFileURL
        rootURL = resolvedRootURL
        canonicalRootURL = resolvedRootURL.resolvingSymlinksInPath()
        mutationAuthorityUsesCaseSensitiveNames = (try? resolvedRootURL.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]
        ).volumeSupportsCaseSensitiveNames) ?? false
        ignoreRulePolicy = try ignoreRulesManager.resolvingLoadedRoot(resolvedRootURL)
        self.ignoreRulesManager = ignoreRulesManager
        self.respectRepoIgnore = respectRepoIgnore
        self.respectCursorignore = respectCursorignore
        self.skipSymlinks = skipSymlinks
        self.enableHierarchicalIgnores = enableHierarchicalIgnores

        watcherIngressMailbox = FileSystemWatcherIngressMailbox(maxQueuedRawEntries: Self.maxPendingRawEvents)
        watcherEarlyFilter = FileSystemWatcherEarlyFilter(rootPath: path)
        nextFSEventStreamStartEventID = FSEventsGetCurrentEventId()

        // Configure parallelism caps based on available cores
        let cores = ProcessInfo.processInfo.activeProcessorCount
        maxParallelScansPerActor = max(2, min(4, cores / 2))
        maxFoldersPerBatch = 256
        maxRecoveryScanAttempts = 3
        recoveryScanRetryBaseNanoseconds = 50_000_000
        recoveryScanSleep = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }

        // Load fresh ignore rules and the exact global-policy provenance together.
        let resolvedIgnoreRules = try await ignoreRulesManager.resolvedIgnoreRules(
            for: path,
            respectRepoIgnore: respectRepoIgnore,
            respectCursorignore: respectCursorignore,
            policy: ignoreRulePolicy
        )
        ignoreRules = resolvedIgnoreRules.rules
        catalogPolicyIdentity = WorkspaceRootCatalogPolicyIdentity(
            schemaVersion: WorkspaceRootCatalogPolicyIdentity.currentSchemaVersion,
            mandatoryIgnorePolicyIdentity: WorkspaceGitignorePolicyIdentity.current.rawValue,
            globalIgnoreDefaultsDigest: resolvedIgnoreRules.globalIgnoreDefaultsDigest,
            respectRepoIgnore: respectRepoIgnore,
            respectCursorignore: respectCursorignore,
            enableHierarchicalIgnores: enableHierarchicalIgnores,
            skipSymlinks: skipSymlinks
        )

        // Initialize root-level ignore rules in per-folder cache
        cacheIgnoreRules(ignoreRules, for: "")
        watcherEarlyFilter.install(ignoreRules.snapshot(), generation: watcherEarlyFilter.currentGeneration())
    }

    #if DEBUG
        package func setMutationIOWillBeginHandlerForTesting(
            _ handler: (@Sendable (FileSystemUncancellableMutation) async -> Void)?
        ) {
            mutationIOWillBeginHandler = handler
        }

        package func setMutationIOWillExecuteHandlerForTesting(
            _ handler: (@Sendable (FileSystemUncancellableMutation) -> Void)?
        ) {
            mutationIOWillExecuteHandler = handler
        }

        package func setMutationWaiterWillRegisterHandlerForTesting(
            _ handler: (@Sendable (FileSystemUncancellableMutation) async -> Void)?
        ) {
            mutationWaiterWillRegisterHandler = handler
        }

        package func setCreateFileDataPreparationForTesting(
            _ preparation: (@Sendable (String) async throws -> Data)?
        ) {
            createFileDataPreparationForTesting = preparation
        }

        package func setCreateFileExclusiveRenameForTesting(
            _ operation: (@Sendable (String, String) -> Int32)?
        ) {
            createFileExclusiveRenameForTesting = operation
        }

        package func setCreateFilePOSIXFailureAfterOpenForTesting(_ errorNumber: Int32?) {
            createFilePOSIXFailureAfterOpenForTesting = errorNumber
        }

        package func setCreateFileFallbackPOSIXFailureAfterOpenForTesting(
            _ handler: (@Sendable (String) -> Int32)?
        ) {
            createFileFallbackPOSIXFailureAfterOpenForTesting = handler
        }

        package func setMoveItemToTrashIOForTesting(_ operation: (@Sendable (URL) throws -> Void)?) {
            moveItemToTrashIOForTesting = operation
        }

        package func setWorkspaceRootNamespaceEnumerationWillFinishHandlerForTesting(
            _ handler: (@Sendable () async -> Void)?
        ) {
            workspaceRootNamespaceEnumerationWillFinishHandler = handler
        }

        package func setPendingIgnoreRulesRebuildCountForTesting(_ count: Int) {
            pendingIgnoreRulesRebuildCount = count
        }

        package func pendingMutationWaiterCountForTesting() -> Int {
            mutationWaiters.count
        }

        package func pendingInFlightMutationCountForTesting() -> Int {
            inFlightMutations.count
        }

        package func pendingMutationDrainWaiterCountForTesting() -> Int {
            mutationDrainWaiters.count
        }

        package func mutationMonitorCompletionCountForTesting() -> Int {
            completedMutationMonitorCountForTesting
        }

        package func pendingMutationCompletionCountForTesting() -> Int {
            mutationCompletionMailbox.count
        }

        package func pendingDeferredEditPublicationCountForTesting() -> Int {
            deferredEditPublicationsByMutationID.count
        }

        /// Test-only initializer that allows injecting initial state
        package init(
            path: String,
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
            maxRecoveryScanAttemptsOverride: Int? = nil,
            recoveryScanRetryBaseNanosecondsOverride: UInt64? = nil,
            recoveryScanSleep: @escaping @Sendable (UInt64) async -> Void = { nanoseconds in
                try? await Task.sleep(nanoseconds: nanoseconds)
            },
            ignoreRulesManager: IgnoreRulesManager
        ) async throws {
            self.path = path
            let resolvedRootURL = URL(fileURLWithPath: path).standardizedFileURL
            rootURL = resolvedRootURL
            canonicalRootURL = resolvedRootURL.resolvingSymlinksInPath()
            mutationAuthorityUsesCaseSensitiveNames = (try? resolvedRootURL.resourceValues(
                forKeys: [.volumeSupportsCaseSensitiveNamesKey]
            ).volumeSupportsCaseSensitiveNames) ?? false
            ignoreRulePolicy = try ignoreRulesManager.resolvingLoadedRoot(resolvedRootURL)
            self.ignoreRulesManager = ignoreRulesManager
            self.respectRepoIgnore = respectRepoIgnore
            self.respectCursorignore = respectCursorignore
            self.skipSymlinks = skipSymlinks
            self.enableHierarchicalIgnores = enableHierarchicalIgnores
            self.isTestMode = isTestMode
            self.fileManagerOverride = fileManagerOverride

            watcherIngressMailbox = FileSystemWatcherIngressMailbox(
                maxQueuedRawEntries: maxPendingWatcherIngressEntriesOverride ?? Self.maxPendingRawEvents
            )
            watcherEarlyFilter = FileSystemWatcherEarlyFilter(rootPath: path)
            nextFSEventStreamStartEventID = FSEventsGetCurrentEventId()

            // Configure parallelism caps (allow test overrides)
            let cores = ProcessInfo.processInfo.activeProcessorCount
            maxParallelScansPerActor = maxParallelScansOverride ?? max(2, min(4, cores / 2))
            maxFoldersPerBatch = maxFoldersPerBatchOverride ?? 256
            maxRecoveryScanAttempts = max(1, maxRecoveryScanAttemptsOverride ?? 3)
            recoveryScanRetryBaseNanoseconds = recoveryScanRetryBaseNanosecondsOverride ?? 50_000_000
            self.recoveryScanSleep = recoveryScanSleep

            // Use test data if provided.
            if testVisitedPaths != nil || testVisitedItems != nil {
                visitedInventory.installOrdinary(
                    paths: testVisitedPaths ?? [],
                    items: testVisitedItems ?? [:]
                )
            }

            // Use test ignore rules or load fresh rules with their exact global-policy provenance.
            if let rules = testIgnoreRules {
                ignoreRules = rules
                catalogPolicyIdentity = await WorkspaceRootCatalogPolicyIdentity(
                    schemaVersion: WorkspaceRootCatalogPolicyIdentity.currentSchemaVersion,
                    mandatoryIgnorePolicyIdentity: WorkspaceGitignorePolicyIdentity.current.rawValue,
                    globalIgnoreDefaultsDigest: IgnoreRulesManager.globalIgnoreDefaultsDigest(
                        for: ignoreRulesManager.resolvedGlobalIgnoreContent()
                    ),
                    respectRepoIgnore: respectRepoIgnore,
                    respectCursorignore: respectCursorignore,
                    enableHierarchicalIgnores: enableHierarchicalIgnores,
                    skipSymlinks: skipSymlinks
                )
            } else {
                #if DEBUG
                    // Pass the fileManagerOverride to IgnoreRulesManager if we have one
                    if let override = fileManagerOverride {
                        await ignoreRulesManager.setFileManagerOverride(override)
                    }
                #endif
                let resolvedIgnoreRules = try await ignoreRulesManager.resolvedIgnoreRules(
                    for: path,
                    respectRepoIgnore: respectRepoIgnore,
                    respectCursorignore: respectCursorignore,
                    policy: ignoreRulePolicy
                )
                ignoreRules = resolvedIgnoreRules.rules
                catalogPolicyIdentity = WorkspaceRootCatalogPolicyIdentity(
                    schemaVersion: WorkspaceRootCatalogPolicyIdentity.currentSchemaVersion,
                    mandatoryIgnorePolicyIdentity: WorkspaceGitignorePolicyIdentity.current.rawValue,
                    globalIgnoreDefaultsDigest: resolvedIgnoreRules.globalIgnoreDefaultsDigest,
                    respectRepoIgnore: respectRepoIgnore,
                    respectCursorignore: respectCursorignore,
                    enableHierarchicalIgnores: enableHierarchicalIgnores,
                    skipSymlinks: skipSymlinks
                )
            }

            // Initialize root-level ignore rules in per-folder cache
            cacheIgnoreRules(ignoreRules, for: "")
            watcherEarlyFilter.install(ignoreRules.snapshot(), generation: watcherEarlyFilter.currentGeneration())
        }

    #endif
}
