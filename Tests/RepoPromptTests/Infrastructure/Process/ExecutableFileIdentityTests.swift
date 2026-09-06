import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

final class ExecutableFileIdentityTests: XCTestCase {
    func testPermitsHomebrewAdminGroupWritableDirectoryForCanonicalCellarAncestors() {
        let effectiveUID: uid_t = 501
        let cases: [(canonicalPath: String, directoryPath: String, ownerUID: uid_t)] = [
            ("/opt/homebrew/Cellar/opencode/1.0/bin/opencode", "/opt/homebrew", 0),
            ("/opt/homebrew/Cellar/opencode/1.0/bin/opencode", "/opt/homebrew/Cellar", effectiveUID),
            ("/opt/homebrew/Cellar/opencode/1.0/bin/opencode", "/opt/homebrew/Cellar/opencode/1.0/bin", 0),
            ("/usr/local/Cellar/opencode/1.0/bin/opencode", "/usr/local", 0),
            ("/usr/local/Cellar/opencode/1.0/bin/opencode", "/usr/local/Cellar", effectiveUID),
            ("/usr/local/Cellar/opencode/1.0/bin/opencode", "/usr/local/Cellar/opencode/1.0/bin", 0)
        ]

        for testCase in cases {
            XCTAssertTrue(
                ExecutableFileIdentity.permitsHomebrewAdminGroupWritableDirectory(
                    canonicalPath: testCase.canonicalPath,
                    directoryPath: testCase.directoryPath,
                    mode: 0o775,
                    ownerUID: testCase.ownerUID,
                    groupGID: 80,
                    effectiveUID: effectiveUID
                ),
                "Expected Homebrew directory to be permitted: \(testCase.directoryPath)"
            )
        }
    }

    func testPermitsHomebrewAdminGroupWritableDirectoryRejectsTrustBoundaryViolations() {
        let canonicalPath = "/opt/homebrew/Cellar/opencode/1.0/bin/opencode"
        let effectiveUID: uid_t = 501
        let cases: [(name: String, canonicalPath: String, directoryPath: String, mode: mode_t, ownerUID: uid_t, groupGID: gid_t)] = [
            ("non-admin group", canonicalPath, "/opt/homebrew/Cellar", 0o775, 0, 20),
            ("untrusted owner", canonicalPath, "/opt/homebrew/Cellar", 0o775, 502, 80),
            ("world writable", canonicalPath, "/opt/homebrew/Cellar", 0o777, 0, 80),
            ("non-Homebrew location", "/private/tmp/opencode", "/private/tmp", 0o775, 0, 80),
            ("prefix lookalike", "/opt/homebrew/Cellarish/opencode", "/opt/homebrew/Cellarish", 0o775, 0, 80),
            ("directory outside Cellar", canonicalPath, "/opt/homebrew/bin", 0o775, 0, 80),
            ("mismatched Homebrew root", canonicalPath, "/usr/local/Cellar", 0o775, 0, 80),
            ("canonical target outside Cellar", "/opt/homebrew/bin/opencode", "/opt/homebrew", 0o775, 0, 80)
        ]

        for testCase in cases {
            XCTAssertFalse(
                ExecutableFileIdentity.permitsHomebrewAdminGroupWritableDirectory(
                    canonicalPath: testCase.canonicalPath,
                    directoryPath: testCase.directoryPath,
                    mode: testCase.mode,
                    ownerUID: testCase.ownerUID,
                    groupGID: testCase.groupGID,
                    effectiveUID: effectiveUID
                ),
                "Expected trust boundary violation to be rejected: \(testCase.name)"
            )
        }
    }

    func testCaptureForTrustedPathLaunchRejectsSymlinkEscapeIntoGroupWritableDirectory() throws {
        let root = try makeTestDirectory(name: "ExecutableFileIdentitySymlinkEscape")
        let trustedDirectory = root.appendingPathComponent("trusted", isDirectory: true)
        let escapedDirectory = root.appendingPathComponent("escaped", isDirectory: true)
        try FileManager.default.createDirectory(at: trustedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: escapedDirectory, withIntermediateDirectories: true)
        let escapedExecutable = escapedDirectory.appendingPathComponent("opencode")
        try "#!/bin/sh\nexit 0\n".write(to: escapedExecutable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: escapedExecutable.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: escapedDirectory.path)
        let canonicalEscapedDirectory = try XCTUnwrap(FileSystemService.realpathString(escapedDirectory.path))

        let alias = trustedDirectory.appendingPathComponent("opencode")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: escapedExecutable)

        XCTAssertThrowsError(try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: alias.path)) { error in
            guard case let ExecutableFileIdentityError.untrustedWritableDirectory(path, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(path, canonicalEscapedDirectory)
        }
    }

    func testDirectoryHasNoExtendedACLAcceptsCleanDirectory() throws {
        let directory = try makeTestDirectory(name: "ExecutableFileIdentityCleanACL")
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: directory.path)

        XCTAssertTrue(ExecutableFileIdentity.directoryHasNoExtendedACL(atPath: directory.path))
        XCTAssertEqual(try posixPermissions(of: directory), 0o775)
    }

    func testDirectoryHasNoExtendedACLRejectsExtendedEntriesWhilePreservingPOSIXMode() throws {
        let entries = [
            "user:nobody allow add_file,delete_child",
            "user:nobody allow read"
        ]

        for entry in entries {
            let directory = try makeTestDirectory(name: "ExecutableFileIdentityExtendedACL")
            try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: directory.path)
            try addExtendedACL(entry, to: directory)

            XCTAssertEqual(try posixPermissions(of: directory), 0o775)
            XCTAssertFalse(
                ExecutableFileIdentity.directoryHasNoExtendedACL(atPath: directory.path),
                "Expected extended ACL to be rejected: \(entry)"
            )
        }
    }

    func testDirectoryHasNoExtendedACLFailsClosedForMissingNonDirectoryAndSymlinkPaths() throws {
        let root = try makeTestDirectory(name: "ExecutableFileIdentityInvalidACLPaths")
        let regularFile = root.appendingPathComponent("regular-file")
        try "not a directory\n".write(to: regularFile, atomically: true, encoding: .utf8)
        let cleanDirectory = root.appendingPathComponent("clean-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: cleanDirectory, withIntermediateDirectories: true)
        let symlink = root.appendingPathComponent("directory-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: cleanDirectory)

        XCTAssertFalse(ExecutableFileIdentity.directoryHasNoExtendedACL(atPath: root.appendingPathComponent("missing").path))
        XCTAssertFalse(ExecutableFileIdentity.directoryHasNoExtendedACL(atPath: regularFile.path))
        XCTAssertFalse(ExecutableFileIdentity.directoryHasNoExtendedACL(atPath: symlink.path))
    }

    private func addExtendedACL(_ entry: String, to directory: URL) throws {
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", entry, directory.path]
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let error = standardError.fileHandleForReading.readDataToEndOfFile()
            throw NSError(
                domain: "ExecutableFileIdentityTests.chmod",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(decoding: error, as: UTF8.self)]
            )
        }
    }

    private func posixPermissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}
