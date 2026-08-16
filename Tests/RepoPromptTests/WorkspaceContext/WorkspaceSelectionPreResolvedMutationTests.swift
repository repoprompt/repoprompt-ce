import Foundation
@testable import RepoPromptApp
import XCTest

final class WorkspaceSelectionPreResolvedMutationTests: XCTestCase {
    private let untouchedFull = "/workspace/UntouchedFull.swift"
    private let untouchedMap = "/workspace/UntouchedMap.swift"
    private let untouchedSlice = "/workspace/UntouchedSlice.swift"
    private let existingTarget = "/workspace/Existing.swift"
    private let newSecond = "/workspace/NewSecond.swift"
    private let newFirst = "/workspace/NewFirst.swift"

    func testFullTargetStateIsExclusiveOrderedAndIdempotent() {
        let service = WorkspaceSelectionMutationService(store: WorkspaceFileContextStore())
        let base = mixedBaseSelection()
        let paths = [newSecond, existingTarget, newFirst, newSecond]

        let result = service.setPreResolvedFilePaths(base: base, absolutePaths: paths, targetState: .full)
        let repeated = service.setPreResolvedFilePaths(base: result, absolutePaths: paths, targetState: .full)

        XCTAssertEqual(result.selectedPaths, [untouchedFull, existingTarget, newSecond, newFirst])
        XCTAssertEqual(result.manualCodemapPaths, [untouchedMap])
        XCTAssertEqual(result.slices, [untouchedSlice: [LineRange(start: 2, end: 4)]])
        XCTAssertTrue(result.codemapAutoEnabled)
        XCTAssertEqual(repeated, result)
    }

    func testCodemapTargetStateIsExclusiveOrderedAndIdempotent() {
        let service = WorkspaceSelectionMutationService(store: WorkspaceFileContextStore())
        let base = mixedBaseSelection()
        let paths = [newSecond, existingTarget, newFirst, newSecond]

        let result = service.setPreResolvedFilePaths(base: base, absolutePaths: paths, targetState: .codemapOnly)
        let repeated = service.setPreResolvedFilePaths(base: result, absolutePaths: paths, targetState: .codemapOnly)

        XCTAssertEqual(result.selectedPaths, [untouchedFull])
        XCTAssertEqual(result.manualCodemapPaths, [untouchedMap, existingTarget, newSecond, newFirst])
        XCTAssertEqual(result.slices, [untouchedSlice: [LineRange(start: 2, end: 4)]])
        XCTAssertFalse(result.codemapAutoEnabled)
        XCTAssertEqual(repeated, result)
    }

    func testUnselectedTargetStateAtomicallyRemovesEveryRepresentation() {
        let service = WorkspaceSelectionMutationService(store: WorkspaceFileContextStore())
        let base = mixedBaseSelection()
        let paths = [newSecond, existingTarget, newFirst, newSecond]

        let result = service.setPreResolvedFilePaths(base: base, absolutePaths: paths, targetState: .unselected)
        let repeated = service.setPreResolvedFilePaths(base: result, absolutePaths: paths, targetState: .unselected)

        XCTAssertEqual(result.selectedPaths, [untouchedFull])
        XCTAssertEqual(result.manualCodemapPaths, [untouchedMap])
        XCTAssertEqual(result.slices, [untouchedSlice: [LineRange(start: 2, end: 4)]])
        XCTAssertTrue(result.codemapAutoEnabled)
        XCTAssertEqual(repeated, result)
    }

    func testCodemapCapabilityRuleRejectsEmptyAndUnsupportedExtensions() {
        let rootID = UUID()
        let swift = fileRecord(name: "App.SWIFT", rootID: rootID)
        let extensionless = fileRecord(name: "LICENSE", rootID: rootID)
        let unsupported = fileRecord(name: "Image.png", rootID: rootID)

        XCTAssertTrue(WorkspaceSelectionMutationService.supportsCodemap(swift))
        XCTAssertFalse(WorkspaceSelectionMutationService.supportsCodemap(extensionless))
        XCTAssertFalse(WorkspaceSelectionMutationService.supportsCodemap(unsupported))
    }

    func testTenThousandFileTargetStateTransformScale() {
        let count = 10000
        let paths = (0 ..< count).map { "/workspace/File\($0).swift" }
        let slices = Dictionary(uniqueKeysWithValues: paths.map { ($0, [LineRange(start: 1, end: 1)]) })
        let base = StoredSelection(
            selectedPaths: paths,
            manualCodemapPaths: paths,
            slices: slices,
            codemapAutoEnabled: true
        )
        let service = WorkspaceSelectionMutationService(store: WorkspaceFileContextStore())
        var result = base

        measure(metrics: [XCTClockMetric()]) {
            result = service.setPreResolvedFilePaths(
                base: base,
                absolutePaths: paths,
                targetState: .unselected
            )
        }

        XCTAssertTrue(result.selectedPaths.isEmpty)
        XCTAssertTrue(result.manualCodemapPaths.isEmpty)
        XCTAssertTrue(result.slices.isEmpty)
        XCTAssertTrue(result.codemapAutoEnabled)
    }

