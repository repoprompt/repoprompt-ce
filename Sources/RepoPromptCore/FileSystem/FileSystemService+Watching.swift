import Dispatch
import Foundation

extension FileSystemService {
    package struct DetachedWatcherStop {
        package let acceptedWatermark: FileSystemWatcherIngressMailbox.Watermark
        package let ingressGeneration: UInt64
        package let lifecycleEpoch: UInt64
    }

    // MARK: - Public watchers API

    /// Installs the sole ordered publication consumer for this root.
    package nonisolated func subscribeToChanges(
        _ handler: @escaping FileSystemDeltaPublicationHub.Handler
    ) -> FileSystemDeltaPublicationSubscription {
        publicationHub.subscribe(handler)
    }

    package nonisolated func closeChangePublication() {
        publicationHub.close()
    }

    /// Gracefully tears down the watcher only after every callback that returned
    /// accepted has crossed the service publication boundary.
    package func stopWatchingForChanges() async {
        let detachedStop = detachWatcherAndCaptureAcceptedWatermark()
        _ = await flushPendingEventsNow(
            throughAcceptedWatcherWatermark: detachedStop.acceptedWatermark
        )
        finishDetachedWatcherStop(detachedStop)
    }

    /// (Re)start the injected watcher if needed.
    package func startWatchingForChanges() {
        startWatcher()
    }

    package func fileExistsOnDisk(relativePath: String) -> Bool {
        let absolutePath = fullPath(forRelativePath: relativePath)
        return fm.fileExists(atPath: absolutePath, isDirectory: nil)
    }

    package func regularFileExistsOnDisk(relativePath rawRelativePath: String) -> Bool {
        let lifecycleCorrelation = WorkspaceRuntimePerf.currentLifecycleCorrelation
        WorkspaceRuntimePerf.lifecycleEvent(
            WorkspaceRuntimePerf.Lifecycle.Search.contentFreshnessRootEntered,
            correlation: lifecycleCorrelation,
            WorkspaceRuntimePerf.Dimensions(rootToken: diagnosticRootToken.uuidString)
        )
        let validationState = WorkspaceRuntimePerf.begin(WorkspaceRuntimePerf.Stage.Search.contentFreshnessValidationRootActorBody)
        var outcome = "missing"
        defer {
            WorkspaceRuntimePerf.end(
                WorkspaceRuntimePerf.Stage.Search.contentFreshnessValidationRootActorBody,
                validationState,
                WorkspaceRuntimePerf.Dimensions(outcome: outcome, rootToken: diagnosticRootToken.uuidString)
            )
            WorkspaceRuntimePerf.lifecycleEvent(
                WorkspaceRuntimePerf.Lifecycle.Search.contentFreshnessRootReturned,
                correlation: lifecycleCorrelation,
                WorkspaceRuntimePerf.Dimensions(outcome: outcome, rootToken: diagnosticRootToken.uuidString)
            )
        }
        let relativePath = (rawRelativePath as NSString).standardizingPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relativePath.isEmpty, !relativePath.hasPrefix("../"), relativePath != ".." else { return false }
        let absolutePath = fullPath(forRelativePath: relativePath)
        let standardizedAbsolutePath = (absolutePath as NSString).standardizingPath
        let rootPrefix = standardizedRootPath.hasSuffix("/") ? standardizedRootPath : standardizedRootPath + "/"
        guard standardizedAbsolutePath == standardizedRootPath || standardizedAbsolutePath.hasPrefix(rootPrefix) else { return false }

        var isDirectory = ObjCBool(false)
        guard fm.fileExists(atPath: standardizedAbsolutePath, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        if let values = try? URL(fileURLWithPath: standardizedAbsolutePath).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            if values.isSymbolicLink == true { return false }
            if values.isRegularFile == false { return false }
        }
        if skipSymlinks, pathContainsSymlinkComponent(relativePath: relativePath) { return false }
        outcome = "current"
        return true
    }

    package func catalogEligibleRegularFileExists(relativePath rawRelativePath: String) async -> Bool {
        await catalogRegularFileEligibility(relativePath: rawRelativePath).isEligible
    }

    package func catalogFolderIsDiscoverable(relativePath rawRelativePath: String) async -> Bool {
        let relativePath = (rawRelativePath as NSString).standardizingPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relativePath.isEmpty, relativePath != "..", !relativePath.hasPrefix("../") else { return false }
        let absolutePath = fullPath(forRelativePath: relativePath)
        let standardizedAbsolutePath = (absolutePath as NSString).standardizingPath
        let rootPrefix = standardizedRootPath.hasSuffix("/") ? standardizedRootPath : standardizedRootPath + "/"
        guard standardizedAbsolutePath.hasPrefix(rootPrefix) else { return false }

        var isDirectory = ObjCBool(false)
        guard fm.fileExists(atPath: standardizedAbsolutePath, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        if skipSymlinks && pathContainsSymlinkComponent(relativePath: relativePath) { return false }
        let canonicalPath = URL(fileURLWithPath: standardizedAbsolutePath).resolvingSymlinksInPath().path
        let canonicalPrefix = canonicalRootPath.hasSuffix("/") ? canonicalRootPath : canonicalRootPath + "/"
        guard canonicalPath == canonicalRootPath || canonicalPath.hasPrefix(canonicalPrefix) else { return false }

        if enableHierarchicalIgnores {
            return await !(isIgnoredHierarchical(relativePath: relativePath, isDirectory: true) || isIgnoredPrefixCheck(relativePath: relativePath, isDirectory: true))
        }
        return !isIgnoredPrefixCheck(relativePath: relativePath, isDirectory: true)
    }

    package func catalogRegularFileEligibility(relativePath rawRelativePath: String) async -> CatalogRegularFileEligibility {
        let relativePath = (rawRelativePath as NSString).standardizingPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relativePath.isEmpty, !relativePath.hasPrefix("../"), relativePath != ".." else {
            return .ineligible(.invalidRelativePath)
        }
        let absolutePath = fullPath(forRelativePath: relativePath)
        let standardizedAbsolutePath = (absolutePath as NSString).standardizingPath
        let rootPrefix = standardizedRootPath.hasSuffix("/") ? standardizedRootPath : standardizedRootPath + "/"
        guard standardizedAbsolutePath.hasPrefix(rootPrefix) else { return .ineligible(.outsideRoot) }

        var isDirectory = ObjCBool(false)
        guard fm.fileExists(atPath: standardizedAbsolutePath, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .ineligible(.missingOrDirectory)
        }
        let url = URL(fileURLWithPath: standardizedAbsolutePath)
        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            if values.isSymbolicLink == true { return .ineligible(.symbolicLink) }
            if values.isRegularFile == false { return .ineligible(.nonRegularFile) }
        }
        if skipSymlinks && pathContainsSymlinkComponent(relativePath: relativePath) {
            return .ineligible(.symlinkComponent)
        }

        let canonicalPath = url.resolvingSymlinksInPath().path
        let canonicalPrefix = canonicalRootPath.hasSuffix("/") ? canonicalRootPath : canonicalRootPath + "/"
        guard canonicalPath == canonicalRootPath || canonicalPath.hasPrefix(canonicalPrefix) else {
            return .ineligible(.outsideCanonicalRoot)
        }

        let isIgnored: Bool = if enableHierarchicalIgnores {
            await isIgnoredHierarchical(relativePath: relativePath, isDirectory: false) || isIgnoredPrefixCheck(relativePath: relativePath)
        } else {
            isIgnoredPrefixCheck(relativePath: relativePath)
        }
        return isIgnored ? .ineligible(.ignored) : .eligible
    }

