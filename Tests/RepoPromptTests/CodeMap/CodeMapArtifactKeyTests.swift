import CryptoKit
import Foundation
@testable import RepoPrompt
import XCTest

final class CodeMapArtifactKeyTests: XCTestCase {
    func testLanguageRegistryCoversEveryLanguageAndUsesExactRegisteredQueryBytes() throws {
        let expected = expectedRegistrations()
        let packageManifest = try String(contentsOf: packageManifestURL(), encoding: .utf8)
        let manager = SyntaxManager()
        var stableIDs = Set<CodeMapPipelineLanguageID>()

        XCTAssertEqual(Set(expected.keys), Set(LanguageType.allCases))
        for language in LanguageType.allCases {
            try XCTContext.runActivity(named: language.rawValue) { _ in
                let registration = try XCTUnwrap(expected[language])
                let descriptor = try manager.codeMapPipelineDescriptor(for: language)
                let identity = try manager.pipelineIdentity(for: language, decoderPolicy: .workspaceAutomaticV1)

                XCTAssertEqual(descriptor.stableLanguageID, registration.stableID)
                XCTAssertTrue(stableIDs.insert(descriptor.stableLanguageID).inserted)
                XCTAssertEqual(descriptor.grammarRevision, registration.revision)
                XCTAssertTrue(
                    packageManifest.contains(
                        ".package(url: \"\(registration.packageURL)\", revision: \"\(registration.revision)\")"
                    )
                )
                XCTAssertEqual(descriptor.queryBytes, Data(registration.query.utf8))
                XCTAssertGreaterThan(descriptor.treeSitterABIVersion, 0)
                XCTAssertEqual(identity.languageID, descriptor.stableLanguageID)
                XCTAssertEqual(identity.grammarRevision, descriptor.grammarRevision)
                XCTAssertEqual(identity.treeSitterABIVersion, descriptor.treeSitterABIVersion)
                XCTAssertEqual(
                    identity.codeMapQuerySHA256.bytes,
                    Data(SHA256.hash(data: Data(registration.query.utf8)))
                )
                XCTAssertEqual(identity.limits, referenceLimits())
                XCTAssertEqual(identity.flags, referenceFlags(for: registration.stableID).map { name, value in
                    CodeMapPipelineNamedFlag(name: name, enabled: value == 1)
                })
            }
        }

        let ts = try manager.codeMapPipelineDescriptor(for: .ts)
        let tsx = try manager.codeMapPipelineDescriptor(for: .tsx)
        XCTAssertNotEqual(ts.stableLanguageID, tsx.stableLanguageID)
        XCTAssertEqual(ts.grammarRevision, tsx.grammarRevision)
        XCTAssertEqual(ts.queryBytes, tsx.queryBytes)
    }

    func testCanonicalPipelineAndKeyMatchIndependentReferenceEncoder() throws {
        let identity = try SyntaxManager().pipelineIdentity(for: .swift, decoderPolicy: .workspaceAutomaticV1)
        let referencePipeline = referencePipelineBytes(identity)

        XCTAssertEqual(identity.canonicalBytes, referencePipeline)
        XCTAssertEqual(try CodeMapPipelineIdentity(canonicalBytes: referencePipeline), identity)
        XCTAssertEqual(try CodeMapPipelineIdentity(canonicalBytes: referencePipeline).canonicalBytes, referencePipeline)

        let source = makeSource(data: Data("struct ReferenceEncoder {}".utf8))
        let key = try CodeMapArtifactKey(source: source, pipelineIdentity: identity)
        let referenceKey = referenceKeyBytes(
            rawDigest: source.rawSHA256.bytes,
            rawByteCount: UInt64(source.rawByteCount),
            pipelineBytes: referencePipeline
        )
        let referenceStorageDigest = Data(SHA256.hash(data: referenceKey))

        XCTAssertEqual(key.canonicalBytes, referenceKey)
        XCTAssertEqual(key.pipelineIdentity.decoderPolicy, source.decoderPolicy)
        XCTAssertEqual(key.storageDigest.bytes, referenceStorageDigest)
        XCTAssertEqual(try CodeMapArtifactKey(canonicalBytes: referenceKey), key)
        XCTAssertEqual(try CodeMapArtifactKey(canonicalBytes: referenceKey).canonicalBytes, referenceKey)
    }

