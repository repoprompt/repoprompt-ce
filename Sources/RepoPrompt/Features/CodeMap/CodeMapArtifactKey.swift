import CryptoKit
import Foundation

enum CodeMapCanonicalIdentityError: Error, Equatable {
    case inputTooLarge
    case truncated(field: String)
    case invalidDomain
    case invalidUTF8(field: String)
    case invalidStableIdentifier(field: String)
    case invalidGrammarRevision
    case invalidBoolean
    case excessiveCount(field: String)
    case duplicateName(field: String)
    case nonCanonicalOrdering(field: String)
    case missingRequiredField(String)
    case unexpectedField(String)
    case invalidValue(field: String)
    case trailingBytes
    case nonCanonicalEncoding
}

struct CodeMapSHA256Digest: Hashable {
    static let byteCount = 32

    let bytes: Data

    init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else {
            throw CodeMapCanonicalIdentityError.invalidValue(field: "sha256")
        }
        self.bytes = bytes
    }

    var lowercaseHex: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

struct CodeMapSemanticVersion: Hashable {
    let major: UInt32
    let minor: UInt32
    let patch: UInt32
}

enum CodeMapPipelineLanguageID: String, CaseIterable, Hashable {
    case swift
    case javascript
    case cSharp = "c-sharp"
    case python
    case c
    case rust
    case cpp
    case go
    case java
    case dart
    case typescript
    case tsx
    case php
    case ruby
}

struct CodeMapPipelineNamedLimit: Hashable {
    let name: String
    let value: UInt64
}

struct CodeMapPipelineNamedFlag: Hashable {
    let name: String
    let enabled: Bool
}

struct CodeMapPipelineIdentity: Hashable {
    static let domain = "codemap-pipeline-identity-v1"

    static let requiredLimitNames = [
        "jsts-max-appended-continuation-lines",
        "parse-line-count",
        "parse-utf16-code-units",
        "parse-utf8-bytes"
    ]

    static let requiredFlagNames = [
        "filename-main-class-shaping",
        "jsts-signature-extraction",
        "lightweight-extraction",
        "path-free-artifact-finalization",
        "swift-range-strategy",
        "typescript-range-strategy"
    ]

    private static let maximumCanonicalByteCount = 16 * 1024
    private static let maximumStableIdentifierByteCount = 64

    let languageID: CodeMapPipelineLanguageID
    let decoderPolicy: CodeMapSourceDecoderPolicy
    let grammarRevision: String
    let treeSitterABIVersion: UInt32
    let codeMapQuerySHA256: CodeMapSHA256Digest
    let extractorVersion: CodeMapSemanticVersion
    let generatorVersion: CodeMapSemanticVersion
    let artifactSchemaVersion: UInt32
    let oversizeParsePolicyVersion: UInt32
    let limits: [CodeMapPipelineNamedLimit]
    let flags: [CodeMapPipelineNamedFlag]

    init(
        languageID: CodeMapPipelineLanguageID,
        decoderPolicy: CodeMapSourceDecoderPolicy,
        grammarRevision: String,
        treeSitterABIVersion: UInt32,
        codeMapQuerySHA256: CodeMapSHA256Digest,
        extractorVersion: CodeMapSemanticVersion,
        generatorVersion: CodeMapSemanticVersion,
        artifactSchemaVersion: UInt32,
        oversizeParsePolicyVersion: UInt32,
        limits: [CodeMapPipelineNamedLimit],
        flags: [CodeMapPipelineNamedFlag]
    ) throws {
        guard Self.isCanonicalGrammarRevision(grammarRevision) else {
            throw CodeMapCanonicalIdentityError.invalidGrammarRevision
        }
        guard treeSitterABIVersion > 0 else {
            throw CodeMapCanonicalIdentityError.invalidValue(field: "tree-sitter-abi")
        }
        guard extractorVersion.major > 0 else {
            throw CodeMapCanonicalIdentityError.invalidValue(field: "extractor-version")
        }
        guard generatorVersion.major > 0 else {
            throw CodeMapCanonicalIdentityError.invalidValue(field: "generator-version")
        }
        guard artifactSchemaVersion > 0 else {
            throw CodeMapCanonicalIdentityError.invalidValue(field: "artifact-schema-version")
        }
        guard oversizeParsePolicyVersion > 0 else {
            throw CodeMapCanonicalIdentityError.invalidValue(field: "oversize-parse-policy-version")
        }

        self.languageID = languageID
        self.decoderPolicy = decoderPolicy
        self.grammarRevision = grammarRevision
        self.treeSitterABIVersion = treeSitterABIVersion
        self.codeMapQuerySHA256 = codeMapQuerySHA256
        self.extractorVersion = extractorVersion
        self.generatorVersion = generatorVersion
        self.artifactSchemaVersion = artifactSchemaVersion
        self.oversizeParsePolicyVersion = oversizeParsePolicyVersion
        self.limits = try Self.validatedLimits(limits)
        self.flags = try Self.validatedFlags(flags)
    }

