import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptSecureStorage
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
