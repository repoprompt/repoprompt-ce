import CoreServices
import Foundation

/// A position in the persistent macOS FSEvents journal.
///
/// This is deliberately distinct from the service-local accepted callback
/// watermark. Values from the two domains must never be compared.
struct FileSystemSeedReplayJournalCut: Hashable {
    let fseventID: FSEventStreamEventId
}

struct FileSystemSeedInitializationID: Hashable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

struct FileSystemSeedCaptureIdentity: Equatable {
    let initializationID: FileSystemSeedInitializationID
    let watcherIngressGeneration: UInt64
    let journalCut: FileSystemSeedReplayJournalCut
    let initialAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark
}

struct FileSystemSeededInventoryPreparation: @unchecked Sendable {
    let serviceIdentity: UUID
    let initializationID: FileSystemSeedInitializationID
    let watcherIngressGeneration: UInt64
    let snapshotIdentity: WorkspaceRootReusableSnapshotIdentity?
    let targetPlanDigest: Data?
    let inventoryManifest: FileSystemSeededInventoryManifest

    var statistics: FileSystemSeededInventoryPreparationStatistics {
        inventoryManifest.statistics
    }
}

struct FileSystemSeedReplayResult {
    let initializationID: FileSystemSeedInitializationID
    let watcherIngressGeneration: UInt64
    let requestedAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark
    let publishedAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark
    let finalServicePublicationSequence: UInt64
    let acceptedPayloadCount: Int
    let acceptedEventCount: Int
    let changedRelativePaths: FileSystemSeededInventoryChangedPaths
    let replayStorageStatistics: FileSystemSeededInventoryReplayStorageStatistics
    let ignoreControlPathsChanged: Bool
    let inventorySnapshot: FileSystemSeededInventorySnapshot
}

struct FileSystemSeedPublicationActivationProof: Equatable {
    let initializationID: FileSystemSeedInitializationID
    let watcherIngressGeneration: UInt64
    let acceptedWatcherWatermark: FileSystemWatcherIngressMailbox.Watermark
    let servicePublicationSequence: UInt64
}

enum FileSystemSeedReplayError: Error, Equatable {
    case invalidJournalCut
    case watcherAlreadyActive
    case initializationAlreadyActive
    case initializationNotCurrent
    case inventoryNotInstalled
    case invalidSeedInventoryPath(String)
    case watcherIngressChanged
    case watcherNotActive
    case requestedWatermarkPredatesCapture
    case requestedWatermarkNotYetAccepted
    case acceptedWatermarkGap(expected: UInt64, actual: UInt64)
    case mailboxOverflow
    case unsafeEventFlags
    case recoveryRequired
    case fullResyncRequired
    case replayAlreadyCompleted
    case requestedWatermarkNotPublished
}

struct FileSystemSeedInitializationState {
    enum Phase: Equatable {
        case capturing
        case inventoryInstalled
        case replaying(FileSystemWatcherIngressMailbox.Watermark)
        case readyForPublication
        case activatedForPublication(FileSystemSeedPublicationActivationProof)
        case failed(FileSystemSeedReplayError)
    }

    let initializationID: FileSystemSeedInitializationID
    let watcherIngressGeneration: UInt64
    let journalCut: FileSystemSeedReplayJournalCut
    let replayBaseAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark
    let replayBasePublicationSequence: UInt64
    var initialAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark
    var phase: Phase
    var lastReplayPublicationSequence: UInt64
}

