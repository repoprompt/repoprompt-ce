import Foundation

/// Request-scoped Oracle attachment. Deliberately non-Codable and path-free: bytes are never persisted.
package struct OracleAttachment: Equatable {
    package static let fallbackFileName = "attachment"

    package let payload: AttachmentPayload
    /// Last path component only, so a full path can never be stored, displayed, or sent to a model.
    package let fileName: String
    package let title: String?

    package init(payload: AttachmentPayload, fileName: String, title: String?) {
        let component = (fileName as NSString).lastPathComponent
        self.payload = payload
        self.fileName = component.isEmpty || component == "/" ? Self.fallbackFileName : component
        self.title = title
    }

    package var kind: AttachmentKind {
        payload.kind
    }

    package var normalizedTitle: String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

package struct OracleAttachmentSet: Equatable {
    package let attachments: [OracleAttachment]

    package init(_ attachments: [OracleAttachment]) {
        self.attachments = attachments
    }

    package var isEmpty: Bool {
        attachments.isEmpty
    }

    package var count: Int {
        attachments.count
    }
}