    func testFixedCanonicalKeyBytesAndStorageDigestGolden() throws {
        let identity = try CodeMapPipelineIdentity(
            languageID: .swift,
            decoderPolicy: .workspaceAutomaticV1,
            grammarRevision: String(repeating: "0", count: 40),
            treeSitterABIVersion: 14,
            codeMapQuerySHA256: CodeMapSHA256Digest(bytes: Data(0 ..< 32)),
            extractorVersion: CodeMapSemanticVersion(major: 1, minor: 2, patch: 3),
            generatorVersion: CodeMapSemanticVersion(major: 4, minor: 5, patch: 6),
            artifactSchemaVersion: 7,
            oversizeParsePolicyVersion: 8,
            limits: referenceLimits(),
            flags: referenceFlags(for: .swift).map {
                CodeMapPipelineNamedFlag(name: $0.0, enabled: $0.1 == 1)
            }
        )
        let key = CodeMapArtifactKey(
            rawSHA256: CodeMapRawSourceDigest(bytes: Data(32 ..< 64)),
            rawByteCount: 0x0102_0304_0506_0708,
            pipelineIdentity: identity
        )
        let expectedCanonical = try XCTUnwrap(Data(base64Encoded: "Y29kZW1hcC1hcnRpZmFjdC1rZXktdjEgISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+PwECAwQFBgcIAAAB9WNvZGVtYXAtcGlwZWxpbmUtaWRlbnRpdHktdjEAAAAFc3dpZnQAAAAWd29ya3NwYWNlLWF1dG9tYXRpYy12MQAAACgwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwAAAADgABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fAAAAAQAAAAIAAAADAAAABAAAAAUAAAAGAAAABwAAAAgAAAAEAAAAJGpzdHMtbWF4LWFwcGVuZGVkLWNvbnRpbnVhdGlvbi1saW5lcwAAAAAAAABQAAAAEHBhcnNlLWxpbmUtY291bnQAAAAAAABhqAAAABZwYXJzZS11dGYxNi1jb2RlLXVuaXRzAAAAAAAW42AAAAAQcGFyc2UtdXRmOC1ieXRlcwAAAAAATEtAAAAABgAAABtmaWxlbmFtZS1tYWluLWNsYXNzLXNoYXBpbmcAAAAAGWpzdHMtc2lnbmF0dXJlLWV4dHJhY3Rpb24AAAAAFmxpZ2h0d2VpZ2h0LWV4dHJhY3Rpb24AAAAAH3BhdGgtZnJlZS1hcnRpZmFjdC1maW5hbGl6YXRpb24BAAAAFHN3aWZ0LXJhbmdlLXN0cmF0ZWd5AQAAABl0eXBlc2NyaXB0LXJhbmdlLXN0cmF0ZWd5AA=="))

        let expectedDigestSegments: [UInt64] = [
            0xF1F1_1877_9CBA_26F2,
            0x5DE7_DD0D_3D69_879B,
            0xB81D_E344_696F_03B4,
            0xB667_8418_C3D0_F5DE
        ]

        XCTAssertEqual(key.canonicalBytes, expectedCanonical)
        XCTAssertEqual(key.storageDigestHex, expectedDigestSegments.map { String(format: "%016llx", $0) }.joined())
    }

    #if DEBUG
        func testArtifactKeyRejectsSourceAndPipelineDecoderPolicyMismatch() throws {
            let source = makeSource(
                data: Data("decoder mismatch".utf8),
                decoderPolicy: .testOnlyMismatch
            )
            let identity = try SyntaxManager().pipelineIdentity(
                for: .swift,
                decoderPolicy: .workspaceAutomaticV1
            )
            XCTAssertThrowsError(try CodeMapArtifactKey(source: source, pipelineIdentity: identity)) {
                XCTAssertEqual(
                    $0 as? CodeMapCanonicalIdentityError,
                    .invalidValue(field: "decoder-policy-mismatch")
                )
            }
        }
    #endif

