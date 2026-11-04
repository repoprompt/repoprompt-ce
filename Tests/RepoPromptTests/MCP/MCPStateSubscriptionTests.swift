import Darwin
import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptProcess
import RepoPromptSecureStorage
import RepoPromptShared
import XCTest

/// Regression coverage for per-subscriber MCP state streams.
///
/// `MCPService` previously exposed one shared `AsyncStream` (`stateStream`) to
/// every window's `MCPServerViewModel`. `AsyncStream` distributes each yield to
/// a single waiting iterator, so windows could steal each other's snapshots —
/// including pending-approval updates — and a closed window's iterator kept its
/// view model (and everything it holds) alive forever.
///
/// These tests pin the replacement contract: every live subscriber receives
/// every snapshot, a late subscriber is seeded with the current state,
/// `unsubscribeFromStateUpdates` finishes only that subscriber's stream, and a
/// view model can be deallocated once observation stops.
final class MCPStateSubscriptionTests: XCTestCase {
    private func makeService() -> MCPService {
        MCPService(
            hostBootstrapOperation: {},
            controllerStartOperation: {},
            controllerFullShutdownOperation: {}
        )
    }

    private func collectAll(_ stream: AsyncStream<MCPService.Snapshot>) async -> [MCPService.Snapshot] {
        var items: [MCPService.Snapshot] = []
        for await snapshot in stream {
            items.append(snapshot)
        }
        return items
    }

    /// Polls a condition with a bounded timeout. Used where state delivery
    /// crosses actors (subscribe/apply hops are asynchronous).
    @MainActor
    private func waitUntil(
        _ condition: @MainActor () async -> Bool,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let satisfied = await condition()
        XCTAssertTrue(satisfied, "Timed out waiting for condition", file: file, line: line)
    }

    /// Two subscribers must each receive every snapshot. On the shared-stream
    /// implementation each yield reached exactly one iterator, so at least one
    /// subscriber would miss updates.
    func testEverySubscriberReceivesEverySnapshot() async {
        let service = makeService()
        let (idA, streamA) = await service.subscribeToStateUpdates()
        let (idB, streamB) = await service.subscribeToStateUpdates()

        await service.join(windowID: 1)
        await service.leave(windowID: 1)
        await service.refreshState()

        await service.unsubscribeFromStateUpdates(id: idA)
        await service.unsubscribeFromStateUpdates(id: idB)

        let snapshotsA = await collectAll(streamA)
        let snapshotsB = await collectAll(streamB)

        // 1 seed snapshot at subscribe + 3 broadcast yields.
        XCTAssertEqual(snapshotsA.count, 4)
        XCTAssertEqual(snapshotsB.count, 4)
        XCTAssertEqual(snapshotsA, snapshotsB)
    }

    /// A subscriber that joins after state changed must observe the current
    /// snapshot first rather than missing it.
    func testLateSubscriberReceivesCurrentSnapshot() async {
        let service = makeService()
        await service.setPendingApprovalForTesting("early-client")

        let (id, stream) = await service.subscribeToStateUpdates()
        await service.unsubscribeFromStateUpdates(id: id)

        let snapshots = await collectAll(stream)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.pendingClientID, "early-client")
    }

    /// Unsubscribing must finish only that subscriber's stream and stop its
    /// deliveries; other subscribers keep receiving updates.
    func testUnsubscribeFinishesOnlyThatStream() async {
        let service = makeService()
        let (idA, streamA) = await service.subscribeToStateUpdates()
        let (idB, streamB) = await service.subscribeToStateUpdates()
        let initialCount = await service.stateSubscriberCountForTesting()
        XCTAssertEqual(initialCount, 2)

        await service.unsubscribeFromStateUpdates(id: idA)
        let remainingCount = await service.stateSubscriberCountForTesting()
        XCTAssertEqual(remainingCount, 1)

        await service.setPendingApprovalForTesting("client-1")
        await service.unsubscribeFromStateUpdates(id: idB)

        let snapshotsA = await collectAll(streamA)
        let snapshotsB = await collectAll(streamB)

        // A only saw the seed snapshot; B saw the seed + the approval update.
        XCTAssertEqual(snapshotsA.count, 1)
        XCTAssertNil(snapshotsA.last?.pendingClientID)
        XCTAssertEqual(snapshotsB.count, 2)
        XCTAssertEqual(snapshotsB.last?.pendingClientID, "client-1")
        let finalCount = await service.stateSubscriberCountForTesting()
        XCTAssertEqual(finalCount, 0)
    }

    /// A pending-approval snapshot must reach every live window's stream, not
    /// whichever iterator happened to be parked on a shared stream.
    func testPendingApprovalBroadcastsToAllSubscribers() async {
        let service = makeService()
        var streams: [AsyncStream<MCPService.Snapshot>] = []
        var ids: [UUID] = []
        for _ in 0 ..< 3 {
            let (id, stream) = await service.subscribeToStateUpdates()
            ids.append(id)
            streams.append(stream)
        }

        await service.setPendingApprovalForTesting("client-xyz")
        for id in ids {
            await service.unsubscribeFromStateUpdates(id: id)
        }

        for stream in streams {
            let snapshots = await collectAll(stream)
            XCTAssertEqual(snapshots.last?.pendingClientID, "client-xyz")
        }
    }

    @MainActor
    private func makeServerViewModel(service: MCPService) -> MCPServerViewModel {
        let store = WorkspaceFileContextStore()
        let fileManager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let aiQueriesService = AIQueriesService(keyManager: keyManager)
        let apiSettings = APISettingsViewModel(
            aiQueriesService: aiQueriesService,
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let settingsManager = WindowSettingsManager(windowID: -1)
        let prompt = PromptViewModel(
            fileManager: fileManager,
            aiQueriesService: aiQueriesService,
            apiSettingsViewModel: apiSettings,
            windowID: -1,
            settingsManager: settingsManager
        )
        let workspaceManager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        let oracle = OracleViewModel(
            aiQueriesService: aiQueriesService,
            promptViewModel: prompt,
            workspaceManager: workspaceManager,
            chatData: ChatDataService()
        )
        return MCPServerViewModel(
            service: service,
            promptVM: prompt,
            oracleVM: oracle,
            workspaceManager: workspaceManager,
            windowID: -1,
            workspaceSearch: { _, _, _, _, _, _, _, _, _, _, _, _, _, _ in
                throw MCPError.internalError("workspace search is not used by these tests")
            },
            ensureGitDataRootLoaded: { _, _ in
                throw MCPError.internalError("git-data loading is not used by these tests")
            }
        )
    }

    /// Composition must leave old events untouched: pruning belongs to window
    /// appearance, not to any of the per-window view-model constructors.
    @MainActor
    func testTwentySixViewModelsDoNotPruneEventDirectoryDuringComposition() throws {
        let directory = MCPExternalClientEvent.eventsDirectoryURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let prefix = "startup-scale-" + UUID().uuidString
        let files = (0 ..< 3000).map { directory.appendingPathComponent("\(prefix)-\($0).json") }
        defer {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
        for file in files {
            try Data("{}".utf8).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-8 * 24 * 3600)],
                ofItemAtPath: file.path
            )
        }

        let service = makeService()
        var servers: [MCPServerViewModel] = []
        let started = ProcessInfo.processInfo.systemUptime
        for _ in 0 ..< 26 {
            servers.append(makeServerViewModel(service: service))
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        defer { for server in servers {
            server.stopServiceObservation()
        } }

        print("STARTUP_SCALE windows=26 events=3000 composition_seconds=\(elapsed)")
        XCTAssertLessThan(elapsed, 5, "Window composition must not wait on repeated event housekeeping")
        XCTAssertTrue(
            files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
            "View-model composition must not prune old events"
        )
    }

    /// The view model's observation loop must not retain the view model: after
    /// teardown stops observation and external references drop, the VM (and its
    /// subscription) must be released. On the shared-stream implementation the
    /// loop held `self` forever and the subscriber slot leaked.
    @MainActor
    func testViewModelDeallocatesAfterObservationStops() async {
        let service = makeService()
        var server: MCPServerViewModel? = makeServerViewModel(service: service)
        weak var weakServer = server

        // The observation task subscribes asynchronously; wait for it to land.
        await waitUntil { await service.stateSubscriberCountForTesting() == 1 }

        server?.stopServiceObservation()
        server = nil

        await waitUntil { weakServer == nil }
        await waitUntil { await service.stateSubscriberCountForTesting() == 0 }
    }

    /// The live window's view model must observe a pending approval, which is
    /// what surfaces the approval overlay.
    @MainActor
    func testViewModelAppliesPendingApprovalSnapshot() async {
        let service = makeService()
        let server = makeServerViewModel(service: service)

        await service.setPendingApprovalForTesting("client-live")

        await waitUntil { server.pendingClientID == "client-live" }
        XCTAssertTrue(server.isApprovalOverlayVisible)

        server.stopServiceObservation()
    }
}

