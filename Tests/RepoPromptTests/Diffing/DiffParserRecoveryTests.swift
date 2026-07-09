@testable import RepoPromptApp
import XCTest

final class DiffParserRecoveryTests: XCTestCase {
    func testExtractFileEntriesPreservesQuotedSpacePathsSelfClosingDeletesAndTruncatedBodies() {
        let input = #"""
        preamble ignored
        <file path="Sources/My Feature/View Model.swift" action="modify">
        <change><description>Update</description><content>alpha</content></change>
        </file>
        <file path=“Docs/Release Notes.md” action=“create”>
        <content>bravo</content>
        </file>
        <file path="Old Folder/Removed File.swift" action="delete" />
        <file path="Truncated/Still Parsed.swift" action="modify">
        <content>charlie</content>
        """#.trimmingCharacters(in: .newlines)

        let entries = DiffParserUtils.extractFileEntries(from: input)

        XCTAssertEqual(entries.count, 4)
        guard entries.count == 4 else { return }
        XCTAssertEqual(entries.map(\.path), [
            "Sources/My Feature/View Model.swift",
            "Docs/Release Notes.md",
            "Old Folder/Removed File.swift",
            "Truncated/Still Parsed.swift"
        ])
        XCTAssertEqual(entries.map(\.action), ["modify", "create", "delete", "modify"])
        XCTAssertEqual(entries[2].body, "")
        XCTAssertTrue(entries[3].body.contains("charlie"))

        let changedLines = GitDiffPatchParsing.extractChangedLines(from: [
            "Sources/My Feature/View Model.swift": #"""
            --- a/Sources/My Feature/View Model.swift
            +++ b/Sources/My Feature/View Model.swift
            @@ -3 +3 @@
            -old title
            \ No newline at end of file
            +new title
            \ No newline at end of file
            """#,
            "Docs/Release Notes.md": #"""
            --- /dev/null
            +++ b/Docs/Release Notes.md
            @@ -0,0 +1 @@
            +initial notes
            """#
        ])

        XCTAssertEqual(changedLines.map { "\($0.path):\($0.lineNumber):\($0.changeType):\($0.content)" }, [
            "Docs/Release Notes.md:1:+:initial notes",
            "Sources/My Feature/View Model.swift:3:-:old title",
            "Sources/My Feature/View Model.swift:3:+:new title"
        ])
    }
}
