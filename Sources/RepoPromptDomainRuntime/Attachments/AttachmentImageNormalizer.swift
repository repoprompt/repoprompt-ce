import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ConvertibleImageFormat: String, Equatable {
    case heic = "HEIC"
    case tiff = "TIFF"
    case bmp = "BMP"
    case avif = "AVIF"
}

enum AttachmentImageNormalizer {
    static let maxSourceDimension = 16384
    static let maxSourcePixelCount = 67_108_864
    static let jpegQuality = 0.9

    /// Decodes the first frame with its orientation applied and re-encodes it as PNG when it carries
    /// alpha, JPEG otherwise.
    static func normalize(
        _ bytes: Data,
        format: ConvertibleImageFormat,
        fileName: String
    ) throws(AttachmentClassificationError) -> AttachmentPayload {
        let failed = AttachmentClassificationError.imageConversionFailed(fileName: fileName, format: format.rawValue)
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            width > 0, height > 0
        else { throw failed }
        guard width <= maxSourceDimension, height <= maxSourceDimension,
              width <= maxSourcePixelCount / height
        else {
            throw .imageTooLarge(fileName: fileName, format: format.rawValue)
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height)
        ] as CFDictionary) else { throw failed }

        let hasAlpha = switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        case .alphaOnly, .first, .last, .premultipliedFirst, .premultipliedLast: true
        @unknown default: true
        }
        let output = NSMutableData()
        let type = hasAlpha ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            throw failed
        }
        let options: CFDictionary? = hasAlpha
            ? nil
            : [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { throw failed }
        return .image(hasAlpha ? .png : .jpeg, output as Data)
    }
}
