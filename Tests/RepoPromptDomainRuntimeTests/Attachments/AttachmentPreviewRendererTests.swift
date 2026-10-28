import CoreGraphics
import Foundation
import ImageIO
import RepoPromptDomainRuntime
import XCTest

final class AttachmentPreviewRendererTests: XCTestCase {
    private func twoPagePDF(width: CGFloat = 612, height: CGFloat = 792) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for gray in [CGFloat(0), 0.5] {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: gray, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    func testPDFRendersPageOneToBoundedJPEG() throws {
        let attachment = AttachmentTestFixtures.attachment(.pdf(try twoPagePDF()), fileName: "doc.pdf")
        let jpeg = try XCTUnwrap(try AttachmentPreviewRenderer.jpegData(from: attachment))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(max(image.width, image.height), AttachmentPreviewRenderer.maxPixelSize)
        XCTAssertLessThan(jpeg.count, 200_000)
    }

    func testPDFFileRenderMatchesInMemoryRender() throws {
        let bytes = try twoPagePDF()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).pdf")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let jpeg = try AttachmentPreviewRenderer.jpegData(fromFileAt: url, kind: .pdf)
        XCTAssertFalse(try XCTUnwrap(jpeg).isEmpty)
        XCTAssertNil(try AttachmentPreviewRenderer.jpegData(fromFileAt: url, kind: .text))
    }

    func testUnrenderablePDFGivesNoPreviewInsteadOfFailing() throws {
        let broken = AttachmentTestFixtures.attachment(.pdf(AttachmentTestFixtures.pdfBytes()), fileName: "broken.pdf")
        XCTAssertNil(try AttachmentPreviewRenderer.jpegData(from: broken))
    }

    func testOversizedPDFPageGivesNoPreview() throws {
        let attachment = AttachmentTestFixtures.attachment(.pdf(try twoPagePDF(width: 20000, height: 20000)), fileName: "huge.pdf")
        XCTAssertNil(try AttachmentPreviewRenderer.jpegData(from: attachment))
    }
}