    @MainActor
    func testCoordinatorTargetsSuppliedInactiveIdentity() async throws {
        let activeSelection = StoredSelection(selectedPaths: ["/workspace/Active.swift"])
        let inactiveSelection = StoredSelection(selectedPaths: ["/workspace/Inactive.swift"])
        let harness = PreResolvedCoordinatorHarness(
            activeSelection: activeSelection,
            inactiveSelection: inactiveSelection
        )
        let added = "/workspace/Added.swift"

        let transactionValue = await harness.coordinator.setPreResolvedFilePathsInSelection(
            [added],
            targetState: .full,
            for: harness.inactiveIdentity,
            lookupContext: .visibleWorkspace
        )
        let transaction = try XCTUnwrap(transactionValue)

        XCTAssertEqual(transaction.identity, harness.inactiveIdentity)
        XCTAssertEqual(transaction.before, inactiveSelection)
        XCTAssertEqual(transaction.after.selectedPaths, ["/workspace/Inactive.swift", added])
        XCTAssertEqual(harness.selection(for: harness.activeIdentity), activeSelection)
        XCTAssertEqual(harness.selection(for: harness.inactiveIdentity), transaction.after)
    }

    @MainActor
    func testCoordinatorSequentialTransactionsComposeAgainstLatestCanonicalSelection() async throws {
        let harness = PreResolvedCoordinatorHarness(activeSelection: StoredSelection())
        let first = "/workspace/First.swift"
        let concurrent = "/workspace/Concurrent.swift"
        let second = "/workspace/Second.swift"

        let firstTransaction = await harness.coordinator.setPreResolvedFilePathsInSelection(
            [first],
            targetState: .full,
            for: harness.activeIdentity,
            lookupContext: .visibleWorkspace
        )
        _ = try XCTUnwrap(firstTransaction)
        harness.replaceSelection(
            StoredSelection(selectedPaths: [first, concurrent]),
            for: harness.activeIdentity
        )
        let transactionValue = await harness.coordinator.setPreResolvedFilePathsInSelection(
            [second],
            targetState: .full,
            for: harness.activeIdentity,
            lookupContext: .visibleWorkspace
        )
        let transaction = try XCTUnwrap(transactionValue)

        XCTAssertEqual(transaction.before.selectedPaths, [first, concurrent])
        XCTAssertEqual(transaction.after.selectedPaths, [first, concurrent, second])
        XCTAssertEqual(harness.selection(for: harness.activeIdentity), transaction.after)
    }

    @MainActor
    func testCoordinatorPersistsCanonicalSelectionBeforeReturningTransaction() async throws {
        let harness = PreResolvedCoordinatorHarness(activeSelection: StoredSelection())
        let added = "/workspace/Added.swift"

        let transactionValue = await harness.coordinator.setPreResolvedFilePathsInSelection(
            [added],
            targetState: .full,
            for: harness.activeIdentity,
            lookupContext: .visibleWorkspace
        )
        let transaction = try XCTUnwrap(transactionValue)

        XCTAssertEqual(harness.manager.selectionStoredByPersistence, transaction.after)
        XCTAssertEqual(harness.selection(for: harness.activeIdentity), transaction.after)
    }

    @MainActor
    func testCoordinatorWorktreePhysicalLogicalRoundTrip() async throws {
        let logicalRoot = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: "/repo/project")
        let physicalRoot = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: "/tmp/worktrees/project-agent")
        let binding = AgentSessionWorktreeBinding(
            id: "binding-1",
            repositoryID: "repo-1",
            repoKey: "repo-key",
            logicalRootPath: logicalRoot.fullPath,
            logicalRootName: logicalRoot.name,
            worktreeID: "wt-1",
            worktreeRootPath: physicalRoot.fullPath,
            source: "test"
        )
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [.init(logicalRoot: logicalRoot, physicalRoot: physicalRoot, binding: binding)]
        )
        let lookupContext = WorkspaceLookupContext(
            rootScope: projection.lookupRootScope,
            bindingProjection: projection
        )
        let logicalPath = "/repo/project/Sources/App.swift"
        let physicalPath = "/tmp/worktrees/project-agent/Sources/App.swift"
        let harness = PreResolvedCoordinatorHarness(
            activeSelection: StoredSelection(
                selectedPaths: [logicalPath],
                slices: [logicalPath: [LineRange(start: 4, end: 8)]],
                codemapAutoEnabled: true
            )
        )

        let transactionValue = await harness.coordinator.setPreResolvedFilePathsInSelection(
            [physicalPath],
            targetState: .codemapOnly,
            for: harness.activeIdentity,
            lookupContext: lookupContext
        )
        let transaction = try XCTUnwrap(transactionValue)

        XCTAssertTrue(transaction.after.selectedPaths.isEmpty)
        XCTAssertEqual(transaction.after.manualCodemapPaths, [logicalPath])
        XCTAssertTrue(transaction.after.slices.isEmpty)
        XCTAssertFalse(transaction.after.codemapAutoEnabled)
        XCTAssertEqual(harness.selection(for: harness.activeIdentity), transaction.after)
    }

    @MainActor
    func testCoordinatorReturnsNilWhenCapturedTargetNoLongerExists() async {
        let harness = PreResolvedCoordinatorHarness(activeSelection: StoredSelection())
        harness.removeTab(harness.activeIdentity.tabID)

        let transaction = await harness.coordinator.setPreResolvedFilePathsInSelection(
            ["/workspace/Added.swift"],
            targetState: .full,
            for: harness.activeIdentity,
            lookupContext: .visibleWorkspace
        )

        XCTAssertNil(transaction)
    }

    private func mixedBaseSelection() -> StoredSelection {
        StoredSelection(
            selectedPaths: [untouchedFull, existingTarget],
            manualCodemapPaths: [untouchedMap, existingTarget],
            slices: [
                untouchedSlice: [LineRange(start: 2, end: 4)],
                existingTarget: [LineRange(start: 8, end: 12)]
            ],
            codemapAutoEnabled: true
        )
    }

    private func fileRecord(name: String, rootID: UUID) -> WorkspaceFileRecord {
        WorkspaceFileRecord(
            id: UUID(),
            rootID: rootID,
            name: name,
            relativePath: name,
            fullPath: "/workspace/\(name)",
            parentFolderID: rootID
        )
    }
}