    init(canonicalBytes: Data) throws {
        guard canonicalBytes.count <= Self.maximumCanonicalByteCount else {
            throw CodeMapCanonicalIdentityError.inputTooLarge
        }

        var reader = CodeMapCanonicalReader(data: canonicalBytes)
        try reader.readDomain(Self.domain)
        let languageName = try reader.readStableIdentifier(
            field: "language-id",
            maximumByteCount: Self.maximumStableIdentifierByteCount
        )
        guard let languageID = CodeMapPipelineLanguageID(rawValue: languageName) else {
            throw CodeMapCanonicalIdentityError.invalidStableIdentifier(field: "language-id")
        }
        let decoderPolicyName = try reader.readStableIdentifier(
            field: "decoder-policy",
            maximumByteCount: Self.maximumStableIdentifierByteCount
        )
        guard let decoderPolicy = CodeMapSourceDecoderPolicy(canonicalID: decoderPolicyName) else {
            throw CodeMapCanonicalIdentityError.invalidStableIdentifier(field: "decoder-policy")
        }
        let grammarRevision = try reader.readString(field: "grammar-revision", maximumByteCount: 40)
        guard Self.isCanonicalGrammarRevision(grammarRevision) else {
            throw CodeMapCanonicalIdentityError.invalidGrammarRevision
        }
        let treeSitterABIVersion = try reader.readUInt32(field: "tree-sitter-abi")
        let queryDigest = try CodeMapSHA256Digest(
            bytes: reader.readData(count: CodeMapSHA256Digest.byteCount, field: "query-sha256")
        )
        let extractorVersion = try reader.readSemanticVersion(field: "extractor-version")
        let generatorVersion = try reader.readSemanticVersion(field: "generator-version")
        let artifactSchemaVersion = try reader.readUInt32(field: "artifact-schema-version")
        let oversizeParsePolicyVersion = try reader.readUInt32(field: "oversize-parse-policy-version")
        let limits = try reader.readNamedLimits(
            requiredNames: Self.requiredLimitNames,
            maximumNameByteCount: Self.maximumStableIdentifierByteCount
        )
        let flags = try reader.readNamedFlags(
            requiredNames: Self.requiredFlagNames,
            maximumNameByteCount: Self.maximumStableIdentifierByteCount
        )
        guard reader.isAtEnd else {
            throw CodeMapCanonicalIdentityError.trailingBytes
        }

        try self.init(
            languageID: languageID,
            decoderPolicy: decoderPolicy,
            grammarRevision: grammarRevision,
            treeSitterABIVersion: treeSitterABIVersion,
            codeMapQuerySHA256: queryDigest,
            extractorVersion: extractorVersion,
            generatorVersion: generatorVersion,
            artifactSchemaVersion: artifactSchemaVersion,
            oversizeParsePolicyVersion: oversizeParsePolicyVersion,
            limits: limits,
            flags: flags
        )
        guard self.canonicalBytes == canonicalBytes else {
            throw CodeMapCanonicalIdentityError.nonCanonicalEncoding
        }
    }

