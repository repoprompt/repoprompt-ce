import Foundation
import RepoPromptDomainRuntime
import XCTest

final class AttachmentPresentationTests: XCTestCase {
    private func make(
        _ kind: AttachmentKind,
        _ fileName: String,
        byteCount: Int = 2048,
        preview: AttachmentPreviewAvailability,
        route: AttachmentRoute? = nil
    ) -> AttachmentPresentation {
        AttachmentPresentation.make(
            facts: AttachmentFacts(kind: kind, fileName: fileName, byteCount: byteCount),
            preview: preview,
            route: route
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

    func testRefusedFileCarriesTheRefusalReasonOnItsTile() throws {
        let tile = make(.pdf, "spec.pdf", preview: .available, route: .openAIChat)
        guard case let .refused(reason) = tile.status else { return XCTFail("expected refusal, got \(tile.status)") }
        XCTAssertEqual(tile.caption, reason)
        XCTAssertFalse(reason.isEmpty)
        XCTAssertTrue(tile.accessibilityLabel.contains(reason))
    }

    func testRefusalAppearsOnlyForRoutesThatCannotCarryTheKind() {
        XCTAssertEqual(make(.pdf, "spec.pdf", preview: .available, route: .anthropicMessages).status, .ready)
        XCTAssertEqual(make(.pdf, "spec.pdf", preview: .available, route: nil).status, .ready)
        guard case .refused = make(.pdf, "spec.pdf", preview: .available, route: .openAIChat).status else {
            return XCTFail("OpenAI chat cannot carry a PDF")
        }
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

    func testFactsLevelRefusalMatchesThePlannerForEveryRouteAndKind() {
        let samples: [(AttachmentKind, OracleAttachment)] = [
            (.image, AttachmentTestFixtures.attachment(.image(.png, Data([1])), fileName: "a.png")),
            (.pdf, AttachmentTestFixtures.attachment(.pdf(AttachmentTestFixtures.pdfBytes()), fileName: "a.pdf")),
            (.text, AttachmentTestFixtures.textAttachment("hello", fileName: "a.txt")),
            (.binary, AttachmentTestFixtures.attachment(.binary(Data([0, 1])), fileName: "a.bin"))
        ]
        for route in AttachmentRoute.allCases {
            for (kind, attachment) in samples {
                let planned = AttachmentPlanner.plan(
                    OracleAttachmentSet([attachment]),
                    route: route,
                    limits: .production
                )
                let facts = AttachmentFacts(kind: kind, fileName: attachment.fileName, byteCount: attachment.payload.byteCount)
                let warns: Bool = if case .refused = AttachmentPresentation
                    .make(facts: facts, preview: .available, route: route).status { true } else { false }
                let refused: Bool = if case .failure = planned { true } else { false }
                XCTAssertEqual(warns, refused, "\(route) \(kind)")
            }
        }
    }

    func testOversizeTextIsRefusedOnInlineRoutes() {
        let limits = OracleAttachmentLimits.production
        let facts = AttachmentFacts(kind: .text, fileName: "big.log", byteCount: limits.maxInlineTextBytes + 1)
        guard case .refused = AttachmentPresentation.make(facts: facts, preview: .unavailable, route: .anthropicMessages).status else {
            return XCTFail("expected oversize refusal")
        }
    }
}
