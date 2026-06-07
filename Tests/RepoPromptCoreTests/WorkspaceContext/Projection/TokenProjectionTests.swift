@testable import RepoPromptCore
import XCTest

final class TokenProjectionTests: XCTestCase {
    func testProvenanceAxesRemainIndependent() {
        let normalized = TokenProjection.Provenance(
            view: .normalized,
            scope: .selection,
            source: .activeLive,
            basis: .componentEstimate
        )
        let configured = TokenProjection.Provenance(
            view: .userConfigured,
            scope: .workspace,
            source: .virtualRecomputed,
            basis: .exactRenderedPayload
        )
        let snapshotExport = TokenProjection.Provenance(
            view: .normalized,
            scope: .export,
            source: .immutableSnapshot,
            basis: .exactRenderedPayload
        )
        let preflightExport = TokenProjection.Provenance(
            view: .userConfigured,
            scope: .export,
            source: .activeLive,
            basis: .renderedPayloadEstimate
        )

        XCTAssertNotEqual(normalized, configured)
        XCTAssertEqual(normalized.view, .normalized)
        XCTAssertEqual(configured.view, .userConfigured)
        XCTAssertEqual(normalized.scope, .selection)
        XCTAssertEqual(configured.scope, .workspace)
        XCTAssertEqual(snapshotExport.scope, .export)
        XCTAssertEqual(normalized.source, .activeLive)
        XCTAssertEqual(configured.source, .virtualRecomputed)
        XCTAssertEqual(snapshotExport.source, .immutableSnapshot)
        XCTAssertEqual(normalized.basis, .componentEstimate)
        XCTAssertEqual(configured.basis, .exactRenderedPayload)
        XCTAssertEqual(preflightExport.basis, .renderedPayloadEstimate)
        XCTAssertNotEqual(preflightExport, snapshotExport)
    }

    func testComponentEstimatePreservesDuplicatePromptArithmetic() {
        let duplicated = TokenCalculationService.calculateComponentBreakdown(
            promptText: "12345678",
            selectedInstructionsText: "1234",
            fileTreeText: "12345678",
            gitDiffText: "1234",
            metadataText: "1234",
            duplicateUserInstructionsAtTop: true
        )
        let withoutDuplicate = TokenCalculationService.calculateComponentBreakdown(
            promptText: "12345678",
            selectedInstructionsText: "1234",
            fileTreeText: "12345678",
            gitDiffText: "1234",
            metadataText: "1234",
            duplicateUserInstructionsAtTop: false
        )
        let selection = makeSelection()

        let duplicatedProjection = TokenProjectionService.workspaceComponentEstimates(
            from: selection,
            source: .immutableSnapshot,
            nonFile: .init(breakdown: duplicated)
        ).normalized
        let singleProjection = TokenProjectionService.workspaceComponentEstimates(
            from: selection,
            source: .immutableSnapshot,
            nonFile: .init(breakdown: withoutDuplicate)
        ).normalized

        XCTAssertEqual(duplicated.promptDisplay, 4)
        XCTAssertEqual(duplicated.totalNonFile, 9)
        XCTAssertEqual(duplicatedProjection.components.prompt, 4)
        XCTAssertEqual(duplicatedProjection.total, 141)
        XCTAssertEqual(withoutDuplicate.promptDisplay, 2)
        XCTAssertEqual(withoutDuplicate.totalNonFile, 7)
        XCTAssertEqual(singleProjection.total, 139)
    }

    func testComponentEstimateDistinguishesAbsentFromKnownZero() {
        let absent = TokenProjectionService.componentEstimate(
            view: .normalized,
            scope: .workspace,
            source: .immutableSnapshot,
            components: .init()
        )
        let knownZero = TokenProjectionService.componentEstimate(
            view: .normalized,
            scope: .workspace,
            source: .immutableSnapshot,
            components: .init(
                files: 0,
                prompt: 0,
                fileTree: 0,
                meta: 0,
                git: 0,
                other: 0,
                filesContent: 0,
                codemaps: 0
            )
        )

        XCTAssertEqual(absent.total, 0)
        XCTAssertEqual(knownZero.total, 0)
        XCTAssertNotEqual(absent.components, knownZero.components)
        XCTAssertNil(absent.components.files)
        XCTAssertEqual(knownZero.components.files, 0)
        XCTAssertNil(absent.components.codemaps)
        XCTAssertEqual(knownZero.components.codemaps, 0)
    }

