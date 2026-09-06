import Darwin
@testable import RepoPromptApp
import XCTest

final class SwitchboardBridgeTransportTests: XCTestCase {
    func testProductionClientRegistersThroughAuthenticatedSocket() async throws {
        let server = try SocketFixture()
        defer { server.finish() }
        let scope = SwitchboardBridgeTestData.scope()
        server.start { socket, bytes in
            do {
                let request = try SwitchboardBridgeWire.decodeFrame(bytes)
                XCTAssertEqual(request["capability"], .string(SwitchboardBridgeTestData.capability))
                XCTAssertEqual(try request.uuid("consent_id"), scope.consentID)
                XCTAssertEqual(try request.uuid("session_id"), scope.sessionID)
                XCTAssertEqual(try request.uuid("controller_generation"), scope.controllerGeneration)
                XCTAssertEqual(request["thread_id"], .string("original-thread"))
                let response = try SwitchboardBridgeWire.encodeFrame([
                    "v": 1, "id": request.text("id"), "result": ["registered": true]
                ])
                SocketFixture.send(response, socket: socket)
            } catch {
                XCTFail("Synthetic registration was malformed")
            }
        }
        let client = try SwitchboardBridgeClient(
            pairing: server.pairing(), scope: scope, now: { SwitchboardBridgeTestData.now }
        )
        try await client.register(threadID: "original-thread")
        server.wait()
        XCTAssertGreaterThan(server.receivedBytes, 0)
    }

    func testAuthenticatedSocketRoundTripRequiresRequestEOF() throws {
        let server = try SocketFixture()
        defer { server.finish() }
        let pairing = try server.pairing()
        server.start { socket, request in
            XCTAssertEqual(request, Data("{}\n".utf8))
            SocketFixture.send(Data("{\"ok\":true}\n".utf8), socket: socket)
        }
        let response = try SwitchboardBridgeTransport.exchange(pairing: pairing, request: Data("{}\n".utf8))
        XCTAssertEqual(try SwitchboardBridgeWire.decodeFrame(response)["ok"], .bool(true))
        server.wait()
        XCTAssertEqual(server.receivedBytes, 3)
    }

    func testWrongPIDOrBirthStampReceivesNoCapabilityBytes() throws {
        for wrongPID in [true, false] {
            let server = try SocketFixture()
            defer { server.finish() }
            var overrides: [String: Any] = [:]
            if wrongPID {
                overrides["peer_pid"] = getpid() + 1
            } else {
                let start = try SwitchboardBridgeTransport.processStart(pid: getpid())
                overrides["peer_start"] = ["seconds": start.seconds - 1, "microseconds": start.microseconds]
            }
            let pairing = try server.pairing(overrides: overrides)
            server.start { _, _ in }
            XCTAssertThrowsError(try SwitchboardBridgeTransport.exchange(pairing: pairing, request: Data("{\"secret\":\"synthetic\"}\n".utf8))) {
                XCTAssertEqual($0 as? SwitchboardBridgeError, .unauthorized)
            }
            server.wait()
            XCTAssertEqual(server.receivedBytes, 0)
        }
    }

