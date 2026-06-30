import Foundation
import XCTest

final class SourceTargetTestConstructorGuardTests: XCTestCase {
    func testSourceTargetContainsNoProvenanceOrBindingTestConstructors() throws {
        let sourcesRoot = try RepoRoot.url()
            .appendingPathComponent("Sources/RepoPrompt", isDirectory: true)
        let forbiddenSymbols = [
            "testFixtureValidated",
            "testOnlyValidated",
            "testOnlyUnchecked"
        ]
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: sourcesRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        )
        var violations: [String] = []

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            for symbol in forbiddenSymbols where contents.contains(symbol) {
                try violations.append(
                    "\(RepoRoot.relativePath(for: fileURL, relativeTo: RepoRoot.url())): \(symbol)"
                )
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Production Sources must not expose provenance/binding test constructors:\n\(violations.joined(separator: "\n"))"
        )
    }
}