    package func registerExplicitlyManagedRegularFile(relativePath rawRelativePath: String) async -> CatalogRegularFileEligibility {
        let eligibility = await catalogRegularFileEligibility(relativePath: rawRelativePath)
        switch eligibility {
        case .eligible, .ineligible(.ignored):
            let relativePath = (rawRelativePath as NSString).standardizingPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            visitedPaths.insert(relativePath)
            visitedItems[relativePath] = false
        case .ineligible:
            break
        }
        return eligibility
    }

    package func pathContainsSymlinkComponent(relativePath: String) -> Bool {
        var current = rootURL
        for component in relativePath.split(separator: "/") {
            current.appendPathComponent(String(component))
            if ((try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false) == true {
                return true
            }
        }
        return false
    }

    package nonisolated func captureAcceptedWatcherWatermark() -> FileSystemWatcherIngressMailbox.Watermark {
        watcherIngressMailbox.captureAcceptedWatermark()
    }

    package func flushPendingEventsNow() async {
        _ = await flushPendingEventsNow(throughAcceptedWatcherWatermark: captureAcceptedWatcherWatermark())
    }

    /// Flushes watcher work through at least the callback-accepted watermark cut.
    ///
    /// Later callbacks may already have joined an actor-visible batch or an overflow
    /// sentinel, so this is intentionally a lower-bound barrier rather than a strict
    /// exclusion boundary. It never returns before the captured cut is published.
    package func flushPendingEventsNow(
        throughAcceptedWatcherWatermark target: FileSystemWatcherIngressMailbox.Watermark
    ) async -> UInt64 {
        drainAcceptedWatcherIngressMailboxPayloads(through: target)
        cancelScheduledCoalescingDelay()

        while lastPublishedWatcherAcceptedWatermark < target {
            if let watcherBatchProcessingTask {
                await watcherBatchProcessingTask.value
                drainAcceptedWatcherIngressMailboxPayloads(through: target)
                cancelScheduledCoalescingDelay()
                continue
            }

            guard startProcessingPendingWatcherBatchIfNeeded() else {
                // A callback cut must remain representable even if accepted payloads
                // were explicitly abandoned during watcher teardown or produced no deltas.
                publishFileSystemDeltas([], source: .watcherBarrierNoop, watcherAcceptedWatermark: target)
                break
            }
        }
        return lastServicePublicationSequence
    }

    #if DEBUG
        public func pendingRawEventCountForDiagnostics() -> Int {
            pendingFSEvents.count
        }

        func lastPublishedDeltaCoalescingDiagnosticsForTesting() -> PublishedDeltaCoalescingDiagnostics? {
            lastPublishedDeltaCoalescingDiagnostics
        }

        public func coalescedPublishableDeltasForTesting(_ deltas: [FileSystemDelta]) -> [FileSystemDelta] {
            coalescedPublishableDeltas(from: deltas)
        }
    #endif

    package func coalescedPublishableDeltas(from deltas: [FileSystemDelta]) -> [FileSystemDelta] {
        FileSystemDeltaPreparation.coalesce(deltas, inRoot: canonicalRootPath)
    }

    // MARK: - Watcher Setup

    package func startWatcher() {
        guard watcher == nil else { return }
        watcherLifecycleEpoch &+= 1
        let acceptanceGeneration = watcherIngressMailbox.startAccepting()
        let watcher = watcherFactory.makeWatcher(path: path)
        guard watcher.start(eventHandler: { [weak self] payload in
            guard let self else { return }
            let lifecycleCorrelation = WorkspaceRuntimePerf.makeLifecycleCorrelationIfActive()
            let diagnosticContext = lifecycleCorrelation.map {
                FileSystemDiagnosticContext(correlationID: $0.id)
            }
            let acceptedWatermark = watcherIngressMailbox.accept(
                payload,
                acceptanceGeneration: acceptanceGeneration,
                diagnosticContext: diagnosticContext
            ) { [weak self] in
                await self?.drainAcceptedWatcherIngressMailbox()
            }
            guard let acceptedWatermark else { return }
            WorkspaceRuntimePerf.lifecycleEvent(
                WorkspaceRuntimePerf.Lifecycle.FileSystem.callbackAccepted,
                correlation: lifecycleCorrelation,
                WorkspaceRuntimePerf.Dimensions(
                    sourceItemCount: payload.count,
                    rootToken: diagnosticRootToken.uuidString,
                    ingressSequence: acceptedWatermark.rawValue
                )
            )
        }) else {
            resetWatcherIngressState()
            return
        }
        self.watcher = watcher
        fileSystemDebugLog("Filesystem watcher started for path: \(path)")
    }

    /// Detaches the platform source and closes admission while preserving all work
    /// whose callback already returned accepted.
    package func detachWatcherAndCaptureAcceptedWatermark() -> DetachedWatcherStop {
        let detachedStop = DetachedWatcherStop(
            acceptedWatermark: watcherIngressMailbox.stopAccepting(),
            ingressGeneration: watcherIngressGeneration,
            lifecycleEpoch: watcherLifecycleEpoch
        )
        if let watcher {
            watcher.stop()
            self.watcher = nil
            fileSystemDebugLog("Filesystem watcher stopped for path: \(path)")
        }
        return detachedStop
    }

    /// Destructive cleanup is valid only after `flushPendingEventsNow(through:)`.
    package func finishDetachedWatcherStop(_ detachedStop: DetachedWatcherStop) {
        guard watcher == nil,
              watcherIngressGeneration == detachedStop.ingressGeneration,
              watcherLifecycleEpoch == detachedStop.lifecycleEpoch
        else {
            return
        }
        resetWatcherIngressState()
    }

    // MARK: - Core event coalescing & handling

    package func drainAcceptedWatcherIngressMailbox() async {
        drainAcceptedWatcherIngressMailboxPayloads()
    }

    package func drainAcceptedWatcherIngressMailboxPayloads(
        through target: FileSystemWatcherIngressMailbox.Watermark? = nil
    ) {
        while let payload = watcherIngressMailbox.takeNextAcceptedPayload(through: target) {
            enqueueAcceptedWatcherPayload(payload)
        }
    }

    package func enqueueAcceptedWatcherPayload(_ payload: FileSystemWatcherIngressMailbox.AcceptedPayload) {
        WorkspaceRuntimePerf.lifecycleEvent(
            WorkspaceRuntimePerf.Lifecycle.FileSystem.serviceEnqueueEntered,
            correlation: payload.diagnosticContext.map {
                WorkspaceRuntimePerf.LifecycleCorrelation(id: $0.correlationID)
            },
            WorkspaceRuntimePerf.Dimensions(
                sourceItemCount: payload.rawEntryCount,
                rootToken: diagnosticRootToken.uuidString,
                queueDepth: pendingFSEvents.count,
                ingressSequence: payload.acceptedHighWatermark.rawValue
            )
        )

        switch payload.contents {
        case let .entries(entries):
            enqueueFSEventEntries(entries, acceptedHighWatermark: payload.acceptedHighWatermark)
        case let .overflowRootRescan(highestEventID, changedIgnoreAbsolutePaths):
            overflowChangedIgnoreDirs.formUnion(ignoreChangeDirs(in: changedIgnoreAbsolutePaths.map { ($0, [], 0) }))
            collapsePendingEventsToRootRescan(
                upTo: highestEventID,
                acceptedHighWatermark: payload.acceptedHighWatermark
            )
        }
        scheduleCoalescingIfNeeded()
    }

    package func enqueueFSEventEntries(
        _ entries: [FileSystemWatchEvent],
        acceptedHighWatermark: FileSystemWatcherIngressMailbox.Watermark? = nil
    ) {
        guard !entries.isEmpty else { return }
        let payloadMaxEventID = entries.map(\.id).max() ?? 0
        if hasPendingOverflowRescan {
            overflowChangedIgnoreDirs.formUnion(ignoreChangeDirs(in: entries.map { ($0.path, $0.flags, $0.id) }))
            collapsePendingEventsToRootRescan(
                upTo: max(pendingFSEvents.first?.id ?? 0, payloadMaxEventID),
                acceptedHighWatermark: acceptedHighWatermark
            )
            return
        }

        let projectedCount = pendingFSEvents.count + entries.count
        if projectedCount > Self.maxPendingRawEvents {
            let bufferedMaxEventID = pendingFSEvents.map(\.id).max() ?? 0
            let maxEventID = max(bufferedMaxEventID, payloadMaxEventID)
            overflowChangedIgnoreDirs.formUnion(ignoreChangeDirs(in: pendingFSEvents))
            overflowChangedIgnoreDirs.formUnion(ignoreChangeDirs(in: entries.map { ($0.path, $0.flags, $0.id) }))
            fileSystemDebugLog(
                "FSEvents overflow for \(path): collapsing \(projectedCount) raw events into a root rescan at event \(maxEventID)"
            )
            collapsePendingEventsToRootRescan(
                upTo: maxEventID,
                acceptedHighWatermark: acceptedHighWatermark
            )
            return
        }

        pendingFSEvents.reserveCapacity(projectedCount)
        pendingFSEvents.append(contentsOf: entries.map { ($0.path, $0.flags, $0.id) })
        if let acceptedHighWatermark {
            pendingWatcherAcceptedHighWatermark = max(pendingWatcherAcceptedHighWatermark ?? .zero, acceptedHighWatermark)
        }
    }

    package func scheduleCoalescingIfNeeded() {
        guard coalescingTask == nil, !pendingFSEvents.isEmpty else { return }
        coalescingTask = Task { [weak self] in
            do {
                guard let self else { return }
                try await Task.sleep(nanoseconds: UInt64(coalescingDelay * 1_000_000_000))
                await scheduledCoalescingDelayDidFinish()
            } catch {
                return
            }
        }
    }

    package func scheduledCoalescingDelayDidFinish() {
        coalescingTask = nil
        if !startProcessingPendingWatcherBatchIfNeeded(), !pendingFSEvents.isEmpty {
            scheduleCoalescingIfNeeded()
        }
    }

    package func cancelScheduledCoalescingDelay() {
        coalescingTask?.cancel()
        coalescingTask = nil
    }

    @discardableResult
    package func startProcessingPendingWatcherBatchIfNeeded() -> Bool {
        guard watcherBatchProcessingTask == nil else { return true }
        let batch = takePendingFSEventsForProcessing()
        guard !batch.isEmpty || batch.watcherAcceptedHighWatermark != nil else { return false }

        nextWatcherBatchProcessingToken &+= 1
        let token = nextWatcherBatchProcessingToken
        watcherBatchProcessingToken = token
        watcherBatchProcessingTask = Task { [weak self] in
            await self?.processWatcherBatch(batch, token: token)
        }
        return true
    }

    package func processWatcherBatch(_ batch: PendingFSEventBatch, token: UInt64) async {
        #if DEBUG
            if let watcherBatchWillProcessHandler {
                await watcherBatchWillProcessHandler()
            }
        #endif
        guard !Task.isCancelled else {
            watcherBatchProcessingDidFinish(token: token)
            return
        }
        _ = await handleBatchedEvents(batch)
        watcherBatchProcessingDidFinish(token: token)
    }

    package func watcherBatchProcessingDidFinish(token: UInt64) {
        guard watcherBatchProcessingToken == token else { return }
        watcherBatchProcessingTask = nil
        watcherBatchProcessingToken = nil
        if !pendingFSEvents.isEmpty {
            scheduleCoalescingIfNeeded()
        }
    }

    package func collapsePendingEventsToRootRescan(
        upTo eventID: FileSystemWatchEventID,
        acceptedHighWatermark: FileSystemWatcherIngressMailbox.Watermark? = nil
    ) {
        overflowChangedIgnoreDirs.formUnion(ignoreChangeDirs(in: pendingFSEvents))
        pendingFSEvents.removeAll(keepingCapacity: false)
        pendingFSEvents.append((standardizedRootPath, Self.overflowRescanEventFlags, eventID))
        if let acceptedHighWatermark {
            pendingWatcherAcceptedHighWatermark = max(pendingWatcherAcceptedHighWatermark ?? .zero, acceptedHighWatermark)
        }
        pendingWatcherPublicationSource = .overflowRootRescan
        hasPendingOverflowRescan = true
    }

    package func takePendingFSEventsForProcessing() -> PendingFSEventBatch {
        let batch = PendingFSEventBatch(
            events: pendingFSEvents,
            watcherAcceptedHighWatermark: pendingWatcherAcceptedHighWatermark,
            publicationSource: pendingWatcherPublicationSource,
            watcherIngressGeneration: watcherIngressGeneration
        )
        pendingFSEvents.removeAll(keepingCapacity: false)
        pendingWatcherAcceptedHighWatermark = nil
        pendingWatcherPublicationSource = .watcher
        hasPendingOverflowRescan = false
        return batch
    }

    package func ignoreChangeDirs(
        in events: [(String, FileSystemWatchEventFlags, FileSystemWatchEventID)]
    ) -> Set<String> {
        var dirs = Set<String>()
        for (absolutePath, _, _) in events {
            guard case let .inside(relativePath) = mapToRelativeEventPath(absolutePath) else { continue }
            guard isIgnoreFile(relativePath) else { continue }
            dirs.insert(parentDirectory(of: relativePath))
        }
        return dirs
    }

    package func resetWatcherIngressState() {
        watcherIngressMailbox.discardPendingAndCancelDrain()
        watcherIngressGeneration &+= 1
        cancelScheduledCoalescingDelay()
        watcherBatchProcessingTask?.cancel()
        pendingFSEvents.removeAll(keepingCapacity: false)
        pendingWatcherAcceptedHighWatermark = nil
        pendingWatcherPublicationSource = .watcher
        hasPendingOverflowRescan = false
        overflowChangedIgnoreDirs.removeAll(keepingCapacity: false)
        pendingScanTargets.removeAll(keepingCapacity: false)
        lastScannedEventIdByFolder.removeAll(keepingCapacity: false)
        lastVerifiedAtByFolder.removeAll(keepingCapacity: false)
        fileEventCountSinceLastScan.removeAll(keepingCapacity: false)
    }

    package func watcherBatchBelongsToCurrentIngressGeneration(_ batch: PendingFSEventBatch) -> Bool {
        guard let generation = batch.watcherIngressGeneration else { return true }
        return generation == watcherIngressGeneration
    }

    // MARK: - Filesystem watcher flag parsing

    #if DEBUG
        /// Format semantic watcher flags into a human-readable string for debugging.
        static func formatFSEventFlags(_ flags: FileSystemWatchEventFlags) -> String {
            let names: [(FileSystemWatchEventFlags, String)] = [
                (.itemCreated, "Created"),
                (.itemRemoved, "Removed"),
                (.itemRenamed, "Renamed"),
                (.contentChanged, "ContentChanged"),
                (.metadataChanged, "MetadataChanged"),
                (.itemIsFile, "IsFile"),
                (.itemIsDirectory, "IsDir"),
                (.itemIsSymlink, "IsSymlink"),
                (.mustScanSubdirectories, "MustScanSubDirs"),
                (.droppedEvents, "DroppedEvents"),
                (.rootChanged, "RootChanged")
            ]
            let labels = names.compactMap { flags.contains($0.0) ? $0.1 : nil }
            return labels.isEmpty ? "None" : labels.joined(separator: " | ")
        }
    #endif

    /// Parsed representation of watcher flags for cleaner event handling.
    package struct ParsedEvent {
        let isDir: Bool
        let isFile: Bool
        let isCreated: Bool
        let isRemoved: Bool
        let isRenamed: Bool
        let isContentChange: Bool
        let isMetadataChange: Bool
        let mustScanSubdirs: Bool
        let userOrKernelDropped: Bool
        let rootChanged: Bool

        var requiresAggressiveScan: Bool {
            mustScanSubdirs || userOrKernelDropped || rootChanged
        }
    }

    /// Parse semantic watcher flags into a structured representation.
    package static func parseEventFlags(
        _ flags: FileSystemWatchEventFlags,
        isDirFallback: Bool
    ) -> ParsedEvent {
        let isDirFlag = flags.contains(.itemIsDirectory)
        let isFileFlag = flags.contains(.itemIsFile)
        return ParsedEvent(
            isDir: isDirFlag || (!isFileFlag && isDirFallback),
            isFile: isFileFlag || (!isDirFlag && !isDirFallback),
            isCreated: flags.contains(.itemCreated),
            isRemoved: flags.contains(.itemRemoved),
            isRenamed: flags.contains(.itemRenamed),
            isContentChange: flags.contains(.contentChanged),
            isMetadataChange: flags.contains(.metadataChanged),
            mustScanSubdirs: flags.contains(.mustScanSubdirectories),
            userOrKernelDropped: flags.contains(.droppedEvents),
            rootChanged: flags.contains(.rootChanged)
        )
    }

    // MARK: - Temp File Detection for Atomic Saves

    /// Common temp file suffixes used by editors for atomic saves
    package static let tempNameSuffixes: [String] = [
        "~", // vim backup
        ".tmp", ".temp",
        ".swp", ".swo", ".swx", // vim swap
        ".bak", ".backup", ".orig", ".old",
        "__jb_tmp__", "__jb_old__" // JetBrains
    ]

    /// Common temp file prefixes used by editors
    package static let tempNamePrefixes: [String] = [
        ".#", // Emacs
        "._", // macOS resource fork
        "~$" // MS Office
    ]

    /// Check if a path looks like a temporary file used for atomic saves
    package static func isTempSaveName(_ relPath: String) -> Bool {
        let name = (relPath as NSString).lastPathComponent.lowercased()

        for suffix in tempNameSuffixes where name.hasSuffix(suffix) {
            return true
        }
        for prefix in tempNamePrefixes where name.hasPrefix(prefix) {
            return true
        }

        // Vim-style hidden swap: .filename.swp
        if name.hasPrefix("."), name.contains(".sw") { return true }

        return false
    }

    // MARK: - Safety-Net Scanning

    /// Get current time for safety-net interval tracking
    @inline(__always)
    package func currentTime() -> TimeInterval {
        Date().timeIntervalSinceReferenceDate
    }

    /// Record that a folder was just verified via directory scan
    package func recordFolderVerified(_ folder: String) {
        lastVerifiedAtByFolder[folder] = currentTime()
        fileEventCountSinceLastScan[folder] = 0
    }

    /// Check if a folder should receive a safety-net scan based on event count and time
    /// Returns true if we should schedule a scan
    package func shouldScheduleSafetyNetScan(for parent: String) -> Bool {
        guard !parent.isEmpty else { return false }

        // Increment event count
        let count = (fileEventCountSinceLastScan[parent] ?? 0) + 1
        fileEventCountSinceLastScan[parent] = count

        // Check thresholds
        let lastVerified = lastVerifiedAtByFolder[parent] ?? 0
        let elapsed = currentTime() - lastVerified

        let stale = elapsed >= safetyNetMinInterval
        let highChurn = count >= safetyNetEventThreshold

        return stale || highChurn
    }

    package func handleBatchedEvents(
        _ batch: PendingFSEventBatch,
        testMode: Bool = false
    ) async -> [FileSystemDelta]? {
        guard watcherBatchBelongsToCurrentIngressGeneration(batch) else {
            return testMode ? [] : nil
        }
        let events = batch.events
        guard !events.isEmpty else {
            if let watermark = batch.watcherAcceptedHighWatermark {
                publishFileSystemDeltas([], source: .watcherBarrierNoop, watcherAcceptedWatermark: watermark)
            }
            return testMode ? [] : nil
        }

        #if DEBUG
            if Self.enableDebugLogging {
                print("┌─────────────────────────────────────────────────────────────")
                print("│ 📥 handleBatchedEvents: Processing \(events.count) coalesced events")
                for (path, flags, eventId) in events {
                    print("│   path: '\(path)'")
                    print("│   flags: \(Self.formatFSEventFlags(flags)), eventId: \(eventId)")
                }
                print("└─────────────────────────────────────────────────────────────")
            }
            if isTestMode, Self.enableDebugLogging {
                print("DEBUG: handleBatchedEvents called with \(events.count) events")
                for (path, flags, _) in events {
                    print("DEBUG: Event - path: '\(path)', flags: \(flags)")
                }
            }
        #endif

        var foldersToScan = Set<String>()
        var folderMaxEventId: [String: FileSystemWatchEventID] = [:] // Track max event ID per folder
        var immediateModifications: [FileSystemDelta] = []
        var changedIgnoreDirs = overflowChangedIgnoreDirs
        overflowChangedIgnoreDirs.removeAll(keepingCapacity: false)

        /// Helper to track folder with its event ID
        func trackFolder(_ folder: String, eventId: FileSystemWatchEventID) {
            foldersToScan.insert(folder)
            folderMaxEventId[folder] = max(folderMaxEventId[folder] ?? 0, eventId)
        }

        for (absPath, flags, eventId) in events {
            let relPath: String
            switch mapToRelativeEventPath(absPath) {
            case let .outside(original):
                #if DEBUG
                    if isTestMode, Self.enableDebugLogging {
                        print("DEBUG: Dropping event outside root: \(original)")
                    }
                #endif
                continue
            case let .inside(relative):
                relPath = relative
            }

            if isGitMetadataPath(relPath) {
                #if DEBUG
                    if isTestMode, Self.enableDebugLogging {
                        print("DEBUG: Ignoring .git metadata event at \(relPath)")
                    }
                #endif
                continue
            }

            if isRepoPromptTempPath(relPath) {
                continue
            }

            #if DEBUG
                if isTestMode, Self.enableDebugLogging {
                    print("DEBUG: Converted absolute path '\(absPath)' to relative path '\(relPath)'")
                }
            #endif

            let isIgnore = isIgnoreFile(relPath)
            let isControlFile = isSpecialControlFile(relPath)

            // Always update filter flag for ignore files.
            if isIgnore {
                changedIgnoreDirs.insert(parentDirectory(of: relPath))
            }

            // Determine whether this event is for a directory, trusting FSEvents when possible.
            let isDirFallback = visitedItems[relPath] ?? fileOrFolderIsDir(relPath)
            let parsed = Self.parseEventFlags(flags, isDirFallback: isDirFallback)
            let isDir = parsed.isDir

            // Handle aggressive scan requirements (FSEvents overflow, dropped events, root changes)
            // These are rare but critical - we must rescan to maintain correctness
            if parsed.requiresAggressiveScan {
                // Schedule root scan for comprehensive recovery
                trackFolder("", eventId: eventId)
                #if DEBUG
                    if isTestMode, Self.enableDebugLogging {
                        print("DEBUG: Aggressive scan required - mustScan=\(parsed.mustScanSubdirs), dropped=\(parsed.userOrKernelDropped), rootChanged=\(parsed.rootChanged)")
                    }
                #endif
                continue
            }

            // ---------- UPDATED FILTER LOGIC ---------------------------------------
            let isKnown = visitedPaths.contains(relPath)
            let shouldIgnore: Bool = if enableHierarchicalIgnores {
                await isIgnoredHierarchical(relativePath: relPath, isDirectory: isDir)
            } else {
                isIgnoredPrefixCheck(relativePath: relPath, isDirectory: isDir)
            }

            #if DEBUG
                if isTestMode, Self.enableDebugLogging {
                    let isRename = flags.contains(.itemRenamed)
                    print("DEBUG: Processing event for '\(relPath)' - isKnown=\(isKnown), isRename=\(isRename), shouldIgnore=\(shouldIgnore), isIgnoreFile=\(isIgnoreFile(relPath))")
                }
            #endif

            // Drop only "brand-new + still-ignored + not an ignore-file" paths
            if !isKnown && !isControlFile && shouldIgnore {
                #if DEBUG
                    if isTestMode, Self.enableDebugLogging {
                        print("DEBUG: FILTERED OUT event for path: \(relPath)")
                    }
                #endif
                continue
            }
            // ----------------------------------------------------------------------

            // Use parsed flags for cleaner event handling
            let removed = parsed.isRemoved
            let created = parsed.isCreated
            let modified = parsed.isContentChange || parsed.isMetadataChange || created

            #if DEBUG
                if Self.enableDebugLogging {
                    print("📋 Event for '\(relPath)':")
                    print("   isKnown=\(isKnown), isDir=\(isDir), isRenamed=\(parsed.isRenamed)")
                    print("   removed=\(removed), created=\(created), modified=\(modified)")
                    if removed, !isKnown {
                        print("   ⚠️ REMOVED flag set but path NOT KNOWN - will NOT emit fileRemoved!")
                    }
                    if removed, !parsed.isRenamed {
                        print("   📋 REMOVED flag set but NOT a rename - pure deletion (handled)")
                    }
                }
            #endif

            #if DEBUG
                // Debug logging for flag analysis
                if isTestMode, Self.enableDebugLogging, relPath.contains("file.txt") {
                    print("DEBUG: Flags for \(relPath): \(flags)")
                    print("  ContentChanged: \(flags.contains(.contentChanged))")
                    print("  ItemCreated: \(flags.contains(.itemCreated))")
                    print("  ItemRemoved: \(flags.contains(.itemRemoved))")
                    print("  ItemRenamed: \(flags.contains(.itemRenamed))")
                    print("  MetadataChanged: \(flags.contains(.metadataChanged))")
                    print("  Calculated modified: \(modified)")
                    print("  Calculated removed: \(removed)")
                    print("  Is in visitedPaths: \(visitedPaths.contains(relPath))")
                }
            #endif

            if !removed && modified {
                // For files already tracked, send immediate modification
                if visitedPaths.contains(relPath) {
                    if isDir {
                        let mdate = await getItemModificationDateIfAvailable(atRelativePath: relPath)
                        immediateModifications.append(.folderModified(relPath, mdate))
                    } else {
                        let mdate = try? await getFileModificationDate(atRelativePath: relPath)
                        immediateModifications.append(.fileModified(relPath, mdate))
                    }
                    // If it's a tracked folder, also scan it for changes
                    if isDir {
                        trackFolder(relPath, eventId: eventId)
                    }
                } else {
                    let parent = parentDirectory(of: relPath)
                    trackFolder(parent, eventId: eventId)
                }
            }

            // ── Pure deletion handling (removed WITHOUT rename flag) ────────────────
            // Direct deletions (rm, programmatic) may not have the rename flag
            if removed && !parsed.isRenamed && isKnown {
                let fullPath = fullPath(forRelativePath: relPath)
                let stillExists = fm.fileExists(atPath: fullPath, isDirectory: nil)

                if !stillExists {
                    // File is truly gone - emit removal delta
                    #if DEBUG
                        if Self.enableDebugLogging {
                            print("🗑️ PURE DELETION detected for '\(relPath)' (no rename flag)")
                        }
                    #endif
                    immediateModifications.append(isDir ? .folderRemoved(relPath) : .fileRemoved(relPath))

                    // If directory, also remove children
                    if isDir {
                        let childrenToRemove = visitedPaths.filter { $0.hasPrefix(relPath + "/") }
                        for child in childrenToRemove {
                            let childIsDir = visitedItems[child] ?? false
                            immediateModifications.append(childIsDir ? .folderRemoved(child) : .fileRemoved(child))
                            visitedPaths.remove(child)
                            visitedItems.removeValue(forKey: child)
                        }
                    }

                    visitedPaths.remove(relPath)
                    visitedItems.removeValue(forKey: relPath)
                } else {
                    // Anomaly: removed flag but file still exists - schedule parent scan
                    let parent = parentDirectory(of: relPath)
                    if !parent.isEmpty {
                        trackFolder(parent, eventId: eventId)
                    }
                }
                continue
            }

            // ── Rename handling ──────────────────────────────────────────────────────
            if parsed.isRenamed {
                let isTempFile = Self.isTempSaveName(relPath)

                // Renamed events sometimes arrive WITHOUT Created/Removed (Finder trash moves, cross-dir moves, etc.)
                if !created, !removed {
                    // Ignore temp-save churn
                    if isTempFile { continue }

                    let fullPath = fullPath(forRelativePath: relPath)
                    var isDirFlag: ObjCBool = false
                    let exists = fm.fileExists(atPath: fullPath, isDirectory: &isDirFlag)
                    let diskIsDir = exists ? isDirFlag.boolValue : isDir // fallback to our best guess

                    if exists {
                        // Path exists at this location: treat as add (if unknown) or modify (if known)
                        if isKnown {
                            if diskIsDir {
                                let mdate = await getItemModificationDateIfAvailable(atRelativePath: relPath)
                                immediateModifications.append(.folderModified(relPath, mdate))
                                trackFolder(relPath, eventId: eventId)
                            } else {
                                let mdate = try? await getFileModificationDate(atRelativePath: relPath)
                                immediateModifications.append(.fileModified(relPath, mdate))
                            }
                        } else {
                            immediateModifications.append(diskIsDir ? .folderAdded(relPath) : .fileAdded(relPath))
                            visitedPaths.insert(relPath)
                            visitedItems[relPath] = diskIsDir
                            if diskIsDir { trackFolder(relPath, eventId: eventId) }
                        }
                    } else if isKnown {
                        // Path no longer exists here => removal from watched root
                        immediateModifications.append(diskIsDir ? .folderRemoved(relPath) : .fileRemoved(relPath))

                        if diskIsDir {
                            let childrenToRemove = visitedPaths.filter { $0.hasPrefix(relPath + "/") }
                            for child in childrenToRemove {
                                let childIsDir = visitedItems[child] ?? false
                                immediateModifications.append(childIsDir ? .folderRemoved(child) : .fileRemoved(child))
                                visitedPaths.remove(child)
                                visitedItems.removeValue(forKey: child)
                            }
                        }

                        visitedPaths.remove(relPath)
                        visitedItems.removeValue(forKey: relPath)
                    }

                    // Always verify parent to discover paired destination if it moved within the repo
                    let parent = parentDirectory(of: relPath)
                    trackFolder(parent, eventId: eventId)
                    continue
                }

                // Atomic save detection: Renamed+Created on a known, non-temp path
                // This is the common pattern for editor saves (temp → real file)
                // BUT: trash/move-away also sends Created+Renamed, so verify file exists!
                if created, isKnown, !isTempFile, !isDir {
                    let fullPath = fullPath(forRelativePath: relPath)
                    let stillExists = fm.fileExists(atPath: fullPath, isDirectory: nil)

                    if stillExists {
                        // Treat as file modification (atomic save completed)
                        let mdate = try? await getFileModificationDate(atRelativePath: relPath)
                        immediateModifications.append(.fileModified(relPath, mdate))
                        #if DEBUG
                            if isTestMode, Self.enableDebugLogging {
                                print("DEBUG: Detected atomic save for '\(relPath)'")
                            }
                        #endif
                        // Skip parent scan for atomic saves - we already know what changed
                        continue
                    } else {
                        // File gone - this is a move-away (trash, mv out), not an atomic save
                        #if DEBUG
                            if Self.enableDebugLogging {
                                print("🗑️ MOVE-AWAY detected for '\(relPath)' (Created+Renamed but file gone)")
                            }
                        #endif
                        immediateModifications.append(.fileRemoved(relPath))
                        visitedPaths.remove(relPath)
                        visitedItems.removeValue(forKey: relPath)
                        continue
                    }
                }

                // Update state immediately for rename chains, with anomaly detection
                if removed, isKnown {
                    #if DEBUG
                        if Self.enableDebugLogging {
                            print("🗑️ REMOVAL detected for KNOWN path: '\(relPath)' (isDir=\(isDir))")
                        }
                    #endif
                    // Anomaly check: verify the file is actually gone
                    // FSEvents can report removal for renames where file still exists
                    let fullPath = fullPath(forRelativePath: relPath)
                    let stillExists = fm.fileExists(atPath: fullPath, isDirectory: nil)

                    #if DEBUG
                        if Self.enableDebugLogging {
                            print("   → Disk check: stillExists=\(stillExists) at '\(fullPath)'")
                        }
                    #endif

                    if stillExists {
                        // Anomaly: "removed" but file still exists
                        // Don't remove from visitedPaths; treat as modification and verify via scan
                        #if DEBUG
                            if Self.enableDebugLogging {
                                print("   ⚠️ ANOMALY: File still exists, treating as modification")
                            }
                            if isTestMode, Self.enableDebugLogging {
                                print("DEBUG: Removal anomaly - '\(relPath)' still exists on disk")
                            }
                        #endif
                        if !isDir {
                            let mdate = try? await getFileModificationDate(atRelativePath: relPath)
                            immediateModifications.append(.fileModified(relPath, mdate))
                        }
                        // Schedule parent scan to verify state
                        let parent = parentDirectory(of: relPath)
                        if !parent.isEmpty {
                            trackFolder(parent, eventId: eventId)
                        }
                        continue
                    }

                    // Normal removal: generate delta and update state
                    #if DEBUG
                        if Self.enableDebugLogging {
                            print("   ✅ EMITTING: \(isDir ? "folderRemoved" : "fileRemoved")('\(relPath)')")
                        }
                    #endif
                    immediateModifications.append(isDir ? .folderRemoved(relPath) : .fileRemoved(relPath))

                    // If it's a directory being removed, also remove all its children
                    if isDir {
                        let childrenToRemove = visitedPaths.filter { $0.hasPrefix(relPath + "/") }
                        for child in childrenToRemove {
                            let childIsDir = visitedItems[child] ?? false
                            immediateModifications.append(childIsDir ? .folderRemoved(child) : .fileRemoved(child))
                            visitedPaths.remove(child)
                            visitedItems.removeValue(forKey: child)
                        }
                    }
                    visitedPaths.remove(relPath)
                    visitedItems.removeValue(forKey: relPath)

                    // For temp file removals, no need to scan parent
                    if isTempFile {
                        continue
                    }
                } else if created, !isKnown {
                    // Skip temp file creations from tracking
                    if isTempFile {
                        continue
                    }

                    // Anomaly check: verify the file actually exists
                    // FSEvents can report creation for renames where file was moved away
                    let fullPath = fullPath(forRelativePath: relPath)
                    let actuallyExists = fm.fileExists(atPath: fullPath, isDirectory: nil)

                    if !actuallyExists {
                        // Anomaly: "created" but file doesn't exist
                        // Don't add to visitedPaths; schedule parent scan to verify
                        #if DEBUG
                            if isTestMode, Self.enableDebugLogging {
                                print("DEBUG: Creation anomaly - '\(relPath)' doesn't exist on disk")
                            }
                        #endif
                        let parent = parentDirectory(of: relPath)
                        if !parent.isEmpty {
                            trackFolder(parent, eventId: eventId)
                        }
                        continue
                    }

                    // Normal creation: generate delta and update state
                    immediateModifications.append(isDir ? .folderAdded(relPath) : .fileAdded(relPath))
                    visitedPaths.insert(relPath)
                    visitedItems[relPath] = isDir
                }

                // For directory renames, scan the new directory to find its contents
                if isDir, created {
                    trackFolder(relPath, eventId: eventId)
                }

                // For non-temp rename anomalies (removed without paired creation),
                // schedule parent verification
                if removed, !isTempFile {
                    let parent = parentDirectory(of: relPath)
                    if !parent.isEmpty {
                        trackFolder(parent, eventId: eventId)
                    }
                }

                // Continue to skip the generic parent scan for renames
                // (we've already handled what needs to be scanned above)
                continue
            }
            // ─────────────────────────────────────────────────────────────────────────

            // Parent scan needed for:
            // - Directory events (contents may have changed)
            // - Unknown paths (need to discover them)
            // NOT needed for known file modifications (already handled above)
            let parent = parentDirectory(of: relPath)

            if parent.hasPrefix("/") {
                continue
            }

            let needsParentScan = isDir || !isKnown

            if needsParentScan {
                if enableHierarchicalIgnores {
                    if await !isIgnoredHierarchicalDir(parent) {
                        trackFolder(parent, eventId: eventId)
                    }
                } else if !isIgnoredPrefixCheck(relativePath: parent, isDirectory: true) {
                    trackFolder(parent, eventId: eventId)
                }
            }
        }

        var allDeltas: [FileSystemDelta] = []
        allDeltas.append(contentsOf: immediateModifications)

        // ── Event ID-based coalescing: filter to only folders needing scan ──
        // Update pendingScanTargets with this batch's event IDs
        for (folder, maxId) in folderMaxEventId {
            pendingScanTargets[folder] = max(pendingScanTargets[folder] ?? 0, maxId)
        }

        // Build eligible set: folders that need scanning
        // - nil lastScannedId means "never scanned" → always eligible
        // - Otherwise, only rescan if pendingId > lastScannedId
        let eligibleFolders = Set(foldersToScan.filter { folder in
            guard let pendingId = pendingScanTargets[folder] else {
                return false // No pending scan target (shouldn't happen, but be defensive)
            }
            guard let lastScannedId = lastScannedEventIdByFolder[folder] else {
                return true // Never scanned before → always scan at least once
            }
            return pendingId > lastScannedId // Only rescan if newer events arrived
        })

        // Use parallel scanning for better I/O performance
        if !eligibleFolders.isEmpty {
            do {
                #if DEBUG
                    if isTestMode {
                        // Track all folders being processed
                        for folder in eligibleFolders {
                            processedFolders.insert(folder)
                        }
                    }
                #endif

                // Ensure all folders have their ignore rules loaded before parallel scan
                if enableHierarchicalIgnores {
                    for folderRelPath in eligibleFolders {
                        _ = try await ensureRulesChain(for: folderRelPath)
                    }
                }

                let folderDeltas = try await scanFoldersInParallel(eligibleFolders)
                allDeltas.append(contentsOf: folderDeltas)

                // Update tracking for successfully scanned folders
                for folder in eligibleFolders {
                    if let pendingId = pendingScanTargets[folder] {
                        lastScannedEventIdByFolder[folder] = pendingId
                        pendingScanTargets.removeValue(forKey: folder)
                    }
                    // Record verification time for safety-net tracking
                    recordFolderVerified(folder)
                }
            } catch {
                print("Error during parallel folder scanning: \(error)")
                // Fallback to serial scanning if parallel fails
                for folderRelPath in eligibleFolders {
                    do {
                        let deltas = try await scanOneLevelAndDiff(folderRelPath)
                        allDeltas.append(contentsOf: deltas)
                        // Update tracking for successfully scanned folder
                        if let pendingId = pendingScanTargets[folderRelPath] {
                            lastScannedEventIdByFolder[folderRelPath] = pendingId
                            pendingScanTargets.removeValue(forKey: folderRelPath)
                        }
                        // Record verification time for safety-net tracking
                        recordFolderVerified(folderRelPath)
                    } catch {
                        print("Error scanning folder '\(folderRelPath)': \(error)")
                        // Leave in pendingScanTargets - will retry when a new FSEvent for this folder arrives
                    }
                }
            }
        }

        #if DEBUG
            if Self.enableDebugLogging {
                print("┌─────────────────────────────────────────────────────────────")
                print("│ 📤 PUBLISHING \(allDeltas.count) deltas:")
                for delta in allDeltas {
                    switch delta {
                    case let .fileAdded(path): print("│   ➕ fileAdded: '\(path)'")
                    case let .fileRemoved(path): print("│   ➖ fileRemoved: '\(path)'")
                    case let .folderAdded(path): print("│   📁➕ folderAdded: '\(path)'")
                    case let .folderRemoved(path): print("│   📁➖ folderRemoved: '\(path)'")
                    case let .fileModified(path, _): print("│   ✏️ fileModified: '\(path)'")
                    case let .folderModified(path, _): print("│   📁✏️ folderModified: '\(path)'")
                    }
                }
                if allDeltas.isEmpty {
                    print("│   (no deltas to publish)")
                }
                print("└─────────────────────────────────────────────────────────────")
            }
        #endif

        guard watcherBatchBelongsToCurrentIngressGeneration(batch) else {
            return testMode ? [] : nil
        }

        let publishableDeltas = coalescedPublishableDeltas(from: allDeltas)
        #if DEBUG
            lastPublishedDeltaCoalescingDiagnostics = PublishedDeltaCoalescingDiagnostics(
                rawDeltaCount: allDeltas.count,
                publishedDeltaCount: publishableDeltas.count
            )
        #endif
        // Flush the split-components cache; next scan will repopulate lazily.
        pathCompsCache.removeAll()

        // ------------------------------------------------------------------
        // Rebuild ignore-rule cache if any of the ignore files changed
        // ------------------------------------------------------------------
        if !changedIgnoreDirs.isEmpty {
            // Record the change durably for consumers (don't clear until consumed)
            ignoreRulesRevision &+= 1
            pendingIgnoreChangeDirs.formUnion(changedIgnoreDirs)
            let dirs = changedIgnoreDirs // capture before escaping
            #if DEBUG
                if isTestMode {
                    await rebuildPerFolderIgnoreCache(changedDirs: dirs)
                } else {
                    Task { await rebuildPerFolderIgnoreCache(changedDirs: dirs) }
                }
            #else
                Task { await rebuildPerFolderIgnoreCache(changedDirs: dirs) }
            #endif
        }

        let publicationSource: FileSystemDeltaPublicationSource = if batch.publicationSource == .overflowRootRescan {
            .overflowRootRescan
        } else if publishableDeltas.isEmpty {
            .watcherBarrierNoop
        } else {
            batch.publicationSource
        }
        if !publishableDeltas.isEmpty || batch.watcherAcceptedHighWatermark != nil {
            publishFileSystemDeltas(
                publishableDeltas,
                source: publicationSource,
                watcherAcceptedWatermark: batch.watcherAcceptedHighWatermark
            )
        }

        // Return the published deltas in test mode.
        return testMode ? publishableDeltas : nil
    }
}
