import CryptoKit
import Foundation
@testable import RepoPromptCodeMapCore

struct CodeMapFixture: Sendable {
    let relativePath: String
    let content: String

    var languageDirectory: String {
        (relativePath as NSString).deletingLastPathComponent
    }

    var fileName: String {
        (relativePath as NSString).lastPathComponent
    }

    var fileExtension: String {
        (fileName as NSString).pathExtension
    }

    var baseName: String {
        (fileName as NSString).deletingPathExtension
    }

    var goldenBaseName: String {
        "\(languageDirectory)_\(baseName)"
    }
}

enum CodeMapFixtureRunner {
    static let fixtureRelativePaths = [
        "c/smoke.c",
        "go/smoke.go",
        "py/smoke.py",
        "swift/smoke.swift",
        "ts/smoke.ts"
    ]

    static let expandedLanguageFixtureRelativePaths = [
        "cs/smoke.cs",
        "dart/smoke.dart",
        "java/smoke.java",
        "js/smoke.js",
        "rb/smoke.rb",
        "rs/smoke.rs"
    ]

    static let edgeFixtureRelativePaths = [
        "cpp/edge_methods.cpp",
        "php/edge_namespaces.php",
        "tsx/component.tsx"
    ]

    static var allFixtureRelativePaths: [String] {
        fixtureRelativePaths + expandedLanguageFixtureRelativePaths + edgeFixtureRelativePaths
    }

    static func loadFixtures(relativePaths: [String] = fixtureRelativePaths) throws -> [CodeMapFixture] {
        try relativePaths.map { relativePath in
            let directory = (relativePath as NSString).deletingLastPathComponent
            let fileName = (relativePath as NSString).lastPathComponent
            let baseName = (fileName as NSString).deletingPathExtension
            let fileExtension = (fileName as NSString).pathExtension
            let url = try resourceURL(
                baseName: baseName,
                extension: fileExtension,
                subdirectory: "Fixtures/\(directory)"
            )
            return try CodeMapFixture(
                relativePath: relativePath,
                content: String(contentsOf: url, encoding: .utf8)
            )
        }
    }

    static func expectedCodeMap(for fixture: CodeMapFixture) throws -> String {
        let url = try resourceURL(
            baseName: fixture.goldenBaseName,
            extension: "codemap.txt",
            subdirectory: "Goldens"
        )
        return try normalize(String(contentsOf: url, encoding: .utf8))
    }

    static func outcome(for fixture: CodeMapFixture) throws -> CodeMapSyntaxArtifactOutcome {
        guard let language = CodeMapSyntaxEngine.shared.language(forFileExtension: fixture.fileExtension) else {
            throw CodeMapFixtureError.unsupportedExtension(fixture.fileExtension)
        }
        return try CodeMapSyntaxArtifactBuilder.build(
            source: makeSourceSnapshot(content: fixture.content),
            language: language
        )
    }

    static func renderArtifactCodeMap(for fixture: CodeMapFixture, tempRoot: URL) throws -> String {
        guard case let .ready(artifact) = try outcome(for: fixture) else {
            throw CodeMapFixtureError.noArtifact(fixture.relativePath)
        }
        let virtualURL = tempRoot.appendingPathComponent(fixture.relativePath)
        let pathAndImports = (["File: \(virtualURL.path)", "Imports:"] + artifact.imports.map { "  - \($0)" })
            .joined(separator: "\n")
        return normalize(pathAndImports + artifact.apiDescription, tempRoot: tempRoot)
    }

    static func makeSourceSnapshot(content: String) -> CodeMapCoreSourceSnapshot {
        let data = Data(content.utf8)
        return CodeMapCoreSourceSnapshot(
            rawByteCount: data.count,
            rawSHA256: CodeMapRawSourceDigest(bytes: Data(SHA256.hash(data: data))),
            decoderPolicy: .workspaceAutomaticV1,
            decodeResult: .decoded(
                CodeMapDecodedSource(
                    text: content,
                    detectedEncodingRawValue: String.Encoding.utf8.rawValue
                )
            )
        )
    }

    static func normalize(_ text: String, tempRoot: URL? = nil) -> String {
        var normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if let tempRoot {
            normalized = normalized.replacingOccurrences(of: tempRoot.path, with: "<ROOT>")
        }
        while normalized.hasSuffix("\n\n") {
            normalized.removeLast()
        }
        if !normalized.hasSuffix("\n") {
            normalized.append("\n")
        }
        return normalized
    }

    private static func resourceURL(
        baseName: String,
        extension fileExtension: String,
        subdirectory: String
    ) throws -> URL {
        guard let url = Bundle.module.url(
            forResource: baseName,
            withExtension: fileExtension,
            subdirectory: subdirectory
        ) else {
            throw CodeMapFixtureError.missingResource("\(subdirectory)/\(baseName).\(fileExtension)")
        }
        return url
    }
}

enum CodeMapFixtureError: Error, CustomStringConvertible {
    case missingResource(String)
    case noArtifact(String)
    case unsupportedExtension(String)

    var description: String {
        switch self {
        case let .missingResource(path):
            "Missing Bundle.module resource: \(path)"
        case let .noArtifact(path):
            "No CodeMapSyntaxArtifact generated for \(path)"
        case let .unsupportedExtension(fileExtension):
            "Unsupported fixture extension: \(fileExtension)"
        }
    }
}