@MainActor
private final class PreResolvedCoordinatorHarness {
    let manager: PreResolvedSelectionHost
    let coordinator: WorkspaceSelectionCoordinator
    let activeIdentity: WorkspaceSelectionIdentity
    let inactiveIdentity: WorkspaceSelectionIdentity

    init(
        activeSelection: StoredSelection,
        inactiveSelection: StoredSelection? = nil
    ) {
        let workspaceID = UUID()
        let activeTabID = UUID()
        let inactiveTabID = UUID()
        var tabs = [ComposeTabState(id: activeTabID, name: "Active", selection: activeSelection)]
        if let inactiveSelection {
            tabs.append(ComposeTabState(id: inactiveTabID, name: "Inactive", selection: inactiveSelection))
        }
        let workspace = WorkspaceModel(
            id: workspaceID,
            name: "Test Workspace",
            repoPaths: [],
            composeTabs: tabs,
            activeComposeTabID: activeTabID
        )
        manager = PreResolvedSelectionHost(workspace: workspace)
        coordinator = WorkspaceSelectionCoordinator(
            workspaceManager: manager,
            store: WorkspaceFileContextStore()
        )
        activeIdentity = WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: activeTabID)
        inactiveIdentity = WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: inactiveTabID)
    }

    func selection(for identity: WorkspaceSelectionIdentity) -> StoredSelection? {
        manager.composeTab(for: identity)?.selection
    }

    func replaceSelection(_ selection: StoredSelection, for identity: WorkspaceSelectionIdentity) {
        manager.replaceSelection(selection, for: identity)
    }

    func removeTab(_ tabID: UUID) {
        manager.removeTab(tabID)
    }
}

@MainActor
private final class PreResolvedSelectionHost: WorkspaceSelectionHost {
    var activeWorkspace: WorkspaceModel?
    var selectionMirrorContextRevision: UInt64 = 0
    private(set) var selectionStoredByPersistence: StoredSelection?

    init(workspace: WorkspaceModel) {
        activeWorkspace = workspace
    }

    func composeTab(with id: UUID) -> ComposeTabState? {
        activeWorkspace?.composeTabs.first { $0.id == id }
    }

    func composeTab(for identity: WorkspaceSelectionIdentity) -> ComposeTabState? {
        guard activeWorkspace?.id == identity.workspaceID else { return nil }
        return composeTab(with: identity.tabID)
    }

    func publishActiveComposeTabSnapshot(commitToMemory: Bool, touchModified: Bool) {}

    func updateComposeTabStoredOnly(_ tab: ComposeTabState, inWorkspaceID workspaceID: UUID) -> Bool {
        guard var workspace = activeWorkspace,
              workspace.id == workspaceID,
              let index = workspace.composeTabs.firstIndex(where: { $0.id == tab.id })
        else { return false }
        workspace.composeTabs[index] = tab
        activeWorkspace = workspace
        selectionStoredByPersistence = tab.selection
        return true
    }

    func applySelectionMirrorAttempt(
        _ selection: StoredSelection,
        forTabID tabID: UUID,
        workspaceID: UUID
    ) async {}

    func replaceSelection(_ selection: StoredSelection, for identity: WorkspaceSelectionIdentity) {
        guard var workspace = activeWorkspace,
              workspace.id == identity.workspaceID,
              let index = workspace.composeTabs.firstIndex(where: { $0.id == identity.tabID })
        else { return }
        workspace.composeTabs[index].selection = selection
        activeWorkspace = workspace
    }

    func removeTab(_ tabID: UUID) {
        guard var workspace = activeWorkspace else { return }
        workspace.composeTabs.removeAll { $0.id == tabID }
        activeWorkspace = workspace
    }
}