    var canonicalBytes: Data {
        var writer = CodeMapCanonicalWriter()
        writer.appendDomain(Self.domain)
        writer.appendString(languageID.rawValue)
        writer.appendString(decoderPolicy.canonicalID)
        writer.appendString(grammarRevision)
        writer.append(treeSitterABIVersion)
        writer.append(codeMapQuerySHA256.bytes)
        writer.append(extractorVersion)
        writer.append(generatorVersion)
        writer.append(artifactSchemaVersion)
        writer.append(oversizeParsePolicyVersion)
        writer.append(UInt32(limits.count))
        for limit in limits {
            writer.appendString(limit.name)
            writer.append(limit.value)
        }
        writer.append(UInt32(flags.count))
        for flag in flags {
            writer.appendString(flag.name)
            writer.append(flag.enabled)
        }
        return writer.data
    }

    private static func validatedLimits(
        _ values: [CodeMapPipelineNamedLimit]
    ) throws -> [CodeMapPipelineNamedLimit] {
        let sorted = values.sorted { Data($0.name.utf8).lexicographicallyPrecedes(Data($1.name.utf8)) }
        try validateNames(sorted.map(\.name), requiredNames: requiredLimitNames, field: "limits")
        return sorted
    }

    private static func validatedFlags(
        _ values: [CodeMapPipelineNamedFlag]
    ) throws -> [CodeMapPipelineNamedFlag] {
        let sorted = values.sorted { Data($0.name.utf8).lexicographicallyPrecedes(Data($1.name.utf8)) }
        try validateNames(sorted.map(\.name), requiredNames: requiredFlagNames, field: "flags")
        return sorted
    }

    private static func validateNames(
        _ names: [String],
        requiredNames: [String],
        field: String
    ) throws {
        guard names.count == Set(names).count else {
            throw CodeMapCanonicalIdentityError.duplicateName(field: field)
        }
        let required = Set(requiredNames)
        for name in names where !required.contains(name) {
            throw CodeMapCanonicalIdentityError.unexpectedField(name)
        }
        for name in requiredNames where !names.contains(name) {
            throw CodeMapCanonicalIdentityError.missingRequiredField(name)
        }
    }

    private static func isCanonicalGrammarRevision(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy { byte in
            (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte) ||
                (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains(byte)
        }
    }
}

struct CodeMapArtifactKey: Hashable {
    static let domain = "codemap-artifact-key-v1"

    private static let maximumCanonicalByteCount = 32 * 1024

    let rawSHA256: CodeMapRawSourceDigest
    let rawByteCount: UInt64
    let pipelineIdentity: CodeMapPipelineIdentity

    init(source: CodeMapSourceSnapshot, pipelineIdentity: CodeMapPipelineIdentity) throws {
        guard source.decoderPolicy == pipelineIdentity.decoderPolicy else {
            throw CodeMapCanonicalIdentityError.invalidValue(field: "decoder-policy-mismatch")
        }
        guard let rawByteCount = UInt64(exactly: source.rawByteCount) else {
            throw CodeMapCanonicalIdentityError.invalidValue(field: "raw-byte-count")
        }
        self.init(
            rawSHA256: source.rawSHA256,
            rawByteCount: rawByteCount,
            pipelineIdentity: pipelineIdentity
        )
    }

    init(
        rawSHA256: CodeMapRawSourceDigest,
        rawByteCount: UInt64,
        pipelineIdentity: CodeMapPipelineIdentity
    ) {
        self.rawSHA256 = rawSHA256
        self.rawByteCount = rawByteCount
        self.pipelineIdentity = pipelineIdentity
    }

