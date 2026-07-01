import CryptoKit
import Foundation

struct CodeMapArtifactContainerPolicy: Equatable {
    static let `default` = CodeMapArtifactContainerPolicy()

    let maximumHeaderByteCount: Int
    let maximumPayloadByteCount: Int
    let maximumContainerByteCount: Int
    let maximumCollectionEntryCount: UInt64
    let maximumStringCount: UInt64
    let maximumStringUTF8ByteCount: UInt64
    let maximumIndividualStringUTF8ByteCount: UInt64
    let maximumJSONNestingDepth: Int
    let maximumJSONTokenCount: UInt64

    init(
        maximumHeaderByteCount: Int = 64 * 1024,
        maximumPayloadByteCount: Int = 16 * 1024 * 1024,
        maximumContainerByteCount: Int = 17 * 1024 * 1024,
        maximumCollectionEntryCount: UInt64 = 100_000,
        maximumStringCount: UInt64 = 200_000,
        maximumStringUTF8ByteCount: UInt64 = 16 * 1024 * 1024,
        maximumIndividualStringUTF8ByteCount: UInt64 = 1024 * 1024,
        maximumJSONNestingDepth: Int = 64,
        maximumJSONTokenCount: UInt64 = 500_000
    ) {
        precondition(maximumHeaderByteCount > 0)
        precondition(maximumPayloadByteCount > 0)
        precondition(maximumContainerByteCount >= maximumHeaderByteCount)
        precondition(maximumJSONNestingDepth > 0)
        precondition(maximumJSONTokenCount > 0)
        self.maximumHeaderByteCount = maximumHeaderByteCount
        self.maximumPayloadByteCount = maximumPayloadByteCount
        self.maximumContainerByteCount = maximumContainerByteCount
        self.maximumCollectionEntryCount = maximumCollectionEntryCount
        self.maximumStringCount = maximumStringCount
        self.maximumStringUTF8ByteCount = maximumStringUTF8ByteCount
        self.maximumIndividualStringUTF8ByteCount = maximumIndividualStringUTF8ByteCount
        self.maximumJSONNestingDepth = maximumJSONNestingDepth
        self.maximumJSONTokenCount = maximumJSONTokenCount
    }
}

enum CodeMapArtifactContainerError: Error, Equatable {
    case truncated
    case trailingBytes
    case invalidMagic
    case unsupportedContainerVersion
    case invalidHeaderLength
    case invalidKeyLength
    case invalidCanonicalKey
    case keyMismatch
    case filenameDigestMismatch
    case schemaMismatch
    case invalidOutcomeKind
    case invalidPayloadLength
    case checksumMismatch
    case invalidSummary
    case collectionLimitExceeded
    case stringLimitExceeded
    case payloadDecodeFailed
    case outcomeKindMismatch
    case nonCanonicalPayload
}

struct DecodedCodeMapArtifactContainer: Equatable {
    let key: CodeMapArtifactKey
    let outcome: CodeMapSyntaxArtifactOutcome
    let payloadByteCount: Int
    let containerByteCount: Int
}

struct CodeMapArtifactContainerPreflight: Equatable {
    let headerByteCount: Int
    let payloadByteCount: Int
    let payloadSHA256: Data
}

enum CodeMapArtifactContainer {
    static let magic = Data("RPCMAPCASARTIF01".utf8)
    static let containerVersion: UInt32 = 1

    private static let summaryVersion: UInt32 = 1
    private static let summaryFieldCount: UInt32 = 20
    private static let fixedHeaderByteCount = 16 + 4 + 4 + 4 + 4 + 1 + 8 + 32 + 4 + 4 + Int(summaryFieldCount) * 8

