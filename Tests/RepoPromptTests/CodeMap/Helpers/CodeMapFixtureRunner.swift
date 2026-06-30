import Foundation
@testable import RepoPrompt

struct CodeMapFixture {
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

    static func renderArtifactCodeMap(for fixture: CodeMapFixture, tempRoot: URL) throws -> String {
        let virtualURL = tempRoot.appendingPathComponent(fixture.relativePath)
        guard let language = SyntaxManager.shared.language(forFileExtension: fixture.fileExtension) else {
            throw CodeMapFixtureError.unsupportedExtension(fixture.fileExtension)
        }

        let source = makeSourceSnapshot(content: fixture.content)
        guard case let .ready(artifact) = try CodeMapSyntaxArtifactBuilder.build(
            source: source,
            language: language
        ) else {
            throw CodeMapFixtureError.noArtifact(fixture.relativePath)
        }

        let rendered = CodeMapAPIContentFormatter.pathAndImportsBlock(
            displayPath: virtualURL.path,
            imports: artifact.imports
        ) + artifact.apiDescription
        return normalize(rendered, tempRoot: tempRoot)
    }

    static func makeSourceSnapshot(content: String, fingerprintSeed: UInt64 = 1) -> CodeMapSourceSnapshot {
        let data = Data(content.utf8)
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

    static func expectedFileTree() throws -> String {
        let url = try resourceURL(
            baseName: "fixture-tree",
            extension: "txt",
            subdirectory: "Goldens"
        )
        return try normalize(String(contentsOf: url, encoding: .utf8))
    }

    static func renderFixtureFileTree(
        tempRoot: URL,
        mode: String = "full",
        selectedFileIDs: Set<UUID> = []
    ) -> String {
        let rootPath = StandardizedPath.absolute(tempRoot.path)
        let sourceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let helperID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let goID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let rootID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let folderID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

        let nestedFolder = FileTreeFolderSnapshot(
            id: folderID,
            name: "nested",
            fullPath: tempRoot.appendingPathComponent("nested").path,
            standardizedFullPath: StandardizedPath.absolute(tempRoot.appendingPathComponent("nested").path),
            standardizedRootPath: rootPath,
            children: [
                .file(FileTreeFileSnapshot(
                    id: helperID,
                    name: "helper.py",
                    fileExtension: "py",
                    hasCodeMap: true
                ))
            ]
        )

        let root = FileTreeFolderSnapshot(
            id: rootID,
            name: "Fixtures",
            fullPath: tempRoot.path,
            standardizedFullPath: rootPath,
            standardizedRootPath: rootPath,
            children: [
                .file(FileTreeFileSnapshot(id: sourceID, name: "sample.swift", fileExtension: "swift", hasCodeMap: true)),
                .folder(nestedFolder),
                .file(FileTreeFileSnapshot(id: goID, name: "worker.go", fileExtension: "go", hasCodeMap: true))
            ]
        )

        let snapshot = FileTreeSelectionSnapshot(
            roots: [root],
            selectedFileIDs: selectedFileIDs,
            mode: mode,
            showFullPaths: true,
            onlyIncludeRootsWithSelectedFiles: false,
            includeLegend: true,
            showCodeMapMarkers: true
        )
        let rendered = CodeMapExtractor.generateFileTree(using: snapshot)
        return rendered.isEmpty ? "" : normalize(rendered, tempRoot: tempRoot)
    }

    static func normalize(_ text: String, tempRoot: URL? = nil) -> String {
        var normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if let tempRoot {
            normalized = normalized.replacingOccurrences(of: StandardizedPath.absolute(tempRoot.path), with: "<ROOT>")
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

    private static func resourceURL(baseName: String, extension fileExtension: String, subdirectory: String) throws -> URL {
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