    func testSelectionCompositionPreservesNormalizedConfiguredAndHiddenTotals() throws {
        let normalized = try XCTUnwrap(TokenProjectionService.selectionProjection(
            from: makeSelection(),
            view: .normalized,
            source: .immutableSnapshot
        ))
        XCTAssertEqual(normalized.total, 132)
        XCTAssertEqual(normalized.components.filesContent, 120)
        XCTAssertEqual(normalized.components.codemaps, 12)

        let selected = try XCTUnwrap(TokenProjectionService.selectionProjection(
            from: makeSelection(alternate: .init(
                codeMapUsage: .selected,
                includesFiles: true,
                contentTokens: 0,
                codemapTokens: 21,
                totalTokens: 21,
                includedTotalTokens: 21
            )),
            view: .userConfigured,
            source: .immutableSnapshot
        ))
        XCTAssertEqual(selected.total, 21)
        XCTAssertEqual(selected.components.filesContent, 0)
        XCTAssertEqual(selected.components.codemaps, 21)

        let complete = try XCTUnwrap(TokenProjectionService.selectionProjection(
            from: makeSelection(alternate: .init(
                codeMapUsage: .complete,
                includesFiles: true,
                contentTokens: 0,
                codemapTokens: 33,
                totalTokens: 33,
                includedTotalTokens: 33
            )),
            view: .userConfigured,
            source: .immutableSnapshot
        ))
        XCTAssertEqual(complete.total, 33)
        XCTAssertEqual(complete.components.filesContent, 0)
        XCTAssertEqual(complete.components.codemaps, 33)

        let none = try XCTUnwrap(TokenProjectionService.selectionProjection(
            from: makeSelection(alternate: .init(
                codeMapUsage: .none,
                includesFiles: true,
                contentTokens: 120,
                codemapTokens: 0,
                totalTokens: 120,
                includedTotalTokens: 120
            )),
            view: .userConfigured,
            source: .immutableSnapshot
        ))
        XCTAssertEqual(none.total, 120)
        XCTAssertEqual(none.components.filesContent, 120)
        XCTAssertEqual(none.components.codemaps, 0)

        let selectedWithoutFiles = try XCTUnwrap(TokenProjectionService.selectionProjection(
            from: makeSelection(alternate: .init(
                codeMapUsage: .selected,
                includesFiles: false,
                contentTokens: 0,
                codemapTokens: 21,
                totalTokens: 21,
                includedTotalTokens: 12
            )),
            view: .userConfigured,
            source: .immutableSnapshot
        ))
        XCTAssertEqual(selectedWithoutFiles.total, 12)
        XCTAssertEqual(selectedWithoutFiles.components.filesContent, 0)
        XCTAssertEqual(selectedWithoutFiles.components.codemaps, 12)

        let noneWithoutFiles = try XCTUnwrap(TokenProjectionService.selectionProjection(
            from: makeSelection(alternate: .init(
                codeMapUsage: .none,
                includesFiles: false,
                contentTokens: 120,
                codemapTokens: 0,
                totalTokens: 120,
                includedTotalTokens: 0
            )),
            view: .userConfigured,
            source: .immutableSnapshot
        ))
        XCTAssertEqual(noneWithoutFiles.total, 0)
        XCTAssertEqual(noneWithoutFiles.components.filesContent, 0)
        XCTAssertEqual(noneWithoutFiles.components.codemaps, 0)
    }

