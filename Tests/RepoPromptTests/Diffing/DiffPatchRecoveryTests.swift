import RepoPromptVCS
import XCTest

final class DiffPatchRecoveryTests: XCTestCase {
    func testChangedLineRecoveryPreservesSpacePathsAndNoNewlineMarkers() {
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
