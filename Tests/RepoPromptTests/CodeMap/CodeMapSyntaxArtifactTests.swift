import Darwin
import Foundation
@testable import RepoPrompt
import SwiftTreeSitter
import XCTest

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
        XCTAssertFalse(encodedText.contains("11111111-1111-1111-1111-111111111111"))
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
        let invalid = makeSource(data: Data([0xFF, 0xFE, 0x00, 0xD8]))
        XCTAssertEqual(
            try CodeMapSyntaxArtifactBuilder.build(source: invalid, language: .swift),
            .decodeFailed(.undecodable)
        )

        let emptySourceQuery = QueryStub { content, language in
            XCTAssertEqual(content, "")
            XCTAssertEqual(language, .swift)
            return .captures([])
        }
        XCTAssertEqual(
            try CodeMapSyntaxArtifactBuilder.build(
                source: makeSource(data: Data()),
                language: .swift,
                syntaxManager: emptySourceQuery
            ),
            .readyNoSymbols
        )

        XCTAssertEqual(
            try CodeMapSyntaxArtifactBuilder.build(
                source: makeSource(text: "// comment only"),
                language: .swift,
                syntaxManager: QueryStub { _, _ in .captures([]) }
            ),
            .readyNoSymbols
        )
        XCTAssertEqual(
            try CodeMapSyntaxArtifactBuilder.build(
                source: makeSource(text: "let value = 1"),
                language: .swift,
                syntaxManager: QueryStub { _, _ in .oversize(.utf16Units(actual: 11, limit: 10)) }
            ),
            .oversize(.utf16Units(actual: 11, limit: 10))
        )
        XCTAssertEqual(
            try CodeMapSyntaxArtifactBuilder.build(
                source: makeSource(text: "let value = 1"),
                language: .swift,
                syntaxManager: QueryStub { _, _ in .parseFailed(.parserReturnedNilTree) }
            ),
            .parseFailed(.parserReturnedNilTree)
        )
        XCTAssertEqual(
            try CodeMapSyntaxArtifactBuilder.build(
                source: makeSource(text: "let value = 1"),
                language: .swift,
                syntaxManager: QueryStub { _, _ in .parseFailed(.parserReturnedNilRoot) }
            ),
            .parseFailed(.parserReturnedNilRoot)
        )

        let lineOversizeSource = makeSource(text: String(repeating: "\n", count: SyntaxManager.parseLineLimit))
        XCTAssertEqual(
            try CodeMapSyntaxArtifactBuilder.build(source: lineOversizeSource, language: .swift),
            .oversize(.lines(actual: SyntaxManager.parseLineLimit + 1, limit: SyntaxManager.parseLineLimit))
        )
    }

    func testBuilderPropagatesTransientQueryFailuresWithoutArtifactOrCatalogState() throws {
        let candidateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeMapSyntaxArtifactTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: candidateRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let resolvedPath = try XCTUnwrap(candidateRoot.path.withCString { pointer -> String? in
            guard let resolved = realpath(pointer, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        })
        let root = URL(fileURLWithPath: resolvedPath, isDirectory: true)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try CodeMapArtifactStore(rootURL: root)

        XCTAssertThrowsError(
            try CodeMapSyntaxArtifactBuilder.build(
                source: makeSource(text: "struct Example {}"),
                language: .swift,
                syntaxManager: QueryStub { _, _ in throw QueryStubError.transient }
            )
        ) { error in
            XCTAssertEqual(error as? QueryStubError, .transient)
        }

        for namespace in ["artifacts", "catalog", "leases"] {
            let url = root.appendingPathComponent("CodeMapArtifacts/v1/\(namespace)", isDirectory: true)
            let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])?
                .compactMap { $0 as? URL }
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true } ?? []
            XCTAssertTrue(files.isEmpty, namespace)
        }
    }

    func testReadyArtifactIsDeterministicAcrossValidationIdentityAndHasNoFilenameInput() throws {
        let content = """
        struct Example {
            let value: Int
        }
        """
        let first = makeSource(text: content, fingerprintSeed: 1)
        let second = makeSource(text: content, fingerprintSeed: 50)
        let firstOutcome = try CodeMapSyntaxArtifactBuilder.build(source: first, language: .swift)
        let repeatedOutcome = try CodeMapSyntaxArtifactBuilder.build(source: first, language: .swift)
        let otherIdentityOutcome = try CodeMapSyntaxArtifactBuilder.build(source: second, language: .swift)

        XCTAssertEqual(firstOutcome, repeatedOutcome)
        XCTAssertEqual(firstOutcome, otherIdentityOutcome)
        guard case let .ready(artifact) = firstOutcome else {
            return XCTFail("Expected representative Swift content to produce an artifact.")
        }
        XCTAssertEqual(artifact.classes.map(\.name), ["Example"])
        XCTAssertFalse(artifact.apiDescription.contains("source.swift"))
        XCTAssertFalse(artifact.apiDescription.contains("other-name.swift"))

        let javaContent = "void helper() {}"
        let captures: [NamedRange]
        switch try SyntaxManager.shared.codeMap(content: javaContent, language: .java) {
        case let .captures(result): captures = result
        case let .oversize(reason): return XCTFail("Unexpected oversize result: \(reason)")
        case let .parseFailed(failure): return XCTFail("Unexpected parse failure: \(failure)")
        }
        XCTAssertFalse(captures.isEmpty)

        let modern = try XCTUnwrap(
            CodeMapGenerator.generateSyntaxArtifact(
                from: captures,
                content: javaContent,
                language: .java
            )
        )
        XCTAssertEqual(modern.functions.map(\.name), ["helper"])
        XCTAssertTrue(modern.classes.isEmpty)
    }

    func testUnsupportedExtensionsRemainOutsideArtifactOutcomes() {
        XCTAssertNil(SyntaxManager.shared.language(forFileExtension: "unsupported"))
        XCTAssertFalse(SyntaxManager.supportsCodeMap(fileExtension: "unsupported"))
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

    private func makeSource(text: String, fingerprintSeed: UInt64 = 1) -> CodeMapSourceSnapshot {
        makeSource(data: Data(text.utf8), fingerprintSeed: fingerprintSeed)
    }

    private func makeSource(data: Data, fingerprintSeed: UInt64 = 1) -> CodeMapSourceSnapshot {
        let fingerprint = FileContentFingerprint(
            deviceID: fingerprintSeed,
            fileNumber: fingerprintSeed + 1,
            byteSize: Int64(data.count),
            modificationSeconds: Int64(fingerprintSeed + 2),
            modificationNanoseconds: 0,
            statusChangeSeconds: Int64(fingerprintSeed + 3),
            statusChangeNanoseconds: 0
        )
        return CodeMapSourceSnapshot(
            validatedContent: ValidatedRawFileContentSnapshot(
                data: data,
                modificationDate: fingerprint.modificationDate,
                fingerprint: fingerprint
            )
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
