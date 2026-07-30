@testable import RepoPromptApp
import XCTest

@MainActor
final class WorkspaceFilesAutoCodemapModeTests: XCTestCase {
    func testExplicitCodemapOnlyIntentSelectsRequestedManualFileAndDisablesAuto() {
        let fixture = makeFixture(fileName: "Present.swift")
        XCTAssertTrue(fixture.viewModel.codemapAutoEnabled)

        fixture.viewModel.setFileAsCodemap(fixture.file)

        XCTAssertFalse(fixture.viewModel.codemapAutoEnabled)
        XCTAssertTrue(fixture.viewModel.autoCodemapFiles.isEmpty)
        XCTAssertFalse(fixture.viewModel.isAutoCodemapFile(fixture.file))
        XCTAssertTrue(fixture.viewModel.snapshotSelection().selectedPaths.isEmpty)
        XCTAssertEqual(
            fixture.viewModel.snapshotSelection().manualCodemapPaths,
            [fixture.file.standardizedFullPath]
        )
    }

    func testOrdinaryFileRemovalPreservesAutoAndFullClearRestoresIt() async {
        do {
            let fixture = makeFixture(fileName: "Selected.swift")
            fixture.viewModel.selectFileForTesting(fixture.file)
            XCTAssertTrue(fixture.viewModel.codemapAutoEnabled)

            fixture.viewModel.removeFileFromAllSelections(fixture.file)

            XCTAssertTrue(fixture.viewModel.selectedFiles.isEmpty)
            XCTAssertTrue(fixture.viewModel.codemapAutoEnabled)
        }

        do {
            let fixture = makeFixture(fileName: "Clear.swift")
            fixture.viewModel.enterManualCodemapMode()
            XCTAssertFalse(fixture.viewModel.codemapAutoEnabled)

            await fixture.viewModel.clearSelection()

            XCTAssertTrue(fixture.viewModel.selectedFiles.isEmpty)
            XCTAssertTrue(fixture.viewModel.autoCodemapFiles.isEmpty)
            XCTAssertTrue(fixture.viewModel.codemapAutoEnabled)
        }
    }

    func testSnapshotAndEncodingContainNoInferredPathState() throws {
        let fixture = makeFixture(fileName: "Dependency.swift")
        fixture.viewModel.selectFileForTesting(fixture.file)

        let snapshot = fixture.viewModel.snapshotSelection()
        XCTAssertEqual(snapshot.selectedPaths, [fixture.file.standardizedFullPath])
        XCTAssertTrue(snapshot.codemapAutoEnabled)

        let encoded = try JSONEncoder().encode(snapshot)
        let encodedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(encodedObject["autoCodemapPaths"] as? [String], [])

        fixture.viewModel.setAutoCodemapFilesForTesting([fixture.file])
        XCTAssertEqual(fixture.viewModel.autoCodemapFiles.map(\.id), [fixture.file.id])
        fixture.viewModel.enterManualCodemapMode()
        XCTAssertFalse(fixture.viewModel.codemapAutoEnabled)
        XCTAssertTrue(fixture.viewModel.autoCodemapFiles.isEmpty)
        XCTAssertTrue(fixture.viewModel.manualCodemapFiles.isEmpty)
        XCTAssertTrue(fixture.viewModel.snapshotSelection().manualCodemapPaths.isEmpty)
    }

    func testNewSourceGenerationClearsExistingInferredMarkersSynchronously() {
        let fixture = makeFixture(fileName: "Generation.swift")
        fixture.viewModel.setAutoCodemapFilesForTesting([fixture.file])

        fixture.viewModel.selectFileForTesting(fixture.file)

        XCTAssertTrue(fixture.viewModel.autoCodemapFiles.isEmpty)
        XCTAssertTrue(fixture.viewModel.codemapAutoEnabled)
    }

