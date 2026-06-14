import Combine
import CoreFoundation
import CoreServices
import Dispatch
import Foundation

struct FSEventCallbackEntry {
    let path: String
    let flags: FSEventStreamEventFlags
    let id: FSEventStreamEventId
}

struct FSEventCallbackPayload {
    let entries: [FSEventCallbackEntry]

    var count: Int {
        entries.count
    }
}

extension FileSystemService {
    // MARK: - Public watchers API

    /// Returns ordered publications whenever changes or watcher progress are detected.
    func publisherForChanges() -> AnyPublisher<FileSystemDeltaPublication, Never> {
        changePublisher.eraseToAnyPublisher()
    }

    /// Request to stop watching for changes. This tears down the FSEvent stream.
    public func stopWatchingForChanges() {
        stopFSEventStream()
    }

    /// (Re)start the FSEvent stream if needed and drain the pre-crawl replay cut.
    public func startWatchingForChanges() async throws {
        try startFSEventStream()
        if let stream = fseventStreamRef {
            FSEventStreamFlushSync(stream)
        }
        let acceptedCut = captureAcceptedWatcherWatermark()
        _ = await flushPendingEventsNow(throughAcceptedWatcherWatermark: acceptedCut)
    }

    public func fileExistsOnDisk(relativePath: String) -> Bool {
        let absolutePath = fullPath(forRelativePath: relativePath)
        return fm.fileExists(atPath: absolutePath, isDirectory: nil)
    }

