import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Transcript thumbnails

package enum OracleImageThumbnail {
    package static let maxPixelSize = 384
    package static let maxSourceDimension = 8192
    package static let maxSourcePixelCount = 16_777_216

    /// Renders a bounded, opaque JPEG preview of `image`, or nil when the source cannot be
    /// decoded within the dimension limits. Full image bytes are never retained.
    package static func jpegData(from image: AITransientImage) throws -> Data? {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(image.bytes as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
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

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            try Task.checkCancellation()
            return nil
        }
        CGImageDestinationAddImage(destination, opaque, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
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

// MARK: - Claude stream-json image transport

/// Encodes image-bearing Claude CLI input as one stream-json user line and reads the
/// terminal result/error event back from stream-json output.
package enum ClaudeStreamJSONImageTransport {
    package struct EncodingError: Error {}

    package static func input(prompt: String, images: [AITransientImage]) throws -> String {
        var content: [[String: Any]] = []
        if !prompt.isEmpty {
            content.append(["type": "text", "text": prompt])
        }
        for image in images {
            if let annotation = image.titleAnnotation {
                content.append(["type": "text", "text": annotation])
            }
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": image.mediaType.rawValue,
                    "data": image.base64Payload
                ]
            ])
        }
        let payload: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": content],
            "parent_tool_use_id": NSNull()
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let line = String(data: data, encoding: .utf8) else { throw EncodingError() }
        return line + "\n"
    }

    /// The last `result` or `error` event, with its lowercased type.
    package static func terminalEvent(in data: Data) -> (type: String, payload: [String: Any])? {
        for line in lines(of: data).reversed() {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = (json["type"] as? String)?.lowercased(),
                  type == "result" || type == "error"
            else { continue }
            return (type: type, payload: json)
        }
        return nil
    }

    package static func indicatesError(_ dict: [String: Any]) -> Bool {
        let type = (dict["type"] as? String)?.lowercased()
        let subtype = (dict["subtype"] as? String)?.lowercased()
        let isError = (dict["is_error"] as? Bool) == true
        let hasErrors = (dict["errors"] as? [Any])?.isEmpty == false
        return type == "error" || isError || subtype?.contains("error") == true || hasErrors
    }

    package static func errorMessage(from dict: [String: Any]) -> String? {
        guard indicatesError(dict) else { return nil }
        for error in dict["errors"] as? [Any] ?? [] {
            let text = (error as? String)
                ?? ((error as? [String: Any]).flatMap { ($0["message"] as? String) ?? ($0["error"] as? String) })
            if let text = nonEmpty(text) { return text }
        }
        for key in ["error", "message", "result"] {
            if let text = nonEmpty(dict[key] as? String) { return text }
        }
        return nil
    }

    /// The terminal event's error, or the last plain-text line when the CLI failed before
    /// emitting stream JSON.
    package static func errorDetail(in data: Data) -> String? {
        if let terminal = terminalEvent(in: data) {
            return errorMessage(from: terminal.payload)
        }
        return lines(of: data).last { !$0.hasPrefix("{") && !$0.hasPrefix("[") }
    }

    private static func lines(of data: Data) -> [String] {
        data.split(separator: 0x0A, omittingEmptySubsequences: true).compactMap {
            nonEmpty(String(data: Data($0), encoding: .utf8))
        }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

// MARK: - Temporary file staging

/// Writes request-scoped images into a private (0700) temporary directory for transports that
/// only accept local file paths. Call `cleanup()` once the request finishes.
package struct OracleTransientImageStaging: Sendable {
    package struct File: Sendable {
        package let path: String
        package let title: String?
    }

    package let directory: URL
    package let files: [File]

    package static func stage(_ images: [AITransientImage]) async throws -> Self? {
        guard !images.isEmpty else { return nil }
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("RepoPromptOracleImages-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                var files: [File] = []
                for (index, image) in images.enumerated() {
                    try Task.checkCancellation()
                    let url = directory.appendingPathComponent(
                        "image-\(index).\(image.preferredFileExtension)",
                        isDirectory: false
                    )
                    try image.bytes.write(to: url, options: .withoutOverwriting)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    files.append(File(path: url.path, title: image.normalizedTitle))
                }
                return Self(directory: directory, files: files)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    package func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - Persisted tool arguments

package enum OracleImageToolArguments {
    /// Drops the `images` key from serialized `ask_oracle` arguments. Fails closed: malformed or
    /// truncated arguments may hide an unparseable `images` key, so nil is returned instead.
    package static func removingImages(fromArgsJSON argsJSON: String) -> String? {
        guard let data = argsJSON.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard object.removeValue(forKey: "images") != nil else { return argsJSON }
        guard JSONSerialization.isValidJSONObject(object),
              let sanitized = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return String(data: sanitized, encoding: .utf8)
    }
}