    func testKeyUsesRawSnapshotProvenanceWithoutRereadOrValidationIdentity() throws {
        let identity = try SyntaxManager().pipelineIdentity(for: .swift, decoderPolicy: .workspaceAutomaticV1)
        let utf8 = Data("same text".utf8)
        var utf16 = Data([0xFF, 0xFE])
        try utf16.append(XCTUnwrap("same text".data(using: .utf16LittleEndian)))

        let first = makeSource(data: utf8, fingerprintSeed: 1)
        let repeated = makeSource(data: utf8, fingerprintSeed: 999)
        let alternateEncoding = makeSource(data: utf16, fingerprintSeed: 1)
        let firstKey = try CodeMapArtifactKey(source: first, pipelineIdentity: identity)
        let repeatedKey = try CodeMapArtifactKey(source: repeated, pipelineIdentity: identity)
        let alternateKey = try CodeMapArtifactKey(source: alternateEncoding, pipelineIdentity: identity)

        XCTAssertEqual(firstKey, repeatedKey)
        XCTAssertEqual(firstKey.storageDigest, repeatedKey.storageDigest)
        XCTAssertNotEqual(firstKey, alternateKey)
        XCTAssertNotEqual(firstKey.rawSHA256, alternateKey.rawSHA256)
        XCTAssertNotEqual(firstKey.rawByteCount, alternateKey.rawByteCount)
        XCTAssertEqual(decodedText(first), decodedText(alternateEncoding))
    }

    func testEveryPipelineComponentLimitAndFlagChangesCanonicalKey() throws {
        let baseline = try SyntaxManager().pipelineIdentity(for: .swift, decoderPolicy: .workspaceAutomaticV1)
        let source = makeSource(data: Data("func componentMutation() {}".utf8))
        let baselineKey = try CodeMapArtifactKey(source: source, pipelineIdentity: baseline)
        var mutations: [(String, CodeMapPipelineIdentity)] = []

        try mutations.append(("language", copyIdentity(baseline, languageID: .python)))
        try mutations.append(("grammar revision", copyIdentity(baseline, grammarRevision: String(repeating: "a", count: 40))))
        try mutations.append(("grammar ABI", copyIdentity(baseline, abiVersion: baseline.treeSitterABIVersion + 1)))
        var queryBytes = baseline.codeMapQuerySHA256.bytes
        queryBytes[0] ^= 0xFF
        try mutations.append(("query digest", copyIdentity(baseline, queryDigest: CodeMapSHA256Digest(bytes: queryBytes))))

        let versionMutations: [(String, CodeMapSemanticVersion, CodeMapSemanticVersion)] = [
            ("extractor major", CodeMapSemanticVersion(major: 2, minor: 0, patch: 0), baseline.generatorVersion),
            ("extractor minor", CodeMapSemanticVersion(major: 1, minor: 1, patch: 0), baseline.generatorVersion),
            ("extractor patch", CodeMapSemanticVersion(major: 1, minor: 0, patch: 1), baseline.generatorVersion),
            ("generator major", baseline.extractorVersion, CodeMapSemanticVersion(major: 2, minor: 0, patch: 0)),
            ("generator minor", baseline.extractorVersion, CodeMapSemanticVersion(major: 1, minor: 1, patch: 0)),
            ("generator patch", baseline.extractorVersion, CodeMapSemanticVersion(major: 1, minor: 0, patch: 1))
        ]
        for (name, extractor, generator) in versionMutations {
            try mutations.append((name, copyIdentity(baseline, extractorVersion: extractor, generatorVersion: generator)))
        }
        try mutations.append(("artifact schema", copyIdentity(baseline, artifactSchemaVersion: 2)))
        try mutations.append(("oversize parse policy", copyIdentity(baseline, oversizeParsePolicyVersion: 2)))

        for index in baseline.limits.indices {
            var limits = baseline.limits
            limits[index] = CodeMapPipelineNamedLimit(name: limits[index].name, value: limits[index].value + 1)
            try mutations.append(("limit \(limits[index].name)", copyIdentity(baseline, limits: limits)))
        }
        for index in baseline.flags.indices {
            var flags = baseline.flags
            flags[index] = CodeMapPipelineNamedFlag(name: flags[index].name, enabled: !flags[index].enabled)
            try mutations.append(("flag \(flags[index].name)", copyIdentity(baseline, flags: flags)))
        }

        for (name, mutation) in mutations {
            try XCTContext.runActivity(named: name) { _ in
                let key = try CodeMapArtifactKey(source: source, pipelineIdentity: mutation)
                XCTAssertNotEqual(mutation.canonicalBytes, baseline.canonicalBytes)
                XCTAssertNotEqual(key.canonicalBytes, baselineKey.canonicalBytes)
                XCTAssertNotEqual(key.storageDigest, baselineKey.storageDigest)
            }
        }

        let alternateDecoderBytes = referencePipelineBytes(baseline, decoderPolicyID: "workspace-automatic-v2")
        XCTAssertNotEqual(alternateDecoderBytes, baseline.canonicalBytes)
        let alternateDecoderKeyBytes = referenceKeyBytes(
            rawDigest: source.rawSHA256.bytes,
            rawByteCount: UInt64(source.rawByteCount),
            pipelineBytes: alternateDecoderBytes
        )
        XCTAssertNotEqual(Data(SHA256.hash(data: alternateDecoderKeyBytes)), baselineKey.storageDigest.bytes)
        XCTAssertThrowsError(try CodeMapPipelineIdentity(canonicalBytes: alternateDecoderBytes))

        let alternateRawDigest = CodeMapRawSourceDigest(bytes: Data(repeating: 0xA5, count: 32))
        XCTAssertNotEqual(
            CodeMapArtifactKey(rawSHA256: alternateRawDigest, rawByteCount: baselineKey.rawByteCount, pipelineIdentity: baseline)
                .storageDigest,
            baselineKey.storageDigest
        )
        XCTAssertNotEqual(
            CodeMapArtifactKey(rawSHA256: baselineKey.rawSHA256, rawByteCount: baselineKey.rawByteCount + 1, pipelineIdentity: baseline)
                .storageDigest,
            baselineKey.storageDigest
        )
    }

