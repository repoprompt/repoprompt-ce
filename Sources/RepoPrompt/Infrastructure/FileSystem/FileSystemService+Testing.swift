import Foundation

#if DEBUG
    extension FileSystemService {
        // MARK: - Testing Support

        func simulateFSEvents(
            _ events: [(absolutePath: String, flags: FileSystemWatchEventFlags, eventId: FileSystemWatchEventID)]
        ) async -> [FileSystemDelta] {
            // Clear any previous deltas
            processedFolders.removeAll()

            // Process the events and get deltas directly
            let formattedEvents = events.map { ($0.absolutePath, $0.flags, $0.eventId) }
            let deltas = await handleBatchedEvents(PendingFSEventBatch(events: formattedEvents), testMode: true)

            return deltas ?? []
        }

        /// Test-only method to get processed folders
        func getProcessedFolders() -> Set<String> {
            processedFolders
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
            let payload = FileSystemWatchEventPayload(
                entries: events.map { event in
                    FileSystemWatchEvent(path: event.absolutePath, flags: event.flags, id: event.eventId)
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
            let acceptanceGeneration = watcherIngressMailbox.startAccepting()
            let payload = FileSystemWatchEventPayload(
                entries: events.map { event in
                    FileSystemWatchEvent(path: event.absolutePath, flags: event.flags, id: event.eventId)
                }
            )
            let drain: (@Sendable () async -> Void)? = if scheduleDrain {
                { [weak self] in await self?.drainAcceptedWatcherIngressMailbox() }
            } else {
                nil
            }
            return watcherIngressMailbox.accept(
                payload,
                acceptanceGeneration: acceptanceGeneration,
                lifecycleCorrelation: nil,
                scheduleDrain: drain
            )
        }

        func watcherIngressMailboxSnapshotForTesting() -> FileSystemWatcherIngressMailbox.Snapshot {
            watcherIngressMailbox.snapshotForTesting()
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

        func setContentReadChunkHandlerForTesting(
            _ handler: (@Sendable (String) async -> Void)?
        ) {
            contentReadChunkHandler = handler
        }

        func cachedEncodingForTesting(relativePath: String) -> String.Encoding? {
            encodingMap[relativePath]
        }

        func isWatchingForChangesForTesting() -> Bool {
            watcher?.isWatching == true
        }

        func watcherStateForTesting() -> (
            pendingRawEventCount: Int,
            hasPendingOverflowRescan: Bool,
            overflowChangedIgnoreDirs: Set<String>,
            pendingScanTargets: [String: FileSystemWatchEventID],
            lastScannedEventIdByFolder: [String: FileSystemWatchEventID],
            lastVerifiedAtByFolder: [String: TimeInterval],
            fileEventCountSinceLastScan: [String: Int]
        ) {
            (
                pendingFSEvents.count,
                hasPendingOverflowRescan,
                overflowChangedIgnoreDirs,
                pendingScanTargets,
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
