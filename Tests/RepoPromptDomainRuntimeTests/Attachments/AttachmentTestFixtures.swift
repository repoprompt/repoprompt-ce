import CoreGraphics
import Foundation
import ImageIO
import RepoPromptDomainRuntime
import UniformTypeIdentifiers
import XCTest

enum AttachmentTestFixtures {
    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
    static let jpegSignature: [UInt8] = [0xFF, 0xD8, 0xFF]

    /// A small opaque gradient encoded by ImageIO in `type`, or nil if this machine cannot encode it.
    static func encodedImage(_ type: UTType, width: Int = 24, height: Int = 16) -> Data? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    static func requireEncodedImage(
        _ type: UTType,
        width: Int = 24,
        height: Int = 16,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Data {
        try XCTUnwrap(encodedImage(type, width: width, height: height), "ImageIO could not encode \(type.identifier)", file: file, line: line)
    }

    static func pdfBytes(extra: Int = 0) -> Data {
        var data = Data("%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n".utf8)
        if extra > 0 { data.append(Data(count: extra)) }
        return data
    }

    static func attachment(_ payload: AttachmentPayload, fileName: String, title: String? = nil) -> OracleAttachment {
        OracleAttachment(payload: payload, fileName: fileName, title: title)
    }

    static func textAttachment(_ text: String, fileName: String, title: String? = nil) -> OracleAttachment {
        attachment(.text(text, Data(text.utf8)), fileName: fileName, title: title)
    }
}
