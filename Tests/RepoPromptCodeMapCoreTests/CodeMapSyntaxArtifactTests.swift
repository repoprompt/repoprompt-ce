import CryptoKit
import Foundation
import XCTest
@testable import RepoPromptCodeMapCore

final class CodeMapSyntaxArtifactTests: XCTestCase {
    func testArtifactSerializationIsPathFreeAndRecomputesDerivedValues() throws {
        let artifact = makeArtifact()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(artifact)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(
            Set(object.keys),
            [
                "aliases", "classes", "enums", "exports", "functions", "globalVars", "imports",
                "interfaces", "literalUnions", "macros", "referencedTypes"
            ]
        )
        let forbiddenFragments = [
            "path", "root", "fileid", "session", "worktree", "modification", "fingerprint",
            "digest", "token", "validation"
        ]
        for key in recursiveKeys(object).map({ $0.lowercased() }) {
            XCTAssertFalse(forbiddenFragments.contains { key.contains($0) }, "Unexpected identity key: \(key)")
        }

        let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(encodedText.contains("/private/sentinel/source.swift"))
        XCTAssertEqual(try JSONDecoder().decode(CodeMapSyntaxArtifact.self, from: encoded), artifact)

        var tampered = object
        tampered["apiDescription"] = "PATH-LEAK-SENTINEL"
        tampered["apiTokenCount"] = -1
        tampered["definedTypeNames"] = ["Wrong"]
        let decoded = try JSONDecoder().decode(
            CodeMapSyntaxArtifact.self,
            from: JSONSerialization.data(withJSONObject: tampered, options: [.sortedKeys])
        )
        XCTAssertEqual(decoded, artifact)
        XCTAssertFalse(decoded.apiDescription.contains("PATH-LEAK-SENTINEL"))

        var copiedClasses = artifact.classes
        copiedClasses[0].properties.append(PropertyInfo(name: "localMutation", typeName: "Int"))
        XCTAssertFalse(artifact.classes[0].properties.contains { $0.name == "localMutation" })
    }