    public func regularFileExistsOnDisk(relativePath rawRelativePath: String) -> Bool {
        let lifecycleCorrelation = EditFlowPerf.currentLifecycleCorrelation
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.Search.contentFreshnessRootEntered,
            correlation: lifecycleCorrelation,
            EditFlowPerf.Dimensions(rootToken: diagnosticRootToken.uuidString)
        )
        let validationState = EditFlowPerf.begin(EditFlowPerf.Stage.Search.contentFreshnessValidationRootActorBody)
        var outcome = "missing"
        defer {
            EditFlowPerf.end(
                EditFlowPerf.Stage.Search.contentFreshnessValidationRootActorBody,
                validationState,
                EditFlowPerf.Dimensions(outcome: outcome, rootToken: diagnosticRootToken.uuidString)
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.Search.contentFreshnessRootReturned,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(outcome: outcome, rootToken: diagnosticRootToken.uuidString)
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

    public func catalogEligibleRegularFileExists(relativePath rawRelativePath: String) async -> Bool {
        await catalogRegularFileEligibility(relativePath: rawRelativePath).isEligible
    }

    func catalogFolderIsDiscoverable(relativePath rawRelativePath: String) async -> Bool {
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

    public func catalogRegularFileEligibility(relativePath rawRelativePath: String) async -> CatalogRegularFileEligibility {
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

    func registerExplicitlyManagedRegularFile(relativePath rawRelativePath: String) async -> CatalogRegularFileEligibility {
        let eligibility = await catalogRegularFileEligibility(relativePath: rawRelativePath)
        switch eligibility {
        case .eligible, .ineligible(.ignored):
            let relativePath = (rawRelativePath as NSString).standardizingPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            visitedPaths.insert(relativePath)
            visitedItems[relativePath] = false
            if case .ineligible(.ignored) = eligibility {
                explicitlyManagedIgnoredFilePaths.insert(relativePath)
                watcherEarlyFilter.addExplicitlyManagedIgnoredFile(relativePath)
            }
        case .ineligible:
            break
        }
        return eligibility
    }

    func pathContainsSymlinkComponent(relativePath: String) -> Bool {
        var current = rootURL
        for component in relativePath.split(separator: "/") {
            current.appendPathComponent(String(component))
            if ((try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false) == true {
                return true
            }
        }
        return false
    }

    nonisolated func captureAcceptedWatcherWatermark() -> FileSystemWatcherIngressMailbox.Watermark {
        watcherIngressMailbox.captureAcceptedWatermark()
    }

    public func flushPendingEventsNow() async {
        _ = await flushPendingEventsNow(throughAcceptedWatcherWatermark: captureAcceptedWatcherWatermark())
    }

    /// Flushes watcher work through at least the callback-accepted watermark cut.
    ///
    /// Later callbacks may already have joined an actor-visible batch or an overflow
    /// sentinel, so this is intentionally a lower-bound barrier rather than a strict
    /// exclusion boundary. It never returns before the captured cut is published.
    func flushPendingEventsNow(
        throughAcceptedWatcherWatermark target: FileSystemWatcherIngressMailbox.Watermark
    ) async -> UInt64 {
        guard !Task.isCancelled else { return lastServicePublicationSequence }
        #if DEBUG
            freshnessFlushCallCount += 1
        #endif
        drainAcceptedWatcherIngressMailboxPayloads(through: target)
        cancelScheduledCoalescingDelay()
        #if DEBUG
            if lastPublishedWatcherAcceptedWatermark >= target {
                freshnessNoopFlushCount += 1
            }
        #endif

        while lastPublishedWatcherAcceptedWatermark < target {
            guard !Task.isCancelled else { return lastServicePublicationSequence }
            if let watcherBatchProcessingTask {
                await watcherBatchProcessingTask.value
                guard !Task.isCancelled else { return lastServicePublicationSequence }
                drainAcceptedWatcherIngressMailboxPayloads(through: target)
                cancelScheduledCoalescingDelay()
                continue
            }

            guard !Task.isCancelled else { return lastServicePublicationSequence }
            guard startProcessingPendingWatcherBatchIfNeeded() else {
                if !dirtyRecoveryScanTargets.isEmpty {
                    scheduleDirtyRecoveryScanRetryIfNeeded()
                    if let recoveryScanRetryTask {
                        await recoveryScanRetryTask.value
                        continue
                    }
                }
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

        public func lastPublishedDeltaCoalescingDiagnosticsForTesting() -> PublishedDeltaCoalescingDiagnostics? {
            lastPublishedDeltaCoalescingDiagnostics
        }

        func freshnessWorkDiagnosticsSnapshot() -> FreshnessWorkDiagnosticsSnapshot {
            FreshnessWorkDiagnosticsSnapshot(
                flushCallCount: freshnessFlushCallCount,
                noopFlushCount: freshnessNoopFlushCount,
                debounceCancellationCount: freshnessDebounceCancellationCount,
                watcherBatchCount: freshnessWatcherBatchCount,
                watcherBatchEventCount: freshnessWatcherBatchEventCount,
                lastWatcherBatchSize: freshnessLastWatcherBatchSize,
                maxWatcherBatchSize: freshnessMaxWatcherBatchSize
            )
        }

        public func coalescedPublishableDeltasForTesting(_ deltas: [FileSystemDelta]) -> [FileSystemDelta] {
            coalescedPublishableDeltas(from: deltas)
        }
    #endif

    func coalescedPublishableDeltas(from deltas: [FileSystemDelta]) -> [FileSystemDelta] {
        FileSystemDeltaPreparation.coalesce(deltas, inRoot: canonicalRootPath)
    }

    // MARK: - FSEvent Setup

    func startFSEventStream() throws {
        guard fseventStreamRef == nil else { return }

        watcherIngressMailbox.startAccepting()
        selfPointer = Unmanaged.passRetained(self).toOpaque()

        var streamContext = FSEventStreamContext(
            version: 0,
            info: selfPointer,
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )

        #if DEBUG
            if watcherActivationFailurePointForTesting == .streamCreation {
                fseventStreamRef = nil
            } else {
                fseventStreamRef = FSEventStreamCreate(
                    kCFAllocatorDefault,
                    Self.fseventCallback,
                    &streamContext,
                    [path] as CFArray,
                    nextFSEventStreamStartEventID,
                    0,
                    flags
                )
            }
        #else
            fseventStreamRef = FSEventStreamCreate(
                kCFAllocatorDefault,
                Self.fseventCallback,
                &streamContext,
                [path] as CFArray,
                nextFSEventStreamStartEventID,
                0,
                flags
            )
        #endif

        guard let stream = fseventStreamRef else {
            // Release the retained self if creation failed to avoid leaks
            if let ptr = selfPointer {
                Unmanaged<FileSystemService>.fromOpaque(ptr).release()
                selfPointer = nil
            }
            resetWatcherIngressState()
            throw FileSystemWatcherActivationError.streamCreationFailed(path: path)
        }

        FSEventStreamSetDispatchQueue(stream, .main)
        #if DEBUG
            let didStart = watcherActivationFailurePointForTesting == .streamStart ? false : FSEventStreamStart(stream)
        #else
            let didStart = FSEventStreamStart(stream)
        #endif
        if !didStart {
            // Clean up to avoid leaks
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            fseventStreamRef = nil
            if let ptr = selfPointer {
                Unmanaged<FileSystemService>.fromOpaque(ptr).release()
                selfPointer = nil
            }
            resetWatcherIngressState()
            throw FileSystemWatcherActivationError.streamStartFailed(path: path)
        }
        fileSystemDebugLog("FSEventStream started for path: \(path) from event ID \(nextFSEventStreamStartEventID)")
    }

    func stopFSEventStream() {
        if let stream = fseventStreamRef {
            nextFSEventStreamStartEventID = max(
                nextFSEventStreamStartEventID,
                FSEventStreamGetLatestEventId(stream)
            )
            FSEventStreamStop(stream)
            FSEventStreamFlushSync(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            fseventStreamRef = nil

            if let ptr = selfPointer {
                Unmanaged<FileSystemService>.fromOpaque(ptr).release()
                selfPointer = nil
            }

            fileSystemDebugLog("FSEventStream stopped for path: \(path)")
        } else {
            fileSystemDebugLog("stream could not be stopped")
        }

        resetWatcherIngressState()
    }

    nonisolated static func deepCopySwiftString(_ source: String) -> String {
        String(decoding: Array(source.utf8), as: UTF8.self)
    }

    nonisolated static func deepCopyEventPath(_ source: CFString) -> String? {
        let length = CFStringGetLength(source)
        if length == 0 { return "" }

        let utf8Encoding = CFStringBuiltInEncodings.UTF8.rawValue
        if let directUTF8 = CFStringGetCStringPtr(source, utf8Encoding) {
            return String(cString: directUTF8)
        }
        let maxBufferSize = max(CFStringGetMaximumSizeForEncoding(length, utf8Encoding) + 1, 1)
        var utf8Buffer = [CChar](repeating: 0, count: maxBufferSize)
        let copiedUTF8 = utf8Buffer.withUnsafeMutableBufferPointer { buffer in
            CFStringGetCString(source, buffer.baseAddress, buffer.count, utf8Encoding)
        }
        if copiedUTF8 {
            return String(cString: utf8Buffer)
        }

        var utf16Buffer = [UniChar](repeating: 0, count: length)
        CFStringGetCharacters(
            source,
            CFRange(location: 0, length: length),
            &utf16Buffer
        )
        return String(utf16CodeUnits: utf16Buffer, count: utf16Buffer.count)
    }

    nonisolated static func buildOwnedFSEventPayload(
        numEvents: Int,
        eventPaths: UnsafeMutableRawPointer,
        eventFlags: UnsafePointer<FSEventStreamEventFlags>,
        eventIds: UnsafePointer<FSEventStreamEventId>
    ) -> FSEventCallbackPayload? {
        let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
        let safeCount = min(numEvents, CFArrayGetCount(cfArray))
        guard safeCount > 0 else { return nil }

        var entries: [FSEventCallbackEntry] = []
        entries.reserveCapacity(safeCount)

        for index in 0 ..< safeCount {
            guard let rawValue = CFArrayGetValueAtIndex(cfArray, index) else { continue }
            let cfObject = unsafeBitCast(rawValue, to: CFTypeRef.self)
            let copiedPath: String?
            if CFGetTypeID(cfObject) == CFStringGetTypeID() {
                let cfString = unsafeBitCast(rawValue, to: CFString.self)
                copiedPath = deepCopyEventPath(cfString)
            } else if let string = cfObject as? String {
                copiedPath = deepCopySwiftString(string)
            } else {
                #if DEBUG
                    if enableDebugLogging {
                        print("DEBUG: Dropping unexpected FSEvent path payload at index \(index): \(type(of: cfObject))")
                    }
                #endif
                copiedPath = nil
            }

            guard let copiedPath else { continue }
            entries.append(
                FSEventCallbackEntry(
                    path: copiedPath,
                    flags: eventFlags[index],
                    id: eventIds[index]
                )
            )
        }

        guard !entries.isEmpty else { return nil }
        return FSEventCallbackPayload(entries: entries)
    }

    /// The static callback that FSEvents uses to report changes. We hand off to Task to enter the actor context.
    static let fseventCallback: FSEventStreamCallback = {
        _, context, numEvents, eventPaths, eventFlags, eventIds in
        // Context must be valid
        guard let context else { return }
        let service = Unmanaged<FileSystemService>.fromOpaque(context).takeUnretainedValue()

        let count = Int(numEvents)
        guard count > 0 else { return }

        // Although these are non-optional in the API, guard against unexpected null pointers defensively
        if Int(bitPattern: eventPaths) == 0 { return }
        if Int(bitPattern: eventFlags) == 0 { return }
        if Int(bitPattern: eventIds) == 0 { return }

        guard let payload = buildOwnedFSEventPayload(
            numEvents: count,
            eventPaths: eventPaths,
            eventFlags: eventFlags,
            eventIds: eventIds
        ) else { return }

        #if DEBUG
            if payload.count != count {
                print("DEBUG: FSEvents vector length mismatch. numEvents=\(count), payloadCount=\(payload.count)")
            }

            // Log raw FSEvents as they arrive
            if enableDebugLogging {
                print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                print("🔔 RAW FSEVENTS CALLBACK: \(payload.count) events")
                for (index, entry) in payload.entries.enumerated() {
                    print("  [\(index)] path: \(entry.path)")
                    print("       flags: \(formatFSEventFlags(entry.flags))")
                    print("       eventId: \(entry.id)")
                }
                print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            }
        #endif

        let filterResult = service.watcherEarlyFilter.filter(payload)
        guard let retainedPayload = filterResult.payload else { return }

        let lifecycleCorrelation = EditFlowPerf.makeLifecycleCorrelationIfActive()
        let acceptedWatermark = service.watcherIngressMailbox.accept(
            retainedPayload,
            lifecycleCorrelation: lifecycleCorrelation
        ) { [weak service] in
            await service?.drainAcceptedWatcherIngressMailbox()
        }
        guard let acceptedWatermark else { return }
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.FileSystem.callbackAccepted,
            correlation: lifecycleCorrelation,
            EditFlowPerf.Dimensions(
                sourceItemCount: payload.count,
                contentItemCount: retainedPayload.count,
                changeCount: filterResult.filteredEntryCount,
                rootToken: service.diagnosticRootToken.uuidString,
                ingressSequence: acceptedWatermark.rawValue
            )
        )
    }

    // MARK: - Core event coalescing & handling

    func drainAcceptedWatcherIngressMailbox() async {
        drainAcceptedWatcherIngressMailboxPayloads()
    }

    func drainAcceptedWatcherIngressMailboxPayloads(
        through target: FileSystemWatcherIngressMailbox.Watermark? = nil
    ) {
        while let payload = watcherIngressMailbox.takeNextAcceptedPayload(through: target) {
            enqueueAcceptedWatcherPayload(payload)
        }
    }

    func enqueueAcceptedWatcherPayload(_ payload: FileSystemWatcherIngressMailbox.AcceptedPayload) {
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.FileSystem.serviceEnqueueEntered,
            correlation: payload.lifecycleCorrelation,
            EditFlowPerf.Dimensions(
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
            nextFSEventStreamStartEventID = max(nextFSEventStreamStartEventID, highestEventID)
            overflowChangedIgnoreDirs.formUnion(ignoreChangeDirs(in: changedIgnoreAbsolutePaths.map { ($0, 0, 0) }))
            collapsePendingEventsToRootRescan(
                upTo: highestEventID,
                acceptedHighWatermark: payload.acceptedHighWatermark
            )
        }
        scheduleCoalescingIfNeeded()
    }

    func enqueueFSEventEntries(
        _ entries: [FSEventCallbackEntry],
        acceptedHighWatermark: FileSystemWatcherIngressMailbox.Watermark? = nil
    ) {
        guard !entries.isEmpty else { return }
        let payloadMaxEventID = entries.map(\.id).max() ?? 0
        nextFSEventStreamStartEventID = max(nextFSEventStreamStartEventID, payloadMaxEventID)
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

    func scheduleCoalescingIfNeeded() {
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

    func scheduledCoalescingDelayDidFinish() {
        coalescingTask = nil
        if !startProcessingPendingWatcherBatchIfNeeded(), !pendingFSEvents.isEmpty {
            scheduleCoalescingIfNeeded()
        }
    }

    func cancelScheduledCoalescingDelay() {
        #if DEBUG
            if coalescingTask != nil {
                freshnessDebounceCancellationCount += 1
            }
        #endif
        coalescingTask?.cancel()
        coalescingTask = nil
    }

    @discardableResult
    func startProcessingPendingWatcherBatchIfNeeded() -> Bool {
        guard watcherBatchProcessingTask == nil else { return true }
        let canPublishParkedWatermark = pendingWatcherAcceptedHighWatermark != nil
            && dirtyRecoveryScanTargets.isEmpty
        guard !pendingFSEvents.isEmpty || !pendingQuietFolderScanTargets.isEmpty || canPublishParkedWatermark else {
            return false
        }
        let batch = takePendingFSEventsForProcessing()

        nextWatcherBatchProcessingToken &+= 1
        let token = nextWatcherBatchProcessingToken
        watcherBatchProcessingToken = token
        watcherBatchProcessingTask = Task { [weak self] in
            await self?.processWatcherBatch(batch, token: token)
        }
        return true
    }

    func processWatcherBatch(_ batch: PendingFSEventBatch, token: UInt64) async {
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

    func watcherBatchProcessingDidFinish(token: UInt64) {
        guard watcherBatchProcessingToken == token else { return }
        watcherBatchProcessingTask = nil
        watcherBatchProcessingToken = nil
        if !pendingFSEvents.isEmpty {
            scheduleCoalescingIfNeeded()
        } else if !pendingQuietFolderScanTargets.isEmpty {
            _ = startProcessingPendingWatcherBatchIfNeeded()
        } else if !dirtyRecoveryScanTargets.isEmpty {
            scheduleDirtyRecoveryScanRetryIfNeeded()
        }
    }

    func scheduleDirtyRecoveryScanRetryIfNeeded() {
        guard recoveryScanRetryTask == nil, !dirtyRecoveryScanTargets.isEmpty else { return }
        let highestAttempt = dirtyRecoveryScanTargets.compactMap { recoveryScanFailureCountByFolder[$0] }.max() ?? 1
        let exponent = min(max(0, highestAttempt - 1), 5)
        let multiplier = UInt64(1 << exponent)
        let delay = recoveryScanRetryBaseNanoseconds.multipliedReportingOverflow(by: multiplier)
        let delayNanoseconds = delay.overflow ? UInt64.max : delay.partialValue
        let expectedIngressGeneration = watcherIngressGeneration
        recoveryScanRetryTask = Task { [weak self] in
            guard let self else { return }
            await recoveryScanSleep(delayNanoseconds)
            guard !Task.isCancelled else { return }
            await recoveryScanRetryDelayDidFinish(expectedIngressGeneration: expectedIngressGeneration)
        }
    }

    func recoveryScanRetryDelayDidFinish(expectedIngressGeneration: UInt64) {
        recoveryScanRetryTask = nil
        guard expectedIngressGeneration == watcherIngressGeneration,
              !dirtyRecoveryScanTargets.isEmpty
        else { return }
        pendingQuietFolderScanTargets.formUnion(dirtyRecoveryScanTargets)
        pendingQuietFolderScanTargets.formIntersection(Set(pendingScanTargets.keys))
        _ = startProcessingPendingWatcherBatchIfNeeded()
    }

    func markRecoveryScanFailed(_ folder: String) -> Bool {
        let failureCount = (recoveryScanFailureCountByFolder[folder] ?? 0) + 1
        recoveryScanFailureCountByFolder[folder] = failureCount
        dirtyRecoveryScanTargets.insert(folder)
        return failureCount >= maxRecoveryScanAttempts
    }

    func clearRecoveryScanState(for folders: some Sequence<String>) {
        for folder in folders {
            dirtyRecoveryScanTargets.remove(folder)
            recoveryScanFailureCountByFolder.removeValue(forKey: folder)
        }
    }

    func collapsePendingEventsToRootRescan(
        upTo eventID: FSEventStreamEventId,
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

    func takePendingFSEventsForProcessing() -> PendingFSEventBatch {
        #if DEBUG
            let batchSize = pendingFSEvents.count
            freshnessWatcherBatchCount += 1
            freshnessWatcherBatchEventCount += batchSize
            freshnessLastWatcherBatchSize = batchSize
            freshnessMaxWatcherBatchSize = max(freshnessMaxWatcherBatchSize, batchSize)
        #endif
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

    func ignoreChangeDirs(
        in events: [(String, FSEventStreamEventFlags, FSEventStreamEventId)]
    ) -> Set<String> {
        var dirs = Set<String>()
        for (absolutePath, _, _) in events {
            guard case let .inside(relativePath) = mapToRelativeEventPath(absolutePath) else { continue }
            guard isIgnoreFile(relativePath) else { continue }
            dirs.insert(parentDirectory(of: relativePath))
        }
        return dirs
    }

    func resetWatcherIngressState() {
        watcherIngressMailbox.stopAcceptingAndDiscardPending()
        watcherIngressGeneration &+= 1
        cancelScheduledCoalescingDelay()
        watcherBatchProcessingTask?.cancel()
        pendingFSEvents.removeAll(keepingCapacity: false)
        pendingWatcherAcceptedHighWatermark = nil
        pendingWatcherPublicationSource = .watcher
        hasPendingOverflowRescan = false
        overflowChangedIgnoreDirs.removeAll(keepingCapacity: false)
        pendingScanTargets.removeAll(keepingCapacity: false)
        pendingQuietFolderScanTargets.removeAll(keepingCapacity: false)
        dirtyRecoveryScanTargets.removeAll(keepingCapacity: false)
        recoveryScanFailureCountByFolder.removeAll(keepingCapacity: false)
        recoveryScanRetryTask?.cancel()
        recoveryScanRetryTask = nil
        lastScannedEventIdByFolder.removeAll(keepingCapacity: false)
        lastVerifiedAtByFolder.removeAll(keepingCapacity: false)
        fileEventCountSinceLastScan.removeAll(keepingCapacity: false)
    }

    func watcherBatchBelongsToCurrentIngressGeneration(_ batch: PendingFSEventBatch) -> Bool {
        guard let generation = batch.watcherIngressGeneration else { return true }
        return generation == watcherIngressGeneration
    }

    // MARK: - FSEvents Flag Parsing

    #if DEBUG
        /// Format FSEventStreamEventFlags into a human-readable string for debugging
        static func formatFSEventFlags(_ flags: FSEventStreamEventFlags) -> String {
            let raw = UInt32(flags)
            var parts: [String] = []

            func check(_ flag: Int, _ name: String) {
                if (raw & UInt32(flag)) != 0 { parts.append(name) }
            }

            check(kFSEventStreamEventFlagItemCreated, "Created")
            check(kFSEventStreamEventFlagItemRemoved, "Removed")
            check(kFSEventStreamEventFlagItemRenamed, "Renamed")
            check(kFSEventStreamEventFlagItemModified, "Modified")
            check(kFSEventStreamEventFlagItemInodeMetaMod, "InodeMeta")
            check(kFSEventStreamEventFlagItemFinderInfoMod, "FinderInfo")
            check(kFSEventStreamEventFlagItemChangeOwner, "OwnerChange")
            check(kFSEventStreamEventFlagItemXattrMod, "Xattr")
            check(kFSEventStreamEventFlagItemIsFile, "IsFile")
            check(kFSEventStreamEventFlagItemIsDir, "IsDir")
            check(kFSEventStreamEventFlagItemIsSymlink, "IsSymlink")
            check(kFSEventStreamEventFlagMustScanSubDirs, "MustScanSubDirs")
            check(kFSEventStreamEventFlagUserDropped, "UserDropped")
            check(kFSEventStreamEventFlagKernelDropped, "KernelDropped")
            check(kFSEventStreamEventFlagRootChanged, "RootChanged")

            let flagStr = parts.isEmpty ? "None" : parts.joined(separator: "|")
            return "\(raw) [\(flagStr)]"
        }
    #endif

    /// Parsed representation of FSEvents flags for cleaner event handling
    struct ParsedEvent {
        let isDir: Bool
        let isFile: Bool

        let isCreated: Bool
        let isRemoved: Bool
        let isRenamed: Bool
        let isContentChange: Bool // data or xattrs changed
        let isMetadataChange: Bool // inode, finder info, owner

        // Reliability signals that require more aggressive handling
        let mustScanSubdirs: Bool // kFSEventStreamEventFlagMustScanSubDirs
        let userOrKernelDropped: Bool // events were dropped
        let rootChanged: Bool // mount/unmount or root moved

        /// True if this event requires us to scan directories for correctness
        var requiresAggressiveScan: Bool {
            mustScanSubdirs || userOrKernelDropped || rootChanged
        }
    }

    /// Parse FSEventStreamEventFlags into a structured representation
    static func parseEventFlags(
        _ flags: FSEventStreamEventFlags,
        isDirFallback: Bool
    ) -> ParsedEvent {
        let raw = UInt32(flags)

        /// FSEvents constants are Int on macOS, convert to UInt32 for bitwise comparison
        func has(_ flag: Int) -> Bool {
            (raw & UInt32(flag)) != 0
        }

        let isDirFlag = has(kFSEventStreamEventFlagItemIsDir)
        let isFileFlag = has(kFSEventStreamEventFlagItemIsFile)

        return ParsedEvent(
            isDir: isDirFlag || (!isFileFlag && isDirFallback),
            isFile: isFileFlag || (!isDirFlag && !isDirFallback),
            isCreated: has(kFSEventStreamEventFlagItemCreated),
            isRemoved: has(kFSEventStreamEventFlagItemRemoved),
            isRenamed: has(kFSEventStreamEventFlagItemRenamed),
            isContentChange: has(kFSEventStreamEventFlagItemModified) || has(kFSEventStreamEventFlagItemXattrMod),
            isMetadataChange: has(kFSEventStreamEventFlagItemInodeMetaMod) ||
                has(kFSEventStreamEventFlagItemFinderInfoMod) ||
                has(kFSEventStreamEventFlagItemChangeOwner),
            mustScanSubdirs: has(kFSEventStreamEventFlagMustScanSubDirs),
            userOrKernelDropped: has(kFSEventStreamEventFlagUserDropped) || has(kFSEventStreamEventFlagKernelDropped),
            rootChanged: has(kFSEventStreamEventFlagRootChanged)
        )
    }

    // MARK: - Temp File Detection for Atomic Saves

    /// Common temp file suffixes used by editors for atomic saves
    static let tempNameSuffixes: [String] = [
        "~", // vim backup
        ".tmp", ".temp",
        ".swp", ".swo", ".swx", // vim swap
        ".bak", ".backup", ".orig", ".old",
        "__jb_tmp__", "__jb_old__" // JetBrains
    ]

    /// Common temp file prefixes used by editors
    static let tempNamePrefixes: [String] = [
        ".#", // Emacs
        "._", // macOS resource fork
        "~$" // MS Office
    ]

    /// Check if a path looks like a temporary file used for atomic saves
    static func isTempSaveName(_ relPath: String) -> Bool {
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
    func currentTime() -> TimeInterval {
        CFAbsoluteTimeGetCurrent()
    }

    /// Record that a folder was just verified via directory scan
    func recordFolderVerified(_ folder: String) {
        lastVerifiedAtByFolder[folder] = currentTime()
        fileEventCountSinceLastScan[folder] = 0
    }

    /// Check if a folder should receive a safety-net scan based on event count and time
    /// Returns true if we should schedule a scan
    func shouldScheduleSafetyNetScan(for parent: String) -> Bool {
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

    func handleBatchedEvents(
        _ batch: PendingFSEventBatch,
        testMode: Bool = false
    ) async -> [FileSystemDelta]? {
        guard watcherBatchBelongsToCurrentIngressGeneration(batch) else {
            return testMode ? [] : nil
        }
        let events = batch.events
        guard !events.isEmpty || !pendingQuietFolderScanTargets.isEmpty else {
            if let watermark = batch.watcherAcceptedHighWatermark {
                if dirtyRecoveryScanTargets.isEmpty {
                    publishFileSystemDeltas([], source: .watcherBarrierNoop, watcherAcceptedWatermark: watermark)
                } else {
                    pendingWatcherAcceptedHighWatermark = max(
                        pendingWatcherAcceptedHighWatermark ?? .zero,
                        watermark
                    )
                }
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
        var folderMaxEventId: [String: FSEventStreamEventId] = [:] // Track max event ID per folder
        var immediateModifications: [FileSystemDelta] = []
        var changedIgnoreDirs = overflowChangedIgnoreDirs
        overflowChangedIgnoreDirs.removeAll(keepingCapacity: false)

        /// Helper to track folder with its event ID
        func trackFolder(_ folder: String, eventId: FSEventStreamEventId) {
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
                    let isRename = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)) != 0
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
                    print("  ItemModified: \(flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified))")
                    print("  ItemCreated: \(flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated))")
                    print("  ItemRemoved: \(flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved))")
                    print("  ItemRenamed: \(flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed))")
                    print("  ItemInodeMetaMod: \(flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemInodeMetaMod))")
                    print("  ItemFinderInfoMod: \(flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemFinderInfoMod))")
                    print("  ItemChangeOwner: \(flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemChangeOwner))")
                    print("  ItemXattrMod: \(flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemXattrMod))")
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
                    // If it's a tracked folder, also scan it for changes.
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
        var requiresFullResync = false
        allDeltas.append(contentsOf: immediateModifications)

        // ── Event ID-based coalescing: filter to only folders needing scan ──
        // Update pendingScanTargets with this batch's event IDs
        for (folder, maxId) in folderMaxEventId {
            pendingScanTargets[folder] = max(pendingScanTargets[folder] ?? 0, maxId)
        }

        // Build eligible set: folders that need scanning
        // - nil lastScannedId means "never scanned" → always eligible
        // - Otherwise, only rescan if pendingId > lastScannedId
        let scanCandidates = foldersToScan.union(pendingQuietFolderScanTargets)
        let eligibleFolderSet = Set(scanCandidates.filter { folder in
            guard let pendingId = pendingScanTargets[folder] else {
                return false // No pending scan target (shouldn't happen, but be defensive)
            }
            guard let lastScannedId = lastScannedEventIdByFolder[folder] else {
                return true // Never scanned before → always scan at least once
            }
            return pendingId > lastScannedId // Only rescan if newer events arrived
        })
        // Carry-over work always precedes newly arrived work. Once a carried folder is
        // scanned it leaves this set, so capped batches advance through the backlog.
        let carriedFolders = pendingQuietFolderScanTargets.intersection(eligibleFolderSet).sorted()
        let newlyEligibleFolders = eligibleFolderSet.subtracting(pendingQuietFolderScanTargets).sorted()
        let eligibleFolders = carriedFolders + newlyEligibleFolders

        // Use parallel scanning for better I/O performance
        if !eligibleFolders.isEmpty {
            do {
                // Ensure all folders have their ignore rules loaded before parallel scan
                if enableHierarchicalIgnores {
                    for folderRelPath in eligibleFolders {
                        _ = try await ensureRulesChain(for: folderRelPath)
                    }
                }

                let scanResult = try await scanFoldersInParallel(eligibleFolders)
                allDeltas.append(contentsOf: scanResult.deltas)

                #if DEBUG
                    if isTestMode {
                        processedFolders.formUnion(scanResult.scannedFolders)
                    }
                #endif

                // Update tracking only for folders actually scanned after applying the cap.
                for folder in scanResult.scannedFolders {
                    if let pendingId = pendingScanTargets[folder] {
                        lastScannedEventIdByFolder[folder] = pendingId
                        pendingScanTargets.removeValue(forKey: folder)
                    }
                    // Record verification time for safety-net tracking
                    recordFolderVerified(folder)
                }
                pendingQuietFolderScanTargets.subtract(scanResult.scannedFolders)
                clearRecoveryScanState(for: scanResult.scannedFolders)
                if watcherBatchBelongsToCurrentIngressGeneration(batch) {
                    pendingQuietFolderScanTargets.formUnion(
                        eligibleFolderSet.subtracting(scanResult.scannedFolders)
                    )
                    pendingQuietFolderScanTargets.formIntersection(Set(pendingScanTargets.keys))
                }
            } catch {
                print("Error during parallel folder scanning: \(error)")
                // The serial fallback gets one immediate attempt. Targets that fail
                // both paths remain explicitly dirty and retain the accepted watermark.
                pendingQuietFolderScanTargets.subtract(Set(eligibleFolders))
                var targetsRequiringFullResync = Set<String>()
                for folderRelPath in eligibleFolders {
                    do {
                        let deltas = try await scanOneLevelAndDiff(folderRelPath)
                        allDeltas.append(contentsOf: deltas)
                        // Update tracking for successfully scanned folder
                        if let pendingId = pendingScanTargets[folderRelPath] {
                            lastScannedEventIdByFolder[folderRelPath] = pendingId
                            pendingScanTargets.removeValue(forKey: folderRelPath)
                        }
                        clearRecoveryScanState(for: CollectionOfOne(folderRelPath))
                        // Record verification time for safety-net tracking
                        recordFolderVerified(folderRelPath)
                    } catch {
                        print("Error scanning folder '\(folderRelPath)': \(error)")
                        if markRecoveryScanFailed(folderRelPath) {
                            targetsRequiringFullResync.insert(folderRelPath)
                        }
                    }
                }

                if !targetsRequiringFullResync.isEmpty {
                    do {
                        try await allDeltas.append(contentsOf: reconcileEntireTreeAfterRecoveryFailure())
                        pendingScanTargets.removeAll(keepingCapacity: false)
                        pendingQuietFolderScanTargets.removeAll(keepingCapacity: false)
                        dirtyRecoveryScanTargets.removeAll(keepingCapacity: false)
                        recoveryScanFailureCountByFolder.removeAll(keepingCapacity: false)
                        requiresFullResync = true
                    } catch {
                        print("Error during recovery full resync for '\(path)': \(error)")
                        dirtyRecoveryScanTargets.formUnion(targetsRequiringFullResync)
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

        let publishSignpost = FileSystemPublishPerf.begin("coalesceAndPublishFileSystemDeltas")
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

        let hasPendingRecoveryScans = !pendingQuietFolderScanTargets.isEmpty || !dirtyRecoveryScanTargets.isEmpty
        let publishableWatcherWatermark: FileSystemWatcherIngressMailbox.Watermark?
        if hasPendingRecoveryScans, let acceptedHighWatermark = batch.watcherAcceptedHighWatermark {
            pendingWatcherAcceptedHighWatermark = max(
                pendingWatcherAcceptedHighWatermark ?? .zero,
                acceptedHighWatermark
            )
            if batch.publicationSource == .overflowRootRescan {
                pendingWatcherPublicationSource = .overflowRootRescan
            }
            publishableWatcherWatermark = nil
        } else {
            publishableWatcherWatermark = batch.watcherAcceptedHighWatermark
        }

        let publicationSource: FileSystemDeltaPublicationSource = if requiresFullResync {
            .recoveryFullResync
        } else if batch.publicationSource == .overflowRootRescan {
            .overflowRootRescan
        } else if publishableDeltas.isEmpty {
            .watcherBarrierNoop
        } else {
            batch.publicationSource
        }
        if !publishableDeltas.isEmpty || publishableWatcherWatermark != nil || requiresFullResync {
            publishFileSystemDeltas(
                publishableDeltas,
                source: publicationSource,
                watcherAcceptedWatermark: publishableWatcherWatermark,
                requiresFullResync: requiresFullResync
            )
        }
        FileSystemPublishPerf.end("coalesceAndPublishFileSystemDeltas", publishSignpost)

        // Return the published deltas in test mode.
        return testMode ? publishableDeltas : nil
    }
}
