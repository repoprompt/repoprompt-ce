import CoreServices
import Darwin
import Foundation

struct WorkspaceRootCreationFSEvent: Equatable {
    let path: String
    let flags: FSEventStreamEventFlags
    let eventID: FSEventStreamEventId
}

enum WorkspaceRootCreationWitnessFlushPhase: Hashable {
    case activation
    case ending
}

enum WorkspaceRootCreationWitnessBarrierPhase: Hashable {
    case activation
    case endCut
    case ending
}

protocol WorkspaceRootCreationWitnessEventStream: AnyObject, Sendable {
    func start() -> Bool
    func flushSync(phase: WorkspaceRootCreationWitnessFlushPhase) -> Bool
    func synchronizeCallbacks(
        phase: WorkspaceRootCreationWitnessBarrierPhase,
        _ body: @escaping @Sendable () -> Void
    ) -> Bool
    func stop()
    func invalidate()
    func release()
}

protocol WorkspaceRootCreationWitnessFSEventsBackend: Sendable {
    func currentEventID() -> FSEventStreamEventId
    func makeStream(
        watchRootURL: URL,
        sinceWhen: FSEventStreamEventId,
        onEvents: @escaping @Sendable ([WorkspaceRootCreationFSEvent]) -> Void
    ) -> (any WorkspaceRootCreationWitnessEventStream)?
}

private struct ProductionWorkspaceRootCreationWitnessFSEventsBackend:
    WorkspaceRootCreationWitnessFSEventsBackend
{
    func currentEventID() -> FSEventStreamEventId {
        FSEventsGetCurrentEventId()
    }

    func makeStream(
        watchRootURL: URL,
        sinceWhen: FSEventStreamEventId,
        onEvents: @escaping @Sendable ([WorkspaceRootCreationFSEvent]) -> Void
    ) -> (any WorkspaceRootCreationWitnessEventStream)? {
        ProductionWorkspaceRootCreationWitnessEventStream(
            watchRootURL: watchRootURL,
            sinceWhen: sinceWhen,
            onEvents: onEvents
        )
    }
}

