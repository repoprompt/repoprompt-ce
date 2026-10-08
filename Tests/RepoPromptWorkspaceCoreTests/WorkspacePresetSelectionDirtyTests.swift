import Foundation
@testable import RepoPromptWorkspaceCore
import XCTest

final class WorkspacePresetSelectionDirtyTests: XCTestCase {
    func testPersistedWhitespaceFilenameMatchesItselfAndDiffersFromUnpaddedDecoy() {
        for name in ["file ", "file\n", "file\t", " "] {
            let exact = (absolute: "/repo/" + name, relative: name)
            let decoyName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let decoy = (absolute: "/repo/" + decoyName, relative: decoyName)
            for presetPath in [exact.absolute, exact.relative] {
                XCTAssertFalse(WorkspacePresetSelectionComparison.isDirty(
                    presetPaths: [presetPath], selectionPaths: [exact]
                ))
                XCTAssertTrue(WorkspacePresetSelectionComparison.isDirty(
                    presetPaths: [presetPath], selectionPaths: [decoy]
                ))
            }
        }
    }

    func testCanonicallyEquivalentUnicodeByteSpellingsRemainDistinctAtActualConsumer() {
        let composed = "caf\u{e9}.txt"
        let decomposed = "cafe\u{301}.txt"
        XCTAssertEqual(composed, decomposed, "Control: Swift String equality folds canonical equivalents")
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8))
        for (saved, current) in [(composed, decomposed), (decomposed, composed)] {
            let selected = (absolute: "/repo/" + current, relative: current)
            XCTAssertTrue(WorkspacePresetSelectionComparison.isDirty(
                presetPaths: ["/repo/" + saved], selectionPaths: [selected]
            ))
            XCTAssertTrue(WorkspacePresetSelectionComparison.isDirty(
                presetPaths: [saved], selectionPaths: [selected]
            ))
            XCTAssertFalse(WorkspacePresetSelectionComparison.isDirty(
                presetPaths: ["/repo/" + current], selectionPaths: [selected]
            ))
        }
    }

    func testAbsoluteRelativeCoverageAndLegacyLexicalGrammarRemainStable() {
        let first = (absolute: "/repo/src/a.txt", relative: "src/a.txt")
        let second = (absolute: "/repo/src/b.txt", relative: "src/b.txt")
        for presetPaths in [
            [first.absolute], [first.relative], [first.absolute, first.relative],
            ["/repo/src/./a.txt", "src/x/../a.txt"], [first.absolute, first.absolute]
        ] {
            XCTAssertFalse(WorkspacePresetSelectionComparison.isDirty(
                presetPaths: presetPaths, selectionPaths: [first]
            ))
        }
        XCTAssertTrue(WorkspacePresetSelectionComparison.isDirty(
            presetPaths: [first.absolute, second.relative], selectionPaths: [first]
        ))
        XCTAssertTrue(WorkspacePresetSelectionComparison.isDirty(
            presetPaths: [first.relative], selectionPaths: [first, second]
        ))
        XCTAssertFalse(WorkspacePresetSelectionComparison.isDirty(
            presetPaths: [second.relative, first.absolute], selectionPaths: [first, second]
        ))
        // Preserve legacy relative coverage across two represented roots; this
        // comparison does not choose or grant authority to either root.
        XCTAssertFalse(WorkspacePresetSelectionComparison.isDirty(
            presetPaths: [first.relative],
            selectionPaths: [first, (absolute: "/other/src/a.txt", relative: first.relative)]
        ))
    }

    func testLegacyEmptyOmissionAndEmptyRelativeDotMarkerRemainStable() {
        XCTAssertNil(WorkspacePresetSelectionComparison.normalizedLegacyComparisonPath(""))
        XCTAssertFalse(WorkspacePresetSelectionComparison.isDirty(presetPaths: [], selectionPaths: []))
        XCTAssertFalse(WorkspacePresetSelectionComparison.isDirty(presetPaths: ["", ""], selectionPaths: []))
        XCTAssertFalse(WorkspacePresetSelectionComparison.isDirty(
            presetPaths: ["", "/repo/a"], selectionPaths: [(absolute: "/repo/a", relative: "a")]
        ))
        XCTAssertTrue(WorkspacePresetSelectionComparison.isDirty(
            presetPaths: [""], selectionPaths: [(absolute: "/repo/a", relative: "a")]
        ))
        XCTAssertFalse(WorkspacePresetSelectionComparison.isDirty(
            presetPaths: ["."], selectionPaths: [(absolute: "/repo", relative: "")]
        ))
    }

    func testInvalidNULComparisonCannotCertifyCleanOrDisappearAsEmpty() {
        XCTAssertNil(WorkspacePresetSelectionComparison.normalizedLegacyComparisonPath("/repo/a\0ignored"))
        XCTAssertTrue(WorkspacePresetSelectionComparison.isDirty(
            presetPaths: ["/repo/a\0ignored"], selectionPaths: []
        ))
        XCTAssertTrue(WorkspacePresetSelectionComparison.isDirty(
            presetPaths: ["/repo/a\0ignored"], selectionPaths: [(absolute: "/repo/a", relative: "a")]
        ))
        XCTAssertTrue(WorkspacePresetSelectionComparison.isDirty(
            presetPaths: ["/repo/a"], selectionPaths: [(absolute: "/repo/a\0ignored", relative: "a")]
        ))
        XCTAssertTrue(WorkspacePresetSelectionComparison.isDirty(
            presetPaths: ["/repo/a"], selectionPaths: [(absolute: "/repo/a", relative: "a\0ignored")]
        ))
    }
}
