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

    private static func sanitizedFixtureName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        return sanitized.isEmpty ? "Fixture" : sanitized
    }
}