    func testStrictPipelineDecoderRejectsNoncanonicalAndMalformedInputs() throws {
        let identity = try SyntaxManager().pipelineIdentity(for: .swift, decoderPolicy: .workspaceAutomaticV1)
        let canonical = identity.canonicalBytes

        for byteCount in 0 ..< canonical.count {
            XCTAssertThrowsError(try CodeMapPipelineIdentity(canonicalBytes: canonical.prefix(byteCount)))
        }
        XCTAssertThrowsError(try CodeMapPipelineIdentity(canonicalBytes: Data(repeating: 0, count: 16 * 1024 + 1)))
        XCTAssertThrowsError(try CodeMapPipelineIdentity(canonicalBytes: canonical + Data([0])))

        var wrongDomain = canonical
        wrongDomain[CodeMapPipelineIdentity.domain.utf8.count - 1] = UInt8(ascii: "2")
        XCTAssertThrowsError(try CodeMapPipelineIdentity(canonicalBytes: wrongDomain))

        var invalidUTF8 = canonical
        invalidUTF8[CodeMapPipelineIdentity.domain.utf8.count + 4] = 0xFF
        XCTAssertThrowsError(try CodeMapPipelineIdentity(canonicalBytes: invalidUTF8))

        var overlongLanguage = canonical
        replaceUInt32(in: &overlongLanguage, at: CodeMapPipelineIdentity.domain.utf8.count, with: UInt32.max)
        XCTAssertThrowsError(try CodeMapPipelineIdentity(canonicalBytes: overlongLanguage))

        let invalidCases = [
            referencePipelineBytes(identity, languageID: "unknown"),
            referencePipelineBytes(identity, decoderPolicyID: "unknown"),
            referencePipelineBytes(identity, grammarRevision: String(repeating: "A", count: 40)),
            referencePipelineBytes(identity, grammarRevision: String(repeating: "a", count: 39)),
            referencePipelineBytes(identity, abiVersion: 0),
            referencePipelineBytes(identity, extractorVersion: CodeMapSemanticVersion(major: 0, minor: 0, patch: 0)),
            referencePipelineBytes(identity, generatorVersion: CodeMapSemanticVersion(major: 0, minor: 0, patch: 0)),
            referencePipelineBytes(identity, artifactSchemaVersion: 0),
            referencePipelineBytes(identity, oversizeParsePolicyVersion: 0),
            referencePipelineBytes(identity, limits: Array(identity.limits.dropLast())),
            referencePipelineBytes(
                identity,
                limits: identity.limits + [CodeMapPipelineNamedLimit(name: "unexpected-limit", value: 1)]
            ),
            referencePipelineBytes(
                identity,
                limits: [identity.limits[1], identity.limits[0]] + Array(identity.limits.dropFirst(2))
            ),
            referencePipelineBytes(
                identity,
                limits: [identity.limits[0], identity.limits[0]] + Array(identity.limits.dropFirst(2))
            ),
            referencePipelineBytes(identity, flags: Array(identity.flags.dropLast()).map(referenceFlag)),
            referencePipelineBytes(
                identity,
                flags: identity.flags.map(referenceFlag) + [("unexpected-flag", 0)]
            ),
            referencePipelineBytes(
                identity,
                flags: [referenceFlag(identity.flags[1]), referenceFlag(identity.flags[0])] +
                    identity.flags.dropFirst(2).map(referenceFlag)
            ),
            referencePipelineBytes(
                identity,
                flags: [referenceFlag(identity.flags[0]), referenceFlag(identity.flags[0])] +
                    identity.flags.dropFirst(2).map(referenceFlag)
            ),
            referencePipelineBytes(
                identity,
                flags: identity.flags.enumerated().map { index, flag in
                    (flag.name, index == 0 ? UInt8(2) : (flag.enabled ? 1 : 0))
                }
            )
        ]
        for bytes in invalidCases {
            XCTAssertThrowsError(try CodeMapPipelineIdentity(canonicalBytes: bytes))
        }
    }