    func testVirtualWorkspaceReplacesOnlyFileProjectionAndOmitsZeroOptionals() throws {
        let selection = makeSelection(alternate: .init(
            codeMapUsage: .selected,
            includesFiles: true,
            contentTokens: 0,
            codemapTokens: 21,
            totalTokens: 21,
            includedTotalTokens: 21
        ))
        let projections = TokenProjectionService.workspaceComponentEstimates(
            from: selection,
            source: .virtualRecomputed,
            nonFile: .init(prompt: 4, fileTree: 2, meta: 1, git: 1, other: 0)
        )
        let configured = try XCTUnwrap(projections.userConfigured)

        XCTAssertEqual(projections.normalized.total, 140)
        XCTAssertEqual(configured.total, 29)
        XCTAssertEqual(projections.normalized.components.prompt, configured.components.prompt)
        XCTAssertEqual(projections.normalized.components.fileTree, configured.components.fileTree)
        XCTAssertEqual(projections.normalized.components.meta, configured.components.meta)
        XCTAssertEqual(projections.normalized.components.git, configured.components.git)
        XCTAssertNil(projections.normalized.components.other)
        XCTAssertNil(configured.components.other)
        XCTAssertEqual(projections.normalized.components.files, 132)
        XCTAssertEqual(configured.components.files, 21)
        XCTAssertEqual(projections.normalized.components.filesContent, 120)
        XCTAssertNil(configured.components.filesContent)
        XCTAssertEqual(projections.normalized.components.codemaps, 12)
        XCTAssertEqual(configured.components.codemaps, 21)

        let empty = TokenProjectionService.workspaceComponentEstimates(
            from: makeEmptySelection(),
            source: .virtualRecomputed,
            nonFile: .init(prompt: 0, fileTree: 0, meta: 0, git: 0)
        ).normalized
        XCTAssertEqual(empty.components.files, 0)
        XCTAssertNil(empty.components.prompt)
        XCTAssertNil(empty.components.fileTree)
        XCTAssertNil(empty.components.meta)
        XCTAssertNil(empty.components.git)
        XCTAssertNil(empty.components.other)
        XCTAssertNil(empty.components.filesContent)
        XCTAssertNil(empty.components.codemaps)
    }

    func testActiveLiveRepairsTotalsAndPreservesKnownZeroComponents() {
        let selection = makeSelection()
        let zeroReported = TokenProjectionService.activeLiveWorkspaceEstimates(
            from: selection,
            input: .init(reportedTotal: 0, prompt: 4, fileTree: 2, meta: 1, git: 1)
        ).normalized
        let belowComponents = TokenProjectionService.activeLiveWorkspaceEstimates(
            from: selection,
            input: .init(reportedTotal: 139, prompt: 4, fileTree: 2, meta: 1, git: 1)
        ).normalized
        let residual = TokenProjectionService.activeLiveWorkspaceEstimates(
            from: selection,
            input: .init(reportedTotal: 150, prompt: 4, fileTree: 2, meta: 1, git: 1)
        ).normalized

        XCTAssertEqual(zeroReported.total, 140)
        XCTAssertEqual(zeroReported.components.other, 0)
        XCTAssertEqual(belowComponents.total, 140)
        XCTAssertEqual(belowComponents.components.other, 0)
        XCTAssertEqual(residual.total, 150)
        XCTAssertEqual(residual.components.other, 10)

        let empty = TokenProjectionService.activeLiveWorkspaceEstimates(
            from: makeEmptySelection(),
            input: .init(reportedTotal: 0, prompt: 0, fileTree: 0, meta: 0, git: 0)
        ).normalized
        XCTAssertEqual(empty.components.files, 0)
        XCTAssertEqual(empty.components.prompt, 0)
        XCTAssertEqual(empty.components.fileTree, 0)
        XCTAssertEqual(empty.components.meta, 0)
        XCTAssertEqual(empty.components.git, 0)
        XCTAssertEqual(empty.components.other, 0)
        XCTAssertNil(empty.components.filesContent)
        XCTAssertNil(empty.components.codemaps)
    }

    func testActiveLiveTreeFallbackOnlyReplacesZeroLiveTree() {
        let selection = makeSelection()
        let fallback = TokenProjectionService.activeLiveWorkspaceEstimates(
            from: selection,
            input: .init(
                reportedTotal: 0,
                prompt: 0,
                fileTree: 0,
                meta: 0,
                git: 0,
                requestedFileTreeEstimate: 3
            )
        ).normalized
        let retained = TokenProjectionService.activeLiveWorkspaceEstimates(
            from: selection,
            input: .init(
                reportedTotal: 0,
                prompt: 0,
                fileTree: 2,
                meta: 0,
                git: 0,
                requestedFileTreeEstimate: 3
            )
        ).normalized

        XCTAssertEqual(fallback.components.fileTree, 3)
        XCTAssertEqual(fallback.total, 135)
        XCTAssertEqual(retained.components.fileTree, 2)
        XCTAssertEqual(retained.total, 134)
    }