final class MCPExternalEventsCleanupTests: XCTestCase {
    @MainActor
    func testManyWindowAppearancesPruneOnceOffMainThread() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = expectation(description: "background prune started")
        started.assertForOverFulfill = true
        let executions = ExecutionCounter()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let monitor = MCPExternalEventsMonitor(eventsDirectory: directory) { _ in
            XCTAssertFalse(Thread.isMainThread)
            executions.increment()
            started.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        }

        let first = monitor.scheduleCleanupOnce()
        XCTAssertEqual(executions.value, 0, "No prune in the synchronous appearance turn")
        await fulfillment(of: [started], timeout: 5)
        var tasks: [Task<Void, Never>] = []
        for _ in 0 ..< 25 {
            tasks.append(monitor.scheduleCleanupOnce())
        }
        XCTAssertEqual(executions.value, 1)
        release.signal()
        await first.value
        for task in tasks {
            await task.value
        }
        // Later windows must not restart maintenance after the first pass finishes.
        await monitor.scheduleCleanupOnce().value
        XCTAssertEqual(executions.value, 1)
    }

    func testSymlinkRetentionMatchesPreviousMetadataLookupWithoutRemovingTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("events")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cutoff = now.addingTimeInterval(-7 * 24 * 3600)
        let cases: [(String, TimeInterval, TimeInterval?)] = [
            ("recent-link.json", -60, -8 * 24 * 3600),
            ("old-link.json", -8 * 24 * 3600, -60),
            ("dangling.json", -8 * 24 * 3600, nil)
        ]
        var expectedNames: Set<String> = []
        var targets: [URL] = []
        for (name, linkAge, targetAge) in cases {
            let target = root.appendingPathComponent(name + ".target")
            if let targetAge {
                try Data("target".utf8).write(to: target)
                try FileManager.default.setAttributes(
                    [.modificationDate: now.addingTimeInterval(targetAge)], ofItemAtPath: target.path
                )
                targets.append(target)
            }
            let link = directory.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let timestamp = timespec(tv_sec: Int(now.addingTimeInterval(linkAge).timeIntervalSince1970), tv_nsec: 0)
            let times = [timestamp, timestamp]
            let result = times.withUnsafeBufferPointer {
                utimensat(AT_FDCWD, link.path, $0.baseAddress, AT_SYMLINK_NOFOLLOW)
            }
            XCTAssertEqual(result, 0)
            // Characterize the original decision, including dangling links, rather
            // than inventing a new link-following policy.
            let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
            let modification = try XCTUnwrap(attributes[.modificationDate] as? Date)
            if modification >= cutoff { expectedNames.insert(name) }
        }

        MCPExternalEventsMonitor.cleanupOldEvents(in: directory, now: now)
        XCTAssertEqual(try Set(FileManager.default.contentsOfDirectory(atPath: directory.path)), expectedNames)
        for target in targets {
            XCTAssertEqual(try Data(contentsOf: target), Data("target".utf8))
        }
    }

    func testRetentionPreservesRecentBoundaryHiddenAndNonJSONFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let retention: TimeInterval = 7 * 24 * 3600
        let cases: [(String, TimeInterval, Bool)] = [
            ("old.json", -retention - 1, false),
            ("cli-old.json", -retention - 1, false),
            ("boundary.json", -retention, true),
            ("recent.json", -60, true),
            ("future.json", 60, true),
            (".hidden.json", -retention - 1, true),
            ("old.txt", -retention - 1, true)
        ]
        for (name, age, _) in cases {
            let url = directory.appendingPathComponent(name)
            try Data("{}".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(age)], ofItemAtPath: url.path)
        }

        MCPExternalEventsMonitor.cleanupOldEvents(in: directory, now: now)
        for (name, _, shouldExist) in cases {
            XCTAssertEqual(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path), shouldExist, name)
        }
        // Missing directories remain a best-effort no-op.
        MCPExternalEventsMonitor.cleanupOldEvents(in: directory.appendingPathComponent("missing"), now: now)
    }
}

private final class ExecutionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}