private final class ProductionWorkspaceRootCreationWitnessEventStream: @unchecked Sendable,
    WorkspaceRootCreationWitnessEventStream
{
    private final class CallbackBox: @unchecked Sendable {
        let onEvents: @Sendable ([WorkspaceRootCreationFSEvent]) -> Void

        init(onEvents: @escaping @Sendable ([WorkspaceRootCreationFSEvent]) -> Void) {
            self.onEvents = onEvents
        }
    }

    private let lock = NSLock()
    private let queue: DispatchQueue
    private let callbackBox: CallbackBox
    private var stream: FSEventStreamRef?

    init?(
        watchRootURL: URL,
        sinceWhen: FSEventStreamEventId,
        onEvents: @escaping @Sendable ([WorkspaceRootCreationFSEvent]) -> Void
    ) {
        queue = DispatchQueue(
            label: "com.repoprompt.worktree-creation-witness.\(UUID().uuidString)",
            qos: .utility
        )
        callbackBox = CallbackBox(onEvents: onEvents)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackBox).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info,
                  let payload = FileSystemService.buildOwnedFSEventPayload(
                      numEvents: Int(count),
                      eventPaths: paths,
                      eventFlags: flags,
                      eventIds: ids
                  )
            else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
            box.onEvents(payload.entries.map {
                WorkspaceRootCreationFSEvent(path: $0.path, flags: $0.flags, eventID: $0.id)
            })
        }
        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [watchRootURL.path] as CFArray,
            sinceWhen,
            0.01,
            createFlags
        ) else {
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
    }

    func start() -> Bool {
        lock.withLock {
            guard let stream else { return false }
            return FSEventStreamStart(stream)
        }
    }

    func flushSync(phase _: WorkspaceRootCreationWitnessFlushPhase) -> Bool {
        lock.withLock {
            guard let stream else { return false }
            FSEventStreamFlushSync(stream)
            return true
        }
    }

    func synchronizeCallbacks(
        phase _: WorkspaceRootCreationWitnessBarrierPhase,
        _ body: @escaping @Sendable () -> Void
    ) -> Bool {
        queue.sync(execute: body)
        return true
    }

    func stop() {
        lock.withLock {
            guard let stream else { return }
            FSEventStreamStop(stream)
        }
    }

    func invalidate() {
        lock.withLock {
            guard let stream else { return }
            FSEventStreamInvalidate(stream)
        }
    }

    func release() {
        lock.withLock {
            guard let stream else { return }
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    deinit {
        lock.withLock {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }
}

final class WorkspaceRootCreationReceiptCoordinator: @unchecked Sendable {
    final class Session: @unchecked Sendable {
        fileprivate let recorder: Recorder
        fileprivate let backend: any WorkspaceRootCreationWitnessFSEventsBackend
        fileprivate let stream: (any WorkspaceRootCreationWitnessEventStream)?
        fileprivate let startedAtUptimeNanoseconds: UInt64
        fileprivate let startEventID: FSEventStreamEventId
        fileprivate let stableWatchRootURL: URL?
        fileprivate let stableWatchRootIdentity: StableWatchRootIdentity?
        fileprivate let stableWatchRootAvailableBeforeMutation: Bool
        fileprivate let destinationWasAbsentBeforeMutation: Bool
        fileprivate let destinationWasStrictDescendant: Bool
        fileprivate let streamCreationSucceeded: Bool
        fileprivate let streamDidStart: Bool
        fileprivate let activationFlushCompleted: Bool
        fileprivate let activationCallbackBarrierCompleted: Bool
        fileprivate let startAcceptedCallbackWatermark: UInt64

        private let finishCondition = NSCondition()
        private var finishInProgress = false
        private var finishedCoverage: GitWorktreeCreationWitnessCoverage?

        fileprivate init(
            recorder: Recorder,
            backend: any WorkspaceRootCreationWitnessFSEventsBackend,
            stream: (any WorkspaceRootCreationWitnessEventStream)?,
            startedAtUptimeNanoseconds: UInt64,
            startEventID: FSEventStreamEventId,
            stableWatchRootURL: URL?,
            stableWatchRootIdentity: StableWatchRootIdentity?,
            stableWatchRootAvailableBeforeMutation: Bool,
            destinationWasAbsentBeforeMutation: Bool,
            destinationWasStrictDescendant: Bool,
            streamCreationSucceeded: Bool,
            streamDidStart: Bool,
            activationFlushCompleted: Bool,
            activationCallbackBarrierCompleted: Bool,
            startAcceptedCallbackWatermark: UInt64
        ) {
            self.recorder = recorder
            self.backend = backend
            self.stream = stream
            self.startedAtUptimeNanoseconds = startedAtUptimeNanoseconds
            self.startEventID = startEventID
            self.stableWatchRootURL = stableWatchRootURL
            self.stableWatchRootIdentity = stableWatchRootIdentity
            self.stableWatchRootAvailableBeforeMutation = stableWatchRootAvailableBeforeMutation
            self.destinationWasAbsentBeforeMutation = destinationWasAbsentBeforeMutation
            self.destinationWasStrictDescendant = destinationWasStrictDescendant
            self.streamCreationSucceeded = streamCreationSucceeded
            self.streamDidStart = streamDidStart
            self.activationFlushCompleted = activationFlushCompleted
            self.activationCallbackBarrierCompleted = activationCallbackBarrierCompleted
            self.startAcceptedCallbackWatermark = startAcceptedCallbackWatermark
        }

        var streamStartedBeforeMutation: Bool {
            streamDidStart && activationFlushCompleted && activationCallbackBarrierCompleted
        }

        fileprivate func performFinishOnce(
            _ body: () -> GitWorktreeCreationWitnessCoverage
        ) -> GitWorktreeCreationWitnessCoverage {
            finishCondition.lock()
            while finishInProgress, finishedCoverage == nil {
                finishCondition.wait()
            }
            if let finishedCoverage {
                finishCondition.unlock()
                return finishedCoverage
            }
            finishInProgress = true
            finishCondition.unlock()

            let coverage = body()

            finishCondition.lock()
            finishedCoverage = coverage
            finishInProgress = false
            finishCondition.broadcast()
            finishCondition.unlock()
            return coverage
        }
    }

    final class Recorder: @unchecked Sendable {
        struct Snapshot {
            let acceptedCallbackWatermark: UInt64
            let acceptedCallbackCount: Int
            let acceptedEventCount: Int
            let acceptedDestinationEventCount: Int
            let acceptedNonDestinationEventCount: Int
            let mustScanSubDirs: Bool
            let rootChanged: Bool
            let userDropped: Bool
            let kernelDropped: Bool
            let eventIDsWrapped: Bool
            let eventIDRegressed: Bool
        }

        private let lock = NSLock()
        private let standardizedDestinationPath: String
        private let standardizedWatchRootPath: String
        private let startEventID: UInt64
        private var semanticEndEventID: UInt64?
        private var latestMaterialEventID: UInt64
        private var acceptedCallbackWatermark: UInt64 = 0
        private var acceptedCallbackCount = 0
        private var acceptedEventCount = 0
        private var acceptedDestinationEventCount = 0
        private var acceptedNonDestinationEventCount = 0
        private var mustScanSubDirs = false
        private var rootChanged = false
        private var userDropped = false
        private var kernelDropped = false
        private var eventIDsWrapped = false
        private var eventIDRegressed = false

        init(destinationPath: String, watchRootPath: String, startEventID: UInt64) {
            standardizedDestinationPath = Self.canonicalPath(destinationPath)
            standardizedWatchRootPath = Self.canonicalPath(watchRootPath)
            self.startEventID = startEventID
            latestMaterialEventID = startEventID
        }

        func accept(_ events: [WorkspaceRootCreationFSEvent]) {
            lock.lock()
            defer { lock.unlock() }
            acceptedCallbackWatermark = Self.incremented(acceptedCallbackWatermark)
            acceptedCallbackCount = Self.incremented(acceptedCallbackCount)
            acceptedEventCount = Self.added(acceptedEventCount, events.count)

            for event in events {
                let flags = event.flags
                if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped) != 0 {
                    userDropped = true
                }
                if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped) != 0 {
                    kernelDropped = true
                }
                if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped) != 0 {
                    eventIDsWrapped = true
                }
                if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                    rootChanged = true
                }

                let path = Self.canonicalPath(event.path)
                if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0,
                   !isProvenDisjointSibling(path)
                {
                    mustScanSubDirs = true
                }

                let eventID = event.eventID
                let isWithinEndingCut = semanticEndEventID.map { eventID <= $0 } ?? true
                guard isWithinEndingCut else {
                    continue
                }
                if eventID == 0 || eventID == UInt64.max || eventID < latestMaterialEventID {
                    eventIDRegressed = true
                } else {
                    latestMaterialEventID = eventID
                }
                guard eventID > startEventID, eventID != UInt64.max else {
                    continue
                }
                if isPath(path, equalToOrInside: standardizedDestinationPath) {
                    acceptedDestinationEventCount = Self.incremented(acceptedDestinationEventCount)
                } else if isPath(path, equalToOrInside: standardizedWatchRootPath) {
                    acceptedNonDestinationEventCount = Self.incremented(acceptedNonDestinationEventCount)
                }
            }
        }

        func closeSemanticInterval(at endEventID: UInt64) {
            lock.withLock {
                semanticEndEventID = endEventID
            }
        }

        func currentAcceptedCallbackWatermark() -> UInt64 {
            lock.withLock { acceptedCallbackWatermark }
        }

        func snapshot() -> Snapshot {
            lock.withLock {
                Snapshot(
                    acceptedCallbackWatermark: acceptedCallbackWatermark,
                    acceptedCallbackCount: acceptedCallbackCount,
                    acceptedEventCount: acceptedEventCount,
                    acceptedDestinationEventCount: acceptedDestinationEventCount,
                    acceptedNonDestinationEventCount: acceptedNonDestinationEventCount,
                    mustScanSubDirs: mustScanSubDirs,
                    rootChanged: rootChanged,
                    userDropped: userDropped,
                    kernelDropped: kernelDropped,
                    eventIDsWrapped: eventIDsWrapped,
                    eventIDRegressed: eventIDRegressed
                )
            }
        }

        private func isProvenDisjointSibling(_ path: String) -> Bool {
            guard isPath(path, equalToOrInside: standardizedWatchRootPath),
                  path != standardizedWatchRootPath
            else {
                return false
            }
            let touchesDestination = isPath(path, equalToOrInside: standardizedDestinationPath)
                || isPath(standardizedDestinationPath, equalToOrInside: path)
            return !touchesDestination
        }

        private func isPath(_ path: String, equalToOrInside root: String) -> Bool {
            path == root || path.hasPrefix(root + "/")
        }

        private static func canonicalPath(_ rawPath: String) -> String {
            URL(fileURLWithPath: rawPath)
                .resolvingSymlinksInPath()
                .standardizedFileURL.path
        }

        private static func incremented(_ value: UInt64) -> UInt64 {
            value == UInt64.max ? value : value + 1
        }

        private static func incremented(_ value: Int) -> Int {
            value == Int.max ? value : value + 1
        }

        private static func added(_ value: Int, _ delta: Int) -> Int {
            guard delta > 0, value < Int.max else { return value }
            return delta > Int.max - value ? Int.max : value + delta
        }
    }

    fileprivate struct StableWatchRootIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private final class CutCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue: UInt64 = 0

        var value: UInt64 {
            lock.withLock { storedValue }
        }

        func store(_ value: UInt64) {
            lock.withLock {
                storedValue = value
            }
        }
    }

    private let backend: any WorkspaceRootCreationWitnessFSEventsBackend

    init(
        backend: any WorkspaceRootCreationWitnessFSEventsBackend =
            ProductionWorkspaceRootCreationWitnessFSEventsBackend()
    ) {
        self.backend = backend
    }

    func start(destinationURL: URL, stableWatchRootURL: URL) -> Session {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let canonicalWatchRoot = Self.canonicalURL(stableWatchRootURL)
        let canonicalDestination = Self.canonicalURL(destinationURL)
        let destinationWasStrictDescendant = Self.isStrictDescendant(
            canonicalDestination.path,
            of: canonicalWatchRoot.path
        )
        let destinationWasAbsent = !Self.pathExists(canonicalDestination.path)
        let watchRootIdentity = Self.stableDirectoryIdentity(at: canonicalWatchRoot)
        let existingDestinationAncestor = Self.nearestExistingAncestor(of: canonicalDestination)
        let watchRootAvailable = watchRootIdentity != nil
            && Self.isLocalVolume(canonicalWatchRoot)
            && existingDestinationAncestor.map(Self.isLocalVolume) == true

        guard watchRootAvailable,
              destinationWasStrictDescendant,
              destinationWasAbsent,
              let watchRootIdentity
        else {
            return Session(
                recorder: Recorder(
                    destinationPath: canonicalDestination.path,
                    watchRootPath: canonicalWatchRoot.path,
                    startEventID: 0
                ),
                backend: backend,
                stream: nil,
                startedAtUptimeNanoseconds: startedAt,
                startEventID: 0,
                stableWatchRootURL: canonicalWatchRoot,
                stableWatchRootIdentity: watchRootIdentity,
                stableWatchRootAvailableBeforeMutation: watchRootAvailable,
                destinationWasAbsentBeforeMutation: destinationWasAbsent,
                destinationWasStrictDescendant: destinationWasStrictDescendant,
                streamCreationSucceeded: false,
                streamDidStart: false,
                activationFlushCompleted: false,
                activationCallbackBarrierCompleted: false,
                startAcceptedCallbackWatermark: 0
            )
        }

        let startCut = backend.currentEventID()
        let recorder = Recorder(
            destinationPath: canonicalDestination.path,
            watchRootPath: canonicalWatchRoot.path,
            startEventID: startCut
        )
        guard Self.isValidCut(startCut) else {
            return Session(
                recorder: recorder,
                backend: backend,
                stream: nil,
                startedAtUptimeNanoseconds: startedAt,
                startEventID: startCut,
                stableWatchRootURL: canonicalWatchRoot,
                stableWatchRootIdentity: watchRootIdentity,
                stableWatchRootAvailableBeforeMutation: true,
                destinationWasAbsentBeforeMutation: true,
                destinationWasStrictDescendant: true,
                streamCreationSucceeded: false,
                streamDidStart: false,
                activationFlushCompleted: false,
                activationCallbackBarrierCompleted: false,
                startAcceptedCallbackWatermark: 0
            )
        }

        let stream = backend.makeStream(
            watchRootURL: canonicalWatchRoot,
            sinceWhen: startCut,
            onEvents: { events in
                recorder.accept(events)
            }
        )
        let streamDidStart = stream?.start() ?? false
        let activationFlushCompleted = streamDidStart
            && (stream?.flushSync(phase: .activation) ?? false)
        let activationBarrierCompleted = activationFlushCompleted
            && (stream?.synchronizeCallbacks(phase: .activation) {} ?? false)
        let startAcceptedWatermark = activationBarrierCompleted
            ? recorder.currentAcceptedCallbackWatermark()
            : 0
        let destinationWasAbsentBeforeMutation = !Self.pathExists(canonicalDestination.path)

        return Session(
            recorder: recorder,
            backend: backend,
            stream: stream,
            startedAtUptimeNanoseconds: startedAt,
            startEventID: startCut,
            stableWatchRootURL: canonicalWatchRoot,
            stableWatchRootIdentity: watchRootIdentity,
            stableWatchRootAvailableBeforeMutation: true,
            destinationWasAbsentBeforeMutation: destinationWasAbsentBeforeMutation,
            destinationWasStrictDescendant: true,
            streamCreationSucceeded: stream != nil,
            streamDidStart: streamDidStart,
            activationFlushCompleted: activationFlushCompleted,
            activationCallbackBarrierCompleted: activationBarrierCompleted,
            startAcceptedCallbackWatermark: startAcceptedWatermark
        )
    }

    func finish(_ session: Session) -> GitWorktreeCreationWitnessCoverage {
        session.performFinishOnce {
            finishUncached(session)
        }
    }

    private func finishUncached(_ session: Session) -> GitWorktreeCreationWitnessCoverage {
        let stableRootMatchedBeforeEnding = Self.stableRootMatches(session)
        var endEventID: UInt64 = 0
        var endingFlushCompleted = false
        var endingBarrierCompleted = false

        if let stream = session.stream, session.streamDidStart {
            let cutCapture = CutCapture()
            let endCutBarrierCompleted = stream.synchronizeCallbacks(phase: .endCut) {
                let cut = session.backend.currentEventID()
                cutCapture.store(cut)
                session.recorder.closeSemanticInterval(at: cut)
            }
            if endCutBarrierCompleted {
                endEventID = cutCapture.value
                endingFlushCompleted = stream.flushSync(phase: .ending)
                endingBarrierCompleted = endingFlushCompleted
                    && stream.synchronizeCallbacks(phase: .ending) {}
            }
            stream.stop()
        }
        session.stream?.invalidate()
        session.stream?.release()

        let endedAt = DispatchTime.now().uptimeNanoseconds
        let snapshot = session.recorder.snapshot()
        let stableRootUnchanged = stableRootMatchedBeforeEnding && Self.stableRootMatches(session)
        let lifetimeExceeded = endedAt < session.startedAtUptimeNanoseconds
            || endedAt - session.startedAtUptimeNanoseconds > UInt64(60 * NSEC_PER_SEC)
        let validStartCut = Self.isValidCut(session.startEventID)
        let validEndCut = Self.isValidCut(endEventID)
        let cutRegressed = validStartCut && validEndCut && endEventID < session.startEventID
        let streamStartedBeforeMutation = session.streamStartedBeforeMutation
        let streamEndedAfterInitialization = streamStartedBeforeMutation
            && validEndCut
            && endingFlushCompleted
            && endingBarrierCompleted
        let hadDrop = snapshot.userDropped || snapshot.kernelDropped
        let hadGap = !session.stableWatchRootAvailableBeforeMutation
            || !session.destinationWasAbsentBeforeMutation
            || !session.destinationWasStrictDescendant
            || !stableRootUnchanged
            || !session.streamCreationSucceeded
            || !streamStartedBeforeMutation
            || !validStartCut
            || !validEndCut
            || cutRegressed
            || !streamEndedAfterInitialization
            || snapshot.mustScanSubDirs
            || snapshot.rootChanged
            || snapshot.eventIDsWrapped
            || snapshot.eventIDRegressed
            || lifetimeExceeded

        return GitWorktreeCreationWitnessCoverage(
            startedAtUptimeNanoseconds: session.startedAtUptimeNanoseconds,
            endedAtUptimeNanoseconds: endedAt,
            startEventID: session.startEventID,
            endEventID: endEventID,
            stableWatchRootAvailableBeforeMutation: session.stableWatchRootAvailableBeforeMutation,
            destinationWasAbsentBeforeMutation: session.destinationWasAbsentBeforeMutation,
            destinationWasStrictDescendant: session.destinationWasStrictDescendant,
            stableWatchRootUnchangedAfterInitialization: stableRootUnchanged,
            streamCreationSucceeded: session.streamCreationSucceeded,
            streamStartedBeforeMutation: streamStartedBeforeMutation,
            activationFlushCompleted: session.activationFlushCompleted,
            activationCallbackBarrierCompleted: session.activationCallbackBarrierCompleted,
            streamEndedAfterInitialization: streamEndedAfterInitialization,
            endingFlushCompleted: endingFlushCompleted,
            endingCallbackBarrierCompleted: endingBarrierCompleted,
            startAcceptedCallbackWatermark: session.startAcceptedCallbackWatermark,
            endAcceptedCallbackWatermark: snapshot.acceptedCallbackWatermark,
            acceptedCallbackCount: snapshot.acceptedCallbackCount,
            acceptedEventCount: snapshot.acceptedEventCount,
            acceptedDestinationEventCount: snapshot.acceptedDestinationEventCount,
            acceptedNonDestinationEventCount: snapshot.acceptedNonDestinationEventCount,
            mustScanSubDirs: snapshot.mustScanSubDirs,
            rootChanged: snapshot.rootChanged,
            userDropped: snapshot.userDropped,
            kernelDropped: snapshot.kernelDropped,
            eventIDsWrapped: snapshot.eventIDsWrapped,
            eventIDRegressed: snapshot.eventIDRegressed || cutRegressed,
            lifetimeExceeded: lifetimeExceeded,
            hadGap: hadGap,
            hadDrop: hadDrop,
            // Retained for receipt fallback compatibility. This continuity-only
            // witness has no path inventory and therefore no cardinality overflow.
            overflowed: false
        )
    }

    private static func stableRootMatches(_ session: Session) -> Bool {
        guard let url = session.stableWatchRootURL,
              let expected = session.stableWatchRootIdentity
        else { return false }
        return canonicalURL(url).path == url.path
            && stableDirectoryIdentity(at: url) == expected
            && isLocalVolume(url)
    }

    private static func stableDirectoryIdentity(at url: URL) -> StableWatchRootIdentity? {
        var value = stat()
        guard lstat(url.path, &value) == 0,
              value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else { return nil }
        return StableWatchRootIdentity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino))
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func isStrictDescendant(_ path: String, of root: String) -> Bool {
        path != root && path.hasPrefix(root + "/")
    }

    private static func pathExists(_ path: String) -> Bool {
        var value = stat()
        return lstat(path, &value) == 0
    }

    private static func nearestExistingAncestor(of url: URL) -> URL? {
        var candidate = url.deletingLastPathComponent()
        while true {
            if pathExists(candidate.path) {
                return canonicalURL(candidate)
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
    }

    private static func isLocalVolume(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true
    }

    private static func isValidCut(_ eventID: UInt64) -> Bool {
        eventID > 0 && eventID != UInt64.max
    }
}
