import Foundation

/// A persisted preview of an image that was attached to a user message. Stores
/// only a small downscaled thumbnail — never the full-resolution bytes — so
/// transcripts can render what was sent without bloating session files.
package struct AIChatImageAttachment: Codable, Equatable, Identifiable {
    package let id: UUID
    /// Downscaled preview bytes (JPEG), capped in dimension and size.
    package let thumbnailData: Data

    package init(
        id: UUID = UUID(),
        thumbnailData: Data
    ) {
        self.id = id
        self.thumbnailData = thumbnailData
    }
}

package extension AIChatImageAttachment {
    static let thumbnailMaxPixelSize = OracleImageThumbnail.maxPixelSize

    /// Builds transcript thumbnails from request-scoped Oracle images off the
    /// caller's actor. Full bytes are never retained; each attachment stores a
    /// downscaled JPEG so session files stay small.
    static func thumbnails(from images: [AITransientImage]) async throws -> [AIChatImageAttachment] {
        try Task.checkCancellation()
        guard !images.isEmpty else { return [] }
        let worker = Task.detached(priority: .userInitiated) {
            var attachments: [AIChatImageAttachment] = []
            for image in images {
                let data = try autoreleasepool { try OracleImageThumbnail.jpegData(from: image) }
                // Keep a path-free indicator even when bounded decoding cannot make a preview.
                attachments.append(AIChatImageAttachment(thumbnailData: data ?? Data()))
            }
            try Task.checkCancellation()
            return attachments
        }
        return try await withTaskCancellationHandler {
            let attachments = try await worker.value
            try Task.checkCancellation()
            return attachments
        } onCancel: {
            worker.cancel()
        }
    }
}