    init(canonicalBytes: Data) throws {
        guard canonicalBytes.count <= Self.maximumCanonicalByteCount else {
            throw CodeMapCanonicalIdentityError.inputTooLarge
        }

        var reader = CodeMapCanonicalReader(data: canonicalBytes)
        try reader.readDomain(Self.domain)
        let rawSHA256 = try CodeMapRawSourceDigest(
            bytes: reader.readData(count: CodeMapSHA256Digest.byteCount, field: "raw-sha256")
        )
        let rawByteCount = try reader.readUInt64(field: "raw-byte-count")
        let pipelineByteCount = try reader.readUInt32(field: "pipeline-byte-count")
        guard pipelineByteCount <= CodeMapPipelineIdentity.maximumEncodedByteCount else {
            throw CodeMapCanonicalIdentityError.inputTooLarge
        }
        let pipelineBytes = try reader.readData(count: Int(pipelineByteCount), field: "pipeline")
        guard reader.isAtEnd else {
            throw CodeMapCanonicalIdentityError.trailingBytes
        }
        let pipelineIdentity = try CodeMapPipelineIdentity(canonicalBytes: pipelineBytes)
        self.init(
            rawSHA256: rawSHA256,
            rawByteCount: rawByteCount,
            pipelineIdentity: pipelineIdentity
        )
        guard self.canonicalBytes == canonicalBytes else {
            throw CodeMapCanonicalIdentityError.nonCanonicalEncoding
        }
    }

    var canonicalBytes: Data {
        let pipelineBytes = pipelineIdentity.canonicalBytes
        precondition(pipelineBytes.count <= Int(UInt32.max))
        var writer = CodeMapCanonicalWriter()
        writer.appendDomain(Self.domain)
        writer.append(rawSHA256.bytes)
        writer.append(rawByteCount)
        writer.append(UInt32(pipelineBytes.count))
        writer.append(pipelineBytes)
        return writer.data
    }

    var storageDigest: CodeMapSHA256Digest {
        try! CodeMapSHA256Digest(bytes: Data(SHA256.hash(data: canonicalBytes)))
    }

    var storageDigestHex: String {
        storageDigest.lowercaseHex
    }

    var shard: String {
        String(storageDigestHex.prefix(2))
    }
}

private extension CodeMapPipelineIdentity {
    static var maximumEncodedByteCount: UInt32 {
        UInt32(maximumCanonicalByteCount)
    }
}

private extension CodeMapSourceDecoderPolicy {
    var canonicalID: String {
        switch self {
        case .workspaceAutomaticV1:
            "workspace-automatic-v1"
        #if DEBUG
            case .testOnlyMismatch:
                "test-only-mismatch"
        #endif
        }
    }

    init?(canonicalID: String) {
        switch canonicalID {
        case "workspace-automatic-v1":
            self = .workspaceAutomaticV1
        #if DEBUG
            case "test-only-mismatch":
                self = .testOnlyMismatch
        #endif
        default:
            return nil
        }
    }
}

private struct CodeMapCanonicalWriter {
    private(set) var data = Data()

    mutating func appendDomain(_ value: String) {
        data.append(contentsOf: value.utf8)
    }

    mutating func appendString(_ value: String) {
        let bytes = Data(value.utf8)
        precondition(bytes.count <= Int(UInt32.max))
        append(UInt32(bytes.count))
        append(bytes)
    }

    mutating func append(_ value: CodeMapSemanticVersion) {
        append(value.major)
        append(value.minor)
        append(value.patch)
    }

    mutating func append(_ value: Bool) {
        data.append(value ? 1 : 0)
    }

