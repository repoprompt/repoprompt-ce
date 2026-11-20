import Darwin
import Foundation
import Logging
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
@testable import RepoPromptMCPServer
import RepoPromptShared
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

    func testUnsafeParentEntriesAreRejectedBeforeCreatingLock() throws {
        for kind in ["file", "symlink", "permissive"] {
            let directory = temporaryDirectory.appendingPathComponent(kind, isDirectory: true)
            switch kind {
            case "file":
                try Data("sentinel".utf8).write(to: directory)
            case "symlink":
                try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: temporaryDirectory)
            default:
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                XCTAssertEqual(chmod(directory.path, 0o777), 0)
            }
            let socket = directory.appendingPathComponent("rejected.sock")
            XCTAssertThrowsError(try BootstrapSocketOwnership.acquire(socketURL: socket))
            XCTAssertFalse(FileManager.default.fileExists(atPath: socket.appendingPathExtension("lock").path))
        }
        XCTAssertEqual(try Data(contentsOf: temporaryDirectory.appendingPathComponent("file")), Data("sentinel".utf8))
        var info = stat()
        XCTAssertEqual(lstat(temporaryDirectory.appendingPathComponent("permissive").path, &info), 0)
        XCTAssertEqual(info.st_mode & mode_t(0o777), mode_t(0o777))
    }

    func testDirectoryPolicyRejectsForeignOwnerAndSpecialBits() {
        var info = stat()
        info.st_mode = mode_t(S_IFDIR) | mode_t(0o700)
        info.st_uid = getuid()
        XCTAssertTrue(MCPBootstrapDirectory.isPrivateDirectory(info))
        info.st_uid = getuid() == 0 ? 1 : 0
        XCTAssertFalse(MCPBootstrapDirectory.isPrivateDirectory(info))
        info.st_uid = getuid()
        for permissions in [0o2700, 0o1700, 0o720, 0o707] {
            info.st_mode = mode_t(S_IFDIR) | mode_t(permissions)
            XCTAssertFalse(MCPBootstrapDirectory.isPrivateDirectory(info))
        }
    }

    func testRetainedDirectoryRejectsReplacementAndDoesNotUnlinkReplacementSocket() throws {
        let parent = temporaryDirectory.appendingPathComponent("parent", isDirectory: true)
        let socket = parent.appendingPathComponent("identity.sock")
        let owner = try BootstrapSocketOwnership.acquire(socketURL: socket)
        defer { owner.release() }
        let fd = try bindSocket(at: socket, listening: true)
        defer { Darwin.close(fd) }
        try owner.captureBoundSocketIdentity()
        let moved = temporaryDirectory.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.moveItem(at: parent, to: moved)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let replacementFD = try bindSocket(at: socket, listening: true)
        defer { Darwin.close(replacementFD) }
        XCTAssertEqual(owner.pathStatus(), .lockLost)
        XCTAssertThrowsError(try owner.validateDirectoryForBinding())
        XCTAssertFalse(owner.removeOwnedSocketIfCurrent())
        XCTAssertNotNil(BootstrapSocketOwnership.identity(atPath: socket.path))
    }

    func testDirectoryCreationAndClientValidationRequirePrivateSocket() throws {
        let parent = temporaryDirectory.appendingPathComponent("created", isDirectory: true)
        let directory = try MCPBootstrapDirectory.open(at: parent, createIfMissing: true)
        try directory.validateCurrentPath()
        XCTAssertNotEqual(fcntl(directory.descriptor, F_GETFD) & FD_CLOEXEC, 0)
        let socket = parent.appendingPathComponent("client.sock")
        let fd = try bindSocket(at: socket, listening: true)
        defer { Darwin.close(fd) }
        XCTAssertEqual(chmod(socket.path, 0o666), 0)
        XCTAssertThrowsError(try directory.validateSocket(at: socket))
        XCTAssertEqual(chmod(socket.path, 0o600), 0)
        try directory.validateSocket(at: socket)
        XCTAssertEqual(chmod(parent.path, 0o755), 0)
        XCTAssertThrowsError(try directory.validateSocket(at: socket))
    }

    func testUntrustedAliasAncestorIsNotMadeTrustedByCanonicalization() throws {
        let target = temporaryDirectory.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let directory = try MCPBootstrapDirectory.open(at: target.appendingPathComponent("sockets"), createIfMissing: true)
        try directory.validateCurrentPath()
        let unsafe = temporaryDirectory.appendingPathComponent("unsafe-alias", isDirectory: true)
        try FileManager.default.createDirectory(at: unsafe, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(unsafe.path, 0o777), 0)
        let alias = unsafe.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        XCTAssertThrowsError(try MCPBootstrapDirectory.open(at: alias.appendingPathComponent("sockets")))
    }

    func testMissingDirectoryAndSocketRemainDistinguishableFromUntrustedEntries() throws {
        let parent = temporaryDirectory.appendingPathComponent("missing", isDirectory: true)
        XCTAssertThrowsError(try MCPBootstrapDirectory.open(at: parent)) { error in
            XCTAssertTrue((error as? MCPBootstrapDirectory.DirectoryError)?.isMissing == true)
        }
        let directory = try MCPBootstrapDirectory.open(at: parent, createIfMissing: true)
        XCTAssertThrowsError(try directory.validateSocket(at: parent.appendingPathComponent("missing.sock"))) { error in
            XCTAssertTrue((error as? MCPBootstrapDirectory.DirectoryError)?.isMissing == true)
        }
        XCTAssertEqual(chmod(parent.path, 0o755), 0)
        XCTAssertThrowsError(try MCPBootstrapDirectory.open(at: parent)) { error in
            XCTAssertFalse((error as? MCPBootstrapDirectory.DirectoryError)?.isMissing == true)
        }
    }

    func testServerRejectsUnsafeFixtureParentWithoutCreatingSocketOrLock() async throws {
        let parent = temporaryDirectory.appendingPathComponent("unsafe", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(parent.path, 0o777), 0)
        let socketURL = parent.appendingPathComponent("server.sock")
        let server = BootstrapSocketServer(socketURL: socketURL, logger: Logger(label: "directory-test"))
        do {
            try await server.start { _, _, _, _ in .reject(.rejected(reason: "fixture", errorCode: "fixture")) }
            XCTFail("Unsafe parent must not start")
        } catch {
            XCTAssertTrue(error is MCPBootstrapDirectory.DirectoryError)
        }
        await server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.appendingPathExtension("lock").path))
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
        let originalIdentity = try XCTUnwrap(BootstrapSocketOwnership.identity(atPath: socketURL.path))
        let identityRecord = try String(contentsOf: owner.lockURL, encoding: .utf8)
        XCTAssertEqual(
            identityRecord,
            "\(BootstrapSocketOwnership.boundIdentityRecordPrefix) \(originalIdentity.device) \(originalIdentity.inode)\n"
        )

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

    #if DEBUG
        func testReadyHandshakeSettlesWhileEarlierPeerIsHeldInPhysicalRead() async throws {
            let socketURL = temporaryDirectory.appendingPathComponent("isolated.sock")
            let server = BootstrapSocketServer(socketURL: socketURL)
            let fixture = BootstrapHandshakeIsolationFixture()
            await server.debugSetHandshakeReadHooks(
                observer: { fixture.observe($0, phase: $1) },
                beforePoll: { fixture.holdFirstPoll($0) }
            )
            try await server.start { _, _, identity, clientName in
                XCTAssertEqual(identity.claimedPID, Int(getpid()))
                XCTAssertEqual(clientName, "RepoPrompt CLI (Interactive)")
                return .accept(
                    publishTransferredFD: { fixture.publish($0) },
                    postAccept: { fixture.postAccepted.fulfill() }
                )
            }

            var firstPeer: Int32 = -1
            var secondPeer: Int32 = -1
            do {
                firstPeer = try Self.connectBootstrapPeer(to: socketURL)
                await fulfillment(of: [fixture.firstPollEntered], timeout: 10)
                secondPeer = try Self.connectBootstrapPeer(to: socketURL)
                try Self.sendInteractiveBootstrapRequest(to: secondPeer)
                await fulfillment(of: [fixture.secondReadQueued], timeout: 10)

                // The first peer cannot progress until cleanup explicitly opens its gate.
                // This is a dependency oracle, not a wall-clock latency requirement.
                await fulfillment(of: [fixture.postAccepted], timeout: 10)
                XCTAssertTrue(fixture.isFirstPollHeld)
                XCTAssertEqual(fixture.transferredCount, 1)
                if fixture.transferredCount == 1 {
                    let frame = try Self.readBootstrapResponseFrame(from: secondPeer)
                    let response = try JSONDecoder().decode(MCPBootstrapResponse.self, from: frame)
                    XCTAssertEqual(response.type, "accepted")
                }
            } catch {
                await Self.cleanUpBootstrapIsolation(server: server, fixture: fixture, peers: [firstPeer, secondPeer])
                throw error
            }
            await Self.cleanUpBootstrapIsolation(server: server, fixture: fixture, peers: [firstPeer, secondPeer])
            let diagnostics = await server.diagnostics()
            XCTAssertEqual(diagnostics.inFlightHandshakes, 0)
            XCTAssertFalse(diagnostics.isRunning)
        }

        func testStopAbortsHeldAdmissionWithoutTransferringOrStartingMCP() async throws {
            let socketURL = temporaryDirectory.appendingPathComponent("stop-admission.sock")
            let server = BootstrapSocketServer(socketURL: socketURL)
            let admissionGate = CancellationSettlementGate()
            let admissionEntered = XCTestExpectation(description: "physical peer completed read and entered admission")
            let aborted = XCTestExpectation(description: "retired listener aborts reserved acceptance")
            let settled = XCTestExpectation(description: "retired handshake returns after abort")
            let receipt = BootstrapAdmissionStopReceipt()
            await server.debugSetHandshakeReadHooks(observer: { _, phase in
                if phase == .settled {
                    settled.fulfill()
                }
            })
            try await server.start { _, _, _, _ in
                admissionEntered.fulfill()
                await admissionGate.wait()
                return .accept(
                    publishTransferredFD: { _ in receipt.recordTransfer() },
                    postAccept: { receipt.recordPostAccept() },
                    onAcceptAborted: {
                        receipt.recordAbort()
                        aborted.fulfill()
                    }
                )
            }
            var peer: Int32 = -1
            do {
                peer = try Self.connectBootstrapPeer(to: socketURL)
                try Self.sendInteractiveBootstrapRequest(to: peer)
                await fulfillment(of: [admissionEntered], timeout: 10)
                await server.stop()
                var byte: UInt8 = 0
                XCTAssertEqual(Darwin.recv(peer, &byte, 1, Int32(MSG_DONTWAIT)), 0)
                await admissionGate.release()
                await fulfillment(of: [aborted, settled], timeout: 10)
                let snapshot = receipt.snapshot()
                XCTAssertEqual(snapshot.transfers, 0)
                XCTAssertEqual(snapshot.postAccepts, 0)
                XCTAssertEqual(snapshot.aborts, 1)
                let diagnostics = await server.diagnostics()
                XCTAssertEqual(diagnostics.inFlightHandshakes, 0)
                XCTAssertFalse(diagnostics.isRunning)
            } catch {
                await admissionGate.release()
                await server.stop()
                if peer >= 0 {
                    Darwin.close(peer)
                }
                throw error
            }
            Darwin.close(peer)
        }

        func testHandshakeLeaseCannotRecycleDescriptorBeforeInitiatingShutdown() throws {
            let result = try BootstrapSocketServer.debugExerciseHandshakeIOLeaseReleaseRacingShutdown()
            XCTAssertTrue(result.remainedOpenUntilInitiatingShutdown)
            XCTAssertTrue(result.closedAfterShutdownFinished)
            XCTAssertTrue(result.peerObservedEOF)
        }

        private static func sendInteractiveBootstrapRequest(to fd: Int32) throws {
            let request = MCPBootstrapRequest(
                sessionToken: UUID().uuidString,
                clientPid: Int(getpid()),
                clientName: "RepoPrompt CLI (Interactive)",
                protocolVersion: MCPBootstrapProtocol.currentVersion
            )
            var payload = try JSONEncoder().encode(request)
            payload.append(UInt8(ascii: "\n"))
            let sent = payload.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            XCTAssertEqual(sent, payload.count)
        }

        /// Same poll/read/newline accumulation as the owning file's sentinel reader,
        /// bounded by one existing bootstrap budget rather than one budget per read.
        private static func readBootstrapResponseFrame(from fd: Int32) throws -> Data {
            let deadline = Date().addingTimeInterval(MCPBootstrapTiming.initialResponseTimeout)
            var buffer = Data()
            var bytes = [UInt8](repeating: 0, count: 1024)
            while true {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw POSIXError(.ETIMEDOUT) }
                var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&event, 1, Int32((remaining * 1000).rounded(.up))) > 0 else {
                    throw POSIXError(.ETIMEDOUT)
                }
                let count = Darwin.read(fd, &bytes, bytes.count)
                guard count > 0 else { throw POSIXError(.EIO) }
                buffer.append(contentsOf: bytes.prefix(count))
                guard buffer.count <= 8192 else { throw POSIXError(.EOVERFLOW) }
                if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    return Data(buffer[..<newline])
                }
            }
        }

        private static func cleanUpBootstrapIsolation(
            server: BootstrapSocketServer,
            fixture: BootstrapHandshakeIsolationFixture,
            peers: [Int32]
        ) async {
            for fd in peers where fd >= 0 {
                _ = Darwin.shutdown(fd, SHUT_RDWR)
            }
            // Release the test hook BEFORE stop: the physical FD lease must be able to exit.
            fixture.releaseFirstPoll()
            await server.stop()
            fixture.closeTransferredDescriptors()
            for fd in peers where fd >= 0 {
                Darwin.close(fd)
            }
        }

        private static func connectBootstrapPeer(to url: URL) throws -> Int32 {
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
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
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else {
                let code = errno
                Darwin.close(fd)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            return fd
        }
    #endif

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

#if DEBUG
    private final class BootstrapAdmissionStopReceipt: @unchecked Sendable {
        private let lock = NSLock()
        private var transfers = 0
        private var postAccepts = 0
        private var aborts = 0

        func recordTransfer() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            transfers += 1
            return false
        }

        func recordPostAccept() {
            lock.lock()
            defer { lock.unlock() }
            postAccepts += 1
        }

        func recordAbort() {
            lock.lock()
            defer { lock.unlock() }
            aborts += 1
        }

        func snapshot() -> (transfers: Int, postAccepts: Int, aborts: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (transfers, postAccepts, aborts)
        }
    }

    private final class BootstrapHandshakeIsolationFixture: @unchecked Sendable {
        let firstPollEntered = XCTestExpectation(description: "first physical peer holds a poll lease")
        let secondReadQueued = XCTestExpectation(description: "second physical peer read is queued")
        let postAccepted = XCTestExpectation(description: "ready second peer receives acceptance and transfers")
        private let lock = NSLock()
        private let firstPollRelease = DispatchSemaphore(value: 0)
        private var acceptedIDs: [UUID] = []
        private var firstPollHeld = false
        private var transferredDescriptors: [Int32] = []

        var isFirstPollHeld: Bool {
            lock.lock()
            defer { lock.unlock() }
            return firstPollHeld
        }

        var transferredCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return transferredDescriptors.count
        }

        func observe(_ id: UUID, phase: BootstrapSocketServer.DebugHandshakeReadPhase) {
            lock.lock()
            if case .accepted = phase {
                acceptedIDs.append(id)
            }
            let isSecondQueued = phase == .queued && acceptedIDs.count == 2 && acceptedIDs[1] == id
            lock.unlock()
            if isSecondQueued {
                secondReadQueued.fulfill()
            }
        }

        func holdFirstPoll(_ id: UUID) {
            lock.lock()
            let isFirst = acceptedIDs.first == id
            if isFirst {
                firstPollHeld = true
            }
            lock.unlock()
            guard isFirst else { return }
            firstPollEntered.fulfill()
            firstPollRelease.wait()
            lock.lock()
            firstPollHeld = false
            lock.unlock()
        }

        func releaseFirstPoll() {
            firstPollRelease.signal()
        }

        func publish(_ fd: Int32) -> Bool {
            lock.lock()
            transferredDescriptors.append(fd)
            lock.unlock()
            return true
        }

        func closeTransferredDescriptors() {
            lock.lock()
            let descriptors = transferredDescriptors
            transferredDescriptors.removeAll()
            lock.unlock()
            for fd in descriptors {
                _ = Darwin.shutdown(fd, SHUT_RDWR)
                Darwin.close(fd)
            }
        }
    }
#endif

private actor CancellationSettlementGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if released {
            return
        }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}
