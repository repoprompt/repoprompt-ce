import Darwin
import Foundation
import Logging
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
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

final class UnixSocketMCPTransportCancellationTests: XCTestCase {
    func testPinnedSDKNormalReturnAfterCancellationDoesNotReachWire() async throws {
        try await assertPinnedSDKCancellation(customError: false)
    }

    func testPinnedSDKCustomCancellationErrorDoesNotReachWire() async throws {
        try await assertPinnedSDKCancellation(customError: true)
    }

    private func assertPinnedSDKCancellation(customError: Bool) async throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENFILE)
        }
        let peer = descriptors[1]
        defer { Darwin.close(peer) }
        let transport = try UnixSocketMCPTransport(connectedFD: descriptors[0])
        let entered = expectation(description: "cancelled handler entered")
        let unrelatedEntered = expectation(description: "unrelated string ID remains active")
        let cancelled = expectation(description: "SDK cancelled the numeric ID handler")
        let completedSend = expectation(description: "SDK numeric response delivery attempt completed")
        let unrelatedSend = expectation(description: "unrelated string response delivery completed")
        let held = CancellationSettlementGate()
        let unrelated = CancellationSettlementGate()
        let observed = CancellationObservedTransport(transport: transport, completedSend: completedSend, unrelatedSend: unrelatedSend)
        let server = Server(name: "cancellation-contract", version: "1", capabilities: .init(tools: .init()))
        await server.withMethodHandler(CallTool.self) { params in
            if params.name == "unrelated" {
                unrelatedEntered.fulfill()
                await unrelated.wait()
                return .init(content: [.text("unrelated-result")])
            }
            return try await withTaskCancellationHandler {
                entered.fulfill()
                await held.wait()
                if customError {
                    throw CancelledByClient()
                }
                return .init(content: [.text("late-cancelled-result")])
            } onCancel: {
                cancelled.fulfill()
            }
        }
        try await server.start(transport: observed)
        do {
            let ledger = JSONRPCBridgeLedger()
            _ = try await ledger.beginConnection()
            let numeric = frame(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"held"}}"#)
            let string = frame(#"{"jsonrpc":"2.0","id":"7","method":"tools/call","params":{"name":"unrelated"}}"#)
            let cancellation = frame(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}"#)
            for request in [numeric, string] {
                let prepared = try await ledger.prepare(frame: request, direction: .clientToServer, now: 0)
                try await ledger.commit(prepared, now: 0)
                try write(request, to: peer)
            }
            await fulfillment(of: [entered, unrelatedEntered], timeout: 5)
            let initialDelivery = await transport.responseDeliverySnapshot()
            XCTAssertEqual(initialDelivery.pendingRequestCount, 2)
            let preparedCancel = try await ledger.prepare(frame: cancellation, direction: .clientToServer, now: 1)
            try await ledger.commit(preparedCancel, now: 1)
            try write(cancellation, to: peer)
            await fulfillment(of: [cancelled], timeout: 5)
            let cancellationDelivery = await transport.responseDeliverySnapshot()
            XCTAssertEqual(cancellationDelivery.pendingRequestCount, 1, "Client cancellation retires only numeric7's delivery obligation")
            await held.release()
            await fulfillment(of: [completedSend], timeout: 5)
            let stillActive = await ledger.snapshot(now: 32)
            XCTAssertEqual(stillActive.activeRequestCount, 1)
            XCTAssertNil(stillActive.terminalReason)
            await unrelated.release()
            await fulfillment(of: [unrelatedSend], timeout: 5)
            let sentinel = frame(#"{"jsonrpc":"2.0","id":99,"method":"ping"}"#)
            let preparedSentinel = try await ledger.prepare(frame: sentinel, direction: .clientToServer, now: 32)
            try await ledger.commit(preparedSentinel, now: 32)
            try write(sentinel, to: peer)
            let replies = try await Task.detached { try Self.readThroughSentinel(from: peer) }.value
            XCTAssertFalse(replies.contains { reply in
                JSONRPCBridgeFrameInspector.inspectPermissively(reply, direction: .serverToClient)
                    .contains { $0.id == .number(7) }
            }, "A client-cancelled response must never reach the bridge, even after cleanup returns")
            XCTAssertTrue(replies.contains { reply in
                JSONRPCBridgeFrameInspector.inspectPermissively(reply, direction: .serverToClient)
                    .contains { $0.id == .string("7") }
            })
            for reply in replies {
                let prepared = try await ledger.prepare(frame: reply, direction: .serverToClient, now: 32)
                try await ledger.commit(prepared, now: 32)
            }
            let final = await ledger.snapshot(now: 32)
            XCTAssertNil(final.terminalReason)
            XCTAssertEqual(final.activeRequestCount, 0)
            let delivery = await transport.responseDeliverySnapshot()
            XCTAssertEqual(delivery.pendingRequestCount, 0)
            await server.stop()
        } catch {
            await held.release()
            await unrelated.release()
            await server.stop()
            throw error
        }
    }

    private func frame(_ string: String) -> Data {
        Data((string + "\n").utf8)
    }

    private func write(_ data: Data, to fd: Int32) throws {
        let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard count == data.count else { throw POSIXError(.EIO) }
    }

    private static func readThroughSentinel(from fd: Int32) throws -> [Data] {
        var buffer = Data()
        var frames: [Data] = []
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&event, 1, 5000) > 0 else { throw POSIXError(.ETIMEDOUT) }
            let count = Darwin.read(fd, &bytes, bytes.count)
            guard count > 0 else { throw POSIXError(.EIO) }
            buffer.append(contentsOf: bytes.prefix(count))
            while let newline = buffer.firstIndex(of: 10) {
                let frame = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                frames.append(frame)
                let ids = JSONRPCBridgeFrameInspector.inspectPermissively(frame, direction: .serverToClient).compactMap(\.id)
                if ids.contains(.number(99)) {
                    return frames
                }
            }
        }
    }
}

