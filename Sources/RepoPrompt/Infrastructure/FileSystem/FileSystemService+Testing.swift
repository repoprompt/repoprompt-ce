import Foundation
import RepoPromptCore

#if DEBUG
    extension FileSystemService {
        // MARK: - Testing Support

        func simulateFSEvents(
            _ events: [(absolutePath: String, flags: FileSystemWatchEventFlags, eventId: FileSystemWatchEventID)]
        ) async -> [FileSystemDelta] {
            // Clear any previous deltas
            processedFolders.removeAll()
            processedFolderBatches.removeAll()

            // Process the events and get deltas directly
            let formattedEvents = events.map { ($0.absolutePath, $0.flags, $0.eventId) }
            let deltas = await handleBatchedEvents(PendingFSEventBatch(events: formattedEvents), testMode: true)

            return deltas ?? []
        }

        /// Test-only method to get processed folders
        func getProcessedFolders() -> Set<String> {
            processedFolders
        }

        func getProcessedFolderBatches() -> [[String]] {
            processedFolderBatches
        }

        /// Test-only method to get current state
        func getTestState() -> (visitedPaths: Set<String>, visitedItems: [String: Bool]) {
            (visitedPaths, visitedItems)
        }

        /// Test-only method to get event ID coalescing state
        func getCoalescingState() -> (
            pendingScanTargets: [String: FileSystemWatchEventID],
            lastScannedEventIdByFolder: [String: FileSystemWatchEventID]
        ) {
            (pendingScanTargets, lastScannedEventIdByFolder)
        }

        func enqueuePendingRawEventsForTesting(
            _ events: [(absolutePath: String, flags: FileSystemWatchEventFlags, eventId: FileSystemWatchEventID)]
        ) {
            let payload = FSEventCallbackPayload(
                entries: events.map { event in
                    FSEventCallbackEntry(path: event.absolutePath, flags: event.flags, id: event.eventId)
                }
            )
            enqueueFSEventEntries(payload.entries)
            scheduleCoalescingIfNeeded()
        }

        @discardableResult
        func acceptWatcherPayloadForTesting(
            _ events: [(absolutePath: String, flags: FileSystemWatchEventFlags, eventId: FileSystemWatchEventID)],
            scheduleDrain: Bool = true
        ) -> FileSystemWatcherIngressMailbox.Watermark? {
            watcherIngressMailbox.startAccepting()
            let payload = FSEventCallbackPayload(
                entries: events.map { event in
                    FSEventCallbackEntry(path: event.absolutePath, flags: event.flags, id: event.eventId)
                }
            )
            let filterResult = watcherEarlyFilter.filter(payload)
            guard let retainedPayload = filterResult.payload else { return nil }
            let drain: (@Sendable () async -> Void)? = if scheduleDrain {
                { [weak self] in await self?.drainAcceptedWatcherIngressMailbox() }
            } else {
                nil
            }
            return watcherIngressMailbox.accept(retainedPayload, lifecycleCorrelation: nil, scheduleDrain: drain)
        }

        func watcherIngressMailboxSnapshotForTesting() -> FileSystemWatcherIngressMailbox.Snapshot {
            watcherIngressMailbox.snapshotForTesting()
        }

        func watcherEarlyFilterSnapshotForTesting() -> FileSystemWatcherEarlyFilter.Snapshot {
            watcherEarlyFilter.snapshotForTesting()
        }

        func publicationStateForTesting() -> (
            lastServicePublicationSequence: UInt64,
            lastPublishedWatcherAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark
        ) {
            (lastServicePublicationSequence, lastPublishedWatcherAcceptedWatermark)
        }

        func setWatcherBatchWillProcessHandlerForTesting(
            _ handler: (@Sendable () async -> Void)?
        ) {
            watcherBatchWillProcessHandler = handler
        }

        func setWatcherActivationFailureForTesting(_ failurePoint: WatcherActivationFailurePoint?) {
            watcherActivationFailurePointForTesting = failurePoint
        }

        func setFolderScanFailureCountForTesting(_ count: Int, folder: String) {
            if count > 0 {
                folderScanFailuresRemainingForTesting[folder] = count
            } else {
                folderScanFailuresRemainingForTesting.removeValue(forKey: folder)
            }
        }

        func setContentReadChunkHandlerForTesting(
            _ handler: (@Sendable (String) async -> Void)?
        ) {
            contentReadChunkHandler = handler
        }

        func resetContentFingerprintRequestCountForTesting() {
            contentFingerprintRequestCountForTesting = 0
        }

        func contentFingerprintRequestCountSnapshotForTesting() -> Int {
            contentFingerprintRequestCountForTesting
        }

        func setCachedSearchContentWatcherActiveOverrideForTesting(_ isActive: Bool?) {
            cachedSearchContentWatcherActiveOverrideForTesting = isActive
        }

        func setParallelFolderEnumerationHookForTesting(
            _ handler: (@Sendable (String) async throws -> Void)?
        ) {
            parallelFolderEnumerationHookForTesting = handler
        }

        func cachedEncodingForTesting(relativePath: String) -> String.Encoding? {
            encodingMap[relativePath]
        }

        func isWatchingForChangesForTesting() -> Bool {
            fileSystemWatcher.isWatching
        }

        func watcherStateForTesting() -> (
            pendingRawEventCount: Int,
            hasPendingOverflowRescan: Bool,
            overflowChangedIgnoreDirs: Set<String>,
            pendingScanTargets: [String: FileSystemWatchEventID],
            pendingQuietFolderScanTargets: Set<String>,
            dirtyRecoveryScanTargets: Set<String>,
            recoveryScanFailureCountByFolder: [String: Int],
            lastScannedEventIdByFolder: [String: FileSystemWatchEventID],
            lastVerifiedAtByFolder: [String: TimeInterval],
            fileEventCountSinceLastScan: [String: Int]
        ) {
            (
                pendingFSEvents.count,
                hasPendingOverflowRescan,
                overflowChangedIgnoreDirs,
                pendingScanTargets,
                pendingQuietFolderScanTargets,
                dirtyRecoveryScanTargets,
                recoveryScanFailureCountByFolder,
                lastScannedEventIdByFolder,
                lastVerifiedAtByFolder,
                fileEventCountSinceLastScan
            )
        }

        /// Test-only method to get per-folder ignore cache keys
        func getIgnoreCacheKeys() -> Set<String> {
            Set(perFolderIgnoreCache.keys)
        }

        /// Test-only method to get no-ignore-file cache
        func getNoIgnoreFileCache() -> Set<String> {
            Set(noIgnoreFileCache.keys)
        }

        /// Test-only method to get no-ignore-file cache size
        func getNoIgnoreFileCacheSize() -> Int {
            noIgnoreFileCache.count
        }

        nonisolated static var ignoreCacheCapacityForTesting: Int {
            ignoreCacheCapacity
        }

        func setMockDirectoryContents(_ provider: @escaping (String) -> [String]) {
            mockDirectoryContents = provider
        }

        /// Get tracked paths for testing
        func getTrackedPaths() async -> [String] {
            Array(visitedPaths)
        }

        /// Get per-folder ignore cache size for testing
        func getPerFolderIgnoreCacheSize() async -> Int {
            perFolderIgnoreCache.count
        }

        /// Public wrapper for scanOneLevelAndDiff for testing
        func scanOneLevelAndDiff(relativeFolderPath: String) async throws -> [FileSystemDelta] {
            try await scanOneLevelAndDiff(relativeFolderPath)
        }

        /// Get filter hash changed status for testing
        func getFilterHashChanged() async -> Bool {
            !pendingIgnoreChangeDirs.isEmpty
        }

        /// Get pending ignore change dirs for testing
        func getPendingIgnoreChangeDirs() async -> Set<String> {
            pendingIgnoreChangeDirs
        }

        /// Test helper to check if a path is ignored using the same hierarchical logic as runtime checks
        func testIsIgnoredPrefixCheck(relativePath: String) async -> Bool {
            await isIgnoredHierarchical(relativePath: relativePath)
        }

        func mapRelativeEventPathForTesting(_ absolutePath: String) -> (isInside: Bool, value: String) {
            switch mapToRelativeEventPath(absolutePath) {
            case let .inside(relative):
                (true, relative)
            case let .outside(original):
                (false, original)
            }
        }
    }
#endif
