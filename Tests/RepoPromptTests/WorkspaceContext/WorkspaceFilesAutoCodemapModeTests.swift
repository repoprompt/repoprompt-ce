@testable import RepoPrompt
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
        let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(encodedText.contains("autoCodemapPaths"))

        fixture.viewModel.setAutoCodemapFilesForTesting([fixture.file])
        XCTAssertEqual(fixture.viewModel.autoCodemapFiles.map(\.id), [fixture.file.id])
        fixture.viewModel.enterManualCodemapMode()
        XCTAssertFalse(fixture.viewModel.codemapAutoEnabled)
        XCTAssertTrue(fixture.viewModel.autoCodemapFiles.isEmpty)
        XCTAssertTrue(fixture.viewModel.manualCodemapFiles.isEmpty)
        XCTAssertTrue(fixture.viewModel.snapshotSelection().manualCodemapPaths.isEmpty)
    }

    func testGraphReadinessDoesNotMutateManualMode() {
        let fixture = makeFixture(fileName: "Manual.swift")
        fixture.viewModel.enterManualCodemapMode()

        fixture.viewModel.handleAutomaticCodemapReadinessForTesting(
            rootEpoch: WorkspaceCodemapRootEpoch(
                rootID: fixture.file.rootIdentifier,
                rootLifetimeID: UUID()
            )
        )

        XCTAssertFalse(fixture.viewModel.codemapAutoEnabled)
        XCTAssertTrue(fixture.viewModel.autoCodemapFiles.isEmpty)
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

    func testPublicationRevalidationIsFinalAwaitBeforeSynchronousCommit() throws {
        let repoRoot = try RepoRoot.url()
        let sourceURL = repoRoot.appendingPathComponent(
            "Sources/RepoPrompt/Features/WorkspaceFiles/ViewModels/WorkspaceFilesViewModel.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let revalidation = try XCTUnwrap(try source.range(
            of: "guard automaticCodemapSelectionIsCurrent(",
            range: XCTUnwrap(source.range(
                of: "revalidateAutomaticCodemapSelectionForPublication("
            )).upperBound ..< source.endIndex
        ))
        let commit = try XCTUnwrap(source.range(
            of: "resetAutoCodemapFiles(resolvedTargets)",
            range: revalidation.lowerBound ..< source.endIndex
        ))
        let synchronousCommitRegion = source[revalidation.lowerBound ..< commit.upperBound]
        XCTAssertFalse(synchronousCommitRegion.contains("await"))
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