private struct CancelledByClient: Error {}

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

private actor CancellationObservedTransport: Transport {
    let logger = Logger(label: "cancellation-contract")
    private let transport: UnixSocketMCPTransport
    private let completedSend: XCTestExpectation
    private let unrelatedSend: XCTestExpectation
    private var stream = AsyncThrowingStream<Data, Error> { $0.finish() }
    init(transport: UnixSocketMCPTransport, completedSend: XCTestExpectation, unrelatedSend: XCTestExpectation) {
        self.transport = transport
        self.completedSend = completedSend
        self.unrelatedSend = unrelatedSend
    }

    func connect() async throws {
        try await transport.connect()
        stream = await transport.receive()
    }

    func disconnect() async {
        await transport.disconnect()
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        stream
    }

    func send(_ frame: Data) async throws {
        try await transport.send(frame)
        if JSONRPCBridgeFrameInspector.inspectPermissively(frame, direction: .serverToClient).contains(where: { $0.id == .number(7) }) {
            completedSend.fulfill()
        }
        if JSONRPCBridgeFrameInspector.inspectPermissively(frame, direction: .serverToClient).contains(where: { $0.id == .string("7") }) {
            unrelatedSend.fulfill()
        }
    }
}

final class MCPClientCancellationOwnershipTests: XCTestCase {
    func testMixedBatchPreservesExactStringIDNullErrorAndNotification() throws {
        let ledger = MCPExecutionWatchdogResponseLedger()
        XCTAssertTrue(try ledger.recordAcceptedClientFrame(frame(#"{"id":7,"method":"tools/list"}"#)))
        XCTAssertTrue(try ledger.recordAcceptedClientFrame(frame(#"{"id":"7","method":"tools/list"}"#)))
        XCTAssertTrue(try ledger.recordAcceptedClientFrame(frame(#"{"method":"notifications/cancelled","params":{"requestId":7}}"#)))
        let batch = frame(#"[{"id":7,"result":{}},{"id":"7","result":{}},{"id":null,"error":{"code":-32600,"message":"Invalid Request"}},{"method":"notifications/progress","params":{"progress":1}}]"#)
        guard case let .frame(prepared) = ledger.prepareServerFrameForDelivery(batch) else {
            return XCTFail("Only the cancelled numeric response may be removed")
        }
        let metadata = JSONRPCBridgeFrameInspector.inspectPermissively(prepared.data, direction: .serverToClient)
        XCTAssertEqual(metadata.filter { $0.kind == .response }.compactMap(\.id), [.string("7"), .null])
        XCTAssertEqual(metadata.filter { $0.kind == .notification }.map(\.method), ["notifications/progress"])
        XCTAssertTrue(try ledger.recordAcceptedClientFrame(frame(#"{"method":"notifications/cancelled","params":{"requestId":99}}"#)))
        guard case .frame = ledger.prepareServerFrameForDelivery(frame(#"{"id":99,"result":{}}"#)) else {
            return XCTFail("Unknown cancellation cannot authorize blanket response suppression")
        }
    }

    func testRetentionCapacityFailsClosedWithoutEviction() throws {
        let ledger = MCPExecutionWatchdogResponseLedger(maximumCancelledRequestIDs: 1)
        for id in [7, 8] {
            XCTAssertTrue(try ledger.recordAcceptedClientFrame(frame("{\"id\":\(id),\"method\":\"tools/list\"}")))
        }
        XCTAssertTrue(try ledger.recordAcceptedClientFrame(frame(#"{"method":"notifications/cancelled","params":{"requestId":7}}"#)))
        XCTAssertThrowsError(try ledger.recordAcceptedClientFrame(frame(#"{"method":"notifications/cancelled","params":{"requestId":8}}"#))) {
            XCTAssertEqual($0 as? MCPClientCancellationOwnershipError, .retentionCapacityExceeded(1))
        }
        XCTAssertThrowsError(try ledger.recordAcceptedClientFrame(frame(#"{"id":9,"method":"tools/list"}"#))) {
            XCTAssertEqual($0 as? MCPClientCancellationOwnershipError, .retentionCapacityExceeded(1))
        }
        guard case let .suppressed(phase, _) = ledger.prepareServerFrameForDelivery(frame(#"{"id":7,"result":{}}"#)) else {
            return XCTFail("Capacity failure cannot let a previous cancelled response escape")
        }
        XCTAssertEqual(phase, "client_cancellation_ownership_failure")
    }

    func testSameGenerationReuseIsRefusedButResetFencesOldIngress() throws {
        let ledger = MCPExecutionWatchdogResponseLedger(maximumCancelledRequestIDs: 1)
        let oldGeneration = ledger.currentGeneration
        let request = frame(#"{"id":7,"method":"tools/list"}"#)
        let cancellation = frame(#"{"method":"notifications/cancelled","params":{"requestId":7}}"#)
        XCTAssertTrue(try ledger.recordAcceptedClientFrame(request, expectedGeneration: oldGeneration))
        XCTAssertTrue(try ledger.recordAcceptedClientFrame(cancellation, expectedGeneration: oldGeneration))
        XCTAssertThrowsError(try ledger.recordAcceptedClientFrame(request, expectedGeneration: oldGeneration)) {
            XCTAssertEqual($0 as? MCPClientCancellationOwnershipError, .cancelledIDReuse(.number(7)))
        }
        ledger.reset()
        let generation = ledger.currentGeneration
        XCTAssertNotEqual(generation, oldGeneration)
        XCTAssertTrue(try ledger.recordAcceptedClientFrame(request, expectedGeneration: generation))
        XCTAssertFalse(try ledger.recordAcceptedClientFrame(cancellation, expectedGeneration: oldGeneration))
        guard case .frame = ledger.prepareServerFrameForDelivery(frame(#"{"id":7,"result":{}}"#)) else {
            return XCTFail("Old ingress cannot cancel the fresh generation's reused ID")
        }
        XCTAssertTrue(try ledger.recordAcceptedClientFrame(cancellation, expectedGeneration: generation))
        guard case .suppressed = ledger.prepareServerFrameForDelivery(frame(#"{"id":7,"result":{}}"#)) else {
            return XCTFail("Reset must restore bounded capacity, not disable cancellation ownership")
        }
    }

    func testCancellationBeforeWatchdogSealRetiresOnlyItsExactID() throws {
        let ledger = MCPExecutionWatchdogResponseLedger()
        XCTAssertTrue(try ledger.recordAcceptedClientFrame(frame(#"[{"id":7,"method":"tools/list"},{"id":"7","method":"tools/list"}]"#)))
        XCTAssertTrue(try ledger.recordAcceptedClientFrame(frame(#"{"method":"notifications/cancelled","params":{"requestId":7}}"#)))
        ledger.seal()
        XCTAssertEqual(ledger.takeOutstandingRequestIDsAfterSeal(), [.string("7")])
        guard case let .suppressed(phase, _) = ledger.prepareServerFrameForDelivery(frame(#"{"id":7,"result":{}}"#)) else {
            return XCTFail("A cancelled response remains suppressed after terminal sealing")
        }
        XCTAssertEqual(phase, "watchdog_late_response_suppressed")
    }

    func testDeliveryTrackerCancellationPreservesStringIDAndRejectsStaleIngress() async {
        let tracker = MCPDomainResponseDeliveryTracker()
        let oldGeneration = tracker.currentGeneration
        let request = frame(#"{"id":7,"method":"tools/list"}"#)
        let cancellation = frame(#"{"method":"notifications/cancelled","params":{"requestId":7}}"#)
        tracker.recordAcceptedClientFrame(request)
        tracker.recordAcceptedClientFrame(frame(#"{"id":"7","method":"tools/list"}"#))
        XCTAssertEqual(tracker.snapshot().pendingRequestCount, 2)
        tracker.recordAcceptedClientFrame(cancellation)
        XCTAssertEqual(tracker.snapshot().pendingRequestCount, 1)
        tracker.recordAcceptedClientFrame(frame(#"{"method":"notifications/cancelled","params":{"requestId":99}}"#))
        XCTAssertEqual(tracker.snapshot().pendingRequestCount, 1)
        tracker.recordDeliveredServerFrame(frame(#"{"id":"7","result":{}}"#))
        let drained = await tracker.waitUntilDrained()
        XCTAssertTrue(drained)
        tracker.reset()
        tracker.recordAcceptedClientFrame(request, expectedGeneration: tracker.currentGeneration)
        tracker.recordAcceptedClientFrame(cancellation, expectedGeneration: oldGeneration)
        XCTAssertEqual(tracker.snapshot().pendingRequestCount, 1)
        tracker.recordAcceptedClientFrame(cancellation, expectedGeneration: tracker.currentGeneration)
        let cancelledDrain = await tracker.waitUntilDrained()
        XCTAssertTrue(cancelledDrain)
    }

    private func frame(_ json: String) -> Data {
        Data((json + "\n").utf8)
    }
}
