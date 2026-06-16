import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class WorkspaceSwitchRecoveryTests: XCTestCase {
    func testConcurrentStaleRequestReportsActiveSwitchAndForcedUnloadEventuallyClearsGuard() async throws {
        let root = try makeTemporaryDirectory(named: "ForcedUnloadRecovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("Blocked.swift")
        try "blocked".write(to: fileURL, atomically: true, encoding: .utf8)

        let clock = WorkspaceSwitchTestClock(now: Date(timeIntervalSince1970: 1000))
        let unloadSleeper = WorkspaceSwitchManualSleeper()
        let store = WorkspaceFileContextStore(
            unloadTerminationPolicy: WorkspaceRootUnloadTerminationPolicy(
                publisherIngressGraceNanoseconds: 11,
                watcherStopGraceNanoseconds: 22,
                sleep: { nanoseconds in await unloadSleeper.sleep(nanoseconds: nanoseconds) }
            )
        )
        let composition = makeComposition(
            store: store,
            timingPolicy: WorkspaceSwitchTimingPolicy(
                staleThreshold: 30,
                chatBusySettleTimeoutNanoseconds: 20,
                chatBusyPollIntervalNanoseconds: 20,
                now: { clock.now() },
                sleep: { _ in }
            )
        )
        let manager = composition.workspaceManager
        await manager.awaitInitialized()

        let source = manager.createWorkspace(
            name: "Recovery Source \(UUID().uuidString.prefix(8))",
            repoPaths: [root.path],
            ephemeral: true
        )
        let sourceResult = await manager.switchWorkspace(
            to: source,
            saveState: false,
            reason: "workspaceSwitchRecoverySource"
        )
        XCTAssertTrue(sourceResult.didSwitch)

        let loadedRoots = await store.roots()
        let matchingRoots = loadedRoots.filter { $0.standardizedFullPath == root.path }
        let loadedRoot = try XCTUnwrap(matchingRoots.first)
        try await store.startWatchingRoot(id: loadedRoot.id)
        let sinkGate = WorkspaceSwitchRecoveryGate()
        await store.setWatcherSinkWillApplyHandler { observedRootID in
            guard observedRootID == loadedRoot.id else { return }
            await sinkGate.arriveAndWait()
        }
        try await store.publishSyntheticFileSystemDeltasForTesting(
            rootID: loadedRoot.id,
            deltas: [.fileModified("Blocked.swift", nil)]
        )
        await sinkGate.waitUntilArrived()

        let target = manager.createWorkspace(
            name: "Recovery Target \(UUID().uuidString.prefix(8))",
            repoPaths: [],
            ephemeral: true
        )
        let firstSwitch = Task { @MainActor in
            await manager.requestWorkspaceSwitch(
                to: target,
                saveState: true,
                reason: "forcedUnloadRecovery"
            )
        }

        try await waitUntil {
            manager.activeWorkspaceSwitch?.phase == .unloadingRoots
        }
        await unloadSleeper.waitUntilSleeping(nanoseconds: 11)
        clock.advance(by: 31)

        let repeatedResult = await manager.requestWorkspaceSwitch(
            to: target,
            saveState: true,
            reason: "repeatedRequest"
        )
        let blockage = try XCTUnwrap(manager.lastWorkspaceSwitchBlockageReport)
        XCTAssertEqual(blockage.activeSwitch.targetWorkspaceID, target.id)
        XCTAssertEqual(blockage.activeSwitch.targetWorkspaceName, target.name)
        XCTAssertEqual(blockage.activeSwitch.reason, "forcedUnloadRecovery")
        XCTAssertEqual(blockage.activeSwitch.phase, .unloadingRoots)
        XCTAssertEqual(blockage.totalAge, 31, accuracy: 0.001)
        XCTAssertEqual(blockage.phaseAge, 31, accuracy: 0.001)
        XCTAssertTrue(blockage.isStale)
        guard case let .blocked(repeatedMessage) = repeatedResult else {
            return XCTFail("Expected repeated request to be blocked")
        }
        XCTAssertEqual(repeatedMessage, blockage.message)
        XCTAssertTrue(repeatedMessage.contains(target.name))
        XCTAssertTrue(repeatedMessage.contains("unloading roots"))
        XCTAssertTrue(repeatedMessage.contains("stale"))
        XCTAssertEqual(manager.pendingWorkspaceSwitchBlockedNotice?.message, repeatedMessage)

        await unloadSleeper.release(nanoseconds: 11)
        let firstResult = await firstSwitch.value
        XCTAssertTrue(firstResult.didSwitch)
        XCTAssertEqual(manager.activeWorkspaceID, target.id)
        XCTAssertFalse(manager.isSwitchingWorkspace)
        XCTAssertNil(manager.activeWorkspaceSwitch)

        await sinkGate.release()
        await sinkGate.waitUntilCompleted()
        XCTAssertEqual(manager.activeWorkspaceID, target.id)
        XCTAssertFalse(manager.isSwitchingWorkspace)
        XCTAssertNil(manager.activeWorkspaceSwitch)
        await store.setWatcherSinkWillApplyHandler(nil)
    }

    func testBusyStateThatPersistsAfterSessionCancellationReturnsExplicitBlockageWithoutStartingSwitch() async throws {
        let clock = WorkspaceSwitchTestClock(now: Date(timeIntervalSince1970: 2000))
        let settleSleeper = WorkspaceSwitchManualSleeper()
        let composition = makeComposition(
            timingPolicy: WorkspaceSwitchTimingPolicy(
                staleThreshold: 30,
                chatBusySettleTimeoutNanoseconds: 22,
                chatBusyPollIntervalNanoseconds: 22,
                now: { clock.now() },
                sleep: { nanoseconds in
                    await settleSleeper.sleep(nanoseconds: nanoseconds)
                    try Task.checkCancellation()
                }
            )
        )
        let manager = composition.workspaceManager
        await manager.awaitInitialized()
        let previousWorkspaceID = manager.activeWorkspaceID
        let provider = StickyBusyWorkspaceSwitchSessionProvider(workspaceManager: manager)
        manager.registerSwitchSessionProvider(provider)
        manager.isChatBusy = true

        let target = manager.createWorkspace(
            name: "Busy Target \(UUID().uuidString.prefix(8))",
            repoPaths: [],
            ephemeral: true
        )
        let request = Task { @MainActor in
            await manager.requestWorkspaceSwitch(to: target, reason: "busySettle")
        }
        try await waitUntil { manager.pendingSwitchConfirmation != nil }
        let confirmationID = try XCTUnwrap(manager.pendingSwitchConfirmation?.id)
        manager.resolveSwitchConfirmation(id: confirmationID, allow: true)
        await settleSleeper.waitUntilSleeping(nanoseconds: 22)
        XCTAssertEqual(manager.activeWorkspaceSwitch?.phase, .waitingForChatIdle)

        clock.advance(by: 2)
        await settleSleeper.release(nanoseconds: 22)
        let result = await request.value

        guard case let .blocked(message) = result else {
            return XCTFail("Expected persistent busy state to block the switch")
        }
        XCTAssertTrue(message.contains("isChatBusy remained true"))
        XCTAssertTrue(message.contains("1 sticky session"))
        XCTAssertEqual(manager.activeWorkspaceID, previousWorkspaceID)
        XCTAssertFalse(manager.isSwitchingWorkspace)
        XCTAssertNil(manager.activeWorkspaceSwitch)
        let report = try XCTUnwrap(manager.lastWorkspaceSwitchBlockageReport)
        XCTAssertEqual(report.activeSwitch.targetWorkspaceID, target.id)
        XCTAssertEqual(report.activeSwitch.phase, .waitingForChatIdle)
        XCTAssertEqual(provider.cancelCount(), 1)
        XCTAssertEqual(manager.pendingWorkspaceSwitchBlockedNotice?.message, message)
    }

    func testConfirmationCancellationClearsOnlyOwnedContinuation() async throws {
        let composition = makeComposition()
        let manager = composition.workspaceManager
        await manager.awaitInitialized()
        let provider = StaticWorkspaceSwitchSessionProvider()
        manager.registerSwitchSessionProvider(provider)

        let firstTarget = manager.createWorkspace(
            name: "First Confirmation Target \(UUID().uuidString.prefix(8))",
            repoPaths: [],
            ephemeral: true
        )
        let firstRequest = Task { @MainActor in
            await manager.requestWorkspaceSwitch(to: firstTarget, reason: "firstConfirmation")
        }
        try await waitUntil { manager.pendingSwitchConfirmation != nil }
        let firstConfirmationID = try XCTUnwrap(manager.pendingSwitchConfirmation?.id)
        firstRequest.cancel()
        let firstResult = await firstRequest.value
        guard case .cancelled = firstResult else {
            return XCTFail("Expected cancellation while awaiting confirmation")
        }
        XCTAssertNil(manager.pendingSwitchConfirmation)
        XCTAssertFalse(manager.hasPendingSwitchConfirmation)
        XCTAssertFalse(manager.isSwitchingWorkspace)

        let secondTarget = manager.createWorkspace(
            name: "Second Confirmation Target \(UUID().uuidString.prefix(8))",
            repoPaths: [],
            ephemeral: true
        )
        let secondRequest = Task { @MainActor in
            await manager.requestWorkspaceSwitch(to: secondTarget, reason: "secondConfirmation")
        }
        try await waitUntil { manager.pendingSwitchConfirmation != nil }
        let secondConfirmationID = try XCTUnwrap(manager.pendingSwitchConfirmation?.id)
        XCTAssertNotEqual(secondConfirmationID, firstConfirmationID)

        manager.resolveSwitchConfirmation(id: firstConfirmationID, allow: true)
        XCTAssertEqual(manager.pendingSwitchConfirmation?.id, secondConfirmationID)
        XCTAssertTrue(manager.hasPendingSwitchConfirmation)

        manager.resolveSwitchConfirmation(id: secondConfirmationID, allow: false)
        let secondResult = await secondRequest.value
        guard case .cancelled = secondResult else {
            return XCTFail("Expected the owned confirmation to cancel the request")
        }
        XCTAssertNil(manager.pendingSwitchConfirmation)
        XCTAssertFalse(manager.hasPendingSwitchConfirmation)
    }

    func testExplicitSwitchCancellationResolvesOwnedConfirmation() async throws {
        let composition = makeComposition()
        let manager = composition.workspaceManager
        await manager.awaitInitialized()
        manager.registerSwitchSessionProvider(StaticWorkspaceSwitchSessionProvider())

        let target = manager.createWorkspace(
            name: "Explicit Cancellation Target \(UUID().uuidString.prefix(8))",
            repoPaths: [],
            ephemeral: true
        )
        let request = Task { @MainActor in
            await manager.requestWorkspaceSwitch(to: target, reason: "explicitConfirmationCancellation")
        }
        try await waitUntil {
            manager.activeWorkspaceSwitch?.phase == .awaitingConfirmation
                && manager.pendingSwitchConfirmation != nil
        }

        await manager.cancelCurrentWorkspaceSwitchAndReturnToSystem()
        let result = await request.value

        guard case .cancelled = result else {
            return XCTFail("Expected explicit switch cancellation to cancel the confirmation request")
        }
        XCTAssertNil(manager.pendingSwitchConfirmation)
        XCTAssertFalse(manager.hasPendingSwitchConfirmation)
        XCTAssertFalse(manager.isSwitchingWorkspace)
        XCTAssertNil(manager.activeWorkspaceSwitch)
    }

    func testSaveAndExitReturnsExactRequestResult() async {
        let composition = makeComposition()
        let manager = composition.workspaceManager
        await manager.awaitInitialized()
        let activeName = manager.activeWorkspace?.name ?? ""

        let result = await manager.saveAndExitToFallback()

        guard case let .blocked(message) = result else {
            return XCTFail("Expected save-and-exit on the fallback workspace to return request blockage")
        }
        XCTAssertEqual(message, "Already on workspace \"\(activeName)\".")
        XCTAssertNil(
            manager.pendingWorkspaceSwitchBlockedNotice,
            "Save-and-exit while already on the fallback workspace is a benign no-op and must stay silent"
        )
    }

    func testCancellationRequestedBySwitchListenerAfterNotificationReturnsSwitched() async {
        let composition = makeComposition()
        let manager = composition.workspaceManager
        await manager.awaitInitialized()
        let target = manager.createWorkspace(
            name: "Listener Commit Target \(UUID().uuidString.prefix(8))",
            repoPaths: [],
            ephemeral: true
        )
        let taskBox = WorkspaceSwitchTaskBox()
        manager.addWorkspaceDidSwitchListener(label: "cancel-after-notification") { workspace in
            guard workspace?.id == target.id else { return }
            taskBox.task?.cancel()
        }

        let request = Task { @MainActor in
            await manager.requestWorkspaceSwitch(
                to: target,
                saveState: false,
                reason: "listenerCommitBoundary"
            )
        }
        taskBox.task = request
        let result = await request.value

        XCTAssertEqual(result, .switched)
        XCTAssertEqual(manager.activeWorkspaceID, target.id)
        XCTAssertFalse(manager.isSwitchingWorkspace)
    }

    func testCancellationAfterUnloadRetainsOwnershipUntilFallbackRecoveryCompletes() async throws {
        let root = try makeTemporaryDirectory(named: "OwnedFallbackRecovery")
        defer { try? FileManager.default.removeItem(at: root) }
        try "source".write(
            to: root.appendingPathComponent("Source.swift"),
            atomically: true,
            encoding: .utf8
        )

        let sleeper = WorkspaceSwitchManualSleeper()
        let store = WorkspaceFileContextStore(
            unloadTerminationPolicy: WorkspaceRootUnloadTerminationPolicy(
                publisherIngressGraceNanoseconds: 11,
                watcherStopGraceNanoseconds: 22,
                sleep: { nanoseconds in await sleeper.sleep(nanoseconds: nanoseconds) }
            )
        )
        let composition = makeComposition(store: store)
        let manager = composition.workspaceManager
        await manager.awaitInitialized()
        let fallbackID = try XCTUnwrap(manager.activeWorkspaceID)

        let source = manager.createWorkspace(
            name: "Owned Recovery Source \(UUID().uuidString.prefix(8))",
            repoPaths: [root.path],
            ephemeral: true
        )
        let sourceSwitchResult = await manager.switchWorkspace(to: source, saveState: false)
        XCTAssertTrue(sourceSwitchResult.didSwitch)
        let loadedRoots = await store.roots()
        let loadedRoot = try XCTUnwrap(loadedRoots.first)
        try await store.startWatchingRoot(id: loadedRoot.id)

        let watcherStopGate = WorkspaceSwitchRecoveryGate()
        await store.setWatcherStopWillBeginHandler { observedRootID in
            guard observedRootID == loadedRoot.id else { return }
            await watcherStopGate.arriveAndWait()
        }
        let recoveryGate = WorkspaceSwitchRecoveryGate()
        manager.setWorkspaceSwitchRecoveryWillBeginHandlerForTesting {
            await recoveryGate.arriveAndWait()
        }

        let target = manager.createWorkspace(
            name: "Owned Recovery Target \(UUID().uuidString.prefix(8))",
            repoPaths: [],
            ephemeral: true
        )
        let competingTarget = manager.createWorkspace(
            name: "Owned Recovery Competitor \(UUID().uuidString.prefix(8))",
            repoPaths: [],
            ephemeral: true
        )
        let request = Task { @MainActor in
            await manager.requestWorkspaceSwitch(
                to: target,
                saveState: true,
                reason: "ownedFallbackRecovery"
            )
        }
        try await waitUntil { manager.activeWorkspaceSwitch?.phase == .unloadingRoots }
        let operationID = try XCTUnwrap(manager.activeWorkspaceSwitch?.operationID)
        await watcherStopGate.waitUntilArrived()
        await sleeper.waitUntilSleeping(nanoseconds: 22)

        await manager.cancelCurrentWorkspaceSwitchAndReturnToSystem()
        await sleeper.release(nanoseconds: 22)
        await recoveryGate.waitUntilArrived()

        XCTAssertTrue(manager.isSwitchingWorkspace)
        XCTAssertEqual(manager.activeWorkspaceSwitch?.operationID, operationID)
        let competingResult = await manager.requestWorkspaceSwitch(
            to: competingTarget,
            saveState: false,
            reason: "competingDuringRecovery"
        )
        guard case .blocked = competingResult else {
            return XCTFail("Expected recovery ownership to block a newer switch")
        }

        await recoveryGate.release()
        let result = await request.value
        guard case .cancelled = result else {
            return XCTFail("Expected the original pre-commit request to report cancellation after recovery")
        }
        XCTAssertEqual(manager.activeWorkspaceID, fallbackID)
        XCTAssertFalse(manager.isSwitchingWorkspace)
        XCTAssertNil(manager.activeWorkspaceSwitch)

        await watcherStopGate.release()
        manager.setWorkspaceSwitchRecoveryWillBeginHandlerForTesting(nil)
        await store.setWatcherStopWillBeginHandler(nil)
    }

    func testSameIDReloadCancellationAfterUnloadRecoversToFallback() async throws {
        let rootA = try makeTemporaryDirectory(named: "SameIDCancelRootA")
        let rootB = try makeTemporaryDirectory(named: "SameIDCancelRootB")
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        try "a".write(to: rootA.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        try "b".write(to: rootB.appendingPathComponent("B.swift"), atomically: true, encoding: .utf8)

        let store = WorkspaceFileContextStore()
        let composition = makeComposition(store: store)
        let manager = composition.workspaceManager
        await manager.awaitInitialized()
        let fallbackID = try XCTUnwrap(manager.activeWorkspaceID)
        let active = manager.createWorkspace(
            name: "Same ID Cancellation \(UUID().uuidString.prefix(8))",
            repoPaths: [rootA.path],
            ephemeral: true
        )
        let activationResult = await manager.switchWorkspace(to: active, saveState: false)
        XCTAssertTrue(activationResult.didSwitch)

        var replacement = active
        replacement.repoPaths = [rootB.path]
        let replacementIndex = try XCTUnwrap(manager.workspaces.firstIndex(where: { $0.id == active.id }))
        manager.workspaces[replacementIndex] = replacement

        let unloadGate = WorkspaceSwitchRecoveryGate()
        await store.setRootUnloadDidDetachHandler { paths in
            guard paths.contains(rootA.path) else { return }
            await unloadGate.arriveAndWait()
        }
        let request = Task { @MainActor in
            await manager.reactivateWorkspaceAfterReplacement(
                replacement,
                reason: "sameIDCancellationAfterUnload"
            )
        }
        await unloadGate.waitUntilArrived()
        _ = try XCTUnwrap(manager.activeWorkspaceSwitch?.operationID)

        request.cancel()
        await unloadGate.release()
        let result = await request.value

        guard case .cancelled = result else {
            return XCTFail("Expected same-ID reload cancellation to remain the caller-visible result")
        }
        XCTAssertEqual(manager.activeWorkspaceID, fallbackID)
        XCTAssertFalse(manager.isSwitchingWorkspace)
        XCTAssertNil(manager.activeWorkspaceSwitch)
        let roots = await store.roots()
        XCTAssertTrue(roots.isEmpty)
        await store.setRootUnloadDidDetachHandler(nil)
    }

    func testMissingTargetAfterUnloadRecoversPreviousWorkspaceBeforeReturningBlocked() async throws {
        let root = try makeTemporaryDirectory(named: "BlockedAfterUnloadSource")
        defer { try? FileManager.default.removeItem(at: root) }
        try "source".write(
            to: root.appendingPathComponent("Source.swift"),
            atomically: true,
            encoding: .utf8
        )

        let store = WorkspaceFileContextStore()
        let composition = makeComposition(store: store)
        let manager = composition.workspaceManager
        await manager.awaitInitialized()
        let source = manager.createWorkspace(
            name: "Blocked Recovery Source \(UUID().uuidString.prefix(8))",
            repoPaths: [root.path],
            ephemeral: true
        )
        let sourceActivationResult = await manager.switchWorkspace(to: source, saveState: false)
        XCTAssertTrue(sourceActivationResult.didSwitch)

        let missingTarget = WorkspaceModel(
            name: "Missing Recovery Target \(UUID().uuidString.prefix(8))",
            repoPaths: [],
            ephemeralFlag: true
        )
        let result = await manager.switchWorkspace(
            to: missingTarget,
            saveState: true,
            reason: "missingTargetAfterUnload"
        )

        guard case let .blocked(message) = result else {
            return XCTFail("Expected missing target to remain blocked after recovery")
        }
        XCTAssertTrue(message.contains("workspace file is missing"))
        XCTAssertEqual(manager.activeWorkspaceID, source.id)
        XCTAssertFalse(manager.isSwitchingWorkspace)
        XCTAssertNil(manager.activeWorkspaceSwitch)
        let roots = await store.roots()
        XCTAssertEqual(roots.map(\.standardizedFullPath), [root.standardizedFileURL.path])
    }

    func testSuccessfulOwningSwitchClearsItsConcurrentBlockedNotice() async throws {
        let root = try makeTemporaryDirectory(named: "OwningNoticeSource")
        defer { try? FileManager.default.removeItem(at: root) }
        try "source".write(
            to: root.appendingPathComponent("Source.swift"),
            atomically: true,
            encoding: .utf8
        )

        let store = WorkspaceFileContextStore()
        let composition = makeComposition(store: store)
        let manager = composition.workspaceManager
        await manager.awaitInitialized()
        let source = manager.createWorkspace(
            name: "Owning Notice Source \(UUID().uuidString.prefix(8))",
            repoPaths: [root.path],
            ephemeral: true
        )
        let sourceActivationResult = await manager.switchWorkspace(to: source, saveState: false)
        XCTAssertTrue(sourceActivationResult.didSwitch)

        let unloadGate = WorkspaceSwitchRecoveryGate()
        await store.setRootUnloadDidDetachHandler { paths in
            guard paths.contains(root.path) else { return }
            await unloadGate.arriveAndWait()
        }
        let target = manager.createWorkspace(
            name: "Owning Notice Target \(UUID().uuidString.prefix(8))",
            repoPaths: [],
            ephemeral: true
        )
        let owner = Task { @MainActor in
            await manager.requestWorkspaceSwitch(
                to: target,
                saveState: true,
                reason: "owningNoticeSwitch"
            )
        }
        await unloadGate.waitUntilArrived()
        let owningOperationID = try XCTUnwrap(manager.activeWorkspaceSwitch?.operationID)

        let repeated = await manager.requestWorkspaceSwitch(
            to: target,
            saveState: false,
            reason: "blockedByOwningNoticeSwitch"
        )
        guard case .blocked = repeated else {
            return XCTFail("Expected repeated request to publish a blocked notice")
        }
        let relatedNotice = try XCTUnwrap(manager.pendingWorkspaceSwitchBlockedNotice)
        XCTAssertEqual(relatedNotice.blockingOperationID, owningOperationID)

        await unloadGate.release()
        let ownerResult = await owner.value
        XCTAssertEqual(ownerResult, .switched)
        XCTAssertNil(manager.pendingWorkspaceSwitchBlockedNotice)
        await store.setRootUnloadDidDetachHandler(nil)
    }

    func testReactivatingReplacedActiveWorkspaceReloadsSameIDRoots() async throws {
        let rootA = try makeTemporaryDirectory(named: "SameIDRootA")
        let rootB = try makeTemporaryDirectory(named: "SameIDRootB")
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        try "a".write(to: rootA.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        try "b".write(to: rootB.appendingPathComponent("B.swift"), atomically: true, encoding: .utf8)

        let store = WorkspaceFileContextStore()
        let composition = makeComposition(store: store)
        let manager = composition.workspaceManager
        await manager.awaitInitialized()
        let active = manager.createWorkspace(
            name: "Same ID Reload \(UUID().uuidString.prefix(8))",
            repoPaths: [rootA.path],
            ephemeral: true
        )
        let activationResult = await manager.switchWorkspace(to: active, saveState: false)
        XCTAssertTrue(activationResult.didSwitch)

        var replacement = active
        replacement.repoPaths = [rootB.path]
        let replacementIndex = try XCTUnwrap(manager.workspaces.firstIndex(where: { $0.id == active.id }))
        manager.workspaces[replacementIndex] = replacement

        let result = await manager.reactivateWorkspaceAfterReplacement(replacement)
        XCTAssertEqual(result, .switched)
        XCTAssertEqual(manager.activeWorkspaceID, replacement.id)
        let roots = await store.roots()
        XCTAssertEqual(roots.map(\.standardizedFullPath), [rootB.standardizedFileURL.path])
    }

    func testSwitchingFromAThroughDefaultAndBBackToAPreservesHydratedSelection() async throws {
        let root = try makeTemporaryDirectory(named: "SelectionReplaySwitchRoot")
        let storage = try makeTemporaryDirectory(named: "SelectionReplaySwitchStorage")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: storage)
        }
        let fixture = try makeSelectionFixture(root: root, workspaceName: "Selection Replay A", storageDirectory: storage)
        try writeWorkspace(fixture.workspace, to: storage.appendingPathComponent("workspace.json"))

        let composition = makeComposition()
        let manager = composition.workspaceManager
        await manager.awaitInitialized()
        manager.workspaces.append(fixture.workspace)

        let initialResult = await manager.switchWorkspace(to: fixture.workspace, saveState: false)
        XCTAssertTrue(initialResult.didSwitch)
        assertSelectionFixture(fixture, composition: composition)

        let defaultWorkspace = try XCTUnwrap(manager.workspaces.first(where: { $0.isSystemWorkspace || $0.name == "Default" }))
        let defaultResult = await manager.switchWorkspace(to: defaultWorkspace, saveState: false)
        XCTAssertTrue(defaultResult.didSwitch)
        let returnFromDefaultResult = await manager.switchWorkspace(to: fixture.workspace, saveState: false)
        XCTAssertTrue(returnFromDefaultResult.didSwitch)
        assertSelectionFixture(fixture, composition: composition)

        let workspaceB = manager.createWorkspace(
            name: "Selection Replay B \(UUID().uuidString.prefix(8))",
            repoPaths: [],
            ephemeral: true
        )
        let workspaceBResult = await manager.switchWorkspace(to: workspaceB, saveState: false)
        XCTAssertTrue(workspaceBResult.didSwitch)
        let returnFromBResult = await manager.switchWorkspace(to: fixture.workspace, saveState: false)
        XCTAssertTrue(returnFromBResult.didSwitch)
        assertSelectionFixture(fixture, composition: composition)

        try await Task.sleep(nanoseconds: 250_000_000)
        await manager.pollAndSaveStateAsync()
        let workspaceURL = manager.workspaceFileURL(for: fixture.workspace)
        let saved = try WorkspaceManagerViewModel.loadWorkspaceFromFile(at: workspaceURL)
        let savedTab = try XCTUnwrap(saved.composeTabs.first(where: { $0.id == fixture.tabID }))
        XCTAssertFalse(savedTab.selection.selectedPaths.isEmpty)
        XCTAssertEqual(savedTab.selection, fixture.selection)
    }

    func testInitialDiskBackedActivationAndReopenPreserveHydratedSelection() async throws {
        let root = try makeTemporaryDirectory(named: "InitialSelectionReplayRoot")
        let storageRoot = try makeTemporaryDirectory(named: "InitialSelectionReplayStorage")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: storageRoot)
        }
        let fixture = try makeSelectionFixture(root: root, workspaceName: "Default")
        try writeIndexedWorkspace(fixture.workspace, baseRoot: storageRoot)

        for _ in 0 ..< 2 {
            let composition = makeComposition(storageRoot: storageRoot)
            let manager = composition.workspaceManager
            await manager.awaitInitialized()

            XCTAssertEqual(manager.activeWorkspaceID, fixture.workspace.id)
            assertSelectionFixture(fixture, composition: composition)

            try await Task.sleep(nanoseconds: 250_000_000)
            await manager.pollAndSaveStateAsync()
            let workspaceURL = manager.workspaceFileURL(for: fixture.workspace)
            let saved = try WorkspaceManagerViewModel.loadWorkspaceFromFile(at: workspaceURL)
            let savedTab = try XCTUnwrap(saved.composeTabs.first(where: { $0.id == fixture.tabID }))
            XCTAssertFalse(savedTab.selection.selectedPaths.isEmpty)
            XCTAssertEqual(savedTab.selection, fixture.selection)
        }
    }

    func testRestoreActivationPreservesAgentCanonicalSelectionFromBlankTransientUI() async throws {
        let root = try makeTemporaryDirectory(named: "AgentSelectionRestoreRoot")
        let storage = try makeTemporaryDirectory(named: "AgentSelectionRestoreStorage")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: storage)
        }

        let versionFile = root.appendingPathComponent("version.env")
        let bootstrapLease = root.appendingPathComponent(
            "Sources/RepoPrompt/Infrastructure/MCP/MCPBootstrapLease.swift"
        )
        try FileManager.default.createDirectory(
            at: bootstrapLease.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "VERSION=1\n".write(to: versionFile, atomically: true, encoding: .utf8)
        try "struct MCPBootstrapLease {}\n".write(
            to: bootstrapLease,
            atomically: true,
            encoding: .utf8
        )

        let tabID = UUID()
        let selection = StoredSelection(
            selectedPaths: [versionFile.path, bootstrapLease.path],
            codemapAutoEnabled: false
        )
        let tab = ComposeTabState(
            id: tabID,
            name: "Persisted Agent",
            activeAgentSessionID: UUID(),
            selection: selection
        )
        let workspace = WorkspaceModel(
            name: "Agent Selection Restore",
            repoPaths: [root.path],
            customStoragePath: storage,
            composeTabs: [tab],
            activeComposeTabID: tabID
        )
        try writeWorkspace(workspace, to: storage.appendingPathComponent("workspace.json"))

        let composition = makeComposition()
        let manager = composition.workspaceManager
        await manager.awaitInitialized()
        manager.workspaces.append(workspace)

        var injectedBlankSnapshot = false
        manager.setWorkspaceSwitchPhaseDidChangeHandlerForTesting { phase in
            guard phase == .hydratingRoots, !injectedBlankSnapshot else { return }
            injectedBlankSnapshot = true
            XCTAssertTrue(composition.workspaceFilesViewModel.snapshotSelection().selectedPaths.isEmpty)
            manager.publishActiveComposeTabSnapshot(commitToMemory: true)
        }
        let result = await manager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "agentSelectionRestoreRace"
        )
        manager.setWorkspaceSwitchPhaseDidChangeHandlerForTesting(nil)

        XCTAssertEqual(result, .switched)
        XCTAssertTrue(injectedBlankSnapshot)
        XCTAssertEqual(manager.composeTab(with: tabID)?.selection, selection)
        XCTAssertEqual(
            Set(composition.workspaceFilesViewModel.snapshotSelection().selectedPaths),
            Set(selection.selectedPaths)
        )
        let routingSnapshot = try XCTUnwrap(
            manager.resolveComposeTabRoutingSnapshot(
                for: tabID,
                captureActiveUIState: false
            )
        )
        XCTAssertFalse(routingSnapshot.usesLiveUIState)
        XCTAssertEqual(
            Set(routingSnapshot.snapshot.selection.selectedPaths),
            Set(selection.selectedPaths)
        )

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(
            try Set(XCTUnwrap(manager.composeTab(with: tabID)).selection.selectedPaths),
            Set(selection.selectedPaths)
        )

        manager.markWorkspaceDirty()
        await manager.pollAndSaveStateAsync()
        let saved = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
            at: manager.workspaceFileURL(for: workspace)
        )
        XCTAssertEqual(
            try Set(XCTUnwrap(saved.composeTabs.first(where: { $0.id == tabID })).selection.selectedPaths),
            Set(selection.selectedPaths)
        )
    }

    func testPostHydrationReplayPreservesNewerCanonicalSelection() async throws {
        let root = try makeTemporaryDirectory(named: "NewerCanonicalSelectionRoot")
        defer { try? FileManager.default.removeItem(at: root) }

        let originalFile = root.appendingPathComponent("Original.swift")
        let newerFile = root.appendingPathComponent("Newer.swift")
        try "let original = true\n".write(to: originalFile, atomically: true, encoding: .utf8)
        try "let newer = true\n".write(to: newerFile, atomically: true, encoding: .utf8)

        let tabID = UUID()
        let originalSelection = StoredSelection(
            selectedPaths: [originalFile.path],
            codemapAutoEnabled: false
        )
        let newerSelection = StoredSelection(
            selectedPaths: [newerFile.path],
            codemapAutoEnabled: false
        )
        let workspace = WorkspaceModel(
            name: "Newer Canonical Selection",
            repoPaths: [root.path],
            ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: tabID, selection: originalSelection)],
            activeComposeTabID: tabID
        )

        let composition = makeComposition()
        let manager = composition.workspaceManager
        await manager.awaitInitialized()
        manager.workspaces.append(workspace)

        var updatedCanonicalSelection = false
        manager.setWorkspaceSwitchPhaseDidChangeHandlerForTesting { phase in
            guard phase == .hydratingRoots, !updatedCanonicalSelection else { return }
            updatedCanonicalSelection = true
            guard var updatedTab = manager.composeTab(with: tabID) else {
                return XCTFail("Expected active compose tab during hydration")
            }
            updatedTab.selection = newerSelection
            XCTAssertTrue(manager.updateComposeTabStoredOnly(updatedTab, inWorkspaceID: workspace.id))
        }
        let result = await manager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "newerCanonicalSelectionDuringHydration"
        )
        manager.setWorkspaceSwitchPhaseDidChangeHandlerForTesting(nil)

        XCTAssertEqual(result, .switched)
        XCTAssertTrue(updatedCanonicalSelection)
        XCTAssertEqual(manager.composeTab(with: tabID)?.selection, newerSelection)
        XCTAssertEqual(composition.workspaceFilesViewModel.snapshotSelection(), newerSelection)
    }

    func testWatcherActivationFailureDegradesWorkspaceReadiness() async throws {
        let root = try makeTemporaryDirectory(named: "WatcherActivationFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        try "let activationFailure = true\n".write(
            to: root.appendingPathComponent("Activation.swift"),
            atomically: true,
            encoding: .utf8
        )

        let store = WorkspaceFileContextStore()
        await store.setWatcherActivationFailureForNewServicesForTesting(.streamStart)
        let composition = makeComposition(store: store)
        let manager = composition.workspaceManager
        await manager.awaitInitialized()
        let target = manager.createWorkspace(
            name: "Watcher Activation Failure \(UUID().uuidString.prefix(8))",
            repoPaths: [root.path],
            ephemeral: true
        )

        let result = await manager.switchWorkspace(to: target, saveState: false)
        XCTAssertTrue(result.didSwitch)
        guard case let .degraded(workspaceID, _, _, _, failures, _) = manager.workspaceSearchReadinessState else {
            return XCTFail("Expected watcher activation failure to degrade workspace readiness")
        }
        XCTAssertEqual(workspaceID, target.id)
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.standardizedRootPath, root.path)
        XCTAssertTrue(failures.first?.errorDescription.contains("Failed to start FSEvent stream") == true)

        let roots = await store.roots()
        let loadedRoot = try XCTUnwrap(roots.first)
        let watcherIsActive = try await store.rootWatcherIsActiveForTesting(rootID: loadedRoot.id)
        XCTAssertFalse(watcherIsActive)
        await store.setWatcherActivationFailureForNewServicesForTesting(nil)
    }

    func testSessionCancellationAdvancesBackToPreparationBeforeSwitchCleanup() async throws {
        let composition = makeComposition()
        let manager = composition.workspaceManager
        await manager.awaitInitialized()
        let cancellationGate = WorkspaceSwitchRecoveryGate()
        manager.registerSwitchSessionProvider(GatedWorkspaceSwitchSessionProvider(gate: cancellationGate))
        var phases: [WorkspaceSwitchPhase] = []
        manager.setWorkspaceSwitchPhaseDidChangeHandlerForTesting { phases.append($0) }

        let target = manager.createWorkspace(
            name: "Phase Target \(UUID().uuidString.prefix(8))",
            repoPaths: [],
            ephemeral: true
        )
        let request = Task { @MainActor in
            await manager.requestWorkspaceSwitch(
                to: target,
                saveState: false,
                reason: "phaseAfterCancellation"
            )
        }
        try await waitUntil { manager.pendingSwitchConfirmation != nil }
        let confirmationID = try XCTUnwrap(manager.pendingSwitchConfirmation?.id)
        manager.resolveSwitchConfirmation(id: confirmationID, allow: true)
        await cancellationGate.waitUntilArrived()
        XCTAssertEqual(manager.activeWorkspaceSwitch?.phase, .cancellingSessions)
        await cancellationGate.release()

        let switchResult = await request.value
        XCTAssertEqual(switchResult, .switched)
        let cancellingIndex = try XCTUnwrap(phases.firstIndex(of: .cancellingSessions))
        XCTAssertGreaterThan(phases.count, cancellingIndex + 1)
        XCTAssertEqual(phases[cancellingIndex + 1], .preparing)
        manager.setWorkspaceSwitchPhaseDidChangeHandlerForTesting(nil)
    }

    func testWatcherActivationFailureStillHydratesSelectionSlicesAndSurfacesFailure() async throws {
        let root = try makeTemporaryDirectory(named: "WatcherFailureSliceHydration")
        defer { try? FileManager.default.removeItem(at: root) }
        try "one\ntwo\nthree\n".write(
            to: root.appendingPathComponent("Sliced.swift"),
            atomically: true,
            encoding: .utf8
        )

        let store = WorkspaceFileContextStore()
        await store.setWatcherActivationFailureForNewServicesForTesting(.streamStart)
        let composition = makeComposition(store: store)
        let manager = composition.workspaceManager
        await manager.awaitInitialized()

        let workspace = manager.createWorkspace(
            name: "Watcher Failure Slices \(UUID().uuidString.prefix(8))",
            repoPaths: [root.path],
            ephemeral: true
        )

        let seededRanges = [LineRange(start: 1, end: 2)]
        let seedScope = PartitionScope(workspaceID: workspace.id)
        let seedCoordinator = SelectionSliceCoordinator()
        try await seedCoordinator.applySliceUpdates(
            groupedByRootPath: [root.path: [SelectionSliceCoordinator.SliceUpdate(
                relativePath: "Sliced.swift",
                ranges: seededRanges,
                fileModificationTime: nil
            )]],
            scope: seedScope,
            mode: .set
        )
        addTeardownBlock {
            _ = try? await seedCoordinator.clearSlices(forRootPaths: [root.path], scope: seedScope)
        }

        let result = await manager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "watcherFailureSliceHydration"
        )
        XCTAssertTrue(result.didSwitch)

        try await waitUntil {
            if case let .degraded(_, _, _, _, failures, _) = manager.workspaceSearchReadinessState {
                return failures.contains { $0.rootPath == root.path }
            }
            return false
        }

        let hydratedSlices = composition.workspaceFilesViewModel.currentSlicesByRootForTesting()
        XCTAssertEqual(hydratedSlices[root.path]?["Sliced.swift"]?.ranges, seededRanges)
    }

    private func makeComposition(
        store: WorkspaceFileContextStore = WorkspaceFileContextStore(),
        timingPolicy: WorkspaceSwitchTimingPolicy = .production,
        storageRoot: URL? = nil
    ) -> WindowStateComposition {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        let defaults = UserDefaults.standard
        let previousStoragePath = defaults.string(forKey: "GlobalCustomStorageURL")
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        if let storageRoot {
            defaults.set(storageRoot.path, forKey: "GlobalCustomStorageURL")
        }
        defer {
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            if let previousStoragePath {
                defaults.set(previousStoragePath, forKey: "GlobalCustomStorageURL")
            } else {
                defaults.removeObject(forKey: "GlobalCustomStorageURL")
            }
        }
        return WindowStateCompositionFactory.make(
            windowID: -900 - Int.random(in: 1 ... 99),
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService(),
            workspaceFileContextStore: store,
            workspaceSwitchTimingPolicy: timingPolicy
        )
    }

    private struct SelectionFixture {
        let workspace: WorkspaceModel
        let tabID: UUID
        let selection: StoredSelection
    }

    private func makeSelectionFixture(
        root: URL,
        workspaceName: String,
        storageDirectory: URL? = nil
    ) throws -> SelectionFixture {
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let selected = sources.appendingPathComponent("Selected.swift")
        let dependency = sources.appendingPathComponent("Dependency.swift")
        try "one\ntwo\nthree\n".write(to: selected, atomically: true, encoding: .utf8)
        try "struct Dependency {}\n".write(to: dependency, atomically: true, encoding: .utf8)

        let selection = StoredSelection(
            selectedPaths: [selected.path],
            autoCodemapPaths: [dependency.path],
            codemapAutoEnabled: false
        )
        let tab = ComposeTabState(selection: selection)
        let workspace = WorkspaceModel(
            name: workspaceName,
            repoPaths: [root.path],
            customStoragePath: storageDirectory,
            composeTabs: [tab],
            activeComposeTabID: tab.id
        )
        return SelectionFixture(
            workspace: workspace,
            tabID: tab.id,
            selection: selection
        )
    }

    private func assertSelectionFixture(
        _ fixture: SelectionFixture,
        composition: WindowStateComposition,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = composition.workspaceFilesViewModel.snapshotSelection()
        XCTAssertEqual(actual.selectedPaths, fixture.selection.selectedPaths, file: file, line: line)
        XCTAssertEqual(actual.autoCodemapPaths, fixture.selection.autoCodemapPaths, file: file, line: line)
        XCTAssertEqual(actual.codemapAutoEnabled, fixture.selection.codemapAutoEnabled, file: file, line: line)
    }

    private func writeWorkspace(_ workspace: WorkspaceModel, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(workspace).write(to: url, options: .atomic)
    }

    private func writeIndexedWorkspace(_ workspace: WorkspaceModel, baseRoot: URL) throws {
        let workspaceDirectory = baseRoot.appendingPathComponent("Workspace-\(workspace.name)-\(workspace.id.uuidString)")
        try writeWorkspace(workspace, to: workspaceDirectory.appendingPathComponent("workspace.json"))
        let entry = WorkspaceIndexEntry(
            id: workspace.id,
            name: workspace.name,
            customStoragePath: workspace.customStoragePath,
            isSystemWorkspace: workspace.isSystemWorkspace,
            isHiddenInMenus: workspace.isHiddenInMenus
        )
        try JSONEncoder().encode([entry]).write(
            to: baseRoot.appendingPathComponent("workspacesIndex.json"),
            options: .atomic
        )
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSwitchRecoveryTests-\(UUID().uuidString)")
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

@MainActor
private final class StickyBusyWorkspaceSwitchSessionProvider: WorkspaceSwitchSessionProvider {
    private weak var workspaceManager: WorkspaceManagerViewModel?
    private var cancellations = 0

    init(workspaceManager: WorkspaceManagerViewModel) {
        self.workspaceManager = workspaceManager
    }

    func switchSessionItems() -> [WorkspaceSwitchSessionItem] {
        [WorkspaceSwitchSessionItem(
            id: "sticky",
            count: 1,
            singularLabel: "sticky session",
            pluralLabel: "sticky sessions"
        )]
    }

    func cancelSwitchSessions() async {
        cancellations += 1
        workspaceManager?.isChatBusy = true
    }

    func cancelCount() -> Int {
        cancellations
    }
}

@MainActor
private final class StaticWorkspaceSwitchSessionProvider: WorkspaceSwitchSessionProvider {
    func switchSessionItems() -> [WorkspaceSwitchSessionItem] {
        [WorkspaceSwitchSessionItem(
            id: "static",
            count: 1,
            singularLabel: "static session",
            pluralLabel: "static sessions"
        )]
    }

    func cancelSwitchSessions() async {}
}

@MainActor
private final class GatedWorkspaceSwitchSessionProvider: WorkspaceSwitchSessionProvider {
    private let gate: WorkspaceSwitchRecoveryGate

    init(gate: WorkspaceSwitchRecoveryGate) {
        self.gate = gate
    }

    func switchSessionItems() -> [WorkspaceSwitchSessionItem] {
        [WorkspaceSwitchSessionItem(
            id: "gated",
            count: 1,
            singularLabel: "gated session",
            pluralLabel: "gated sessions"
        )]
    }

    func cancelSwitchSessions() async {
        await gate.arriveAndWait()
    }
}

@MainActor
private final class WorkspaceSwitchTaskBox {
    var task: Task<WorkspaceSwitchResult, Never>?
}

private final class WorkspaceSwitchTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(now: Date) {
        value = now
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

private actor WorkspaceSwitchManualSleeper {
    private struct Waiter {
        let continuation: CheckedContinuation<Void, Never>
    }

    private var waitersByNanoseconds: [UInt64: [UUID: Waiter]] = [:]
    private var registrationWaitersByNanoseconds: [UInt64: [CheckedContinuation<Void, Never>]] = [:]
    private var releasedNanoseconds: Set<UInt64> = []
    private var cancelledWaiterIDs: Set<UUID> = []

    func sleep(nanoseconds: UInt64) async {
        if releasedNanoseconds.contains(nanoseconds) { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || cancelledWaiterIDs.remove(waiterID) != nil || releasedNanoseconds.contains(nanoseconds) {
                    continuation.resume()
                    return
                }
                waitersByNanoseconds[nanoseconds, default: [:]][waiterID] = Waiter(continuation: continuation)
                let registrationWaiters = registrationWaitersByNanoseconds.removeValue(forKey: nanoseconds) ?? []
                registrationWaiters.forEach { $0.resume() }
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID, nanoseconds: nanoseconds) }
        }
    }

    func waitUntilSleeping(nanoseconds: UInt64) async {
        guard waitersByNanoseconds[nanoseconds]?.isEmpty != false else { return }
        await withCheckedContinuation { continuation in
            registrationWaitersByNanoseconds[nanoseconds, default: []].append(continuation)
        }
    }

    func release(nanoseconds: UInt64) {
        releasedNanoseconds.insert(nanoseconds)
        let waiters = waitersByNanoseconds.removeValue(forKey: nanoseconds) ?? [:]
        waiters.values.forEach { $0.continuation.resume() }
        let registrationWaiters = registrationWaitersByNanoseconds.removeValue(forKey: nanoseconds) ?? []
        registrationWaiters.forEach { $0.resume() }
    }

    private func cancel(waiterID: UUID, nanoseconds: UInt64) {
        guard let waiter = waitersByNanoseconds[nanoseconds]?.removeValue(forKey: waiterID) else {
            cancelledWaiterIDs.insert(waiterID)
            return
        }
        if waitersByNanoseconds[nanoseconds]?.isEmpty == true {
            waitersByNanoseconds.removeValue(forKey: nanoseconds)
        }
        waiter.continuation.resume()
    }
}

private actor WorkspaceSwitchRecoveryGate {
    private var arrived = false
    private var completed = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var arrivalContinuations: [CheckedContinuation<Void, Never>] = []
    private var completionContinuations: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        arrived = true
        let continuations = arrivalContinuations
        arrivalContinuations.removeAll()
        continuations.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        completed = true
        let completionWaiters = completionContinuations
        completionContinuations.removeAll()
        completionWaiters.forEach { $0.resume() }
    }

    func waitUntilArrived() async {
        if arrived { return }
        await withCheckedContinuation { continuation in
            arrivalContinuations.append(continuation)
        }
    }

    func waitUntilCompleted() async {
        if completed { return }
        await withCheckedContinuation { continuation in
            completionContinuations.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
