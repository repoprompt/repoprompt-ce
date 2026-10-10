import Darwin
import Foundation
import MCP
@testable import RepoPromptApp
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
        func testUnverifiedNamesNeverAuthorizeAdmission() {
            let names = [
                "claude-code", "codex-mcp-client", "gemini-cli-mcp-client",
                "opencode", "cursor", "cursor-mcp-client", "claude-ai",
                "Claude Code 2", "cursor-custom", "previously-approved-client",
                "RepoPrompt CLI", "RepoPrompt CLI Debug"
            ]
            for name in names {
                XCTAssertFalse(ServerController.canAutomaticallyApprove(clientName: name, bundledCLI: false), name)
                XCTAssertFalse(ServerController.isBuiltInAlwaysAllowedClient(name), name)
            }
            XCTAssertTrue(ServerController.canAutomaticallyApprove(clientName: "RepoPrompt CLI", bundledCLI: true))
            XCTAssertTrue(ServerController.canAutomaticallyApprove(clientName: "RepoPrompt CLI Debug", bundledCLI: true))
            XCTAssertFalse(ServerController.canAutomaticallyApprove(clientName: "cursor", bundledCLI: true))
        }

        func testLegacyNamesArePreservedWithoutBecomingGrants() throws {
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

        func testOneTimeApprovalDoesNotTransferToSameNamePeerOrStaleResponse() async {
            let controller = ServerController(installNetworkCallbacks: false)
            let events = AdmissionEvents()
            await controller.setApprovalCallback { _, generation in events.prompt(generation) }
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

        func testExplicitDenialRemainsConnectionSpecific() async {
            let controller = ServerController(installNetworkCallbacks: false)
            let events = AdmissionEvents()
            await controller.setApprovalCallback { _, generation in events.prompt(generation) }
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
#endif
