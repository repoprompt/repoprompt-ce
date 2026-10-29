import Foundation
import RepoPromptDomainRuntime
import XCTest

#if canImport(ImageIO)
    import CoreGraphics
    import ImageIO
    import UniformTypeIdentifiers

    typealias AttachmentFixtureImageType = UTType
#else
    enum AttachmentFixtureImageType: String {
        case png, jpeg, gif
        var identifier: String {
            rawValue
        }
    }
#endif

enum AttachmentTestFixtures {
    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
    static let jpegSignature: [UInt8] = [0xFF, 0xD8, 0xFF]

    /// A small opaque gradient encoded by ImageIO in `type`, or nil if this machine cannot encode it.
    static func encodedImage(_ type: AttachmentFixtureImageType, width: Int = 24, height: Int = 16) -> Data? {
        #if canImport(ImageIO)
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
        #else
            guard width == 24, height == 16 else { return nil }
            let encoded = switch type {
            case .png: "iVBORw0KGgoAAAANSUhEUgAAABgAAAAQCAIAAACDRijCAAAALUlEQVR4nGOU8n3GQAhsemZCUA0TQRVEglGDhqJBjGeMpahi0ODz2qhBdDQIAKagBFGZiD7DAAAAAElFTkSuQmCC"
            case .jpeg: "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAAQABgDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDjqntv4vwqxRW+ZcS/XcNLD+y5ea2vNfZp9l2Pfy7hz6niY4j2t7X0tbdNd33Ciiivlj6c/9k="
            case .gif: "R0lGODdhGAAQAIEAAMwzGhpN5gAAAAAAACwAAAAAGAAQAEAIOAADCBxIUCCAgwgTKlzIsGHBhwEaSpwoEWJBigAsEsTIsaPHhRoHYgxpkCLJiCZJflzJsqVLlgEBADs="
            }
            return Data(base64Encoded: encoded)
        #endif
    }

    static func requireEncodedImage(
        _ type: AttachmentFixtureImageType,
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
