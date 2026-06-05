import Foundation

package struct WorkspaceDocumentFormatVersion: Hashable {
    package let family: String
    package let version: Int

    package init(family: String, version: Int) {
        self.family = family
        self.version = version
    }
}

package struct WorkspaceCodecWarning: Hashable {
    package let code: String
    package let message: String

    package init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

package struct WorkspaceDocumentDecodeResult<Document: Sendable> {
    package let document: Document
    package let sourceVersion: WorkspaceDocumentFormatVersion
    package let warnings: [WorkspaceCodecWarning]
    package let requiresRewrite: Bool

    package init(
        document: Document,
        sourceVersion: WorkspaceDocumentFormatVersion,
        warnings: [WorkspaceCodecWarning] = [],
        requiresRewrite: Bool = false
    ) {
        self.document = document
        self.sourceVersion = sourceVersion
        self.warnings = warnings
        self.requiresRewrite = requiresRewrite
    }
}

package struct WorkspaceDocumentEncodeResult {
    package let data: Data
    package let schemaVersion: WorkspaceDocumentFormatVersion

    package init(data: Data, schemaVersion: WorkspaceDocumentFormatVersion) {
        self.data = data
        self.schemaVersion = schemaVersion
    }
}

/// Version-aware serialization boundary for the canonical workspace domain introduced in Phase 2.
///
/// Phase 1 intentionally keeps the document generic so Core does not invent a competing schema
/// before the app's canonical workspace value graph moves into this target.
package protocol WorkspaceDocumentCodec: Sendable {
    associatedtype Document: Sendable

    func decode(_ data: Data) throws -> WorkspaceDocumentDecodeResult<Document>
    func encode(_ document: Document) throws -> WorkspaceDocumentEncodeResult
}