    static func encode(
        key: CodeMapArtifactKey,
        outcome: CodeMapSyntaxArtifactOutcome,
        policy: CodeMapArtifactContainerPolicy = .default
    ) throws -> Data {
        let payload = try canonicalPayload(for: outcome)
        guard payload.count <= policy.maximumPayloadByteCount else {
            throw CodeMapArtifactContainerError.invalidPayloadLength
        }
        let summary = try CodeMapArtifactSummary(outcome: outcome, policy: policy)
        let keyBytes = key.canonicalBytes
        guard keyBytes.count <= Int(UInt32.max) else {
            throw CodeMapArtifactContainerError.invalidKeyLength
        }
        let headerByteCount = try checkedAdd(fixedHeaderByteCount, keyBytes.count)
        guard headerByteCount <= policy.maximumHeaderByteCount,
              headerByteCount <= Int(UInt32.max)
        else {
            throw CodeMapArtifactContainerError.invalidHeaderLength
        }
        let containerByteCount = try checkedAdd(headerByteCount, payload.count)
        guard containerByteCount <= policy.maximumContainerByteCount else {
            throw CodeMapArtifactContainerError.invalidPayloadLength
        }

        var writer = CodeMapArtifactBinaryWriter(capacity: containerByteCount)
        writer.append(magic)
        writer.append(containerVersion)
        writer.append(UInt32(headerByteCount))
        writer.append(UInt32(keyBytes.count))
        writer.append(keyBytes)
        writer.append(key.pipelineIdentity.artifactSchemaVersion)
        writer.append(CodeMapArtifactOutcomeKind(outcome: outcome).rawValue)
        writer.append(UInt64(payload.count))
        writer.append(Data(SHA256.hash(data: payload)))
        writer.append(summaryVersion)
        writer.append(summaryFieldCount)
        for field in summary.fields {
            writer.append(field)
        }
        precondition(writer.data.count == headerByteCount)
        writer.append(payload)
        return writer.data
    }

    static func preflightHeader(
        _ header: Data,
        expectedKey: CodeMapArtifactKey,
        filenameDigest: String,
        totalFileByteCount: Int,
        policy: CodeMapArtifactContainerPolicy = .default
    ) throws -> CodeMapArtifactContainerPreflight {
        guard header.count <= policy.maximumHeaderByteCount,
              totalFileByteCount <= policy.maximumContainerByteCount
        else {
            throw CodeMapArtifactContainerError.invalidHeaderLength
        }
        var reader = CodeMapArtifactBinaryReader(data: header)
        guard try reader.readData(count: magic.count) == magic else {
            throw CodeMapArtifactContainerError.invalidMagic
        }
        guard try reader.readUInt32() == containerVersion else {
            throw CodeMapArtifactContainerError.unsupportedContainerVersion
        }
        let headerByteCount = try boundedInt(reader.readUInt32())
        guard headerByteCount == header.count,
              headerByteCount >= fixedHeaderByteCount
        else {
            throw CodeMapArtifactContainerError.invalidHeaderLength
        }
        let keyByteCount = try boundedInt(reader.readUInt32())
        guard keyByteCount > 0,
              keyByteCount <= headerByteCount - fixedHeaderByteCount
        else {
            throw CodeMapArtifactContainerError.invalidKeyLength
        }
        let decodedKey: CodeMapArtifactKey
        do {
            decodedKey = try CodeMapArtifactKey(canonicalBytes: reader.readData(count: keyByteCount))
        } catch {
            throw CodeMapArtifactContainerError.invalidCanonicalKey
        }
        guard decodedKey == expectedKey else { throw CodeMapArtifactContainerError.keyMismatch }
        guard isCanonicalDigest(filenameDigest), decodedKey.storageDigestHex == filenameDigest else {
            throw CodeMapArtifactContainerError.filenameDigestMismatch
        }
        guard try reader.readUInt32() == decodedKey.pipelineIdentity.artifactSchemaVersion else {
            throw CodeMapArtifactContainerError.schemaMismatch
        }
        guard try CodeMapArtifactOutcomeKind(rawValue: reader.readUInt8()) != nil else {
            throw CodeMapArtifactContainerError.invalidOutcomeKind
        }
        let payloadByteCount = try boundedInt(reader.readUInt64())
        guard payloadByteCount <= policy.maximumPayloadByteCount else {
            throw CodeMapArtifactContainerError.invalidPayloadLength
        }
        let payloadSHA256 = try reader.readData(count: SHA256.byteCount)
        guard try reader.readUInt32() == summaryVersion,
              try reader.readUInt32() == summaryFieldCount
        else {
            throw CodeMapArtifactContainerError.invalidSummary
        }
        var summaryFields: [UInt64] = []
        summaryFields.reserveCapacity(Int(summaryFieldCount))
        for _ in 0 ..< summaryFieldCount {
            try summaryFields.append(reader.readUInt64())
        }
        try CodeMapArtifactSummary.validateDeclared(fields: summaryFields, policy: policy)
        guard reader.offset == headerByteCount else {
            throw CodeMapArtifactContainerError.invalidHeaderLength
        }
        let expectedTotalByteCount = try checkedAdd(headerByteCount, payloadByteCount)
        guard expectedTotalByteCount == totalFileByteCount else {
            if expectedTotalByteCount > totalFileByteCount { throw CodeMapArtifactContainerError.truncated }
            throw CodeMapArtifactContainerError.trailingBytes
        }
        return CodeMapArtifactContainerPreflight(
            headerByteCount: headerByteCount,
            payloadByteCount: payloadByteCount,
            payloadSHA256: payloadSHA256
        )
    }

