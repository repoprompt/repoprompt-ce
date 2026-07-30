@testable import RepoPromptApp
import XCTest

final class GitServiceSplitUnifiedDiffByFileRecoveryTests: XCTestCase {
    func testSplitUnifiedDiffByFileSeparatesModifiedRenameAndDeleteBlocks() {
        let diff = #"""
        warning: ignored preamble
        diff --git a/Sources/One.swift b/Sources/One.swift
        index 1111111..2222222 100644
        --- a/Sources/One.swift
        +++ b/Sources/One.swift
        @@ -1 +1 @@
        -old
        +new
        diff --git "a/Docs/Old Name.md" "b/Docs/New Name.md"
        similarity index 100%
        rename from "Docs/Old Name.md"
        rename to "Docs/New Name.md"
        diff --git a/Docs/Removed.md b/Docs/Removed.md
        deleted file mode 100644
        index 3333333..0000000
        --- a/Docs/Removed.md
        +++ /dev/null
        @@ -1 +0,0 @@
        -deleted
        """#.trimmingCharacters(in: .newlines)

        let perFile = GitService.splitUnifiedDiffByFile(diff)

        XCTAssertEqual(Set(perFile.keys), [
            "Sources/One.swift",
            "Docs/New Name.md",
            "Docs/Removed.md"
        ])
        XCTAssertFalse(perFile["Sources/One.swift"]?.contains("warning: ignored preamble") ?? true)
        XCTAssertFalse(perFile["Sources/One.swift"]?.contains("Docs/New Name.md") ?? true)
        XCTAssertTrue(perFile["Docs/New Name.md"]?.contains("rename to \"Docs/New Name.md\"") ?? false)
        XCTAssertTrue(perFile["Docs/Removed.md"]?.contains("+++ /dev/null") ?? false)
        XCTAssertFalse(perFile["Docs/Removed.md"]?.hasSuffix("\n") ?? true)
    }

    func testSplitUnifiedDiffByFileNormalizesNumberedNoIndexDotPrefixes() {
        let diff = #"""
        diff --git 1/./Nested/Second File.txt 2/./Nested/Second File.txt
        new file mode 100644
        index 0000000..2222222
        --- /dev/null
        +++ 2/./Nested/Second File.txt
        @@ -0,0 +1 @@
        +second
        """#.trimmingCharacters(in: .newlines)

        let normalized = GitService.normalizeBatchedUntrackedDiffPaths(diff)
        let perFile = GitService.splitUnifiedDiffByFile(normalized)

        XCTAssertTrue(normalized.contains("diff --git a/Nested/Second File.txt b/Nested/Second File.txt"))
        XCTAssertFalse(normalized.contains("1/./"))
        XCTAssertFalse(normalized.contains("2/./"))
        XCTAssertEqual(Set(perFile.keys), Set(["Nested/Second File.txt"]))
    }

    func testSplitUnifiedDiffByFileNormalizesMnemonicPrefixes() {
        let diff = #"""
        diff --git i/Sources/One.swift w/Sources/One.swift
        index 1111111..2222222 100644
        --- i/Sources/One.swift
        +++ w/Sources/One.swift
        @@ -1 +1 @@
        -old
        +new
        """#.trimmingCharacters(in: .newlines)

        let perFile = GitService.splitUnifiedDiffByFile(diff)

        XCTAssertEqual(Set(perFile.keys), Set(["Sources/One.swift"]))
    }

    func testSplitUnifiedDiffByFilePreservesUnpairedMnemonicLikeDirectories() {
        let diff = #"""
        diff --git w/Sources/One.swift w/Sources/One.swift
        index 1111111..2222222 100644
        --- w/Sources/One.swift
        +++ w/Sources/One.swift
        @@ -1 +1 @@
        -old
        +new
        """#.trimmingCharacters(in: .newlines)

        let perFile = GitService.splitUnifiedDiffByFile(diff)

        XCTAssertEqual(Set(perFile.keys), Set(["w/Sources/One.swift"]))
    }

    func testSplitUnifiedDiffByFileNormalizesNumberedPrefixesFromHeaderFallback() {
        let diff = #"""
        diff --git 1/./Artifacts/Output.bin 2/./Artifacts/Output.bin
        index 1111111..2222222 100644
        Binary files 1/./Artifacts/Output.bin and 2/./Artifacts/Output.bin differ
        """#.trimmingCharacters(in: .newlines)

        let perFile = GitService.splitUnifiedDiffByFile(diff)

        XCTAssertEqual(Set(perFile.keys), Set(["Artifacts/Output.bin"]))
    }
}
