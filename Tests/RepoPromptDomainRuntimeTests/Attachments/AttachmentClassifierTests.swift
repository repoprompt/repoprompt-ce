import Foundation
import ImageIO
import RepoPromptDomainRuntime
import UniformTypeIdentifiers
import XCTest

final class AttachmentClassifierTests: XCTestCase {
    func testNativeImageFormatsKeepTheirBytes() throws {
        let png = try AttachmentTestFixtures.requireEncodedImage(.png)
        let jpeg = try AttachmentTestFixtures.requireEncodedImage(.jpeg)
        let gif = try AttachmentTestFixtures.requireEncodedImage(.gif)

        XCTAssertEqual(try AttachmentClassifier.classify(bytes: png, fileName: "a.png"), .image(.png, png))
        XCTAssertEqual(try AttachmentClassifier.classify(bytes: jpeg, fileName: "a.jpg"), .image(.jpeg, jpeg))
        XCTAssertEqual(try AttachmentClassifier.classify(bytes: gif, fileName: "a.gif"), .image(.gif, gif))
    }

    func testWebPIsRecognizedByItsRIFFHeader() throws {
        var webp = Data("RIFF".utf8)
        webp.append(contentsOf: [0x1A, 0, 0, 0])
        webp.append(Data("WEBPVP8 ".utf8))
        webp.append(Data(count: 16))

        XCTAssertEqual(try AttachmentClassifier.classify(bytes: webp, fileName: "a.webp"), .image(.webp, webp))
    }

    func testFormatsNoTransportAcceptsAreConvertedToJpegOrPng() throws {
        let sources: [(UTType, String)] = [(.heic, "photo.heic"), (.tiff, "scan.tiff"), (.bmp, "icon.bmp")]
        for (type, name) in sources {
            let original = try AttachmentTestFixtures.requireEncodedImage(type)
            let payload = try AttachmentClassifier.classify(bytes: original, fileName: name)

            guard case let .image(mediaType, converted) = payload else {
                return XCTFail("\(name) classified as \(payload.kind), expected image")
            }
            XCTAssertNotEqual(converted, original, name)
            switch mediaType {
            case .png: XCTAssertTrue(converted.starts(with: AttachmentTestFixtures.pngSignature), name)
            case .jpeg: XCTAssertTrue(converted.starts(with: AttachmentTestFixtures.jpegSignature), name)
            case .gif, .webp: XCTFail("\(name) converted to \(mediaType.rawValue)")
            }
        }
    }

    func testConvertedImageStillDecodesWithItsOriginalDimensions() throws {
        let original = try AttachmentTestFixtures.requireEncodedImage(.tiff, width: 40, height: 30)
        guard case let .image(_, converted) = try AttachmentClassifier.classify(bytes: original, fileName: "a.tiff"),
              let source = CGImageSourceCreateWithData(converted as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return XCTFail("converted TIFF did not decode") }

        XCTAssertEqual(image.width, 40)
        XCTAssertEqual(image.height, 30)
    }

    func testUndecodableConvertibleImageThrowsInsteadOfFallingToBinary() {
        var avif = Data([0, 0, 0, 0x18])
        avif.append(Data("ftypavif".utf8))
        avif.append(contentsOf: [0, 0, 0, 0])
        avif.append(Data("avifmif1".utf8))
        avif.append(Data(repeating: 0xAB, count: 64))

        XCTAssertThrowsError(try AttachmentClassifier.classify(bytes: avif, fileName: "broken.avif")) { error in
            XCTAssertEqual(
                error as? AttachmentClassificationError,
                .imageConversionFailed(fileName: "broken.avif", format: "AVIF")
            )
            XCTAssertTrue(error.localizedDescription.contains("broken.avif"))
        }
    }

    func testPdfIsRecognizedByContentNotExtension() throws {
        let pdf = AttachmentTestFixtures.pdfBytes()

        XCTAssertEqual(try AttachmentClassifier.classify(bytes: pdf, fileName: "disguised.png"), .pdf(pdf))
        XCTAssertEqual(try AttachmentClassifier.classify(bytes: pdf, fileName: "notes.txt"), .pdf(pdf))
    }

    func testTextWithAnImageExtensionIsStillText() throws {
        let bytes = Data("just words\n".utf8)

        XCTAssertEqual(try AttachmentClassifier.classify(bytes: bytes, fileName: "fake.png"), .text("just words\n", bytes))
    }

    func testUTF8TextKeepsDecodedStringAndOriginalBytes() throws {
        let text = "name,note\nZoë,日本語 ✓\n"
        let bytes = Data(text.utf8)

        XCTAssertEqual(try AttachmentClassifier.classify(bytes: bytes, fileName: "people.csv"), .text(text, bytes))
    }

    func testEmptyFileIsEmptyText() throws {
        XCTAssertEqual(try AttachmentClassifier.classify(bytes: Data(), fileName: "empty.txt"), .text("", Data()))
    }

    func testUTF16WithNulBytesIsBinary() throws {
        let bytes = try XCTUnwrap("hello world".data(using: .utf16LittleEndian))

        XCTAssertEqual(try AttachmentClassifier.classify(bytes: bytes, fileName: "wide.txt"), .binary(bytes))
    }

    func testInvalidUTF8IsBinary() throws {
        let bytes = Data([0x68, 0x69, 0xC3, 0x28, 0x0A])

        XCTAssertEqual(try AttachmentClassifier.classify(bytes: bytes, fileName: "latin1.txt"), .binary(bytes))
    }

    func testNulInsideTheProbeWindowIsBinaryEvenWhenValidUTF8() throws {
        var bytes = Data("header".utf8)
        bytes.append(0)
        bytes.append(Data("tail".utf8))

        XCTAssertEqual(try AttachmentClassifier.classify(bytes: bytes, fileName: "blob.txt"), .binary(bytes))
    }

    func testTextThatMerelyStartsWithBMIsNotMistakenForBitmap() throws {
        let bytes = Data("BMW makes cars and this sentence is long enough to look like a header.\n".utf8)

        guard case .text = try AttachmentClassifier.classify(bytes: bytes, fileName: "cars.txt") else {
            return XCTFail("text starting with BM must stay text")
        }
    }

    func testUnrecognizedContainerIsBinary() throws {
        let zip = Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00, 0x08, 0x00, 0xFF, 0xFE])

        XCTAssertEqual(try AttachmentClassifier.classify(bytes: zip, fileName: "archive.zip"), .binary(zip))
    }

    func testAttachmentKeepsOnlyTheLastPathComponentOfItsName() {
        let payload = AttachmentPayload.binary(Data([1]))

        XCTAssertEqual(OracleAttachment(payload: payload, fileName: "/Users/me/secret/report.csv", title: nil).fileName, "report.csv")
        XCTAssertEqual(OracleAttachment(payload: payload, fileName: "a/b/c.txt", title: nil).fileName, "c.txt")
        XCTAssertEqual(OracleAttachment(payload: payload, fileName: "/", title: nil).fileName, OracleAttachment.fallbackFileName)
        XCTAssertEqual(OracleAttachment(payload: payload, fileName: "", title: nil).fileName, OracleAttachment.fallbackFileName)
    }
}