    static func decode(
        _ data: Data,
        expectedKey: CodeMapArtifactKey,
        filenameDigest: String,
        policy: CodeMapArtifactContainerPolicy = .default
    ) throws -> DecodedCodeMapArtifactContainer {
        guard data.count <= policy.maximumContainerByteCount else {
            throw CodeMapArtifactContainerError.invalidPayloadLength
        }
        var reader = CodeMapArtifactBinaryReader(data: data)
        guard try reader.readData(count: magic.count) == magic else {
            throw CodeMapArtifactContainerError.invalidMagic
        }
        guard try reader.readUInt32() == containerVersion else {
            throw CodeMapArtifactContainerError.unsupportedContainerVersion
        }
        let headerByteCount = try boundedInt(reader.readUInt32())
        guard headerByteCount >= fixedHeaderByteCount,
              headerByteCount <= policy.maximumHeaderByteCount,
              headerByteCount <= data.count
        else {
            throw CodeMapArtifactContainerError.invalidHeaderLength
        }
        let keyByteCount = try boundedInt(reader.readUInt32())
        guard keyByteCount > 0,
              keyByteCount <= headerByteCount - fixedHeaderByteCount
        else {
            throw CodeMapArtifactContainerError.invalidKeyLength
        }
        let keyBytes = try reader.readData(count: keyByteCount)
        let decodedKey: CodeMapArtifactKey
        do {
            decodedKey = try CodeMapArtifactKey(canonicalBytes: keyBytes)
        } catch {
            throw CodeMapArtifactContainerError.invalidCanonicalKey
        }
        guard decodedKey == expectedKey else {
            throw CodeMapArtifactContainerError.keyMismatch
        }
        guard Self.isCanonicalDigest(filenameDigest), decodedKey.storageDigestHex == filenameDigest else {
            throw CodeMapArtifactContainerError.filenameDigestMismatch
        }

        guard try reader.readUInt32() == decodedKey.pipelineIdentity.artifactSchemaVersion else {
            throw CodeMapArtifactContainerError.schemaMismatch
        }
        guard let outcomeKind = try CodeMapArtifactOutcomeKind(rawValue: reader.readUInt8()) else {
            throw CodeMapArtifactContainerError.invalidOutcomeKind
        }
        let payloadByteCount = try boundedInt(reader.readUInt64())
        guard payloadByteCount <= policy.maximumPayloadByteCount else {
            throw CodeMapArtifactContainerError.invalidPayloadLength
        }
        let expectedChecksum = try reader.readData(count: SHA256.byteCount)
        guard try reader.readUInt32() == summaryVersion,
              try reader.readUInt32() == summaryFieldCount
        else {
            throw CodeMapArtifactContainerError.invalidSummary
        }
        var summaryFields: [UInt64] = []
        summaryFields.reserveCapacity(Int(summaryFieldCount))
        for _ in 0 ..< summaryFieldCount {
            try summaryFields.append(reader.readUInt64())
        }
        try CodeMapArtifactSummary.validateDeclared(fields: summaryFields, policy: policy)
        guard reader.offset == headerByteCount else {
            throw CodeMapArtifactContainerError.invalidHeaderLength
        }
        let expectedTotalByteCount = try checkedAdd(headerByteCount, payloadByteCount)
        guard expectedTotalByteCount <= policy.maximumContainerByteCount else {
            throw CodeMapArtifactContainerError.invalidPayloadLength
        }
        guard expectedTotalByteCount <= data.count else {
            throw CodeMapArtifactContainerError.truncated
        }
        guard expectedTotalByteCount == data.count else {
            throw CodeMapArtifactContainerError.trailingBytes
        }
        let payload = try reader.readData(count: payloadByteCount)
        guard Data(SHA256.hash(data: payload)) == expectedChecksum else {
            throw CodeMapArtifactContainerError.checksumMismatch
        }
        try validateJSONStructure(payload, policy: policy)

        let outcome: CodeMapSyntaxArtifactOutcome
        do {
            outcome = try JSONDecoder().decode(CodeMapSyntaxArtifactOutcome.self, from: payload)
        } catch {
            throw CodeMapArtifactContainerError.payloadDecodeFailed
        }
        guard CodeMapArtifactOutcomeKind(outcome: outcome) == outcomeKind else {
            throw CodeMapArtifactContainerError.outcomeKindMismatch
        }
        guard try canonicalPayload(for: outcome) == payload else {
            throw CodeMapArtifactContainerError.nonCanonicalPayload
        }
        let actualSummary = try CodeMapArtifactSummary(outcome: outcome, policy: policy)
        guard actualSummary.fields == summaryFields else {
            throw CodeMapArtifactContainerError.invalidSummary
        }
        return DecodedCodeMapArtifactContainer(
            key: decodedKey,
            outcome: outcome,
            payloadByteCount: payloadByteCount,
            containerByteCount: data.count
        )
    }

