import Foundation
import XCTest

final class CodemapGraphNativeDeletionRegressionTests: XCTestCase {
    func testProductionSourcesContainNoLegacyCodemapProjectionAuthority() throws {
        let repoRoot = try RepoRoot.url()
        let sourceRoot = repoRoot.appendingPathComponent("Sources", isDirectory: true)
        let removedFileNames = [
            "WorkspaceCodemap" + "ProjectionPreloadModels.swift",
            "WorkspaceCodemapSelectionGraph" + "RuntimeModels.swift",
            "WorkspaceCodemapStoreSelectionGraph" + "Models.swift",
            "WorkspaceCodemapStructure" + "PresentationModels.swift",
            "WorkspaceCodemapStructure" + "TraversalModels.swift"
        ]
        let forbiddenSymbols = [
            "WorkspaceCodemap" + "ProjectionDemand",
            "Projection" + "PreloadJob",
            "scheduleProjection" + "Preload",
            "planAutomaticSelection" + "Candidates",
            "WorkspaceCodemap" + "ProjectionSegment",
            "WorkspaceCodemapAutomaticSelectionPublication" + "Permit",
            "WorkspaceCodemapAutomaticSelectionPublication" + "Lease",
            "publishLegacyConsumer" + "GraphBridge",
            "acceptCodemap" + "ProjectionSnapshot",
            "graph" + "Contributions(",
            "consumeGraph" + "Snapshot(",
            "fullRecompute" + "Comparator",
            "CodemapProjection" + "DemandRecord",
            "CodemapProjection" + "PreloadLaunch",
            "CodemapProjection" + "PreloadRetry",
            "CodemapProjection" + "RecoveryObserver",
            "WorkspaceCodemapProjection" + "CoverageProof",
            "WorkspaceCodemapProjection" + "Snapshot",
            "WorkspaceCodemapCurrentProjection" + "Snapshot",
            "WorkspaceCodemapAutomaticSelectionPublication" + "Receipt",
            "WorkspaceCodemapAutomaticSelectionPublication" + "Disposition",
            "WorkspaceCodemapStructureTraversalPublication" + "Receipt",
            "WorkspaceCodemapSelectionGraphRuntimeRebuild" + "Disposition",
            "CodemapSelectionGraph" + "State",
            "CodemapGraphPublication" + "Flight",
            "codemapGraphPublication" + "FlightID",
            "codemapProjectionSnapshotsByRoot" + "Epoch",
            "codemapProjectionDemandsBy" + "ID",
            "codemapProjectionPreloadLaunchesByRoot" + "Epoch",
            "codemapProjectionPreloadRetriesByRoot" + "Epoch",
            "codemapProjectionRecovery" + "Observer",
            "codemapAutomaticSelectionPublicationPermitsByRoot" + "Epoch",
            "acceptCodemapProjectionStatus" + "Snapshot",
            "applyProjection" + "Snapshot",
            "applyEquivalentProjection" + "Successor",
            "prepareCompletedProjection" + "Successor",
            "commitCompletedProjection" + "Successor",
            "currentCompleted" + "Projection",
            "prepared" + "Seal",
            "staged" + "Projection",
            "projection" + "Coverage",
            "projection" + "Accounting",
            "observed" + "Key",
            "previousDesired" + "Key",
            "observeDesired" + "Key",
            "publication" + "Basis",
            "successor" + "Proof",
            "waitForCurrentProjection" + "Coverage",
            "refreshProjectionAutomaticCodemapSelection" + "Result",
            "revalidateProjectionAutomaticCodemapSelectionForPublication" + "Unreleased",
            "runCodemapGraphPublication" + "Flight",
            "startCodemapGraphPublication" + "Flight",
            "finishCodemapGraphPublication" + "Flight",
            "scheduleDirtyCodemapGraphPublicationIf" + "Unfenced",
            "armCodemapProjectionRecovery" + "Observer",
            "runCodemapProjectionRecovery" + "Observer",
            "scheduleCodemapProjectionPreload" + "Retry",
            "performCodemapProjectionPreload" + "Retry",
            "graph" + "Rebuilding",
            "lastRebuild" + "Disposition"
        ]

        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ))
        var encounteredFileNames = Set<String>()
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            encounteredFileNames.insert(fileURL.lastPathComponent)
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            for symbol in forbiddenSymbols {
                XCTAssertFalse(
                    source.contains(symbol),
                    "\(fileURL.path) retains deleted codemap authority symbol \(symbol)"
                )
            }
        }
        XCTAssertTrue(
            encounteredFileNames.isDisjoint(with: removedFileNames),
            "A deleted codemap authority source file remains"
        )
    }
}