    func testRejectsPublicParentSocketAndEverySymlinkComponent() throws {
        let server = try SocketFixture()
        defer { server.finish() }
        XCTAssertNoThrow(try SwitchboardBridgeTransport.validatePath(server.path))
        XCTAssertEqual(chmod(server.directory.path, 0o755), 0)
        XCTAssertThrowsError(try SwitchboardBridgeTransport.validatePath(server.path))
        XCTAssertEqual(chmod(server.directory.path, 0o700), 0)
        XCTAssertEqual(chmod(server.path, 0o666), 0)
        XCTAssertThrowsError(try SwitchboardBridgeTransport.validatePath(server.path))
        XCTAssertEqual(chmod(server.path, 0o600), 0)
        let link = server.directory.appendingPathComponent("alias.sock").path
        XCTAssertEqual(symlink(server.path, link), 0)
        XCTAssertThrowsError(try SwitchboardBridgeTransport.validatePath(link))
        let parentLink = server.directory.appendingPathComponent("alias-parent").path
        XCTAssertEqual(symlink(server.directory.path, parentLink), 0)
        XCTAssertThrowsError(try SwitchboardBridgeTransport.validatePath(parentLink + "/session.sock"))
        // /tmp itself is a symlink on macOS, even though the final parent is private.
        XCTAssertThrowsError(try SwitchboardBridgeTransport.validatePath(server.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/")))
    }

    func testRejectsDelayedTrailingBytesAndOversizedResponse() throws {
        for oversized in [false, true] {
            let server = try SocketFixture()
            defer { server.finish() }
            server.start { socket, _ in
                if oversized {
                    SocketFixture.send(Data(repeating: 0x20, count: 65537), socket: socket)
                } else {
                    SocketFixture.send(Data("{}\n".utf8), socket: socket)
                    Thread.sleep(forTimeInterval: 0.03)
                    SocketFixture.send(Data(" ".utf8), socket: socket)
                }
            }
            XCTAssertThrowsError(try SwitchboardBridgeTransport.exchange(pairing: server.pairing(), request: Data("{}\n".utf8))) {
                XCTAssertEqual($0 as? SwitchboardBridgeError, .invalidRequest)
            }
        }
    }

    func testWholeExchangeDeadlineIncludesWaitingForResponseEOF() throws {
        let server = try SocketFixture()
        defer { server.finish() }
        server.start { socket, _ in
            SocketFixture.send(Data("{}\n".utf8), socket: socket)
            Thread.sleep(forTimeInterval: 3.3)
        }
        let start = DispatchTime.now().uptimeNanoseconds
        XCTAssertThrowsError(try SwitchboardBridgeTransport.exchange(pairing: server.pairing(), request: Data("{}\n".utf8))) {
            XCTAssertEqual($0 as? SwitchboardBridgeError, .unavailable)
        }
        let duration = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        XCTAssertGreaterThanOrEqual(duration, 2.8)
        XCTAssertLessThan(duration, 3.25)
    }

    private final class SocketFixture: @unchecked Sendable {
        let directory: URL
        let path: String
        private let listener: Int32
        private let completed = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var started = false
        private var waited = false
        private var received = 0

        var receivedBytes: Int {
            lock.withLock { received }
        }

        init() throws {
            directory = URL(fileURLWithPath: "/private/tmp/sb-wire-" + UUID().uuidString.prefix(12))
            path = directory.appendingPathComponent("session.sock").path
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard listener >= 0 else { throw SwitchboardBridgeError.unavailable }
            var address = try SwitchboardBridgeTransport.address(path: path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0, chmod(path, 0o600) == 0, Darwin.listen(listener, 2) == 0 else {
                Darwin.close(listener)
                throw SwitchboardBridgeError.unavailable
            }
        }

        func pairing(overrides: [String: Any] = [:]) throws -> SwitchboardPairingEnvelope {
            try SwitchboardBridgeTestData.envelope(overrides: ["socket_path": path].merging(overrides) { _, value in value })
        }

        func start(response: @escaping @Sendable (Int32, Data) -> Void) {
            started = true
            DispatchQueue(label: "switchboard.synthetic.socket").async { [self] in
                defer { completed.signal() }
                var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard Darwin.poll(&descriptor, 1, 4000) > 0 else { return }
                let socket = Darwin.accept(listener, nil, nil)
                guard socket >= 0 else { return }
                defer { Darwin.close(socket) }
                var noSignal: Int32 = 1
                _ = setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 4, tv_usec: 0)
                _ = setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var request = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while request.count <= 65536 {
                    let count = Darwin.recv(socket, &buffer, buffer.count, 0)
                    if count <= 0 { break }
                    request.append(contentsOf: buffer.prefix(count))
                }
                lock.withLock { received = request.count }
                response(socket, request)
            }
        }

        static func send(_ data: Data, socket: Int32) {
            data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var written = 0
                while written < bytes.count {
                    let count = Darwin.send(socket, base.advanced(by: written), bytes.count - written, 0)
                    guard count > 0 else { return }
                    written += count
                }
            }
        }

        func wait() {
            guard started, !waited else { return }
            XCTAssertEqual(completed.wait(timeout: .now() + 6), .success)
            waited = true
        }

        func finish() {
            wait()
            Darwin.close(listener)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
