import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension AIChatImageAttachment {
    static let thumbnailMaxPixelSize = 384

    /// Builds transcript thumbnails from request-scoped Oracle images off the
    /// caller's actor. Full bytes are never retained; each attachment stores a
    /// downscaled JPEG so session files stay small.
    static func thumbnails(from images: [AITransientImage]) async -> [AIChatImageAttachment] {
        guard !images.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) {
            images.compactMap(thumbnail(from:))
        }.value
    }

    private static func thumbnail(from image: AITransientImage) -> AIChatImageAttachment? {
        guard let source = CGImageSourceCreateWithData(image.bytes as CFData, nil),
              let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize
              ] as CFDictionary),
              let opaque = flattenedOnWhite(scaled)
        else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, opaque, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        return AIChatImageAttachment(
            mediaType: image.mediaType.rawValue,
            title: image.normalizedTitle,
            thumbnailData: output as Data
        )
    }

    /// JPEG has no alpha channel; matte transparent pixels onto white so
    /// transparent PNG/GIF/WebP screenshots do not render as black.
    private static func flattenedOnWhite(_ image: CGImage) -> CGImage? {
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        return context.makeImage()
    }
}