extension FileSystemService {
    /// Starts a hidden-root watcher at the receipt's durable journal boundary.
    /// Callback acceptance remains live, but automatic mailbox draining stays
    /// paused until `completeSeededPublication` transfers the service to normal use.
    func startWatchingForSeedPreparation(
        since journalCut: FileSystemSeedReplayJournalCut,
        initializationID: FileSystemSeedInitializationID
    ) async throws -> FileSystemSeedCaptureIdentity {
        guard journalCut.fseventID != 0,
              journalCut.fseventID != FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        else {
            throw FileSystemSeedReplayError.invalidJournalCut
        }
        guard fseventStreamRef == nil else {
            throw FileSystemSeedReplayError.watcherAlreadyActive
        }
        guard seedInitializationState == nil else {
            throw FileSystemSeedReplayError.initializationAlreadyActive
        }

        watcherIngressMailbox.pauseAutomaticDraining()
        nextFSEventStreamStartEventID = journalCut.fseventID
        seedInitializationState = FileSystemSeedInitializationState(
            initializationID: initializationID,
            watcherIngressGeneration: watcherIngressGeneration,
            journalCut: journalCut,
            replayBaseAcceptedWatermark: lastPublishedWatcherAcceptedWatermark,
            replayBasePublicationSequence: lastServicePublicationSequence,
            initialAcceptedWatermark: captureAcceptedWatcherWatermark(),
            phase: .capturing,
            lastReplayPublicationSequence: lastServicePublicationSequence
        )

        do {
            try startFSEventStream()
            if let stream = fseventStreamRef {
                FSEventStreamFlushSync(stream)
            }
            try requireCurrentSeedInitialization(initializationID)
            let initialAcceptedWatermark = captureAcceptedWatcherWatermark()
            seedInitializationState?.initialAcceptedWatermark = initialAcceptedWatermark
            return FileSystemSeedCaptureIdentity(
                initializationID: initializationID,
                watcherIngressGeneration: watcherIngressGeneration,
                journalCut: journalCut,
                initialAcceptedWatermark: initialAcceptedWatermark
            )
        } catch {
            if fseventStreamRef != nil {
                stopFSEventStream()
            } else {
                watcherIngressMailbox.stopAcceptingAndDiscardPending()
            }
            seedInitializationState = nil
            throw error
        }
    }

    /// Captures the service-local callback cut after proving that the requested
    /// hidden initialization still owns the live watcher generation.
    func captureSeedReplayAcceptedWatermark(
        initializationID: FileSystemSeedInitializationID
    ) throws -> FileSystemWatcherIngressMailbox.Watermark {
        try requireCurrentSeedInitialization(initializationID)
        return captureAcceptedWatcherWatermark()
    }

    func prepareSeededInventory(
        planHandle: WorkspaceRootTargetSeedPlanHandle,
        initializationID: FileSystemSeedInitializationID
    ) async throws -> FileSystemSeededInventoryPreparation {
        try requireCurrentSeedInitialization(initializationID)
        guard seedInitializationState?.phase == .capturing else {
            throw FileSystemSeedReplayError.replayAlreadyCompleted
        }

        let manifest = try FileSystemSeededInventoryManifest(validating: planHandle)
        return FileSystemSeededInventoryPreparation(
            serviceIdentity: diagnosticRootToken,
            initializationID: initializationID,
            watcherIngressGeneration: watcherIngressGeneration,
            snapshotIdentity: planHandle.snapshotIdentity,
            targetPlanDigest: planHandle.planManifest.footer.digest,
            inventoryManifest: manifest
        )
    }

    func installSeededInventory(_ preparation: FileSystemSeededInventoryPreparation) async throws {
        try requireCurrentSeedInitialization(preparation.initializationID)
        guard seedInitializationState?.phase == .capturing else {
            throw FileSystemSeedReplayError.replayAlreadyCompleted
        }
        guard preparation.serviceIdentity == diagnosticRootToken,
              preparation.watcherIngressGeneration == watcherIngressGeneration
        else {
            throw FileSystemSeedReplayError.watcherIngressChanged
        }

        visitedInventory.installSeeded(manifest: preparation.inventoryManifest)
        explicitlyManagedIgnoredFilePaths.removeAll(keepingCapacity: false)
        seedInitializationState?.phase = .inventoryInstalled
    }

