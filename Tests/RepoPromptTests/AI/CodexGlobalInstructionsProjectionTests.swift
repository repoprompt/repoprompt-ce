import CryptoKit
import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

final class CodexGlobalInstructionsProjectionTests: XCTestCase {
    private var root: URL!
    private var ordinaryHome: URL!
    private var managedHome: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexGlobalInstructionsProjectionTests-\(UUID().uuidString)")
        ordinaryHome = root.appendingPathComponent("ordinary", isDirectory: true)
        managedHome = root.appendingPathComponent("managed", isDirectory: true)
        try FileManager.default.createDirectory(at: ordinaryHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managedHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testPrepareCopiesBothFilesIncludingEmptyOverride() throws {
        try write(Data(), to: ordinary("AGENTS.override.md"))
        try write(Data("fallback".utf8), to: ordinary("AGENTS.md"))

        try project()

        XCTAssertEqual(try Data(contentsOf: managed("AGENTS.override.md")), Data())
        XCTAssertEqual(try Data(contentsOf: managed("AGENTS.md")), Data("fallback".utf8))
        assertRegularFile(managed("AGENTS.override.md"))
        assertRegularFile(managed("AGENTS.md"))
        let hashes = try manifestHashes()
        XCTAssertEqual(hashes["AGENTS.override.md"], hash(Data()))
        XCTAssertEqual(hashes["AGENTS.md"], hash(Data("fallback".utf8)))

        try project()
        XCTAssertEqual(try Data(contentsOf: managed("AGENTS.md")), Data("fallback".utf8))
    }

    func testPrepareRefreshesOwnedFilesAndRemovesOwnedMissingSources() throws {
        try write(Data("first override".utf8), to: ordinary("AGENTS.override.md"))
        try write(Data("fallback".utf8), to: ordinary("AGENTS.md"))
        try project()

        try write(Data("second override".utf8), to: ordinary("AGENTS.override.md"))
        try FileManager.default.removeItem(at: ordinary("AGENTS.md"))
        try project()

        XCTAssertEqual(try Data(contentsOf: managed("AGENTS.override.md")), Data("second override".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed("AGENTS.md").path))
        XCTAssertEqual(try Set(manifestHashes().keys), ["AGENTS.override.md"])
        try project()

        try FileManager.default.removeItem(at: ordinary("AGENTS.override.md"))
        try project()
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed("AGENTS.override.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    func testPrepareRejectsUnmanifestedDestinationWithoutMutatingEitherFile() throws {
        for existingData in [Data("foreign".utf8), Data("source".utf8)] {
            try resetManagedHome()
            try write(Data("source".utf8), to: ordinary("AGENTS.override.md"))
            try write(Data("fallback".utf8), to: ordinary("AGENTS.md"))
            try write(existingData, to: managed("AGENTS.override.md"))

            XCTAssertThrowsError(try project()) { error in
                guard case CodexGlobalInstructionsProjection.Failure.unownedDestination = error else {
                    return XCTFail("Expected unowned destination failure, got \(error)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: managed("AGENTS.override.md")), existingData)
            XCTAssertFalse(FileManager.default.fileExists(atPath: managed("AGENTS.md").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path))
        }
    }

    func testPrepareRejectsModifiedOwnedDestinationWithoutMutatingEitherFile() throws {
        try write(Data("override".utf8), to: ordinary("AGENTS.override.md"))
        try write(Data("old fallback".utf8), to: ordinary("AGENTS.md"))
        try project()
        let originalManifest = try Data(contentsOf: manifestURL)

        try write(Data("manual edit".utf8), to: managed("AGENTS.override.md"))
        try write(Data("new fallback".utf8), to: ordinary("AGENTS.md"))

        XCTAssertThrowsError(try project()) { error in
            guard case CodexGlobalInstructionsProjection.Failure.modifiedDestination = error else {
                return XCTFail("Expected modified destination failure, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: managed("AGENTS.override.md")), Data("manual edit".utf8))
        XCTAssertEqual(try Data(contentsOf: managed("AGENTS.md")), Data("old fallback".utf8))
        XCTAssertEqual(try Data(contentsOf: manifestURL), originalManifest)
    }

    func testPrepareRejectsDestinationSymlinkWithoutFollowingIt() throws {
        let external = root.appendingPathComponent("external")
        try write(Data("external".utf8), to: external)
        try write(Data("override".utf8), to: ordinary("AGENTS.override.md"))
        try write(Data("fallback".utf8), to: ordinary("AGENTS.md"))
        try FileManager.default.createSymbolicLink(at: managed("AGENTS.override.md"), withDestinationURL: external)

        XCTAssertThrowsError(try project())
        XCTAssertEqual(try Data(contentsOf: external), Data("external".utf8))
        assertSymbolicLink(managed("AGENTS.override.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed("AGENTS.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    func testPrepareFollowsSourceSymlinkAndCreatesRegularDestination() throws {
        let external = root.appendingPathComponent("source")
        try write(Data("first".utf8), to: external)
        try FileManager.default.createSymbolicLink(at: ordinary("AGENTS.md"), withDestinationURL: external)

        try project()

        XCTAssertEqual(try Data(contentsOf: managed("AGENTS.md")), Data("first".utf8))
        assertRegularFile(managed("AGENTS.md"))

        try write(Data("second".utf8), to: external)
        try project()
        XCTAssertEqual(try Data(contentsOf: managed("AGENTS.md")), Data("second".utf8))
    }

    func testPrepareReconcilesEstablishedInterruptedUpdate() throws {
        try write(Data("old override".utf8), to: ordinary("AGENTS.override.md"))
        try write(Data("old fallback".utf8), to: ordinary("AGENTS.md"))
        try project()

        try write(Data("new override".utf8), to: ordinary("AGENTS.override.md"))
        try write(Data("new fallback".utf8), to: ordinary("AGENTS.md"))
        try write(Data("new override".utf8), to: managed("AGENTS.override.md"))

        try project()

        XCTAssertEqual(try Data(contentsOf: managed("AGENTS.override.md")), Data("new override".utf8))
        XCTAssertEqual(try Data(contentsOf: managed("AGENTS.md")), Data("new fallback".utf8))
        let hashes = try manifestHashes()
        XCTAssertEqual(hashes["AGENTS.override.md"], hash(Data("new override".utf8)))
        XCTAssertEqual(hashes["AGENTS.md"], hash(Data("new fallback".utf8)))
    }

    func testPrepareRejectsInvalidManifestBeforeMutation() throws {
        try write(Data("source".utf8), to: ordinary("AGENTS.md"))
        let unicodeDigits = String(repeating: "١", count: 64)
        let invalidManifests = [
            Data("not json".utf8),
            Data(#"{"schemaVersion":2,"projectedFileHashes":{}}"#.utf8),
            Data(#"{"schemaVersion":1,"projectedFileHashes":{"OTHER.md":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}"#.utf8),
            Data(#"{"schemaVersion":1,"projectedFileHashes":{"AGENTS.md":"invalid"}}"#.utf8),
            Data("{\"schemaVersion\":1,\"projectedFileHashes\":{\"AGENTS.md\":\"\(unicodeDigits)\"}}".utf8)
        ]

        for manifest in invalidManifests {
            try resetManagedHome()
            try write(manifest, to: manifestURL)
            XCTAssertThrowsError(try project())
            XCTAssertFalse(FileManager.default.fileExists(atPath: managed("AGENTS.md").path))
        }

        try resetManagedHome()
        let external = root.appendingPathComponent("external-manifest")
        try write(Data("{}".utf8), to: external)
        try FileManager.default.createSymbolicLink(at: manifestURL, withDestinationURL: external)
        XCTAssertThrowsError(try project())
        assertSymbolicLink(manifestURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed("AGENTS.md").path))
    }

    private var manifestURL: URL {
        managed(".repoprompt-agents-projection.json")
    }

    private func ordinary(_ name: String) -> URL {
        ordinaryHome.appendingPathComponent(name)
    }

    private func managed(_ name: String) -> URL {
        managedHome.appendingPathComponent(name)
    }

    private func project() throws {
        try CodexGlobalInstructionsProjection.prepare(
            ordinaryCodexHome: ordinaryHome,
            managedCodexHome: managedHome
        )
    }

    private func resetManagedHome() throws {
        try? FileManager.default.removeItem(at: managedHome)
        try FileManager.default.createDirectory(at: managedHome, withIntermediateDirectories: true)
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    private func manifestHashes() throws -> [String: String] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
        let dictionary = try XCTUnwrap(object as? [String: Any])
        return try XCTUnwrap(dictionary["projectedFileHashes"] as? [String: String])
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func assertRegularFile(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        var metadata = Darwin.stat()
        XCTAssertEqual(lstat(url.path, &metadata), 0, file: file, line: line)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFREG, file: file, line: line)
    }

    private func assertSymbolicLink(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        var metadata = Darwin.stat()
        XCTAssertEqual(lstat(url.path, &metadata), 0, file: file, line: line)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFLNK, file: file, line: line)
    }
}
