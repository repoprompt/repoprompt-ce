import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Every entry returns nil rather than failing when a file cannot be rendered within the limits, so
/// an unreadable attachment still produces a tile. Full file bytes are never retained.
package enum AttachmentPreviewRenderer {
    package static let maxPixelSize = 384
    package static let maxSourceDimension = 8192
    package static let maxSourcePixelCount = 16_777_216
    /// PDF 1.7 caps a page at 200 inches, which is 14,400 points.
    package static let maxPDFPageDimension: CGFloat = 14400
    private static let jpegQuality = 0.72

    package static func jpegData(from attachment: OracleAttachment) throws -> Data? {
        try Task.checkCancellation()
        switch attachment.payload {
        case let .image(_, bytes):
            guard let source = CGImageSourceCreateWithData(bytes as CFData, imageSourceOptions) else { return nil }
            return try jpegData(fromImageSource: source)
        case let .pdf(bytes):
            guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
            return try jpegData(fromPDF: CGPDFDocument(provider))
        case .text, .binary:
            return nil
        }
    }

    /// Renders a preview straight from a file without reading it whole. Kinds without a preview give nil.
    package static func jpegData(fromFileAt url: URL, kind: AttachmentKind) throws -> Data? {
        try Task.checkCancellation()
        switch kind {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, imageSourceOptions) else { return nil }
            return try jpegData(fromImageSource: source)
        case .pdf:
            return try jpegData(fromPDF: CGPDFDocument(url as CFURL))
        case .text, .binary:
            return nil
        }
    }

    private static var imageSourceOptions: CFDictionary {
        [kCGImageSourceShouldCache: false] as CFDictionary
    }

    private static func jpegData(fromImageSource source: CGImageSource) throws -> Data? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = sourceDimension(properties[kCGImagePropertyPixelWidth]),
              let height = sourceDimension(properties[kCGImagePropertyPixelHeight]),
              width <= maxSourceDimension, height <= maxSourceDimension,
              width <= maxSourcePixelCount / height
        else {
            try Task.checkCancellation()
            return nil
        }
        try Task.checkCancellation()
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary),
            scaled.width > 0, scaled.height > 0,
            scaled.width <= maxPixelSize, scaled.height <= maxPixelSize
        else {
            try Task.checkCancellation()
            return nil
        }
        try Task.checkCancellation()
        guard let opaque = flattenedOnWhite(scaled) else {
            try Task.checkCancellation()
            return nil
        }
        return try encodeJPEG(opaque)
    }

    private static func jpegData(fromPDF document: CGPDFDocument?) throws -> Data? {
        guard let document, document.numberOfPages >= 1,
              !document.isEncrypted || document.isUnlocked,
              let page = document.page(at: 1)
        else {
            try Task.checkCancellation()
            return nil
        }
        let box = page.getBoxRect(.cropBox)
        let quarterTurned = page.rotationAngle % 180 != 0
        let pageWidth = quarterTurned ? box.height : box.width
        let pageHeight = quarterTurned ? box.width : box.height
        guard pageWidth.isFinite, pageHeight.isFinite, pageWidth > 0, pageHeight > 0,
              pageWidth <= maxPDFPageDimension, pageHeight <= maxPDFPageDimension
        else {
            try Task.checkCancellation()
            return nil
        }
        let scale = CGFloat(maxPixelSize) / max(pageWidth, pageHeight)
        let width = max(1, Int((pageWidth * scale).rounded()))
        let height = max(1, Int((pageHeight * scale).rounded()))
        try Task.checkCancellation()
        guard let context = whiteBitmapContext(width: width, height: height) else { return nil }
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        try Task.checkCancellation()
        guard let rendered = context.makeImage() else { return nil }
        return try encodeJPEG(rendered)
    }

    private static func encodeJPEG(_ image: CGImage) throws -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            try Task.checkCancellation()
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        let finalized = CGImageDestinationFinalize(destination)
        try Task.checkCancellation()
        guard finalized else { return nil }
        return output as Data
    }

    private static func sourceDimension(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value > 0, value.rounded(.towardZero) == value,
              let dimension = Int(exactly: value)
        else { return nil }
        return dimension
    }

    /// JPEG has no alpha channel; matte transparent pixels onto white so
    /// transparent PNG/GIF/WebP screenshots do not render as black.
    private static func flattenedOnWhite(_ image: CGImage) -> CGImage? {
        guard let context = whiteBitmapContext(width: image.width, height: image.height) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private static func whiteBitmapContext(width: Int, height: Int) -> CGContext? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }
}