    /// Strictly applies every callback payload through `cut` exactly once.
    /// Unlike the ordinary freshness barrier, this never synthesizes progress
    /// after teardown and never recovers from lossy watcher evidence.
    func flushSeedReplay(
        through cut: FileSystemWatcherIngressMailbox.Watermark,
        initializationID: FileSystemSeedInitializationID
    ) async throws -> FileSystemSeedReplayResult {
        try requireCurrentSeedInitialization(initializationID)
        guard let initialState = seedInitializationState else {
            throw FileSystemSeedReplayError.initializationNotCurrent
        }
        guard initialState.phase == .inventoryInstalled else {
            throw FileSystemSeedReplayError.inventoryNotInstalled
        }
        guard cut >= initialState.replayBaseAcceptedWatermark else {
            throw FileSystemSeedReplayError.requestedWatermarkPredatesCapture
        }
        guard cut <= captureAcceptedWatcherWatermark() else {
            throw FileSystemSeedReplayError.requestedWatermarkNotYetAccepted
        }

        seedInitializationState?.phase = .replaying(cut)
        do {
            let evidence = try drainSeedReplayPayloads(
                through: cut,
                initializationID: initializationID
            )
            cancelScheduledCoalescingDelay()

            while lastPublishedWatcherAcceptedWatermark < cut {
                try requireCurrentSeedInitialization(initializationID, replaying: cut)
                if let watcherBatchProcessingTask {
                    await watcherBatchProcessingTask.value
                    try requireCurrentSeedInitialization(initializationID, replaying: cut)
                    try throwSeedReplayFailureIfRecorded()
                    continue
                }
                guard startProcessingPendingWatcherBatchIfNeeded() else {
                    throw FileSystemSeedReplayError.requestedWatermarkNotPublished
                }
            }

            if let watcherBatchProcessingTask {
                await watcherBatchProcessingTask.value
            }
            try requireCurrentSeedInitialization(initializationID, replaying: cut)
            try throwSeedReplayFailureIfRecorded()
            guard dirtyRecoveryScanTargets.isEmpty,
                  recoveryScanFailureCountByFolder.isEmpty,
                  recoveryScanRetryTask == nil
            else {
                throw FileSystemSeedReplayError.recoveryRequired
            }
            guard lastPublishedWatcherAcceptedWatermark >= cut else {
                throw FileSystemSeedReplayError.requestedWatermarkNotPublished
            }

            let inventorySnapshot = try visitedInventory.seededSnapshot()
            let result = FileSystemSeedReplayResult(
                initializationID: initializationID,
                watcherIngressGeneration: watcherIngressGeneration,
                requestedAcceptedWatermark: cut,
                publishedAcceptedWatermark: lastPublishedWatcherAcceptedWatermark,
                finalServicePublicationSequence: lastServicePublicationSequence,
                acceptedPayloadCount: evidence.payloadCount,
                acceptedEventCount: evidence.eventCount,
                changedRelativePaths: inventorySnapshot.changedRelativePaths,
                replayStorageStatistics: visitedInventory.seededReplayStorageStatistics,
                ignoreControlPathsChanged: evidence.ignoreControlPathsChanged,
                inventorySnapshot: inventorySnapshot
            )
            seedInitializationState?.phase = .readyForPublication
            return result
        } catch let error as FileSystemSeedReplayError {
            failSeedReplay(error, initializationID: initializationID)
            throw error
        } catch {
            let failure = FileSystemSeedReplayError.recoveryRequired
            failSeedReplay(failure, initializationID: initializationID)
            throw failure
        }
    }

    /// Activates ordinary draining while the owning root is still private and
    /// retains an exact proof until the store atomically publishes or aborts.
    func activateSeededPublication(
        initializationID: FileSystemSeedInitializationID
    ) -> FileSystemSeedPublicationActivationProof? {
        guard let state = seedInitializationState,
              state.initializationID == initializationID,
              state.watcherIngressGeneration == watcherIngressGeneration,
              state.phase == .readyForPublication,
              fseventStreamRef != nil
        else { return nil }
        #if DEBUG
            guard !seededPublicationActivationShouldFailForTesting else { return nil }
        #endif
        let proof = FileSystemSeedPublicationActivationProof(
            initializationID: initializationID,
            watcherIngressGeneration: watcherIngressGeneration,
            acceptedWatcherWatermark: captureAcceptedWatcherWatermark(),
            servicePublicationSequence: lastServicePublicationSequence
        )
        seedInitializationState?.phase = .activatedForPublication(proof)
        watcherIngressMailbox.resumeAutomaticDraining { [weak self] in
            await self?.drainAcceptedWatcherIngressMailbox()
        }
        return proof
    }

    func seededPublicationActivationIsCurrent(
        _ proof: FileSystemSeedPublicationActivationProof
    ) -> Bool {
        guard let state = seedInitializationState,
              state.initializationID == proof.initializationID,
              state.watcherIngressGeneration == proof.watcherIngressGeneration,
              state.phase == .activatedForPublication(proof),
              watcherIngressGeneration == proof.watcherIngressGeneration,
              fseventStreamRef != nil
        else { return false }
        return true
    }

    @discardableResult
    func finalizeSeededPublication(
        _ proof: FileSystemSeedPublicationActivationProof
    ) -> Bool {
        guard seededPublicationActivationIsCurrent(proof) else { return false }
        seedInitializationState = nil
        return true
    }

    /// Compatibility helper for direct service tests. Store publication uses
    /// the three-step activate/revalidate/finalize protocol above.
    @discardableResult
    func completeSeededPublication(initializationID: FileSystemSeedInitializationID) -> Bool {
        guard let proof = activateSeededPublication(initializationID: initializationID) else { return false }
        return finalizeSeededPublication(proof)
    }

    func abortSeededPreparation(initializationID: FileSystemSeedInitializationID) {
        guard seedInitializationState?.initializationID == initializationID else { return }
        stopFSEventStream()
        seedInitializationState = nil
    }

