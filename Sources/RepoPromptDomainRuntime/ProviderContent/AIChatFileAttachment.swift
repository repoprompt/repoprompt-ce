import Foundation

/// A persisted record of a file that was attached to a user message: what it was and a small
/// downscaled preview when one could be rendered — never the file's bytes — so transcripts can show
/// what was sent without bloating session files or leaking a path.
package struct AIChatFileAttachment: Codable, Equatable, Identifiable {
    package let id: UUID
    /// Downscaled preview bytes (JPEG), capped in dimension and size. Empty when none could be rendered.
    package let thumbnailData: Data
    package let kind: AttachmentKind
    /// Last path component only. Empty for rows written before file names were recorded.
    package let fileName: String
    /// Zero for rows written before sizes were recorded.
    package let byteCount: Int

    package init(
        id: UUID = UUID(),
        thumbnailData: Data,
        kind: AttachmentKind = .image,
        fileName: String = "",
        byteCount: Int = 0
    ) {
        self.id = id
        self.thumbnailData = thumbnailData
        self.kind = kind
        self.fileName = AttachmentFacts.lastPathComponent(fileName)
        self.byteCount = max(0, byteCount)
    }

    private enum CodingKeys: String, CodingKey {
        case id, thumbnailData, kind, fileName, byteCount
    }

    /// Rows persisted before this type recorded facts were image-only, so they decode as images.
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            thumbnailData: container.decode(Data.self, forKey: .thumbnailData),
            kind: container.decodeIfPresent(AttachmentKind.self, forKey: .kind) ?? .image,
            fileName: container.decodeIfPresent(String.self, forKey: .fileName) ?? "",
            byteCount: container.decodeIfPresent(Int.self, forKey: .byteCount) ?? 0
        )
    }

    package var facts: AttachmentFacts {
        AttachmentFacts(kind: kind, fileName: fileName, byteCount: byteCount)
    }
}

package extension AIChatFileAttachment {
    static let thumbnailMaxPixelSize = AttachmentPreviewRenderer.maxPixelSize

    static func thumbnails(from oracleAttachments: [OracleAttachment]) async throws -> [AIChatFileAttachment] {
        try Task.checkCancellation()
        guard !oracleAttachments.isEmpty else { return [] }
        let worker = Task.detached(priority: .userInitiated) {
            var attachments: [AIChatFileAttachment] = []
            for oracleAttachment in oracleAttachments {
                let data = try autoreleasepool { try AttachmentPreviewRenderer.jpegData(from: oracleAttachment) }
                attachments.append(AIChatFileAttachment(
                    thumbnailData: data ?? Data(),
                    kind: oracleAttachment.kind,
                    fileName: oracleAttachment.fileName,
                    byteCount: oracleAttachment.payload.byteCount
                ))
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
