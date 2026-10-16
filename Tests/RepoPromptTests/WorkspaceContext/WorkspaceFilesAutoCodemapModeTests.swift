@testable import RepoPromptApp
import RepoPromptFileSystem
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

/// Regression coverage for `WorkspaceFilesViewModel`'s store-stream loops.
///
/// `subscribeToWorkspaceStoreDeltaEvents` and
/// `subscribeToCodemapMarkerReadinessUpdates` previously did `guard let self`
/// before a never-ending `for await`, so each task retained the view model for
/// the life of the process — a closed window's whole graph (store, prompt and
/// oracle VMs) could never be released. The loops now capture the store and
/// re-acquire `self` per event, matching the existing
/// `subscribeToCodemapRootStatusUpdates` shape: once the window drops the VM,
/// `deinit` cancels the tasks, the stream iterators terminate, and the store's
/// per-subscriber continuation slots are removed via `onTermination`.
@MainActor
final class WorkspaceFilesViewModelStreamLifetimeTests: XCTestCase {
    private func waitUntil(
        _ condition: @MainActor () async -> Bool,
        timeout: TimeInterval = 5,
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

    /// Releasing the view model must release it: the tasks hold only the store,
    /// `deinit` cancels them, and the store's subscriber slots are freed.
    /// Fails without the fix — the loops retain `self` so the VM never deinits.
    func testViewModelDeallocatesAndStoreStreamsEndAfterRelease() async {
        let store = WorkspaceFileContextStore()
        var viewModel: WorkspaceFilesViewModel? =
            WorkspaceFilesViewModel(workspaceFileContextStore: store)
        weak var weakVM = viewModel

        // Subscriptions register asynchronously from the observation tasks.
        await waitUntil {
            let counts = await store.streamContinuationCountsForTesting()
            return counts.appliedIndex == 1
                && counts.codemapMarkerReadiness == 1
                && counts.codemapRootStatus == 1
        }

        viewModel = nil

        await waitUntil { weakVM == nil }
        await waitUntil {
            let counts = await store.streamContinuationCountsForTesting()
            return counts.appliedIndex == 0
                && counts.codemapMarkerReadiness == 0
                && counts.codemapRootStatus == 0
        }
    }

    /// Releasing one window's view model must not disturb another window's
    /// subscriptions on the same store.
    func testReleasingOneViewModelKeepsSiblingSubscriptionsAlive() async {
        let store = WorkspaceFileContextStore()
        var closingVM: WorkspaceFilesViewModel? =
            WorkspaceFilesViewModel(workspaceFileContextStore: store)
        let liveVM = WorkspaceFilesViewModel(workspaceFileContextStore: store)
        weak var weakClosing = closingVM
        weak var weakLive = liveVM

        await waitUntil {
            let counts = await store.streamContinuationCountsForTesting()
            return counts.appliedIndex == 2
                && counts.codemapMarkerReadiness == 2
                && counts.codemapRootStatus == 2
        }

        closingVM = nil

        await waitUntil { weakClosing == nil }
        await waitUntil {
            let counts = await store.streamContinuationCountsForTesting()
            return counts.appliedIndex == 1
                && counts.codemapMarkerReadiness == 1
                && counts.codemapRootStatus == 1
        }
        XCTAssertNotNil(weakLive)
    }
}