    private static func canonicalPayload(for outcome: CodeMapSyntaxArtifactOutcome) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(outcome)
        } catch {
            throw CodeMapArtifactContainerError.payloadDecodeFailed
        }
    }

    private static func validateJSONStructure(
        _ payload: Data,
        policy: CodeMapArtifactContainerPolicy
    ) throws {
        var depth = 0
        var tokenCount: UInt64 = 0
        var stringCount: UInt64 = 0
        var totalStringByteCount: UInt64 = 0
        var currentStringByteCount: UInt64 = 0
        var inString = false
        var escaped = false
        var inPrimitive = false

        func increment(_ value: inout UInt64, limit: UInt64) throws {
            let (next, overflow) = value.addingReportingOverflow(1)
            guard !overflow, next <= limit else {
                throw CodeMapArtifactContainerError.collectionLimitExceeded
            }
            value = next
        }

        for byte in payload {
            if inString {
                if escaped {
                    escaped = false
                    currentStringByteCount += 1
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                    currentStringByteCount += 1
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                    totalStringByteCount += currentStringByteCount
                    guard currentStringByteCount <= policy.maximumIndividualStringUTF8ByteCount,
                          totalStringByteCount <= policy.maximumStringUTF8ByteCount
                    else {
                        throw CodeMapArtifactContainerError.stringLimitExceeded
                    }
                } else {
                    guard byte >= 0x20 else { throw CodeMapArtifactContainerError.payloadDecodeFailed }
                    currentStringByteCount += 1
                }
                continue
            }

            switch byte {
            case UInt8(ascii: "\""):
                try increment(&tokenCount, limit: policy.maximumJSONTokenCount)
                try increment(&stringCount, limit: policy.maximumStringCount)
                inString = true
                escaped = false
                currentStringByteCount = 0
                inPrimitive = false
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                try increment(&tokenCount, limit: policy.maximumJSONTokenCount)
                depth += 1
                guard depth <= policy.maximumJSONNestingDepth else {
                    throw CodeMapArtifactContainerError.collectionLimitExceeded
                }
                inPrimitive = false
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                guard depth > 0 else { throw CodeMapArtifactContainerError.payloadDecodeFailed }
                depth -= 1
                inPrimitive = false
            case UInt8(ascii: ","):
                try increment(&tokenCount, limit: policy.maximumJSONTokenCount)
                inPrimitive = false
            case UInt8(ascii: ":"), UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\t"):
                inPrimitive = false
            default:
                if !inPrimitive {
                    try increment(&tokenCount, limit: policy.maximumJSONTokenCount)
                    inPrimitive = true
                }
            }
        }
        guard !inString, !escaped, depth == 0 else {
            throw CodeMapArtifactContainerError.payloadDecodeFailed
        }
    }

    private static func isCanonicalDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte) ||
                (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains(byte)
        }
    }

    private static func boundedInt(_ value: some FixedWidthInteger) throws -> Int {
        guard let result = Int(exactly: value) else {
            throw CodeMapArtifactContainerError.invalidPayloadLength
        }
        return result
    }

    private static func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw CodeMapArtifactContainerError.invalidPayloadLength
        }
        return result
    }
}

private enum CodeMapArtifactOutcomeKind: UInt8 {
    case ready = 1
    case readyNoSymbols = 2
    case oversize = 3
    case decodeFailed = 4
    case parseFailed = 5

    init(outcome: CodeMapSyntaxArtifactOutcome) {
        self = switch outcome {
        case .ready: .ready
        case .readyNoSymbols: .readyNoSymbols
        case .oversize: .oversize
        case .decodeFailed: .decodeFailed
        case .parseFailed: .parseFailed
        }
    }
}

