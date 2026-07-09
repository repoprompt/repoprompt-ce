@testable import RepoPromptApp
import XCTest

final class BenchmarkDiffApplierTests: XCTestCase {
    func testModifyChangeAppliesGeneratedDiffChunks() async {
        let original = "func greet() {\n    print(\"hello\")\n}\n"
        let expected = "func greet() {\n    print(\"goodbye\")\n}\n"
        var fileSystem = BenchmarkMockFileSystem(files: ["src/App.swift": original])
        let baseline = fileSystem.snapshot()
        let parsedFile = ParsedFile(
            fileName: "benchmark/src/App.swift",
            changes: [
                Change(
                    id: UUID(),
                    type: .modify,
                    summary: "Update greeting",
                    isSelected: true,
                    content: [
                        "func greet() {",
                        "    print(\"goodbye\")",
                        "}"
                    ],
                    startSelector: nil,
                    endSelector: nil,
                    searchBlock: [
                        "func greet() {",
                        "    print(\"hello\")",
                        "}"
                    ]
                )
            ],
            fileContent: original,
            canBeLoaded: true,
            action: .modify,
            lineEnding: "\n"
        )
        let task = BenchmarkTaskSpec(
            id: "benchmark-diff-applier-modify",
            type: .curlyFixSwift,
            language: .swift,
            selectFiles: ["src/App.swift"],
            maxEdits: 1,
            instructions: [],
            task: "Update greeting",
            acceptance: [],
            params: [:]
        )

        let result = await BenchmarkDiffApplier.apply(
            parsedFiles: [parsedFile],
            task: task,
            fileSystem: &fileSystem,
            baseline: baseline
        )

        XCTAssertEqual(result.errors, [])
        XCTAssertEqual(result.edited, [BenchmarkEditedFile(path: "src/App.swift", content: expected)])
        XCTAssertEqual(fileSystem.content(for: "src/App.swift"), expected)
    }
}
