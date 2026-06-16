import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class MCPToolAdmissionPolicyTests: XCTestCase {
    func testClassificationExhaustivelyCoversCanonicalCatalogWithoutDefault() {
        let canonicalTools = MCPToolExecutionContractCatalog.orderedAdvertisedToolNames
        XCTAssertEqual(canonicalTools.count, 26)
        XCTAssertEqual(Set(MCPToolAdmissionPolicy.classifications.keys), Set(canonicalTools))
        XCTAssertEqual(MCPToolAdmissionPolicy.classifications.count, canonicalTools.count)
        XCTAssertNil(MCPToolAdmissionPolicy.classification(forCanonicalToolName: "future_unreviewed_tool"))
        XCTAssertNil(ServerNetworkManager.callLane(forCanonicalToolName: "future_unreviewed_tool"))

        assertClass(.smallRead, tools: [
            MCPWindowToolName.getCodeStructure,
            MCPWindowToolName.getFileTree,
            MCPWindowToolName.readFile,
            MCPWindowToolName.oracleChatLog
        ])
        assertClass(.gitRead, tools: [MCPWindowToolName.git])
        assertClass(.fileSearch, tools: [MCPWindowToolName.search])
        assertClass(.control, tools: [
            MCPWindowToolName.oracleUtils,
            MCPWindowToolName.askOracle,
            MCPWindowToolName.oracleSend,
            MCPWindowToolName.contextBuilder,
            MCPWindowToolName.askUser,
            MCPWindowToolName.agentExplore,
            MCPWindowToolName.agentRun,
            MCPWindowToolName.agentManage,
            MCPWindowToolName.shareThoughts,
            MCPWindowToolName.setStatus,
            MCPWindowToolName.waitForNextInstruction
        ])
        assertClass(.exclusive, tools: [
            MCPGlobalToolName.appSettings,
            MCPGlobalToolName.bindContext,
            MCPGlobalToolName.manageWorkspaces,
            MCPWindowToolName.manageSelection,
            MCPWindowToolName.fileActions,
            MCPWindowToolName.workspaceContext,
            MCPWindowToolName.prompt,
            MCPWindowToolName.applyEdits,
            MCPWindowToolName.manageWorktree
        ])

        let alias = ServerNetworkManager.canonicalToolName(for: "discover_manage_selection")
        XCTAssertEqual(alias, MCPWindowToolName.manageSelection)
        XCTAssertEqual(ServerNetworkManager.admissionClass(forCanonicalToolName: alias), .exclusive)
    }

    func testGateBCapacitiesRecordConservativeWI3BaselineChoices() {
        XCTAssertEqual(MCPToolAdmissionPolicy.exclusiveConnectionLimit, 1)
        XCTAssertEqual(MCPToolAdmissionPolicy.controlConnectionLimit, 8)
        XCTAssertEqual(MCPToolAdmissionPolicy.smallReadConnectionLimit, 2)
        XCTAssertEqual(MCPToolAdmissionPolicy.smallReadPerWindowLimit, 2)
        XCTAssertEqual(MCPToolAdmissionPolicy.gitReadConnectionLimit, 2)
        XCTAssertEqual(MCPToolAdmissionPolicy.gitReadPerRepositoryLimit, 1)
        XCTAssertEqual(MCPToolAdmissionPolicy.fileSearchConnectionLimit, 4)
        XCTAssertEqual(ServerNetworkManager.smallReadCallLaneLimit, 2)
        XCTAssertEqual(ServerNetworkManager.controlCallLaneLimit, 8)
        XCTAssertEqual(ServerNetworkManager.gitReadCallLaneLimit, 2)
        XCTAssertEqual(ServerNetworkManager.fileSearchCallLaneLimit, 4)
    }

    func testSameConnectionSmallReadsOverlapAtBoundedCapacity() async throws {
        let manager = ServerNetworkManager()
        let connectionID = UUID()
        _ = await manager.debugInstallConnectionLimiterForTesting(connectionID: connectionID)
        let gate = AdmissionTestGate()

        let tasks = (0 ..< 2).map { _ in
            Task {
                try await manager.withConnectionCallPermitForTesting(
                    connectionID: connectionID,
                    lane: .smallRead
                ) {
                    await gate.enterAndWaitForRelease()
                }
            }
        }

        let didStartBothSmallReads = await waitUntil { await gate.startedCount() == 2 }
        XCTAssertTrue(didStartBothSmallReads)
        await gate.release()
        for task in tasks {
            try await task.value
        }
        await manager.debugRemoveConnection(connectionID)
    }

    func testSameConnectionExclusiveCallsRemainSerialized() async throws {
        let manager = ServerNetworkManager()
        let connectionID = UUID()
        _ = await manager.debugInstallConnectionLimiterForTesting(connectionID: connectionID)
        let gate = AdmissionTestGate()

        let first = Task {
            try await manager.withConnectionCallPermitForTesting(
                connectionID: connectionID,
                lane: .ordinary
            ) {
                await gate.enterAndWaitForRelease()
            }
        }
        let didStartFirstExclusive = await waitUntil { await gate.startedCount() == 1 }
        XCTAssertTrue(didStartFirstExclusive)

        let second = Task {
            try await manager.withConnectionCallPermitForTesting(
                connectionID: connectionID,
                lane: .ordinary
            ) {
                await gate.enterAndWaitForRelease()
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        let exclusiveCountWhileBlocked = await gate.startedCount()
        XCTAssertEqual(exclusiveCountWhileBlocked, 1)

        await gate.release()
        try await first.value
        try await second.value
        let finalExclusiveCount = await gate.startedCount()
        XCTAssertEqual(finalExclusiveCount, 2)
        await manager.debugRemoveConnection(connectionID)
    }

    func testSameConnectionControlAndExclusiveLanesOverlap() async throws {
        let manager = ServerNetworkManager()
        let connectionID = UUID()
        _ = await manager.debugInstallConnectionLimiterForTesting(connectionID: connectionID)
        let gate = AdmissionTestGate()

        let exclusive = Task {
            try await manager.withConnectionCallPermitForTesting(
                connectionID: connectionID,
                lane: .ordinary
            ) {
                await gate.enterAndWaitForRelease()
            }
        }
        let didStartExclusive = await waitUntil { await gate.startedCount() == 1 }
        XCTAssertTrue(didStartExclusive)

        let control = Task {
            try await manager.withConnectionCallPermitForTesting(
                connectionID: connectionID,
                lane: .control
            ) {
                await gate.enterAndWaitForRelease()
            }
        }

        let didStartControlWhileExclusiveHeld = await waitUntil { await gate.startedCount() == 2 }
        XCTAssertTrue(didStartControlWhileExclusiveHeld)

        await gate.release()
        try await exclusive.value
        try await control.value
        await manager.debugRemoveConnection(connectionID)
    }

    func testSameConnectionSmallReadAndGitReadLanesOverlap() async throws {
        let manager = ServerNetworkManager()
        let connectionID = UUID()
        _ = await manager.debugInstallConnectionLimiterForTesting(connectionID: connectionID)
        let gate = AdmissionTestGate()

        let smallRead = Task {
            try await manager.withConnectionCallPermitForTesting(
                connectionID: connectionID,
                lane: .smallRead
            ) {
                await gate.enterAndWaitForRelease()
            }
        }
        let gitRead = Task {
            try await manager.withConnectionCallPermitForTesting(
                connectionID: connectionID,
                lane: .gitRead
            ) {
                await gate.enterAndWaitForRelease()
            }
        }

        let didStartMixedLanes = await waitUntil { await gate.startedCount() == 2 }
        XCTAssertTrue(didStartMixedLanes)
        await gate.release()
        try await smallRead.value
        try await gitRead.value
        await manager.debugRemoveConnection(connectionID)
    }

    func testMutationAdmissionSerializesSameWindowButNotDistinctWindows() async throws {
        let controller = MCPToolResourceAdmissionController(limit: 1)
        let gate = AdmissionTestGate()

        let firstWindow = mutationTask(controller: controller, resource: .window(10), gate: gate)
        let didStartFirstWindow = await waitUntil { await gate.startedCount() == 1 }
        XCTAssertTrue(didStartFirstWindow)

        let sameWindow = mutationTask(controller: controller, resource: .window(10), gate: gate)
        let otherWindow = mutationTask(controller: controller, resource: .window(20), gate: gate)

        let didOverlapDistinctWindows = await waitUntil { await gate.startedCount() == 2 }
        XCTAssertTrue(didOverlapDistinctWindows)
        XCTAssertEqual(controller.waiterCount(for: .window(10)), 1)
        XCTAssertEqual(controller.activeCount(for: .window(10)), 1)
        XCTAssertEqual(controller.activeCount(for: .window(20)), 1)

        await gate.release()
        try await firstWindow.value
        try await sameWindow.value
        try await otherWindow.value
        let finalMutationCount = await gate.startedCount()
        XCTAssertEqual(finalMutationCount, 3)
        XCTAssertEqual(controller.activeCount(for: .window(10)), 0)
        XCTAssertEqual(controller.activeCount(for: .window(20)), 0)
    }

    func testSmallReadResourceAdmissionBoundsOneWindowAndOverlapsDistinctWindows() async throws {
        let controller = MCPToolResourceAdmissionController(
            limit: MCPToolAdmissionPolicy.smallReadPerWindowLimit
        )
        let gate = AdmissionTestGate()

        let first = mutationTask(controller: controller, resource: .window(30), gate: gate)
        let second = mutationTask(controller: controller, resource: .window(30), gate: gate)
        let didFillWindowCapacity = await waitUntil { await gate.startedCount() == 2 }
        XCTAssertTrue(didFillWindowCapacity)

        let queuedSameWindow = mutationTask(controller: controller, resource: .window(30), gate: gate)
        let distinctWindow = mutationTask(controller: controller, resource: .window(40), gate: gate)
        let didOverlapDistinctWindow = await waitUntil { await gate.startedCount() == 3 }
        XCTAssertTrue(didOverlapDistinctWindow)
        XCTAssertEqual(controller.activeCount(for: .window(30)), 2)
        XCTAssertEqual(controller.activeCount(for: .window(40)), 1)
        XCTAssertEqual(controller.waiterCount(for: .window(30)), 1)

        await gate.release()
        try await first.value
        try await second.value
        try await queuedSameWindow.value
        try await distinctWindow.value
        let finalReadCount = await gate.startedCount()
        XCTAssertEqual(finalReadCount, 4)
        XCTAssertEqual(controller.activeCount(for: .window(30)), 0)
        XCTAssertEqual(controller.activeCount(for: .window(40)), 0)
    }

    func testToolCardOwnershipRejectsDuplicateInvocationAndReleasesExactly() throws {
        let ledger = MCPToolCardOwnershipLedger()
        let windowID = 7
        let runID = UUID()
        let firstInvocation = UUID()
        let secondInvocation = UUID()

        let first = try XCTUnwrap(ledger.begin(
            windowID: windowID,
            runID: runID,
            invocationID: firstInvocation,
            connectionID: UUID(),
            toolName: MCPWindowToolName.readFile
        ))
        let second = try XCTUnwrap(ledger.begin(
            windowID: windowID,
            runID: runID,
            invocationID: secondInvocation,
            connectionID: UUID(),
            toolName: MCPWindowToolName.getFileTree
        ))
        XCTAssertNil(ledger.begin(
            windowID: windowID,
            runID: runID,
            invocationID: firstInvocation,
            connectionID: UUID(),
            toolName: MCPWindowToolName.readFile
        ))
        XCTAssertEqual(ledger.snapshots().single?.invocationIDs, [firstInvocation, secondInvocation])

        first.release()
        XCTAssertFalse(ledger.contains(windowID: windowID, runID: runID, invocationID: firstInvocation))
        XCTAssertTrue(ledger.contains(windowID: windowID, runID: runID, invocationID: secondInvocation))
        second.release()
        XCTAssertTrue(ledger.snapshots().isEmpty)
    }

    func testGitAdmissionSerializesLinkedWorktreesByCommonDirectory() async throws {
        let fixture = try GitAdmissionWorktreeFixture()
        defer { fixture.cleanup() }
        let controller = MCPGitToolAdmissionController(perRepositoryLimit: 1)
        let gate = AdmissionTestGate()

        XCTAssertEqual(
            MCPGitToolAdmissionController.repositoryKey(for: fixture.repo),
            MCPGitToolAdmissionController.repositoryKey(for: fixture.worktree)
        )

        let mainCheckout = gitTask(controller: controller, repositoryRoots: [fixture.repo], gate: gate)
        let didStartMainCheckout = await waitUntil { await gate.startedCount() == 1 }
        XCTAssertTrue(didStartMainCheckout)

        let linkedWorktree = gitTask(controller: controller, repositoryRoots: [fixture.worktree], gate: gate)
        try await Task.sleep(for: .milliseconds(50))
        let startedWhileMainCheckoutHeld = await gate.startedCount()
        XCTAssertEqual(startedWhileMainCheckoutHeld, 1)
        XCTAssertEqual(controller.activeCount(repositoryRoot: fixture.repo), 1)
        XCTAssertEqual(controller.activeCount(repositoryRoot: fixture.worktree), 1)
        XCTAssertEqual(controller.waiterCount(), 1)

        await gate.release()
        try await mainCheckout.value
        try await linkedWorktree.value
        let finalGitCount = await gate.startedCount()
        XCTAssertEqual(finalGitCount, 2)
        XCTAssertEqual(controller.activeCount(repositoryRoot: fixture.repo), 0)
        XCTAssertEqual(controller.activeCount(repositoryRoot: fixture.worktree), 0)
    }

    func testGitAdmissionSerializesSameRepositoryAndOverlapsDistinctRepositories() async throws {
        let controller = MCPGitToolAdmissionController(perRepositoryLimit: 1)
        let gate = AdmissionTestGate()
        let repoA = "/tmp/WI10-Repo-A"
        let repoB = "/tmp/WI10-Repo-B"

        let firstA = gitTask(controller: controller, repositories: [repoA], gate: gate)
        let didStartFirstRepository = await waitUntil { await gate.startedCount() == 1 }
        XCTAssertTrue(didStartFirstRepository)

        let secondA = gitTask(controller: controller, repositories: [repoA], gate: gate)
        let firstB = gitTask(controller: controller, repositories: [repoB], gate: gate)

        let didOverlapDistinctRepositories = await waitUntil { await gate.startedCount() == 2 }
        XCTAssertTrue(didOverlapDistinctRepositories)
        XCTAssertEqual(controller.activeCount(repositoryKey: repoA), 1)
        XCTAssertEqual(controller.activeCount(repositoryKey: repoB), 1)
        XCTAssertEqual(controller.waiterCount(), 1)

        await gate.release()
        try await firstA.value
        try await secondA.value
        try await firstB.value
        let finalGitCount = await gate.startedCount()
        XCTAssertEqual(finalGitCount, 3)
        XCTAssertEqual(controller.activeCount(repositoryKey: repoA), 0)
        XCTAssertEqual(controller.activeCount(repositoryKey: repoB), 0)
    }

    private func assertClass(_ expected: MCPToolAdmissionClass, tools: [String]) {
        XCTAssertEqual(
            Set(MCPToolAdmissionPolicy.classifications.compactMap { tool, classification in
                classification == expected ? tool : nil
            }),
            Set(tools),
            "Unexpected canonical tools in admission class \(expected.rawValue)"
        )
        for tool in tools {
            XCTAssertEqual(ServerNetworkManager.admissionClass(forCanonicalToolName: tool), expected)
            XCTAssertEqual(ServerNetworkManager.callLane(forCanonicalToolName: tool), expected.connectionLane)
        }
    }

    private func mutationTask(
        controller: MCPToolResourceAdmissionController,
        resource: MCPToolResourceAdmissionController.Resource,
        gate: AdmissionTestGate
    ) -> Task<Void, Error> {
        Task {
            let lease = try await controller.acquire(resource)
            await gate.enterAndWaitForRelease()
            lease.release()
        }
    }

    private func gitTask(
        controller: MCPGitToolAdmissionController,
        repositoryRoots: [URL],
        gate: AdmissionTestGate
    ) -> Task<Void, Error> {
        Task {
            let lease = try await controller.acquire(repositoryRoots: repositoryRoots)
            await gate.enterAndWaitForRelease()
            controller.release(lease)
        }
    }

    private func gitTask(
        controller: MCPGitToolAdmissionController,
        repositories: [String],
        gate: AdmissionTestGate
    ) -> Task<Void, Error> {
        Task {
            let lease = try await controller.acquire(repositoryKeys: repositories)
            await gate.enterAndWaitForRelease()
            controller.release(lease)
        }
    }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        for _ in 0 ..< 200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

private actor AdmissionTestGate {
    private var started = 0
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWaitForRelease() async {
        started += 1
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func startedCount() -> Int {
        started
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private extension Array {
    var single: Element? {
        count == 1 ? first : nil
    }
}

private struct GitAdmissionWorktreeFixture {
    let sandbox: URL
    let repo: URL
    let worktree: URL

    init() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPGitToolAdmissionControllerTests-\(UUID().uuidString)", isDirectory: true)
        repo = sandbox.appendingPathComponent("repo", isDirectory: true).standardizedFileURL
        worktree = sandbox.appendingPathComponent("linked", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["init"], cwd: repo)
        try runGit(["config", "user.name", "RepoPrompt Test"], cwd: repo)
        try runGit(["config", "user.email", "repoprompt@example.test"], cwd: repo)
        try runGit(["config", "commit.gpgSign", "false"], cwd: repo)
        try runGit(["checkout", "-b", "main"], cwd: repo)
        try "base\n".write(to: repo.appendingPathComponent("Tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "Tracked.txt"], cwd: repo)
        try runGit(["commit", "-m", "Initial commit"], cwd: repo)
        try runGit(["worktree", "add", "-b", "feature/linked", worktree.path, "HEAD"], cwd: repo)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func runGit(_ arguments: [String], cwd: URL) throws {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let result = try TestProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            currentDirectoryURL: cwd,
            environment: environment
        )
        guard result.terminationStatus == 0 else {
            throw NSError(
                domain: "MCPGitToolAdmissionControllerTests.git",
                code: Int(result.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: result.outputText]
            )
        }
    }
}
