import Foundation
@testable import RepoPrompt
@testable import RepoPromptCore
import XCTest

@MainActor
final class WorkspaceSlice1CompositionTests: XCTestCase {
    func testAppContainerSharesOneRepositoryAndWriterWithEverySessionController() {
        let container = RepoPromptAppCoreContainer.shared
        let first = container.coreHost.makeEmbeddedSession(routingSessionID: MCPRoutingSessionID(rawValue: 91001))
        let second = container.coreHost.makeEmbeddedSession(routingSessionID: MCPRoutingSessionID(rawValue: 91002))

        XCTAssertTrue(first.session.workspaceRepository === container.workspaceRepository)
        XCTAssertTrue(second.session.workspaceRepository === container.workspaceRepository)
        XCTAssertTrue(first.session.workspacePersistenceWriter === container.workspacePersistenceWriter)
        XCTAssertTrue(second.session.workspacePersistenceWriter === container.workspacePersistenceWriter)
        XCTAssertTrue(first.session.workspaceSessionController.repository === container.workspaceRepository)
        XCTAssertTrue(first.session.workspaceSessionController.persistenceWriter === container.workspacePersistenceWriter)
    }

    func testProductionConstructorsRemainAppOwnedAndAppV1IsTheOnlySelectedCodec() throws {
        let root = try RepoRoot.url()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var repositoryConstructors: [String] = []
        var controllerConstructors: [String] = []
        var selectedV2Codecs: [String] = []

        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
            let relative = RepoRoot.relativePath(for: canonicalURL, relativeTo: root)
            if source.contains("WorkspaceRepository(") { repositoryConstructors.append(relative) }
            if source.contains("WorkspaceSessionController(") { controllerConstructors.append(relative) }
            if source.contains("CanonicalWorkspaceCodecV2(") { selectedV2Codecs.append(relative) }
        }

        XCTAssertEqual(repositoryConstructors, ["Sources/RepoPrompt/App/CoreAdapters/EmbeddedWorkspaceRepositoryFactory.swift"])
        XCTAssertEqual(controllerConstructors, ["Sources/RepoPrompt/Infrastructure/Core/RepoPromptCoreHost.swift"])
        XCTAssertTrue(selectedV2Codecs.isEmpty)
    }

    func testWindowRetainsObservationAndCanonicalSelectionController() throws {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }
        let window = WindowState()
        defer { window.beginClose() }
        let workspace = WorkspaceModel(name: "Lifetime", repoPaths: ["/tmp/lifetime"])
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)

        window.workspaceManager.replaceWorkspaceInventory([workspace], activeWorkspaceID: workspace.id)

        XCTAssertTrue(window.workspaceObservation === window.workspaceManager.workspaceObservation)
        XCTAssertEqual(window.selectionCoordinator.activeTabID(), tabID)
        XCTAssertEqual(window.selectionCoordinator.controller.sessionController.activeWorkspace?.id, workspace.id)
    }

    func testPollSaveDoesNotAdvanceRepoBaselineFromStaleGeneration() async throws {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSlice1SaveRace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        let window = WindowState()
        defer { window.beginClose() }
        await window.workspaceManager.awaitInitialized()
        let workspace = WorkspaceModel(
            name: "Save Race",
            repoPaths: ["/tmp/original"],
            customStoragePath: storage
        )
        window.workspaceManager.replaceWorkspaceInventory([workspace], activeWorkspaceID: workspace.id)
        window.workspaceManager.mutateWorkspace(id: workspace.id) { $0.repoPaths = ["/tmp/captured"] }

        let gate = Slice1AppWorkspaceWriteGate()
        let writer = window.workspaceManager.sessionController.persistenceWriter
        await writer.setAtomicWriteGateForTesting { await gate.waitIfFirstWrite() }
        let saveTask = Task {
            await window.workspaceManager.pollAndSaveStateAsync(source: "slice1.race")
        }
        await gate.waitUntilFirstWriteStarted()
        window.workspaceManager.mutateWorkspace(id: workspace.id) { $0.name = "Newer local mutation" }
        await gate.releaseFirstWrite()
        await saveTask.value
        await writer.setAtomicWriteGateForTesting(nil)

        XCTAssertTrue(window.workspaceManager.sessionController.isDirty(workspaceID: workspace.id))
        XCTAssertEqual(
            window.workspaceManager.sessionController.repositoryBaseline(workspaceID: workspace.id),
            ["/tmp/original"]
        )
    }

    func testWorkspaceManagerSourceContainsNoSecondWritableCanonicalState() throws {
        let source = try String(
            contentsOf: RepoRoot.url().appendingPathComponent(
                "Sources/RepoPrompt/Features/Workspaces/ViewModels/WorkspaceManagerViewModel.swift"
            ),
            encoding: .utf8
        )

        XCTAssertNil(source.range(of: #"@Published\s+(?:private\(set\)\s+)?var\s+workspaces\b"#, options: .regularExpression))
        XCTAssertNil(source.range(of: #"@Published\s+(?:private\(set\)\s+)?var\s+activeWorkspaceID\b"#, options: .regularExpression))
        XCTAssertNotNil(
            source.range(
                of: #"var\s+workspaces\s*:\s*\[WorkspaceModel\]\s*\{\s*sessionController\.workspaces\s*\}"#,
                options: .regularExpression
            )
        )
        XCTAssertNotNil(
            source.range(
                of: #"var\s+activeWorkspaceID\s*:\s*UUID\?\s*\{\s*sessionController\.activeWorkspaceID\s*\}"#,
                options: .regularExpression
            )
        )
    }
}

private actor Slice1AppWorkspaceWriteGate {
    private var firstStarted = false
    private var firstReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitIfFirstWrite() async {
        guard !firstStarted else { return }
        firstStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        guard !firstReleased else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilFirstWriteStarted() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseFirstWrite() {
        firstReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}