    func testStrictKeyDecoderRejectsNoncanonicalFraming() throws {
        let identity = try SyntaxManager().pipelineIdentity(for: .swift, decoderPolicy: .workspaceAutomaticV1)
        let source = makeSource(data: Data("let framing = true".utf8))
        let canonical = try CodeMapArtifactKey(source: source, pipelineIdentity: identity).canonicalBytes

        for byteCount in 0 ..< canonical.count {
            XCTAssertThrowsError(try CodeMapArtifactKey(canonicalBytes: canonical.prefix(byteCount)))
        }
        XCTAssertThrowsError(try CodeMapArtifactKey(canonicalBytes: Data(repeating: 0, count: 32 * 1024 + 1)))
        XCTAssertThrowsError(try CodeMapArtifactKey(canonicalBytes: canonical + Data([0])))

        var wrongDomain = canonical
        wrongDomain[CodeMapArtifactKey.domain.utf8.count - 1] = UInt8(ascii: "2")
        XCTAssertThrowsError(try CodeMapArtifactKey(canonicalBytes: wrongDomain))

        var mismatchedPipelineLength = canonical
        let lengthOffset = CodeMapArtifactKey.domain.utf8.count + 32 + 8
        replaceUInt32(in: &mismatchedPipelineLength, at: lengthOffset, with: UInt32(identity.canonicalBytes.count + 1))
        XCTAssertThrowsError(try CodeMapArtifactKey(canonicalBytes: mismatchedPipelineLength))
    }

