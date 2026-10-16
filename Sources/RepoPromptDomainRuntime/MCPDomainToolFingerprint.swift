import CryptoKit
import Foundation
import MCP

package struct MCPDomainToolFingerprint: Hashable, Sendable {
    package let name: String
    package let descriptionDigest: String
    package let schemaDigest: String
    package let annotationSignature: String
    package let isEnabledByDefault: Bool
    package let digest: String

    package init(definition: MCPDomainToolDefinition) throws {
        name = definition.name
        descriptionDigest = Self.sha256(definition.description)
        schemaDigest = Self.sha256(try Self.canonicalJSONString(definition.inputSchema))
        annotationSignature = Self.annotationSignature(definition.annotations)
        isEnabledByDefault = definition.isEnabledByDefault
        digest = Self.sha256([
            definition.name,
            definition.description,
            try Self.canonicalJSONString(definition.inputSchema),
            annotationSignature,
            String(definition.isEnabledByDefault),
        ].joined(separator: "\u{1f}"))
    }

    package func goldenSignature(index: Int) -> String {
        "\(index)|\(name)|enabled=\(isEnabledByDefault)|ann=\(annotationSignature)|desc=\(descriptionDigest)|schema=\(schemaDigest)"
    }

    package static func canonicalJSONString(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func annotationSignature(_ annotations: MCPDomainToolAnnotations) -> String {
        [
            "title=\(annotations.title ?? "nil")",
            "readOnly=\(optionalBool(annotations.readOnlyHint))",
            "destructive=\(optionalBool(annotations.destructiveHint))",
            "idempotent=\(optionalBool(annotations.idempotentHint))",
            "openWorld=\(optionalBool(annotations.openWorldHint))",
        ].joined(separator: ",")
    }

    private static func optionalBool(_ value: Bool?) -> String {
        value.map(String.init) ?? "nil"
    }

    private static func sha256(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
