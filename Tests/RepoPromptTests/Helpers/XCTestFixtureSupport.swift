import Foundation
import XCTest

extension XCTestCase {
    func makeTestDirectory(
        name: String = #function,
        namespace: String = "RepoPromptTests",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent("\(Self.sanitizedFixtureName(name))-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            XCTFail("create test directory \(url.path): \(error)", file: file, line: line)
            throw error
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    func makeTestPath(
        name: String = #function,
        namespace: String = "RepoPromptTests"
    ) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent("\(Self.sanitizedFixtureName(name))-\(UUID().uuidString)")
            .standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private static func sanitizedFixtureName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        return sanitized.isEmpty ? "Fixture" : sanitized
    }
}

enum SwiftFixtureSource {
    static func emptyStruct(_ name: String, trailingNewline: Bool = true) -> String {
        "struct \(name) {}" + (trailingNewline ? "\n" : "")
    }

    static func sourceReferencingTarget(
        source: String = "Source",
        target: String = "Target",
        sourcePath: String? = nil,
        targetPath: String? = nil
    ) -> [String: String] {
        [
            sourcePath ?? "Sources/\(source).swift": "struct \(source) { let target: \(target) }\n",
            targetPath ?? "Sources/\(target).swift": emptyStruct(target)
        ]
    }
}