    func testActiveLiveConfiguredReplacementPreservesResidualAndComponentFloor() throws {
        let selection = makeSelection(alternate: .init(
            codeMapUsage: .selected,
            includesFiles: true,
            contentTokens: 0,
            codemapTokens: 21,
            totalTokens: 21,
            includedTotalTokens: 21
        ))
        let residual = TokenProjectionService.activeLiveWorkspaceEstimates(
            from: selection,
            input: .init(reportedTotal: 150, prompt: 4, fileTree: 2, meta: 1, git: 1)
        )
        let repaired = TokenProjectionService.activeLiveWorkspaceEstimates(
            from: selection,
            input: .init(reportedTotal: 0, prompt: 4, fileTree: 2, meta: 1, git: 1)
        )
        let residualConfigured = try XCTUnwrap(residual.userConfigured)
        let repairedConfigured = try XCTUnwrap(repaired.userConfigured)

        XCTAssertEqual(residual.normalized.components.other, 10)
        XCTAssertEqual(residualConfigured.total, 39)
        XCTAssertEqual(residualConfigured.components.other, 10)
        XCTAssertEqual(repairedConfigured.total, 29)
        XCTAssertEqual(repairedConfigured.components.other, 0)
    }

    func testWorkspaceComponentEstimateDoesNotDoubleCountCodemapsAndDefaultsOtherToZero() {
        let selection = makeSelection()
        let withoutOther = TokenProjectionService.workspaceComponentEstimates(
            from: selection,
            source: .virtualRecomputed,
            nonFile: .init(prompt: 4, fileTree: 0, meta: 0, git: 0)
        ).normalized
        let withOther = TokenProjectionService.workspaceComponentEstimates(
            from: selection,
            source: .virtualRecomputed,
            nonFile: .init(prompt: 4, fileTree: 0, meta: 0, git: 0, other: 5)
        ).normalized

        XCTAssertEqual(withoutOther.total, 136)
        XCTAssertEqual(withoutOther.components.codemaps, 12)
        XCTAssertNil(withoutOther.components.other)
        XCTAssertEqual(withOther.total, 141)
        XCTAssertEqual(withOther.components.other, 5)
    }

    func testRenderedPayloadEstimateUsesCompleteStringWithoutClaimingExactBytes() {
        let projection = TokenProjectionService.renderedPayloadEstimate(
            "12345678",
            view: .userConfigured,
            source: .activeLive
        )

        XCTAssertEqual(projection.total, TokenCalculationService.estimateTokens(for: "12345678"))
        XCTAssertEqual(projection.provenance, .init(
            view: .userConfigured,
            scope: .export,
            source: .activeLive,
            basis: .renderedPayloadEstimate
        ))
        XCTAssertEqual(projection.components, .init())
    }

    func testExactRenderedPayloadUsesCompleteStringEstimateWithoutInventingComponents() {
        let projection = TokenProjectionService.exactRenderedPayload(
            "12345678",
            view: .userConfigured,
            source: .immutableSnapshot
        )
        let empty = TokenProjectionService.exactRenderedPayload(
            "",
            view: .normalized,
            source: .immutableSnapshot
        )

        XCTAssertEqual(projection.total, TokenCalculationService.estimateTokens(for: "12345678"))
        XCTAssertEqual(projection.provenance, .init(
            view: .userConfigured,
            scope: .export,
            source: .immutableSnapshot,
            basis: .exactRenderedPayload
        ))
        XCTAssertEqual(projection.components, .init())
        XCTAssertEqual(empty.total, 0)
        XCTAssertEqual(empty.components, .init())
    }

    private func makeSelection(
        alternate: WorkspaceSelectionProjection.Alternate? = nil
    ) -> WorkspaceSelectionProjection {
        WorkspaceSelectionProjection(
            files: [],
            slices: [],
            summary: .init(
                fullCount: 1,
                sliceCount: 1,
                codemapCount: 1,
                fullTokens: 100,
                sliceTokens: 20,
                codemapTokens: 12
            ),
            invalidPaths: [],
            codeMapUsage: .auto,
            codemapAutoEnabled: true,
            alternate: alternate
        )
    }

    private func makeEmptySelection() -> WorkspaceSelectionProjection {
        WorkspaceSelectionProjection(
            files: [],
            slices: [],
            summary: .empty,
            invalidPaths: [],
            codeMapUsage: .auto,
            codemapAutoEnabled: true,
            alternate: nil
        )
    }
}
