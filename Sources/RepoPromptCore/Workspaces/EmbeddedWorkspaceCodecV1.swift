import Foundation

/// Current embedded-app workspace document codec.
///
/// Decode normalization is reported as metadata only; neither this codec nor the repository writes on read.
package struct EmbeddedWorkspaceCodecV1: WorkspaceDocumentCodec {
    package typealias Document = WorkspaceModel

    package static let formatVersion = WorkspaceDocumentFormatVersion(family: "embedded-app", version: 1)

    package init() {}

    package func decode(_ data: Data) throws -> WorkspaceDocumentDecodeResult<WorkspaceModel> {
        try WorkspaceModel.decodeAppV1(data)
    }

    package func encode(_ document: WorkspaceModel) throws -> WorkspaceDocumentEncodeResult {
        try WorkspaceDocumentEncodeResult(data: JSONEncoder().encode(document), schemaVersion: Self.formatVersion)
    }
}
