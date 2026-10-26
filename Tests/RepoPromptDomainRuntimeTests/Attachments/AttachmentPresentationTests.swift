import Foundation
import RepoPromptDomainRuntime
import XCTest

final class AttachmentPresentationTests: XCTestCase {
    private func make(
        _ kind: AttachmentKind,
        _ fileName: String,
        byteCount: Int = 2048,
        preview: AttachmentPreviewAvailability
    ) -> AttachmentPresentation {
        AttachmentPresentation.make(
            facts: AttachmentFacts(kind: kind, fileName: fileName, byteCount: byteCount),
            preview: preview
        )
    }

    func testDecodableImageShowsItsPreviewWithoutBadge() {
        let tile = make(.image, "shot.png", preview: .available)
        XCTAssertEqual(tile.face, .preview)
        XCTAssertEqual(tile.status, .ready)
        XCTAssertEqual(tile.title, "shot.png")
        XCTAssertNil(tile.badge)
    }

    func testImageWithoutPreviewFallsBackToPhotoGlyphWithFormatBadge() {
        let tile = make(.image, "shot.png", preview: .unavailable)
        XCTAssertEqual(tile.face, .glyph(.photo))
        XCTAssertEqual(tile.status, .previewUnavailable)
        XCTAssertEqual(tile.badge, "PNG")
        XCTAssertEqual(tile.caption, AttachmentPresentation.previewUnavailableCaption)
    }

    func testPDFShowsPageOnePreviewWithPDFBadge() {
        let tile = make(.pdf, "spec.pdf", preview: .available)
        XCTAssertEqual(tile.face, .preview)
        XCTAssertEqual(tile.status, .ready)
        XCTAssertEqual(tile.badge, "PDF")
    }

    func testTextFileShowsDocumentGlyphWithExtensionBadge() {
        let tile = make(.text, "sales.csv", preview: .unavailable)
        XCTAssertEqual(tile.face, .glyph(.document))
        XCTAssertEqual(tile.status, .ready)
        XCTAssertEqual(tile.badge, "CSV")
        XCTAssertEqual(tile.title, "sales.csv")
    }

    func testBinaryFileShowsGenericFileGlyphWithExtensionBadge() {
        let tile = make(.binary, "bundle.zip", preview: .unavailable)
        XCTAssertEqual(tile.face, .glyph(.file))
        XCTAssertEqual(tile.status, .ready)
        XCTAssertEqual(tile.badge, "ZIP")
    }

    func testDegenerateFactsNeverProduceABlankTile() {
        for kind in AttachmentKind.allCases {
            let tile = make(kind, "", byteCount: 0, preview: .unavailable)
            XCTAssertFalse(tile.title.isEmpty, "\(kind)")
            XCTAssertFalse(tile.accessibilityLabel.isEmpty, "\(kind)")
        }
    }

    func testFileNameIsReducedToItsLastPathComponent() {
        let facts = AttachmentFacts(kind: .text, fileName: "/Users/someone/private/notes.txt", byteCount: 1)
        XCTAssertEqual(facts.fileName, "notes.txt")
        XCTAssertEqual(AttachmentFacts(kind: .text, fileName: "/", byteCount: 1).fileName, "")
    }

    func testPreviewlessKindsNeverAskForAPreview() {
        XCTAssertTrue(AttachmentFacts(kind: .image, fileName: "a", byteCount: 1).canHavePreview)
        XCTAssertTrue(AttachmentFacts(kind: .pdf, fileName: "a", byteCount: 1).canHavePreview)
        XCTAssertFalse(AttachmentFacts(kind: .text, fileName: "a", byteCount: 1).canHavePreview)
        XCTAssertFalse(AttachmentFacts(kind: .binary, fileName: "a", byteCount: 1).canHavePreview)
    }
}
