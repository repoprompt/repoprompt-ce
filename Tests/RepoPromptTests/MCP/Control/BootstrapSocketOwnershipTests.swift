import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

final class BootstrapSocketOwnershipTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("rpso-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testExclusiveLockRejectsSecondOwnerAndHasCloseOnExec() throws {
        let socketURL = temporaryDirectory.appendingPathComponent("owner.sock")
        let first = try BootstrapSocketOwnership.acquire(socketURL: socketURL)
        defer { first.release() }

        #if DEBUG
            XCTAssertTrue(first.debugLockHasCloseOnExec())
        #endif
        XCTAssertThrowsError(try BootstrapSocketOwnership.acquire(socketURL: socketURL)) { error in
            guard case BootstrapSocketOwnership.OwnershipError.lockUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testExistingOwnerControlledLockIsSecuredBeforeIdentityCapture() throws {
        let socketURL = temporaryDirectory.appendingPathComponent("permissions.sock")
        let lockURL = socketURL.appendingPathExtension("lock")
        try Data().write(to: lockURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lockURL.path)

        let owner = try BootstrapSocketOwnership.acquire(socketURL: socketURL)
        defer { owner.release() }
        let attributes = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let fd = try bindSocket(at: socketURL, listening: true)
        defer {
            Darwin.close(fd)
            unlink(socketURL.path)
        }
        try owner.captureBoundSocketIdentity()
        XCTAssertEqual(owner.pathStatus(), .owned)
    }

    func testPrepareRemovesConfirmedStaleSocket() throws {
        let socketURL = temporaryDirectory.appendingPathComponent("stale.sock")
        let fd = try bindSocket(at: socketURL, listening: false)
        Darwin.close(fd)
        XCTAssertNotNil(BootstrapSocketOwnership.identity(atPath: socketURL.path))

        let owner = try BootstrapSocketOwnership.acquire(socketURL: socketURL)
        defer { owner.release() }
        try owner.preparePathForBinding()

        XCTAssertNil(BootstrapSocketOwnership.identity(atPath: socketURL.path))
    }

    func testPrepareRefusesLiveSocketAndNonSocketEntry() throws {
        let liveURL = temporaryDirectory.appendingPathComponent("live.sock")
        let liveFD = try bindSocket(at: liveURL, listening: true)
        defer {
            Darwin.close(liveFD)
            unlink(liveURL.path)
        }
        let liveOwner = try BootstrapSocketOwnership.acquire(socketURL: liveURL)
        defer { liveOwner.release() }
        XCTAssertThrowsError(try liveOwner.preparePathForBinding()) { error in
            guard case BootstrapSocketOwnership.OwnershipError.liveOwner = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let fileURL = temporaryDirectory.appendingPathComponent("file.sock")
        try Data("not a socket".utf8).write(to: fileURL)
        let fileOwner = try BootstrapSocketOwnership.acquire(socketURL: fileURL)
        defer { fileOwner.release() }
        XCTAssertThrowsError(try fileOwner.preparePathForBinding()) { error in
            guard case BootstrapSocketOwnership.OwnershipError.unmanagedPath = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testReplacementPathIsNeverRemovedByOldOwner() throws {
        let socketURL = temporaryDirectory.appendingPathComponent("replace.sock")
        let owner = try BootstrapSocketOwnership.acquire(socketURL: socketURL)
        defer { owner.release() }
        try owner.preparePathForBinding()
        let originalFD = try bindSocket(at: socketURL, listening: true)
        defer { Darwin.close(originalFD) }
        try owner.captureBoundSocketIdentity()
        XCTAssertEqual(owner.pathStatus(), .owned)

        XCTAssertEqual(unlink(socketURL.path), 0)
        let replacementFD = try bindSocket(at: socketURL, listening: true)
        defer {
            Darwin.close(replacementFD)
            unlink(socketURL.path)
        }

        guard case .replaced = owner.pathStatus() else {
            return XCTFail("Expected replacement identity")
        }
        XCTAssertFalse(owner.removeOwnedSocketIfCurrent())
        XCTAssertNotNil(BootstrapSocketOwnership.identity(atPath: socketURL.path))
    }

    func testSameFlavorDuplicateServerCannotDeleteFirstListener() async throws {
        let socketURL = temporaryDirectory.appendingPathComponent("server.sock")
        let first = BootstrapSocketServer(socketURL: socketURL)
        try await first.start { _, _, _, _ in .reject() }
        let second = BootstrapSocketServer(socketURL: socketURL)

        do {
            try await second.start { _, _, _, _ in .reject() }
            XCTFail("Expected duplicate ownership failure")
        } catch {
            guard case BootstrapSocketOwnership.OwnershipError.lockUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let firstIsListening = await first.isListening()
        let firstDiagnostics = await first.diagnostics()
        XCTAssertTrue(firstIsListening)
        XCTAssertEqual(firstDiagnostics.socketPathStatus, .owned)
        await second.stop()
        XCTAssertNotNil(BootstrapSocketOwnership.identity(atPath: socketURL.path))
        await first.stop()
        XCTAssertNil(BootstrapSocketOwnership.identity(atPath: socketURL.path))
    }

    func testDifferentFlavorPathsCoexistAndStopInReverseOrder() async throws {
        let debugURL = temporaryDirectory.appendingPathComponent("repoprompt-ce-D-7.sock")
        let releaseURL = temporaryDirectory.appendingPathComponent("repoprompt-ce-7.sock")
        let debugServer = BootstrapSocketServer(socketURL: debugURL)
        let releaseServer = BootstrapSocketServer(socketURL: releaseURL)
        try await debugServer.start { _, _, _, _ in .reject() }
        try await releaseServer.start { _, _, _, _ in .reject() }

        await releaseServer.stop()
        XCTAssertNotNil(BootstrapSocketOwnership.identity(atPath: debugURL.path))
        XCTAssertNil(BootstrapSocketOwnership.identity(atPath: releaseURL.path))
        await debugServer.stop()
        XCTAssertNil(BootstrapSocketOwnership.identity(atPath: debugURL.path))
    }

    private func bindSocket(at url: URL, listening: Bool) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENFILE) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = url.path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { destination in
                for (index, byte) in pathBytes.enumerated() {
                    destination[index] = byte
                }
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        if listening {
            guard Darwin.listen(fd, 8) == 0 else {
                let code = errno
                Darwin.close(fd)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
        }
        return fd
    }
}
