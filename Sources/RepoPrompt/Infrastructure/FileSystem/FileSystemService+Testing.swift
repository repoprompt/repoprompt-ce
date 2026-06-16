import CoreFoundation
import CoreServices
import Foundation

#if DEBUG
    extension FileSystemService {
        // MARK: - Testing Support

        nonisolated static func deepCopiedEventPathForTesting(_ source: NSString) -> String? {
            deepCopyEventPath(source as CFString)
        }

        nonisolated static func buildOwnedFSEventPayloadForTesting(
            pathObjects: [Any],
            flags: [FSEventStreamEventFlags],
            ids: [FSEventStreamEventId],
            limit: Int? = nil
        ) -> (paths: [String], flags: [FSEventStreamEventFlags], ids: [FSEventStreamEventId])? {
            let safeCount = min(limit ?? pathObjects.count, pathObjects.count, flags.count, ids.count)
            guard safeCount > 0 else { return nil }

            var copiedPaths: [String] = []
            var copiedFlags: [FSEventStreamEventFlags] = []
            var copiedIDs: [FSEventStreamEventId] = []
            copiedPaths.reserveCapacity(safeCount)
            copiedFlags.reserveCapacity(safeCount)
            copiedIDs.reserveCapacity(safeCount)

            for index in 0 ..< safeCount {
                let copiedPath: String? = switch pathObjects[index] {
                case let string as NSString:
                    deepCopyEventPath(string as CFString)
                case let string as String:
                    deepCopySwiftString(string)
                default:
                    nil
                }

                guard let copiedPath else { continue }
                copiedPaths.append(copiedPath)
                copiedFlags.append(flags[index])
                copiedIDs.append(ids[index])
            }

            guard !copiedPaths.isEmpty else { return nil }
            return (copiedPaths, copiedFlags, copiedIDs)
        }

        nonisolated static func fseventCallbackEntryCountForTesting(
            pathObjects: [AnyObject],
            flags: [FSEventStreamEventFlags],
            ids: [FSEventStreamEventId],
            limit: Int? = nil
        ) -> Int {
            let safeCount = min(limit ?? pathObjects.count, pathObjects.count, flags.count, ids.count)
            guard safeCount > 0 else { return 0 }
            let cfArray = pathObjects as CFArray
            let eventPaths = UnsafeMutableRawPointer(Unmanaged.passUnretained(cfArray).toOpaque())
            return flags.withUnsafeBufferPointer { flagBuffer in
                guard let flagBase = flagBuffer.baseAddress else { return 0 }
                return ids.withUnsafeBufferPointer { idBuffer in
                    guard let idBase = idBuffer.baseAddress else { return 0 }
                    return buildOwnedFSEventPayload(
                        numEvents: safeCount,
                        eventPaths: eventPaths,
                        eventFlags: flagBase,
                        eventIds: idBase
                    )?.entries.count ?? 0
                }
            }
        }

        nonisolated static func buildOwnedFSEventPayloadFromCFArrayForTesting(
            pathObjects: [AnyObject],
            flags: [FSEventStreamEventFlags],
            ids: [FSEventStreamEventId],
            limit: Int? = nil
        ) -> (paths: [String], flags: [FSEventStreamEventFlags], ids: [FSEventStreamEventId])? {
            let safeCount = min(limit ?? pathObjects.count, pathObjects.count, flags.count, ids.count)
            guard safeCount > 0 else { return nil }
            let cfArray = pathObjects as CFArray
            let eventPaths = UnsafeMutableRawPointer(Unmanaged.passUnretained(cfArray).toOpaque())
            return flags.withUnsafeBufferPointer { flagBuffer in
                guard let flagBase = flagBuffer.baseAddress else { return nil }
                return ids.withUnsafeBufferPointer { idBuffer in
                    guard let idBase = idBuffer.baseAddress else { return nil }
                    guard let payload = buildOwnedFSEventPayload(
                        numEvents: safeCount,
                        eventPaths: eventPaths,
                        eventFlags: flagBase,
                        eventIds: idBase
                    ) else { return nil }
                    return (
                        payload.entries.map(\.path),
                        payload.entries.map(\.flags),
                        payload.entries.map(\.id)
                    )
                }
            }
        }

        func simulateFSEvents(
            _ events: [(absolutePath: String, flags: FSEventStreamEventFlags, eventId: FSEventStreamEventId)]
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
            pendingScanTargets: [String: FSEventStreamEventId],
            lastScannedEventIdByFolder: [String: FSEventStreamEventId]
        ) {
            (pendingScanTargets, lastScannedEventIdByFolder)
        }

        func enqueuePendingRawEventsForTesting(
            _ events: [(absolutePath: String, flags: FSEventStreamEventFlags, eventId: FSEventStreamEventId)]
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
            _ events: [(absolutePath: String, flags: FSEventStreamEventFlags, eventId: FSEventStreamEventId)],
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
            fseventStreamRef != nil
        }

        func watcherStateForTesting() -> (
            pendingRawEventCount: Int,
            hasPendingOverflowRescan: Bool,
            overflowChangedIgnoreDirs: Set<String>,
            pendingScanTargets: [String: FSEventStreamEventId],
            pendingQuietFolderScanTargets: Set<String>,
            dirtyRecoveryScanTargets: Set<String>,
            recoveryScanFailureCountByFolder: [String: Int],
            lastScannedEventIdByFolder: [String: FSEventStreamEventId],
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