    mutating func append(_ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    mutating func append(_ value: UInt64) {
        data.append(UInt8((value >> 56) & 0xFF))
        data.append(UInt8((value >> 48) & 0xFF))
        data.append(UInt8((value >> 40) & 0xFF))
        data.append(UInt8((value >> 32) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    mutating func append(_ bytes: Data) {
        data.append(bytes)
    }
}

private struct CodeMapCanonicalReader {
    let data: Data
    private(set) var offset = 0

    var isAtEnd: Bool {
        offset == data.count
    }

    mutating func readDomain(_ expected: String) throws {
        let expectedBytes = Data(expected.utf8)
        let actual = try readData(count: expectedBytes.count, field: "domain")
        guard actual == expectedBytes else {
            throw CodeMapCanonicalIdentityError.invalidDomain
        }
    }

    mutating func readStableIdentifier(field: String, maximumByteCount: Int) throws -> String {
        let value = try readString(field: field, maximumByteCount: maximumByteCount)
        guard !value.isEmpty, value.utf8.allSatisfy({ byte in
            (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte) ||
                (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte) ||
                byte == UInt8(ascii: "-")
        }) else {
            throw CodeMapCanonicalIdentityError.invalidStableIdentifier(field: field)
        }
        return value
    }

    mutating func readString(field: String, maximumByteCount: Int) throws -> String {
        let byteCount = try readUInt32(field: "\(field)-length")
        guard byteCount <= UInt32(maximumByteCount) else {
            throw CodeMapCanonicalIdentityError.inputTooLarge
        }
        let bytes = try readData(count: Int(byteCount), field: field)
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw CodeMapCanonicalIdentityError.invalidUTF8(field: field)
        }
        return value
    }

    mutating func readSemanticVersion(field: String) throws -> CodeMapSemanticVersion {
        try CodeMapSemanticVersion(
            major: readUInt32(field: "\(field)-major"),
            minor: readUInt32(field: "\(field)-minor"),
            patch: readUInt32(field: "\(field)-patch")
        )
    }

    mutating func readNamedLimits(
        requiredNames: [String],
        maximumNameByteCount: Int
    ) throws -> [CodeMapPipelineNamedLimit] {
        let count = try readUInt32(field: "limit-count")
        guard count == UInt32(requiredNames.count) else {
            throw CodeMapCanonicalIdentityError.excessiveCount(field: "limits")
        }
        var result: [CodeMapPipelineNamedLimit] = []
        result.reserveCapacity(Int(count))
        var previousNameBytes: Data?
        for _ in 0 ..< count {
            let name = try readStableIdentifier(field: "limit-name", maximumByteCount: maximumNameByteCount)
            try validateCanonicalNameOrder(name, previousNameBytes: &previousNameBytes, field: "limits")
            try result.append(CodeMapPipelineNamedLimit(name: name, value: readUInt64(field: name)))
        }
        return result
    }

    mutating func readNamedFlags(
        requiredNames: [String],
        maximumNameByteCount: Int
    ) throws -> [CodeMapPipelineNamedFlag] {
        let count = try readUInt32(field: "flag-count")
        guard count == UInt32(requiredNames.count) else {
            throw CodeMapCanonicalIdentityError.excessiveCount(field: "flags")
        }
        var result: [CodeMapPipelineNamedFlag] = []
        result.reserveCapacity(Int(count))
        var previousNameBytes: Data?
        for _ in 0 ..< count {
            let name = try readStableIdentifier(field: "flag-name", maximumByteCount: maximumNameByteCount)
            try validateCanonicalNameOrder(name, previousNameBytes: &previousNameBytes, field: "flags")
            try result.append(CodeMapPipelineNamedFlag(name: name, enabled: readBool(field: name)))
        }
        return result
    }

    mutating func readBool(field: String) throws -> Bool {
        let byte = try readData(count: 1, field: field)[0]
        return switch byte {
        case 0: false
        case 1: true
        default: throw CodeMapCanonicalIdentityError.invalidBoolean
        }
    }

    mutating func readUInt32(field: String) throws -> UInt32 {
        let bytes = try readData(count: 4, field: field)
        return bytes.reduce(into: UInt32(0)) { result, byte in
            result = (result << 8) | UInt32(byte)
        }
    }

    mutating func readUInt64(field: String) throws -> UInt64 {
        let bytes = try readData(count: 8, field: field)
        return bytes.reduce(into: UInt64(0)) { result, byte in
            result = (result << 8) | UInt64(byte)
        }
    }

    mutating func readData(count: Int, field: String) throws -> Data {
        guard count >= 0, count <= data.count - offset else {
            throw CodeMapCanonicalIdentityError.truncated(field: field)
        }
        let end = offset + count
        defer { offset = end }
        return data.subdata(in: offset ..< end)
    }

    private func validateCanonicalNameOrder(
        _ name: String,
        previousNameBytes: inout Data?,
        field: String
    ) throws {
        let bytes = Data(name.utf8)
        if let previousNameBytes {
            if bytes == previousNameBytes {
                throw CodeMapCanonicalIdentityError.duplicateName(field: field)
            }
            guard previousNameBytes.lexicographicallyPrecedes(bytes) else {
                throw CodeMapCanonicalIdentityError.nonCanonicalOrdering(field: field)
            }
        }
        previousNameBytes = bytes
    }
}