    func testStorageDigestAndShardAreIdentityFreeDigestOnlyNames() throws {
        let sentinel = "/private/root/WORKTREE-SESSION-source.swift"
        let source = makeSource(data: Data(sentinel.utf8))
        let identity = try SyntaxManager().pipelineIdentity(for: .swift, decoderPolicy: .workspaceAutomaticV1)
        let key = try CodeMapArtifactKey(source: source, pipelineIdentity: identity)

        XCTAssertEqual(key.storageDigestHex.count, 64)
        XCTAssertTrue(key.storageDigestHex.allSatisfy { $0.isNumber || ("a" ... "f").contains($0) })
        XCTAssertEqual(key.shard.count, 2)
        XCTAssertEqual(key.shard, String(key.storageDigestHex.prefix(2)))
        XCTAssertFalse(key.storageDigestHex.localizedCaseInsensitiveContains("worktree"))
        XCTAssertFalse(key.storageDigestHex.localizedCaseInsensitiveContains("session"))
        XCTAssertFalse(key.storageDigestHex.contains(sentinel))
        XCTAssertFalse(key.shard.contains(sentinel))
        XCTAssertNil(key.canonicalBytes.range(of: Data(sentinel.utf8)))
    }

    private typealias ExpectedRegistration = (
        stableID: CodeMapPipelineLanguageID,
        packageURL: String,
        revision: String,
        query: String
    )

    private func expectedRegistrations() -> [LanguageType: ExpectedRegistration] {
        [
            .swift: (
                .swift, "https://github.com/alex-pinkus/tree-sitter-swift",
                "9253825dd2570430b53fa128cbb40cb62498e75d", swiftCodeMapQuery
            ),
            .js: (
                .javascript, "https://github.com/tree-sitter/tree-sitter-javascript",
                "39798e26b6d4dbcee8e522b8db83f8b2df33a5ea", javascriptCodeMapQuery
            ),
            .c_sharp: (
                .cSharp, "https://github.com/tree-sitter/tree-sitter-c-sharp.git",
                "b27b091bfdc5f16d0ef76421ea5609c82a57dff0", csharpCodeMapQuery
            ),
            .python: (
                .python, "https://github.com/tree-sitter/tree-sitter-python",
                "c5fca1a186e8e528115196178c28eefa8d86b0b0", pythonCodeMapQuery
            ),
            .c: (
                .c, "https://github.com/tree-sitter/tree-sitter-c",
                "3efee11f784605d44623d7dadd6cd12a0f73ea92", cCodeMapQuery
            ),
            .rust: (
                .rust, "https://github.com/tree-sitter/tree-sitter-rust",
                "2eaf126458a4d6a69401089b6ba78c5e5d6c1ced", rustCodeMapQuery
            ),
            .cpp: (
                .cpp, "https://github.com/tree-sitter/tree-sitter-cpp",
                "e5cea0ec884c5c3d2d1e41a741a66ce13da4d945", cppCodeMapQuery
            ),
            .go: (
                .go, "https://github.com/tree-sitter/tree-sitter-go",
                "c350fa54d38af725c40d061a602ee3205ef1e072", goCodeMapQuery
            ),
            .java: (
                .java, "https://github.com/tree-sitter/tree-sitter-java",
                "e10607b45ff745f5f876bfa3e94fbcc6b44bdc11", javaCodeMapQuery
            ),
            .dart: (
                .dart, "https://github.com/UserNobody14/tree-sitter-dart",
                "80e23c07b64494f7e21090bb3450223ef0b192f4", dartCodeMapQuery
            ),
            .ts: (
                .typescript, "https://github.com/tree-sitter/tree-sitter-typescript",
                "75b3874edb2dc714fb1fd77a32013d0f8699989f", typeScriptCodeMapQuery
            ),
            .tsx: (
                .tsx, "https://github.com/tree-sitter/tree-sitter-typescript",
                "75b3874edb2dc714fb1fd77a32013d0f8699989f", typeScriptCodeMapQuery
            ),
            .php: (
                .php, "https://github.com/provencher/tree-sitter-php",
                "0a99deca13c4af1fb9adcb03c958bfc9f4c740a9", phpCodeMapQuery
            ),
            .ruby: (
                .ruby, "https://github.com/tree-sitter/tree-sitter-ruby",
                "7a010836b74351855148818d5cb8170dc4df8e6a", rubyCodeMapQuery
            )
        ]
    }