    func testAutomaticPublicationTargetReconstructionPreservesExactReceiptOrder() throws {
        let fixture = makeReconstructionFixture()
        let firstTarget = try makeTarget(
            rootEpoch: fixture.rootEpoch,
            file: fixture.firstTarget,
            relativePath: "First.swift"
        )
        let secondTarget = try makeTarget(
            rootEpoch: fixture.rootEpoch,
            file: fixture.secondTarget,
            relativePath: "Second.swift"
        )

        let resolved = fixture.viewModel.reconstructAutomaticCodemapTargetsForTesting(
            receiptTargets: [secondTarget, firstTarget],
            revalidatedTargets: [secondTarget, firstTarget],
            sourceIDs: [fixture.source.id],
            filesByID: [
                fixture.firstTarget.id: fixture.firstTarget,
                fixture.secondTarget.id: fixture.secondTarget
            ]
        )

        XCTAssertEqual(resolved?.map(\.id), [fixture.secondTarget.id, fixture.firstTarget.id])
    }

    func testAutomaticPublicationTargetReconstructionRejectsEveryMismatchAtomicallyAndRetries() throws {
        let fixture = makeReconstructionFixture()
        let firstTarget = try makeTarget(
            rootEpoch: fixture.rootEpoch,
            file: fixture.firstTarget,
            relativePath: "First.swift"
        )
        let secondTarget = try makeTarget(
            rootEpoch: fixture.rootEpoch,
            file: fixture.secondTarget,
            relativePath: "Second.swift"
        )
        let duplicateTargets = [firstTarget, firstTarget]
        let wrongRootTarget = try makeTarget(
            rootEpoch: WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID()),
            file: fixture.firstTarget,
            relativePath: "First.swift"
        )
        let filesByID = [
            fixture.firstTarget.id: fixture.firstTarget,
            fixture.secondTarget.id: fixture.secondTarget
        ]
        let malformedCases: [(
            receipt: [WorkspaceCodemapAutomaticSelectionTarget],
            revalidated: [WorkspaceCodemapAutomaticSelectionTarget],
            sourceIDs: [UUID],
            filesByID: [UUID: FileViewModel]
        )] = [
            ([firstTarget, secondTarget], [firstTarget], [fixture.source.id], filesByID),
            ([firstTarget, secondTarget], [secondTarget, firstTarget], [fixture.source.id], filesByID),
            (duplicateTargets, duplicateTargets, [fixture.source.id], filesByID),
            ([wrongRootTarget], [wrongRootTarget], [fixture.source.id], filesByID),
            ([firstTarget], [firstTarget], [fixture.firstTarget.id], filesByID),
            ([firstTarget, secondTarget], [firstTarget, secondTarget], [fixture.source.id], [
                fixture.firstTarget.id: fixture.firstTarget
            ])
        ]