    /// Performs the existing authoritative full-tree recovery reconciliation once
    /// in response to an event-driven Git authority invalidation. This API never
    /// schedules itself and therefore cannot become a polling loop.
    @discardableResult
    func reconcileEntireTreeForAuthorityChange() async -> Bool {
        guard seedInitializationState == nil else { return false }
        do {
            let deltas = try await reconcileEntireTreeAfterRecoveryFailure()
            publishFileSystemDeltas(
                deltas,
                source: .recoveryFullResync,
                requiresFullResync: true
            )
            return true
        } catch {
            return false
        }
    }

    func recordSeedReplayPublication(
        source: FileSystemDeltaPublicationSource,
        watcherAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark?,
        requiresFullResync: Bool,
        deltas: [FileSystemDelta],
        servicePublicationSequence: UInt64
    ) {
        guard var state = seedInitializationState,
              case .replaying = state.phase
        else { return }
        guard !requiresFullResync else {
            state.phase = .failed(.fullResyncRequired)
            seedInitializationState = state
            return
        }
        guard source == .watcher || source == .watcherBarrierNoop else {
            state.phase = .failed(source == .recoveryFullResync ? .fullResyncRequired : .mailboxOverflow)
            seedInitializationState = state
            return
        }
        let expectedSequence = state.lastReplayPublicationSequence &+ 1
        guard servicePublicationSequence == expectedSequence else {
            state.phase = .failed(.acceptedWatermarkGap(
                expected: expectedSequence,
                actual: servicePublicationSequence
            ))
            seedInitializationState = state
            return
        }
        state.lastReplayPublicationSequence = servicePublicationSequence
        if watcherAcceptedWatermark != nil {
            for delta in deltas {
                visitedInventory.recordSeedReplayDelta(delta)
            }
        }
        seedInitializationState = state
    }

    func seedReplayRequiresFailClosedRecovery() -> Bool {
        guard let state = seedInitializationState else { return false }
        if case .replaying = state.phase { return true }
        return false
    }

    func failCurrentSeedReplayForRecovery() {
        guard let initializationID = seedInitializationState?.initializationID else { return }
        failSeedReplay(.recoveryRequired, initializationID: initializationID)
    }

    private func drainSeedReplayPayloads(
        through cut: FileSystemWatcherIngressMailbox.Watermark,
        initializationID: FileSystemSeedInitializationID
    ) throws -> (payloadCount: Int, eventCount: Int, ignoreControlPathsChanged: Bool) {
        let state = try currentSeedInitialization(initializationID)
        var expected = state.replayBaseAcceptedWatermark.rawValue &+ 1
        var payloadCount = 0
        var eventCount = 0
        var ignoreControlPathsChanged = false

        while let payload = watcherIngressMailbox.takeNextAcceptedPayload(through: cut) {
            guard payload.lowestAcceptedWatermark.rawValue == expected else {
                throw FileSystemSeedReplayError.acceptedWatermarkGap(
                    expected: expected,
                    actual: payload.lowestAcceptedWatermark.rawValue
                )
            }
            guard payload.lowestAcceptedWatermark == payload.acceptedHighWatermark else {
                throw FileSystemSeedReplayError.mailboxOverflow
            }
            switch payload.contents {
            case .overflowRootRescan:
                throw FileSystemSeedReplayError.mailboxOverflow
            case let .entries(entries):
                guard !entries.contains(where: { Self.hasUnsafeSeedReplayFlags($0.flags) }) else {
                    throw FileSystemSeedReplayError.unsafeEventFlags
                }
                payloadCount += 1
                eventCount += entries.count
                ignoreControlPathsChanged = ignoreControlPathsChanged || entries.contains {
                    Self.isSeedReplayIgnoreControlPath($0.path)
                }
                let materialEntries = entries.filter { entry in
                    (entry.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)) == 0
                }
                if materialEntries.isEmpty {
                    pendingWatcherAcceptedHighWatermark = max(
                        pendingWatcherAcceptedHighWatermark ?? .zero,
                        payload.acceptedHighWatermark
                    )
                } else {
                    enqueueFSEventEntries(
                        materialEntries,
                        acceptedHighWatermark: payload.acceptedHighWatermark
                    )
                }
            }
            expected = payload.acceptedHighWatermark.rawValue &+ 1
        }