    private func copyIdentity(
        _ identity: CodeMapPipelineIdentity,
        languageID: CodeMapPipelineLanguageID? = nil,
        grammarRevision: String? = nil,
        abiVersion: UInt32? = nil,
        queryDigest: CodeMapSHA256Digest? = nil,
        extractorVersion: CodeMapSemanticVersion? = nil,
        generatorVersion: CodeMapSemanticVersion? = nil,
        artifactSchemaVersion: UInt32? = nil,
        oversizeParsePolicyVersion: UInt32? = nil,
        limits: [CodeMapPipelineNamedLimit]? = nil,
        flags: [CodeMapPipelineNamedFlag]? = nil
    ) throws -> CodeMapPipelineIdentity {
        try CodeMapPipelineIdentity(
            languageID: languageID ?? identity.languageID,
            decoderPolicy: identity.decoderPolicy,
            grammarRevision: grammarRevision ?? identity.grammarRevision,
            treeSitterABIVersion: abiVersion ?? identity.treeSitterABIVersion,
            codeMapQuerySHA256: queryDigest ?? identity.codeMapQuerySHA256,
            extractorVersion: extractorVersion ?? identity.extractorVersion,
            generatorVersion: generatorVersion ?? identity.generatorVersion,
            artifactSchemaVersion: artifactSchemaVersion ?? identity.artifactSchemaVersion,
            oversizeParsePolicyVersion: oversizeParsePolicyVersion ?? identity.oversizeParsePolicyVersion,
            limits: limits ?? identity.limits,
            flags: flags ?? identity.flags
        )
    }

    private func referencePipelineBytes(
        _ identity: CodeMapPipelineIdentity,
        languageID: String? = nil,
        decoderPolicyID: String? = nil,
        grammarRevision: String? = nil,
        abiVersion: UInt32? = nil,
        extractorVersion: CodeMapSemanticVersion? = nil,
        generatorVersion: CodeMapSemanticVersion? = nil,
        artifactSchemaVersion: UInt32? = nil,
        oversizeParsePolicyVersion: UInt32? = nil,
        limits: [CodeMapPipelineNamedLimit]? = nil,
        flags: [(String, UInt8)]? = nil
    ) -> Data {
        var result = Data("codemap-pipeline-identity-v1".utf8)
        appendString(languageID ?? referenceLanguageID(identity.languageID), to: &result)
        appendString(decoderPolicyID ?? referenceDecoderPolicyID(identity.decoderPolicy), to: &result)
        appendString(grammarRevision ?? identity.grammarRevision, to: &result)
        appendUInt32(abiVersion ?? identity.treeSitterABIVersion, to: &result)
        result.append(identity.codeMapQuerySHA256.bytes)
        appendVersion(extractorVersion ?? identity.extractorVersion, to: &result)
        appendVersion(generatorVersion ?? identity.generatorVersion, to: &result)
        appendUInt32(artifactSchemaVersion ?? identity.artifactSchemaVersion, to: &result)
        appendUInt32(oversizeParsePolicyVersion ?? identity.oversizeParsePolicyVersion, to: &result)

        let encodedLimits = limits ?? referenceLimits()
        appendUInt32(UInt32(encodedLimits.count), to: &result)
        for limit in encodedLimits {
            appendString(limit.name, to: &result)
            appendUInt64(limit.value, to: &result)
        }

        let encodedFlags = flags ?? referenceFlags(for: identity.languageID)
        appendUInt32(UInt32(encodedFlags.count), to: &result)
        for (name, value) in encodedFlags {
            appendString(name, to: &result)
            result.append(value)
        }
        return result
    }

    private func referenceKeyBytes(rawDigest: Data, rawByteCount: UInt64, pipelineBytes: Data) -> Data {
        var result = Data("codemap-artifact-key-v1".utf8)
        result.append(rawDigest)
        appendUInt64(rawByteCount, to: &result)
        appendUInt32(UInt32(pipelineBytes.count), to: &result)
        result.append(pipelineBytes)
        return result
    }

