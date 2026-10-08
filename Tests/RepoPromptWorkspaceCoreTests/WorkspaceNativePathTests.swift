import Foundation
@testable import RepoPromptWorkspaceCore
import XCTest

final class WorkspaceNativePathTests: XCTestCase {
    func testNativeIngressPreservesLiteralFilenameBytes() throws {
        let names = [" ", "file ", "line\nname", "comma,name", "report–draft.txt", "x／y.txt", "file\\name", "100%20", "~/literal"]
        for name in names {
            let relative = try WorkspaceRelativePath.nativeText(name)
            XCTAssertEqual(try Array(relative.utf8ForPlatform().utf8), Array(name.utf8), name)
            let absolute = try WorkspaceAbsolutePath.nativeText("/repo/\(name)")
            XCTAssertEqual(try Array(absolute.utf8ForWire().utf8), Array("/repo/\(name)".utf8), name)
        }
    }

    func testIdentityKeysDistinguishCaseUnicodeAndWhitespace() throws {
        let spellings = ["/repo/File", "/repo/file", "/repo/file ", "/repo/café", "/repo/cafe\u{301}"]
        let paths = try spellings.map(WorkspaceAbsolutePath.nativeText)
        XCTAssertEqual(Set(paths).count, spellings.count)
        for (path, spelling) in zip(paths, spellings) {
            XCTAssertEqual(try Array(path.utf8ForWire().utf8), Array(spelling.utf8))
        }
    }

    func testNonUnicodeNativeIdentityNeverSilentlyBecomesReplacementText() throws {
        let first = try WorkspaceAbsolutePath.nativeBytes([0x2F, 0xFF])
        let second = try WorkspaceAbsolutePath.nativeBytes([0x2F, 0xFE])
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(Set([first, second]).count, 2)
        XCTAssertEqual(first.display, second.display)
        XCTAssertThrowsError(try first.utf8ForPlatform()) {
            XCTAssertEqual($0 as? WorkspaceNativePathError, .unsupportedTextEncoding)
        }
        XCTAssertThrowsError(try first.utf8ForWire()) {
            XCTAssertEqual($0 as? WorkspaceNativePathError, .unsupportedTextEncoding)
        }
        XCTAssertThrowsError(try JSONEncoder().encode(first))
    }

    func testNativeKindsRejectInvalidInputBeforeSeparatorNormalization() throws {
        XCTAssertThrowsError(try WorkspaceAbsolutePath.nativeText("relative")) {
            XCTAssertEqual($0 as? WorkspaceNativePathError, .absolutePathRequired)
        }
        XCTAssertThrowsError(try WorkspaceRelativePath.nativeText("/absolute")) {
            XCTAssertEqual($0 as? WorkspaceNativePathError, .relativePathRequired)
        }
        for name in ["", ".", "..", "/name", "name/", "name//", "one/two", "bad\0name"] {
            XCTAssertThrowsError(try WorkspaceFilename.nativeText(name), name)
        }
        XCTAssertThrowsError(try WorkspaceAbsolutePath.nativeBytes([0x2F, 0, 0x61])) {
            XCTAssertEqual($0 as? WorkspaceNativePathError, .embeddedNUL)
        }
        let space = try WorkspaceFilename.nativeText(" ")
        XCTAssertEqual(try space.utf8ForPlatform(), " ")
    }

    func testDotResolutionRequiresExplicitWorkspaceInputPolicy() throws {
        let raw = try WorkspaceRelativePath.nativeText("link/../file ")
        XCTAssertEqual(try raw.utf8ForPlatform(), "link/../file ")
        let root = try WorkspaceAbsolutePath.nativeText("/repo")
        XCTAssertEqual(try root.appending(raw).utf8ForPlatform(), "/repo/link/../file ")
        XCTAssertEqual(try raw.lexicallyNormalizedForWorkspaceInput().utf8ForPlatform(), "file ")
        XCTAssertThrowsError(try WorkspaceRelativePath.nativeText("one/../../outside").lexicallyNormalizedForWorkspaceInput()) {
            XCTAssertEqual($0 as? WorkspaceNativePathError, .escapesRoot)
        }
        let sibling = try WorkspaceAbsolutePath.nativeText("/repository/file")
        XCTAssertFalse(sibling.isLexicallyWithin(root))
        XCTAssertThrowsError(try sibling.relative(to: root))
        XCTAssertEqual(try root.appending(raw).relative(to: root), raw)
    }