private struct CodeMapArtifactSummary {
    private(set) var topLevelCounts = [UInt64](repeating: 0, count: 11)
    private(set) var nestedCounts = [UInt64](repeating: 0, count: 5)
    private(set) var stringCount: UInt64 = 0
    private(set) var collectionEntryCount: UInt64 = 0
    private(set) var stringUTF8ByteCount: UInt64 = 0
    private(set) var maximumStringUTF8ByteCount: UInt64 = 0

    var fields: [UInt64] {
        topLevelCounts + nestedCounts + [
            stringCount,
            collectionEntryCount,
            stringUTF8ByteCount,
            maximumStringUTF8ByteCount
        ]
    }

    static func validateDeclared(
        fields: [UInt64],
        policy: CodeMapArtifactContainerPolicy
    ) throws {
        guard fields.count == 20 else { throw CodeMapArtifactContainerError.invalidSummary }
        let declaredStringCount = fields[16]
        let declaredCollectionCount = fields[17]
        let declaredStringByteCount = fields[18]
        let declaredMaximumStringByteCount = fields[19]
        guard declaredCollectionCount <= policy.maximumCollectionEntryCount else {
            throw CodeMapArtifactContainerError.collectionLimitExceeded
        }
        guard declaredStringCount <= policy.maximumStringCount,
              declaredStringByteCount <= policy.maximumStringUTF8ByteCount,
              declaredMaximumStringByteCount <= policy.maximumIndividualStringUTF8ByteCount,
              declaredMaximumStringByteCount <= declaredStringByteCount
        else {
            throw CodeMapArtifactContainerError.stringLimitExceeded
        }
        var visibleCollectionCount: UInt64 = 0
        for field in fields[0 ..< 16] {
            let (next, overflow) = visibleCollectionCount.addingReportingOverflow(field)
            guard !overflow, field <= declaredCollectionCount else {
                throw CodeMapArtifactContainerError.invalidSummary
            }
            visibleCollectionCount = next
        }
        guard visibleCollectionCount <= declaredCollectionCount else {
            throw CodeMapArtifactContainerError.invalidSummary
        }
    }

    init(outcome: CodeMapSyntaxArtifactOutcome, policy: CodeMapArtifactContainerPolicy) throws {
        guard case let .ready(artifact) = outcome else {
            try Self.validateNegativeOutcome(outcome)
            return
        }

        let topLevelCollectionCounts = [
            artifact.imports.count, artifact.exports.count, artifact.classes.count, artifact.interfaces.count,
            artifact.aliases.count, artifact.literalUnions.count, artifact.functions.count, artifact.enums.count,
            artifact.globalVars.count, artifact.macros.count, artifact.referencedTypes.count
        ]
        for (index, count) in topLevelCollectionCounts.enumerated() {
            topLevelCounts[index] = UInt64(count)
            try addCollection(count: count, policy: policy)
        }

        for value in artifact.imports + artifact.exports + artifact.literalUnions + artifact.macros + artifact.referencedTypes {
            try addString(value, policy: policy)
        }
        for classInfo in artifact.classes {
            try addString(classInfo.name, policy: policy)
            nestedCounts[0] = try adding(nestedCounts[0], UInt64(classInfo.methods.count))
            nestedCounts[1] = try adding(nestedCounts[1], UInt64(classInfo.properties.count))
            try addCollection(count: classInfo.methods.count, policy: policy)
            try addCollection(count: classInfo.properties.count, policy: policy)
            for method in classInfo.methods {
                try add(method, policy: policy)
            }
            for property in classInfo.properties {
                try add(property, policy: policy)
            }
        }
        for interfaceInfo in artifact.interfaces {
            try addString(interfaceInfo.name, policy: policy)
            nestedCounts[2] = try adding(nestedCounts[2], UInt64(interfaceInfo.methods.count))
            nestedCounts[3] = try adding(nestedCounts[3], UInt64(interfaceInfo.properties.count))
            try addCollection(count: interfaceInfo.methods.count, policy: policy)
            try addCollection(count: interfaceInfo.properties.count, policy: policy)
            for method in interfaceInfo.methods {
                try add(method, policy: policy)
            }
            for property in interfaceInfo.properties {
                try add(property, policy: policy)
            }
        }
        for alias in artifact.aliases {
            try addString(alias.name, policy: policy)
            try addString(alias.definitionLine, policy: policy)
        }
        for function in artifact.functions {
            try add(function, policy: policy)
        }
        for enumInfo in artifact.enums {
            try addString(enumInfo.name, policy: policy)
            nestedCounts[4] = try adding(nestedCounts[4], UInt64(enumInfo.cases.count))
            try addCollection(count: enumInfo.cases.count, policy: policy)
            for value in enumInfo.cases {
                try addString(value, policy: policy)
            }
        }
        for variable in artifact.globalVars {
            try addString(variable.name, policy: policy)
            try addOptionalString(variable.typeName, policy: policy)
            try addString(variable.definitionLine, policy: policy)
        }
    }

