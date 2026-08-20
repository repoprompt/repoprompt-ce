#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif
import Foundation
import MCP

public struct MCPDomainToolFingerprint: Hashable, Sendable {
    public let name: String
    public let descriptionDigest: String
    public let schemaDigest: String
    public let annotationSignature: String
    public let isEnabledByDefault: Bool
    public let digest: String

    public init(definition: MCPDomainToolDefinition) throws {
        name = definition.name
        descriptionDigest = Self.sha256(definition.description)
        schemaDigest = try Self.sha256(Self.canonicalJSONString(definition.inputSchema))
        annotationSignature = Self.annotationSignature(definition.annotations)
        isEnabledByDefault = definition.isEnabledByDefault
        digest = try Self.sha256([
            definition.name,
            definition.description,
            Self.canonicalJSONString(definition.inputSchema),
            annotationSignature,
            String(definition.isEnabledByDefault)
        ].joined(separator: "\u{1f}"))
    }

    public func goldenSignature(index: Int) -> String {
        "\(index)|\(name)|enabled=\(isEnabledByDefault)|ann=\(annotationSignature)|desc=\(descriptionDigest)|schema=\(schemaDigest)"
    }

    public static func canonicalJSONString(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try String(decoding: encoder.encode(value), as: UTF8.self)
    }

    private static func annotationSignature(_ annotations: MCPDomainToolAnnotations) -> String {
        [
            "title=\(annotations.title ?? "nil")",
            "readOnly=\(optionalBool(annotations.readOnlyHint))",
            "destructive=\(optionalBool(annotations.destructiveHint))",
            "idempotent=\(optionalBool(annotations.idempotentHint))",
            "openWorld=\(optionalBool(annotations.openWorldHint))"
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