#if DEBUG
    final class MCPConnectionAdmissionTests: XCTestCase {
        private func principal(pid: Int32 = 400, start: UInt64 = 1, parent: Int32 = 200) -> MCPApprovalProcessIdentity {
            MCPApprovalProcessIdentity(
                pid: pid, parentPID: parent, effectiveUID: geteuid(),
                startSeconds: start, startMicroseconds: 5, executablePath: "/test/launcher"
            )
        }

        func testSuspendedLivenessCheckCannotBeOvertakenByNewArrival() async {
            // Exercise both an initial arrival and a head dequeued after resolving UI.
            for queuedHead in [false, true] {
                let controller = ServerController(installNetworkCallbacks: false)
                let events = AdmissionEvents()
                let suspended = expectation(description: "FIFO head suspended (queued: \(queuedHead))")
                let gate = ApprovalLivenessGate(suspended: suspended)
                await controller.setApprovalCallback { clientID, generation, _ in
                    events.decide(clientID)
                    events.prompt(generation)
                }
                if queuedHead {
                    await controller.test_requestApproval(clientID: "active", approve: {}, deny: {})
                    await controller.test_requestApproval(
                        clientID: "head", isConnectionLive: { await gate.check() }, approve: {}, deny: {}
                    )
                }
                await gate.pause()
                let advance = Task {
                    if queuedHead {
                        await controller.resolvePendingApproval(allow: false, generation: events.generations[0])
                    } else {
                        await controller.test_requestApproval(
                            clientID: "head", isConnectionLive: { await gate.check() }, approve: {}, deny: {}
                        )
                    }
                }
                await fulfillment(of: [suspended], timeout: 2)
                await controller.test_requestApproval(clientID: "tail", approve: {}, deny: {})
                XCTAssertEqual(events.decisions, queuedHead ? ["active"] : [], "New arrival must not overtake the suspended head")
                await gate.resume()
                await advance.value
                XCTAssertEqual(events.decisions, queuedHead ? ["active", "head"] : ["head"])
                if let generation = events.generations.last {
                    await controller.resolvePendingApproval(allow: false, generation: generation)
                }
                XCTAssertEqual(events.decisions, queuedHead ? ["active", "head", "tail"] : ["head", "tail"])
                if let generation = events.generations.last {
                    await controller.resolvePendingApproval(allow: false, generation: generation)
                }
            }
        }

        private actor ApprovalLivenessGate {
            let suspended: XCTestExpectation
            private var paused = false
            private var continuation: CheckedContinuation<Bool, Never>?

            init(suspended: XCTestExpectation) {
                self.suspended = suspended
            }

            func pause() {
                paused = true
            }

            func check() async -> Bool {
                guard paused else { return true }
                return await withCheckedContinuation { continuation in
                    self.continuation = continuation
                    suspended.fulfill()
                }
            }

            func resume() {
                paused = false
                continuation?.resume(returning: true)
                continuation = nil
            }
        }

        func testSessionApprovalCoversReconnectsButNotSameNameOrRecycledPID() async {
            let controller = ServerController(installNetworkCallbacks: false, processIsCurrent: { _ in true })
            let events = AdmissionEvents()
            await controller.setApprovalCallback { _, generation, path in
                XCTAssertEqual(path, "/test/launcher")
                events.prompt(generation)
            }
            let launcher = principal()
            for _ in 0 ..< 2 {
                await controller.test_requestApproval(
                    clientID: "external-test-client", principal: launcher,
                    approve: { events.decide("allowed") }, deny: { events.decide("denied") }
                )
            }
            await controller.resolvePendingApproval(allow: true, generation: events.generations[0])
            XCTAssertEqual(events.decisions, ["allowed", "allowed"])
            await controller.test_requestApproval(
                clientID: "different-self-reported-name", principal: launcher,
                approve: { events.decide("reconnected") }, deny: { events.decide("denied") }
            )
            XCTAssertEqual(events.decisions.last, "reconnected")
            XCTAssertEqual(events.generations.count, 1)
            await controller.test_requestApproval(
                clientID: "external-test-client", principal: principal(start: 2),
                approve: {}, deny: {}
            )
            XCTAssertEqual(events.generations.count, 2)
            await controller.resolvePendingApproval(allow: false, generation: events.generations[1])
        }

        func testDenialCooldownDrainsQueuedRetriesAndDoesNotSlide() async {
            let clock = AdmissionClock()
            let controller = ServerController(
                installNetworkCallbacks: false, monotonicNow: { clock.now }, processIsCurrent: { _ in true }
            )
            let events = AdmissionEvents()
            await controller.setApprovalCallback { _, generation, _ in events.prompt(generation) }
            for _ in 0 ..< 2 {
                await controller.test_requestApproval(
                    clientID: "same-name", principal: principal(),
                    approve: { events.decide("allowed") }, deny: { events.decide("denied") }
                )
            }
            await controller.resolvePendingApproval(allow: false, generation: events.generations[0])
            XCTAssertEqual(events.decisions, ["denied", "denied"])
            clock.advance(59)
            await controller.test_requestApproval(
                clientID: "same-name", principal: principal(),
                approve: {}, deny: { events.decide("cooldown") }
            )
            XCTAssertEqual(events.decisions.last, "cooldown")
            XCTAssertEqual(events.generations.count, 1)
            clock.advance(2)
            await controller.test_requestApproval(clientID: "same-name", principal: principal(), approve: {}, deny: {})
            XCTAssertEqual(events.generations.count, 2)
            await controller.resolvePendingApproval(allow: false, generation: events.generations[1])
            await controller.test_requestApproval(
                clientID: "same-name", principal: principal(pid: 401), approve: {}, deny: {}
            )
            XCTAssertEqual(events.generations.count, 3)
            await controller.resolvePendingApproval(allow: false, generation: events.generations[2])
        }

        func testBundledHelperUsesImmediateParentButUnverifiedPeerCannot() {
            let launcher = principal()
            let helper = principal(pid: 500, parent: launcher.pid)
            let replacement = principal(pid: 501, parent: launcher.pid)
            let processes = [launcher.pid: launcher, helper.pid: helper, replacement.pid: replacement]
            XCTAssertEqual(MCPApprovalProcessIdentity.resolve(peerPID: helper.pid, bundledHelper: true, read: { processes[$0] }), launcher)
            XCTAssertEqual(MCPApprovalProcessIdentity.resolve(peerPID: replacement.pid, bundledHelper: true, read: { processes[$0] }), launcher)
            XCTAssertEqual(MCPApprovalProcessIdentity.resolve(peerPID: helper.pid, bundledHelper: false, read: { processes[$0] }), helper)
            XCTAssertNil(MCPApprovalProcessIdentity.resolve(peerPID: 999, bundledHelper: true, read: { processes[$0] }))
            XCTAssertNil(MCPApprovalProcessIdentity.resolve(peerPID: helper.pid, bundledHelper: true, read: { $0 == helper.pid ? helper : nil }))
            var reads = 0
            XCTAssertNil(MCPApprovalProcessIdentity.resolve(peerPID: helper.pid, bundledHelper: true, read: {
                reads += 1
                return reads == 3 ? replacement : processes[$0]
            }))
        }

        func testCapacityRetiresDeadEntriesBeforeLongLivedLauncherConsent() async throws {
            let lifetimes = AdmissionLiveness()
            let controller = ServerController(
                installNetworkCallbacks: false,
                processIsCurrent: { $0.pid == 400 || $0.pid == 656 || lifetimes.isLive }
            )
            let events = AdmissionEvents()
            await controller.setApprovalCallback { _, generation, _ in events.prompt(generation) }
            for pid in Int32(400) ..< Int32(656) {
                await controller.test_requestApproval(clientID: "client", principal: principal(pid: pid), approve: {}, deny: {})
                let generation = try XCTUnwrap(events.generations.last)
                await controller.resolvePendingApproval(allow: true, generation: generation)
            }
            lifetimes.close()
            await controller.test_requestApproval(clientID: "client", principal: principal(pid: 656), approve: {}, deny: {})
            let generation = try XCTUnwrap(events.generations.last)
            await controller.resolvePendingApproval(allow: true, generation: generation)
            await controller.test_requestApproval(
                clientID: "long-lived-client", principal: principal(),
                approve: { events.decide("remembered") }, deny: { events.decide("denied") }
            )
            XCTAssertEqual(events.generations.count, 257)
            XCTAssertEqual(events.decisions, ["remembered"])
        }

        func testApprovalQueueIsBoundedAndResolvesOverflow() async {
            let controller = ServerController(installNetworkCallbacks: false)
            let events = AdmissionEvents()
            await controller.setApprovalCallback { _, generation, _ in events.prompt(generation) }
            for _ in 0 ..< 33 {
                await controller.test_requestApproval(clientID: "peer", approve: {}, deny: { events.decide("denied") })
            }
            XCTAssertEqual(events.generations.count, 1)
            XCTAssertEqual(events.decisions, ["denied"])
            for index in 0 ..< 32 {
                await controller.resolvePendingApproval(allow: false, generation: events.generations[index])
            }
            XCTAssertEqual(events.decisions.count, 33)
        }

        func testVanishedHelperRetainsConsentForLiveLauncherButCannotUseDeadConnection() async {
            let controller = ServerController(installNetworkCallbacks: false, processIsCurrent: { _ in true })
            let events = AdmissionEvents()
            await controller.setApprovalCallback { _, generation, _ in events.prompt(generation) }
            await controller.test_requestApproval(
                clientID: "external", principal: principal(), validate: { false },
                approve: { events.decide("unexpected") }, deny: { events.decide("gone") }
            )
            await controller.test_requestApproval(
                clientID: "external", principal: principal(),
                approve: { events.decide("allowed") }, deny: { events.decide("denied") }
            )
            await controller.resolvePendingApproval(allow: true, generation: events.generations[0])
            XCTAssertEqual(events.decisions, ["gone", "allowed"])
            XCTAssertEqual(events.generations.count, 1)
            await controller.test_requestApproval(
                clientID: "external", principal: principal(), validate: { false },
                approve: { events.decide("unexpected") }, deny: { events.decide("rejected") }
            )
            XCTAssertEqual(events.decisions, ["gone", "allowed", "rejected"])
            XCTAssertEqual(events.generations.count, 1)
        }

        /// Avoid blocking Process.waitUntilExit across actor hops and bound cleanup.
        /// The exact mechanism of the CI hang was not identified.
        private func withAdmissionChild(_ operation: (ChildProcessExitObserver) async throws -> Void) async throws {
            let process = try ProcessLauncher.spawn(
                command: "/bin/sleep", arguments: ["60"], environment: [:], workingDirectory: nil, purpose: .tool
            )
            let child = ChildProcessExitObserver.observe(pid: process.pid)
            process.stdin?.closeFile()
            process.stdout.closeFile()
            process.stderr.closeFile()
            do {
                try await operation(child)
            } catch {
                _ = await stopAdmissionChild(child)
                throw error
            }
            _ = await stopAdmissionChild(child)
        }

        private func stopAdmissionChild(_ child: ChildProcessExitObserver) async -> Bool {
            // The observer owns reaping and closes signaling before PID reuse.
            // Repeated cleanup after an explicit stop is therefore safe.
            _ = child.signalRootProcessFamilyIfUnreaped(processGroupID: nil, signal: SIGKILL)
            let outcome = await child.wait(timeout: 5)
            let expected = ChildProcessExitObserver.Outcome.exited(.uncaughtSignal(signal: SIGKILL))
            XCTAssertEqual(outcome, expected, "Synthetic admission child exit/cleanup was not confirmed within five seconds")
            return outcome == expected
        }

        /// Uses real OS child lifetimes to exercise process resolution and consent;
        /// bundled-executable verification and the MCP socket path are separate boundaries.
        func testRealChildRespawnsShareLauncherConsentEvenAfterPromptingChildExits() async throws {
            for allow in [true, false] {
                let controller = ServerController(installNetworkCallbacks: false)
                let events = AdmissionEvents()
                await controller.setApprovalCallback { _, generation, _ in events.prompt(generation) }
                try await withAdmissionChild { first in
                    let firstPID = first.pid
                    let firstPeer = try XCTUnwrap(MCPApprovalProcessIdentity.read(pid: firstPID))
                    let launcher = try XCTUnwrap(MCPApprovalProcessIdentity.resolve(peerPID: firstPID, bundledHelper: true))
                    XCTAssertEqual(launcher.pid, getpid())
                    await controller.test_requestApproval(
                        clientID: "external-test-client", principal: launcher,
                        validate: { MCPApprovalProcessIdentity.read(pid: firstPID) == firstPeer },
                        isConnectionLive: { MCPApprovalProcessIdentity.read(pid: firstPID) == firstPeer },
                        approve: { events.decide("unexpected") }, deny: { events.decide("old-helper-denied") }
                    )
                    guard await stopAdmissionChild(first) else { return }
                    try await withAdmissionChild { second in
                        let secondPID = second.pid
                        let secondPeer = try XCTUnwrap(MCPApprovalProcessIdentity.read(pid: secondPID))
                        let secondLauncher = try XCTUnwrap(MCPApprovalProcessIdentity.resolve(peerPID: secondPID, bundledHelper: true))
                        XCTAssertEqual(secondLauncher, launcher)
                        await controller.test_requestApproval(
                            clientID: "external-test-client", principal: secondLauncher,
                            validate: { MCPApprovalProcessIdentity.read(pid: secondPID) == secondPeer },
                            isConnectionLive: { MCPApprovalProcessIdentity.read(pid: secondPID) == secondPeer },
                            approve: { events.decide("new-helper-allowed") }, deny: { events.decide("new-helper-denied") }
                        )
                        await controller.resolvePendingApproval(allow: allow, generation: events.generations[0])
                        XCTAssertEqual(events.generations.count, 1)
                        XCTAssertEqual(events.decisions, ["old-helper-denied", allow ? "new-helper-allowed" : "new-helper-denied"])
                    }
                }
            }
        }

        func testClosedQueuedConnectionNeverPresentsAnotherDialog() async {
            let controller = ServerController(installNetworkCallbacks: false)
            let events = AdmissionEvents()
            let liveness = AdmissionLiveness()
            await controller.setApprovalCallback { _, generation, _ in events.prompt(generation) }
            await controller.test_requestApproval(clientID: "active", approve: { events.decide("active") }, deny: {})
            await controller.test_requestApproval(
                clientID: "closed", isConnectionLive: { liveness.isLive },
                approve: { events.decide("unexpected") }, deny: { events.decide("closed") }
            )
            liveness.close()
            await controller.resolvePendingApproval(allow: true, generation: events.generations[0])
            XCTAssertEqual(events.decisions, ["active", "closed"])
            XCTAssertEqual(events.generations.count, 1)
            await controller.test_requestApproval(
                clientID: "already-closed", isConnectionLive: { false }, approve: {}, deny: { events.decide("discarded") }
            )
            XCTAssertEqual(events.decisions.last, "discarded")
            XCTAssertEqual(events.generations.count, 1)
        }

        func testUnverifiedTimeoutDrainsOnlySameNameUnverifiedRequests() async {
            let controller = ServerController(installNetworkCallbacks: false)
            let events = AdmissionEvents()
            await controller.setApprovalCallback { _, generation, _ in events.prompt(generation) }
            for _ in 0 ..< 2 {
                await controller.test_requestApproval(clientID: "unknown", approve: {}, deny: { events.decide("timed-out") })
            }
            await controller.test_requestApproval(clientID: "other", approve: {}, deny: { events.decide("other") })
            await controller.test_timeoutApproval(generation: events.generations[0])
            XCTAssertEqual(events.decisions, ["timed-out", "timed-out"])
            XCTAssertEqual(events.generations.count, 2)
            await controller.resolvePendingApproval(allow: false, generation: events.generations[1])
        }

        func testTimeoutCreatesCooldownAndDrainsOnlyMatchingProcess() async {
            let controller = ServerController(installNetworkCallbacks: false, processIsCurrent: { _ in true })
            let events = AdmissionEvents()
            await controller.setApprovalCallback { _, generation, _ in events.prompt(generation) }
            for _ in 0 ..< 2 {
                await controller.test_requestApproval(
                    clientID: "external", principal: principal(), approve: {}, deny: { events.decide("timeout") }
                )
            }
            await controller.test_requestApproval(
                clientID: "external", principal: principal(pid: 401), approve: {}, deny: { events.decide("other") }
            )
            await controller.test_timeoutApproval(generation: events.generations[0])
            XCTAssertEqual(events.decisions, ["timeout", "timeout"])
            XCTAssertEqual(events.generations.count, 2)
            await controller.test_timeoutApproval(generation: events.generations[0])
            XCTAssertEqual(events.decisions.count, 2)
            await controller.resolvePendingApproval(allow: false, generation: events.generations[1])
        }

        func testProcessIdentityComesFromKernelAndDoesNotDependOnLauncherAncestry() throws {
            let observed = try XCTUnwrap(MCPApprovalProcessIdentity.read(pid: getpid()))
            XCTAssertEqual(observed.pid, getpid())
            XCTAssertEqual(observed.effectiveUID, geteuid())
            XCTAssertGreaterThan(observed.startSeconds, 0)
            XCTAssertFalse(observed.executablePath.isEmpty)
            XCTAssertEqual(principal(), principal(parent: 999))
            XCTAssertEqual(Set([principal(), principal(parent: 999)]).count, 1)
        }

        func testBundledHelperAdmissionStillRequiresExecutableVerification() {
            let names = [
                "claude-code", "codex-mcp-client", "gemini-cli-mcp-client",
                "opencode", "cursor", "cursor-mcp-client", "claude-ai",
                "Claude Code 2", "cursor-custom", "previously-approved-client",
                "RepoPrompt CLI", "RepoPrompt CLI Debug"
            ]
            for name in names {
                XCTAssertFalse(ServerController.canAutomaticallyApprove(clientName: name, bundledCLI: false), name)
            }
            XCTAssertTrue(ServerController.canAutomaticallyApprove(clientName: "RepoPrompt CLI", bundledCLI: true))
            XCTAssertTrue(ServerController.canAutomaticallyApprove(clientName: "RepoPrompt CLI Debug", bundledCLI: true))
            XCTAssertFalse(ServerController.canAutomaticallyApprove(clientName: "cursor", bundledCLI: true))
            XCTAssertFalse(ServerController.canSaveAlwaysAllowed(clientName: "RepoPrompt CLI"))
            XCTAssertFalse(ServerController.isBuiltInAlwaysAllowedClient("RepoPrompt CLI Debug"))
            XCTAssertTrue(ServerController.canSaveAlwaysAllowed(clientName: "external-test-client"))
            XCTAssertTrue(ServerController.isBuiltInAlwaysAllowedClient("cursor"))
        }

        func testLegacyNamesArePreservedAndCannotBypassBundledHelperVerification() throws {
            let suite = "MCPConnectionAdmissionTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let names = ["previously-approved-client", "RepoPrompt CLI", "cursor-custom"]
            defaults.set(names, forKey: "mcp.alwaysAllowedClients")
            XCTAssertEqual(ServerController.loadLegacyClientNames(defaults: defaults), Set(names))
            XCTAssertEqual(defaults.stringArray(forKey: "mcp.alwaysAllowedClients"), names)
            for name in names {
                XCTAssertFalse(ServerController.canAutomaticallyApprove(clientName: name, bundledCLI: false))
            }
        }

        func testStrictModeCannotSaveAlwaysAllowAndStaleResponseCannotSaveSuccessorName() async throws {
            for strict in [true, false] {
                let suite = "MCPConnectionAdmissionTests.\(UUID().uuidString)"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let controller = ServerController(
                    installNetworkCallbacks: false, approvalDefaults: defaults,
                    strictConnectionApprovalEnabled: { strict }
                )
                let events = AdmissionEvents()
                await controller.setApprovalCallback { _, generation, _ in events.prompt(generation) }
                for name in ["first", "second"] {
                    await controller.test_requestApproval(
                        clientID: name, approve: { events.decide(name) }, deny: {}
                    )
                }
                let first = try XCTUnwrap(events.generations.first)
                await controller.resolvePendingApproval(allow: true, generation: first, alwaysAllow: true)
                await controller.resolvePendingApproval(allow: true, generation: first, alwaysAllow: true)
                XCTAssertEqual(defaults.stringArray(forKey: "mcp.alwaysAllowedClients") ?? [], strict ? [] : ["first"])
                XCTAssertEqual(events.decisions, ["first"])
                await controller.resolvePendingApproval(allow: false, generation: events.generations[1])
            }
        }

        func testAlwaysAllowCannotPersistForClosedAnonymousConnectionOrExitedProcess() async throws {
            for (hasPrincipal, connectionIsValid) in [(false, false), (true, false), (true, true)] {
                let suite = "MCPConnectionAdmissionTests.\(UUID().uuidString)"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let process = AdmissionLiveness()
                let controller = ServerController(
                    installNetworkCallbacks: false, approvalDefaults: defaults,
                    strictConnectionApprovalEnabled: { false }, processIsCurrent: { _ in process.isLive }
                )
                let events = AdmissionEvents()
                await controller.setApprovalCallback { _, generation, _ in events.prompt(generation) }
                await controller.test_requestApproval(
                    clientID: "external-test-client", principal: hasPrincipal ? principal() : nil,
                    validate: { connectionIsValid },
                    approve: { events.decide("allowed") }, deny: { events.decide("denied") }
                )
                let generation = try XCTUnwrap(events.generations.first)
                process.close()
                await controller.resolvePendingApproval(allow: true, generation: generation, alwaysAllow: true)
                XCTAssertEqual(defaults.stringArray(forKey: "mcp.alwaysAllowedClients") ?? [], [])
                XCTAssertEqual(events.decisions, ["denied"])
            }
        }

        func testOneTimeApprovalDoesNotTransferToSameNamePeerOrStaleResponse() async {
            let controller = ServerController(installNetworkCallbacks: false)
            let events = AdmissionEvents()
            await controller.setApprovalCallback { _, generation, _ in events.prompt(generation) }
            await controller.test_requestApproval(
                clientID: "same-name", approve: { events.decide("first-allowed") }, deny: { events.decide("first-denied") }
            )
            await controller.test_requestApproval(
                clientID: "same-name", approve: { events.decide("second-allowed") }, deny: { events.decide("second-denied") }
            )
            XCTAssertEqual(events.generations.count, 1)
            let first = events.generations[0]
            await controller.resolvePendingApproval(allow: true, generation: first)
            XCTAssertEqual(events.decisions, ["first-allowed"])
            XCTAssertEqual(events.generations.count, 2)
            let second = events.generations[1]
            XCTAssertNotEqual(first, second)
            await controller.resolvePendingApproval(allow: true, generation: first)
            XCTAssertEqual(events.decisions, ["first-allowed"])
            await controller.resolvePendingApproval(allow: true, generation: second)
            XCTAssertEqual(events.decisions, ["first-allowed", "second-allowed"])
        }

        func testTwoWindowServiceResponsesCannotResolveSuccessorGeneration() async throws {
            let controller = ServerController(installNetworkCallbacks: false)
            let service = MCPService(
                controller: controller,
                hostBootstrapOperation: {}, controllerStartOperation: {}, controllerFullShutdownOperation: {}
            )
            let (windowA, streamA) = await service.subscribeToStateUpdates()
            let (windowB, streamB) = await service.subscribeToStateUpdates()
            let events = AdmissionEvents()
            await controller.setApprovalCallback { name, generation, executablePath in
                await service.setPendingApprovalForTesting(name, generation: generation, executablePath: executablePath)
                events.prompt(generation)
            }
            for peer in ["first", "second"] {
                await controller.test_requestApproval(
                    clientID: "same-name", approve: { events.decide("\(peer)-allowed") }, deny: { events.decide("\(peer)-denied") }
                )
            }
            // Init may have installed the equivalent production callback. Read the generations
            // from the service streams themselves, just as two windows do.
            var iteratorA = streamA.makeAsyncIterator()
            _ = await iteratorA.next() // seed
            let nextFirstSnapshot = await iteratorA.next()
            let firstSnapshot = try XCTUnwrap(nextFirstSnapshot)
            let first = try XCTUnwrap(firstSnapshot.pendingApprovalGeneration)
            await service.continuePendingApproval(allow: true, generation: first)
            _ = await iteratorA.next() // clear before successor
            let nextSecondSnapshot = await iteratorA.next()
            let secondSnapshot = try XCTUnwrap(nextSecondSnapshot)
            let second = try XCTUnwrap(secondSnapshot.pendingApprovalGeneration)
            XCTAssertNotEqual(first, second)
            XCTAssertEqual(secondSnapshot.pendingClientID, "same-name")
            await service.updateDiagnostics(MCPDiagnostics())
            // A delayed second-window click cannot clear or resolve the successor.
            await service.continuePendingApproval(allow: false, generation: first)
            XCTAssertEqual(events.decisions, ["first-allowed"])
            await service.continuePendingApproval(allow: false, generation: second)
            XCTAssertEqual(events.decisions, ["first-allowed", "second-denied"])
            // Publish a known diagnostic before finishing the streams, without relying
            // on when the controller's unawaited denial diagnostic happens to run.
            let marker = MCPDiagnostics(
                issue: .lastClientApprovalDenied(clientID: "same-name"),
                listenerStateDescription: "controlled approval diagnostic"
            )
            await service.updateDiagnostics(marker)
            await service.unsubscribeFromStateUpdates(id: windowA)
            await service.unsubscribeFromStateUpdates(id: windowB)
            var snapshotsB: [MCPService.Snapshot] = []
            for await snapshot in streamB {
                snapshotsB.append(snapshot)
            }
            // Diagnostics also publish snapshots; compare approval transitions, not notification counts.
            let approvalTransitions = snapshotsB.reduce(into: [MCPService.Snapshot]()) { transitions, snapshot in
                if let previous = transitions.last,
                   previous.pendingApprovalGeneration == snapshot.pendingApprovalGeneration,
                   previous.pendingClientID == snapshot.pendingClientID,
                   previous.pendingApprovalExecutablePath == snapshot.pendingApprovalExecutablePath
                { return }
                transitions.append(snapshot)
            }
            XCTAssertEqual(approvalTransitions.map(\.pendingApprovalGeneration), [nil, first, nil, second, nil])
            XCTAssertEqual(approvalTransitions.map(\.pendingClientID), [nil, "same-name", nil, "same-name", nil])
            XCTAssertEqual(approvalTransitions.map(\.pendingApprovalExecutablePath), [nil, nil, nil, nil, nil])
            // Diagnostic snapshots may also occur while the successor is pending. Start
            // the suffix after its final clear, rather than assuming five publications.
            let lastPendingIndex = try XCTUnwrap(snapshotsB.lastIndex { $0.pendingApprovalGeneration == second })
            let approvalSuffix = snapshotsB.dropFirst(lastPendingIndex + 2)
            _ = try XCTUnwrap(approvalSuffix.first { $0.diagnostics == marker })
            for snapshot in approvalSuffix {
                XCTAssertNil(snapshot.pendingClientID)
                XCTAssertNil(snapshot.pendingApprovalGeneration)
                XCTAssertNil(snapshot.pendingApprovalExecutablePath)
                XCTAssertNotEqual(snapshot.diagnostics, MCPDiagnostics(), "only diagnostic publications may follow the final clear")
            }
        }

        func testExplicitDenialRemainsConnectionSpecific() async {
            let controller = ServerController(installNetworkCallbacks: false)
            let events = AdmissionEvents()
            await controller.setApprovalCallback { _, generation, _ in events.prompt(generation) }
            for peer in ["first", "second"] {
                await controller.test_requestApproval(
                    clientID: "same-name", approve: { events.decide("\(peer)-allowed") }, deny: { events.decide("\(peer)-denied") }
                )
            }
            await controller.resolvePendingApproval(allow: false, generation: events.generations[0])
            XCTAssertEqual(events.decisions, ["first-denied"])
            await controller.resolvePendingApproval(allow: true, generation: events.generations[1])
            XCTAssertEqual(events.decisions, ["first-denied", "second-allowed"])
        }
    }

    private final class AdmissionLiveness: @unchecked Sendable {
        private let lock = NSLock()
        private var value = true
        var isLive: Bool {
            lock.withLock { value }
        }

        func close() {
            lock.withLock { value = false }
        }
    }

    private final class AdmissionClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 0
        var now: TimeInterval {
            lock.withLock { value }
        }

        func advance(_ seconds: TimeInterval) {
            lock.withLock { value += seconds }
        }
    }

    private final class AdmissionEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var storedGenerations: [UInt64] = []
        private var storedDecisions: [String] = []

        var generations: [UInt64] {
            lock.withLock { storedGenerations }
        }

        var decisions: [String] {
            lock.withLock { storedDecisions }
        }

        func prompt(_ generation: UInt64) {
            lock.withLock { storedGenerations.append(generation) }
        }

        func decide(_ decision: String) {
            lock.withLock { storedDecisions.append(decision) }
        }
    }

    /// Isolated socket-level coverage: real MCP initialize, kernel peer credentials,
    /// production admission/identity/liveness, and connection removal. No app launch.
    final class MCPConnectionApprovalTransportTests: XCTestCase {
        func testAlwaysAllowPersistsAcrossReconnectAndControllerRestart() async throws {
            try await exerciseReconnectAndRestart(strict: false, clientName: "external-test-client")
        }

        func testBuiltInNamesAreAllowedByDefault() async throws {
            try await exerciseReconnectAndRestart(strict: false, clientName: "cursor")
        }

        func testStrictModeIgnoresSavedNamesAndResetsOnRestart() async throws {
            try await exerciseReconnectAndRestart(strict: true, clientName: "external-test-client")
        }

        func testStrictModeKeepsExplicitGlobalAutoApprove() async throws {
            try await exerciseReconnectAndRestart(strict: true, clientName: "external-test-client", autoApproveAll: true)
        }

        func testStrictModeAlsoPromptsForBuiltInNames() async throws {
            try await exerciseReconnectAndRestart(strict: true, clientName: "cursor")
        }

        private func exerciseReconnectAndRestart(
            strict: Bool, clientName: String, autoApproveAll: Bool = false
        ) async throws {
            let suite = "MCPConnectionApprovalTransportTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            // Strict runs start with a saved name that default mode would honor.
            if strict { defaults.set([clientName], forKey: "mcp.alwaysAllowedClients") }
            defaults.set(autoApproveAll, forKey: "mcpAutoApproveAllClients")
            let events = ApprovalEvents()
            // New owners model a RepoPrompt restart: only the same defaults survive.
            for _ in 0 ..< 2 {
                let network = ServerNetworkManager()
                let controller = ServerController(
                    networkManager: network, installNetworkCallbacks: false,
                    approvalDefaults: defaults, strictConnectionApprovalEnabled: { strict }
                )
                await controller.setApprovalCallback { [weak controller] name, generation, _ in
                    XCTAssertEqual(name, clientName)
                    events.prompt(generation)
                    await controller?.resolvePendingApproval(allow: true, generation: generation, alwaysAllow: true)
                }
                for _ in 0 ..< 2 {
                    let connection = try await makeConnection(network: network, controller: controller, clientName: clientName)
                    do {
                        _ = try await connection.client.connect(transport: connection.transport)
                    } catch {
                        await connection.close()
                        await network.stop()
                        throw error
                    }
                    await connection.close()
                }
                await controller.setApprovalCallback { _, _, _ in }
                await network.stop()
            }
            let expectedPrompts = autoApproveAll ? 0 : (strict ? 2 : (clientName == "cursor" ? 0 : 1))
            XCTAssertEqual(events.generations.count, expectedPrompts)
            XCTAssertEqual(defaults.stringArray(forKey: "mcp.alwaysAllowedClients") ?? [], clientName == "cursor" && !strict ? [] : [clientName])
        }

        func testAllowSurvivesSocketCloseBeforeClickAndAdmitsReconnectWithoutPrompt() async throws {
            try await exerciseDecisionAfterSocketCloses(allow: true)
        }

        func testDenySurvivesSocketCloseBeforeClickAndRejectsReconnectWithoutPrompt() async throws {
            try await exerciseDecisionAfterSocketCloses(allow: false)
        }

        func testAlwaysAllowSurvivesSocketCloseBeforeClickAndControllerRestart() async throws {
            try await exerciseDecisionAfterSocketCloses(allow: true, strict: false, alwaysAllow: true)
        }

        private func exerciseDecisionAfterSocketCloses(
            allow: Bool, strict: Bool = true, alwaysAllow: Bool = false
        ) async throws {
            let suite = "MCPConnectionApprovalTransportTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let network = ServerNetworkManager()
            let controller = ServerController(
                networkManager: network, installNetworkCallbacks: false,
                approvalDefaults: defaults, strictConnectionApprovalEnabled: { strict }
            )
            let autoApprove = await controller.getAutoApproveAllClients()
            XCTAssertFalse(autoApprove, "This regression must exercise manual approval, not the global bypass")
            let prompted = expectation(description: "External initialize requests manual approval")
            let events = ApprovalEvents()
            await controller.setApprovalCallback { [weak controller] name, generation, path in
                XCTAssertEqual(name, "external-test-client")
                XCTAssertEqual(path, MCPApprovalProcessIdentity.read(pid: getpid())?.executablePath)
                events.prompt(generation)
                if events.generations.count == 1 {
                    prompted.fulfill()
                } else {
                    XCTFail("A replacement connection unexpectedly prompted again")
                    await controller?.resolvePendingApproval(allow: false, generation: generation)
                }
            }
            let first = try await makeConnection(network: network, controller: controller)
            let initialize = Task { try await first.client.connect(transport: first.transport) }
            await fulfillment(of: [prompted], timeout: 5)
            guard let generation = events.generations.first else {
                initialize.cancel()
                await first.close()
                await network.stop()
                return XCTFail("Production admission never presented an approval")
            }

            // Model a host abandoning initialize while the user is reading the dialog.
            // The OS principal remains alive, but the actual network lifecycle is gone.
            await first.close()
            let firstIsLive = await network.isConnectionLiveForApproval(first.id)
            XCTAssertFalse(firstIsLive)
            await controller.resolvePendingApproval(allow: allow, generation: generation, alwaysAllow: alwaysAllow)
            initialize.cancel()
            _ = await initialize.result
            let removed = await network.debugDirectAdmissionStateForTesting(connectionID: first.id)
            XCTAssertNil(removed.pendingClientID)

            let second = try await makeConnection(network: network, controller: controller)
            do {
                do {
                    _ = try await second.client.connect(transport: second.transport)
                    XCTAssertTrue(allow, "A remembered denial must reject the replacement connection")
                } catch {
                    if allow { throw error }
                }
                XCTAssertEqual(events.generations.count, 1, "Replacement sockets from the same process must not prompt again")
                if !allow {
                    let deniedIsLive = await network.isConnectionLiveForApproval(second.id)
                    let denied = await network.debugDirectAdmissionStateForTesting(connectionID: second.id)
                    XCTAssertFalse(deniedIsLive)
                    XCTAssertNil(denied.pendingClientID, "Cooldown rejection must release the reserved admission slot")
                }
            } catch {
                await second.close()
                await controller.setApprovalCallback { _, _, _ in }
                await network.stop()
                throw error
            }
            await second.close()
            await controller.setApprovalCallback { _, _, _ in }
            await network.stop()

            let shouldPersist = allow && alwaysAllow && !strict
            XCTAssertEqual(defaults.stringArray(forKey: "mcp.alwaysAllowedClients") ?? [], shouldPersist ? ["external-test-client"] : [])
            guard shouldPersist else { return }

            let restartedNetwork = ServerNetworkManager()
            let restartedController = ServerController(
                networkManager: restartedNetwork, installNetworkCallbacks: false,
                approvalDefaults: defaults, strictConnectionApprovalEnabled: { strict }
            )
            await restartedController.setApprovalCallback { [weak restartedController] _, generation, _ in
                events.prompt(generation)
                XCTFail("Always Allow after socket closure must survive controller recreation")
                await restartedController?.resolvePendingApproval(allow: false, generation: generation)
            }
            let reconnected = try await makeConnection(network: restartedNetwork, controller: restartedController)
            do {
                _ = try await reconnected.client.connect(transport: reconnected.transport)
                XCTAssertEqual(events.generations.count, 1)
            } catch {
                await reconnected.close()
                await restartedNetwork.stop()
                throw error
            }
            await reconnected.close()
            await restartedNetwork.stop()
        }

        private func makeConnection(
            network: ServerNetworkManager,
            controller: ServerController,
            clientName: String = "external-test-client"
        ) async throws -> SocketConnection {
            var descriptors = [Int32](repeating: -1, count: 2)
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENFILE)
            }
            defer {
                for fd in descriptors where fd >= 0 {
                    Darwin.close(fd)
                }
            }
            var peerPID: pid_t = 0
            var length = socklen_t(MemoryLayout<pid_t>.size)
            guard getsockopt(descriptors[0], SOL_LOCAL, LOCAL_PEERPID, &peerPID, &length) == 0, peerPID > 1 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ESRCH)
            }
            XCTAssertEqual(peerPID, getpid())
            let id = UUID()
            let token = UUID().uuidString
            let server = try BootstrapSocketConnectionManager(
                connectionID: id, sessionToken: token, clientPid: Int(peerPID),
                observedKernelPeerPID: Int(peerPID), clientName: clientName,
                purpose: .unknown, codeMapsDisabled: true, connectedFD: descriptors[0], parentManager: network
            )
            descriptors[0] = -1
            let transport = try UnixSocketMCPTransport(connectedFD: descriptors[1], connectionID: id, correlationConnectionID: token)
            descriptors[1] = -1
            await network.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: id, connection: server, pendingClientID: clientName
            )
            _ = await network.debugInstallConnectionLimiterForTesting(connectionID: id)
            do {
                try await server.start { info in
                    await controller.test_authorizeConnection(connectionID: id, clientName: info.name)
                }
            } catch {
                await transport.disconnect()
                await server.stop()
                await network.debugRemoveConnection(id)
                throw error
            }
            return SocketConnection(
                id: id, client: Client(name: clientName, version: "1.0"),
                transport: transport, server: server, network: network
            )
        }

        private struct SocketConnection {
            let id: UUID
            let client: Client
            let transport: UnixSocketMCPTransport
            let server: BootstrapSocketConnectionManager
            let network: ServerNetworkManager

            func close() async {
                await client.disconnect()
                await transport.disconnect()
                await server.stop()
                await network.debugRemoveConnection(id)
            }
        }

        private final class ApprovalEvents: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [UInt64] = []
            var generations: [UInt64] {
                lock.withLock { values }
            }

            func prompt(_ generation: UInt64) {
                lock.withLock { values.append(generation) }
            }
        }
    }
#endif
