import Foundation
@testable import RepoPromptApp
import XCTest

final class CodemapAutomaticSelectionGraphNativeTests: XCTestCase {
    func testFilesystemTSAndTSXCodeMapsUseCurrentBytesWithoutGitOrManifestAccess() async throws {
        let workspace = try PlainWorkspaceFixture(name: #function)
        try workspace.write(
            """
            export interface AlphaCardProps {
              id: string;
            }

            export class AlphaCardModel {
              title: string;

              constructor(title: string) {
                this.title = title;
              }
            }

            """,
            to: "src/Alpha.ts"
        )
        try workspace.write(
            """
            export interface BetaButtonProps {
              label: string;
            }

            export type BetaButtonState = "idle" | "busy";

            """,
            to: "ui/Beta.tsx"
        )

        let fixture = try CodemapStoreFixture(name: #function, forbidCodeMapGitProcesses: true)
        let store = fixture.makeProductionStore()
        let loaded = try await store.loadRoot(path: workspace.rootURL.path)
        addTeardownBlock {
            await store.unloadRoot(id: loaded.id)
            await fixture.shutdown()
            workspace.cleanup()
        }

        let engine = try fixture.runtime().bindingEngine()
        let rootAccounting = try await waitForGraphCompletion(engine: engine, rootID: loaded.id)
        XCTAssertEqual(rootAccounting.phase, .complete)
        XCTAssertEqual(rootAccounting.retryAttempt, 0)
        XCTAssertEqual(rootAccounting.progress.counts.processedCandidateCount, 2)
        XCTAssertEqual(rootAccounting.progress.counts.terminalExcludedCount, 0)

        let sourceMode = await engine.sourceMode(rootEpoch: rootAccounting.rootEpoch)
        XCTAssertEqual(
            sourceMode,
            WorkspaceCodemapRootSourceMode(sourceKind: .filesystem, manifestMode: .notApplicable)
        )

        let files = await store.files(inRoot: loaded.id)
        let alpha = try XCTUnwrap(files.first { $0.standardizedRelativePath == "src/Alpha.ts" })
        let beta = try XCTUnwrap(files.first { $0.standardizedRelativePath == "ui/Beta.tsx" })

        let pinned = try await requireReadySnapshot(engine: engine, rootEpoch: rootAccounting.rootEpoch)
        XCTAssertTrue(pinned.snapshot.coverage.isComplete)
        XCTAssertEqual(pinned.snapshot.coverage.pendingCount, 0)
        XCTAssertEqual(
            definitions(in: pinned, fileID: alpha.id),
            ["AlphaCardModel", "AlphaCardProps"]
        )
        XCTAssertEqual(
            definitions(in: pinned, fileID: beta.id),
            ["BetaButtonProps", "BetaButtonState"]
        )

        // The preview/interactive demand route must render the same current bytes.
        let presentation = try await WorkspaceCodemapPresentationCoordinator(store: store)
            .presentation(
                for: .exact(fileIDs: [alpha.id, beta.id], completeRootSet: false),
                rootScope: .allLoaded,
                logicalRootDisplayNamesByRootID: [loaded.id: "PlainRoot"]
            )
        XCTAssertEqual(presentation.coverage, .complete)
        XCTAssertEqual(presentation.issues, [])
        let alphaEntry = try XCTUnwrap(presentation.renderedEntriesByFileID[alpha.id])
        let betaEntry = try XCTUnwrap(presentation.renderedEntriesByFileID[beta.id])
        XCTAssertTrue(alphaEntry.text.contains("AlphaCardModel"))
        XCTAssertTrue(alphaEntry.text.contains("AlphaCardProps"))
        XCTAssertTrue(betaEntry.text.contains("BetaButtonProps"))
        XCTAssertTrue(betaEntry.text.contains("BetaButtonState"))
        XCTAssertEqual(alphaEntry.logicalPath.displayPath, "PlainRoot/src/Alpha.ts")

        // Observed before teardown: no manifest writer was ever registered for this root, and no
        // manifest load or write was attempted on any origin.
        let writerState = try await fixture.manifestWriterSessionState()
        XCTAssertEqual(writerState.nextSequence, 1)
        XCTAssertEqual(writerState.activeCount, 0)
        let measurements = await engine.debugManifestMeasurementSnapshot(
            rootEpoch: rootAccounting.rootEpoch
        )
        XCTAssertEqual(measurements.byOrigin, [:])
        let manifestFailures = await engine.debugManifestFailureSnapshot(
            rootEpoch: rootAccounting.rootEpoch
        )
        XCTAssertEqual(manifestFailures.counts, [:])
        XCTAssertNil(manifestFailures.lastFailure)
        XCTAssertEqual(fixture.codeMapGitProcessAttempts.values, [])

        await store.unloadRoot(id: loaded.id)
        let writerStateAfterCleanup = try await fixture.manifestWriterSessionState()
        XCTAssertEqual(writerStateAfterCleanup.nextSequence, 1)
        XCTAssertEqual(writerStateAfterCleanup.activeCount, 0)
        XCTAssertEqual(fixture.codeMapGitProcessAttempts.values, [])
    }

    func testFilesystemSiblingRootsRemainIsolatedAfterWatcherEdit() async throws {
        let workspace = try PlainWorkspaceFixture(name: #function)
        let alphaRoot = try workspace.makeSiblingRoot(named: "alpha")
        let betaRoot = try workspace.makeSiblingRoot(named: "beta")
        try workspace.write(
            "export interface AlphaOnlyProps {\n  id: string;\n}\n",
            to: "src/App.ts",
            in: alphaRoot
        )
        try workspace.write(
            "export interface BetaOnlyProps {\n  id: string;\n}\n",
            to: "src/App.ts",
            in: betaRoot
        )

        let fixture = try CodemapStoreFixture(name: #function, forbidCodeMapGitProcesses: true)
        let store = fixture.makeProductionStore()
        let loadedAlpha = try await store.loadRoot(path: alphaRoot.path)
        let loadedBeta = try await store.loadRoot(path: betaRoot.path)
        addTeardownBlock {
            await store.unloadRoot(id: loadedAlpha.id)
            await store.unloadRoot(id: loadedBeta.id)
            await fixture.shutdown()
            workspace.cleanup()
        }

        let engine = try fixture.runtime().bindingEngine()
        let alphaAccounting = try await waitForGraphCompletion(engine: engine, rootID: loadedAlpha.id)
        let betaAccounting = try await waitForGraphCompletion(engine: engine, rootID: loadedBeta.id)
        XCTAssertNotEqual(alphaAccounting.rootEpoch, betaAccounting.rootEpoch)

        let alphaFiles = await store.files(inRoot: loadedAlpha.id)
        let betaFiles = await store.files(inRoot: loadedBeta.id)
        let alphaFile = try XCTUnwrap(
            alphaFiles.first { $0.standardizedRelativePath == "src/App.ts" }
        )
        let betaFile = try XCTUnwrap(
            betaFiles.first { $0.standardizedRelativePath == "src/App.ts" }
        )
        XCTAssertNotEqual(alphaFile.id, betaFile.id)

        let initialAlpha = try await requireReadySnapshot(
            engine: engine,
            rootEpoch: alphaAccounting.rootEpoch
        )
        let initialBeta = try await requireReadySnapshot(
            engine: engine,
            rootEpoch: betaAccounting.rootEpoch
        )
        XCTAssertEqual(definitions(in: initialAlpha, fileID: alphaFile.id), ["AlphaOnlyProps"])
        XCTAssertEqual(definitions(in: initialBeta, fileID: betaFile.id), ["BetaOnlyProps"])

        // Captured before the mutation, so an immediate unnecessary sibling rebuild cannot escape
        // the comparison below. Attempts rather than completions: a rebuild that has merely started
        // is already a violation.
        let betaBuildsBeforeEdit = fixture.builtSourceTexts.values
            .count(where: { $0.contains("BetaOnlyProps") })

        try workspace.write(
            "export interface AlphaReplacedProps {\n  id: string;\n}\n",
            to: "src/App.ts",
            in: alphaRoot
        )
        await store.replayObservedFileSystemDeltas(
            rootID: loadedAlpha.id,
            deltas: [.fileModified("src/App.ts", Date())]
        )

        // Structure for both roots after the edit. The edited root must show its new symbol; the
        // untouched sibling must still show its own and must not be rebuilt.

        let structure = try await WorkspaceCodemapPresentationCoordinator(store: store)
            .presentation(
                for: .exact(fileIDs: [alphaFile.id, betaFile.id], completeRootSet: false),
                rootScope: .allLoaded
            )
        XCTAssertEqual(structure.coverage, .complete)
        let alphaText = try XCTUnwrap(structure.renderedEntriesByFileID[alphaFile.id]?.text)
        let betaText = try XCTUnwrap(structure.renderedEntriesByFileID[betaFile.id]?.text)
        XCTAssertTrue(alphaText.contains("AlphaReplacedProps"))
        XCTAssertFalse(alphaText.contains("AlphaOnlyProps"))
        XCTAssertFalse(alphaText.contains("BetaOnlyProps"))
        XCTAssertTrue(betaText.contains("BetaOnlyProps"))
        XCTAssertFalse(betaText.contains("AlphaReplacedProps"))
        XCTAssertEqual(
            fixture.builtSourceTexts.values.count(where: { $0.contains("BetaOnlyProps") }),
            betaBuildsBeforeEdit,
            "An edit in one root must not rebuild the sibling root's identically named source"
        )

        let replacedAlpha = try await waitForReadySnapshot(
            engine: engine,
            rootEpoch: alphaAccounting.rootEpoch,
            "edited sibling root maps its new symbol"
        ) { snapshot in
            Self.definitions(in: snapshot, fileID: alphaFile.id) == ["AlphaReplacedProps"]
        }
        XCTAssertFalse(
            definitions(in: replacedAlpha, fileID: alphaFile.id).contains("AlphaOnlyProps")
        )
        XCTAssertNil(replacedAlpha.snapshot.nodesByFileID[betaFile.id])

        let untouchedBeta = try await requireReadySnapshot(
            engine: engine,
            rootEpoch: betaAccounting.rootEpoch
        )
        XCTAssertEqual(definitions(in: untouchedBeta, fileID: betaFile.id), ["BetaOnlyProps"])
        XCTAssertTrue(untouchedBeta.snapshot.coverage.isComplete)
        XCTAssertNil(untouchedBeta.snapshot.nodesByFileID[alphaFile.id])
        XCTAssertEqual(fixture.codeMapGitProcessAttempts.values, [])
    }

    func testFilesystemAuthorityReplacementAndReloadRejectStaleCompletions() async throws {
        let workspace = try PlainWorkspaceFixture(name: #function)
        try workspace.write(
            "export interface StaleAlphaProps {\n  id: string;\n}\n",
            to: "src/App.ts"
        )
        try workspace.write(
            "export interface StaleLegacyProps {\n  id: string;\n}\n",
            to: "src/Legacy.ts"
        )
        // A cataloged top-level `HEAD` with no `objects` or `refs` is still definite non-Git
        // evidence, and its removal is a repository-control delta. Recovery has to be able to
        // apply that delta itself instead of re-entering root-authority detachment.
        try workspace.write("ref: refs/heads/main\n", to: "HEAD")

        let staleBuildGate = TestReleaseFence(name: "stale filesystem artifact build")
        let gatedTexts = CodemapLockedValues<String>()
        let fixture = try CodemapStoreFixture(
            name: #function,
            forbidCodeMapGitProcesses: true,
            beforeArtifactBuild: { text in
                guard text.contains("StaleGammaProps"), gatedTexts.values.isEmpty else { return }
                gatedTexts.append(text)
                await staleBuildGate.enterAndWait()
            }
        )
        let store = fixture.makeProductionStore()
        let loaded = try await store.loadRoot(path: workspace.rootURL.path)
        addTeardownBlock {
            staleBuildGate.release()
            await store.unloadRoot(id: loaded.id)
            await fixture.shutdown()
            workspace.cleanup()
        }

        let engine = try fixture.runtime().bindingEngine()
        let originalAccounting = try await waitForGraphCompletion(engine: engine, rootID: loaded.id)
        let rootEpoch = originalAccounting.rootEpoch
        let originalFiles = await store.files(inRoot: loaded.id)
        let originalFile = try XCTUnwrap(
            originalFiles.first { $0.standardizedRelativePath == "src/App.ts" }
        )
        let maybeOriginalGraph = await engine.selectionGraph(rootEpoch: rootEpoch)
        let originalGraph = try XCTUnwrap(maybeOriginalGraph)
        let originalSnapshot = try await requireReadySnapshot(engine: engine, rootEpoch: rootEpoch)
        XCTAssertEqual(
            definitions(in: originalSnapshot, fileID: originalFile.id),
            ["StaleAlphaProps"]
        )
        let originalGeneration = try XCTUnwrap(
            Self.filesystemAuthorityGeneration(originalSnapshot.receipt.rootAuthority)
        )

        // Case (a): same-epoch authority replacement while an old artifact build is still in flight.
        try workspace.write(
            "export interface StaleGammaProps {\n  id: string;\n}\n",
            to: "src/App.ts"
        )
        await store.replayObservedFileSystemDeltas(
            rootID: loaded.id,
            deltas: [.fileModified("src/App.ts", Date())]
        )
        let staleBuildEntered = await staleBuildGate.waitUntilEntered(timeout: 30)
        XCTAssertTrue(staleBuildEntered)

        let replacementRoot = try workspace.makeSiblingRoot(named: "replacement")
        try workspace.write(
            "export interface FreshBetaProps {\n  id: string;\n}\n",
            to: "src/App.ts",
            in: replacementRoot
        )
        try workspace.write(
            "export interface FreshOnlyProps {\n  id: string;\n}\n",
            to: "src/Fresh.ts",
            in: replacementRoot
        )
        try workspace.replaceRootDirectory(with: replacementRoot)
        staleBuildGate.release()

        // Nothing announced the replacement: no watcher delta, no interactive demand, and no
        // manual catalog reconciliation. A graph-only structure query is the first consumer, and
        // it must not answer from the retired directory's committed graph.
        let staleStructure = try await store.queryCodemapStructureGraphs(
            seedFileIDs: [originalFile.id],
            direction: nil,
            maximumDepth: 1,
            budget: Self.graphOnlyStructureBudget,
            rootScope: .allLoaded
        )
        XCTAssertEqual(staleStructure.roots.count, 1)
        let staleStructureRoot = try XCTUnwrap(staleStructure.roots.first)
        XCTAssertEqual(staleStructure.status, .pending)
        XCTAssertEqual(staleStructureRoot.status, .pending)
        XCTAssertTrue(
            staleStructureRoot.nodes.isEmpty,
            "A graph-only query must not serve the retired directory's committed graph"
        )
        XCTAssertNil(
            staleStructureRoot.receipt,
            "A retired committed graph must not hand out a receipt for the replaced root"
        )

        // Recovery owns the physical catalog too. The replacement has a different inventory, so a
        // rebuild over the retired catalog would map a file that is gone and omit the new one.
        // The retired `HEAD` must be gone as well: its removal is the repository-control delta that
        // recovery applies under its own barrier.
        try await AsyncTestWait.waitUntil(
            "replacement inventory replaces the retired catalog",
            timeout: 60
        ) {
            await store.files(inRoot: loaded.id)
                .map(\.standardizedRelativePath)
                .sorted() == ["src/App.ts", "src/Fresh.ts"]
        }
        let replacedFiles = await store.files(inRoot: loaded.id)
        let replacedFile = try XCTUnwrap(
            replacedFiles.first { $0.standardizedRelativePath == "src/App.ts" }
        )
        let freshFile = try XCTUnwrap(
            replacedFiles.first { $0.standardizedRelativePath == "src/Fresh.ts" }
        )

        // The ordinary structure consumer must observe the replacement root's current bytes.
        let replacedStructure = try await waitForRenderedStructure(
            store: store,
            rootID: loaded.id,
            relativePath: "src/App.ts",
            "replacement authority renders the current bytes",
            timeout: 60
        ) { $0.contains("FreshBetaProps") }
        XCTAssertFalse(replacedStructure.contains("StaleGammaProps"))
        XCTAssertFalse(replacedStructure.contains("StaleAlphaProps"))

        // The replacement authority must be strictly newer for the same root epoch, and its graph
        // must be rebuilt over the reconciled inventory rather than left empty behind a revoked
        // authority.
        let replacedSnapshot = try await waitForReadySnapshot(
            engine: engine,
            rootEpoch: rootEpoch,
            "replacement authority maps the current bytes",
            timeout: 30
        ) { snapshot in
            guard let generation = Self.filesystemAuthorityGeneration(snapshot.receipt.rootAuthority)
            else { return false }
            return generation > originalGeneration &&
                snapshot.snapshot.coverage.isComplete &&
                Self.definitions(in: snapshot, fileID: freshFile.id) == ["FreshOnlyProps"]
        }
        XCTAssertEqual(replacedSnapshot.receipt.rootEpoch, rootEpoch)
        XCTAssertEqual(definitions(in: replacedSnapshot, fileID: replacedFile.id), ["FreshBetaProps"])
        XCTAssertFalse(
            replacedSnapshot.snapshot.nodesByFileID.values.contains { node in
                node.contribution.sortedUniqueDefinitions.contains("StaleGammaProps") ||
                    node.contribution.sortedUniqueDefinitions.contains("StaleAlphaProps") ||
                    node.contribution.sortedUniqueDefinitions.contains("StaleLegacyProps")
            },
            "A completion from the revoked authority must never publish into the replacement graph"
        )

        // The same graph-only consumer serves again once the replacement graph is current.
        let recoveredStructure = try await store.queryCodemapStructureGraphs(
            seedFileIDs: [replacedFile.id, freshFile.id],
            direction: nil,
            maximumDepth: 1,
            budget: Self.graphOnlyStructureBudget,
            rootScope: .allLoaded
        )
        XCTAssertEqual(
            Set(recoveredStructure.orderedNodeFileIDs),
            [replacedFile.id, freshFile.id]
        )

        XCTAssertTrue(
            fixture.completedSourceTexts.values.contains { $0.contains("StaleGammaProps") },
            "The stale build must actually have completed for its rejection to be meaningful"
        )

        let maybeReplacementGraph = await engine.selectionGraph(rootEpoch: rootEpoch)
        let replacementGraph = try XCTUnwrap(maybeReplacementGraph)
        let staleReceiptDisposition = await replacementGraph.revalidate(
            originalSnapshot.receipt,
            affectedFileIDs: [originalFile.id]
        )
        XCTAssertEqual(staleReceiptDisposition, .invalid(.rootAuthorityMismatch))
        let originalGraphDisposition = await originalGraph.latestSnapshot()
        guard case .revoked = originalGraphDisposition else {
            return XCTFail("The revoked authority's graph must stop serving its old snapshot")
        }

        let replacementExtractionCount = fixture.builtSourceTexts.values
            .count(where: { $0.contains("FreshBetaProps") })
        XCTAssertEqual(replacementExtractionCount, 1)

        // Case (b): a second physical replacement whose catalog reconciliation cannot succeed.
        // `src/App.ts` keeps identical bytes, so only the directory identity changes; the added
        // file is what a completed reconciliation would have to publish.
        let secondReplacementRoot = try workspace.makeSiblingRoot(named: "second-replacement")
        try workspace.write(
            "export interface FreshBetaProps {\n  id: string;\n}\n",
            to: "src/App.ts",
            in: secondReplacementRoot
        )
        try workspace.write(
            "export interface FreshOnlyProps {\n  id: string;\n}\n",
            to: "src/Fresh.ts",
            in: secondReplacementRoot
        )
        try workspace.write(
            "export interface SecondOnlyProps {\n  id: string;\n}\n",
            to: "src/Second.ts",
            in: secondReplacementRoot
        )
        let acceptedReceipt = try XCTUnwrap(recoveredStructure.roots.first?.receipt)
        XCTAssertEqual(acceptedReceipt.rootEpoch, rootEpoch)

        let maybeService = await store.fileSystemServiceForTesting(rootID: loaded.id)
        let service = try XCTUnwrap(maybeService)
        for folder in ["", "src"] {
            await service.setFolderScanFailureCountForTesting(16, folder: folder)
        }
        try workspace.replaceRootDirectory(with: secondReplacementRoot)

        // Receipt acceptance is the first consumer after this replacement: no structure query, no
        // interactive demand. It must reject the receipt rather than confirm the retired binding.
        let revalidation = await store.revalidateCodemapStructureGraphs(recoveredStructure)
        guard case let .invalid(revalidationCode, _)? = revalidation[rootEpoch] else {
            return XCTFail("Receipt acceptance must reject a replaced root binding")
        }
        XCTAssertEqual(revalidationCode, "graph_revalidation_failed")

        // Recovery cannot establish the replacement inventory, so its barrier must keep every
        // admission entrance closed instead of letting work run against the retired catalog. The
        // window is sampled past the original cleanup flight and several reconciliation retries, so
        // the barrier — not the cleanup flight — is what keeps these closed.
        let fenceDeadline = ContinuousClock().now.advanced(by: .milliseconds(1500))
        while ContinuousClock().now < fenceDeadline {
            let fencedDemand = await store.requestCodemapArtifact(forFileID: replacedFile.id)
            guard case let .unavailable(fencedReason) = fencedDemand else {
                return XCTFail("Demand must not be admitted while catalog recovery is unresolved")
            }
            XCTAssertEqual(fencedReason, .busy(retryAfterMilliseconds: nil))
            let fencedPrioritize = await store.prioritizeCodemapGraphIndexNow(rootID: loaded.id)
            XCTAssertEqual(
                fencedPrioritize,
                .unavailable,
                "A build must not be scheduled against the retired inventory"
            )
            let fencedFiles = await store.files(inRoot: loaded.id).map(\.standardizedRelativePath)
            XCTAssertFalse(
                fencedFiles.contains("src/Second.ts"),
                "A failed reconciliation must not be reported as completed recovery"
            )
            try await Task.sleep(for: .milliseconds(50))
        }

        // A non-terminal detach must not discard the outstanding reconciliation requirement.
        // Suspending cancels the recovery task; resume has to restart it under the same barrier,
        // so nothing may be admitted until a scan actually succeeds — not the resume's own
        // schedule, and not an interactive demand or an explicit prioritize arriving after it.
        let unresolvedSuspension = await store.setCodemapGenerationSuspended(
            rootID: loaded.id,
            suspended: true
        )
        XCTAssertEqual(unresolvedSuspension, .changed)
        let unresolvedResume = await store.setCodemapGenerationSuspended(
            rootID: loaded.id,
            suspended: false
        )
        XCTAssertEqual(unresolvedResume, .changed)

        let resumedFenceDeadline = ContinuousClock().now.advanced(by: .milliseconds(750))
        while ContinuousClock().now < resumedFenceDeadline {
            let resumedDemand = await store.requestCodemapArtifact(forFileID: replacedFile.id)
            guard case let .unavailable(resumedReason) = resumedDemand else {
                return XCTFail("Resume must not admit demand while catalog recovery is unresolved")
            }
            XCTAssertEqual(resumedReason, .busy(retryAfterMilliseconds: nil))
            let resumedPrioritize = await store.prioritizeCodemapGraphIndexNow(rootID: loaded.id)
            XCTAssertEqual(
                resumedPrioritize,
                .unavailable,
                "Resume must not schedule a build against the retired inventory"
            )
            let resumedFiles = await store.files(inRoot: loaded.id).map(\.standardizedRelativePath)
            XCTAssertFalse(
                resumedFiles.contains("src/Second.ts"),
                "A still-failing reconciliation must not be reported as completed recovery"
            )
            try await Task.sleep(for: .milliseconds(50))
        }

        // Once the scans can succeed, the restarted recovery has to reconcile the replacement
        // inventory itself. No watcher delta and no manual reconciliation are delivered here, and
        // `src/Second.ts` exists only in the replacement directory, so its discovery can only come
        // from recovery's own scan — and the replacement graph must then index it.
        for folder in ["", "src"] {
            await service.setFolderScanFailureCountForTesting(0, folder: folder)
        }
        let repairedSuspension = await store.setCodemapGenerationSuspended(
            rootID: loaded.id,
            suspended: true
        )
        XCTAssertEqual(repairedSuspension, .changed)
        let repairedResume = await store.setCodemapGenerationSuspended(
            rootID: loaded.id,
            suspended: false
        )
        XCTAssertEqual(repairedResume, .changed)
        try await AsyncTestWait.waitUntil(
            "restarted recovery reconciles the replacement inventory",
            timeout: 60
        ) {
            await store.files(inRoot: loaded.id)
                .map(\.standardizedRelativePath)
                .sorted() == ["src/App.ts", "src/Fresh.ts", "src/Second.ts"]
        }
        let secondFiles = await store.files(inRoot: loaded.id)
        let secondFile = try XCTUnwrap(
            secondFiles.first { $0.standardizedRelativePath == "src/Second.ts" }
        )
        let repairedSnapshot = try await waitForReadySnapshot(
            engine: engine,
            rootEpoch: rootEpoch,
            "restarted recovery releases indexing over the reconciled inventory",
            timeout: 60
        ) { snapshot in
            snapshot.snapshot.coverage.isComplete &&
                Self.definitions(in: snapshot, fileID: secondFile.id) == ["SecondOnlyProps"]
        }
        XCTAssertEqual(definitions(in: repairedSnapshot, fileID: secondFile.id), ["SecondOnlyProps"])

        // Case (c) unloads from an unresolved recovery, so the repair above is undone: the physical
        // binding is replaced once more and this recovery is again denied a successful scan.
        for folder in ["", "src"] {
            await service.setFolderScanFailureCountForTesting(16, folder: folder)
        }
        let thirdReplacementRoot = try workspace.makeSiblingRoot(named: "third-replacement")
        for (path, text) in [
            ("src/App.ts", "export interface FreshBetaProps {\n  id: string;\n}\n"),
            ("src/Fresh.ts", "export interface FreshOnlyProps {\n  id: string;\n}\n"),
            ("src/Second.ts", "export interface SecondOnlyProps {\n  id: string;\n}\n")
        ] {
            try workspace.write(text, to: path, in: thirdReplacementRoot)
        }
        try workspace.replaceRootDirectory(with: thirdReplacementRoot)
        _ = try await store.queryCodemapStructureGraphs(
            seedFileIDs: [secondFile.id],
            direction: nil,
            maximumDepth: 1,
            budget: Self.graphOnlyStructureBudget,
            rootScope: .allLoaded
        )

        // Case (c): unload while recovery is the only outstanding work. It is the sole record of
        // the revoked authority, so the terminal release depends on it reaching the cleanup flight.
        let beforeUnload = await engine.capabilitySnapshotForTesting()
        XCTAssertEqual(beforeUnload.historicalRecordCount, 0)
        await store.unloadRoot(id: loaded.id)
        let afterUnload = await engine.capabilitySnapshotForTesting()
        XCTAssertEqual(afterUnload.activeRecordCount, 0)
        XCTAssertEqual(
            afterUnload.historicalRecordCount,
            1,
            "Unloading during recovery-only work must still terminalize the revoked root epoch"
        )
        let unloadedDemand = await store.requestCodemapArtifact(forFileID: replacedFile.id)
        guard case let .unavailable(unloadedReason) = unloadedDemand else {
            return XCTFail("An unloaded root must not serve demand for its old file handle")
        }
        XCTAssertEqual(unloadedReason, .fileNotCataloged)

        let reloaded = try await store.loadRoot(path: workspace.rootURL.path)
        addTeardownBlock { await store.unloadRoot(id: reloaded.id) }
        let reloadedAccounting = try await waitForGraphCompletion(engine: engine, rootID: reloaded.id)
        XCTAssertNotEqual(reloadedAccounting.rootEpoch, rootEpoch)
        XCTAssertNotEqual(reloadedAccounting.rootEpoch.rootLifetimeID, rootEpoch.rootLifetimeID)

        let reloadedFiles = await store.files(inRoot: reloaded.id)
        let reloadedFile = try XCTUnwrap(
            reloadedFiles.first { $0.standardizedRelativePath == "src/App.ts" }
        )
        let reloadedSnapshot = try await requireReadySnapshot(
            engine: engine,
            rootEpoch: reloadedAccounting.rootEpoch
        )
        XCTAssertEqual(definitions(in: reloadedSnapshot, fileID: reloadedFile.id), ["FreshBetaProps"])
        XCTAssertNil(reloadedSnapshot.snapshot.nodesByFileID[replacedFile.id])
        let maybeReloadedGraph = await engine.selectionGraph(rootEpoch: reloadedAccounting.rootEpoch)
        let reloadedGraph = try XCTUnwrap(maybeReloadedGraph)
        let reloadedStaleDisposition = await reloadedGraph.revalidate(
            replacedSnapshot.receipt,
            affectedFileIDs: [replacedFile.id]
        )
        XCTAssertEqual(reloadedStaleDisposition, .invalid(.rootEpochMismatch))

        // Cold reload reuses the verified content-addressed artifact instead of re-extracting.
        XCTAssertEqual(
            fixture.builtSourceTexts.values.count(where: { $0.contains("FreshBetaProps") }),
            replacementExtractionCount
        )

        // Case (d): unload arriving while the original cleanup is still registered, with another
        // non-terminal detach interposed in between. A retained path invalidation holds the
        // original cleanup open; suspending generation then detaches again, cancelling the
        // authority recovery and taking the revoked epoch's engine with it. That interposed work
        // has to be ordered after the original cleanup rather than dropped onto it, and the unload
        // that follows finds no session, launch, eligibility record or recovery flight left — only
        // the cleanup chain that now owns the epoch — yet still has to terminalize it.
        let reloadedEpoch = reloadedAccounting.rootEpoch
        let pathFlightGate = TestReleaseFence(name: "retained path invalidation flight")
        await store.setCodemapPathInvalidationStageHandlerForTesting { _, _, _ in
            await pathFlightGate.enterAndWait()
        }
        let retainedPathInvalidation = Task {
            await store.replayObservedFileSystemDeltas(
                rootID: reloaded.id,
                deltas: [.fileModified("src/App.ts", Date())]
            )
        }
        addTeardownBlock {
            pathFlightGate.release()
            await retainedPathInvalidation.value
        }
        let pathFlightEntered = await pathFlightGate.waitUntilEntered(timeout: 30)
        XCTAssertTrue(pathFlightEntered)
        await store.setCodemapPathInvalidationStageHandlerForTesting(nil)

        let overlapReplacementRoot = try workspace.makeSiblingRoot(named: "overlap-replacement")
        try workspace.write(
            "export interface FreshBetaProps {\n  id: string;\n}\n",
            to: "src/App.ts",
            in: overlapReplacementRoot
        )
        try workspace.replaceRootDirectory(with: overlapReplacementRoot)
        _ = try await store.queryCodemapStructureGraphs(
            seedFileIDs: [reloadedFile.id],
            direction: nil,
            maximumDepth: 1,
            budget: Self.graphOnlyStructureBudget,
            rootScope: .allLoaded
        )

        // Suspension is the interposed non-terminal detach. It reaches the store whether or not
        // the authority replacement above has already been accepted, and in both orderings it
        // leaves the epoch registered with the engine and no session holding it.
        let suspension = await store.setCodemapGenerationSuspended(
            rootID: reloaded.id,
            suspended: true
        )
        XCTAssertEqual(suspension, .changed)

        async let overlappedUnload: Void = store.unloadRoot(id: reloaded.id)
        pathFlightGate.release()
        await overlappedUnload
        await retainedPathInvalidation.value
        let afterOverlappedUnload = await engine.capabilitySnapshotForTesting()
        XCTAssertEqual(afterOverlappedUnload.activeRecordCount, 0)
        XCTAssertEqual(
            afterOverlappedUnload.historicalRecordCount,
            2,
            "Unload after an interposed detach must still terminalize the replaced root epoch"
        )

        // Case (e): unload after the cleanup chain has fully drained. Suspension detaches the
        // engine while the root stays loaded, so once that chain deregisters no session, flight,
        // recovery or eligibility record names the epoch at all — yet the engine still holds it,
        // including the capability record whose release writes the epoch's tombstone.
        let quiescedRoot = try await store.loadRoot(path: workspace.rootURL.path)
        addTeardownBlock { await store.unloadRoot(id: quiescedRoot.id) }
        _ = try await waitForGraphCompletion(engine: engine, rootID: quiescedRoot.id)
        let beforeQuiescedUnload = await engine.capabilitySnapshotForTesting()
        XCTAssertEqual(beforeQuiescedUnload.activeRecordCount, 1)
        let quiescedSuspension = await store.setCodemapGenerationSuspended(
            rootID: quiescedRoot.id,
            suspended: true
        )
        XCTAssertEqual(quiescedSuspension, .changed)
        // Returns only after the cleanup flight registered by that suspension has drained and
        // deregistered, so the unload below starts from a root with no outstanding codemap work.
        await store.fenceCodemapAuthorityForCheckoutMutation(rootIDs: [quiescedRoot.id])
        await store.unloadRoot(id: quiescedRoot.id)
        let afterQuiescedUnload = await engine.capabilitySnapshotForTesting()
        XCTAssertEqual(afterQuiescedUnload.activeRecordCount, 0)
        XCTAssertEqual(
            afterQuiescedUnload.historicalRecordCount,
            3,
            "Unload after the cleanup chain drained must still terminalize the suspended root epoch"
        )
        XCTAssertEqual(fixture.codeMapGitProcessAttempts.values, [])
    }

    func testUnrelatedGitIndexChurnDoesNotRestartGraphPage() async throws {
        let repository = try ReviewGitRepositoryFixture(name: #function)
        let rootURL = try repository.makeRepository(
            named: "root",
            files: [
                "Sources/First.swift": "struct First {}\n",
                "Sources/Second.swift": "struct Second {}\n"
            ]
        )
        let indexURL = rootURL.appendingPathComponent(".git/index")
        let authorityCaptures = CodemapLockedValues<Int>()
        let fixture = try CodemapStoreFixture(
            name: #function,
            capabilityHooks: WorkspaceCodemapRootCapabilityServiceHooks(
                afterFirstAuthorityCapture: {
                    let shouldChurn = !authorityCaptures.values.isEmpty
                    authorityCaptures.append(1)
                    if shouldChurn {
                        try? FileManager.default.setAttributes(
                            [.modificationDate: Date()],
                            ofItemAtPath: indexURL.path
                        )
                    }
                }
            )
        )
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: rootURL.path)
        addTeardownBlock {
            await store.unloadRoot(id: loaded.id)
            await fixture.shutdown()
            repository.cleanup()
        }

        let engine = try fixture.runtime().bindingEngine()
        let rootAccounting = try await waitForGraphCompletion(
            engine: engine,
            rootID: loaded.id
        )

        XCTAssertEqual(rootAccounting.phase, .complete)
        XCTAssertEqual(rootAccounting.retryAttempt, 0)
        XCTAssertNil(rootAccounting.retry)
        XCTAssertEqual(rootAccounting.progress.counts.processedCandidateCount, 2)
        XCTAssertGreaterThan(authorityCaptures.values.count, 1)
        let accounting = await engine.accounting()
        XCTAssertEqual(accounting.counters.graphIndexRetries, 0)
    }

    func testNestedRepositoryGraphUsesValidatedWorktreeBytesAndCompletesWithoutRetry() async throws {
        let repository = try ReviewGitRepositoryFixture(name: #function)
        let relativePath = "Nested/Sources/Feature.swift"
        let rootURL = try repository.makeRepository(
            named: "outer",
            files: [relativePath: "struct OuterBlobOnly { let value: Int }\n"]
        )
        let nestedRoot = rootURL.appendingPathComponent("Nested", isDirectory: true)
        try repository.initializeRepository(at: nestedRoot)
        try repository.write(
            "struct NestedWorktreeOnly { let value: Int }\n",
            to: "Sources/Feature.swift",
            at: nestedRoot
        )
        try repository.stage("Sources/Feature.swift", at: nestedRoot)
        try repository.commit("Nested worktree content", at: nestedRoot)

        let outerBlob = try repository.runGit(["show", "HEAD:\(relativePath)"], at: rootURL)
        let worktreeBytes = try String(
            contentsOf: rootURL.appendingPathComponent(relativePath),
            encoding: .utf8
        )
        XCTAssertTrue(outerBlob.contains("OuterBlobOnly"))
        XCTAssertTrue(worktreeBytes.contains("NestedWorktreeOnly"))

        let fixture = try CodemapStoreFixture(name: #function)
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: rootURL.path)
        addTeardownBlock {
            await store.unloadRoot(id: loaded.id)
            await fixture.shutdown()
            repository.cleanup()
        }

        let files = await store.files(inRoot: loaded.id)
        let nestedFile = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == relativePath
        })
        let engine = try fixture.runtime().bindingEngine()
        let rootAccounting = try await waitForGraphCompletion(
            engine: engine,
            rootID: loaded.id
        )

        XCTAssertEqual(rootAccounting.phase, .complete)
        XCTAssertEqual(rootAccounting.retryAttempt, 0)
        XCTAssertNil(rootAccounting.retry)
        XCTAssertNotNil(rootAccounting.progress.catalogCompletion)
        XCTAssertEqual(rootAccounting.progress.counts.transientCount, 0)
        XCTAssertEqual(rootAccounting.progress.counts.terminalExcludedCount, 0)

        let accounting = await engine.accounting()
        XCTAssertEqual(accounting.counters.graphIndexRetries, 0)
        let maybeGraph = await engine.selectionGraph(rootEpoch: rootAccounting.rootEpoch)
        let graph = try XCTUnwrap(maybeGraph)
        let pinned: WorkspaceCodemapGraphPinnedSnapshot
        switch await graph.latestSnapshot() {
        case let .ready(snapshot):
            pinned = snapshot
        case .pending:
            return XCTFail("Completed graph index should publish a graph snapshot")
        case let .revoked(reason):
            return XCTFail("Completed graph index should not be revoked: \(reason)")
        }

        XCTAssertTrue(pinned.snapshot.coverage.isComplete)
        XCTAssertEqual(pinned.snapshot.coverage.pendingCount, 0)
        XCTAssertEqual(pinned.snapshot.coverage.terminalExcludedCount, 0)
        let node = try XCTUnwrap(pinned.snapshot.nodesByFileID[nestedFile.id])
        XCTAssertTrue(node.contribution.sortedUniqueDefinitions.contains("NestedWorktreeOnly"))
        XCTAssertFalse(node.contribution.sortedUniqueDefinitions.contains("OuterBlobOnly"))
        guard case .contributed = pinned.snapshot.slotsByFileID[nestedFile.id]?.state else {
            return XCTFail("Nested source should contribute to the completed graph")
        }
        XCTAssertFalse(pinned.snapshot.slotsByFileID.values.contains { slot in
            if case .terminalExcluded(.repositoryBoundary) = slot.state { return true }
            return false
        })
        XCTAssertTrue(fixture.builtSourceTexts.values.contains { $0.contains("NestedWorktreeOnly") })
        XCTAssertFalse(fixture.builtSourceTexts.values.contains { $0.contains("OuterBlobOnly") })
    }

    private func waitForGraphCompletion(
        engine: WorkspaceCodemapBindingEngine,
        rootID: UUID,
        timeout: Duration = .seconds(20)
    ) async throws -> WorkspaceCodemapBindingEngineGraphIndexRootAccounting {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let accounting = await engine.accounting()
            if let root = accounting.graphIndexRoots.first(where: { $0.rootEpoch.rootID == rootID }),
               root.phase == .complete
            {
                return root
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw GraphWaitError.timedOut
    }

    private func requireReadySnapshot(
        engine: WorkspaceCodemapBindingEngine,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) async throws -> WorkspaceCodemapGraphPinnedSnapshot {
        let maybeGraph = await engine.selectionGraph(rootEpoch: rootEpoch)
        let graph = try XCTUnwrap(maybeGraph)
        switch await graph.latestSnapshot() {
        case let .ready(snapshot):
            return snapshot
        case .pending:
            throw GraphWaitError.snapshotPending
        case let .revoked(reason):
            throw GraphWaitError.snapshotRevoked(String(describing: reason))
        }
    }

    /// Waits for a ready snapshot of the newest graph installed for `rootEpoch` that satisfies
    /// `matching`. Same-epoch authority replacement installs a new graph, so the lookup is repeated
    /// on every attempt rather than pinned once.
    private func waitForReadySnapshot(
        engine: WorkspaceCodemapBindingEngine,
        rootEpoch: WorkspaceCodemapRootEpoch,
        _ description: String,
        timeout: TimeInterval = 30,
        matching: @escaping @Sendable (WorkspaceCodemapGraphPinnedSnapshot) -> Bool
    ) async throws -> WorkspaceCodemapGraphPinnedSnapshot {
        let matched = CodemapLockedValues<WorkspaceCodemapGraphPinnedSnapshot>()
        try await AsyncTestWait.waitUntil(description, timeout: timeout) {
            guard let graph = await engine.selectionGraph(rootEpoch: rootEpoch),
                  case let .ready(snapshot) = await graph.latestSnapshot(),
                  matching(snapshot)
            else { return false }
            matched.append(snapshot)
            return true
        }
        return try XCTUnwrap(matched.values.last)
    }

    /// Drives the ordinary structure/preview consumer until it renders matching text. Serving
    /// paths are what re-resolve a root after its authority is replaced, so the wait exercises the
    /// production route rather than polling an idle graph.
    private func waitForRenderedStructure(
        store: WorkspaceFileContextStore,
        rootID: UUID,
        relativePath: String,
        _ description: String,
        timeout: TimeInterval = 30,
        matching: @escaping @Sendable (String) -> Bool
    ) async throws -> String {
        let matched = CodemapLockedValues<String>()
        try await AsyncTestWait.waitUntil(description, timeout: timeout) {
            let files = await store.files(inRoot: rootID)
            guard let file = files.first(where: { $0.standardizedRelativePath == relativePath })
            else { return false }
            guard let presentation = try? await WorkspaceCodemapPresentationCoordinator(store: store)
                .presentation(
                    for: .exact(fileIDs: [file.id], completeRootSet: false),
                    rootScope: .allLoaded
                ),
                let text = presentation.renderedEntriesByFileID[file.id]?.text,
                matching(text)
            else { return false }
            matched.append(text)
            return true
        }
        return try XCTUnwrap(matched.values.last)
    }

    private func definitions(
        in snapshot: WorkspaceCodemapGraphPinnedSnapshot,
        fileID: UUID
    ) -> [String] {
        Self.definitions(in: snapshot, fileID: fileID)
    }

    private static func definitions(
        in snapshot: WorkspaceCodemapGraphPinnedSnapshot,
        fileID: UUID
    ) -> [String] {
        snapshot.snapshot.nodesByFileID[fileID]?.contribution.sortedUniqueDefinitions ?? []
    }

    /// Budget for direct committed-graph structure queries: the graph-only serving path that never
    /// issues interactive artifact demand.
    private static let graphOnlyStructureBudget = WorkspaceCodemapGraphQueryBudget(
        maximumTokenCount: 100_000,
        maximumNodeCount: 64,
        maximumEdgeCount: 256,
        maximumGraphByteCount: 1 << 20,
        graphEvidenceTokenCount: 0,
        renderTokenCount: 0
    )

    private static func filesystemAuthorityGeneration(
        _ token: WorkspaceCodemapRootAuthorityToken
    ) -> UInt64? {
        guard case let .filesystem(_, authorityGeneration) = token else { return nil }
        return authorityGeneration
    }
}

private enum GraphWaitError: Error {
    case timedOut
    case snapshotPending
    case snapshotRevoked(String)
}

/// Owned temporary workspace for plain, non-Git Code Map roots.
private final class PlainWorkspaceFixture: Sendable {
    let sandbox: URL
    let rootURL: URL

    init(name: String) throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlainWorkspaceFixture-\(name)-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        rootURL = sandbox.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func makeSiblingRoot(named name: String) throws -> URL {
        let url = sandbox.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func write(_ contents: String, to relativePath: String, in root: URL? = nil) throws {
        let file = (root ?? rootURL).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Replaces the loaded root with a different physical directory at the same path, which is a
    /// real binding change rather than ordinary content churn.
    func replaceRootDirectory(with replacement: URL) throws {
        let retired = sandbox.appendingPathComponent("retired-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: rootURL, to: retired)
        try FileManager.default.moveItem(at: replacement, to: rootURL)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: sandbox)
    }
}