        guard expected == cut.rawValue &+ 1 else {
            throw FileSystemSeedReplayError.acceptedWatermarkGap(
                expected: expected,
                actual: cut.rawValue &+ 1
            )
        }
        return (payloadCount, eventCount, ignoreControlPathsChanged)
    }

    private func currentSeedInitialization(
        _ initializationID: FileSystemSeedInitializationID
    ) throws -> FileSystemSeedInitializationState {
        guard let state = seedInitializationState,
              state.initializationID == initializationID
        else {
            throw FileSystemSeedReplayError.initializationNotCurrent
        }
        return state
    }

    private func requireCurrentSeedInitialization(
        _ initializationID: FileSystemSeedInitializationID,
        replaying cut: FileSystemWatcherIngressMailbox.Watermark? = nil
    ) throws {
        let state = try currentSeedInitialization(initializationID)
        guard state.watcherIngressGeneration == watcherIngressGeneration else {
            throw FileSystemSeedReplayError.watcherIngressChanged
        }
        guard fseventStreamRef != nil else {
            throw FileSystemSeedReplayError.watcherNotActive
        }
        if let cut, state.phase != .replaying(cut) {
            if case let .failed(error) = state.phase { throw error }
            throw FileSystemSeedReplayError.initializationNotCurrent
        }
    }

    private func throwSeedReplayFailureIfRecorded() throws {
        guard let state = seedInitializationState else {
            throw FileSystemSeedReplayError.initializationNotCurrent
        }
        if case let .failed(error) = state.phase { throw error }
    }

    private func failSeedReplay(
        _ error: FileSystemSeedReplayError,
        initializationID: FileSystemSeedInitializationID
    ) {
        guard seedInitializationState?.initializationID == initializationID else { return }
        seedInitializationState?.phase = .failed(error)
        cancelScheduledCoalescingDelay()
        recoveryScanRetryTask?.cancel()
        recoveryScanRetryTask = nil
    }

    private nonisolated static func hasUnsafeSeedReplayFlags(_ flags: FSEventStreamEventFlags) -> Bool {
        let mask = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagEventIdsWrapped
        )
        return (flags & mask) != 0
    }

    private nonisolated static func isSeedReplayIgnoreControlPath(_ path: String) -> Bool {
        let filename = (path as NSString).lastPathComponent.lowercased()
        return filename == ".gitignore" || filename == ".repo_ignore" || filename == ".cursorignore"
    }
}

#if DEBUG
    extension FileSystemService {
        private func validatedSeedPaths(_ paths: Set<String>) throws -> Set<String> {
            var validated = Set<String>()
            validated.reserveCapacity(paths.count)
            for path in paths {
                let standardized = StandardizedPath.relative(path)
                guard !standardized.isEmpty,
                      standardized != ".",
                      standardized != "..",
                      !standardized.hasPrefix("../"),
                      !standardized.hasPrefix("/")
                else {
                    throw FileSystemSeedReplayError.invalidSeedInventoryPath(path)
                }
                validated.insert(standardized)
            }
            return validated
        }

        func setSeededPublicationActivationFailureForTesting(_ shouldFail: Bool) {
            seededPublicationActivationShouldFailForTesting = shouldFail
        }

        func prepareSeededInventoryForTesting(
            relativeFilePaths: Set<String>,
            relativeFolderPaths: Set<String>,
            initializationID: FileSystemSeedInitializationID
        ) throws -> FileSystemSeededInventoryPreparation {
            try requireCurrentSeedInitialization(initializationID)
            let validatedFiles = try validatedSeedPaths(relativeFilePaths)
            let validatedFolders = try validatedSeedPaths(relativeFolderPaths)
            guard validatedFiles.isDisjoint(with: validatedFolders) else {
                throw FileSystemSeedReplayError.invalidSeedInventoryPath(
                    validatedFiles.intersection(validatedFolders).sorted().first ?? ""
                )
            }
            var records: [FileSystemSeededInventoryRecord] = []
            records.reserveCapacity(relativeFilePaths.count + relativeFolderPaths.count)
            records.append(contentsOf: validatedFiles.map {
                FileSystemSeededInventoryRecord(relativePath: $0, isDirectory: false)
            })
            records.append(contentsOf: validatedFolders.map {
                FileSystemSeededInventoryRecord(relativePath: $0, isDirectory: true)
            })
            let manifest = try FileSystemSeededInventoryManifest.makeForTesting(records: records)
            return FileSystemSeededInventoryPreparation(
                serviceIdentity: diagnosticRootToken,
                initializationID: initializationID,
                watcherIngressGeneration: watcherIngressGeneration,
                snapshotIdentity: nil,
                targetPlanDigest: nil,
                inventoryManifest: manifest
            )
        }
    }
#endif
