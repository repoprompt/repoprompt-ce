import Foundation

/// Request-scoped Oracle attachment. Deliberately non-Codable: bytes and paths are never persisted.
package struct OracleAttachment: Equatable {
    package static let fallbackFileName = "attachment"

    package let payload: AttachmentPayload
    /// Last path component only, so the name is what is stored, displayed, and sent on every route.
    package let fileName: String
    package let title: String?
    /// Absolute path of the file on this machine. It exists so a route that runs locally can tell its
    /// agent where to open the file; the planner reads it for no other purpose. It is never persisted,
    /// never displayed, and never sent to a network route. Nil when no absolute path is known: a
    /// relative path is never accepted, and a path containing a control character is dropped so it
    /// cannot break out of the single line that carries it.
    package let localPath: String?

    package init(payload: AttachmentPayload, fileName: String, title: String?, localPath: String? = nil) {
        let component = (fileName as NSString).lastPathComponent
        self.payload = payload
        self.fileName = component.isEmpty || component == "/" ? Self.fallbackFileName : component
        self.title = title
        self.localPath = Self.absolutePath(localPath)
    }

    private static func absolutePath(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/"), !path.unicodeScalars.contains(where: {
            $0.properties.generalCategory == .control
        }) else { return nil }
        return path
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