    private static func validateNegativeOutcome(_ outcome: CodeMapSyntaxArtifactOutcome) throws {
        if case let .oversize(reason) = outcome {
            let values: (Int, Int) = switch reason {
            case let .utf8Bytes(actual, limit), let .utf16Units(actual, limit), let .lines(actual, limit):
                (actual, limit)
            }
            guard values.0 >= 0, values.1 >= 0 else {
                throw CodeMapArtifactContainerError.invalidSummary
            }
        }
    }

    private mutating func add(_ value: FunctionInfo, policy: CodeMapArtifactContainerPolicy) throws {
        try addString(value.name, policy: policy)
        try addCollection(count: value.parameters.count, policy: policy)
        for parameter in value.parameters {
            try addOptionalString(parameter.externalName, policy: policy)
            try addString(parameter.localName, policy: policy)
            try addOptionalString(parameter.typeName, policy: policy)
        }
        try addOptionalString(value.returnType, policy: policy)
        try addString(value.definitionLine, policy: policy)
    }

    private mutating func add(_ value: PropertyInfo, policy: CodeMapArtifactContainerPolicy) throws {
        try addString(value.name, policy: policy)
        try addOptionalString(value.typeName, policy: policy)
    }

    private mutating func addCollection(count: Int, policy: CodeMapArtifactContainerPolicy) throws {
        guard let count = UInt64(exactly: count) else {
            throw CodeMapArtifactContainerError.collectionLimitExceeded
        }
        collectionEntryCount = try adding(collectionEntryCount, count)
        guard collectionEntryCount <= policy.maximumCollectionEntryCount else {
            throw CodeMapArtifactContainerError.collectionLimitExceeded
        }
    }

    private mutating func addOptionalString(_ value: String?, policy: CodeMapArtifactContainerPolicy) throws {
        if let value { try addString(value, policy: policy) }
    }

    private mutating func addString(_ value: String, policy: CodeMapArtifactContainerPolicy) throws {
        let byteCount = UInt64(value.utf8.count)
        guard byteCount <= policy.maximumIndividualStringUTF8ByteCount else {
            throw CodeMapArtifactContainerError.stringLimitExceeded
        }
        stringCount = try adding(stringCount, 1)
        stringUTF8ByteCount = try adding(stringUTF8ByteCount, byteCount)
        maximumStringUTF8ByteCount = max(maximumStringUTF8ByteCount, byteCount)
        guard stringCount <= policy.maximumStringCount,
              stringUTF8ByteCount <= policy.maximumStringUTF8ByteCount
        else {
            throw CodeMapArtifactContainerError.stringLimitExceeded
        }
    }

    private func adding(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw CodeMapArtifactContainerError.collectionLimitExceeded
        }
        return result
    }
}

private struct CodeMapArtifactBinaryWriter {
    private(set) var data: Data

    init(capacity: Int) {
        data = Data(capacity: capacity)
    }

    mutating func append(_ value: UInt8) {
        data.append(value)
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

    mutating func append(_ value: Data) {
        data.append(value)
    }
}

private struct CodeMapArtifactBinaryReader {
    let data: Data
    private(set) var offset = 0

    mutating func readUInt8() throws -> UInt8 {
        try readData(count: 1)[0]
    }

    mutating func readUInt32() throws -> UInt32 {
        try readData(count: 4).reduce(into: UInt32(0)) { result, byte in
            result = (result << 8) | UInt32(byte)
        }
    }

    mutating func readUInt64() throws -> UInt64 {
        try readData(count: 8).reduce(into: UInt64(0)) { result, byte in
            result = (result << 8) | UInt64(byte)
        }
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, count <= data.count - offset else {
            throw CodeMapArtifactContainerError.truncated
        }
        let end = offset + count
        defer { offset = end }
        return data.subdata(in: offset ..< end)
    }
}