    private func referenceDecoderPolicyID(_ policy: CodeMapSourceDecoderPolicy) -> String {
        switch policy {
        case .workspaceAutomaticV1: "workspace-automatic-v1"
        #if DEBUG
            case .testOnlyMismatch: "test-only-mismatch"
        #endif
        }
    }

    private func referenceLanguageID(_ languageID: CodeMapPipelineLanguageID) -> String {
        switch languageID {
        case .swift: "swift"
        case .javascript: "javascript"
        case .cSharp: "c-sharp"
        case .python: "python"
        case .c: "c"
        case .rust: "rust"
        case .cpp: "cpp"
        case .go: "go"
        case .java: "java"
        case .dart: "dart"
        case .typescript: "typescript"
        case .tsx: "tsx"
        case .php: "php"
        case .ruby: "ruby"
        }
    }

    private func referenceLimits() -> [CodeMapPipelineNamedLimit] {
        [
            CodeMapPipelineNamedLimit(name: "jsts-max-appended-continuation-lines", value: 80),
            CodeMapPipelineNamedLimit(name: "parse-line-count", value: 25000),
            CodeMapPipelineNamedLimit(name: "parse-utf16-code-units", value: 1_500_000),
            CodeMapPipelineNamedLimit(name: "parse-utf8-bytes", value: 5_000_000)
        ]
    }

    private func referenceFlags(for languageID: CodeMapPipelineLanguageID) -> [(String, UInt8)] {
        let isJSTS = languageID == .javascript || languageID == .typescript || languageID == .tsx
        let isLightweight = isJSTS || languageID == .php || languageID == .ruby
        return [
            ("filename-main-class-shaping", 0),
            ("jsts-signature-extraction", isJSTS ? 1 : 0),
            ("lightweight-extraction", isLightweight ? 1 : 0),
            ("path-free-artifact-finalization", 1),
            ("swift-range-strategy", languageID == .swift ? 1 : 0),
            ("typescript-range-strategy", languageID == .typescript || languageID == .tsx ? 1 : 0)
        ]
    }

    private func referenceFlag(_ flag: CodeMapPipelineNamedFlag) -> (String, UInt8) {
        (flag.name, flag.enabled ? 1 : 0)
    }

    private func appendString(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        appendUInt32(UInt32(bytes.count), to: &data)
        data.append(bytes)
    }

    private func appendVersion(_ value: CodeMapSemanticVersion, to data: inout Data) {
        appendUInt32(value.major, to: &data)
        appendUInt32(value.minor, to: &data)
        appendUInt32(value.patch, to: &data)
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private func appendUInt64(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    private func replaceUInt32(in data: inout Data, at offset: Int, with value: UInt32) {
        var bytes = Data()
        appendUInt32(value, to: &bytes)
        data.replaceSubrange(offset ..< offset + 4, with: bytes)
    }

    private func makeSource(
        data: Data,
        fingerprintSeed: Int64 = 1,
        decoderPolicy: CodeMapSourceDecoderPolicy = .workspaceAutomaticV1
    ) -> CodeMapSourceSnapshot {
        let fingerprint = FileContentFingerprint(
            deviceID: UInt64(fingerprintSeed),
            fileNumber: UInt64(fingerprintSeed + 1),
            byteSize: Int64(data.count),
            modificationSeconds: fingerprintSeed + 2,
            modificationNanoseconds: fingerprintSeed + 3,
            statusChangeSeconds: fingerprintSeed + 4,
            statusChangeNanoseconds: fingerprintSeed + 5
        )
        return CodeMapSourceSnapshot(
            validatedContent: ValidatedRawFileContentSnapshot(
                data: data,
                modificationDate: Date(timeIntervalSince1970: TimeInterval(fingerprintSeed + 2)),
                fingerprint: fingerprint
            ),
            decoderPolicy: decoderPolicy
        )
    }

    private func decodedText(_ snapshot: CodeMapSourceSnapshot) -> String? {
        guard case let .decoded(decoded) = snapshot.decodeResult else { return nil }
        return decoded.text
    }

    private func packageManifestURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
    }
}