    func testDirectoryRequirementSurvivesFilePathSeparatorNormalizationAndSerialization() throws {
        let path = try WorkspaceAbsolutePath.nativeText("/repo///directory//")
        XCTAssertTrue(path.requiresDirectory)
        XCTAssertEqual(try path.utf8ForPlatform(), "/repo/directory/")
        let roundTripped = try JSONDecoder().decode(WorkspaceAbsolutePath.self, from: JSONEncoder().encode(path))
        XCTAssertEqual(roundTripped, path)
        XCTAssertTrue(roundTripped.requiresDirectory)
        let relative = try WorkspaceRelativePath.nativeText("directory/")
        XCTAssertTrue(try WorkspaceAbsolutePath.nativeText("/repo").appending(relative).requiresDirectory)
    }

    func testCodablePreservesLegacyStringShapeAndValidatesDecodedKind() throws {
        let spelling = "/repo/cafe\u{301} \n100%20"
        let wire = try JSONEncoder().encode(spelling)
        let path = try JSONDecoder().decode(WorkspaceAbsolutePath.self, from: wire)
        let encodedSpelling = try JSONDecoder().decode(String.self, from: JSONEncoder().encode(path))
        XCTAssertEqual(Array(encodedSpelling.utf8), Array(spelling.utf8))
        XCTAssertThrowsError(try JSONDecoder().decode(WorkspaceRelativePath.self, from: wire))
        XCTAssertThrowsError(try JSONDecoder().decode(WorkspaceFilename.self, from: JSONEncoder().encode("name/")))
    }

    func testTypedComponentsPreserveFilenameBytesAndDirectoryPrefixOrder() throws {
        let relative = try WorkspaceRelativePath.nativeText("root alias/folder ／ name/file ")
        XCTAssertEqual(try relative.firstFilename?.utf8ForWire(), "root alias")
        XCTAssertEqual(try relative.lastFilename?.utf8ForWire(), "file ")
        XCTAssertEqual(try relative.droppingFirstComponent()?.utf8ForWire(), "folder ／ name/file ")
        XCTAssertEqual(try relative.directoryPrefixes.map { try $0.utf8ForWire() }, ["root alias/folder ／ name/", "root alias/"])
        XCTAssertEqual(try relative.filenameComponents().map { try $0.utf8ForWire() }, ["root alias", "folder ／ name", "file "])
        let prefix = try XCTUnwrap(relative.parent)
        XCTAssertEqual(try prefix.appending(XCTUnwrap(relative.lastFilename)), relative)
        XCTAssertNil(try WorkspaceRelativePath.nativeText("file").parent)
        XCTAssertThrowsError(try WorkspaceRelativePath.nativeText("root/../file").filenameComponents())
    }

    func testNonUnicodeBytesRoundTripThroughTypedComponentOperations() throws {
        let path = try WorkspaceRelativePath.nativeBytes([0xFF, 0x2F, 0xFE])
        let expected = try [WorkspaceFilename.nativeBytes([0xFF]), WorkspaceFilename.nativeBytes([0xFE])]
        XCTAssertEqual(try path.filenameComponents(), expected)
        XCTAssertEqual(try XCTUnwrap(path.parent).appending(XCTUnwrap(path.lastFilename)), path)
        XCTAssertEqual(path.droppingFirstComponent(), try WorkspaceRelativePath.nativeBytes([0xFE]))
    }

    func testExplicitUserTildeExpansionDoesNotApplySearchOrAliasGrammar() throws {
        let home = try WorkspaceAbsolutePath.nativeText("/Users/test")
        XCTAssertEqual(try WorkspaceNativePathInput.userText("~/link/../file ", homeDirectory: home).utf8ForWire(), "/Users/test/link/../file ")
        XCTAssertEqual(try WorkspaceNativePathInput.userText("~/", homeDirectory: home).utf8ForWire(), "/Users/test/")
        XCTAssertEqual(try WorkspaceNativePathInput.userText("~", homeDirectory: home).utf8ForWire(), "/Users/test/")
        XCTAssertEqual(try WorkspaceRelativePath.nativeText("~").utf8ForWire(), "~")
        XCTAssertEqual(try WorkspaceNativePathInput.userText("~literal", homeDirectory: home).utf8ForWire(), "~literal")
        XCTAssertEqual(try WorkspaceNativePathInput.userText("alias//file ", homeDirectory: home).utf8ForWire(), "alias/file ")
        XCTAssertEqual(try WorkspaceNativePathInput.userText(" ~/file ", homeDirectory: home).utf8ForWire(), " ~/file ")
    }
}