    func testOutcomeSerializationUsesStableExplicitDiscriminators() throws {
        let cases: [(CodeMapSyntaxArtifactOutcome, String)] = [
            (.readyNoSymbols, #"{"kind":"readyNoSymbols"}"#),
            (.decodeFailed(.undecodable), #"{"failure":"undecodable","kind":"decodeFailed"}"#),
            (
                .oversize(.utf8Bytes(actual: 12, limit: 10)),
                #"{"kind":"oversize","reason":{"actual":12,"kind":"utf8Bytes","limit":10}}"#
            ),
            (.parseFailed(.parserReturnedNilTree), #"{"failure":"parserReturnedNilTree","kind":"parseFailed"}"#),
            (.parseFailed(.parserReturnedNilRoot), #"{"failure":"parserReturnedNilRoot","kind":"parseFailed"}"#)
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for (outcome, expectedJSON) in cases {
            let data = try encoder.encode(outcome)
            XCTAssertEqual(String(data: data, encoding: .utf8), expectedJSON)
            XCTAssertEqual(try JSONDecoder().decode(CodeMapSyntaxArtifactOutcome.self, from: data), outcome)
        }

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                CodeMapSyntaxArtifactOutcome.self,
                from: Data(#"{"kind":"unsupported"}"#.utf8)
            )
        )
    }

    func testBuilderMapsDecodeEmptyNoSymbolsOversizeAndParseFailures() throws {
        XCTAssertEqual(
            try CodeMapSyntaxArtifactBuilder.build(
                source: makeFailedSource(),
                language: .swift
            ),
            .decodeFailed(.undecodable)
        )

        let emptySourceQuery = QueryStub { content, language in
            XCTAssertEqual(content, "")
            XCTAssertEqual(language, .swift)
            return .captures([])
        }
        XCTAssertEqual(
            try CodeMapSyntaxArtifactBuilder.build(
                source: makeSource(text: ""),
                language: .swift,
                syntaxEngine: emptySourceQuery
            ),
            .readyNoSymbols
        )

        XCTAssertEqual(
            try CodeMapSyntaxArtifactBuilder.build(
                source: makeSource(text: "// comment only"),
                language: .swift,
                syntaxEngine: QueryStub { _, _ in .captures([]) }
            ),
            .readyNoSymbols
        )
        XCTAssertEqual(
            try CodeMapSyntaxArtifactBuilder.build(
                source: makeSource(text: "let value = 1"),
                language: .swift,
                syntaxEngine: QueryStub { _, _ in .oversize(.utf16Units(actual: 11, limit: 10)) }
            ),
            .oversize(.utf16Units(actual: 11, limit: 10))
        )
        XCTAssertEqual(
            try CodeMapSyntaxArtifactBuilder.build(
                source: makeSource(text: "let value = 1"),
                language: .swift,
                syntaxEngine: QueryStub { _, _ in .parseFailed(.parserReturnedNilTree) }
            ),
            .parseFailed(.parserReturnedNilTree)
        )
        XCTAssertEqual(
            try CodeMapSyntaxArtifactBuilder.build(
                source: makeSource(text: "let value = 1"),
                language: .swift,
                syntaxEngine: QueryStub { _, _ in .parseFailed(.parserReturnedNilRoot) }
            ),
            .parseFailed(.parserReturnedNilRoot)
        )

        let lineOversizeSource = makeSource(
            text: String(repeating: "\n", count: CodeMapSyntaxEngine.parseLineLimit)
        )
        XCTAssertEqual(
            try CodeMapSyntaxArtifactBuilder.build(source: lineOversizeSource, language: .swift),
            .oversize(
                .lines(
                    actual: CodeMapSyntaxEngine.parseLineLimit + 1,
                    limit: CodeMapSyntaxEngine.parseLineLimit
                )
            )
        )
    }

    func testBuilderPropagatesExactTransientQueryError() throws {
        XCTAssertThrowsError(
            try CodeMapSyntaxArtifactBuilder.build(
                source: makeSource(text: "struct Example {}"),
                language: .swift,
                syntaxEngine: QueryStub { _, _ in throw QueryStubError.transient }
            )
        ) { error in
            XCTAssertEqual(error as? QueryStubError, .transient)
        }
    }

    func testReadyArtifactIsDeterministicAcrossSourceMetadataAndHasNoFilenameInput() throws {
        let content = """
        struct Example {
            let value: Int
        }
        """
        let first = makeSource(text: content, digestSeed: 1)
        let second = makeSource(text: content, digestSeed: 50)
        let firstOutcome = try CodeMapSyntaxArtifactBuilder.build(source: first, language: .swift)
        let repeatedOutcome = try CodeMapSyntaxArtifactBuilder.build(source: first, language: .swift)
        let otherMetadataOutcome = try CodeMapSyntaxArtifactBuilder.build(source: second, language: .swift)

        XCTAssertEqual(firstOutcome, repeatedOutcome)
        XCTAssertEqual(firstOutcome, otherMetadataOutcome)
        guard case let .ready(artifact) = firstOutcome else {
            return XCTFail("Expected representative Swift content to produce an artifact.")
        }
        XCTAssertEqual(artifact.classes.map(\.name), ["Example"])
        XCTAssertFalse(artifact.apiDescription.contains("source.swift"))
        XCTAssertFalse(artifact.apiDescription.contains("other-name.swift"))

        let javaOutcome = try CodeMapSyntaxArtifactBuilder.build(
            source: makeSource(text: "void helper() {}"),
            language: .java
        )
        guard case let .ready(javaArtifact) = javaOutcome else {
            return XCTFail("Expected representative Java content to produce an artifact.")
        }
        XCTAssertEqual(javaArtifact.functions.map(\.name), ["helper"])
        XCTAssertTrue(javaArtifact.classes.isEmpty)
    }

    func testUnsupportedExtensionsRemainOutsideArtifactOutcomes() {
        XCTAssertNil(CodeMapSyntaxEngine.shared.language(forFileExtension: "unsupported"))
        XCTAssertFalse(CodeMapSyntaxEngine.supportsCodeMap(fileExtension: "unsupported"))
    }

    private func makeArtifact() -> CodeMapSyntaxArtifact {
        CodeMapSyntaxArtifact(
            imports: ["Foundation"],
            exports: ["Example"],
            classes: [
                ClassInfo(
                    name: "Example",
                    methods: [
                        FunctionInfo(
                            name: "run",
                            parameters: [],
                            returnType: "Void",
                            definitionLine: "func run()",
                            lineNumber: 3
                        )
                    ],
                    properties: [PropertyInfo(name: "value", typeName: "Int")]
                )
            ],
            interfaces: [],
            aliases: [TypeAliasInfo(name: "Count", definitionLine: "typealias Count = Int")],
            literalUnions: [],
            functions: [],
            enums: [],
            globalVars: [],
            macros: [],
            referencedTypes: ["Int", "Void"]
        )
    }

    private func makeSource(text: String, digestSeed: UInt8 = 1) -> CodeMapCoreSourceSnapshot {
        let data = Data(text.utf8)
        var digestInput = data
        digestInput.append(digestSeed)
        return CodeMapCoreSourceSnapshot(
            rawByteCount: data.count,
            rawSHA256: CodeMapRawSourceDigest(bytes: Data(SHA256.hash(data: digestInput))),
            decoderPolicy: .workspaceAutomaticV1,
            decodeResult: .decoded(
                CodeMapDecodedSource(
                    text: text,
                    detectedEncodingRawValue: String.Encoding.utf8.rawValue
                )
            )
        )
    }

    private func makeFailedSource() -> CodeMapCoreSourceSnapshot {
        let bytes = Data([0xFF, 0xFE, 0x00, 0xD8])
        return CodeMapCoreSourceSnapshot(
            rawByteCount: bytes.count,
            rawSHA256: CodeMapRawSourceDigest(bytes: Data(SHA256.hash(data: bytes))),
            decoderPolicy: .workspaceAutomaticV1,
            decodeResult: .failed(.undecodable)
        )
    }

    private func recursiveKeys(_ value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            return dictionary.flatMap { key, value in [key] + recursiveKeys(value) }
        }
        if let array = value as? [Any] {
            return array.flatMap(recursiveKeys)
        }
        return []
    }
}

private struct QueryStub: CodeMapSyntaxQuerying {
    let handler: (String, LanguageType) throws -> CodeMapSyntaxQueryOutcome

    func codeMap(content: String, language: LanguageType) throws -> CodeMapSyntaxQueryOutcome {
        try handler(content, language)
    }
}

private enum QueryStubError: Error, Equatable {
    case transient
}
