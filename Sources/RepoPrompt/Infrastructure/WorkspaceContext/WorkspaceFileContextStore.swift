import Combine
import CoreServices
import Dispatch
import Foundation
#if DEBUG
    import CryptoKit
#endif

enum WorkspaceFileTreePresentationMode: String {
    case none
    case selected
    case full
    case folders
    case auto

    init(fileTreeOption: FileTreeOption) {
        switch fileTreeOption {
        case .none:
            self = .none
        case .selected:
            self = .selected
        case .files:
            self = .full
        case .auto:
            self = .auto
        }
    }
}

typealias WorkspaceFileTreeSnapshotMode = WorkspaceFileTreePresentationMode

struct WorkspaceBoundedFolderExpansionResult: Equatable {
    let files: [WorkspaceFileRecord]
    let handled: Bool
    let displayPath: String?
    let issue: PathResolutionIssue?
    let didExceedLimit: Bool
    let visitedUniqueFileCount: Int
}

struct WorkspaceBoundedCodeStructureFileResolution: Equatable {
    let files: [WorkspaceFileRecord]
    let didExceedLimit: Bool
    let visitedUniqueFileCount: Int
}

struct WorkspaceCodemapStructureSeedAdmission: Equatable {
    let fileIDs: [UUID]
    let issues: [WorkspaceCodemapOperationCandidateIssue]
    let didExceedLimit: Bool
}

struct WorkspaceFileTreePresentationRequest {
    fileprivate let selectedFileIDs: Set<UUID>
    let mode: WorkspaceFileTreePresentationMode
    let filePathDisplay: FilePathDisplay
    let onlyIncludeRootsWithSelectedFiles: Bool
    let includeLegend: Bool
    let showCodeMapMarkers: Bool
    let rootScope: WorkspaceLookupRootScope
    let startPath: String?
    let maxDepth: Int?

    init(
        mode: WorkspaceFileTreePresentationMode,
        filePathDisplay: FilePathDisplay,
        onlyIncludeRootsWithSelectedFiles: Bool,
        includeLegend: Bool,
        showCodeMapMarkers: Bool = true,
        rootScope: WorkspaceLookupRootScope = .allLoaded,
        startPath: String? = nil,
        maxDepth: Int? = nil
    ) {
        selectedFileIDs = []
        self.mode = mode
        self.filePathDisplay = filePathDisplay
        self.onlyIncludeRootsWithSelectedFiles = onlyIncludeRootsWithSelectedFiles
        self.includeLegend = includeLegend
        self.showCodeMapMarkers = showCodeMapMarkers
        self.rootScope = rootScope
        self.startPath = startPath
        self.maxDepth = maxDepth
    }
}

typealias WorkspaceFileTreeSnapshotRequest = WorkspaceFileTreePresentationRequest

enum WorkspaceFileCatalogMaterializationResult: Equatable {
    case materialized(WorkspaceFileRecord)
    case ineligible(CatalogRegularFileIneligibilityReason)

    var file: WorkspaceFileRecord? {
        if case let .materialized(file) = self { return file }
        return nil
    }

    var ineligibilityReason: CatalogRegularFileIneligibilityReason? {
        if case let .ineligible(reason) = self { return reason }
        return nil
    }
}

enum WorkspaceExplicitFileMaterializationResult: Equatable {
    case materialized(WorkspaceFileRecord)
    case noCandidate
    case blocked
    case ambiguous
}

enum WorkspaceExplicitCatalogFileLookupResult: Equatable {
    case matched(WorkspaceFileRecord)
    case noCandidate
    case blocked
    case ambiguous
}

struct WorkspaceDisplayRootRefsSnapshot: Equatable {
    let visibleRoots: [WorkspaceRootRef]
    let allRoots: [WorkspaceRootRef]
}

private final class WorkspaceSessionRootLifetimeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func advance() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    func snapshot(physicalRootPaths: [String]) -> WorkspaceSessionRootLifetimeSnapshot {
        lock.lock()
        let capturedGeneration = generation
        lock.unlock()
        return WorkspaceSessionRootLifetimeSnapshot(
            clock: self,
            generation: capturedGeneration,
            physicalRootPaths: physicalRootPaths
        )
    }

    func performIfGenerationCurrent(
        generation expectedGeneration: UInt64,
        operation: () -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expectedGeneration else { return false }
        operation()
        return true
    }
}

struct WorkspaceSessionRootLifetimeSnapshot: @unchecked Sendable {
    fileprivate let clock: WorkspaceSessionRootLifetimeClock
    fileprivate let generation: UInt64
    fileprivate let physicalRootPaths: [String]

    func isGenerationCurrent() -> Bool {
        clock.performIfGenerationCurrent(
            generation: generation,
            operation: {}
        )
    }

    func isCurrent() async -> Bool {
        let physicalRootPaths = physicalRootPaths
        let rootsExist = await Task.detached(priority: .userInitiated) {
            physicalRootPaths.allSatisfy { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
        }.value
        guard rootsExist else { return false }
        return isGenerationCurrent()
    }

    @discardableResult
    func performIfGenerationCurrent(_ operation: () -> Void) -> Bool {
        clock.performIfGenerationCurrent(
            generation: generation,
            operation: operation
        )
    }
}

actor WorkspaceFileContextStore {
    private static let maximumRetainedCodemapProjectionDemands = 256
    private static let maximumRetainedCodemapProjectionDemandMetadataBytes: UInt64 = 4 * 1024 * 1024
    #if DEBUG
        enum CodemapProjectionPreloadLaunchPolicyForTesting: Equatable {
            case enabled
            case disabled
        }

        enum CodemapAutomaticRetainedProjectionDemandPolicyForTesting: Equatable {
            case enabled
            case suppressed
        }
    #endif

    enum CodemapProjectionPreloadStoreEventKind: String, Equatable {
        case rootInventoryAndSearchReady
        case scheduled
        case started
        case eligibilityEligible
        case eligibilityTerminal
        case eligibilityTransient
        case setupJoining
        case engineScheduling
        case handedOff
        case retryScheduled
        case retryStarted
        case repositoryAuthorityDetached
        case cancelled
        case superseded
    }

    struct CodemapProjectionPreloadStoreEvent: Equatable {
        let ordinal: UInt64
        let rootEpoch: WorkspaceCodemapRootEpoch
        let kind: CodemapProjectionPreloadStoreEventKind
        let launchPhase: WorkspaceCodemapProjectionPreloadLaunchPhase
    }

    struct CodemapProjectionPreloadRetryPolicy: @unchecked Sendable {
        let maximumRetryCount: Int
        let initialBackoffNanoseconds: UInt64
        let maximumBackoffNanoseconds: UInt64
        let nowNanoseconds: @Sendable () -> UInt64
        let sleep: @Sendable (UInt64) async throws -> Void

        static let production = Self(
            maximumRetryCount: 3,
            initialBackoffNanoseconds: 250_000_000,
            maximumBackoffNanoseconds: 2_000_000_000,
            nowNanoseconds: { DispatchTime.now().uptimeNanoseconds },
            sleep: { nanoseconds in
                try await Task.sleep(nanoseconds: nanoseconds)
            }
        )

        func backoffNanoseconds(forAttempt attempt: Int) -> UInt64 {
            guard attempt > 1 else { return min(initialBackoffNanoseconds, maximumBackoffNanoseconds) }
            var delay = min(initialBackoffNanoseconds, maximumBackoffNanoseconds)
            for _ in 1 ..< attempt {
                if delay >= maximumBackoffNanoseconds { return maximumBackoffNanoseconds }
                let (doubled, overflow) = delay.multipliedReportingOverflow(by: 2)
                delay = overflow ? maximumBackoffNanoseconds : min(doubled, maximumBackoffNanoseconds)
            }
            return delay
        }
    }

    private static let maximumRetainedCodemapPresentationRecordsPerRoot = 64
    private static let maximumCodemapPresentationRequestsPerBundle = 4096

    private struct RootState {
        let lifetimeID: UUID
        let root: WorkspaceRootRecord
        let service: FileSystemService
        var folderIDsByRelativePath: [String: UUID]
        var fileIDsByRelativePath: [String: UUID]
        var childFolderIDsByFolderID: [UUID: [UUID]]
        var childFileIDsByFolderID: [UUID: [UUID]]
    }

    private struct PendingSeededRoot {
        let id: WorkspacePendingSeededRootID
        let token: WorkspaceSessionWorktreeOwnershipToken
        let bindingFingerprint: String
        let standardizedPath: String
        let initializationID: FileSystemSeedInitializationID
        let loadConfiguration: RootLoadConfiguration
        let startupContext: WorktreeStartupContext
        var phase: WorkspacePendingSeededRootPhase
        var state: RootState
        var indexes: RootIndexBuffers
        var captureIdentity: FileSystemSeedCaptureIdentity?
        var authorityFence: GitWorkspacePendingInitializationAuthorityFence?
        var authorityInvalidationGeneration: UInt64
        var authorityAcceptedMetadataWatermark: UInt64
        var authorityMutationDepth: Int
        var snapshot: WorkspaceRootReusableSnapshot?
        var targetPlanHandle: WorkspaceRootTargetSeedPlanHandle?
        var authorityClaim: WorkspaceRootSeedServingAuthorityClaim?
        var attachment: WatcherPublisherAttachment?
        var preparedShard: RootCatalogShard?
        var lastAppliedServicePublicationSequence: UInt64
        var lastAppliedWatcherWatermark: FileSystemWatcherIngressMailbox.Watermark
        var activationProof: FileSystemSeedPublicationActivationProof?
        var terminalFallbackReason: WorkspaceRootSeedFallbackReason?
    }

    private struct PublishedSeededAuthorityState {
        var epoch: UInt64
        var pendingInvalidationGeneration: UInt64?
        var pendingAcceptedMetadataWatermark: UInt64
        var activeMutationDepth: Int
        var isBlocked: Bool
        var isReconciling: Bool
        var reconciliationFailed: Bool
        var fullCrawlAttemptedGeneration: UInt64?
        var fullCrawlCompletedGeneration: UInt64?
    }

    private enum PendingSeededRootAttempt {
        case prepared(WorkspacePendingSeededRootPreparation)
        case fallback(WorkspaceRootSeedFallbackReason)
    }

    private struct CodemapRootAuthority: Equatable {
        let rootEpoch: WorkspaceCodemapRootEpoch
        let standardizedRootPath: String
        let catalogGeneration: UInt64
        let ingressGeneration: UInt64
    }

    private enum CodemapEligibilityResolution {
        case eligible
        case terminal(WorkspaceCodemapGitTerminalUnavailableReason, WorkspaceCodemapNonGitFilesystemProof?)
        case transient(WorkspaceCodemapGitTransientUnavailableReason)
        case stale
        case cancelled
    }

    private struct CodemapEligibilityFlight {
        let id: UUID
        let authority: CodemapRootAuthority
        let task: Task<CodemapEligibilityResolution, Never>
    }

    private struct CodemapCompletedEligibility {
        let authority: CodemapRootAuthority
        let result: CodemapEligibilityResolution
    }

    private struct CodemapProjectionPreloadLaunch {
        let id: UUID
        let authority: CodemapRootAuthority
        let retryAttempt: Int
        var phase: WorkspaceCodemapProjectionPreloadLaunchPhase
        var task: Task<Void, Never>?
    }

    private struct CodemapProjectionPreloadRetry {
        let id: UUID
        let authority: CodemapRootAuthority
        let attempt: Int
        let deadlineNanoseconds: UInt64
        let task: Task<Void, Never>
    }

    private enum CodemapSetupDisposition {
        case ready
        case unavailable(WorkspaceCodemapArtifactDemandUnavailableReason)
    }

    private enum CodemapInvalidationCommand {
        case modified(Set<String>)
        case deleted(Set<String>)
        case renamed(from: String, to: String)
        case watcherGap
        case checkout
        case repositoryAuthority
        case catalogAdvanced
        case unload
    }

    private struct CodemapDemandRecord {
        let ticket: WorkspaceCodemapArtifactDemandTicket
        let identity: WorkspaceCodemapArtifactBindingIdentity
        let language: LanguageType
        let owner: WorkspaceCodemapLiveDemandOwner
        var retainIDs: Set<UUID>
        var result: WorkspaceCodemapArtifactDemandResult
        var task: Task<Void, Never>?
    }

    private struct CodemapPublishedStructureCapture {
        let request: WorkspaceCodemapPublishedArtifactLookupRequest
        let rootEpoch: WorkspaceCodemapRootEpoch
        let authority: CodemapRootAuthority
        let engine: WorkspaceCodemapBindingEngine
        let logicalPath: WorkspaceCodemapLogicalPresentationPath
    }

    private enum CodemapWarmPublishedMarkerReplayDisposition {
        case applied
        case alreadyCurrent
        case stale
    }

    private struct CodemapProjectionDemandRecord {
        let ticket: WorkspaceCodemapProjectionDemandTicket
        let fileIDs: [UUID]
        let metadataByteCount: UInt64
        let engine: WorkspaceCodemapBindingEngine
        var expiryTask: Task<Void, Never>?
    }

    private struct TerminalCodemapProjectionDemandRecord {
        let ticket: WorkspaceCodemapProjectionDemandTicket
        let status: WorkspaceCodemapProjectionDemandStatus
    }

    private struct CodemapPresentationRecord {
        let id: WorkspaceCodemapFrozenPresentationBundleID
        let rootEpoch: WorkspaceCodemapRootEpoch
        let entries: [WorkspaceCodemapFrozenPresentationEntry]
        let handles: [WorkspaceCodemapLiveFrozenArtifactHandle]
        let requestIDs: Set<UUID>
    }

    private struct CodemapSelectionGraphState {
        let id: UUID
        let graph: WorkspaceCodemapSelectionGraph
        var desiredKey: WorkspaceCodemapSelectionGraphRuntimeKey?
        var pendingSnapshot: WorkspaceCodemapLiveGraphSnapshot?
        var publishedSummary: WorkspaceCodemapSelectionGraphRuntimePublishedSummary?
        var lastRebuildDisposition: WorkspaceCodemapSelectionGraphRuntimeRebuildDisposition?
        var workerID: UUID?
        var workerTask: Task<Void, Never>?
    }

    private enum AutomaticSelectionTargetAuthority {
        case retainedReadyDemand
        case currentCompletedProjection
    }

    private struct CodemapProjectionRecoveryObserver {
        let id: UUID
        let authority: CodemapRootAuthority
        var latestSignalSerial: UInt64
        var lastRecoveredContributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration?
        var recoveringSignalSerial: UInt64?
        var lastRecoveredSignalSerial: UInt64?
        var publishingContributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration?
        var publishingSignalSerial: UInt64?
        var task: Task<Void, Never>?
    }

    private final class CodemapSharedTaskDeadlineRace: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func resolve(_ value: Bool) {
            lock.lock()
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: value)
        }
    }

    private struct CodemapGraphPublicationFlight {
        let id: UUID
        let authority: CodemapRootAuthority
        let projectionRecoveryObserverID: UUID?
        var latestSignalSerial: UInt64
        var flushingSerial: UInt64?
        var replayRequired: Bool
        var followUpStarted: Bool
        var task: Task<Void, Never>?
    }

    private final class CodemapAutomaticSelectionWeakPublicationPermit {
        weak var permit: WorkspaceCodemapAutomaticSelectionPublicationPermit?

        init(_ permit: WorkspaceCodemapAutomaticSelectionPublicationPermit) {
            self.permit = permit
        }
    }

    private struct CodemapGraphQueryCapture {
        let authority: CodemapRootAuthority
        let graphStateID: UUID
        let graph: WorkspaceCodemapSelectionGraph
        let desiredKey: WorkspaceCodemapSelectionGraphRuntimeKey
        let workerWasActive: Bool
        let sources: [WorkspaceCodemapStoreSelectionGraphSourceIdentity]
    }

    private enum CodemapAutomaticSelectionSourceSnapshot: Equatable {
        case rootEpochNotCurrent
        case outsideRootScope
        case staleCatalogGeneration(UInt64?)
        case notCataloged
        case notDemanded
        case pending(WorkspaceCodemapArtifactDemandTicket)
        case unavailable(WorkspaceCodemapArtifactDemandUnavailableReason)
        case ready(WorkspaceCodemapArtifactDemandTicket)
    }

    private struct CodemapAutomaticSelectionSnapshot: Equatable {
        let allowedRootIDs: Set<UUID>
        let sourceStates: [
            WorkspaceCodemapAutomaticSelectionSourceIdentity:
                CodemapAutomaticSelectionSourceSnapshot
        ]
    }

    private struct CodemapRootSession {
        let authority: CodemapRootAuthority
        var endpoint: WorkspaceCodemapBindingIntegrationEndpoint?
        var routeToken: WorkspaceCodemapBindingIntegrationRouteToken?
        var runtime: CodeMapArtifactRuntime?
        var engine: WorkspaceCodemapBindingEngine?
        var setupTask: Task<CodemapSetupDisposition, Never>?
        var setupDisposition: CodemapSetupDisposition?
        var pathGenerationsByRelativePath: [String: UInt64] = [:]
        var markerReadinessByFileID: [UUID: WorkspaceCodemapMarkerReadinessChange] = [:]
        var markerReadinessRevision: UInt64 = 0
        var demandsByFileID: [UUID: CodemapDemandRecord] = [:]
        var bundlesByRequestID: [UUID: WorkspaceCodemapLiveOverlayBundle] = [:]
        var presentationRecordsByID: [
            WorkspaceCodemapFrozenPresentationBundleID: CodemapPresentationRecord
        ] = [:]
        var graphPublicationFlight: CodemapGraphPublicationFlight?
        var projectionRecoveryObserver: CodemapProjectionRecoveryObserver?
        var selectionGraph: CodemapSelectionGraphState?
        var graphSnapshotDirtyDuringPathInvalidation = false
    }

    private struct DetachedCodemapSession: @unchecked Sendable {
        let authority: CodemapRootAuthority
        let registry: WorkspaceCodemapBindingIntegrationRegistry?
        let routeToken: WorkspaceCodemapBindingIntegrationRouteToken?
        let engine: WorkspaceCodemapBindingEngine?
        let owners: [WorkspaceCodemapLiveDemandOwner]
        let setupTask: Task<CodemapSetupDisposition, Never>?
        let demandTasks: [Task<Void, Never>]
        let projectionDemands: [CodemapProjectionDemandRecord]
        let graphPublicationTask: Task<Void, Never>?
        let projectionRecoveryObserverTask: Task<Void, Never>?
        let selectionGraph: WorkspaceCodemapSelectionGraph?
        let graphWorkerTask: Task<Void, Never>?
        let preloadLaunchTask: Task<Void, Never>?
        let eligibilityTask: Task<CodemapEligibilityResolution, Never>?
        let preloadRetryTask: Task<Void, Never>?
        let predecessorTasks: [Task<Void, Never>]
        let invalidationCommands: [CodemapInvalidationCommand]
        let graphInvalidationReason: WorkspaceCodemapSelectionGraphRuntimeExternalUnavailableReason
    }

    private struct CodemapPathFenceToken: Hashable {
        let id: UUID
        let rootEpoch: WorkspaceCodemapRootEpoch
        let standardizedRelativePaths: Set<String>
        let shouldRescheduleProjectionPreload: Bool
    }

    private struct CodemapRootMutationFenceToken: Hashable {
        let id: UUID
        let rootEpoch: WorkspaceCodemapRootEpoch
    }

    private struct CodemapPathInvalidationFlight {
        let id: UUID
        let rootEpoch: WorkspaceCodemapRootEpoch
        let task: Task<Void, Never>
    }

    private struct CodemapCleanupFlight {
        let id: UUID
        let rootEpoch: WorkspaceCodemapRootEpoch
        let task: Task<Void, Never>
    }

    private struct DetachedWatcherStop {
        let index: Int
        let rootID: UUID
        let rootPath: String
        let completionLatch: WorkspaceRootUnloadCompletionLatch
        let task: Task<Void, Never>
    }

    private struct RootLoadConfiguration: Hashable {
        let kind: WorkspaceRootKind
        let gitignorePolicyIdentity: WorkspaceGitignorePolicyIdentity
        let respectRepoIgnore: Bool
        let respectCursorignore: Bool
        let skipSymlinks: Bool
        let enableHierarchicalIgnores: Bool
    }

    private struct RootLoadCompletionIdentity {
        let rootID: UUID
        let lifetimeID: UUID
    }

    private final class RootLoadFlightCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var completionIdentity: RootLoadCompletionIdentity?

        func record(rootID: UUID, lifetimeID: UUID) {
            lock.lock()
            completionIdentity = RootLoadCompletionIdentity(
                rootID: rootID,
                lifetimeID: lifetimeID
            )
            lock.unlock()
        }

        func identity() -> RootLoadCompletionIdentity? {
            lock.lock()
            let identity = completionIdentity
            lock.unlock()
            return identity
        }
    }

    private struct RootLoadFlight {
        let id: UUID
        let task: Task<WorkspaceRootRecord, Error>
        let completion: RootLoadFlightCompletion
    }

    private struct SessionWorktreeRootLifetimeKey: Hashable {
        let rootID: UUID
        let lifetimeID: UUID
    }

    private struct WatcherInfrastructureKey: Hashable {
        let rootID: UUID
        let lifetimeID: UUID
    }

    private struct WatcherPublisherAttachment {
        let subscription: WorkspaceFileSystemIngressCoordinator.Subscription
        let cancellable: AnyCancellable
    }

    private struct WatcherInfrastructureFlight {
        let id: UUID
        let task: Task<Void, Error>
    }

    private struct SessionWorktreeOwnershipRecord {
        let bindingFingerprint: String
        let roots: [WorkspaceSessionWorktreeOwnedRoot]
        let pendingSeededRootIDs: [WorkspacePendingSeededRootID]
    }

    private struct SessionWorktreeReservedLoadFlight {
        let ownerID: UUID
        let standardizedPath: String
        let flight: RootLoadFlight
    }

    #if DEBUG
        private struct SessionWorktreeOrphanLoadCleanup {
            let ownerID: UUID
            let standardizedPath: String
            let task: Task<Void, Never>
        }
    #endif

    private struct SessionWorktreeOwnershipRemoval {
        var ownedRoots: [WorkspaceSessionWorktreeOwnedRoot] = []
        var reservedLoadFlights: [SessionWorktreeReservedLoadFlight] = []
        var pendingSeededRootIDs: [WorkspacePendingSeededRootID] = []

        mutating func append(_ other: SessionWorktreeOwnershipRemoval) {
            ownedRoots.append(contentsOf: other.ownedRoots)
            reservedLoadFlights.append(contentsOf: other.reservedLoadFlights)
            pendingSeededRootIDs.append(contentsOf: other.pendingSeededRootIDs)
        }
    }

    private final class RootLoadTaskWaitRace: @unchecked Sendable {
        private let lock = NSLock()
        private var resolution: Result<WorkspaceRootRecord, Error>?
        private var continuation: CheckedContinuation<WorkspaceRootRecord, Error>?

        func value() async throws -> WorkspaceRootRecord {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let resolution {
                    lock.unlock()
                    continuation.resume(with: resolution)
                } else {
                    precondition(self.continuation == nil)
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }

        func resolve(_ resolution: Result<WorkspaceRootRecord, Error>) {
            let continuation: CheckedContinuation<WorkspaceRootRecord, Error>?
            lock.lock()
            guard self.resolution == nil else {
                lock.unlock()
                return
            }
            self.resolution = resolution
            continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: resolution)
        }

        func cancel() {
            resolve(.failure(CancellationError()))
        }
    }

    private final class WatcherInfrastructureTaskWaitRace: @unchecked Sendable {
        private let lock = NSLock()
        private var resolution: Result<Void, Error>?
        private var continuation: CheckedContinuation<Void, Error>?

        func value() async throws {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let resolution {
                    lock.unlock()
                    continuation.resume(with: resolution)
                } else {
                    precondition(self.continuation == nil)
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }

        func resolve(_ resolution: Result<Void, Error>) {
            let continuation: CheckedContinuation<Void, Error>?
            lock.lock()
            guard self.resolution == nil else {
                lock.unlock()
                return
            }
            self.resolution = resolution
            continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: resolution)
        }

        func cancel() {
            resolve(.failure(CancellationError()))
        }
    }

    private struct SliceRebaseSourceCacheKey: Hashable {
        let rootID: UUID
        let rootLifetimeID: UUID
        let fileID: UUID
        let relativePath: String
    }

    private struct SliceRebaseSourceCacheEntry {
        let snapshot: WorkspaceSliceRebaseSourceSnapshot
        let byteCost: Int
        var accessOrdinal: UInt64
    }

    private enum CatalogInvalidationReason: String, Hashable {
        case fileSystemPublication = "file_system_publication"
        case rootLoad = "root_load"
        case rootUnload = "root_unload"
        case explicitMaterialization = "explicit_materialization"
        case managedFilePromotion = "managed_file_promotion"
        case catalogMutation = "catalog_mutation"
        case cacheCapacity = "cache_capacity"
    }

    private final class PublicationInvalidationBatch {
        var topologyInvalidationRequested = false
        var affectedRootKinds = Set<WorkspaceRootKind>()
        var affectedRootIDs = Set<UUID>()
        var reasons = Set<CatalogInvalidationReason>()
        var searchContentInvalidations = WorkspaceSearchContentInvalidationBatch()
    }

    private struct ScopedIngressBarrierTarget {
        let watcherAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark
        let acceptedServicePublicationSequence: UInt64

        func covers(_ other: ScopedIngressBarrierTarget) -> Bool {
            watcherAcceptedWatermark >= other.watcherAcceptedWatermark
                && acceptedServicePublicationSequence >= other.acceptedServicePublicationSequence
        }

        func merging(_ other: ScopedIngressBarrierTarget) -> ScopedIngressBarrierTarget {
            ScopedIngressBarrierTarget(
                watcherAcceptedWatermark: max(watcherAcceptedWatermark, other.watcherAcceptedWatermark),
                acceptedServicePublicationSequence: max(
                    acceptedServicePublicationSequence,
                    other.acceptedServicePublicationSequence
                )
            )
        }
    }

    private struct ScopedIngressBarrierCompletedCut {
        let target: ScopedIngressBarrierTarget
        let sample: WorkspaceIngressBarrierSample
    }

    #if DEBUG
        private struct ScopedIngressBarrierTaskOutput {
            let sample: WorkspaceIngressBarrierSample
            let completedAtNanoseconds: UInt64
        }
    #else
        private typealias ScopedIngressBarrierTaskOutput = WorkspaceIngressBarrierSample
    #endif

    private final class ScopedIngressBarrierJoin: @unchecked Sendable {
        private let lock = NSLock()
        private var isCompleted = false
        private var completedOutput: ScopedIngressBarrierTaskOutput?
        private var waiters: [UUID: CheckedContinuation<ScopedIngressBarrierTaskOutput?, Never>] = [:]

        func value() async -> ScopedIngressBarrierTaskOutput? {
            let waiterID = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    lock.lock()
                    if Task.isCancelled {
                        lock.unlock()
                        continuation.resume(returning: nil)
                    } else if isCompleted {
                        let output = completedOutput
                        lock.unlock()
                        continuation.resume(returning: output)
                    } else {
                        waiters[waiterID] = continuation
                        lock.unlock()
                    }
                }
            } onCancel: {
                cancelWaiter(id: waiterID)
            }
        }

        func complete(with output: ScopedIngressBarrierTaskOutput?) {
            let continuations: [CheckedContinuation<ScopedIngressBarrierTaskOutput?, Never>]
            lock.lock()
            guard !isCompleted else {
                lock.unlock()
                return
            }
            isCompleted = true
            completedOutput = output
            continuations = Array(waiters.values)
            waiters.removeAll(keepingCapacity: false)
            lock.unlock()
            continuations.forEach { $0.resume(returning: output) }
        }

        private func cancelWaiter(id waiterID: UUID) {
            let continuation: CheckedContinuation<ScopedIngressBarrierTaskOutput?, Never>?
            lock.lock()
            continuation = waiters.removeValue(forKey: waiterID)
            lock.unlock()
            continuation?.resume(returning: nil)
        }
    }

    private final class ScopedIngressBarrierFlight {
        let token: UInt64
        let target: ScopedIngressBarrierTarget
        let join: ScopedIngressBarrierJoin
        var task: Task<Void, Never>?
        #if DEBUG
            let startedAtNanoseconds: UInt64
        #endif

        init(
            token: UInt64,
            target: ScopedIngressBarrierTarget,
            join: ScopedIngressBarrierJoin,
            startedAtNanoseconds: UInt64 = 0
        ) {
            self.token = token
            self.target = target
            self.join = join
            #if DEBUG
                self.startedAtNanoseconds = startedAtNanoseconds
            #endif
        }
    }

    private final class ScopedIngressBarrierPendingFlight {
        var target: ScopedIngressBarrierTarget
        let join: ScopedIngressBarrierJoin
        #if DEBUG
            let enqueuedAtNanoseconds: UInt64
        #endif

        init(
            target: ScopedIngressBarrierTarget,
            join: ScopedIngressBarrierJoin,
            enqueuedAtNanoseconds: UInt64 = 0
        ) {
            self.target = target
            self.join = join
            #if DEBUG
                self.enqueuedAtNanoseconds = enqueuedAtNanoseconds
            #endif
        }
    }

    private final class ScopedIngressBarrierRootFlightState {
        var active: ScopedIngressBarrierFlight?
        var pending: ScopedIngressBarrierPendingFlight?

        init(
            active: ScopedIngressBarrierFlight? = nil,
            pending: ScopedIngressBarrierPendingFlight? = nil
        ) {
            self.active = active
            self.pending = pending
        }
    }

    #if DEBUG
        struct ScopedIngressBarrierStats: Equatable {
            let launchCount: Int
            let joinCount: Int
            let successorCount: Int
            let coalescedSuccessorCount: Int
            let noopCount: Int
        }

        struct ScopedIngressBarrierDebugSnapshot: Equatable {
            struct Active: Equatable {
                let targetWatcherWatermark: UInt64
                let targetServicePublicationSequence: UInt64
                let ageMilliseconds: UInt64
            }

            struct Pending: Equatable {
                let targetWatcherWatermark: UInt64
                let targetServicePublicationSequence: UInt64
                let ageMilliseconds: UInt64
            }

            struct Completed: Equatable {
                let token: UInt64
                let targetWatcherWatermark: UInt64
                let targetServicePublicationSequence: UInt64
                let publishedServicePublicationSequence: UInt64
                let appliedServicePublicationSequence: UInt64
                let appliedWatcherWatermark: UInt64
                let durationMilliseconds: UInt64
            }

            let launchCount: Int
            let joinCount: Int
            let successorCount: Int
            let coalescedSuccessorCount: Int
            let completionCount: Int
            let noopCount: Int
            let totalWaitMilliseconds: UInt64
            let maxWaitMilliseconds: UInt64
            let active: Active?
            let pending: Pending?
            let lastCompleted: Completed?
        }

        struct PublicationInvalidationDebugSample: Equatable {
            let servicePublicationSequence: UInt64
            let watcherAcceptedWatermark: UInt64?
            let preparedDeltaCount: Int
            let topologyInvalidationCount: Int
            let catalogGenerationAdvanceCount: Int
            let searchCatalogCacheClearCount: Int
            let pathWorkerInvalidationRequestCount: Int
            let contentInvalidationCount: Int
            let distinctContentKeyCount: Int
            let decodedCacheInvalidationRequestCount: Int
            let codemapInvalidationRequestCount: Int
            let appliedIndexEventYieldCount: Int
        }

        struct PublicationInvalidationHistoryDebugSnapshot: Equatable {
            let retainedSampleLimit: Int
            let totalObservedPublicationCount: Int
            let droppedPublicationSampleCount: Int
            let samples: [PublicationInvalidationDebugSample]
        }

        struct CatalogInvalidationDebugEvent: Equatable {
            let sequence: UInt64
            let reasons: [String]
            let affectedRootIDs: [UUID]
            let affectedRootKinds: [String]
            let evictedScopes: [String]
        }

        struct CatalogRebuildDebugSnapshot: Equatable {
            let rebuildCount: Int
            let filterMicroseconds: UInt64
            let sortMicroseconds: UInt64
            let fileSortMicroseconds: UInt64
            let folderSortMicroseconds: UInt64
            let sortResidualMicroseconds: UInt64
            let sortReconciliationDeltaMicroseconds: Int64
            let sortInvocationCount: Int
            let sortFileInputCount: Int
            let sortFolderInputCount: Int
            let materializationMicroseconds: UInt64
            let pathIndexKeyMicroseconds: UInt64
            let pathIndexConstructionMicroseconds: UInt64
            let compositionCacheResidualMicroseconds: UInt64
            let totalMicroseconds: UInt64
            let lastFileCount: Int
            let lastRootCount: Int
        }

        enum RootCatalogShardFallbackReason: String, CaseIterable, Hashable {
            case missingReusableShard
            case generationGap
            case fullResync
            case unsafeOrAmbiguousBatch
            case retentionBoundary
            case patchThresholdExceeded
            case patchApplicationBackstop
            case shadowValidationMismatch
        }

        struct RootCatalogShardGenerationDebugSnapshot: Equatable {
            let rootID: UUID
            let lifetimeID: UUID?
            let publishedTopologyGeneration: UInt64?
            let liveTopologyGenerations: [UInt64]
            let retainedTopologyGenerations: [UInt64]
            let buildCount: Int
            let pathIndexBuildCount: Int
            let overlayPathIndexBuildCount: Int
            let patchCount: Int
            let authoritativeRebuildCount: Int
            let fallbackCount: Int
            let fallbackReasonCounts: [RootCatalogShardFallbackReason: Int]
            let lastAppliedIndexGeneration: UInt64?
            let deltaStateDirty: Bool
            let backstopCount: Int
            let maxLiveGenerationCount: Int
        }

        struct RootCatalogShardDebugSnapshot: Equatable {
            let liveGenerationCapPerRoot: Int
            let maxPatchLogicalMutationCount: Int
            let publishedShardCount: Int
            let totalBuildCount: Int
            let totalBackstopCount: Int
            let singleShardCompositionReuseCount: Int
            let genericMergeElementVisitCount: Int
            let shadowComparisonCount: Int
            let shadowMismatchCount: Int
            let lastShadowByteCount: Int
            let roots: [RootCatalogShardGenerationDebugSnapshot]
        }

        struct StoreWorkDiagnosticsSnapshot: Equatable {
            let invalidations: [CatalogInvalidationDebugEvent]
            let catalogRebuild: CatalogRebuildDebugSnapshot
            let rootCatalogShards: RootCatalogShardDebugSnapshot
        }

        struct PublishedSeededAuthorityDebugSnapshot: Equatable {
            let epoch: UInt64
            let isBlocked: Bool
            let activeMutationDepth: Int
            let isReconciling: Bool
            let reconciliationFailed: Bool
            let waiterCount: Int
            let fullCrawlCount: Int
        }

        struct ReadSearchRootDiagnosticsSnapshot: Equatable {
            let rootID: UUID
            let rootToken: UUID
            let rootPath: String
            let rootKind: String
            let crawlCount: Int
            let watcherActive: Bool
            let explicitWatcherDemand: Bool
            let sessionWorktreeOwnerCount: Int
            let ingress: WorkspaceFileSystemIngressCoordinator.DebugSnapshot
            let barrier: ScopedIngressBarrierDebugSnapshot
            let freshness: FileSystemService.FreshnessWorkDiagnosticsSnapshot
            let invalidation: PublicationInvalidationHistoryDebugSnapshot
            let producedAppliedIndexGeneration: UInt64
        }

        struct ApplyEditsRebaseProbePathSnapshot: Equatable {
            let rootID: UUID
            let rootLifetimeID: UUID
            let rootToken: UUID
            let rootPath: String
            let fileID: UUID
            let fullPath: String
            let relativePath: String
            let isSessionWorktree: Bool
            let producedAppliedIndexGeneration: UInt64
        }

        private final class PublicationInvalidationRecorder: @unchecked Sendable {
            let preparedDeltaCount: Int
            var topologyInvalidationCount = 0
            var catalogGenerationAdvanceCount = 0
            var searchCatalogCacheClearCount = 0
            var pathWorkerInvalidationRequestCount = 0
            var contentInvalidationCount = 0
            var decodedCacheInvalidationRequestCount = 0
            var codemapInvalidationRequestCount = 0
            var appliedIndexEventYieldCount = 0
            var distinctContentKeys = Set<WorkspaceSearchContentCacheKey>()

            init(preparedDeltaCount: Int) {
                self.preparedDeltaCount = preparedDeltaCount
            }
        }

        private struct PublicationInvalidationHistoryState {
            var totalObservedPublicationCount = 0
            var samples: [PublicationInvalidationDebugSample] = []
        }

        @TaskLocal private static var activePublicationInvalidationRecorder: PublicationInvalidationRecorder?
        private static let publicationInvalidationSampleLimit = 32
    #endif

    #if DEBUG
        private var rootLoadWillStartHandler: (@Sendable (String) async -> Void)?
        private var sessionWorktreeDrainDidEnterLoadFlightWaitHandler: (@Sendable () -> Void)?
        private var sessionWorktreeDrainLoadFlightWaiterCount = 0
        private var rootLoadDidJoinInFlightHandler: (@Sendable (String) async -> Void)?
        private var rootUnloadDidDetachHandler: (@Sendable ([String]) async -> Void)?
        private var ensureIndexedFilesEligibilityDidResolveHandler: (@Sendable (UUID, String) async -> Void)?
        private var contextBuilderSelectionCandidateEligibilityDidResolveHandler: (@Sendable (UUID) async -> Void)?
        private var publishedGitArtifactIngressDidRegisterHandler: (@Sendable (UUID, String) async -> Void)?
        private var watcherSinkWillApplyHandler: (@Sendable (UUID) async -> Void)?
        private var storeEditDeferredPublicationDidRegisterHandler: (@Sendable (UUID, String) async -> Void)?
        private var publisherIngressWillWaitHandler: (@Sendable (Set<UUID>) async -> Void)?
        private var watcherPublisherIngressDidOpenHandler: (@Sendable (UUID, UUID) async -> Void)?
        private var watcherInfrastructureDidJoinFlightHandler: (@Sendable (UUID, UUID) async -> Void)?
        private var watcherServiceStateWillReconcileHandler: (@Sendable (UUID, Bool) async -> Void)?
        private var watcherStopWillBeginHandler: (@Sendable (UUID) async -> Void)?
        private var rootUnloadTerminationDidCompleteHandler: (@Sendable (WorkspaceRootUnloadTerminationDiagnostics) async -> Void)?
        private var appliedIngressDidCaptureWatermarksHandler: (@Sendable ([UUID: UInt64]) async -> Void)?
        private var scopedIngressBarrierWillFlushHandler: (@Sendable (UUID) async -> Void)?
        private var watcherActivationFailurePointForNewServicesForTesting: FileSystemService.WatcherActivationFailurePoint?
        private var seededShardPreparationShouldFailForTesting = false
        private var pendingSeededRootDidBecomeReadyHandler: (@Sendable (String) async -> Void)?
        private var pendingSeededRootDidActivateHandler: (@Sendable (String) async -> Void)?
        private var seededPublicationActivationShouldFailForTesting = false
        private var publishedSeededAuthorityFullCrawlCountsByRootID: [UUID: Int] = [:]
        private var scopedIngressBarrierLaunchCountsByRootID: [UUID: Int] = [:]
        private var scopedIngressBarrierJoinCountsByRootID: [UUID: Int] = [:]
        private var scopedIngressBarrierSuccessorCountsByRootID: [UUID: Int] = [:]
        private var scopedIngressBarrierCoalescedSuccessorCountsByRootID: [UUID: Int] = [:]
        private var scopedIngressBarrierCompletionCountsByRootID: [UUID: Int] = [:]
        private var scopedIngressBarrierNoopCountsByRootID: [UUID: Int] = [:]
        private var scopedIngressBarrierTotalWaitMillisecondsByRootID: [UUID: UInt64] = [:]
        private var scopedIngressBarrierMaxWaitMillisecondsByRootID: [UUID: UInt64] = [:]
        private var lastCompletedScopedIngressBarrierByRootID: [UUID: ScopedIngressBarrierDebugSnapshot.Completed] = [:]
        private var publicationInvalidationHistoryByRootID: [UUID: PublicationInvalidationHistoryState] = [:]
        private var rootCrawlCountsByRootID: [UUID: Int] = [:]
        private var nextCatalogInvalidationSequence: UInt64 = 0
        private var catalogInvalidationHistory: [CatalogInvalidationDebugEvent] = []
        private var catalogRebuildCount = 0
        private var catalogRebuildFilterMicroseconds: UInt64 = 0
        private var catalogRebuildSortMicroseconds: UInt64 = 0
        private var catalogRebuildFileSortMicroseconds: UInt64 = 0
        private var catalogRebuildFolderSortMicroseconds: UInt64 = 0
        private var catalogRebuildSortResidualMicroseconds: UInt64 = 0
        private var catalogRebuildSortReconciliationDeltaMicroseconds: Int64 = 0
        private var catalogRebuildSortInvocationCount = 0
        private var catalogRebuildSortFileInputCount = 0
        private var catalogRebuildSortFolderInputCount = 0
        private var catalogRebuildMaterializationMicroseconds: UInt64 = 0
        private var catalogRebuildPathIndexKeyMicroseconds: UInt64 = 0
        private var catalogRebuildPathIndexConstructionMicroseconds: UInt64 = 0
        private var catalogRebuildCompositionCacheResidualMicroseconds: UInt64 = 0
        private var catalogRebuildTotalMicroseconds: UInt64 = 0
        private var catalogRebuildLastFileCount = 0
        private var catalogRebuildLastRootCount = 0
        private var rootCatalogShardBuildCountsByRootID: [UUID: Int] = [:]
        private var rootCatalogShardFullPathIndexBuildCountsByRootID: [UUID: Int] = [:]
        private var rootCatalogShardOverlayPathIndexBuildCountsByRootID: [UUID: Int] = [:]
        private var rootCatalogShardPatchCountsByRootID: [UUID: Int] = [:]
        private var rootCatalogShardAuthoritativeRebuildCountsByRootID: [UUID: Int] = [:]
        private var rootCatalogShardFallbackCountsByRootID: [UUID: Int] = [:]
        private var rootCatalogShardFallbackReasonCountsByRootID: [UUID: [RootCatalogShardFallbackReason: Int]] = [:]
        private var rootCatalogShardFallbackLifetimeIDsByRootID: [UUID: UUID] = [:]
        private var rootCatalogShardBackstopCountsByRootID: [UUID: Int] = [:]
        private var rootCatalogShardMaxLiveGenerationCountsByRootID: [UUID: Int] = [:]
        private var rootCatalogShardSingleShardCompositionReuseCount = 0
        private var rootCatalogShardGenericMergeElementVisitCount = 0
        private var rootCatalogShardShadowComparisonCount = 0
        private var rootCatalogShardShadowMismatchCount = 0
        private var rootCatalogShardLastShadowByteCount = 0

        func setCodemapProjectionPreloadStartHandlerForTesting(
            _ handler: (@Sendable (WorkspaceCodemapRootEpoch) async -> Void)?
        ) {
            codemapProjectionPreloadStartHandler = handler
        }

        func setCodemapProjectionCatalogBuildHandlerForTesting(
            _ handler: (@Sendable (WorkspaceCodemapRootEpoch) async -> Void)?
        ) {
            codemapProjectionCatalogBuildHandler = handler
        }

        func codemapProjectionPreloadStoreEventsForTesting(
            rootID: UUID? = nil
        ) -> [CodemapProjectionPreloadStoreEvent] {
            codemapProjectionPreloadStoreEvents.filter { event in
                rootID.map { event.rootEpoch.rootID == $0 } ?? true
            }
        }

        func codemapProjectionPreloadLaunchPhaseForTesting(
            rootEpoch: WorkspaceCodemapRootEpoch
        ) -> WorkspaceCodemapProjectionPreloadLaunchPhase? {
            codemapProjectionPreloadLaunchesByRootEpoch[rootEpoch]?.phase
        }

        func codemapEligibilityFlightCountForTesting() -> Int {
            codemapEligibilityFlightsByRootEpoch.count
        }

        func codemapProjectionPreloadRetrySnapshotForTesting(
            rootEpoch: WorkspaceCodemapRootEpoch
        ) -> (attempt: Int, deadlineNanoseconds: UInt64)? {
            codemapProjectionPreloadRetriesByRootEpoch[rootEpoch].map {
                (attempt: $0.attempt, deadlineNanoseconds: $0.deadlineNanoseconds)
            }
        }

        func debugAcquireCodemapProjectionAdmissionHold(
            rootID: UUID,
            expiresAfterMilliseconds: UInt64
        ) async -> (
            holdID: UUID,
            metrics: [String: UInt64],
            queueWaitMilliseconds: [UInt64]
        )? {
            guard let owner = debugCodemapBindingEngine(rootID: rootID),
                  let acquired = await owner.engine.debugAcquireProjectionAdmissionHold(
                      rootEpoch: owner.rootEpoch,
                      expiresAfterMilliseconds: expiresAfterMilliseconds
                  )
            else { return nil }
            debugCodemapProjectionHoldOwners[acquired.holdID] = owner
            debugCodemapProjectionHoldExpiryTasks[acquired.holdID] = Task { [weak self] in
                try? await Task.sleep(
                    nanoseconds: (expiresAfterMilliseconds + 1000) * 1_000_000
                )
                guard !Task.isCancelled else { return }
                await self?.debugForgetCodemapProjectionAdmissionHold(acquired.holdID)
            }
            return acquired
        }

        func debugReleaseCodemapProjectionAdmissionHold(
            rootID: UUID,
            holdID: UUID
        ) async -> (
            released: Bool,
            metrics: [String: UInt64],
            queueWaitMilliseconds: [UInt64]
        )? {
            let owner: (rootEpoch: WorkspaceCodemapRootEpoch, engine: WorkspaceCodemapBindingEngine)
            if let retained = debugCodemapProjectionHoldOwners[holdID] {
                guard retained.rootEpoch.rootID == rootID else { return nil }
                owner = retained
            } else {
                guard let current = debugCodemapBindingEngine(rootID: rootID) else { return nil }
                owner = current
            }
            let released = await owner.engine.debugReleaseProjectionAdmissionHold(
                holdID,
                rootEpoch: owner.rootEpoch
            )
            debugCodemapProjectionHoldOwners.removeValue(forKey: holdID)
            debugCodemapProjectionHoldExpiryTasks.removeValue(forKey: holdID)?.cancel()
            return released
        }

        func debugCodemapProjectionAdmissionSnapshot(
            rootID: UUID
        ) async -> (
            metrics: [String: UInt64],
            queueWaitMilliseconds: [UInt64]
        )? {
            guard let owner = debugCodemapBindingEngine(rootID: rootID) else { return nil }
            return await owner.engine.debugProjectionAdmissionSnapshot(rootEpoch: owner.rootEpoch)
        }

        func debugCodemapEnginePresent(rootID: UUID) -> Bool {
            debugCodemapBindingEngine(rootID: rootID) != nil
        }

        func codemapBindingEngineAccountingForTesting(
            rootID: UUID
        ) async -> WorkspaceCodemapBindingEngineAccounting? {
            guard let owner = debugCodemapBindingEngine(rootID: rootID) else { return nil }
            return await owner.engine.accounting()
        }

        private func debugCodemapBindingEngine(
            rootID: UUID
        ) -> (rootEpoch: WorkspaceCodemapRootEpoch, engine: WorkspaceCodemapBindingEngine)? {
            let matchingSessions: [(key: WorkspaceCodemapRootEpoch, value: CodemapRootSession)] =
                codemapSessionsByRootEpoch.filter {
                    $0.key.rootID == rootID && $0.value.engine != nil
                }
            let newestSession: (key: WorkspaceCodemapRootEpoch, value: CodemapRootSession)? =
                matchingSessions.max { lhs, rhs in
                    lhs.value.authority.catalogGeneration < rhs.value.authority.catalogGeneration
                }
            guard let newestSession,
                  let engine = newestSession.value.engine
            else { return nil }
            return (newestSession.key, engine)
        }

        private func debugForgetCodemapProjectionAdmissionHold(_ holdID: UUID) {
            debugCodemapProjectionHoldOwners.removeValue(forKey: holdID)
            debugCodemapProjectionHoldExpiryTasks.removeValue(forKey: holdID)
        }

        func setRootLoadWillStartHandler(_ handler: (@Sendable (String) async -> Void)?) {
            rootLoadWillStartHandler = handler
        }

        func setSessionWorktreeDrainDidEnterLoadFlightWaitHandler(
            _ handler: (@Sendable () -> Void)?
        ) {
            sessionWorktreeDrainDidEnterLoadFlightWaitHandler = handler
        }

        func sessionWorktreeDrainLoadFlightWaiterCountForTesting() -> Int {
            sessionWorktreeDrainLoadFlightWaiterCount
        }

        func setRootLoadDidJoinInFlightHandler(_ handler: (@Sendable (String) async -> Void)?) {
            rootLoadDidJoinInFlightHandler = handler
        }

        func setRootUnloadDidDetachHandler(_ handler: (@Sendable ([String]) async -> Void)?) {
            rootUnloadDidDetachHandler = handler
        }

        func setEnsureIndexedFilesEligibilityDidResolveHandler(_ handler: (@Sendable (UUID, String) async -> Void)?) {
            ensureIndexedFilesEligibilityDidResolveHandler = handler
        }

        func setContextBuilderSelectionCandidateEligibilityDidResolveHandler(
            _ handler: (@Sendable (UUID) async -> Void)?
        ) {
            contextBuilderSelectionCandidateEligibilityDidResolveHandler = handler
        }

        func setPublishedGitArtifactIngressDidRegisterHandler(
            _ handler: (@Sendable (UUID, String) async -> Void)?
        ) {
            publishedGitArtifactIngressDidRegisterHandler = handler
        }

        func setWatcherSinkWillApplyHandler(_ handler: (@Sendable (UUID) async -> Void)?) {
            watcherSinkWillApplyHandler = handler
        }

        func setPublisherIngressWillWaitHandler(_ handler: (@Sendable (Set<UUID>) async -> Void)?) {
            publisherIngressWillWaitHandler = handler
        }

        func setWatcherPublisherIngressDidOpenHandler(_ handler: (@Sendable (UUID, UUID) async -> Void)?) {
            watcherPublisherIngressDidOpenHandler = handler
        }

        func setWatcherInfrastructureDidJoinFlightHandler(_ handler: (@Sendable (UUID, UUID) async -> Void)?) {
            watcherInfrastructureDidJoinFlightHandler = handler
        }

        func watcherInfrastructureFlightCountForTesting(rootID: UUID) -> Int {
            watcherInfrastructureFlightsByKey.keys.count(where: { $0.rootID == rootID })
        }

        func setWatcherServiceStateWillReconcileHandler(_ handler: (@Sendable (UUID, Bool) async -> Void)?) {
            watcherServiceStateWillReconcileHandler = handler
        }

        func setWatcherStopWillBeginHandler(_ handler: (@Sendable (UUID) async -> Void)?) {
            watcherStopWillBeginHandler = handler
        }

        func setRootUnloadTerminationDidCompleteHandler(
            _ handler: (@Sendable (WorkspaceRootUnloadTerminationDiagnostics) async -> Void)?
        ) {
            rootUnloadTerminationDidCompleteHandler = handler
        }

        func setAppliedIngressDidCaptureWatermarksHandler(_ handler: (@Sendable ([UUID: UInt64]) async -> Void)?) {
            appliedIngressDidCaptureWatermarksHandler = handler
        }

        func setScopedIngressBarrierWillFlushHandler(_ handler: (@Sendable (UUID) async -> Void)?) {
            scopedIngressBarrierWillFlushHandler = handler
        }

        func setWatcherActivationFailureForNewServicesForTesting(
            _ failurePoint: FileSystemService.WatcherActivationFailurePoint?
        ) {
            watcherActivationFailurePointForNewServicesForTesting = failurePoint
        }

        func setSeededShardPreparationFailureForTesting(_ enabled: Bool) {
            seededShardPreparationShouldFailForTesting = enabled
        }

        func setPendingSeededRootDidBecomeReadyHandler(
            _ handler: (@Sendable (String) async -> Void)?
        ) {
            pendingSeededRootDidBecomeReadyHandler = handler
        }

        func setPendingSeededRootDidActivateHandler(
            _ handler: (@Sendable (String) async -> Void)?
        ) {
            pendingSeededRootDidActivateHandler = handler
        }

        func setSeededPublicationActivationFailureForTesting(_ shouldFail: Bool) {
            seededPublicationActivationShouldFailForTesting = shouldFail
        }

        func handleSeededAuthorityInvalidationForTesting(
            _ event: GitWorkspaceAuthorityInvalidationEvent
        ) {
            handleSeededAuthorityInvalidation(event)
        }

        func publishedSeededAuthoritySnapshotForTesting(
            rootID: UUID
        ) -> PublishedSeededAuthorityDebugSnapshot? {
            guard let state = publishedSeededAuthorityStatesByRootID[rootID] else { return nil }
            return PublishedSeededAuthorityDebugSnapshot(
                epoch: state.epoch,
                isBlocked: state.isBlocked,
                activeMutationDepth: state.activeMutationDepth,
                isReconciling: state.isReconciling,
                reconciliationFailed: state.reconciliationFailed,
                waiterCount: publishedSeededAuthorityWaitersByRootID[rootID]?.count ?? 0,
                fullCrawlCount: publishedSeededAuthorityFullCrawlCountsByRootID[rootID] ?? 0
            )
        }

        func publishedSeededAuthorityIsCurrentForTesting(rootID: UUID) -> Bool {
            publishedSeededAuthorityIsQueryable(rootID: rootID)
        }

        func waitForPublishedSeededAuthorityReconciliationForTesting(rootID: UUID) async {
            while let task = seededAuthorityReconciliationTasksByRootID[rootID] {
                await task.value
            }
        }

        func waitForPublishedSeededAuthorityWaiterForTesting(rootID: UUID) async {
            while publishedSeededAuthorityWaitersByRootID[rootID]?.isEmpty != false {
                await Task.yield()
            }
        }

        func waitForPublishedSeededAuthorityMutationDepthForTesting(
            rootID: UUID,
            atLeast expectedDepth: Int
        ) async {
            while (publishedSeededAuthorityStatesByRootID[rootID]?.activeMutationDepth ?? 0) < expectedDepth {
                await Task.yield()
            }
        }

        func scopedIngressBarrierStatsForTesting(rootID: UUID) -> ScopedIngressBarrierStats {
            ScopedIngressBarrierStats(
                launchCount: scopedIngressBarrierLaunchCountsByRootID[rootID] ?? 0,
                joinCount: scopedIngressBarrierJoinCountsByRootID[rootID] ?? 0,
                successorCount: scopedIngressBarrierSuccessorCountsByRootID[rootID] ?? 0,
                coalescedSuccessorCount: scopedIngressBarrierCoalescedSuccessorCountsByRootID[rootID] ?? 0,
                noopCount: scopedIngressBarrierNoopCountsByRootID[rootID] ?? 0
            )
        }

        func scopedIngressBarrierFlightCountForTesting() -> Int {
            scopedIngressBarrierFlightStatesByRootID.values.reduce(0) { count, state in
                count + (state.active == nil ? 0 : 1) + (state.pending == nil ? 0 : 1)
            }
        }

        func resetScopedIngressBarrierDiagnosticsForTesting(rootID: UUID) {
            scopedIngressBarrierLaunchCountsByRootID.removeValue(forKey: rootID)
            scopedIngressBarrierJoinCountsByRootID.removeValue(forKey: rootID)
            scopedIngressBarrierSuccessorCountsByRootID.removeValue(forKey: rootID)
            scopedIngressBarrierCoalescedSuccessorCountsByRootID.removeValue(forKey: rootID)
            scopedIngressBarrierCompletionCountsByRootID.removeValue(forKey: rootID)
            scopedIngressBarrierNoopCountsByRootID.removeValue(forKey: rootID)
            scopedIngressBarrierTotalWaitMillisecondsByRootID.removeValue(forKey: rootID)
            scopedIngressBarrierMaxWaitMillisecondsByRootID.removeValue(forKey: rootID)
            lastCompletedScopedIngressBarrierByRootID.removeValue(forKey: rootID)
            completedScopedIngressBarrierCutsByRootID.removeValue(forKey: rootID)
        }

        func fileSystemServiceForTesting(rootID: UUID) -> FileSystemService? {
            rootStatesByID[rootID]?.service
        }

        func debugApplyEditsRebaseProbePathSnapshot(
            fullPath rawFullPath: String,
            rootScope: WorkspaceLookupRootScope
        ) -> ApplyEditsRebaseProbePathSnapshot? {
            let fullPath = StandardizedPath.absolute(rawFullPath)
            guard let root = rootsForPathLookup(scope: rootScope)
                .filter({ StandardizedPath.isDescendant(fullPath, of: $0.standardizedFullPath) })
                .max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count }),
                let state = rootStatesByID[root.id]
            else { return nil }
            let relativePath = URL(fileURLWithPath: fullPath)
                .relativePath(from: URL(fileURLWithPath: root.standardizedFullPath))
            guard let file = file(rootID: root.id, relativePath: relativePath),
                  file.standardizedFullPath == fullPath
            else { return nil }
            return ApplyEditsRebaseProbePathSnapshot(
                rootID: root.id,
                rootLifetimeID: state.lifetimeID,
                rootToken: state.service.diagnosticRootToken,
                rootPath: root.standardizedFullPath,
                fileID: file.id,
                fullPath: file.standardizedFullPath,
                relativePath: file.standardizedRelativePath,
                isSessionWorktree: root.kind == .sessionWorktree,
                producedAppliedIndexGeneration: appliedIndexGenerationsByRootID[root.id] ?? 0
            )
        }

        func readSearchRootDiagnosticsSnapshot(
            recentPublicationLimit: Int = 8
        ) async -> [ReadSearchRootDiagnosticsSnapshot] {
            let requestedLimit = min(max(0, recentPublicationLimit), Self.publicationInvalidationSampleLimit)
            var snapshots: [ReadSearchRootDiagnosticsSnapshot] = []
            snapshots.reserveCapacity(rootLoadOrder.count)
            for rootID in rootLoadOrder {
                guard let state = rootStatesByID[rootID] else { continue }
                let history = publicationInvalidationHistoryByRootID[rootID] ?? PublicationInvalidationHistoryState()
                let freshness = await state.service.freshnessWorkDiagnosticsSnapshot()
                let watcherActive = await state.service.isWatchingForChangesForTesting()
                snapshots.append(ReadSearchRootDiagnosticsSnapshot(
                    rootID: rootID,
                    rootToken: state.service.diagnosticRootToken,
                    rootPath: state.root.standardizedFullPath,
                    rootKind: Self.rootKindDiagnosticLabel(state.root.kind),
                    crawlCount: rootCrawlCountsByRootID[rootID] ?? 0,
                    watcherActive: watcherActive,
                    explicitWatcherDemand: explicitWatcherDemandRootIDs.contains(rootID),
                    sessionWorktreeOwnerCount: sessionWorktreeOwnerCount(rootID: rootID, lifetimeID: state.lifetimeID),
                    ingress: publisherIngressCoordinator.debugSnapshot(rootID: rootID),
                    barrier: scopedIngressBarrierDebugSnapshot(rootID: rootID),
                    freshness: freshness,
                    invalidation: PublicationInvalidationHistoryDebugSnapshot(
                        retainedSampleLimit: Self.publicationInvalidationSampleLimit,
                        totalObservedPublicationCount: history.totalObservedPublicationCount,
                        droppedPublicationSampleCount: max(0, history.totalObservedPublicationCount - history.samples.count),
                        samples: requestedLimit == 0 ? [] : Array(history.samples.suffix(requestedLimit))
                    ),
                    producedAppliedIndexGeneration: appliedIndexGenerationsByRootID[rootID] ?? 0
                ))
            }
            return snapshots
        }

        func storeWorkDiagnosticsSnapshot() -> StoreWorkDiagnosticsSnapshot {
            StoreWorkDiagnosticsSnapshot(
                invalidations: catalogInvalidationHistory,
                catalogRebuild: CatalogRebuildDebugSnapshot(
                    rebuildCount: catalogRebuildCount,
                    filterMicroseconds: catalogRebuildFilterMicroseconds,
                    sortMicroseconds: catalogRebuildSortMicroseconds,
                    fileSortMicroseconds: catalogRebuildFileSortMicroseconds,
                    folderSortMicroseconds: catalogRebuildFolderSortMicroseconds,
                    sortResidualMicroseconds: catalogRebuildSortResidualMicroseconds,
                    sortReconciliationDeltaMicroseconds: catalogRebuildSortReconciliationDeltaMicroseconds,
                    sortInvocationCount: catalogRebuildSortInvocationCount,
                    sortFileInputCount: catalogRebuildSortFileInputCount,
                    sortFolderInputCount: catalogRebuildSortFolderInputCount,
                    materializationMicroseconds: catalogRebuildMaterializationMicroseconds,
                    pathIndexKeyMicroseconds: catalogRebuildPathIndexKeyMicroseconds,
                    pathIndexConstructionMicroseconds: catalogRebuildPathIndexConstructionMicroseconds,
                    compositionCacheResidualMicroseconds: catalogRebuildCompositionCacheResidualMicroseconds,
                    totalMicroseconds: catalogRebuildTotalMicroseconds,
                    lastFileCount: catalogRebuildLastFileCount,
                    lastRootCount: catalogRebuildLastRootCount
                ),
                rootCatalogShards: rootCatalogShardDebugSnapshot()
            )
        }

        private func recordCatalogInvalidation(
            reasons: Set<CatalogInvalidationReason>,
            affectedRootIDs: Set<UUID>,
            affectedRootKinds: Set<WorkspaceRootKind>,
            evictedScopes: [WorkspaceLookupRootScope]
        ) {
            nextCatalogInvalidationSequence &+= 1
            catalogInvalidationHistory.append(CatalogInvalidationDebugEvent(
                sequence: nextCatalogInvalidationSequence,
                reasons: reasons.map(\.rawValue).sorted(),
                affectedRootIDs: affectedRootIDs.sorted { $0.uuidString < $1.uuidString },
                affectedRootKinds: affectedRootKinds.map(Self.rootKindDiagnosticLabel).sorted(),
                evictedScopes: evictedScopes.map(Self.scopeDiagnosticLabel).sorted()
            ))
            if catalogInvalidationHistory.count > 64 {
                catalogInvalidationHistory.removeFirst(catalogInvalidationHistory.count - 64)
            }
        }

        private func recordCatalogRebuild(
            filterMicroseconds: UInt64,
            sortMicroseconds: UInt64,
            fileSortMicroseconds: UInt64,
            folderSortMicroseconds: UInt64,
            sortResidualMicroseconds: UInt64,
            sortReconciliationDeltaMicroseconds: Int64,
            sortInvocationCount: Int,
            sortFileInputCount: Int,
            sortFolderInputCount: Int,
            materializationMicroseconds: UInt64,
            pathIndexKeyMicroseconds: UInt64,
            pathIndexConstructionMicroseconds: UInt64,
            compositionCacheResidualMicroseconds: UInt64,
            totalMicroseconds: UInt64,
            fileCount: Int,
            rootCount: Int
        ) {
            catalogRebuildCount += 1
            catalogRebuildFilterMicroseconds &+= filterMicroseconds
            catalogRebuildSortMicroseconds &+= sortMicroseconds
            catalogRebuildFileSortMicroseconds &+= fileSortMicroseconds
            catalogRebuildFolderSortMicroseconds &+= folderSortMicroseconds
            catalogRebuildSortResidualMicroseconds &+= sortResidualMicroseconds
            catalogRebuildSortReconciliationDeltaMicroseconds += sortReconciliationDeltaMicroseconds
            catalogRebuildSortInvocationCount += sortInvocationCount
            catalogRebuildSortFileInputCount += sortFileInputCount
            catalogRebuildSortFolderInputCount += sortFolderInputCount
            catalogRebuildMaterializationMicroseconds &+= materializationMicroseconds
            catalogRebuildPathIndexKeyMicroseconds &+= pathIndexKeyMicroseconds
            catalogRebuildPathIndexConstructionMicroseconds &+= pathIndexConstructionMicroseconds
            catalogRebuildCompositionCacheResidualMicroseconds &+= compositionCacheResidualMicroseconds
            catalogRebuildTotalMicroseconds &+= totalMicroseconds
            catalogRebuildLastFileCount = fileCount
            catalogRebuildLastRootCount = rootCount
        }

        private func rootCatalogShardDebugSnapshot() -> RootCatalogShardDebugSnapshot {
            var trackedRootIDs = Set(rootStatesByID.keys)
            trackedRootIDs.formUnion(publishedRootCatalogShardsByRootID.keys)
            trackedRootIDs.formUnion(rootCatalogShardWeakReferencesByRootID.keys)

            let staleDiagnosticRootIDs = Set(rootCatalogShardBuildCountsByRootID.keys).subtracting(trackedRootIDs)
            for rootID in staleDiagnosticRootIDs {
                rootCatalogShardBuildCountsByRootID.removeValue(forKey: rootID)
                rootCatalogShardFullPathIndexBuildCountsByRootID.removeValue(forKey: rootID)
                rootCatalogShardOverlayPathIndexBuildCountsByRootID.removeValue(forKey: rootID)
                rootCatalogShardPatchCountsByRootID.removeValue(forKey: rootID)
                rootCatalogShardAuthoritativeRebuildCountsByRootID.removeValue(forKey: rootID)
                rootCatalogShardFallbackCountsByRootID.removeValue(forKey: rootID)
                rootCatalogShardFallbackReasonCountsByRootID.removeValue(forKey: rootID)
                rootCatalogShardFallbackLifetimeIDsByRootID.removeValue(forKey: rootID)
                rootCatalogShardBackstopCountsByRootID.removeValue(forKey: rootID)
                rootCatalogShardMaxLiveGenerationCountsByRootID.removeValue(forKey: rootID)
            }

            let roots = trackedRootIDs.sorted { $0.uuidString < $1.uuidString }.map { rootID in
                let liveShards = liveRootCatalogShards(rootID: rootID)
                let publishedShard = publishedRootCatalogShardsByRootID[rootID]
                let liveGenerations = liveShards.map(\.key.topologyGeneration).sorted()
                let retainedGenerations = liveShards.compactMap { shard -> UInt64? in
                    guard let publishedShard else { return shard.key.topologyGeneration }
                    return shard === publishedShard ? nil : shard.key.topologyGeneration
                }.sorted()
                let maxLiveCount = max(
                    rootCatalogShardMaxLiveGenerationCountsByRootID[rootID] ?? 0,
                    liveShards.count
                )
                rootCatalogShardMaxLiveGenerationCountsByRootID[rootID] = maxLiveCount
                let lifetimeID = publishedShard?.key.lifetimeID
                    ?? rootCatalogShardDeltaStatesByRootID[rootID]?.lifetimeID
                    ?? rootStatesByID[rootID]?.lifetimeID
                    ?? rootCatalogShardFallbackLifetimeIDsByRootID[rootID]
                    ?? liveShards.first?.key.lifetimeID
                if let lifetimeID {
                    resetRootCatalogShardFallbackDiagnosticsIfLifetimeChanged(
                        rootID: rootID,
                        lifetimeID: lifetimeID
                    )
                }
                return RootCatalogShardGenerationDebugSnapshot(
                    rootID: rootID,
                    lifetimeID: lifetimeID,
                    publishedTopologyGeneration: publishedShard?.key.topologyGeneration,
                    liveTopologyGenerations: liveGenerations,
                    retainedTopologyGenerations: retainedGenerations,
                    buildCount: rootCatalogShardBuildCountsByRootID[rootID] ?? 0,
                    pathIndexBuildCount: rootCatalogShardFullPathIndexBuildCountsByRootID[rootID] ?? 0,
                    overlayPathIndexBuildCount: rootCatalogShardOverlayPathIndexBuildCountsByRootID[rootID] ?? 0,
                    patchCount: rootCatalogShardPatchCountsByRootID[rootID] ?? 0,
                    authoritativeRebuildCount: rootCatalogShardAuthoritativeRebuildCountsByRootID[rootID] ?? 0,
                    fallbackCount: rootCatalogShardFallbackCountsByRootID[rootID] ?? 0,
                    fallbackReasonCounts: rootCatalogShardFallbackReasonCountsByRootID[rootID] ?? [:],
                    lastAppliedIndexGeneration: rootCatalogShardDeltaStatesByRootID[rootID]?.lastAppliedIndexGeneration,
                    deltaStateDirty: rootCatalogShardDeltaStatesByRootID[rootID]?.isDirty ?? false,
                    backstopCount: rootCatalogShardBackstopCountsByRootID[rootID] ?? 0,
                    maxLiveGenerationCount: maxLiveCount
                )
            }
            return RootCatalogShardDebugSnapshot(
                liveGenerationCapPerRoot: Self.maxLiveRootCatalogShardGenerationsPerRoot,
                maxPatchLogicalMutationCount: Self.maxRootCatalogShardPatchLogicalMutationCount,
                publishedShardCount: publishedRootCatalogShardsByRootID.count,
                totalBuildCount: rootCatalogShardBuildCountsByRootID.values.reduce(0, +),
                totalBackstopCount: rootCatalogShardBackstopCountsByRootID.values.reduce(0, +),
                singleShardCompositionReuseCount: rootCatalogShardSingleShardCompositionReuseCount,
                genericMergeElementVisitCount: rootCatalogShardGenericMergeElementVisitCount,
                shadowComparisonCount: rootCatalogShardShadowComparisonCount,
                shadowMismatchCount: rootCatalogShardShadowMismatchCount,
                lastShadowByteCount: rootCatalogShardLastShadowByteCount,
                roots: roots
            )
        }

        private static func rootKindDiagnosticLabel(_ kind: WorkspaceRootKind) -> String {
            switch kind {
            case .primaryWorkspace: "primary_workspace"
            case .workspaceGitData: "workspace_git_data"
            case .supplementalSystem: "supplemental_system"
            case .sessionWorktree: "session_worktree"
            }
        }

        private static func scopeDiagnosticLabel(_ scope: WorkspaceLookupRootScope) -> String {
            switch scope {
            case .visibleWorkspace:
                "visible_workspace"
            case .visibleWorkspacePlusGitData:
                "visible_workspace_plus_git_data"
            case .allLoaded:
                "all_loaded"
            case .allLoadedExcludingGitData:
                "all_loaded_excluding_git_data"
            case let .sessionBoundWorkspace(logicalRootPaths, physicalRootPaths):
                "session_bound_workspace(logical=\(logicalRootPaths.sorted().joined(separator: ","));physical=\(physicalRootPaths.sorted().joined(separator: ",")))"
            case let .validatedSessionBoundWorkspace(canonicalRoots, physicalRoots):
                "validated_session_bound_workspace(logical=\(canonicalRoots.map(\.standardizedFullPath).sorted().joined(separator: ","));physical=\(physicalRoots.map(\.standardizedFullPath).sorted().joined(separator: ",")))"
            }
        }

        private static func debugElapsedMicroseconds(since start: UInt64, through end: UInt64) -> UInt64 {
            end >= start ? (end - start) / 1000 : 0
        }

        private func scopedIngressBarrierDebugSnapshot(rootID: UUID) -> ScopedIngressBarrierDebugSnapshot {
            let now = debugNowNanoseconds()
            let state = scopedIngressBarrierFlightStatesByRootID[rootID]
            let active = state?.active.map { flight in
                ScopedIngressBarrierDebugSnapshot.Active(
                    targetWatcherWatermark: flight.target.watcherAcceptedWatermark.rawValue,
                    targetServicePublicationSequence: flight.target.acceptedServicePublicationSequence,
                    ageMilliseconds: Self.elapsedMilliseconds(
                        since: flight.startedAtNanoseconds,
                        now: now
                    )
                )
            }
            let pending = state?.pending.map { pending in
                ScopedIngressBarrierDebugSnapshot.Pending(
                    targetWatcherWatermark: pending.target.watcherAcceptedWatermark.rawValue,
                    targetServicePublicationSequence: pending.target.acceptedServicePublicationSequence,
                    ageMilliseconds: Self.elapsedMilliseconds(
                        since: pending.enqueuedAtNanoseconds,
                        now: now
                    )
                )
            }
            return ScopedIngressBarrierDebugSnapshot(
                launchCount: scopedIngressBarrierLaunchCountsByRootID[rootID] ?? 0,
                joinCount: scopedIngressBarrierJoinCountsByRootID[rootID] ?? 0,
                successorCount: scopedIngressBarrierSuccessorCountsByRootID[rootID] ?? 0,
                coalescedSuccessorCount: scopedIngressBarrierCoalescedSuccessorCountsByRootID[rootID] ?? 0,
                completionCount: scopedIngressBarrierCompletionCountsByRootID[rootID] ?? 0,
                noopCount: scopedIngressBarrierNoopCountsByRootID[rootID] ?? 0,
                totalWaitMilliseconds: scopedIngressBarrierTotalWaitMillisecondsByRootID[rootID] ?? 0,
                maxWaitMilliseconds: scopedIngressBarrierMaxWaitMillisecondsByRootID[rootID] ?? 0,
                active: active,
                pending: pending,
                lastCompleted: lastCompletedScopedIngressBarrierByRootID[rootID]
            )
        }

        func retainedReadSearchDiagnosticRootIDsForTesting() -> Set<UUID> {
            Set(scopedIngressBarrierLaunchCountsByRootID.keys)
                .union(scopedIngressBarrierJoinCountsByRootID.keys)
                .union(scopedIngressBarrierSuccessorCountsByRootID.keys)
                .union(scopedIngressBarrierCoalescedSuccessorCountsByRootID.keys)
                .union(scopedIngressBarrierCompletionCountsByRootID.keys)
                .union(scopedIngressBarrierNoopCountsByRootID.keys)
                .union(scopedIngressBarrierTotalWaitMillisecondsByRootID.keys)
                .union(scopedIngressBarrierMaxWaitMillisecondsByRootID.keys)
                .union(lastCompletedScopedIngressBarrierByRootID.keys)
                .union(publicationInvalidationHistoryByRootID.keys)
                .union(rootCrawlCountsByRootID.keys)
        }

        private func recordScopedIngressBarrierCompletion(
            rootID: UUID,
            token: UInt64,
            target: ScopedIngressBarrierTarget,
            sample: WorkspaceIngressBarrierSample,
            startedAtNanoseconds: UInt64,
            completedAtNanoseconds: UInt64
        ) {
            guard rootStatesByID[rootID] != nil else { return }
            scopedIngressBarrierCompletionCountsByRootID[rootID, default: 0] += 1
            let durationMilliseconds = Self.elapsedMilliseconds(
                since: startedAtNanoseconds,
                now: completedAtNanoseconds
            )
            scopedIngressBarrierTotalWaitMillisecondsByRootID[rootID, default: 0] += durationMilliseconds
            scopedIngressBarrierMaxWaitMillisecondsByRootID[rootID] = max(
                scopedIngressBarrierMaxWaitMillisecondsByRootID[rootID] ?? 0,
                durationMilliseconds
            )
            guard token > (lastCompletedScopedIngressBarrierByRootID[rootID]?.token ?? 0) else { return }
            lastCompletedScopedIngressBarrierByRootID[rootID] = ScopedIngressBarrierDebugSnapshot.Completed(
                token: token,
                targetWatcherWatermark: target.watcherAcceptedWatermark.rawValue,
                targetServicePublicationSequence: target.acceptedServicePublicationSequence,
                publishedServicePublicationSequence: sample.publishedServicePublicationSequence,
                appliedServicePublicationSequence: sample.appliedServicePublicationSequence,
                appliedWatcherWatermark: sample.appliedWatcherWatermark,
                durationMilliseconds: durationMilliseconds
            )
        }

        private func recordPublicationInvalidationDiagnostics(
            rootID: UUID,
            servicePublicationSequence: UInt64,
            watcherAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark?,
            recorder: PublicationInvalidationRecorder
        ) {
            guard rootStatesByID[rootID] != nil else { return }
            let sample = makePublicationInvalidationDebugSample(
                servicePublicationSequence: servicePublicationSequence,
                watcherAcceptedWatermark: watcherAcceptedWatermark,
                recorder: recorder
            )
            var history = publicationInvalidationHistoryByRootID[rootID] ?? PublicationInvalidationHistoryState()
            history.totalObservedPublicationCount += 1
            history.samples.append(sample)
            if history.samples.count > Self.publicationInvalidationSampleLimit {
                history.samples.removeFirst(history.samples.count - Self.publicationInvalidationSampleLimit)
            }
            publicationInvalidationHistoryByRootID[rootID] = history
        }

        private func makePublicationInvalidationDebugSample(
            servicePublicationSequence: UInt64,
            watcherAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark?,
            recorder: PublicationInvalidationRecorder
        ) -> PublicationInvalidationDebugSample {
            PublicationInvalidationDebugSample(
                servicePublicationSequence: servicePublicationSequence,
                watcherAcceptedWatermark: watcherAcceptedWatermark?.rawValue,
                preparedDeltaCount: recorder.preparedDeltaCount,
                topologyInvalidationCount: recorder.topologyInvalidationCount,
                catalogGenerationAdvanceCount: recorder.catalogGenerationAdvanceCount,
                searchCatalogCacheClearCount: recorder.searchCatalogCacheClearCount,
                pathWorkerInvalidationRequestCount: recorder.pathWorkerInvalidationRequestCount,
                contentInvalidationCount: recorder.contentInvalidationCount,
                distinctContentKeyCount: recorder.distinctContentKeys.count,
                decodedCacheInvalidationRequestCount: recorder.decodedCacheInvalidationRequestCount,
                codemapInvalidationRequestCount: recorder.codemapInvalidationRequestCount,
                appliedIndexEventYieldCount: recorder.appliedIndexEventYieldCount
            )
        }

        private static func elapsedMilliseconds(since start: UInt64, now: UInt64) -> UInt64 {
            guard now >= start else { return 0 }
            return (now - start) / 1_000_000
        }

        func searchDecodedContentCacheSnapshotForTesting() async -> WorkspaceSearchDecodedContentCache.Snapshot {
            await searchDecodedContentCache.snapshotForTesting()
        }

        func interactiveReadCacheSnapshotForTesting() async -> WorkspaceInteractiveReadCache.Snapshot {
            await interactiveReadCache.snapshotForTesting()
        }

        func searchLaneSnapshotForTesting() async -> StoreBackedWorkspaceSearchLane.Snapshot {
            await storeBackedSearchLane.snapshotForTesting()
        }

        func configureSearchLaneForTesting(
            _ configuration: StoreBackedWorkspaceSearchLane.Configuration
        ) async -> StoreBackedWorkspaceSearchLane.DebugConfigurationUpdateResult {
            await storeBackedSearchLane.configureForTesting(configuration)
        }

        func resetSearchLaneConfigurationForTesting() async -> StoreBackedWorkspaceSearchLane.DebugConfigurationUpdateResult {
            await storeBackedSearchLane.resetConfigurationForTesting()
        }

        func setSearchLanePermitAcquiredHandlerForTesting(
            _ handler: (@Sendable () async -> Void)?
        ) async {
            await storeBackedSearchLane.setPermitAcquiredHandlerForTesting(handler)
        }

        func setStoreEditDeferredPublicationDidRegisterHandlerForTesting(
            _ handler: (@Sendable (UUID, String) async -> Void)?
        ) {
            storeEditDeferredPublicationDidRegisterHandler = handler
        }

        func setSearchContentReadChunkHandlerForTesting(
            rootID: UUID,
            _ handler: (@Sendable (String) async -> Void)?
        ) async throws {
            let state = try state(for: rootID)
            await state.service.setContentReadChunkHandlerForTesting(handler)
        }

        func resetSearchContentFingerprintRequestCountForTesting(rootID: UUID) async throws {
            let state = try state(for: rootID)
            await state.service.resetContentFingerprintRequestCountForTesting()
        }

        func searchContentFingerprintRequestCountForTesting(rootID: UUID) async throws -> Int {
            let state = try state(for: rootID)
            return await state.service.contentFingerprintRequestCountSnapshotForTesting()
        }

        func setCachedSearchContentWatcherActiveOverrideForTesting(
            rootID: UUID,
            _ isActive: Bool?
        ) async throws {
            let state = try state(for: rootID)
            await state.service.setCachedSearchContentWatcherActiveOverrideForTesting(isActive)
        }
    #endif

    private enum ExplicitDiskLookupCandidatesResult {
        case candidates([(rootID: UUID, relativePath: String)])
        case ambiguousAlias
    }

    private struct RootIndexBuffers {
        var foldersByID: [UUID: WorkspaceFolderRecord] = [:]
        var filesByID: [UUID: WorkspaceFileRecord] = [:]
        var folderIDsByStandardizedFullPath: [String: UUID] = [:]
        var fileIDsByStandardizedFullPath: [String: UUID] = [:]
    }

    private struct RootCatalogCanonicalConfigurationIdentity: Hashable {
        let canonicalPath: String
        let loadConfiguration: RootLoadConfiguration
    }

    private struct RootCatalogShardKey: Hashable {
        let canonicalConfigurationIdentity: RootCatalogCanonicalConfigurationIdentity
        let rootID: UUID
        let lifetimeID: UUID
        let topologyGeneration: UInt64
    }

    private struct RootCatalogProjectionFile {
        let file: WorkspaceFileRecord
        let language: LanguageType
    }

    private final class RootCatalogShard: @unchecked Sendable {
        let key: RootCatalogShardKey
        let root: WorkspaceRootRecord
        let files: [WorkspaceFileRecord]
        let projectionFiles: [RootCatalogProjectionFile]
        let projectionFileIndexByID: [UUID: Int]
        let folders: [WorkspaceFolderRecord]
        let entries: [WorkspaceSearchCatalogEntry]
        let pathSearchIndex: WorkspaceSearchRootPathIndex?
        let appliedIndexGeneration: UInt64

        var folderCount: Int {
            folders.count
        }

        init(
            key: RootCatalogShardKey,
            root: WorkspaceRootRecord,
            files: [WorkspaceFileRecord],
            precomputedProjectionFiles: [RootCatalogProjectionFile]? = nil,
            folders: [WorkspaceFolderRecord],
            entries: [WorkspaceSearchCatalogEntry],
            pathSearchIndex: WorkspaceSearchRootPathIndex?,
            appliedIndexGeneration: UInt64
        ) {
            self.key = key
            self.root = root
            self.files = files
            let projectionFiles = precomputedProjectionFiles ?? files
                .compactMap { file in
                    let fileExtension = (file.name as NSString).pathExtension
                    guard SyntaxManager.supportsCodeMap(fileExtension: fileExtension),
                          let language = SyntaxManager.shared.language(forFileExtension: fileExtension)
                    else { return nil }
                    return RootCatalogProjectionFile(file: file, language: language)
                }
                .sorted { lhs, rhs in
                    WorkspaceFileContextStore.searchRootCatalogFilePrecedes(lhs.file, rhs.file)
                }
            self.projectionFiles = projectionFiles
            projectionFileIndexByID = Dictionary(
                uniqueKeysWithValues: projectionFiles.enumerated().map { ($0.element.file.id, $0.offset) }
            )
            self.folders = folders
            self.entries = entries
            self.pathSearchIndex = pathSearchIndex
            self.appliedIndexGeneration = appliedIndexGeneration
        }
    }

    private struct CodemapProjectionCatalogShardBuildSnapshot: @unchecked Sendable {
        let authority: CodemapRootAuthority
        let key: RootCatalogShardKey
        let root: WorkspaceRootRecord
        let appliedIndexGeneration: UInt64
        let projectionInvalidationGeneration: UInt64
        let files: [WorkspaceFileRecord]
        let folders: [WorkspaceFolderRecord]
        let managedOnlyFileIDs: Set<UUID>
        let managedOnlyFolderIDs: Set<UUID>
    }

    private enum CodemapProjectionCatalogShardPublicationDisposition {
        case ready
        case retry
        case unavailable
    }

    private final class WeakRootCatalogShardReference {
        weak var shard: RootCatalogShard?

        init(_ shard: RootCatalogShard) {
            self.shard = shard
        }
    }

    private struct RootCatalogMergeCursor {
        let shardIndex: Int
        let elementIndex: Int
    }

    private struct AuthoritativeCatalogComponents {
        let files: [WorkspaceFileRecord]
        let folders: [WorkspaceFolderRecord]
        let entries: [WorkspaceSearchCatalogEntry]
    }

    private struct RootCatalogShardDeltaState {
        let lifetimeID: UUID
        var lastAppliedIndexGeneration: UInt64
        var isDirty: Bool
        let capability: WorkspaceSearchCatalogAccessRequirement
    }

    private enum RootCatalogShardBuildKind {
        case patch
        case authoritative
        case promotion
    }

    private struct RootCatalogShardBuilderOutput {
        let files: [WorkspaceFileRecord]
        let folders: [WorkspaceFolderRecord]
        let logicalMutationCount: Int
        let pathIndexChangedFileIDs: Set<UUID>
    }

    private struct SearchCatalogRootDependency: Hashable {
        let canonicalIdentity: String
        let rootID: UUID
        let lifetimeID: UUID
        let generation: UInt64
    }

    private enum SearchCatalogSnapshotValidationToken: Hashable {
        case staticScope(generation: UInt64)
        case sessionBound(
            logicalRootPaths: [String],
            physicalRootPaths: [String],
            dependencies: [SearchCatalogRootDependency]
        )
    }

    private struct SearchCatalogSnapshotCacheEntry {
        let validationToken: SearchCatalogSnapshotValidationToken
        let capability: WorkspaceSearchCatalogAccessRequirement
        let snapshot: WorkspaceSearchCatalogSnapshot
        var lastAccessSequence: UInt64
    }

    private struct SessionCatalogGenerationState {
        let validationToken: SearchCatalogSnapshotValidationToken
        let generation: UInt64
    }

    private struct StaticPathMatchSnapshotCacheEntry {
        let snapshot: StaticPathMatchData
        var lastAccessSequence: UInt64
    }

    private let sessionRootLifetimeClock = WorkspaceSessionRootLifetimeClock()
    private var rootStatesByID: [UUID: RootState] = [:]
    private var rootIDsByStandardizedPath: [String: UUID] = [:]
    private var foldersByID: [UUID: WorkspaceFolderRecord] = [:]
    private var filesByID: [UUID: WorkspaceFileRecord] = [:]
    private var folderIDsByStandardizedFullPath: [String: UUID] = [:]
    private var fileIDsByStandardizedFullPath: [String: UUID] = [:]
    private var managedOnlyFileIDs = Set<UUID>()
    private var managedOnlyFolderIDs = Set<UUID>()
    private var rootLoadOrder: [UUID] = []
    private var unloadingRootPaths: Set<String> = []
    private var unloadWaitersByRootPath: [String: [UUID: CheckedContinuation<Void, Error>]] = [:]
    private var rootLoadFlightsByPath: [String: RootLoadFlight] = [:]
    private var rootLoadConfigurationsByPath: [String: RootLoadConfiguration] = [:]
    private var catalogGenerationsByScope: [WorkspaceLookupRootScope: UInt64] = [
        .visibleWorkspace: 0,
        .visibleWorkspacePlusGitData: 0,
        .allLoaded: 0
    ]
    private var catalogGenerationsByRootID: [UUID: UInt64] = [:]
    private var sessionCatalogGenerationStatesByScope: [WorkspaceLookupRootScope: SessionCatalogGenerationState] = [:]
    private var nextSessionCatalogGeneration: UInt64 = 0
    private var searchCatalogSnapshotsByScope: [WorkspaceLookupRootScope: SearchCatalogSnapshotCacheEntry] = [:]
    private var nextSearchCatalogSnapshotAccessSequence: UInt64 = 0
    private var publishedRootCatalogShardsByRootID: [UUID: RootCatalogShard] = [:]
    private struct RootSeedSearchShadow {
        let scope: WorkspaceRootSeedShadowScope
        let control: WorkspaceProjectedPathSearchShadowControl
    }

    private var rootSeedSearchShadowsByRootID: [UUID: RootSeedSearchShadow] = [:]
    private var rootCatalogShardWeakReferencesByRootID: [UUID: [WeakRootCatalogShardReference]] = [:]
    private var rootCatalogShardDeltaStatesByRootID: [UUID: RootCatalogShardDeltaState] = [:]
    private var pathMatchSnapshotIdentitiesByScope: [WorkspaceLookupRootScope: PathMatchCacheIdentity] = [:]
    private var staticPathMatchSnapshotsByScope: [WorkspaceLookupRootScope: StaticPathMatchSnapshotCacheEntry] = [:]
    private var nextStaticPathMatchSnapshotAccessSequence: UInt64 = 0
    private let storeBackedSearchLane: StoreBackedWorkspaceSearchLane
    private let rootReusableSnapshotCoordinator = WorkspaceRootReusableSnapshotCoordinator.shared
    private let rootMaterializationHintEvaluator = WorkspaceRootMaterializationHintEvaluator.shared
    private let rootSeedPlanner = WorkspaceRootSeedPlanner.shared
    private let workspaceStateAuthority = GitWorkspaceStateAuthority.shared
    private let worktreeSeedGitService = GitService()
    private let searchDecodedContentCache = WorkspaceSearchDecodedContentCache()
    private let interactiveReadCache = WorkspaceInteractiveReadCache()
    private let searchContentSchedulerOwnerID = UUID()
    private let interactiveReadSchedulerOwnerID = UUID()
    #if os(macOS)
        private let searchContentMemoryPressureSource: DispatchSourceMemoryPressure
    #endif
    private var searchContentInvalidationEpochsByFileID: [UUID: UInt64] = [:]
    private var nextSearchContentInvalidationEpoch: UInt64 = 0
    private var activePublicationInvalidationBatch: PublicationInvalidationBatch?
    private static let maxCachedSearchCatalogSnapshotScopes = 16
    private static let maxCachedStaticPathMatchSnapshotScopes = 16
    /// Covers overlapping readers/index builds while bounding retained full-root arrays. At the cap,
    /// callers receive an authoritative uncached rebuild until older ARC leases drain.
    private static let maxLiveRootCatalogShardGenerationsPerRoot = 8
    // The checked-in WI-3 baseline (`docs/investigations/mcp-tool-throughput-wi3-baseline-2026-06-11.md`)
    // records authoritative catalog rebuild work in roots/files, and its fixture
    // proves a three-file/two-root rebuild, but it does not establish a multi-record crossover.
    // Patch exactly one logical catalog record—the common single-file watcher case—and rebuild for
    // every broader batch until measured evidence supports increasing this deliberately conservative cap.
    private static let maxRootCatalogShardPatchLogicalMutationCount = 1
    private static let defaultMaxPendingDeltasPerRoot = 10000
    private let pathMatchWorker = PathMatchWorker()
    private let deferredReplayBuffer = DeferredReplayBufferActor(
        maxPendingDeltasPerRoot: WorkspaceFileContextStore.defaultMaxPendingDeltasPerRoot
    )
    private let codemapRuntimeProvider: CodeMapArtifactRuntimeProvider.Factory
    private let codemapLocalGitClassificationProbe: WorkspaceCodemapLocalGitClassificationProbe
    private let codemapGitEligibilityProbe: WorkspaceCodemapGitEligibilityProbe
    private let codemapProjectionPreloadRetryPolicy: CodemapProjectionPreloadRetryPolicy
    private let selectionGraphFactory: WorkspaceCodemapSelectionGraphFactory
    private let selectionGraphQueryBudgetPolicy: WorkspaceCodemapStoreSelectionGraphQueryBudgetPolicy
    private let automaticSelectionAccountingMaximum: Int
    private let codemapCancellationCleanupHook: @Sendable (WorkspaceCodemapArtifactDemandTicket) async -> Void
    private let codemapReadyPublicationHook: @Sendable (WorkspaceCodemapArtifactDemandTicket) async -> Void
    private let codemapGraphPublicationWaiter: @Sendable (WorkspaceCodemapRootEpoch) async -> Void
    private let codemapDemandResultHook: @Sendable (
        WorkspaceCodemapArtifactDemandTicket,
        WorkspaceCodemapBindingDemandResult
    ) async -> WorkspaceCodemapBindingDemandResult
    private let codemapAutomaticSelectionQueryHook: @Sendable (WorkspaceCodemapRootEpoch) async -> Void
    private struct TerminalNonGitCodemapCacheEntry {
        let standardizedRootPath: String
        let proof: WorkspaceCodemapNonGitFilesystemProof
    }

    private var codemapSessionsByRootEpoch: [WorkspaceCodemapRootEpoch: CodemapRootSession] = [:]
    private var codemapEligibilityFlightsByRootEpoch: [
        WorkspaceCodemapRootEpoch: CodemapEligibilityFlight
    ] = [:]
    private var codemapCompletedEligibilityByRootEpoch: [
        WorkspaceCodemapRootEpoch: CodemapCompletedEligibility
    ] = [:]
    private var codemapProjectionPreloadLaunchesByRootEpoch: [
        WorkspaceCodemapRootEpoch: CodemapProjectionPreloadLaunch
    ] = [:]
    private var codemapProjectionPreloadRetriesByRootEpoch: [
        WorkspaceCodemapRootEpoch: CodemapProjectionPreloadRetry
    ] = [:]
    private var codemapProjectionDemandsByID: [UUID: CodemapProjectionDemandRecord] = [:]
    private var terminalCodemapProjectionDemandsByID: [
        UUID: TerminalCodemapProjectionDemandRecord
    ] = [:]
    private var terminalNonGitCodemapCacheByEpoch: [
        WorkspaceCodemapRootEpoch: TerminalNonGitCodemapCacheEntry
    ] = [:]
    #if DEBUG
        private let codemapProjectionPreloadLaunchPolicyForTesting: CodemapProjectionPreloadLaunchPolicyForTesting
        private let codemapAutomaticRetainedProjectionDemandPolicyForTesting:
            CodemapAutomaticRetainedProjectionDemandPolicyForTesting
        private let codemapSelectionGraphRuntimeQueryOverrideForTesting: (@Sendable (
            WorkspaceCodemapRootEpoch,
            WorkspaceCodemapSelectionGraphRuntimeQuery
        ) async -> WorkspaceCodemapSelectionGraphRuntimeQueryDisposition?)?
        private var debugCodemapProjectionHoldOwners: [
            UUID: (rootEpoch: WorkspaceCodemapRootEpoch, engine: WorkspaceCodemapBindingEngine)
        ] = [:]
        private var debugCodemapProjectionHoldExpiryTasks: [UUID: Task<Void, Never>] = [:]
        private var codemapProjectionPreloadStoreEvents: [CodemapProjectionPreloadStoreEvent] = []
        private var nextCodemapProjectionPreloadStoreEventOrdinal: UInt64 = 0
        private var codemapProjectionPreloadStartHandler: (@Sendable (WorkspaceCodemapRootEpoch) async -> Void)?
        private var codemapProjectionCatalogBuildHandler: (@Sendable (WorkspaceCodemapRootEpoch) async -> Void)?
        private var codemapStructureSeedAdmissionRequestCountForTesting = 0
        private var codeStructureSelectedMetadataResolutionRequestCountForTesting = 0
        private var codemapPresentationCandidateRequestCountForTesting = 0
        private var codemapArtifactDemandRequestCountForTesting = 0
        private var codemapPresentationFreezeRequestCountForTesting = 0
        private var codemapSetupTaskCreationCountForTesting = 0
        private var codemapDemandTaskCreationCountForTesting = 0
        private var codemapTargetedReadyFreezeCountForTesting = 0
        private var codemapFullRootGraphFreezeCountForTesting = 0
        private var codemapGraphBatchSignalCountForTesting = 0
        private var codemapGraphBatchFlushCountForTesting = 0
        private var codemapGraphWorkerStartCountForTesting = 0
        private var codemapProjectionRecoveryObserverStartCountForTesting = 0
        private var codemapProjectionRecoveryObserverRearmCountForTesting = 0
        private var codemapGraphPublicationWillFlushHandlerForTesting:
            (@Sendable (WorkspaceCodemapRootEpoch, Int) async -> Void)?
        private var codemapProjectionRecoveryObserverWillWaitHandlerForTesting:
            (@Sendable (WorkspaceCodemapRootEpoch) async -> Void)?
    #endif
    private var codemapCleanupFlightsByRootID: [UUID: CodemapCleanupFlight] = [:]
    private var codemapPathInvalidationFlightsByRootEpoch: [
        WorkspaceCodemapRootEpoch: CodemapPathInvalidationFlight
    ] = [:]
    private var codemapPathFenceTokensByID: [UUID: CodemapPathFenceToken] = [:]
    private var codemapRootMutationFenceTokensByRootEpoch: [
        WorkspaceCodemapRootEpoch: CodemapRootMutationFenceToken
    ] = [:]
    private var codemapRootMutationFenceWaitersByRootEpoch: [
        WorkspaceCodemapRootEpoch: [UUID: CheckedContinuation<Void, Never>]
    ] = [:]
    private var codemapProjectionPreloadReschedulePendingRootEpochs: Set<WorkspaceCodemapRootEpoch> = []
    private var codemapPathLocalCatalogMutationDepthByRootID: [UUID: Int] = [:]
    private var codemapAuthorityGenerationsByRootEpoch: [WorkspaceCodemapRootEpoch: UInt64] = [:]
    private var codemapProjectionInvalidationGenerationsByRootEpoch: [
        WorkspaceCodemapRootEpoch: UInt64
    ] = [:]
    private var codemapAutomaticSelectionPublicationPermitsByRootEpoch: [
        WorkspaceCodemapRootEpoch: [UUID: CodemapAutomaticSelectionWeakPublicationPermit]
    ] = [:]
    private var codemapSelectionGraphReadinessContinuations: [
        UUID: AsyncStream<WorkspaceCodemapSelectionGraphReadinessEvent>.Continuation
    ] = [:]
    private var codemapMarkerReadinessContinuations: [
        UUID: AsyncStream<WorkspaceCodemapMarkerReadinessEvent>.Continuation
    ] = [:]
    private var fileSystemDeltaContinuations: [UUID: AsyncStream<WorkspaceFileSystemDeltaEvent>.Continuation] = [:]
    private var appliedIndexContinuations: [UUID: AsyncStream<WorkspaceAppliedIndexBatchEvent>.Continuation] = [:]
    private var appliedIndexGenerationsByRootID: [UUID: UInt64] = [:]
    private var sliceRebaseSourceEntries: [SliceRebaseSourceCacheKey: SliceRebaseSourceCacheEntry] = [:]
    private var sliceRebaseSourceEstimatedBytes = 0
    private var sliceRebaseSourceAccessOrdinal: UInt64 = 0
    private static let maxSliceRebaseSourceEntryCount = 64
    private static let maxSliceRebaseSourceTotalBytes = 32 * 1024 * 1024
    private static let maxSliceRebaseSourceEntryBytes = 8 * 1024 * 1024
    private var watcherPublisherAttachmentsByKey: [WatcherInfrastructureKey: WatcherPublisherAttachment] = [:]
    private var watcherInfrastructureFlightsByKey: [WatcherInfrastructureKey: WatcherInfrastructureFlight] = [:]
    private var explicitWatcherDemandRootIDs = Set<UUID>()
    private var explicitWatcherDemandGenerationByKey: [WatcherInfrastructureKey: UInt64] = [:]
    private var latestSessionWorktreeOwnershipGenerationByOwnerID: [UUID: UInt64] = [:]
    private var installedSessionWorktreeOwnershipTokenByOwnerID: [UUID: WorkspaceSessionWorktreeOwnershipToken] = [:]
    private var sessionWorktreeOwnershipRecordsByToken: [WorkspaceSessionWorktreeOwnershipToken: SessionWorktreeOwnershipRecord] = [:]
    private var sessionWorktreeOwnershipTokensByRootLifetime: [SessionWorktreeRootLifetimeKey: Set<WorkspaceSessionWorktreeOwnershipToken>] = [:]
    private var sessionWorktreeReservationTokensByStandardizedPath: [String: Set<WorkspaceSessionWorktreeOwnershipToken>] = [:]
    private var sessionWorktreeReservedPathsByToken: [WorkspaceSessionWorktreeOwnershipToken: Set<String>] = [:]
    private var sessionWorktreeReservationLoadFlightsByToken: [WorkspaceSessionWorktreeOwnershipToken: [String: RootLoadFlight]] = [:]
    #if DEBUG
        private var sessionWorktreeOrphanLoadCleanupsByID: [UUID: SessionWorktreeOrphanLoadCleanup] = [:]
        private var sessionWorktreeOrphanLoadCleanupOverflowCount = 0
        private static let maximumSessionWorktreeOrphanLoadCleanupRecords = 64
    #endif
    private var pendingSeededRootsByID: [WorkspacePendingSeededRootID: PendingSeededRoot] = [:]
    private var pendingSeededRootIDsByStandardizedPath: [String: WorkspacePendingSeededRootID] = [:]
    #if DEBUG
        private var pendingReceiptConsumptionDecisionByToken: [
            WorkspaceSessionWorktreeOwnershipToken:
                (correlationID: UUID, decision: WorktreeStartupInstrumentation.ReceiptConsumptionDecision)
        ] = [:]
    #endif
    private var pendingSeededRootVisibilityWaitersByPath: [
        String: [UUID: CheckedContinuation<Void, Error>]
    ] = [:]
    private var seededAuthorityInvalidationListenerTask: Task<Void, Never>?
    private var publishedSeededAuthorityFencesByRootID: [UUID: GitWorkspacePendingInitializationAuthorityFence] = [:]
    private var publishedSeededAuthorityClaimsByRootID: [UUID: WorkspaceRootSeedServingAuthorityClaim] = [:]
    private var publishedSeededAuthorityStatesByRootID: [UUID: PublishedSeededAuthorityState] = [:]
    private var publishedSeededAuthorityWaitersByRootID: [
        UUID: [UUID: CheckedContinuation<Void, Error>]
    ] = [:]
    private var seededAuthorityPendingGenerationByRootID: [UUID: UInt64] = [:]
    private var seededAuthorityReconciliationTasksByRootID: [UUID: Task<Void, Never>] = [:]
    private let publisherIngressCoordinator: WorkspaceFileSystemIngressCoordinator
    private let unloadTerminationPolicy: WorkspaceRootUnloadTerminationPolicy
    private var scopedIngressBarrierFlightStatesByRootID: [UUID: ScopedIngressBarrierRootFlightState] = [:]
    private var completedScopedIngressBarrierCutsByRootID: [UUID: ScopedIngressBarrierCompletedCut] = [:]
    private var nextScopedIngressBarrierToken: UInt64 = 0
    private static let maxConcurrentScopedIngressBarriers = 8
    #if DEBUG
        private let debugNowNanoseconds: @Sendable () -> UInt64
        private let isCatalogShardShadowValidationEnabled: Bool
    #endif

    #if DEBUG
        init(
            searchLaneConfiguration: StoreBackedWorkspaceSearchLane.Configuration = .production,
            debugNowNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
            unloadTerminationPolicy: WorkspaceRootUnloadTerminationPolicy = .production,
            enableCatalogShardShadowValidation: Bool = true,
            codemapRuntimeProvider: @escaping CodeMapArtifactRuntimeProvider.Factory = {
                try CodeMapArtifactRuntime.processWide()
            },
            codemapLocalGitClassificationProbe: WorkspaceCodemapLocalGitClassificationProbe = .production,
            codemapGitEligibilityProbe: WorkspaceCodemapGitEligibilityProbe = .production(),
            codemapProjectionPreloadRetryPolicy: CodemapProjectionPreloadRetryPolicy = .production,
            codemapProjectionPreloadLaunchPolicyForTesting: CodemapProjectionPreloadLaunchPolicyForTesting = .enabled,
            codemapAutomaticRetainedProjectionDemandPolicyForTesting:
            CodemapAutomaticRetainedProjectionDemandPolicyForTesting = .enabled,
            selectionGraphFactory: WorkspaceCodemapSelectionGraphFactory = .production,
            codemapSelectionGraphRuntimeQueryOverrideForTesting: (@Sendable (
                WorkspaceCodemapRootEpoch,
                WorkspaceCodemapSelectionGraphRuntimeQuery
            ) async -> WorkspaceCodemapSelectionGraphRuntimeQueryDisposition?)? = nil,
            selectionGraphQueryBudgetPolicy: WorkspaceCodemapStoreSelectionGraphQueryBudgetPolicy = .initial,
            automaticSelectionAccountingMaximum: Int = .max,
            codemapCancellationCleanupHook: @escaping @Sendable (
                WorkspaceCodemapArtifactDemandTicket
            ) async -> Void = { _ in },
            codemapReadyPublicationHook: @escaping @Sendable (
                WorkspaceCodemapArtifactDemandTicket
            ) async -> Void = { _ in },
            codemapGraphPublicationWaiter: @escaping @Sendable (
                WorkspaceCodemapRootEpoch
            ) async -> Void = { _ in
                try? await Task.sleep(for: .milliseconds(10))
            },
            codemapDemandResultHook: @escaping @Sendable (
                WorkspaceCodemapArtifactDemandTicket,
                WorkspaceCodemapBindingDemandResult
            ) async -> WorkspaceCodemapBindingDemandResult = { _, result in result },
            codemapAutomaticSelectionQueryHook: @escaping @Sendable (
                WorkspaceCodemapRootEpoch
            ) async -> Void = { _ in }
        ) {
            storeBackedSearchLane = StoreBackedWorkspaceSearchLane(configuration: searchLaneConfiguration)
            self.debugNowNanoseconds = debugNowNanoseconds
            self.unloadTerminationPolicy = unloadTerminationPolicy
            self.codemapRuntimeProvider = codemapRuntimeProvider
            self.codemapLocalGitClassificationProbe = codemapLocalGitClassificationProbe
            self.codemapGitEligibilityProbe = codemapGitEligibilityProbe
            self.codemapProjectionPreloadRetryPolicy = codemapProjectionPreloadRetryPolicy
            self.codemapProjectionPreloadLaunchPolicyForTesting = codemapProjectionPreloadLaunchPolicyForTesting
            self.codemapAutomaticRetainedProjectionDemandPolicyForTesting =
                codemapAutomaticRetainedProjectionDemandPolicyForTesting
            self.selectionGraphFactory = selectionGraphFactory
            self.codemapSelectionGraphRuntimeQueryOverrideForTesting =
                codemapSelectionGraphRuntimeQueryOverrideForTesting
            self.selectionGraphQueryBudgetPolicy = selectionGraphQueryBudgetPolicy
            precondition(automaticSelectionAccountingMaximum >= 0)
            self.automaticSelectionAccountingMaximum = automaticSelectionAccountingMaximum
            self.codemapCancellationCleanupHook = codemapCancellationCleanupHook
            self.codemapReadyPublicationHook = codemapReadyPublicationHook
            self.codemapGraphPublicationWaiter = codemapGraphPublicationWaiter
            self.codemapDemandResultHook = codemapDemandResultHook
            self.codemapAutomaticSelectionQueryHook = codemapAutomaticSelectionQueryHook
            isCatalogShardShadowValidationEnabled = enableCatalogShardShadowValidation
            publisherIngressCoordinator = WorkspaceFileSystemIngressCoordinator(debugNowNanoseconds: debugNowNanoseconds)
            #if os(macOS)
                let source = DispatchSource.makeMemoryPressureSource(
                    eventMask: [.warning, .critical],
                    queue: .global(qos: .utility)
                )
                searchContentMemoryPressureSource = source
                source.setEventHandler { [weak self] in
                    Task { await self?.clearSearchDecodedContentCache() }
                }
                source.activate()
            #endif
        }
    #else
        init(
            searchLaneConfiguration: StoreBackedWorkspaceSearchLane.Configuration = .production,
            unloadTerminationPolicy: WorkspaceRootUnloadTerminationPolicy = .production,
            codemapRuntimeProvider: @escaping CodeMapArtifactRuntimeProvider.Factory = {
                try CodeMapArtifactRuntime.processWide()
            },
            codemapLocalGitClassificationProbe: WorkspaceCodemapLocalGitClassificationProbe = .production,
            codemapGitEligibilityProbe: WorkspaceCodemapGitEligibilityProbe = .production(),
            codemapProjectionPreloadRetryPolicy: CodemapProjectionPreloadRetryPolicy = .production,
            selectionGraphFactory: WorkspaceCodemapSelectionGraphFactory = .production,
            selectionGraphQueryBudgetPolicy: WorkspaceCodemapStoreSelectionGraphQueryBudgetPolicy = .initial,
            automaticSelectionAccountingMaximum: Int = .max,
            codemapCancellationCleanupHook: @escaping @Sendable (
                WorkspaceCodemapArtifactDemandTicket
            ) async -> Void = { _ in },
            codemapReadyPublicationHook: @escaping @Sendable (
                WorkspaceCodemapArtifactDemandTicket
            ) async -> Void = { _ in },
            codemapGraphPublicationWaiter: @escaping @Sendable (
                WorkspaceCodemapRootEpoch
            ) async -> Void = { _ in
                try? await Task.sleep(for: .milliseconds(10))
            },
            codemapDemandResultHook: @escaping @Sendable (
                WorkspaceCodemapArtifactDemandTicket,
                WorkspaceCodemapBindingDemandResult
            ) async -> WorkspaceCodemapBindingDemandResult = { _, result in result },
            codemapAutomaticSelectionQueryHook: @escaping @Sendable (
                WorkspaceCodemapRootEpoch
            ) async -> Void = { _ in }
        ) {
            storeBackedSearchLane = StoreBackedWorkspaceSearchLane(configuration: searchLaneConfiguration)
            self.unloadTerminationPolicy = unloadTerminationPolicy
            self.codemapRuntimeProvider = codemapRuntimeProvider
            self.codemapLocalGitClassificationProbe = codemapLocalGitClassificationProbe
            self.codemapGitEligibilityProbe = codemapGitEligibilityProbe
            self.codemapProjectionPreloadRetryPolicy = codemapProjectionPreloadRetryPolicy
            self.selectionGraphFactory = selectionGraphFactory
            self.selectionGraphQueryBudgetPolicy = selectionGraphQueryBudgetPolicy
            precondition(automaticSelectionAccountingMaximum >= 0)
            self.automaticSelectionAccountingMaximum = automaticSelectionAccountingMaximum
            self.codemapCancellationCleanupHook = codemapCancellationCleanupHook
            self.codemapReadyPublicationHook = codemapReadyPublicationHook
            self.codemapGraphPublicationWaiter = codemapGraphPublicationWaiter
            self.codemapDemandResultHook = codemapDemandResultHook
            self.codemapAutomaticSelectionQueryHook = codemapAutomaticSelectionQueryHook
            publisherIngressCoordinator = WorkspaceFileSystemIngressCoordinator()
            #if os(macOS)
                let source = DispatchSource.makeMemoryPressureSource(
                    eventMask: [.warning, .critical],
                    queue: .global(qos: .utility)
                )
                searchContentMemoryPressureSource = source
                source.setEventHandler { [weak self] in
                    Task { await self?.clearSearchDecodedContentCache() }
                }
                source.activate()
            #endif
        }
    #endif

    deinit {
        #if os(macOS)
            searchContentMemoryPressureSource.cancel()
        #endif
        for session in codemapSessionsByRootEpoch.values {
            session.setupTask?.cancel()
            for demand in session.demandsByFileID.values {
                demand.task?.cancel()
            }
            session.graphPublicationFlight?.task?.cancel()
            session.projectionRecoveryObserver?.task?.cancel()
            session.selectionGraph?.workerTask?.cancel()
            for bundle in session.bundlesByRequestID.values {
                bundle.close()
            }
        }
        for projectionDemand in codemapProjectionDemandsByID.values {
            projectionDemand.expiryTask?.cancel()
        }
        for flight in codemapCleanupFlightsByRootID.values {
            flight.task.cancel()
        }
        for flight in codemapPathInvalidationFlightsByRootEpoch.values {
            flight.task.cancel()
        }
        for attachment in watcherPublisherAttachmentsByKey.values {
            attachment.cancellable.cancel()
        }
        for flight in watcherInfrastructureFlightsByKey.values {
            flight.task.cancel()
        }
        for continuation in codemapSelectionGraphReadinessContinuations.values {
            continuation.finish()
        }
        for continuation in codemapMarkerReadinessContinuations.values {
            continuation.finish()
        }
        for continuation in fileSystemDeltaContinuations.values {
            continuation.finish()
        }
        for continuation in appliedIndexContinuations.values {
            continuation.finish()
        }
    }

    func roots() -> [WorkspaceRootRecord] {
        rootLoadOrder.compactMap { rootStatesByID[$0]?.root }
    }

    func rootRecords(forRootFolderPaths rootFolderPaths: [String], includeSystemRoots: Bool = true) -> [WorkspaceRootRecord] {
        let standardizedRootPaths = Set(rootFolderPaths.map { ($0 as NSString).standardizingPath })
        guard !standardizedRootPaths.isEmpty else { return [] }
        return rootLoadOrder.compactMap { rootID in
            guard let root = rootStatesByID[rootID]?.root,
                  standardizedRootPaths.contains(root.standardizedFullPath),
                  includeSystemRoots || !root.isSystemRoot
            else {
                return nil
            }
            return root
        }
    }

    func fileSystemDeltaEvents() -> AsyncStream<WorkspaceFileSystemDeltaEvent> {
        let streamID = UUID()
        return AsyncStream { continuation in
            fileSystemDeltaContinuations[streamID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeFileSystemDeltaContinuation(id: streamID) }
            }
        }
    }

    private func removeFileSystemDeltaContinuation(id: UUID) {
        fileSystemDeltaContinuations.removeValue(forKey: id)
    }

    func appliedIndexEvents() -> AsyncStream<WorkspaceAppliedIndexBatchEvent> {
        let streamID = UUID()
        return AsyncStream { continuation in
            appliedIndexContinuations[streamID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeAppliedIndexContinuation(id: streamID) }
            }
        }
    }

    private func removeAppliedIndexContinuation(id: UUID) {
        appliedIndexContinuations.removeValue(forKey: id)
    }

    func startWatchingRoot(id rootID: UUID) async throws {
        let state = try state(for: rootID)
        let key = WatcherInfrastructureKey(rootID: rootID, lifetimeID: state.lifetimeID)
        let demandGeneration = (explicitWatcherDemandGenerationByKey[key] ?? 0) &+ 1
        explicitWatcherDemandGenerationByKey[key] = demandGeneration
        explicitWatcherDemandRootIDs.insert(rootID)
        do {
            try await reconcileAggregateWatcherDemand(rootID: rootID)
        } catch {
            if explicitWatcherDemandGenerationByKey[key] == demandGeneration,
               isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: key.lifetimeID)
            {
                explicitWatcherDemandRootIDs.remove(rootID)
                try? await reconcileAggregateWatcherDemand(rootID: rootID)
            }
            throw error
        }
    }

    private func ensureWatcherInfrastructure(state: RootState, rootID: UUID) async throws {
        let key = WatcherInfrastructureKey(rootID: rootID, lifetimeID: state.lifetimeID)
        guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: key.lifetimeID) else {
            throw WorkspaceSessionWorktreeOwnershipError.unavailableRoot(state.root.standardizedFullPath)
        }
        if let flight = watcherInfrastructureFlightsByKey[key] {
            #if DEBUG
                if let watcherInfrastructureDidJoinFlightHandler {
                    await watcherInfrastructureDidJoinFlightHandler(rootID, key.lifetimeID)
                }
            #endif
            try await awaitWatcherInfrastructureFlight(flight)
            return
        }

        let flightID = UUID()
        let rootPath = state.root.standardizedFullPath
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            do {
                try await performWatcherInfrastructureSetup(key: key, rootPath: rootPath)
                await clearWatcherInfrastructureFlight(key: key, expectedID: flightID)
            } catch {
                await clearWatcherInfrastructureFlight(key: key, expectedID: flightID)
                throw error
            }
        }
        let flight = WatcherInfrastructureFlight(id: flightID, task: task)
        watcherInfrastructureFlightsByKey[key] = flight
        try await awaitWatcherInfrastructureFlight(flight)
    }

    private func awaitWatcherInfrastructureFlight(_ flight: WatcherInfrastructureFlight) async throws {
        let race = WatcherInfrastructureTaskWaitRace()
        Task {
            let result = await flight.task.result
            race.resolve(result)
        }
        try await withTaskCancellationHandler {
            try await race.value()
        } onCancel: {
            race.cancel()
        }
    }

    private func clearWatcherInfrastructureFlight(key: WatcherInfrastructureKey, expectedID: UUID) {
        guard watcherInfrastructureFlightsByKey[key]?.id == expectedID else { return }
        watcherInfrastructureFlightsByKey.removeValue(forKey: key)
    }

    private func performWatcherInfrastructureSetup(
        key: WatcherInfrastructureKey,
        rootPath: String
    ) async throws {
        while true {
            guard let state = rootStatesByID[key.rootID],
                  state.lifetimeID == key.lifetimeID,
                  hasAggregateWatcherDemand(rootID: key.rootID, lifetimeID: key.lifetimeID)
            else {
                throw WorkspaceSessionWorktreeOwnershipError.unavailableRoot(rootPath)
            }

            let subscription: WorkspaceFileSystemIngressCoordinator.Subscription
            if let attachment = watcherPublisherAttachmentsByKey[key],
               publisherIngressCoordinator.isPublisherIngressOpen(attachment.subscription)
            {
                subscription = attachment.subscription
            } else {
                watcherPublisherAttachmentsByKey.removeValue(forKey: key)?.cancellable.cancel()
                guard let attachedSubscription = try await attachPublisherIngress(
                    state: state,
                    key: key
                ) else {
                    guard isRootLifetimeCurrent(rootID: key.rootID, expectedLifetimeID: key.lifetimeID),
                          hasAggregateWatcherDemand(rootID: key.rootID, lifetimeID: key.lifetimeID)
                    else {
                        throw WorkspaceSessionWorktreeOwnershipError.unavailableRoot(rootPath)
                    }
                    continue
                }
                subscription = attachedSubscription
            }

            do {
                try await reconcileWatcherServiceState(state.service, rootID: key.rootID)
                await waitForCurrentPublisherIngress(rootIDs: [key.rootID])
            } catch {
                removeWatcherPublisherAttachment(key: key, subscription: subscription)
                if isRootLifetimeCurrent(rootID: key.rootID, expectedLifetimeID: key.lifetimeID) {
                    try? await reconcileWatcherServiceState(state.service, rootID: key.rootID)
                    await waitForCurrentPublisherIngress(rootIDs: [key.rootID])
                }
                throw error
            }

            guard isRootLifetimeCurrent(rootID: key.rootID, expectedLifetimeID: key.lifetimeID),
                  hasAggregateWatcherDemand(rootID: key.rootID, lifetimeID: key.lifetimeID)
            else {
                removeWatcherPublisherAttachment(key: key, subscription: subscription)
                if isRootLifetimeCurrent(rootID: key.rootID, expectedLifetimeID: key.lifetimeID) {
                    try? await reconcileWatcherServiceState(state.service, rootID: key.rootID)
                    await waitForCurrentPublisherIngress(rootIDs: [key.rootID])
                }
                throw WorkspaceSessionWorktreeOwnershipError.unavailableRoot(rootPath)
            }
            guard watcherPublisherAttachmentsByKey[key]?.subscription == subscription,
                  publisherIngressCoordinator.isPublisherIngressOpen(subscription)
            else {
                continue
            }
            return
        }
    }

    private func attachPublisherIngress(
        state: RootState,
        key: WatcherInfrastructureKey
    ) async throws -> WorkspaceFileSystemIngressCoordinator.Subscription? {
        guard isRootLifetimeCurrent(rootID: key.rootID, expectedLifetimeID: key.lifetimeID) else { return nil }
        let root = state.root
        let diagnosticRootToken = state.service.diagnosticRootToken
        let publisherIngressCoordinator = publisherIngressCoordinator
        let subscription = publisherIngressCoordinator.openPublisherIngress(rootID: key.rootID) { [weak self] publication, publicationCorrelation in
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.WorkspaceIngress.storeSinkBegan,
                correlation: publicationCorrelation,
                EditFlowPerf.Dimensions(
                    changeCount: publication.deltas.count,
                    rootToken: diagnosticRootToken.uuidString,
                    ingressSequence: publication.watcherAcceptedWatermark?.rawValue,
                    barrierSequence: publication.servicePublicationSequence
                )
            )
            await self?.handleObservedPublisherFileSystemPublication(
                publication,
                root: root,
                expectedLifetimeID: key.lifetimeID,
                publicationCorrelation: publicationCorrelation,
                diagnosticRootToken: diagnosticRootToken
            )
        }
        #if DEBUG
            if let watcherPublisherIngressDidOpenHandler {
                await watcherPublisherIngressDidOpenHandler(key.rootID, key.lifetimeID)
            }
        #endif
        let publisher = await state.service.publisherForChanges()
        guard isRootLifetimeCurrent(rootID: key.rootID, expectedLifetimeID: key.lifetimeID),
              publisherIngressCoordinator.isPublisherIngressOpen(subscription)
        else {
            publisherIngressCoordinator.closePublisherIngress(subscription)
            return nil
        }
        let cancellable = publisher.sink { publication in
            #if DEBUG || EDIT_FLOW_PERF
                let publicationCorrelation = EditFlowPerf.currentFileSystemPublicationCorrelation
            #else
                let publicationCorrelation: EditFlowPerf.LifecycleCorrelation? = nil
            #endif
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.WorkspaceIngress.storeSinkScheduled,
                correlation: publicationCorrelation,
                EditFlowPerf.Dimensions(
                    changeCount: publication.deltas.count,
                    rootToken: diagnosticRootToken.uuidString,
                    ingressSequence: publication.watcherAcceptedWatermark?.rawValue,
                    barrierSequence: publication.servicePublicationSequence
                )
            )
            publisherIngressCoordinator.accept(
                subscription,
                publication: publication,
                lifecycleCorrelation: publicationCorrelation
            )
        }
        guard isRootLifetimeCurrent(rootID: key.rootID, expectedLifetimeID: key.lifetimeID),
              publisherIngressCoordinator.isPublisherIngressOpen(subscription)
        else {
            cancellable.cancel()
            publisherIngressCoordinator.closePublisherIngress(subscription)
            return nil
        }
        watcherPublisherAttachmentsByKey[key] = WatcherPublisherAttachment(
            subscription: subscription,
            cancellable: cancellable
        )
        return subscription
    }

    /// Opens canonical publisher ingress before subscribing to the hidden
    /// service, preserving the same sink-boundary ordering as published roots.
    private func attachPendingSeededRootPublisherIngress(
        pendingID: WorkspacePendingSeededRootID
    ) async throws -> WatcherPublisherAttachment {
        guard let pending = pendingSeededRootsByID[pendingID] else {
            throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
        }
        let rootID = pending.state.root.id
        let lifetimeID = pending.state.lifetimeID
        let coordinator = publisherIngressCoordinator
        let subscription = coordinator.openPublisherIngress(rootID: rootID) { [weak self] publication, _ in
            await self?.handlePendingSeededRootPublication(
                publication,
                pendingID: pendingID,
                expectedRootID: rootID,
                expectedLifetimeID: lifetimeID
            )
        }
        let publisher = await pending.state.service.publisherForChanges()
        guard let current = pendingSeededRootsByID[pendingID],
              current.state.root.id == rootID,
              current.state.lifetimeID == lifetimeID,
              coordinator.isPublisherIngressOpen(subscription)
        else {
            coordinator.closePublisherIngress(subscription)
            throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
        }
        let cancellable = publisher.sink { publication in
            coordinator.accept(
                subscription,
                publication: publication,
                lifecycleCorrelation: nil
            )
        }
        guard let current = pendingSeededRootsByID[pendingID],
              current.state.root.id == rootID,
              current.state.lifetimeID == lifetimeID,
              coordinator.isPublisherIngressOpen(subscription)
        else {
            cancellable.cancel()
            coordinator.closePublisherIngress(subscription)
            throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
        }
        return WatcherPublisherAttachment(subscription: subscription, cancellable: cancellable)
    }

    private func handlePendingSeededRootPublication(
        _ publication: FileSystemDeltaPublication,
        pendingID: WorkspacePendingSeededRootID,
        expectedRootID: UUID,
        expectedLifetimeID: UUID
    ) {
        guard var pending = pendingSeededRootsByID[pendingID],
              pending.state.root.id == expectedRootID,
              pending.state.lifetimeID == expectedLifetimeID,
              pending.terminalFallbackReason == nil
        else { return }

        guard case .replaying = pending.phase else {
            if pending.phase == .readyForCommit {
                pending.terminalFallbackReason = .serviceIngressGenerationChanged
                pendingSeededRootsByID[pendingID] = pending
            }
            return
        }

        let expectedSequence = pending.lastAppliedServicePublicationSequence &+ 1
        guard publication.servicePublicationSequence == expectedSequence else {
            pending.terminalFallbackReason = .pendingIngressSequenceGap
            pendingSeededRootsByID[pendingID] = pending
            return
        }
        guard !publication.requiresFullResync,
              publication.source == .watcher || publication.source == .watcherBarrierNoop
        else {
            pending.terminalFallbackReason = switch publication.source {
            case .overflowRootRescan: .watcherOverflow
            case .recoveryFullResync: .watcherRecoveryUncertain
            case .watcher, .watcherBarrierNoop, .syntheticMutation: .watcherDrop
            }
            pendingSeededRootsByID[pendingID] = pending
            return
        }

        pending.lastAppliedServicePublicationSequence = publication.servicePublicationSequence
        if let watermark = publication.watcherAcceptedWatermark {
            guard watermark >= pending.lastAppliedWatcherWatermark else {
                pending.terminalFallbackReason = .pendingIngressSequenceGap
                pendingSeededRootsByID[pendingID] = pending
                return
            }
            pending.lastAppliedWatcherWatermark = watermark
        }
        pendingSeededRootsByID[pendingID] = pending
    }

    private func removeWatcherPublisherAttachment(
        key: WatcherInfrastructureKey,
        subscription: WorkspaceFileSystemIngressCoordinator.Subscription
    ) {
        if watcherPublisherAttachmentsByKey[key]?.subscription == subscription {
            watcherPublisherAttachmentsByKey.removeValue(forKey: key)?.cancellable.cancel()
        }
        publisherIngressCoordinator.closePublisherIngress(subscription)
    }

    #if DEBUG
        func attachPublisherIngressWithoutStartingWatcherForTesting(rootID: UUID) async throws -> Bool {
            let state = try state(for: rootID)
            let key = WatcherInfrastructureKey(rootID: rootID, lifetimeID: state.lifetimeID)
            if let attachment = watcherPublisherAttachmentsByKey[key],
               publisherIngressCoordinator.isPublisherIngressOpen(attachment.subscription)
            {
                return true
            }
            return try await attachPublisherIngress(state: state, key: key) != nil
        }
    #endif

    func stopWatchingRoot(id rootID: UUID) async {
        if let state = rootStatesByID[rootID] {
            let key = WatcherInfrastructureKey(rootID: rootID, lifetimeID: state.lifetimeID)
            explicitWatcherDemandGenerationByKey[key, default: 0] &+= 1
        }
        explicitWatcherDemandRootIDs.remove(rootID)
        try? await reconcileAggregateWatcherDemand(rootID: rootID)
    }

    func nextSessionWorktreeOwnershipGeneration(ownerID: UUID) -> UInt64 {
        (latestSessionWorktreeOwnershipGenerationByOwnerID[ownerID] ?? 0) &+ 1
    }

    private func pendingSeededRootIsCurrent(
        _ pendingID: WorkspacePendingSeededRootID,
        token: WorkspaceSessionWorktreeOwnershipToken,
        standardizedPath: String,
        expectedPhase: WorkspacePendingSeededRootPhase? = nil
    ) -> Bool {
        guard latestSessionWorktreeOwnershipGenerationByOwnerID[token.ownerID] == token.generation,
              let record = sessionWorktreeOwnershipRecordsByToken[token],
              record.pendingSeededRootIDs.contains(pendingID),
              sessionWorktreeReservedPathsByToken[token]?.contains(standardizedPath) == true,
              pendingSeededRootIDsByStandardizedPath[standardizedPath] == pendingID,
              let pending = pendingSeededRootsByID[pendingID],
              pending.token == token,
              pending.standardizedPath == standardizedPath
        else { return false }
        return expectedPhase == nil || pending.phase == expectedPhase
    }

    private func requirePendingSeededRootCurrent(
        _ pendingID: WorkspacePendingSeededRootID,
        token: WorkspaceSessionWorktreeOwnershipToken,
        standardizedPath: String,
        expectedPhase: WorkspacePendingSeededRootPhase? = nil
    ) throws {
        guard pendingSeededRootIsCurrent(
            pendingID,
            token: token,
            standardizedPath: standardizedPath,
            expectedPhase: expectedPhase
        ) else {
            throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
        }
    }

    private func installValidatedPendingAuthorityFence(
        _ candidate: GitWorkspacePendingInitializationAuthorityFence,
        pendingID: WorkspacePendingSeededRootID,
        token: WorkspaceSessionWorktreeOwnershipToken,
        standardizedPath: String,
        expectedPhase: WorkspacePendingSeededRootPhase
    ) async throws {
        guard await workspaceStateAuthority.pendingInitializationAuthorityFenceIsCurrent(candidate) else {
            throw GitWorkspaceAuthorityUnavailableReason.superseded
        }
        try requirePendingSeededRootCurrent(
            pendingID,
            token: token,
            standardizedPath: standardizedPath,
            expectedPhase: expectedPhase
        )
        guard workspaceStateAuthority
            .pendingInitializationAuthorityFenceIsSynchronouslyCurrent(candidate),
            var pending = pendingSeededRootsByID[pendingID],
            pending.authorityInvalidationGeneration <= candidate.lease.invalidationGeneration,
            pending.authorityAcceptedMetadataWatermark <= candidate.acceptedMetadataWatermark,
            pending.authorityMutationDepth == 0,
            pending.terminalFallbackReason == nil
        else {
            throw GitWorkspaceAuthorityUnavailableReason.superseded
        }
        pending.authorityFence = candidate
        pending.authorityInvalidationGeneration = candidate.lease.invalidationGeneration
        pending.authorityAcceptedMetadataWatermark = candidate.acceptedMetadataWatermark
        pendingSeededRootsByID[pendingID] = pending
    }

    private func preparePendingSeededRoot(
        token: WorkspaceSessionWorktreeOwnershipToken,
        bindingFingerprint: String,
        standardizedPath: String,
        hint: WorkspaceRootMaterializationHint,
        startupContext: WorktreeStartupContext
    ) async throws -> PendingSeededRootAttempt {
        guard hint.creationReceipt.witnessCoverage.endEventID > 0 else {
            WorktreeStartupInstrumentation.recordSeedReceiptJournalCut(present: false)
            return .fallback(.witnessGap)
        }
        WorktreeStartupInstrumentation.recordSeedReceiptJournalCut(present: true)
        try Task.checkCancellation()
        guard latestSessionWorktreeOwnershipGenerationByOwnerID[token.ownerID] == token.generation,
              sessionWorktreeReservedPathsByToken[token]?.contains(standardizedPath) == true,
              pendingSeededRootIDsByStandardizedPath[standardizedPath] == nil,
              rootIDsByStandardizedPath[standardizedPath] == nil
        else { throw WorkspaceSessionWorktreeOwnershipError.staleUpdate }

        let service: FileSystemService
        do {
            service = try await FileSystemService(
                path: standardizedPath,
                respectRepoIgnore: true,
                respectCursorignore: true,
                skipSymlinks: true,
                enableHierarchicalIgnores: true
            )
        } catch {
            return .fallback(.watcherActivationFailure)
        }
        try Task.checkCancellation()
        guard latestSessionWorktreeOwnershipGenerationByOwnerID[token.ownerID] == token.generation,
              sessionWorktreeReservedPathsByToken[token]?.contains(standardizedPath) == true
        else { throw WorkspaceSessionWorktreeOwnershipError.staleUpdate }
        #if DEBUG
            if let watcherActivationFailurePointForNewServicesForTesting {
                await service.setWatcherActivationFailureForTesting(
                    watcherActivationFailurePointForNewServicesForTesting
                )
            }
            await service.setSeededPublicationActivationFailureForTesting(
                seededPublicationActivationShouldFailForTesting
            )
        #endif

        let topology = try makePendingSeededRootTopology(
            standardizedPath: standardizedPath,
            service: service
        )
        let pendingID = WorkspacePendingSeededRootID()
        let initializationID = FileSystemSeedInitializationID()
        let loadConfiguration = RootLoadConfiguration(
            kind: .sessionWorktree,
            gitignorePolicyIdentity: .current,
            respectRepoIgnore: true,
            respectCursorignore: true,
            skipSymlinks: true,
            enableHierarchicalIgnores: true
        )
        pendingSeededRootsByID[pendingID] = PendingSeededRoot(
            id: pendingID,
            token: token,
            bindingFingerprint: bindingFingerprint,
            standardizedPath: standardizedPath,
            initializationID: initializationID,
            loadConfiguration: loadConfiguration,
            startupContext: startupContext,
            phase: .reserved,
            state: topology.state,
            indexes: topology.indexes,
            captureIdentity: nil,
            authorityFence: nil,
            authorityInvalidationGeneration: 0,
            authorityAcceptedMetadataWatermark: 0,
            authorityMutationDepth: 0,
            snapshot: nil,
            targetPlanHandle: nil,
            authorityClaim: nil,
            attachment: nil,
            preparedShard: nil,
            lastAppliedServicePublicationSequence: 0,
            lastAppliedWatcherWatermark: .zero,
            activationProof: nil,
            terminalFallbackReason: nil
        )
        pendingSeededRootIDsByStandardizedPath[standardizedPath] = pendingID
        try registerPendingSessionWorktreeRoot(
            pendingID,
            standardizedPath: standardizedPath,
            token: token,
            bindingFingerprint: bindingFingerprint
        )

        do {
            let attachment = try await attachPendingSeededRootPublisherIngress(pendingID: pendingID)
            try requirePendingSeededRootCurrent(
                pendingID,
                token: token,
                standardizedPath: standardizedPath,
                expectedPhase: .reserved
            )
            pendingSeededRootsByID[pendingID]?.attachment = attachment

            await ensureSeededAuthorityInvalidationListener()
            try requirePendingSeededRootCurrent(
                pendingID,
                token: token,
                standardizedPath: standardizedPath,
                expectedPhase: .reserved
            )

            let journalCut = FileSystemSeedReplayJournalCut(
                fseventID: FSEventStreamEventId(hint.creationReceipt.witnessCoverage.endEventID)
            )
            let capture = try await service.startWatchingForSeedPreparation(
                since: journalCut,
                initializationID: initializationID
            )
            try requirePendingSeededRootCurrent(
                pendingID,
                token: token,
                standardizedPath: standardizedPath,
                expectedPhase: .reserved
            )
            pendingSeededRootsByID[pendingID]?.captureIdentity = capture
            pendingSeededRootsByID[pendingID]?.lastAppliedWatcherWatermark = capture.initialAcceptedWatermark
            pendingSeededRootsByID[pendingID]?.phase = .watcherCapturing
            WorktreeStartupInstrumentation.record(
                .seedWatcherAttached,
                context: startupContext,
                route: .diffSeedServing
            )

            pendingSeededRootsByID[pendingID]?.phase = .planning
            let planningOutcome = await rootSeedPlanner.planForServing(hint: hint, service: service)
            try Task.checkCancellation()
            try requirePendingSeededRootCurrent(
                pendingID,
                token: token,
                standardizedPath: standardizedPath,
                expectedPhase: .planning
            )
            let planHandle: WorkspaceRootTargetSeedPlanHandle
            let authorityClaim: WorkspaceRootSeedServingAuthorityClaim
            let authorityFence: GitWorkspacePendingInitializationAuthorityFence
            switch planningOutcome {
            case let .fallback(reason):
                await fallBackPendingSeededRoot(
                    pendingID,
                    reason: reason,
                    startupContext: startupContext
                )
                return .fallback(reason)
            case let .planned(handle, claim):
                planHandle = handle
                authorityClaim = claim
                guard let fence = await claim.authorityFence() else {
                    await fallBackPendingSeededRoot(
                        pendingID,
                        reason: .authorityUnstable,
                        startupContext: startupContext
                    )
                    return .fallback(.authorityUnstable)
                }
                // Record the coordinator claim before the awaited fence
                // validation can publish its non-owning fence value into
                // pending state. Abort cleanup must never mistake that shared
                // value for a store-owned lease.
                pendingSeededRootsByID[pendingID]?.authorityClaim = claim
                let validatedFence = try await claim.validatePendingAuthorityFence(
                    replacing: fence
                )
                authorityFence = validatedFence
                try await installValidatedPendingAuthorityFence(
                    validatedFence,
                    pendingID: pendingID,
                    token: token,
                    standardizedPath: standardizedPath,
                    expectedPhase: .planning
                )
            }

            let snapshot = planHandle.snapshot
            guard snapshot.compatibilityKey == hint.creationReceipt.parentCompatibilityKey else {
                await fallBackPendingSeededRoot(
                    pendingID,
                    reason: .compatibilityMismatch,
                    startupContext: startupContext
                )
                return .fallback(.compatibilityMismatch)
            }
            try requirePendingSeededRootCurrent(
                pendingID,
                token: token,
                standardizedPath: standardizedPath,
                expectedPhase: .planning
            )
            pendingSeededRootsByID[pendingID]?.snapshot = snapshot
            pendingSeededRootsByID[pendingID]?.targetPlanHandle = planHandle

            let inventory = try await service.prepareSeededInventory(
                planHandle: planHandle,
                initializationID: initializationID
            )
            try requirePendingSeededRootCurrent(
                pendingID,
                token: token,
                standardizedPath: standardizedPath,
                expectedPhase: .planning
            )
            try await service.installSeededInventory(inventory)
            try requirePendingSeededRootCurrent(
                pendingID,
                token: token,
                standardizedPath: standardizedPath,
                expectedPhase: .planning
            )
            pendingSeededRootsByID[pendingID]?.phase = .seedInstalled

            let replayCut = try await service.captureSeedReplayAcceptedWatermark(
                initializationID: initializationID
            )
            try requirePendingSeededRootCurrent(
                pendingID,
                token: token,
                standardizedPath: standardizedPath,
                expectedPhase: .seedInstalled
            )
            pendingSeededRootsByID[pendingID]?.phase = .replaying(replayCut)
            let replay = try await service.flushSeedReplay(
                through: replayCut,
                initializationID: initializationID
            )
            try requirePendingSeededRootCurrent(
                pendingID,
                token: token,
                standardizedPath: standardizedPath,
                expectedPhase: .replaying(replayCut)
            )
            await publisherIngressCoordinator.waitUntilApplied(
                rootID: topology.state.root.id,
                servicePublicationSequence: replay.finalServicePublicationSequence
            )
            try requirePendingSeededRootCurrent(
                pendingID,
                token: token,
                standardizedPath: standardizedPath,
                expectedPhase: .replaying(replayCut)
            )
            guard let reconciled = pendingSeededRootsByID[pendingID],
                  reconciled.terminalFallbackReason == nil,
                  reconciled.lastAppliedServicePublicationSequence == replay.finalServicePublicationSequence,
                  reconciled.lastAppliedWatcherWatermark >= replay.requestedAcceptedWatermark
            else {
                let reason = pendingSeededRootsByID[pendingID]?.terminalFallbackReason
                    ?? .pendingIngressSequenceGap
                await fallBackPendingSeededRoot(
                    pendingID,
                    reason: reason,
                    startupContext: startupContext
                )
                return .fallback(reason)
            }
            guard !replay.ignoreControlPathsChanged else {
                await fallBackPendingSeededRoot(
                    pendingID,
                    reason: .changedIgnoreAuthority,
                    startupContext: startupContext
                )
                return .fallback(.changedIgnoreAuthority)
            }
            WorktreeStartupInstrumentation.record(
                .seedReplayFenced,
                context: startupContext,
                route: .diffSeedServing
            )
            WorktreeStartupInstrumentation.recordSeedReplay(
                acceptedPayloadCount: replay.acceptedPayloadCount,
                acceptedEventCount: replay.acceptedEventCount,
                initializationWatermarkDelta: Int(
                    replay.requestedAcceptedWatermark.rawValue
                        &- capture.initialAcceptedWatermark.rawValue
                ),
                serviceSequenceDelta: Int(replay.finalServicePublicationSequence),
                changedPathCount: replay.changedRelativePaths.count
            )

            let validatedFence = try await authorityClaim.validatePendingAuthorityFence(
                replacing: authorityFence
            )
            try await installValidatedPendingAuthorityFence(
                validatedFence,
                pendingID: pendingID,
                token: token,
                standardizedPath: standardizedPath,
                expectedPhase: .replaying(replayCut)
            )
            WorktreeStartupInstrumentation.recordSeedMetadataRevalidation(
                used: validatedFence.revalidationUsed
            )
            try requirePendingSeededRootCurrent(
                pendingID,
                token: token,
                standardizedPath: standardizedPath,
                expectedPhase: .replaying(replayCut)
            )

            pendingSeededRootsByID[pendingID]?.phase = .preparingShard
            let finalTopology = try makePendingSeededRootTopology(
                standardizedPath: standardizedPath,
                service: service,
                inventorySnapshot: replay.inventorySnapshot,
                root: topology.state.root,
                lifetimeID: topology.state.lifetimeID
            )
            let components = buildPendingCatalogComponents(
                root: finalTopology.state.root,
                indexes: finalTopology.indexes
            )
            let key = RootCatalogShardKey(
                canonicalConfigurationIdentity: RootCatalogCanonicalConfigurationIdentity(
                    canonicalPath: standardizedPath,
                    loadConfiguration: loadConfiguration
                ),
                rootID: finalTopology.state.root.id,
                lifetimeID: finalTopology.state.lifetimeID,
                // The atomic root publication performs exactly one catalog
                // invalidation after installing the private shard.
                topologyGeneration: 1
            )
            let indexIdentity = WorkspaceSearchRootPathIndexIdentity(
                rootID: key.rootID,
                lifetimeID: key.lifetimeID,
                topologyGeneration: key.topologyGeneration
            )
            #if DEBUG
                if seededShardPreparationShouldFailForTesting {
                    await fallBackPendingSeededRoot(
                        pendingID,
                        reason: .seededShardPreparationFailure,
                        startupContext: startupContext
                    )
                    return .fallback(.seededShardPreparationFailure)
                }
            #endif
            guard let projected = WorkspaceProjectedPathSearchIndex(
                snapshot: snapshot,
                planHandle: planHandle,
                additionalChangedRelativePaths: replay.changedRelativePaths,
                root: finalTopology.state.root,
                authoritativeEntries: components.entries
            ) else {
                await fallBackPendingSeededRoot(
                    pendingID,
                    reason: .seededShardPreparationFailure,
                    startupContext: startupContext
                )
                return .fallback(.seededShardPreparationFailure)
            }
            let pathIndex = WorkspaceSearchRootPathIndex(
                identity: indexIdentity,
                rootPath: finalTopology.state.root.standardizedFullPath,
                entries: components.entries,
                projectedIndex: projected
            )
            let shard = RootCatalogShard(
                key: key,
                root: finalTopology.state.root,
                files: components.files,
                folders: components.folders,
                entries: components.entries,
                pathSearchIndex: pathIndex,
                appliedIndexGeneration: 0
            )
            guard var ready = pendingSeededRootsByID[pendingID],
                  ready.phase == .preparingShard,
                  ready.state.root.id == topology.state.root.id,
                  ready.state.lifetimeID == topology.state.lifetimeID
            else { throw WorkspaceSessionWorktreeOwnershipError.staleUpdate }

            ready.state = finalTopology.state
            ready.indexes = finalTopology.indexes
            ready.targetPlanHandle = nil
            ready.preparedShard = shard
            ready.phase = .readyForCommit
            pendingSeededRootsByID[pendingID] = ready
            WorktreeStartupInstrumentation.recordSeedProjectedPreparation(
                baseEntryCount: projected.baseEntryCount,
                overlayEntryCount: projected.overlayEntryCount,
                tombstoneCount: projected.tombstoneCount
            )
            WorktreeStartupInstrumentation.record(
                .seedReadyForCommit,
                context: startupContext,
                route: .diffSeedServing
            )
            #if DEBUG
                if let pendingSeededRootDidBecomeReadyHandler {
                    await pendingSeededRootDidBecomeReadyHandler(standardizedPath)
                    try requirePendingSeededRootCurrent(
                        pendingID,
                        token: token,
                        standardizedPath: standardizedPath,
                        expectedPhase: .readyForCommit
                    )
                }
            #endif
            return .prepared(WorkspacePendingSeededRootPreparation(id: pendingID))
        } catch is CancellationError {
            await abortPendingSeededRoots([pendingID])
            throw CancellationError()
        } catch let error as WorkspaceSessionWorktreeOwnershipError {
            await abortPendingSeededRoots([pendingID])
            throw error
        } catch let error as FileSystemWatcherActivationError {
            await fallBackPendingSeededRoot(
                pendingID,
                reason: .watcherActivationFailure,
                startupContext: startupContext
            )
            _ = error
            return .fallback(.watcherActivationFailure)
        } catch let error as FileSystemSeedReplayError {
            let reason: WorkspaceRootSeedFallbackReason = switch error {
            case .mailboxOverflow: .watcherOverflow
            case .unsafeEventFlags: .watcherDrop
            case .recoveryRequired, .fullResyncRequired: .watcherRecoveryUncertain
            case .acceptedWatermarkGap, .requestedWatermarkNotPublished,
                 .watcherIngressChanged, .watcherNotActive,
                 .requestedWatermarkPredatesCapture, .requestedWatermarkNotYetAccepted:
                .pendingIngressSequenceGap
            case .invalidJournalCut: .witnessGap
            case .watcherAlreadyActive, .initializationAlreadyActive,
                 .initializationNotCurrent, .inventoryNotInstalled,
                 .invalidSeedInventoryPath, .replayAlreadyCompleted:
                .serviceIngressGenerationChanged
            }
            await fallBackPendingSeededRoot(
                pendingID,
                reason: reason,
                startupContext: startupContext
            )
            return .fallback(reason)
        } catch {
            await fallBackPendingSeededRoot(
                pendingID,
                reason: .authorityUnstable,
                startupContext: startupContext
            )
            return .fallback(.authorityUnstable)
        }
    }

    private func ensureSeededAuthorityInvalidationListener() async {
        guard seededAuthorityInvalidationListenerTask == nil else { return }
        let events = await workspaceStateAuthority.invalidationEvents()
        seededAuthorityInvalidationListenerTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { break }
                await self?.handleSeededAuthorityInvalidation(event)
            }
        }
    }

    private func handleSeededAuthorityInvalidation(
        _ event: GitWorkspaceAuthorityInvalidationEvent
    ) {
        let affectedPendingIDs = pendingSeededRootsByID.compactMap { pendingID, pending in
            pending.authorityFence?.repositoryKey == event.repositoryKey ? pendingID : nil
        }
        for pendingID in affectedPendingIDs {
            guard var pending = pendingSeededRootsByID[pendingID] else { continue }
            pending.authorityInvalidationGeneration = max(
                pending.authorityInvalidationGeneration,
                event.invalidationGeneration
            )
            pending.authorityAcceptedMetadataWatermark = max(
                pending.authorityAcceptedMetadataWatermark,
                event.acceptedMetadataWatermark
            )
            switch event.kind {
            case .mutationBegan:
                pending.authorityMutationDepth += 1
            case .mutationCompleted:
                pending.authorityMutationDepth = max(0, pending.authorityMutationDepth - 1)
            case .metadata:
                break
            }
            pendingSeededRootsByID[pendingID] = pending
        }

        let affectedRootIDs = publishedSeededAuthorityFencesByRootID.compactMap { rootID, fence in
            fence.repositoryKey == event.repositoryKey ? rootID : nil
        }
        for rootID in affectedRootIDs {
            var state = publishedSeededAuthorityStatesByRootID[rootID] ?? PublishedSeededAuthorityState(
                epoch: 0,
                pendingInvalidationGeneration: nil,
                pendingAcceptedMetadataWatermark: 0,
                activeMutationDepth: 0,
                isBlocked: false,
                isReconciling: false,
                reconciliationFailed: false,
                fullCrawlAttemptedGeneration: nil,
                fullCrawlCompletedGeneration: nil
            )
            let wasBlocked = state.isBlocked
            state.epoch &+= 1
            state.pendingInvalidationGeneration = max(
                state.pendingInvalidationGeneration ?? 0,
                event.invalidationGeneration
            )
            state.pendingAcceptedMetadataWatermark = max(
                state.pendingAcceptedMetadataWatermark,
                event.acceptedMetadataWatermark
            )
            state.isBlocked = true
            state.reconciliationFailed = false
            switch event.kind {
            case .mutationBegan:
                state.activeMutationDepth += 1
            case .mutationCompleted:
                state.activeMutationDepth = max(0, state.activeMutationDepth - 1)
            case .metadata:
                break
            }
            publishedSeededAuthorityStatesByRootID[rootID] = state
            if !wasBlocked, let root = rootStatesByID[rootID]?.root {
                invalidatePathMatchSnapshot(
                    affectedRootKinds: [root.kind],
                    reason: .catalogMutation,
                    affectedRootIDs: [rootID]
                )
            }
            seededAuthorityPendingGenerationByRootID[rootID] = max(
                seededAuthorityPendingGenerationByRootID[rootID] ?? 0,
                event.invalidationGeneration
            )
            schedulePublishedSeededAuthorityReconciliationIfPossible(rootID: rootID)
        }
    }

    private func schedulePublishedSeededAuthorityReconciliationIfPossible(rootID: UUID) {
        guard publishedSeededAuthorityStatesByRootID[rootID]?.activeMutationDepth == 0,
              seededAuthorityReconciliationTasksByRootID[rootID] == nil,
              seededAuthorityPendingGenerationByRootID[rootID] != nil
        else { return }
        seededAuthorityReconciliationTasksByRootID[rootID] = Task { [weak self] in
            await self?.reconcilePublishedSeededAuthority(rootID: rootID)
        }
    }

    private func reconcilePublishedSeededAuthority(rootID: UUID) async {
        while let capturedGeneration = seededAuthorityPendingGenerationByRootID[rootID],
              let fence = publishedSeededAuthorityFencesByRootID[rootID],
              let authorityClaim = publishedSeededAuthorityClaimsByRootID[rootID],
              let state = rootStatesByID[rootID]
        {
            guard publishedSeededAuthorityStatesByRootID[rootID]?.activeMutationDepth == 0 else { break }
            seededAuthorityPendingGenerationByRootID.removeValue(forKey: rootID)
            publishedSeededAuthorityStatesByRootID[rootID]?.isReconciling = true
            do {
                let replacement = try await authorityClaim
                    .recapturePublishedAuthorityFence(replacing: fence)
                guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: state.lifetimeID),
                      publishedSeededAuthorityFencesByRootID[rootID] == fence,
                      publishedSeededAuthorityStatesByRootID[rootID]?.activeMutationDepth == 0,
                      seededAuthorityPendingGenerationByRootID[rootID].map({ $0 > capturedGeneration }) != true,
                      await workspaceStateAuthority.pendingInitializationAuthorityFenceIsCurrent(replacement),
                      workspaceStateAuthority
                      .pendingInitializationAuthorityFenceIsSynchronouslyCurrent(replacement)
                else {
                    continue
                }

                if replacement.snapshot != fence.snapshot {
                    guard publishedSeededAuthorityStatesByRootID[rootID]?.fullCrawlAttemptedGeneration == nil
                    else {
                        failPublishedSeededAuthorityReconciliation(rootID: rootID, state: state)
                        break
                    }
                    publishedSeededAuthorityStatesByRootID[rootID]?.fullCrawlAttemptedGeneration = capturedGeneration
                    #if DEBUG
                        publishedSeededAuthorityFullCrawlCountsByRootID[rootID, default: 0] += 1
                    #endif
                    guard await state.service.reconcileEntireTreeForAuthorityChange() else {
                        failPublishedSeededAuthorityReconciliation(rootID: rootID, state: state)
                        break
                    }
                    publishedSeededAuthorityStatesByRootID[rootID]?.fullCrawlCompletedGeneration = capturedGeneration
                    await waitForCurrentPublisherIngress(rootIDs: [rootID])
                    guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: state.lifetimeID),
                          publishedSeededAuthorityStatesByRootID[rootID]?.activeMutationDepth == 0,
                          seededAuthorityPendingGenerationByRootID[rootID].map({ $0 > capturedGeneration }) != true,
                          await workspaceStateAuthority.pendingInitializationAuthorityFenceIsCurrent(replacement),
                          workspaceStateAuthority
                          .pendingInitializationAuthorityFenceIsSynchronouslyCurrent(replacement)
                    else {
                        continue
                    }
                }
                publishedSeededAuthorityFencesByRootID[rootID] = replacement
                markPublishedSeededAuthorityCurrent(rootID: rootID)
            } catch {
                if await workspaceStateAuthority.collectionMutationFenceReason(
                    for: fence.repositoryKey
                ) != nil {
                    seededAuthorityPendingGenerationByRootID[rootID] = max(
                        seededAuthorityPendingGenerationByRootID[rootID] ?? 0,
                        capturedGeneration
                    )
                    publishedSeededAuthorityStatesByRootID[rootID]?.isBlocked = true
                    break
                }
                guard publishedSeededAuthorityStatesByRootID[rootID]?.activeMutationDepth == 0 else { break }
                if publishedSeededAuthorityStatesByRootID[rootID]?.fullCrawlAttemptedGeneration == nil,
                   isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: state.lifetimeID)
                {
                    publishedSeededAuthorityStatesByRootID[rootID]?.fullCrawlAttemptedGeneration = capturedGeneration
                    #if DEBUG
                        publishedSeededAuthorityFullCrawlCountsByRootID[rootID, default: 0] += 1
                    #endif
                    if await state.service.reconcileEntireTreeForAuthorityChange() {
                        publishedSeededAuthorityStatesByRootID[rootID]?.fullCrawlCompletedGeneration = capturedGeneration
                    }
                    await waitForCurrentPublisherIngress(rootIDs: [rootID])
                }
                if await retirePublishedSeededAuthorityAfterUnifiedFullCrawl(rootID: rootID, state: state) {
                    break
                }
                failPublishedSeededAuthorityReconciliation(rootID: rootID, state: state)
                break
            }
            guard seededAuthorityPendingGenerationByRootID[rootID].map({ $0 > capturedGeneration }) == true else {
                break
            }
        }
        seededAuthorityReconciliationTasksByRootID.removeValue(forKey: rootID)
        publishedSeededAuthorityStatesByRootID[rootID]?.isReconciling = false
        schedulePublishedSeededAuthorityReconciliationIfPossible(rootID: rootID)
    }

    private func markPublishedSeededAuthorityCurrent(rootID: UUID) {
        guard var authority = publishedSeededAuthorityStatesByRootID[rootID] else { return }
        authority.pendingInvalidationGeneration = nil
        authority.isBlocked = false
        authority.isReconciling = false
        authority.reconciliationFailed = false
        authority.fullCrawlAttemptedGeneration = nil
        authority.fullCrawlCompletedGeneration = nil
        publishedSeededAuthorityStatesByRootID[rootID] = authority
        resumePublishedSeededAuthorityWaiters(rootID: rootID, error: nil)
    }

    private func retirePublishedSeededAuthorityAfterUnifiedFullCrawl(
        rootID: UUID,
        state: RootState
    ) async -> Bool {
        guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: state.lifetimeID),
              let authority = publishedSeededAuthorityStatesByRootID[rootID],
              authority.activeMutationDepth == 0,
              authority.fullCrawlCompletedGeneration != nil
        else { return false }

        seededAuthorityPendingGenerationByRootID.removeValue(forKey: rootID)
        let claim = publishedSeededAuthorityClaimsByRootID.removeValue(forKey: rootID)
        let fence = publishedSeededAuthorityFencesByRootID.removeValue(forKey: rootID)
        publishedSeededAuthorityStatesByRootID.removeValue(forKey: rootID)
        resumePublishedSeededAuthorityWaiters(rootID: rootID, error: nil)
        if let claim {
            await claim.release()
        } else if let fence {
            await workspaceStateAuthority.releasePendingInitializationAuthorityFence(fence)
        }
        return true
    }

    private func failPublishedSeededAuthorityReconciliation(rootID: UUID, state: RootState) {
        guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: state.lifetimeID),
              var authority = publishedSeededAuthorityStatesByRootID[rootID]
        else { return }
        authority.isBlocked = true
        authority.isReconciling = false
        authority.reconciliationFailed = true
        publishedSeededAuthorityStatesByRootID[rootID] = authority
        resumePublishedSeededAuthorityWaiters(
            rootID: rootID,
            error: WorkspaceSessionWorktreeOwnershipError.unavailableRoot(state.root.standardizedFullPath)
        )
    }

    private func publishedSeededAuthorityIsQueryable(rootID: UUID) -> Bool {
        guard let fence = publishedSeededAuthorityFencesByRootID[rootID] else { return true }
        guard let state = publishedSeededAuthorityStatesByRootID[rootID],
              !state.isBlocked,
              !state.reconciliationFailed
        else { return false }
        return workspaceStateAuthority.pendingInitializationAuthorityFenceIsSynchronouslyCurrent(fence)
    }

    private func requirePublishedSeededAuthorityFresh(rootID: UUID) async throws {
        while publishedSeededAuthorityFencesByRootID[rootID] != nil {
            if publishedSeededAuthorityIsQueryable(rootID: rootID) { return }
            guard let state = publishedSeededAuthorityStatesByRootID[rootID],
                  !state.reconciliationFailed,
                  state.isBlocked
            else {
                let path = rootStatesByID[rootID]?.root.standardizedFullPath ?? rootID.uuidString
                throw WorkspaceSessionWorktreeOwnershipError.unavailableRoot(path)
            }
            let waiterID = UUID()
            let _: Void = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    guard !Task.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    publishedSeededAuthorityWaitersByRootID[rootID, default: [:]][waiterID] = continuation
                }
            } onCancel: {
                Task { await self.cancelPublishedSeededAuthorityWaiter(rootID: rootID, waiterID: waiterID) }
            }
        }
    }

    private func cancelPublishedSeededAuthorityWaiter(rootID: UUID, waiterID: UUID) {
        guard let continuation = publishedSeededAuthorityWaitersByRootID[rootID]?
            .removeValue(forKey: waiterID)
        else { return }
        if publishedSeededAuthorityWaitersByRootID[rootID]?.isEmpty == true {
            publishedSeededAuthorityWaitersByRootID.removeValue(forKey: rootID)
        }
        continuation.resume(throwing: CancellationError())
    }

    private func resumePublishedSeededAuthorityWaiters(rootID: UUID, error: Error?) {
        let waiters = publishedSeededAuthorityWaitersByRootID.removeValue(forKey: rootID) ?? [:]
        for continuation in waiters.values {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    private func fallBackPendingSeededRoot(
        _ pendingID: WorkspacePendingSeededRootID,
        reason: WorkspaceRootSeedFallbackReason,
        startupContext: WorktreeStartupContext
    ) async {
        guard var pending = pendingSeededRootsByID[pendingID] else { return }
        if case .fallingBack = pending.phase { return }
        pending.phase = .fallingBack(reason)
        pending.terminalFallbackReason = pending.terminalFallbackReason ?? reason
        pendingSeededRootsByID[pendingID] = pending
        WorktreeStartupInstrumentation.record(
            .seedFallback,
            context: startupContext,
            route: .diffSeedServing,
            fallback: reason
        )
        WorktreeStartupInstrumentation.recordSeedFullCrawlFallback()
        await discardPendingSeededRoot(pendingID, terminalPhase: .aborted)
    }

    private func abortPendingSeededRoots(_ pendingIDs: [WorkspacePendingSeededRootID]) async {
        for pendingID in pendingIDs {
            await discardPendingSeededRoot(pendingID, terminalPhase: .aborted)
        }
    }

    private func discardPendingSeededRoot(
        _ pendingID: WorkspacePendingSeededRootID,
        terminalPhase: WorkspacePendingSeededRootPhase
    ) async {
        guard var pending = pendingSeededRootsByID[pendingID] else { return }
        pending.phase = terminalPhase
        pendingSeededRootsByID[pendingID] = pending
        await pending.state.service.abortSeededPreparation(initializationID: pending.initializationID)
        pending.attachment?.cancellable.cancel()
        if let subscription = pending.attachment?.subscription {
            publisherIngressCoordinator.closePublisherIngress(subscription)
            await publisherIngressCoordinator.waitForCurrentPublisherIngress(rootIDs: [pending.state.root.id])
        }
        if let authorityClaim = pending.authorityClaim {
            await authorityClaim.release()
        } else if let fence = pending.authorityFence {
            await worktreeSeedGitService.releasePendingInitializationAuthorityFence(fence)
        }
        pendingSeededRootsByID.removeValue(forKey: pendingID)
        if pendingSeededRootIDsByStandardizedPath[pending.standardizedPath] == pendingID {
            pendingSeededRootIDsByStandardizedPath.removeValue(forKey: pending.standardizedPath)
        }
        finishPendingSeededRootVisibility(path: pending.standardizedPath)
        if let record = sessionWorktreeOwnershipRecordsByToken[pending.token] {
            sessionWorktreeOwnershipRecordsByToken[pending.token] = SessionWorktreeOwnershipRecord(
                bindingFingerprint: record.bindingFingerprint,
                roots: record.roots,
                pendingSeededRootIDs: record.pendingSeededRootIDs.filter { $0 != pendingID }
            )
        }
    }

    func prepareSessionWorktreeOwnership(
        ownerID: UUID,
        bindingFingerprint: String,
        physicalRootPaths: [String],
        startupContext: WorktreeStartupContext? = nil,
        initializationHintsByPhysicalRootPath: [String: WorkspaceRootMaterializationHint] = [:]
    ) async throws -> WorkspaceSessionWorktreeOwnershipPreparation {
        #if DEBUG
            var receiptConsumptionDecision = WorktreeStartupInstrumentation.ReceiptConsumptionDecision()
        #endif
        let standardizedPaths = Array(Set(physicalRootPaths.map {
            StandardizedPath.absolute(($0 as NSString).expandingTildeInPath)
        })).sorted()
        if let installedToken = installedSessionWorktreeOwnershipTokenByOwnerID[ownerID],
           let installedRecord = sessionWorktreeOwnershipRecordsByToken[installedToken],
           installedRecord.bindingFingerprint == bindingFingerprint,
           installedRecord.roots.map(\.standardizedPhysicalPath).sorted() == standardizedPaths,
           sessionWorktreeOwnershipRecordIsCurrent(installedRecord)
        {
            #if DEBUG
                if let startupContext {
                    receiptConsumptionDecision.ownershipReused = true
                    receiptConsumptionDecision.finalObservation = .disabled
                    WorktreeStartupInstrumentation.recordReceiptConsumptionDecision(
                        correlationID: startupContext.correlationID,
                        decision: receiptConsumptionDecision
                    )
                }
            #endif
            return WorkspaceSessionWorktreeOwnershipPreparation(
                token: installedToken,
                bindingFingerprint: bindingFingerprint,
                roots: installedRecord.roots,
                reusesInstalledOwnership: true
            )
        }

        let generation = (latestSessionWorktreeOwnershipGenerationByOwnerID[ownerID] ?? 0) &+ 1
        #if DEBUG
            receiptConsumptionDecision.ownershipReused = false
        #endif
        latestSessionWorktreeOwnershipGenerationByOwnerID[ownerID] = generation
        let installedToken = installedSessionWorktreeOwnershipTokenByOwnerID[ownerID]
        if let installedToken,
           let installedRecord = sessionWorktreeOwnershipRecordsByToken[installedToken]
        {
            for root in installedRecord.roots {
                invalidateRootSeedSearchShadow(rootID: root.rootID)
            }
        }
        let token = WorkspaceSessionWorktreeOwnershipToken(ownerID: ownerID, generation: generation)
        let supersededTokens = sessionWorktreeOwnershipRecordsByToken.keys.filter {
            $0.ownerID == ownerID && $0 != installedToken
        }
        var supersededResources = SessionWorktreeOwnershipRemoval()
        for supersededToken in supersededTokens {
            supersededResources.append(removeSessionWorktreeOwnershipToken(supersededToken))
        }
        await cleanupOrphanedSessionWorktreeResources(supersededResources)
        guard latestSessionWorktreeOwnershipGenerationByOwnerID[ownerID] == generation else {
            throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
        }

        sessionWorktreeOwnershipRecordsByToken[token] = SessionWorktreeOwnershipRecord(
            bindingFingerprint: bindingFingerprint,
            roots: [],
            pendingSeededRootIDs: []
        )
        reserveSessionWorktreePaths(standardizedPaths, for: token)
        do {
            var preparedRoots: [WorkspaceSessionWorktreeOwnedRoot] = []
            var materializationHintObservations: [String: WorkspaceRootMaterializationHintObservation] = [:]
            var rootSeedShadowPreparations: [WorkspaceRootSeedShadowPreparation] = []
            var pendingSeededRootPreparations: [WorkspacePendingSeededRootPreparation] = []
            for path in standardizedPaths {
                try Task.checkCancellation()
                guard latestSessionWorktreeOwnershipGenerationByOwnerID[ownerID] == generation else {
                    throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
                }
                let hint = initializationHintsByPhysicalRootPath[path]
                #if DEBUG
                    if let hint, let startupContext {
                        receiptConsumptionDecision.ownerGenerationMatch = hint.expectedOwnerBindingGeneration == generation
                            ? .match
                            : .mismatch
                        receiptConsumptionDecision.hintSessionMatch = hint.agentSessionID == ownerID
                            ? .match
                            : .mismatch
                        receiptConsumptionDecision.hintCorrelationMatch = hint.correlationID == startupContext.correlationID
                            ? .match
                            : .mismatch
                        receiptConsumptionDecision.hintOwnerMatch = startupContext.agentSessionID == ownerID
                            ? .match
                            : .mismatch
                    }
                #endif
                var servingFallbackReason: WorkspaceRootSeedFallbackReason?
                if let startupContext,
                   startupContext.flags.serveDiffSeededWorktreeStartup,
                   startupContext.servingControl == .automatic,
                   let hint
                {
                    let observation: WorkspaceRootMaterializationHintObservation = if hint.expectedOwnerBindingGeneration != generation
                        || hint.agentSessionID != ownerID
                        || startupContext.agentSessionID != ownerID
                    {
                        .fallback(.ownerSuperseded)
                    } else {
                        await rootMaterializationHintEvaluator.observe(
                            hint,
                            observationEnabled: true
                        )
                    }
                    try Task.checkCancellation()
                    guard latestSessionWorktreeOwnershipGenerationByOwnerID[ownerID] == generation else {
                        throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
                    }
                    materializationHintObservations[path] = observation
                    #if DEBUG
                        switch observation {
                        case .observationDisabled:
                            receiptConsumptionDecision.initialHintObservation = .disabled
                        case let .fallback(reason):
                            receiptConsumptionDecision.initialHintObservation = .fallback(reason)
                        case .eligible:
                            receiptConsumptionDecision.initialHintObservation = .eligible
                        }
                    #endif
                    switch observation {
                    case .observationDisabled:
                        break
                    case let .fallback(reason):
                        servingFallbackReason = reason
                        WorktreeStartupInstrumentation.record(
                            .seedFallback,
                            context: startupContext,
                            route: .diffSeedServing,
                            fallback: reason
                        )
                    case .eligible:
                        let attempt = try await FileSystemService.withContentReadForegroundActivity(
                            kind: .rootLoad
                        ) {
                            try await self.preparePendingSeededRoot(
                                token: token,
                                bindingFingerprint: bindingFingerprint,
                                standardizedPath: path,
                                hint: hint,
                                startupContext: startupContext
                            )
                        }
                        switch attempt {
                        case let .prepared(preparation):
                            #if DEBUG
                                receiptConsumptionDecision.pendingSeededPreparationResult = .eligible
                                receiptConsumptionDecision.fullCrawlPerformed = false
                                receiptConsumptionDecision.finalObservation = .eligible
                                receiptConsumptionDecision.selectedRoute = .diffSeedServing
                            #endif
                            pendingSeededRootPreparations.append(preparation)
                            continue
                        case let .fallback(reason):
                            #if DEBUG
                                receiptConsumptionDecision.pendingSeededPreparationResult = .fallback(reason)
                            #endif
                            servingFallbackReason = reason
                            materializationHintObservations[path] = .fallback(reason)
                        }
                    }
                }

                if let startupContext {
                    #if DEBUG
                        receiptConsumptionDecision.fullCrawlPerformed = true
                        receiptConsumptionDecision.selectedRoute = .fullCrawl
                    #endif
                    WorktreeStartupInstrumentation.record(
                        .rootLoadStarted,
                        context: startupContext,
                        route: .fullCrawl
                    )
                }
                var isDirectory = ObjCBool(false)
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                      isDirectory.boolValue
                else {
                    throw WorkspaceSessionWorktreeOwnershipError.unavailableRoot(path)
                }
                let root: WorkspaceRootRecord
                do {
                    root = try await loadRoot(
                        path: path,
                        kind: .sessionWorktree,
                        respectRepoIgnore: true,
                        respectCursorignore: true,
                        sessionWorktreeReservationToken: token
                    )
                } catch is IgnoreRulePolicyResolutionError {
                    throw WorkspaceSessionWorktreeOwnershipError.unavailableRoot(path)
                }
                try Task.checkCancellation()
                guard latestSessionWorktreeOwnershipGenerationByOwnerID[ownerID] == generation,
                      let state = rootStatesByID[root.id],
                      state.root.kind == .sessionWorktree,
                      state.root.standardizedFullPath == path
                else {
                    if latestSessionWorktreeOwnershipGenerationByOwnerID[ownerID] != generation {
                        throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
                    }
                    throw WorkspaceSessionWorktreeOwnershipError.invalidRootKind(path)
                }
                let ownedRoot = WorkspaceSessionWorktreeOwnedRoot(
                    rootID: root.id,
                    lifetimeID: state.lifetimeID,
                    standardizedPhysicalPath: path
                )
                preparedRoots.append(ownedRoot)
                try convertSessionWorktreeReservationToClaim(
                    token: token,
                    bindingFingerprint: bindingFingerprint,
                    preparedRoots: preparedRoots,
                    ownedRoot: ownedRoot
                )
                try await reconcileAggregateWatcherDemand(rootID: root.id)
                try Task.checkCancellation()
                guard latestSessionWorktreeOwnershipGenerationByOwnerID[ownerID] == generation,
                      isRootLifetimeCurrent(rootID: root.id, expectedLifetimeID: state.lifetimeID),
                      let rootCatalogGeneration = catalogGenerationsByRootID[root.id],
                      let appliedIndexGeneration = appliedIndexGenerationsByRootID[root.id]
                else {
                    throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
                }

                let observation: WorkspaceRootMaterializationHintObservation = if let servingFallbackReason {
                    .fallback(servingFallbackReason)
                } else if startupContext?.servingControl == .forceFullCrawl {
                    .fallback(.noReceipt)
                } else if let hint,
                          hint.expectedOwnerBindingGeneration != generation
                          || hint.agentSessionID != ownerID
                          || startupContext?.agentSessionID != ownerID
                {
                    .fallback(.ownerSuperseded)
                } else {
                    await rootMaterializationHintEvaluator.observe(
                        hint,
                        observationEnabled: startupContext?.flags.observeDiffSeededWorktreeStartup ?? false
                    )
                }
                #if DEBUG
                    switch observation {
                    case .observationDisabled:
                        receiptConsumptionDecision.finalObservation = .disabled
                        receiptConsumptionDecision.initialHintObservation = receiptConsumptionDecision.initialHintObservation
                            ?? .disabled
                    case let .fallback(reason):
                        receiptConsumptionDecision.finalObservation = .fallback(reason)
                        receiptConsumptionDecision.initialHintObservation = receiptConsumptionDecision.initialHintObservation
                            ?? .fallback(reason)
                    case .eligible:
                        receiptConsumptionDecision.finalObservation = .eligible
                        receiptConsumptionDecision.initialHintObservation = receiptConsumptionDecision.initialHintObservation
                            ?? .eligible
                    }
                #endif
                if servingFallbackReason == nil,
                   startupContext?.servingControl != .forceFullCrawl,
                   case let .fallback(reason) = observation,
                   let startupContext,
                   startupContext.flags.observeDiffSeededWorktreeStartup
                {
                    WorktreeStartupInstrumentation.record(
                        .shadowVerified,
                        context: startupContext,
                        route: .diffSeedObservation,
                        fallback: reason
                    )
                }
                if servingFallbackReason == nil,
                   startupContext?.servingControl != .forceFullCrawl,
                   case .eligible = observation,
                   let hint,
                   let startupContext,
                   startupContext.flags.observeDiffSeededWorktreeStartup
                {
                    let planningOutcome = await rootSeedPlanner.plan(hint: hint, service: state.service)
                    switch planningOutcome {
                    case let .fallback(reason):
                        WorktreeStartupInstrumentation.record(
                            .shadowVerified,
                            context: startupContext,
                            route: .diffSeedObservation,
                            fallback: reason
                        )
                    case let .planned(planHandle):
                        let authoritativeFileCount = state.fileIDsByRelativePath.values.count(where: {
                            isDiscoverableFileID($0)
                        })
                        let authoritativeFolderCount = state.folderIDsByRelativePath.count(where: { relativePath, folderID in
                            !relativePath.isEmpty && isDiscoverableFolderID(folderID)
                        })
                        var plannedFileCount = 0
                        var plannedFolderCount = 0
                        var matches = true
                        do {
                            let reader = try planHandle.makeReader()
                            while let record = try reader.next() {
                                guard let relativePath = String(data: record.relativePathBytes, encoding: .utf8),
                                      Data(relativePath.utf8) == record.relativePathBytes
                                else {
                                    matches = false
                                    continue
                                }
                                switch record.disposition {
                                case .ordinaryFile:
                                    plannedFileCount += 1
                                    guard let fileID = state.fileIDsByRelativePath[relativePath],
                                          isDiscoverableFileID(fileID)
                                    else { matches = false
                                        continue
                                    }
                                case .ordinaryDirectory:
                                    plannedFolderCount += 1
                                    guard let folderID = state.folderIDsByRelativePath[relativePath],
                                          isDiscoverableFolderID(folderID)
                                    else { matches = false
                                        continue
                                    }
                                case .policyIgnoredTrackedFile:
                                    if let fileID = state.fileIDsByRelativePath[relativePath],
                                       isDiscoverableFileID(fileID)
                                    { matches = false }
                                case .baseTombstone:
                                    break
                                }
                            }
                            matches = matches
                                && reader.validationState == .verified
                                && plannedFileCount == authoritativeFileCount
                                && plannedFolderCount == authoritativeFolderCount
                        } catch {
                            matches = false
                        }
                        WorktreeStartupInstrumentation.recordInventoryComparison(matched: matches)
                        if matches {
                            let scope = WorkspaceRootSeedShadowScope(
                                token: token,
                                bindingFingerprint: bindingFingerprint,
                                rootID: root.id,
                                lifetimeID: state.lifetimeID,
                                standardizedPhysicalPath: path,
                                catalogGeneration: rootCatalogGeneration,
                                appliedIndexGeneration: appliedIndexGeneration
                            )
                            rootSeedShadowPreparations.append(WorkspaceRootSeedShadowPreparation(
                                scope: scope,
                                snapshot: planHandle.snapshot,
                                planHandle: planHandle
                            ))
                            WorktreeStartupInstrumentation.record(
                                .shadowVerified,
                                context: startupContext,
                                route: .diffSeedObservation
                            )
                        } else {
                            WorktreeStartupInstrumentation.record(
                                .shadowVerified,
                                context: startupContext,
                                route: .diffSeedObservation,
                                fallback: .unexplainedFilesystemEntry
                            )
                        }
                    }
                }
                guard latestSessionWorktreeOwnershipGenerationByOwnerID[ownerID] == generation,
                      isRootLifetimeCurrent(rootID: root.id, expectedLifetimeID: state.lifetimeID),
                      catalogGenerationsByRootID[root.id] == rootCatalogGeneration,
                      appliedIndexGenerationsByRootID[root.id] == appliedIndexGeneration
                else {
                    materializationHintObservations[path] = .fallback(.serviceIngressGenerationChanged)
                    throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
                }
                materializationHintObservations[path] = observation
            }
            #if DEBUG
                if let startupContext {
                    if pendingSeededRootPreparations.isEmpty {
                        WorktreeStartupInstrumentation.recordReceiptConsumptionDecision(
                            correlationID: startupContext.correlationID,
                            decision: receiptConsumptionDecision
                        )
                    } else {
                        pendingReceiptConsumptionDecisionByToken[token] = (
                            correlationID: startupContext.correlationID,
                            decision: receiptConsumptionDecision
                        )
                    }
                }
            #endif
            return WorkspaceSessionWorktreeOwnershipPreparation(
                token: token,
                bindingFingerprint: bindingFingerprint,
                roots: preparedRoots,
                reusesInstalledOwnership: false,
                materializationHintObservationsByPhysicalRootPath: materializationHintObservations,
                rootSeedShadowPreparations: rootSeedShadowPreparations,
                pendingSeededRootPreparations: pendingSeededRootPreparations
            )
        } catch {
            #if DEBUG
                if let startupContext {
                    WorktreeStartupInstrumentation.recordReceiptConsumptionDecision(
                        correlationID: startupContext.correlationID,
                        decision: receiptConsumptionDecision
                    )
                }
            #endif
            let resources = removeSessionWorktreeOwnershipToken(token)
            await cleanupOrphanedSessionWorktreeResources(resources)
            throw error
        }
    }

    @discardableResult
    func commitSessionWorktreeOwnership(
        _ preparation: WorkspaceSessionWorktreeOwnershipPreparation
    ) async throws -> [WorkspaceSessionWorktreeOwnedRoot] {
        if preparation.reusesInstalledOwnership {
            guard installedSessionWorktreeOwnershipTokenByOwnerID[preparation.token.ownerID] == preparation.token,
                  let record = sessionWorktreeOwnershipRecordsByToken[preparation.token],
                  sessionWorktreeOwnershipRecordIsCurrent(record)
            else {
                throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
            }
            return record.roots
        }
        if !preparation.pendingSeededRootPreparations.isEmpty {
            return try await commitPendingSeededSessionWorktreeOwnership(preparation)
        }
        guard latestSessionWorktreeOwnershipGenerationByOwnerID[preparation.token.ownerID] == preparation.token.generation,
              let record = sessionWorktreeOwnershipRecordsByToken[preparation.token],
              record.bindingFingerprint == preparation.bindingFingerprint,
              record.roots == preparation.roots,
              record.pendingSeededRootIDs == preparation.pendingSeededRootPreparations.map(\.id),
              sessionWorktreeOwnershipRecordIsCurrent(record)
        else {
            throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
        }

        if record.roots.isEmpty {
            installedSessionWorktreeOwnershipTokenByOwnerID.removeValue(forKey: preparation.token.ownerID)
            var releasedResources = removeSessionWorktreeOwnershipToken(preparation.token)
            let previousTokens = sessionWorktreeOwnershipRecordsByToken.keys.filter {
                $0.ownerID == preparation.token.ownerID
            }
            for previousToken in previousTokens {
                releasedResources.append(removeSessionWorktreeOwnershipToken(previousToken))
            }
            scheduleOrphanedSessionWorktreeResourceCleanup(releasedResources)
            return []
        }

        let previousToken = installedSessionWorktreeOwnershipTokenByOwnerID.updateValue(
            preparation.token,
            forKey: preparation.token.ownerID
        )
        var previousResources = SessionWorktreeOwnershipRemoval()
        if let previousToken, previousToken != preparation.token {
            previousResources = removeSessionWorktreeOwnershipToken(previousToken)
        }
        for shadowPreparation in preparation.rootSeedShadowPreparations {
            installRootSeedSearchShadow(shadowPreparation)
        }
        scheduleOrphanedSessionWorktreeResourceCleanup(previousResources)
        return record.roots
    }

    private func commitPendingSeededSessionWorktreeOwnership(
        _ preparation: WorkspaceSessionWorktreeOwnershipPreparation
    ) async throws -> [WorkspaceSessionWorktreeOwnedRoot] {
        let pendingIDs = preparation.pendingSeededRootPreparations.map(\.id)
        guard latestSessionWorktreeOwnershipGenerationByOwnerID[preparation.token.ownerID]
            == preparation.token.generation,
            let record = sessionWorktreeOwnershipRecordsByToken[preparation.token],
            record.bindingFingerprint == preparation.bindingFingerprint,
            record.roots == preparation.roots,
            record.pendingSeededRootIDs == pendingIDs,
            sessionWorktreeVisibleRootsAreCurrent(record.roots),
            pendingIDs.allSatisfy({ pendingID in
                guard let pending = pendingSeededRootsByID[pendingID],
                      pending.token == preparation.token,
                      pending.bindingFingerprint == preparation.bindingFingerprint,
                      pending.phase == .readyForCommit,
                      pending.preparedShard != nil,
                      pending.attachment.map({
                          publisherIngressCoordinator.isPublisherIngressOpen($0.subscription)
                      }) == true,
                      pendingSeededRootIDsByStandardizedPath[pending.standardizedPath] == pendingID,
                      rootIDsByStandardizedPath[pending.standardizedPath] == nil,
                      sessionWorktreeReservedPathsByToken[preparation.token]?
                      .contains(pending.standardizedPath) == true
                else { return false }
                return true
            })
        else {
            throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
        }

        // Metadata callbacks may have arrived after preparation returned. Each
        // pending root gets at most the single event-triggered recapture owned by
        // its fence; no timer or polling path is introduced.
        do {
            for pendingID in pendingIDs {
                guard let pending = pendingSeededRootsByID[pendingID],
                      let fence = pending.authorityFence,
                      let authorityClaim = pending.authorityClaim
                else { throw WorkspaceSessionWorktreeOwnershipError.staleUpdate }
                let validated = try await authorityClaim
                    .validatePendingAuthorityFence(replacing: fence)
                try await installValidatedPendingAuthorityFence(
                    validated,
                    pendingID: pendingID,
                    token: preparation.token,
                    standardizedPath: pending.standardizedPath,
                    expectedPhase: .readyForCommit
                )
                WorktreeStartupInstrumentation.recordSeedMetadataRevalidation(
                    used: validated.revalidationUsed
                )
            }
        } catch let error as WorkspaceSessionWorktreeOwnershipError {
            throw error
        } catch {
            return try await fallBackPendingSeededRootsDuringCommit(
                preparation,
                pendingIDs: pendingIDs,
                reason: .authorityUnstable
            )
        }

        // Resume each watcher while its root is still private. Any publication
        // that lands before the ingress handoff invalidates the prepared shard
        // and takes the ordinary one-shot crawl route.
        for pendingID in pendingIDs {
            guard let pending = pendingSeededRootsByID[pendingID] else {
                throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
            }
            guard let proof = await pending.state.service.activateSeededPublication(
                initializationID: pending.initializationID
            ) else {
                return try await fallBackPendingSeededRootsDuringCommit(
                    preparation,
                    pendingIDs: pendingIDs,
                    reason: .watcherActivationFailure
                )
            }
            try requirePendingSeededRootCurrent(
                pendingID,
                token: preparation.token,
                standardizedPath: pending.standardizedPath,
                expectedPhase: .readyForCommit
            )
            pendingSeededRootsByID[pendingID]?.activationProof = proof
            #if DEBUG
                if let pendingSeededRootDidActivateHandler {
                    await pendingSeededRootDidActivateHandler(pending.standardizedPath)
                }
            #endif
            try requirePendingSeededRootCurrent(
                pendingID,
                token: preparation.token,
                standardizedPath: pending.standardizedPath,
                expectedPhase: .readyForCommit
            )
            await publisherIngressCoordinator.waitForCurrentPublisherIngress(
                rootIDs: [pending.state.root.id]
            )
            guard let current = pendingSeededRootsByID[pendingID],
                  current.terminalFallbackReason == nil,
                  await current.state.service.seededPublicationActivationIsCurrent(proof)
            else {
                return try await fallBackPendingSeededRootsDuringCommit(
                    preparation,
                    pendingIDs: pendingIDs,
                    reason: .serviceIngressGenerationChanged
                )
            }
        }

        guard latestSessionWorktreeOwnershipGenerationByOwnerID[preparation.token.ownerID]
            == preparation.token.generation,
            let currentRecord = sessionWorktreeOwnershipRecordsByToken[preparation.token],
            currentRecord.bindingFingerprint == preparation.bindingFingerprint,
            currentRecord.roots == preparation.roots,
            currentRecord.pendingSeededRootIDs == pendingIDs,
            sessionWorktreeVisibleRootsAreCurrent(currentRecord.roots)
        else { throw WorkspaceSessionWorktreeOwnershipError.staleUpdate }

        var pendingRoots: [PendingSeededRoot] = []
        pendingRoots.reserveCapacity(pendingIDs.count)
        for pendingID in pendingIDs {
            guard let pending = pendingSeededRootsByID[pendingID],
                  pending.phase == .readyForCommit,
                  let shard = pending.preparedShard,
                  shard.key.rootID == pending.state.root.id,
                  shard.key.lifetimeID == pending.state.lifetimeID,
                  shard.pathSearchIndex != nil,
                  let attachment = pending.attachment,
                  pending.activationProof != nil,
                  let authorityFence = pending.authorityFence,
                  publisherIngressCoordinator.isPublisherIngressOpen(attachment.subscription),
                  pending.lastAppliedServicePublicationSequence > 0,
                  pending.lastAppliedWatcherWatermark > .zero,
                  rootIDsByStandardizedPath[pending.standardizedPath] == nil
            else { throw WorkspaceSessionWorktreeOwnershipError.staleUpdate }
            guard workspaceStateAuthority
                .pendingInitializationAuthorityFenceIsSynchronouslyCurrent(authorityFence),
                pending.authorityMutationDepth == 0,
                pending.terminalFallbackReason == nil
            else {
                return try await fallBackPendingSeededRootsDuringCommit(
                    preparation,
                    pendingIDs: pendingIDs,
                    reason: .authorityUnstable
                )
            }
            pendingRoots.append(pending)
        }

        var pausedHandoffSubscriptions: [WorkspaceFileSystemIngressCoordinator.Subscription] = []
        for pending in pendingRoots {
            guard let attachment = pending.attachment else {
                throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
            }
            let root = pending.state.root
            let diagnosticRootToken = pending.state.service.diagnosticRootToken
            let publishedLifetimeID = pending.state.lifetimeID
            let replacement: WorkspaceFileSystemIngressCoordinator.DrainHandler = { [weak self] publication, correlation in
                await self?.handleObservedPublisherFileSystemPublication(
                    publication,
                    root: root,
                    expectedLifetimeID: publishedLifetimeID,
                    publicationCorrelation: correlation,
                    diagnosticRootToken: diagnosticRootToken
                )
            }
            if !publisherIngressCoordinator.pauseDrainAndReplaceHandler(
                attachment.subscription,
                drainHandler: replacement
            ) {
                await publisherIngressCoordinator.waitForCurrentPublisherIngress(rootIDs: [root.id])
                guard pendingSeededRootsByID[pending.id]?.terminalFallbackReason == nil,
                      publisherIngressCoordinator.pauseDrainAndReplaceHandler(
                          attachment.subscription,
                          drainHandler: replacement
                      )
                else {
                    for subscription in pausedHandoffSubscriptions {
                        _ = publisherIngressCoordinator.resumeDrainAfterHandoff(subscription)
                    }
                    return try await fallBackPendingSeededRootsDuringCommit(
                        preparation,
                        pendingIDs: pendingIDs,
                        reason: .serviceIngressGenerationChanged
                    )
                }
            }
            pausedHandoffSubscriptions.append(attachment.subscription)
        }

        for pending in pendingRoots {
            guard let proof = pending.activationProof,
                  await pending.state.service.seededPublicationActivationIsCurrent(proof),
                  pendingSeededRootIsCurrent(
                      pending.id,
                      token: preparation.token,
                      standardizedPath: pending.standardizedPath,
                      expectedPhase: .readyForCommit
                  )
            else {
                for subscription in pausedHandoffSubscriptions {
                    _ = publisherIngressCoordinator.resumeDrainAfterHandoff(subscription)
                }
                return try await fallBackPendingSeededRootsDuringCommit(
                    preparation,
                    pendingIDs: pendingIDs,
                    reason: .serviceIngressGenerationChanged
                )
            }
        }

        guard pendingRoots.compactMap(\.authorityFence).count == pendingRoots.count else {
            throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
        }
        let publicationFences = pendingRoots.compactMap(\.authorityFence)

        // No await, callback, task creation, or throwing operation is allowed
        // from the authority permit through the complete visible-state assignment.
        var installedRoots = currentRecord.roots
        var newlyPublishedRootIDs = Set<UUID>()
        var newlyPublishedPaths: [String] = []
        var pendingServices: [(FileSystemService, FileSystemSeedPublicationActivationProof, WorktreeStartupContext)] = []
        var previousToken: WorkspaceSessionWorktreeOwnershipToken?
        let didPublish = workspaceStateAuthority.withPendingInitializationAuthorityPublicationPermit(
            publicationFences
        ) {
            guard latestSessionWorktreeOwnershipGenerationByOwnerID[preparation.token.ownerID]
                == preparation.token.generation,
                sessionWorktreeOwnershipRecordsByToken[preparation.token]?.pendingSeededRootIDs == pendingIDs,
                pendingRoots.allSatisfy({ pending in
                    guard let fence = pending.authorityFence,
                          let current = pendingSeededRootsByID[pending.id]
                    else { return false }
                    return current.phase == .readyForCommit
                        && current.authorityFence == fence
                        && current.authorityInvalidationGeneration == fence.lease.invalidationGeneration
                        && current.authorityAcceptedMetadataWatermark == fence.acceptedMetadataWatermark
                        && current.authorityMutationDepth == 0
                        && current.terminalFallbackReason == nil
                }),
                pausedHandoffSubscriptions.allSatisfy({
                    publisherIngressCoordinator.resumeDrainAfterHandoff($0)
                })
            else { return false }

            for pending in pendingRoots {
                guard let fence = pending.authorityFence,
                      let authorityClaim = pending.authorityClaim,
                      let activationProof = pending.activationProof
                else { return false }
                let root = pending.state.root
                let ownedRoot = WorkspaceSessionWorktreeOwnedRoot(
                    rootID: root.id,
                    lifetimeID: pending.state.lifetimeID,
                    standardizedPhysicalPath: pending.standardizedPath
                )
                commit(pending.indexes)
                rootIDsByStandardizedPath[pending.standardizedPath] = root.id
                revokeAllAutomaticSelectionPublicationPermits()
                rootStatesByID[root.id] = pending.state
                rootLoadConfigurationsByPath[pending.standardizedPath] = pending.loadConfiguration
                rootLoadOrder.append(root.id)
                appliedIndexGenerationsByRootID[root.id] = 0
                catalogGenerationsByRootID[root.id] = 0
                publishedRootCatalogShardsByRootID[root.id] = pending.preparedShard
                rootCatalogShardDeltaStatesByRootID[root.id] = RootCatalogShardDeltaState(
                    lifetimeID: pending.state.lifetimeID,
                    lastAppliedIndexGeneration: 0,
                    isDirty: false,
                    capability: .recordsAndPathIndexes
                )
                if let shard = pending.preparedShard {
                    registerPublishedRootCatalogShard(shard, kind: .authoritative)
                }
                if let attachment = pending.attachment {
                    watcherPublisherAttachmentsByKey[WatcherInfrastructureKey(
                        rootID: root.id,
                        lifetimeID: pending.state.lifetimeID
                    )] = attachment
                }
                let lifetimeKey = SessionWorktreeRootLifetimeKey(
                    rootID: root.id,
                    lifetimeID: pending.state.lifetimeID
                )
                sessionWorktreeOwnershipTokensByRootLifetime[lifetimeKey, default: []]
                    .insert(preparation.token)
                removeSessionWorktreeReservation(
                    standardizedPath: pending.standardizedPath,
                    token: preparation.token
                )
                installedRoots.append(ownedRoot)
                newlyPublishedRootIDs.insert(root.id)
                newlyPublishedPaths.append(pending.standardizedPath)
                pendingServices.append((pending.state.service, activationProof, pending.startupContext))
                publishedSeededAuthorityFencesByRootID[root.id] = fence
                publishedSeededAuthorityClaimsByRootID[root.id] = authorityClaim
                publishedSeededAuthorityStatesByRootID[root.id] = PublishedSeededAuthorityState(
                    epoch: 0,
                    pendingInvalidationGeneration: nil,
                    pendingAcceptedMetadataWatermark: fence.acceptedMetadataWatermark,
                    activeMutationDepth: 0,
                    isBlocked: false,
                    isReconciling: false,
                    reconciliationFailed: false,
                    fullCrawlAttemptedGeneration: nil,
                    fullCrawlCompletedGeneration: nil
                )
                pendingSeededRootsByID.removeValue(forKey: pending.id)
                pendingSeededRootIDsByStandardizedPath.removeValue(forKey: pending.standardizedPath)
                #if DEBUG
                    rootCrawlCountsByRootID[root.id] = 0
                #endif
            }
            sessionRootLifetimeClock.advance()
            sessionWorktreeOwnershipRecordsByToken[preparation.token] = SessionWorktreeOwnershipRecord(
                bindingFingerprint: preparation.bindingFingerprint,
                roots: installedRoots,
                pendingSeededRootIDs: []
            )
            previousToken = installedSessionWorktreeOwnershipTokenByOwnerID.updateValue(
                preparation.token,
                forKey: preparation.token.ownerID
            )
            invalidatePathMatchSnapshot(
                affectedRootKinds: [.sessionWorktree],
                reason: .rootLoad,
                affectedRootIDs: newlyPublishedRootIDs
            )
            return true
        } ?? false

        guard didPublish else {
            for subscription in pausedHandoffSubscriptions {
                _ = publisherIngressCoordinator.resumeDrainAfterHandoff(subscription)
            }
            return try await fallBackPendingSeededRootsDuringCommit(
                preparation,
                pendingIDs: pendingIDs,
                reason: .authorityUnstable
            )
        }

        var previousResources = SessionWorktreeOwnershipRemoval()
        if let previousToken, previousToken != preparation.token {
            previousResources = removeSessionWorktreeOwnershipToken(previousToken)
        }
        for shadowPreparation in preparation.rootSeedShadowPreparations {
            installRootSeedSearchShadow(shadowPreparation)
        }

        // Watchers were activated and revalidated while private. Finalization
        // only retires the proof; visibility waiters remain held until it succeeds.
        for (service, activationProof, context) in pendingServices {
            guard await service.finalizeSeededPublication(activationProof) else {
                throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
            }
            WorktreeStartupInstrumentation.record(
                .seedPublished,
                context: context,
                route: .diffSeedServing
            )
        }
        #if DEBUG
            if let pendingDecision = pendingReceiptConsumptionDecisionByToken.removeValue(
                forKey: preparation.token
            ) {
                WorktreeStartupInstrumentation.recordReceiptConsumptionDecision(
                    correlationID: pendingDecision.correlationID,
                    decision: pendingDecision.decision
                )
            }
        #endif
        for path in newlyPublishedPaths {
            finishPendingSeededRootVisibility(path: path)
        }
        for pending in pendingRoots {
            let rootEpoch = WorkspaceCodemapRootEpoch(
                rootID: pending.state.root.id,
                rootLifetimeID: pending.state.lifetimeID
            )
            recordCodemapRootReadyForProjectionPreload(rootEpoch: rootEpoch)
            scheduleCodemapProjectionPreloadAfterRootReady(rootEpoch: rootEpoch)
        }
        scheduleOrphanedSessionWorktreeResourceCleanup(previousResources)
        return installedRoots
    }

    private func fallBackPendingSeededRootsDuringCommit(
        _ preparation: WorkspaceSessionWorktreeOwnershipPreparation,
        pendingIDs: [WorkspacePendingSeededRootID],
        reason: WorkspaceRootSeedFallbackReason
    ) async throws -> [WorkspaceSessionWorktreeOwnedRoot] {
        guard latestSessionWorktreeOwnershipGenerationByOwnerID[preparation.token.ownerID]
            == preparation.token.generation
        else { throw WorkspaceSessionWorktreeOwnershipError.staleUpdate }
        let pending = pendingIDs.compactMap { pendingSeededRootsByID[$0] }
        guard pending.count == pendingIDs.count else {
            throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
        }
        for root in pending {
            await fallBackPendingSeededRoot(
                root.id,
                reason: reason,
                startupContext: root.startupContext
            )
        }

        var roots = sessionWorktreeOwnershipRecordsByToken[preparation.token]?.roots ?? []
        for root in pending {
            guard latestSessionWorktreeOwnershipGenerationByOwnerID[preparation.token.ownerID]
                == preparation.token.generation
            else { throw WorkspaceSessionWorktreeOwnershipError.staleUpdate }
            WorktreeStartupInstrumentation.record(
                .rootLoadStarted,
                context: root.startupContext,
                route: .fullCrawl
            )
            let loaded = try await loadRoot(
                path: root.standardizedPath,
                kind: .sessionWorktree,
                respectRepoIgnore: true,
                respectCursorignore: true,
                sessionWorktreeReservationToken: preparation.token
            )
            guard let loadedState = rootStatesByID[loaded.id] else {
                throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
            }
            let owned = WorkspaceSessionWorktreeOwnedRoot(
                rootID: loaded.id,
                lifetimeID: loadedState.lifetimeID,
                standardizedPhysicalPath: root.standardizedPath
            )
            roots.append(owned)
            try convertSessionWorktreeReservationToClaim(
                token: preparation.token,
                bindingFingerprint: preparation.bindingFingerprint,
                preparedRoots: roots,
                ownedRoot: owned
            )
            try await reconcileAggregateWatcherDemand(rootID: loaded.id)
        }
        let replacement = WorkspaceSessionWorktreeOwnershipPreparation(
            token: preparation.token,
            bindingFingerprint: preparation.bindingFingerprint,
            roots: roots,
            reusesInstalledOwnership: false,
            materializationHintObservationsByPhysicalRootPath:
            preparation.materializationHintObservationsByPhysicalRootPath,
            rootSeedShadowPreparations: preparation.rootSeedShadowPreparations
        )
        let committedRoots = try await commitSessionWorktreeOwnership(replacement)
        #if DEBUG
            if var pendingDecision = pendingReceiptConsumptionDecisionByToken.removeValue(
                forKey: preparation.token
            ) {
                pendingDecision.decision.pendingSeededPreparationResult = .fallback(reason)
                pendingDecision.decision.fullCrawlPerformed = true
                pendingDecision.decision.finalObservation = .fallback(reason)
                pendingDecision.decision.selectedRoute = .fullCrawl
                WorktreeStartupInstrumentation.recordReceiptConsumptionDecision(
                    correlationID: pendingDecision.correlationID,
                    decision: pendingDecision.decision
                )
            }
        #endif
        return committedRoots
    }

    func abortSessionWorktreeOwnership(
        _ preparation: WorkspaceSessionWorktreeOwnershipPreparation
    ) async {
        #if DEBUG
            terminalizePendingReceiptConsumptionDecision(for: preparation.token)
        #endif
        guard !preparation.reusesInstalledOwnership,
              installedSessionWorktreeOwnershipTokenByOwnerID[preparation.token.ownerID] != preparation.token
        else { return }
        let resources = removeSessionWorktreeOwnershipToken(preparation.token)
        await cleanupOrphanedSessionWorktreeResources(resources)
    }

    func releaseSessionWorktreeOwnership(ownerID: UUID) async {
        latestSessionWorktreeOwnershipGenerationByOwnerID[ownerID, default: 0] &+= 1
        installedSessionWorktreeOwnershipTokenByOwnerID.removeValue(forKey: ownerID)
        let tokens = sessionWorktreeOwnershipRecordsByToken.keys.filter { $0.ownerID == ownerID }
        var resources = SessionWorktreeOwnershipRemoval()
        for token in tokens {
            resources.append(removeSessionWorktreeOwnershipToken(token))
        }
        await cleanupOrphanedSessionWorktreeResources(resources)
    }

    func sessionWorktreeOwnershipCovers(
        ownerID: UUID,
        bindingFingerprint: String,
        physicalRootPaths: Set<String>
    ) -> Bool {
        guard let token = installedSessionWorktreeOwnershipTokenByOwnerID[ownerID],
              let record = sessionWorktreeOwnershipRecordsByToken[token],
              record.bindingFingerprint == bindingFingerprint,
              Set(record.roots.map(\.standardizedPhysicalPath)) == Set(physicalRootPaths.map {
                  StandardizedPath.absolute(($0 as NSString).expandingTildeInPath)
              }),
              sessionWorktreeOwnershipRecordIsCurrent(record)
        else { return false }
        return true
    }

    func installedSessionWorktreeRoots(
        ownerID: UUID,
        bindingFingerprint: String,
        physicalRootPaths: Set<String>
    ) -> [WorkspaceRootRecord]? {
        guard sessionWorktreeOwnershipCovers(
            ownerID: ownerID,
            bindingFingerprint: bindingFingerprint,
            physicalRootPaths: physicalRootPaths
        ),
            let token = installedSessionWorktreeOwnershipTokenByOwnerID[ownerID],
            let record = sessionWorktreeOwnershipRecordsByToken[token]
        else { return nil }
        return record.roots.compactMap { rootStatesByID[$0.rootID]?.root }
    }

    func validateSessionRootAuthorization(
        _ authorization: WorkspaceSessionRootAuthorization
    ) -> WorkspaceSessionRootAuthorizationMismatch? {
        sessionRootAuthorizationMismatch(authorization)
    }

    private func sessionRootAuthorizationMismatch(
        _ authorization: WorkspaceSessionRootAuthorization
    ) -> WorkspaceSessionRootAuthorizationMismatch? {
        guard let token = installedSessionWorktreeOwnershipTokenByOwnerID[authorization.sessionID] else {
            return .token
        }
        guard token.generation == authorization.ownershipGeneration else {
            return .generation
        }
        guard let record = sessionWorktreeOwnershipRecordsByToken[token] else {
            return .token
        }
        guard sessionWorktreeOwnershipRecordIsCurrent(record) else {
            return .rootClaim
        }
        guard let ownedRoot = record.roots.first(where: { $0.rootID == authorization.root.id }) else {
            return .rootID
        }
        guard ownedRoot.lifetimeID == authorization.lifetimeID else {
            return .lifetime
        }
        guard ownedRoot.standardizedPhysicalPath == authorization.root.standardizedFullPath else {
            return .path
        }
        guard let state = rootStatesByID[authorization.root.id] else {
            return .rootID
        }
        guard state.lifetimeID == authorization.lifetimeID else {
            return .lifetime
        }
        guard state.root.kind == .sessionWorktree else {
            return .kind
        }
        guard state.root.standardizedFullPath == authorization.root.standardizedFullPath else {
            return .path
        }
        let lifetimeKey = SessionWorktreeRootLifetimeKey(
            rootID: authorization.root.id,
            lifetimeID: authorization.lifetimeID
        )
        guard sessionWorktreeOwnershipTokensByRootLifetime[lifetimeKey]?.contains(token) == true else {
            return .rootClaim
        }
        return nil
    }

    #if DEBUG
        enum SessionWorktreeOwnershipDrainDebugError: Error {
            case invalidExpectedPathDigests
        }

        struct SessionWorktreeOwnershipDrainDebugSnapshot: Equatable {
            let ownerID: UUID
            let ownerGeneration: UInt64
            let expectedPhysicalPathDigests: [String]
            let actorEntryDelayNanoseconds: UInt64
            let installedTokenCount: Int
            let provisionalTokenCount: Int
            let rootClaimCount: Int
            let pathReservationCount: Int
            let matchingLiveRootCount: Int
            let matchingWatcherAttachmentCount: Int
            let pendingSeededRootCount: Int
            let pendingVisibilityWaiterCount: Int
            let queuedPublicationCount: Int
            let applyingPublicationCount: Int
            let outstandingPublicationCount: Int
            let publisherWaiterCount: Int
            let unloadingRootCount: Int
            let reservedLoadFlightCount: Int
            let isDrained: Bool
        }

        struct SessionWorktreeOwnershipDebugSnapshot: Equatable {
            let installedOwnerCount: Int
            let provisionalOwnerCount: Int
            let rootClaimCount: Int
            let pathReservationCount: Int
            let explicitWatcherDemandCount: Int
            let pendingSeededRootCount: Int
            let pendingVisibilityWaiterCount: Int
        }

        func sessionWorktreeOwnershipDrainSnapshotForTesting(
            ownerID: UUID,
            expectedPhysicalPathDigests: Set<String>,
            requestedAtNanoseconds: UInt64
        ) async throws -> SessionWorktreeOwnershipDrainDebugSnapshot {
            guard !expectedPhysicalPathDigests.isEmpty,
                  expectedPhysicalPathDigests.count <= 16,
                  expectedPhysicalPathDigests.allSatisfy({
                      $0.count == 64 && $0.allSatisfy(\.isHexDigit)
                  })
            else { throw SessionWorktreeOwnershipDrainDebugError.invalidExpectedPathDigests }

            let matchingCleanupTasks: [Task<Void, Never>] =
                sessionWorktreeOrphanLoadCleanupsByID.values.compactMap { cleanup in
                    guard cleanup.ownerID == ownerID,
                          expectedPhysicalPathDigests.contains(
                              Self.sessionWorktreePathDigest(cleanup.standardizedPath)
                          )
                    else { return nil }
                    return cleanup.task
                }
            if !matchingCleanupTasks.isEmpty {
                sessionWorktreeDrainLoadFlightWaiterCount += 1
                sessionWorktreeDrainDidEnterLoadFlightWaitHandler?()
                for task in matchingCleanupTasks {
                    await task.value
                }
                sessionWorktreeDrainLoadFlightWaiterCount -= 1
            }

            let entry = DispatchTime.now().uptimeNanoseconds
            let ownerTokens = Set(sessionWorktreeOwnershipRecordsByToken.keys.filter { $0.ownerID == ownerID })
            let installedToken = installedSessionWorktreeOwnershipTokenByOwnerID[ownerID]
            let installedTokenCount = installedToken.map { ownerTokens.contains($0) ? 1 : 0 } ?? 0
            let provisionalTokenCount = ownerTokens.count - installedTokenCount
            let rootClaimCount = sessionWorktreeOwnershipTokensByRootLifetime.values.reduce(0) {
                $0 + $1.intersection(ownerTokens).count
            }
            let pathReservationCount = sessionWorktreeReservationTokensByStandardizedPath.values.reduce(0) {
                $0 + $1.intersection(ownerTokens).count
            }
            let matchingLiveRootIDs: Set<UUID> = Set(rootStatesByID.compactMap { entry -> UUID? in
                let (rootID, state) = entry
                guard state.root.kind == .sessionWorktree,
                      expectedPhysicalPathDigests.contains(Self.sessionWorktreePathDigest(state.root.standardizedFullPath))
                else { return nil }
                return rootID
            })
            let matchingPending = pendingSeededRootsByID.values.filter {
                expectedPhysicalPathDigests.contains(Self.sessionWorktreePathDigest($0.standardizedPath))
            }
            var matchingIngressRootIDs = matchingLiveRootIDs
            matchingIngressRootIDs.formUnion(matchingPending.map(\.state.root.id))
            let matchingWatcherAttachmentCount = watcherPublisherAttachmentsByKey.keys.count {
                matchingIngressRootIDs.contains($0.rootID)
            }
            let pendingVisibilityWaiterCount = pendingSeededRootVisibilityWaitersByPath.reduce(0) {
                expectedPhysicalPathDigests.contains(Self.sessionWorktreePathDigest($1.key))
                    ? $0 + $1.value.count
                    : $0
            }
            let ingressSnapshots = matchingIngressRootIDs.map {
                publisherIngressCoordinator.debugSnapshot(rootID: $0)
            }
            let queuedPublicationCount = ingressSnapshots.reduce(0) { $0 + $1.queuedPublicationCount }
            let applyingPublicationCount = ingressSnapshots.reduce(0) { $0 + $1.applyingPublicationCount }
            let outstandingPublicationCount = ingressSnapshots.reduce(0) { $0 + $1.outstandingPublicationCount }
            let publisherWaiterCount = ingressSnapshots.reduce(0) { $0 + $1.waiterCount }
            let unloadingRootCount = unloadingRootPaths.count {
                expectedPhysicalPathDigests.contains(Self.sessionWorktreePathDigest($0))
            }
            let reservedLoadFlightCount = sessionWorktreeOrphanLoadCleanupsByID.values.count { cleanup in
                cleanup.ownerID == ownerID
                    && expectedPhysicalPathDigests.contains(
                        Self.sessionWorktreePathDigest(cleanup.standardizedPath)
                    )
            } + sessionWorktreeOrphanLoadCleanupOverflowCount
            let componentCounts = [
                installedTokenCount,
                provisionalTokenCount,
                rootClaimCount,
                pathReservationCount,
                matchingLiveRootIDs.count,
                matchingWatcherAttachmentCount,
                matchingPending.count,
                pendingVisibilityWaiterCount,
                queuedPublicationCount,
                applyingPublicationCount,
                outstandingPublicationCount,
                publisherWaiterCount,
                unloadingRootCount,
                reservedLoadFlightCount
            ]
            return SessionWorktreeOwnershipDrainDebugSnapshot(
                ownerID: ownerID,
                ownerGeneration: latestSessionWorktreeOwnershipGenerationByOwnerID[ownerID] ?? 0,
                expectedPhysicalPathDigests: expectedPhysicalPathDigests.sorted(),
                actorEntryDelayNanoseconds: entry >= requestedAtNanoseconds ? entry - requestedAtNanoseconds : 0,
                installedTokenCount: installedTokenCount,
                provisionalTokenCount: provisionalTokenCount,
                rootClaimCount: rootClaimCount,
                pathReservationCount: pathReservationCount,
                matchingLiveRootCount: matchingLiveRootIDs.count,
                matchingWatcherAttachmentCount: matchingWatcherAttachmentCount,
                pendingSeededRootCount: matchingPending.count,
                pendingVisibilityWaiterCount: pendingVisibilityWaiterCount,
                queuedPublicationCount: queuedPublicationCount,
                applyingPublicationCount: applyingPublicationCount,
                outstandingPublicationCount: outstandingPublicationCount,
                publisherWaiterCount: publisherWaiterCount,
                unloadingRootCount: unloadingRootCount,
                reservedLoadFlightCount: reservedLoadFlightCount,
                isDrained: componentCounts.allSatisfy { $0 == 0 }
            )
        }

        private nonisolated static func sessionWorktreePathDigest(_ path: String) -> String {
            let standardized = StandardizedPath.absolute((path as NSString).expandingTildeInPath)
            return SHA256.hash(data: Data(standardized.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
        }

        func sessionWorktreeOwnershipDebugSnapshotForTesting() -> SessionWorktreeOwnershipDebugSnapshot {
            let installedTokens = Set(installedSessionWorktreeOwnershipTokenByOwnerID.values)
            return SessionWorktreeOwnershipDebugSnapshot(
                installedOwnerCount: installedTokens.count,
                provisionalOwnerCount: sessionWorktreeOwnershipRecordsByToken.keys.count(where: { !installedTokens.contains($0) }),
                rootClaimCount: sessionWorktreeOwnershipTokensByRootLifetime.values.reduce(0) { $0 + $1.count },
                pathReservationCount: sessionWorktreeReservationTokensByStandardizedPath.values.reduce(0) { $0 + $1.count },
                explicitWatcherDemandCount: explicitWatcherDemandRootIDs.count,
                pendingSeededRootCount: pendingSeededRootsByID.count,
                pendingVisibilityWaiterCount: pendingSeededRootVisibilityWaitersByPath.values.reduce(0) {
                    $0 + $1.count
                }
            )
        }
    #endif

    private func sessionWorktreeOwnershipRecordIsCurrent(_ record: SessionWorktreeOwnershipRecord) -> Bool {
        guard record.pendingSeededRootIDs.isEmpty else { return false }
        return sessionWorktreeVisibleRootsAreCurrent(record.roots)
    }

    private func sessionWorktreeVisibleRootsAreCurrent(
        _ roots: [WorkspaceSessionWorktreeOwnedRoot]
    ) -> Bool {
        roots.allSatisfy { root in
            let watcherKey = WatcherInfrastructureKey(rootID: root.rootID, lifetimeID: root.lifetimeID)
            guard let state = rootStatesByID[root.rootID],
                  state.lifetimeID == root.lifetimeID,
                  state.root.kind == .sessionWorktree,
                  state.root.standardizedFullPath == root.standardizedPhysicalPath,
                  let attachment = watcherPublisherAttachmentsByKey[watcherKey],
                  publisherIngressCoordinator.isPublisherIngressOpen(attachment.subscription)
            else { return false }
            let key = SessionWorktreeRootLifetimeKey(rootID: root.rootID, lifetimeID: root.lifetimeID)
            return sessionWorktreeOwnershipTokensByRootLifetime[key]?.isEmpty == false
        }
    }

    private func reserveSessionWorktreePaths(
        _ standardizedPaths: [String],
        for token: WorkspaceSessionWorktreeOwnershipToken
    ) {
        guard !standardizedPaths.isEmpty else { return }
        let paths = Set(standardizedPaths)
        sessionWorktreeReservedPathsByToken[token] = paths
        for path in paths {
            sessionWorktreeReservationTokensByStandardizedPath[path, default: []].insert(token)
        }
    }

    private func registerSessionWorktreeReservationLoadFlight(
        _ flight: RootLoadFlight,
        standardizedPath: String,
        token: WorkspaceSessionWorktreeOwnershipToken
    ) {
        guard sessionWorktreeReservedPathsByToken[token]?.contains(standardizedPath) == true else { return }
        sessionWorktreeReservationLoadFlightsByToken[token, default: [:]][standardizedPath] = flight
    }

    private func convertSessionWorktreeReservationToClaim(
        token: WorkspaceSessionWorktreeOwnershipToken,
        bindingFingerprint: String,
        preparedRoots: [WorkspaceSessionWorktreeOwnedRoot],
        ownedRoot: WorkspaceSessionWorktreeOwnedRoot
    ) throws {
        guard let record = sessionWorktreeOwnershipRecordsByToken[token],
              record.bindingFingerprint == bindingFingerprint,
              record.roots == Array(preparedRoots.dropLast()),
              preparedRoots.last == ownedRoot,
              sessionWorktreeReservedPathsByToken[token]?.contains(ownedRoot.standardizedPhysicalPath) == true,
              sessionWorktreeReservationTokensByStandardizedPath[
                  ownedRoot.standardizedPhysicalPath
              ]?.contains(token) == true
        else {
            throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
        }

        sessionWorktreeOwnershipRecordsByToken[token] = SessionWorktreeOwnershipRecord(
            bindingFingerprint: bindingFingerprint,
            roots: preparedRoots,
            pendingSeededRootIDs: record.pendingSeededRootIDs
        )
        let rootKey = SessionWorktreeRootLifetimeKey(
            rootID: ownedRoot.rootID,
            lifetimeID: ownedRoot.lifetimeID
        )
        sessionWorktreeOwnershipTokensByRootLifetime[rootKey, default: []].insert(token)
        if sessionWorktreeOwnershipTokensByRootLifetime[rootKey] != Set([token]) {
            invalidateRootSeedSearchShadow(rootID: ownedRoot.rootID)
        }
        removeSessionWorktreeReservation(
            standardizedPath: ownedRoot.standardizedPhysicalPath,
            token: token
        )
    }

    private func registerPendingSessionWorktreeRoot(
        _ pendingID: WorkspacePendingSeededRootID,
        standardizedPath: String,
        token: WorkspaceSessionWorktreeOwnershipToken,
        bindingFingerprint: String
    ) throws {
        guard let record = sessionWorktreeOwnershipRecordsByToken[token],
              record.bindingFingerprint == bindingFingerprint,
              sessionWorktreeReservedPathsByToken[token]?.contains(standardizedPath) == true,
              sessionWorktreeReservationTokensByStandardizedPath[standardizedPath]?.contains(token) == true,
              !record.pendingSeededRootIDs.contains(pendingID)
        else {
            throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
        }
        sessionWorktreeOwnershipRecordsByToken[token] = SessionWorktreeOwnershipRecord(
            bindingFingerprint: record.bindingFingerprint,
            roots: record.roots,
            pendingSeededRootIDs: record.pendingSeededRootIDs + [pendingID]
        )
    }

    private func removeSessionWorktreeReservation(
        standardizedPath: String,
        token: WorkspaceSessionWorktreeOwnershipToken
    ) {
        sessionWorktreeReservationTokensByStandardizedPath[standardizedPath]?.remove(token)
        if sessionWorktreeReservationTokensByStandardizedPath[standardizedPath]?.isEmpty == true {
            sessionWorktreeReservationTokensByStandardizedPath.removeValue(forKey: standardizedPath)
        }
        sessionWorktreeReservedPathsByToken[token]?.remove(standardizedPath)
        sessionWorktreeReservationLoadFlightsByToken[token]?.removeValue(forKey: standardizedPath)
        if sessionWorktreeReservedPathsByToken[token]?.isEmpty == true {
            sessionWorktreeReservedPathsByToken.removeValue(forKey: token)
        }
        if sessionWorktreeReservationLoadFlightsByToken[token]?.isEmpty == true {
            sessionWorktreeReservationLoadFlightsByToken.removeValue(forKey: token)
        }
    }

    private func removeSessionWorktreeOwnershipToken(
        _ token: WorkspaceSessionWorktreeOwnershipToken
    ) -> SessionWorktreeOwnershipRemoval {
        #if DEBUG
            terminalizePendingReceiptConsumptionDecision(for: token)
        #endif
        let record = sessionWorktreeOwnershipRecordsByToken.removeValue(forKey: token)
        let reservedPaths = sessionWorktreeReservedPathsByToken.removeValue(forKey: token) ?? []
        let reservedLoadFlightsByPath =
            sessionWorktreeReservationLoadFlightsByToken.removeValue(forKey: token) ?? [:]
        for path in reservedPaths {
            sessionWorktreeReservationTokensByStandardizedPath[path]?.remove(token)
            if sessionWorktreeReservationTokensByStandardizedPath[path]?.isEmpty == true {
                sessionWorktreeReservationTokensByStandardizedPath.removeValue(forKey: path)
            }
        }
        for root in record?.roots ?? [] {
            if rootSeedSearchShadowsByRootID[root.rootID]?.scope.token == token {
                invalidateRootSeedSearchShadow(rootID: root.rootID)
            }
            let key = SessionWorktreeRootLifetimeKey(rootID: root.rootID, lifetimeID: root.lifetimeID)
            sessionWorktreeOwnershipTokensByRootLifetime[key]?.remove(token)
            if sessionWorktreeOwnershipTokensByRootLifetime[key]?.isEmpty == true {
                sessionWorktreeOwnershipTokensByRootLifetime.removeValue(forKey: key)
            }
        }
        return SessionWorktreeOwnershipRemoval(
            ownedRoots: record?.roots ?? [],
            reservedLoadFlights: reservedLoadFlightsByPath.compactMap { path, flight in
                guard reservedPaths.contains(path) else { return nil }
                return SessionWorktreeReservedLoadFlight(
                    ownerID: token.ownerID,
                    standardizedPath: path,
                    flight: flight
                )
            },
            pendingSeededRootIDs: record?.pendingSeededRootIDs ?? []
        )
    }

    #if DEBUG
        func terminalizeReceiptConsumptionDecision(
            _ preparation: WorkspaceSessionWorktreeOwnershipPreparation
        ) {
            terminalizePendingReceiptConsumptionDecision(for: preparation.token)
        }

        private func terminalizePendingReceiptConsumptionDecision(
            for token: WorkspaceSessionWorktreeOwnershipToken
        ) {
            guard let pendingDecision = pendingReceiptConsumptionDecisionByToken.removeValue(
                forKey: token
            ) else { return }
            WorktreeStartupInstrumentation.recordReceiptConsumptionDecision(
                correlationID: pendingDecision.correlationID,
                decision: pendingDecision.decision
            )
        }
    #endif

    private func scheduleOrphanedSessionWorktreeResourceCleanup(
        _ resources: SessionWorktreeOwnershipRemoval
    ) {
        guard !resources.ownedRoots.isEmpty || !resources.reservedLoadFlights.isEmpty
            || !resources.pendingSeededRootIDs.isEmpty
        else { return }
        Task { await cleanupOrphanedSessionWorktreeResources(resources) }
    }

    private func cleanupOrphanedSessionWorktreeResources(
        _ resources: SessionWorktreeOwnershipRemoval
    ) async {
        await abortPendingSeededRoots(resources.pendingSeededRootIDs)
        await cleanupOrphanedSessionWorktreeRoots(resources.ownedRoots)
        scheduleOrphanedSessionWorktreeLoadFlightCleanup(resources.reservedLoadFlights)
    }

    private func cleanupOrphanedSessionWorktreeRoots(
        _ roots: [WorkspaceSessionWorktreeOwnedRoot]
    ) async {
        var seen = Set<SessionWorktreeRootLifetimeKey>()
        for root in roots {
            let key = SessionWorktreeRootLifetimeKey(rootID: root.rootID, lifetimeID: root.lifetimeID)
            guard seen.insert(key).inserted,
                  isRootLifetimeCurrent(rootID: root.rootID, expectedLifetimeID: root.lifetimeID),
                  rootStatesByID[root.rootID]?.root.standardizedFullPath == root.standardizedPhysicalPath,
                  !hasAggregateWatcherDemand(rootID: root.rootID, lifetimeID: root.lifetimeID)
            else { continue }
            try? await reconcileAggregateWatcherDemand(rootID: root.rootID)
            guard isRootLifetimeCurrent(rootID: root.rootID, expectedLifetimeID: root.lifetimeID),
                  !hasAggregateWatcherDemand(rootID: root.rootID, lifetimeID: root.lifetimeID),
                  rootStatesByID[root.rootID]?.root.kind == .sessionWorktree,
                  rootStatesByID[root.rootID]?.root.standardizedFullPath == root.standardizedPhysicalPath
            else { continue }
            await unloadRoot(id: root.rootID)
        }
    }

    private func scheduleOrphanedSessionWorktreeLoadFlightCleanup(
        _ reservations: [SessionWorktreeReservedLoadFlight]
    ) {
        var scheduledFlightIDs = Set<UUID>()
        for reservation in reservations where scheduledFlightIDs.insert(reservation.flight.id).inserted {
            #if DEBUG
                let cleanupID = UUID()
                let tracked = sessionWorktreeOrphanLoadCleanupsByID.count
                    < Self.maximumSessionWorktreeOrphanLoadCleanupRecords
                if !tracked {
                    sessionWorktreeOrphanLoadCleanupOverflowCount &+= 1
                }
                let task = Task { [weak self] in
                    guard let self else { return }
                    await self.completeOrphanedSessionWorktreeLoadFlightCleanup(
                        reservation,
                        cleanupID: tracked ? cleanupID : nil
                    )
                }
                if tracked {
                    sessionWorktreeOrphanLoadCleanupsByID[cleanupID] = SessionWorktreeOrphanLoadCleanup(
                        ownerID: reservation.ownerID,
                        standardizedPath: reservation.standardizedPath,
                        task: task
                    )
                }
            #else
                Task { [weak self] in
                    guard let self else { return }
                    await self.completeOrphanedSessionWorktreeLoadFlightCleanup(
                        reservation,
                        cleanupID: nil
                    )
                }
            #endif
        }
    }

    private func completeOrphanedSessionWorktreeLoadFlightCleanup(
        _ reservation: SessionWorktreeReservedLoadFlight,
        cleanupID: UUID?
    ) async {
        if let root = try? await reservation.flight.task.value,
           let identity = reservation.flight.completion.identity(),
           root.id == identity.rootID
        {
            await cleanupOrphanedSessionWorktreeRoots([
                WorkspaceSessionWorktreeOwnedRoot(
                    rootID: identity.rootID,
                    lifetimeID: identity.lifetimeID,
                    standardizedPhysicalPath: reservation.standardizedPath
                )
            ])
        }
        #if DEBUG
            if let cleanupID {
                sessionWorktreeOrphanLoadCleanupsByID.removeValue(forKey: cleanupID)
            } else if sessionWorktreeOrphanLoadCleanupOverflowCount > 0 {
                sessionWorktreeOrphanLoadCleanupOverflowCount -= 1
            }
        #endif
    }

    private func sessionWorktreeOwnerCount(rootID: UUID, lifetimeID: UUID) -> Int {
        sessionWorktreeOwnershipTokensByRootLifetime[
            SessionWorktreeRootLifetimeKey(rootID: rootID, lifetimeID: lifetimeID)
        ]?.count ?? 0
    }

    private func hasAggregateWatcherDemand(rootID: UUID, lifetimeID: UUID) -> Bool {
        let hasPathReservation: Bool = if let state = rootStatesByID[rootID], state.lifetimeID == lifetimeID {
            sessionWorktreeReservationTokensByStandardizedPath[
                state.root.standardizedFullPath
            ]?.isEmpty == false
        } else {
            false
        }
        return explicitWatcherDemandRootIDs.contains(rootID)
            || sessionWorktreeOwnerCount(rootID: rootID, lifetimeID: lifetimeID) > 0
            || hasPathReservation
    }

    private func reconcileAggregateWatcherDemand(rootID: UUID) async throws {
        guard let state = rootStatesByID[rootID] else {
            await waitForCurrentPublisherIngress(rootIDs: [rootID])
            return
        }
        if hasAggregateWatcherDemand(rootID: rootID, lifetimeID: state.lifetimeID) {
            try await ensureWatcherInfrastructure(state: state, rootID: rootID)
            return
        }
        let key = WatcherInfrastructureKey(rootID: rootID, lifetimeID: state.lifetimeID)
        watcherPublisherAttachmentsByKey.removeValue(forKey: key)?.cancellable.cancel()
        publisherIngressCoordinator.closePublisherIngress(rootID: rootID)
        try await reconcileWatcherServiceState(state.service, rootID: rootID)
        await waitForCurrentPublisherIngress(rootIDs: [rootID])
    }

    private func reconcileWatcherServiceState(_ service: FileSystemService, rootID: UUID) async throws {
        while true {
            let shouldWatch = publisherIngressCoordinator.hasOpenPublisherIngress(rootID: rootID)
            #if DEBUG
                if let watcherServiceStateWillReconcileHandler {
                    await watcherServiceStateWillReconcileHandler(rootID, shouldWatch)
                }
            #endif
            if shouldWatch {
                try await service.startWatchingForChanges()
            } else {
                await service.stopWatchingForChanges()
            }
            guard shouldWatch != publisherIngressCoordinator.hasOpenPublisherIngress(rootID: rootID) else { return }
        }
    }

    private func waitForCurrentPublisherIngress(rootIDs: Set<UUID>) async {
        #if DEBUG
            if publisherIngressCoordinator.pendingPublisherIngressCount(rootIDs: rootIDs) > 0,
               let publisherIngressWillWaitHandler
            {
                await publisherIngressWillWaitHandler(rootIDs)
            }
        #endif
        await publisherIngressCoordinator.waitForCurrentPublisherIngress(rootIDs: rootIDs)
    }

    private func yieldFileSystemDeltaEvent(_ event: WorkspaceFileSystemDeltaEvent) {
        for continuation in fileSystemDeltaContinuations.values {
            continuation.yield(event)
        }
    }

    private func yieldAppliedIndexEvent(_ event: WorkspaceAppliedIndexBatchEvent) {
        // Canonical batches are the only delta authority for search shards. Raw FSEvents first
        // mutate the store indexes and can never patch a published shard directly.
        applyAppliedIndexEventToRootCatalogShard(event)
        #if DEBUG
            Self.activePublicationInvalidationRecorder?.appliedIndexEventYieldCount += 1
        #endif
        for continuation in appliedIndexContinuations.values {
            continuation.yield(event)
        }
    }

    private func nextAppliedIndexGeneration(forRootID rootID: UUID) -> UInt64 {
        let next = (appliedIndexGenerationsByRootID[rootID] ?? 0) &+ 1
        appliedIndexGenerationsByRootID[rootID] = next
        return next
    }

    func replayObservedFileSystemDeltas(rootID: UUID, deltas: [FileSystemDelta]) async {
        guard let root = rootStatesByID[rootID]?.root else { return }
        await handleObservedFileSystemDeltas(deltas, root: root)
    }

    #if DEBUG
        func replayFileSystemPublicationForInvalidationDiagnosticsForTesting(
            rootID: UUID,
            deltas: [FileSystemDelta]
        ) async throws -> PublicationInvalidationDebugSample {
            let root = try state(for: rootID).root
            let preparedDeltas = prepareObservedFileSystemDeltas(deltas, root: root)
            let recorder = await applyPreparedIndexDeltasRecordingInvalidations(
                rootID: rootID,
                deltas: preparedDeltas
            )
            return makePublicationInvalidationDebugSample(
                servicePublicationSequence: 0,
                watcherAcceptedWatermark: nil,
                recorder: recorder
            )
        }

        func publishSyntheticFileSystemDeltasForTesting(rootID: UUID, deltas: [FileSystemDelta]) async throws {
            let state = try state(for: rootID)
            await state.service.publishFileSystemDeltas(deltas, source: .syntheticMutation)
        }

        func publisherIngressCountForTesting(rootID: UUID) -> Int {
            publisherIngressCoordinator.pendingPublisherIngressCount(rootIDs: [rootID])
        }

        func rootWatcherIsActiveForTesting(rootID: UUID) async throws -> Bool {
            let state = try state(for: rootID)
            return await state.service.isWatchingForChangesForTesting()
        }

        func acceptWatcherPayloadForTesting(
            rootID: UUID,
            events: [(absolutePath: String, flags: FSEventStreamEventFlags, eventId: FSEventStreamEventId)],
            scheduleDrain: Bool = true
        ) async throws -> FileSystemWatcherIngressMailbox.Watermark? {
            let state = try state(for: rootID)
            return await state.service.acceptWatcherPayloadForTesting(events, scheduleDrain: scheduleDrain)
        }

        func appliedIngressSnapshotForTesting(rootID: UUID) -> WorkspaceFileSystemIngressCoordinator.AppliedSnapshot {
            publisherIngressCoordinator.appliedSnapshot(rootID: rootID)
        }

        func acceptedWatcherWatermarkForTesting(rootID: UUID) throws -> FileSystemWatcherIngressMailbox.Watermark {
            try state(for: rootID).service.captureAcceptedWatcherWatermark()
        }

        func publisherIngressDebugSnapshotForTesting(
            rootID: UUID
        ) -> WorkspaceFileSystemIngressCoordinator.DebugSnapshot {
            publisherIngressCoordinator.debugSnapshot(rootID: rootID)
        }

        func waitUntilPublisherIngressAppliedForTesting(
            rootID: UUID,
            servicePublicationSequence: UInt64
        ) async {
            await publisherIngressCoordinator.waitUntilApplied(
                rootID: rootID,
                servicePublicationSequence: servicePublicationSequence
            )
        }

        func rootLifetimeIDForTesting(rootID: UUID) throws -> UUID {
            try state(for: rootID).lifetimeID
        }

        func applyAppliedIndexEventToRootCatalogShardForTesting(
            _ event: WorkspaceAppliedIndexBatchEvent
        ) {
            applyAppliedIndexEventToRootCatalogShard(event)
        }

        func recordRootCatalogShardFallbackForTesting(
            rootID: UUID,
            lifetimeID: UUID,
            reason: RootCatalogShardFallbackReason
        ) {
            recordRootCatalogShardFallback(
                rootID: rootID,
                lifetimeID: lifetimeID,
                reason: reason
            )
        }

        func advanceRootCatalogTopologyGenerationForTesting(rootID: UUID) {
            catalogGenerationsByRootID[rootID, default: 0] &+= 1
        }

        func replayPublisherFileSystemPublicationForTesting(
            rootID: UUID,
            expectedLifetimeID: UUID,
            deltas: [FileSystemDelta],
            requiresFullResync: Bool = false
        ) async {
            guard let root = rootStatesByID[rootID]?.root else { return }
            await handleObservedFileSystemDeltas(
                deltas,
                root: root,
                expectedLifetimeID: expectedLifetimeID,
                requiresFullResync: requiresFullResync
            )
        }
    #endif

    private func handleObservedPublisherFileSystemPublication(
        _ publication: FileSystemDeltaPublication,
        root: WorkspaceRootRecord,
        expectedLifetimeID: UUID,
        publicationCorrelation: EditFlowPerf.LifecycleCorrelation?,
        diagnosticRootToken: UUID
    ) async {
        #if DEBUG
            if let watcherSinkWillApplyHandler {
                await watcherSinkWillApplyHandler(root.id)
            }
        #endif
        guard isRootLifetimeCurrent(rootID: root.id, expectedLifetimeID: expectedLifetimeID) else { return }
        #if DEBUG
            MCPApplyEditsRebaseProbeRecorder.recordPublisherIngress(
                rootID: root.id,
                source: publication.source,
                deltas: publication.deltas
            )
        #endif
        if publication.source == .overflowRootRescan || publication.source == .recoveryFullResync {
            await invalidateRetainedSearchContentForRecoveryUncertainty(rootID: root.id)
            guard isRootLifetimeCurrent(rootID: root.id, expectedLifetimeID: expectedLifetimeID) else { return }
        }
        await handleObservedFileSystemDeltas(
            publication.deltas,
            root: root,
            expectedLifetimeID: expectedLifetimeID,
            publicationCorrelation: publicationCorrelation,
            diagnosticRootToken: diagnosticRootToken,
            watcherAcceptedWatermark: publication.watcherAcceptedWatermark,
            servicePublicationSequence: publication.servicePublicationSequence,
            requiresFullResync: publication.requiresFullResync
        )
    }

    private func handleObservedFileSystemDeltas(
        _ deltas: [FileSystemDelta],
        root: WorkspaceRootRecord,
        expectedLifetimeID: UUID? = nil,
        publicationCorrelation: EditFlowPerf.LifecycleCorrelation? = nil,
        diagnosticRootToken: UUID? = nil,
        watcherAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark? = nil,
        servicePublicationSequence: UInt64? = nil,
        requiresFullResync: Bool = false
    ) async {
        guard isRootLifetimeCurrent(rootID: root.id, expectedLifetimeID: expectedLifetimeID) else { return }
        for delta in deltas {
            guard await isDiscoveryFacingFileSystemDelta(delta, rootID: root.id) else { continue }
            guard isRootLifetimeCurrent(rootID: root.id, expectedLifetimeID: expectedLifetimeID) else { return }
            yieldFileSystemDeltaEvent(WorkspaceFileSystemDeltaEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                delta: delta
            ))
        }
        let preparedDeltas = prepareObservedFileSystemDeltas(deltas, root: root)
        #if DEBUG
            await applyPreparedIndexDeltas(
                rootID: root.id,
                deltas: preparedDeltas,
                expectedLifetimeID: expectedLifetimeID,
                watcherAcceptedWatermark: watcherAcceptedWatermark,
                servicePublicationSequence: servicePublicationSequence,
                requiresFullResync: requiresFullResync
            )
        #else
            await applyPreparedIndexDeltas(
                rootID: root.id,
                deltas: preparedDeltas,
                expectedLifetimeID: expectedLifetimeID,
                requiresFullResync: requiresFullResync
            )
        #endif
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.WorkspaceIngress.storeCanonicalApplyCompleted,
            correlation: publicationCorrelation,
            EditFlowPerf.Dimensions(
                appliedCount: preparedDeltas.count,
                rootToken: diagnosticRootToken?.uuidString,
                ingressSequence: watcherAcceptedWatermark?.rawValue,
                barrierSequence: servicePublicationSequence
            )
        )
    }

    private func prepareObservedFileSystemDeltas(
        _ deltas: [FileSystemDelta],
        root: WorkspaceRootRecord
    ) -> [PreparedFileSystemDelta] {
        FileSystemDeltaPreparation.coalesce(deltas, inRoot: root.standardizedFullPath)
            .compactMap { FileSystemDeltaPreparation.prepare($0, inRoot: root.standardizedFullPath) }
    }

    private func isDiscoveryFacingFileSystemDelta(_ delta: FileSystemDelta, rootID: UUID) async -> Bool {
        guard let state = rootStatesByID[rootID] else { return false }
        switch delta {
        case let .fileAdded(relativePath):
            return await state.service.catalogEligibleRegularFileExists(relativePath: relativePath)
        case let .folderAdded(relativePath):
            return await state.service.catalogFolderIsDiscoverable(relativePath: relativePath)
        case let .fileRemoved(relativePath), let .fileModified(relativePath, _):
            guard let file = file(rootID: rootID, relativePath: relativePath) else { return false }
            return isDiscoverableFileID(file.id)
        case let .folderRemoved(relativePath), let .folderModified(relativePath, _):
            guard let folder = folder(rootID: rootID, relativePath: relativePath) else { return false }
            return isDiscoverableFolderID(folder.id)
        }
    }

    func files(inRoot rootID: UUID) -> [WorkspaceFileRecord] {
        guard let state = rootStatesByID[rootID] else { return [] }
        return state.fileIDsByRelativePath.values
            .filter(isDiscoverableFileID)
            .compactMap { filesByID[$0] }
            .sorted { $0.standardizedRelativePath < $1.standardizedRelativePath }
    }

    private struct LoadedRootReusableSnapshotCurrentness {
        let rootID: UUID
        let lifetimeID: UUID
        let standardizedPath: String
        let catalogGeneration: UInt64
        let appliedIndexGeneration: UInt64
        let acceptedWatcherWatermark: UInt64
        let acceptedServicePublicationSequence: UInt64
    }

    private func loadedRootReusableSnapshotCurrentness(
        _ currentness: LoadedRootReusableSnapshotCurrentness
    ) -> WorkspaceRootReusableSnapshotCoordinator.CurrentnessValidation {
        guard let state = rootStatesByID[currentness.rootID],
              state.lifetimeID == currentness.lifetimeID,
              state.root.standardizedFullPath == currentness.standardizedPath
        else {
            return .stale(.loadedRootOwnerStale)
        }
        guard catalogGenerationsByRootID[currentness.rootID] == currentness.catalogGeneration,
              appliedIndexGenerationsByRootID[currentness.rootID] == currentness.appliedIndexGeneration
        else {
            return .stale(.loadedRootCatalogStale)
        }
        guard state.service.captureAcceptedWatcherWatermark().rawValue == currentness.acceptedWatcherWatermark else {
            return .stale(.loadedRootWatcherStale)
        }
        let ingress = publisherIngressCoordinator.appliedSnapshot(rootID: currentness.rootID)
        guard ingress.acceptedServicePublicationSequence == currentness.acceptedServicePublicationSequence,
              ingress.appliedServicePublicationSequence >= currentness.acceptedServicePublicationSequence,
              ingress.appliedWatcherWatermark.rawValue >= currentness.acceptedWatcherWatermark
        else {
            return .stale(.loadedRootWatcherStale)
        }
        return .current
    }

    private func loadedRootCatalogBatchEvidence(
        currentness: LoadedRootReusableSnapshotCurrentness,
        relativePaths: [String],
        service: FileSystemService,
        expectedPolicyIdentity: WorkspaceRootCatalogPolicyIdentity
    ) async -> WorkspaceRootReusableSnapshotCoordinator.CatalogBatchEvidenceResult {
        switch loadedRootReusableSnapshotCurrentness(currentness) {
        case .current:
            break
        case let .stale(cause):
            return .stale(cause)
        }
        guard let state = rootStatesByID[currentness.rootID], state.service === service,
              let exactPaths = WorkspaceRootByteExactPathSet(relativePaths, rejectExactDuplicates: true)
        else { return .stale(.loadedRootOwnerStale) }
        var discoverableByPath: [WorkspaceRootByteExactPathKey: Bool] = [:]
        discoverableByPath.reserveCapacity(exactPaths.count)
        for path in exactPaths.sortedKeys {
            discoverableByPath[path] = state.fileIDsByRelativePath[path.value]
                .map(isDiscoverableFileID) ?? false
        }
        guard let evidence = await service.catalogProjectionEvidence(
            forCommittedRegularPaths: exactPaths
        ) else { return .stale(.loadedRootCatalogStale) }
        switch loadedRootReusableSnapshotCurrentness(currentness) {
        case .current:
            break
        case let .stale(cause):
            return .stale(cause)
        }
        guard evidence.policyIdentity == expectedPolicyIdentity,
              Set(evidence.dispositionsByRelativePath.keys) == exactPaths.keys
        else { return .stale(.loadedRootCatalogStale) }
        for (path, disposition) in evidence.dispositionsByRelativePath {
            let discoverable = discoverableByPath[path] == true
            switch (discoverable, disposition) {
            case (true, .searchableRegularFile), (false, .policyIgnoredRegularFile):
                break
            case (true, _), (false, _):
                return .catalogMismatch
            }
        }
        return .evidence(evidence)
    }

    func admitReusableSnapshotForLoadedRoot(
        rootID: UUID,
        expectedStandardizedPath: String,
        prefixControlEvidenceCacheMode: GitPrefixControlEvidenceCacheMode = .bypassReadAndAdmission
    ) async throws -> WorkspaceRootReusableSnapshotCoordinator.ObservationResult {
        guard !Task.isCancelled else {
            return .failed(.init(stage: .loadedRootValidation, cause: .cancelled))
        }
        guard let initialState = rootStatesByID[rootID],
              initialState.root.standardizedFullPath == expectedStandardizedPath
        else {
            return .failed(.init(stage: .loadedRootValidation, cause: .loadedRootOwnerStale))
        }
        let initialLifetimeID = initialState.lifetimeID
        let rootRef = WorkspaceRootRef(
            id: initialState.root.id,
            name: initialState.root.name,
            fullPath: initialState.root.standardizedFullPath
        )
        let ingressSamples = await {
            #if DEBUG
                let span = WorktreeStartupPreparationInstrumentation.currentRecorder?
                    .begin(.loadedRootIngressFence)
                defer { span?.end() }
            #endif
            return await awaitAppliedIngress(rootRefs: [rootRef])
        }()
        guard !Task.isCancelled else {
            return .failed(.init(stage: .initialCurrentness, cause: .cancelled))
        }
        guard ingressSamples.count == 1,
              let ingressSample = ingressSamples.first,
              ingressSample.rootID == rootID,
              ingressSample.rootPath == expectedStandardizedPath
        else {
            return .failed(.init(stage: .initialCurrentness, cause: .loadedRootWatcherStale))
        }
        guard let state = rootStatesByID[rootID],
              state.lifetimeID == initialLifetimeID,
              state.root.standardizedFullPath == expectedStandardizedPath
        else {
            return .failed(.init(stage: .initialCurrentness, cause: .loadedRootOwnerStale))
        }
        guard let catalogGeneration = catalogGenerationsByRootID[rootID],
              let appliedIndexGeneration = appliedIndexGenerationsByRootID[rootID]
        else {
            return .failed(.init(stage: .initialCurrentness, cause: .loadedRootCatalogStale))
        }

        let acceptedWatcherWatermark = state.service.captureAcceptedWatcherWatermark().rawValue
        let ingress = publisherIngressCoordinator.appliedSnapshot(rootID: rootID)
        guard ingressSample.appliedWatcherWatermark >= acceptedWatcherWatermark,
              ingressSample.appliedServicePublicationSequence >= ingress.acceptedServicePublicationSequence,
              ingress.appliedWatcherWatermark.rawValue >= acceptedWatcherWatermark,
              ingress.appliedServicePublicationSequence >= ingress.acceptedServicePublicationSequence
        else {
            return .failed(.init(stage: .initialCurrentness, cause: .loadedRootWatcherStale))
        }

        let currentness = LoadedRootReusableSnapshotCurrentness(
            rootID: rootID,
            lifetimeID: initialLifetimeID,
            standardizedPath: expectedStandardizedPath,
            catalogGeneration: catalogGeneration,
            appliedIndexGeneration: appliedIndexGeneration,
            acceptedWatcherWatermark: acceptedWatcherWatermark,
            acceptedServicePublicationSequence: ingress.acceptedServicePublicationSequence
        )
        switch loadedRootReusableSnapshotCurrentness(currentness) {
        case .current:
            break
        case let .stale(cause):
            return .failed(.init(stage: .initialCurrentness, cause: cause))
        }
        let rootURL = URL(fileURLWithPath: expectedStandardizedPath).standardizedFileURL
        let service = state.service
        let catalogPolicyIdentity = await {
            #if DEBUG
                let span = WorktreeStartupPreparationInstrumentation.currentRecorder?
                    .begin(.loadedRootPolicySnapshot)
                defer { span?.end() }
            #endif
            return await service.currentWorkspaceRootCatalogPolicyIdentity()
        }()

        let result = await rootReusableSnapshotCoordinator.observeStreamedAuthoritativeFullLoad(
            rootURL: rootURL,
            catalogPolicyIdentity: catalogPolicyIdentity,
            prefixControlEvidenceCacheMode: prefixControlEvidenceCacheMode,
            catalogBatchEvidenceProvider: { [weak self] relativePaths in
                guard let self else { return .stale(.loadedRootOwnerStale) }
                return await loadedRootCatalogBatchEvidence(
                    currentness: currentness,
                    relativePaths: relativePaths,
                    service: service,
                    expectedPolicyIdentity: catalogPolicyIdentity
                )
            },
            currentnessValidator: { [weak self] in
                guard let self else { return .stale(.loadedRootOwnerStale) }
                return await loadedRootReusableSnapshotCurrentness(currentness)
            }
        )
        guard case let .admitted(snapshotIdentity) = result else {
            return result
        }
        #if DEBUG
            let finalCurrentnessSpan = WorktreeStartupPreparationInstrumentation.currentRecorder?
                .begin(.finalLoadedRootCurrentness)
            defer { finalCurrentnessSpan?.end() }
        #endif
        if Task.isCancelled {
            await workspaceStateAuthority.revokeReusableSnapshotAdmissions(
                snapshotIdentity: snapshotIdentity
            )
            return .failed(.init(stage: .finalLoadedRootCurrentness, cause: .cancelled))
        }
        switch loadedRootReusableSnapshotCurrentness(currentness) {
        case .current:
            return result
        case let .stale(cause):
            await workspaceStateAuthority.revokeReusableSnapshotAdmissions(
                snapshotIdentity: snapshotIdentity
            )
            return .failed(.init(stage: .finalLoadedRootCurrentness, cause: cause))
        }
    }

    func folders(inRoot rootID: UUID) -> [WorkspaceFolderRecord] {
        guard let state = rootStatesByID[rootID] else { return [] }
        return state.folderIDsByRelativePath.values
            .filter(isDiscoverableFolderID)
            .compactMap { foldersByID[$0] }
            .sorted { $0.standardizedRelativePath < $1.standardizedRelativePath }
    }

    func appliedIndexRootSnapshot(rootID: UUID) -> WorkspaceAppliedIndexRootSnapshot? {
        guard publishedSeededAuthorityIsQueryable(rootID: rootID),
              let root = rootStatesByID[rootID]?.root
        else { return nil }
        return WorkspaceAppliedIndexRootSnapshot(
            root: root,
            generation: appliedIndexGenerationsByRootID[rootID] ?? 0,
            files: files(inRoot: rootID),
            folders: folders(inRoot: rootID)
        )
    }

    struct ReadFileAutoSelectionCatalogValidationSnapshot: Equatable {
        let visibleCatalogGeneration: UInt64
        let rootScopeCatalogGeneration: UInt64
        let rootScopeAvailability: WorkspaceLookupRootScopeAvailability
    }

    func readFileAutoSelectionCatalogValidationSnapshot(
        rootScope: WorkspaceLookupRootScope
    ) -> ReadFileAutoSelectionCatalogValidationSnapshot {
        ReadFileAutoSelectionCatalogValidationSnapshot(
            visibleCatalogGeneration: scopedSnapshotGeneration(scope: .visibleWorkspace),
            rootScopeCatalogGeneration: scopedSnapshotGeneration(scope: rootScope),
            rootScopeAvailability: rootScopeAvailability(rootScope)
        )
    }

    func catalogGeneration(rootScope: WorkspaceLookupRootScope = .visibleWorkspace) -> UInt64 {
        scopedSnapshotGeneration(scope: rootScope)
    }

    func catalogDiagnostics(rootScope: WorkspaceLookupRootScope = .visibleWorkspace) -> WorkspaceCatalogDiagnostics {
        let roots = rootsForPathLookup(scope: rootScope)
        let allowedRootIDs = Set(roots.map(\.id))
        let folderCount = foldersByID.values.reduce(into: 0) { count, folder in
            if allowedRootIDs.contains(folder.rootID), isDiscoverableFolderID(folder.id) { count += 1 }
        }
        let fileCount = filesByID.values.reduce(into: 0) { count, file in
            if allowedRootIDs.contains(file.rootID), isDiscoverableFileID(file.id) { count += 1 }
        }
        return WorkspaceCatalogDiagnostics(
            generation: scopedSnapshotGeneration(scope: rootScope),
            rootScope: rootScope,
            rootCount: roots.count,
            folderCount: folderCount,
            fileCount: fileCount
        )
    }

    func withStoreBackedSearchAccess<T>(
        searchMode: SearchMode,
        admissionClass: BroadSearchAdmissionClass?,
        operation: @Sendable (FileSearchActor) async throws -> T
    ) async throws -> T {
        try await storeBackedSearchLane.withSearchAccess(
            searchMode: searchMode,
            admissionClass: admissionClass,
            operation: operation
        )
    }

    func sessionBoundRootScopeValidationSnapshot(
        _ rootScope: WorkspaceLookupRootScope,
        expectedPhysicalRoots: [WorkspaceRootRef]
    ) -> WorkspaceSessionRootLifetimeSnapshot? {
        guard !expectedPhysicalRoots.isEmpty else { return nil }
        let expectedPaths = Set(expectedPhysicalRoots.map(\.standardizedFullPath))
        let requestedMatches: Bool = switch rootScope {
        case let .sessionBoundWorkspace(_, requestedPhysicalRootPaths):
            Set(requestedPhysicalRootPaths.map {
                StandardizedPath.absolute(($0 as NSString).expandingTildeInPath)
            }) == expectedPaths
        case let .validatedSessionBoundWorkspace(_, requestedPhysicalRoots):
            requestedPhysicalRoots == Set(expectedPhysicalRoots)
        case .visibleWorkspace, .visibleWorkspacePlusGitData, .allLoaded, .allLoadedExcludingGitData:
            false
        }
        guard requestedMatches,
              expectedPhysicalRoots.allSatisfy({ expectedRoot in
                  guard let currentRoot = rootStatesByID[expectedRoot.id]?.root else { return false }
                  return currentRoot.kind == .sessionWorktree
                      && currentRoot.standardizedFullPath == expectedRoot.standardizedFullPath
              })
        else { return nil }
        guard rootScopeAvailability(rootScope) == .available else { return nil }

        return sessionRootLifetimeClock.snapshot(physicalRootPaths: expectedPaths.sorted())
    }

    func rootScopeAvailability(_ rootScope: WorkspaceLookupRootScope) -> WorkspaceLookupRootScopeAvailability {
        let missing: [String]
        switch rootScope {
        case .visibleWorkspace, .visibleWorkspacePlusGitData, .allLoaded, .allLoadedExcludingGitData:
            return .available
        case let .sessionBoundWorkspace(requestedCanonicalRootPaths, requestedPhysicalRootPaths):
            guard !requestedCanonicalRootPaths.isEmpty || !requestedPhysicalRootPaths.isEmpty else {
                return .sessionWorktreeUnavailable(missingPhysicalRootPaths: [])
            }
            let requested = Set(requestedPhysicalRootPaths.map {
                StandardizedPath.absolute(($0 as NSString).expandingTildeInPath)
            })
            missing = requested.filter { path in
                guard let rootID = rootIDsByStandardizedPath[path],
                      rootStatesByID[rootID]?.root.kind == .sessionWorktree,
                      publishedSeededAuthorityIsQueryable(rootID: rootID)
                else { return true }
                var isDirectory: ObjCBool = false
                return !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) ||
                    !isDirectory.boolValue
            }.sorted()
        case let .validatedSessionBoundWorkspace(canonicalRoots, physicalRoots):
            guard !canonicalRoots.isEmpty || !physicalRoots.isEmpty else {
                return .sessionWorktreeUnavailable(missingPhysicalRootPaths: [])
            }
            missing = (
                canonicalRoots.map { ($0, WorkspaceRootKind.primaryWorkspace) }
                    + physicalRoots.map { ($0, WorkspaceRootKind.sessionWorktree) }
            )
            .compactMap { expectedRoot, expectedKind in
                guard let currentRoot = rootStatesByID[expectedRoot.id]?.root,
                      currentRoot.kind == expectedKind,
                      currentRoot.standardizedFullPath == expectedRoot.standardizedFullPath,
                      publishedSeededAuthorityIsQueryable(rootID: expectedRoot.id)
                else { return expectedRoot.standardizedFullPath }
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(
                    atPath: currentRoot.standardizedFullPath,
                    isDirectory: &isDirectory
                ) && isDirectory.boolValue ? nil : currentRoot.standardizedFullPath
            }.sorted()
        }
        return missing.isEmpty
            ? .available
            : .sessionWorktreeUnavailable(missingPhysicalRootPaths: missing)
    }

    #if DEBUG
        private struct CatalogSortProjection {
            let file: WorkspaceFileRecord
            let standardizedSortPath: String
        }

        func debugAuthoritativeCatalogSortProbe(
            rootScope: WorkspaceLookupRootScope,
            warmupCount: Int = 1,
            measuredCount: Int = 3
        ) -> WorkspaceCatalogSortAttributionProbe {
            guard rootScopeAvailability(rootScope) == .available else {
                return WorkspaceCatalogSortAttributionProbe(
                    status: .unavailable,
                    sourceFileCount: 0,
                    sourceFolderCount: 0,
                    samples: [],
                    directAndProjectedOrdersMatch: true,
                    firstMismatchIndex: nil,
                    orderedFileIDs: []
                )
            }

            let roots = rootsForPathLookup(scope: rootScope)
            let usesRootLocalFileOrder = roots.count == 1
            let allowedRootIDs = Set(roots.map(\.id))
            let sourceFiles = filesByID.values.filter {
                allowedRootIDs.contains($0.rootID) && isDiscoverableFileID($0.id)
            }
            let sourceFolders = foldersByID.values.filter {
                allowedRootIDs.contains($0.rootID) && isDiscoverableFolderID($0.id)
            }
            guard !sourceFiles.isEmpty || !sourceFolders.isEmpty else {
                return WorkspaceCatalogSortAttributionProbe(
                    status: .empty,
                    sourceFileCount: 0,
                    sourceFolderCount: 0,
                    samples: [],
                    directAndProjectedOrdersMatch: true,
                    firstMismatchIndex: nil,
                    orderedFileIDs: []
                )
            }

            func directFilePrecedes(_ lhs: WorkspaceFileRecord, _ rhs: WorkspaceFileRecord) -> Bool {
                usesRootLocalFileOrder
                    ? Self.searchRootCatalogFilePrecedes(lhs, rhs)
                    : Self.searchCatalogFilePrecedes(lhs, rhs)
            }

            func projectionPrecedes(_ lhs: CatalogSortProjection, _ rhs: CatalogSortProjection) -> Bool {
                switch Self.compareUTF8Binary(lhs.standardizedSortPath, rhs.standardizedSortPath) {
                case .orderedAscending:
                    true
                case .orderedDescending:
                    false
                case .orderedSame:
                    Self.compareUTF8Binary(
                        lhs.file.id.uuidString,
                        rhs.file.id.uuidString
                    ) == .orderedAscending
                }
            }

            func timedDirectFileSort() -> (nanoseconds: UInt64, files: [WorkspaceFileRecord]) {
                let start = WorkspaceFileSearchDebugTiming.now()
                let files = sourceFiles.sorted(by: directFilePrecedes)
                let end = WorkspaceFileSearchDebugTiming.now()
                return (
                    WorkspaceFileSearchDebugTiming.elapsed(since: start, through: end),
                    files
                )
            }

            func timedProjectedPipeline() -> (
                keyNanoseconds: UInt64,
                assemblyNanoseconds: UInt64,
                sortNanoseconds: UInt64,
                mappingNanoseconds: UInt64,
                projections: [CatalogSortProjection],
                files: [WorkspaceFileRecord]
            ) {
                let keyStart = WorkspaceFileSearchDebugTiming.now()
                let standardizedSortPaths = sourceFiles.map {
                    usesRootLocalFileOrder
                        ? $0.standardizedRelativePath
                        : $0.standardizedFullPath
                }
                let keyEnd = WorkspaceFileSearchDebugTiming.now()

                let assemblyStart = WorkspaceFileSearchDebugTiming.now()
                let projections = zip(sourceFiles, standardizedSortPaths).map {
                    CatalogSortProjection(file: $0.0, standardizedSortPath: $0.1)
                }
                let assemblyEnd = WorkspaceFileSearchDebugTiming.now()

                let sortStart = WorkspaceFileSearchDebugTiming.now()
                let orderedProjections = projections.sorted(by: projectionPrecedes)
                let sortEnd = WorkspaceFileSearchDebugTiming.now()

                let mappingStart = WorkspaceFileSearchDebugTiming.now()
                let orderedFiles = orderedProjections.map(\.file)
                let mappingEnd = WorkspaceFileSearchDebugTiming.now()

                return (
                    WorkspaceFileSearchDebugTiming.elapsed(since: keyStart, through: keyEnd),
                    WorkspaceFileSearchDebugTiming.elapsed(since: assemblyStart, through: assemblyEnd),
                    WorkspaceFileSearchDebugTiming.elapsed(since: sortStart, through: sortEnd),
                    WorkspaceFileSearchDebugTiming.elapsed(since: mappingStart, through: mappingEnd),
                    projections,
                    orderedFiles
                )
            }

            let excludedWarmupCount = max(0, warmupCount)
            let retainedMeasuredCount = max(0, measuredCount)
            var samples: [WorkspaceCatalogSortAttributionSample] = []
            samples.reserveCapacity(retainedMeasuredCount)
            var allOrdersMatch = true
            var firstMismatchIndex: Int?
            var orderedFileIDs: [UUID] = []

            for repetitionIndex in 0 ..< (excludedWarmupCount + retainedMeasuredCount) {
                let direct: (nanoseconds: UInt64, files: [WorkspaceFileRecord])
                let projected: (
                    keyNanoseconds: UInt64,
                    assemblyNanoseconds: UInt64,
                    sortNanoseconds: UInt64,
                    mappingNanoseconds: UInt64,
                    projections: [CatalogSortProjection],
                    files: [WorkspaceFileRecord]
                )
                if repetitionIndex.isMultiple(of: 2) {
                    direct = timedDirectFileSort()
                    projected = timedProjectedPipeline()
                } else {
                    projected = timedProjectedPipeline()
                    direct = timedDirectFileSort()
                }

                let folderStart = WorkspaceFileSearchDebugTiming.now()
                _ = sourceFolders.sorted(by: Self.searchCatalogFolderPrecedes)
                let folderEnd = WorkspaceFileSearchDebugTiming.now()
                let directIDs = direct.files.map(\.id)
                let projectedIDs = projected.files.map(\.id)
                let sharedIndexRange = 0 ..< min(directIDs.count, projectedIDs.count)
                let mismatchIndex = sharedIndexRange.first { directIDs[$0] != projectedIDs[$0] }
                    ?? (directIDs.count == projectedIDs.count ? nil : sharedIndexRange.upperBound)
                let ordersMatch = mismatchIndex == nil

                var directFileComparatorCalls = 0
                _ = sourceFiles.sorted {
                    directFileComparatorCalls += 1
                    return directFilePrecedes($0, $1)
                }
                var projectedFileComparatorCalls = 0
                _ = projected.projections.sorted {
                    projectedFileComparatorCalls += 1
                    return projectionPrecedes($0, $1)
                }
                var folderComparatorCalls = 0
                _ = sourceFolders.sorted {
                    folderComparatorCalls += 1
                    return Self.searchCatalogFolderPrecedes($0, $1)
                }

                guard repetitionIndex >= excludedWarmupCount else { continue }
                if orderedFileIDs.isEmpty {
                    orderedFileIDs = directIDs
                }
                allOrdersMatch = allOrdersMatch && ordersMatch
                if firstMismatchIndex == nil {
                    firstMismatchIndex = mismatchIndex
                }
                samples.append(WorkspaceCatalogSortAttributionSample(
                    directFileSortNanoseconds: direct.nanoseconds,
                    directFolderSortNanoseconds: WorkspaceFileSearchDebugTiming.elapsed(
                        since: folderStart,
                        through: folderEnd
                    ),
                    keyDerivationNanoseconds: projected.keyNanoseconds,
                    projectionAssemblyNanoseconds: projected.assemblyNanoseconds,
                    projectedFileSortNanoseconds: projected.sortNanoseconds,
                    projectionMappingNanoseconds: projected.mappingNanoseconds,
                    directFileComparatorCalls: directFileComparatorCalls,
                    projectedFileComparatorCalls: projectedFileComparatorCalls,
                    folderComparatorCalls: folderComparatorCalls,
                    directAndProjectedOrdersMatch: ordersMatch,
                    firstMismatchIndex: mismatchIndex
                ))
            }

            return WorkspaceCatalogSortAttributionProbe(
                status: .completed,
                sourceFileCount: sourceFiles.count,
                sourceFolderCount: sourceFolders.count,
                samples: samples,
                directAndProjectedOrdersMatch: allOrdersMatch,
                firstMismatchIndex: firstMismatchIndex,
                orderedFileIDs: orderedFileIDs
            )
        }
    #endif

    func searchCatalogAccess(
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        requirement: WorkspaceSearchCatalogAccessRequirement = .recordsAndPathIndexes
    ) -> WorkspaceSearchCatalogAccess {
        let availability = rootScopeAvailability(rootScope)
        guard availability == .available else {
            return .unavailable(availability)
        }
        return .available(searchCatalogSnapshot(rootScope: rootScope, requirement: requirement))
    }

    func searchCatalogSnapshot(
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        requirement: WorkspaceSearchCatalogAccessRequirement = .recordsAndPathIndexes
    ) -> WorkspaceSearchCatalogSnapshot {
        let catalogSnapshotState = EditFlowPerf.begin(EditFlowPerf.Stage.Search.catalogSnapshot)
        if rootsForPathLookupIgnoringPublishedAuthority(scope: rootScope).contains(where: {
            !publishedSeededAuthorityIsQueryable(rootID: $0.id)
        }) {
            searchCatalogSnapshotsByScope.removeValue(forKey: rootScope)
        }
        let validationToken = searchCatalogSnapshotValidationToken(scope: rootScope)
        if var cached = searchCatalogSnapshotsByScope[rootScope] {
            if cached.validationToken == validationToken {
                if cached.capability.satisfies(requirement) {
                    cached.lastAccessSequence = nextSearchCatalogAccessSequence()
                    searchCatalogSnapshotsByScope[rootScope] = cached
                    EditFlowPerf.end(
                        EditFlowPerf.Stage.Search.catalogSnapshot,
                        catalogSnapshotState,
                        EditFlowPerf.Dimensions(
                            fileCount: cached.snapshot.diagnostics.fileCount,
                            cacheHit: true,
                            rootCount: cached.snapshot.diagnostics.rootCount,
                            folderCount: cached.snapshot.diagnostics.folderCount
                        )
                    )
                    return requirement.requiresPathIndexes
                        ? cached.snapshot
                        : cached.snapshot.recordsOnlyProjection()
                }
            } else {
                searchCatalogSnapshotsByScope.removeValue(forKey: rootScope)
            }
        }
        #if DEBUG
            let rebuildStart = WorkspaceFileSearchDebugTiming.now()
            let catalogBuildObserver = WorkspaceFileSearchCatalogBuildObserver()
        #endif
        let roots = rootsForPathLookup(scope: rootScope)
        let generation = scopedSnapshotGeneration(scope: rootScope, validationToken: validationToken)
        var shouldCacheSnapshot = false
        let snapshot: WorkspaceSearchCatalogSnapshot
        #if DEBUG
            let preparedShards = WorkspaceFileSearchDebugContext.$catalogBuildObserver.withValue(
                catalogBuildObserver
            ) {
                prepareAndPublishRootCatalogShardBatch(for: roots, requirement: requirement)
            }
        #else
            let preparedShards = prepareAndPublishRootCatalogShardBatch(for: roots, requirement: requirement)
        #endif
        if let shards = preparedShards {
            var composedSnapshot = composeSearchCatalogSnapshot(
                rootScope: rootScope,
                generation: generation,
                roots: roots,
                shards: shards,
                requirement: requirement
            )
            shouldCacheSnapshot = true
            #if DEBUG
                if isCatalogShardShadowValidationEnabled {
                    let authoritativeSnapshot = buildAuthoritativeSearchCatalogSnapshot(
                        rootScope: rootScope,
                        generation: generation,
                        roots: roots,
                        requirement: .recordsOnly
                    )
                    let composedBytes = catalogShadowBytes(composedSnapshot)
                    let authoritativeBytes = catalogShadowBytes(authoritativeSnapshot)
                    let shadowMatches = composedBytes == authoritativeBytes
                    recordRootCatalogShardShadowComparison(
                        matched: shadowMatches,
                        byteCount: authoritativeBytes.count
                    )
                    if !shadowMatches {
                        for shard in shards {
                            recordRootCatalogShardFallback(
                                rootID: shard.key.rootID,
                                lifetimeID: shard.key.lifetimeID,
                                reason: .shadowValidationMismatch
                            )
                        }
                        assertionFailure("Root catalog shard composition diverged from the authoritative full rebuild")
                        composedSnapshot = buildAuthoritativeSearchCatalogSnapshot(
                            rootScope: rootScope,
                            generation: generation,
                            roots: roots,
                            requirement: requirement
                        )
                        shouldCacheSnapshot = false
                    }
                }
            #endif
            snapshot = composedSnapshot
        } else {
            #if DEBUG
                snapshot = WorkspaceFileSearchDebugContext.$catalogBuildObserver.withValue(
                    catalogBuildObserver
                ) {
                    buildAuthoritativeSearchCatalogSnapshot(
                        rootScope: rootScope,
                        generation: generation,
                        roots: roots,
                        requirement: requirement
                    )
                }
            #else
                snapshot = buildAuthoritativeSearchCatalogSnapshot(
                    rootScope: rootScope,
                    generation: generation,
                    roots: roots,
                    requirement: requirement
                )
            #endif
        }
        EditFlowPerf.end(
            EditFlowPerf.Stage.Search.catalogSnapshot,
            catalogSnapshotState,
            EditFlowPerf.Dimensions(
                fileCount: snapshot.diagnostics.fileCount,
                cacheHit: false,
                rootCount: snapshot.diagnostics.rootCount,
                folderCount: snapshot.diagnostics.folderCount
            )
        )
        if shouldCacheSnapshot {
            cacheSearchCatalogSnapshot(
                snapshot,
                validationToken: validationToken,
                capability: requirement,
                scope: rootScope
            )
        }
        #if DEBUG
            let rebuildEnd = WorkspaceFileSearchDebugTiming.now()
            let phaseNanoseconds = catalogBuildObserver.snapshot()
            let filterMicroseconds = WorkspaceFileSearchDebugTiming.microseconds(phaseNanoseconds.filterNanoseconds)
            let sortMicroseconds = WorkspaceFileSearchDebugTiming.microseconds(phaseNanoseconds.sortNanoseconds)
            let fileSortMicroseconds = WorkspaceFileSearchDebugTiming.microseconds(
                phaseNanoseconds.fileSortNanoseconds
            )
            let folderSortMicroseconds = WorkspaceFileSearchDebugTiming.microseconds(
                phaseNanoseconds.folderSortNanoseconds
            )
            let sortResidualMicroseconds = WorkspaceFileSearchDebugTiming.microseconds(
                phaseNanoseconds.sortResidualNanoseconds
            )
            let sortReconciliationDeltaMicroseconds =
                phaseNanoseconds.sortReconciliationDeltaNanoseconds / 1000
            let materializationMicroseconds = WorkspaceFileSearchDebugTiming.microseconds(
                phaseNanoseconds.materializationNanoseconds
            )
            let pathIndexKeyMicroseconds = WorkspaceFileSearchDebugTiming.microseconds(
                phaseNanoseconds.pathIndexKeyNanoseconds
            )
            let pathIndexConstructionMicroseconds = WorkspaceFileSearchDebugTiming.microseconds(
                phaseNanoseconds.pathIndexConstructionNanoseconds
            )
            let totalMicroseconds = WorkspaceFileSearchDebugTiming.microseconds(
                WorkspaceFileSearchDebugTiming.elapsed(since: rebuildStart, through: rebuildEnd)
            )
            let classifiedMicroseconds = filterMicroseconds &+ sortMicroseconds &+ materializationMicroseconds
                &+ pathIndexKeyMicroseconds &+ pathIndexConstructionMicroseconds
            let compositionCacheResidualMicroseconds = totalMicroseconds >= classifiedMicroseconds
                ? totalMicroseconds - classifiedMicroseconds
                : 0
            let catalogPhases = WorkspaceFileSearchPhaseSnapshot.Catalog(
                rebuildCount: 1,
                filterMicroseconds: filterMicroseconds,
                sortMicroseconds: sortMicroseconds,
                fileSortMicroseconds: fileSortMicroseconds,
                folderSortMicroseconds: folderSortMicroseconds,
                sortResidualMicroseconds: sortResidualMicroseconds,
                sortReconciliationDeltaMicroseconds: sortReconciliationDeltaMicroseconds,
                sortInvocationCount: phaseNanoseconds.sortInvocationCount,
                sortFileInputCount: phaseNanoseconds.sortFileInputCount,
                sortFolderInputCount: phaseNanoseconds.sortFolderInputCount,
                materializationMicroseconds: materializationMicroseconds,
                pathIndexKeyMicroseconds: pathIndexKeyMicroseconds,
                pathIndexConstructionMicroseconds: pathIndexConstructionMicroseconds,
                compositionCacheResidualMicroseconds: compositionCacheResidualMicroseconds,
                totalMicroseconds: totalMicroseconds,
                fileCount: snapshot.files.count,
                rootCount: roots.count
            )
            recordCatalogRebuild(
                filterMicroseconds: filterMicroseconds,
                sortMicroseconds: sortMicroseconds,
                fileSortMicroseconds: fileSortMicroseconds,
                folderSortMicroseconds: folderSortMicroseconds,
                sortResidualMicroseconds: sortResidualMicroseconds,
                sortReconciliationDeltaMicroseconds: sortReconciliationDeltaMicroseconds,
                sortInvocationCount: phaseNanoseconds.sortInvocationCount,
                sortFileInputCount: phaseNanoseconds.sortFileInputCount,
                sortFolderInputCount: phaseNanoseconds.sortFolderInputCount,
                materializationMicroseconds: materializationMicroseconds,
                pathIndexKeyMicroseconds: pathIndexKeyMicroseconds,
                pathIndexConstructionMicroseconds: pathIndexConstructionMicroseconds,
                compositionCacheResidualMicroseconds: compositionCacheResidualMicroseconds,
                totalMicroseconds: totalMicroseconds,
                fileCount: snapshot.files.count,
                rootCount: roots.count
            )
            WorkspaceFileSearchDebugContext.collector?.recordCatalogRebuild(catalogPhases)
        #endif
        return snapshot
    }

    private func prepareAndPublishRootCatalogShardBatch(
        for roots: [WorkspaceRootRecord],
        requirement: WorkspaceSearchCatalogAccessRequirement
    ) -> [RootCatalogShard]? {
        var keysByRootID: [UUID: RootCatalogShardKey] = [:]
        keysByRootID.reserveCapacity(roots.count)
        var rootsNeedingAuthoritativeBuild: [(root: WorkspaceRootRecord, key: RootCatalogShardKey)] = []
        var rootsNeedingPromotion: [(root: WorkspaceRootRecord, key: RootCatalogShardKey, shard: RootCatalogShard)] = []
        rootsNeedingAuthoritativeBuild.reserveCapacity(roots.count)
        rootsNeedingPromotion.reserveCapacity(roots.count)

        for root in roots {
            guard let key = rootCatalogShardKey(for: root) else { return nil }
            keysByRootID[root.id] = key
            guard let published = publishedRootCatalogShardsByRootID[root.id], published.key == key else {
                rootsNeedingAuthoritativeBuild.append((root, key))
                continue
            }
            if requirement.requiresPathIndexes, published.pathSearchIndex == nil {
                rootsNeedingPromotion.append((root, key, published))
            }
        }

        for candidate in rootsNeedingAuthoritativeBuild {
            let liveGenerationCount = liveRootCatalogShards(rootID: candidate.root.id).count
            if rootCatalogShardDeltaStatesByRootID[candidate.root.id]?.isDirty == true,
               liveGenerationCount >= Self.maxLiveRootCatalogShardGenerationsPerRoot
            {
                return nil
            }
            guard canPublishAnotherRootCatalogShard(rootID: candidate.root.id) else {
                #if DEBUG
                    recordRootCatalogShardFallback(
                        rootID: candidate.root.id,
                        lifetimeID: candidate.key.lifetimeID,
                        reason: .retentionBoundary
                    )
                #endif
                markRootCatalogShardDirty(
                    rootID: candidate.root.id,
                    lifetimeID: candidate.key.lifetimeID,
                    lastAppliedIndexGeneration: appliedIndexGenerationsByRootID[candidate.root.id] ?? 0,
                    capability: rootCatalogShardDeltaStatesByRootID[candidate.root.id]?.capability ?? .recordsOnly
                )
                publishedRootCatalogShardsByRootID.removeValue(forKey: candidate.root.id)
                return nil
            }
        }
        for candidate in rootsNeedingPromotion {
            guard canPublishAnotherRootCatalogShard(rootID: candidate.root.id) else {
                #if DEBUG
                    recordRootCatalogShardFallback(
                        rootID: candidate.root.id,
                        lifetimeID: candidate.key.lifetimeID,
                        reason: .retentionBoundary
                    )
                #endif
                return nil
            }
        }

        // Build the complete replacement batch privately; the actor publishes it with one assignment below.
        var newlyBuiltShardsByRootID: [UUID: (shard: RootCatalogShard, kind: RootCatalogShardBuildKind)] = [:]
        newlyBuiltShardsByRootID.reserveCapacity(
            rootsNeedingAuthoritativeBuild.count + rootsNeedingPromotion.count
        )
        for candidate in rootsNeedingAuthoritativeBuild {
            let appliedIndexGeneration = appliedIndexGenerationsByRootID[candidate.root.id] ?? 0
            let savedCapability = rootCatalogShardDeltaStatesByRootID[candidate.root.id].flatMap { state in
                state.lifetimeID == candidate.key.lifetimeID ? state.capability : nil
            }
            let buildRequirement = if let savedCapability, savedCapability.satisfies(requirement) {
                savedCapability
            } else {
                requirement
            }
            let shard = buildAuthoritativeRootCatalogShard(
                root: candidate.root,
                key: candidate.key,
                appliedIndexGeneration: appliedIndexGeneration,
                requirement: buildRequirement
            )
            newlyBuiltShardsByRootID[candidate.root.id] = (shard, .authoritative)
        }
        for candidate in rootsNeedingPromotion {
            let promoted = RootCatalogShard(
                key: candidate.shard.key,
                root: candidate.shard.root,
                files: candidate.shard.files,
                folders: candidate.shard.folders,
                entries: candidate.shard.entries,
                pathSearchIndex: makeRootPathSearchIndex(
                    key: candidate.shard.key,
                    root: candidate.shard.root,
                    entries: candidate.shard.entries
                ),
                appliedIndexGeneration: candidate.shard.appliedIndexGeneration
            )
            newlyBuiltShardsByRootID[candidate.root.id] = (promoted, .promotion)
        }

        var publication = publishedRootCatalogShardsByRootID
        publication.reserveCapacity(max(publication.count, roots.count))
        for root in roots {
            guard let key = keysByRootID[root.id] else { return nil }
            if let newlyBuilt = newlyBuiltShardsByRootID[root.id]?.shard {
                publication[root.id] = newlyBuilt
            } else if let retained = publishedRootCatalogShardsByRootID[root.id], retained.key == key,
                      !requirement.requiresPathIndexes || retained.pathSearchIndex != nil
            {
                publication[root.id] = retained
            } else {
                return nil
            }
        }

        publishedRootCatalogShardsByRootID = publication
        for built in newlyBuiltShardsByRootID.values {
            switch built.kind {
            case .authoritative, .promotion:
                rootCatalogShardDeltaStatesByRootID[built.shard.key.rootID] = RootCatalogShardDeltaState(
                    lifetimeID: built.shard.key.lifetimeID,
                    lastAppliedIndexGeneration: built.shard.appliedIndexGeneration,
                    isDirty: false,
                    capability: built.shard.pathSearchIndex == nil ? .recordsOnly : .recordsAndPathIndexes
                )
            case .patch:
                break
            }
            registerPublishedRootCatalogShard(built.shard, kind: built.kind)
        }
        return roots.compactMap { publication[$0.id] }
    }

    private func rootCatalogShardKey(for root: WorkspaceRootRecord) -> RootCatalogShardKey? {
        guard let state = rootStatesByID[root.id],
              let loadConfiguration = rootLoadConfigurationsByPath[root.standardizedFullPath]
        else { return nil }
        return RootCatalogShardKey(
            canonicalConfigurationIdentity: RootCatalogCanonicalConfigurationIdentity(
                canonicalPath: root.standardizedFullPath,
                loadConfiguration: loadConfiguration
            ),
            rootID: root.id,
            lifetimeID: state.lifetimeID,
            topologyGeneration: catalogGenerationsByRootID[root.id] ?? 0
        )
    }

    private func buildAuthoritativeRootCatalogShard(
        root: WorkspaceRootRecord,
        key: RootCatalogShardKey,
        appliedIndexGeneration: UInt64,
        requirement: WorkspaceSearchCatalogAccessRequirement
    ) -> RootCatalogShard {
        let components = buildAuthoritativeCatalogComponents(roots: [root])
        return RootCatalogShard(
            key: key,
            root: root,
            files: components.files,
            folders: components.folders,
            entries: components.entries,
            pathSearchIndex: requirement.requiresPathIndexes
                ? makeRootPathSearchIndex(key: key, root: root, entries: components.entries)
                : nil,
            appliedIndexGeneration: appliedIndexGeneration
        )
    }

    private func makeRootPathSearchIndex(
        key: RootCatalogShardKey,
        root: WorkspaceRootRecord,
        entries: [WorkspaceSearchCatalogEntry]
    ) -> WorkspaceSearchRootPathIndex {
        #if DEBUG
            let keyStart = WorkspaceFileSearchDebugTiming.now()
        #endif
        let identity = WorkspaceSearchRootPathIndexIdentity(
            rootID: key.rootID,
            lifetimeID: key.lifetimeID,
            topologyGeneration: key.topologyGeneration
        )
        #if DEBUG
            WorkspaceFileSearchDebugContext.catalogBuildObserver?.recordPathIndexKey(
                nanoseconds: WorkspaceFileSearchDebugTiming.elapsed(
                    since: keyStart,
                    through: WorkspaceFileSearchDebugTiming.now()
                )
            )
            let constructionStart = WorkspaceFileSearchDebugTiming.now()
        #endif
        let shadowControl = rootSeedSearchShadowControl(key: key, root: root)
        let index = WorkspaceSearchRootPathIndex(
            identity: identity,
            rootPath: root.standardizedFullPath,
            entries: entries,
            shadowControl: shadowControl
        )
        #if DEBUG
            WorkspaceFileSearchDebugContext.catalogBuildObserver?.recordPathIndexConstruction(
                nanoseconds: WorkspaceFileSearchDebugTiming.elapsed(
                    since: constructionStart,
                    through: WorkspaceFileSearchDebugTiming.now()
                )
            )
        #endif
        return index
    }

    private func installRootSeedSearchShadow(_ preparation: WorkspaceRootSeedShadowPreparation) {
        let scope = preparation.scope
        let lifetimeKey = SessionWorktreeRootLifetimeKey(rootID: scope.rootID, lifetimeID: scope.lifetimeID)
        guard installedSessionWorktreeOwnershipTokenByOwnerID[scope.token.ownerID] == scope.token,
              latestSessionWorktreeOwnershipGenerationByOwnerID[scope.token.ownerID] == scope.token.generation,
              let record = sessionWorktreeOwnershipRecordsByToken[scope.token],
              record.bindingFingerprint == scope.bindingFingerprint,
              record.roots.contains(where: {
                  $0.rootID == scope.rootID
                      && $0.lifetimeID == scope.lifetimeID
                      && $0.standardizedPhysicalPath == scope.standardizedPhysicalPath
              }),
              sessionWorktreeOwnershipTokensByRootLifetime[lifetimeKey] == Set([scope.token]),
              let state = rootStatesByID[scope.rootID],
              state.lifetimeID == scope.lifetimeID,
              state.root.standardizedFullPath == scope.standardizedPhysicalPath,
              catalogGenerationsByRootID[scope.rootID] == scope.catalogGeneration,
              appliedIndexGenerationsByRootID[scope.rootID] == scope.appliedIndexGeneration
        else {
            WorktreeStartupInstrumentation.recordShadowFallback(.ownerSuperseded)
            return
        }
        let entries = buildAuthoritativeCatalogComponents(roots: [state.root]).entries
        guard let projection = WorkspaceProjectedPathSearchIndex(
            snapshot: preparation.snapshot,
            planHandle: preparation.planHandle,
            additionalChangedRelativePaths: .empty,
            root: state.root,
            authoritativeEntries: entries
        ) else {
            WorktreeStartupInstrumentation.recordShadowFallback(.projectedSearchMismatch)
            return
        }
        invalidateRootSeedSearchShadow(rootID: scope.rootID)
        let control = WorkspaceProjectedPathSearchShadowControl(scope: scope, projection: projection)
        rootSeedSearchShadowsByRootID[scope.rootID] = RootSeedSearchShadow(
            scope: scope,
            control: control
        )
    }

    private func rootSeedSearchShadowControl(
        key: RootCatalogShardKey,
        root: WorkspaceRootRecord
    ) -> WorkspaceProjectedPathSearchShadowControl? {
        guard let shadow = rootSeedSearchShadowsByRootID[root.id] else { return nil }
        let scope = shadow.scope
        let lifetimeKey = SessionWorktreeRootLifetimeKey(rootID: scope.rootID, lifetimeID: scope.lifetimeID)
        guard shadow.control.isActive,
              scope.rootID == key.rootID,
              scope.lifetimeID == key.lifetimeID,
              scope.catalogGeneration == key.topologyGeneration,
              scope.standardizedPhysicalPath == root.standardizedFullPath,
              appliedIndexGenerationsByRootID[root.id] == scope.appliedIndexGeneration,
              installedSessionWorktreeOwnershipTokenByOwnerID[scope.token.ownerID] == scope.token,
              latestSessionWorktreeOwnershipGenerationByOwnerID[scope.token.ownerID] == scope.token.generation,
              sessionWorktreeOwnershipTokensByRootLifetime[lifetimeKey] == Set([scope.token])
        else {
            invalidateRootSeedSearchShadow(rootID: root.id)
            return nil
        }
        return shadow.control
    }

    private func invalidateRootSeedSearchShadow(rootID: UUID) {
        rootSeedSearchShadowsByRootID.removeValue(forKey: rootID)?.control.invalidate()
    }

    private func registerPublishedRootCatalogShard(
        _ shard: RootCatalogShard,
        kind: RootCatalogShardBuildKind
    ) {
        rootCatalogShardWeakReferencesByRootID[shard.key.rootID, default: []]
            .append(WeakRootCatalogShardReference(shard))
        #if DEBUG
            rootCatalogShardBuildCountsByRootID[shard.key.rootID, default: 0] += 1
            switch kind {
            case .patch:
                rootCatalogShardPatchCountsByRootID[shard.key.rootID, default: 0] += 1
            case .authoritative:
                rootCatalogShardAuthoritativeRebuildCountsByRootID[shard.key.rootID, default: 0] += 1
            case .promotion:
                break
            }
            switch shard.pathSearchIndex?.buildKind {
            case .full:
                rootCatalogShardFullPathIndexBuildCountsByRootID[shard.key.rootID, default: 0] += 1
            case .overlay:
                rootCatalogShardOverlayPathIndexBuildCountsByRootID[shard.key.rootID, default: 0] += 1
            case .projectedReuse:
                rootCatalogShardOverlayPathIndexBuildCountsByRootID[shard.key.rootID, default: 0] += 1
            case .reused, nil:
                break
            }
            let liveCount = liveRootCatalogShards(rootID: shard.key.rootID).count
            rootCatalogShardMaxLiveGenerationCountsByRootID[shard.key.rootID] = max(
                rootCatalogShardMaxLiveGenerationCountsByRootID[shard.key.rootID] ?? 0,
                liveCount
            )
        #endif
    }

    private func liveRootCatalogShards(rootID: UUID) -> [RootCatalogShard] {
        let live = (rootCatalogShardWeakReferencesByRootID[rootID] ?? []).compactMap(\.shard)
        if live.isEmpty {
            rootCatalogShardWeakReferencesByRootID.removeValue(forKey: rootID)
        } else {
            rootCatalogShardWeakReferencesByRootID[rootID] = live.map(WeakRootCatalogShardReference.init)
        }
        return live
    }

    private func canPublishAnotherRootCatalogShard(rootID: UUID) -> Bool {
        let liveGenerations = liveRootCatalogShards(rootID: rootID)
        guard liveGenerations.count < Self.maxLiveRootCatalogShardGenerationsPerRoot else {
            #if DEBUG
                rootCatalogShardBackstopCountsByRootID[rootID, default: 0] += 1
                rootCatalogShardMaxLiveGenerationCountsByRootID[rootID] = max(
                    rootCatalogShardMaxLiveGenerationCountsByRootID[rootID] ?? 0,
                    liveGenerations.count
                )
            #endif
            return false
        }
        return true
    }

    private func applyAppliedIndexEventToRootCatalogShard(_ event: WorkspaceAppliedIndexBatchEvent) {
        // Any post-initialization filesystem publication invalidates the one-shot shadow plan.
        invalidateRootSeedSearchShadow(rootID: event.rootID)
        if event.isRootUnload {
            publishedRootCatalogShardsByRootID.removeValue(forKey: event.rootID)
            rootCatalogShardDeltaStatesByRootID.removeValue(forKey: event.rootID)
            return
        }

        guard let state = rootStatesByID[event.rootID],
              state.root.standardizedFullPath == StandardizedPath.absolute(event.rootPath),
              let currentKey = rootCatalogShardKey(for: state.root)
        else {
            publishedRootCatalogShardsByRootID.removeValue(forKey: event.rootID)
            rootCatalogShardDeltaStatesByRootID.removeValue(forKey: event.rootID)
            return
        }

        guard let previousShard = publishedRootCatalogShardsByRootID[event.rootID] else {
            guard let deltaState = rootCatalogShardDeltaStatesByRootID[event.rootID],
                  deltaState.lifetimeID == state.lifetimeID
            else {
                // The actor's authoritative records and generations already include this batch.
                // Keep catalog publication fully lazy until a caller requests a catalog capability.
                return
            }
            #if DEBUG
                recordRootCatalogShardFallback(
                    rootID: event.rootID,
                    lifetimeID: state.lifetimeID,
                    reason: deltaState.isDirty ? .retentionBoundary : .missingReusableShard
                )
            #endif
            rebuildRootCatalogShardAuthoritatively(
                root: state.root,
                key: currentKey,
                appliedIndexGeneration: event.generation,
                requirement: deltaState.capability
            )
            return
        }
        let fallbackRequirement: WorkspaceSearchCatalogAccessRequirement = previousShard.pathSearchIndex == nil
            ? .recordsOnly
            : .recordsAndPathIndexes
        let deltaState = rootCatalogShardDeltaStatesByRootID[event.rootID] ?? RootCatalogShardDeltaState(
            lifetimeID: previousShard.key.lifetimeID,
            lastAppliedIndexGeneration: previousShard.appliedIndexGeneration,
            isDirty: false,
            capability: fallbackRequirement
        )
        guard deltaState.lifetimeID == state.lifetimeID,
              previousShard.key.lifetimeID == state.lifetimeID,
              previousShard.key.rootID == event.rootID,
              previousShard.key.canonicalConfigurationIdentity == currentKey.canonicalConfigurationIdentity
        else {
            #if DEBUG
                recordRootCatalogShardFallback(
                    rootID: event.rootID,
                    lifetimeID: state.lifetimeID,
                    reason: .unsafeOrAmbiguousBatch
                )
            #endif
            rebuildRootCatalogShardAuthoritatively(
                root: state.root,
                key: currentKey,
                appliedIndexGeneration: event.generation,
                requirement: fallbackRequirement
            )
            return
        }
        if deltaState.isDirty {
            #if DEBUG
                recordRootCatalogShardFallback(
                    rootID: event.rootID,
                    lifetimeID: state.lifetimeID,
                    reason: .retentionBoundary
                )
            #endif
            rebuildRootCatalogShardAuthoritatively(
                root: state.root,
                key: currentKey,
                appliedIndexGeneration: event.generation,
                requirement: fallbackRequirement
            )
            return
        }
        if event.requiresFullResync {
            #if DEBUG
                recordRootCatalogShardFallback(
                    rootID: event.rootID,
                    lifetimeID: state.lifetimeID,
                    reason: .fullResync
                )
            #endif
            rebuildRootCatalogShardAuthoritatively(
                root: state.root,
                key: currentKey,
                appliedIndexGeneration: event.generation,
                requirement: fallbackRequirement
            )
            return
        }
        if deltaState.lastAppliedIndexGeneration == UInt64.max || event.generation == 0 {
            #if DEBUG
                recordRootCatalogShardFallback(
                    rootID: event.rootID,
                    lifetimeID: state.lifetimeID,
                    reason: .generationGap
                )
            #endif
            rebuildRootCatalogShardAuthoritatively(
                root: state.root,
                key: currentKey,
                appliedIndexGeneration: event.generation,
                requirement: fallbackRequirement
            )
            return
        }
        guard event.generation == deltaState.lastAppliedIndexGeneration + 1 else {
            #if DEBUG
                recordRootCatalogShardFallback(
                    rootID: event.rootID,
                    lifetimeID: state.lifetimeID,
                    reason: .generationGap
                )
            #endif
            rebuildRootCatalogShardAuthoritatively(
                root: state.root,
                key: currentKey,
                appliedIndexGeneration: event.generation,
                requirement: fallbackRequirement
            )
            return
        }

        let hasTopologyMutation = !event.upsertedFiles.isEmpty
            || !event.upsertedFolders.isEmpty
            || !event.removedFileIDs.isEmpty
            || !event.removedFolderIDs.isEmpty
            || !event.removedFilePaths.isEmpty
            || !event.removedFolderPaths.isEmpty
        let expectedTopologyGeneration: UInt64
        if hasTopologyMutation {
            guard previousShard.key.topologyGeneration != UInt64.max else {
                #if DEBUG
                    recordRootCatalogShardFallback(
                        rootID: event.rootID,
                        lifetimeID: state.lifetimeID,
                        reason: .generationGap
                    )
                #endif
                rebuildRootCatalogShardAuthoritatively(
                    root: state.root,
                    key: currentKey,
                    appliedIndexGeneration: event.generation,
                    requirement: fallbackRequirement
                )
                return
            }
            expectedTopologyGeneration = previousShard.key.topologyGeneration + 1
        } else {
            expectedTopologyGeneration = previousShard.key.topologyGeneration
        }
        guard currentKey.topologyGeneration == expectedTopologyGeneration else {
            #if DEBUG
                recordRootCatalogShardFallback(
                    rootID: event.rootID,
                    lifetimeID: state.lifetimeID,
                    reason: .unsafeOrAmbiguousBatch
                )
            #endif
            rebuildRootCatalogShardAuthoritatively(
                root: state.root,
                key: currentKey,
                appliedIndexGeneration: event.generation,
                requirement: fallbackRequirement
            )
            return
        }
        guard let builderOutput = buildRootCatalogShardPatch(event: event, previousShard: previousShard) else {
            #if DEBUG
                recordRootCatalogShardFallback(
                    rootID: event.rootID,
                    lifetimeID: state.lifetimeID,
                    reason: .patchApplicationBackstop
                )
            #endif
            rebuildRootCatalogShardAuthoritatively(
                root: state.root,
                key: currentKey,
                appliedIndexGeneration: event.generation,
                requirement: fallbackRequirement
            )
            return
        }
        guard builderOutput.logicalMutationCount <= Self.maxRootCatalogShardPatchLogicalMutationCount else {
            #if DEBUG
                recordRootCatalogShardFallback(
                    rootID: event.rootID,
                    lifetimeID: state.lifetimeID,
                    reason: .patchThresholdExceeded
                )
            #endif
            rebuildRootCatalogShardAuthoritatively(
                root: state.root,
                key: currentKey,
                appliedIndexGeneration: event.generation,
                requirement: fallbackRequirement
            )
            return
        }
        guard canPublishAnotherRootCatalogShard(rootID: event.rootID) else {
            #if DEBUG
                recordRootCatalogShardFallback(
                    rootID: event.rootID,
                    lifetimeID: state.lifetimeID,
                    reason: .retentionBoundary
                )
            #endif
            markRootCatalogShardDirty(
                rootID: event.rootID,
                lifetimeID: state.lifetimeID,
                lastAppliedIndexGeneration: event.generation,
                capability: fallbackRequirement
            )
            publishedRootCatalogShardsByRootID.removeValue(forKey: event.rootID)
            return
        }

        let patchedEntries = builderOutput.files.map { WorkspaceSearchCatalogEntry(file: $0, root: state.root) }
        let patchedPathSearchIndex = previousShard.pathSearchIndex?.applyingPatch(
            identity: WorkspaceSearchRootPathIndexIdentity(
                rootID: currentKey.rootID,
                lifetimeID: currentKey.lifetimeID,
                topologyGeneration: currentKey.topologyGeneration
            ),
            entries: patchedEntries,
            changedFileIDs: builderOutput.pathIndexChangedFileIDs
        )
        let patchedShard = RootCatalogShard(
            key: currentKey,
            root: state.root,
            files: builderOutput.files,
            folders: builderOutput.folders,
            entries: patchedEntries,
            pathSearchIndex: patchedPathSearchIndex,
            appliedIndexGeneration: event.generation
        )
        var publication = publishedRootCatalogShardsByRootID
        publication[event.rootID] = patchedShard
        publishedRootCatalogShardsByRootID = publication
        rootCatalogShardDeltaStatesByRootID[event.rootID] = RootCatalogShardDeltaState(
            lifetimeID: state.lifetimeID,
            lastAppliedIndexGeneration: event.generation,
            isDirty: false,
            capability: fallbackRequirement
        )
        registerPublishedRootCatalogShard(patchedShard, kind: .patch)
    }

    private func rebuildRootCatalogShardAuthoritatively(
        root: WorkspaceRootRecord,
        key: RootCatalogShardKey,
        appliedIndexGeneration: UInt64,
        requirement: WorkspaceSearchCatalogAccessRequirement = .recordsAndPathIndexes
    ) {
        guard canPublishAnotherRootCatalogShard(rootID: root.id) else {
            #if DEBUG
                recordRootCatalogShardFallback(
                    rootID: root.id,
                    lifetimeID: key.lifetimeID,
                    reason: .retentionBoundary
                )
            #endif
            markRootCatalogShardDirty(
                rootID: root.id,
                lifetimeID: key.lifetimeID,
                lastAppliedIndexGeneration: appliedIndexGeneration,
                capability: requirement
            )
            publishedRootCatalogShardsByRootID.removeValue(forKey: root.id)
            return
        }
        let rebuiltShard = buildAuthoritativeRootCatalogShard(
            root: root,
            key: key,
            appliedIndexGeneration: appliedIndexGeneration,
            requirement: requirement
        )
        var publication = publishedRootCatalogShardsByRootID
        publication[root.id] = rebuiltShard
        publishedRootCatalogShardsByRootID = publication
        rootCatalogShardDeltaStatesByRootID[root.id] = RootCatalogShardDeltaState(
            lifetimeID: key.lifetimeID,
            lastAppliedIndexGeneration: appliedIndexGeneration,
            isDirty: false,
            capability: requirement
        )
        registerPublishedRootCatalogShard(rebuiltShard, kind: .authoritative)
    }

    private func markRootCatalogShardDirty(
        rootID: UUID,
        lifetimeID: UUID,
        lastAppliedIndexGeneration: UInt64,
        capability: WorkspaceSearchCatalogAccessRequirement
    ) {
        rootCatalogShardDeltaStatesByRootID[rootID] = RootCatalogShardDeltaState(
            lifetimeID: lifetimeID,
            lastAppliedIndexGeneration: lastAppliedIndexGeneration,
            isDirty: true,
            capability: capability
        )
    }

    #if DEBUG
        private func resetRootCatalogShardFallbackDiagnosticsIfLifetimeChanged(
            rootID: UUID,
            lifetimeID: UUID
        ) {
            guard rootCatalogShardFallbackLifetimeIDsByRootID[rootID] != lifetimeID else { return }
            rootCatalogShardFallbackLifetimeIDsByRootID[rootID] = lifetimeID
            rootCatalogShardFallbackCountsByRootID.removeValue(forKey: rootID)
            rootCatalogShardFallbackReasonCountsByRootID.removeValue(forKey: rootID)
        }

        private func recordRootCatalogShardFallback(
            rootID: UUID,
            lifetimeID: UUID,
            reason: RootCatalogShardFallbackReason
        ) {
            resetRootCatalogShardFallbackDiagnosticsIfLifetimeChanged(
                rootID: rootID,
                lifetimeID: lifetimeID
            )
            rootCatalogShardFallbackCountsByRootID[rootID, default: 0] += 1
            rootCatalogShardFallbackReasonCountsByRootID[rootID, default: [:]][reason, default: 0] += 1
            assert(
                rootCatalogShardFallbackCountsByRootID[rootID]
                    == rootCatalogShardFallbackReasonCountsByRootID[rootID]?.values.reduce(0, +)
            )
        }
    #endif

    private func buildRootCatalogShardPatch(
        event: WorkspaceAppliedIndexBatchEvent,
        previousShard: RootCatalogShard
    ) -> RootCatalogShardBuilderOutput? {
        let oldFilesByID = Dictionary(uniqueKeysWithValues: previousShard.files.map { ($0.id, $0) })
        let oldFileIDsByPath = Dictionary(
            previousShard.files.map { ($0.standardizedRelativePath, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        let oldFoldersByID = Dictionary(uniqueKeysWithValues: previousShard.folders.map { ($0.id, $0) })
        let oldFolderIDsByPath = Dictionary(
            previousShard.folders.map { ($0.standardizedRelativePath, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )

        let upsertedFilesByID = Dictionary(event.upsertedFiles.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let upsertedFoldersByID = Dictionary(event.upsertedFolders.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        guard upsertedFilesByID.count == event.upsertedFiles.count,
              upsertedFoldersByID.count == event.upsertedFolders.count,
              event.upsertedFiles.allSatisfy({ $0.rootID == event.rootID && filesByID[$0.id] == $0 }),
              event.upsertedFolders.allSatisfy({ $0.rootID == event.rootID && foldersByID[$0.id] == $0 })
        else { return nil }
        let representedFolderIDs = Set(oldFoldersByID.keys).union(upsertedFoldersByID.keys)
        for file in upsertedFilesByID.values {
            var parentFolderID = file.parentFolderID
            while let folderID = parentFolderID {
                guard representedFolderIDs.contains(folderID),
                      let folder = foldersByID[folderID]
                else { return nil }
                parentFolderID = folder.parentFolderID
            }
        }

        let removedFileIDs = Set(event.removedFileIDs)
        let removedFolderIDs = Set(event.removedFolderIDs)
        let removedFilePaths = Set(event.removedFilePaths.map(StandardizedPath.relative))
        let removedFolderPaths = Set(event.removedFolderPaths.map(StandardizedPath.relative))
        let modifiedFileIDs = Set(event.modifiedFileIDs)
        let modifiedFolderIDs = Set(event.modifiedFolderIDs)
        guard removedFileIDs.count == event.removedFileIDs.count,
              removedFolderIDs.count == event.removedFolderIDs.count,
              modifiedFileIDs.count == event.modifiedFileIDs.count,
              modifiedFolderIDs.count == event.modifiedFolderIDs.count,
              modifiedFileIDs.allSatisfy({ filesByID[$0]?.rootID == event.rootID }),
              modifiedFolderIDs.allSatisfy({ foldersByID[$0]?.rootID == event.rootID })
        else { return nil }

        var touchedFileIDs = Set(upsertedFilesByID.keys)
        var touchedFolderIDs = Set(upsertedFoldersByID.keys)
        for id in removedFileIDs {
            guard oldFilesByID[id] != nil else { return nil }
            touchedFileIDs.insert(id)
        }
        for path in removedFilePaths {
            guard let id = oldFileIDsByPath[path] else { return nil }
            touchedFileIDs.insert(id)
        }
        for id in modifiedFileIDs {
            guard oldFilesByID[id] != nil else { return nil }
            touchedFileIDs.insert(id)
        }
        for id in removedFolderIDs {
            guard oldFoldersByID[id] != nil else { return nil }
            touchedFolderIDs.insert(id)
        }
        for path in removedFolderPaths {
            guard let id = oldFolderIDsByPath[path] else { return nil }
            touchedFolderIDs.insert(id)
        }
        for id in modifiedFolderIDs {
            guard oldFoldersByID[id] != nil else { return nil }
            touchedFolderIDs.insert(id)
        }

        let upsertedFilePaths = Set(upsertedFilesByID.values.map(\.standardizedRelativePath))
        let upsertedFolderPaths = Set(upsertedFoldersByID.values.map(\.standardizedRelativePath))
        var pathIndexChangedFileIDs = touchedFileIDs
        for path in removedFilePaths.union(upsertedFilePaths) {
            if let oldFileID = oldFileIDsByPath[path] {
                pathIndexChangedFileIDs.insert(oldFileID)
            }
        }
        guard removedFileIDs.isDisjoint(with: upsertedFilesByID.keys),
              removedFolderIDs.isDisjoint(with: upsertedFoldersByID.keys),
              removedFilePaths.isDisjoint(with: upsertedFilePaths),
              removedFolderPaths.isDisjoint(with: upsertedFolderPaths),
              modifiedFileIDs.isDisjoint(with: removedFileIDs),
              modifiedFolderIDs.isDisjoint(with: removedFolderIDs)
        else { return nil }

        let logicalMutationCount = touchedFileIDs.count + touchedFolderIDs.count
        guard logicalMutationCount <= Self.maxRootCatalogShardPatchLogicalMutationCount else {
            return RootCatalogShardBuilderOutput(
                files: previousShard.files,
                folders: previousShard.folders,
                logicalMutationCount: logicalMutationCount,
                pathIndexChangedFileIDs: []
            )
        }

        func insertFile(_ file: WorkspaceFileRecord, into files: inout [WorkspaceFileRecord]) {
            var lowerBound = 0
            var upperBound = files.count
            while lowerBound < upperBound {
                let midpoint = (lowerBound + upperBound) / 2
                if Self.searchRootCatalogFilePrecedes(files[midpoint], file) {
                    lowerBound = midpoint + 1
                } else {
                    upperBound = midpoint
                }
            }
            files.insert(file, at: lowerBound)
        }

        func insertFolder(_ folder: WorkspaceFolderRecord, into folders: inout [WorkspaceFolderRecord]) {
            var lowerBound = 0
            var upperBound = folders.count
            while lowerBound < upperBound {
                let midpoint = (lowerBound + upperBound) / 2
                if Self.searchCatalogFolderPrecedes(folders[midpoint], folder) {
                    lowerBound = midpoint + 1
                } else {
                    upperBound = midpoint
                }
            }
            folders.insert(folder, at: lowerBound)
        }

        var files = previousShard.files
        if let touchedFileID = touchedFileIDs.first {
            files.removeAll { file in
                file.id == touchedFileID
                    || removedFilePaths.contains(file.standardizedRelativePath)
                    || upsertedFilePaths.contains(file.standardizedRelativePath)
            }
            if let upserted = upsertedFilesByID[touchedFileID] {
                insertFile(upserted, into: &files)
            } else if modifiedFileIDs.contains(touchedFileID), let modified = filesByID[touchedFileID] {
                insertFile(modified, into: &files)
            }
        }

        var folders = previousShard.folders
        if let touchedFolderID = touchedFolderIDs.first {
            folders.removeAll { folder in
                folder.id == touchedFolderID
                    || removedFolderPaths.contains(folder.standardizedRelativePath)
                    || upsertedFolderPaths.contains(folder.standardizedRelativePath)
            }
            if let upserted = upsertedFoldersByID[touchedFolderID] {
                insertFolder(upserted, into: &folders)
            } else if modifiedFolderIDs.contains(touchedFolderID), let modified = foldersByID[touchedFolderID] {
                insertFolder(modified, into: &folders)
            }
        }

        return RootCatalogShardBuilderOutput(
            files: files,
            folders: folders,
            logicalMutationCount: logicalMutationCount,
            pathIndexChangedFileIDs: pathIndexChangedFileIDs
        )
    }

    private func buildAuthoritativeCatalogComponents(
        roots: [WorkspaceRootRecord]
    ) -> AuthoritativeCatalogComponents {
        let rootsByID = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
        let allowedRootIDs = Set(rootsByID.keys)
        let filePrecedes: (WorkspaceFileRecord, WorkspaceFileRecord) -> Bool = roots.count == 1
            ? Self.searchRootCatalogFilePrecedes
            : Self.searchCatalogFilePrecedes
        #if DEBUG
            let filterStart = WorkspaceFileSearchDebugTiming.now()
            let filteredFiles = filesByID.values
                .filter { allowedRootIDs.contains($0.rootID) && isDiscoverableFileID($0.id) }
            let filteredFolders = foldersByID.values
                .filter { allowedRootIDs.contains($0.rootID) && isDiscoverableFolderID($0.id) }
            let filterEnd = WorkspaceFileSearchDebugTiming.now()
            WorkspaceFileSearchDebugContext.catalogBuildObserver?.recordFilter(
                nanoseconds: WorkspaceFileSearchDebugTiming.elapsed(since: filterStart, through: filterEnd)
            )
            let sortStart = WorkspaceFileSearchDebugTiming.now()
            let fileSortStart = WorkspaceFileSearchDebugTiming.now()
            let files = filteredFiles.sorted(by: filePrecedes)
            let fileSortEnd = WorkspaceFileSearchDebugTiming.now()
            let folderSortStart = WorkspaceFileSearchDebugTiming.now()
            let folders = filteredFolders.sorted(by: Self.searchCatalogFolderPrecedes)
            let folderSortEnd = WorkspaceFileSearchDebugTiming.now()
            let sortEnd = WorkspaceFileSearchDebugTiming.now()
            WorkspaceFileSearchDebugContext.catalogBuildObserver?.recordSort(
                nanoseconds: WorkspaceFileSearchDebugTiming.elapsed(since: sortStart, through: sortEnd),
                fileNanoseconds: WorkspaceFileSearchDebugTiming.elapsed(
                    since: fileSortStart,
                    through: fileSortEnd
                ),
                folderNanoseconds: WorkspaceFileSearchDebugTiming.elapsed(
                    since: folderSortStart,
                    through: folderSortEnd
                ),
                fileInputCount: filteredFiles.count,
                folderInputCount: filteredFolders.count
            )
            let materializationStart = WorkspaceFileSearchDebugTiming.now()
            let entries = files.compactMap { file -> WorkspaceSearchCatalogEntry? in
                guard let root = rootsByID[file.rootID] else { return nil }
                return WorkspaceSearchCatalogEntry(file: file, root: root)
            }
            let materializationEnd = WorkspaceFileSearchDebugTiming.now()
            WorkspaceFileSearchDebugContext.catalogBuildObserver?.recordMaterialization(
                nanoseconds: WorkspaceFileSearchDebugTiming.elapsed(
                    since: materializationStart,
                    through: materializationEnd
                )
            )
        #else
            let files = filesByID.values
                .filter { allowedRootIDs.contains($0.rootID) && isDiscoverableFileID($0.id) }
                .sorted(by: filePrecedes)
            let folders = foldersByID.values
                .filter { allowedRootIDs.contains($0.rootID) && isDiscoverableFolderID($0.id) }
                .sorted(by: Self.searchCatalogFolderPrecedes)
            let entries = files.compactMap { file -> WorkspaceSearchCatalogEntry? in
                guard let root = rootsByID[file.rootID] else { return nil }
                return WorkspaceSearchCatalogEntry(file: file, root: root)
            }
        #endif
        return AuthoritativeCatalogComponents(files: files, folders: folders, entries: entries)
    }

    /// Builds the publication payload for a hidden root without consulting any
    /// globally visible store map. This is the catalog half of the 8D atomic
    /// root publication invariant.
    private func buildPendingCatalogComponents(
        root: WorkspaceRootRecord,
        indexes: RootIndexBuffers
    ) -> AuthoritativeCatalogComponents {
        let files = indexes.filesByID.values.sorted(by: Self.searchRootCatalogFilePrecedes)
        let folders = indexes.foldersByID.values.sorted(by: Self.searchCatalogFolderPrecedes)
        let entries = files.map { WorkspaceSearchCatalogEntry(file: $0, root: root) }
        return AuthoritativeCatalogComponents(files: files, folders: folders, entries: entries)
    }

    private func buildAuthoritativeSearchCatalogSnapshot(
        rootScope: WorkspaceLookupRootScope,
        generation: UInt64,
        roots: [WorkspaceRootRecord],
        requirement: WorkspaceSearchCatalogAccessRequirement
    ) -> WorkspaceSearchCatalogSnapshot {
        let components = buildAuthoritativeCatalogComponents(roots: roots)
        let diagnostics = WorkspaceCatalogDiagnostics(
            generation: generation,
            rootScope: rootScope,
            rootCount: roots.count,
            folderCount: components.folders.count,
            fileCount: components.files.count
        )
        let rootPathIndexes = requirement.requiresPathIndexes
            ? buildAuthoritativeRootPathIndexes(roots: roots, entries: components.entries)
            : []
        precondition(!requirement.requiresPathIndexes || rootPathIndexes.count == roots.count)
        return WorkspaceSearchCatalogSnapshot(
            generation: generation,
            rootScope: rootScope,
            roots: roots,
            files: components.files,
            entries: components.entries,
            rootPathIndexes: rootPathIndexes,
            diagnostics: diagnostics
        )
    }

    private func buildAuthoritativeRootPathIndexes(
        roots: [WorkspaceRootRecord],
        entries: [WorkspaceSearchCatalogEntry]
    ) -> [WorkspaceSearchRootPathIndex] {
        #if DEBUG
            let keyStart = WorkspaceFileSearchDebugTiming.now()
        #endif
        let entriesByRootID = Dictionary(grouping: entries, by: \.rootID)
        #if DEBUG
            WorkspaceFileSearchDebugContext.catalogBuildObserver?.recordPathIndexKey(
                nanoseconds: WorkspaceFileSearchDebugTiming.elapsed(
                    since: keyStart,
                    through: WorkspaceFileSearchDebugTiming.now()
                )
            )
            let constructionStart = WorkspaceFileSearchDebugTiming.now()
        #endif
        let indexes: [WorkspaceSearchRootPathIndex] = roots.compactMap { root in
            guard let state = rootStatesByID[root.id] else { return nil }
            let rootEntries = entriesByRootID[root.id] ?? []
            let identity = WorkspaceSearchRootPathIndexIdentity(
                rootID: root.id,
                lifetimeID: state.lifetimeID,
                topologyGeneration: catalogGenerationsByRootID[root.id] ?? 0
            )
            let shadowControl = rootCatalogShardKey(for: root).flatMap {
                rootSeedSearchShadowControl(key: $0, root: root)
            }
            return WorkspaceSearchRootPathIndex(
                identity: identity,
                rootPath: root.standardizedFullPath,
                entries: rootEntries,
                shadowControl: shadowControl
            )
        }
        #if DEBUG
            WorkspaceFileSearchDebugContext.catalogBuildObserver?.recordPathIndexConstruction(
                nanoseconds: WorkspaceFileSearchDebugTiming.elapsed(
                    since: constructionStart,
                    through: WorkspaceFileSearchDebugTiming.now()
                )
            )
        #endif
        return indexes
    }

    private func composeSearchCatalogSnapshot(
        rootScope: WorkspaceLookupRootScope,
        generation: UInt64,
        roots: [WorkspaceRootRecord],
        shards: [RootCatalogShard],
        requirement: WorkspaceSearchCatalogAccessRequirement
    ) -> WorkspaceSearchCatalogSnapshot {
        let merged: (files: [WorkspaceFileRecord], entries: [WorkspaceSearchCatalogEntry])
        if let shard = shards.first, shards.count == 1 {
            merged = (shard.files, shard.entries)
            #if DEBUG
                rootCatalogShardSingleShardCompositionReuseCount += 1
            #endif
        } else {
            merged = mergeRootCatalogShards(shards)
            #if DEBUG
                rootCatalogShardGenericMergeElementVisitCount += merged.files.count
            #endif
        }
        let diagnostics = WorkspaceCatalogDiagnostics(
            generation: generation,
            rootScope: rootScope,
            rootCount: roots.count,
            folderCount: shards.reduce(0) { $0 + $1.folderCount },
            fileCount: merged.files.count
        )
        let rootPathIndexes: [WorkspaceSearchRootPathIndex] = if requirement.requiresPathIndexes {
            shards.map { shard in
                guard let pathSearchIndex = shard.pathSearchIndex else {
                    preconditionFailure("Indexed catalog composition requires one path index per root")
                }
                return pathSearchIndex
            }
        } else {
            []
        }
        return WorkspaceSearchCatalogSnapshot(
            generation: generation,
            rootScope: rootScope,
            roots: roots,
            files: merged.files,
            entries: merged.entries,
            rootPathIndexes: rootPathIndexes,
            diagnostics: diagnostics,
            generationLease: WorkspaceSearchCatalogGenerationLease(
                retaining: shards.map { $0 as AnyObject }
            )
        )
    }

    private func mergeRootCatalogShards(
        _ shards: [RootCatalogShard]
    ) -> (files: [WorkspaceFileRecord], entries: [WorkspaceSearchCatalogEntry]) {
        let totalFileCount = shards.reduce(0) { $0 + $1.files.count }
        var files: [WorkspaceFileRecord] = []
        var entries: [WorkspaceSearchCatalogEntry] = []
        files.reserveCapacity(totalFileCount)
        entries.reserveCapacity(totalFileCount)
        var heap: [RootCatalogMergeCursor] = []
        heap.reserveCapacity(shards.count)

        func cursorPrecedes(_ lhs: RootCatalogMergeCursor, _ rhs: RootCatalogMergeCursor) -> Bool {
            let lhsFile = shards[lhs.shardIndex].files[lhs.elementIndex]
            let rhsFile = shards[rhs.shardIndex].files[rhs.elementIndex]
            if Self.searchCatalogFilePrecedes(lhsFile, rhsFile) { return true }
            if Self.searchCatalogFilePrecedes(rhsFile, lhsFile) { return false }
            if lhs.shardIndex == rhs.shardIndex { return lhs.elementIndex < rhs.elementIndex }
            return lhs.shardIndex < rhs.shardIndex
        }

        func push(_ cursor: RootCatalogMergeCursor) {
            heap.append(cursor)
            var index = heap.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard cursorPrecedes(heap[index], heap[parent]) else { break }
                heap.swapAt(index, parent)
                index = parent
            }
        }

        func pop() -> RootCatalogMergeCursor? {
            guard !heap.isEmpty else { return nil }
            if heap.count == 1 { return heap.removeLast() }
            let first = heap[0]
            heap[0] = heap.removeLast()
            var index = 0
            while true {
                let left = index * 2 + 1
                guard left < heap.count else { break }
                let right = left + 1
                let next = right < heap.count && cursorPrecedes(heap[right], heap[left]) ? right : left
                guard cursorPrecedes(heap[next], heap[index]) else { break }
                heap.swapAt(index, next)
                index = next
            }
            return first
        }

        for shardIndex in shards.indices where !shards[shardIndex].files.isEmpty {
            push(RootCatalogMergeCursor(shardIndex: shardIndex, elementIndex: 0))
        }
        while let cursor = pop() {
            let shard = shards[cursor.shardIndex]
            files.append(shard.files[cursor.elementIndex])
            entries.append(shard.entries[cursor.elementIndex])
            let nextElementIndex = cursor.elementIndex + 1
            if nextElementIndex < shard.files.count {
                push(RootCatalogMergeCursor(shardIndex: cursor.shardIndex, elementIndex: nextElementIndex))
            }
        }
        return (files, entries)
    }

    static func compareUTF8Binary(_ lhs: String, _ rhs: String) -> ComparisonResult {
        var lhsIterator = lhs.utf8.makeIterator()
        var rhsIterator = rhs.utf8.makeIterator()
        while true {
            switch (lhsIterator.next(), rhsIterator.next()) {
            case let (lhsByte?, rhsByte?):
                if lhsByte < rhsByte { return .orderedAscending }
                if lhsByte > rhsByte { return .orderedDescending }
            case (nil, nil):
                return .orderedSame
            case (nil, _?):
                return .orderedAscending
            case (_?, nil):
                return .orderedDescending
            }
        }
    }

    private static func searchCatalogFilePrecedes(_ lhs: WorkspaceFileRecord, _ rhs: WorkspaceFileRecord) -> Bool {
        searchCatalogFilePrecedes(
            lhsPath: lhs.standardizedFullPath,
            lhsID: lhs.id,
            rhsPath: rhs.standardizedFullPath,
            rhsID: rhs.id
        )
    }

    private static func searchRootCatalogFilePrecedes(
        _ lhs: WorkspaceFileRecord,
        _ rhs: WorkspaceFileRecord
    ) -> Bool {
        searchCatalogFilePrecedes(
            lhsPath: lhs.standardizedRelativePath,
            lhsID: lhs.id,
            rhsPath: rhs.standardizedRelativePath,
            rhsID: rhs.id
        )
    }

    static func searchCatalogEntryPrecedes(
        _ lhs: WorkspaceSearchCatalogEntry,
        _ rhs: WorkspaceSearchCatalogEntry
    ) -> Bool {
        searchCatalogFilePrecedes(
            lhsPath: lhs.standardizedFullPath,
            lhsID: lhs.id,
            rhsPath: rhs.standardizedFullPath,
            rhsID: rhs.id
        )
    }

    private static func searchCatalogFilePrecedes(
        lhsPath: String,
        lhsID: UUID,
        rhsPath: String,
        rhsID: UUID
    ) -> Bool {
        switch compareUTF8Binary(lhsPath, rhsPath) {
        case .orderedAscending:
            true
        case .orderedDescending:
            false
        case .orderedSame:
            compareUTF8Binary(lhsID.uuidString, rhsID.uuidString) == .orderedAscending
        }
    }

    private static func searchCatalogFolderPrecedes(_ lhs: WorkspaceFolderRecord, _ rhs: WorkspaceFolderRecord) -> Bool {
        if lhs.standardizedFullPath == rhs.standardizedFullPath {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.standardizedFullPath < rhs.standardizedFullPath
    }

    #if DEBUG
        private func recordRootCatalogShardShadowComparison(matched: Bool, byteCount: Int) {
            rootCatalogShardShadowComparisonCount += 1
            rootCatalogShardLastShadowByteCount = byteCount
            if !matched {
                rootCatalogShardShadowMismatchCount += 1
            }
        }

        private func catalogShadowBytes(_ snapshot: WorkspaceSearchCatalogSnapshot) -> Data {
            let null = NSNull()
            let roots: [[String: Any]] = snapshot.roots.map { root in
                [
                    "id": root.id.uuidString,
                    "name": root.name,
                    "full_path": root.fullPath,
                    "standardized_full_path": root.standardizedFullPath,
                    "is_system_root": root.isSystemRoot,
                    "kind": Self.rootKindDiagnosticLabel(root.kind)
                ]
            }
            let files: [[String: Any]] = snapshot.files.map { file in
                [
                    "id": file.id.uuidString,
                    "root_id": file.rootID.uuidString,
                    "name": file.name,
                    "relative_path": file.relativePath,
                    "standardized_relative_path": file.standardizedRelativePath,
                    "full_path": file.fullPath,
                    "standardized_full_path": file.standardizedFullPath,
                    "parent_folder_id": file.parentFolderID.map { $0.uuidString as Any } ?? null,
                    "modification_date_bits": file.modificationDate.map {
                        String($0.timeIntervalSinceReferenceDate.bitPattern) as Any
                    } ?? null
                ]
            }
            let entries: [[String: Any]] = snapshot.entries.map { entry in
                [
                    "id": entry.id.uuidString,
                    "root_id": entry.rootID.uuidString,
                    "root_path": entry.rootPath,
                    "root_name": entry.rootName,
                    "name": entry.name,
                    "relative_path": entry.relativePath,
                    "standardized_relative_path": entry.standardizedRelativePath,
                    "full_path": entry.fullPath,
                    "standardized_full_path": entry.standardizedFullPath,
                    "display_path": entry.displayPath
                ]
            }
            let object: [String: Any] = [
                "generation": String(snapshot.generation),
                "root_scope": Self.scopeDiagnosticLabel(snapshot.rootScope),
                "roots": roots,
                "files": files,
                "entries": entries,
                "diagnostics": [
                    "generation": String(snapshot.diagnostics.generation),
                    "root_scope": Self.scopeDiagnosticLabel(snapshot.diagnostics.rootScope),
                    "root_count": snapshot.diagnostics.rootCount,
                    "folder_count": snapshot.diagnostics.folderCount,
                    "file_count": snapshot.diagnostics.fileCount,
                    "total_item_count": snapshot.diagnostics.totalItemCount
                ]
            ]
            return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
    #endif

    func directFolderChildren(
        rootID: UUID,
        relativePath: String = ""
    ) -> WorkspaceDirectFolderChildrenSnapshot? {
        guard let state = rootStatesByID[rootID] else { return nil }
        let key = StandardizedPath.relative(relativePath)
        guard let folderID = state.folderIDsByRelativePath[key] else { return nil }
        return directFolderChildren(folderID: folderID)
    }

    func directFolderChildren(folderID: UUID) -> WorkspaceDirectFolderChildrenSnapshot? {
        guard isDiscoverableFolderID(folderID),
              let folder = foldersByID[folderID],
              let state = rootStatesByID[folder.rootID]
        else { return nil }
        let childFolders = (state.childFolderIDsByFolderID[folderID] ?? [])
            .filter(isDiscoverableFolderID)
            .compactMap { foldersByID[$0] }
            .sorted(by: compareDirectChildFolders)
        let childFiles = (state.childFileIDsByFolderID[folderID] ?? [])
            .filter(isDiscoverableFileID)
            .compactMap { filesByID[$0] }
            .sorted(by: compareDirectChildFiles)
        return WorkspaceDirectFolderChildrenSnapshot(
            generation: scopedSnapshotGeneration(scope: .allLoaded),
            root: state.root,
            folder: folder,
            childFolders: childFolders,
            childFiles: childFiles
        )
    }

    private func compareDirectChildFolders(_ lhs: WorkspaceFolderRecord, _ rhs: WorkspaceFolderRecord) -> Bool {
        if lhs.name != rhs.name {
            return lhs.name.utf8.lexicographicallyPrecedes(rhs.name.utf8)
        }
        if lhs.standardizedRelativePath != rhs.standardizedRelativePath {
            return lhs.standardizedRelativePath.utf8.lexicographicallyPrecedes(rhs.standardizedRelativePath.utf8)
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func compareDirectChildFiles(_ lhs: WorkspaceFileRecord, _ rhs: WorkspaceFileRecord) -> Bool {
        if lhs.name != rhs.name {
            return lhs.name.utf8.lexicographicallyPrecedes(rhs.name.utf8)
        }
        if lhs.standardizedRelativePath != rhs.standardizedRelativePath {
            return lhs.standardizedRelativePath.utf8.lexicographicallyPrecedes(rhs.standardizedRelativePath.utf8)
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    @discardableResult
    func warmPathLookupIndexes(rootScope: WorkspaceLookupRootScope = .visibleWorkspace) async -> UInt64 {
        while true {
            let staticData = buildStaticSnapshot(scope: rootScope)
            let warmedGeneration = await pathMatchWorker.prepare(staticData: staticData)
            let currentGeneration = scopedSnapshotGeneration(scope: rootScope)
            if warmedGeneration == currentGeneration || Task.isCancelled {
                return warmedGeneration
            }
        }
    }

    /// Awaits callback payloads accepted before the captured cut through canonical store application.
    ///
    /// FSEvents not yet delivered by macOS remain outside this contract. Later accepted callbacks
    /// may join the same actor-visible batch or overflow sentinel, so the captured watcher cut is a
    /// lower bound rather than a strict exclusion boundary. Synthetic publications are ordered with
    /// watcher publications and included in the downstream service-publication cut, but they do not
    /// advance watcher-accepted watermarks.
    func awaitAppliedIngressForAllRoots() async -> [WorkspaceIngressBarrierSample] {
        await awaitAppliedIngress(rootIDs: rootLoadOrder)
    }

    /// Awaits freshness only for roots represented by `rootScope`.
    /// Concurrent requests for the same root share a watermark-keyed flight when the
    /// existing flight covers both the callback-accepted and publisher-accepted cuts.
    func awaitAppliedIngress(rootScope: WorkspaceLookupRootScope) async -> [WorkspaceIngressBarrierSample] {
        await awaitAppliedIngress(rootIDs: rootsForPathLookup(scope: rootScope).map(\.id))
    }

    func awaitAppliedIngress(rootRefs: [WorkspaceRootRef]) async -> [WorkspaceIngressBarrierSample] {
        await awaitAppliedIngress(rootIDs: rootRefs.map(\.id))
    }

    func contentSearchFreshnessPolicy(
        rootScope: WorkspaceLookupRootScope,
        appliedIngressSamples: [WorkspaceIngressBarrierSample]
    ) async -> FileContentFreshnessPolicy {
        await contentSearchFreshnessPolicy(
            rootRefs: rootRefs(scope: rootScope),
            appliedIngressSamples: appliedIngressSamples
        )
    }

    func contentSearchFreshnessPolicy(
        rootRefs: [WorkspaceRootRef],
        appliedIngressSamples: [WorkspaceIngressBarrierSample]
    ) async -> FileContentFreshnessPolicy {
        guard !rootRefs.isEmpty,
              appliedIngressSamples.count == rootRefs.count
        else {
            return .validateDiskMetadata
        }
        let samplesByRootID = Dictionary(uniqueKeysWithValues: appliedIngressSamples.map { ($0.rootID, $0) })
        for root in rootRefs {
            guard let state = rootStatesByID[root.id],
                  let sample = samplesByRootID[root.id],
                  await state.service.canUseCachedSearchContent(
                      afterAppliedWatcherWatermark: sample.appliedWatcherWatermark
                  ),
                  publisherIngressCoordinator.appliedSnapshot(rootID: root.id)
                  .acceptedServicePublicationSequence <= sample.appliedServicePublicationSequence
            else {
                return .validateDiskMetadata
            }
        }
        return .cachedMetadata
    }

    /// Resolves the narrowest safe workspace freshness scope for an explicit request.
    /// Absolute paths await only their containing loaded root. Absolute paths outside all
    /// loaded roots (including always-readable support files) do not pay a workspace barrier.
    /// Relative and alias-shaped paths await the caller's fallback scope because resolution
    /// may depend on more than one candidate root.
    func awaitAppliedIngressForExplicitRequest(
        userPath: String,
        fallbackScope: WorkspaceLookupRootScope
    ) async -> [WorkspaceIngressBarrierSample] {
        await awaitAppliedIngressForExplicitRequest(
            userPath: userPath,
            fallbackRootRefs: rootRefs(scope: fallbackScope)
        )
    }

    func awaitAppliedIngressForExplicitRequest(
        userPath: String,
        fallbackRootRefs: [WorkspaceRootRef]
    ) async -> [WorkspaceIngressBarrierSample] {
        let trimmed = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        guard standardized.hasPrefix("/") else {
            return await awaitAppliedIngress(rootIDs: fallbackRootRefs.map(\.id))
        }
        let containingRootID = fallbackRootRefs
            .filter { StandardizedPath.isDescendant(standardized, of: $0.standardizedFullPath) }
            .max { $0.standardizedFullPath.count < $1.standardizedFullPath.count }?
            .id
        guard let containingRootID else { return [] }
        return await awaitAppliedIngress(rootIDs: [containingRootID])
    }

    private func awaitAppliedIngress(rootIDs: [UUID]) async -> [WorkspaceIngressBarrierSample] {
        let orderedRootIDs = rootIDs.reduce(into: [UUID]()) { result, rootID in
            guard rootStatesByID[rootID] != nil, !result.contains(rootID) else { return }
            result.append(rootID)
        }
        guard !orderedRootIDs.isEmpty else { return [] }

        let targetsByRootID = Dictionary(uniqueKeysWithValues: orderedRootIDs.compactMap { rootID in
            rootStatesByID[rootID].map { state in
                (
                    rootID,
                    ScopedIngressBarrierTarget(
                        watcherAcceptedWatermark: state.service.captureAcceptedWatcherWatermark(),
                        acceptedServicePublicationSequence: publisherIngressCoordinator.appliedSnapshot(rootID: rootID)
                            .acceptedServicePublicationSequence
                    )
                )
            }
        })

        #if DEBUG
            if let appliedIngressDidCaptureWatermarksHandler {
                await appliedIngressDidCaptureWatermarksHandler(targetsByRootID.mapValues { $0.watcherAcceptedWatermark.rawValue })
            }
        #endif

        var samplesByIndex: [Int: WorkspaceIngressBarrierSample] = [:]
        for chunkStart in stride(from: 0, to: orderedRootIDs.count, by: Self.maxConcurrentScopedIngressBarriers) {
            guard !Task.isCancelled else { break }
            let chunkEnd = min(chunkStart + Self.maxConcurrentScopedIngressBarriers, orderedRootIDs.count)
            await withTaskGroup(of: (Int, WorkspaceIngressBarrierSample?).self) { group in
                for index in chunkStart ..< chunkEnd {
                    let rootID = orderedRootIDs[index]
                    guard let target = targetsByRootID[rootID] else { continue }
                    group.addTask { [weak self] in
                        guard !Task.isCancelled, let self else { return (index, nil) }
                        guard await (try? requirePublishedSeededAuthorityFresh(rootID: rootID)) != nil else {
                            return (index, nil)
                        }
                        let sample = await awaitAppliedIngress(rootID: rootID, target: target)
                        guard await (try? requirePublishedSeededAuthorityFresh(rootID: rootID)) != nil else {
                            return (index, nil)
                        }
                        return (index, sample)
                    }
                }
                for await (index, sample) in group {
                    if let sample { samplesByIndex[index] = sample }
                }
            }
        }
        return samplesByIndex.keys.sorted().compactMap { samplesByIndex[$0] }
    }

    private func awaitAppliedIngress(
        rootID: UUID,
        target: ScopedIngressBarrierTarget
    ) async -> WorkspaceIngressBarrierSample? {
        guard !Task.isCancelled, let state = rootStatesByID[rootID] else { return nil }
        if completedScopedIngressBarrierCutsByRootID[rootID] != nil {
            let applied = publisherIngressCoordinator.appliedSnapshot(rootID: rootID)
            if applied.appliedWatcherWatermark >= target.watcherAcceptedWatermark,
               applied.appliedServicePublicationSequence >= target.acceptedServicePublicationSequence
            {
                #if DEBUG
                    scopedIngressBarrierNoopCountsByRootID[rootID, default: 0] += 1
                #endif
                return WorkspaceIngressBarrierSample(
                    rootID: rootID,
                    rootPath: state.root.standardizedFullPath,
                    pendingRawEventCountBeforeFlush: 0,
                    acceptedWatcherWatermark: target.watcherAcceptedWatermark.rawValue,
                    publishedServicePublicationSequence: target.acceptedServicePublicationSequence,
                    appliedServicePublicationSequence: applied.appliedServicePublicationSequence,
                    appliedWatcherWatermark: applied.appliedWatcherWatermark.rawValue
                )
            }
        }
        let flightState = scopedIngressBarrierFlightStatesByRootID[rootID]
            ?? ScopedIngressBarrierRootFlightState()

        if let active = flightState.active, active.target.covers(target) {
            #if DEBUG
                scopedIngressBarrierJoinCountsByRootID[rootID, default: 0] += 1
            #endif
            guard let output = await active.join.value() else { return nil }
            return scopedIngressBarrierSample(from: output)
        }

        if let pending = flightState.pending, pending.target.covers(target) {
            #if DEBUG
                scopedIngressBarrierJoinCountsByRootID[rootID, default: 0] += 1
                scopedIngressBarrierCoalescedSuccessorCountsByRootID[rootID, default: 0] += 1
            #endif
            guard let output = await pending.join.value() else { return nil }
            return scopedIngressBarrierSample(from: output)
        }

        if let pending = flightState.pending {
            pending.target = pending.target.merging(target)
            #if DEBUG
                scopedIngressBarrierJoinCountsByRootID[rootID, default: 0] += 1
                scopedIngressBarrierCoalescedSuccessorCountsByRootID[rootID, default: 0] += 1
            #endif
            guard let output = await pending.join.value() else { return nil }
            return scopedIngressBarrierSample(from: output)
        }

        if flightState.active != nil {
            let join = ScopedIngressBarrierJoin()
            #if DEBUG
                let enqueuedAtNanoseconds = debugNowNanoseconds()
                scopedIngressBarrierSuccessorCountsByRootID[rootID, default: 0] += 1
            #else
                let enqueuedAtNanoseconds: UInt64 = 0
            #endif
            flightState.pending = ScopedIngressBarrierPendingFlight(
                target: target,
                join: join,
                enqueuedAtNanoseconds: enqueuedAtNanoseconds
            )
            scopedIngressBarrierFlightStatesByRootID[rootID] = flightState
            guard let output = await join.value() else { return nil }
            return scopedIngressBarrierSample(from: output)
        }

        let join = ScopedIngressBarrierJoin()
        launchScopedIngressBarrier(
            rootID: rootID,
            target: target,
            join: join,
            flightState: flightState
        )
        guard let output = await join.value() else { return nil }
        return scopedIngressBarrierSample(from: output)
    }

    private func launchScopedIngressBarrier(
        rootID: UUID,
        target: ScopedIngressBarrierTarget,
        join: ScopedIngressBarrierJoin,
        flightState: ScopedIngressBarrierRootFlightState
    ) {
        guard let state = rootStatesByID[rootID] else {
            join.complete(with: nil)
            return
        }
        nextScopedIngressBarrierToken &+= 1
        let token = nextScopedIngressBarrierToken
        let publisherIngressCoordinator = publisherIngressCoordinator
        let root = state.root
        let service = state.service
        #if DEBUG
            scopedIngressBarrierLaunchCountsByRootID[rootID, default: 0] += 1
            let barrierCompletionNowNanoseconds = debugNowNanoseconds
            let barrierStartedAtNanoseconds = barrierCompletionNowNanoseconds()
            let scopedIngressBarrierWillFlushHandler = scopedIngressBarrierWillFlushHandler
            let publisherIngressWillWaitHandler = publisherIngressWillWaitHandler
        #else
            let barrierStartedAtNanoseconds: UInt64 = 0
        #endif
        #if DEBUG || EDIT_FLOW_PERF
            let lifecycleCorrelation = EditFlowPerf.currentLifecycleCorrelation
        #else
            let lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation? = nil
        #endif
        let flight = ScopedIngressBarrierFlight(
            token: token,
            target: target,
            join: join,
            startedAtNanoseconds: barrierStartedAtNanoseconds
        )
        flightState.active = flight
        scopedIngressBarrierFlightStatesByRootID[rootID] = flightState
        flight.task = Task { [weak self] in
            #if DEBUG
                if let scopedIngressBarrierWillFlushHandler {
                    await scopedIngressBarrierWillFlushHandler(rootID)
                }
            #endif
            guard !Task.isCancelled else {
                if let self {
                    await finishScopedIngressBarrier(
                        rootID: rootID,
                        token: token,
                        target: target,
                        output: nil,
                        startedAtNanoseconds: barrierStartedAtNanoseconds,
                        join: join
                    )
                } else {
                    join.complete(with: nil)
                }
                return
            }
            #if DEBUG
                let pendingCount = await service.pendingRawEventCountForDiagnostics()
            #else
                let pendingCount = 0
            #endif
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.WorkspaceIngress.rootFlushBegan,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(
                    pendingRawEventCount: pendingCount,
                    rootToken: service.diagnosticRootToken.uuidString,
                    ingressSequence: target.watcherAcceptedWatermark.rawValue
                )
            )
            #if DEBUG
                if target.acceptedServicePublicationSequence > publisherIngressCoordinator.appliedSnapshot(rootID: rootID).appliedServicePublicationSequence,
                   let publisherIngressWillWaitHandler
                {
                    await publisherIngressWillWaitHandler([rootID])
                }
            #endif
            guard !Task.isCancelled else {
                if let self {
                    await finishScopedIngressBarrier(
                        rootID: rootID,
                        token: token,
                        target: target,
                        output: nil,
                        startedAtNanoseconds: barrierStartedAtNanoseconds,
                        join: join
                    )
                } else {
                    join.complete(with: nil)
                }
                return
            }
            await publisherIngressCoordinator.waitUntilApplied(
                rootID: rootID,
                servicePublicationSequence: target.acceptedServicePublicationSequence
            )
            guard !Task.isCancelled else {
                if let self {
                    await finishScopedIngressBarrier(
                        rootID: rootID,
                        token: token,
                        target: target,
                        output: nil,
                        startedAtNanoseconds: barrierStartedAtNanoseconds,
                        join: join
                    )
                } else {
                    join.complete(with: nil)
                }
                return
            }
            let publishedSequence = await service.flushPendingEventsNow(
                throughAcceptedWatcherWatermark: target.watcherAcceptedWatermark
            )
            guard !Task.isCancelled else {
                if let self {
                    await finishScopedIngressBarrier(
                        rootID: rootID,
                        token: token,
                        target: target,
                        output: nil,
                        startedAtNanoseconds: barrierStartedAtNanoseconds,
                        join: join
                    )
                } else {
                    join.complete(with: nil)
                }
                return
            }
            let acceptedDownstreamCut = publisherIngressCoordinator.appliedSnapshot(rootID: rootID)
                .acceptedServicePublicationSequence
            await publisherIngressCoordinator.waitUntilApplied(
                rootID: rootID,
                servicePublicationSequence: max(target.acceptedServicePublicationSequence, acceptedDownstreamCut)
            )
            guard !Task.isCancelled else {
                if let self {
                    await finishScopedIngressBarrier(
                        rootID: rootID,
                        token: token,
                        target: target,
                        output: nil,
                        startedAtNanoseconds: barrierStartedAtNanoseconds,
                        join: join
                    )
                } else {
                    join.complete(with: nil)
                }
                return
            }
            let applied = publisherIngressCoordinator.appliedSnapshot(rootID: rootID)
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.WorkspaceIngress.rootFlushEnded,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(
                    pendingRawEventCount: pendingCount,
                    rootToken: service.diagnosticRootToken.uuidString,
                    ingressSequence: applied.appliedWatcherWatermark.rawValue,
                    barrierSequence: applied.appliedServicePublicationSequence
                )
            )
            let sample = WorkspaceIngressBarrierSample(
                rootID: rootID,
                rootPath: root.standardizedFullPath,
                pendingRawEventCountBeforeFlush: pendingCount,
                acceptedWatcherWatermark: target.watcherAcceptedWatermark.rawValue,
                publishedServicePublicationSequence: publishedSequence,
                appliedServicePublicationSequence: applied.appliedServicePublicationSequence,
                appliedWatcherWatermark: applied.appliedWatcherWatermark.rawValue
            )
            #if DEBUG
                let output = ScopedIngressBarrierTaskOutput(
                    sample: sample,
                    completedAtNanoseconds: barrierCompletionNowNanoseconds()
                )
            #else
                let output = sample
            #endif
            if let self {
                await finishScopedIngressBarrier(
                    rootID: rootID,
                    token: token,
                    target: target,
                    output: output,
                    startedAtNanoseconds: barrierStartedAtNanoseconds,
                    join: join
                )
            } else {
                join.complete(with: output)
            }
        }
    }

    private func finishScopedIngressBarrier(
        rootID: UUID,
        token: UInt64,
        target: ScopedIngressBarrierTarget,
        output: ScopedIngressBarrierTaskOutput?,
        startedAtNanoseconds: UInt64,
        join: ScopedIngressBarrierJoin
    ) {
        guard let flightState = scopedIngressBarrierFlightStatesByRootID[rootID],
              flightState.active?.token == token
        else {
            join.complete(with: output)
            return
        }
        flightState.active = nil
        if let output {
            completedScopedIngressBarrierCutsByRootID[rootID] = ScopedIngressBarrierCompletedCut(
                target: target,
                sample: scopedIngressBarrierSample(from: output)
            )
        }
        #if DEBUG
            if let output {
                recordScopedIngressBarrierCompletion(
                    rootID: rootID,
                    token: token,
                    target: target,
                    sample: output.sample,
                    startedAtNanoseconds: startedAtNanoseconds,
                    completedAtNanoseconds: output.completedAtNanoseconds
                )
            }
        #endif

        if let output, let pending = flightState.pending {
            flightState.pending = nil
            launchScopedIngressBarrier(
                rootID: rootID,
                target: pending.target,
                join: pending.join,
                flightState: flightState
            )
            join.complete(with: output)
            return
        }

        let pending = flightState.pending
        flightState.pending = nil
        scopedIngressBarrierFlightStatesByRootID.removeValue(forKey: rootID)
        if output == nil {
            pending?.join.complete(with: nil)
        }
        join.complete(with: output)
    }

    private func scopedIngressBarrierSample(
        from output: ScopedIngressBarrierTaskOutput
    ) -> WorkspaceIngressBarrierSample {
        #if DEBUG
            output.sample
        #else
            output
        #endif
    }

    /// Compatibility wrapper for callers that still consume the original diagnostic shape.
    func flushPendingServiceEventsForAllRoots() async -> [(rootPath: String, pendingRawEventCountBeforeFlush: Int)] {
        await awaitAppliedIngressForAllRoots().map { sample in
            (sample.rootPath, sample.pendingRawEventCountBeforeFlush)
        }
    }

    // MARK: - Deferred replay buffer ownership

    func updateDeferredReplayRoutingState(
        isWindowFocused: Bool,
        isReplayActive: Bool,
        routingVersion: UInt64
    ) async {
        await deferredReplayBuffer.updateRoutingState(
            isWindowFocused: isWindowFocused,
            isReplayActive: isReplayActive,
            routingVersion: routingVersion
        )
    }

    func updateDeferredReplayImmediateChunkSizeOverride(_ chunkSize: Int?) async {
        await deferredReplayBuffer.updateImmediateReplayChunkSizeOverride(chunkSize)
    }

    func registerDeferredReplayRootGeneration(_ generation: UInt64, forRootKey rootKey: String) async {
        await deferredReplayBuffer.registerActiveRootGeneration(generation, forRootKey: rootKey)
    }

    func unregisterDeferredReplayRootGeneration(forRootKey rootKey: String) async {
        await deferredReplayBuffer.unregisterActiveRootGeneration(forRootKey: rootKey)
    }

    func ingestDeferredReplayLiveDeltas(
        _ deltas: [FileSystemDelta],
        forRootKey rootKey: String,
        rootGeneration: UInt64
    ) async -> DeferredReplayIngressResult {
        await deferredReplayBuffer.ingestLiveDeltas(deltas, forRootKey: rootKey, rootGeneration: rootGeneration)
    }

    func ingestDeferredReplayLiveDeltas(
        _ deltas: [FileSystemDelta],
        forRootKey rootKey: String
    ) async -> DeferredReplayIngressResult {
        await deferredReplayBuffer.ingestLiveDeltas(deltas, forRootKey: rootKey)
    }

    func finishDeferredReplayPreparedImmediateIngress(_ immediateReplay: PreparedImmediateReplay) async {
        await deferredReplayBuffer.finishPreparedImmediateIngress(immediateReplay)
    }

    func enqueueDeferredReplayDeltas(
        _ deltas: [FileSystemDelta],
        forRootKey rootKey: String
    ) async -> DeferredReplayIngressResult {
        await deferredReplayBuffer.enqueueDeferredDeltas(deltas, forRootKey: rootKey)
    }

    func drainDeferredReplayPreparedBatches(
        preferredRootOrder: [String],
        chunkSize: Int
    ) async -> [PreparedFileSystemReplayBatch] {
        await deferredReplayBuffer.drainPreparedBatches(
            preferredRootOrder: preferredRootOrder,
            chunkSize: chunkSize
        )
    }

    func clearDeferredReplayRoot(_ rootKey: String) async {
        await deferredReplayBuffer.clearRoot(rootKey)
    }

    func clearDeferredReplayBuffer() async {
        await deferredReplayBuffer.clearAll()
    }

    func hasDeferredReplayPendingWork() async -> Bool {
        await deferredReplayBuffer.hasPendingWork()
    }

    func pendingDeferredReplayDeltaCount(forRootKey rootKey: String) async -> Int {
        await deferredReplayBuffer.pendingDeltaCount(forRootKey: rootKey)
    }

    func deferredReplayPendingWorkSnapshot() async -> DeferredReplayPendingWorkSnapshot {
        await deferredReplayBuffer.pendingWorkSnapshot()
    }

    #if DEBUG
        func deferredReplayDiagnosticsSnapshot() async -> DeferredReplayBufferDiagnostics {
            await deferredReplayBuffer.diagnosticsSnapshot()
        }

        func gitignorePolicyIdentityForTesting(rootID: UUID) -> WorkspaceGitignorePolicyIdentity? {
            guard let root = rootStatesByID[rootID]?.root else { return nil }
            return rootLoadConfigurationsByPath[root.standardizedFullPath]?.gitignorePolicyIdentity
        }
    #endif

    func refreshFileSystemSettings(
        rootID: UUID,
        respectRepoIgnore: Bool,
        respectCursorignore: Bool,
        skipSymlinks: Bool,
        enableHierarchicalIgnores: Bool
    ) async throws -> Bool {
        let state = try state(for: rootID)
        try await state.service.updateRespectRepoIgnore(respectRepoIgnore)
        try await state.service.updateRespectCursorignore(respectCursorignore)
        await state.service.updateSkipSymlinks(skipSymlinks)
        await state.service.updateEnableHierarchicalIgnores(enableHierarchicalIgnores)
        try await state.service.refreshIgnoreRules()
        return await state.service.takePendingIgnoreRulesChange() != nil
    }

    @discardableResult
    func reconcileLoadedRootCatalogWithDisk(rootID: UUID) async -> [FileSystemDelta] {
        guard let state = rootStatesByID[rootID] else { return [] }
        let root = state.root
        let folderPaths = Set(
            state.folderIDsByRelativePath.compactMap { relativePath, folderID -> String? in
                isDiscoverableFolderID(folderID) ? relativePath : nil
            }
        )
        guard !folderPaths.isEmpty else { return [] }

        let deltas: [FileSystemDelta]
        do {
            deltas = try await state.service.scanFoldersInParallel(folderPaths.sorted()).deltas
        } catch {
            return []
        }
        guard !deltas.isEmpty,
              let currentRoot = rootStatesByID[rootID]?.root,
              currentRoot.standardizedFullPath == root.standardizedFullPath
        else { return deltas }

        await handleObservedFileSystemDeltas(deltas, root: root)
        return deltas
    }

    func ensureIndexedFiles(paths: [String]) async -> [String] {
        struct EligibleFile {
            let fullPath: String
            let rootID: UUID
            let rootPath: String
            let relativePath: String
        }

        var eligibleFiles: [EligibleFile] = []
        for rawPath in paths {
            let fullPath = StandardizedPath.absolute(rawPath)
            guard fileIDsByStandardizedFullPath[fullPath] == nil,
                  let root = loadedRoot(containing: fullPath),
                  let service = rootStatesByID[root.id]?.service
            else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let relativePath = relativePath(for: fullPath, rootPath: root.standardizedFullPath)
            guard !relativePath.isEmpty,
                  await service.catalogEligibleRegularFileExists(relativePath: relativePath)
            else { continue }
            #if DEBUG
                if let ensureIndexedFilesEligibilityDidResolveHandler {
                    await ensureIndexedFilesEligibilityDidResolveHandler(root.id, fullPath)
                }
            #endif
            eligibleFiles.append(EligibleFile(
                fullPath: fullPath,
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                relativePath: relativePath
            ))
        }

        var codemapFencesByRootID: [UUID: CodemapRootMutationFenceToken] = [:]
        for rootID in Set(eligibleFiles.map(\.rootID)) {
            if let fence = await beginCodemapRootMutationFence(
                rootID: rootID,
                command: .catalogAdvanced
            ) {
                codemapFencesByRootID[rootID] = fence
            }
        }
        var indexed: [String] = []
        var upsertedFilesByRoot: [UUID: [WorkspaceFileRecord]] = [:]
        defer {
            for (rootID, fence) in codemapFencesByRootID {
                finishCodemapRootMutationFence(
                    fence,
                    didCommitMutation: upsertedFilesByRoot[rootID]?.isEmpty == false
                )
            }
        }
        for eligible in eligibleFiles {
            guard codemapFencesByRootID[eligible.rootID] != nil,
                  fileIDsByStandardizedFullPath[eligible.fullPath] == nil,
                  folderIDsByStandardizedFullPath[eligible.fullPath] == nil,
                  var state = rootStatesByID[eligible.rootID],
                  state.root.id == eligible.rootID,
                  state.root.standardizedFullPath == eligible.rootPath,
                  rootIDsByStandardizedPath[eligible.rootPath] == eligible.rootID,
                  loadedRoot(containing: eligible.fullPath)?.id == eligible.rootID,
                  state.fileIDsByRelativePath[eligible.relativePath] == nil,
                  state.folderIDsByRelativePath[eligible.relativePath] == nil
            else { continue }
            var indexes = RootIndexBuffers()
            let hierarchy = eligible.relativePath.split(separator: "/").count
            indexFiles(
                [FSItemDTO(relativePath: eligible.relativePath, isDirectory: false, hierarchy: hierarchy)],
                root: state.root,
                state: &state,
                indexes: &indexes
            )
            guard !indexes.filesByID.isEmpty else { continue }
            commit(indexes)
            rootStatesByID[eligible.rootID] = state
            indexed.append(eligible.fullPath)
            upsertedFilesByRoot[eligible.rootID, default: []].append(contentsOf: indexes.filesByID.values)
        }
        if !indexed.isEmpty {
            let affectedKinds = Set(upsertedFilesByRoot.keys.compactMap { rootStatesByID[$0]?.root.kind })
            invalidatePathMatchSnapshot(
                affectedRootKinds: affectedKinds,
                reason: .explicitMaterialization,
                affectedRootIDs: Set(upsertedFilesByRoot.keys)
            )
            for (rootID, files) in upsertedFilesByRoot {
                guard let root = rootStatesByID[rootID]?.root else { continue }
                publishAppliedIndexEvent(root: root, upsertedFiles: files)
            }
        }
        return indexed
    }

    private func loadedRoot(containing fullPath: String) -> WorkspaceRootRecord? {
        rootStatesByID.values
            .map(\.root)
            .filter { fullPath == $0.standardizedFullPath || fullPath.hasPrefix($0.standardizedFullPath + "/") }
            .max { $0.standardizedFullPath.count < $1.standardizedFullPath.count }
    }

    private func relativePath(for fullPath: String, rootPath: String) -> String {
        guard fullPath != rootPath else { return "" }
        let start = fullPath.index(fullPath.startIndex, offsetBy: rootPath.count)
        let suffix = fullPath[start...]
        return StandardizedPath.relative(String(suffix).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    func makeFileTreePresentation(
        selection: StoredSelection,
        request: WorkspaceFileTreePresentationRequest,
        lookupContext: WorkspaceLookupContext,
        codemapPresentation: WorkspaceCodemapOperationPresentation,
        profile: PathLocateProfile = .uiAssisted
    ) async -> WorkspaceFileTreePresentation {
        await makeFileTreePresentation(
            selection: selection,
            request: request,
            lookupContext: lookupContext,
            renderableCodemapFileIDs: Set(codemapPresentation.renderedEntriesByFileID.keys),
            codemapCoverage: codemapPresentation.coverage,
            codemapIssues: codemapPresentation.issues,
            profile: profile
        )
    }

    /// Renders file-tree codemap markers from the actor's current ready snapshot only.
    /// This path intentionally performs no artifact demand, readiness wait, or presentation freeze.
    func makeCurrentSnapshotFileTreePresentation(
        selection: StoredSelection,
        request: WorkspaceFileTreePresentationRequest,
        lookupContext: WorkspaceLookupContext,
        profile: PathLocateProfile = .uiAssisted
    ) async -> WorkspaceFileTreePresentation {
        #if DEBUG
            let benchmarkMetricTag = WorktreeStartupInstrumentation.currentBenchmarkMetricTag
            let benchmarkStarted = DispatchTime.now().uptimeNanoseconds
            defer {
                let benchmarkFinished = DispatchTime.now().uptimeNanoseconds
                WorktreeStartupInstrumentation.recordBenchmarkPassiveTree(
                    tag: benchmarkMetricTag,
                    durationMicroseconds: (benchmarkFinished - benchmarkStarted) / 1000
                )
            }
        #endif
        let unmarkedSnapshot = await makeFileTreeSelectionSnapshot(
            selection: selection,
            request: request,
            renderableCodemapFileIDs: [],
            profile: profile
        )
        let rootDisplayNames = await lookupContext.logicalRootDisplayNamesByRootID(store: self)
        let renderableCodemapFileIDs = request.showCodeMapMarkers
            ? currentRenderableCodemapFileIDs(rootScope: request.rootScope)
            : Set<UUID>()
        let snapshot = fileTreeSnapshot(
            unmarkedSnapshot,
            renderableCodemapFileIDs: renderableCodemapFileIDs,
            showCodeMapMarkers: request.showCodeMapMarkers
        )
        let logicalSnapshot = snapshot.logicalized(
            roots: rootRefs(scope: request.rootScope),
            rootDisplayNamesByRootID: rootDisplayNames
        )
        return WorkspaceFileTreePresentation(
            content: WorkspaceFileTreePresentationRenderer.render(logicalSnapshot),
            rootCount: logicalSnapshot.roots.count,
            usesLegend: logicalSnapshot.includeLegend,
            codemapCoverage: .complete,
            codemapIssues: []
        )
    }

    private func makeFileTreePresentation(
        selection: StoredSelection,
        request: WorkspaceFileTreePresentationRequest,
        lookupContext: WorkspaceLookupContext,
        renderableCodemapFileIDs: Set<UUID>,
        codemapCoverage: WorkspaceCodemapOperationPresentationCoverage,
        codemapIssues: [WorkspaceCodemapOperationIssue],
        profile: PathLocateProfile
    ) async -> WorkspaceFileTreePresentation {
        let snapshot = await makeFileTreeSelectionSnapshot(
            selection: selection,
            request: request,
            renderableCodemapFileIDs: renderableCodemapFileIDs,
            profile: profile
        )
        let roots = rootRefs(scope: request.rootScope)
        let rootDisplayNames = await lookupContext.logicalRootDisplayNamesByRootID(store: self)
        let logicalSnapshot = snapshot.logicalized(
            roots: roots,
            rootDisplayNamesByRootID: rootDisplayNames
        )
        return WorkspaceFileTreePresentation(
            content: WorkspaceFileTreePresentationRenderer.render(logicalSnapshot),
            rootCount: logicalSnapshot.roots.count,
            usesLegend: logicalSnapshot.includeLegend,
            codemapCoverage: codemapCoverage,
            codemapIssues: codemapIssues
        )
    }

    private func currentRenderableCodemapFileIDs(
        rootScope: WorkspaceLookupRootScope
    ) -> Set<UUID> {
        var fileIDs = Set<UUID>()
        for root in rootRefs(scope: rootScope) {
            guard let state = rootStatesByID[root.id] else { continue }
            let rootEpoch = WorkspaceCodemapRootEpoch(
                rootID: root.id,
                rootLifetimeID: state.lifetimeID
            )
            guard let session = codemapSessionsByRootEpoch[rootEpoch],
                  codemapAuthorityIsCurrent(session.authority)
            else { continue }
            fileIDs.formUnion(session.markerReadinessByFileID.keys)
        }
        return fileIDs
    }

    private func fileTreeSnapshot(
        _ snapshot: FileTreeSelectionSnapshot,
        renderableCodemapFileIDs: Set<UUID>,
        showCodeMapMarkers: Bool
    ) -> FileTreeSelectionSnapshot {
        FileTreeSelectionSnapshot(
            roots: snapshot.roots.map {
                fileTreeFolderSnapshot(
                    $0,
                    renderableCodemapFileIDs: renderableCodemapFileIDs
                )
            },
            selectedFileIDs: snapshot.selectedFileIDs,
            mode: snapshot.mode,
            showFullPaths: snapshot.showFullPaths,
            onlyIncludeRootsWithSelectedFiles: snapshot.onlyIncludeRootsWithSelectedFiles,
            includeLegend: snapshot.includeLegend,
            showCodeMapMarkers: showCodeMapMarkers,
            maxDepth: snapshot.maxDepth
        )
    }

    private func fileTreeFolderSnapshot(
        _ folder: FileTreeFolderSnapshot,
        renderableCodemapFileIDs: Set<UUID>
    ) -> FileTreeFolderSnapshot {
        FileTreeFolderSnapshot(
            id: folder.id,
            name: folder.name,
            fullPath: folder.fullPath,
            standardizedFullPath: folder.standardizedFullPath,
            standardizedRootPath: folder.standardizedRootPath,
            children: folder.children.map { child in
                switch child {
                case let .folder(childFolder):
                    .folder(fileTreeFolderSnapshot(
                        childFolder,
                        renderableCodemapFileIDs: renderableCodemapFileIDs
                    ))
                case let .file(file):
                    .file(FileTreeFileSnapshot(
                        id: file.id,
                        name: file.name,
                        fileExtension: file.fileExtension,
                        hasCodeMap: renderableCodemapFileIDs.contains(file.id)
                    ))
                }
            }
        )
    }

    func makeFileTreeSelectionSnapshot(
        selection: StoredSelection,
        request: WorkspaceFileTreeSnapshotRequest,
        profile: PathLocateProfile = .uiAssisted
    ) async -> FileTreeSelectionSnapshot {
        let renderableCodemapFileIDs = Set<UUID>()
        return await makeFileTreeSelectionSnapshot(
            selection: selection,
            request: request,
            renderableCodemapFileIDs: renderableCodemapFileIDs,
            profile: profile
        )
    }

    func makeFileTreeSelectionSnapshot(
        selection: StoredSelection,
        request: WorkspaceFileTreeSnapshotRequest,
        renderableCodemapFileIDs: Set<UUID>,
        profile: PathLocateProfile = .uiAssisted
    ) async -> FileTreeSelectionSnapshot {
        var selectedStoreFileIDs = Set<UUID>()
        for path in selection.selectedPaths {
            guard let result = await lookupSelectionPath(path, profile: profile, rootScope: request.rootScope) else { continue }
            if let file = result.file {
                selectedStoreFileIDs.insert(file.id)
            }
            if let folder = result.folder,
               let state = rootStatesByID[folder.rootID]
            {
                selectedStoreFileIDs.formUnion(descendantFileIDs(in: folder.id, state: state))
            }
        }
        for (path, _) in selection.slices {
            guard let result = await lookupSelectionPath(path, profile: profile, rootScope: request.rootScope),
                  let file = result.file
            else { continue }
            selectedStoreFileIDs.insert(file.id)
        }
        return await makeFileTreeSelectionSnapshot(
            request,
            selectedStoreFileIDs: selectedStoreFileIDs,
            renderableCodemapFileIDs: renderableCodemapFileIDs,
            profile: profile
        )
    }

    private func lookupSelectionPath(
        _ userPath: String,
        profile: PathLocateProfile,
        rootScope: WorkspaceLookupRootScope
    ) async -> WorkspacePathLookupResult? {
        switch lookupCatalogFileForExplicitRequest(userPath, rootScope: rootScope) {
        case let .matched(file):
            return lookupPath(rootID: file.rootID, relativePath: file.standardizedRelativePath)
        case .ambiguous, .blocked:
            return nil
        case .noCandidate:
            break
        }
        switch try? await materializeExplicitlyRequestedFile(userPath, rootScope: rootScope) {
        case let .some(.materialized(file)):
            return lookupPath(rootID: file.rootID, relativePath: file.standardizedRelativePath)
        case .some(.ambiguous), .some(.blocked):
            return nil
        case .some(.noCandidate), .none:
            break
        }
        if let direct = directAbsoluteLookup(userPath, rootScope: rootScope), isDiscoverableLookupResult(direct) {
            return direct
        }
        if let direct = directUnambiguousRelativeLookup(userPath, rootScope: rootScope), isDiscoverableLookupResult(direct) {
            return direct
        }
        return await lookupPath(userPath, profile: profile, rootScope: rootScope)
    }

    private func directAbsoluteLookup(_ userPath: String, rootScope: WorkspaceLookupRootScope) -> WorkspacePathLookupResult? {
        let expanded = (userPath as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        let standardizedPath = StandardizedPath.absolute(expanded)
        guard let root = rootsForPathLookup(scope: rootScope)
            .filter({ candidate in
                standardizedPath == candidate.standardizedFullPath
                    || standardizedPath.hasPrefix(candidate.standardizedFullPath + "/")
            })
            .max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count })
        else { return nil }
        let relativePath = relativePath(for: standardizedPath, rootPath: root.standardizedFullPath)
        return lookupPath(rootID: root.id, relativePath: relativePath)
    }

    private func directUnambiguousRelativeLookup(_ userPath: String, rootScope: WorkspaceLookupRootScope) -> WorkspacePathLookupResult? {
        let expanded = (userPath as NSString).expandingTildeInPath
        guard !expanded.hasPrefix("/") else { return nil }
        let relativePath = StandardizedPath.relative(expanded)
        guard !relativePath.isEmpty else { return nil }
        let matches = rootsForPathLookup(scope: rootScope).compactMap { root in
            lookupPath(rootID: root.id, relativePath: relativePath)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func isDiscoverableLookupResult(_ result: WorkspacePathLookupResult) -> Bool {
        if let file = result.file, !isDiscoverableFileID(file.id) { return false }
        if let folder = result.folder, !isDiscoverableFolderID(folder.id) { return false }
        return true
    }

    private func descendantFileIDs(in folderID: UUID, state: RootState) -> Set<UUID> {
        var fileIDs = Set((state.childFileIDsByFolderID[folderID] ?? []).filter(isDiscoverableFileID))
        for childFolderID in (state.childFolderIDsByFolderID[folderID] ?? []).filter(isDiscoverableFolderID) {
            fileIDs.formUnion(descendantFileIDs(in: childFolderID, state: state))
        }
        return fileIDs
    }

    private func makeFileTreeSelectionSnapshot(
        _ request: WorkspaceFileTreeSnapshotRequest,
        selectedStoreFileIDs: Set<UUID>,
        renderableCodemapFileIDs: Set<UUID>
    ) -> FileTreeSelectionSnapshot {
        makeFileTreeSelectionSnapshot(
            request,
            selectedStoreFileIDs: selectedStoreFileIDs,
            renderableCodemapFileIDs: renderableCodemapFileIDs,
            startFolder: nil
        )
    }

    private func makeFileTreeSelectionSnapshot(
        _ request: WorkspaceFileTreeSnapshotRequest,
        selectedStoreFileIDs: Set<UUID>,
        renderableCodemapFileIDs: Set<UUID>,
        profile: PathLocateProfile
    ) async -> FileTreeSelectionSnapshot {
        let trimmedStartPath = request.startPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedStartPath, !trimmedStartPath.isEmpty else {
            return makeFileTreeSelectionSnapshot(
                request,
                selectedStoreFileIDs: selectedStoreFileIDs,
                renderableCodemapFileIDs: renderableCodemapFileIDs,
                startFolder: nil
            )
        }
        let startFolder = await (lookupSelectionPath(trimmedStartPath, profile: profile, rootScope: request.rootScope))?.folder
        return makeFileTreeSelectionSnapshot(
            request,
            selectedStoreFileIDs: selectedStoreFileIDs,
            renderableCodemapFileIDs: renderableCodemapFileIDs,
            startFolder: startFolder
        )
    }

    private func makeFileTreeSelectionSnapshot(
        _ request: WorkspaceFileTreeSnapshotRequest,
        selectedStoreFileIDs: Set<UUID>,
        renderableCodemapFileIDs: Set<UUID>,
        startFolder: WorkspaceFolderRecord?
    ) -> FileTreeSelectionSnapshot {
        let selectedFileIDs = selectedStoreFileIDs
        let explicitlyIncludedManagedOnlyFileIDs = request.mode == .selected
            ? Set(selectedFileIDs.filter { managedOnlyFileIDs.contains($0) })
            : []
        let explicitlyIncludedManagedOnlyFolderIDs = managedOnlyAncestorFolderIDs(for: explicitlyIncludedManagedOnlyFileIDs)
        let roots: [FileTreeFolderSnapshot]
        if let startFolder,
           let state = rootStatesByID[startFolder.rootID],
           let root = rootStatesByID[startFolder.rootID]?.root
        {
            var visited = Set<UUID>()
            roots = makeFileTreeFolderSnapshot(
                startFolder,
                rootStandardizedPath: root.standardizedFullPath,
                state: state,
                visited: &visited,
                renderableCodemapFileIDs: renderableCodemapFileIDs,
                explicitlyIncludedManagedOnlyFileIDs: explicitlyIncludedManagedOnlyFileIDs,
                explicitlyIncludedManagedOnlyFolderIDs: explicitlyIncludedManagedOnlyFolderIDs
            ).map { [$0] } ?? []
        } else if request.startPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            roots = []
        } else {
            roots = rootsForPathLookup(scope: request.rootScope).compactMap { root -> FileTreeFolderSnapshot? in
                guard let state = rootStatesByID[root.id],
                      let rootFolderID = state.folderIDsByRelativePath[""],
                      let rootFolder = foldersByID[rootFolderID]
                else { return nil }
                var visited = Set<UUID>()
                return makeFileTreeFolderSnapshot(
                    rootFolder,
                    rootStandardizedPath: root.standardizedFullPath,
                    state: state,
                    visited: &visited,
                    renderableCodemapFileIDs: renderableCodemapFileIDs,
                    explicitlyIncludedManagedOnlyFileIDs: explicitlyIncludedManagedOnlyFileIDs,
                    explicitlyIncludedManagedOnlyFolderIDs: explicitlyIncludedManagedOnlyFolderIDs
                )
            }
        }

        return FileTreeSelectionSnapshot(
            roots: roots,
            selectedFileIDs: selectedFileIDs,
            mode: request.mode.rawValue,
            showFullPaths: request.filePathDisplay == .full,
            onlyIncludeRootsWithSelectedFiles: request.onlyIncludeRootsWithSelectedFiles,
            includeLegend: request.includeLegend,
            showCodeMapMarkers: request.showCodeMapMarkers,
            maxDepth: request.maxDepth
        )
    }

    func codemapSelectionGraphReadinessUpdates() -> AsyncStream<WorkspaceCodemapSelectionGraphReadinessEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            codemapSelectionGraphReadinessContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeCodemapSelectionGraphReadinessContinuation(id) }
            }
        }
    }

    private func removeCodemapSelectionGraphReadinessContinuation(_ id: UUID) {
        codemapSelectionGraphReadinessContinuations.removeValue(forKey: id)
    }

    func codemapMarkerReadinessUpdates() -> AsyncStream<WorkspaceCodemapMarkerReadinessEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            codemapMarkerReadinessContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeCodemapMarkerReadinessContinuation(id) }
            }
        }
    }

    private func removeCodemapMarkerReadinessContinuation(_ id: UUID) {
        codemapMarkerReadinessContinuations.removeValue(forKey: id)
    }

    @discardableResult
    func loadRoot(
        path: String,
        isSystemRoot: Bool = false,
        kind: WorkspaceRootKind? = nil,
        respectRepoIgnore: Bool = true,
        respectCursorignore: Bool = true,
        skipSymlinks: Bool = true,
        enableHierarchicalIgnores: Bool = true,
        cancelUnderlyingLoadOnCallerCancellation: Bool = false,
        sessionWorktreeReservationToken: WorkspaceSessionWorktreeOwnershipToken? = nil
    ) async throws -> WorkspaceRootRecord {
        let standardizedPath = (path as NSString).standardizingPath
        #if DEBUG
            let rootLoadRouteStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            let rootLoadName = URL(fileURLWithPath: standardizedPath).lastPathComponent
        #endif
        try Task.checkCancellation()
        try await waitForRootUnloadIfNeeded(standardizedPath: standardizedPath)
        try Task.checkCancellation()
        try await waitForPendingSeededRootVisibilityIfNeeded(
            standardizedPath: standardizedPath,
            bypassToken: sessionWorktreeReservationToken
        )
        try Task.checkCancellation()
        if let sessionWorktreeReservationToken {
            guard sessionWorktreeReservedPathsByToken[
                sessionWorktreeReservationToken
            ]?.contains(standardizedPath) == true else {
                throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
            }
        }
        let loadConfiguration = RootLoadConfiguration(
            kind: kind ?? (isSystemRoot ? .supplementalSystem : .primaryWorkspace),
            gitignorePolicyIdentity: .current,
            respectRepoIgnore: respectRepoIgnore,
            respectCursorignore: respectCursorignore,
            skipSymlinks: skipSymlinks,
            enableHierarchicalIgnores: enableHierarchicalIgnores
        )
        if let existingID = rootIDsByStandardizedPath[standardizedPath],
           let existing = rootStatesByID[existingID]?.root
        {
            guard let existingConfiguration = rootLoadConfigurationsByPath[standardizedPath], existingConfiguration == loadConfiguration else {
                throw WorkspaceFileContextStoreError.rootAlreadyLoadedWithDifferentConfiguration(standardizedPath)
            }
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "store.rootLoad.existing",
                    fields: [
                        "rootName": rootLoadName,
                        "rootID": WorkspaceRestorePerfLog.shortID(existing.id),
                        "kind": "\(loadConfiguration.kind)",
                        "duration": rootLoadRouteStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            return existing
        }
        if let inFlight = rootLoadFlightsByPath[standardizedPath] {
            guard rootLoadConfigurationsByPath[standardizedPath] == loadConfiguration else {
                throw WorkspaceFileContextStoreError.rootLoadInFlightWithDifferentConfiguration(standardizedPath)
            }
            if let sessionWorktreeReservationToken {
                registerSessionWorktreeReservationLoadFlight(
                    inFlight,
                    standardizedPath: standardizedPath,
                    token: sessionWorktreeReservationToken
                )
            }
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "store.rootLoad.joinInFlight",
                    fields: [
                        "rootName": rootLoadName,
                        "kind": "\(loadConfiguration.kind)"
                    ]
                )
                if let rootLoadDidJoinInFlightHandler {
                    await rootLoadDidJoinInFlightHandler(standardizedPath)
                }
            #endif
            return try await awaitRootLoadTask(
                inFlight.task,
                flightID: inFlight.id,
                standardizedPath: standardizedPath,
                cancelUnderlyingLoadOnCallerCancellation: cancelUnderlyingLoadOnCallerCancellation
            )
        }

        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "store.rootLoad.scheduled",
                fields: [
                    "rootName": rootLoadName,
                    "kind": "\(loadConfiguration.kind)"
                ]
            )
        #endif
        let completion = RootLoadFlightCompletion()
        let task = Task { [weak self] in
            guard let self else { throw WorkspaceFileContextStoreError.storeDeallocated }
            return try await FileSystemService.withContentReadForegroundActivity(kind: .rootLoad) {
                try await self.performLoadRoot(
                    standardizedPath: standardizedPath,
                    isSystemRoot: isSystemRoot,
                    kind: kind,
                    respectRepoIgnore: respectRepoIgnore,
                    respectCursorignore: respectCursorignore,
                    skipSymlinks: skipSymlinks,
                    enableHierarchicalIgnores: enableHierarchicalIgnores,
                    completion: completion
                )
            }
        }
        let flightID = UUID()
        let flight = RootLoadFlight(
            id: flightID,
            task: task,
            completion: completion
        )
        rootLoadFlightsByPath[standardizedPath] = flight
        rootLoadConfigurationsByPath[standardizedPath] = loadConfiguration
        if let sessionWorktreeReservationToken {
            registerSessionWorktreeReservationLoadFlight(
                flight,
                standardizedPath: standardizedPath,
                token: sessionWorktreeReservationToken
            )
        }
        Task { [weak self] in
            _ = try? await task.value
            await self?.clearCompletedRootLoadTask(
                standardizedPath: standardizedPath,
                expectedFlightID: flightID
            )
        }
        return try await awaitRootLoadTask(
            task,
            flightID: flightID,
            standardizedPath: standardizedPath,
            cancelUnderlyingLoadOnCallerCancellation: cancelUnderlyingLoadOnCallerCancellation
        )
    }

    private func awaitRootLoadTask(
        _ task: Task<WorkspaceRootRecord, Error>,
        flightID: UUID,
        standardizedPath: String,
        cancelUnderlyingLoadOnCallerCancellation: Bool
    ) async throws -> WorkspaceRootRecord {
        let race = RootLoadTaskWaitRace()
        Task {
            await race.resolve(task.result)
        }
        let root = try await withTaskCancellationHandler {
            try await race.value()
        } onCancel: {
            race.cancel()
            guard cancelUnderlyingLoadOnCallerCancellation else { return }
            task.cancel()
            Task {
                await self.cancelRootLoad(
                    standardizedPath: standardizedPath,
                    expectedFlightID: flightID
                )
            }
        }
        try Task.checkCancellation()
        return root
    }

    func cancelRootLoad(path: String) {
        let standardizedPath = (path as NSString).standardizingPath
        guard let flight = rootLoadFlightsByPath[standardizedPath] else { return }
        flight.task.cancel()
        removeRootLoadFlight(
            standardizedPath: standardizedPath,
            expectedFlightID: flight.id
        )
    }

    private func cancelRootLoad(
        standardizedPath: String,
        expectedFlightID: UUID
    ) {
        guard let flight = rootLoadFlightsByPath[standardizedPath],
              flight.id == expectedFlightID
        else { return }
        flight.task.cancel()
        removeRootLoadFlight(
            standardizedPath: standardizedPath,
            expectedFlightID: expectedFlightID
        )
    }

    private func clearCompletedRootLoadTask(
        standardizedPath: String,
        expectedFlightID: UUID
    ) {
        removeRootLoadFlight(
            standardizedPath: standardizedPath,
            expectedFlightID: expectedFlightID
        )
    }

    private func removeRootLoadFlight(
        standardizedPath: String,
        expectedFlightID: UUID
    ) {
        guard rootLoadFlightsByPath[standardizedPath]?.id == expectedFlightID else { return }
        rootLoadFlightsByPath.removeValue(forKey: standardizedPath)
        if rootIDsByStandardizedPath[standardizedPath] == nil {
            rootLoadConfigurationsByPath.removeValue(forKey: standardizedPath)
        }
    }

    private func performLoadRoot(
        standardizedPath: String,
        isSystemRoot: Bool,
        kind: WorkspaceRootKind?,
        respectRepoIgnore: Bool,
        respectCursorignore: Bool,
        skipSymlinks: Bool,
        enableHierarchicalIgnores: Bool,
        completion: RootLoadFlightCompletion
    ) async throws -> WorkspaceRootRecord {
        #if DEBUG
            let benchmarkMetricTag = WorktreeStartupInstrumentation.currentBenchmarkMetricTag
            let benchmarkFilesystemStarted = DispatchTime.now().uptimeNanoseconds
            defer {
                let finished = DispatchTime.now().uptimeNanoseconds
                WorktreeStartupInstrumentation.recordBenchmarkFilesystemWork(
                    tag: benchmarkMetricTag,
                    durationMicroseconds: finished >= benchmarkFilesystemStarted
                        ? (finished - benchmarkFilesystemStarted) / 1000
                        : 0,
                    itemCount: 1
                )
            }
        #endif
        if let existingID = rootIDsByStandardizedPath[standardizedPath],
           let existingState = rootStatesByID[existingID]
        {
            completion.record(
                rootID: existingState.root.id,
                lifetimeID: existingState.lifetimeID
            )
            return existingState.root
        }

        #if DEBUG
            if let rootLoadWillStartHandler {
                await rootLoadWillStartHandler(standardizedPath)
            }
        #endif

        let rootURL = URL(fileURLWithPath: standardizedPath).standardizedFileURL
        #if DEBUG
            let performLoadStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            WorkspaceRestorePerfLog.event(
                "store.rootLoad.begin",
                fields: [
                    "rootName": rootURL.lastPathComponent,
                    "kind": "\(kind ?? (isSystemRoot ? .supplementalSystem : .primaryWorkspace))",
                    "isSystemRoot": "\(isSystemRoot)"
                ]
            )
        #endif
        let root = if let kind {
            WorkspaceRootRecord(name: rootURL.lastPathComponent, fullPath: rootURL.path, kind: kind)
        } else {
            WorkspaceRootRecord(name: rootURL.lastPathComponent, fullPath: rootURL.path, isSystemRoot: isSystemRoot)
        }
        let service = try await FileSystemService(
            path: root.fullPath,
            respectRepoIgnore: respectRepoIgnore,
            respectCursorignore: respectCursorignore,
            skipSymlinks: skipSymlinks,
            enableHierarchicalIgnores: enableHierarchicalIgnores
        )
        #if DEBUG
            if let watcherActivationFailurePointForNewServicesForTesting {
                await service.setWatcherActivationFailureForTesting(
                    watcherActivationFailurePointForNewServicesForTesting
                )
            }
        #endif

        #if DEBUG
            var rootRecordCreatedFields: [String: String] = [
                "rootName": root.name,
                "rootID": WorkspaceRestorePerfLog.shortID(root.id),
                "kind": "\(root.kind)",
                "durationSinceStoreRootLoadBegin": performLoadStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
            ]
            rootRecordCreatedFields.merge(
                WorkspaceRootLoadDiagnostics.rootRecordCreatedFields(forPath: standardizedPath),
                uniquingKeysWith: { _, diagnostic in diagnostic }
            )
            WorkspaceRestorePerfLog.event("store.rootLoad.rootRecordCreated", fields: rootRecordCreatedFields)
        #endif

        var state = RootState(
            lifetimeID: UUID(),
            root: root,
            service: service,
            folderIDsByRelativePath: [:],
            fileIDsByRelativePath: [:],
            childFolderIDsByFolderID: [:],
            childFileIDsByFolderID: [:]
        )

        var stagedIndexes = RootIndexBuffers()
        let rootFolder = WorkspaceFolderRecord(
            id: root.id,
            rootID: root.id,
            name: root.name,
            relativePath: "",
            fullPath: root.fullPath,
            parentFolderID: nil
        )
        stagedIndexes.foldersByID[rootFolder.id] = rootFolder
        stagedIndexes.folderIDsByStandardizedFullPath[rootFolder.standardizedFullPath] = rootFolder.id
        state.folderIDsByRelativePath[""] = rootFolder.id

        #if DEBUG
            let coldStartWalkStart = WorkspaceFileSearchDebugTiming.now()
            let walkStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            var chunkCount = 0
        #endif
        for try await event in await service.loadContentsInChunks(of: rootURL) {
            try Task.checkCancellation()
            guard case let .preparedItems(chunk) = event else { continue }
            #if DEBUG
                chunkCount += 1
                if chunkCount == 1 {
                    var firstChunkFields: [String: String] = [
                        "rootName": root.name,
                        "rootID": WorkspaceRestorePerfLog.shortID(root.id),
                        "chunkFolders": "\(chunk.folders.count)",
                        "chunkFiles": "\(chunk.files.count)",
                        "durationSinceStoreRootLoadBegin": performLoadStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                    firstChunkFields.merge(
                        WorkspaceRootLoadDiagnostics.firstPreparedChunkFields(forPath: standardizedPath),
                        uniquingKeysWith: { _, diagnostic in diagnostic }
                    )
                    WorkspaceRestorePerfLog.event("store.rootLoad.firstPreparedChunk", fields: firstChunkFields)
                }
            #endif
            indexFolders(chunk.folders, root: root, state: &state, indexes: &stagedIndexes)
            indexFiles(chunk.files, root: root, state: &state, indexes: &stagedIndexes)
        }
        try Task.checkCancellation()
        #if DEBUG
            WorkspaceFileSearchDebugContext.coldStartCollector?.recordRootCrawl(
                nanoseconds: WorkspaceFileSearchDebugTiming.elapsed(
                    since: coldStartWalkStart,
                    through: WorkspaceFileSearchDebugTiming.now()
                ),
                files: stagedIndexes.filesByID.count,
                folders: stagedIndexes.foldersByID.count
            )
            WorkspaceRestorePerfLog.event(
                "store.rootLoad.walk",
                fields: [
                    "rootName": root.name,
                    "chunkCount": "\(chunkCount)",
                    "folders": "\(stagedIndexes.foldersByID.count)",
                    "files": "\(stagedIndexes.filesByID.count)",
                    "duration": walkStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
            let commitStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif

        commit(stagedIndexes)
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "store.rootLoad.commit",
                fields: [
                    "rootName": root.name,
                    "folders": "\(stagedIndexes.foldersByID.count)",
                    "files": "\(stagedIndexes.filesByID.count)",
                    "duration": commitStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
        if root.kind == .sessionWorktree {
            sessionRootLifetimeClock.advance()
        }
        rootIDsByStandardizedPath[root.standardizedFullPath] = root.id
        revokeAllAutomaticSelectionPublicationPermits()
        rootStatesByID[root.id] = state
        completion.record(rootID: root.id, lifetimeID: state.lifetimeID)
        rootLoadOrder.append(root.id)
        appliedIndexGenerationsByRootID[root.id] = 0
        catalogGenerationsByRootID[root.id] = 0
        #if DEBUG
            rootCrawlCountsByRootID[root.id, default: 0] += 1
        #endif
        invalidatePathMatchSnapshot(
            affectedRootKinds: [root.kind],
            reason: .rootLoad,
            affectedRootIDs: [root.id]
        )
        if WorktreeStartupFeatureFlags.current().observeDiffSeededWorktreeStartup {
            _ = try? await admitReusableSnapshotForLoadedRoot(
                rootID: root.id,
                expectedStandardizedPath: root.standardizedFullPath
            )
        }
        let rootEpoch = WorkspaceCodemapRootEpoch(
            rootID: root.id,
            rootLifetimeID: state.lifetimeID
        )
        recordCodemapRootReadyForProjectionPreload(rootEpoch: rootEpoch)
        scheduleCodemapProjectionPreloadAfterRootReady(rootEpoch: rootEpoch)
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "store.rootLoad.end",
                fields: [
                    "rootName": root.name,
                    "rootID": WorkspaceRestorePerfLog.shortID(root.id),
                    "folders": "\(stagedIndexes.foldersByID.count)",
                    "files": "\(stagedIndexes.filesByID.count)",
                    "duration": performLoadStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
        return root
    }

    /// Constructs fresh target-local IDs and records for a pending seeded root.
    /// No source-worktree record, metadata, descriptor, or cache is reused.
    private func makePendingSeededRootTopology(
        standardizedPath: String,
        service: FileSystemService,
        inventorySnapshot: FileSystemSeededInventorySnapshot? = nil,
        root existingRoot: WorkspaceRootRecord? = nil,
        lifetimeID existingLifetimeID: UUID? = nil
    ) throws -> (state: RootState, indexes: RootIndexBuffers) {
        let rootURL = URL(fileURLWithPath: standardizedPath).standardizedFileURL
        let root = existingRoot ?? WorkspaceRootRecord(
            name: rootURL.lastPathComponent,
            fullPath: rootURL.path,
            kind: .sessionWorktree
        )
        var state = RootState(
            lifetimeID: existingLifetimeID ?? UUID(),
            root: root,
            service: service,
            folderIDsByRelativePath: [:],
            fileIDsByRelativePath: [:],
            childFolderIDsByFolderID: [:],
            childFileIDsByFolderID: [:]
        )
        var indexes = RootIndexBuffers()
        let rootFolder = WorkspaceFolderRecord(
            id: root.id,
            rootID: root.id,
            name: root.name,
            relativePath: "",
            fullPath: root.fullPath,
            parentFolderID: nil
        )
        indexes.foldersByID[rootFolder.id] = rootFolder
        indexes.folderIDsByStandardizedFullPath[rootFolder.standardizedFullPath] = rootFolder.id
        state.folderIDsByRelativePath[""] = rootFolder.id

        if let inventorySnapshot {
            let reader = try inventorySnapshot.makeReader()
            while let item = try reader.next() {
                let dto = FSItemDTO(
                    relativePath: item.relativePath,
                    isDirectory: item.isDirectory,
                    hierarchy: item.relativePath.split(separator: "/").count
                )
                if item.isDirectory {
                    indexFolders([dto], root: root, state: &state, indexes: &indexes)
                } else {
                    indexFiles([dto], root: root, state: &state, indexes: &indexes)
                }
            }
        }
        return (state, indexes)
    }

    private func waitForRootUnloadIfNeeded(standardizedPath: String) async throws {
        try Task.checkCancellation()
        while unloadingRootPaths.contains(standardizedPath) {
            let waiterID = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    unloadWaitersByRootPath[standardizedPath, default: [:]][waiterID] = continuation
                }
            } onCancel: {
                Task { await self.cancelRootUnloadWaiter(standardizedPath: standardizedPath, waiterID: waiterID) }
            }
            try Task.checkCancellation()
        }
    }

    private func waitForPendingSeededRootVisibilityIfNeeded(
        standardizedPath: String,
        bypassToken: WorkspaceSessionWorktreeOwnershipToken?
    ) async throws {
        while let pendingID = pendingSeededRootIDsByStandardizedPath[standardizedPath],
              let pending = pendingSeededRootsByID[pendingID]
        {
            if pending.token == bypassToken {
                throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
            }
            let waiterID = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    pendingSeededRootVisibilityWaitersByPath[standardizedPath, default: [:]][waiterID] = continuation
                }
            } onCancel: {
                Task {
                    await self.cancelPendingSeededRootVisibilityWaiter(
                        standardizedPath: standardizedPath,
                        waiterID: waiterID
                    )
                }
            }
            try Task.checkCancellation()
        }
    }

    private func cancelPendingSeededRootVisibilityWaiter(
        standardizedPath: String,
        waiterID: UUID
    ) {
        guard let continuation = pendingSeededRootVisibilityWaitersByPath[standardizedPath]?
            .removeValue(forKey: waiterID)
        else { return }
        if pendingSeededRootVisibilityWaitersByPath[standardizedPath]?.isEmpty == true {
            pendingSeededRootVisibilityWaitersByPath.removeValue(forKey: standardizedPath)
        }
        continuation.resume(throwing: CancellationError())
    }

    private func finishPendingSeededRootVisibility(path: String) {
        let waiters = pendingSeededRootVisibilityWaitersByPath.removeValue(forKey: path) ?? [:]
        for continuation in waiters.values {
            continuation.resume()
        }
    }

    private func cancelRootUnloadWaiter(standardizedPath: String, waiterID: UUID) {
        guard let waiter = unloadWaitersByRootPath[standardizedPath]?.removeValue(forKey: waiterID) else { return }
        if unloadWaitersByRootPath[standardizedPath]?.isEmpty == true {
            unloadWaitersByRootPath.removeValue(forKey: standardizedPath)
        }
        waiter.resume(throwing: CancellationError())
    }

    private func finishRootUnload(for standardizedPaths: [String]) {
        for path in standardizedPaths {
            unloadingRootPaths.remove(path)
            let waiters = unloadWaitersByRootPath.removeValue(forKey: path) ?? [:]
            for waiter in waiters.values {
                waiter.resume()
            }
        }
    }

    func unloadRoot(id rootID: UUID) async {
        await unloadRoots(ids: [rootID])
    }

    func unloadRoots(ids rootIDs: [UUID]) async {
        var seenRootIDs = Set<UUID>()
        let orderedRootIDs = rootIDs.filter { seenRootIDs.insert($0).inserted }
        guard !orderedRootIDs.isEmpty else { return }

        var statesToUnload: [(rootID: UUID, state: RootState)] = []
        var codemapCleanupFlights: [CodemapCleanupFlight] = []
        var codemapCleanupIDs = Set<UUID>()
        var seededAuthorityFencesToRelease: [GitWorkspacePendingInitializationAuthorityFence] = []
        var seededAuthorityClaimsToRelease: [WorkspaceRootSeedServingAuthorityClaim] = []
        var ownershipResourcesReleasedByUnload = SessionWorktreeOwnershipRemoval()
        var invalidatedOwnershipTokens = Set<WorkspaceSessionWorktreeOwnershipToken>()
        for rootID in orderedRootIDs {
            if let claim = publishedSeededAuthorityClaimsByRootID.removeValue(forKey: rootID) {
                seededAuthorityClaimsToRelease.append(claim)
                publishedSeededAuthorityFencesByRootID.removeValue(forKey: rootID)
            } else if let fence = publishedSeededAuthorityFencesByRootID.removeValue(forKey: rootID) {
                seededAuthorityFencesToRelease.append(fence)
            }
            publishedSeededAuthorityStatesByRootID.removeValue(forKey: rootID)
            let unavailablePath = rootStatesByID[rootID]?.root.standardizedFullPath ?? rootID.uuidString
            resumePublishedSeededAuthorityWaiters(
                rootID: rootID,
                error: WorkspaceSessionWorktreeOwnershipError.unavailableRoot(unavailablePath)
            )
            seededAuthorityPendingGenerationByRootID.removeValue(forKey: rootID)
            seededAuthorityReconciliationTasksByRootID.removeValue(forKey: rootID)?.cancel()
            explicitWatcherDemandRootIDs.remove(rootID)
            if let state = rootStatesByID[rootID] {
                let watcherKey = WatcherInfrastructureKey(rootID: rootID, lifetimeID: state.lifetimeID)
                explicitWatcherDemandGenerationByKey.removeValue(forKey: watcherKey)
            }
            if let state = rootStatesByID[rootID], state.root.kind == .sessionWorktree {
                let lifetimeKey = SessionWorktreeRootLifetimeKey(rootID: rootID, lifetimeID: state.lifetimeID)
                let ownershipTokens = (sessionWorktreeOwnershipTokensByRootLifetime[lifetimeKey] ?? [])
                    .union(sessionWorktreeReservationTokensByStandardizedPath[state.root.standardizedFullPath] ?? [])
                for token in ownershipTokens where invalidatedOwnershipTokens.insert(token).inserted {
                    latestSessionWorktreeOwnershipGenerationByOwnerID[token.ownerID, default: 0] &+= 1
                    if installedSessionWorktreeOwnershipTokenByOwnerID[token.ownerID] == token {
                        installedSessionWorktreeOwnershipTokenByOwnerID.removeValue(forKey: token.ownerID)
                    }
                    ownershipResourcesReleasedByUnload.append(removeSessionWorktreeOwnershipToken(token))
                }
            }
            if let flightState = scopedIngressBarrierFlightStatesByRootID.removeValue(forKey: rootID) {
                flightState.active?.task?.cancel()
                flightState.active?.join.complete(with: nil)
                flightState.pending?.join.complete(with: nil)
            }
            completedScopedIngressBarrierCutsByRootID.removeValue(forKey: rootID)
            if let state = rootStatesByID[rootID] {
                let watcherKey = WatcherInfrastructureKey(rootID: rootID, lifetimeID: state.lifetimeID)
                watcherPublisherAttachmentsByKey.removeValue(forKey: watcherKey)?.cancellable.cancel()
                watcherInfrastructureFlightsByKey.removeValue(forKey: watcherKey)?.task.cancel()
            }
            publisherIngressCoordinator.closePublisherIngress(rootID: rootID)
            if rootStatesByID[rootID]?.root.kind == .sessionWorktree {
                sessionRootLifetimeClock.advance()
            }
            if let currentState = rootStatesByID[rootID] {
                revokeAutomaticSelectionPublicationPermits(rootEpoch: WorkspaceCodemapRootEpoch(
                    rootID: rootID,
                    rootLifetimeID: currentState.lifetimeID
                ))
            }
            guard let state = rootStatesByID.removeValue(forKey: rootID) else { continue }
            invalidateRootSeedSearchShadow(rootID: rootID)
            let rootEpoch = WorkspaceCodemapRootEpoch(
                rootID: rootID,
                rootLifetimeID: state.lifetimeID
            )
            codemapRootMutationFenceTokensByRootEpoch.removeValue(forKey: rootEpoch)
            let rootMutationWaiters = codemapRootMutationFenceWaitersByRootEpoch.removeValue(
                forKey: rootEpoch
            ) ?? [:]
            for continuation in rootMutationWaiters.values {
                continuation.resume()
            }
            codemapProjectionPreloadReschedulePendingRootEpochs.remove(rootEpoch)
            if let cleanup = detachCodemapSession(
                rootEpoch: rootEpoch,
                invalidationCommands: [.unload],
                graphInvalidationReason: .rootUnloaded
            ),
                codemapCleanupIDs.insert(cleanup.id).inserted
            {
                codemapCleanupFlights.append(cleanup)
            }
            codemapAuthorityGenerationsByRootEpoch.removeValue(forKey: rootEpoch)
            codemapProjectionInvalidationGenerationsByRootEpoch.removeValue(forKey: rootEpoch)
            terminalNonGitCodemapCacheByEpoch.removeValue(forKey: rootEpoch)
            codemapPathFenceTokensByID = codemapPathFenceTokensByID.filter {
                $0.value.rootEpoch != rootEpoch
            }
            statesToUnload.append((rootID, state))
        }
        for claim in seededAuthorityClaimsToRelease {
            await claim.release()
        }
        for fence in seededAuthorityFencesToRelease {
            await worktreeSeedGitService.releasePendingInitializationAuthorityFence(fence)
        }
        guard !statesToUnload.isEmpty else { return }
        invalidatePathMatchSnapshot(
            affectedRootKinds: Set(statesToUnload.map(\.state.root.kind)),
            reason: .rootUnload,
            affectedRootIDs: Set(statesToUnload.map(\.rootID))
        )
        for entry in statesToUnload {
            for fileID in entry.state.fileIDsByRelativePath.values {
                searchContentInvalidationEpochsByFileID.removeValue(forKey: fileID)
            }
            removeSliceRebaseSources(rootID: entry.rootID, rootLifetimeID: entry.state.lifetimeID)
            await searchDecodedContentCache.invalidate(rootID: entry.rootID)
            await interactiveReadCache.invalidate(rootID: entry.rootID)
        }
        #if DEBUG
            let rootUnloadStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            let rootUnloadFolderCount = statesToUnload.reduce(0) { $0 + $1.state.folderIDsByRelativePath.count }
            let rootUnloadFileCount = statesToUnload.reduce(0) { $0 + $1.state.fileIDsByRelativePath.count }
            WorkspaceRestorePerfLog.event(
                "store.rootUnload.begin",
                fields: [
                    "rootCount": "\(statesToUnload.count)",
                    "folderCount": "\(rootUnloadFolderCount)",
                    "fileCount": "\(rootUnloadFileCount)"
                ]
            )
            let detachStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif

        let unloadingPaths = statesToUnload.map(\.state.root.standardizedFullPath)
        for path in unloadingPaths {
            unloadingRootPaths.insert(path)
        }
        #if DEBUG
            if let rootUnloadDidDetachHandler {
                await rootUnloadDidDetachHandler(unloadingPaths)
            }
        #endif

        let removedRootIDSet = Set(statesToUnload.map(\.rootID))
        rootLoadOrder.removeAll { removedRootIDSet.contains($0) }
        for entry in statesToUnload {
            rootIDsByStandardizedPath.removeValue(forKey: entry.state.root.standardizedFullPath)
            rootLoadConfigurationsByPath.removeValue(forKey: entry.state.root.standardizedFullPath)
        }
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "store.rootUnload.detach",
                fields: [
                    "rootCount": "\(statesToUnload.count)",
                    "duration": detachStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
            let stopWatchersStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif

        // Stop each detached service exactly once. The caller only waits through a bounded
        // completion latch; cancellation cannot interrupt synchronous FSEvents flush work.
        let detachedWatcherStops = startDetachedWatcherStops(statesToUnload)
        #if DEBUG
            if publisherIngressCoordinator.pendingPublisherIngressCount(rootIDs: removedRootIDSet) > 0,
               let publisherIngressWillWaitHandler
            {
                await publisherIngressWillWaitHandler(removedRootIDSet)
            }
        #endif
        let removedRootIDsInOrder = statesToUnload.map(\.rootID)
        async let publisherIngressReports = publisherIngressCoordinator.terminateClosedPublisherIngress(
            rootIDs: removedRootIDsInOrder,
            gracefulDrainTimeoutNanoseconds: unloadTerminationPolicy.publisherIngressGraceNanoseconds,
            sleep: unloadTerminationPolicy.sleep
        )
        let watcherStopReports = await awaitDetachedWatcherStops(detachedWatcherStops)
        let resolvedPublisherIngressReports = await publisherIngressReports
        let terminationDiagnostics = WorkspaceRootUnloadTerminationDiagnostics(
            publisherIngressReports: resolvedPublisherIngressReports,
            watcherStopReports: watcherStopReports
        )
        WorkspaceRootUnloadDiagnosticsLog.record(terminationDiagnostics)
        #if DEBUG
            if let rootUnloadTerminationDidCompleteHandler {
                await rootUnloadTerminationDidCompleteHandler(terminationDiagnostics)
            }
        #endif
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "store.rootUnload.stopWatchers",
                fields: [
                    "rootCount": "\(statesToUnload.count)",
                    "duration": stopWatchersStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
            let indexCleanupStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif

        for entry in statesToUnload {
            let rootID = entry.rootID
            let state = entry.state
            let discoverableFolderIDsByPath = state.folderIDsByRelativePath.filter { isDiscoverableFolderID($0.value) }
            let discoverableFileIDsByPath = state.fileIDsByRelativePath.filter { isDiscoverableFileID($0.value) }
            for folderID in state.folderIDsByRelativePath.values {
                managedOnlyFolderIDs.remove(folderID)
                if let folder = foldersByID.removeValue(forKey: folderID),
                   folderIDsByStandardizedFullPath[folder.standardizedFullPath] == folderID
                {
                    folderIDsByStandardizedFullPath.removeValue(forKey: folder.standardizedFullPath)
                }
            }
            for fileID in state.fileIDsByRelativePath.values {
                managedOnlyFileIDs.remove(fileID)
                if let file = filesByID.removeValue(forKey: fileID),
                   fileIDsByStandardizedFullPath[file.standardizedFullPath] == fileID
                {
                    fileIDsByStandardizedFullPath.removeValue(forKey: file.standardizedFullPath)
                }
            }
            let generation = nextAppliedIndexGeneration(forRootID: rootID)
            yieldAppliedIndexEvent(WorkspaceAppliedIndexBatchEvent(
                rootID: rootID,
                rootPath: state.root.standardizedFullPath,
                generation: generation,
                rootLifetimeID: state.lifetimeID,
                removedFileIDs: Array(discoverableFileIDsByPath.values),
                removedFolderIDs: Array(discoverableFolderIDsByPath.values),
                removedFilePaths: Array(discoverableFileIDsByPath.keys).sorted(),
                removedFolderPaths: Array(discoverableFolderIDsByPath.keys).sorted(),
                requiresFullResync: true,
                isRootUnload: true
            ))
            appliedIndexGenerationsByRootID.removeValue(forKey: rootID)
            catalogGenerationsByRootID.removeValue(forKey: rootID)
            #if DEBUG
                publicationInvalidationHistoryByRootID.removeValue(forKey: rootID)
                scopedIngressBarrierLaunchCountsByRootID.removeValue(forKey: rootID)
                scopedIngressBarrierJoinCountsByRootID.removeValue(forKey: rootID)
                scopedIngressBarrierSuccessorCountsByRootID.removeValue(forKey: rootID)
                scopedIngressBarrierCoalescedSuccessorCountsByRootID.removeValue(forKey: rootID)
                scopedIngressBarrierCompletionCountsByRootID.removeValue(forKey: rootID)
                scopedIngressBarrierNoopCountsByRootID.removeValue(forKey: rootID)
                scopedIngressBarrierTotalWaitMillisecondsByRootID.removeValue(forKey: rootID)
                scopedIngressBarrierMaxWaitMillisecondsByRootID.removeValue(forKey: rootID)
                lastCompletedScopedIngressBarrierByRootID.removeValue(forKey: rootID)
                rootCrawlCountsByRootID.removeValue(forKey: rootID)
            #endif
        }

        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "store.rootUnload.indexCleanup",
                fields: [
                    "rootCount": "\(statesToUnload.count)",
                    "removedFolders": "\(rootUnloadFolderCount)",
                    "removedFiles": "\(rootUnloadFileCount)",
                    "duration": indexCleanupStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
        for cleanup in codemapCleanupFlights {
            await cleanup.task.value
        }
        finishRootUnload(for: unloadingPaths)
        let removedLifetimeKeys = Set(statesToUnload.map {
            SessionWorktreeRootLifetimeKey(rootID: $0.rootID, lifetimeID: $0.state.lifetimeID)
        })
        let removedStandardizedPaths = Set(statesToUnload.map(\.state.root.standardizedFullPath))
        await cleanupOrphanedSessionWorktreeResources(SessionWorktreeOwnershipRemoval(
            ownedRoots: ownershipResourcesReleasedByUnload.ownedRoots.filter {
                !removedLifetimeKeys.contains(
                    SessionWorktreeRootLifetimeKey(rootID: $0.rootID, lifetimeID: $0.lifetimeID)
                )
            },
            reservedLoadFlights: ownershipResourcesReleasedByUnload.reservedLoadFlights.filter {
                !removedStandardizedPaths.contains($0.standardizedPath)
            }
        ))
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "store.rootUnload.end",
                fields: [
                    "rootCount": "\(statesToUnload.count)",
                    "duration": rootUnloadStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
    }

    private func startDetachedWatcherStops(
        _ statesToUnload: [(rootID: UUID, state: RootState)]
    ) -> [DetachedWatcherStop] {
        statesToUnload.enumerated().map { index, entry in
            let completionLatch = WorkspaceRootUnloadCompletionLatch()
            let service = entry.state.service
            #if DEBUG
                let watcherStopWillBeginHandler = watcherStopWillBeginHandler
            #endif
            let task = Task.detached {
                #if DEBUG
                    if let watcherStopWillBeginHandler {
                        await watcherStopWillBeginHandler(entry.rootID)
                    }
                #endif
                await service.stopWatchingForChanges()
                completionLatch.complete()
            }
            return DetachedWatcherStop(
                index: index,
                rootID: entry.rootID,
                rootPath: entry.state.root.standardizedFullPath,
                completionLatch: completionLatch,
                task: task
            )
        }
    }

    private func awaitDetachedWatcherStops(
        _ stops: [DetachedWatcherStop]
    ) async -> [WorkspaceRootWatcherStopReport] {
        await withTaskGroup(of: (Int, WorkspaceRootWatcherStopReport).self) { group in
            for stop in stops {
                group.addTask { [unloadTerminationPolicy] in
                    let outcome = await WorkspaceRootUnloadBoundedWait.waitForCompletion(
                        stop.completionLatch,
                        timeoutNanoseconds: unloadTerminationPolicy.watcherStopGraceNanoseconds,
                        sleep: unloadTerminationPolicy.sleep
                    )
                    if outcome != .completed {
                        stop.task.cancel()
                    }
                    return (
                        stop.index,
                        WorkspaceRootWatcherStopReport(
                            rootID: stop.rootID,
                            rootPath: stop.rootPath,
                            outcome: outcome,
                            graceNanoseconds: unloadTerminationPolicy.watcherStopGraceNanoseconds
                        )
                    )
                }
            }
            var reports: [(Int, WorkspaceRootWatcherStopReport)] = []
            for await report in group {
                reports.append(report)
            }
            return reports.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    func file(rootID: UUID, relativePath: String) -> WorkspaceFileRecord? {
        guard let state = rootStatesByID[rootID] else { return nil }
        let key = StandardizedPath.relative(relativePath)
        guard let fileID = state.fileIDsByRelativePath[key] else { return nil }
        return filesByID[fileID]
    }

    func folder(rootID: UUID, relativePath: String) -> WorkspaceFolderRecord? {
        guard let state = rootStatesByID[rootID] else { return nil }
        let key = StandardizedPath.relative(relativePath)
        guard let folderID = state.folderIDsByRelativePath[key] else { return nil }
        return foldersByID[folderID]
    }

    func cachedSearchContentSnapshot(
        for expectedRecord: WorkspaceFileRecord
    ) async -> FileSearchContentSnapshot {
        guard publishedSeededAuthorityIsQueryable(rootID: expectedRecord.rootID) else {
            return staleSearchContentSnapshot(for: expectedRecord)
        }
        guard let current = file(
            rootID: expectedRecord.rootID,
            relativePath: expectedRecord.standardizedRelativePath
        ), current.id == expectedRecord.id else {
            return staleSearchContentSnapshot(for: expectedRecord)
        }
        let epoch = searchContentInvalidationEpochsByFileID[current.id] ?? 0
        let cacheKey = WorkspaceSearchContentCacheKey(
            rootID: current.rootID,
            fileID: current.id,
            standardizedRelativePath: current.standardizedRelativePath
        )
        guard let cached = await searchDecodedContentCache.cachedSnapshot(
            for: cacheKey,
            invalidationEpoch: epoch
        ), searchContentRecordIsCurrent(current, invalidationEpoch: epoch) else {
            return staleSearchContentSnapshot(for: current)
        }
        if let state = rootStatesByID[current.rootID] {
            retainSliceRebaseSource(
                content: cached.content,
                modificationDate: cached.modificationDate,
                file: current,
                rootLifetimeID: state.lifetimeID
            )
        }
        return FileSearchContentSnapshot(
            content: cached.content,
            contentRevision: cached.revision,
            modificationDate: cached.modificationDate,
            isFresh: true
        )
    }

    func searchContentSnapshot(
        for expectedRecord: WorkspaceFileRecord,
        freshnessPolicy: FileContentFreshnessPolicy = .validateDiskMetadata
    ) async throws -> FileSearchContentSnapshot {
        try await requirePublishedSeededAuthorityFresh(rootID: expectedRecord.rootID)
        for attempt in 0 ..< 2 {
            try Task.checkCancellation()
            guard let state = rootStatesByID[expectedRecord.rootID],
                  let current = file(rootID: expectedRecord.rootID, relativePath: expectedRecord.standardizedRelativePath),
                  current.id == expectedRecord.id
            else {
                return staleSearchContentSnapshot(for: expectedRecord)
            }

            let service = state.service
            let epoch = searchContentInvalidationEpochsByFileID[current.id] ?? 0
            let cacheKey = WorkspaceSearchContentCacheKey(
                rootID: current.rootID,
                fileID: current.id,
                standardizedRelativePath: current.standardizedRelativePath
            )
            if case .cachedMetadata = freshnessPolicy,
               let cached = await searchDecodedContentCache.cachedSnapshot(
                   for: cacheKey,
                   invalidationEpoch: epoch
               )
            {
                guard searchContentRecordIsCurrent(current, invalidationEpoch: epoch) else {
                    if attempt == 0 { continue }
                    return staleSearchContentSnapshot(for: current)
                }
                retainSliceRebaseSource(
                    content: cached.content,
                    modificationDate: cached.modificationDate,
                    file: current,
                    rootLifetimeID: state.lifetimeID
                )
                try await requirePublishedSeededAuthorityFresh(rootID: current.rootID)
                return FileSearchContentSnapshot(
                    content: cached.content,
                    contentRevision: cached.revision,
                    modificationDate: cached.modificationDate,
                    isFresh: true
                )
            }
            let fingerprint: FileContentFingerprint
            do {
                fingerprint = try await service.contentFingerprint(
                    ofRelativePath: current.standardizedRelativePath
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch FileSystemError.fileNotFound {
                await pruneCatalogFileIfStillCurrent(current)
                return staleSearchContentSnapshot(for: current)
            } catch {
                return staleSearchContentSnapshot(for: current)
            }

            guard searchContentRecordIsCurrent(current, invalidationEpoch: epoch) else {
                if attempt == 0 { continue }
                return staleSearchContentSnapshot(for: current)
            }

            let schedulerOwnerID = searchContentSchedulerOwnerID
            do {
                let cached = try await searchDecodedContentCache.snapshot(
                    for: cacheKey,
                    fingerprint: fingerprint,
                    invalidationEpoch: epoch
                ) {
                    try await service.loadValidatedContent(
                        ofRelativePath: current.standardizedRelativePath,
                        expectedFingerprint: fingerprint,
                        workloadClass: .contentSearch,
                        schedulerOwnerID: schedulerOwnerID
                    )
                }
                guard let cached else {
                    if attempt == 0 { continue }
                    return staleSearchContentSnapshot(for: current)
                }
                guard searchContentRecordIsCurrent(current, invalidationEpoch: epoch) else {
                    if attempt == 0 { continue }
                    return staleSearchContentSnapshot(for: current)
                }
                retainSliceRebaseSource(
                    content: cached.content,
                    modificationDate: cached.modificationDate,
                    file: current,
                    rootLifetimeID: state.lifetimeID
                )
                try await requirePublishedSeededAuthorityFresh(rootID: current.rootID)
                return FileSearchContentSnapshot(
                    content: cached.content,
                    contentRevision: cached.revision,
                    modificationDate: cached.modificationDate,
                    isFresh: true
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ContentReadSchedulerError {
                throw error
            } catch FileContentValidationError.fingerprintChanged {
                if attempt == 0 { continue }
                return staleSearchContentSnapshot(for: current)
            } catch FileSystemError.fileNotFound {
                await pruneCatalogFileIfStillCurrent(current)
                return staleSearchContentSnapshot(for: current)
            } catch {
                return staleSearchContentSnapshot(for: current)
            }
        }
        return staleSearchContentSnapshot(for: expectedRecord)
    }

    func interactiveReadSnapshot(
        for expectedRecord: WorkspaceFileRecord
    ) async throws -> WorkspaceInteractiveReadSnapshot? {
        try await FileSystemService.withContentReadForegroundActivity(kind: .interactiveRead) {
            try await self.interactiveReadSnapshotWithinForegroundActivity(for: expectedRecord)
        }
    }

    private func interactiveReadSnapshotWithinForegroundActivity(
        for expectedRecord: WorkspaceFileRecord
    ) async throws -> WorkspaceInteractiveReadSnapshot? {
        try await requirePublishedSeededAuthorityFresh(rootID: expectedRecord.rootID)
        for attempt in 0 ..< 2 {
            try Task.checkCancellation()
            guard let state = rootStatesByID[expectedRecord.rootID],
                  let current = file(
                      rootID: expectedRecord.rootID,
                      relativePath: expectedRecord.standardizedRelativePath
                  ),
                  current.id == expectedRecord.id
            else {
                return nil
            }

            let service = state.service
            let epoch = searchContentInvalidationEpochsByFileID[current.id] ?? 0
            let cacheKey = WorkspaceInteractiveReadCacheKey(
                rootID: current.rootID,
                rootLifetimeID: state.lifetimeID,
                fileID: current.id,
                standardizedRelativePath: current.standardizedRelativePath
            )
            let fingerprint: FileContentFingerprint
            do {
                fingerprint = try await service.contentFingerprint(
                    ofRelativePath: current.standardizedRelativePath
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch FileSystemError.fileNotFound {
                await pruneCatalogFileIfStillCurrent(current)
                return nil
            } catch {
                return nil
            }

            guard searchContentRecordIsCurrent(current, invalidationEpoch: epoch) else {
                if attempt == 0 { continue }
                return nil
            }

            let schedulerOwnerID = interactiveReadSchedulerOwnerID
            do {
                let cached = try await interactiveReadCache.snapshot(
                    for: cacheKey,
                    fingerprint: fingerprint,
                    invalidationEpoch: epoch
                ) {
                    let loaded = try await service.loadValidatedContent(
                        ofRelativePath: current.standardizedRelativePath,
                        expectedFingerprint: fingerprint,
                        workloadClass: .interactiveRead,
                        schedulerOwnerID: schedulerOwnerID
                    )
                    guard let content = loaded.content else { return nil }
                    return await WorkspaceInteractiveReadProcessor.prepareOffActor(content)
                }
                guard let preparedContent = cached.preparedContent else {
                    if attempt == 0 { continue }
                    return nil
                }
                guard searchContentRecordIsCurrent(current, invalidationEpoch: epoch) else {
                    if attempt == 0 { continue }
                    return nil
                }
                retainSliceRebaseSource(
                    content: preparedContent.linesWithEndings.joined(),
                    modificationDate: fingerprint.modificationDate,
                    file: current,
                    rootLifetimeID: state.lifetimeID
                )
                try await requirePublishedSeededAuthorityFresh(rootID: current.rootID)
                return WorkspaceInteractiveReadSnapshot(
                    preparedContent: preparedContent,
                    cacheHit: cached.cacheHit
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ContentReadSchedulerError {
                throw error
            } catch FileContentValidationError.fingerprintChanged {
                if attempt == 0 { continue }
                return nil
            } catch FileSystemError.fileNotFound {
                await pruneCatalogFileIfStillCurrent(current)
                return nil
            } catch {
                return nil
            }
        }
        return nil
    }

    func clearSearchDecodedContentCache() async {
        await searchDecodedContentCache.clear()
        await interactiveReadCache.clear()
        clearSliceRebaseSources()
    }

    func readContentPrefix(
        rootID: UUID,
        relativePath: String,
        maximumBytes: Int,
        workloadClass: ContentReadWorkloadClass = .unspecified
    ) async throws -> FileContentPrefix? {
        try await requirePublishedSeededAuthorityFresh(rootID: rootID)
        let state = try state(for: rootID)
        let result = try await state.service.loadContentPrefix(
            ofRelativePath: StandardizedPath.relative(relativePath),
            maximumBytes: maximumBytes,
            workloadClass: workloadClass
        )
        try await requirePublishedSeededAuthorityFresh(rootID: rootID)
        return result
    }

    func readContent(
        rootID: UUID,
        relativePath: String,
        workloadClass: ContentReadWorkloadClass = .unspecified
    ) async throws -> String? {
        try await requirePublishedSeededAuthorityFresh(rootID: rootID)
        let state = try state(for: rootID)
        let lifecycleCorrelation = EditFlowPerf.currentLifecycleCorrelation
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.ReadFile.storeReadContentEntered,
            correlation: lifecycleCorrelation,
            EditFlowPerf.Dimensions(
                workloadClass: workloadClass.rawValue,
                rootToken: state.service.diagnosticRootToken.uuidString
            )
        )
        let forwardState = EditFlowPerf.begin(
            EditFlowPerf.Stage.ReadFile.storeReadContentForwardAwait,
            EditFlowPerf.Dimensions(workloadClass: workloadClass.rawValue)
        )
        do {
            let content = try await state.service.loadContent(
                ofRelativePath: StandardizedPath.relative(relativePath),
                workloadClass: workloadClass
            )
            try await requirePublishedSeededAuthorityFresh(rootID: rootID)
            EditFlowPerf.end(
                EditFlowPerf.Stage.ReadFile.storeReadContentForwardAwait,
                forwardState,
                EditFlowPerf.Dimensions(outcome: "returned", workloadClass: workloadClass.rawValue)
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.storeReadContentReturned,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(
                    outcome: "returned",
                    workloadClass: workloadClass.rawValue,
                    rootToken: state.service.diagnosticRootToken.uuidString
                )
            )
            return content
        } catch {
            EditFlowPerf.end(
                EditFlowPerf.Stage.ReadFile.storeReadContentForwardAwait,
                forwardState,
                EditFlowPerf.Dimensions(outcome: error is CancellationError ? "cancelled" : "error", workloadClass: workloadClass.rawValue)
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.storeReadContentReturned,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(
                    outcome: error is CancellationError ? "cancelled" : "error",
                    workloadClass: workloadClass.rawValue,
                    rootToken: state.service.diagnosticRootToken.uuidString
                )
            )
            throw error
        }
    }

    func readValidatedContentSnapshot(
        rootID: UUID,
        relativePath: String,
        workloadClass: ContentReadWorkloadClass = .unspecified
    ) async throws -> ValidatedFileContentSnapshot {
        try await requirePublishedSeededAuthorityFresh(rootID: rootID)
        let state = try state(for: rootID)
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        let fingerprint = try await state.service.contentFingerprint(ofRelativePath: standardizedRelativePath)
        let result = try await state.service.loadValidatedContent(
            ofRelativePath: standardizedRelativePath,
            expectedFingerprint: fingerprint,
            workloadClass: workloadClass
        )
        try await requirePublishedSeededAuthorityFresh(rootID: rootID)
        return result
    }

    func readContentWithDate(
        rootID: UUID,
        relativePath: String,
        workloadClass: ContentReadWorkloadClass = .unspecified
    ) async throws -> (content: String?, modificationDate: Date) {
        try await requirePublishedSeededAuthorityFresh(rootID: rootID)
        let state = try state(for: rootID)
        let lifecycleCorrelation = EditFlowPerf.currentLifecycleCorrelation
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.ReadFile.storeReadContentEntered,
            correlation: lifecycleCorrelation,
            EditFlowPerf.Dimensions(
                workloadClass: workloadClass.rawValue,
                rootToken: state.service.diagnosticRootToken.uuidString
            )
        )
        let forwardState = EditFlowPerf.begin(
            EditFlowPerf.Stage.ReadFile.storeReadContentForwardAwait,
            EditFlowPerf.Dimensions(workloadClass: workloadClass.rawValue)
        )
        do {
            let loaded = try await state.service.loadContentWithDate(
                ofRelativePath: StandardizedPath.relative(relativePath),
                workloadClass: workloadClass
            )
            try await requirePublishedSeededAuthorityFresh(rootID: rootID)
            EditFlowPerf.end(
                EditFlowPerf.Stage.ReadFile.storeReadContentForwardAwait,
                forwardState,
                EditFlowPerf.Dimensions(outcome: "returned", workloadClass: workloadClass.rawValue)
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.storeReadContentReturned,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(
                    outcome: "returned",
                    workloadClass: workloadClass.rawValue,
                    rootToken: state.service.diagnosticRootToken.uuidString
                )
            )
            return loaded
        } catch {
            EditFlowPerf.end(
                EditFlowPerf.Stage.ReadFile.storeReadContentForwardAwait,
                forwardState,
                EditFlowPerf.Dimensions(outcome: error is CancellationError ? "cancelled" : "error", workloadClass: workloadClass.rawValue)
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.storeReadContentReturned,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(
                    outcome: error is CancellationError ? "cancelled" : "error",
                    workloadClass: workloadClass.rawValue,
                    rootToken: state.service.diagnosticRootToken.uuidString
                )
            )
            throw error
        }
    }

    func fileExistsOnDisk(rootID: UUID, relativePath: String) async throws -> Bool {
        let state = try state(for: rootID)
        return await state.service.fileExistsOnDisk(relativePath: StandardizedPath.relative(relativePath))
    }

    func fileModificationDate(rootID: UUID, relativePath: String) async throws -> Date {
        let state = try state(for: rootID)
        return try await state.service.getFileModificationDate(atRelativePath: StandardizedPath.relative(relativePath))
    }

    func itemModificationDateIfAvailable(rootID: UUID, relativePath: String) async throws -> Date? {
        let state = try state(for: rootID)
        return await state.service.getItemModificationDateIfAvailable(atRelativePath: StandardizedPath.relative(relativePath))
    }

    func refreshIgnoreRules(rootID: UUID) async throws {
        let state = try state(for: rootID)
        try await state.service.refreshIgnoreRules()
    }

    func fullPath(rootID: UUID, relativePath: String) async -> String? {
        guard let state = rootStatesByID[rootID] else { return nil }
        return await state.service.fullPath(forRelativePath: StandardizedPath.relative(relativePath))
    }

    func codemapAutomaticSelectionSourceIdentities(
        forFileIDs sourceFileIDs: [UUID],
        rootScope: WorkspaceLookupRootScope
    ) -> [WorkspaceCodemapAutomaticSelectionSourceIdentity] {
        let allowedRootIDs = Set(rootsForPathLookup(scope: rootScope).map(\.id))
        var seenFileIDs = Set<UUID>()
        return sourceFileIDs.compactMap { fileID in
            guard seenFileIDs.insert(fileID).inserted,
                  let file = filesByID[fileID],
                  allowedRootIDs.contains(file.rootID),
                  isDiscoverableFileID(fileID),
                  let state = rootStatesByID[file.rootID],
                  state.fileIDsByRelativePath[file.standardizedRelativePath] == fileID,
                  let catalogGeneration = catalogGenerationsByRootID[file.rootID]
            else { return nil }
            return WorkspaceCodemapAutomaticSelectionSourceIdentity(
                rootEpoch: WorkspaceCodemapRootEpoch(
                    rootID: file.rootID,
                    rootLifetimeID: state.lifetimeID
                ),
                fileID: fileID,
                catalogGeneration: catalogGeneration
            )
        }
    }

    func codemapStructureSeedAdmission(
        forFileIDs fileIDs: [UUID],
        rootScope: WorkspaceLookupRootScope,
        maximumUniqueFileCount: Int
    ) -> WorkspaceCodemapStructureSeedAdmission {
        precondition(maximumUniqueFileCount > 0)
        #if DEBUG
            codemapStructureSeedAdmissionRequestCountForTesting += 1
        #endif
        let allowedRootIDs = Set(rootsForPathLookup(scope: rootScope).map(\.id))
        var seenInputFileIDs = Set<UUID>()
        var seenStandardizedFullPaths = Set<String>()
        var admittedFileIDs: [UUID] = []
        var issues: [WorkspaceCodemapOperationCandidateIssue] = []

        for fileID in fileIDs where seenInputFileIDs.insert(fileID).inserted {
            guard let file = filesByID[fileID], isDiscoverableFileID(fileID) else {
                issues.append(.fileNotCataloged(fileID))
                continue
            }
            guard allowedRootIDs.contains(file.rootID) else {
                issues.append(.fileOutsideRootScope(fileID))
                continue
            }
            guard let state = rootStatesByID[file.rootID],
                  state.fileIDsByRelativePath[file.standardizedRelativePath] == fileID,
                  catalogGenerationsByRootID[file.rootID] != nil
            else {
                issues.append(.fileNotCataloged(fileID))
                continue
            }
            guard seenStandardizedFullPaths.insert(file.standardizedFullPath).inserted else {
                continue
            }
            admittedFileIDs.append(fileID)
            if admittedFileIDs.count > maximumUniqueFileCount {
                return WorkspaceCodemapStructureSeedAdmission(
                    fileIDs: admittedFileIDs,
                    issues: issues,
                    didExceedLimit: true
                )
            }
        }
        return WorkspaceCodemapStructureSeedAdmission(
            fileIDs: admittedFileIDs,
            issues: issues,
            didExceedLimit: false
        )
    }

    func codemapOperationPresentationCandidates(
        forFileIDs fileIDs: [UUID],
        rootScope: WorkspaceLookupRootScope,
        logicalRootDisplayNamesByRootID: [UUID: String] = [:],
        includeCompleteRootCatalogs: Bool = false
    ) -> WorkspaceCodemapOperationCandidateCollection {
        #if DEBUG
            codemapPresentationCandidateRequestCountForTesting += 1
        #endif
        let scopedRoots = rootsForPathLookup(scope: rootScope)
        let allowedRootIDs = Set(scopedRoots.map(\.id))
        let defaultRootLabels = WorkspaceLogicalRootIdentity.labels(for: scopedRoots.compactMap { root in
            guard let state = rootStatesByID[root.id] else { return nil }
            return WorkspaceLogicalRootIdentity.RootDescriptor(
                physicalRootID: root.id,
                rootEpoch: WorkspaceCodemapRootEpoch(
                    rootID: root.id,
                    rootLifetimeID: state.lifetimeID
                ),
                preferredName: root.name
            )
        })
        let effectiveRootLabels = defaultRootLabels.merging(logicalRootDisplayNamesByRootID) {
            _, supplied in supplied
        }
        var seenFileIDs = Set<UUID>()
        var candidates: [WorkspaceCodemapOperationPresentationCandidate] = []
        var issues: [WorkspaceCodemapOperationCandidateIssue] = []

        for fileID in fileIDs where seenFileIDs.insert(fileID).inserted {
            guard let file = filesByID[fileID], isDiscoverableFileID(fileID) else {
                issues.append(.fileNotCataloged(fileID))
                continue
            }
            guard allowedRootIDs.contains(file.rootID) else {
                issues.append(.fileOutsideRootScope(fileID))
                continue
            }
            guard let state = rootStatesByID[file.rootID],
                  state.fileIDsByRelativePath[file.standardizedRelativePath] == fileID,
                  let catalogGeneration = catalogGenerationsByRootID[file.rootID]
            else {
                issues.append(.fileNotCataloged(fileID))
                continue
            }
            guard let logicalPath = WorkspaceCodemapLogicalPresentationPath(
                rootDisplayName: effectiveRootLabels[file.rootID] ?? state.root.name,
                standardizedRelativePath: file.standardizedRelativePath
            ) else {
                issues.append(.logicalPathUnavailable(fileID))
                continue
            }
            candidates.append(WorkspaceCodemapOperationPresentationCandidate(
                fileID: fileID,
                rootEpoch: WorkspaceCodemapRootEpoch(
                    rootID: file.rootID,
                    rootLifetimeID: state.lifetimeID
                ),
                catalogGeneration: catalogGeneration,
                logicalPath: logicalPath
            ))
        }

        candidates.sort {
            if $0.logicalPath.displayPath != $1.logicalPath.displayPath {
                return $0.logicalPath.displayPath.utf8.lexicographicallyPrecedes(
                    $1.logicalPath.displayPath.utf8
                )
            }
            return $0.fileID.uuidString < $1.fileID.uuidString
        }
        let completeRootCatalogs: [WorkspaceCodemapOperationCompleteRootCatalogReceipt]
        if includeCompleteRootCatalogs {
            completeRootCatalogs = rootsForPathLookup(scope: rootScope).compactMap { root in
                guard let state = rootStatesByID[root.id],
                      let catalogGeneration = catalogGenerationsByRootID[root.id]
                else { return nil }
                let supportedFileIDs = state.fileIDsByRelativePath.values.filter { fileID in
                    guard isDiscoverableFileID(fileID), let file = filesByID[fileID] else { return false }
                    let fileExtension = (file.name as NSString).pathExtension
                    return SyntaxManager.supportsCodeMap(fileExtension: fileExtension)
                }.sorted { $0.uuidString < $1.uuidString }
                return WorkspaceCodemapOperationCompleteRootCatalogReceipt(
                    rootEpoch: WorkspaceCodemapRootEpoch(
                        rootID: root.id,
                        rootLifetimeID: state.lifetimeID
                    ),
                    catalogGeneration: catalogGeneration,
                    supportedFileIDs: supportedFileIDs
                )
            }.sorted { codemapRootEpochPrecedes($0.rootEpoch, $1.rootEpoch) }
            let requestedCandidateIDs = Set(candidates.map(\.fileID))
            let missingFileIDs = completeRootCatalogs.flatMap(\.supportedFileIDs)
                .filter { !requestedCandidateIDs.contains($0) }
            if !missingFileIDs.isEmpty {
                issues.append(.incompleteRootSet(missingFileIDs: missingFileIDs))
            }
        } else {
            completeRootCatalogs = []
        }
        issues.sort { candidateIssueSortKey($0) < candidateIssueSortKey($1) }
        return WorkspaceCodemapOperationCandidateCollection(
            candidates: candidates,
            issues: issues,
            completeRootCatalogs: completeRootCatalogs
        )
    }

    private func candidateIssueSortKey(
        _ issue: WorkspaceCodemapOperationCandidateIssue
    ) -> String {
        switch issue {
        case let .fileNotCataloged(fileID):
            "0:file_not_cataloged:\(fileID.uuidString)"
        case let .fileOutsideRootScope(fileID):
            "1:file_outside_root_scope:\(fileID.uuidString)"
        case let .logicalPathUnavailable(fileID):
            "2:logical_path_unavailable:\(fileID.uuidString)"
        case let .incompleteRootSet(missingFileIDs):
            "3:incomplete_root_set:\(missingFileIDs.map(\.uuidString).sorted().joined(separator: ","))"
        }
    }

    func planAutomaticCodemapSelectionCandidates(
        sources: [WorkspaceCodemapAutomaticSelectionSourceIdentity],
        rootScope: WorkspaceLookupRootScope,
        maximumCandidateDemandCount: Int = 1024
    ) async -> WorkspaceCodemapAutomaticSelectionCandidatePlanDisposition {
        guard !sources.isEmpty else { return .unavailable(.noReadySources) }
        guard maximumCandidateDemandCount > 0 else {
            return .budget(.candidateDemandLimit(attempted: 1, limit: 0))
        }
        let rootScopeEpochs = codemapAutomaticSelectionRootScopeEpochs(rootScope)
        let allowedRootIDs = Set(rootScopeEpochs.map(\.rootID))
        let sourceIDsByRoot = Dictionary(grouping: sources, by: \.rootEpoch)
        let orderedRootEpochs = sourceIDsByRoot.keys.sorted(by: codemapRootEpochPrecedes)
        var graphSources: [WorkspaceCodemapStoreSelectionGraphSourceIdentity] = []
        var sourceTicketsByIdentity: [
            WorkspaceCodemapAutomaticSelectionSourceIdentity: WorkspaceCodemapArtifactDemandTicket
        ] = [:]
        var catalogShardsByRootEpoch: [WorkspaceCodemapRootEpoch: RootCatalogShard] = [:]

        for rootEpoch in orderedRootEpochs {
            guard allowedRootIDs.contains(rootEpoch.rootID),
                  let state = rootStatesByID[rootEpoch.rootID],
                  state.lifetimeID == rootEpoch.rootLifetimeID,
                  let session = codemapSessionsByRootEpoch[rootEpoch]
            else {
                return .stale(.rootEpochNotCurrent(rootEpoch))
            }
            let rootSources = sourceIDsByRoot[rootEpoch] ?? []
            for source in rootSources {
                guard let record = session.demandsByFileID[source.fileID],
                      case let .ready(ready) = record.result,
                      codemapTicketsShareDemand(ready.ticket, record.ticket),
                      codemapDemandIsCurrent(ready.ticket)
                else {
                    return .pending([.manifestAdmission(rootEpoch: rootEpoch)])
                }
                graphSources.append(WorkspaceCodemapStoreSelectionGraphSourceIdentity(
                    ticket: ready.ticket
                ))
                sourceTicketsByIdentity[source] = ready.ticket
            }
            guard let catalogShard = automaticSelectionCatalogShard(rootEpoch: rootEpoch) else {
                return .stale(.rootEpochNotCurrent(rootEpoch))
            }
            catalogShardsByRootEpoch[rootEpoch] = catalogShard
        }

        var provisionalCandidates: [WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate] = []
        var provisionalIncompleteReasons: [WorkspaceCodemapAutomaticSelectionIncompleteReason] = []
        for rootEpoch in orderedRootEpochs {
            guard let session = codemapSessionsByRootEpoch[rootEpoch],
                  let engine = session.engine,
                  let catalogShard = catalogShardsByRootEpoch[rootEpoch]
            else { continue }
            let rootSourceTickets = (sourceIDsByRoot[rootEpoch] ?? []).compactMap {
                sourceTicketsByIdentity[$0]
            }
            let catalogCandidates = catalogShard.projectionFiles.compactMap {
                automaticSelectionCatalogCandidate(
                    projectionFile: $0,
                    rootEpoch: rootEpoch,
                    catalogShard: catalogShard
                )
            }
            let engineDisposition = await engine.planAutomaticSelectionCandidates(
                WorkspaceCodemapBindingAutomaticSelectionPlanRequest(
                    rootEpoch: rootEpoch,
                    sourceTickets: rootSourceTickets,
                    candidates: catalogCandidates,
                    maximumMatchedCandidateCount: maximumCandidateDemandCount
                )
            )
            if case let .provisional(candidates, _, progress, remainingCount, retry) = engineDisposition {
                let remainingCapacity = maximumCandidateDemandCount - provisionalCandidates.count
                guard candidates.count <= remainingCapacity else {
                    return .budget(.candidateDemandLimit(
                        attempted: maximumCandidateDemandCount + 1,
                        limit: maximumCandidateDemandCount
                    ))
                }
                provisionalCandidates.append(contentsOf: candidates)
                provisionalIncompleteReasons.append(.graph(.definitionUniverse(
                    rootEpoch: rootEpoch,
                    progress: progress,
                    remainingCount: remainingCount,
                    retry: retry
                )))
            }
        }
        let provisionalFallbackDisposition: WorkspaceCodemapAutomaticSelectionCandidatePlanDisposition? = if !provisionalCandidates.isEmpty {
            .provisional(WorkspaceCodemapAutomaticSelectionProvisionalCandidatePlan(
                candidates: provisionalCandidates.sorted(by: automaticSelectionCandidatePrecedes),
                rootScopeEpochs: rootScopeEpochs,
                incompleteReasons: provisionalIncompleteReasons
            ))
        } else {
            nil
        }

        let basePolicy = selectionGraphQueryBudgetPolicy
        let queryPolicy = WorkspaceCodemapStoreSelectionGraphQueryBudgetPolicy(
            maximumRootCount: basePolicy.maximumRootCount,
            maximumRawSourceCount: basePolicy.maximumRawSourceCount,
            maximumUniqueSourceCount: basePolicy.maximumUniqueSourceCount,
            maximumSourceIssueCount: basePolicy.maximumSourceIssueCount,
            maximumTargetCount: maximumCandidateDemandCount,
            maximumResolutionCount: basePolicy.maximumResolutionCount,
            maximumReferenceFailureCount: basePolicy.maximumReferenceFailureCount,
            maximumByteCount: basePolicy.maximumByteCount
        )
        let disposition = await queryCodemapSelectionGraph(
            WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: graphSources),
            budgetPolicy: queryPolicy
        )
        await codemapAutomaticSelectionQueryHook(orderedRootEpochs[0])
        guard codemapAutomaticSelectionRootScopeEpochs(rootScope) == rootScopeEpochs else {
            return .stale(.rootEpochNotCurrent(orderedRootEpochs[0]))
        }
        for rootEpoch in orderedRootEpochs {
            guard let capturedShard = catalogShardsByRootEpoch[rootEpoch],
                  automaticSelectionCatalogShard(rootEpoch: rootEpoch) === capturedShard
            else { return .stale(.coverageProof(rootEpoch)) }
        }
        for source in sources {
            guard let capturedTicket = sourceTicketsByIdentity[source],
                  let record = codemapSessionsByRootEpoch[source.rootEpoch]?
                  .demandsByFileID[source.fileID],
                  case let .ready(ready) = record.result,
                  codemapTicketsShareDemand(capturedTicket, ready.ticket),
                  codemapTicketsShareDemand(ready.ticket, record.ticket),
                  ready.ticket.requestGeneration == capturedTicket.requestGeneration,
                  codemapDemandIsCurrent(capturedTicket)
            else { return .stale(.sourceStateChanged(source)) }
        }

        switch disposition {
        case let .readyPartial(queryResult):
            guard queryResult.roots.count == orderedRootEpochs.count else {
                return .unavailable(.graph(.invalidGraphResult(orderedRootEpochs[0])))
            }
            let selectedFileIDs = Set(sources.map(\.fileID))
            var plannedCandidates: [WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate] = []
            var coverageProofs: [WorkspaceCodemapProjectionCoverageProof] = []
            for rootEpoch in orderedRootEpochs {
                guard let catalogShard = catalogShardsByRootEpoch[rootEpoch],
                      automaticSelectionCatalogShard(rootEpoch: rootEpoch) === catalogShard,
                      let supportedCandidateCount = UInt64(exactly: catalogShard.projectionFiles.count)
                else { return .stale(.coverageProof(rootEpoch)) }
                guard let rootResult = queryResult.roots.first(where: { $0.rootEpoch == rootEpoch }),
                      case let .complete(proof, candidateCount, _, _) =
                      rootResult.result.definitionUniverseCoverage,
                      candidateCount == supportedCandidateCount,
                      proof.catalogCompletion.supportedCandidateCount == candidateCount,
                      automaticSelectionCoverageProofIsCurrent(proof)
                else { return .stale(.coverageProof(rootEpoch)) }
                for endpoint in rootResult.result.targets where !selectedFileIDs.contains(endpoint.fileID) {
                    guard let candidate = automaticSelectionCatalogCandidate(
                        endpoint: endpoint,
                        rootEpoch: rootEpoch,
                        catalogShard: catalogShard
                    )
                    else { return .stale(.coverageProof(rootEpoch)) }
                    plannedCandidates.append(candidate)
                }
                coverageProofs.append(proof)
            }
            plannedCandidates.sort(by: automaticSelectionCandidatePrecedes)
            return .ready(WorkspaceCodemapAutomaticSelectionCandidatePlan(
                candidates: plannedCandidates,
                rootScopeEpochs: rootScopeEpochs,
                coverageProofs: coverageProofs
            ))
        case let .incomplete(reason):
            return provisionalFallbackDisposition ?? .incomplete([.graph(reason)])
        case let .busy(reason):
            return provisionalFallbackDisposition ?? .busy(reason)
        case let .unavailable(reason):
            return .unavailable(.graph(reason))
        case let .stale(reason):
            return .stale(.graph(reason))
        case let .budget(reason):
            let budgetDisposition: WorkspaceCodemapAutomaticSelectionCandidatePlanDisposition = if case let .targetLimit(attempted, _) = reason {
                .budget(.candidateDemandLimit(
                    attempted: attempted,
                    limit: maximumCandidateDemandCount
                ))
            } else {
                .budget(codemapAutomaticSelectionBudgetReason(
                    reason,
                    rootEpoch: orderedRootEpochs.first
                ))
            }
            return budgetDisposition
        }
    }

    private func automaticSelectionCatalogShard(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> RootCatalogShard? {
        guard let state = rootStatesByID[rootEpoch.rootID],
              state.lifetimeID == rootEpoch.rootLifetimeID,
              let session = codemapSessionsByRootEpoch[rootEpoch],
              let shard = publishedRootCatalogShardsByRootID[rootEpoch.rootID],
              shard.key.rootID == rootEpoch.rootID,
              shard.key.lifetimeID == rootEpoch.rootLifetimeID,
              shard.root.id == rootEpoch.rootID,
              shard.root.standardizedFullPath == session.authority.standardizedRootPath,
              session.authority.rootEpoch == rootEpoch
        else { return nil }
        return shard
    }

    private func automaticSelectionCatalogCandidate(
        endpoint: WorkspaceCodemapSelectionGraphRuntimeEndpoint,
        rootEpoch: WorkspaceCodemapRootEpoch,
        catalogShard: RootCatalogShard
    ) -> WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate? {
        guard endpoint.rootEpoch == rootEpoch,
              automaticSelectionCatalogShard(rootEpoch: rootEpoch) === catalogShard,
              let state = rootStatesByID[rootEpoch.rootID],
              let session = codemapSessionsByRootEpoch[rootEpoch],
              let projectionIndex = catalogShard.projectionFileIndexByID[endpoint.fileID]
        else { return nil }
        let projectionFile = catalogShard.projectionFiles[projectionIndex]
        let file = projectionFile.file
        let fileExtension = (file.name as NSString).pathExtension
        guard isDiscoverableFileID(file.id),
              filesByID[file.id] == file,
              state.fileIDsByRelativePath[file.standardizedRelativePath] == file.id,
              SyntaxManager.supportsCodeMap(fileExtension: fileExtension),
              SyntaxManager.shared.language(forFileExtension: fileExtension) == projectionFile.language,
              let identity = WorkspaceCodemapArtifactBindingIdentity(
                  rootID: rootEpoch.rootID,
                  rootLifetimeID: rootEpoch.rootLifetimeID,
                  fileID: file.id,
                  standardizedRootPath: session.authority.standardizedRootPath,
                  standardizedRelativePath: file.standardizedRelativePath,
                  standardizedFullPath: file.standardizedFullPath
              )
        else { return nil }
        let pathGeneration = session.pathGenerationsByRelativePath[file.standardizedRelativePath]
            ?? session.authority.ingressGeneration
        guard endpoint.requestGeneration == pathGeneration else { return nil }
        return WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate(
            identity: identity,
            language: projectionFile.language,
            requestGeneration: pathGeneration,
            catalogGeneration: session.authority.catalogGeneration,
            pathGeneration: pathGeneration,
            ingressGeneration: session.authority.ingressGeneration
        )
    }

    private func automaticSelectionCatalogCandidate(
        projectionFile: RootCatalogProjectionFile,
        rootEpoch: WorkspaceCodemapRootEpoch,
        catalogShard: RootCatalogShard
    ) -> WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate? {
        guard automaticSelectionCatalogShard(rootEpoch: rootEpoch) === catalogShard,
              let state = rootStatesByID[rootEpoch.rootID],
              let session = codemapSessionsByRootEpoch[rootEpoch]
        else { return nil }
        let file = projectionFile.file
        let fileExtension = (file.name as NSString).pathExtension
        guard isDiscoverableFileID(file.id),
              filesByID[file.id] == file,
              state.fileIDsByRelativePath[file.standardizedRelativePath] == file.id,
              SyntaxManager.supportsCodeMap(fileExtension: fileExtension),
              SyntaxManager.shared.language(forFileExtension: fileExtension) == projectionFile.language,
              let identity = WorkspaceCodemapArtifactBindingIdentity(
                  rootID: rootEpoch.rootID,
                  rootLifetimeID: rootEpoch.rootLifetimeID,
                  fileID: file.id,
                  standardizedRootPath: session.authority.standardizedRootPath,
                  standardizedRelativePath: file.standardizedRelativePath,
                  standardizedFullPath: file.standardizedFullPath
              )
        else { return nil }
        let pathGeneration = session.pathGenerationsByRelativePath[file.standardizedRelativePath]
            ?? session.authority.ingressGeneration
        return WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate(
            identity: identity,
            language: projectionFile.language,
            requestGeneration: pathGeneration,
            catalogGeneration: session.authority.catalogGeneration,
            pathGeneration: pathGeneration,
            ingressGeneration: session.authority.ingressGeneration
        )
    }

    func automaticCodemapSelectionSourceDemandLimit() -> Int {
        selectionGraphQueryBudgetPolicy.maximumRawSourceCount
    }

    private func codemapAutomaticSelectionRootScopeEpochs(
        _ rootScope: WorkspaceLookupRootScope
    ) -> [WorkspaceCodemapRootEpoch] {
        rootsForPathLookup(scope: rootScope).compactMap { root in
            guard let state = rootStatesByID[root.id] else { return nil }
            return WorkspaceCodemapRootEpoch(
                rootID: root.id,
                rootLifetimeID: state.lifetimeID
            )
        }.sorted(by: codemapRootEpochPrecedes)
    }

    private func automaticSelectionCoverageProofIsCurrent(
        _ proof: WorkspaceCodemapProjectionCoverageProof
    ) -> Bool {
        let rootEpoch = proof.generation.rootEpoch
        guard !codemapProjectionCatalogIsFenced(rootEpoch: rootEpoch),
              let session = codemapSessionsByRootEpoch[rootEpoch],
              codemapAuthorityIsCurrent(session.authority),
              let currentCatalog = codemapProjectionCatalogShardAndToken(
                  authority: session.authority
              ),
              currentCatalog.token == proof.generation.catalogToken,
              let graphState = session.selectionGraph
        else { return false }
        let graphKey = WorkspaceCodemapSelectionGraphRuntimeKey(generation: proof.generation)
        guard graphState.desiredKey == graphKey,
              let summary = graphState.publishedSummary,
              summary.key == graphKey,
              case let .complete(currentProof, _, _, _) = summary.definitionUniverseCoverage,
              currentProof == proof
        else { return false }
        return true
    }

    private func automaticSelectionCoverageProofsAreCurrent(
        _ proofs: [WorkspaceCodemapProjectionCoverageProof]
    ) -> Bool {
        guard !proofs.isEmpty else { return false }
        var rootEpochs = Set<WorkspaceCodemapRootEpoch>()
        for proof in proofs {
            guard rootEpochs.insert(proof.generation.rootEpoch).inserted,
                  automaticSelectionCoverageProofIsCurrent(proof)
            else { return false }
        }
        return true
    }

    func provisionalAutomaticCodemapSelectionResult(
        sources: [WorkspaceCodemapAutomaticSelectionSourceIdentity],
        plan: WorkspaceCodemapAutomaticSelectionProvisionalCandidatePlan,
        readyCandidates: [WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate],
        pendingReasons: [WorkspaceCodemapAutomaticSelectionPendingReason],
        partialReasons: [WorkspaceCodemapAutomaticSelectionPartialReason],
        rootScope: WorkspaceLookupRootScope
    ) -> WorkspaceCodemapAutomaticSelectionResult {
        guard codemapAutomaticSelectionRootScopeEpochs(rootScope) == plan.rootScopeEpochs else {
            return WorkspaceCodemapAutomaticSelectionResult(
                roots: [],
                aggregateCoverage: .stale(.publicationReceipt)
            )
        }

        var sourceTickets: [WorkspaceCodemapArtifactDemandTicket] = []
        sourceTickets.reserveCapacity(sources.count)
        for source in sources {
            guard let record = codemapSessionsByRootEpoch[source.rootEpoch]?
                .demandsByFileID[source.fileID],
                case let .ready(ready) = record.result,
                codemapTicketsShareDemand(record.ticket, ready.ticket),
                codemapDemandIsCurrent(ready.ticket),
                ready.snapshot.requestGeneration == ready.ticket.requestGeneration
            else {
                return WorkspaceCodemapAutomaticSelectionResult(
                    roots: [],
                    aggregateCoverage: .stale(.sourceStateChanged(source))
                )
            }
            sourceTickets.append(ready.ticket)
        }

        let sourceSlots = Set(sources.map {
            WorkspaceCodemapRootScopedFileSlot(rootEpoch: $0.rootEpoch, fileID: $0.fileID)
        })
        var selectedCandidates: [WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate] = []
        var seenCandidateSlots = Set<WorkspaceCodemapRootScopedFileSlot>()
        for candidate in readyCandidates.sorted(by: automaticSelectionCandidatePrecedes) {
            let slot = WorkspaceCodemapRootScopedFileSlot(candidate: candidate)
            guard seenCandidateSlots.insert(slot).inserted else { continue }
            selectedCandidates.append(candidate)
        }

        var targetCandidates: [WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate] = []
        var targets: [WorkspaceCodemapAutomaticSelectionTarget] = []
        var provisionalPartial = partialReasons
        for candidate in selectedCandidates {
            let rootEpoch = candidate.rootEpoch
            let slot = WorkspaceCodemapRootScopedFileSlot(candidate: candidate)
            guard !sourceSlots.contains(slot),
                  provisionalAutomaticSelectionCandidateDemandIsCurrent(
                      candidate: candidate,
                      rootScope: rootScope,
                      rootScopeEpochs: plan.rootScopeEpochs
                  ),
                  let state = rootStatesByID[rootEpoch.rootID],
                  let file = filesByID[candidate.identity.fileID],
                  let session = codemapSessionsByRootEpoch[rootEpoch],
                  let record = session.demandsByFileID[file.id],
                  case let .ready(ready) = record.result,
                  codemapTicketsShareDemand(record.ticket, ready.ticket),
                  ready.ticket.requestGeneration == candidate.requestGeneration,
                  ready.snapshot.requestGeneration == candidate.requestGeneration,
                  codemapDemandIsCurrent(ready.ticket),
                  let logicalPath = WorkspaceCodemapLogicalPresentationPath(
                      rootDisplayName: state.root.name,
                      standardizedRelativePath: file.standardizedRelativePath
                  )
            else {
                // Revalidation cannot distinguish unavailable causes here; staleCurrentness is the conservative catch-all.
                provisionalPartial.append(.candidateUnavailable(
                    rootEpoch: rootEpoch,
                    fileID: candidate.identity.fileID,
                    reason: .staleCurrentness
                ))
                continue
            }
            targetCandidates.append(candidate)
            targets.append(WorkspaceCodemapAutomaticSelectionTarget(
                rootEpoch: rootEpoch,
                fileID: file.id,
                catalogGeneration: candidate.catalogGeneration,
                requestGeneration: candidate.requestGeneration,
                logicalPath: logicalPath
            ))
        }

        targets.sort(by: automaticSelectionTargetPrecedes)
        let targetSlots = Set(targets.map { WorkspaceCodemapRootScopedFileSlot(rootEpoch: $0.rootEpoch, fileID: $0.fileID) })
        targetCandidates.sort(by: automaticSelectionCandidatePrecedes)
        let diagnosticRootEpochs = Set(
            plan.incompleteReasons.compactMap(automaticSelectionIncompleteReasonRootEpoch) +
                pendingReasons.compactMap(automaticSelectionPendingReasonRootEpoch) +
                provisionalPartial.compactMap(automaticSelectionPartialReasonRootEpoch) +
                sources.map(\.rootEpoch) +
                targetSlots.map(\.rootEpoch)
        )
        let orderedRootEpochs = diagnosticRootEpochs.sorted(by: codemapRootEpochPrecedes)
        let fallbackRootEpoch = orderedRootEpochs.first
        let roots: [WorkspaceCodemapAutomaticSelectionRootResult] = orderedRootEpochs.map { rootEpoch in
            let rootTargets = targets.filter { $0.rootEpoch == rootEpoch }
            let rootIncomplete = plan.incompleteReasons.filter {
                automaticSelectionIncompleteReasonRootEpoch($0) == rootEpoch
            }
            let rootPending = pendingReasons.filter {
                automaticSelectionPendingReasonRootEpoch($0) == rootEpoch
            }
            let rootPartial = provisionalPartial.filter {
                let reasonRoot = automaticSelectionPartialReasonRootEpoch($0)
                return reasonRoot == rootEpoch || (reasonRoot == nil && rootEpoch == fallbackRootEpoch)
            }
            return WorkspaceCodemapAutomaticSelectionRootResult(
                rootEpoch: rootEpoch,
                targets: rootTargets,
                sourceIssues: [],
                targetIssues: [],
                coverage: .provisional(
                    incomplete: rootIncomplete,
                    pending: rootPending,
                    partial: rootPartial
                )
            )
        }
        let aggregateCoverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage.provisional(
            incomplete: plan.incompleteReasons,
            pending: pendingReasons,
            partial: provisionalPartial
        )
        guard !targets.isEmpty else {
            return WorkspaceCodemapAutomaticSelectionResult(
                roots: roots,
                aggregateCoverage: aggregateCoverage
            )
        }
        guard Set(targets).count == targets.count,
              targetSlots.count == targets.count,
              targetCandidates.count == targets.count,
              Set(targetCandidates.map { WorkspaceCodemapRootScopedFileSlot(candidate: $0) }).count == targetCandidates.count
        else {
            return WorkspaceCodemapAutomaticSelectionResult(
                roots: [],
                aggregateCoverage: .stale(.publicationReceipt)
            )
        }
        let requestID = UUID()
        let publicationPermit = WorkspaceCodemapAutomaticSelectionPublicationPermit()
        registerAutomaticSelectionPublicationPermit(
            publicationPermit,
            requestID: requestID,
            rootScopeEpochs: plan.rootScopeEpochs
        )
        let receipt = WorkspaceCodemapAutomaticSelectionPublicationReceipt(
            requestID: requestID,
            rootScope: rootScope,
            rootScopeEpochs: plan.rootScopeEpochs,
            sourceTickets: sourceTickets,
            graphKeys: [],
            coverageProofs: [],
            targets: targets,
            publicationBasis: .provisionalCandidates(targetCandidates),
            publicationPermit: publicationPermit
        )
        return WorkspaceCodemapAutomaticSelectionResult(
            roots: roots,
            aggregateCoverage: aggregateCoverage,
            publicationReceipt: receipt
        )
    }

    private func automaticSelectionTargetPrecedes(
        _ lhs: WorkspaceCodemapAutomaticSelectionTarget,
        _ rhs: WorkspaceCodemapAutomaticSelectionTarget
    ) -> Bool {
        if lhs.rootEpoch != rhs.rootEpoch { return codemapRootEpochPrecedes(lhs.rootEpoch, rhs.rootEpoch) }
        if lhs.logicalPath.standardizedRelativePath != rhs.logicalPath.standardizedRelativePath {
            return lhs.logicalPath.standardizedRelativePath.utf8.lexicographicallyPrecedes(
                rhs.logicalPath.standardizedRelativePath.utf8
            )
        }
        return lhs.fileID.uuidString < rhs.fileID.uuidString
    }

    private func automaticSelectionIncompleteReasonRootEpoch(
        _ reason: WorkspaceCodemapAutomaticSelectionIncompleteReason
    ) -> WorkspaceCodemapRootEpoch? {
        switch reason {
        case let .graph(.definitionUniverse(rootEpoch, _, _, _)):
            rootEpoch
        }
    }

    private func automaticSelectionPendingReasonRootEpoch(
        _ reason: WorkspaceCodemapAutomaticSelectionPendingReason
    ) -> WorkspaceCodemapRootEpoch? {
        switch reason {
        case let .sourceDemand(source, _), let .sourceBusy(source, _):
            source.rootEpoch
        case let .candidateDemand(rootEpoch, _, _), let .candidateBusy(rootEpoch, _, _),
             let .manifestAdmission(rootEpoch), let .graphRebuild(rootEpoch):
            rootEpoch
        }
    }

    private func automaticSelectionPartialReasonRootEpoch(
        _ reason: WorkspaceCodemapAutomaticSelectionPartialReason
    ) -> WorkspaceCodemapRootEpoch? {
        switch reason {
        case .graph:
            nil
        case let .source(issue):
            switch issue {
            case let .outsideRootScope(source), let .notCataloged(source),
                 let .notDemanded(source), let .pending(source, _),
                 let .unavailable(source, _), let .staleCatalogGeneration(source, _):
                source.rootEpoch
            }
        case let .sourceDemandTimedOut(source):
            source.rootEpoch
        case let .candidateUnavailable(rootEpoch, _, _):
            rootEpoch
        }
    }

    private func registerAutomaticSelectionPublicationPermit(
        _ permit: WorkspaceCodemapAutomaticSelectionPublicationPermit,
        requestID: UUID,
        rootScopeEpochs: [WorkspaceCodemapRootEpoch]
    ) {
        for rootEpoch in rootScopeEpochs {
            var permits = codemapAutomaticSelectionPublicationPermitsByRootEpoch[rootEpoch] ?? [:]
            permits = permits.filter { $0.value.permit != nil }
            permits[requestID] = CodemapAutomaticSelectionWeakPublicationPermit(permit)
            codemapAutomaticSelectionPublicationPermitsByRootEpoch[rootEpoch] = permits
        }
    }

    private func revokeAutomaticSelectionPublicationPermits(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) {
        let permits = codemapAutomaticSelectionPublicationPermitsByRootEpoch
            .removeValue(forKey: rootEpoch) ?? [:]
        for weakPermit in permits.values {
            weakPermit.permit?.revoke()
        }
    }

    private func revokeAllAutomaticSelectionPublicationPermits() {
        let permitGroups = codemapAutomaticSelectionPublicationPermitsByRootEpoch.values
        codemapAutomaticSelectionPublicationPermitsByRootEpoch.removeAll()
        for permits in permitGroups {
            for weakPermit in permits.values {
                weakPermit.permit?.revoke()
            }
        }
    }

    private func automaticSelectionAccountingCanRepresent(
        _ policy: WorkspaceCodemapStoreSelectionGraphQueryBudgetPolicy
    ) -> Bool {
        addingAutomaticSelectionCount(policy.maximumSourceIssueCount, 1) != nil &&
            addingAutomaticSelectionCount(policy.maximumTargetCount, 1) != nil &&
            addingAutomaticSelectionCount(policy.maximumResolutionCount, 1) != nil &&
            addingAutomaticSelectionCount(policy.maximumReferenceFailureCount, 1) != nil &&
            addingAutomaticSelectionCount(policy.maximumByteCount, 1) != nil
    }

    private func addingAutomaticSelectionCount(_ lhs: Int, _ rhs: Int) -> Int? {
        guard lhs >= 0, rhs >= 0,
              lhs <= automaticSelectionAccountingMaximum,
              rhs <= automaticSelectionAccountingMaximum
        else { return nil }
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow, sum <= automaticSelectionAccountingMaximum else { return nil }
        return sum
    }

    func resolveAutomaticCodemapSelection(
        sources: [WorkspaceCodemapAutomaticSelectionSourceIdentity],
        rootScope: WorkspaceLookupRootScope
    ) async throws -> WorkspaceCodemapAutomaticSelectionResult {
        try await resolveAutomaticCodemapSelection(
            sources: sources,
            rootScope: rootScope,
            targetAuthority: .retainedReadyDemand
        )
    }

    private func resolveAutomaticCodemapSelection(
        sources: [WorkspaceCodemapAutomaticSelectionSourceIdentity],
        rootScope: WorkspaceLookupRootScope,
        targetAuthority: AutomaticSelectionTargetAuthority
    ) async throws -> WorkspaceCodemapAutomaticSelectionResult {
        let budgetPolicy = selectionGraphQueryBudgetPolicy
        guard automaticSelectionAccountingCanRepresent(budgetPolicy) else {
            return codemapAutomaticSelectionAggregateBudgetResult(
                reason: .accountingOverflow
            )
        }
        guard sources.count <= budgetPolicy.maximumRawSourceCount else {
            return codemapAutomaticSelectionAggregateBudgetResult(
                reason: .sourceLimit(
                    attempted: sources.count,
                    limit: budgetPolicy.maximumRawSourceCount
                )
            )
        }

        var seenSources = Set<WorkspaceCodemapAutomaticSelectionSourceIdentity>()
        var uniqueSources: [WorkspaceCodemapAutomaticSelectionSourceIdentity] = []
        uniqueSources.reserveCapacity(min(sources.count, budgetPolicy.maximumUniqueSourceCount))
        for source in sources where seenSources.insert(source).inserted {
            guard uniqueSources.count < budgetPolicy.maximumUniqueSourceCount else {
                guard let attempted = addingAutomaticSelectionCount(uniqueSources.count, 1) else {
                    return codemapAutomaticSelectionAggregateBudgetResult(
                        reason: .accountingOverflow
                    )
                }
                return codemapAutomaticSelectionAggregateBudgetResult(
                    reason: .uniqueSourceLimit(
                        attempted: attempted,
                        limit: budgetPolicy.maximumUniqueSourceCount
                    )
                )
            }
            uniqueSources.append(source)
        }
        uniqueSources.sort(by: codemapAutomaticSelectionSourcePrecedes)

        var rootEpochs = Set<WorkspaceCodemapRootEpoch>()
        for source in uniqueSources where rootEpochs.insert(source.rootEpoch).inserted {
            guard rootEpochs.count <= budgetPolicy.maximumRootCount else {
                return codemapAutomaticSelectionAggregateBudgetResult(
                    reason: .rootLimit(
                        attempted: rootEpochs.count,
                        limit: budgetPolicy.maximumRootCount
                    )
                )
            }
        }
        let partitions = Dictionary(grouping: uniqueSources, by: \.rootEpoch)
        return try await resolveAutomaticCodemapSelection(
            partitions: partitions,
            orderedSources: uniqueSources,
            rootScope: rootScope,
            targetAuthority: targetAuthority,
            retryCount: 0
        )
    }

    private func resolveAutomaticCodemapSelection(
        partitions: [
            WorkspaceCodemapRootEpoch: [WorkspaceCodemapAutomaticSelectionSourceIdentity]
        ],
        orderedSources: [WorkspaceCodemapAutomaticSelectionSourceIdentity],
        rootScope: WorkspaceLookupRootScope,
        targetAuthority: AutomaticSelectionTargetAuthority,
        retryCount: Int
    ) async throws -> WorkspaceCodemapAutomaticSelectionResult {
        let budgetPolicy = selectionGraphQueryBudgetPolicy
        let snapshot = codemapAutomaticSelectionSnapshot(
            sources: orderedSources,
            rootScope: rootScope
        )
        let orderedRootEpochs = partitions.keys.sorted(by: codemapRootEpochPrecedes)
        var rootResults: [WorkspaceCodemapAutomaticSelectionRootResult] = []
        rootResults.reserveCapacity(orderedRootEpochs.count)
        var sourceIssueCount = 0
        var targetCount = 0
        var resolutionCount = 0
        var referenceFailureCount = 0
        var byteCount = 0

        for rootEpoch in orderedRootEpochs {
            try Task.checkCancellation()
            let remainingPolicy = budgetPolicy.remaining(
                targetCount: targetCount,
                resolutionCount: resolutionCount,
                referenceFailureCount: referenceFailureCount,
                byteCount: byteCount
            )
            var rootResult = try await resolveAutomaticCodemapSelection(
                sources: partitions[rootEpoch] ?? [],
                rootEpoch: rootEpoch,
                allowedRootIDs: snapshot.allowedRootIDs,
                rootScope: rootScope,
                targetAuthority: targetAuthority,
                sourceIssueAllowance: budgetPolicy.maximumSourceIssueCount - sourceIssueCount,
                queryBudgetPolicy: remainingPolicy
            )

            let currentSnapshot = codemapAutomaticSelectionSnapshot(
                sources: orderedSources,
                rootScope: rootScope
            )
            guard currentSnapshot == snapshot else {
                if retryCount == 0,
                   codemapAutomaticSelectionShouldRetry(
                       previous: snapshot,
                       current: currentSnapshot
                   )
                {
                    return try await resolveAutomaticCodemapSelection(
                        partitions: partitions,
                        orderedSources: orderedSources,
                        rootScope: rootScope,
                        targetAuthority: targetAuthority,
                        retryCount: 1
                    )
                }
                if case .stale = rootResult.coverage {
                    return WorkspaceCodemapAutomaticSelectionResult(roots: [rootResult])
                }
                return codemapAutomaticSelectionStaleResult(
                    previous: snapshot,
                    current: currentSnapshot,
                    orderedRootEpochs: orderedRootEpochs,
                    orderedSources: orderedSources
                )
            }

            rootResult = codemapAutomaticSelectionTranslatingBudget(
                rootResult,
                sourceIssueCount: sourceIssueCount,
                targetCount: targetCount,
                resolutionCount: resolutionCount,
                referenceFailureCount: referenceFailureCount,
                byteCount: byteCount,
                budgetPolicy: budgetPolicy
            )
            if case let .budget(reason) = rootResult.coverage {
                return WorkspaceCodemapAutomaticSelectionResult(
                    roots: [],
                    aggregateCoverage: .budget(codemapAutomaticSelectionBudgetReason(
                        reason,
                        rootEpoch: rootEpoch
                    ))
                )
            }
            switch rootResult.coverage {
            case .complete, .partial:
                break
            case .provisional, .incomplete, .pending, .unavailable, .stale, .busy, .budget:
                return WorkspaceCodemapAutomaticSelectionResult(roots: [rootResult])
            }

            guard let nextSourceIssueCount = addingAutomaticSelectionCount(
                sourceIssueCount,
                rootResult.sourceIssues.count
            ), let nextTargetCount = addingAutomaticSelectionCount(
                targetCount,
                rootResult.graphTargetCount
            ), let nextResolutionCount = addingAutomaticSelectionCount(
                resolutionCount,
                rootResult.graphResolutionCount
            ), let nextReferenceFailureCount = addingAutomaticSelectionCount(
                referenceFailureCount,
                rootResult.graphReferenceFailureCount
            ), let nextByteCount = addingAutomaticSelectionCount(
                byteCount,
                rootResult.graphByteCount
            ) else {
                return WorkspaceCodemapAutomaticSelectionResult(
                    roots: [],
                    aggregateCoverage: .budget(.accountingOverflow)
                )
            }
            rootResults.append(rootResult)
            sourceIssueCount = nextSourceIssueCount
            targetCount = nextTargetCount
            resolutionCount = nextResolutionCount
            referenceFailureCount = nextReferenceFailureCount
            byteCount = nextByteCount
        }

        let finalSnapshot = codemapAutomaticSelectionSnapshot(
            sources: orderedSources,
            rootScope: rootScope
        )
        guard finalSnapshot == snapshot else {
            if retryCount == 0 {
                return try await resolveAutomaticCodemapSelection(
                    partitions: partitions,
                    orderedSources: orderedSources,
                    rootScope: rootScope,
                    targetAuthority: targetAuthority,
                    retryCount: 1
                )
            }
            return codemapAutomaticSelectionStaleResult(
                previous: snapshot,
                current: finalSnapshot,
                orderedRootEpochs: orderedRootEpochs,
                orderedSources: orderedSources
            )
        }
        let sourceTickets = orderedSources.compactMap { source -> WorkspaceCodemapArtifactDemandTicket? in
            guard let record = codemapSessionsByRootEpoch[source.rootEpoch]?
                .demandsByFileID[source.fileID],
                case let .ready(ready) = record.result,
                codemapTicketsShareDemand(ready.ticket, record.ticket),
                ready.snapshot.requestGeneration == ready.ticket.requestGeneration,
                codemapDemandIsCurrent(ready.ticket)
            else { return nil }
            return ready.ticket
        }
        let aggregate = WorkspaceCodemapAutomaticSelectionResult(roots: rootResults).aggregateCoverage
        let publicTargets = rootResults.flatMap(\.targets)
        let coverageProofs: [WorkspaceCodemapProjectionCoverageProof]
        switch aggregate {
        case let .complete(proofs):
            coverageProofs = proofs
        case let .partial(proofs, _):
            coverageProofs = proofs
        case .provisional, .incomplete, .pending, .unavailable, .stale, .busy, .budget:
            return WorkspaceCodemapAutomaticSelectionResult(
                roots: rootResults,
                aggregateCoverage: aggregate
            )
        }

        let rootScopeEpochs = codemapAutomaticSelectionRootScopeEpochs(rootScope)
        let graphKeys = rootResults.compactMap(\.graphKey)
        let resultRootEpochs = rootResults.map(\.rootEpoch)
        guard sourceTickets.count == orderedSources.count,
              Set(sourceTickets.map { WorkspaceCodemapRootScopedFileSlot(
                  rootEpoch: $0.rootEpoch,
                  fileID: $0.fileID
              ) }) == Set(orderedSources.map { WorkspaceCodemapRootScopedFileSlot(
                  rootEpoch: $0.rootEpoch,
                  fileID: $0.fileID
              ) }),
              Set(rootScopeEpochs.map(\.rootID)) == snapshot.allowedRootIDs,
              graphKeys.count == rootResults.count,
              coverageProofs.count == rootResults.count,
              Set(resultRootEpochs).count == resultRootEpochs.count,
              zip(resultRootEpochs, graphKeys).allSatisfy({ pair in
                  pair.1.rootEpoch == pair.0
              }),
              zip(resultRootEpochs, coverageProofs).allSatisfy({ pair in
                  pair.1.generation.rootEpoch == pair.0
              }),
              zip(graphKeys, coverageProofs).allSatisfy({ pair in
                  pair.0 == WorkspaceCodemapSelectionGraphRuntimeKey(generation: pair.1.generation)
              }),
              automaticSelectionCoverageProofsAreCurrent(coverageProofs)
        else {
            return WorkspaceCodemapAutomaticSelectionResult(
                roots: [],
                aggregateCoverage: .stale(.publicationReceipt)
            )
        }
        let requestID = UUID()
        let publicationPermit = WorkspaceCodemapAutomaticSelectionPublicationPermit()
        registerAutomaticSelectionPublicationPermit(
            publicationPermit,
            requestID: requestID,
            rootScopeEpochs: rootScopeEpochs
        )
        let receipt = WorkspaceCodemapAutomaticSelectionPublicationReceipt(
            requestID: requestID,
            rootScope: rootScope,
            rootScopeEpochs: rootScopeEpochs,
            sourceTickets: sourceTickets,
            graphKeys: graphKeys,
            coverageProofs: coverageProofs,
            targets: publicTargets,
            publicationPermit: publicationPermit
        )
        return WorkspaceCodemapAutomaticSelectionResult(
            roots: rootResults,
            aggregateCoverage: aggregate,
            publicationReceipt: receipt
        )
    }

    private func codemapAutomaticSelectionAggregateBudgetResult(
        reason: WorkspaceCodemapStoreSelectionGraphQueryBudgetReason
    ) -> WorkspaceCodemapAutomaticSelectionResult {
        WorkspaceCodemapAutomaticSelectionResult(
            roots: [],
            aggregateCoverage: .budget(codemapAutomaticSelectionBudgetReason(
                reason,
                rootEpoch: nil
            ))
        )
    }

    private func codemapAutomaticSelectionBudgetReason(
        _ reason: WorkspaceCodemapStoreSelectionGraphQueryBudgetReason,
        rootEpoch: WorkspaceCodemapRootEpoch?
    ) -> WorkspaceCodemapAutomaticSelectionBudgetReason {
        switch reason {
        case let .sourceLimit(attempted, limit): .sourceLimit(attempted: attempted, limit: limit)
        case let .uniqueSourceLimit(attempted, limit): .uniqueSourceLimit(attempted: attempted, limit: limit)
        case let .sourceIssueLimit(attempted, limit): .sourceIssueLimit(attempted: attempted, limit: limit)
        case let .rootLimit(attempted, limit): .rootLimit(attempted: attempted, limit: limit)
        case let .targetLimit(attempted, limit): .targetLimit(attempted: attempted, limit: limit)
        case let .resolutionLimit(attempted, limit): .resolutionLimit(attempted: attempted, limit: limit)
        case let .referenceFailureLimit(attempted, limit): .referenceFailureLimit(attempted: attempted, limit: limit)
        case let .byteLimit(attempted, limit): .byteLimit(attempted: attempted, limit: limit)
        case .accountingOverflow:
            if let rootEpoch {
                .graph(rootEpoch: rootEpoch, reason: .accountingOverflow)
            } else {
                .accountingOverflow
            }
        case let .definitionUniverse(definitionRootEpoch, dimension, attempted, limit):
            .graph(
                rootEpoch: definitionRootEpoch,
                reason: .definitionUniverse(
                    rootEpoch: definitionRootEpoch,
                    dimension: dimension,
                    attempted: attempted,
                    limit: limit
                )
            )
        case let .runtime(runtimeRootEpoch, runtimeReason):
            .graph(rootEpoch: runtimeRootEpoch, reason: .runtime(
                rootEpoch: runtimeRootEpoch,
                reason: runtimeReason
            ))
        }
    }

    private func codemapAutomaticSelectionSnapshot(
        sources: [WorkspaceCodemapAutomaticSelectionSourceIdentity],
        rootScope: WorkspaceLookupRootScope
    ) -> CodemapAutomaticSelectionSnapshot {
        let allowedRootIDs = Set(rootsForPathLookup(scope: rootScope).map(\.id))
        var sourceStates: [
            WorkspaceCodemapAutomaticSelectionSourceIdentity:
                CodemapAutomaticSelectionSourceSnapshot
        ] = [:]
        sourceStates.reserveCapacity(sources.count)

        for source in sources {
            guard let state = rootStatesByID[source.rootEpoch.rootID],
                  state.lifetimeID == source.rootEpoch.rootLifetimeID
            else {
                sourceStates[source] = .rootEpochNotCurrent
                continue
            }
            guard allowedRootIDs.contains(source.rootEpoch.rootID) else {
                sourceStates[source] = .outsideRootScope
                continue
            }
            let catalogGeneration = catalogGenerationsByRootID[source.rootEpoch.rootID]
            guard source.catalogGeneration == catalogGeneration else {
                sourceStates[source] = .staleCatalogGeneration(catalogGeneration)
                continue
            }
            guard let file = filesByID[source.fileID],
                  file.rootID == source.rootEpoch.rootID,
                  isDiscoverableFileID(file.id),
                  state.fileIDsByRelativePath[file.standardizedRelativePath] == file.id
            else {
                sourceStates[source] = .notCataloged
                continue
            }
            guard let record = codemapSessionsByRootEpoch[source.rootEpoch]?
                .demandsByFileID[source.fileID]
            else {
                sourceStates[source] = .notDemanded
                continue
            }
            switch record.result {
            case let .pending(ticket):
                sourceStates[source] = codemapDemandIsCurrent(ticket)
                    ? .pending(ticket)
                    : .staleCatalogGeneration(catalogGeneration)
            case let .unavailable(reason):
                sourceStates[source] = .unavailable(reason)
            case let .ready(ready):
                if ready.ticket == record.ticket,
                   ready.ticket.fileID == source.fileID,
                   ready.ticket.rootEpoch == source.rootEpoch,
                   codemapDemandIsCurrent(ready.ticket)
                {
                    sourceStates[source] = .ready(ready.ticket)
                } else {
                    sourceStates[source] = .staleCatalogGeneration(catalogGeneration)
                }
            }
        }
        return CodemapAutomaticSelectionSnapshot(
            allowedRootIDs: allowedRootIDs,
            sourceStates: sourceStates
        )
    }

    private func codemapAutomaticSelectionShouldRetry(
        previous: CodemapAutomaticSelectionSnapshot,
        current: CodemapAutomaticSelectionSnapshot
    ) -> Bool {
        if previous.allowedRootIDs != current.allowedRootIDs {
            return true
        }
        for (source, previousState) in previous.sourceStates {
            guard case .ready = current.sourceStates[source] else { continue }
            switch previousState {
            case .notDemanded, .pending, .unavailable:
                return true
            case .rootEpochNotCurrent, .outsideRootScope, .staleCatalogGeneration,
                 .notCataloged, .ready:
                continue
            }
        }
        return false
    }

    private func codemapAutomaticSelectionStaleResult(
        previous: CodemapAutomaticSelectionSnapshot,
        current: CodemapAutomaticSelectionSnapshot,
        orderedRootEpochs: [WorkspaceCodemapRootEpoch],
        orderedSources: [WorkspaceCodemapAutomaticSelectionSourceIdentity]
    ) -> WorkspaceCodemapAutomaticSelectionResult {
        if previous.allowedRootIDs != current.allowedRootIDs,
           let rootEpoch = orderedRootEpochs.first
        {
            return WorkspaceCodemapAutomaticSelectionResult(roots: [
                WorkspaceCodemapAutomaticSelectionRootResult(
                    rootEpoch: rootEpoch,
                    targets: [],
                    sourceIssues: [],
                    targetIssues: [],
                    coverage: .stale(.rootScopeChanged(rootEpoch))
                )
            ])
        }
        if let source = orderedSources.first(where: {
            previous.sourceStates[$0] != current.sourceStates[$0]
        }) {
            return WorkspaceCodemapAutomaticSelectionResult(roots: [
                WorkspaceCodemapAutomaticSelectionRootResult(
                    rootEpoch: source.rootEpoch,
                    targets: [],
                    sourceIssues: [],
                    targetIssues: [],
                    coverage: .stale(.sourceStateChanged(source))
                )
            ])
        }
        let rootEpoch = orderedRootEpochs[0]
        return WorkspaceCodemapAutomaticSelectionResult(roots: [
            WorkspaceCodemapAutomaticSelectionRootResult(
                rootEpoch: rootEpoch,
                targets: [],
                sourceIssues: [],
                targetIssues: [],
                coverage: .stale(.rootEpochNotCurrent(rootEpoch))
            )
        ])
    }

    private func codemapAutomaticSelectionTranslatingBudget(
        _ result: WorkspaceCodemapAutomaticSelectionRootResult,
        sourceIssueCount: Int,
        targetCount: Int,
        resolutionCount: Int,
        referenceFailureCount: Int,
        byteCount: Int,
        budgetPolicy: WorkspaceCodemapStoreSelectionGraphQueryBudgetPolicy
    ) -> WorkspaceCodemapAutomaticSelectionRootResult {
        guard case let .budget(reason) = result.coverage else { return result }

        let translated: WorkspaceCodemapStoreSelectionGraphQueryBudgetReason
        switch reason {
        case let .sourceIssueLimit(attempted, _):
            guard let total = addingAutomaticSelectionCount(sourceIssueCount, attempted) else {
                translated = .accountingOverflow
                break
            }
            translated = .sourceIssueLimit(
                attempted: total,
                limit: budgetPolicy.maximumSourceIssueCount
            )
        case let .targetLimit(attempted, _):
            guard let total = addingAutomaticSelectionCount(targetCount, attempted) else {
                translated = .accountingOverflow
                break
            }
            translated = .targetLimit(attempted: total, limit: budgetPolicy.maximumTargetCount)
        case let .resolutionLimit(attempted, _):
            guard let total = addingAutomaticSelectionCount(resolutionCount, attempted) else {
                translated = .accountingOverflow
                break
            }
            translated = .resolutionLimit(attempted: total, limit: budgetPolicy.maximumResolutionCount)
        case let .referenceFailureLimit(attempted, _):
            guard let total = addingAutomaticSelectionCount(referenceFailureCount, attempted) else {
                translated = .accountingOverflow
                break
            }
            translated = .referenceFailureLimit(
                attempted: total,
                limit: budgetPolicy.maximumReferenceFailureCount
            )
        case let .byteLimit(attempted, _):
            guard let total = addingAutomaticSelectionCount(byteCount, attempted) else {
                translated = .accountingOverflow
                break
            }
            translated = .byteLimit(attempted: total, limit: budgetPolicy.maximumByteCount)
        case .sourceLimit, .uniqueSourceLimit, .rootLimit, .accountingOverflow,
             .definitionUniverse, .runtime:
            translated = reason
        }
        return WorkspaceCodemapAutomaticSelectionRootResult(
            rootEpoch: result.rootEpoch,
            targets: [],
            sourceIssues: [],
            targetIssues: [],
            coverage: .budget(translated)
        )
    }

    private func resolveAutomaticCodemapSelection(
        sources: [WorkspaceCodemapAutomaticSelectionSourceIdentity],
        rootEpoch: WorkspaceCodemapRootEpoch,
        allowedRootIDs: Set<UUID>,
        rootScope: WorkspaceLookupRootScope,
        targetAuthority: AutomaticSelectionTargetAuthority,
        sourceIssueAllowance: Int,
        queryBudgetPolicy: WorkspaceCodemapStoreSelectionGraphQueryBudgetPolicy
    ) async throws -> WorkspaceCodemapAutomaticSelectionRootResult {
        guard let state = rootStatesByID[rootEpoch.rootID],
              state.lifetimeID == rootEpoch.rootLifetimeID
        else {
            return WorkspaceCodemapAutomaticSelectionRootResult(
                rootEpoch: rootEpoch,
                targets: [],
                sourceIssues: [],
                targetIssues: [],
                coverage: .stale(.rootEpochNotCurrent(rootEpoch))
            )
        }
        guard allowedRootIDs.contains(rootEpoch.rootID) else {
            guard sources.count <= sourceIssueAllowance else {
                guard let attempted = addingAutomaticSelectionCount(sourceIssueAllowance, 1) else {
                    return WorkspaceCodemapAutomaticSelectionRootResult(
                        rootEpoch: rootEpoch,
                        targets: [],
                        sourceIssues: [],
                        targetIssues: [],
                        coverage: .budget(.accountingOverflow)
                    )
                }
                return WorkspaceCodemapAutomaticSelectionRootResult(
                    rootEpoch: rootEpoch,
                    targets: [],
                    sourceIssues: [],
                    targetIssues: [],
                    coverage: .budget(.sourceIssueLimit(
                        attempted: attempted,
                        limit: sourceIssueAllowance
                    ))
                )
            }
            let issues = sources.map(WorkspaceCodemapAutomaticSelectionSourceIssue.outsideRootScope)
            return WorkspaceCodemapAutomaticSelectionRootResult(
                rootEpoch: rootEpoch,
                targets: [],
                sourceIssues: issues,
                targetIssues: [],
                coverage: .unavailable(.noReadySources)
            )
        }

        guard let catalogGeneration = catalogGenerationsByRootID[rootEpoch.rootID] else {
            return WorkspaceCodemapAutomaticSelectionRootResult(
                rootEpoch: rootEpoch,
                targets: [],
                sourceIssues: [],
                targetIssues: [],
                coverage: .stale(.rootEpochNotCurrent(rootEpoch))
            )
        }
        var sourceIssues: [WorkspaceCodemapAutomaticSelectionSourceIssue] = []
        var graphSources: [WorkspaceCodemapStoreSelectionGraphSourceIdentity] = []
        for source in sources {
            let issue: WorkspaceCodemapAutomaticSelectionSourceIssue?
            if source.catalogGeneration != catalogGeneration {
                issue = .staleCatalogGeneration(
                    source,
                    currentCatalogGeneration: catalogGeneration
                )
            } else if let file = filesByID[source.fileID],
                      file.rootID == rootEpoch.rootID,
                      isDiscoverableFileID(file.id),
                      state.fileIDsByRelativePath[file.standardizedRelativePath] == file.id
            {
                if let record = codemapSessionsByRootEpoch[rootEpoch]?
                    .demandsByFileID[source.fileID]
                {
                    switch record.result {
                    case let .pending(ticket):
                        if codemapDemandIsCurrent(ticket) {
                            issue = .pending(source, ticket)
                        } else {
                            issue = .staleCatalogGeneration(
                                source,
                                currentCatalogGeneration: catalogGenerationsByRootID[rootEpoch.rootID]
                            )
                        }
                    case let .unavailable(reason):
                        issue = .unavailable(source, reason)
                    case let .ready(ready):
                        if ready.ticket == record.ticket,
                           ready.ticket.fileID == source.fileID,
                           ready.ticket.rootEpoch == source.rootEpoch,
                           codemapDemandIsCurrent(ready.ticket)
                        {
                            graphSources.append(WorkspaceCodemapStoreSelectionGraphSourceIdentity(
                                ticket: ready.ticket
                            ))
                            issue = nil
                        } else {
                            issue = .staleCatalogGeneration(
                                source,
                                currentCatalogGeneration: catalogGenerationsByRootID[rootEpoch.rootID]
                            )
                        }
                    }
                } else {
                    issue = .notDemanded(source)
                }
            } else {
                issue = .notCataloged(source)
            }

            if let issue {
                guard sourceIssues.count < sourceIssueAllowance else {
                    guard let attempted = addingAutomaticSelectionCount(sourceIssues.count, 1) else {
                        return WorkspaceCodemapAutomaticSelectionRootResult(
                            rootEpoch: rootEpoch,
                            targets: [],
                            sourceIssues: [],
                            targetIssues: [],
                            coverage: .budget(.accountingOverflow)
                        )
                    }
                    return WorkspaceCodemapAutomaticSelectionRootResult(
                        rootEpoch: rootEpoch,
                        targets: [],
                        sourceIssues: [],
                        targetIssues: [],
                        coverage: .budget(.sourceIssueLimit(
                            attempted: attempted,
                            limit: sourceIssueAllowance
                        ))
                    )
                }
                sourceIssues.append(issue)
            }
        }

        guard !graphSources.isEmpty else {
            if let staleIssue = sourceIssues.first(where: {
                if case .staleCatalogGeneration = $0 { return true }
                return false
            }), case let .staleCatalogGeneration(source, currentGeneration) = staleIssue {
                return WorkspaceCodemapAutomaticSelectionRootResult(
                    rootEpoch: rootEpoch,
                    targets: [],
                    sourceIssues: sourceIssues,
                    targetIssues: [],
                    coverage: .stale(.sourceCatalogGeneration(
                        source,
                        currentCatalogGeneration: currentGeneration
                    ))
                )
            }
            return WorkspaceCodemapAutomaticSelectionRootResult(
                rootEpoch: rootEpoch,
                targets: [],
                sourceIssues: sourceIssues,
                targetIssues: [],
                coverage: .unavailable(.noReadySources)
            )
        }

        let disposition = await queryCodemapSelectionGraph(
            WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: graphSources),
            budgetPolicy: queryBudgetPolicy
        )
        await codemapAutomaticSelectionQueryHook(rootEpoch)
        try Task.checkCancellation()
        guard let currentState = rootStatesByID[rootEpoch.rootID],
              currentState.lifetimeID == rootEpoch.rootLifetimeID
        else {
            return WorkspaceCodemapAutomaticSelectionRootResult(
                rootEpoch: rootEpoch,
                targets: [],
                sourceIssues: sourceIssues,
                targetIssues: [],
                coverage: .stale(.rootEpochNotCurrent(rootEpoch))
            )
        }
        guard catalogGenerationsByRootID[rootEpoch.rootID] == catalogGeneration else {
            let source = sources[0]
            return WorkspaceCodemapAutomaticSelectionRootResult(
                rootEpoch: rootEpoch,
                targets: [],
                sourceIssues: sourceIssues,
                targetIssues: [],
                coverage: .stale(.sourceCatalogGeneration(
                    source,
                    currentCatalogGeneration: catalogGenerationsByRootID[rootEpoch.rootID]
                ))
            )
        }
        guard rootsForPathLookup(scope: rootScope).contains(where: { $0.id == rootEpoch.rootID }) else {
            let issues = sources.map(WorkspaceCodemapAutomaticSelectionSourceIssue.outsideRootScope)
            return WorkspaceCodemapAutomaticSelectionRootResult(
                rootEpoch: rootEpoch,
                targets: [],
                sourceIssues: issues,
                targetIssues: [],
                coverage: .unavailable(.noReadySources)
            )
        }
        guard graphSources.allSatisfy({ source in
            let ticket = source.ticket
            guard codemapDemandIsCurrent(ticket),
                  let record = codemapSessionsByRootEpoch[rootEpoch]?
                  .demandsByFileID[ticket.fileID],
                  codemapTicketsShareDemand(record.ticket, ticket),
                  case let .ready(ready) = record.result
            else { return false }
            return codemapTicketsShareDemand(ready.ticket, ticket)
        }) else {
            return WorkspaceCodemapAutomaticSelectionRootResult(
                rootEpoch: rootEpoch,
                targets: [],
                sourceIssues: sourceIssues,
                targetIssues: [],
                coverage: .stale(.graph(.currentness(rootEpoch)))
            )
        }

        switch disposition {
        case let .readyPartial(queryResult):
            guard queryResult.roots.count == 1,
                  let graphRootResult = queryResult.roots.first,
                  graphRootResult.rootEpoch == rootEpoch,
                  case let .complete(proof, _, _, _) =
                  graphRootResult.result.definitionUniverseCoverage,
                  automaticSelectionCoverageProofIsCurrent(proof)
            else {
                return WorkspaceCodemapAutomaticSelectionRootResult(
                    rootEpoch: rootEpoch,
                    targets: [],
                    sourceIssues: sourceIssues,
                    targetIssues: [],
                    coverage: .unavailable(.graph(.invalidGraphResult(rootEpoch)))
                )
            }
            guard graphRootResult.result.targets.allSatisfy({ $0.rootEpoch == rootEpoch }) else {
                return WorkspaceCodemapAutomaticSelectionRootResult(
                    rootEpoch: rootEpoch,
                    targets: [],
                    sourceIssues: sourceIssues,
                    targetIssues: [],
                    coverage: .unavailable(.graph(.invalidGraphResult(rootEpoch)))
                )
            }
            let selectedFileIDs = Set(sources.map(\.fileID))
            var seenTargets = Set<WorkspaceCodemapAutomaticSelectionTarget>()
            var targets: [WorkspaceCodemapAutomaticSelectionTarget] = []
            var targetIssues: [WorkspaceCodemapAutomaticSelectionTargetIssue] = []
            for endpoint in graphRootResult.result.targets where !selectedFileIDs.contains(endpoint.fileID) {
                guard let file = filesByID[endpoint.fileID],
                      file.rootID == rootEpoch.rootID,
                      isDiscoverableFileID(file.id),
                      currentState.fileIDsByRelativePath[file.standardizedRelativePath] == file.id
                else {
                    targetIssues.append(.notCataloged(
                        rootEpoch: rootEpoch,
                        fileID: endpoint.fileID
                    ))
                    continue
                }
                let targetAuthorityIsCurrent = switch targetAuthority {
                case .retainedReadyDemand:
                    if let record = codemapSessionsByRootEpoch[rootEpoch]?
                        .demandsByFileID[endpoint.fileID],
                        record.ticket.requestGeneration == endpoint.requestGeneration,
                        codemapDemandIsCurrent(record.ticket),
                        case let .ready(ready) = record.result,
                        ready.ticket == record.ticket
                    {
                        true
                    } else {
                        false
                    }
                case .currentCompletedProjection:
                    if let catalogShard = automaticSelectionCatalogShard(rootEpoch: rootEpoch),
                       automaticSelectionCatalogCandidate(
                           endpoint: endpoint,
                           rootEpoch: rootEpoch,
                           catalogShard: catalogShard
                       ) != nil,
                       automaticSelectionCoverageProofIsCurrent(proof)
                    {
                        true
                    } else {
                        false
                    }
                }
                guard targetAuthorityIsCurrent else {
                    targetIssues.append(.staleGeneration(
                        rootEpoch: rootEpoch,
                        fileID: endpoint.fileID,
                        requestGeneration: endpoint.requestGeneration
                    ))
                    continue
                }
                guard let logicalPath = WorkspaceCodemapLogicalPresentationPath(
                    rootDisplayName: currentState.root.name,
                    standardizedRelativePath: file.standardizedRelativePath
                ) else {
                    targetIssues.append(.logicalPathUnavailable(
                        rootEpoch: rootEpoch,
                        fileID: endpoint.fileID
                    ))
                    continue
                }
                let target = WorkspaceCodemapAutomaticSelectionTarget(
                    rootEpoch: rootEpoch,
                    fileID: endpoint.fileID,
                    catalogGeneration: catalogGeneration,
                    requestGeneration: endpoint.requestGeneration,
                    logicalPath: logicalPath
                )
                if seenTargets.insert(target).inserted {
                    targets.append(target)
                }
            }
            targets.sort {
                if $0.logicalPath.standardizedRelativePath != $1.logicalPath.standardizedRelativePath {
                    return $0.logicalPath.standardizedRelativePath < $1.logicalPath.standardizedRelativePath
                }
                return $0.fileID.uuidString < $1.fileID.uuidString
            }

            if let targetIssue = targetIssues.first {
                return WorkspaceCodemapAutomaticSelectionRootResult(
                    rootEpoch: rootEpoch,
                    targets: [],
                    sourceIssues: sourceIssues,
                    targetIssues: targetIssues,
                    coverage: .stale(.targetStateChanged(targetIssue))
                )
            }
            var partialReasons: [WorkspaceCodemapAutomaticSelectionPartialReason] = []
            for reason in [
                WorkspaceCodemapStoreSelectionGraphPartialReason.sourceCoverageIncomplete,
                .referenceFailuresPresent
            ] where graphRootResult.partialReasons.contains(reason) {
                partialReasons.append(.graph(reason))
            }
            partialReasons.append(contentsOf: sourceIssues.map {
                WorkspaceCodemapAutomaticSelectionPartialReason.source($0)
            })
            return WorkspaceCodemapAutomaticSelectionRootResult(
                rootEpoch: rootEpoch,
                targets: targets,
                sourceIssues: sourceIssues,
                targetIssues: [],
                coverage: partialReasons.isEmpty
                    ? .complete(proof)
                    : .partial(proof: proof, reasons: partialReasons),
                graphTargetCount: graphRootResult.result.targets.count,
                graphResolutionCount: graphRootResult.result.resolutions.count,
                graphReferenceFailureCount: graphRootResult.result.referenceFailures.count,
                graphByteCount: graphRootResult.result.materializedByteCount,
                graphKey: graphRootResult.result.key
            )
        case let .incomplete(reason):
            return WorkspaceCodemapAutomaticSelectionRootResult(
                rootEpoch: rootEpoch,
                targets: [],
                sourceIssues: sourceIssues,
                targetIssues: [],
                coverage: .incomplete([.graph(reason)])
            )
        case let .unavailable(reason):
            return WorkspaceCodemapAutomaticSelectionRootResult(
                rootEpoch: rootEpoch,
                targets: [],
                sourceIssues: sourceIssues,
                targetIssues: [],
                coverage: .unavailable(.graph(reason))
            )
        case let .stale(reason):
            return WorkspaceCodemapAutomaticSelectionRootResult(
                rootEpoch: rootEpoch,
                targets: [],
                sourceIssues: sourceIssues,
                targetIssues: [],
                coverage: .stale(.graph(reason))
            )
        case let .busy(reason):
            return Self.automaticSelectionBusyRootResult(
                rootEpoch: rootEpoch,
                sourceIssues: sourceIssues,
                reason: reason
            )
        case let .budget(reason):
            return WorkspaceCodemapAutomaticSelectionRootResult(
                rootEpoch: rootEpoch,
                targets: [],
                sourceIssues: sourceIssues,
                targetIssues: [],
                coverage: .budget(reason)
            )
        }
    }

    static func automaticSelectionBusyRootResult(
        rootEpoch: WorkspaceCodemapRootEpoch,
        sourceIssues: [WorkspaceCodemapAutomaticSelectionSourceIssue],
        reason: WorkspaceCodemapStoreSelectionGraphQueryBusyReason
    ) -> WorkspaceCodemapAutomaticSelectionRootResult {
        WorkspaceCodemapAutomaticSelectionRootResult(
            rootEpoch: rootEpoch,
            targets: [],
            sourceIssues: sourceIssues,
            targetIssues: [],
            coverage: .busy(reason)
        )
    }

    func revalidateAutomaticCodemapSelectionForPublication(
        _ receipt: WorkspaceCodemapAutomaticSelectionPublicationReceipt,
        rootScope: WorkspaceLookupRootScope
    ) async -> WorkspaceCodemapAutomaticSelectionPublicationDisposition {
        let disposition = revalidateAutomaticCodemapSelectionForPublicationUnreleased(
            receipt,
            rootScope: rootScope
        )
        await receipt.publicationLease?.release()
        return disposition
    }

    private func codemapDeadlineIsCurrent(_ deadline: ContinuousClock.Instant?) -> Bool {
        !Task.isCancelled && deadline.map { ContinuousClock.now < $0 } != false
    }

    private func waitForCodemapSharedTask(
        _ task: Task<Void, Never>,
        deadline: ContinuousClock.Instant?
    ) async -> Bool {
        guard codemapDeadlineIsCurrent(deadline) else { return false }
        guard let deadline else {
            await task.value
            return !Task.isCancelled
        }
        let completed = await withCheckedContinuation { continuation in
            let race = CodemapSharedTaskDeadlineRace(continuation)
            Task {
                await task.value
                race.resolve(ContinuousClock.now < deadline)
            }
            Task {
                try? await Task.sleep(until: deadline, clock: .continuous)
                race.resolve(false)
            }
        }
        return completed && codemapDeadlineIsCurrent(deadline)
    }

    func waitForCodemapGraphPublication(
        rootEpoch: WorkspaceCodemapRootEpoch,
        deadline: ContinuousClock.Instant? = nil
    ) async -> Bool {
        var waitedFlightIDs = Set<UUID>()
        var waitedObserverIDs = Set<UUID>()
        var waitedWorkerIDs = Set<UUID>()
        var observedQuiescentPass = false
        while codemapDeadlineIsCurrent(deadline) {
            if let flight = codemapSessionsByRootEpoch[rootEpoch]?.graphPublicationFlight,
               waitedFlightIDs.insert(flight.id).inserted,
               let task = flight.task
            {
                observedQuiescentPass = false
                guard await waitForCodemapSharedTask(task, deadline: deadline),
                      codemapDeadlineIsCurrent(deadline)
                else { return false }
                continue
            }
            if let observer = codemapSessionsByRootEpoch[rootEpoch]?.projectionRecoveryObserver,
               waitedObserverIDs.insert(observer.id).inserted,
               let task = observer.task
            {
                observedQuiescentPass = false
                guard await waitForCodemapSharedTask(task, deadline: deadline),
                      codemapDeadlineIsCurrent(deadline)
                else { return false }
                continue
            }
            if let state = codemapSessionsByRootEpoch[rootEpoch]?.selectionGraph,
               let workerID = state.workerID,
               waitedWorkerIDs.insert(workerID).inserted,
               let task = state.workerTask
            {
                observedQuiescentPass = false
                guard await waitForCodemapSharedTask(task, deadline: deadline),
                      codemapDeadlineIsCurrent(deadline)
                else { return false }
                continue
            }
            guard observedQuiescentPass else {
                observedQuiescentPass = true
                await Task.yield()
                continue
            }
            return codemapDeadlineIsCurrent(deadline)
        }
        return false
    }

    func refreshAutomaticCodemapSelectionResultForCurrentProjection(
        _ result: WorkspaceCodemapAutomaticSelectionResult,
        sourceTickets: [WorkspaceCodemapArtifactDemandTicket],
        rootScope: WorkspaceLookupRootScope,
        deadline: ContinuousClock.Instant? = nil
    ) async -> WorkspaceCodemapAutomaticSelectionResult? {
        guard codemapDeadlineIsCurrent(deadline),
              let receipt = result.publicationReceipt,
              receipt.publicationPermit.withCurrent({ true }) == true,
              receipt.rootScope == rootScope,
              receipt.rootScopeEpochs == codemapAutomaticSelectionRootScopeEpochs(rootScope),
              sourceTickets.count == receipt.sourceTickets.count
        else { return nil }

        switch receipt.publicationBasis {
        case .projectionCoverage:
            return await refreshProjectionAutomaticCodemapSelectionResult(
                result,
                receipt: receipt,
                sourceTickets: sourceTickets,
                rootScope: rootScope,
                deadline: deadline
            )
        case .provisionalCandidates:
            return refreshProvisionalAutomaticCodemapSelectionResult(
                result,
                receipt: receipt,
                sourceTickets: sourceTickets,
                rootScope: rootScope,
                deadline: deadline
            )
        }
    }

    private func refreshProjectionAutomaticCodemapSelectionResult(
        _ result: WorkspaceCodemapAutomaticSelectionResult,
        receipt: WorkspaceCodemapAutomaticSelectionPublicationReceipt,
        sourceTickets: [WorkspaceCodemapArtifactDemandTicket],
        rootScope: WorkspaceLookupRootScope,
        deadline: ContinuousClock.Instant? = nil
    ) async -> WorkspaceCodemapAutomaticSelectionResult? {
        guard receipt.coverageProofs.count == receipt.graphKeys.count,
              !receipt.coverageProofs.isEmpty,
              automaticSelectionSourceTicketsAreCurrent(
                  sourceTickets,
                  rootScopeEpochs: receipt.rootScopeEpochs
              )
        else { return nil }

        let sources = sourceTickets.map {
            WorkspaceCodemapAutomaticSelectionSourceIdentity(
                rootEpoch: $0.rootEpoch,
                fileID: $0.fileID,
                catalogGeneration: $0.catalogGeneration
            )
        }
        guard !Task.isCancelled,
              let refreshedResult = try? await resolveAutomaticCodemapSelection(
                  sources: sources,
                  rootScope: rootScope,
                  targetAuthority: .currentCompletedProjection
              ),
              codemapDeadlineIsCurrent(deadline),
              let refreshedReceipt = refreshedResult.publicationReceipt
        else { return nil }

        let predecessorRootEpochs = receipt.coverageProofs.map(\.generation.rootEpoch)
        let refreshedRootEpochs = refreshedReceipt.coverageProofs.map(\.generation.rootEpoch)
        guard Set(predecessorRootEpochs).count == predecessorRootEpochs.count,
              Set(refreshedRootEpochs).count == refreshedRootEpochs.count
        else {
            refreshedReceipt.publicationPermit.revoke()
            return nil
        }
        let predecessorProofs = Dictionary(
            uniqueKeysWithValues: receipt.coverageProofs.map {
                ($0.generation.rootEpoch, $0)
            }
        )
        let refreshedProofs = Dictionary(
            uniqueKeysWithValues: refreshedReceipt.coverageProofs.map {
                ($0.generation.rootEpoch, $0)
            }
        )
        let sourceSlots = Set(sourceTickets.map {
            WorkspaceCodemapRootScopedFileSlot(rootEpoch: $0.rootEpoch, fileID: $0.fileID)
        })
        let refreshedSourceSlots = Set(refreshedReceipt.sourceTickets.map {
            WorkspaceCodemapRootScopedFileSlot(rootEpoch: $0.rootEpoch, fileID: $0.fileID)
        })
        guard refreshedReceipt.rootScope == receipt.rootScope,
              refreshedReceipt.rootScopeEpochs == receipt.rootScopeEpochs,
              refreshedReceipt.publicationBasis == .projectionCoverage,
              refreshedReceipt.coverageProofs.count == receipt.coverageProofs.count,
              predecessorProofs.count == receipt.coverageProofs.count,
              refreshedProofs.count == refreshedReceipt.coverageProofs.count,
              sourceSlots.count == sourceTickets.count,
              refreshedSourceSlots == sourceSlots,
              refreshedReceipt.sourceTickets.count == sourceTickets.count,
              refreshedReceipt.targets.count == receipt.targets.count,
              Set(refreshedReceipt.targets) == Set(receipt.targets),
              predecessorProofs.allSatisfy({ rootEpoch, predecessor in
                  guard let current = refreshedProofs[rootEpoch] else { return false }
                  return predecessor == current || predecessor.successor(
                      contributionGeneration: current.generation.contributionGeneration
                  ) == current
              })
        else {
            refreshedReceipt.publicationPermit.revoke()
            return nil
        }

        receipt.publicationPermit.revoke()
        let replacementReceipt = WorkspaceCodemapAutomaticSelectionPublicationReceipt(
            requestID: refreshedReceipt.requestID,
            rootScope: refreshedReceipt.rootScope,
            rootScopeEpochs: refreshedReceipt.rootScopeEpochs,
            sourceTickets: sourceTickets,
            graphKeys: refreshedReceipt.graphKeys,
            coverageProofs: refreshedReceipt.coverageProofs,
            targets: refreshedReceipt.targets,
            publicationPermit: refreshedReceipt.publicationPermit
        )
        return WorkspaceCodemapAutomaticSelectionResult(
            roots: refreshedResult.roots,
            aggregateCoverage: refreshedResult.aggregateCoverage,
            publicationReceipt: replacementReceipt
        )
    }

    private func refreshProvisionalAutomaticCodemapSelectionResult(
        _ result: WorkspaceCodemapAutomaticSelectionResult,
        receipt: WorkspaceCodemapAutomaticSelectionPublicationReceipt,
        sourceTickets: [WorkspaceCodemapArtifactDemandTicket],
        rootScope _: WorkspaceLookupRootScope,
        deadline: ContinuousClock.Instant? = nil
    ) -> WorkspaceCodemapAutomaticSelectionResult? {
        guard codemapDeadlineIsCurrent(deadline),
              provisionalAutomaticSelectionReceiptIsCurrent(
                  receipt,
                  sourceTickets: sourceTickets
              )
        else { return nil }
        receipt.publicationPermit.revoke()
        let requestID = UUID()
        let publicationPermit = WorkspaceCodemapAutomaticSelectionPublicationPermit()
        registerAutomaticSelectionPublicationPermit(
            publicationPermit,
            requestID: requestID,
            rootScopeEpochs: receipt.rootScopeEpochs
        )
        let replacementReceipt = WorkspaceCodemapAutomaticSelectionPublicationReceipt(
            requestID: requestID,
            rootScope: receipt.rootScope,
            rootScopeEpochs: receipt.rootScopeEpochs,
            sourceTickets: sourceTickets,
            graphKeys: [],
            coverageProofs: [],
            targets: receipt.targets,
            publicationBasis: receipt.publicationBasis,
            publicationPermit: publicationPermit
        )
        return WorkspaceCodemapAutomaticSelectionResult(
            roots: result.roots,
            aggregateCoverage: result.aggregateCoverage,
            publicationReceipt: replacementReceipt
        )
    }

    private func automaticSelectionSourceTicketsAreCurrent(
        _ sourceTickets: [WorkspaceCodemapArtifactDemandTicket],
        rootScopeEpochs: [WorkspaceCodemapRootEpoch]
    ) -> Bool {
        let allowedRootIDs = Set(rootScopeEpochs.map(\.rootID))
        for ticket in sourceTickets {
            guard allowedRootIDs.contains(ticket.rootEpoch.rootID),
                  codemapDemandIsCurrent(ticket),
                  let record = codemapSessionsByRootEpoch[ticket.rootEpoch]?
                  .demandsByFileID[ticket.fileID],
                  record.retainIDs.contains(ticket.retainID),
                  codemapTicketsShareDemand(record.ticket, ticket),
                  case let .ready(ready) = record.result,
                  codemapTicketsShareDemand(ready.ticket, ticket),
                  ready.snapshot.requestGeneration == ticket.requestGeneration
            else {
                return false
            }
        }
        return true
    }

    private func provisionalAutomaticSelectionReceiptIsCurrent(
        _ receipt: WorkspaceCodemapAutomaticSelectionPublicationReceipt,
        sourceTickets replacementSourceTickets: [WorkspaceCodemapArtifactDemandTicket]? = nil
    ) -> Bool {
        guard case let .provisionalCandidates(candidates) = receipt.publicationBasis,
              receipt.publicationPermit.withCurrent({ true }) == true,
              receipt.rootScopeEpochs == codemapAutomaticSelectionRootScopeEpochs(receipt.rootScope),
              receipt.graphKeys.isEmpty,
              receipt.coverageProofs.isEmpty,
              !receipt.targets.isEmpty,
              candidates.count == receipt.targets.count,
              Set(receipt.targets).count == receipt.targets.count,
              Set(receipt.targets.map { WorkspaceCodemapRootScopedFileSlot(target: $0) }).count == receipt.targets.count,
              Set(candidates.map { WorkspaceCodemapRootScopedFileSlot(candidate: $0) }).count == candidates.count
        else { return false }

        let sourceTickets = replacementSourceTickets ?? receipt.sourceTickets
        guard sourceTickets.count == receipt.sourceTickets.count,
              automaticSelectionSourceTicketsAreCurrent(
                  sourceTickets,
                  rootScopeEpochs: receipt.rootScopeEpochs
              )
        else { return false }
        let sourceSlots = Set(sourceTickets.map {
            WorkspaceCodemapRootScopedFileSlot(rootEpoch: $0.rootEpoch, fileID: $0.fileID)
        })
        let receiptSourceSlots = Set(receipt.sourceTickets.map {
            WorkspaceCodemapRootScopedFileSlot(rootEpoch: $0.rootEpoch, fileID: $0.fileID)
        })
        guard sourceSlots.count == sourceTickets.count,
              receiptSourceSlots == sourceSlots
        else { return false }

        var candidatesBySlot: [WorkspaceCodemapRootScopedFileSlot: WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate] = [:]
        for candidate in candidates {
            let rootEpoch = WorkspaceCodemapRootEpoch(
                rootID: candidate.identity.rootID,
                rootLifetimeID: candidate.identity.rootLifetimeID
            )
            let slot = WorkspaceCodemapRootScopedFileSlot(rootEpoch: rootEpoch, fileID: candidate.identity.fileID)
            guard candidatesBySlot[slot] == nil else { return false }
            candidatesBySlot[slot] = candidate
        }

        for target in receipt.targets {
            let slot = WorkspaceCodemapRootScopedFileSlot(rootEpoch: target.rootEpoch, fileID: target.fileID)
            guard !sourceSlots.contains(slot),
                  let candidate = candidatesBySlot[slot],
                  candidate.catalogGeneration == target.catalogGeneration,
                  candidate.requestGeneration == target.requestGeneration,
                  candidate.pathGeneration == target.requestGeneration,
                  provisionalAutomaticSelectionCandidateDemandIsCurrent(
                      candidate: candidate,
                      rootScope: receipt.rootScope,
                      rootScopeEpochs: receipt.rootScopeEpochs
                  ),
                  let state = rootStatesByID[target.rootEpoch.rootID],
                  state.lifetimeID == target.rootEpoch.rootLifetimeID,
                  catalogGenerationsByRootID[target.rootEpoch.rootID] == target.catalogGeneration,
                  let file = filesByID[target.fileID],
                  file.rootID == target.rootEpoch.rootID,
                  isDiscoverableFileID(file.id),
                  state.fileIDsByRelativePath[file.standardizedRelativePath] == file.id,
                  file.standardizedRelativePath == candidate.identity.standardizedRelativePath,
                  file.standardizedFullPath == candidate.identity.standardizedFullPath,
                  target.logicalPath.standardizedRelativePath == file.standardizedRelativePath
            else { return false }
        }
        return true
    }

    private func revalidateAutomaticCodemapSelectionForPublicationUnreleased(
        _ receipt: WorkspaceCodemapAutomaticSelectionPublicationReceipt,
        rootScope: WorkspaceLookupRootScope
    ) -> WorkspaceCodemapAutomaticSelectionPublicationDisposition {
        guard receipt.publicationPermit.withCurrent({ true }) == true,
              receipt.rootScope == rootScope
        else {
            return .stale(.publicationReceipt)
        }
        switch receipt.publicationBasis {
        case .projectionCoverage:
            return revalidateProjectionAutomaticCodemapSelectionForPublicationUnreleased(
                receipt,
                rootScope: rootScope
            )
        case .provisionalCandidates:
            guard provisionalAutomaticSelectionReceiptIsCurrent(receipt) else {
                return .stale(.publicationReceipt)
            }
            return .current(receipt.targets)
        }
    }

    private func revalidateProjectionAutomaticCodemapSelectionForPublicationUnreleased(
        _ receipt: WorkspaceCodemapAutomaticSelectionPublicationReceipt,
        rootScope: WorkspaceLookupRootScope
    ) -> WorkspaceCodemapAutomaticSelectionPublicationDisposition {
        let currentRootScopeEpochs = codemapAutomaticSelectionRootScopeEpochs(rootScope)
        guard receipt.rootScopeEpochs == currentRootScopeEpochs,
              !receipt.sourceTickets.isEmpty,
              receipt.graphKeys.count == receipt.coverageProofs.count,
              !receipt.coverageProofs.isEmpty,
              Set(receipt.targets).count == receipt.targets.count,
              automaticSelectionCoverageProofsAreCurrent(receipt.coverageProofs)
        else { return .stale(.publicationReceipt) }
        let allowedRootIDs = Set(currentRootScopeEpochs.map(\.rootID))
        let sourceSlots = receipt.sourceTickets.map {
            WorkspaceCodemapRootScopedFileSlot(rootEpoch: $0.rootEpoch, fileID: $0.fileID)
        }
        let sourceSlotSet = Set(sourceSlots)
        guard sourceSlotSet.count == sourceSlots.count,
              receipt.targets.allSatisfy({ target in
                  !sourceSlotSet.contains(WorkspaceCodemapRootScopedFileSlot(
                      rootEpoch: target.rootEpoch,
                      fileID: target.fileID
                  ))
              })
        else {
            return .stale(.publicationReceipt)
        }
        let coveredRootEpochs = receipt.coverageProofs.map(\.generation.rootEpoch)
        guard Set(coveredRootEpochs).count == coveredRootEpochs.count,
              Set(receipt.sourceTickets.map(\.rootEpoch)) == Set(coveredRootEpochs),
              zip(receipt.graphKeys, receipt.coverageProofs).allSatisfy({ pair in
                  pair.0 == WorkspaceCodemapSelectionGraphRuntimeKey(generation: pair.1.generation)
              }),
              automaticSelectionSourceTicketsAreCurrent(
                  receipt.sourceTickets,
                  rootScopeEpochs: currentRootScopeEpochs
              )
        else { return .stale(.publicationReceipt) }
        for key in receipt.graphKeys {
            guard allowedRootIDs.contains(key.rootEpoch.rootID),
                  let graphState = codemapSessionsByRootEpoch[key.rootEpoch]?.selectionGraph,
                  graphState.desiredKey == key,
                  graphState.publishedSummary?.key == key
            else { return .stale(.publicationReceipt) }
        }
        for target in receipt.targets {
            guard coveredRootEpochs.contains(target.rootEpoch),
                  allowedRootIDs.contains(target.rootEpoch.rootID),
                  let state = rootStatesByID[target.rootEpoch.rootID],
                  state.lifetimeID == target.rootEpoch.rootLifetimeID,
                  catalogGenerationsByRootID[target.rootEpoch.rootID] == target.catalogGeneration,
                  let file = filesByID[target.fileID],
                  file.rootID == target.rootEpoch.rootID,
                  isDiscoverableFileID(file.id),
                  state.fileIDsByRelativePath[file.standardizedRelativePath] == file.id,
                  target.logicalPath.standardizedRelativePath == file.standardizedRelativePath,
                  let session = codemapSessionsByRootEpoch[target.rootEpoch],
                  (
                      session.pathGenerationsByRelativePath[file.standardizedRelativePath]
                          ?? session.authority.ingressGeneration
                  ) == target.requestGeneration
            else { return .stale(.publicationReceipt) }
        }
        return .current(receipt.targets)
    }

    private func currentCodemapAuthority(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> CodemapRootAuthority? {
        guard let state = rootStatesByID[rootEpoch.rootID],
              state.lifetimeID == rootEpoch.rootLifetimeID
        else { return nil }
        if let session = codemapSessionsByRootEpoch[rootEpoch],
           codemapAuthorityMatchesLoadedRoot(session.authority)
        {
            return session.authority
        }
        if let launch = codemapProjectionPreloadLaunchesByRootEpoch[rootEpoch],
           codemapAuthorityMatchesLoadedRoot(launch.authority)
        {
            return launch.authority
        }
        if let flight = codemapEligibilityFlightsByRootEpoch[rootEpoch],
           codemapAuthorityMatchesLoadedRoot(flight.authority)
        {
            return flight.authority
        }
        if let completed = codemapCompletedEligibilityByRootEpoch[rootEpoch],
           codemapAuthorityMatchesLoadedRoot(completed.authority)
        {
            return completed.authority
        }
        if let retry = codemapProjectionPreloadRetriesByRootEpoch[rootEpoch],
           codemapAuthorityMatchesLoadedRoot(retry.authority)
        {
            return retry.authority
        }
        let generation = codemapAuthorityGenerationsByRootEpoch[rootEpoch] ?? 1
        guard generation > 0 else { return nil }
        codemapAuthorityGenerationsByRootEpoch[rootEpoch] = generation
        return CodemapRootAuthority(
            rootEpoch: rootEpoch,
            standardizedRootPath: state.root.standardizedFullPath,
            catalogGeneration: generation,
            ingressGeneration: generation
        )
    }

    private func recordCodemapProjectionPreloadStoreEvent(
        _ kind: CodemapProjectionPreloadStoreEventKind,
        rootEpoch: WorkspaceCodemapRootEpoch,
        phase: WorkspaceCodemapProjectionPreloadLaunchPhase
    ) {
        #if DEBUG
            nextCodemapProjectionPreloadStoreEventOrdinal &+= 1
            codemapProjectionPreloadStoreEvents.append(CodemapProjectionPreloadStoreEvent(
                ordinal: nextCodemapProjectionPreloadStoreEventOrdinal,
                rootEpoch: rootEpoch,
                kind: kind,
                launchPhase: phase
            ))
            if codemapProjectionPreloadStoreEvents.count > 2048 {
                codemapProjectionPreloadStoreEvents.removeFirst(
                    codemapProjectionPreloadStoreEvents.count - 2048
                )
            }
        #endif
    }

    private func recordCodemapRootReadyForProjectionPreload(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) {
        recordCodemapProjectionPreloadStoreEvent(
            .rootInventoryAndSearchReady,
            rootEpoch: rootEpoch,
            phase: .notScheduled
        )
    }

    /// Records launch state and creates the background task only. Git eligibility, runtime,
    /// integration-route, manifest, CAS, source, and graph work all begin in the task body.
    private func scheduleCodemapProjectionPreloadAfterRootReady(
        rootEpoch: WorkspaceCodemapRootEpoch,
        retryAttempt: Int = 0
    ) {
        #if DEBUG
            guard codemapProjectionPreloadLaunchPolicyForTesting == .enabled else { return }
        #endif
        guard codemapCleanupFlightsByRootID[rootEpoch.rootID] == nil,
              codemapRootMutationFenceTokensByRootEpoch[rootEpoch] == nil,
              let authority = currentCodemapAuthority(rootEpoch: rootEpoch),
              codemapPreflightAuthorityIsCurrent(authority)
        else { return }
        if let existing = codemapProjectionPreloadLaunchesByRootEpoch[rootEpoch] {
            switch existing.phase {
            case .cancelled, .superseded, .transientRetry:
                break
            case .notScheduled, .eligibilityQueued, .setupJoining, .engineScheduling,
                 .handedOff, .terminalNonGit:
                return
            }
        }

        let launchID = UUID()
        codemapProjectionPreloadLaunchesByRootEpoch[rootEpoch] = CodemapProjectionPreloadLaunch(
            id: launchID,
            authority: authority,
            retryAttempt: retryAttempt,
            phase: .eligibilityQueued,
            task: nil
        )
        recordCodemapProjectionPreloadStoreEvent(
            .scheduled,
            rootEpoch: rootEpoch,
            phase: .eligibilityQueued
        )
        let task = Task<Void, Never>(priority: .background) { [weak self] in
            guard let self else { return }
            await runCodemapProjectionPreloadLaunch(
                launchID: launchID,
                authority: authority
            )
        }
        guard var launch = codemapProjectionPreloadLaunchesByRootEpoch[rootEpoch],
              launch.id == launchID
        else {
            task.cancel()
            return
        }
        launch.task = task
        codemapProjectionPreloadLaunchesByRootEpoch[rootEpoch] = launch
    }

    private func runCodemapProjectionPreloadLaunch(
        launchID: UUID,
        authority: CodemapRootAuthority
    ) async {
        #if DEBUG
            if let codemapProjectionPreloadStartHandler {
                await codemapProjectionPreloadStartHandler(authority.rootEpoch)
            }
        #endif
        guard !Task.isCancelled,
              codemapProjectionPreloadLaunchIsCurrent(launchID: launchID, authority: authority)
        else {
            finishCodemapProjectionPreloadLaunch(
                launchID: launchID,
                authority: authority,
                phase: .cancelled
            )
            return
        }
        recordCodemapProjectionPreloadStoreEvent(
            .started,
            rootEpoch: authority.rootEpoch,
            phase: .eligibilityQueued
        )

        let eligibility: CodemapEligibilityResolution = if let cached = cachedCodemapEligibility(authority: authority) {
            cached
        } else {
            await resolveCodemapEligibility(authority: authority)
        }
        guard !Task.isCancelled,
              codemapProjectionPreloadLaunchIsCurrent(launchID: launchID, authority: authority)
        else {
            finishCodemapProjectionPreloadLaunch(
                launchID: launchID,
                authority: authority,
                phase: .cancelled
            )
            return
        }
        switch eligibility {
        case .eligible:
            recordCodemapProjectionPreloadStoreEvent(
                .eligibilityEligible,
                rootEpoch: authority.rootEpoch,
                phase: .setupJoining
            )
        case let .terminal(reason, _):
            let unavailable = WorkspaceCodemapArtifactDemandUnavailableReason.gitTerminal(reason)
            installCodemapTerminalSetupDisposition(unavailable, authority: authority)
            let phase: WorkspaceCodemapProjectionPreloadLaunchPhase = reason == .nonGit
                ? .terminalNonGit
                : .superseded
            recordCodemapProjectionPreloadStoreEvent(
                .eligibilityTerminal,
                rootEpoch: authority.rootEpoch,
                phase: phase
            )
            finishCodemapProjectionPreloadLaunch(
                launchID: launchID,
                authority: authority,
                phase: phase
            )
            return
        case .transient:
            recordCodemapProjectionPreloadStoreEvent(
                .eligibilityTransient,
                rootEpoch: authority.rootEpoch,
                phase: .transientRetry
            )
            finishCodemapProjectionPreloadLaunch(
                launchID: launchID,
                authority: authority,
                phase: .transientRetry
            )
            scheduleCodemapProjectionPreloadRetry(
                launchID: launchID,
                authority: authority
            )
            return
        case .stale:
            finishCodemapProjectionPreloadLaunch(
                launchID: launchID,
                authority: authority,
                phase: .superseded
            )
            return
        case .cancelled:
            finishCodemapProjectionPreloadLaunch(
                launchID: launchID,
                authority: authority,
                phase: .cancelled
            )
            return
        }

        guard let setup = ensureCodemapSetupTask(authority: authority) else {
            finishCodemapProjectionPreloadLaunch(
                launchID: launchID,
                authority: authority,
                phase: .superseded
            )
            return
        }
        updateCodemapProjectionPreloadLaunchPhase(
            .setupJoining,
            launchID: launchID,
            authority: authority
        )
        recordCodemapProjectionPreloadStoreEvent(
            .setupJoining,
            rootEpoch: authority.rootEpoch,
            phase: .setupJoining
        )
        let setupDisposition = await setup.value
        guard !Task.isCancelled,
              codemapProjectionPreloadLaunchIsCurrent(launchID: launchID, authority: authority)
        else {
            finishCodemapProjectionPreloadLaunch(
                launchID: launchID,
                authority: authority,
                phase: .cancelled
            )
            return
        }
        guard case .ready = setupDisposition else {
            let retryable = codemapSetupDispositionIsRetryable(setupDisposition)
            let phase: WorkspaceCodemapProjectionPreloadLaunchPhase = retryable
                ? .transientRetry
                : .superseded
            finishCodemapProjectionPreloadLaunch(
                launchID: launchID,
                authority: authority,
                phase: phase
            )
            if retryable {
                scheduleCodemapProjectionPreloadRetry(
                    launchID: launchID,
                    authority: authority
                )
            }
            return
        }
        guard let engine = codemapSessionsByRootEpoch[authority.rootEpoch]?.engine else {
            finishCodemapProjectionPreloadLaunch(
                launchID: launchID,
                authority: authority,
                phase: .superseded
            )
            return
        }

        updateCodemapProjectionPreloadLaunchPhase(
            .engineScheduling,
            launchID: launchID,
            authority: authority
        )
        recordCodemapProjectionPreloadStoreEvent(
            .engineScheduling,
            rootEpoch: authority.rootEpoch,
            phase: .engineScheduling
        )
        let disposition = await engine.scheduleProjectionPreload(rootEpoch: authority.rootEpoch)
        guard codemapProjectionPreloadLaunchIsCurrent(launchID: launchID, authority: authority) else {
            return
        }
        finishCodemapProjectionPreloadLaunch(
            launchID: launchID,
            authority: authority,
            phase: disposition
        )
        if disposition == .handedOff {
            recordCodemapProjectionPreloadStoreEvent(
                .handedOff,
                rootEpoch: authority.rootEpoch,
                phase: .handedOff
            )
        }
    }

    private func resolveCodemapEligibility(
        authority: CodemapRootAuthority
    ) async -> CodemapEligibilityResolution {
        var skipLocalClassification = false
        if let completed = codemapCompletedEligibilityByRootEpoch[authority.rootEpoch],
           completed.authority == authority,
           codemapPreflightAuthorityIsCurrent(authority)
        {
            if case let .terminal(.nonGit, proof?) = completed.result {
                if codemapLocalGitClassificationProbe.validate(proof) {
                    return completed.result
                }
                codemapCompletedEligibilityByRootEpoch.removeValue(forKey: authority.rootEpoch)
                terminalNonGitCodemapCacheByEpoch.removeValue(forKey: authority.rootEpoch)
                skipLocalClassification = true
            } else {
                return completed.result
            }
        }
        if let cached = terminalNonGitCodemapCacheByEpoch[authority.rootEpoch] {
            guard cached.standardizedRootPath == authority.standardizedRootPath,
                  codemapPreflightAuthorityIsCurrent(authority)
            else {
                terminalNonGitCodemapCacheByEpoch.removeValue(forKey: authority.rootEpoch)
                return .stale
            }
            if codemapLocalGitClassificationProbe.validate(cached.proof) {
                return .terminal(.nonGit, cached.proof)
            }
            terminalNonGitCodemapCacheByEpoch.removeValue(forKey: authority.rootEpoch)
            skipLocalClassification = true
        }

        let flight: CodemapEligibilityFlight
        if let existing = codemapEligibilityFlightsByRootEpoch[authority.rootEpoch],
           existing.authority == authority
        {
            flight = existing
        } else {
            let id = UUID()
            let task = Task { [weak self] in
                guard let self else { return CodemapEligibilityResolution.cancelled }
                return await performCodemapEligibility(
                    authority: authority,
                    skipLocalClassification: skipLocalClassification
                )
            }
            flight = CodemapEligibilityFlight(id: id, authority: authority, task: task)
            codemapEligibilityFlightsByRootEpoch[authority.rootEpoch] = flight
        }

        let result = await flight.task.value
        if codemapEligibilityFlightsByRootEpoch[authority.rootEpoch]?.id == flight.id {
            codemapEligibilityFlightsByRootEpoch.removeValue(forKey: authority.rootEpoch)
        }
        switch result {
        case .eligible, .terminal:
            if codemapPreflightAuthorityIsCurrent(authority) {
                codemapCompletedEligibilityByRootEpoch[authority.rootEpoch] = .init(
                    authority: authority,
                    result: result
                )
            }
        case .transient, .stale, .cancelled:
            break
        }
        if case let .terminal(.nonGit, proof?) = result,
           codemapPreflightAuthorityIsCurrent(authority),
           codemapLocalGitClassificationProbe.validate(proof)
        {
            terminalNonGitCodemapCacheByEpoch[authority.rootEpoch] = .init(
                standardizedRootPath: authority.standardizedRootPath,
                proof: proof
            )
        }
        return result
    }

    private func cachedCodemapEligibility(
        authority: CodemapRootAuthority
    ) -> CodemapEligibilityResolution? {
        guard let session = codemapSessionsByRootEpoch[authority.rootEpoch],
              session.authority == authority
        else { return nil }
        if case .ready? = session.setupDisposition, session.engine != nil {
            return .eligible
        }
        if case let .unavailable(reason)? = session.setupDisposition {
            switch reason {
            case let .gitTerminal(reason):
                return .terminal(reason, nil)
            case let .gitTransient(reason):
                return .transient(reason)
            default:
                return nil
            }
        }
        return nil
    }

    private func performCodemapEligibility(
        authority: CodemapRootAuthority,
        skipLocalClassification: Bool
    ) async -> CodemapEligibilityResolution {
        let rootURL = URL(fileURLWithPath: authority.standardizedRootPath, isDirectory: true)
        if !skipLocalClassification {
            let local = await codemapLocalGitClassificationProbe.resolve(rootURL)
            guard !Task.isCancelled else { return .cancelled }
            guard codemapPreflightAuthorityIsCurrent(authority) else { return .stale }
            if case let .definitelyNonGit(proof) = local,
               codemapLocalGitClassificationProbe.validate(proof)
            {
                return .terminal(.nonGit, proof)
            }
        }
        let result = await codemapGitEligibilityProbe.resolve(rootURL)
        guard !Task.isCancelled else { return .cancelled }
        guard codemapPreflightAuthorityIsCurrent(authority) else { return .stale }
        return switch result {
        case .eligible:
            .eligible
        case let .terminalUnavailable(reason):
            .terminal(reason, nil)
        case let .transientUnavailable(reason):
            .transient(reason)
        }
    }

    private func installCodemapTerminalSetupDisposition(
        _ disposition: WorkspaceCodemapArtifactDemandUnavailableReason,
        authority: CodemapRootAuthority
    ) {
        guard codemapPreflightAuthorityIsCurrent(authority) else { return }
        codemapCompletedEligibilityByRootEpoch.removeValue(forKey: authority.rootEpoch)
        if var session = codemapSessionsByRootEpoch[authority.rootEpoch] {
            guard session.authority == authority,
                  session.setupTask == nil,
                  session.setupDisposition == nil
            else { return }
            session.setupDisposition = .unavailable(disposition)
            codemapSessionsByRootEpoch[authority.rootEpoch] = session
        } else {
            var session = CodemapRootSession(authority: authority)
            session.setupDisposition = .unavailable(disposition)
            codemapSessionsByRootEpoch[authority.rootEpoch] = session
        }
    }

    private func ensureCodemapSetupTask(
        authority: CodemapRootAuthority
    ) -> Task<CodemapSetupDisposition, Never>? {
        guard codemapPreflightAuthorityIsCurrent(authority) else { return nil }
        codemapCompletedEligibilityByRootEpoch.removeValue(forKey: authority.rootEpoch)
        if let existing = codemapSessionsByRootEpoch[authority.rootEpoch] {
            guard existing.authority == authority else { return nil }
            if let setupTask = existing.setupTask { return setupTask }
            if let disposition = existing.setupDisposition {
                return Task { disposition }
            }
        } else {
            codemapSessionsByRootEpoch[authority.rootEpoch] = CodemapRootSession(
                authority: authority
            )
        }
        #if DEBUG
            codemapSetupTaskCreationCountForTesting += 1
        #endif
        let setupTask = Task { [weak self] in
            guard let self else {
                return CodemapSetupDisposition.unavailable(.cancelled)
            }
            return await performCodemapSetup(authority: authority)
        }
        codemapSessionsByRootEpoch[authority.rootEpoch]?.setupTask = setupTask
        return setupTask
    }

    private func codemapProjectionPreloadLaunchIsCurrent(
        launchID: UUID,
        authority: CodemapRootAuthority
    ) -> Bool {
        guard let launch = codemapProjectionPreloadLaunchesByRootEpoch[authority.rootEpoch],
              launch.id == launchID,
              launch.authority == authority,
              codemapPreflightAuthorityIsCurrent(authority)
        else { return false }
        return true
    }

    private func updateCodemapProjectionPreloadLaunchPhase(
        _ phase: WorkspaceCodemapProjectionPreloadLaunchPhase,
        launchID: UUID,
        authority: CodemapRootAuthority
    ) {
        guard var launch = codemapProjectionPreloadLaunchesByRootEpoch[authority.rootEpoch],
              launch.id == launchID,
              launch.authority == authority
        else { return }
        launch.phase = phase
        codemapProjectionPreloadLaunchesByRootEpoch[authority.rootEpoch] = launch
    }

    private func finishCodemapProjectionPreloadLaunch(
        launchID: UUID,
        authority: CodemapRootAuthority,
        phase: WorkspaceCodemapProjectionPreloadLaunchPhase
    ) {
        guard var launch = codemapProjectionPreloadLaunchesByRootEpoch[authority.rootEpoch],
              launch.id == launchID,
              launch.authority == authority
        else { return }
        launch.phase = phase
        codemapProjectionPreloadLaunchesByRootEpoch[authority.rootEpoch] = launch
        if phase == .cancelled || phase == .superseded {
            recordCodemapProjectionPreloadStoreEvent(
                phase == .cancelled ? .cancelled : .superseded,
                rootEpoch: authority.rootEpoch,
                phase: phase
            )
        }
    }

    private func codemapSetupDispositionIsRetryable(
        _ disposition: CodemapSetupDisposition
    ) -> Bool {
        guard case let .unavailable(reason) = disposition else { return false }
        return !codemapUnavailableIsStable(reason)
    }

    private func scheduleCodemapProjectionPreloadRetry(
        launchID: UUID,
        authority: CodemapRootAuthority
    ) {
        guard let launch = codemapProjectionPreloadLaunchesByRootEpoch[authority.rootEpoch],
              launch.id == launchID,
              launch.authority == authority,
              launch.phase == .transientRetry,
              codemapPreflightAuthorityIsCurrent(authority),
              codemapProjectionPreloadRetriesByRootEpoch[authority.rootEpoch] == nil
        else { return }
        let attempt = launch.retryAttempt + 1
        guard attempt <= codemapProjectionPreloadRetryPolicy.maximumRetryCount else { return }
        let delay = codemapProjectionPreloadRetryPolicy.backoffNanoseconds(forAttempt: attempt)
        let now = codemapProjectionPreloadRetryPolicy.nowNanoseconds()
        let (candidateDeadline, overflow) = now.addingReportingOverflow(delay)
        let deadline = overflow ? UInt64.max : candidateDeadline
        let retryID = UUID()
        let sleep = codemapProjectionPreloadRetryPolicy.sleep
        let task = Task<Void, Never>(priority: .background) { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard let self else { return }
            await performCodemapProjectionPreloadRetry(
                retryID: retryID,
                authority: authority,
                attempt: attempt,
                deadlineNanoseconds: deadline
            )
        }
        codemapProjectionPreloadRetriesByRootEpoch[authority.rootEpoch] = .init(
            id: retryID,
            authority: authority,
            attempt: attempt,
            deadlineNanoseconds: deadline,
            task: task
        )
        recordCodemapProjectionPreloadStoreEvent(
            .retryScheduled,
            rootEpoch: authority.rootEpoch,
            phase: .transientRetry
        )
    }

    private func performCodemapProjectionPreloadRetry(
        retryID: UUID,
        authority: CodemapRootAuthority,
        attempt: Int,
        deadlineNanoseconds: UInt64
    ) async {
        guard let retry = codemapProjectionPreloadRetriesByRootEpoch[authority.rootEpoch],
              retry.id == retryID,
              retry.authority == authority,
              retry.attempt == attempt,
              retry.deadlineNanoseconds == deadlineNanoseconds
        else { return }
        codemapProjectionPreloadRetriesByRootEpoch.removeValue(forKey: authority.rootEpoch)
        guard !Task.isCancelled,
              codemapProjectionPreloadRetryPolicy.nowNanoseconds() >= deadlineNanoseconds,
              codemapPreflightAuthorityIsCurrent(authority)
        else { return }
        recordCodemapProjectionPreloadStoreEvent(
            .retryStarted,
            rootEpoch: authority.rootEpoch,
            phase: .transientRetry
        )

        if let setupDisposition = codemapSessionsByRootEpoch[authority.rootEpoch]?.setupDisposition,
           codemapSetupDispositionIsRetryable(setupDisposition)
        {
            _ = detachCodemapSession(
                rootEpoch: authority.rootEpoch,
                invalidationCommands: [.catalogAdvanced]
            )
            await awaitCodemapCleanupFlights(rootIDs: [authority.rootEpoch.rootID])
            guard !Task.isCancelled else { return }
        }
        scheduleCodemapProjectionPreloadAfterRootReady(
            rootEpoch: authority.rootEpoch,
            retryAttempt: attempt
        )
    }

    func publishedCodemapStructurePresentation(
        seedFileIDs: [UUID],
        outputLimits: WorkspaceCodemapStructureOutputLimits,
        rootScope: WorkspaceLookupRootScope,
        logicalRootDisplayNamesByRootID: [UUID: String]
    ) async -> WorkspaceCodemapStructurePresentation? {
        guard !Task.isCancelled,
              !seedFileIDs.isEmpty,
              outputLimits.maximumCodemapTokenCount > 0
        else { return nil }

        var orderedFileIDs: [UUID] = []
        var seenFileIDs = Set<UUID>()
        for fileID in seedFileIDs where seenFileIDs.insert(fileID).inserted {
            orderedFileIDs.append(fileID)
        }
        guard orderedFileIDs.count <= outputLimits.maximumFileCount else { return nil }

        let allowedRootIDs = Set(rootsForPathLookup(scope: rootScope).map(\.id))
        var captures: [CodemapPublishedStructureCapture] = []
        captures.reserveCapacity(orderedFileIDs.count)
        for fileID in orderedFileIDs {
            guard let file = filesByID[fileID],
                  allowedRootIDs.contains(file.rootID),
                  isDiscoverableFileID(file.id),
                  let state = rootStatesByID[file.rootID],
                  state.fileIDsByRelativePath[file.standardizedRelativePath] == file.id,
                  let identity = WorkspaceCodemapArtifactBindingIdentity(
                      rootID: file.rootID,
                      rootLifetimeID: state.lifetimeID,
                      fileID: file.id,
                      standardizedRootPath: state.root.standardizedFullPath,
                      standardizedRelativePath: file.standardizedRelativePath,
                      standardizedFullPath: file.standardizedFullPath
                  )
            else { return nil }
            let rootEpoch = WorkspaceCodemapRootEpoch(
                rootID: file.rootID,
                rootLifetimeID: state.lifetimeID
            )
            guard codemapCleanupFlightsByRootID[file.rootID] == nil,
                  codemapRootMutationFenceTokensByRootEpoch[rootEpoch] == nil,
                  !codemapPathIsFenced(
                      rootEpoch: rootEpoch,
                      relativePath: file.standardizedRelativePath
                  ),
                  let session = codemapSessionsByRootEpoch[rootEpoch],
                  codemapAuthorityIsCurrent(session.authority),
                  case .ready? = session.setupDisposition,
                  let engine = session.engine
            else { return nil }
            let fileExtension = (file.name as NSString).pathExtension
            guard let language = SyntaxManager.shared.language(forFileExtension: fileExtension),
                  SyntaxManager.supportsCodeMap(fileExtension: fileExtension),
                  let logicalPath = WorkspaceCodemapLogicalPresentationPath(
                      rootDisplayName: logicalRootDisplayNamesByRootID[file.rootID] ?? state.root.name,
                      standardizedRelativePath: file.standardizedRelativePath
                  )
            else { return nil }
            let pathGeneration = session.pathGenerationsByRelativePath[file.standardizedRelativePath]
                ?? session.authority.ingressGeneration
            captures.append(CodemapPublishedStructureCapture(
                request: WorkspaceCodemapPublishedArtifactLookupRequest(
                    ownerID: UUID(),
                    identity: identity,
                    requestGeneration: pathGeneration,
                    catalogGeneration: session.authority.catalogGeneration,
                    pathGeneration: pathGeneration,
                    ingressGeneration: session.authority.ingressGeneration,
                    language: language
                ),
                rootEpoch: rootEpoch,
                authority: session.authority,
                engine: engine,
                logicalPath: logicalPath
            ))
        }

        var hitsByFileID: [UUID: WorkspaceCodemapPublishedArtifactLookupHit] = [:]
        hitsByFileID.reserveCapacity(captures.count)
        for capture in captures {
            guard !Task.isCancelled else { return nil }
            switch await capture.engine.lookupPublishedArtifact(capture.request) {
            case let .hit(hit):
                hitsByFileID[capture.request.identity.fileID] = hit
            case .miss, .cancelled:
                return nil
            }
        }

        let finalAllowedRootIDs = Set(rootsForPathLookup(scope: rootScope).map(\.id))
        for capture in captures {
            let identity = capture.request.identity
            guard let file = filesByID[identity.fileID],
                  finalAllowedRootIDs.contains(identity.rootID),
                  isDiscoverableFileID(identity.fileID),
                  file.rootID == identity.rootID,
                  file.standardizedRelativePath == identity.standardizedRelativePath,
                  file.standardizedFullPath == identity.standardizedFullPath,
                  let state = rootStatesByID[identity.rootID],
                  state.lifetimeID == identity.rootLifetimeID,
                  state.fileIDsByRelativePath[identity.standardizedRelativePath] == identity.fileID,
                  codemapCleanupFlightsByRootID[identity.rootID] == nil,
                  codemapRootMutationFenceTokensByRootEpoch[capture.rootEpoch] == nil,
                  !codemapPathIsFenced(
                      rootEpoch: capture.rootEpoch,
                      relativePath: identity.standardizedRelativePath
                  ),
                  let session = codemapSessionsByRootEpoch[capture.rootEpoch],
                  session.authority == capture.authority,
                  session.engine === capture.engine,
                  (
                      session.pathGenerationsByRelativePath[identity.standardizedRelativePath]
                          ?? session.authority.ingressGeneration
                  ) == capture.request.pathGeneration
            else { return nil }
        }

        for capture in captures {
            guard let hit = hitsByFileID[capture.request.identity.fileID],
                  case .ready = hit.handle.outcome
            else { return nil }
        }
        guard replayWarmPublishedCodemapMarkerReadiness(
            captures,
            rootScope: rootScope
        ) != .stale else { return nil }

        captures.sort {
            if $0.logicalPath.displayPath != $1.logicalPath.displayPath {
                return $0.logicalPath.displayPath.utf8.lexicographicallyPrecedes(
                    $1.logicalPath.displayPath.utf8
                )
            }
            return $0.request.identity.fileID.uuidString < $1.request.identity.fileID.uuidString
        }

        let bundleID = WorkspaceCodemapFrozenPresentationBundleID()
        let separatorTokens = TokenCalculationService.estimateTokens(for: "\n\n")
        var entries: [WorkspaceCodemapStructureRenderedEntry] = []
        var issues: [WorkspaceCodemapStructureIssue] = []
        var usedTokens = 0
        for capture in captures {
            let fileID = capture.request.identity.fileID
            guard let hit = hitsByFileID[fileID],
                  case let .ready(artifact) = hit.handle.outcome
            else { return nil }
            let text = CodeMapAPIContentFormatter.pathAndImportsBlock(
                displayPath: capture.logicalPath.displayPath,
                imports: artifact.imports
            ) + artifact.apiDescription
            let tokenCount = TokenCalculationService.estimateTokens(for: text)
            let cost = tokenCount + (entries.isEmpty ? 0 : separatorTokens)
            let (attempted, overflow) = usedTokens.addingReportingOverflow(cost)
            guard !overflow, attempted <= outputLimits.maximumCodemapTokenCount else {
                issues.append(.tokenLimit(
                    path: capture.logicalPath.displayPath,
                    attempted: overflow ? .max : attempted,
                    limit: outputLimits.maximumCodemapTokenCount
                ))
                break
            }
            usedTokens = attempted
            entries.append(WorkspaceCodemapStructureRenderedEntry(
                entry: WorkspaceCodemapOperationRenderedEntry(
                    bundleID: bundleID,
                    fileID: fileID,
                    rootEpoch: capture.rootEpoch,
                    artifactKey: hit.handle.key,
                    logicalPath: capture.logicalPath,
                    text: text,
                    tokenCount: tokenCount
                ),
                isSeed: true,
                depth: 0,
                reachedBy: []
            ))
        }
        return WorkspaceCodemapStructurePresentation(
            outcome: issues.isEmpty ? .ready : .budget,
            entries: entries,
            issues: issues,
            requestedSeedCount: seedFileIDs.count,
            resolvedSeedCount: captures.count,
            examinedEdgeCount: 0,
            codemapTokenCount: usedTokens
        )
    }

    private func replayWarmPublishedCodemapMarkerReadiness(
        _ captures: [CodemapPublishedStructureCapture],
        rootScope: WorkspaceLookupRootScope
    ) -> CodemapWarmPublishedMarkerReplayDisposition {
        let requestedRootIDs = Set(rootRefs(scope: rootScope).map(\.id))
        var changesByRootEpoch: [
            WorkspaceCodemapRootEpoch: [WorkspaceCodemapMarkerReadinessChange]
        ] = [:]
        for capture in captures {
            let request = capture.request
            let identity = request.identity
            guard requestedRootIDs.contains(identity.rootID),
                  capture.rootEpoch == WorkspaceCodemapRootEpoch(
                      rootID: identity.rootID,
                      rootLifetimeID: identity.rootLifetimeID
                  ),
                  let state = rootStatesByID[identity.rootID],
                  state.lifetimeID == identity.rootLifetimeID,
                  state.root.standardizedFullPath == identity.standardizedRootPath,
                  state.fileIDsByRelativePath[identity.standardizedRelativePath] == identity.fileID,
                  let file = filesByID[identity.fileID],
                  isDiscoverableFileID(identity.fileID),
                  file.rootID == identity.rootID,
                  file.standardizedRelativePath == identity.standardizedRelativePath,
                  file.standardizedFullPath == identity.standardizedFullPath,
                  codemapCleanupFlightsByRootID[identity.rootID] == nil,
                  !codemapProjectionCatalogIsFenced(rootEpoch: capture.rootEpoch),
                  let session = codemapSessionsByRootEpoch[capture.rootEpoch],
                  case .ready? = session.setupDisposition,
                  session.authority == capture.authority,
                  codemapAuthorityIsCurrent(session.authority),
                  session.engine === capture.engine,
                  session.authority.catalogGeneration == request.catalogGeneration,
                  session.authority.ingressGeneration == request.ingressGeneration
            else { return .stale }
            let currentPathGeneration = session.pathGenerationsByRelativePath[
                identity.standardizedRelativePath
            ] ?? session.authority.ingressGeneration
            guard request.requestGeneration == currentPathGeneration,
                  request.pathGeneration == currentPathGeneration
            else { return .stale }
            changesByRootEpoch[capture.rootEpoch, default: []].append(
                WorkspaceCodemapMarkerReadinessChange(
                    fileID: identity.fileID,
                    standardizedRelativePath: identity.standardizedRelativePath,
                    requestGeneration: request.requestGeneration,
                    pathGeneration: request.pathGeneration,
                    state: .ready
                )
            )
        }

        var applied = false
        let rootEpochs = changesByRootEpoch.keys.sorted {
            if $0.rootID != $1.rootID {
                return $0.rootID.uuidString < $1.rootID.uuidString
            }
            return $0.rootLifetimeID.uuidString < $1.rootLifetimeID.uuidString
        }
        for rootEpoch in rootEpochs {
            var session = codemapSessionsByRootEpoch[rootEpoch]!
            let changes = changesByRootEpoch[rootEpoch]!
            let effectiveChanges = changes.filter {
                session.markerReadinessByFileID[$0.fileID] != $0
            }
            guard !effectiveChanges.isEmpty else { continue }
            for change in effectiveChanges {
                session.markerReadinessByFileID[change.fileID] = change
            }
            session.markerReadinessRevision &+= 1
            codemapSessionsByRootEpoch[rootEpoch] = session
            #if DEBUG
                WorktreeStartupInstrumentation.recordBenchmarkMarkerPublication(
                    tag: WorktreeStartupInstrumentation.currentBenchmarkMetricTag,
                    rootID: rootEpoch.rootID,
                    rootLifetimeID: rootEpoch.rootLifetimeID,
                    revision: session.markerReadinessRevision,
                    effectiveChangeCount: effectiveChanges.count,
                    source: .warmReplay
                )
            #endif
            yieldCodemapMarkerReadiness(WorkspaceCodemapMarkerReadinessEvent(
                rootEpoch: rootEpoch,
                revision: session.markerReadinessRevision,
                changes: effectiveChanges
            ))
            applied = true
        }
        return applied ? .applied : .alreadyCurrent
    }

    func requestCodemapArtifact(
        forFileID fileID: UUID,
        priority: CodeMapArtifactBuildPriority = .demand
    ) async -> WorkspaceCodemapArtifactDemandResult {
        await requestCodemapArtifactWithOwnership(forFileID: fileID, priority: priority).result
    }

    func requestAutomaticCodemapArtifactWithOwnership(
        candidate: WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate,
        rootScope: WorkspaceLookupRootScope,
        rootScopeEpochs: [WorkspaceCodemapRootEpoch],
        coverageProofs: [WorkspaceCodemapProjectionCoverageProof]
    ) async -> WorkspaceCodemapArtifactDemandOwnedResult? {
        guard automaticSelectionCandidateDemandIsCurrent(
            candidate: candidate,
            rootScope: rootScope,
            rootScopeEpochs: rootScopeEpochs,
            coverageProofs: coverageProofs
        ) else { return nil }
        return await requestCodemapArtifactWithOwnership(
            forFileID: candidate.identity.fileID,
            priority: .background
        )
    }

    func requestProvisionalAutomaticCodemapArtifactWithOwnership(
        candidate: WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate,
        rootScope: WorkspaceLookupRootScope,
        rootScopeEpochs: [WorkspaceCodemapRootEpoch]
    ) async -> WorkspaceCodemapArtifactDemandOwnedResult? {
        guard provisionalAutomaticSelectionCandidateDemandIsCurrent(
            candidate: candidate,
            rootScope: rootScope,
            rootScopeEpochs: rootScopeEpochs
        ) else { return nil }
        return await requestCodemapArtifactWithOwnership(
            forFileID: candidate.identity.fileID,
            priority: .background
        )
    }

    func retryBusyAutomaticCodemapArtifactDemand(
        _ ticket: WorkspaceCodemapArtifactDemandTicket,
        candidate: WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate,
        rootScope: WorkspaceLookupRootScope,
        rootScopeEpochs: [WorkspaceCodemapRootEpoch],
        coverageProofs: [WorkspaceCodemapProjectionCoverageProof]
    ) async -> WorkspaceCodemapArtifactDemandOwnedResult? {
        guard automaticSelectionCandidateDemandIsCurrent(
            candidate: candidate,
            rootScope: rootScope,
            rootScopeEpochs: rootScopeEpochs,
            coverageProofs: coverageProofs
        ), codemapDemandIsCurrent(ticket),
        var session = codemapSessionsByRootEpoch[ticket.rootEpoch],
        let record = session.demandsByFileID[ticket.fileID],
        codemapTicketsShareDemand(record.ticket, ticket),
        record.retainIDs.contains(ticket.retainID),
        case .unavailable(.busy) = record.result
        else { return nil }
        guard record.retainIDs.count == 1 else {
            return WorkspaceCodemapArtifactDemandOwnedResult(
                result: codemapDemandResult(record.result, for: ticket),
                ownership: .notAcquired
            )
        }
        session.demandsByFileID.removeValue(forKey: ticket.fileID)
        let bundle = session.bundlesByRequestID.removeValue(forKey: ticket.requestID)
        codemapSessionsByRootEpoch[ticket.rootEpoch] = session
        bundle?.close()
        if let engine = session.engine {
            _ = await engine.cancel(owner: record.owner)
        }
        guard !Task.isCancelled,
              automaticSelectionCandidateDemandIsCurrent(
                  candidate: candidate,
                  rootScope: rootScope,
                  rootScopeEpochs: rootScopeEpochs,
                  coverageProofs: coverageProofs
              )
        else { return nil }
        return await requestAutomaticCodemapArtifactWithOwnership(
            candidate: candidate,
            rootScope: rootScope,
            rootScopeEpochs: rootScopeEpochs,
            coverageProofs: coverageProofs
        )
    }

    private func automaticSelectionCandidateDemandIsCurrent(
        candidate: WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate,
        rootScope: WorkspaceLookupRootScope,
        rootScopeEpochs: [WorkspaceCodemapRootEpoch],
        coverageProofs: [WorkspaceCodemapProjectionCoverageProof]
    ) -> Bool {
        let rootEpoch = WorkspaceCodemapRootEpoch(
            rootID: candidate.identity.rootID,
            rootLifetimeID: candidate.identity.rootLifetimeID
        )
        guard codemapAutomaticSelectionRootScopeEpochs(rootScope) == rootScopeEpochs,
              rootScopeEpochs.contains(rootEpoch),
              coverageProofs.contains(where: { $0.generation.rootEpoch == rootEpoch }),
              automaticSelectionCoverageProofsAreCurrent(coverageProofs),
              let state = rootStatesByID[rootEpoch.rootID],
              state.lifetimeID == rootEpoch.rootLifetimeID,
              let file = filesByID[candidate.identity.fileID],
              file.rootID == rootEpoch.rootID,
              isDiscoverableFileID(file.id),
              state.fileIDsByRelativePath[file.standardizedRelativePath] == file.id,
              file.standardizedRelativePath == candidate.identity.standardizedRelativePath,
              file.standardizedFullPath == candidate.identity.standardizedFullPath,
              let session = codemapSessionsByRootEpoch[rootEpoch],
              session.authority.catalogGeneration == candidate.catalogGeneration,
              session.authority.ingressGeneration == candidate.ingressGeneration
        else { return false }
        let pathGeneration = session.pathGenerationsByRelativePath[file.standardizedRelativePath]
            ?? session.authority.ingressGeneration
        return pathGeneration == candidate.pathGeneration &&
            pathGeneration == candidate.requestGeneration
    }

    private func provisionalAutomaticSelectionCandidateDemandIsCurrent(
        candidate: WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate,
        rootScope: WorkspaceLookupRootScope,
        rootScopeEpochs: [WorkspaceCodemapRootEpoch]
    ) -> Bool {
        let rootEpoch = WorkspaceCodemapRootEpoch(
            rootID: candidate.identity.rootID,
            rootLifetimeID: candidate.identity.rootLifetimeID
        )
        guard codemapAutomaticSelectionRootScopeEpochs(rootScope) == rootScopeEpochs,
              rootScopeEpochs.contains(rootEpoch),
              let state = rootStatesByID[rootEpoch.rootID],
              state.lifetimeID == rootEpoch.rootLifetimeID,
              let file = filesByID[candidate.identity.fileID],
              file.rootID == rootEpoch.rootID,
              isDiscoverableFileID(file.id),
              state.fileIDsByRelativePath[file.standardizedRelativePath] == file.id,
              file.standardizedRelativePath == candidate.identity.standardizedRelativePath,
              file.standardizedFullPath == candidate.identity.standardizedFullPath,
              let session = codemapSessionsByRootEpoch[rootEpoch],
              session.authority.catalogGeneration == candidate.catalogGeneration,
              session.authority.ingressGeneration == candidate.ingressGeneration
        else { return false }
        let pathGeneration = session.pathGenerationsByRelativePath[file.standardizedRelativePath]
            ?? session.authority.ingressGeneration
        return pathGeneration == candidate.pathGeneration &&
            pathGeneration == candidate.requestGeneration
    }

    func requestCodemapArtifactWithOwnership(
        forFileID fileID: UUID,
        priority: CodeMapArtifactBuildPriority = .demand
    ) async -> WorkspaceCodemapArtifactDemandOwnedResult {
        #if DEBUG
            codemapArtifactDemandRequestCountForTesting += 1
        #endif
        guard let file = filesByID[fileID] else {
            return .init(result: .unavailable(.fileNotCataloged), ownership: .notAcquired)
        }
        guard let state = rootStatesByID[file.rootID] else {
            return .init(result: .unavailable(.rootNotLoaded), ownership: .notAcquired)
        }
        guard state.fileIDsByRelativePath[file.standardizedRelativePath] == file.id,
              filesByID[file.id] == file
        else {
            return .init(result: .unavailable(.fileNotCataloged), ownership: .notAcquired)
        }

        let fileExtension = (file.name as NSString).pathExtension
        guard let language = SyntaxManager.shared.language(forFileExtension: fileExtension),
              SyntaxManager.supportsCodeMap(fileExtension: fileExtension)
        else {
            return .init(result: .unavailable(.unsupportedFileType), ownership: .notAcquired)
        }
        guard let identity = WorkspaceCodemapArtifactBindingIdentity(
            rootID: file.rootID,
            rootLifetimeID: state.lifetimeID,
            fileID: file.id,
            standardizedRootPath: state.root.standardizedFullPath,
            standardizedRelativePath: file.standardizedRelativePath,
            standardizedFullPath: file.standardizedFullPath
        ) else {
            return .init(result: .unavailable(.staleCurrentness), ownership: .notAcquired)
        }

        let rootEpoch = WorkspaceCodemapRootEpoch(
            rootID: file.rootID,
            rootLifetimeID: state.lifetimeID
        )
        if codemapCleanupFlightsByRootID[file.rootID] != nil ||
            codemapRootMutationFenceTokensByRootEpoch[rootEpoch] != nil ||
            codemapPathIsFenced(rootEpoch: rootEpoch, relativePath: file.standardizedRelativePath)
        {
            return .init(result: .unavailable(.busy(retryAfterMilliseconds: nil)), ownership: .notAcquired)
        }

        guard let authority = currentCodemapAuthority(rootEpoch: rootEpoch) else {
            return .init(result: .unavailable(.staleCurrentness), ownership: .notAcquired)
        }
        if let retry = codemapProjectionPreloadRetriesByRootEpoch[rootEpoch],
           retry.authority == authority
        {
            let now = codemapProjectionPreloadRetryPolicy.nowNanoseconds()
            let remainingNanoseconds = retry.deadlineNanoseconds > now
                ? retry.deadlineNanoseconds - now
                : 0
            return .init(
                result: .unavailable(.busy(
                    retryAfterMilliseconds: Int(exactly: remainingNanoseconds / 1_000_000)
                )),
                ownership: .notAcquired
            )
        }
        if let existing = codemapSessionsByRootEpoch[rootEpoch],
           !codemapAuthorityMatchesLoadedRoot(existing.authority)
        {
            _ = detachCodemapSession(
                rootEpoch: rootEpoch,
                invalidationCommands: [.repositoryAuthority]
            )
            return .init(result: .unavailable(.busy(retryAfterMilliseconds: nil)), ownership: .notAcquired)
        }

        if case let .unavailable(reason)? =
            codemapSessionsByRootEpoch[rootEpoch]?.setupDisposition,
            codemapUnavailableIsStable(reason)
        {
            var shouldReturnStableUnavailable = true
            if case .gitTerminal(.nonGit) = reason,
               let cached = terminalNonGitCodemapCacheByEpoch[rootEpoch]
            {
                if cached.standardizedRootPath == authority.standardizedRootPath,
                   codemapLocalGitClassificationProbe.validate(cached.proof)
                {
                    shouldReturnStableUnavailable = true
                } else {
                    codemapCompletedEligibilityByRootEpoch.removeValue(forKey: rootEpoch)
                    codemapSessionsByRootEpoch.removeValue(forKey: rootEpoch)
                    shouldReturnStableUnavailable = false
                }
            }
            if shouldReturnStableUnavailable {
                return .init(result: .unavailable(reason), ownership: .notAcquired)
            }
        }

        if codemapSessionsByRootEpoch[rootEpoch] == nil {
            let eligibility = await resolveCodemapEligibility(authority: authority)
            guard codemapPreflightAuthorityIsCurrent(authority),
                  let currentFile = filesByID[file.id],
                  currentFile == file,
                  rootStatesByID[file.rootID]?
                  .fileIDsByRelativePath[file.standardizedRelativePath] == file.id
            else {
                return .init(result: .unavailable(.staleCurrentness), ownership: .notAcquired)
            }
            switch eligibility {
            case .eligible:
                break
            case let .terminal(reason, _):
                installCodemapTerminalSetupDisposition(.gitTerminal(reason), authority: authority)
                return .init(result: .unavailable(.gitTerminal(reason)), ownership: .notAcquired)
            case let .transient(reason):
                return .init(result: .unavailable(.gitTransient(reason)), ownership: .notAcquired)
            case .stale:
                return .init(result: .unavailable(.staleCurrentness), ownership: .notAcquired)
            case .cancelled:
                return .init(result: .unavailable(.cancelled), ownership: .notAcquired)
            }
        }

        if var session = codemapSessionsByRootEpoch[rootEpoch],
           var existing = session.demandsByFileID[file.id]
        {
            switch existing.result {
            case .pending, .ready:
                let joinedTicket = retainedCodemapTicket(for: existing.ticket)
                existing.retainIDs.insert(joinedTicket.retainID)
                session.demandsByFileID[file.id] = existing
                codemapSessionsByRootEpoch[rootEpoch] = session
                return .init(
                    result: codemapDemandResult(existing.result, for: joinedTicket),
                    ownership: .joined(joinedTicket)
                )
            case let .unavailable(reason) where codemapUnavailableIsStable(reason):
                return .init(result: existing.result, ownership: .notAcquired)
            case .unavailable:
                break
            }
        }
        if case let .unavailable(reason)? =
            codemapSessionsByRootEpoch[rootEpoch]?.setupDisposition,
            !codemapUnavailableIsStable(reason)
        {
            if codemapProjectionPreloadRetriesByRootEpoch[rootEpoch] != nil {
                return .init(
                    result: .unavailable(.busy(retryAfterMilliseconds: nil)),
                    ownership: .notAcquired
                )
            }
            _ = detachCodemapSession(rootEpoch: rootEpoch)
            return .init(result: .unavailable(.busy(retryAfterMilliseconds: nil)), ownership: .notAcquired)
        }

        if codemapSessionsByRootEpoch[rootEpoch] == nil {
            codemapSessionsByRootEpoch[rootEpoch] = CodemapRootSession(authority: authority)
        }

        let pathGeneration = codemapSessionsByRootEpoch[rootEpoch]?
            .pathGenerationsByRelativePath[file.standardizedRelativePath] ?? authority.ingressGeneration
        let ticket = WorkspaceCodemapArtifactDemandTicket(
            retainID: UUID(),
            requestID: UUID(),
            rootEpoch: rootEpoch,
            fileID: file.id,
            requestGeneration: pathGeneration,
            catalogGeneration: authority.catalogGeneration,
            pathGeneration: pathGeneration,
            ingressGeneration: authority.ingressGeneration
        )
        let owner = WorkspaceCodemapLiveDemandOwner()
        var record = CodemapDemandRecord(
            ticket: ticket,
            identity: identity,
            language: language,
            owner: owner,
            retainIDs: [ticket.retainID],
            result: .pending(ticket),
            task: nil
        )

        _ = ensureCodemapSetupTask(authority: authority)

        codemapSessionsByRootEpoch[rootEpoch]?.demandsByFileID[file.id] = record
        #if DEBUG
            codemapDemandTaskCreationCountForTesting += 1
        #endif
        let demandTask = Task { [weak self] in
            guard let self else { return }
            await performCodemapDemand(ticket: ticket, priority: priority)
        }
        record.task = demandTask
        codemapSessionsByRootEpoch[rootEpoch]?.demandsByFileID[file.id] = record
        return .init(result: .pending(ticket), ownership: .created(ticket))
    }

    func codemapArtifactDemandStatus(
        _ ticket: WorkspaceCodemapArtifactDemandTicket
    ) -> WorkspaceCodemapArtifactDemandResult {
        guard codemapDemandIsCurrent(ticket),
              let record = codemapSessionsByRootEpoch[ticket.rootEpoch]?
              .demandsByFileID[ticket.fileID],
              codemapTicketsShareDemand(record.ticket, ticket)
        else {
            return .unavailable(.staleCurrentness)
        }
        guard record.retainIDs.contains(ticket.retainID) else {
            if case .unavailable(.cancelled) = record.result {
                return .unavailable(.cancelled)
            }
            return .unavailable(.staleCurrentness)
        }
        return codemapDemandResult(record.result, for: ticket)
    }

    func acquireCodemapProjectionDemand(
        sourceTickets: [WorkspaceCodemapArtifactDemandTicket],
        deadlineUptimeNanoseconds: UInt64
    ) async -> WorkspaceCodemapProjectionDemandAcquisition {
        #if DEBUG
            guard codemapAutomaticRetainedProjectionDemandPolicyForTesting == .enabled else {
                return .unavailable(reason: .capabilityUnavailable, retryAfterMilliseconds: nil)
            }
        #endif
        guard sourceTickets.count <= 1024 else {
            return .busy(
                reason: .fileIDLimit(attempted: 1025, limit: 1024),
                retryAfterMilliseconds: 100
            )
        }
        guard let first = sourceTickets.first else {
            return .unavailable(reason: .generationMismatch, retryAfterMilliseconds: nil)
        }
        let rootEpoch = first.rootEpoch
        var uniqueFileIDs: [UUID] = []
        var seenFileIDs = Set<UUID>()
        for ticket in sourceTickets {
            guard ticket.rootEpoch == rootEpoch,
                  ticket.catalogGeneration == first.catalogGeneration,
                  ticket.ingressGeneration == first.ingressGeneration,
                  codemapDemandIsCurrent(ticket),
                  let record = codemapSessionsByRootEpoch[rootEpoch]?
                  .demandsByFileID[ticket.fileID],
                  record.retainIDs.contains(ticket.retainID),
                  codemapTicketsShareDemand(record.ticket, ticket),
                  case let .ready(ready) = record.result,
                  codemapTicketsShareDemand(ready.ticket, ticket)
            else {
                return .unavailable(reason: .generationMismatch, retryAfterMilliseconds: nil)
            }
            if seenFileIDs.insert(ticket.fileID).inserted {
                uniqueFileIDs.append(ticket.fileID)
            }
        }
        guard let session = codemapSessionsByRootEpoch[rootEpoch],
              session.authority.catalogGeneration == first.catalogGeneration,
              session.authority.ingressGeneration == first.ingressGeneration,
              let engine = session.engine
        else {
            return .unavailable(reason: .rootNotRegistered, retryAfterMilliseconds: 100)
        }
        guard codemapProjectionDemandsByID.count < Self.maximumRetainedCodemapProjectionDemands else {
            return .busy(reason: .requestLimit, retryAfterMilliseconds: 100)
        }
        guard let fileIDCount = UInt64(exactly: uniqueFileIDs.count) else {
            return .busy(
                reason: .metadataByteLimit(
                    attempted: .max,
                    limit: Self.maximumRetainedCodemapProjectionDemandMetadataBytes
                ),
                retryAfterMilliseconds: 100
            )
        }
        let (fileIDBytes, multiplicationOverflow) = fileIDCount.multipliedReportingOverflow(by: 16)
        let (metadataByteCount, metadataOverflowForRecord) = fileIDBytes.addingReportingOverflow(192)
        guard !multiplicationOverflow, !metadataOverflowForRecord else {
            return .busy(
                reason: .metadataByteLimit(
                    attempted: .max,
                    limit: Self.maximumRetainedCodemapProjectionDemandMetadataBytes
                ),
                retryAfterMilliseconds: 100
            )
        }
        let retainedMetadataByteCount = codemapProjectionDemandsByID.values.reduce(UInt64(0)) {
            let (value, overflow) = $0.addingReportingOverflow($1.metadataByteCount)
            return overflow ? .max : value
        }
        let (attemptedMetadataByteCount, metadataOverflow) = retainedMetadataByteCount
            .addingReportingOverflow(metadataByteCount)
        guard !metadataOverflow,
              attemptedMetadataByteCount <= Self.maximumRetainedCodemapProjectionDemandMetadataBytes
        else {
            return .busy(
                reason: .metadataByteLimit(
                    attempted: metadataOverflow ? .max : attemptedMetadataByteCount,
                    limit: Self.maximumRetainedCodemapProjectionDemandMetadataBytes
                ),
                retryAfterMilliseconds: 100
            )
        }

        let acquisition = await engine.acquireProjectionDemand(
            rootEpoch: rootEpoch,
            fileIDs: uniqueFileIDs,
            catalogGeneration: first.catalogGeneration,
            ingressGeneration: first.ingressGeneration,
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds,
            owner: WorkspaceCodemapLiveDemandOwner()
        )
        guard case let .acquired(ticket, _) = acquisition else { return acquisition }

        var demandRecord = CodemapProjectionDemandRecord(
            ticket: ticket,
            fileIDs: uniqueFileIDs,
            metadataByteCount: metadataByteCount,
            engine: engine,
            expiryTask: nil
        )
        let expiryTask = Task { [weak self] in
            let now = DispatchTime.now().uptimeNanoseconds
            if deadlineUptimeNanoseconds > now {
                try? await Task.sleep(nanoseconds: deadlineUptimeNanoseconds - now)
            }
            // Preserve the engine's typed `.expired` result through the caller's final exact
            // deadline poll. This bounded grace is cleanup-only; it does not retain priority.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.expireCodemapProjectionDemand(ticket)
        }
        demandRecord.expiryTask = expiryTask
        codemapProjectionDemandsByID[ticket.id] = demandRecord
        return acquisition
    }

    func codemapProjectionDemandStatus(
        _ ticket: WorkspaceCodemapProjectionDemandTicket
    ) async -> WorkspaceCodemapProjectionDemandStatus {
        guard let record = codemapProjectionDemandsByID[ticket.id],
              record.ticket == ticket
        else {
            if let terminal = terminalCodemapProjectionDemandsByID[ticket.id],
               terminal.ticket == ticket
            {
                return terminal.status
            }
            return .stale
        }
        let isCurrent = record.fileIDs.allSatisfy { fileID in
            guard let session = codemapSessionsByRootEpoch[ticket.rootEpoch],
                  session.authority.catalogGeneration == ticket.catalogGeneration,
                  session.authority.ingressGeneration == ticket.ingressGeneration,
                  let demand = session.demandsByFileID[fileID],
                  codemapDemandIsCurrent(demand.ticket),
                  case let .ready(ready) = demand.result
            else { return false }
            return codemapTicketsShareDemand(ready.ticket, demand.ticket)
        }
        guard isCurrent else {
            codemapProjectionDemandsByID.removeValue(forKey: ticket.id)?.expiryTask?.cancel()
            await record.engine.releaseProjectionDemand(ticket)
            return .stale
        }
        return await record.engine.projectionDemandStatus(ticket)
    }

    @discardableResult
    func releaseCodemapProjectionDemand(
        _ ticket: WorkspaceCodemapProjectionDemandTicket,
        deadline: ContinuousClock.Instant? = nil
    ) async -> Bool {
        guard let record = codemapProjectionDemandsByID.removeValue(forKey: ticket.id),
              record.ticket == ticket
        else {
            return terminalCodemapProjectionDemandsByID.removeValue(forKey: ticket.id) != nil
        }
        record.expiryTask?.cancel()
        terminalCodemapProjectionDemandsByID.removeValue(forKey: ticket.id)
        let cleanupTask = Task {
            await record.engine.releaseProjectionDemand(ticket)
        }
        _ = await waitForCodemapSharedTask(cleanupTask, deadline: deadline)
        return true
    }

    private func expireCodemapProjectionDemand(
        _ ticket: WorkspaceCodemapProjectionDemandTicket
    ) async {
        guard let record = codemapProjectionDemandsByID.removeValue(forKey: ticket.id),
              record.ticket == ticket
        else { return }
        let terminalStatus = await record.engine.projectionDemandStatus(ticket)
        await record.engine.releaseProjectionDemand(ticket)
        terminalCodemapProjectionDemandsByID[ticket.id] = TerminalCodemapProjectionDemandRecord(
            ticket: ticket,
            status: terminalStatus
        )
        if terminalCodemapProjectionDemandsByID.count > Self.maximumRetainedCodemapProjectionDemands,
           let evictedID = terminalCodemapProjectionDemandsByID.keys.sorted(by: {
               $0.uuidString < $1.uuidString
           }).first
        {
            terminalCodemapProjectionDemandsByID.removeValue(forKey: evictedID)
        }
    }

    func retryBusyCodemapArtifactDemand(
        _ ticket: WorkspaceCodemapArtifactDemandTicket,
        priority: CodeMapArtifactBuildPriority
    ) async -> WorkspaceCodemapArtifactDemandResult {
        guard codemapDemandIsCurrent(ticket),
              var session = codemapSessionsByRootEpoch[ticket.rootEpoch],
              let record = session.demandsByFileID[ticket.fileID],
              codemapTicketsShareDemand(record.ticket, ticket),
              record.retainIDs.contains(ticket.retainID),
              case .unavailable(.busy) = record.result
        else {
            return codemapArtifactDemandStatus(ticket)
        }
        guard record.retainIDs.count == 1 else {
            return codemapDemandResult(record.result, for: ticket)
        }
        session.demandsByFileID.removeValue(forKey: ticket.fileID)
        let bundle = session.bundlesByRequestID.removeValue(forKey: ticket.requestID)
        codemapSessionsByRootEpoch[ticket.rootEpoch] = session
        bundle?.close()
        if let engine = session.engine {
            _ = await engine.cancel(owner: record.owner)
        }
        guard !Task.isCancelled else { return .unavailable(.cancelled) }
        return await requestCodemapArtifact(forFileID: ticket.fileID, priority: priority)
    }

    func queryCodemapSelectionGraph(
        _ query: WorkspaceCodemapStoreSelectionGraphQuery
    ) async -> WorkspaceCodemapStoreSelectionGraphQueryDisposition {
        await queryCodemapSelectionGraph(query, budgetPolicy: selectionGraphQueryBudgetPolicy)
    }

    func queryCodemapStructureGraph(
        _ query: WorkspaceCodemapStructureTraversalQuery
    ) async -> WorkspaceCodemapStructureTraversalDisposition {
        guard !Task.isCancelled else { return .cancelled }
        guard !query.seeds.isEmpty else { return .unavailable(.emptySeeds) }

        var uniqueSeeds: [
            WorkspaceCodemapRootScopedFileSlot: WorkspaceCodemapStoreSelectionGraphSourceIdentity
        ] = [:]
        for seed in query.seeds {
            guard seed.rootEpoch == seed.ticket.rootEpoch else {
                return .unavailable(.foreignRootEpoch(seed.ticket.fileID))
            }
            let slot = WorkspaceCodemapRootScopedFileSlot(
                rootEpoch: seed.rootEpoch,
                fileID: seed.ticket.fileID
            )
            if let existing = uniqueSeeds[slot] {
                guard existing == seed else {
                    return .unavailable(.duplicateSeedConflict(seed.ticket.fileID))
                }
            } else {
                uniqueSeeds[slot] = seed
            }
        }

        let orderedSeeds = uniqueSeeds.values.sorted(by: codemapGraphSourcePrecedes)
        let partitions = Dictionary(grouping: orderedSeeds, by: \.rootEpoch)
        let rootEpochs = partitions.keys.sorted(by: codemapRootEpochPrecedes)
        let rootLimit = selectionGraphQueryBudgetPolicy.maximumRootCount
        guard rootEpochs.count <= rootLimit else {
            return .budget(nil, .rootLimit(attempted: rootEpochs.count, limit: rootLimit))
        }

        var captures: [CodemapGraphQueryCapture] = []
        for rootEpoch in rootEpochs {
            guard let state = rootStatesByID[rootEpoch.rootID],
                  state.lifetimeID == rootEpoch.rootLifetimeID,
                  let session = codemapSessionsByRootEpoch[rootEpoch]
            else { return .stale(.rootEpoch(rootEpoch)) }
            let seeds = partitions[rootEpoch] ?? []
            guard codemapAuthorityIsCurrent(session.authority) else {
                return .stale(.rootEpoch(rootEpoch))
            }
            for seed in seeds {
                let ticket = seed.ticket
                guard codemapDemandIsCurrent(ticket),
                      let record = session.demandsByFileID[ticket.fileID],
                      codemapTicketsShareDemand(record.ticket, ticket)
                else { return .stale(.seed(ticket)) }
                guard case let .ready(ready) = record.result,
                      codemapTicketsShareDemand(ready.ticket, ticket)
                else { return .unavailable(.seedNotReady(ticket.fileID)) }
            }
            guard let graphState = session.selectionGraph,
                  let desiredKey = graphState.desiredKey
            else { return .unavailable(.graphNotBuilt(rootEpoch)) }
            captures.append(CodemapGraphQueryCapture(
                authority: session.authority,
                graphStateID: graphState.id,
                graph: graphState.graph,
                desiredKey: desiredKey,
                workerWasActive: graphState.workerID != nil,
                sources: seeds
            ))
        }

        var rootReceipts: [WorkspaceCodemapStructureTraversalRootReceipt] = []
        var nodes: [WorkspaceCodemapStructureTraversalNode] = []
        var partialReasons = Set<WorkspaceCodemapStructureTraversalPartialReason>()
        var referenceFailures: [WorkspaceCodemapSelectionGraphRuntimeReferenceFailureRecord] = []
        var examinedEdgeCount = 0
        var materializedByteCount = 0

        func aggregateResult() -> WorkspaceCodemapStructureTraversalResult {
            WorkspaceCodemapStructureTraversalResult(
                nodes: nodes,
                examinedEdgeCount: examinedEdgeCount,
                partialReasons: partialReasons,
                referenceFailures: referenceFailures,
                publicationReceipt: WorkspaceCodemapStructureTraversalPublicationReceipt(
                    query: query,
                    roots: rootReceipts
                )
            )
        }

        for capture in captures {
            guard !Task.isCancelled else { return .cancelled }
            guard codemapGraphQueryCaptureIsCurrent(capture) else {
                return .stale(.graph(capture.authority.rootEpoch))
            }
            let remainingNodes = query.limits.maximumNodeCount - nodes.count
            guard remainingNodes > 0 else {
                return .budget(
                    aggregateResult(),
                    .nodeLimit(attempted: nodes.count + 1, limit: query.limits.maximumNodeCount)
                )
            }
            let remainingEdges = query.limits.maximumEdgeCount - examinedEdgeCount
            let remainingBytes = query.limits.maximumByteCount - materializedByteCount
            guard remainingEdges >= 0, remainingBytes > 0 else {
                return .budget(
                    aggregateResult(),
                    remainingEdges < 0
                        ? .edgeLimit(attempted: examinedEdgeCount, limit: query.limits.maximumEdgeCount)
                        : .byteLimit(attempted: materializedByteCount, limit: query.limits.maximumByteCount)
                )
            }
            let runtimeSeeds = capture.sources.map {
                WorkspaceCodemapSelectionGraphRuntimeQuerySource(
                    fileID: $0.ticket.fileID,
                    requestGeneration: $0.ticket.requestGeneration
                )
            }
            let disposition = await capture.graph.queryStructure(
                WorkspaceCodemapSelectionGraphRuntimeStructureQuery(
                    key: capture.desiredKey,
                    seeds: runtimeSeeds,
                    direction: query.direction,
                    limits: WorkspaceCodemapStructureTraversalLimits(
                        maximumDepth: query.limits.maximumDepth,
                        maximumNodeCount: remainingNodes,
                        maximumEdgeCount: remainingEdges,
                        maximumByteCount: remainingBytes
                    )
                )
            )
            guard !Task.isCancelled else { return .cancelled }
            guard codemapGraphQueryCaptureIsCurrent(capture) else {
                return .stale(.graph(capture.authority.rootEpoch))
            }

            let runtimeResult: WorkspaceCodemapSelectionGraphRuntimeStructureResult
            let budgetDimension: WorkspaceCodemapSelectionGraphRuntimeStructureBudgetDimension?
            switch disposition {
            case let .readyPartial(result):
                runtimeResult = result
                budgetDimension = nil
            case let .budget(result, dimension):
                runtimeResult = result
                budgetDimension = dimension
            case let .definitionUniverse(coverage):
                return .unavailable(.definitionUniverse(
                    rootEpoch: capture.authority.rootEpoch,
                    coverage: coverage
                ))
            case let .unavailable(reason):
                switch reason {
                case .rebuilding:
                    return .pending(.graphRebuilding(capture.authority.rootEpoch))
                case .actorAdmissionRejected, .processAdmissionRejected:
                    return .pending(.graphBusy(capture.authority.rootEpoch))
                case .staleCurrentness, .explicitRootUnavailable:
                    return .stale(.graph(capture.authority.rootEpoch))
                case .cancelled:
                    return .cancelled
                case .notBuilt where capture.workerWasActive:
                    return .pending(.graphRebuilding(capture.authority.rootEpoch))
                case .notBuilt:
                    return .unavailable(.graphNotBuilt(capture.authority.rootEpoch))
                case .budgetExceeded, .outputBudgetExceeded:
                    return .budget(nil, .accountingOverflow)
                case .invalidSnapshot, .invalidQuery:
                    return .unavailable(.runtime(
                        rootEpoch: capture.authority.rootEpoch,
                        reason: reason
                    ))
                }
            }

            guard runtimeResult.key == capture.desiredKey,
                  runtimeResult.publishedSummary.key == capture.desiredKey,
                  Set(runtimeResult.seeds) == Set(runtimeSeeds),
                  runtimeResult.nodes.allSatisfy({ $0.endpoint.rootEpoch == capture.authority.rootEpoch })
            else { return .unavailable(.invalidGraphResult(capture.authority.rootEpoch)) }
            guard case let .complete(proof, candidateCount, contributedCount, terminalCount) =
                runtimeResult.definitionUniverseCoverage
            else {
                return .unavailable(.definitionUniverse(
                    rootEpoch: capture.authority.rootEpoch,
                    coverage: runtimeResult.definitionUniverseCoverage
                ))
            }
            guard WorkspaceCodemapSelectionGraphRuntimeKey(generation: proof.generation) ==
                capture.desiredKey,
                candidateCount == proof.candidateCount,
                contributedCount == proof.contributedCount,
                terminalCount == proof.terminalCount,
                runtimeResult.definitionUniverseCoverage ==
                runtimeResult.publishedSummary.definitionUniverseCoverage
            else { return .unavailable(.invalidGraphResult(capture.authority.rootEpoch)) }

            rootReceipts.append(WorkspaceCodemapStructureTraversalRootReceipt(
                rootEpoch: capture.authority.rootEpoch,
                graphKey: runtimeResult.key,
                seeds: runtimeSeeds,
                nodes: runtimeResult.nodes,
                examinedEdgeCount: runtimeResult.examinedEdgeCount
            ))
            nodes.append(contentsOf: runtimeResult.nodes.map {
                WorkspaceCodemapStructureTraversalNode(
                    rootEpoch: $0.endpoint.rootEpoch,
                    fileID: $0.endpoint.fileID,
                    requestGeneration: $0.endpoint.requestGeneration,
                    depth: $0.depth,
                    reachedBy: $0.reachedBy
                )
            })
            examinedEdgeCount += runtimeResult.examinedEdgeCount
            materializedByteCount += runtimeResult.materializedByteCount
            referenceFailures.append(contentsOf: runtimeResult.referenceFailures)
            if !runtimeResult.referenceFailures.isEmpty {
                partialReasons.insert(.referenceFailuresPresent(capture.authority.rootEpoch))
            }
            if let budgetDimension {
                let reason: WorkspaceCodemapStructureTraversalBudgetReason = switch budgetDimension {
                case .nodes:
                    .nodeLimit(attempted: nodes.count + 1, limit: query.limits.maximumNodeCount)
                case .edges:
                    .edgeLimit(attempted: examinedEdgeCount + 1, limit: query.limits.maximumEdgeCount)
                case .bytes:
                    .byteLimit(attempted: materializedByteCount + 1, limit: query.limits.maximumByteCount)
                }
                return .budget(aggregateResult(), reason)
            }
        }

        nodes.sort {
            if $0.depth != $1.depth { return $0.depth < $1.depth }
            if $0.rootEpoch != $1.rootEpoch {
                return codemapRootEpochPrecedes($0.rootEpoch, $1.rootEpoch)
            }
            return $0.fileID.uuidString < $1.fileID.uuidString
        }
        return .readyPartial(aggregateResult())
    }

    private func queryCodemapSelectionGraph(
        _ query: WorkspaceCodemapStoreSelectionGraphQuery,
        budgetPolicy: WorkspaceCodemapStoreSelectionGraphQueryBudgetPolicy
    ) async -> WorkspaceCodemapStoreSelectionGraphQueryDisposition {
        guard !query.selectedSources.isEmpty else {
            return .unavailable(.emptySources)
        }
        let sourceLimit = budgetPolicy.maximumRawSourceCount
        guard query.selectedSources.count <= sourceLimit else {
            return .budget(.sourceLimit(
                attempted: query.selectedSources.count,
                limit: sourceLimit
            ))
        }

        var uniqueSources: [
            WorkspaceCodemapRootScopedFileSlot: WorkspaceCodemapStoreSelectionGraphSourceIdentity
        ] = [:]
        for source in query.selectedSources {
            let ticket = source.ticket
            guard source.rootEpoch == ticket.rootEpoch else {
                return .unavailable(.foreignRootEpoch(ticket.fileID))
            }
            let slot = WorkspaceCodemapRootScopedFileSlot(
                rootEpoch: source.rootEpoch,
                fileID: ticket.fileID
            )
            if let existing = uniqueSources[slot] {
                guard existing == source else {
                    return .unavailable(.duplicateSourceConflict(ticket.fileID))
                }
            } else {
                guard uniqueSources.count < budgetPolicy.maximumUniqueSourceCount else {
                    guard let attempted = addingAutomaticSelectionCount(uniqueSources.count, 1) else {
                        return .budget(.accountingOverflow)
                    }
                    return .budget(.uniqueSourceLimit(
                        attempted: attempted,
                        limit: budgetPolicy.maximumUniqueSourceCount
                    ))
                }
                uniqueSources[slot] = source
            }
        }

        let orderedSources = uniqueSources.values.sorted {
            codemapGraphSourcePrecedes($0, $1)
        }
        let partitions = Dictionary(grouping: orderedSources) { $0.rootEpoch }
        let orderedRootEpochs = partitions.keys.sorted(by: codemapRootEpochPrecedes)
        let rootLimit = budgetPolicy.maximumRootCount
        guard orderedRootEpochs.count <= rootLimit else {
            return .budget(.rootLimit(
                attempted: orderedRootEpochs.count,
                limit: rootLimit
            ))
        }
        var captures: [CodemapGraphQueryCapture] = []
        captures.reserveCapacity(orderedRootEpochs.count)

        for rootEpoch in orderedRootEpochs {
            guard let state = rootStatesByID[rootEpoch.rootID],
                  state.lifetimeID == rootEpoch.rootLifetimeID
            else {
                return .stale(.currentness(rootEpoch))
            }
            let sources = partitions[rootEpoch] ?? []
            guard let session = codemapSessionsByRootEpoch[rootEpoch] else {
                if let authorityGeneration = codemapAuthorityGenerationsByRootEpoch[rootEpoch],
                   sources.contains(where: {
                       $0.ticket.catalogGeneration != authorityGeneration ||
                           $0.ticket.ingressGeneration != authorityGeneration
                   })
                {
                    return .stale(.currentness(rootEpoch))
                }
                return .unavailable(.notActivated(rootEpoch))
            }
            guard sources.allSatisfy({ source in
                let ticket = source.ticket
                guard let record = session.demandsByFileID[ticket.fileID] else { return false }
                return ticket.catalogGeneration == session.authority.catalogGeneration &&
                    ticket.ingressGeneration == session.authority.ingressGeneration &&
                    ticket.pathGeneration == (
                        session.pathGenerationsByRelativePath[record.identity.standardizedRelativePath]
                            ?? session.authority.ingressGeneration
                    )
            }), codemapAuthorityIsCurrent(session.authority) else {
                return .stale(.currentness(rootEpoch))
            }
            for source in sources {
                let ticket = source.ticket
                guard codemapDemandIsCurrent(ticket),
                      let record = session.demandsByFileID[ticket.fileID],
                      codemapTicketsShareDemand(record.ticket, ticket)
                else {
                    return .stale(.currentness(rootEpoch))
                }
                guard case let .ready(ready) = record.result,
                      codemapTicketsShareDemand(ready.ticket, ticket),
                      ready.snapshot.rootEpoch == rootEpoch,
                      ready.snapshot.fileID == ticket.fileID,
                      ready.snapshot.requestGeneration == ticket.requestGeneration
                else {
                    return .unavailable(.sourceNotReady(ticket.fileID))
                }
            }
            guard let graphState = session.selectionGraph,
                  let desiredKey = graphState.desiredKey,
                  graphState.publishedSummary?.key == desiredKey
            else {
                return .unavailable(.notActivated(rootEpoch))
            }
            captures.append(CodemapGraphQueryCapture(
                authority: session.authority,
                graphStateID: graphState.id,
                graph: graphState.graph,
                desiredKey: desiredKey,
                workerWasActive: graphState.workerID != nil,
                sources: sources
            ))
        }

        var rootResults: [WorkspaceCodemapStoreSelectionGraphRootResult] = []
        rootResults.reserveCapacity(captures.count)
        var aggregateTargetCount = 0
        var aggregateResolutionCount = 0
        var aggregateReferenceFailureCount = 0
        var aggregateByteCount = 0

        for capture in captures {
            guard codemapGraphQueryCaptureIsCurrent(capture) else {
                return .stale(.currentness(capture.authority.rootEpoch))
            }
            let runtimeSources = capture.sources.map {
                WorkspaceCodemapSelectionGraphRuntimeQuerySource(
                    fileID: $0.ticket.fileID,
                    requestGeneration: $0.ticket.requestGeneration
                )
            }
            let runtimeQuery = WorkspaceCodemapSelectionGraphRuntimeQuery(
                key: capture.desiredKey,
                selectedSources: runtimeSources,
                outputBudget: .init(
                    maximumResolvedTargetCount: budgetPolicy.maximumTargetCount - aggregateTargetCount,
                    maximumResolutionCount: budgetPolicy.maximumResolutionCount - aggregateResolutionCount,
                    maximumReferenceFailureCount: budgetPolicy.maximumReferenceFailureCount - aggregateReferenceFailureCount,
                    maximumByteCount: budgetPolicy.maximumByteCount - aggregateByteCount
                )
            )
            let runtimeDisposition: WorkspaceCodemapSelectionGraphRuntimeQueryDisposition
            #if DEBUG
                if let override = codemapSelectionGraphRuntimeQueryOverrideForTesting,
                   let overridden = await override(capture.authority.rootEpoch, runtimeQuery)
                {
                    runtimeDisposition = overridden
                } else {
                    runtimeDisposition = await capture.graph.query(runtimeQuery)
                }
            #else
                runtimeDisposition = await capture.graph.query(runtimeQuery)
            #endif
            guard codemapGraphQueryCaptureIsCurrent(capture) else {
                return .stale(.currentness(capture.authority.rootEpoch))
            }

            switch runtimeDisposition {
            case let .readyPartial(result):
                guard codemapGraphResultIsValid(
                    result,
                    capture: capture,
                    expectedSources: runtimeSources
                ), case .complete = result.definitionUniverseCoverage,
                result.definitionUniverseCoverage ==
                result.publishedSummary.definitionUniverseCoverage
                else {
                    return .unavailable(.invalidGraphResult(capture.authority.rootEpoch))
                }
                var partialReasons = Set<WorkspaceCodemapStoreSelectionGraphPartialReason>()
                if result.sourceCoverage.count != runtimeSources.count ||
                    result.sourceCoverage.contains(where: { $0.state != .covered })
                {
                    partialReasons.insert(.sourceCoverageIncomplete)
                }
                if !result.referenceFailures.isEmpty {
                    partialReasons.insert(.referenceFailuresPresent)
                }

                guard let nextTargetCount = addingAutomaticSelectionCount(
                    aggregateTargetCount,
                    result.targets.count
                ), let nextResolutionCount = addingAutomaticSelectionCount(
                    aggregateResolutionCount,
                    result.resolutions.count
                ), let nextReferenceFailureCount = addingAutomaticSelectionCount(
                    aggregateReferenceFailureCount,
                    result.referenceFailures.count
                ), let nextByteCount = addingAutomaticSelectionCount(
                    aggregateByteCount,
                    result.materializedByteCount
                ) else {
                    return .budget(.accountingOverflow)
                }
                guard nextTargetCount <= budgetPolicy.maximumTargetCount else {
                    return .budget(.targetLimit(
                        attempted: nextTargetCount,
                        limit: budgetPolicy.maximumTargetCount
                    ))
                }
                guard nextResolutionCount <= budgetPolicy.maximumResolutionCount else {
                    return .budget(.resolutionLimit(
                        attempted: nextResolutionCount,
                        limit: budgetPolicy.maximumResolutionCount
                    ))
                }
                guard nextReferenceFailureCount <= budgetPolicy.maximumReferenceFailureCount else {
                    return .budget(.referenceFailureLimit(
                        attempted: nextReferenceFailureCount,
                        limit: budgetPolicy.maximumReferenceFailureCount
                    ))
                }
                guard nextByteCount <= budgetPolicy.maximumByteCount else {
                    return .budget(.byteLimit(
                        attempted: nextByteCount,
                        limit: budgetPolicy.maximumByteCount
                    ))
                }
                aggregateTargetCount = nextTargetCount
                aggregateResolutionCount = nextResolutionCount
                aggregateReferenceFailureCount = nextReferenceFailureCount
                aggregateByteCount = nextByteCount

                rootResults.append(WorkspaceCodemapStoreSelectionGraphRootResult(
                    rootEpoch: capture.authority.rootEpoch,
                    result: result,
                    partialReasons: partialReasons
                ))
            case let .definitionUniverse(coverage):
                switch coverage {
                case let .incomplete(progress, remainingCount, retry):
                    return .incomplete(.definitionUniverse(
                        rootEpoch: capture.authority.rootEpoch,
                        progress: progress,
                        remainingCount: remainingCount,
                        retry: retry
                    ))
                case let .busy(progress, retryAfterMilliseconds):
                    return .busy(.definitionUniverse(
                        rootEpoch: capture.authority.rootEpoch,
                        progress: progress,
                        retryAfterMilliseconds: retryAfterMilliseconds
                    ))
                case let .budget(dimension, attempted, limit):
                    return .budget(.definitionUniverse(
                        rootEpoch: capture.authority.rootEpoch,
                        dimension: dimension,
                        attempted: attempted,
                        limit: limit
                    ))
                case let .unavailable(reason):
                    return .unavailable(.definitionUniverse(
                        rootEpoch: capture.authority.rootEpoch,
                        reason: reason
                    ))
                case .complete:
                    return .unavailable(.invalidGraphResult(capture.authority.rootEpoch))
                }
            case let .unavailable(reason):
                switch reason {
                case .rebuilding:
                    return .busy(.runtime(
                        rootEpoch: capture.authority.rootEpoch,
                        reason: reason
                    ))
                case .notBuilt where capture.workerWasActive:
                    return .busy(.runtime(
                        rootEpoch: capture.authority.rootEpoch,
                        reason: .rebuilding
                    ))
                case .actorAdmissionRejected, .processAdmissionRejected:
                    return .busy(.runtime(
                        rootEpoch: capture.authority.rootEpoch,
                        reason: reason
                    ))
                case .budgetExceeded:
                    return .budget(.runtime(
                        rootEpoch: capture.authority.rootEpoch,
                        reason: reason
                    ))
                case let .outputBudgetExceeded(dimension):
                    let attempted: Int?
                    switch dimension {
                    case .resolvedTargets:
                        attempted = addingAutomaticSelectionCount(budgetPolicy.maximumTargetCount, 1)
                        guard let attempted else { return .budget(.accountingOverflow) }
                        return .budget(.targetLimit(
                            attempted: attempted,
                            limit: budgetPolicy.maximumTargetCount
                        ))
                    case .resolutions:
                        attempted = addingAutomaticSelectionCount(budgetPolicy.maximumResolutionCount, 1)
                        guard let attempted else { return .budget(.accountingOverflow) }
                        return .budget(.resolutionLimit(
                            attempted: attempted,
                            limit: budgetPolicy.maximumResolutionCount
                        ))
                    case .referenceFailures:
                        attempted = addingAutomaticSelectionCount(budgetPolicy.maximumReferenceFailureCount, 1)
                        guard let attempted else { return .budget(.accountingOverflow) }
                        return .budget(.referenceFailureLimit(
                            attempted: attempted,
                            limit: budgetPolicy.maximumReferenceFailureCount
                        ))
                    case .bytes:
                        attempted = addingAutomaticSelectionCount(budgetPolicy.maximumByteCount, 1)
                        guard let attempted else { return .budget(.accountingOverflow) }
                        return .budget(.byteLimit(
                            attempted: attempted,
                            limit: budgetPolicy.maximumByteCount
                        ))
                    }
                case .staleCurrentness, .explicitRootUnavailable:
                    return .stale(.runtime(
                        rootEpoch: capture.authority.rootEpoch,
                        reason: reason
                    ))
                case .notBuilt, .cancelled, .invalidSnapshot, .invalidQuery:
                    return .unavailable(.runtime(
                        rootEpoch: capture.authority.rootEpoch,
                        reason: reason
                    ))
                }
            }
        }

        for capture in captures where !codemapGraphQueryCaptureIsCurrent(capture) {
            return .stale(.currentness(capture.authority.rootEpoch))
        }
        return .readyPartial(WorkspaceCodemapStoreSelectionGraphQueryResult(
            roots: rootResults
        ))
    }

    private func codemapGraphQueryCaptureIsCurrent(
        _ capture: CodemapGraphQueryCapture
    ) -> Bool {
        guard codemapAuthorityIsCurrent(capture.authority),
              let session = codemapSessionsByRootEpoch[capture.authority.rootEpoch],
              let graphState = session.selectionGraph,
              graphState.id == capture.graphStateID,
              graphState.graph === capture.graph,
              graphState.desiredKey == capture.desiredKey
        else { return false }

        for source in capture.sources {
            let ticket = source.ticket
            guard codemapDemandIsCurrent(ticket),
                  let record = session.demandsByFileID[ticket.fileID],
                  codemapTicketsShareDemand(record.ticket, ticket),
                  case let .ready(ready) = record.result,
                  codemapTicketsShareDemand(ready.ticket, ticket),
                  ready.snapshot.requestGeneration == ticket.requestGeneration
            else { return false }
        }
        return true
    }

    private func codemapGraphResultIsValid(
        _ result: WorkspaceCodemapSelectionGraphRuntimeQueryResult,
        capture: CodemapGraphQueryCapture,
        expectedSources: [WorkspaceCodemapSelectionGraphRuntimeQuerySource]
    ) -> Bool {
        let rootEpoch = capture.authority.rootEpoch
        let expectedSourceSet = Set(expectedSources)
        guard result.key == capture.desiredKey,
              result.key.rootEpoch == rootEpoch,
              result.publishedSummary.key == capture.desiredKey,
              Set(result.selectedSources) == expectedSourceSet,
              result.sourceCoverage.allSatisfy({
                  expectedSourceSet.contains($0.source)
              }),
              result.targets.allSatisfy({ $0.rootEpoch == rootEpoch }),
              result.resolutions.allSatisfy({
                  $0.source.rootEpoch == rootEpoch && $0.target.rootEpoch == rootEpoch
              }),
              result.referenceFailures.allSatisfy({
                  $0.source.rootEpoch == rootEpoch
              })
        else { return false }
        return true
    }

    private func codemapGraphSourcePrecedes(
        _ lhs: WorkspaceCodemapStoreSelectionGraphSourceIdentity,
        _ rhs: WorkspaceCodemapStoreSelectionGraphSourceIdentity
    ) -> Bool {
        if lhs.rootEpoch != rhs.rootEpoch {
            return codemapRootEpochPrecedes(lhs.rootEpoch, rhs.rootEpoch)
        }
        if lhs.ticket.fileID != rhs.ticket.fileID {
            return lhs.ticket.fileID.uuidString < rhs.ticket.fileID.uuidString
        }
        return lhs.ticket.requestGeneration < rhs.ticket.requestGeneration
    }

    private func codemapRootEpochPrecedes(
        _ lhs: WorkspaceCodemapRootEpoch,
        _ rhs: WorkspaceCodemapRootEpoch
    ) -> Bool {
        if lhs.rootID != rhs.rootID {
            return lhs.rootID.uuidString < rhs.rootID.uuidString
        }
        return lhs.rootLifetimeID.uuidString < rhs.rootLifetimeID.uuidString
    }

    private func codemapAutomaticSelectionSourcePrecedes(
        _ lhs: WorkspaceCodemapAutomaticSelectionSourceIdentity,
        _ rhs: WorkspaceCodemapAutomaticSelectionSourceIdentity
    ) -> Bool {
        if lhs.rootEpoch != rhs.rootEpoch {
            return codemapRootEpochPrecedes(lhs.rootEpoch, rhs.rootEpoch)
        }
        if lhs.fileID != rhs.fileID {
            return lhs.fileID.uuidString < rhs.fileID.uuidString
        }
        return lhs.catalogGeneration < rhs.catalogGeneration
    }

    func freezeCodemapPresentation(
        _ requests: [WorkspaceCodemapPresentationRequest]
    ) -> WorkspaceCodemapPresentationFreezeDisposition {
        #if DEBUG
            codemapPresentationFreezeRequestCountForTesting += 1
        #endif
        guard !requests.isEmpty else {
            return .unavailable(.emptyRequest)
        }
        let entryLimit = Self.maximumCodemapPresentationRequestsPerBundle
        guard requests.count <= entryLimit else {
            return .unavailable(.entryLimitExceeded(limit: entryLimit))
        }

        let rootEpoch = requests[0].ticket.rootEpoch
        guard requests.allSatisfy({ $0.ticket.rootEpoch == rootEpoch }) else {
            return .unavailable(.mixedRootEpoch)
        }

        var fileIDs = Set<UUID>()
        for request in requests where !fileIDs.insert(request.ticket.fileID).inserted {
            return .unavailable(.duplicateFileID(request.ticket.fileID))
        }

        guard let originalSession = codemapSessionsByRootEpoch[rootEpoch] else {
            return .unavailable(.staleCurrentness)
        }
        let retainedLimit = Self.maximumRetainedCodemapPresentationRecordsPerRoot
        guard originalSession.presentationRecordsByID.count < retainedLimit else {
            return .unavailable(.retainedBundleLimitExceeded(limit: retainedLimit))
        }

        var pairs: [(
            entry: WorkspaceCodemapFrozenPresentationEntry,
            handle: WorkspaceCodemapLiveFrozenArtifactHandle
        )] = []
        pairs.reserveCapacity(requests.count)

        for request in requests {
            let ticket = request.ticket
            guard codemapDemandIsCurrent(ticket),
                  let demandRecord = codemapSessionsByRootEpoch[rootEpoch]?
                  .demandsByFileID[ticket.fileID],
                  codemapTicketsShareDemand(demandRecord.ticket, ticket)
            else {
                return .unavailable(.staleCurrentness)
            }

            let ready: WorkspaceCodemapArtifactDemandReady
            switch demandRecord.result {
            case let .pending(pendingTicket):
                guard pendingTicket == ticket else {
                    return .unavailable(.staleCurrentness)
                }
                return .unavailable(.pending(ticket))
            case let .unavailable(reason):
                return .unavailable(.demandUnavailable(ticket, reason))
            case let .ready(currentReady):
                ready = currentReady
            }

            guard codemapTicketsShareDemand(ready.ticket, ticket),
                  ready.identity == demandRecord.identity,
                  ready.identity.rootID == ticket.rootEpoch.rootID,
                  ready.identity.rootLifetimeID == ticket.rootEpoch.rootLifetimeID,
                  ready.identity.fileID == ticket.fileID,
                  ready.snapshot.rootEpoch == ticket.rootEpoch,
                  ready.snapshot.fileID == ticket.fileID,
                  ready.snapshot.requestGeneration == ticket.requestGeneration
            else {
                return .unavailable(.staleCurrentness)
            }
            guard request.logicalPath.standardizedRelativePath ==
                ready.identity.standardizedRelativePath,
                request.logicalPath.standardizedRelativePath ==
                ready.snapshot.standardizedRelativePath
            else {
                return .unavailable(.logicalPathMismatch(ticket.fileID))
            }

            let artifactKey: CodeMapArtifactKey
            let outcome: WorkspaceCodemapLiveArtifactOutcome
            do {
                artifactKey = try ready.handle.artifactKey()
                outcome = try ready.handle.outcome()
            } catch {
                return .unavailable(.handleRevoked(ticket.fileID))
            }
            guard artifactKey == ready.snapshot.artifactKey,
                  outcome == ready.snapshot.outcome
            else {
                return .unavailable(.staleCurrentness)
            }

            pairs.append((
                entry: WorkspaceCodemapFrozenPresentationEntry(
                    ticket: ticket,
                    logicalPath: request.logicalPath,
                    artifactKey: artifactKey,
                    outcome: outcome
                ),
                handle: ready.handle
            ))
        }

        pairs.sort { lhs, rhs in
            let lhsPath = lhs.entry.logicalPath.displayPath
            let rhsPath = rhs.entry.logicalPath.displayPath
            if lhsPath != rhsPath {
                return lhsPath < rhsPath
            }
            return lhs.entry.ticket.fileID.uuidString < rhs.entry.ticket.fileID.uuidString
        }

        for pair in pairs {
            let entry = pair.entry
            guard codemapDemandIsCurrent(entry.ticket),
                  let demandRecord = codemapSessionsByRootEpoch[rootEpoch]?
                  .demandsByFileID[entry.ticket.fileID],
                  case let .ready(ready) = demandRecord.result,
                  codemapPresentationReadyMatches(
                      ready,
                      demandRecord: demandRecord,
                      entry: entry
                  )
            else {
                return .unavailable(.staleCurrentness)
            }
            do {
                guard try pair.handle.artifactKey() == entry.artifactKey,
                      try pair.handle.outcome() == entry.outcome
                else {
                    return .unavailable(.staleCurrentness)
                }
            } catch {
                return .unavailable(.handleRevoked(entry.ticket.fileID))
            }
        }

        guard var currentSession = codemapSessionsByRootEpoch[rootEpoch],
              currentSession.authority == originalSession.authority,
              currentSession.presentationRecordsByID.count < retainedLimit
        else {
            return .unavailable(.staleCurrentness)
        }

        let id = WorkspaceCodemapFrozenPresentationBundleID()
        let entries = pairs.map(\.entry)
        let handles = pairs.map(\.handle)
        var callerHandles: [WorkspaceCodemapLiveFrozenArtifactHandle] = []
        callerHandles.reserveCapacity(handles.count)
        for (index, handle) in handles.enumerated() {
            do {
                try callerHandles.append(handle.retainingLease())
            } catch {
                return .unavailable(.handleRevoked(entries[index].ticket.fileID))
            }
        }
        let record = CodemapPresentationRecord(
            id: id,
            rootEpoch: rootEpoch,
            entries: entries,
            handles: handles,
            requestIDs: Set(entries.map(\.ticket.requestID))
        )
        let bundle = WorkspaceCodemapFrozenPresentationBundle(
            id: id,
            rootEpoch: rootEpoch,
            entries: entries,
            handles: callerHandles
        )
        currentSession.presentationRecordsByID[id] = record
        codemapSessionsByRootEpoch[rootEpoch] = currentSession
        return .ready(bundle)
    }

    func renderCodemapPresentation(
        _ bundle: WorkspaceCodemapFrozenPresentationBundle
    ) -> WorkspaceCodemapPresentationRenderDisposition {
        guard let session = codemapSessionsByRootEpoch[bundle.rootEpoch],
              let record = session.presentationRecordsByID[bundle.id]
        else {
            return .unavailable(.bundleNotRetained)
        }
        guard record.id == bundle.id,
              record.rootEpoch == bundle.rootEpoch,
              record.entries == bundle.entries,
              record.entries.count == record.handles.count
        else {
            return .unavailable(.bundleMetadataMismatch)
        }

        var renderedEntries: [WorkspaceCodemapRenderedPresentationEntry] = []
        renderedEntries.reserveCapacity(record.entries.count)

        for (entry, handle) in zip(record.entries, record.handles) {
            guard codemapDemandIsCurrent(entry.ticket),
                  let demandRecord = codemapSessionsByRootEpoch[record.rootEpoch]?
                  .demandsByFileID[entry.ticket.fileID],
                  case let .ready(ready) = demandRecord.result,
                  codemapPresentationReadyMatches(
                      ready,
                      demandRecord: demandRecord,
                      entry: entry
                  )
            else {
                return .unavailable(.staleCurrentness(entry.ticket))
            }

            do {
                guard try handle.artifactKey() == entry.artifactKey,
                      try handle.outcome() == entry.outcome
                else {
                    return .unavailable(.staleCurrentness(entry.ticket))
                }
                guard let rendered = try handle.renderedCodemap(
                    displayPath: entry.logicalPath.displayPath
                ) else {
                    return .unavailable(.noRenderableCodemap(entry.ticket.fileID))
                }
                renderedEntries.append(WorkspaceCodemapRenderedPresentationEntry(
                    ticket: entry.ticket,
                    logicalPath: entry.logicalPath,
                    artifactKey: entry.artifactKey,
                    outcome: entry.outcome,
                    text: rendered.text,
                    tokenCount: rendered.tokenCount
                ))
            } catch {
                return .unavailable(.handleRevoked(entry.ticket.fileID))
            }
        }

        for (entry, handle) in zip(record.entries, record.handles) {
            guard codemapDemandIsCurrent(entry.ticket) else {
                return .unavailable(.staleCurrentness(entry.ticket))
            }
            do {
                guard try handle.artifactKey() == entry.artifactKey,
                      try handle.outcome() == entry.outcome
                else {
                    return .unavailable(.staleCurrentness(entry.ticket))
                }
            } catch {
                return .unavailable(.handleRevoked(entry.ticket.fileID))
            }
        }

        return .ready(renderedEntries)
    }

    func revalidateCodemapOperationPresentationForPublication(
        _ receipt: WorkspaceCodemapOperationPresentationPublicationReceipt,
        rootScope: WorkspaceLookupRootScope
    ) -> WorkspaceCodemapOperationPublicationDisposition {
        guard receipt.rootScope == rootScope else { return .stale(.rootScope) }
        let allowedRootIDs = Set(rootsForPathLookup(scope: rootScope).map(\.id))

        if receipt.completeRootSet {
            guard allowedRootIDs == Set(receipt.completeRootCatalogs.map(\.rootEpoch.rootID)) else {
                return .stale(.rootScope)
            }
            for catalog in receipt.completeRootCatalogs {
                guard let state = rootStatesByID[catalog.rootEpoch.rootID],
                      state.lifetimeID == catalog.rootEpoch.rootLifetimeID
                else { return .stale(.rootEpoch(catalog.rootEpoch)) }
                guard catalogGenerationsByRootID[catalog.rootEpoch.rootID] == catalog.catalogGeneration else {
                    return .stale(.rootEpoch(catalog.rootEpoch))
                }
                let currentSupportedFileIDs = state.fileIDsByRelativePath.values.filter { fileID in
                    guard isDiscoverableFileID(fileID), let file = filesByID[fileID] else { return false }
                    return SyntaxManager.supportsCodeMap(
                        fileExtension: (file.name as NSString).pathExtension
                    )
                }.sorted { $0.uuidString < $1.uuidString }
                guard currentSupportedFileIDs == catalog.supportedFileIDs else {
                    return .stale(.rootEpoch(catalog.rootEpoch))
                }
            }
        }

        for candidate in receipt.candidates {
            let rootEpoch = candidate.rootEpoch
            guard allowedRootIDs.contains(rootEpoch.rootID),
                  let state = rootStatesByID[rootEpoch.rootID],
                  state.lifetimeID == rootEpoch.rootLifetimeID
            else { return .stale(.rootEpoch(rootEpoch)) }
            guard catalogGenerationsByRootID[rootEpoch.rootID] == candidate.catalogGeneration,
                  let file = filesByID[candidate.fileID],
                  file.rootID == rootEpoch.rootID,
                  isDiscoverableFileID(candidate.fileID),
                  state.fileIDsByRelativePath[file.standardizedRelativePath] == candidate.fileID,
                  candidate.logicalPath.rootDisplayName == (
                      receipt.logicalRootDisplayNamesByRootID[rootEpoch.rootID] ?? state.root.name
                  ),
                  candidate.logicalPath.standardizedRelativePath == file.standardizedRelativePath
            else { return .stale(.catalog(fileID: candidate.fileID)) }
        }

        for ticket in receipt.demandTickets {
            guard allowedRootIDs.contains(ticket.rootEpoch.rootID),
                  codemapDemandIsCurrent(ticket),
                  let record = codemapSessionsByRootEpoch[ticket.rootEpoch]?
                  .demandsByFileID[ticket.fileID],
                  codemapTicketsShareDemand(record.ticket, ticket),
                  record.retainIDs.contains(ticket.retainID),
                  case let .ready(ready) = record.result,
                  codemapTicketsShareDemand(ready.ticket, ticket)
            else { return .stale(.demand(ticket)) }
        }

        for bundle in receipt.bundles {
            guard let record = codemapSessionsByRootEpoch[bundle.rootEpoch]?
                .presentationRecordsByID[bundle.bundleID],
                record.id == bundle.bundleID,
                record.rootEpoch == bundle.rootEpoch,
                record.entries.count == record.handles.count
            else {
                return .stale(.bundle(
                    rootEpoch: bundle.rootEpoch,
                    bundleID: bundle.bundleID
                ))
            }
            let retainedEntriesByFileID = Dictionary(
                uniqueKeysWithValues: zip(record.entries, record.handles).map { entry, handle in
                    (entry.ticket.fileID, (entry, handle))
                }
            )
            for entry in bundle.entries {
                guard let (retainedEntry, handle) = retainedEntriesByFileID[entry.ticket.fileID],
                      retainedEntry == entry
                else {
                    return .stale(.bundle(
                        rootEpoch: bundle.rootEpoch,
                        bundleID: bundle.bundleID
                    ))
                }
                guard let demandRecord = codemapSessionsByRootEpoch[bundle.rootEpoch]?
                    .demandsByFileID[entry.ticket.fileID],
                    demandRecord.retainIDs.contains(entry.ticket.retainID),
                    case let .ready(ready) = demandRecord.result,
                    codemapPresentationReadyMatches(
                        ready,
                        demandRecord: demandRecord,
                        entry: entry
                    )
                else {
                    return .stale(.bundle(
                        rootEpoch: bundle.rootEpoch,
                        bundleID: bundle.bundleID
                    ))
                }
                do {
                    guard try handle.artifactKey() == entry.artifactKey,
                          try handle.outcome() == entry.outcome
                    else {
                        return .stale(.bundle(
                            rootEpoch: bundle.rootEpoch,
                            bundleID: bundle.bundleID
                        ))
                    }
                } catch {
                    return .stale(.bundle(
                        rootEpoch: bundle.rootEpoch,
                        bundleID: bundle.bundleID
                    ))
                }
            }
        }

        if let automaticReceipt = receipt.automaticReceipt {
            switch revalidateAutomaticCodemapSelectionForPublicationUnreleased(
                automaticReceipt,
                rootScope: rootScope
            ) {
            case .current:
                break
            case let .stale(reason):
                return .stale(.automatic(reason))
            }
        }
        return .current
    }

    func revalidateCodemapStructureForPublication(
        _ receipt: WorkspaceCodemapStructurePublicationReceipt,
        rootScope: WorkspaceLookupRootScope
    ) -> WorkspaceCodemapStructurePublicationDisposition {
        switch revalidateCodemapOperationPresentationForPublication(
            receipt.presentation,
            rootScope: rootScope
        ) {
        case .current:
            break
        case let .stale(reason):
            return .stale(.presentation(reason))
        }

        let candidateFileIDs = receipt.presentation.candidates.map(\.fileID)
        guard candidateFileIDs == receipt.outputFileIDs else { return .stale(.output) }
        guard Set(receipt.outputFileIDs).count == receipt.outputFileIDs.count else {
            return .stale(.output)
        }

        guard let traversal = receipt.traversal else { return .current }
        let allowedRootIDs = Set(rootsForPathLookup(scope: rootScope).map(\.id))
        let seedsByRoot = Dictionary(grouping: traversal.query.seeds, by: \.rootEpoch)
        guard Set(traversal.roots.map(\.rootEpoch)) == Set(seedsByRoot.keys) else {
            guard let rootEpoch = traversal.roots.first?.rootEpoch
                ?? traversal.query.seeds.first?.rootEpoch
            else { return .stale(.output) }
            return .stale(.traversal(.graph(rootEpoch)))
        }
        for rootReceipt in traversal.roots {
            let rootEpoch = rootReceipt.rootEpoch
            guard allowedRootIDs.contains(rootEpoch.rootID),
                  let state = rootStatesByID[rootEpoch.rootID],
                  state.lifetimeID == rootEpoch.rootLifetimeID,
                  let session = codemapSessionsByRootEpoch[rootEpoch],
                  let graphState = session.selectionGraph,
                  graphState.desiredKey == rootReceipt.graphKey,
                  graphState.publishedSummary?.key == rootReceipt.graphKey
            else { return .stale(.traversal(.graph(rootEpoch))) }

            let expectedSeeds = (seedsByRoot[rootEpoch] ?? []).map {
                WorkspaceCodemapSelectionGraphRuntimeQuerySource(
                    fileID: $0.ticket.fileID,
                    requestGeneration: $0.ticket.requestGeneration
                )
            }
            guard Set(expectedSeeds) == Set(rootReceipt.seeds) else {
                return .stale(.traversal(.graph(rootEpoch)))
            }
            for seed in seedsByRoot[rootEpoch] ?? [] {
                let ticket = seed.ticket
                guard codemapDemandIsCurrent(ticket),
                      let record = session.demandsByFileID[ticket.fileID],
                      record.retainIDs.contains(ticket.retainID),
                      codemapTicketsShareDemand(record.ticket, ticket),
                      case let .ready(ready) = record.result,
                      codemapTicketsShareDemand(ready.ticket, ticket)
                else { return .stale(.traversal(.seed(ticket))) }
            }
            for node in rootReceipt.nodes {
                guard node.endpoint.rootEpoch == rootEpoch,
                      let file = filesByID[node.endpoint.fileID],
                      file.rootID == rootEpoch.rootID,
                      state.fileIDsByRelativePath[file.standardizedRelativePath] == file.id,
                      let record = session.demandsByFileID[file.id],
                      record.ticket.requestGeneration == node.endpoint.requestGeneration,
                      case .ready = record.result
                else { return .stale(.traversal(.graph(rootEpoch))) }
            }
        }
        return .current
    }

    func releaseCodemapPresentation(
        _ bundle: WorkspaceCodemapFrozenPresentationBundle
    ) -> Bool {
        guard var session = codemapSessionsByRootEpoch[bundle.rootEpoch],
              let record = session.presentationRecordsByID[bundle.id],
              record.rootEpoch == bundle.rootEpoch,
              record.entries == bundle.entries
        else {
            return false
        }
        session.presentationRecordsByID.removeValue(forKey: bundle.id)
        codemapSessionsByRootEpoch[bundle.rootEpoch] = session
        return true
    }

    func releaseReadyCodemapArtifactDemandRetain(
        _ ticket: WorkspaceCodemapArtifactDemandTicket,
        deadline: ContinuousClock.Instant? = nil
    ) async -> Bool {
        guard codemapDemandIsCurrent(ticket),
              let record = codemapSessionsByRootEpoch[ticket.rootEpoch]?
              .demandsByFileID[ticket.fileID],
              codemapTicketsShareDemand(record.ticket, ticket),
              case .ready = record.result
        else { return false }
        return await cancelCodemapArtifactDemand(ticket, deadline: deadline)
    }

    func cancelCodemapArtifactDemand(
        _ ticket: WorkspaceCodemapArtifactDemandTicket,
        deadline: ContinuousClock.Instant? = nil
    ) async -> Bool {
        guard codemapDemandIsCurrent(ticket),
              var session = codemapSessionsByRootEpoch[ticket.rootEpoch],
              var record = session.demandsByFileID[ticket.fileID],
              codemapTicketsShareDemand(record.ticket, ticket),
              record.retainIDs.remove(ticket.retainID) != nil
        else {
            return false
        }
        if !record.retainIDs.isEmpty {
            session.demandsByFileID[ticket.fileID] = record
            codemapSessionsByRootEpoch[ticket.rootEpoch] = session
            return true
        }
        if case .unavailable(.cancelled) = record.result {
            return true
        }
        let shouldRevokeReadyArtifact = if case .ready = record.result {
            true
        } else {
            false
        }

        record.task?.cancel()
        let presentationIDs = session.presentationRecordsByID.compactMap { id, presentation in
            presentation.requestIDs.contains(ticket.requestID) ? id : nil
        }
        for id in presentationIDs {
            session.presentationRecordsByID.removeValue(forKey: id)
        }
        let retainedBundle = session.bundlesByRequestID.removeValue(forKey: ticket.requestID)
        let graphPublicationTask = session.graphPublicationFlight?.task
        graphPublicationTask?.cancel()
        session.graphPublicationFlight = nil
        let projectionRecoveryObserverTask = session.projectionRecoveryObserver?.task
        projectionRecoveryObserverTask?.cancel()
        session.projectionRecoveryObserver = nil
        if var selectionGraph = session.selectionGraph {
            selectionGraph.workerTask?.cancel()
            selectionGraph.pendingSnapshot = nil
            selectionGraph.publishedSummary = nil
            selectionGraph.lastRebuildDisposition = nil
            selectionGraph.workerID = nil
            selectionGraph.workerTask = nil
            session.selectionGraph = selectionGraph
        }
        record.result = .unavailable(.cancelled)
        record.task = nil
        session.demandsByFileID[ticket.fileID] = record
        codemapSessionsByRootEpoch[ticket.rootEpoch] = session
        retainedBundle?.close()
        let cleanupTask = Task { [weak self] in
            await self?.finishCancelledCodemapArtifactDemand(
                ticket,
                record: record,
                engine: session.engine,
                shouldRevokeReadyArtifact: shouldRevokeReadyArtifact,
                graphPublicationTask: graphPublicationTask,
                projectionRecoveryObserverTask: projectionRecoveryObserverTask
            )
            return ()
        }
        _ = await waitForCodemapSharedTask(cleanupTask, deadline: deadline)
        return true
    }

    private func finishCancelledCodemapArtifactDemand(
        _ ticket: WorkspaceCodemapArtifactDemandTicket,
        record: CodemapDemandRecord,
        engine: WorkspaceCodemapBindingEngine?,
        shouldRevokeReadyArtifact: Bool,
        graphPublicationTask: Task<Void, Never>?,
        projectionRecoveryObserverTask: Task<Void, Never>?
    ) async {
        if let engine {
            await codemapCancellationCleanupHook(ticket)
            _ = await engine.cancel(owner: record.owner)
            if shouldRevokeReadyArtifact {
                _ = await engine.revokeReadyArtifact(
                    rootEpoch: ticket.rootEpoch,
                    fileID: ticket.fileID,
                    requestGeneration: ticket.requestGeneration
                )
            }
        }
        if let graphPublicationTask {
            await graphPublicationTask.value
        }
        if let projectionRecoveryObserverTask {
            await projectionRecoveryObserverTask.value
        }
        if var currentSession = codemapSessionsByRootEpoch[ticket.rootEpoch],
           let currentRecord = currentSession.demandsByFileID[ticket.fileID],
           codemapTicketsShareDemand(currentRecord.ticket, ticket),
           currentRecord.retainIDs.isEmpty,
           case .unavailable(.cancelled) = currentRecord.result
        {
            currentSession.demandsByFileID.removeValue(forKey: ticket.fileID)
            codemapSessionsByRootEpoch[ticket.rootEpoch] = currentSession
        }
        if codemapSessionsByRootEpoch[ticket.rootEpoch]?
            .demandsByFileID.values.contains(where: {
                if case .ready = $0.result { return true }
                return false
            }) == true
        {
            signalCodemapGraphPublication(rootEpoch: ticket.rootEpoch)
        }
    }

    #if DEBUG
        struct CodemapPresentationOperationCounts: Equatable {
            let structureSeedAdmissionRequests: Int
            let selectedMetadataResolutionRequests: Int
            let presentationCandidateRequests: Int
            let artifactDemandRequests: Int
            let presentationFreezeRequests: Int
            let setupTasksCreated: Int
            let demandTasksCreated: Int
            let targetedReadyFreezes: Int
            let fullRootGraphFreezes: Int
            let graphBatchSignals: Int
            let graphBatchFlushes: Int
            let graphWorkerStarts: Int
            let projectionRecoveryObserversStarted: Int
            let projectionRecoveryObserverRearms: Int
        }

        struct CodemapGraphPublicationRecoveryStateForTesting: Equatable {
            let flightActive: Bool
            let flightFollowUpStarted: Bool
            let flightLatestSignalSerial: UInt64?
            let observerActive: Bool
            let observerLatestSignalSerial: UInt64?
        }

        func setCodemapGraphPublicationWillFlushHandlerForTesting(
            _ handler: (@Sendable (WorkspaceCodemapRootEpoch, Int) async -> Void)?
        ) {
            codemapGraphPublicationWillFlushHandlerForTesting = handler
        }

        func setCodemapProjectionRecoveryObserverWillWaitHandlerForTesting(
            _ handler: (@Sendable (WorkspaceCodemapRootEpoch) async -> Void)?
        ) {
            codemapProjectionRecoveryObserverWillWaitHandlerForTesting = handler
        }

        func revokeReadyCodemapArtifactContributionForTesting(
            _ ticket: WorkspaceCodemapArtifactDemandTicket
        ) async -> Bool {
            guard codemapDemandIsCurrent(ticket),
                  let engine = codemapSessionsByRootEpoch[ticket.rootEpoch]?.engine
            else { return false }
            let revoked = await engine.revokeReadyArtifact(
                rootEpoch: ticket.rootEpoch,
                fileID: ticket.fileID,
                requestGeneration: ticket.requestGeneration
            )
            if revoked {
                signalCodemapGraphPublication(rootEpoch: ticket.rootEpoch)
            }
            return revoked
        }

        func codemapGraphPublicationRecoveryStateForTesting(
            rootEpoch: WorkspaceCodemapRootEpoch
        ) -> CodemapGraphPublicationRecoveryStateForTesting {
            let session = codemapSessionsByRootEpoch[rootEpoch]
            return CodemapGraphPublicationRecoveryStateForTesting(
                flightActive: session?.graphPublicationFlight != nil,
                flightFollowUpStarted: session?.graphPublicationFlight?.followUpStarted ?? false,
                flightLatestSignalSerial: session?.graphPublicationFlight?.latestSignalSerial,
                observerActive: session?.projectionRecoveryObserver != nil,
                observerLatestSignalSerial: session?.projectionRecoveryObserver?.latestSignalSerial
            )
        }

        func codemapPresentationOperationCountsForTesting() -> CodemapPresentationOperationCounts {
            CodemapPresentationOperationCounts(
                structureSeedAdmissionRequests: codemapStructureSeedAdmissionRequestCountForTesting,
                selectedMetadataResolutionRequests: codeStructureSelectedMetadataResolutionRequestCountForTesting,
                presentationCandidateRequests: codemapPresentationCandidateRequestCountForTesting,
                artifactDemandRequests: codemapArtifactDemandRequestCountForTesting,
                presentationFreezeRequests: codemapPresentationFreezeRequestCountForTesting,
                setupTasksCreated: codemapSetupTaskCreationCountForTesting,
                demandTasksCreated: codemapDemandTaskCreationCountForTesting,
                targetedReadyFreezes: codemapTargetedReadyFreezeCountForTesting,
                fullRootGraphFreezes: codemapFullRootGraphFreezeCountForTesting,
                graphBatchSignals: codemapGraphBatchSignalCountForTesting,
                graphBatchFlushes: codemapGraphBatchFlushCountForTesting,
                graphWorkerStarts: codemapGraphWorkerStartCountForTesting,
                projectionRecoveryObserversStarted: codemapProjectionRecoveryObserverStartCountForTesting,
                projectionRecoveryObserverRearms: codemapProjectionRecoveryObserverRearmCountForTesting
            )
        }

        func codemapArtifactDemandRetainCountForTesting(
            _ ticket: WorkspaceCodemapArtifactDemandTicket
        ) -> Int {
            guard let record = codemapSessionsByRootEpoch[ticket.rootEpoch]?
                .demandsByFileID[ticket.fileID],
                codemapTicketsShareDemand(record.ticket, ticket)
            else { return 0 }
            return record.retainIDs.count
        }

        func codemapArtifactDemandRetainCountForTesting(
            rootEpoch: WorkspaceCodemapRootEpoch,
            fileID: UUID
        ) -> Int {
            codemapSessionsByRootEpoch[rootEpoch]?.demandsByFileID[fileID]?.retainIDs.count ?? 0
        }

        struct CodemapArtifactDemandCleanupSnapshot: Equatable {
            let demandRecordPresent: Bool
            let bundlePresent: Bool
            let ownerCount: Int
            let liveOverlayPresent: Bool
        }

        func codemapArtifactDemandCleanupSnapshotForTesting(
            _ ticket: WorkspaceCodemapArtifactDemandTicket
        ) async -> CodemapArtifactDemandCleanupSnapshot {
            let session = codemapSessionsByRootEpoch[ticket.rootEpoch]
            let demandRecordPresent = session?.demandsByFileID[ticket.fileID] != nil
            let bundlePresent = session?.bundlesByRequestID[ticket.requestID] != nil
            let engine = session?.engine
            let ownerCount = await engine?.accounting().ownerCount ?? 0
            let liveBundle = await engine?.freezeReadyArtifact(
                rootEpoch: ticket.rootEpoch,
                fileID: ticket.fileID,
                requestGeneration: ticket.requestGeneration
            )
            let liveOverlayPresent = liveBundle != nil
            liveBundle?.close()
            return CodemapArtifactDemandCleanupSnapshot(
                demandRecordPresent: demandRecordPresent,
                bundlePresent: bundlePresent,
                ownerCount: ownerCount,
                liveOverlayPresent: liveOverlayPresent
            )
        }

        func codemapPresentationRetainCountForTesting(
            rootEpoch: WorkspaceCodemapRootEpoch
        ) -> Int {
            codemapSessionsByRootEpoch[rootEpoch]?.presentationRecordsByID.count ?? 0
        }
    #endif

    private func performCodemapSetup(
        authority: CodemapRootAuthority
    ) async -> CodemapSetupDisposition {
        guard codemapAuthorityIsCurrent(authority) else {
            return .unavailable(.staleCurrentness)
        }

        let runtime: CodeMapArtifactRuntime
        do {
            runtime = try codemapRuntimeProvider()
        } catch {
            let disposition = CodemapSetupDisposition.unavailable(.runtimeFailure)
            publishCodemapSetupDisposition(disposition, authority: authority)
            return disposition
        }
        guard codemapAuthorityIsCurrent(authority), !Task.isCancelled else {
            return .unavailable(.staleCurrentness)
        }

        let endpoint = WorkspaceCodemapBindingIntegrationEndpoint(
            sourceReader: WorkspaceCodemapValidatedSourceReaderClient { [weak self] identity, fingerprint, maximumBytes, ownerID in
                guard let self else {
                    throw WorkspaceCodemapBindingIntegrationRoutingError.routeDetached(
                        WorkspaceCodemapRootEpoch(
                            rootID: identity.rootID,
                            rootLifetimeID: identity.rootLifetimeID
                        )
                    )
                }
                return try await readCodemapSource(
                    identity: identity,
                    expectedFingerprint: fingerprint,
                    maximumBytes: maximumBytes,
                    ownerID: ownerID,
                    authority: authority
                )
            },
            catalogClient: WorkspaceCodemapBindingCatalogClient { [weak self] rootEpoch, relativePath in
                guard let self else { return nil }
                return await codemapManifestCandidate(
                    rootEpoch: rootEpoch,
                    relativePath: relativePath,
                    authority: authority
                )
            } readProjectionCatalogPage: { [weak self] request in
                guard let self else { return .unavailable(.rootNotCurrent) }
                return await readCodemapProjectionCatalogPage(
                    request,
                    authority: authority
                )
            } revalidateProjectionCatalogToken: { [weak self] rootEpoch, token in
                guard let self else { return .unavailable(.rootNotCurrent) }
                return await revalidateCodemapProjectionCatalogToken(
                    rootEpoch: rootEpoch,
                    token: token,
                    authority: authority
                )
            } publishProjection: { [weak self] snapshot in
                guard let self else { return .superseded }
                return await acceptCodemapProjectionSnapshot(
                    snapshot,
                    authority: authority
                )
            } publishMarkerReadiness: { [weak self] update in
                guard let self else { return false }
                return await acceptCodemapMarkerReadinessUpdate(
                    update,
                    authority: authority
                )
            }
        )
        let registry = runtime.bindingIntegrationRegistry
        guard let routeToken = await registry.register(
            rootEpoch: authority.rootEpoch,
            endpoint: endpoint
        ) else {
            let disposition = CodemapSetupDisposition.unavailable(.routeConflict)
            publishCodemapSetupDisposition(disposition, authority: authority)
            return disposition
        }
        guard codemapAuthorityIsCurrent(authority), !Task.isCancelled else {
            _ = await registry.unregister(routeToken)
            return .unavailable(.staleCurrentness)
        }

        codemapSessionsByRootEpoch[authority.rootEpoch]?.endpoint = endpoint
        codemapSessionsByRootEpoch[authority.rootEpoch]?.routeToken = routeToken
        codemapSessionsByRootEpoch[authority.rootEpoch]?.runtime = runtime

        let engine: WorkspaceCodemapBindingEngine
        do {
            engine = try runtime.bindingEngine()
        } catch {
            _ = await registry.unregister(routeToken)
            if codemapAuthorityIsCurrent(authority) {
                codemapSessionsByRootEpoch[authority.rootEpoch]?.endpoint = nil
                codemapSessionsByRootEpoch[authority.rootEpoch]?.routeToken = nil
                codemapSessionsByRootEpoch[authority.rootEpoch]?.runtime = nil
            }
            let disposition = CodemapSetupDisposition.unavailable(.runtimeFailure)
            publishCodemapSetupDisposition(disposition, authority: authority)
            return disposition
        }
        guard codemapAuthorityIsCurrent(authority), !Task.isCancelled else {
            _ = await registry.unregister(routeToken)
            await fenceLateCodemapSetup(engine: engine, authority: authority)
            return .unavailable(.staleCurrentness)
        }
        codemapSessionsByRootEpoch[authority.rootEpoch]?.engine = engine

        let registration = WorkspaceCodemapBindingRootRegistration(
            rootID: authority.rootEpoch.rootID,
            rootLifetimeID: authority.rootEpoch.rootLifetimeID,
            loadedRootURL: URL(fileURLWithPath: authority.standardizedRootPath, isDirectory: true),
            catalogGeneration: authority.catalogGeneration,
            ingressGeneration: authority.ingressGeneration
        )
        let registrationResult = await engine.registerRoot(registration)
        guard codemapAuthorityIsCurrent(authority), !Task.isCancelled else {
            _ = await registry.unregister(routeToken)
            await fenceLateCodemapSetup(engine: engine, authority: authority)
            return .unavailable(.staleCurrentness)
        }

        let disposition: CodemapSetupDisposition = switch registrationResult {
        case .registered, .exactDuplicate:
            .ready
        case let .unavailable(state):
            switch state {
            case let .terminalUnavailable(reason):
                .unavailable(.gitTerminal(reason))
            case let .transientUnavailable(reason, _):
                .unavailable(.gitTransient(reason))
            case .unresolved, .resolving, .eligible:
                .unavailable(.registrationFailed)
            }
        case .busy:
            .unavailable(.busy(retryAfterMilliseconds: nil))
        case .failed:
            .unavailable(.registrationFailed)
        }
        publishCodemapSetupDisposition(disposition, authority: authority)
        return disposition
    }

    private func performCodemapDemand(
        ticket: WorkspaceCodemapArtifactDemandTicket,
        priority: CodeMapArtifactBuildPriority
    ) async {
        guard codemapDemandIsCurrent(ticket),
              let session = codemapSessionsByRootEpoch[ticket.rootEpoch],
              let record = session.demandsByFileID[ticket.fileID],
              codemapTicketsShareDemand(record.ticket, ticket)
        else { return }

        let setupDisposition: CodemapSetupDisposition = if let existing = session.setupDisposition {
            existing
        } else if let setupTask = session.setupTask {
            await setupTask.value
        } else {
            .unavailable(.runtimeFailure)
        }

        guard codemapDemandIsCurrent(ticket), !Task.isCancelled,
              let refreshedSession = codemapSessionsByRootEpoch[ticket.rootEpoch],
              let refreshedRecord = refreshedSession.demandsByFileID[ticket.fileID],
              refreshedRecord.ticket == ticket
        else { return }

        switch setupDisposition {
        case let .unavailable(reason):
            publishCodemapDemandResult(.unavailable(reason), ticket: ticket)
            return
        case .ready:
            break
        }
        guard let engine = refreshedSession.engine else {
            publishCodemapDemandResult(.unavailable(.runtimeFailure), ticket: ticket)
            return
        }

        let engineResult = await engine.demand(WorkspaceCodemapBindingDemand(
            owner: refreshedRecord.owner,
            identity: refreshedRecord.identity,
            requestGeneration: ticket.requestGeneration,
            catalogGeneration: ticket.catalogGeneration,
            pathGeneration: ticket.pathGeneration,
            ingressGeneration: ticket.ingressGeneration,
            priority: priority,
            language: refreshedRecord.language
        ))
        let result = await codemapDemandResultHook(ticket, engineResult)
        guard codemapDemandIsCurrent(ticket), !Task.isCancelled else { return }

        switch result {
        case let .ready(snapshot), let .alreadyReady(snapshot):
            await publishCodemapReady(
                snapshot: snapshot,
                engine: engine,
                ticket: ticket
            )
        case let .unavailable(reason):
            publishCodemapDemandResult(
                .unavailable(.demandUnavailable(reason)),
                ticket: ticket
            )
        case let .busy(retryAfterMilliseconds):
            publishCodemapDemandResult(
                .unavailable(.busy(retryAfterMilliseconds: retryAfterMilliseconds)),
                ticket: ticket
            )
        case .rejected(.staleCompletion):
            publishCodemapDemandResult(.unavailable(.staleCurrentness), ticket: ticket)
        case let .rejected(rejection):
            publishCodemapDemandResult(
                .unavailable(.rejected(rejection)),
                ticket: ticket
            )
        case .cancelled:
            publishCodemapDemandResult(.unavailable(.cancelled), ticket: ticket)
        }
    }

    private func publishCodemapReady(
        snapshot: WorkspaceCodemapLiveReadySnapshot,
        engine: WorkspaceCodemapBindingEngine,
        ticket: WorkspaceCodemapArtifactDemandTicket
    ) async {
        guard codemapDemandIsCurrent(ticket),
              let record = codemapSessionsByRootEpoch[ticket.rootEpoch]?
              .demandsByFileID[ticket.fileID],
              codemapTicketsShareDemand(record.ticket, ticket)
        else { return }

        await codemapReadyPublicationHook(ticket)
        #if DEBUG
            codemapTargetedReadyFreezeCountForTesting += 1
        #endif
        guard let bundle = await engine.freezeReadyArtifact(
            rootEpoch: ticket.rootEpoch,
            fileID: ticket.fileID,
            requestGeneration: ticket.requestGeneration
        ) else {
            publishCodemapDemandResult(.unavailable(.staleCurrentness), ticket: ticket)
            return
        }
        guard codemapDemandIsCurrent(ticket),
              bundle.rootEpoch == ticket.rootEpoch,
              bundle.catalogGeneration == ticket.catalogGeneration,
              snapshot.rootEpoch == ticket.rootEpoch,
              snapshot.fileID == ticket.fileID,
              snapshot.standardizedRelativePath == record.identity.standardizedRelativePath,
              snapshot.requestGeneration == ticket.requestGeneration,
              let frozenSnapshot = try? bundle.snapshot().first(where: {
                  $0.fileID == ticket.fileID &&
                      $0.standardizedRelativePath == record.identity.standardizedRelativePath &&
                      $0.requestGeneration == ticket.requestGeneration &&
                      $0.artifactKey == snapshot.artifactKey
              }),
              frozenSnapshot == snapshot,
              let handle = try? bundle.handle(for: ticket.fileID),
              (try? handle.artifactKey()) == snapshot.artifactKey
        else {
            bundle.close()
            if codemapDemandIsCurrent(ticket) {
                publishCodemapDemandResult(.unavailable(.staleCurrentness), ticket: ticket)
            }
            return
        }

        guard var session = codemapSessionsByRootEpoch[ticket.rootEpoch],
              session.demandsByFileID[ticket.fileID]?.ticket == ticket
        else {
            bundle.close()
            return
        }
        session.bundlesByRequestID[ticket.requestID] = bundle
        codemapSessionsByRootEpoch[ticket.rootEpoch] = session

        let ready = WorkspaceCodemapArtifactDemandReady(
            ticket: ticket,
            identity: record.identity,
            snapshot: snapshot,
            handle: handle
        )
        guard publishCodemapDemandResult(.ready(ready), ticket: ticket) else {
            codemapSessionsByRootEpoch[ticket.rootEpoch]?
                .bundlesByRequestID.removeValue(forKey: ticket.requestID)
            bundle.close()
            return
        }
        if var currentSession = codemapSessionsByRootEpoch[ticket.rootEpoch],
           var graphState = currentSession.selectionGraph
        {
            graphState.publishedSummary = nil
            currentSession.selectionGraph = graphState
            codemapSessionsByRootEpoch[ticket.rootEpoch] = currentSession
        }
        signalCodemapGraphPublication(rootEpoch: ticket.rootEpoch)
    }

    private func fenceLateCodemapSetup(
        engine: WorkspaceCodemapBindingEngine,
        authority: CodemapRootAuthority
    ) async {
        if codemapAuthorityMatchesLoadedRoot(authority) {
            _ = await engine.invalidateRepositoryAuthority(rootEpoch: authority.rootEpoch)
        } else {
            await engine.unloadRoot(rootEpoch: authority.rootEpoch)
        }
    }

    private func publishCodemapSetupDisposition(
        _ disposition: CodemapSetupDisposition,
        authority: CodemapRootAuthority
    ) {
        guard codemapAuthorityIsCurrent(authority) else { return }
        codemapSessionsByRootEpoch[authority.rootEpoch]?.setupDisposition = disposition
        codemapSessionsByRootEpoch[authority.rootEpoch]?.setupTask = nil
    }

    @discardableResult
    private func publishCodemapDemandResult(
        _ result: WorkspaceCodemapArtifactDemandResult,
        ticket: WorkspaceCodemapArtifactDemandTicket
    ) -> Bool {
        guard codemapDemandIsCurrent(ticket),
              var session = codemapSessionsByRootEpoch[ticket.rootEpoch],
              var record = session.demandsByFileID[ticket.fileID],
              codemapTicketsShareDemand(record.ticket, ticket)
        else { return false }
        record.result = result
        record.task = nil
        session.demandsByFileID[ticket.fileID] = record
        codemapSessionsByRootEpoch[ticket.rootEpoch] = session
        return true
    }

    private func signalCodemapGraphPublication(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) {
        #if DEBUG
            codemapGraphBatchSignalCountForTesting += 1
        #endif

        let pathIsFenced = codemapPathInvalidationFlightsByRootEpoch[rootEpoch] != nil ||
            codemapPathFenceTokensByID.values.contains { $0.rootEpoch == rootEpoch }
        if pathIsFenced {
            codemapSessionsByRootEpoch[rootEpoch]?
                .graphSnapshotDirtyDuringPathInvalidation = true
            return
        }

        guard var session = codemapSessionsByRootEpoch[rootEpoch],
              codemapAuthorityIsCurrent(session.authority),
              session.engine != nil
        else { return }

        if var observer = session.projectionRecoveryObserver {
            if observer.latestSignalSerial < .max {
                observer.latestSignalSerial += 1
            }
            session.projectionRecoveryObserver = observer
            codemapSessionsByRootEpoch[rootEpoch] = session
            return
        }

        if var flight = session.graphPublicationFlight {
            if flight.latestSignalSerial < .max {
                flight.latestSignalSerial += 1
            }
            flight.replayRequired = true
            session.graphPublicationFlight = flight
            codemapSessionsByRootEpoch[rootEpoch] = session
            return
        }

        startCodemapGraphPublicationFlight(
            rootEpoch: rootEpoch,
            authority: session.authority,
            initialSignalSerial: 1
        )
    }

    private func startCodemapGraphPublicationFlight(
        rootEpoch: WorkspaceCodemapRootEpoch,
        authority: CodemapRootAuthority,
        initialSignalSerial: UInt64,
        projectionRecoveryObserverID: UUID? = nil
    ) {
        guard initialSignalSerial > 0,
              var session = codemapSessionsByRootEpoch[rootEpoch],
              session.authority == authority,
              codemapAuthorityIsCurrent(authority),
              session.engine != nil,
              session.graphPublicationFlight == nil
        else { return }

        let flightID = UUID()
        session.graphPublicationFlight = CodemapGraphPublicationFlight(
            id: flightID,
            authority: authority,
            projectionRecoveryObserverID: projectionRecoveryObserverID,
            latestSignalSerial: initialSignalSerial,
            flushingSerial: nil,
            replayRequired: false,
            followUpStarted: false,
            task: nil
        )
        codemapSessionsByRootEpoch[rootEpoch] = session

        let waiter = codemapGraphPublicationWaiter
        let task = Task { [weak self] in
            await waiter(rootEpoch)
            await self?.runCodemapGraphPublicationFlight(
                rootEpoch: rootEpoch,
                flightID: flightID
            )
        }
        guard var installedSession = codemapSessionsByRootEpoch[rootEpoch],
              var installedFlight = installedSession.graphPublicationFlight,
              installedFlight.id == flightID
        else {
            task.cancel()
            return
        }
        installedFlight.task = task
        installedSession.graphPublicationFlight = installedFlight
        codemapSessionsByRootEpoch[rootEpoch] = installedSession
    }

    private func runCodemapGraphPublicationFlight(
        rootEpoch: WorkspaceCodemapRootEpoch,
        flightID: UUID
    ) async {
        guard !Task.isCancelled else {
            finishCodemapGraphPublicationFlight(rootEpoch: rootEpoch, flightID: flightID)
            return
        }

        var flushCount = 0
        while flushCount < 2, !Task.isCancelled {
            guard var session = codemapSessionsByRootEpoch[rootEpoch],
                  var flight = session.graphPublicationFlight,
                  flight.id == flightID,
                  session.authority == flight.authority,
                  codemapAuthorityIsCurrent(flight.authority),
                  let engine = session.engine
            else {
                finishCodemapGraphPublicationFlight(rootEpoch: rootEpoch, flightID: flightID)
                return
            }

            let flushingSerial = flight.latestSignalSerial
            flight.flushingSerial = flushingSerial
            flight.replayRequired = false
            if flushCount == 1 {
                flight.followUpStarted = true
            }
            session.graphPublicationFlight = flight
            codemapSessionsByRootEpoch[rootEpoch] = session

            #if DEBUG
                let flushHandler = codemapGraphPublicationWillFlushHandlerForTesting
                await flushHandler?(rootEpoch, flushCount + 1)
                guard !Task.isCancelled,
                      codemapSessionsByRootEpoch[rootEpoch]?.graphPublicationFlight?.id == flightID
                else {
                    finishCodemapGraphPublicationFlight(rootEpoch: rootEpoch, flightID: flightID)
                    return
                }
                codemapGraphBatchFlushCountForTesting += 1
                codemapFullRootGraphFreezeCountForTesting += 1
            #endif
            let bundle = await engine.freeze(rootEpoch: rootEpoch)
            let snapshot = try? bundle?.graphSnapshot()
            bundle?.close()

            guard !Task.isCancelled else {
                finishCodemapGraphPublicationFlight(rootEpoch: rootEpoch, flightID: flightID)
                return
            }
            if let snapshot,
               let acceptedSnapshot = acceptedCodemapGraphPublicationSnapshot(
                   snapshot,
                   authority: flight.authority
               )
            {
                await enqueueCodemapGraphSnapshot(
                    acceptedSnapshot,
                    retiringGraphPublicationFlightID: flightID
                )
            }

            flushCount += 1
            guard var currentSession = codemapSessionsByRootEpoch[rootEpoch],
                  let currentFlight = currentSession.graphPublicationFlight,
                  currentFlight.id == flightID
            else { return }

            let replayRequired = currentFlight.replayRequired ||
                currentFlight.latestSignalSerial != flushingSerial
            if replayRequired, flushCount < 2 {
                continue
            }

            let successorSerial = replayRequired
                ? currentFlight.latestSignalSerial
                : nil
            currentSession.graphPublicationFlight = nil
            codemapSessionsByRootEpoch[rootEpoch] = currentSession
            if let successorSerial {
                startCodemapGraphPublicationFlight(
                    rootEpoch: rootEpoch,
                    authority: currentFlight.authority,
                    initialSignalSerial: successorSerial,
                    projectionRecoveryObserverID: currentFlight.projectionRecoveryObserverID
                )
            }
            return
        }

        finishCodemapGraphPublicationFlight(rootEpoch: rootEpoch, flightID: flightID)
    }

    private func finishCodemapGraphPublicationFlight(
        rootEpoch: WorkspaceCodemapRootEpoch,
        flightID: UUID
    ) {
        guard var session = codemapSessionsByRootEpoch[rootEpoch],
              session.graphPublicationFlight?.id == flightID
        else { return }
        session.graphPublicationFlight = nil
        codemapSessionsByRootEpoch[rootEpoch] = session
    }

    private func startCodemapProjectionRecoveryObserver(
        rootEpoch: WorkspaceCodemapRootEpoch,
        authority: CodemapRootAuthority,
        engine: WorkspaceCodemapBindingEngine,
        contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration,
        retiringGraphPublicationFlightID: UUID?
    ) {
        guard var session = codemapSessionsByRootEpoch[rootEpoch],
              session.authority == authority,
              codemapAuthorityIsCurrent(authority),
              session.engine === engine
        else { return }

        var latestSignalSerial: UInt64 = 1
        if let retiringGraphPublicationFlightID {
            guard let flight = session.graphPublicationFlight,
                  flight.id == retiringGraphPublicationFlightID,
                  flight.authority == authority
            else { return }
            latestSignalSerial = max(1, flight.latestSignalSerial)
            session.graphPublicationFlight = nil
            if let observerID = flight.projectionRecoveryObserverID {
                guard var observer = session.projectionRecoveryObserver,
                      observer.id == observerID,
                      observer.authority == authority
                else {
                    codemapSessionsByRootEpoch[rootEpoch] = session
                    return
                }
                observer.latestSignalSerial = max(observer.latestSignalSerial, latestSignalSerial)
                guard let recoveredGeneration = observer.lastRecoveredContributionGeneration,
                      let recoveredSignalSerial = observer.lastRecoveredSignalSerial,
                      contributionGeneration > recoveredGeneration ||
                      observer.latestSignalSerial > recoveredSignalSerial
                else {
                    session.projectionRecoveryObserver = nil
                    codemapSessionsByRootEpoch[rootEpoch] = session
                    return
                }
                observer.task = nil
                session.projectionRecoveryObserver = observer
                codemapSessionsByRootEpoch[rootEpoch] = session
                #if DEBUG
                    codemapProjectionRecoveryObserverRearmCountForTesting += 1
                #endif
                armCodemapProjectionRecoveryObserver(
                    rootEpoch: rootEpoch,
                    observerID: observerID,
                    authority: authority,
                    engine: engine,
                    contributionGeneration: contributionGeneration
                )
                return
            }
        }
        if var existing = session.projectionRecoveryObserver {
            existing.latestSignalSerial = max(existing.latestSignalSerial, latestSignalSerial)
            session.projectionRecoveryObserver = existing
            codemapSessionsByRootEpoch[rootEpoch] = session
            return
        }

        let observerID = UUID()
        session.projectionRecoveryObserver = CodemapProjectionRecoveryObserver(
            id: observerID,
            authority: authority,
            latestSignalSerial: latestSignalSerial,
            lastRecoveredContributionGeneration: nil,
            recoveringSignalSerial: nil,
            lastRecoveredSignalSerial: nil,
            publishingContributionGeneration: nil,
            publishingSignalSerial: nil,
            task: nil
        )
        codemapSessionsByRootEpoch[rootEpoch] = session
        #if DEBUG
            codemapProjectionRecoveryObserverStartCountForTesting += 1
        #endif

        armCodemapProjectionRecoveryObserver(
            rootEpoch: rootEpoch,
            observerID: observerID,
            authority: authority,
            engine: engine,
            contributionGeneration: contributionGeneration
        )
    }

    private func armCodemapProjectionRecoveryObserver(
        rootEpoch: WorkspaceCodemapRootEpoch,
        observerID: UUID,
        authority: CodemapRootAuthority,
        engine: WorkspaceCodemapBindingEngine,
        contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration
    ) {
        guard var session = codemapSessionsByRootEpoch[rootEpoch],
              let observer = session.projectionRecoveryObserver,
              observer.id == observerID,
              observer.authority == authority,
              observer.task == nil,
              codemapAuthorityIsCurrent(authority)
        else { return }
        var armedObserver = observer
        armedObserver.recoveringSignalSerial = observer.latestSignalSerial
        session.projectionRecoveryObserver = armedObserver
        let task = Task { [weak self] in
            await self?.runCodemapProjectionRecoveryObserver(
                rootEpoch: rootEpoch,
                observerID: observerID,
                authority: authority,
                engine: engine,
                contributionGeneration: contributionGeneration
            )
            return ()
        }
        guard var installedObserver = session.projectionRecoveryObserver,
              installedObserver.id == observerID
        else {
            task.cancel()
            return
        }
        installedObserver.task = task
        session.projectionRecoveryObserver = installedObserver
        codemapSessionsByRootEpoch[rootEpoch] = session
    }

    private func runCodemapProjectionRecoveryObserver(
        rootEpoch: WorkspaceCodemapRootEpoch,
        observerID: UUID,
        authority: CodemapRootAuthority,
        engine: WorkspaceCodemapBindingEngine,
        contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration
    ) async {
        #if DEBUG
            let waitHandler = codemapProjectionRecoveryObserverWillWaitHandlerForTesting
            await waitHandler?(rootEpoch)
        #endif
        guard !Task.isCancelled,
              codemapSessionsByRootEpoch[rootEpoch]?.projectionRecoveryObserver?.id == observerID
        else {
            finishCodemapProjectionRecoveryObserver(
                rootEpoch: rootEpoch,
                observerID: observerID,
                contributionGeneration: contributionGeneration,
                latestObservedContributionGeneration: contributionGeneration,
                recoveredCurrentCoverage: false
            )
            return
        }
        _ = await engine.restartCompletedProjectionForOverlayAdvance(
            rootEpoch: rootEpoch,
            contributionGeneration: contributionGeneration
        )
        let recovered = await engine.waitForCurrentProjectionCoverage(rootEpoch: rootEpoch)
        var latestObservedContributionGeneration = contributionGeneration
        if !Task.isCancelled,
           let bundle = await engine.freeze(rootEpoch: rootEpoch)
        {
            latestObservedContributionGeneration =
                (try? bundle.graphSnapshot())?.contributionGeneration ?? contributionGeneration
            bundle.close()
        }
        finishCodemapProjectionRecoveryObserver(
            rootEpoch: rootEpoch,
            observerID: observerID,
            contributionGeneration: contributionGeneration,
            latestObservedContributionGeneration: latestObservedContributionGeneration,
            recoveredCurrentCoverage: recovered && !Task.isCancelled && codemapAuthorityIsCurrent(authority)
        )
    }

    private func finishCodemapProjectionRecoveryObserver(
        rootEpoch: WorkspaceCodemapRootEpoch,
        observerID: UUID,
        contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration,
        latestObservedContributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration,
        recoveredCurrentCoverage: Bool
    ) {
        guard var session = codemapSessionsByRootEpoch[rootEpoch],
              var observer = session.projectionRecoveryObserver,
              observer.id == observerID
        else { return }
        let latestSignalSerial = observer.latestSignalSerial
        let authority = observer.authority
        guard session.authority == authority,
              codemapAuthorityIsCurrent(authority),
              let engine = session.engine
        else {
            session.projectionRecoveryObserver = nil
            codemapSessionsByRootEpoch[rootEpoch] = session
            return
        }
        let recoveredSignalSerial = observer.recoveringSignalSerial ?? observer.latestSignalSerial
        let hasCoalescedRecoveryWork = latestObservedContributionGeneration > contributionGeneration ||
            observer.latestSignalSerial > recoveredSignalSerial
        observer.task = nil
        observer.lastRecoveredContributionGeneration = contributionGeneration
        observer.lastRecoveredSignalSerial = recoveredSignalSerial
        observer.recoveringSignalSerial = nil
        session.projectionRecoveryObserver = observer
        codemapSessionsByRootEpoch[rootEpoch] = session
        if hasCoalescedRecoveryWork {
            #if DEBUG
                codemapProjectionRecoveryObserverRearmCountForTesting += 1
            #endif
            armCodemapProjectionRecoveryObserver(
                rootEpoch: rootEpoch,
                observerID: observerID,
                authority: authority,
                engine: engine,
                contributionGeneration: latestObservedContributionGeneration
            )
            return
        }
        guard recoveredCurrentCoverage else {
            session.projectionRecoveryObserver = nil
            codemapSessionsByRootEpoch[rootEpoch] = session
            return
        }
        startCodemapGraphPublicationFlight(
            rootEpoch: rootEpoch,
            authority: authority,
            initialSignalSerial: latestSignalSerial,
            projectionRecoveryObserverID: observerID
        )
    }

    private func completeCodemapProjectionRecoveryPublication(
        rootEpoch: WorkspaceCodemapRootEpoch,
        graphPublicationFlightID: UUID?
    ) {
        guard let graphPublicationFlightID,
              var session = codemapSessionsByRootEpoch[rootEpoch],
              let flight = session.graphPublicationFlight,
              flight.id == graphPublicationFlightID,
              let observerID = flight.projectionRecoveryObserverID,
              let observer = session.projectionRecoveryObserver,
              observer.id == observerID
        else { return }

        let publishedSignalSerial = flight.flushingSerial ?? flight.latestSignalSerial
        if observer.latestSignalSerial > publishedSignalSerial {
            session.graphPublicationFlight = nil
            codemapSessionsByRootEpoch[rootEpoch] = session
            startCodemapGraphPublicationFlight(
                rootEpoch: rootEpoch,
                authority: observer.authority,
                initialSignalSerial: observer.latestSignalSerial,
                projectionRecoveryObserverID: observerID
            )
        } else {
            session.projectionRecoveryObserver = nil
            codemapSessionsByRootEpoch[rootEpoch] = session
        }
    }

    private func codemapProjectionRecoveryRequiresRearm(
        rootEpoch: WorkspaceCodemapRootEpoch,
        contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration,
        graphPublicationFlightID: UUID?
    ) -> Bool {
        guard let graphPublicationFlightID,
              let session = codemapSessionsByRootEpoch[rootEpoch],
              let flight = session.graphPublicationFlight,
              flight.id == graphPublicationFlightID,
              let observerID = flight.projectionRecoveryObserverID,
              let observer = session.projectionRecoveryObserver,
              observer.id == observerID,
              let recoveredGeneration = observer.lastRecoveredContributionGeneration,
              let recoveredSignalSerial = observer.lastRecoveredSignalSerial
        else { return false }
        return contributionGeneration > recoveredGeneration ||
            observer.latestSignalSerial > recoveredSignalSerial
    }

    private func markCodemapProjectionRecoveryRebuild(
        rootEpoch: WorkspaceCodemapRootEpoch,
        contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration,
        graphPublicationFlightID: UUID?
    ) {
        guard let graphPublicationFlightID,
              var session = codemapSessionsByRootEpoch[rootEpoch],
              let flight = session.graphPublicationFlight,
              flight.id == graphPublicationFlightID,
              let observerID = flight.projectionRecoveryObserverID,
              var observer = session.projectionRecoveryObserver,
              observer.id == observerID
        else { return }
        observer.publishingContributionGeneration = contributionGeneration
        observer.publishingSignalSerial = flight.flushingSerial ?? flight.latestSignalSerial
        session.projectionRecoveryObserver = observer
        codemapSessionsByRootEpoch[rootEpoch] = session
    }

    private func completeCodemapProjectionRecoveryRebuild(
        rootEpoch: WorkspaceCodemapRootEpoch,
        publishedKey: WorkspaceCodemapSelectionGraphRuntimeKey
    ) {
        guard var session = codemapSessionsByRootEpoch[rootEpoch],
              var observer = session.projectionRecoveryObserver,
              observer.publishingContributionGeneration == publishedKey.contributionGeneration,
              let publishedSignalSerial = observer.publishingSignalSerial
        else { return }

        observer.publishingContributionGeneration = nil
        observer.publishingSignalSerial = nil
        guard observer.latestSignalSerial > publishedSignalSerial else {
            session.projectionRecoveryObserver = nil
            codemapSessionsByRootEpoch[rootEpoch] = session
            return
        }

        if var flight = session.graphPublicationFlight,
           flight.projectionRecoveryObserverID == observer.id
        {
            flight.latestSignalSerial = max(flight.latestSignalSerial, observer.latestSignalSerial)
            flight.replayRequired = true
            session.graphPublicationFlight = flight
            session.projectionRecoveryObserver = observer
            codemapSessionsByRootEpoch[rootEpoch] = session
            return
        }

        session.projectionRecoveryObserver = observer
        codemapSessionsByRootEpoch[rootEpoch] = session
        startCodemapGraphPublicationFlight(
            rootEpoch: rootEpoch,
            authority: observer.authority,
            initialSignalSerial: observer.latestSignalSerial,
            projectionRecoveryObserverID: observer.id
        )
    }

    private func acceptedCodemapGraphPublicationSnapshot(
        _ snapshot: WorkspaceCodemapLiveGraphSnapshot,
        authority: CodemapRootAuthority
    ) -> WorkspaceCodemapLiveGraphSnapshot? {
        guard snapshot.rootEpoch == authority.rootEpoch,
              snapshot.catalogGeneration == authority.catalogGeneration,
              codemapAuthorityIsCurrent(authority),
              let session = codemapSessionsByRootEpoch[authority.rootEpoch],
              session.authority == authority
        else { return nil }

        for binding in snapshot.bindings {
            guard let record = session.demandsByFileID[binding.identity.fileID],
                  case let .ready(triggeringReady) = record.result,
                  codemapTicketsShareDemand(record.ticket, triggeringReady.ticket)
            else { continue }
            if codemapGraphSnapshotIsAccepted(
                snapshot,
                triggeringReady: triggeringReady
            ) {
                return snapshot
            }
        }
        return nil
    }

    private func codemapGraphSnapshotIsAccepted(
        _ snapshot: WorkspaceCodemapLiveGraphSnapshot,
        triggeringReady: WorkspaceCodemapArtifactDemandReady
    ) -> Bool {
        let ticket = triggeringReady.ticket
        guard snapshot.rootEpoch == ticket.rootEpoch,
              snapshot.catalogGeneration == ticket.catalogGeneration,
              snapshot.contributionGeneration.rawValue > 0,
              codemapDemandIsCurrent(ticket),
              let session = codemapSessionsByRootEpoch[ticket.rootEpoch],
              session.authority.catalogGeneration == snapshot.catalogGeneration,
              let state = rootStatesByID[ticket.rootEpoch.rootID],
              state.lifetimeID == ticket.rootEpoch.rootLifetimeID
        else { return false }

        var seenFileIDs = Set<UUID>()
        var seenRelativePaths = Set<String>()
        var triggeringBindingCount = 0
        for binding in snapshot.bindings {
            let identity = binding.identity
            guard identity.rootID == snapshot.rootEpoch.rootID,
                  identity.rootLifetimeID == snapshot.rootEpoch.rootLifetimeID,
                  identity.standardizedRootPath == session.authority.standardizedRootPath,
                  state.fileIDsByRelativePath[identity.standardizedRelativePath] == identity.fileID,
                  let file = filesByID[identity.fileID],
                  file.rootID == identity.rootID,
                  file.standardizedRelativePath == identity.standardizedRelativePath,
                  file.standardizedFullPath == identity.standardizedFullPath,
                  seenFileIDs.insert(identity.fileID).inserted,
                  seenRelativePaths.insert(identity.standardizedRelativePath).inserted,
                  case let .resolved(completion) = binding.availability,
                  completion.token.isFactoryValidated,
                  completion.sourceProof.isFactoryValidated,
                  completion.token.identity == identity,
                  completion.sourceProof == completion.token.sourceExpectation,
                  completion.token.catalogGeneration == snapshot.catalogGeneration,
                  completion.sourceProof.sourceAuthority.rootEpoch == snapshot.rootEpoch,
                  completion.sourceProof.sourceAuthority.repositoryAuthority ==
                  snapshot.repositoryAuthority
            else { return false }

            switch completion.outcome {
            case .ready, .readyNoSymbols:
                break
            case .oversize, .decodeFailed, .parseFailed:
                return false
            }

            if identity.fileID == ticket.fileID {
                triggeringBindingCount += 1
                guard identity == triggeringReady.identity,
                      completion.token.requestGeneration == ticket.requestGeneration,
                      completion.artifactKey == triggeringReady.snapshot.artifactKey,
                      codemapGraphOutcomeMatches(
                          completion.outcome,
                          triggeringReady.snapshot.outcome
                      )
                else { return false }
            }
        }
        return triggeringBindingCount == 1
    }

    private func codemapGraphOutcomeMatches(
        _ completion: CodeMapSyntaxArtifactOutcome,
        _ snapshot: WorkspaceCodemapLiveArtifactOutcome
    ) -> Bool {
        switch (completion, snapshot) {
        case (.ready, .ready), (.readyNoSymbols, .readyNoSymbols):
            true
        case (.ready, _), (.readyNoSymbols, _), (.oversize, _), (.decodeFailed, _),
             (.parseFailed, _):
            false
        }
    }

    private func enqueueCodemapGraphSnapshot(
        _ snapshot: WorkspaceCodemapLiveGraphSnapshot,
        retiringGraphPublicationFlightID: UUID? = nil
    ) async {
        guard var session = codemapSessionsByRootEpoch[snapshot.rootEpoch],
              codemapAuthorityIsCurrent(session.authority),
              session.authority.catalogGeneration == snapshot.catalogGeneration,
              let engine = session.engine
        else { return }

        let key = WorkspaceCodemapSelectionGraphRuntimeKey(snapshot: snapshot)
        let state = session.selectionGraph ?? CodemapSelectionGraphState(
            id: UUID(),
            graph: selectionGraphFactory.make(rootEpoch: snapshot.rootEpoch),
            desiredKey: nil,
            pendingSnapshot: nil,
            publishedSummary: nil,
            lastRebuildDisposition: nil,
            workerID: nil,
            workerTask: nil
        )
        if let desiredKey = state.desiredKey {
            if key.contributionGeneration < desiredKey.contributionGeneration {
                return
            }
            if key == desiredKey {
                if state.publishedSummary?.key == key {
                    completeCodemapProjectionRecoveryPublication(
                        rootEpoch: snapshot.rootEpoch,
                        graphPublicationFlightID: retiringGraphPublicationFlightID
                    )
                    return
                }
                if state.pendingSnapshot != nil || state.workerTask != nil {
                    return
                }
            }
        }

        let graphStateID = state.id
        let graph = state.graph
        let previousDesiredKey = state.desiredKey
        session.selectionGraph = state
        codemapSessionsByRootEpoch[snapshot.rootEpoch] = session

        if state.desiredKey == key,
           state.publishedSummary == nil,
           state.pendingSnapshot == nil,
           state.workerTask == nil
        {
            let accounting = await graph.accounting()
            if let summary = accounting.publishedSummary,
               summary.key == key,
               case .complete = summary.definitionUniverseCoverage,
               var restoredSession = codemapSessionsByRootEpoch[snapshot.rootEpoch],
               var restoredState = restoredSession.selectionGraph,
               restoredState.id == graphStateID,
               restoredState.graph === graph,
               restoredState.desiredKey == key,
               restoredState.pendingSnapshot == nil,
               restoredState.workerTask == nil
            {
                restoredState.publishedSummary = summary
                restoredSession.selectionGraph = restoredState
                codemapSessionsByRootEpoch[snapshot.rootEpoch] = restoredSession
                yieldCodemapSelectionGraphReadiness(rootEpoch: snapshot.rootEpoch)
                completeCodemapProjectionRecoveryPublication(
                    rootEpoch: snapshot.rootEpoch,
                    graphPublicationFlightID: retiringGraphPublicationFlightID
                )
                return
            }
        }

        let preparedSeal = state.workerTask == nil && state.pendingSnapshot == nil
            ? await engine.prepareCompletedProjectionSuccessor(
                rootEpoch: snapshot.rootEpoch,
                liveSnapshot: snapshot
            )
            : nil
        if let seal = preparedSeal,
           state.desiredKey == WorkspaceCodemapSelectionGraphRuntimeKey(
               generation: seal.predecessorProof.generation
           )
        {
            let disposition = await graph.applyEquivalentProjectionSuccessor(
                seal,
                liveSnapshot: snapshot
            )
            switch disposition {
            case .accepted, .exactDuplicate:
                if await engine.commitCompletedProjectionSuccessor(seal) {
                    let accounting = await graph.accounting()
                    guard var resealedSession = codemapSessionsByRootEpoch[snapshot.rootEpoch],
                          var resealedState = resealedSession.selectionGraph,
                          resealedState.id == graphStateID,
                          resealedState.graph === graph,
                          resealedState.desiredKey == previousDesiredKey,
                          let summary = accounting.publishedSummary,
                          summary.key == key,
                          case let .complete(proof, _, _, _) = summary.definitionUniverseCoverage,
                          proof == seal.successorProof
                    else { return }
                    resealedState.desiredKey = key
                    resealedState.publishedSummary = summary
                    resealedState.lastRebuildDisposition = nil
                    resealedSession.selectionGraph = resealedState
                    codemapSessionsByRootEpoch[snapshot.rootEpoch] = resealedSession
                    yieldCodemapSelectionGraphReadiness(rootEpoch: snapshot.rootEpoch)
                    completeCodemapProjectionRecoveryPublication(
                        rootEpoch: snapshot.rootEpoch,
                        graphPublicationFlightID: retiringGraphPublicationFlightID
                    )
                    return
                }
            case .stale, .superseded, .busy, .budget, .unavailable:
                break
            }
            startCodemapProjectionRecoveryObserver(
                rootEpoch: snapshot.rootEpoch,
                authority: session.authority,
                engine: engine,
                contributionGeneration: snapshot.contributionGeneration,
                retiringGraphPublicationFlightID: retiringGraphPublicationFlightID
            )
            return
        }

        if codemapProjectionRecoveryRequiresRearm(
            rootEpoch: snapshot.rootEpoch,
            contributionGeneration: snapshot.contributionGeneration,
            graphPublicationFlightID: retiringGraphPublicationFlightID
        ) {
            startCodemapProjectionRecoveryObserver(
                rootEpoch: snapshot.rootEpoch,
                authority: session.authority,
                engine: engine,
                contributionGeneration: snapshot.contributionGeneration,
                retiringGraphPublicationFlightID: retiringGraphPublicationFlightID
            )
            return
        }

        guard await graph.observeDesiredKey(key) else { return }

        guard var currentSession = codemapSessionsByRootEpoch[snapshot.rootEpoch],
              var currentState = currentSession.selectionGraph,
              currentState.id == graphStateID,
              currentState.graph === graph,
              currentState.desiredKey == previousDesiredKey,
              codemapAuthorityIsCurrent(currentSession.authority),
              currentSession.authority.catalogGeneration == snapshot.catalogGeneration
        else { return }

        currentState.desiredKey = key
        currentState.pendingSnapshot = snapshot

        if currentState.workerTask == nil {
            let workerID = UUID()
            currentState.workerID = workerID
            currentState.workerTask = Task { [weak self] in
                await self?.runCodemapGraphWorker(
                    rootEpoch: snapshot.rootEpoch,
                    graphStateID: graphStateID,
                    workerID: workerID
                )
            }
            #if DEBUG
                codemapGraphWorkerStartCountForTesting += 1
            #endif
        }
        currentSession.selectionGraph = currentState
        codemapSessionsByRootEpoch[snapshot.rootEpoch] = currentSession
        markCodemapProjectionRecoveryRebuild(
            rootEpoch: snapshot.rootEpoch,
            contributionGeneration: snapshot.contributionGeneration,
            graphPublicationFlightID: retiringGraphPublicationFlightID
        )
    }

    private func runCodemapGraphWorker(
        rootEpoch: WorkspaceCodemapRootEpoch,
        graphStateID: UUID,
        workerID: UUID
    ) async {
        while !Task.isCancelled {
            guard var session = codemapSessionsByRootEpoch[rootEpoch],
                  var state = session.selectionGraph,
                  state.id == graphStateID,
                  state.workerID == workerID,
                  let snapshot = state.pendingSnapshot
            else { return }

            let key = WorkspaceCodemapSelectionGraphRuntimeKey(snapshot: snapshot)
            guard state.desiredKey == key else {
                state.workerID = nil
                state.workerTask = nil
                session.selectionGraph = state
                codemapSessionsByRootEpoch[rootEpoch] = session
                return
            }

            state.pendingSnapshot = nil
            let graph = state.graph
            session.selectionGraph = state
            codemapSessionsByRootEpoch[rootEpoch] = session

            let disposition = await graph.rebuild(from: snapshot)

            guard var currentSession = codemapSessionsByRootEpoch[rootEpoch],
                  var currentState = currentSession.selectionGraph,
                  currentState.id == graphStateID,
                  currentState.graph === graph,
                  currentState.workerID == workerID
            else { return }

            if currentState.desiredKey == key {
                currentState.lastRebuildDisposition = disposition
                switch disposition {
                case let .published(summary):
                    if summary.key == key {
                        currentState.publishedSummary = summary
                    }
                case let .publishedEmpty(summary):
                    if summary.key == key {
                        currentState.publishedSummary = summary
                    }
                case .busy, .cancelled, .rejected, .superseded:
                    break
                }
            }

            let processAdmissionBindingCount: Int? = switch disposition {
            case .busy(_, .processAdmission): snapshot.bindings.count
            case .published, .publishedEmpty, .busy, .cancelled, .rejected, .superseded: nil
            }

            let automaticSelectionReadinessChanged = currentState.publishedSummary?.key == key

            if currentState.pendingSnapshot == nil,
               let processAdmissionBindingCount
            {
                currentSession.selectionGraph = currentState
                codemapSessionsByRootEpoch[rootEpoch] = currentSession
                await graph.waitForProcessAdmissionAvailability(
                    bindingCount: processAdmissionBindingCount
                )
                guard !Task.isCancelled,
                      var availableSession = codemapSessionsByRootEpoch[rootEpoch],
                      var availableState = availableSession.selectionGraph,
                      availableState.id == graphStateID,
                      availableState.graph === graph,
                      availableState.workerID == workerID
                else { return }
                if availableState.desiredKey == key {
                    availableState.pendingSnapshot = snapshot
                } else if availableState.pendingSnapshot == nil {
                    availableState.workerID = nil
                    availableState.workerTask = nil
                    availableSession.selectionGraph = availableState
                    codemapSessionsByRootEpoch[rootEpoch] = availableSession
                    return
                }
                availableSession.selectionGraph = availableState
                codemapSessionsByRootEpoch[rootEpoch] = availableSession
                yieldCodemapSelectionGraphReadiness(rootEpoch: rootEpoch)
                continue
            }

            if currentState.pendingSnapshot == nil || Task.isCancelled {
                currentState.workerID = nil
                currentState.workerTask = nil
                currentSession.selectionGraph = currentState
                codemapSessionsByRootEpoch[rootEpoch] = currentSession
                if automaticSelectionReadinessChanged {
                    completeCodemapProjectionRecoveryRebuild(
                        rootEpoch: rootEpoch,
                        publishedKey: key
                    )
                    yieldCodemapSelectionGraphReadiness(rootEpoch: rootEpoch)
                }
                return
            }

            currentSession.selectionGraph = currentState
            codemapSessionsByRootEpoch[rootEpoch] = currentSession
            if automaticSelectionReadinessChanged {
                completeCodemapProjectionRecoveryRebuild(
                    rootEpoch: rootEpoch,
                    publishedKey: key
                )
                yieldCodemapSelectionGraphReadiness(rootEpoch: rootEpoch)
            }
        }
    }

    private func codemapProjectionCatalogShardAndToken(
        authority: CodemapRootAuthority
    ) -> (shard: RootCatalogShard, token: WorkspaceCodemapProjectionCatalogToken)? {
        guard codemapAuthorityIsCurrent(authority),
              let state = rootStatesByID[authority.rootEpoch.rootID],
              state.lifetimeID == authority.rootEpoch.rootLifetimeID,
              state.root.standardizedFullPath == authority.standardizedRootPath,
              let shard = publishedRootCatalogShardsByRootID[authority.rootEpoch.rootID],
              shard.key.rootID == authority.rootEpoch.rootID,
              shard.key.lifetimeID == authority.rootEpoch.rootLifetimeID,
              shard.root.id == authority.rootEpoch.rootID,
              shard.root.standardizedFullPath == authority.standardizedRootPath,
              shard.key.canonicalConfigurationIdentity.canonicalPath == authority.standardizedRootPath,
              catalogGenerationsByRootID[authority.rootEpoch.rootID] != nil
        else { return nil }
        return (
            shard,
            WorkspaceCodemapProjectionCatalogToken(
                rootEpoch: authority.rootEpoch,
                topologyGeneration: shard.key.topologyGeneration,
                appliedIndexGeneration: shard.appliedIndexGeneration,
                catalogGeneration: authority.catalogGeneration,
                ingressGeneration: authority.ingressGeneration,
                projectionInvalidationGeneration:
                codemapProjectionInvalidationGenerationsByRootEpoch[authority.rootEpoch] ?? 1
            )
        )
    }

    private func advanceCodemapProjectionInvalidationGeneration(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) {
        revokeAutomaticSelectionPublicationPermits(rootEpoch: rootEpoch)
        let current = codemapProjectionInvalidationGenerationsByRootEpoch[rootEpoch] ?? 1
        codemapProjectionInvalidationGenerationsByRootEpoch[rootEpoch] = current == .max
            ? 0
            : current + 1
    }

    private func codemapProjectionCatalogIsFenced(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> Bool {
        codemapPathFenceTokensByID.values.contains { $0.rootEpoch == rootEpoch }
            || codemapRootMutationFenceTokensByRootEpoch[rootEpoch] != nil
            || codemapPathInvalidationFlightsByRootEpoch[rootEpoch] != nil
            || (codemapPathLocalCatalogMutationDepthByRootID[rootEpoch.rootID] ?? 0) > 0
    }

    private func ensureCodemapProjectionCatalogShard(
        authority: CodemapRootAuthority
    ) async -> Bool {
        for _ in 0 ..< 2 {
            if codemapProjectionCatalogShardAndToken(authority: authority) != nil {
                return true
            }
            guard let snapshot = codemapProjectionCatalogShardBuildSnapshot(authority: authority) else {
                return false
            }
            #if DEBUG
                let buildHandler = codemapProjectionCatalogBuildHandler
            #endif
            let shard = await Task.detached(priority: .userInitiated) { [snapshot] in
                #if DEBUG
                    if let buildHandler {
                        await buildHandler(snapshot.authority.rootEpoch)
                    }
                #endif
                return Self.buildCodemapProjectionCatalogShard(snapshot: snapshot)
            }.value
            guard !Task.isCancelled else { return false }
            switch publishCodemapProjectionCatalogShard(shard, snapshot: snapshot) {
            case .ready:
                return true
            case .retry:
                continue
            case .unavailable:
                return false
            }
        }
        return codemapProjectionCatalogShardAndToken(authority: authority) != nil
    }

    private func codemapProjectionCatalogShardBuildSnapshot(
        authority: CodemapRootAuthority
    ) -> CodemapProjectionCatalogShardBuildSnapshot? {
        guard codemapAuthorityIsCurrent(authority),
              !codemapProjectionCatalogIsFenced(rootEpoch: authority.rootEpoch),
              let state = rootStatesByID[authority.rootEpoch.rootID],
              state.lifetimeID == authority.rootEpoch.rootLifetimeID,
              state.root.standardizedFullPath == authority.standardizedRootPath,
              let key = rootCatalogShardKey(for: state.root),
              let appliedIndexGeneration = appliedIndexGenerationsByRootID[authority.rootEpoch.rootID]
        else { return nil }
        return CodemapProjectionCatalogShardBuildSnapshot(
            authority: authority,
            key: key,
            root: state.root,
            appliedIndexGeneration: appliedIndexGeneration,
            projectionInvalidationGeneration:
            codemapProjectionInvalidationGenerationsByRootEpoch[authority.rootEpoch] ?? 1,
            files: state.fileIDsByRelativePath.values.compactMap { filesByID[$0] },
            folders: state.folderIDsByRelativePath.values.compactMap { foldersByID[$0] },
            managedOnlyFileIDs: managedOnlyFileIDs,
            managedOnlyFolderIDs: managedOnlyFolderIDs
        )
    }

    private nonisolated static func buildCodemapProjectionCatalogShard(
        snapshot: CodemapProjectionCatalogShardBuildSnapshot
    ) -> RootCatalogShard {
        let files = snapshot.files
            .filter { !snapshot.managedOnlyFileIDs.contains($0.id) }
            .sorted(by: searchRootCatalogFilePrecedes)
        let folders = snapshot.folders
            .filter { !snapshot.managedOnlyFolderIDs.contains($0.id) }
            .sorted(by: searchCatalogFolderPrecedes)
        let entries = files.map { WorkspaceSearchCatalogEntry(file: $0, root: snapshot.root) }
        let syntaxManager = SyntaxManager()
        let projectionFiles = files.compactMap { file -> RootCatalogProjectionFile? in
            let fileExtension = (file.name as NSString).pathExtension
            guard SyntaxManager.supportsCodeMap(fileExtension: fileExtension),
                  let language = syntaxManager.language(forFileExtension: fileExtension)
            else { return nil }
            return RootCatalogProjectionFile(file: file, language: language)
        }
        return RootCatalogShard(
            key: snapshot.key,
            root: snapshot.root,
            files: files,
            precomputedProjectionFiles: projectionFiles,
            folders: folders,
            entries: entries,
            pathSearchIndex: nil,
            appliedIndexGeneration: snapshot.appliedIndexGeneration
        )
    }

    private func publishCodemapProjectionCatalogShard(
        _ shard: RootCatalogShard,
        snapshot: CodemapProjectionCatalogShardBuildSnapshot
    ) -> CodemapProjectionCatalogShardPublicationDisposition {
        if codemapProjectionCatalogShardAndToken(authority: snapshot.authority) != nil {
            return .ready
        }
        guard codemapAuthorityIsCurrent(snapshot.authority),
              !codemapProjectionCatalogIsFenced(rootEpoch: snapshot.authority.rootEpoch),
              let state = rootStatesByID[snapshot.authority.rootEpoch.rootID],
              state.lifetimeID == snapshot.authority.rootEpoch.rootLifetimeID,
              state.root.standardizedFullPath == snapshot.authority.standardizedRootPath,
              rootCatalogShardKey(for: state.root) == snapshot.key,
              appliedIndexGenerationsByRootID[snapshot.authority.rootEpoch.rootID]
              == snapshot.appliedIndexGeneration,
              (codemapProjectionInvalidationGenerationsByRootEpoch[snapshot.authority.rootEpoch] ?? 1)
              == snapshot.projectionInvalidationGeneration
        else {
            return codemapAuthorityIsCurrent(snapshot.authority) ? .retry : .unavailable
        }
        guard canPublishAnotherRootCatalogShard(rootID: snapshot.authority.rootEpoch.rootID) else {
            return .unavailable
        }
        publishedRootCatalogShardsByRootID[snapshot.authority.rootEpoch.rootID] = shard
        rootCatalogShardDeltaStatesByRootID[snapshot.authority.rootEpoch.rootID] = RootCatalogShardDeltaState(
            lifetimeID: snapshot.authority.rootEpoch.rootLifetimeID,
            lastAppliedIndexGeneration: snapshot.appliedIndexGeneration,
            isDirty: false,
            capability: .recordsOnly
        )
        registerPublishedRootCatalogShard(shard, kind: .authoritative)
        return .ready
    }

    private func readCodemapProjectionCatalogPage(
        _ request: WorkspaceCodemapProjectionCatalogPageRequest,
        authority: CodemapRootAuthority
    ) async -> WorkspaceCodemapProjectionCatalogPageDisposition {
        guard request.rootEpoch == authority.rootEpoch else { return .stale }
        guard request.cursor == nil || request.token != nil else { return .stale }
        guard codemapAuthorityIsCurrent(authority) else { return .stale }
        if codemapProjectionCatalogIsFenced(rootEpoch: authority.rootEpoch) {
            return request.token == nil ? .unavailable(.catalogNotReady) : .stale
        }
        guard await ensureCodemapProjectionCatalogShard(authority: authority) else {
            return codemapAuthorityIsCurrent(authority)
                ? .unavailable(.catalogNotReady)
                : .stale
        }
        guard let current = codemapProjectionCatalogShardAndToken(authority: authority) else {
            return .unavailable(.catalogNotReady)
        }
        guard request.token == nil || request.token == current.token else { return .stale }
        guard let session = codemapSessionsByRootEpoch[authority.rootEpoch],
              session.authority == authority
        else { return .stale }

        let startIndex: Int
        if let cursor = request.cursor {
            guard let cursorIndex = current.shard.projectionFileIndexByID[cursor.fileID],
                  current.shard.projectionFiles[cursorIndex].file.standardizedRelativePath
                  == cursor.standardizedRelativePath
            else { return .stale }
            startIndex = cursorIndex + 1
        } else {
            startIndex = 0
        }

        var entries: [WorkspaceCodemapProjectionCatalogCandidate] = []
        entries.reserveCapacity(min(
            request.maximumEntryCount,
            current.shard.projectionFiles.count - startIndex
        ))
        var pathByteCount: UInt64 = 0
        var nextIndex = startIndex
        while nextIndex < current.shard.projectionFiles.count,
              entries.count < request.maximumEntryCount
        {
            let projectionFile = current.shard.projectionFiles[nextIndex]
            let file = projectionFile.file
            guard let state = rootStatesByID[authority.rootEpoch.rootID],
                  state.lifetimeID == authority.rootEpoch.rootLifetimeID,
                  state.fileIDsByRelativePath[file.standardizedRelativePath] == file.id,
                  filesByID[file.id] == file,
                  isDiscoverableFileID(file.id),
                  let identity = WorkspaceCodemapArtifactBindingIdentity(
                      rootID: authority.rootEpoch.rootID,
                      rootLifetimeID: authority.rootEpoch.rootLifetimeID,
                      fileID: file.id,
                      standardizedRootPath: authority.standardizedRootPath,
                      standardizedRelativePath: file.standardizedRelativePath,
                      standardizedFullPath: file.standardizedFullPath
                  )
            else { return .stale }

            guard let candidatePathByteCount = UInt64(exactly: file.standardizedRelativePath.utf8.count),
                  candidatePathByteCount <= request.maximumPathByteCount
            else { return .unavailable(.catalogUnavailable) }
            let (nextPathByteCount, overflow) = pathByteCount.addingReportingOverflow(candidatePathByteCount)
            guard !overflow else { return .unavailable(.catalogUnavailable) }
            if nextPathByteCount > request.maximumPathByteCount {
                break
            }

            let pathGeneration = session.pathGenerationsByRelativePath[file.standardizedRelativePath]
                ?? authority.ingressGeneration
            entries.append(WorkspaceCodemapProjectionCatalogCandidate(
                identity: identity,
                language: projectionFile.language,
                requestGeneration: pathGeneration,
                pathGeneration: pathGeneration
            ))
            pathByteCount = nextPathByteCount
            nextIndex += 1
        }

        guard !entries.isEmpty || nextIndex == current.shard.projectionFiles.count else {
            return .unavailable(.catalogUnavailable)
        }
        let isEnd = nextIndex == current.shard.projectionFiles.count
        let nextCursor = isEnd ? nil : entries.last.map {
            WorkspaceCodemapProjectionCatalogCursor(
                standardizedRelativePath: $0.identity.standardizedRelativePath,
                fileID: $0.identity.fileID
            )
        }
        guard let supportedCandidateCountThroughPage = UInt64(exactly: nextIndex) else {
            return .unavailable(.catalogUnavailable)
        }
        switch WorkspaceCodemapProjectionCatalogPage.validated(
            request: request,
            token: current.token,
            entries: entries,
            nextCursor: nextCursor,
            isEnd: isEnd,
            supportedCandidateCountThroughPage: supportedCandidateCountThroughPage
        ) {
        case let .success(page):
            return .page(page)
        case .failure:
            return .unavailable(.catalogUnavailable)
        }
    }

    private func revalidateCodemapProjectionCatalogToken(
        rootEpoch: WorkspaceCodemapRootEpoch,
        token: WorkspaceCodemapProjectionCatalogToken,
        authority: CodemapRootAuthority
    ) -> WorkspaceCodemapProjectionCatalogTokenDisposition {
        guard rootEpoch == authority.rootEpoch, token.rootEpoch == rootEpoch else { return .stale }
        guard codemapAuthorityIsCurrent(authority) else { return .stale }
        guard !codemapProjectionCatalogIsFenced(rootEpoch: rootEpoch) else { return .stale }
        guard let current = codemapProjectionCatalogShardAndToken(authority: authority) else {
            return .unavailable(.catalogNotReady)
        }
        return current.token == token ? .current : .stale
    }

    private func acceptCodemapMarkerReadinessUpdate(
        _ update: WorkspaceCodemapMarkerReadinessUpdate,
        authority: CodemapRootAuthority
    ) -> Bool {
        guard update.rootEpoch == authority.rootEpoch,
              codemapAuthorityIsCurrent(authority),
              !codemapProjectionCatalogIsFenced(rootEpoch: authority.rootEpoch),
              var session = codemapSessionsByRootEpoch[authority.rootEpoch],
              session.authority == authority
        else { return false }

        var appliedChanges: [WorkspaceCodemapMarkerReadinessChange] = []
        for change in update.changes {
            guard change.standardizedRelativePath == StandardizedPath.relative(
                change.standardizedRelativePath
            ),
                !change.standardizedRelativePath.isEmpty,
                !codemapPathIsFenced(
                    rootEpoch: authority.rootEpoch,
                    relativePath: change.standardizedRelativePath
                ),
                let state = rootStatesByID[authority.rootEpoch.rootID],
                state.fileIDsByRelativePath[change.standardizedRelativePath] == change.fileID,
                let file = filesByID[change.fileID],
                file.rootID == authority.rootEpoch.rootID,
                file.standardizedRelativePath == change.standardizedRelativePath
            else { continue }
            let pathGeneration = session.pathGenerationsByRelativePath[change.standardizedRelativePath]
                ?? authority.ingressGeneration
            guard change.requestGeneration == pathGeneration,
                  change.pathGeneration == pathGeneration
            else { continue }

            switch change.state {
            case .ready:
                guard session.markerReadinessByFileID[change.fileID] != change else { continue }
                session.markerReadinessByFileID[change.fileID] = change
                appliedChanges.append(change)
            case .unavailable:
                guard let removed = session.markerReadinessByFileID.removeValue(forKey: change.fileID) else {
                    continue
                }
                appliedChanges.append(WorkspaceCodemapMarkerReadinessChange(
                    fileID: removed.fileID,
                    standardizedRelativePath: removed.standardizedRelativePath,
                    requestGeneration: change.requestGeneration,
                    pathGeneration: change.pathGeneration,
                    state: .unavailable
                ))
            }
        }

        guard !appliedChanges.isEmpty else { return true }
        session.markerReadinessRevision &+= 1
        let event = WorkspaceCodemapMarkerReadinessEvent(
            rootEpoch: authority.rootEpoch,
            revision: session.markerReadinessRevision,
            changes: appliedChanges
        )
        codemapSessionsByRootEpoch[authority.rootEpoch] = session
        #if DEBUG
            WorktreeStartupInstrumentation.recordBenchmarkMarkerPublication(
                tag: WorktreeStartupInstrumentation.currentBenchmarkMetricTag,
                rootID: authority.rootEpoch.rootID,
                rootLifetimeID: authority.rootEpoch.rootLifetimeID,
                revision: session.markerReadinessRevision,
                effectiveChangeCount: appliedChanges.count,
                source: .publishedUpdate
            )
        #endif
        yieldCodemapMarkerReadiness(event)
        return true
    }

    #if DEBUG
        func acceptCodemapMarkerReadinessUpdateForTesting(
            _ update: WorkspaceCodemapMarkerReadinessUpdate
        ) -> Bool {
            guard let authority = codemapSessionsByRootEpoch[update.rootEpoch]?.authority else {
                return false
            }
            return acceptCodemapMarkerReadinessUpdate(update, authority: authority)
        }

        func codemapMarkerReadinessSnapshotForTesting(
            rootEpoch: WorkspaceCodemapRootEpoch
        ) -> (revision: UInt64, changes: [WorkspaceCodemapMarkerReadinessChange])? {
            codemapSessionsByRootEpoch[rootEpoch].map {
                (
                    revision: $0.markerReadinessRevision,
                    changes: $0.markerReadinessByFileID.values.sorted {
                        $0.standardizedRelativePath < $1.standardizedRelativePath
                    }
                )
            }
        }

        @discardableResult
        func clearCodemapMarkerReadinessForTesting(
            rootEpoch: WorkspaceCodemapRootEpoch,
            fileID: UUID
        ) -> Bool {
            guard var session = codemapSessionsByRootEpoch[rootEpoch],
                  let removed = session.markerReadinessByFileID.removeValue(forKey: fileID)
            else { return false }
            let pathGeneration = session.pathGenerationsByRelativePath[
                removed.standardizedRelativePath
            ] ?? session.authority.ingressGeneration
            let change = WorkspaceCodemapMarkerReadinessChange(
                fileID: removed.fileID,
                standardizedRelativePath: removed.standardizedRelativePath,
                requestGeneration: pathGeneration,
                pathGeneration: pathGeneration,
                state: .unavailable
            )
            session.markerReadinessRevision &+= 1
            codemapSessionsByRootEpoch[rootEpoch] = session
            yieldCodemapMarkerReadiness(WorkspaceCodemapMarkerReadinessEvent(
                rootEpoch: rootEpoch,
                revision: session.markerReadinessRevision,
                changes: [change]
            ))
            return true
        }
    #endif

    private func acceptCodemapProjectionSnapshot(
        _ snapshot: WorkspaceCodemapProjectionSnapshot,
        authority: CodemapRootAuthority
    ) async -> WorkspaceCodemapProjectionSnapshotDisposition {
        guard codemapAuthorityIsCurrent(authority) else { return .superseded }
        guard !codemapProjectionCatalogIsFenced(rootEpoch: authority.rootEpoch) else { return .stale }
        guard let current = codemapProjectionCatalogShardAndToken(authority: authority),
              let session = codemapSessionsByRootEpoch[authority.rootEpoch],
              session.authority == authority
        else { return .stale }

        let generation: WorkspaceCodemapProjectionGeneration = switch snapshot {
        case let .segment(segment):
            segment.generation
        case let .seal(proof):
            proof.generation
        }
        guard generation.rootEpoch == authority.rootEpoch,
              generation.catalogToken == current.token,
              generation.schemaVersion == CodeMapSelectionGraphContribution.currentSchemaVersion,
              generation.policyVersion == CodeMapSelectionGraphContribution.currentPolicyVersion
        else { return .stale }

        switch snapshot {
        case let .segment(segment):
            for entry in segment.entries {
                guard let index = current.shard.projectionFileIndexByID[entry.identity.fileID] else {
                    return .stale
                }
                let file = current.shard.projectionFiles[index].file
                let language = current.shard.projectionFiles[index].language
                let pathGeneration = session.pathGenerationsByRelativePath[file.standardizedRelativePath]
                    ?? authority.ingressGeneration
                guard let expectedPipelineIdentity = try? SyntaxManager.shared.pipelineIdentity(
                    for: language,
                    decoderPolicy: .workspaceAutomaticV1
                ) else { return .stale }
                guard entry.identity.rootID == authority.rootEpoch.rootID,
                      entry.identity.rootLifetimeID == authority.rootEpoch.rootLifetimeID,
                      entry.identity.standardizedRootPath == authority.standardizedRootPath,
                      entry.identity.fileID == file.id,
                      entry.identity.standardizedRelativePath == file.standardizedRelativePath,
                      entry.identity.standardizedFullPath == file.standardizedFullPath,
                      rootStatesByID[authority.rootEpoch.rootID]?
                      .fileIDsByRelativePath[file.standardizedRelativePath] == file.id,
                      filesByID[file.id] == file,
                      entry.requestGeneration == pathGeneration,
                      entry.pathGeneration == pathGeneration,
                      entry.pipelineIdentity == expectedPipelineIdentity
                else { return .stale }
            }
        case let .seal(proof):
            guard proof.catalogCompletion.token == current.token,
                  proof.catalogCompletion.supportedCandidateCount
                  == UInt64(current.shard.projectionFiles.count)
            else { return .stale }
            let expectedFinalCursor = current.shard.projectionFiles.last.map {
                WorkspaceCodemapProjectionCatalogCursor(
                    standardizedRelativePath: $0.file.standardizedRelativePath,
                    fileID: $0.file.id
                )
            }
            guard proof.catalogCompletion.finalCursor == expectedFinalCursor else { return .stale }
            if proof.lastSegmentSequence == UInt64.max { return .stale }
        }

        let key = WorkspaceCodemapSelectionGraphRuntimeKey(generation: generation)
        var graphState = session.selectionGraph ?? CodemapSelectionGraphState(
            id: UUID(),
            graph: selectionGraphFactory.make(rootEpoch: authority.rootEpoch),
            desiredKey: nil,
            pendingSnapshot: nil,
            publishedSummary: nil,
            lastRebuildDisposition: nil,
            workerID: nil,
            workerTask: nil
        )
        if let desiredKey = graphState.desiredKey {
            if key.contributionGeneration < desiredKey.contributionGeneration {
                return .stale
            }
            if key.contributionGeneration == desiredKey.contributionGeneration,
               key != desiredKey
            {
                return .superseded
            }
        }
        graphState.desiredKey = key
        let graphStateID = graphState.id
        let graph = graphState.graph
        var installedSession = session
        installedSession.selectionGraph = graphState
        codemapSessionsByRootEpoch[authority.rootEpoch] = installedSession

        let disposition = await graph.applyProjectionSnapshot(snapshot)
        guard codemapAuthorityIsCurrent(authority),
              !codemapProjectionCatalogIsFenced(rootEpoch: authority.rootEpoch),
              let revalidated = codemapProjectionCatalogShardAndToken(authority: authority),
              revalidated.token == generation.catalogToken,
              let currentSession = codemapSessionsByRootEpoch[authority.rootEpoch],
              let currentGraphState = currentSession.selectionGraph,
              currentGraphState.id == graphStateID,
              currentGraphState.graph === graph,
              currentGraphState.desiredKey == key
        else { return .stale }

        let accounting = await graph.accounting()
        guard codemapAuthorityIsCurrent(authority),
              !codemapProjectionCatalogIsFenced(rootEpoch: authority.rootEpoch),
              var finalSession = codemapSessionsByRootEpoch[authority.rootEpoch],
              var finalGraphState = finalSession.selectionGraph,
              finalGraphState.id == graphStateID,
              finalGraphState.graph === graph,
              finalGraphState.desiredKey == key
        else { return .stale }
        finalGraphState.publishedSummary = accounting.publishedSummary
        finalSession.selectionGraph = finalGraphState
        codemapSessionsByRootEpoch[authority.rootEpoch] = finalSession

        if case .seal = snapshot,
           case .accepted = disposition,
           case .complete? = accounting.publishedSummary?.definitionUniverseCoverage
        {
            yieldCodemapSelectionGraphReadiness(rootEpoch: authority.rootEpoch)
        }
        return disposition
    }

    private func codemapManifestCandidate(
        rootEpoch: WorkspaceCodemapRootEpoch,
        relativePath: String,
        authority: CodemapRootAuthority
    ) -> WorkspaceCodemapManifestBindingCandidate? {
        guard rootEpoch == authority.rootEpoch,
              codemapAuthorityIsCurrent(authority),
              let state = rootStatesByID[rootEpoch.rootID],
              let session = codemapSessionsByRootEpoch[rootEpoch],
              session.authority == authority
        else { return nil }
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !StandardizedPath.containsNUL(relativePath),
              standardizedRelativePath == relativePath,
              standardizedRelativePath != "..",
              !standardizedRelativePath.hasPrefix("../"),
              let fileID = state.fileIDsByRelativePath[standardizedRelativePath],
              let file = filesByID[fileID],
              file.rootID == rootEpoch.rootID,
              file.standardizedRelativePath == standardizedRelativePath,
              let identity = WorkspaceCodemapArtifactBindingIdentity(
                  rootID: rootEpoch.rootID,
                  rootLifetimeID: rootEpoch.rootLifetimeID,
                  fileID: file.id,
                  standardizedRootPath: authority.standardizedRootPath,
                  standardizedRelativePath: standardizedRelativePath,
                  standardizedFullPath: file.standardizedFullPath
              )
        else { return nil }
        let pathGeneration = session.pathGenerationsByRelativePath[standardizedRelativePath]
            ?? authority.ingressGeneration
        guard pathGeneration > 0 else { return nil }
        return WorkspaceCodemapManifestBindingCandidate(
            identity: identity,
            requestGeneration: pathGeneration,
            pathGeneration: pathGeneration,
            ingressGeneration: authority.ingressGeneration
        )
    }

    private func readCodemapSource(
        identity: WorkspaceCodemapArtifactBindingIdentity,
        expectedFingerprint: GitBlobLStatFingerprint,
        maximumBytes: Int64,
        ownerID: UUID,
        authority: CodemapRootAuthority
    ) async throws -> ValidatedRawFileContentSnapshot {
        guard WorkspaceCodemapRootEpoch(
            rootID: identity.rootID,
            rootLifetimeID: identity.rootLifetimeID
        ) == authority.rootEpoch,
            codemapAuthorityIsCurrent(authority),
            let state = rootStatesByID[identity.rootID],
            state.root.standardizedFullPath == identity.standardizedRootPath,
            let fileID = state.fileIDsByRelativePath[identity.standardizedRelativePath],
            fileID == identity.fileID,
            let file = filesByID[fileID],
            file.standardizedFullPath == identity.standardizedFullPath
        else {
            throw WorkspaceCodemapBindingIntegrationRoutingError.routeDetached(authority.rootEpoch)
        }

        let snapshot = try await state.service.loadValidatedRawContent(
            ofRelativePath: identity.standardizedRelativePath,
            expectedFingerprint: FileContentFingerprint(
                deviceID: expectedFingerprint.device,
                fileNumber: expectedFingerprint.inode,
                byteSize: expectedFingerprint.size,
                modificationSeconds: expectedFingerprint.modificationSeconds,
                modificationNanoseconds: expectedFingerprint.modificationNanoseconds,
                statusChangeSeconds: expectedFingerprint.changeSeconds,
                statusChangeNanoseconds: expectedFingerprint.changeNanoseconds
            ),
            maximumBytes: maximumBytes,
            workloadClass: .codemap,
            schedulerOwnerID: ownerID
        )
        guard codemapAuthorityIsCurrent(authority),
              let currentState = rootStatesByID[identity.rootID],
              currentState.lifetimeID == identity.rootLifetimeID,
              currentState.root.standardizedFullPath == identity.standardizedRootPath,
              currentState.fileIDsByRelativePath[identity.standardizedRelativePath] == identity.fileID,
              let currentFile = filesByID[identity.fileID],
              currentFile.standardizedFullPath == identity.standardizedFullPath
        else {
            throw WorkspaceCodemapBindingIntegrationRoutingError.routeDetached(authority.rootEpoch)
        }
        return snapshot
    }

    private func codemapAuthorityMatchesLoadedRoot(
        _ authority: CodemapRootAuthority
    ) -> Bool {
        guard let state = rootStatesByID[authority.rootEpoch.rootID],
              state.lifetimeID == authority.rootEpoch.rootLifetimeID,
              state.root.standardizedFullPath == authority.standardizedRootPath
        else { return false }
        return true
    }

    private func codemapPreflightAuthorityIsCurrent(
        _ authority: CodemapRootAuthority
    ) -> Bool {
        codemapAuthorityMatchesLoadedRoot(authority)
            && codemapAuthorityGenerationsByRootEpoch[authority.rootEpoch]
            == authority.catalogGeneration
    }

    private func codemapAuthorityIsCurrent(
        _ authority: CodemapRootAuthority
    ) -> Bool {
        codemapSessionsByRootEpoch[authority.rootEpoch]?.authority == authority &&
            codemapAuthorityMatchesLoadedRoot(authority)
    }

    private func codemapDemandIsCurrent(
        _ ticket: WorkspaceCodemapArtifactDemandTicket
    ) -> Bool {
        guard ticket.requestGeneration > 0,
              ticket.catalogGeneration > 0,
              ticket.pathGeneration > 0,
              ticket.ingressGeneration > 0,
              ticket.requestGeneration == ticket.pathGeneration,
              let session = codemapSessionsByRootEpoch[ticket.rootEpoch],
              session.authority.catalogGeneration == ticket.catalogGeneration,
              session.authority.ingressGeneration == ticket.ingressGeneration,
              codemapAuthorityIsCurrent(session.authority),
              let record = session.demandsByFileID[ticket.fileID],
              codemapTicketsShareDemand(record.ticket, ticket),
              (
                  session.pathGenerationsByRelativePath[record.identity.standardizedRelativePath]
                      ?? session.authority.ingressGeneration
              ) == ticket.pathGeneration,
              let state = rootStatesByID[ticket.rootEpoch.rootID],
              state.fileIDsByRelativePath[record.identity.standardizedRelativePath] == ticket.fileID,
              filesByID[ticket.fileID]?.rootID == ticket.rootEpoch.rootID
        else { return false }
        return true
    }

    private func retainedCodemapTicket(
        for ticket: WorkspaceCodemapArtifactDemandTicket
    ) -> WorkspaceCodemapArtifactDemandTicket {
        WorkspaceCodemapArtifactDemandTicket(
            retainID: UUID(),
            requestID: ticket.requestID,
            rootEpoch: ticket.rootEpoch,
            fileID: ticket.fileID,
            requestGeneration: ticket.requestGeneration,
            catalogGeneration: ticket.catalogGeneration,
            pathGeneration: ticket.pathGeneration,
            ingressGeneration: ticket.ingressGeneration
        )
    }

    private func codemapTicketsShareDemand(
        _ lhs: WorkspaceCodemapArtifactDemandTicket,
        _ rhs: WorkspaceCodemapArtifactDemandTicket
    ) -> Bool {
        lhs.requestID == rhs.requestID &&
            lhs.rootEpoch == rhs.rootEpoch &&
            lhs.fileID == rhs.fileID &&
            lhs.requestGeneration == rhs.requestGeneration &&
            lhs.catalogGeneration == rhs.catalogGeneration &&
            lhs.pathGeneration == rhs.pathGeneration &&
            lhs.ingressGeneration == rhs.ingressGeneration
    }

    private func codemapDemandResult(
        _ result: WorkspaceCodemapArtifactDemandResult,
        for ticket: WorkspaceCodemapArtifactDemandTicket
    ) -> WorkspaceCodemapArtifactDemandResult {
        switch result {
        case .unavailable:
            result
        case .pending:
            .pending(ticket)
        case let .ready(ready):
            .ready(WorkspaceCodemapArtifactDemandReady(
                ticket: ticket,
                identity: ready.identity,
                snapshot: ready.snapshot,
                handle: ready.handle
            ))
        }
    }

    private func codemapPresentationReadyMatches(
        _ ready: WorkspaceCodemapArtifactDemandReady,
        demandRecord: CodemapDemandRecord,
        entry: WorkspaceCodemapFrozenPresentationEntry
    ) -> Bool {
        let ticket = entry.ticket
        return codemapTicketsShareDemand(demandRecord.ticket, ticket) &&
            codemapTicketsShareDemand(ready.ticket, ticket) &&
            ready.identity == demandRecord.identity &&
            ready.identity.rootID == ticket.rootEpoch.rootID &&
            ready.identity.rootLifetimeID == ticket.rootEpoch.rootLifetimeID &&
            ready.identity.fileID == ticket.fileID &&
            ready.identity.standardizedRelativePath ==
            entry.logicalPath.standardizedRelativePath &&
            ready.snapshot.rootEpoch == ticket.rootEpoch &&
            ready.snapshot.fileID == ticket.fileID &&
            ready.snapshot.standardizedRelativePath ==
            entry.logicalPath.standardizedRelativePath &&
            ready.snapshot.requestGeneration == ticket.requestGeneration &&
            ready.snapshot.artifactKey == entry.artifactKey &&
            ready.snapshot.outcome == entry.outcome
    }

    private func codemapUnavailableIsStable(
        _ reason: WorkspaceCodemapArtifactDemandUnavailableReason
    ) -> Bool {
        switch reason {
        case .rootNotLoaded, .fileNotCataloged, .unsupportedFileType:
            true
        case let .gitTerminal(reason):
            reason != .releasedRootEpoch
        case let .demandUnavailable(reason):
            reason != .transient
        case .gitTransient, .busy, .rejected, .routeConflict, .registrationFailed,
             .runtimeFailure, .staleCurrentness, .cancelled:
            false
        }
    }

    private func codemapPathIsFenced(
        rootEpoch: WorkspaceCodemapRootEpoch,
        relativePath: String
    ) -> Bool {
        let path = StandardizedPath.relative(relativePath)
        return codemapPathFenceTokensByID.values.contains {
            $0.rootEpoch == rootEpoch && $0.standardizedRelativePaths.contains(path)
        }
    }

    private func standardizedCodemapInvalidationCommand(
        _ command: CodemapInvalidationCommand
    ) -> CodemapInvalidationCommand? {
        switch command {
        case let .modified(paths):
            let safe = Set(paths.map(StandardizedPath.relative).filter { !$0.isEmpty })
            return safe.isEmpty ? nil : .modified(safe)
        case let .deleted(paths):
            let safe = Set(paths.map(StandardizedPath.relative).filter { !$0.isEmpty })
            return safe.isEmpty ? nil : .deleted(safe)
        case let .renamed(from, to):
            let oldPath = StandardizedPath.relative(from)
            let newPath = StandardizedPath.relative(to)
            guard !oldPath.isEmpty, !newPath.isEmpty else { return nil }
            return .renamed(from: oldPath, to: newPath)
        case .watcherGap, .checkout, .repositoryAuthority, .catalogAdvanced, .unload:
            return command
        }
    }

    private func codemapPaths(
        in commands: [CodemapInvalidationCommand]
    ) -> Set<String> {
        var paths = Set<String>()
        for command in commands {
            switch command {
            case let .modified(commandPaths), let .deleted(commandPaths):
                paths.formUnion(commandPaths)
            case let .renamed(from, to):
                paths.insert(from)
                paths.insert(to)
            case .watcherGap, .checkout, .repositoryAuthority, .catalogAdvanced, .unload:
                break
            }
        }
        return paths
    }

    private func fenceCodemapPaths(
        rootID: UUID,
        commands rawCommands: [CodemapInvalidationCommand]
    ) async -> CodemapPathFenceToken? {
        let commands = rawCommands.compactMap(standardizedCodemapInvalidationCommand)
        let paths = codemapPaths(in: commands)
        guard !paths.isEmpty,
              let state = rootStatesByID[rootID]
        else { return nil }
        let rootEpoch = WorkspaceCodemapRootEpoch(
            rootID: rootID,
            rootLifetimeID: state.lifetimeID
        )

        guard await waitForCodemapRootMutationFenceIfNeeded(rootEpoch: rootEpoch) else {
            return nil
        }

        if let cleanup = codemapCleanupFlightsByRootID[rootID] {
            await cleanup.task.value
            return nil
        }
        if let existing = codemapPathInvalidationFlightsByRootEpoch[rootEpoch] {
            await existing.task.value
            guard rootStatesByID[rootID]?.lifetimeID == rootEpoch.rootLifetimeID,
                  codemapSessionsByRootEpoch[rootEpoch] != nil
            else { return nil }
            return await fenceCodemapPaths(rootID: rootID, commands: commands)
        }
        advanceCodemapProjectionInvalidationGeneration(rootEpoch: rootEpoch)
        _ = cancelCodemapProjectionPreloadLaunchForInvalidation(
            rootEpoch: rootEpoch
        )

        let token = CodemapPathFenceToken(
            id: UUID(),
            rootEpoch: rootEpoch,
            standardizedRelativePaths: paths,
            shouldRescheduleProjectionPreload: true
        )
        codemapPathFenceTokensByID[token.id] = token

        guard var session = codemapSessionsByRootEpoch[rootEpoch] else {
            return token
        }

        let removedMarkerReadiness = session.markerReadinessByFileID.values
            .filter { paths.contains($0.standardizedRelativePath) }
            .map {
                WorkspaceCodemapMarkerReadinessChange(
                    fileID: $0.fileID,
                    standardizedRelativePath: $0.standardizedRelativePath,
                    requestGeneration: $0.requestGeneration,
                    pathGeneration: $0.pathGeneration,
                    state: .unavailable
                )
            }
            .sorted {
                if $0.standardizedRelativePath != $1.standardizedRelativePath {
                    return $0.standardizedRelativePath < $1.standardizedRelativePath
                }
                return $0.fileID.uuidString < $1.fileID.uuidString
            }
        for change in removedMarkerReadiness {
            session.markerReadinessByFileID.removeValue(forKey: change.fileID)
        }
        let markerReadinessEvent: WorkspaceCodemapMarkerReadinessEvent? = if removedMarkerReadiness.isEmpty {
            nil
        } else {
            WorkspaceCodemapMarkerReadinessEvent(
                rootEpoch: rootEpoch,
                revision: session.markerReadinessRevision &+ 1,
                changes: removedMarkerReadiness
            )
        }
        if markerReadinessEvent != nil {
            session.markerReadinessRevision &+= 1
        }

        var affectedRecords: [CodemapDemandRecord] = []
        for (fileID, record) in session.demandsByFileID
            where paths.contains(record.identity.standardizedRelativePath)
        {
            affectedRecords.append(record)
            session.demandsByFileID.removeValue(forKey: fileID)
            session.bundlesByRequestID.removeValue(forKey: record.ticket.requestID)?.close()
        }
        let affectedRequestIDs = Set(affectedRecords.map(\.ticket.requestID))
        session.presentationRecordsByID = session.presentationRecordsByID.filter {
            $0.value.requestIDs.isDisjoint(with: affectedRequestIDs)
        }
        for record in affectedRecords {
            record.task?.cancel()
        }
        for path in paths {
            let current = session.pathGenerationsByRelativePath[path] ?? session.authority.ingressGeneration
            session.pathGenerationsByRelativePath[path] = current == .max ? .max : current + 1
        }

        let graphPublicationTask = session.graphPublicationFlight?.task
        graphPublicationTask?.cancel()
        session.graphPublicationFlight = nil
        let projectionRecoveryObserverTask = session.projectionRecoveryObserver?.task
        projectionRecoveryObserverTask?.cancel()
        session.projectionRecoveryObserver = nil
        let graph = session.selectionGraph?.graph
        let graphWorkerTask = session.selectionGraph?.workerTask
        graphWorkerTask?.cancel()
        if let graph {
            session.selectionGraph = CodemapSelectionGraphState(
                id: UUID(),
                graph: graph,
                desiredKey: nil,
                pendingSnapshot: nil,
                publishedSummary: nil,
                lastRebuildDisposition: nil,
                workerID: nil,
                workerTask: nil
            )
        }
        codemapSessionsByRootEpoch[rootEpoch] = session
        if let markerReadinessEvent {
            yieldCodemapMarkerReadiness(markerReadinessEvent)
        }

        let flightID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await performCodemapPathInvalidation(
                flightID: flightID,
                authority: session.authority,
                engine: session.engine,
                setupTask: session.setupTask,
                graphPublicationTask: graphPublicationTask,
                projectionRecoveryObserverTask: projectionRecoveryObserverTask,
                graph: graph,
                graphWorkerTask: graphWorkerTask,
                commands: commands
            )
        }
        let flight = CodemapPathInvalidationFlight(
            id: flightID,
            rootEpoch: rootEpoch,
            task: task
        )
        codemapPathInvalidationFlightsByRootEpoch[rootEpoch] = flight
        await task.value
        return token
    }

    private func performCodemapPathInvalidation(
        flightID: UUID,
        authority: CodemapRootAuthority,
        engine: WorkspaceCodemapBindingEngine?,
        setupTask: Task<CodemapSetupDisposition, Never>?,
        graphPublicationTask: Task<Void, Never>?,
        projectionRecoveryObserverTask: Task<Void, Never>?,
        graph: WorkspaceCodemapSelectionGraph?,
        graphWorkerTask: Task<Void, Never>?,
        commands: [CodemapInvalidationCommand]
    ) async {
        if let graphPublicationTask {
            await graphPublicationTask.value
        }
        if let projectionRecoveryObserverTask {
            await projectionRecoveryObserverTask.value
        }
        if let graph {
            _ = await graph.fenceContributionsForPathInvalidation(
                rootEpoch: authority.rootEpoch
            )
        }
        if let graphWorkerTask {
            await graphWorkerTask.value
        }
        if let setupTask {
            _ = await setupTask.value
        }
        let resolvedEngine = engine ?? codemapSessionsByRootEpoch[authority.rootEpoch]?.engine
        if let resolvedEngine {
            await applyCodemapInvalidationCommands(
                commands,
                rootEpoch: authority.rootEpoch,
                engine: resolvedEngine
            )
        }
        let bundle = await resolvedEngine?.freeze(rootEpoch: authority.rootEpoch)
        let snapshot = try? bundle?.graphSnapshot()
        await finishCodemapPathInvalidation(
            flightID: flightID,
            authority: authority,
            snapshot: snapshot
        )
        bundle?.close()
    }

    private func finishCodemapPathInvalidation(
        flightID: UUID,
        authority: CodemapRootAuthority,
        snapshot: WorkspaceCodemapLiveGraphSnapshot?
    ) async {
        guard codemapPathInvalidationFlightsByRootEpoch[authority.rootEpoch]?.id == flightID else {
            return
        }
        defer {
            if codemapPathInvalidationFlightsByRootEpoch[authority.rootEpoch]?.id == flightID {
                codemapPathInvalidationFlightsByRootEpoch.removeValue(forKey: authority.rootEpoch)
                scheduleDirtyCodemapGraphPublicationIfUnfenced(
                    rootEpoch: authority.rootEpoch
                )
                schedulePendingCodemapProjectionPreloadIfFullyUnfenced(
                    rootEpoch: authority.rootEpoch
                )
            }
        }
        guard codemapAuthorityIsCurrent(authority) else { return }
        if let snapshot,
           let acceptedSnapshot = codemapPathInvalidationGraphSnapshot(
               snapshot,
               authority: authority
           )
        {
            await enqueueCodemapGraphSnapshot(acceptedSnapshot)
        }
    }

    private func codemapPathInvalidationGraphSnapshot(
        _ snapshot: WorkspaceCodemapLiveGraphSnapshot,
        authority: CodemapRootAuthority
    ) -> WorkspaceCodemapLiveGraphSnapshot? {
        guard snapshot.rootEpoch == authority.rootEpoch,
              snapshot.catalogGeneration == authority.catalogGeneration,
              let session = codemapSessionsByRootEpoch[authority.rootEpoch]
        else { return nil }
        let retainedBindings = snapshot.bindings.filter { binding in
            guard let record = session.demandsByFileID[binding.identity.fileID],
                  case let .ready(ready) = record.result,
                  case let .resolved(completion) = binding.availability
            else { return false }
            return ready.identity == binding.identity &&
                ready.ticket == record.ticket &&
                ready.snapshot.artifactKey == completion.artifactKey
        }
        guard let firstBinding = retainedBindings.first,
              let firstRecord = session.demandsByFileID[firstBinding.identity.fileID],
              case let .ready(triggeringReady) = firstRecord.result
        else { return nil }
        let filtered = WorkspaceCodemapLiveGraphSnapshot(
            rootEpoch: snapshot.rootEpoch,
            catalogGeneration: snapshot.catalogGeneration,
            repositoryAuthority: snapshot.repositoryAuthority,
            contributionGeneration: snapshot.contributionGeneration,
            bindings: retainedBindings
        )
        return codemapGraphSnapshotIsAccepted(
            filtered,
            triggeringReady: triggeringReady
        ) ? filtered : nil
    }

    private func releaseCodemapPathFence(
        _ token: CodemapPathFenceToken?,
        didCommitMutation: Bool = true
    ) {
        guard let token else { return }
        codemapPathFenceTokensByID.removeValue(forKey: token.id)
        scheduleDirtyCodemapGraphPublicationIfUnfenced(rootEpoch: token.rootEpoch)
        // The fence itself advanced projection/path authority and cancelled old work. A failed
        // disk mutation still needs one restoration preload, while committed work needs the same
        // reschedule against the new public catalog.
        if token.shouldRescheduleProjectionPreload {
            codemapProjectionPreloadReschedulePendingRootEpochs.insert(token.rootEpoch)
        }
        _ = didCommitMutation
        schedulePendingCodemapProjectionPreloadIfFullyUnfenced(rootEpoch: token.rootEpoch)
    }

    private func cancelCodemapProjectionPreloadLaunchForInvalidation(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> Task<Void, Never>? {
        codemapProjectionPreloadRetriesByRootEpoch.removeValue(forKey: rootEpoch)?.task.cancel()
        guard let launch = codemapProjectionPreloadLaunchesByRootEpoch.removeValue(
            forKey: rootEpoch
        ) else { return nil }
        launch.task?.cancel()
        recordCodemapProjectionPreloadStoreEvent(
            .superseded,
            rootEpoch: rootEpoch,
            phase: .superseded
        )
        return launch.task
    }

    private func scheduleDirtyCodemapGraphPublicationIfUnfenced(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) {
        guard codemapPathInvalidationFlightsByRootEpoch[rootEpoch] == nil,
              !codemapPathFenceTokensByID.values.contains(where: {
                  $0.rootEpoch == rootEpoch
              }),
              var session = codemapSessionsByRootEpoch[rootEpoch],
              session.graphSnapshotDirtyDuringPathInvalidation
        else { return }
        session.graphSnapshotDirtyDuringPathInvalidation = false
        codemapSessionsByRootEpoch[rootEpoch] = session
        signalCodemapGraphPublication(rootEpoch: rootEpoch)
    }

    @discardableResult
    private func detachCodemapSession(
        rootEpoch: WorkspaceCodemapRootEpoch,
        invalidationCommands: [CodemapInvalidationCommand] = [.catalogAdvanced],
        graphInvalidationReason: WorkspaceCodemapSelectionGraphRuntimeExternalUnavailableReason =
            .authorityRevoked
    ) -> CodemapCleanupFlight? {
        let launch = codemapProjectionPreloadLaunchesByRootEpoch.removeValue(forKey: rootEpoch)
        launch?.task?.cancel()
        if launch != nil {
            recordCodemapProjectionPreloadStoreEvent(
                .cancelled,
                rootEpoch: rootEpoch,
                phase: .cancelled
            )
        }
        let eligibilityFlight = codemapEligibilityFlightsByRootEpoch.removeValue(forKey: rootEpoch)
        eligibilityFlight?.task.cancel()
        let preloadRetry = codemapProjectionPreloadRetriesByRootEpoch.removeValue(forKey: rootEpoch)
        preloadRetry?.task.cancel()
        let completedEligibility = codemapCompletedEligibilityByRootEpoch.removeValue(
            forKey: rootEpoch
        )
        let session = codemapSessionsByRootEpoch.removeValue(forKey: rootEpoch)
        if let session, !session.markerReadinessByFileID.isEmpty {
            let changes = session.markerReadinessByFileID.values.map {
                WorkspaceCodemapMarkerReadinessChange(
                    fileID: $0.fileID,
                    standardizedRelativePath: $0.standardizedRelativePath,
                    requestGeneration: $0.requestGeneration,
                    pathGeneration: $0.pathGeneration,
                    state: .unavailable
                )
            }.sorted {
                if $0.standardizedRelativePath != $1.standardizedRelativePath {
                    return $0.standardizedRelativePath < $1.standardizedRelativePath
                }
                return $0.fileID.uuidString < $1.fileID.uuidString
            }
            yieldCodemapMarkerReadiness(WorkspaceCodemapMarkerReadinessEvent(
                rootEpoch: rootEpoch,
                revision: session.markerReadinessRevision &+ 1,
                changes: changes
            ))
        }
        let projectionDemandIDs = codemapProjectionDemandsByID.compactMap { id, record in
            record.ticket.rootEpoch == rootEpoch ? id : nil
        }
        let projectionDemands = projectionDemandIDs.compactMap {
            codemapProjectionDemandsByID.removeValue(forKey: $0)
        }
        for record in projectionDemands {
            record.expiryTask?.cancel()
        }
        guard session != nil || launch != nil || eligibilityFlight != nil || completedEligibility != nil
            || preloadRetry != nil || !projectionDemands.isEmpty
        else {
            return codemapCleanupFlightsByRootID[rootEpoch.rootID]
        }
        advanceCodemapProjectionInvalidationGeneration(rootEpoch: rootEpoch)
        guard let authority = session?.authority ?? launch?.authority ?? eligibilityFlight?.authority
            ?? completedEligibility?.authority ?? preloadRetry?.authority
        else {
            return codemapCleanupFlightsByRootID[rootEpoch.rootID]
        }
        let authorityGeneration = codemapAuthorityGenerationsByRootEpoch[rootEpoch]
            ?? authority.ingressGeneration
        codemapAuthorityGenerationsByRootEpoch[rootEpoch] = authorityGeneration == .max
            ? 0
            : authorityGeneration + 1
        session?.setupTask?.cancel()
        session?.graphPublicationFlight?.task?.cancel()
        session?.projectionRecoveryObserver?.task?.cancel()
        session?.selectionGraph?.workerTask?.cancel()
        let demandRecords = session.map { Array($0.demandsByFileID.values) } ?? []
        for record in demandRecords {
            record.task?.cancel()
        }
        for bundle in session.map({ Array($0.bundlesByRequestID.values) }) ?? [] {
            bundle.close()
        }
        let predecessorTasks = codemapPathInvalidationFlightsByRootEpoch[rootEpoch]
            .map { [$0.task] } ?? []
        let detached = DetachedCodemapSession(
            authority: authority,
            registry: session?.runtime?.bindingIntegrationRegistry,
            routeToken: session?.routeToken,
            engine: session?.engine,
            owners: demandRecords.map(\.owner),
            setupTask: session?.setupTask,
            demandTasks: demandRecords.compactMap(\.task),
            projectionDemands: projectionDemands,
            graphPublicationTask: session?.graphPublicationFlight?.task,
            projectionRecoveryObserverTask: session?.projectionRecoveryObserver?.task,
            selectionGraph: session?.selectionGraph?.graph,
            graphWorkerTask: session?.selectionGraph?.workerTask,
            preloadLaunchTask: launch?.task,
            eligibilityTask: eligibilityFlight?.task,
            preloadRetryTask: preloadRetry?.task,
            predecessorTasks: predecessorTasks,
            invalidationCommands: invalidationCommands.compactMap(
                standardizedCodemapInvalidationCommand
            ),
            graphInvalidationReason: graphInvalidationReason
        )
        return startCodemapCleanup(detached)
    }

    private func startCodemapCleanup(
        _ detached: DetachedCodemapSession
    ) -> CodemapCleanupFlight {
        if let existing = codemapCleanupFlightsByRootID[detached.authority.rootEpoch.rootID] {
            return existing
        }
        let cleanupID = UUID()
        let task = Task { [weak self] in
            for predecessorTask in detached.predecessorTasks {
                await predecessorTask.value
            }
            if let graphPublicationTask = detached.graphPublicationTask {
                await graphPublicationTask.value
            }
            if let projectionRecoveryObserverTask = detached.projectionRecoveryObserverTask {
                await projectionRecoveryObserverTask.value
            }
            if let selectionGraph = detached.selectionGraph {
                _ = await selectionGraph.invalidateCurrentness(
                    rootEpoch: detached.authority.rootEpoch,
                    reason: detached.graphInvalidationReason
                )
            }
            if let registry = detached.registry, let routeToken = detached.routeToken {
                _ = await registry.unregister(routeToken)
            }
            if let engine = detached.engine {
                await self?.applyCodemapInvalidationCommands(
                    detached.invalidationCommands,
                    rootEpoch: detached.authority.rootEpoch,
                    engine: engine
                )
                for owner in detached.owners {
                    _ = await engine.cancel(owner: owner)
                }
                for projectionDemand in detached.projectionDemands {
                    await projectionDemand.engine.releaseProjectionDemand(projectionDemand.ticket)
                }
                if detached.invalidationCommands.contains(where: {
                    if case .unload = $0 { true } else { false }
                }) {
                    await engine.unloadRoot(rootEpoch: detached.authority.rootEpoch)
                }
            }
            if let setupTask = detached.setupTask {
                _ = await setupTask.value
            }
            if let preloadLaunchTask = detached.preloadLaunchTask {
                await preloadLaunchTask.value
            }
            if let eligibilityTask = detached.eligibilityTask {
                _ = await eligibilityTask.value
            }
            if let preloadRetryTask = detached.preloadRetryTask {
                await preloadRetryTask.value
            }
            for demandTask in detached.demandTasks {
                await demandTask.value
            }
            if let graphWorkerTask = detached.graphWorkerTask {
                await graphWorkerTask.value
            }
            await self?.finishCodemapCleanup(
                rootID: detached.authority.rootEpoch.rootID,
                cleanupID: cleanupID
            )
        }
        let flight = CodemapCleanupFlight(
            id: cleanupID,
            rootEpoch: detached.authority.rootEpoch,
            task: task
        )
        codemapCleanupFlightsByRootID[detached.authority.rootEpoch.rootID] = flight
        return flight
    }

    private func applyCodemapInvalidationCommands(
        _ commands: [CodemapInvalidationCommand],
        rootEpoch: WorkspaceCodemapRootEpoch,
        engine: WorkspaceCodemapBindingEngine
    ) async {
        for command in commands {
            switch command {
            case let .modified(paths):
                _ = await engine.invalidateModified(
                    rootEpoch: rootEpoch,
                    standardizedRelativePaths: paths
                )
            case let .deleted(paths):
                _ = await engine.invalidateDeleted(
                    rootEpoch: rootEpoch,
                    standardizedRelativePaths: paths
                )
            case let .renamed(from, to):
                _ = await engine.invalidateRenamed(rootEpoch: rootEpoch, from: from, to: to)
            case .watcherGap:
                _ = await engine.invalidateWatcherGap(rootEpoch: rootEpoch)
            case .checkout:
                _ = await engine.invalidateCheckout(rootEpoch: rootEpoch)
            case .repositoryAuthority:
                _ = await engine.invalidateRepositoryAuthority(rootEpoch: rootEpoch)
            case .catalogAdvanced:
                _ = await engine.invalidateCatalog(rootEpoch: rootEpoch)
            case .unload:
                break
            }
        }
    }

    private func finishCodemapCleanup(rootID: UUID, cleanupID: UUID) {
        guard codemapCleanupFlightsByRootID[rootID]?.id == cleanupID else { return }
        let rootEpoch = codemapCleanupFlightsByRootID[rootID]?.rootEpoch
        codemapCleanupFlightsByRootID.removeValue(forKey: rootID)
        if let rootEpoch {
            schedulePendingCodemapProjectionPreloadIfFullyUnfenced(rootEpoch: rootEpoch)
        }
    }

    private func awaitCodemapCleanupFlights(rootIDs: Set<UUID>) async {
        let flights = rootIDs.compactMap { codemapCleanupFlightsByRootID[$0] }
        for flight in flights {
            await flight.task.value
        }
    }

    private func beginCodemapRootMutationFence(
        rootID: UUID,
        command: CodemapInvalidationCommand
    ) async -> CodemapRootMutationFenceToken? {
        guard let initialState = rootStatesByID[rootID] else { return nil }
        let rootEpoch = WorkspaceCodemapRootEpoch(
            rootID: rootID,
            rootLifetimeID: initialState.lifetimeID
        )
        guard await waitForCodemapRootMutationFenceIfNeeded(rootEpoch: rootEpoch) else {
            return nil
        }

        let token = CodemapRootMutationFenceToken(id: UUID(), rootEpoch: rootEpoch)
        codemapRootMutationFenceTokensByRootEpoch[rootEpoch] = token
        var didTransferFenceOwnership = false
        defer {
            if !didTransferFenceOwnership {
                finishCodemapRootMutationFence(token, didCommitMutation: false)
            }
        }
        while codemapPathInvalidationFlightsByRootEpoch[rootEpoch] != nil ||
            codemapPathFenceTokensByID.values.contains(where: { $0.rootEpoch == rootEpoch })
        {
            await Task.yield()
            guard !Task.isCancelled,
                  rootStatesByID[rootID]?.lifetimeID == rootEpoch.rootLifetimeID
            else {
                return nil
            }
        }
        await fenceCodemapRootAuthority(rootIDs: [rootID], command: command)
        guard !Task.isCancelled,
              rootStatesByID[rootID]?.lifetimeID == rootEpoch.rootLifetimeID
        else {
            return nil
        }
        didTransferFenceOwnership = true
        return token
    }

    private func waitForCodemapRootMutationFenceIfNeeded(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) async -> Bool {
        while codemapRootMutationFenceTokensByRootEpoch[rootEpoch] != nil {
            let waiterID = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if codemapRootMutationFenceTokensByRootEpoch[rootEpoch] == nil || Task.isCancelled {
                        continuation.resume()
                    } else {
                        codemapRootMutationFenceWaitersByRootEpoch[rootEpoch, default: [:]][waiterID] = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancelCodemapRootMutationFenceWaiter(rootEpoch: rootEpoch, waiterID: waiterID) }
            }
            guard !Task.isCancelled,
                  rootStatesByID[rootEpoch.rootID]?.lifetimeID == rootEpoch.rootLifetimeID
            else { return false }
        }
        return true
    }

    private func cancelCodemapRootMutationFenceWaiter(
        rootEpoch: WorkspaceCodemapRootEpoch,
        waiterID: UUID
    ) {
        guard let continuation = codemapRootMutationFenceWaitersByRootEpoch[rootEpoch]?
            .removeValue(forKey: waiterID)
        else { return }
        if codemapRootMutationFenceWaitersByRootEpoch[rootEpoch]?.isEmpty == true {
            codemapRootMutationFenceWaitersByRootEpoch.removeValue(forKey: rootEpoch)
        }
        continuation.resume()
    }

    private func finishCodemapRootMutationFence(
        _ token: CodemapRootMutationFenceToken?,
        didCommitMutation: Bool
    ) {
        guard let token,
              codemapRootMutationFenceTokensByRootEpoch[token.rootEpoch] == token
        else { return }
        codemapRootMutationFenceTokensByRootEpoch.removeValue(forKey: token.rootEpoch)
        // Root fencing detaches the previous authority before the mutation begins. Restore
        // preload even when the disk operation fails; successful mutations observe the same
        // post-publication scheduling point.
        if rootStatesByID[token.rootEpoch.rootID]?.lifetimeID == token.rootEpoch.rootLifetimeID {
            codemapProjectionPreloadReschedulePendingRootEpochs.insert(token.rootEpoch)
        }
        _ = didCommitMutation
        let waiters = codemapRootMutationFenceWaitersByRootEpoch.removeValue(forKey: token.rootEpoch) ?? [:]
        for continuation in waiters.values {
            continuation.resume()
        }
        schedulePendingCodemapProjectionPreloadIfFullyUnfenced(rootEpoch: token.rootEpoch)
    }

    private func schedulePendingCodemapProjectionPreloadIfFullyUnfenced(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) {
        guard codemapProjectionPreloadReschedulePendingRootEpochs.contains(rootEpoch),
              codemapRootMutationFenceTokensByRootEpoch[rootEpoch] == nil,
              codemapPathInvalidationFlightsByRootEpoch[rootEpoch] == nil,
              !codemapPathFenceTokensByID.values.contains(where: { $0.rootEpoch == rootEpoch }),
              codemapCleanupFlightsByRootID[rootEpoch.rootID] == nil,
              rootStatesByID[rootEpoch.rootID]?.lifetimeID == rootEpoch.rootLifetimeID
        else { return }
        codemapProjectionPreloadReschedulePendingRootEpochs.remove(rootEpoch)
        scheduleCodemapProjectionPreloadAfterRootReady(rootEpoch: rootEpoch)
    }

    private func fenceCodemapRootAuthority(
        rootIDs: [UUID],
        command: CodemapInvalidationCommand
    ) async {
        let loadedRootIDs = Set(rootIDs.filter { rootStatesByID[$0] != nil })
        guard !loadedRootIDs.isEmpty else { return }
        let affectedRootEpochs = Set(codemapSessionsByRootEpoch.keys)
            .union(codemapProjectionPreloadLaunchesByRootEpoch.keys)
            .union(codemapEligibilityFlightsByRootEpoch.keys)
            .union(codemapCompletedEligibilityByRootEpoch.keys)
            .union(codemapProjectionPreloadRetriesByRootEpoch.keys)
            .union(codemapAuthorityGenerationsByRootEpoch.keys)
            .filter { loadedRootIDs.contains($0.rootID) }
        for rootEpoch in affectedRootEpochs {
            let previousGeneration = codemapAuthorityGenerationsByRootEpoch[rootEpoch]
            let cleanup = detachCodemapSession(
                rootEpoch: rootEpoch,
                invalidationCommands: [command]
            )
            if cleanup == nil,
               let previousGeneration,
               codemapAuthorityGenerationsByRootEpoch[rootEpoch] == previousGeneration
            {
                advanceCodemapProjectionInvalidationGeneration(rootEpoch: rootEpoch)
                codemapAuthorityGenerationsByRootEpoch[rootEpoch] = previousGeneration == .max
                    ? 0
                    : previousGeneration + 1
            }
        }
        await awaitCodemapCleanupFlights(rootIDs: loadedRootIDs)
    }

    func fenceCodemapAuthorityForCheckoutMutation(rootIDs: [UUID]) async {
        await fenceCodemapRootAuthority(rootIDs: rootIDs, command: .checkout)
    }

    func fenceCodemapAuthorityForRepositoryAuthorityMutation(rootIDs: [UUID]) async {
        await fenceCodemapRootAuthority(rootIDs: rootIDs, command: .repositoryAuthority)
    }

    @discardableResult
    func createFile(
        rootID: UUID,
        relativePath: String,
        content: String,
        validating rootScope: WorkspaceLookupRootScope? = nil
    ) async throws -> WorkspaceFileCatalogMaterializationResult {
        if let rootScope {
            guard rootScopeAvailability(rootScope) == .available,
                  rootsForPathLookup(scope: rootScope).contains(where: { $0.id == rootID })
            else {
                throw WorkspaceFileContextStoreError.rootNotLoaded(rootID)
            }
        }
        let state = try state(for: rootID)
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        guard let codemapFence = await beginCodemapRootMutationFence(
            rootID: rootID,
            command: .catalogAdvanced
        ) else {
            throw WorkspaceFileContextStoreError.rootNotLoaded(rootID)
        }
        var didCommitCatalogMutation = false
        defer {
            finishCodemapRootMutationFence(
                codemapFence,
                didCommitMutation: didCommitCatalogMutation
            )
        }
        try await state.service.createFile(atRelativePath: standardizedRelativePath, content: content)
        let result = try await materializeCatalogFileAfterDiskWrite(
            rootID: rootID,
            relativePath: standardizedRelativePath
        )
        await awaitCodemapCleanupFlights(rootIDs: [rootID])
        if case .materialized = result {
            didCommitCatalogMutation = true
        }
        return result
    }

    @discardableResult
    func editFile(rootID: UUID, relativePath: String, newContent: String) async throws -> WorkspaceFileCatalogMaterializationResult? {
        let state = try state(for: rootID)
        let expectedLifetimeID = state.lifetimeID
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        let codemapFence = await fenceCodemapPaths(
            rootID: rootID,
            commands: [.modified([standardizedRelativePath])]
        )
        var didCommitCodemapMutation = false
        defer {
            releaseCodemapPathFence(
                codemapFence,
                didCommitMutation: didCommitCodemapMutation
            )
        }
        let deferredPublicationToken: FileSystemDeferredEditPublicationToken
        do {
            guard let token = try await state.service.editFile(
                atRelativePath: standardizedRelativePath,
                newContent: newContent,
                modificationPublicationPolicy: .deferSyntheticModificationToSuccessfulCaller
            ) else {
                throw WorkspaceFileContextStoreError.catalogMaterializationFailed(
                    "store-owned edit completed without a deferred modification publication token"
                )
            }
            deferredPublicationToken = token
            didCommitCodemapMutation = true
        } catch FileSystemError.fileNotFound {
            didCommitCodemapMutation = withCodemapPathLocalCatalogMutation(rootID: rootID) {
                pruneCatalogFileMissingOnDisk(
                    rootID: rootID,
                    relativePath: standardizedRelativePath,
                    publishDelta: true
                )
            }
            throw FileSystemError.fileNotFound
        }

        do {
            #if DEBUG
                if let storeEditDeferredPublicationDidRegisterHandler {
                    await storeEditDeferredPublicationDidRegisterHandler(rootID, standardizedRelativePath)
                }
            #endif
            try Task.checkCancellation()
            guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: expectedLifetimeID) else {
                throw WorkspaceFileContextStoreError.rootNotLoaded(rootID)
            }

            let result: WorkspaceFileCatalogMaterializationResult?
            let publishedCanonicalModification: Bool
            if let file = file(rootID: rootID, relativePath: standardizedRelativePath) {
                invalidateSearchContent(file)
                publishedCanonicalModification = isDiscoverableFileID(file.id)
                if publishedCanonicalModification {
                    publishAppliedIndexEvent(root: state.root, modifiedFileIDs: [file.id])
                    #if DEBUG
                        MCPApplyEditsRebaseProbeRecorder.recordStoreModification(
                            rootID: rootID,
                            fileID: file.id,
                            generation: appliedIndexGenerationsByRootID[rootID] ?? 0
                        )
                    #endif
                }
                result = .materialized(file)
            } else {
                let materialization = try await materializeCatalogFileAfterDiskWrite(
                    rootID: rootID,
                    relativePath: standardizedRelativePath,
                    codemapPathLocalMutation: true
                )
                result = materialization
                switch materialization {
                case let .materialized(file):
                    publishedCanonicalModification = isDiscoverableFileID(file.id)
                case .ineligible:
                    publishedCanonicalModification = false
                }
            }

            await state.service.resolveDeferredEditPublication(
                deferredPublicationToken,
                resolution: publishedCanonicalModification
                    ? .callerPublishedCanonicalModification
                    : .publishSyntheticFallback
            )
            return result
        } catch {
            await state.service.resolveDeferredEditPublication(
                deferredPublicationToken,
                resolution: .publishSyntheticFallback
            )
            throw error
        }
    }

    func moveFile(rootID: UUID, from oldRelativePath: String, to newRelativePath: String) async throws {
        let state = try state(for: rootID)
        let oldPath = StandardizedPath.relative(oldRelativePath)
        let newPath = StandardizedPath.relative(newRelativePath)
        let codemapFence = await fenceCodemapPaths(
            rootID: rootID,
            commands: [.renamed(from: oldPath, to: newPath)]
        )
        var didCommitCodemapMutation = false
        defer {
            releaseCodemapPathFence(
                codemapFence,
                didCommitMutation: didCommitCodemapMutation
            )
        }
        let oldFile = file(rootID: rootID, relativePath: oldPath)
        let oldFileWasDiscoverable = oldFile.map { isDiscoverableFileID($0.id) } ?? false
        try await state.service.moveFile(
            atRelativePath: oldPath,
            toRelativePath: newPath
        )
        didCommitCodemapMutation = true
        let destinationEligibility = await state.service.registerExplicitlyManagedRegularFile(relativePath: newPath)
        let destinationManagedOnly: Bool
        switch destinationEligibility {
        case .eligible:
            destinationManagedOnly = false
        case .ineligible(.ignored):
            destinationManagedOnly = true
        case let .ineligible(reason):
            throw WorkspaceFileContextStoreError.catalogMaterializationFailed("moved file is not catalog-eligible at destination: \(reason.description)")
        }
        withCodemapPathLocalCatalogMutation(rootID: rootID) {
            removeFile(relativePath: oldPath, rootID: rootID)
            indexFile(relativePath: newPath, root: state.root, managedOnly: destinationManagedOnly)
            publishAppliedIndexEvent(
                root: state.root,
                upsertedFiles: destinationManagedOnly ? [] : (file(rootID: rootID, relativePath: newPath).map { [$0] } ?? []),
                removedFileIDs: oldFileWasDiscoverable ? (oldFile.map { [$0.id] } ?? []) : [],
                removedFilePaths: oldFileWasDiscoverable ? (oldFile.map { [$0.standardizedRelativePath] } ?? []) : []
            )
        }
    }

    func deleteFile(rootID: UUID, relativePath: String) async throws {
        let state = try state(for: rootID)
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        let codemapFence = await fenceCodemapPaths(
            rootID: rootID,
            commands: [.deleted([standardizedRelativePath])]
        )
        var didCommitCodemapMutation = false
        defer {
            releaseCodemapPathFence(
                codemapFence,
                didCommitMutation: didCommitCodemapMutation
            )
        }
        let oldFile = file(rootID: rootID, relativePath: standardizedRelativePath)
        let oldFileWasDiscoverable = oldFile.map { isDiscoverableFileID($0.id) } ?? false
        do {
            try await state.service.deleteFile(atRelativePath: standardizedRelativePath)
        } catch FileSystemError.fileNotFound {
            if oldFile != nil {
                didCommitCodemapMutation = withCodemapPathLocalCatalogMutation(rootID: rootID) {
                    pruneCatalogFileMissingOnDisk(
                        rootID: rootID,
                        relativePath: standardizedRelativePath,
                        publishDelta: true
                    )
                }
            }
            throw FileSystemError.fileNotFound
        }
        didCommitCodemapMutation = true
        withCodemapPathLocalCatalogMutation(rootID: rootID) {
            removeFile(relativePath: standardizedRelativePath, rootID: rootID)
            if let oldFile, oldFileWasDiscoverable {
                publishAppliedIndexEvent(root: state.root, removedFileIDs: [oldFile.id], removedFilePaths: [oldFile.standardizedRelativePath])
            }
        }
    }

    func moveItemToTrash(rootID: UUID, relativePath: String) async throws {
        let state = try state(for: rootID)
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        let oldFile = file(rootID: rootID, relativePath: standardizedRelativePath)
        let oldFileWasDiscoverable = oldFile.map { isDiscoverableFileID($0.id) } ?? false
        let oldFolder = folder(rootID: rootID, relativePath: standardizedRelativePath)
        let oldFolderWasDiscoverable = oldFolder.map { isDiscoverableFolderID($0.id) } ?? false
        let affectedPaths: Set<String> = if oldFolder != nil {
            Set(state.fileIDsByRelativePath.keys.filter {
                $0 == standardizedRelativePath || $0.hasPrefix(standardizedRelativePath + "/")
            })
        } else {
            [standardizedRelativePath]
        }
        let codemapFence = await fenceCodemapPaths(
            rootID: rootID,
            commands: [.deleted(affectedPaths)]
        )
        var didCommitCodemapMutation = false
        defer {
            releaseCodemapPathFence(
                codemapFence,
                didCommitMutation: didCommitCodemapMutation
            )
        }
        do {
            try await state.service.moveItemToTrash(atRelativePath: standardizedRelativePath)
        } catch FileSystemError.fileNotFound {
            if oldFile != nil || oldFolder != nil {
                didCommitCodemapMutation = withCodemapPathLocalCatalogMutation(rootID: rootID) {
                    pruneCatalogItemMissingOnDisk(
                        rootID: rootID,
                        relativePath: standardizedRelativePath,
                        publishDelta: true
                    )
                }
            }
            throw FileSystemError.fileNotFound
        }
        didCommitCodemapMutation = true
        withCodemapPathLocalCatalogMutation(rootID: rootID) {
            if let oldFile {
                removeFile(relativePath: standardizedRelativePath, rootID: rootID)
                if oldFileWasDiscoverable {
                    publishAppliedIndexEvent(root: state.root, removedFileIDs: [oldFile.id], removedFilePaths: [oldFile.standardizedRelativePath])
                }
            } else if let oldFolder {
                let removal = removeFolderTree(relativePath: standardizedRelativePath, rootID: rootID)
                publishAppliedIndexEvent(
                    root: state.root,
                    removedFileIDs: removal.fileIDs,
                    removedFolderIDs: removal.folderIDs.isEmpty && oldFolderWasDiscoverable ? [oldFolder.id] : removal.folderIDs,
                    removedFilePaths: removal.filePaths,
                    removedFolderPaths: removal.folderPaths.isEmpty && oldFolderWasDiscoverable ? [oldFolder.standardizedRelativePath] : removal.folderPaths
                )
            }
        }
    }

    func validateCatalogFileStillPresent(_ file: WorkspaceFileRecord) async -> WorkspaceFileRecord? {
        let lifecycleCorrelation = EditFlowPerf.currentLifecycleCorrelation
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.Search.contentFreshnessStoreEntered,
            correlation: lifecycleCorrelation
        )
        let validationState = EditFlowPerf.begin(EditFlowPerf.Stage.Search.contentFreshnessValidationStoreActorBody)
        var outcome = "missing"
        defer {
            EditFlowPerf.end(
                EditFlowPerf.Stage.Search.contentFreshnessValidationStoreActorBody,
                validationState,
                EditFlowPerf.Dimensions(outcome: outcome)
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.Search.contentFreshnessStoreReturned,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(outcome: outcome)
            )
        }
        guard let state = rootStatesByID[file.rootID],
              let current = self.file(rootID: file.rootID, relativePath: file.standardizedRelativePath)
        else { return nil }
        if await state.service.regularFileExistsOnDisk(relativePath: current.standardizedRelativePath) {
            outcome = "current"
            return current
        }
        _ = await fenceAndPruneCatalogFileMissingOnDisk(
            rootID: file.rootID,
            relativePath: current.standardizedRelativePath,
            publishDelta: true
        )
        return nil
    }

    @discardableResult
    func pruneMissingCatalogFilesForExactMutationLookup(
        _ userPath: String,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> Bool {
        let trimmed = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var candidates: [WorkspaceFileRecord] = []
        func appendCandidate(rootID: UUID, relativePath: String) {
            guard let file = file(rootID: rootID, relativePath: relativePath),
                  !candidates.contains(where: { $0.id == file.id })
            else { return }
            candidates.append(file)
        }
        func appendAbsoluteCandidate(_ path: String) {
            let absolute = StandardizedPath.absolute(path)
            guard let fileID = fileIDsByStandardizedFullPath[absolute], let file = filesByID[fileID],
                  rootsForPathLookup(scope: rootScope).contains(where: { $0.id == file.rootID }),
                  !candidates.contains(where: { $0.id == file.id })
            else { return }
            candidates.append(file)
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardizedInput = (expanded as NSString).standardizingPath
        let roots = rootRefs(scope: rootScope)
        if standardizedInput.hasPrefix("/") {
            appendAbsoluteCandidate(standardizedInput)
            let pseudoAlias = standardizedInput.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            switch WorkspaceAliasResolver.resolve(userPath: pseudoAlias, roots: roots, options: RootAliasOptions(requireRemainder: true)) {
            case let .prefixed(root, _, remainder):
                appendCandidate(rootID: root.id, relativePath: remainder)
            case .ambiguous, .bareRoot, .notAliasPrefixed:
                break
            }
        } else {
            switch WorkspaceAliasResolver.resolve(userPath: standardizedInput, roots: roots, options: RootAliasOptions(requireRemainder: true)) {
            case let .prefixed(root, _, remainder):
                appendCandidate(rootID: root.id, relativePath: remainder)
            case .ambiguous, .bareRoot, .notAliasPrefixed:
                break
            }
            let relative = StandardizedPath.relative(standardizedInput)
            if !relative.isEmpty {
                for root in roots {
                    appendCandidate(rootID: root.id, relativePath: relative)
                }
            }
        }

        var pruned = false
        for candidate in candidates {
            if await validateCatalogFileStillPresent(candidate) == nil {
                pruned = true
            }
        }
        return pruned
    }

    /// Returns an exact cataloged file without touching disk. Disk recovery for ignored
    /// files is intentionally reserved for absolute-path misses.
    func lookupCatalogFileForExplicitRequest(
        _ userPath: String,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) -> WorkspaceExplicitCatalogFileLookupResult {
        lookupCatalogFileForExplicitRequest(
            userPath,
            rootRefs: rootRefs(scope: rootScope)
        )
    }

    func lookupCatalogFileForExplicitRequest(
        _ userPath: String,
        rootRefs roots: [WorkspaceRootRef]
    ) -> WorkspaceExplicitCatalogFileLookupResult {
        #if DEBUG || EDIT_FLOW_PERF
            var exactCatalogLookupOutcome = "noCandidate"
            var exactCatalogLookupRoute = "empty"
            let exactCatalogLookupActorBody = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.exactCatalogLookupActorBody)
            defer {
                let dimensions = EditFlowPerf.Dimensions(status: exactCatalogLookupRoute, outcome: exactCatalogLookupOutcome)
                EditFlowPerf.end(
                    EditFlowPerf.Stage.ReadFile.exactCatalogLookupActorBody,
                    exactCatalogLookupActorBody,
                    dimensions
                )
                EditFlowPerf.lifecycleEvent(
                    EditFlowPerf.Lifecycle.ReadFile.exactCatalogLookupResolved,
                    dimensions
                )
            }
        #endif

        let trimmed = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .noCandidate }
        guard !StandardizedPath.containsNUL(trimmed) else {
            #if DEBUG || EDIT_FLOW_PERF
                exactCatalogLookupRoute = "blocked"
                exactCatalogLookupOutcome = "blocked"
            #endif
            return .blocked
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardized = StandardizedPath.absolute(expanded)

        if standardized.hasPrefix("/") {
            #if DEBUG || EDIT_FLOW_PERF
                exactCatalogLookupRoute = "absolute"
            #endif
            guard let root = roots
                .filter({ StandardizedPath.isDescendant(standardized, of: $0.standardizedFullPath) })
                .max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count })
            else { return .noCandidate }
            let relativePath = String(standardized.dropFirst(root.standardizedFullPath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let file = file(rootID: root.id, relativePath: relativePath) else { return .noCandidate }
            #if DEBUG || EDIT_FLOW_PERF
                exactCatalogLookupOutcome = "matched"
            #endif
            return .matched(file)
        }

        switch WorkspaceAliasResolver.resolve(
            userPath: standardized,
            roots: roots,
            options: RootAliasOptions(requireRemainder: true)
        ) {
        case let .prefixed(root, _, remainder):
            #if DEBUG || EDIT_FLOW_PERF
                exactCatalogLookupRoute = "rootAlias"
            #endif
            guard let file = file(rootID: root.id, relativePath: remainder) else { return .noCandidate }
            #if DEBUG || EDIT_FLOW_PERF
                exactCatalogLookupOutcome = "matched"
            #endif
            return .matched(file)
        case .ambiguous:
            #if DEBUG || EDIT_FLOW_PERF
                exactCatalogLookupRoute = "rootAlias"
                exactCatalogLookupOutcome = "ambiguous"
            #endif
            return .ambiguous
        case .bareRoot, .notAliasPrefixed:
            break
        }

        #if DEBUG || EDIT_FLOW_PERF
            exactCatalogLookupRoute = "relative"
        #endif
        let relativePath = StandardizedPath.relative(standardized)
        guard !relativePath.isEmpty,
              relativePath != "..",
              !relativePath.hasPrefix("../")
        else {
            #if DEBUG || EDIT_FLOW_PERF
                exactCatalogLookupOutcome = "blocked"
            #endif
            return .blocked
        }
        let matches = roots.compactMap { file(rootID: $0.id, relativePath: relativePath) }
        guard matches.count <= 1 else {
            #if DEBUG || EDIT_FLOW_PERF
                exactCatalogLookupOutcome = "ambiguous"
            #endif
            return .ambiguous
        }
        guard let match = matches.first else { return .noCandidate }
        #if DEBUG || EDIT_FLOW_PERF
            exactCatalogLookupOutcome = "matched"
        #endif
        return .matched(match)
    }

    /// Resolves an exact file path that the caller explicitly requested, even when
    /// discovery policy hides it. Ignore rules remain discovery filters: background scans,
    /// replay, tree rendering, search, and fuzzy matching still skip managed-only files.
    func materializeExplicitlyRequestedFile(
        _ userPath: String,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async throws -> WorkspaceExplicitFileMaterializationResult {
        try await materializeExplicitlyRequestedFile(
            userPath,
            rootRefs: rootRefs(scope: rootScope)
        )
    }

    func materializeExplicitlyRequestedFile(
        _ userPath: String,
        rootRefs roots: [WorkspaceRootRef]
    ) async throws -> WorkspaceExplicitFileMaterializationResult {
        let trimmed = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .noCandidate }
        guard !StandardizedPath.containsNUL(trimmed) else { return .blocked }
        guard (trimmed as NSString).expandingTildeInPath.hasPrefix("/") else { return .noCandidate }

        let candidates: [(rootID: UUID, relativePath: String)]
        switch explicitDiskLookupCandidates(for: trimmed, rootRefs: roots) {
        case let .candidates(resolvedCandidates):
            candidates = resolvedCandidates
        case .ambiguousAlias:
            return .ambiguous
        }
        var materializable: [(rootID: UUID, relativePath: String, managedOnly: Bool)] = []
        var foundBlockedCandidate = false
        for candidate in candidates {
            guard let state = rootStatesByID[candidate.rootID] else { continue }
            switch await state.service.catalogRegularFileEligibility(relativePath: candidate.relativePath) {
            case .eligible:
                materializable.append((candidate.rootID, candidate.relativePath, false))
            case .ineligible(.ignored):
                materializable.append((candidate.rootID, candidate.relativePath, true))
            case .ineligible(.missingOrDirectory):
                _ = await fenceAndPruneCatalogFileMissingOnDisk(
                    rootID: candidate.rootID,
                    relativePath: candidate.relativePath,
                    publishDelta: true
                )
                continue
            case .ineligible:
                foundBlockedCandidate = true
            }
        }
        guard materializable.count <= 1 else { return .ambiguous }
        guard let candidate = materializable.first,
              let state = rootStatesByID[candidate.rootID]
        else { return foundBlockedCandidate ? .blocked : .noCandidate }
        let registeredEligibility = await state.service.registerExplicitlyManagedRegularFile(relativePath: candidate.relativePath)
        let managedOnly: Bool
        switch registeredEligibility {
        case .eligible:
            managedOnly = false
        case .ineligible(.ignored):
            managedOnly = true
        case .ineligible(.missingOrDirectory):
            _ = await fenceAndPruneCatalogFileMissingOnDisk(
                rootID: candidate.rootID,
                relativePath: candidate.relativePath,
                publishDelta: true
            )
            return .noCandidate
        case .ineligible:
            return .blocked
        }
        guard let codemapFence = await beginCodemapRootMutationFence(
            rootID: candidate.rootID,
            command: .catalogAdvanced
        ) else { return .noCandidate }
        do {
            let materialized = try materializeCatalogRegularFile(
                rootID: candidate.rootID,
                relativePath: candidate.relativePath,
                managedOnly: managedOnly
            )
            await awaitCodemapCleanupFlights(rootIDs: [candidate.rootID])
            finishCodemapRootMutationFence(codemapFence, didCommitMutation: true)
            return .materialized(materialized)
        } catch {
            finishCodemapRootMutationFence(codemapFence, didCommitMutation: false)
            throw error
        }
    }

    @discardableResult
    func materializeCatalogFileAfterDiskWrite(
        rootID: UUID,
        relativePath: String,
        codemapPathLocalMutation: Bool = false
    ) async throws -> WorkspaceFileCatalogMaterializationResult {
        let state = try state(for: rootID)
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        let eligibility = await state.service.registerExplicitlyManagedRegularFile(relativePath: standardizedRelativePath)

        func materialize(managedOnly: Bool) throws -> WorkspaceFileCatalogMaterializationResult {
            let perform = {
                try self.materializeCatalogRegularFile(
                    rootID: rootID,
                    relativePath: standardizedRelativePath,
                    managedOnly: managedOnly
                )
            }
            let file = if codemapPathLocalMutation {
                try withCodemapPathLocalCatalogMutation(rootID: rootID, perform)
            } else {
                try perform()
            }
            return .materialized(file)
        }

        switch eligibility {
        case .ineligible(.ignored):
            // A direct app/MCP write is an explicit request to manage this exact file.
            // Keep it available for follow-up read_file/apply_edits calls without making
            // ignored siblings discoverable through scans or replay.
            return try materialize(managedOnly: true)
        case let .ineligible(reason):
            guard isExpectedDiskWriteCatalogIneligibility(reason) else {
                throw WorkspaceFileContextStoreError.catalogMaterializationFailed(
                    "file was written but is not catalog-eligible after the write: \(reason.description)"
                )
            }
            return .ineligible(reason)
        case .eligible:
            return try materialize(managedOnly: false)
        }
    }

    func ingressPublishedGitArtifacts(
        _ request: WorkspacePublishedGitArtifactIngressRequest
    ) async -> WorkspacePublishedGitArtifactIngressResult {
        func staleRootResult() -> WorkspacePublishedGitArtifactIngressResult {
            WorkspacePublishedGitArtifactIngressResult(outcomes: request.artifacts.map {
                WorkspacePublishedGitArtifactIngressOutcome(artifact: $0, status: .staleRoot)
            })
        }

        guard let initialState = exactRootState(
            expectedRoot: request.root,
            expectedKind: .workspaceGitData
        ) else {
            return staleRootResult()
        }
        let expectedBatchLifetimeID = initialState.lifetimeID
        guard let codemapFence = await beginCodemapRootMutationFence(
            rootID: request.root.id,
            command: .catalogAdvanced
        ) else { return staleRootResult() }
        var didPublishCatalogMutation = false
        defer {
            finishCodemapRootMutationFence(
                codemapFence,
                didCommitMutation: didPublishCatalogMutation
            )
        }
        guard let fencedState = exactRootState(
            expectedRoot: request.root,
            expectedKind: .workspaceGitData
        ), fencedState.lifetimeID == expectedBatchLifetimeID else {
            return staleRootResult()
        }

        var outcomes: [WorkspacePublishedGitArtifactIngressOutcome] = []
        var seenAbsolutePaths = Set<String>()

        func append(
            _ artifact: GitDiffPublishedArtifact,
            _ status: WorkspacePublishedGitArtifactIngressOutcomeStatus
        ) {
            outcomes.append(WorkspacePublishedGitArtifactIngressOutcome(
                artifact: artifact,
                status: status
            ))
        }

        for artifact in request.artifacts {
            let relativePath = artifact.gitDataRelativePath
            guard GitDiffArtifactPathPolicy.isSafeRelativeArtifactPath(relativePath) else {
                append(artifact, .invalidRelativePath)
                continue
            }

            let absolutePath = artifact.absolutePath
            guard absolutePath.hasPrefix("/"),
                  !StandardizedPath.containsNUL(absolutePath),
                  StandardizedPath.isDescendant(absolutePath, of: request.root.standardizedFullPath),
                  absolutePath != request.root.standardizedFullPath
            else {
                append(artifact, .outsideExpectedRoot)
                continue
            }

            let reconstructedPath = StandardizedPath.join(
                standardizedRoot: request.root.standardizedFullPath,
                standardizedRelativePath: relativePath
            )
            guard reconstructedPath == absolutePath else {
                append(artifact, .outsideExpectedRoot)
                continue
            }

            guard seenAbsolutePaths.insert(absolutePath).inserted else {
                append(artifact, .duplicateOf(path: absolutePath))
                continue
            }

            guard let state = exactRootState(
                expectedRoot: request.root,
                expectedKind: .workspaceGitData
            ), state.lifetimeID == expectedBatchLifetimeID else {
                return staleRootResult()
            }
            let eligibility = await state.service.registerExplicitlyManagedRegularFile(
                relativePath: relativePath
            )
            #if DEBUG
                if let publishedGitArtifactIngressDidRegisterHandler {
                    await publishedGitArtifactIngressDidRegisterHandler(request.root.id, relativePath)
                }
            #endif

            guard let revalidatedState = exactRootState(
                expectedRoot: request.root,
                expectedKind: .workspaceGitData
            ), revalidatedState.lifetimeID == expectedBatchLifetimeID else {
                return staleRootResult()
            }

            let managedOnly: Bool
            switch eligibility {
            case .eligible:
                managedOnly = false
            case .ineligible(.ignored):
                managedOnly = true
            case .ineligible(.missingOrDirectory):
                pruneCatalogFileMissingOnDisk(
                    rootID: request.root.id,
                    relativePath: relativePath,
                    publishDelta: true
                )
                append(artifact, .missingOnDisk)
                continue
            case let .ineligible(reason):
                append(artifact, .ineligible(reason: reason))
                continue
            }

            do {
                let record = try materializeCatalogRegularFile(
                    rootID: request.root.id,
                    relativePath: relativePath,
                    managedOnly: managedOnly
                )
                didPublishCatalogMutation = true
                append(artifact, .cataloged(record: record))
            } catch {
                if !regularFileAppearsPresentOnDisk(
                    root: revalidatedState.root,
                    relativePath: relativePath
                ) {
                    append(artifact, .missingOnDisk)
                } else {
                    append(artifact, .materializationFailed(reason: error.localizedDescription))
                }
            }
        }

        guard let finalState = exactRootState(
            expectedRoot: request.root,
            expectedKind: .workspaceGitData
        ), finalState.lifetimeID == expectedBatchLifetimeID else {
            return staleRootResult()
        }
        await awaitCodemapCleanupFlights(rootIDs: [request.root.id])
        return WorkspacePublishedGitArtifactIngressResult(outcomes: outcomes)
    }

    private func explicitDiskLookupCandidates(
        for userPath: String,
        rootRefs roots: [WorkspaceRootRef]
    ) -> ExplicitDiskLookupCandidatesResult {
        let expanded = (userPath as NSString).expandingTildeInPath
        let standardized = StandardizedPath.absolute(expanded)
        var candidates: [(rootID: UUID, relativePath: String)] = []
        var seen = Set<String>()

        func append(root: WorkspaceRootRef, relativePath rawRelativePath: String) {
            let relativePath = StandardizedPath.relative(rawRelativePath)
            guard !relativePath.isEmpty,
                  relativePath != "..",
                  !relativePath.hasPrefix("../")
            else { return }
            let absolutePath = StandardizedPath.join(
                standardizedRoot: root.standardizedFullPath,
                standardizedRelativePath: relativePath
            )
            guard StandardizedPath.isDescendant(absolutePath, of: root.standardizedFullPath) else { return }
            let key = "\(root.id.uuidString)|\(relativePath)"
            guard seen.insert(key).inserted else { return }
            candidates.append((root.id, relativePath))
        }

        func appendAbsolute(_ absolutePath: String) {
            guard let root = roots
                .filter({ StandardizedPath.isDescendant(absolutePath, of: $0.standardizedFullPath) })
                .max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count })
            else { return }
            let relativePath = String(absolutePath.dropFirst(root.standardizedFullPath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            append(root: root, relativePath: relativePath)
        }

        if standardized.hasPrefix("/") {
            appendAbsolute(standardized)
            return .candidates(candidates)
        }

        switch WorkspaceAliasResolver.resolve(
            userPath: standardized,
            roots: roots,
            options: RootAliasOptions(requireRemainder: true)
        ) {
        case let .prefixed(root, _, remainder):
            append(root: root, relativePath: remainder)
            return .candidates(candidates)
        case .ambiguous:
            return .ambiguousAlias
        case .bareRoot, .notAliasPrefixed:
            break
        }

        for root in roots {
            append(root: root, relativePath: standardized)
        }
        return .candidates(candidates)
    }

    private func materializeCatalogRegularFile(
        rootID: UUID,
        relativePath: String,
        managedOnly: Bool
    ) throws -> WorkspaceFileRecord {
        let state = try state(for: rootID)
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        if let existing = file(rootID: rootID, relativePath: standardizedRelativePath) {
            let wasManagedOnly = managedOnlyFileIDs.contains(existing.id)
            if !managedOnly {
                promoteToDiscoverable(existing)
                if wasManagedOnly {
                    invalidatePathMatchSnapshot(
                        affectedRootKinds: [state.root.kind],
                        reason: .managedFilePromotion,
                        affectedRootIDs: [state.root.id]
                    )
                    publishAppliedIndexEvent(
                        root: state.root,
                        upsertedFiles: [existing],
                        upsertedFolders: discoverableParentFolders(for: standardizedRelativePath, rootID: rootID)
                    )
                }
            }
            return existing
        }

        guard regularFileAppearsPresentOnDisk(root: state.root, relativePath: standardizedRelativePath) else {
            throw WorkspaceFileContextStoreError.catalogMaterializationFailed(
                "eligible file disappeared before it could be added to the workspace catalog: \(standardizedRelativePath)"
            )
        }
        indexFile(relativePath: standardizedRelativePath, root: state.root, managedOnly: managedOnly)
        guard let file = file(rootID: rootID, relativePath: standardizedRelativePath) else {
            throw WorkspaceFileContextStoreError.catalogMaterializationFailed(
                "eligible file exists on disk but the workspace catalog did not return a record: \(standardizedRelativePath)"
            )
        }
        if !managedOnly {
            publishAppliedIndexEvent(
                root: state.root,
                upsertedFiles: [file],
                upsertedFolders: discoverableParentFolders(for: standardizedRelativePath, rootID: rootID)
            )
        }
        return file
    }

    private func isExpectedDiskWriteCatalogIneligibility(_ reason: CatalogRegularFileIneligibilityReason) -> Bool {
        switch reason {
        case .ignored, .symbolicLink, .nonRegularFile, .symlinkComponent, .outsideCanonicalRoot, .outsideRoot:
            true
        case .invalidRelativePath, .missingOrDirectory:
            false
        }
    }

    private func regularFileAppearsPresentOnDisk(root: WorkspaceRootRecord, relativePath: String) -> Bool {
        let fullPath = StandardizedPath.join(standardizedRoot: root.standardizedFullPath, standardizedRelativePath: StandardizedPath.relative(relativePath))
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        if let values = try? URL(fileURLWithPath: fullPath).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            if values.isSymbolicLink == true { return false }
            if values.isRegularFile == false { return false }
        }
        return true
    }

    private func directoryAppearsPresentOnDisk(root: WorkspaceRootRecord, relativePath: String) -> Bool {
        let fullPath = StandardizedPath.join(standardizedRoot: root.standardizedFullPath, standardizedRelativePath: StandardizedPath.relative(relativePath))
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        if let values = try? URL(fileURLWithPath: fullPath).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            if values.isSymbolicLink == true { return false }
            if values.isDirectory == false { return false }
        }
        return true
    }

    @discardableResult
    private func fenceAndPruneCatalogFileMissingOnDisk(
        rootID: UUID,
        relativePath: String,
        publishDelta: Bool
    ) async -> Bool {
        let path = StandardizedPath.relative(relativePath)
        let token = await fenceCodemapPaths(
            rootID: rootID,
            commands: [.deleted([path])]
        )
        let didPrune = withCodemapPathLocalCatalogMutation(rootID: rootID) {
            pruneCatalogFileMissingOnDisk(
                rootID: rootID,
                relativePath: path,
                publishDelta: publishDelta
            )
        }
        releaseCodemapPathFence(token, didCommitMutation: didPrune)
        return didPrune
    }

    @discardableResult
    private func pruneCatalogFileMissingOnDisk(
        rootID: UUID,
        relativePath: String,
        publishDelta: Bool
    ) -> Bool {
        guard let state = rootStatesByID[rootID],
              let oldFile = file(rootID: rootID, relativePath: relativePath)
        else { return false }
        let oldFileWasDiscoverable = isDiscoverableFileID(oldFile.id)
        removeFile(relativePath: oldFile.standardizedRelativePath, rootID: rootID)
        if publishDelta, oldFileWasDiscoverable {
            publishAppliedIndexEvent(root: state.root, removedFileIDs: [oldFile.id], removedFilePaths: [oldFile.standardizedRelativePath])
        }
        return true
    }

    @discardableResult
    private func pruneCatalogItemMissingOnDisk(
        rootID: UUID,
        relativePath: String,
        publishDelta: Bool
    ) -> Bool {
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        if pruneCatalogFileMissingOnDisk(rootID: rootID, relativePath: standardizedRelativePath, publishDelta: publishDelta) {
            return true
        }
        guard let state = rootStatesByID[rootID],
              let oldFolder = folder(rootID: rootID, relativePath: standardizedRelativePath)
        else { return false }
        let oldFolderWasDiscoverable = isDiscoverableFolderID(oldFolder.id)
        let removal = removeFolderTree(relativePath: standardizedRelativePath, rootID: rootID)
        if publishDelta {
            publishAppliedIndexEvent(
                root: state.root,
                removedFileIDs: removal.fileIDs,
                removedFolderIDs: removal.folderIDs.isEmpty && oldFolderWasDiscoverable ? [oldFolder.id] : removal.folderIDs,
                removedFilePaths: removal.filePaths,
                removedFolderPaths: removal.folderPaths.isEmpty && oldFolderWasDiscoverable ? [oldFolder.standardizedRelativePath] : removal.folderPaths
            )
        }
        return true
    }

    #if DEBUG
        private func applyPreparedIndexDeltas(
            rootID: UUID,
            deltas: [PreparedFileSystemDelta],
            expectedLifetimeID: UUID? = nil,
            watcherAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark?,
            servicePublicationSequence: UInt64?,
            requiresFullResync: Bool = false
        ) async {
            guard let servicePublicationSequence else {
                await applyPreparedIndexDeltasBody(
                    rootID: rootID,
                    deltas: deltas,
                    expectedLifetimeID: expectedLifetimeID,
                    requiresFullResync: requiresFullResync
                )
                return
            }
            let recorder = await applyPreparedIndexDeltasRecordingInvalidations(
                rootID: rootID,
                deltas: deltas,
                expectedLifetimeID: expectedLifetimeID,
                requiresFullResync: requiresFullResync
            )
            guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: expectedLifetimeID) else { return }
            recordPublicationInvalidationDiagnostics(
                rootID: rootID,
                servicePublicationSequence: servicePublicationSequence,
                watcherAcceptedWatermark: watcherAcceptedWatermark,
                recorder: recorder
            )
        }

        private func applyPreparedIndexDeltasRecordingInvalidations(
            rootID: UUID,
            deltas: [PreparedFileSystemDelta],
            expectedLifetimeID: UUID? = nil,
            requiresFullResync: Bool = false
        ) async -> PublicationInvalidationRecorder {
            let recorder = PublicationInvalidationRecorder(preparedDeltaCount: deltas.count)
            await Self.$activePublicationInvalidationRecorder.withValue(recorder) {
                await applyPreparedIndexDeltasBody(
                    rootID: rootID,
                    deltas: deltas,
                    expectedLifetimeID: expectedLifetimeID,
                    requiresFullResync: requiresFullResync
                )
            }
            return recorder
        }
    #else
        private func applyPreparedIndexDeltas(
            rootID: UUID,
            deltas: [PreparedFileSystemDelta],
            expectedLifetimeID: UUID? = nil,
            requiresFullResync: Bool = false
        ) async {
            await applyPreparedIndexDeltasBody(
                rootID: rootID,
                deltas: deltas,
                expectedLifetimeID: expectedLifetimeID,
                requiresFullResync: requiresFullResync
            )
        }
    #endif

    private func codemapWatcherInvalidationCommands(
        rootID: UUID,
        deltas: [PreparedFileSystemDelta],
        requiresFullResync: Bool
    ) -> (rootCommand: CodemapInvalidationCommand?, pathCommands: [CodemapInvalidationCommand]) {
        if requiresFullResync {
            return (.watcherGap, [])
        }
        var commands: [CodemapInvalidationCommand] = []
        for prepared in deltas {
            switch prepared.delta {
            case .fileAdded:
                commands.append(.modified([prepared.relativePath]))
            case .fileModified:
                commands.append(.modified([prepared.relativePath]))
            case .fileRemoved:
                commands.append(.deleted([prepared.relativePath]))
            case .folderRemoved:
                let folderPath = StandardizedPath.relative(prepared.relativePath)
                let descendantPaths = Set(
                    rootStatesByID[rootID]?.fileIDsByRelativePath.keys.filter {
                        $0 == folderPath || $0.hasPrefix(folderPath + "/")
                    } ?? []
                )
                if !descendantPaths.isEmpty {
                    commands.append(.deleted(descendantPaths))
                }
            case .folderAdded, .folderModified:
                break
            }
        }
        return (nil, commands)
    }

    private func applyPreparedIndexDeltasBody(
        rootID: UUID,
        deltas: [PreparedFileSystemDelta],
        expectedLifetimeID: UUID? = nil,
        requiresFullResync: Bool = false
    ) async {
        guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: expectedLifetimeID) else { return }
        var didCommitRepositoryMutation = false
        let repositoryMutationFence = await beginCodemapRepositoryAuthorityMutationIfNeeded(
            rootID: rootID,
            deltas: deltas,
            requiresFullResync: requiresFullResync
        )
        defer {
            finishCodemapRootMutationFence(
                repositoryMutationFence,
                didCommitMutation: didCommitRepositoryMutation
            )
        }
        let applicableDeltas = await preflightPreparedIndexDeltas(
            rootID: rootID,
            deltas: deltas,
            expectedLifetimeID: expectedLifetimeID
        )
        guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: expectedLifetimeID) else { return }
        let invalidation = codemapWatcherInvalidationCommands(
            rootID: rootID,
            deltas: applicableDeltas,
            requiresFullResync: requiresFullResync
        )
        if let rootCommand = invalidation.rootCommand {
            if repositoryMutationFence == nil {
                await fenceCodemapRootAuthority(rootIDs: [rootID], command: rootCommand)
            }
            guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: expectedLifetimeID) else { return }
            applyPreparedIndexDeltaMutations(
                rootID: rootID,
                deltas: applicableDeltas,
                requiresFullResync: requiresFullResync
            )
            didCommitRepositoryMutation = repositoryMutationFence != nil
            await awaitCodemapCleanupFlights(rootIDs: [rootID])
            if repositoryMutationFence == nil, let current = rootStatesByID[rootID] {
                scheduleCodemapProjectionPreloadAfterRootReady(rootEpoch: WorkspaceCodemapRootEpoch(
                    rootID: rootID,
                    rootLifetimeID: current.lifetimeID
                ))
            }
            return
        }

        if repositoryMutationFence != nil {
            guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: expectedLifetimeID) else { return }
            applyPreparedIndexDeltaMutations(
                rootID: rootID,
                deltas: applicableDeltas,
                requiresFullResync: requiresFullResync
            )
            didCommitRepositoryMutation = true
            return
        }

        let token = await fenceCodemapPaths(
            rootID: rootID,
            commands: invalidation.pathCommands
        )
        var didCommitPathMutation = false
        defer {
            releaseCodemapPathFence(token, didCommitMutation: didCommitPathMutation)
        }
        guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: expectedLifetimeID) else { return }
        withCodemapPathLocalCatalogMutation(rootID: rootID) {
            applyPreparedIndexDeltaMutations(
                rootID: rootID,
                deltas: applicableDeltas,
                requiresFullResync: requiresFullResync
            )
        }
        #if DEBUG
            if let recorder = Self.activePublicationInvalidationRecorder,
               recorder.topologyInvalidationCount == 0
            {
                recorder.codemapInvalidationRequestCount += token?.standardizedRelativePaths.count ?? 0
            }
        #endif
        didCommitPathMutation = true
    }

    private func beginCodemapRepositoryAuthorityMutationIfNeeded(
        rootID: UUID,
        deltas: [PreparedFileSystemDelta],
        requiresFullResync: Bool
    ) async -> CodemapRootMutationFenceToken? {
        guard let state = rootStatesByID[rootID] else { return nil }
        let rootEpoch = WorkspaceCodemapRootEpoch(rootID: rootID, rootLifetimeID: state.lifetimeID)
        if requiresFullResync {
            terminalNonGitCodemapCacheByEpoch.removeValue(forKey: rootEpoch)
        }
        let repositoryLayoutMayHaveChanged = deltas.contains { prepared in
            let path = prepared.relativePath
            return path == ".git" || path.hasPrefix(".git/") || path == "HEAD" ||
                path == "objects" || path.hasPrefix("objects/") || path == "refs" || path.hasPrefix("refs/")
        }
        guard repositoryLayoutMayHaveChanged else { return nil }

        terminalNonGitCodemapCacheByEpoch.removeValue(forKey: rootEpoch)
        recordCodemapProjectionPreloadStoreEvent(
            .repositoryAuthorityDetached,
            rootEpoch: rootEpoch,
            phase: .superseded
        )
        return await beginCodemapRootMutationFence(
            rootID: rootID,
            command: .repositoryAuthority
        )
    }

    private func preflightPreparedIndexDeltas(
        rootID: UUID,
        deltas: [PreparedFileSystemDelta],
        expectedLifetimeID: UUID? = nil
    ) async -> [PreparedFileSystemDelta] {
        var applicableDeltas: [PreparedFileSystemDelta] = []
        applicableDeltas.reserveCapacity(deltas.count)
        for prepared in deltas {
            switch prepared.delta {
            case .fileAdded:
                guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: expectedLifetimeID),
                      let service = rootStatesByID[rootID]?.service,
                      await service.catalogEligibleRegularFileExists(relativePath: prepared.relativePath),
                      isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: expectedLifetimeID)
                else { continue }
                applicableDeltas.append(prepared)
            case .folderAdded:
                guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: expectedLifetimeID),
                      let service = rootStatesByID[rootID]?.service,
                      await service.catalogFolderIsDiscoverable(relativePath: prepared.relativePath),
                      isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: expectedLifetimeID)
                else { continue }
                applicableDeltas.append(prepared)
            case .fileRemoved, .folderRemoved, .fileModified, .folderModified:
                applicableDeltas.append(prepared)
            }
        }
        return applicableDeltas
    }

    private func applyPreparedIndexDeltaMutations(
        rootID: UUID,
        deltas: [PreparedFileSystemDelta],
        requiresFullResync: Bool = false
    ) {
        guard let root = rootStatesByID[rootID]?.root else { return }
        precondition(activePublicationInvalidationBatch == nil)
        let invalidationBatch = PublicationInvalidationBatch()
        activePublicationInvalidationBatch = invalidationBatch
        defer { activePublicationInvalidationBatch = nil }

        var upsertedFiles: [WorkspaceFileRecord] = []
        var upsertedFolders: [WorkspaceFolderRecord] = []
        var removedFileIDs: [UUID] = []
        var removedFolderIDs: [UUID] = []
        var removedFilePaths: [String] = []
        var removedFolderPaths: [String] = []
        var modifiedFileIDs: [UUID] = []
        var modifiedFolderIDs: [UUID] = []
        for prepared in deltas {
            let relativePath = prepared.relativePath
            switch prepared.delta {
            case .fileAdded:
                guard regularFileAppearsPresentOnDisk(root: root, relativePath: relativePath) else { continue }
                let existingFile = file(rootID: rootID, relativePath: relativePath)
                let existed = existingFile != nil
                if let existingFile {
                    invalidateSearchContent(existingFile)
                }
                let existingFolderPaths = Set(rootStatesByID[rootID].map { Array($0.folderIDsByRelativePath.keys) } ?? [])
                indexFile(relativePath: relativePath, root: root)
                if let file = file(rootID: rootID, relativePath: relativePath) {
                    // Publish existing records too: file-system deltas may have already
                    // indexed the catalog while UI replay still has optimistic UUIDs.
                    // Treating add as an upsert lets subscribers reconcile to store IDs.
                    upsertedFiles.append(file)
                    if !existed {
                        upsertedFolders.append(contentsOf: newlyIndexedParentFolders(for: relativePath, rootID: rootID, existingFolderPaths: existingFolderPaths))
                    }
                    upsertedFolders.append(contentsOf: discoverableParentFolders(for: relativePath, rootID: rootID))
                }
            case .folderAdded:
                guard directoryAppearsPresentOnDisk(root: root, relativePath: relativePath) else { continue }
                indexFolder(relativePath: relativePath, root: root)
                if let folder = folder(rootID: rootID, relativePath: relativePath) {
                    // Same upsert semantics as files: repeated folder add deltas are
                    // harmless and allow UI identity reconciliation.
                    upsertedFolders.append(folder)
                }
            case .fileRemoved:
                if let oldFile = file(rootID: rootID, relativePath: relativePath) {
                    let oldFileWasDiscoverable = isDiscoverableFileID(oldFile.id)
                    removeFile(relativePath: relativePath, rootID: rootID)
                    if oldFileWasDiscoverable {
                        removedFileIDs.append(oldFile.id)
                        removedFilePaths.append(oldFile.standardizedRelativePath)
                    }
                }
            case .folderRemoved:
                if let oldFolder = folder(rootID: rootID, relativePath: relativePath) {
                    let oldFolderWasDiscoverable = isDiscoverableFolderID(oldFolder.id)
                    let removal = removeFolderTree(relativePath: relativePath, rootID: rootID)
                    removedFileIDs.append(contentsOf: removal.fileIDs)
                    removedFolderIDs.append(contentsOf: removal.folderIDs.isEmpty && oldFolderWasDiscoverable ? [oldFolder.id] : removal.folderIDs)
                    removedFilePaths.append(contentsOf: removal.filePaths)
                    removedFolderPaths.append(contentsOf: removal.folderPaths.isEmpty && oldFolderWasDiscoverable ? [oldFolder.standardizedRelativePath] : removal.folderPaths)
                }
            case .fileModified:
                if let file = file(rootID: rootID, relativePath: relativePath) {
                    invalidateSearchContent(file)
                    if isDiscoverableFileID(file.id) { modifiedFileIDs.append(file.id) }
                }
            case .folderModified:
                if let folder = folder(rootID: rootID, relativePath: relativePath), isDiscoverableFolderID(folder.id) {
                    modifiedFolderIDs.append(folder.id)
                }
            }
        }

        finalizePublicationInvalidations(invalidationBatch)
        publishAppliedIndexEvent(
            root: root,
            upsertedFiles: upsertedFiles,
            upsertedFolders: upsertedFolders,
            removedFileIDs: removedFileIDs,
            removedFolderIDs: removedFolderIDs,
            removedFilePaths: removedFilePaths,
            removedFolderPaths: removedFolderPaths,
            modifiedFileIDs: modifiedFileIDs,
            modifiedFolderIDs: modifiedFolderIDs,
            requiresFullResync: requiresFullResync
        )
    }

    func lookupPath(
        _ userPath: String,
        profile: PathLocateProfile = .uiAssisted,
        rootScope: WorkspaceLookupRootScope = .allLoaded
    ) async -> WorkspacePathLookupResult? {
        let request = WorkspacePathLookupRequest(userPath: userPath, profile: profile, rootScope: rootScope)
        return await lookupPath(request)
    }

    func lookupPath(_ request: WorkspacePathLookupRequest) async -> WorkspacePathLookupResult? {
        let normalizedPath = normalizeUserInputPath(request.userPath)
        guard !normalizedPath.isEmpty else { return nil }

        let selectedFileFullPaths = request.selectedFileFullPaths
        let staticData = buildStaticSnapshot(scope: request.rootScope)
        guard let match = await pathMatchWorker.locate(
            userPath: normalizedPath,
            profile: request.profile,
            staticData: staticData,
            selectedFileFullPaths: selectedFileFullPaths,
            selectionSig: selectionSignature(for: selectedFileFullPaths)
        ) else { return nil }
        return lookupResult(input: request.userPath, match: match)
    }

    func lookupPath(
        _ request: WorkspacePathLookupRequest,
        rootRefs: [WorkspaceRootRef]
    ) async -> WorkspacePathLookupResult? {
        let normalizedPath = normalizeUserInputPath(request.userPath)
        guard !normalizedPath.isEmpty else { return nil }

        let selectedFileFullPaths = request.selectedFileFullPaths
        let staticData = buildStaticSnapshot(scope: request.rootScope, rootRefs: rootRefs)
        guard let match = await pathMatchWorker.locate(
            userPath: normalizedPath,
            profile: request.profile,
            staticData: staticData,
            selectedFileFullPaths: selectedFileFullPaths,
            selectionSig: selectionSignature(for: selectedFileFullPaths)
        ) else { return nil }
        return lookupResult(input: request.userPath, match: match)
    }

    func lookupPaths(_ requests: [WorkspacePathLookupRequest]) async -> [String: WorkspacePathLookupResult] {
        struct LookupBatchKey: Hashable {
            let rootScope: WorkspaceLookupRootScope
            let profile: PathLocateProfile
            let selectedFileFullPaths: Set<String>
        }

        var grouped: [LookupBatchKey: [(original: String, normalized: String)]] = [:]
        for request in requests {
            let normalizedPath = normalizeUserInputPath(request.userPath)
            guard !normalizedPath.isEmpty else { continue }
            let key = LookupBatchKey(
                rootScope: request.rootScope,
                profile: request.profile,
                selectedFileFullPaths: request.selectedFileFullPaths
            )
            grouped[key, default: []].append((request.userPath, normalizedPath))
        }

        var results: [String: WorkspacePathLookupResult] = [:]
        for (key, paths) in grouped {
            let staticData = buildStaticSnapshot(scope: key.rootScope)
            let matches = await pathMatchWorker.locateMany(
                userPaths: paths.map(\.normalized),
                profile: key.profile,
                staticData: staticData,
                selectedFileFullPaths: key.selectedFileFullPaths,
                selectionSig: selectionSignature(for: key.selectedFileFullPaths)
            )
            for path in paths {
                guard let match = matches[path.normalized],
                      let result = lookupResult(input: path.original, match: match)
                else { continue }
                results[path.original] = result
            }
        }
        return results
    }

    func findCreationPath(
        userPath: String,
        rootScope: WorkspaceLookupRootScope = .allLoaded,
        selectedFileFullPaths: Set<String> = []
    ) async -> FileCreationResult? {
        let normalizedPath = normalizeUserInputPath(userPath)
        guard !normalizedPath.isEmpty else { return nil }
        let staticData = buildStaticSnapshot(scope: rootScope)
        return await pathMatchWorker.findCreationPath(
            userPath: normalizedPath,
            staticData: staticData,
            selectedFileFullPaths: selectedFileFullPaths,
            selectionSig: selectionSignature(for: selectedFileFullPaths)
        )
    }

    func resolveCreationPath(
        userPath: String,
        rootScope: WorkspaceLookupRootScope = .allLoaded,
        selectedFileFullPaths: Set<String> = [],
        mode: CreationResolutionMode
    ) async -> FileCreationResolution? {
        let normalizedPath = normalizeUserInputPath(userPath)
        guard !normalizedPath.isEmpty else { return nil }
        let staticData = buildStaticSnapshot(scope: rootScope)
        return await pathMatchWorker.resolveCreationPath(
            userPath: normalizedPath,
            staticData: staticData,
            selectedFileFullPaths: selectedFileFullPaths,
            selectionSig: selectionSignature(for: selectedFileFullPaths),
            mode: mode
        )
    }

    func lookupPath(rootID: UUID, relativePath: String) -> WorkspacePathLookupResult? {
        guard let state = rootStatesByID[rootID] else { return nil }
        let key = StandardizedPath.relative(relativePath)
        if let fileID = state.fileIDsByRelativePath[key], let file = filesByID[fileID] {
            return lookupResult(input: relativePath, root: state.root, correctedPath: file.standardizedRelativePath)
        }
        if let folderID = state.folderIDsByRelativePath[key], let folder = foldersByID[folderID] {
            return lookupResult(input: relativePath, root: state.root, correctedPath: folder.standardizedRelativePath)
        }
        return nil
    }

    func lookupDiscoverablePath(rootID: UUID, relativePath: String) -> WorkspacePathLookupResult? {
        guard publishedSeededAuthorityIsQueryable(rootID: rootID),
              let result = lookupPath(rootID: rootID, relativePath: relativePath),
              isDiscoverableLookupResult(result)
        else { return nil }
        return result
    }

    func lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(
        _ userPath: String,
        rootScope: WorkspaceLookupRootScope
    ) -> WorkspacePathLookupResult? {
        let trimmed = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !StandardizedPath.containsNUL(trimmed) else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        let standardizedPath = StandardizedPath.absolute(expanded)
        guard let root = rootsForPathLookup(scope: rootScope)
            .filter({ StandardizedPath.isDescendant(standardizedPath, of: $0.standardizedFullPath) })
            .max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count })
        else { return nil }
        let relativePath = relativePath(for: standardizedPath, rootPath: root.standardizedFullPath)
        guard let result = lookupPath(rootID: root.id, relativePath: relativePath),
              isDiscoverableLookupResult(result)
        else { return nil }
        return result
    }

    func rootRefs(scope: WorkspaceLookupRootScope = .allLoaded) -> [WorkspaceRootRef] {
        rootsForPathLookup(scope: scope).map {
            WorkspaceRootRef(id: $0.id, name: $0.name, fullPath: $0.standardizedFullPath)
        }
    }

    func codemapRootEpochs(scope: WorkspaceLookupRootScope = .allLoaded) -> [UUID: WorkspaceCodemapRootEpoch] {
        Dictionary(uniqueKeysWithValues: rootsForPathLookup(scope: scope).compactMap { root in
            guard let state = rootStatesByID[root.id] else { return nil }
            return (
                root.id,
                WorkspaceCodemapRootEpoch(rootID: root.id, rootLifetimeID: state.lifetimeID)
            )
        })
    }

    /// Returns one already-loaded root by exact path and kind without consulting a lookup scope.
    /// This is intentionally not a discovery API: it never loads, enumerates, or aliases roots.
    func exactRootRef(path: String, kind: WorkspaceRootKind) -> WorkspaceRootRef? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !StandardizedPath.containsNUL(trimmed),
              trimmed.hasPrefix("/")
        else { return nil }

        let standardizedPath = StandardizedPath.absolute(trimmed)
        guard let rootID = rootIDsByStandardizedPath[standardizedPath],
              let state = rootStatesByID[rootID],
              publishedSeededAuthorityIsQueryable(rootID: rootID),
              state.root.kind == kind,
              state.root.standardizedFullPath == standardizedPath
        else { return nil }

        return WorkspaceRootRef(
            id: state.root.id,
            name: state.root.name,
            fullPath: state.root.standardizedFullPath
        )
    }

    /// Resolves one Context Builder selection candidate against an exact Agent-owned
    /// session root. This route never consults another root, aliases, general lookup, or
    /// raw filesystem fallback.
    func resolveContextBuilderSelectionCandidate(
        path rawPath: String,
        authorization: WorkspaceSessionRootAuthorization,
        folderPolicy: SelectedGitDiffFolderPolicy
    ) async throws -> WorkspaceAuthorizedSelectionCandidateResolution {
        try Task.checkCancellation()
        if let mismatch = sessionRootAuthorizationMismatch(authorization) {
            return .staleAuthority(mismatch)
        }

        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !StandardizedPath.containsNUL(trimmed)
        else {
            return .blockedOrAmbiguous(.invalidPath)
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            return .blockedOrAmbiguous(.invalidPath)
        }
        let standardizedPath = StandardizedPath.absolute(expanded)
        let selectsAuthorizedRoot = standardizedPath == authorization.root.standardizedFullPath
        guard selectsAuthorizedRoot
            || StandardizedPath.isDescendant(
                standardizedPath,
                of: authorization.root.standardizedFullPath
            )
        else {
            return .blockedOrAmbiguous(.outsideAuthorizedRoot)
        }

        if selectsAuthorizedRoot {
            let expandsFolders = switch folderPolicy {
            case .filesOnly: false
            case .expandFolders: true
            }
            guard expandsFolders,
                  let folder = rootFolderRecord(rootID: authorization.root.id)
            else {
                return .noCandidate
            }
            if let mismatch = sessionRootAuthorizationMismatch(authorization) {
                return .staleAuthority(mismatch)
            }
            return .resolved(files: descendantFiles(in: folder.id), route: .catalogFolder)
        }

        let relativePath = relativePath(
            for: standardizedPath,
            rootPath: authorization.root.standardizedFullPath
        )
        guard !relativePath.isEmpty,
              relativePath != "..",
              !relativePath.hasPrefix("../")
        else {
            return .blockedOrAmbiguous(.outsideAuthorizedRoot)
        }
        guard let state = rootStatesByID[authorization.root.id] else {
            return .staleAuthority(.rootID)
        }

        let eligibility = await state.service.catalogRegularFileEligibility(
            relativePath: relativePath
        )
        #if DEBUG
            if let contextBuilderSelectionCandidateEligibilityDidResolveHandler {
                await contextBuilderSelectionCandidateEligibilityDidResolveHandler(authorization.root.id)
            }
        #endif
        try Task.checkCancellation()
        if let mismatch = sessionRootAuthorizationMismatch(authorization) {
            return .staleAuthority(mismatch)
        }

        switch eligibility {
        case .eligible, .ineligible(.ignored):
            if let record = file(rootID: authorization.root.id, relativePath: relativePath),
               record.rootID == authorization.root.id,
               record.standardizedFullPath == standardizedPath
            {
                return .resolved(files: [record], route: .catalogFile)
            }

            let registered = await state.service.registerExplicitlyManagedRegularFile(
                relativePath: relativePath
            )
            try Task.checkCancellation()
            if let mismatch = sessionRootAuthorizationMismatch(authorization) {
                return .staleAuthority(mismatch)
            }
            let managedOnly: Bool
            switch registered {
            case .eligible:
                managedOnly = false
            case .ineligible(.ignored):
                managedOnly = true
            case .ineligible(.missingOrDirectory):
                return .noCandidate
            case let .ineligible(reason):
                return .blockedOrAmbiguous(
                    contextBuilderSelectionCandidateBlock(for: reason)
                )
            }
            do {
                let record = try materializeCatalogRegularFile(
                    rootID: authorization.root.id,
                    relativePath: relativePath,
                    managedOnly: managedOnly
                )
                if let mismatch = sessionRootAuthorizationMismatch(authorization) {
                    return .staleAuthority(mismatch)
                }
                return .resolved(files: [record], route: .materializedFile)
            } catch {
                return .blockedOrAmbiguous(.materializationFailed)
            }

        case .ineligible(.missingOrDirectory):
            let expandsFolders = switch folderPolicy {
            case .filesOnly: false
            case .expandFolders: true
            }
            guard expandsFolders,
                  let folder = folder(rootID: authorization.root.id, relativePath: relativePath),
                  isDiscoverableFolderID(folder.id)
            else {
                return .noCandidate
            }
            if let mismatch = sessionRootAuthorizationMismatch(authorization) {
                return .staleAuthority(mismatch)
            }
            return .resolved(files: descendantFiles(in: folder.id), route: .catalogFolder)

        case let .ineligible(reason):
            return .blockedOrAmbiguous(
                contextBuilderSelectionCandidateBlock(for: reason)
            )
        }
    }

    private func contextBuilderSelectionCandidateBlock(
        for reason: CatalogRegularFileIneligibilityReason
    ) -> WorkspaceAuthorizedSelectionCandidateBlock {
        switch reason {
        case .invalidRelativePath:
            .invalidPath
        case .outsideRoot:
            .outsideAuthorizedRoot
        case .symbolicLink:
            .symbolicLink
        case .symlinkComponent:
            .symlinkComponent
        case .outsideCanonicalRoot:
            .outsideCanonicalRoot
        case .nonRegularFile:
            .nonRegularFile
        case .missingOrDirectory, .ignored:
            .materializationFailed
        }
    }

    /// Returns one exact catalog record under a previously frozen root identity.
    /// Missing records remain missing; this never materializes an ignored or on-disk file.
    func exactCatalogFile(
        absolutePath: String,
        expectedRoot: WorkspaceRootRef,
        expectedKind: WorkspaceRootKind
    ) -> WorkspaceFileRecord? {
        guard let state = exactRootState(expectedRoot: expectedRoot, expectedKind: expectedKind) else {
            return nil
        }
        guard publishedSeededAuthorityIsQueryable(rootID: state.root.id) else { return nil }

        let trimmed = absolutePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !StandardizedPath.containsNUL(trimmed),
              trimmed.hasPrefix("/")
        else { return nil }

        let standardizedPath = StandardizedPath.absolute(trimmed)
        guard StandardizedPath.isDescendant(standardizedPath, of: state.root.standardizedFullPath),
              standardizedPath != state.root.standardizedFullPath
        else { return nil }

        let relativePath = relativePath(for: standardizedPath, rootPath: state.root.standardizedFullPath)
        guard let record = file(rootID: state.root.id, relativePath: relativePath),
              record.rootID == state.root.id,
              record.standardizedFullPath == standardizedPath
        else { return nil }
        return record
    }

    /// Reads one exact, already-cataloged record and revalidates its root lifetime after the await.
    /// No raw absolute-path or filesystem fallback is permitted.
    func readExactCatalogFile(
        _ file: WorkspaceFileRecord,
        expectedRoot: WorkspaceRootRef
    ) async -> String? {
        guard await (try? requirePublishedSeededAuthorityFresh(rootID: file.rootID)) != nil else { return nil }
        guard let state = exactRootState(expectedRoot: expectedRoot, expectedKind: .workspaceGitData),
              file.rootID == state.root.id,
              let current = self.file(rootID: state.root.id, relativePath: file.standardizedRelativePath),
              current.id == file.id,
              current.standardizedFullPath == file.standardizedFullPath
        else { return nil }

        let expectedLifetimeID = state.lifetimeID
        let content = try? await state.service.loadContent(ofRelativePath: file.standardizedRelativePath)

        guard await (try? requirePublishedSeededAuthorityFresh(rootID: file.rootID)) != nil else { return nil }

        guard let currentState = rootStatesByID[expectedRoot.id],
              currentState.lifetimeID == expectedLifetimeID,
              currentState.root.standardizedFullPath == expectedRoot.standardizedFullPath,
              currentState.root.kind == .workspaceGitData,
              let revalidated = self.file(rootID: expectedRoot.id, relativePath: file.standardizedRelativePath),
              revalidated.id == file.id,
              revalidated.standardizedFullPath == file.standardizedFullPath
        else { return nil }
        return content
    }

    private func exactRootState(
        expectedRoot: WorkspaceRootRef,
        expectedKind: WorkspaceRootKind
    ) -> RootState? {
        guard let state = rootStatesByID[expectedRoot.id],
              state.root.id == expectedRoot.id,
              state.root.standardizedFullPath == expectedRoot.standardizedFullPath,
              state.root.kind == expectedKind
        else { return nil }
        return state
    }

    func displayRootRefsSnapshot() -> WorkspaceDisplayRootRefsSnapshot {
        WorkspaceDisplayRootRefsSnapshot(
            visibleRoots: rootRefs(scope: .visibleWorkspace),
            allRoots: rootRefs(scope: .allLoaded)
        )
    }

    func exactPathResolutionIssue(
        for userPath: String,
        kind: WorkspaceExactPathLookupKind,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) -> PathResolutionIssue? {
        exactPathResolutionIssue(
            for: userPath,
            kind: kind,
            rootRefs: rootRefs(scope: rootScope)
        )
    }

    func exactPathResolutionIssue(
        for userPath: String,
        kind: WorkspaceExactPathLookupKind,
        rootRefs roots: [WorkspaceRootRef]
    ) -> PathResolutionIssue? {
        let trimmedInput = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return .emptyInput }
        if StandardizedPath.containsNUL(trimmedInput) {
            return .invalidPathCharacters(
                input: trimmedInput,
                reason: "embedded NUL (\\0) characters are not allowed"
            )
        }
        let expanded = (trimmedInput as NSString).expandingTildeInPath
        let standardized = StandardizedPath.absolute(expanded)
        guard !standardized.hasPrefix("/") else { return nil }

        guard !roots.isEmpty else { return nil }

        switch WorkspaceAliasResolver.resolve(
            userPath: standardized,
            roots: roots,
            options: RootAliasOptions(requireRemainder: false, allowCompatibilityAlias: true)
        ) {
        case let .ambiguous(alias, matchingRoots):
            return .ambiguousAlias(alias: alias, matchingRoots: matchingRoots)
        case let .bareRoot(root, _):
            switch kind {
            case .folder, .either:
                if rootStatesByID[root.id] != nil { return nil }
            case .file:
                break
            }
        case let .prefixed(root, _, remainder):
            let absolute = StandardizedPath.join(
                standardizedRoot: root.standardizedFullPath,
                standardizedRelativePath: StandardizedPath.relative(remainder)
            )
            if exactRecordExists(standardizedFullPath: absolute, kind: kind) { return nil }
        case .notAliasPrefixed:
            break
        }

        let relative = StandardizedPath.relative(standardized.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        guard !relative.isEmpty else { return nil }
        let matchingRoots = roots.filter { root in
            let absolute = StandardizedPath.join(
                standardizedRoot: root.standardizedFullPath,
                standardizedRelativePath: relative
            )
            return exactRecordExists(standardizedFullPath: absolute, kind: kind)
        }
        guard matchingRoots.count > 1 else { return nil }
        return .ambiguousRootMatch(input: trimmedInput, candidateRoots: matchingRoots)
    }

    func lookupFiles(
        atPaths paths: [String],
        profile: PathLocateProfile = .mcpSelection,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> [String: WorkspaceFileRecord] {
        var files: [String: WorkspaceFileRecord] = [:]
        var generalLookupPaths: [String] = []
        for path in paths {
            switch lookupCatalogFileForExplicitRequest(path, rootScope: rootScope) {
            case let .matched(file):
                files[path] = file
                continue
            case .ambiguous, .blocked:
                continue
            case .noCandidate:
                break
            }
            switch try? await materializeExplicitlyRequestedFile(path, rootScope: rootScope) {
            case let .some(.materialized(file)):
                files[path] = file
            case .some(.ambiguous), .some(.blocked):
                continue
            case .some(.noCandidate), .none:
                generalLookupPaths.append(path)
            }
        }
        let requests = generalLookupPaths.map { WorkspacePathLookupRequest(userPath: $0, profile: profile, rootScope: rootScope) }
        let results = await lookupPaths(requests)
        for path in generalLookupPaths where files[path] == nil {
            if let file = results[path]?.file {
                files[path] = file
            }
        }
        return files
    }

    func resolveFolderInput(
        _ path: String,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        profile: PathLocateProfile = .mcpSelection
    ) async -> (folder: WorkspaceFolderRecord?, displayPath: String?, issue: PathResolutionIssue?) {
        await resolveFolderInput(
            path,
            rootScope: rootScope,
            profile: profile,
            rootRefs: rootRefs(scope: rootScope)
        )
    }

    func resolveFolderInput(
        _ path: String,
        rootScope: WorkspaceLookupRootScope,
        profile: PathLocateProfile,
        rootRefs roots: [WorkspaceRootRef],
        validateIssue: Bool = true,
        allowGeneralLookupFallback: Bool = true
    ) async -> (folder: WorkspaceFolderRecord?, displayPath: String?, issue: PathResolutionIssue?) {
        let cleaned = normalizeUserInputPath(path).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return (nil, nil, .emptyInput) }

        if validateIssue,
           let issue = exactPathResolutionIssue(for: cleaned, kind: .folder, rootRefs: roots)
        {
            return (nil, nil, issue)
        }

        if cleaned.hasPrefix("/") {
            if let folderID = folderIDsByStandardizedFullPath[StandardizedPath.absolute(cleaned)],
               isDiscoverableFolderID(folderID),
               let folder = foldersByID[folderID],
               let root = roots.first(where: { $0.id == folder.rootID })
            {
                return (folder, ClientPathFormatter.displayPath(root: root, relativePath: folder.standardizedRelativePath, visibleRoots: roots), nil)
            }
            let pseudoAlias = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            switch WorkspaceAliasResolver.resolve(userPath: pseudoAlias, roots: roots, options: RootAliasOptions(requireRemainder: false)) {
            case let .bareRoot(root, _):
                if let folder = rootFolderRecord(rootID: root.id) {
                    return (folder, ClientPathFormatter.displayPath(root: root, relativePath: "", visibleRoots: roots), nil)
                }
            case let .prefixed(root, _, remainder):
                if let folder = folder(rootID: root.id, relativePath: remainder), isDiscoverableFolderID(folder.id) {
                    return (folder, ClientPathFormatter.displayPath(root: root, relativePath: folder.standardizedRelativePath, visibleRoots: roots), nil)
                }
            case let .ambiguous(alias, matchingRoots):
                return (nil, nil, .ambiguousAlias(alias: alias, matchingRoots: matchingRoots))
            case .notAliasPrefixed:
                break
            }
        }

        switch WorkspaceAliasResolver.resolve(userPath: cleaned, roots: roots, options: RootAliasOptions(requireRemainder: false)) {
        case let .bareRoot(root, _):
            if let folder = rootFolderRecord(rootID: root.id) {
                return (folder, ClientPathFormatter.displayPath(root: root, relativePath: "", visibleRoots: roots), nil)
            }
        case let .prefixed(root, _, remainder):
            if let folder = folder(rootID: root.id, relativePath: remainder), isDiscoverableFolderID(folder.id) {
                return (folder, ClientPathFormatter.displayPath(root: root, relativePath: folder.standardizedRelativePath, visibleRoots: roots), nil)
            }
        case let .ambiguous(alias, matchingRoots):
            return (nil, nil, .ambiguousAlias(alias: alias, matchingRoots: matchingRoots))
        case .notAliasPrefixed:
            break
        }

        let relative = StandardizedPath.relative(cleaned)
        let directRelativeMatches = roots.compactMap { root -> (WorkspaceRootRef, WorkspaceFolderRecord)? in
            guard let folder = folder(rootID: root.id, relativePath: relative), isDiscoverableFolderID(folder.id) else { return nil }
            return (root, folder)
        }
        if directRelativeMatches.count == 1, let match = directRelativeMatches.first {
            return (
                match.1,
                ClientPathFormatter.displayPath(root: match.0, relativePath: match.1.standardizedRelativePath, visibleRoots: roots),
                nil
            )
        }

        guard allowGeneralLookupFallback else { return (nil, nil, nil) }
        let generalLookupState = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.folderResolutionGeneralLookupFallback)
        let lookup = await lookupPath(
            WorkspacePathLookupRequest(userPath: cleaned, profile: profile, rootScope: rootScope),
            rootRefs: roots
        )
        EditFlowPerf.end(
            EditFlowPerf.Stage.ReadFile.folderResolutionGeneralLookupFallback,
            generalLookupState,
            EditFlowPerf.Dimensions(outcome: lookup?.folder == nil ? "noFolder" : "folder")
        )
        if let folder = lookup?.folder,
           let root = roots.first(where: { $0.id == folder.rootID })
        {
            return (folder, ClientPathFormatter.displayPath(root: root, relativePath: folder.standardizedRelativePath, visibleRoots: roots), nil)
        }
        return (nil, nil, nil)
    }

    func expandFolderInputToFiles(
        _ path: String,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        profile: PathLocateProfile = .mcpSelection
    ) async -> WorkspaceFolderExpansionResult {
        let resolution = await resolveFolderInput(path, rootScope: rootScope, profile: profile)
        if let folder = resolution.folder {
            return WorkspaceFolderExpansionResult(
                files: descendantFiles(in: folder.id),
                handled: true,
                displayPath: resolution.displayPath,
                issue: nil
            )
        }
        if let issue = resolution.issue {
            return WorkspaceFolderExpansionResult(files: [], handled: false, displayPath: nil, issue: issue)
        }
        return WorkspaceFolderExpansionResult(files: [], handled: false, displayPath: nil, issue: .unresolved(input: path))
    }

    func resolveSelectedCodeStructureFiles(
        atPaths paths: [String],
        rootScope: WorkspaceLookupRootScope,
        maximumUniqueFileCount: Int
    ) async -> WorkspaceBoundedCodeStructureFileResolution {
        precondition(maximumUniqueFileCount > 0)
        #if DEBUG
            codeStructureSelectedMetadataResolutionRequestCountForTesting += 1
        #endif
        var files: [WorkspaceFileRecord] = []
        var seenStandardizedFullPaths = Set<String>()

        for path in paths {
            switch lookupCatalogFileForExplicitRequest(path, rootScope: rootScope) {
            case let .matched(file):
                guard seenStandardizedFullPaths.insert(file.standardizedFullPath).inserted else {
                    continue
                }
                files.append(file)
                if files.count > maximumUniqueFileCount {
                    return WorkspaceBoundedCodeStructureFileResolution(
                        files: files,
                        didExceedLimit: true,
                        visitedUniqueFileCount: files.count
                    )
                }
                continue
            case .ambiguous, .blocked:
                continue
            case .noCandidate:
                break
            }

            let folderResolution = await expandFolderInputToFiles(
                path,
                rootScope: rootScope,
                profile: .mcpSelection,
                excludingStandardizedFullPaths: seenStandardizedFullPaths,
                maximumUniqueFileCount: maximumUniqueFileCount - files.count,
                allowGeneralLookupFallback: false
            )
            guard folderResolution.handled else { continue }
            for file in folderResolution.files
                where seenStandardizedFullPaths.insert(file.standardizedFullPath).inserted
            {
                files.append(file)
            }
            if folderResolution.didExceedLimit {
                return WorkspaceBoundedCodeStructureFileResolution(
                    files: files,
                    didExceedLimit: true,
                    visitedUniqueFileCount: files.count
                )
            }
        }
        return WorkspaceBoundedCodeStructureFileResolution(
            files: files,
            didExceedLimit: false,
            visitedUniqueFileCount: files.count
        )
    }

    func expandFolderInputToFiles(
        _ path: String,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        profile: PathLocateProfile = .mcpSelection,
        excludingStandardizedFullPaths: Set<String>,
        maximumUniqueFileCount: Int,
        allowGeneralLookupFallback: Bool = true
    ) async -> WorkspaceBoundedFolderExpansionResult {
        precondition(maximumUniqueFileCount >= 0)
        let resolution = await resolveFolderInput(
            path,
            rootScope: rootScope,
            profile: profile,
            rootRefs: rootRefs(scope: rootScope),
            allowGeneralLookupFallback: allowGeneralLookupFallback
        )
        if let folder = resolution.folder {
            let traversal = boundedDescendantFiles(
                in: folder.id,
                excludingStandardizedFullPaths: excludingStandardizedFullPaths,
                maximumUniqueFileCount: maximumUniqueFileCount
            )
            return WorkspaceBoundedFolderExpansionResult(
                files: traversal.files,
                handled: true,
                displayPath: resolution.displayPath,
                issue: nil,
                didExceedLimit: traversal.didExceedLimit,
                visitedUniqueFileCount: traversal.files.count
            )
        }
        if let issue = resolution.issue {
            return WorkspaceBoundedFolderExpansionResult(
                files: [],
                handled: false,
                displayPath: nil,
                issue: issue,
                didExceedLimit: false,
                visitedUniqueFileCount: 0
            )
        }
        return WorkspaceBoundedFolderExpansionResult(
            files: [],
            handled: false,
            displayPath: nil,
            issue: .unresolved(input: path),
            didExceedLimit: false,
            visitedUniqueFileCount: 0
        )
    }

    private func boundedDescendantFiles(
        in folderID: UUID,
        excludingStandardizedFullPaths: Set<String>,
        maximumUniqueFileCount: Int
    ) -> (files: [WorkspaceFileRecord], didExceedLimit: Bool) {
        guard let folder = foldersByID[folderID],
              let state = rootStatesByID[folder.rootID]
        else { return ([], false) }

        var files: [WorkspaceFileRecord] = []
        var seenStandardizedFullPaths = excludingStandardizedFullPaths
        var visitedFolderIDs = Set<UUID>()

        func visit(_ currentFolderID: UUID) -> Bool {
            guard visitedFolderIDs.insert(currentFolderID).inserted else { return false }

            for fileID in state.childFileIDsByFolderID[currentFolderID] ?? [] {
                guard isDiscoverableFileID(fileID),
                      let file = filesByID[fileID],
                      seenStandardizedFullPaths.insert(file.standardizedFullPath).inserted
                else { continue }
                files.append(file)
                if files.count > maximumUniqueFileCount { return true }
            }
            for childFolderID in state.childFolderIDsByFolderID[currentFolderID] ?? [] {
                guard isDiscoverableFolderID(childFolderID) else { continue }
                if visit(childFolderID) { return true }
            }
            return false
        }

        let didExceedLimit = visit(folderID)
        return (files, didExceedLimit)
    }

    private func exactRecordExists(standardizedFullPath: String, kind: WorkspaceExactPathLookupKind) -> Bool {
        let absolute = StandardizedPath.absolute(standardizedFullPath)
        switch kind {
        case .file:
            return fileIDsByStandardizedFullPath[absolute] != nil
        case .folder:
            return folderIDsByStandardizedFullPath[absolute].map(isDiscoverableFolderID) ?? false
        case .either:
            return fileIDsByStandardizedFullPath[absolute] != nil || (folderIDsByStandardizedFullPath[absolute].map(isDiscoverableFolderID) ?? false)
        }
    }

    private func rootFolderRecord(rootID: UUID) -> WorkspaceFolderRecord? {
        guard let state = rootStatesByID[rootID],
              let folderID = state.folderIDsByRelativePath[""]
        else { return nil }
        return foldersByID[folderID]
    }

    private func descendantFiles(in folderID: UUID) -> [WorkspaceFileRecord] {
        guard let folder = foldersByID[folderID], let state = rootStatesByID[folder.rootID] else { return [] }
        let ids = descendantFileIDs(in: folderID, state: state)
        return ids.compactMap { filesByID[$0] }
            .sorted { $0.standardizedRelativePath < $1.standardizedRelativePath }
    }

    private func lookupResult(input: String, match: PathMatchLocation) -> WorkspacePathLookupResult? {
        let rootPath = (match.rootPath as NSString).standardizingPath
        guard let rootID = rootIDsByStandardizedPath[rootPath],
              let state = rootStatesByID[rootID]
        else { return nil }
        return lookupResult(input: input, root: state.root, correctedPath: match.correctedPath)
    }

    private func lookupResult(input: String, root: WorkspaceRootRecord, correctedPath: String) -> WorkspacePathLookupResult? {
        let correctedPath = StandardizedPath.relative(correctedPath)
        let fullPath = ((root.standardizedFullPath as NSString).appendingPathComponent(correctedPath) as NSString).standardizingPath
        let file = fileIDsByStandardizedFullPath[fullPath].flatMap { filesByID[$0] }
        let folder = folderIDsByStandardizedFullPath[fullPath].flatMap { foldersByID[$0] }
        guard file != nil || folder != nil else { return nil }
        return WorkspacePathLookupResult(
            input: input,
            location: WorkspacePathLocation(rootID: root.id, rootPath: root.standardizedFullPath, correctedPath: correctedPath),
            file: file,
            folder: folder
        )
    }

    private func buildStaticSnapshot(scope: WorkspaceLookupRootScope) -> StaticPathMatchData {
        let cacheIdentity = pathMatchCacheIdentity(scope: scope)
        if var cached = staticPathMatchSnapshotsByScope[scope],
           cached.snapshot.cacheIdentity == cacheIdentity
        {
            cached.lastAccessSequence = nextStaticPathMatchSnapshotAccessSequenceValue()
            staticPathMatchSnapshotsByScope[scope] = cached
            return cached.snapshot
        }
        let snapshot = buildStaticSnapshot(
            rootRefs: rootRefs(scope: scope),
            cacheIdentity: cacheIdentity
        )
        cacheStaticPathMatchSnapshot(snapshot, scope: scope)
        return snapshot
    }

    private func buildStaticSnapshot(
        scope: WorkspaceLookupRootScope,
        rootRefs roots: [WorkspaceRootRef]
    ) -> StaticPathMatchData {
        buildStaticSnapshot(
            rootRefs: roots,
            cacheIdentity: pathMatchCacheIdentity(scope: scope, rootRefs: roots)
        )
    }

    private func buildStaticSnapshot(
        rootRefs roots: [WorkspaceRootRef],
        cacheIdentity: PathMatchCacheIdentity
    ) -> StaticPathMatchData {
        let snapshotState = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.pathLookupStaticSnapshotBuild)
        defer { EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.pathLookupStaticSnapshotBuild, snapshotState) }
        let allowedRootIDs = Set(roots.map(\.id))
        var fileRecords: [String: FileRecord] = [:]
        for file in filesByID.values.sorted(by: { $0.standardizedFullPath < $1.standardizedFullPath }) {
            guard allowedRootIDs.contains(file.rootID),
                  isDiscoverableFileID(file.id),
                  let root = rootStatesByID[file.rootID]?.root,
                  fileRecords[file.standardizedFullPath] == nil
            else { continue }
            fileRecords[file.standardizedFullPath] = FrozenFileRecord(
                name: file.name,
                relativePath: file.standardizedRelativePath,
                fullPath: file.standardizedFullPath,
                rootFolderPath: root.standardizedFullPath
            ) as FileRecord
        }
        var folderRecords: [String: FolderRecord] = [:]
        for folder in foldersByID.values.sorted(by: { $0.standardizedFullPath < $1.standardizedFullPath }) {
            guard allowedRootIDs.contains(folder.rootID),
                  isDiscoverableFolderID(folder.id),
                  let root = rootStatesByID[folder.rootID]?.root,
                  folderRecords[folder.standardizedFullPath] == nil
            else { continue }
            folderRecords[folder.standardizedFullPath] = FrozenFolderRecord(
                name: folder.name,
                relativePath: folder.standardizedRelativePath,
                fullPath: folder.standardizedFullPath,
                rootPath: root.standardizedFullPath,
                displayName: folder.name
            ) as FolderRecord
        }
        let rootFolders: [FolderRecord] = roots.compactMap { root in
            guard let folderID = rootStatesByID[root.id]?.folderIDsByRelativePath[""],
                  let folder = foldersByID[folderID]
            else { return nil }
            return FrozenFolderRecord(
                name: folder.name,
                relativePath: "",
                fullPath: folder.standardizedFullPath,
                rootPath: root.standardizedFullPath,
                displayName: folder.name
            ) as FolderRecord
        }
        return StaticPathMatchData(
            filesByFullPath: fileRecords,
            foldersByFullPath: folderRecords,
            rootFolders: rootFolders,
            cacheScopeID: cacheIdentity.scopeID,
            id: cacheIdentity.snapshotID
        )
    }

    private func cacheStaticPathMatchSnapshot(
        _ snapshot: StaticPathMatchData,
        scope: WorkspaceLookupRootScope
    ) {
        if staticPathMatchSnapshotsByScope[scope] == nil,
           staticPathMatchSnapshotsByScope.count >= Self.maxCachedStaticPathMatchSnapshotScopes,
           let eviction = staticPathMatchSnapshotsByScope.min(by: {
               $0.value.lastAccessSequence < $1.value.lastAccessSequence
           })
        {
            staticPathMatchSnapshotsByScope.removeValue(forKey: eviction.key)
            if pathMatchSnapshotIdentitiesByScope[eviction.key] == eviction.value.snapshot.cacheIdentity {
                pathMatchSnapshotIdentitiesByScope.removeValue(forKey: eviction.key)
            }
            invalidatePathMatchCache(snapshotIdentities: [eviction.value.snapshot.cacheIdentity])
        }
        pathMatchSnapshotIdentitiesByScope[scope] = snapshot.cacheIdentity
        staticPathMatchSnapshotsByScope[scope] = StaticPathMatchSnapshotCacheEntry(
            snapshot: snapshot,
            lastAccessSequence: nextStaticPathMatchSnapshotAccessSequenceValue()
        )
    }

    private func nextStaticPathMatchSnapshotAccessSequenceValue() -> UInt64 {
        nextStaticPathMatchSnapshotAccessSequence &+= 1
        return nextStaticPathMatchSnapshotAccessSequence
    }

    private func pathMatchCacheIdentity(scope: WorkspaceLookupRootScope) -> PathMatchCacheIdentity {
        PathMatchCacheIdentity(
            scopeID: scopeDiscriminator(scope),
            snapshotID: scopedSnapshotGeneration(scope: scope)
        )
    }

    private func pathMatchCacheIdentity(
        scope: WorkspaceLookupRootScope,
        rootRefs roots: [WorkspaceRootRef]
    ) -> PathMatchCacheIdentity {
        var hasher = Hasher()
        hasher.combine("explicitRootRefs")
        hasher.combine(scopeDiscriminator(scope))
        for root in roots {
            hasher.combine(root.id)
            hasher.combine(root.standardizedFullPath)
            hasher.combine(rootStatesByID[root.id]?.lifetimeID)
            hasher.combine(catalogGenerationsByRootID[root.id] ?? 0)
        }
        return PathMatchCacheIdentity(
            scopeID: scopeDiscriminator(scope),
            snapshotID: UInt64(bitPattern: Int64(hasher.finalize()))
        )
    }

    #if DEBUG
        func staticPathMatchSnapshotCacheCountForTesting() -> Int {
            staticPathMatchSnapshotsByScope.count
        }

        func searchCatalogSnapshotCacheCountForTesting() -> Int {
            searchCatalogSnapshotsByScope.count
        }

        func sessionCatalogGenerationForTesting(scope: WorkspaceLookupRootScope) -> UInt64? {
            sessionCatalogGenerationStatesByScope[scope]?.generation
        }
    #endif

    private func scopedSnapshotGeneration(scope: WorkspaceLookupRootScope) -> UInt64 {
        scopedSnapshotGeneration(
            scope: scope,
            validationToken: searchCatalogSnapshotValidationToken(scope: scope)
        )
    }

    private func scopedSnapshotGeneration(
        scope: WorkspaceLookupRootScope,
        validationToken: SearchCatalogSnapshotValidationToken
    ) -> UInt64 {
        switch validationToken {
        case let .staticScope(generation):
            return generation
        case .sessionBound:
            if let state = sessionCatalogGenerationStatesByScope[scope],
               state.validationToken == validationToken
            {
                return state.generation
            }
            nextSessionCatalogGeneration &+= 1
            let generation = nextSessionCatalogGeneration
            sessionCatalogGenerationStatesByScope[scope] = SessionCatalogGenerationState(
                validationToken: validationToken,
                generation: generation
            )
            return generation
        }
    }

    private func searchCatalogSnapshotValidationToken(
        scope: WorkspaceLookupRootScope
    ) -> SearchCatalogSnapshotValidationToken {
        switch scope {
        case .visibleWorkspace, .visibleWorkspacePlusGitData, .allLoaded, .allLoadedExcludingGitData:
            var hasher = Hasher()
            hasher.combine((catalogGenerationsByScope[scope] ?? 0) &* 3 &+ scopeDiscriminator(scope))
            for root in rootsForPathLookupIgnoringPublishedAuthority(scope: scope) {
                guard publishedSeededAuthorityFencesByRootID[root.id] != nil else { continue }
                hasher.combine(root.id)
                hasher.combine(publishedSeededAuthorityStatesByRootID[root.id]?.epoch ?? 0)
                hasher.combine(publishedSeededAuthorityIsQueryable(rootID: root.id))
            }
            let generation = UInt64(bitPattern: Int64(hasher.finalize()))
            return .staticScope(generation: generation)
        case let .sessionBoundWorkspace(logicalRootPaths, physicalRootPaths):
            let normalizedLogicalRootPaths = normalizedSessionSelectorPaths(logicalRootPaths).sorted()
            let normalizedPhysicalRootPaths = normalizedSessionSelectorPaths(physicalRootPaths).sorted()
            let dependencies = rootsForPathLookup(scope: scope).compactMap { root -> SearchCatalogRootDependency? in
                guard let state = rootStatesByID[root.id] else { return nil }
                return SearchCatalogRootDependency(
                    canonicalIdentity: root.standardizedFullPath,
                    rootID: root.id,
                    lifetimeID: state.lifetimeID,
                    generation: catalogGenerationsByRootID[root.id] ?? 0
                )
            }.sorted {
                if $0.canonicalIdentity == $1.canonicalIdentity {
                    return $0.rootID.uuidString < $1.rootID.uuidString
                }
                return $0.canonicalIdentity < $1.canonicalIdentity
            }
            return .sessionBound(
                logicalRootPaths: normalizedLogicalRootPaths,
                physicalRootPaths: normalizedPhysicalRootPaths,
                dependencies: dependencies
            )
        case let .validatedSessionBoundWorkspace(canonicalRoots, physicalRoots):
            let normalizedLogicalRootPaths = canonicalRoots.map(\.standardizedFullPath).sorted()
            let normalizedPhysicalRootPaths = physicalRoots.map(\.standardizedFullPath).sorted()
            let dependencies = rootsForPathLookup(scope: scope).compactMap { root -> SearchCatalogRootDependency? in
                guard let state = rootStatesByID[root.id] else { return nil }
                return SearchCatalogRootDependency(
                    canonicalIdentity: root.standardizedFullPath,
                    rootID: root.id,
                    lifetimeID: state.lifetimeID,
                    generation: catalogGenerationsByRootID[root.id] ?? 0
                )
            }.sorted {
                if $0.canonicalIdentity == $1.canonicalIdentity {
                    return $0.rootID.uuidString < $1.rootID.uuidString
                }
                return $0.canonicalIdentity < $1.canonicalIdentity
            }
            return .sessionBound(
                logicalRootPaths: normalizedLogicalRootPaths,
                physicalRootPaths: normalizedPhysicalRootPaths,
                dependencies: dependencies
            )
        }
    }

    private func cacheSearchCatalogSnapshot(
        _ snapshot: WorkspaceSearchCatalogSnapshot,
        validationToken: SearchCatalogSnapshotValidationToken,
        capability: WorkspaceSearchCatalogAccessRequirement,
        scope: WorkspaceLookupRootScope
    ) {
        if searchCatalogSnapshotsByScope[scope] == nil,
           searchCatalogSnapshotsByScope.count >= Self.maxCachedSearchCatalogSnapshotScopes,
           let eviction = searchCatalogSnapshotsByScope.min(by: {
               $0.value.lastAccessSequence < $1.value.lastAccessSequence
           })
        {
            evictSearchCatalogSnapshots(
                scopes: [eviction.key],
                reasons: [.cacheCapacity],
                affectedRootIDs: Set(eviction.value.snapshot.roots.map(\.id)),
                affectedRootKinds: Set(eviction.value.snapshot.roots.map(\.kind))
            )
        }
        searchCatalogSnapshotsByScope[scope] = SearchCatalogSnapshotCacheEntry(
            validationToken: validationToken,
            capability: capability,
            snapshot: snapshot,
            lastAccessSequence: nextSearchCatalogAccessSequence()
        )
    }

    private func nextSearchCatalogAccessSequence() -> UInt64 {
        nextSearchCatalogSnapshotAccessSequence &+= 1
        return nextSearchCatalogSnapshotAccessSequence
    }

    private func scopeDiscriminator(_ scope: WorkspaceLookupRootScope) -> UInt64 {
        switch scope {
        case .visibleWorkspace:
            return 0
        case .visibleWorkspacePlusGitData:
            return 1
        case .allLoaded:
            return 2
        case .allLoadedExcludingGitData:
            return 3
        case let .sessionBoundWorkspace(canonicalRootPaths, physicalRootPaths):
            var hasher = Hasher()
            hasher.combine("sessionBoundWorkspace")
            hasher.combine(normalizedSessionSelectorPaths(canonicalRootPaths).sorted())
            hasher.combine(normalizedSessionSelectorPaths(physicalRootPaths).sorted())
            return UInt64(bitPattern: Int64(hasher.finalize()))
        case let .validatedSessionBoundWorkspace(canonicalRoots, physicalRoots):
            var hasher = Hasher()
            hasher.combine("validatedSessionBoundWorkspace")
            hasher.combine(canonicalRoots.sorted { $0.id.uuidString < $1.id.uuidString })
            hasher.combine(physicalRoots.sorted { $0.id.uuidString < $1.id.uuidString })
            return UInt64(bitPattern: Int64(hasher.finalize()))
        }
    }

    private func withCodemapPathLocalCatalogMutation<T>(
        rootID: UUID,
        _ body: () throws -> T
    ) rethrows -> T {
        codemapPathLocalCatalogMutationDepthByRootID[rootID, default: 0] += 1
        defer {
            let next = (codemapPathLocalCatalogMutationDepthByRootID[rootID] ?? 1) - 1
            if next == 0 {
                codemapPathLocalCatalogMutationDepthByRootID.removeValue(forKey: rootID)
            } else {
                codemapPathLocalCatalogMutationDepthByRootID[rootID] = next
            }
        }
        return try body()
    }

    private func bumpCatalogGenerations(
        affectedRootKinds: Set<WorkspaceRootKind>,
        affectedRootIDs: Set<UUID>
    ) {
        guard !affectedRootKinds.isEmpty || !affectedRootIDs.isEmpty else { return }
        for scope in WorkspaceFileContextStore.catalogGenerationScopes {
            guard scopeIncludesAnyRootKind(scope, affectedRootKinds) else { continue }
            catalogGenerationsByScope[scope] = (catalogGenerationsByScope[scope] ?? 0) &+ 1
            #if DEBUG
                Self.activePublicationInvalidationRecorder?.catalogGenerationAdvanceCount += 1
            #endif
        }
        let rootIDsToAdvance = affectedRootIDs.isEmpty
            ? Set(rootStatesByID.values.compactMap { affectedRootKinds.contains($0.root.kind) ? $0.root.id : nil })
            : affectedRootIDs
        for rootID in rootIDsToAdvance {
            catalogGenerationsByRootID[rootID] = (catalogGenerationsByRootID[rootID] ?? 0) &+ 1
        }
        let rootIDsRequiringAuthorityFence = rootIDsToAdvance.filter {
            codemapPathLocalCatalogMutationDepthByRootID[$0] == nil
        }
        let rootEpochsRequiringAuthorityFence = Set(codemapSessionsByRootEpoch.keys)
            .union(codemapProjectionPreloadLaunchesByRootEpoch.keys)
            .union(codemapEligibilityFlightsByRootEpoch.keys)
            .union(codemapCompletedEligibilityByRootEpoch.keys)
            .union(codemapProjectionPreloadRetriesByRootEpoch.keys)
            .filter { rootIDsRequiringAuthorityFence.contains($0.rootID) }
        for rootEpoch in rootEpochsRequiringAuthorityFence {
            _ = detachCodemapSession(
                rootEpoch: rootEpoch,
                invalidationCommands: [.catalogAdvanced]
            )
        }
    }

    private static let catalogGenerationScopes: [WorkspaceLookupRootScope] = [
        .visibleWorkspace,
        .visibleWorkspacePlusGitData,
        .allLoaded,
        .allLoadedExcludingGitData
    ]

    private func scopeIncludesAnyRootKind(_ scope: WorkspaceLookupRootScope, _ kinds: Set<WorkspaceRootKind>) -> Bool {
        switch scope {
        case .visibleWorkspace:
            kinds.contains(.primaryWorkspace)
        case .visibleWorkspacePlusGitData:
            kinds.contains(.primaryWorkspace) || kinds.contains(.workspaceGitData)
        case .allLoaded:
            true
        case .allLoadedExcludingGitData:
            kinds.contains { $0 != .workspaceGitData }
        case .sessionBoundWorkspace, .validatedSessionBoundWorkspace:
            kinds.contains(.primaryWorkspace) || kinds.contains(.sessionWorktree)
        }
    }

    private func normalizedSessionSelectorPaths(_ paths: Set<String>) -> Set<String> {
        Set(paths.map { StandardizedPath.absolute(($0 as NSString).expandingTildeInPath) })
    }

    private func rootsForPathLookup(scope: WorkspaceLookupRootScope) -> [WorkspaceRootRecord] {
        rootsForPathLookupIgnoringPublishedAuthority(scope: scope).filter {
            publishedSeededAuthorityIsQueryable(rootID: $0.id)
        }
    }

    private func rootsForPathLookupIgnoringPublishedAuthority(
        scope: WorkspaceLookupRootScope
    ) -> [WorkspaceRootRecord] {
        let allRoots = roots()
        switch scope {
        case .visibleWorkspace:
            return allRoots.filter { $0.kind == .primaryWorkspace }
        case .visibleWorkspacePlusGitData:
            return allRoots.filter { $0.kind == .primaryWorkspace || $0.kind == .workspaceGitData }
        case .allLoaded:
            return allRoots
        case .allLoadedExcludingGitData:
            return allRoots.filter { $0.kind != .workspaceGitData }
        case let .sessionBoundWorkspace(canonicalRootPaths, physicalRootPaths):
            let normalizedCanonicalRootPaths = normalizedSessionSelectorPaths(canonicalRootPaths)
            let normalizedPhysicalRootPaths = normalizedSessionSelectorPaths(physicalRootPaths)
            return allRoots.filter { root in
                switch root.kind {
                case .primaryWorkspace:
                    normalizedCanonicalRootPaths.contains(root.standardizedFullPath)
                case .sessionWorktree:
                    normalizedPhysicalRootPaths.contains(root.standardizedFullPath)
                case .workspaceGitData, .supplementalSystem:
                    false
                }
            }
        case let .validatedSessionBoundWorkspace(canonicalRoots, physicalRoots):
            let canonicalByID = Dictionary(uniqueKeysWithValues: canonicalRoots.map { ($0.id, $0) })
            let physicalByID = Dictionary(uniqueKeysWithValues: physicalRoots.map { ($0.id, $0) })
            return allRoots.filter { root in
                switch root.kind {
                case .primaryWorkspace:
                    canonicalByID[root.id]?.standardizedFullPath == root.standardizedFullPath
                case .sessionWorktree:
                    physicalByID[root.id]?.standardizedFullPath == root.standardizedFullPath
                case .workspaceGitData, .supplementalSystem:
                    false
                }
            }
        }
    }

    private func normalizeUserInputPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }

    @discardableResult
    private func evictInvalidSearchCatalogSnapshots(
        reasons: Set<CatalogInvalidationReason>,
        affectedRootIDs: Set<UUID> = [],
        affectedRootKinds: Set<WorkspaceRootKind> = []
    ) -> [WorkspaceLookupRootScope] {
        let scopes = Set(searchCatalogSnapshotsByScope.compactMap { scope, entry in
            entry.validationToken == searchCatalogSnapshotValidationToken(scope: scope) ? nil : scope
        })
        return evictSearchCatalogSnapshots(
            scopes: scopes,
            reasons: reasons,
            affectedRootIDs: affectedRootIDs,
            affectedRootKinds: affectedRootKinds
        )
    }

    @discardableResult
    private func evictSearchCatalogSnapshots(
        scopes: Set<WorkspaceLookupRootScope>,
        reasons: Set<CatalogInvalidationReason>,
        affectedRootIDs: Set<UUID> = [],
        affectedRootKinds: Set<WorkspaceRootKind> = []
    ) -> [WorkspaceLookupRootScope] {
        let evictedScopes = Array(scopes).filter { searchCatalogSnapshotsByScope.removeValue(forKey: $0) != nil }
        #if DEBUG
            Self.activePublicationInvalidationRecorder?.searchCatalogCacheClearCount += 1
            recordCatalogInvalidation(
                reasons: reasons,
                affectedRootIDs: affectedRootIDs,
                affectedRootKinds: affectedRootKinds,
                evictedScopes: evictedScopes
            )
        #endif
        return evictedScopes
    }

    private func staleSearchContentSnapshot(for record: WorkspaceFileRecord) -> FileSearchContentSnapshot {
        FileSearchContentSnapshot(
            content: nil,
            contentRevision: nil,
            modificationDate: record.modificationDate ?? .distantPast,
            isFresh: false
        )
    }

    private func searchContentRecordIsCurrent(
        _ record: WorkspaceFileRecord,
        invalidationEpoch: UInt64
    ) -> Bool {
        guard let current = file(rootID: record.rootID, relativePath: record.standardizedRelativePath),
              current.id == record.id
        else { return false }
        return (searchContentInvalidationEpochsByFileID[record.id] ?? 0) == invalidationEpoch
    }

    private func pruneCatalogFileIfStillCurrent(_ record: WorkspaceFileRecord) async {
        guard let current = file(rootID: record.rootID, relativePath: record.standardizedRelativePath),
              current.id == record.id
        else { return }
        _ = await fenceAndPruneCatalogFileMissingOnDisk(
            rootID: current.rootID,
            relativePath: current.standardizedRelativePath,
            publishDelta: true
        )
    }

    private func retainSliceRebaseSource(
        content: String?,
        modificationDate: Date,
        file: WorkspaceFileRecord,
        rootLifetimeID: UUID
    ) {
        guard let content else { return }
        let byteCost = content.utf8.count
        guard byteCost <= Self.maxSliceRebaseSourceEntryBytes,
              let state = rootStatesByID[file.rootID],
              state.lifetimeID == rootLifetimeID,
              self.file(rootID: file.rootID, relativePath: file.standardizedRelativePath)?.id == file.id
        else { return }
        let key = SliceRebaseSourceCacheKey(
            rootID: file.rootID,
            rootLifetimeID: rootLifetimeID,
            fileID: file.id,
            relativePath: file.standardizedRelativePath
        )
        if let previous = sliceRebaseSourceEntries.removeValue(forKey: key) {
            sliceRebaseSourceEstimatedBytes -= previous.byteCost
        }
        sliceRebaseSourceAccessOrdinal &+= 1
        let snapshot = WorkspaceSliceRebaseSourceSnapshot(
            rootID: file.rootID,
            rootLifetimeID: rootLifetimeID,
            fileID: file.id,
            relativePath: file.standardizedRelativePath,
            fullPath: file.standardizedFullPath,
            text: content,
            modificationTime: modificationDate.timeIntervalSince1970
        )
        sliceRebaseSourceEntries[key] = SliceRebaseSourceCacheEntry(
            snapshot: snapshot,
            byteCost: byteCost,
            accessOrdinal: sliceRebaseSourceAccessOrdinal
        )
        sliceRebaseSourceEstimatedBytes += byteCost
        trimSliceRebaseSourcesIfNeeded()
    }

    private func takeSliceRebaseSource(
        rootID: UUID,
        rootLifetimeID: UUID,
        file: WorkspaceFileRecord
    ) -> WorkspaceSliceRebaseSourceSnapshot? {
        let key = SliceRebaseSourceCacheKey(
            rootID: rootID,
            rootLifetimeID: rootLifetimeID,
            fileID: file.id,
            relativePath: file.standardizedRelativePath
        )
        guard let entry = sliceRebaseSourceEntries.removeValue(forKey: key) else { return nil }
        sliceRebaseSourceEstimatedBytes -= entry.byteCost
        guard entry.snapshot.fullPath == file.standardizedFullPath else { return nil }
        if let recordTime = file.modificationDate?.timeIntervalSince1970,
           abs(recordTime - entry.snapshot.modificationTime) > 0.001
        {
            return nil
        }
        return entry.snapshot
    }

    private func trimSliceRebaseSourcesIfNeeded() {
        while sliceRebaseSourceEntries.count > Self.maxSliceRebaseSourceEntryCount
            || sliceRebaseSourceEstimatedBytes > Self.maxSliceRebaseSourceTotalBytes
        {
            guard let oldest = sliceRebaseSourceEntries.min(by: { $0.value.accessOrdinal < $1.value.accessOrdinal }) else {
                break
            }
            sliceRebaseSourceEstimatedBytes -= oldest.value.byteCost
            sliceRebaseSourceEntries.removeValue(forKey: oldest.key)
        }
    }

    private func clearSliceRebaseSources() {
        sliceRebaseSourceEntries.removeAll(keepingCapacity: true)
        sliceRebaseSourceEstimatedBytes = 0
    }

    private func removeSliceRebaseSources(
        rootID: UUID,
        rootLifetimeID: UUID? = nil,
        fileID: UUID? = nil
    ) {
        let keys = sliceRebaseSourceEntries.keys.filter { key in
            guard key.rootID == rootID else { return false }
            if let rootLifetimeID, key.rootLifetimeID != rootLifetimeID { return false }
            if let fileID, key.fileID != fileID { return false }
            return true
        }
        for key in keys {
            if let removed = sliceRebaseSourceEntries.removeValue(forKey: key) {
                sliceRebaseSourceEstimatedBytes -= removed.byteCost
            }
        }
    }

    func sliceRebasePathState(fullPath rawFullPath: String) -> WorkspaceSliceRebasePathState? {
        let fullPath = StandardizedPath.absolute(rawFullPath)
        guard let root = rootStatesByID.values
            .map(\.root)
            .filter({ fullPath == $0.standardizedFullPath || fullPath.hasPrefix($0.standardizedFullPath + "/") })
            .max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count }),
            let state = rootStatesByID[root.id]
        else { return nil }
        return WorkspaceSliceRebasePathState(
            rootID: root.id,
            rootLifetimeID: state.lifetimeID,
            rootKind: root.kind,
            appliedIndexGeneration: appliedIndexGenerationsByRootID[root.id] ?? 0
        )
    }

    func sliceRebaseFileIsCurrent(
        rootID: UUID,
        rootLifetimeID: UUID,
        fileID: UUID,
        relativePath: String,
        fullPath: String
    ) -> Bool {
        guard let state = rootStatesByID[rootID], state.lifetimeID == rootLifetimeID,
              let current = file(rootID: rootID, relativePath: relativePath)
        else { return false }
        return current.id == fileID && current.standardizedFullPath == StandardizedPath.absolute(fullPath)
    }

    private func invalidateSearchContent(_ file: WorkspaceFileRecord) {
        let key = WorkspaceSearchContentCacheKey(
            rootID: file.rootID,
            fileID: file.id,
            standardizedRelativePath: file.standardizedRelativePath
        )
        #if DEBUG
            if let recorder = Self.activePublicationInvalidationRecorder {
                recorder.contentInvalidationCount += 1
                recorder.distinctContentKeys.insert(key)
            }
        #endif
        nextSearchContentInvalidationEpoch &+= 1
        let invalidationEpoch = nextSearchContentInvalidationEpoch
        searchContentInvalidationEpochsByFileID[file.id] = invalidationEpoch
        if let activePublicationInvalidationBatch {
            activePublicationInvalidationBatch.searchContentInvalidations.record(key, through: invalidationEpoch)
            return
        }
        Task {
            await searchDecodedContentCache.invalidate(key, through: invalidationEpoch)
            await interactiveReadCache.invalidate(key, through: invalidationEpoch)
        }
    }

    private func invalidateRetainedSearchContentForRecoveryUncertainty(rootID: UUID) async {
        guard let state = rootStatesByID[rootID] else { return }
        var invalidations = WorkspaceSearchContentInvalidationBatch()
        for fileID in state.fileIDsByRelativePath.values {
            guard let file = filesByID[fileID] else { continue }
            let key = WorkspaceSearchContentCacheKey(
                rootID: file.rootID,
                fileID: file.id,
                standardizedRelativePath: file.standardizedRelativePath
            )
            nextSearchContentInvalidationEpoch &+= 1
            let invalidationEpoch = nextSearchContentInvalidationEpoch
            searchContentInvalidationEpochsByFileID[file.id] = invalidationEpoch
            invalidations.record(key, through: invalidationEpoch)
        }
        guard !invalidations.isEmpty else { return }
        await searchDecodedContentCache.invalidate(invalidations)
        await interactiveReadCache.invalidate(invalidations)
    }

    private func finalizePublicationInvalidations(_ batch: PublicationInvalidationBatch) {
        if batch.topologyInvalidationRequested {
            performPathMatchSnapshotInvalidation(
                affectedRootKinds: batch.affectedRootKinds,
                reasons: batch.reasons.isEmpty ? [.fileSystemPublication] : batch.reasons,
                affectedRootIDs: batch.affectedRootIDs
            )
        }
        guard !batch.searchContentInvalidations.isEmpty else { return }
        #if DEBUG
            Self.activePublicationInvalidationRecorder?.decodedCacheInvalidationRequestCount += 1
        #endif
        let searchContentInvalidations = batch.searchContentInvalidations
        Task {
            await searchDecodedContentCache.invalidate(searchContentInvalidations)
            await interactiveReadCache.invalidate(searchContentInvalidations)
        }
    }

    private func invalidatePathMatchSnapshot(
        affectedRootKinds: Set<WorkspaceRootKind>,
        reason: CatalogInvalidationReason = .catalogMutation,
        affectedRootIDs: Set<UUID> = []
    ) {
        if let activePublicationInvalidationBatch {
            activePublicationInvalidationBatch.topologyInvalidationRequested = true
            activePublicationInvalidationBatch.affectedRootKinds.formUnion(affectedRootKinds)
            activePublicationInvalidationBatch.affectedRootIDs.formUnion(affectedRootIDs)
            activePublicationInvalidationBatch.reasons.insert(.fileSystemPublication)
            return
        }
        performPathMatchSnapshotInvalidation(
            affectedRootKinds: affectedRootKinds,
            reasons: [reason],
            affectedRootIDs: affectedRootIDs
        )
    }

    private func performPathMatchSnapshotInvalidation(
        affectedRootKinds: Set<WorkspaceRootKind>,
        reasons: Set<CatalogInvalidationReason>,
        affectedRootIDs: Set<UUID>
    ) {
        #if DEBUG
            Self.activePublicationInvalidationRecorder?.topologyInvalidationCount += 1
        #endif
        bumpCatalogGenerations(
            affectedRootKinds: affectedRootKinds,
            affectedRootIDs: affectedRootIDs
        )
        // Keep the previous immutable shard until the canonical applied-index batch arrives.
        // The batch either publishes a contiguous patch or replaces it from the authoritative root snapshot.
        evictInvalidSearchCatalogSnapshots(
            reasons: reasons,
            affectedRootIDs: affectedRootIDs,
            affectedRootKinds: affectedRootKinds
        )
        let stalePathMatchIdentities = Set(pathMatchSnapshotIdentitiesByScope.compactMap { scope, identity in
            identity == pathMatchCacheIdentity(scope: scope) ? nil : identity
        })
        pathMatchSnapshotIdentitiesByScope = pathMatchSnapshotIdentitiesByScope.filter { scope, identity in
            identity == pathMatchCacheIdentity(scope: scope)
        }
        staticPathMatchSnapshotsByScope = staticPathMatchSnapshotsByScope.filter { scope, entry in
            entry.snapshot.cacheIdentity == pathMatchCacheIdentity(scope: scope)
        }
        invalidatePathMatchCache(snapshotIdentities: stalePathMatchIdentities)
    }

    private func invalidatePathMatchCache(snapshotIdentities: Set<PathMatchCacheIdentity>) {
        guard !snapshotIdentities.isEmpty else { return }
        #if DEBUG
            Self.activePublicationInvalidationRecorder?.pathWorkerInvalidationRequestCount += 1
        #endif
        Task { await pathMatchWorker.invalidateCache(snapshotIdentities: snapshotIdentities) }
    }

    private func indexFolder(relativePath: String, root: WorkspaceRootRecord) {
        guard var state = rootStatesByID[root.id] else { return }
        var stagedIndexes = RootIndexBuffers()
        indexFolders([FSItemDTO(relativePath: relativePath, isDirectory: true, hierarchy: relativePath.split(separator: "/").count)], root: root, state: &state, indexes: &stagedIndexes)
        commit(stagedIndexes)
        rootStatesByID[root.id] = state
        if let folder = folder(rootID: root.id, relativePath: relativePath) {
            promoteFolderToDiscoverable(folder)
        }
        invalidatePathMatchSnapshot(affectedRootKinds: [root.kind], affectedRootIDs: [root.id])
    }

    private func indexFile(relativePath: String, root: WorkspaceRootRecord, managedOnly: Bool = false) {
        guard var state = rootStatesByID[root.id] else { return }
        let existingFolderPaths = Set(state.folderIDsByRelativePath.keys)
        var stagedIndexes = RootIndexBuffers()
        indexFiles([FSItemDTO(relativePath: relativePath, isDirectory: false, hierarchy: relativePath.split(separator: "/").count)], root: root, state: &state, indexes: &stagedIndexes)
        commit(stagedIndexes)
        rootStatesByID[root.id] = state
        if let file = file(rootID: root.id, relativePath: relativePath) {
            if managedOnly {
                managedOnlyFileIDs.insert(file.id)
                for folder in newlyIndexedParentFolders(for: relativePath, rootID: root.id, existingFolderPaths: existingFolderPaths) {
                    managedOnlyFolderIDs.insert(folder.id)
                }
            } else {
                promoteToDiscoverable(file)
            }
        }
        invalidatePathMatchSnapshot(affectedRootKinds: [root.kind], affectedRootIDs: [root.id])
    }

    private func discoverableParentFolders(for fileRelativePath: String, rootID: UUID) -> [WorkspaceFolderRecord] {
        guard let state = rootStatesByID[rootID] else { return [] }
        let standardizedPath = StandardizedPath.relative(fileRelativePath)
        var current = (standardizedPath as NSString).deletingLastPathComponent
        var folders: [WorkspaceFolderRecord] = []
        while !current.isEmpty, current != "." {
            let key = StandardizedPath.relative(current)
            if let folderID = state.folderIDsByRelativePath[key],
               isDiscoverableFolderID(folderID),
               let folder = foldersByID[folderID]
            {
                folders.append(folder)
            }
            let next = (key as NSString).deletingLastPathComponent
            guard next != key else { break }
            current = next
        }
        return folders.sorted { $0.standardizedRelativePath < $1.standardizedRelativePath }
    }

    private func newlyIndexedParentFolders(
        for fileRelativePath: String,
        rootID: UUID,
        existingFolderPaths: Set<String>
    ) -> [WorkspaceFolderRecord] {
        guard let state = rootStatesByID[rootID] else { return [] }
        let standardizedPath = StandardizedPath.relative(fileRelativePath)
        let parentPath = (standardizedPath as NSString).deletingLastPathComponent
        guard !parentPath.isEmpty, parentPath != "." else { return [] }
        var folders: [WorkspaceFolderRecord] = []
        var current = parentPath
        while !current.isEmpty, current != "." {
            let key = StandardizedPath.relative(current)
            if !existingFolderPaths.contains(key),
               let folderID = state.folderIDsByRelativePath[key],
               let folder = foldersByID[folderID]
            {
                folders.append(folder)
            }
            let next = (key as NSString).deletingLastPathComponent
            guard next != key else { break }
            current = next
        }
        return folders.sorted { $0.standardizedRelativePath < $1.standardizedRelativePath }
    }

    private func publishAppliedIndexEvent(
        root: WorkspaceRootRecord,
        upsertedFiles: [WorkspaceFileRecord] = [],
        upsertedFolders: [WorkspaceFolderRecord] = [],
        removedFileIDs: [UUID] = [],
        removedFolderIDs: [UUID] = [],
        removedFilePaths: [String] = [],
        removedFolderPaths: [String] = [],
        modifiedFileIDs: [UUID] = [],
        modifiedFolderIDs: [UUID] = [],
        requiresFullResync: Bool = false
    ) {
        let upsertedFiles = upsertedFiles.filter { isDiscoverableFileID($0.id) }
        let upsertedFolders = upsertedFolders.filter { isDiscoverableFolderID($0.id) }
        let modifiedFileIDs = modifiedFileIDs.filter(isDiscoverableFileID)
        let modifiedFolderIDs = modifiedFolderIDs.filter(isDiscoverableFolderID)
        guard requiresFullResync || !upsertedFiles.isEmpty || !upsertedFolders.isEmpty || !removedFileIDs.isEmpty || !removedFolderIDs.isEmpty || !removedFilePaths.isEmpty || !removedFolderPaths.isEmpty || !modifiedFileIDs.isEmpty || !modifiedFolderIDs.isEmpty else { return }
        let rootLifetimeID = rootStatesByID[root.id]?.lifetimeID
        let modifiedFileSourceSnapshotsByID: [UUID: WorkspaceSliceRebaseSourceSnapshot] = Dictionary(
            uniqueKeysWithValues: modifiedFileIDs.compactMap { fileID -> (UUID, WorkspaceSliceRebaseSourceSnapshot)? in
                guard let rootLifetimeID,
                      let file = filesByID[fileID],
                      let snapshot = takeSliceRebaseSource(
                          rootID: root.id,
                          rootLifetimeID: rootLifetimeID,
                          file: file
                      )
                else { return nil }
                return (fileID, snapshot)
            }
        )
        let generation = nextAppliedIndexGeneration(forRootID: root.id)
        #if DEBUG
            MCPApplyEditsRebaseProbeRecorder.recordAppliedIndexModification(
                rootID: root.id,
                fileIDs: modifiedFileIDs,
                generation: generation
            )
        #endif
        yieldAppliedIndexEvent(WorkspaceAppliedIndexBatchEvent(
            rootID: root.id,
            rootPath: root.standardizedFullPath,
            generation: generation,
            rootLifetimeID: rootLifetimeID,
            modifiedFileSourceSnapshotsByID: modifiedFileSourceSnapshotsByID,
            upsertedFiles: upsertedFiles.sorted { $0.standardizedRelativePath < $1.standardizedRelativePath },
            upsertedFolders: upsertedFolders.sorted { $0.standardizedRelativePath < $1.standardizedRelativePath },
            removedFileIDs: removedFileIDs,
            removedFolderIDs: removedFolderIDs,
            removedFilePaths: removedFilePaths.sorted(),
            removedFolderPaths: removedFolderPaths.sorted(),
            modifiedFileIDs: modifiedFileIDs,
            modifiedFolderIDs: modifiedFolderIDs,
            requiresFullResync: requiresFullResync
        ))
    }

    private func removeFile(relativePath: String, rootID: UUID) {
        guard var state = rootStatesByID[rootID] else { return }
        let removedFileID = removeFile(relativePath: relativePath, state: &state)
        rootStatesByID[rootID] = state
        if removedFileID != nil {
            invalidatePathMatchSnapshot(affectedRootKinds: [state.root.kind], affectedRootIDs: [state.root.id])
        }
    }

    @discardableResult
    private func removeFile(relativePath: String, state: inout RootState) -> UUID? {
        let key = StandardizedPath.relative(relativePath)
        guard let fileID = state.fileIDsByRelativePath.removeValue(forKey: key),
              let file = filesByID.removeValue(forKey: fileID)
        else { return nil }
        removeSliceRebaseSources(rootID: file.rootID, fileID: fileID)
        invalidateSearchContent(file)
        searchContentInvalidationEpochsByFileID.removeValue(forKey: fileID)
        fileIDsByStandardizedFullPath.removeValue(forKey: file.standardizedFullPath)
        managedOnlyFileIDs.remove(fileID)
        if let parentID = file.parentFolderID {
            state.childFileIDsByFolderID[parentID]?.removeAll { $0 == fileID }
        }
        return fileID
    }

    private func removeFolderTree(relativePath: String, rootID: UUID) -> (fileIDs: [UUID], folderIDs: [UUID], filePaths: [String], folderPaths: [String]) {
        guard var state = rootStatesByID[rootID] else { return ([], [], [], []) }
        let key = StandardizedPath.relative(relativePath)
        guard !key.isEmpty,
              let folderID = state.folderIDsByRelativePath[key],
              let folder = foldersByID[folderID]
        else { return ([], [], [], []) }

        let filePaths = state.fileIDsByRelativePath.keys
            .filter { $0 == key || $0.hasPrefix(key + "/") }
        var removedFileIDs: [UUID] = []
        var removedFilePaths: [String] = []
        for path in filePaths {
            let wasDiscoverable = state.fileIDsByRelativePath[path].map(isDiscoverableFileID) ?? false
            if let removedFileID = removeFile(relativePath: path, state: &state), wasDiscoverable {
                removedFileIDs.append(removedFileID)
                removedFilePaths.append(path)
            }
        }

        let folderPaths = state.folderIDsByRelativePath.keys
            .filter { $0 == key || $0.hasPrefix(key + "/") }
            .sorted { $0.count > $1.count }
        var removedFolderIDs: [UUID] = []
        var removedFolderPaths: [String] = []
        for path in folderPaths {
            guard let id = state.folderIDsByRelativePath.removeValue(forKey: path),
                  let removed = foldersByID.removeValue(forKey: id)
            else { continue }
            let wasDiscoverable = isDiscoverableFolderID(id)
            if wasDiscoverable {
                removedFolderIDs.append(id)
                removedFolderPaths.append(path)
            }
            managedOnlyFolderIDs.remove(id)
            folderIDsByStandardizedFullPath.removeValue(forKey: removed.standardizedFullPath)
            if let parentID = removed.parentFolderID {
                state.childFolderIDsByFolderID[parentID]?.removeAll { $0 == id }
            }
            state.childFolderIDsByFolderID.removeValue(forKey: id)
            state.childFileIDsByFolderID.removeValue(forKey: id)
        }

        if let parentID = folder.parentFolderID {
            state.childFolderIDsByFolderID[parentID]?.removeAll { $0 == folderID }
        }
        rootStatesByID[rootID] = state
        invalidatePathMatchSnapshot(affectedRootKinds: [state.root.kind], affectedRootIDs: [state.root.id])
        return (removedFileIDs, removedFolderIDs, removedFilePaths, removedFolderPaths)
    }

    private func isDiscoverableFileID(_ fileID: UUID) -> Bool {
        !managedOnlyFileIDs.contains(fileID)
    }

    private func isDiscoverableFolderID(_ folderID: UUID) -> Bool {
        !managedOnlyFolderIDs.contains(folderID)
    }

    private func promoteToDiscoverable(_ file: WorkspaceFileRecord) {
        managedOnlyFileIDs.remove(file.id)
        if let folderID = file.parentFolderID, let folder = foldersByID[folderID] {
            promoteFolderToDiscoverable(folder)
        }
    }

    private func promoteFolderToDiscoverable(_ folder: WorkspaceFolderRecord) {
        var folderID: UUID? = folder.id
        while let id = folderID {
            managedOnlyFolderIDs.remove(id)
            folderID = foldersByID[id]?.parentFolderID
        }
    }

    private func yieldCodemapSelectionGraphReadiness(rootEpoch: WorkspaceCodemapRootEpoch) {
        let event = WorkspaceCodemapSelectionGraphReadinessEvent(rootEpoch: rootEpoch)
        for continuation in codemapSelectionGraphReadinessContinuations.values {
            continuation.yield(event)
        }
    }

    private func yieldCodemapMarkerReadiness(_ event: WorkspaceCodemapMarkerReadinessEvent) {
        for continuation in codemapMarkerReadinessContinuations.values {
            continuation.yield(event)
        }
    }

    private func isRootLifetimeCurrent(rootID: UUID, expectedLifetimeID: UUID?) -> Bool {
        guard let state = rootStatesByID[rootID] else { return false }
        guard let expectedLifetimeID else { return true }
        return state.lifetimeID == expectedLifetimeID
    }

    private func state(for rootID: UUID) throws -> RootState {
        guard let state = rootStatesByID[rootID] else {
            throw WorkspaceFileContextStoreError.rootNotLoaded(rootID)
        }
        return state
    }

    private func managedOnlyAncestorFolderIDs(for fileIDs: Set<UUID>) -> Set<UUID> {
        var folderIDs = Set<UUID>()
        for fileID in fileIDs {
            var folderID = filesByID[fileID]?.parentFolderID
            while let currentFolderID = folderID {
                folderIDs.insert(currentFolderID)
                folderID = foldersByID[currentFolderID]?.parentFolderID
            }
        }
        return folderIDs
    }

    private func makeFileTreeFolderSnapshot(
        _ folder: WorkspaceFolderRecord,
        rootStandardizedPath: String,
        state: RootState,
        visited: inout Set<UUID>,
        renderableCodemapFileIDs: Set<UUID>,
        explicitlyIncludedManagedOnlyFileIDs: Set<UUID> = [],
        explicitlyIncludedManagedOnlyFolderIDs: Set<UUID> = []
    ) -> FileTreeFolderSnapshot? {
        guard visited.insert(folder.id).inserted else { return nil }

        let childFolders = (state.childFolderIDsByFolderID[folder.id] ?? [])
            .filter { isDiscoverableFolderID($0) || explicitlyIncludedManagedOnlyFolderIDs.contains($0) }
            .compactMap { foldersByID[$0] }
            .sorted { $0.name < $1.name }
        let childFiles = (state.childFileIDsByFolderID[folder.id] ?? [])
            .filter { isDiscoverableFileID($0) || explicitlyIncludedManagedOnlyFileIDs.contains($0) }
            .compactMap { filesByID[$0] }
            .sorted { $0.name < $1.name }

        var children: [FileTreeNodeSnapshot] = []
        children.reserveCapacity(childFolders.count + childFiles.count)
        for childFolder in childFolders {
            if let snapshot = makeFileTreeFolderSnapshot(
                childFolder,
                rootStandardizedPath: rootStandardizedPath,
                state: state,
                visited: &visited,
                renderableCodemapFileIDs: renderableCodemapFileIDs,
                explicitlyIncludedManagedOnlyFileIDs: explicitlyIncludedManagedOnlyFileIDs,
                explicitlyIncludedManagedOnlyFolderIDs: explicitlyIncludedManagedOnlyFolderIDs
            ) {
                children.append(.folder(snapshot))
            }
        }
        for file in childFiles {
            children.append(.file(FileTreeFileSnapshot(
                id: file.id,
                name: file.name,
                fileExtension: (file.name as NSString).pathExtension.isEmpty ? nil : (file.name as NSString).pathExtension,
                hasCodeMap: renderableCodemapFileIDs.contains(file.id)
            )))
        }

        return FileTreeFolderSnapshot(
            id: folder.id,
            name: folder.name,
            fullPath: folder.fullPath,
            standardizedFullPath: folder.standardizedFullPath,
            standardizedRootPath: rootStandardizedPath,
            children: children
        )
    }

    private func commit(_ indexes: RootIndexBuffers) {
        foldersByID.merge(indexes.foldersByID) { _, new in new }
        filesByID.merge(indexes.filesByID) { _, new in new }
        folderIDsByStandardizedFullPath.merge(indexes.folderIDsByStandardizedFullPath) { _, new in new }
        fileIDsByStandardizedFullPath.merge(indexes.fileIDsByStandardizedFullPath) { _, new in new }
    }

    private func indexFolders(_ items: [FSItemDTO], root: WorkspaceRootRecord, state: inout RootState, indexes: inout RootIndexBuffers) {
        for item in items {
            let relativePath = StandardizedPath.relative(item.relativePath)
            guard state.folderIDsByRelativePath[relativePath] == nil else { continue }
            let parentPath = (relativePath as NSString).deletingLastPathComponent
            let parentID = ensureParentFolderID(for: parentPath, root: root, state: &state, indexes: &indexes)
            let folder = WorkspaceFolderRecord(
                rootID: root.id,
                name: URL(fileURLWithPath: relativePath).lastPathComponent,
                relativePath: relativePath,
                fullPath: (root.fullPath as NSString).appendingPathComponent(relativePath),
                parentFolderID: parentID
            )
            indexes.foldersByID[folder.id] = folder
            indexes.folderIDsByStandardizedFullPath[folder.standardizedFullPath] = folder.id
            state.folderIDsByRelativePath[folder.standardizedRelativePath] = folder.id
            state.childFolderIDsByFolderID[parentID, default: []].append(folder.id)
        }
    }

    private func indexFiles(_ items: [FSItemDTO], root: WorkspaceRootRecord, state: inout RootState, indexes: inout RootIndexBuffers) {
        for item in items {
            let relativePath = StandardizedPath.relative(item.relativePath)
            guard state.fileIDsByRelativePath[relativePath] == nil else { continue }
            let parentID = ensureParentFolderID(for: (relativePath as NSString).deletingLastPathComponent, root: root, state: &state, indexes: &indexes)
            let file = WorkspaceFileRecord(
                rootID: root.id,
                name: URL(fileURLWithPath: relativePath).lastPathComponent,
                relativePath: relativePath,
                fullPath: (root.fullPath as NSString).appendingPathComponent(relativePath),
                parentFolderID: parentID
            )
            indexes.filesByID[file.id] = file
            indexes.fileIDsByStandardizedFullPath[file.standardizedFullPath] = file.id
            state.fileIDsByRelativePath[file.standardizedRelativePath] = file.id
            state.childFileIDsByFolderID[parentID, default: []].append(file.id)
        }
    }

    private func ensureParentFolderID(for relativePath: String, root: WorkspaceRootRecord, state: inout RootState, indexes: inout RootIndexBuffers) -> UUID {
        let key = StandardizedPath.relative(relativePath)
        if key.isEmpty || key == "." { return root.id }
        if let existing = state.folderIDsByRelativePath[key] { return existing }

        let parentPath = (key as NSString).deletingLastPathComponent
        let parentID = ensureParentFolderID(for: parentPath, root: root, state: &state, indexes: &indexes)
        let folder = WorkspaceFolderRecord(
            rootID: root.id,
            name: URL(fileURLWithPath: key).lastPathComponent,
            relativePath: key,
            fullPath: (root.fullPath as NSString).appendingPathComponent(key),
            parentFolderID: parentID
        )
        indexes.foldersByID[folder.id] = folder
        indexes.folderIDsByStandardizedFullPath[folder.standardizedFullPath] = folder.id
        state.folderIDsByRelativePath[folder.standardizedRelativePath] = folder.id
        state.childFolderIDsByFolderID[parentID, default: []].append(folder.id)
        return folder.id
    }
}

enum WorkspaceFileContextStoreError: Error, Equatable {
    case rootNotLoaded(UUID)
    case storeDeallocated
    case rootAlreadyLoadedWithDifferentConfiguration(String)
    case rootLoadInFlightWithDifferentConfiguration(String)
    case catalogMaterializationFailed(String)
}

extension WorkspaceFileContextStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .rootNotLoaded(id):
            "Workspace root is not loaded: \(id)."
        case .storeDeallocated:
            "Workspace file context store was deallocated."
        case let .rootAlreadyLoadedWithDifferentConfiguration(path):
            "Workspace root is already loaded with a different configuration: \(path)."
        case let .rootLoadInFlightWithDifferentConfiguration(path):
            "Workspace root load is already in flight with a different configuration: \(path)."
        case let .catalogMaterializationFailed(message):
            message
        }
    }
}
