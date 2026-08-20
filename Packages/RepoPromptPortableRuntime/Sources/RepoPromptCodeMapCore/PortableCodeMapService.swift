#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif
import Foundation

public struct PortableCodeMapResult: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case ready, noSymbols, unsupported, oversize, parseFailed }
    public let status: Status
    public let language: String?
    public let content: String
    public let contentDigest: String

    public init(status: Status, language: String?, content: String, contentDigest: String) {
        self.status = status
        self.language = language
        self.content = content
        self.contentDigest = contentDigest
    }
}

public enum PortableCodeMapService {
    public static func build(content: String, fileExtension: String) throws -> PortableCodeMapResult {
        let data = Data(content.utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let engine = CodeMapSyntaxEngine.shared
        guard let language = engine.language(forFileExtension: fileExtension) else {
            return PortableCodeMapResult(status: .unsupported, language: nil, content: "", contentDigest: digest)
        }
        let source = CodeMapCoreSourceSnapshot(
            rawByteCount: data.count,
            rawSHA256: CodeMapRawSourceDigest(bytes: Data(SHA256.hash(data: data))),
            decoderPolicy: .workspaceAutomaticV1,
            decodeResult: .decoded(CodeMapDecodedSource(text: content, detectedEncodingRawValue: String.Encoding.utf8.rawValue))
        )
        switch try CodeMapSyntaxArtifactBuilder.build(source: source, language: language) {
        case let .ready(artifact):
            return PortableCodeMapResult(status: .ready, language: language.rawValue, content: artifact.apiDescription, contentDigest: digest)
        case .readyNoSymbols:
            return PortableCodeMapResult(status: .noSymbols, language: language.rawValue, content: "", contentDigest: digest)
        case .oversize:
            return PortableCodeMapResult(status: .oversize, language: language.rawValue, content: "", contentDigest: digest)
        case .decodeFailed, .parseFailed:
            return PortableCodeMapResult(status: .parseFailed, language: language.rawValue, content: "", contentDigest: digest)
        }
    }
}