        for malformed in malformedCases {
            fixture.viewModel.setAutoCodemapFilesForTesting([
                fixture.firstTarget,
                fixture.secondTarget
            ])

            XCTAssertTrue(fixture.viewModel.rejectInvalidAutomaticCodemapTargetsForTesting(
                receiptTargets: malformed.receipt,
                revalidatedTargets: malformed.revalidated,
                sourceIDs: malformed.sourceIDs,
                filesByID: malformed.filesByID
            ))
            XCTAssertTrue(fixture.viewModel.autoCodemapFiles.isEmpty)
            XCTAssertTrue(fixture.viewModel.automaticCodemapReadinessRetryPendingForTesting)
        }
    }

    func testMatchingReadyMarkerCoalescesReadinessRetry() async throws {
        let fixture = try await makeRetryLifecycleFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        fixture.viewModel.armAutomaticCodemapReadinessRetryForTesting(
            rootEpoch: fixture.rootEpoch,
            fileID: fixture.targetFileID
        )
        let armedGeneration = fixture.viewModel.automaticCodemapSelectionGenerationForTesting

        fixture.viewModel.handleCodemapMarkerReadinessForTesting(.init(
            rootEpoch: fixture.rootEpoch,
            revision: 1,
            changes: [.init(
                fileID: UUID(),
                standardizedRelativePath: "Other.swift",
                requestGeneration: 1,
                pathGeneration: 1,
                state: .ready
            )]
        ))
        XCTAssertTrue(fixture.viewModel.automaticCodemapReadinessRetryPendingForTesting)
        XCTAssertTrue(fixture.viewModel.automaticCodemapReadinessRetryTaskActiveForTesting)
        XCTAssertEqual(
            fixture.viewModel.automaticCodemapSelectionGenerationForTesting,
            armedGeneration
        )

        fixture.viewModel.handleCodemapMarkerReadinessForTesting(.init(
            rootEpoch: fixture.rootEpoch,
            revision: 2,
            changes: [.init(
                fileID: fixture.targetFileID,
                standardizedRelativePath: "Target.swift",
                requestGeneration: 0,
                pathGeneration: 0,
                state: .ready
            )]
        ))
        XCTAssertTrue(fixture.viewModel.automaticCodemapReadinessRetryPendingForTesting)
        XCTAssertEqual(
            fixture.viewModel.automaticCodemapSelectionGenerationForTesting,
            armedGeneration
        )

        let matchingReady = WorkspaceCodemapMarkerReadinessEvent(
            rootEpoch: fixture.rootEpoch,
            revision: 3,
            changes: [.init(
                fileID: fixture.targetFileID,
                standardizedRelativePath: "Target.swift",
                requestGeneration: 1,
                pathGeneration: 1,
                state: .ready
            )]
        )
        fixture.viewModel.handleCodemapMarkerReadinessForTesting(matchingReady)
        let triggeredGeneration = fixture.viewModel.automaticCodemapSelectionGenerationForTesting
        XCTAssertEqual(triggeredGeneration, armedGeneration &+ 1)
        XCTAssertFalse(fixture.viewModel.automaticCodemapReadinessRetryPendingForTesting)
        XCTAssertFalse(fixture.viewModel.automaticCodemapReadinessRetryTaskActiveForTesting)

        fixture.viewModel.handleCodemapMarkerReadinessForTesting(matchingReady)
        XCTAssertEqual(
            fixture.viewModel.automaticCodemapSelectionGenerationForTesting,
            triggeredGeneration
        )
        fixture.viewModel.enterManualCodemapMode()
        await fixture.viewModel.unloadAllRootFolders()
    }

    func testPendingReadinessRetryAutonomouslySchedulesOnceWithoutReadinessEvents() async throws {
        let fixture = try await makeRetryLifecycleFixture(retryDelay: .milliseconds(10))
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        fixture.viewModel.armAutomaticCodemapReadinessRetryForTesting(
            rootEpoch: fixture.rootEpoch,
            fileID: fixture.targetFileID
        )
        let armedGeneration = fixture.viewModel.automaticCodemapSelectionGenerationForTesting
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))

        while fixture.viewModel.automaticCodemapSelectionGenerationForTesting == armedGeneration,
              clock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(
            fixture.viewModel.automaticCodemapSelectionGenerationForTesting,
            armedGeneration &+ 1
        )
        XCTAssertFalse(fixture.viewModel.automaticCodemapReadinessRetryPendingForTesting)
        XCTAssertFalse(fixture.viewModel.automaticCodemapReadinessRetryTaskActiveForTesting)
        fixture.viewModel.enterManualCodemapMode()
        await fixture.viewModel.unloadAllRootFolders()
    }

    func testPendingReadinessRetryCancelsForModeSelectionAndRootChanges() async throws {
        do {
            let fixture = try await makeRetryLifecycleFixture()
            defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
            fixture.viewModel.armAutomaticCodemapReadinessRetryForTesting(
                rootEpoch: fixture.rootEpoch,
                fileID: fixture.targetFileID
            )

            fixture.viewModel.enterManualCodemapMode()

            XCTAssertFalse(fixture.viewModel.automaticCodemapReadinessRetryPendingForTesting)
            XCTAssertFalse(fixture.viewModel.automaticCodemapReadinessRetryTaskActiveForTesting)
            await fixture.viewModel.unloadAllRootFolders()
        }

        do {
            let fixture = try await makeRetryLifecycleFixture()
            defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
            fixture.viewModel.armAutomaticCodemapReadinessRetryForTesting(
                rootEpoch: fixture.rootEpoch,
                fileID: fixture.targetFileID
            )

            fixture.viewModel.removeFileFromAllSelections(fixture.source)

            XCTAssertFalse(fixture.viewModel.automaticCodemapReadinessRetryPendingForTesting)
            XCTAssertFalse(fixture.viewModel.automaticCodemapReadinessRetryTaskActiveForTesting)
            await fixture.viewModel.unloadAllRootFolders()
        }

        do {
            let fixture = try await makeRetryLifecycleFixture()
            defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
            fixture.viewModel.armAutomaticCodemapReadinessRetryForTesting(
                rootEpoch: fixture.rootEpoch,
                fileID: fixture.targetFileID
            )

            let detached = await fixture.viewModel.detachRootShell(
                forRootPath: fixture.rootURL.path,
                unloadStoreRoot: true
            )

            XCTAssertTrue(detached)
            XCTAssertFalse(fixture.viewModel.automaticCodemapReadinessRetryPendingForTesting)
            XCTAssertFalse(fixture.viewModel.automaticCodemapReadinessRetryTaskActiveForTesting)
        }
    }

    func testStaleReadyMarkerAfterSelectionGenerationChangeDoesNotPublish() async throws {
        let fixture = try await makeRetryLifecycleFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        fixture.viewModel.armAutomaticCodemapReadinessRetryForTesting(
            rootEpoch: fixture.rootEpoch,
            fileID: fixture.targetFileID
        )
        fixture.viewModel.removeFileFromAllSelections(fixture.source)
        let invalidatedGeneration = fixture.viewModel.automaticCodemapSelectionGenerationForTesting

        fixture.viewModel.handleCodemapMarkerReadinessForTesting(.init(
            rootEpoch: fixture.rootEpoch,
            revision: 1,
            changes: [.init(
                fileID: fixture.targetFileID,
                standardizedRelativePath: "Target.swift",
                requestGeneration: 1,
                pathGeneration: 1,
                state: .ready
            )]
        ))

        XCTAssertTrue(fixture.viewModel.autoCodemapFiles.isEmpty)
        XCTAssertFalse(fixture.viewModel.automaticCodemapReadinessRetryPendingForTesting)
        XCTAssertEqual(
            fixture.viewModel.automaticCodemapSelectionGenerationForTesting,
            invalidatedGeneration
        )
        await fixture.viewModel.unloadAllRootFolders()
    }

    func testMilestoneDProductionCallersContainNoEagerCodemapOrCacheActions() throws {
        let repoRoot = try RepoRoot.url()
        let relativePaths = [
            "Sources/RepoPrompt/Features/WorkspaceFiles/ViewModels/WorkspaceFilesViewModel.swift",
            "Sources/RepoPrompt/Features/Workspaces/ViewModels/WorkspaceManagerViewModel.swift",
            "Sources/RepoPrompt/Features/Workspaces/WorkspaceCheckoutRefreshService.swift",
            "Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift",
            "Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+WorktreeMerge.swift",
            "Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentMCPStartWorktreeCoordinator.swift",
            "Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceRootBindingProjection.swift"
        ]
        let forbidden = [
            "initializeCodemapsForSessionWorktreeRoots",
            "requestCodemapScans",
            "repairMissingCodemapSnapshots",
            "purgeStaleCodemapCaches",
            "clearCodeMapCache",
            "codeMapUpdatePublisher",
            "codemapUpdates()"
        ]

        for relativePath in relativePaths {
            let source = try String(
                contentsOf: repoRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            for symbol in forbidden {
                XCTAssertFalse(source.contains(symbol), "\(relativePath) still references \(symbol)")
            }
        }
    }

    func testValueReceiptRevalidationIsFinalAwaitBeforeSynchronousCommit() throws {
        let repoRoot = try RepoRoot.url()
        let sourceURL = repoRoot.appendingPathComponent(
            "Sources/RepoPrompt/Features/WorkspaceFiles/ViewModels/WorkspaceFilesViewModel.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let revalidationCall = try XCTUnwrap(source.range(
            of: "let revalidation = await workspaceFileContextStore.revalidateAutomaticCodemapSelection("
        ))
        let postRevalidationGuard = try XCTUnwrap(source.range(
            of: "guard automaticCodemapSelectionIsCurrent(",
            range: revalidationCall.upperBound ..< source.endIndex
        ))
        let commit = try XCTUnwrap(source.range(
            of: "resetAutoCodemapFiles(resolvedTargets)",
            range: postRevalidationGuard.lowerBound ..< source.endIndex
        ))
        let synchronousCommitRegion = source[postRevalidationGuard.lowerBound ..< commit.upperBound]
        XCTAssertFalse(synchronousCommitRegion.contains("await"))
    }

    private func makeRetryLifecycleFixture(
        retryDelay: Duration = .seconds(10)
    ) async throws -> (
        viewModel: WorkspaceFilesViewModel,
        source: FileViewModel,
        targetFileID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch,
        rootURL: URL
    ) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceFilesAutoCodemapModeTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "struct Source {}\n".write(
            to: rootURL.appendingPathComponent("Source.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "struct Target {}\n".write(
            to: rootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        let rootLifetimeID = try await store.rootLifetimeIDForTesting(rootID: root.id)
        let records = await store.files(inRoot: root.id)
        let target = try XCTUnwrap(records.first { $0.standardizedRelativePath == "Target.swift" })
        let viewModel = WorkspaceFilesViewModel(
            workspaceFileContextStore: store,
            automaticCodemapReadinessRetryDelay: retryDelay
        )
        _ = try viewModel.attachRootShell(for: root, workspaceID: UUID())
        let materializedSource = await viewModel.materializeFileForUserInput(
            rootURL.appendingPathComponent("Source.swift").path
        )
        let source = try XCTUnwrap(materializedSource)
        viewModel.selectFileForTesting(source)
        return (
            viewModel,
            source,
            target.id,
            WorkspaceCodemapRootEpoch(rootID: root.id, rootLifetimeID: rootLifetimeID),
            rootURL
        )
    }

    private func makeFixture(fileName: String) -> (
        viewModel: WorkspaceFilesViewModel,
        file: FileViewModel
    ) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceFilesAutoCodemapModeTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rootID = UUID()
        let file = FileViewModel(
            file: File(
                name: fileName,
                path: rootURL.appendingPathComponent(fileName).path,
                modificationDate: Date(timeIntervalSince1970: 1000)
            ),
            rootPath: rootURL.path,
            rootIdentifier: rootID,
            rootFolderPath: rootURL.path,
            fileSystemService: nil
        )
        return (WorkspaceFilesViewModel(), file)
    }

    private func makeReconstructionFixture() -> (
        viewModel: WorkspaceFilesViewModel,
        rootEpoch: WorkspaceCodemapRootEpoch,
        source: FileViewModel,
        firstTarget: FileViewModel,
        secondTarget: FileViewModel
    ) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceFilesAutoCodemapModeTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rootID = UUID()
        return (
            WorkspaceFilesViewModel(),
            WorkspaceCodemapRootEpoch(rootID: rootID, rootLifetimeID: UUID()),
            makeFile(name: "Source.swift", rootURL: rootURL, rootID: rootID),
            makeFile(name: "First.swift", rootURL: rootURL, rootID: rootID),
            makeFile(name: "Second.swift", rootURL: rootURL, rootID: rootID)
        )
    }

    private func makeFile(name: String, rootURL: URL, rootID: UUID) -> FileViewModel {
        FileViewModel(
            file: File(
                name: name,
                path: rootURL.appendingPathComponent(name).path,
                modificationDate: Date(timeIntervalSince1970: 1000)
            ),
            rootPath: rootURL.path,
            rootIdentifier: rootID,
            rootFolderPath: rootURL.path,
            fileSystemService: nil
        )
    }

    private func makeTarget(
        rootEpoch: WorkspaceCodemapRootEpoch,
        file: FileViewModel,
        relativePath: String
    ) throws -> WorkspaceCodemapAutomaticSelectionTarget {
        try WorkspaceCodemapAutomaticSelectionTarget(
            rootEpoch: rootEpoch,
            fileID: file.id,
            catalogGeneration: 1,
            requestGeneration: 1,
            logicalPath: XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
                rootDisplayName: "Root",
                standardizedRelativePath: relativePath
            ))
        )
    }
}
