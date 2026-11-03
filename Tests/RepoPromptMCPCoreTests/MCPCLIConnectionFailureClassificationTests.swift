import Darwin
import Foundation
@testable import RepoPromptMCPCore
import RepoPromptShared
import XCTest

/// Issue #294: launch/reconnect failures must be classified instead of collapsing into one
/// generic connection failure, and unsupported stdio framing must fail fast and clearly.
final class MCPCLIConnectionFailureClassificationTests: XCTestCase {
    // MARK: - Raw stdio framing (#294 item 3)

    func testContentLengthFramedClientFramesAreRejectedWithExplicitDetail() throws {
        for header in [
            "Content-Length: 123\r",
            "content-length: 7",
            "  CONTENT-LENGTH:42",
            "\rContent-Length: 1"
        ] {
            let detail = try XCTUnwrap(
                MCPStdioClientFraming.unsupportedFramingDetail(for: Data(header.utf8)),
                "'\(header)' must be classified as unsupported framing"
            )
            XCTAssertTrue(detail.contains("Content-Length"), detail)
            XCTAssertTrue(detail.contains("newline-delimited JSON-RPC"), detail)
        }
    }

    func testNewlineDelimitedFramesAndBlankLinesAreNotRejected() {
        for frame in [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
            "",
            "\r",
            "   ",
            #"{"content-length": 3}"#,
            "Content-Type: application/json"
        ] {
            XCTAssertNil(MCPStdioClientFraming.unsupportedFramingDetail(for: Data(frame.utf8)), frame)
        }
    }

    func testUnsupportedClientFramingIsAPermanentNonRetryableProxyFailure() throws {
        let error = CLIRuntimeError.connectionFailed(
            underlying: SocketProxyError.unsupportedClientFraming(
                detail: MCPStdioClientFraming.unsupportedContentLengthDetail
            )
        )
        XCTAssertFalse(CLIProxyRuntimePolicy.shouldRetry(after: error))
        XCTAssertEqual(CLIProxyRuntimePolicy.failureReason(for: error), "unsupported_stdio_framing")
        let description = try XCTUnwrap(
            SocketProxyError.unsupportedClientFraming(detail: "x").errorDescription
        )
        XCTAssertTrue(description.hasPrefix("Unsupported stdio framing"), description)
        XCTAssertFalse(description.contains("unknown JSON-RPC response id"), description)
    }

    // MARK: - Transient reconnect window versus app not running (#294 item 2)

    func testBootstrapSocketUnavailableIsRetryableAndDistinctFromAppNotRunning() {
        XCTAssertFalse(InteractiveSessionError.appNotRunning.isRetryableConnectionFailure)
        XCTAssertFalse(InteractiveSessionError.approvalDenied.isRetryableConnectionFailure)
        XCTAssertTrue(InteractiveSessionError.bootstrapSocketUnavailable(errno: ECONNREFUSED).isRetryableConnectionFailure)
        XCTAssertTrue(InteractiveSessionError.bootstrapSocketUnavailable(errno: ENOENT).isRetryableConnectionFailure)
        XCTAssertTrue(InteractiveSessionError.bootstrapResponseTimeout.isRetryableConnectionFailure)

        let refused = InteractiveSessionError.bootstrapSocketUnavailable(errno: ECONNREFUSED).description
        XCTAssertTrue(refused.contains("refused the connection"), refused)
        XCTAssertTrue(refused.contains("retryable"), refused)
        XCTAssertTrue(refused.contains("--connect-wait"), refused)
        XCTAssertFalse(refused.contains("not running"), refused)

        let missing = InteractiveSessionError.bootstrapSocketUnavailable(errno: ENOENT).description
        XCTAssertTrue(missing.contains("socket is missing"), missing)

        let notRunning = InteractiveSessionError.appNotRunning.description
        XCTAssertTrue(notRunning.contains("not running or MCP is disabled"), notRunning)
        XCTAssertFalse(notRunning.contains("retryable"), notRunning)
    }

    // MARK: - Bootstrap handshake classification (follow-up to #1598)

    func testHandshakeWithoutBootstrapDirectoryIsAppNotRunning() async {
        let directory = Self.scratchDirectoryURL()
        let error = await Self.handshakeError(socketURL: directory.appendingPathComponent("s.sock"))
        guard case .appNotRunning = error else {
            return XCTFail("missing bootstrap directory must stay permanent, got \(String(describing: error))")
        }
    }

    func testHandshakeWithDirectoryButMissingSocketIsRetryableSocketUnavailable() async throws {
        let directory = try makePrivateDirectory()
        let error = await Self.handshakeError(socketURL: directory.appendingPathComponent("s.sock"))
        guard case let .bootstrapSocketUnavailable(code) = error else {
            return XCTFail("missing socket under a present directory must be retryable, got \(String(describing: error))")
        }
        XCTAssertEqual(code, ENOENT)
    }

    func testHandshakeWithStaleSocketIsRetryableConnectionRefused() async throws {
        let directory = try makePrivateDirectory()
        let socketURL = directory.appendingPathComponent("s.sock")
        let listener = try Self.bindSocket(at: socketURL, listen: false)
        Darwin.close(listener)
        let error = await Self.handshakeError(socketURL: socketURL)
        guard case let .bootstrapSocketUnavailable(code) = error else {
            return XCTFail("stale socket must be retryable, got \(String(describing: error))")
        }
        XCTAssertEqual(code, ECONNREFUSED)
    }

    func testHandshakeWhenSocketIsRemovedAfterConnectIsRetryableSocketUnavailable() async throws {
        let directory = try makePrivateDirectory()
        let socketURL = directory.appendingPathComponent("s.sock")
        let listener = try Self.bindSocket(at: socketURL, listen: true)
        defer { Darwin.close(listener) }
        let path = socketURL.path
        let error = await Self.handshakeError(socketURL: socketURL) {
            XCTAssertEqual(unlink(path), 0)
        }
        guard case let .bootstrapSocketUnavailable(code) = error else {
            return XCTFail("socket removed after connect must be retryable, got \(String(describing: error))")
        }
        XCTAssertEqual(code, ENOENT)
    }

    func testHandshakeKeepsUnsafeSocketEntriesAsHardFailures() async throws {
        let directory = try makePrivateDirectory()
        let socketURL = directory.appendingPathComponent("s.sock")

        // A regular file where the socket should be.
        XCTAssertTrue(FileManager.default.createFile(
            atPath: socketURL.path, contents: Data(), attributes: [.posixPermissions: 0o600]
        ))
        try await Self.assertHardValidationFailure(socketURL: socketURL, "non-socket entry")
        XCTAssertEqual(unlink(socketURL.path), 0)

        // A symlink to an otherwise valid socket.
        let target = directory.appendingPathComponent("t.sock")
        let listener = try Self.bindSocket(at: target, listen: true)
        defer { Darwin.close(listener) }
        XCTAssertEqual(symlink(target.path, socketURL.path), 0)
        try await Self.assertHardValidationFailure(socketURL: socketURL, "symlinked socket")
        XCTAssertEqual(unlink(socketURL.path), 0)

        // A socket with permissions wider than owner-only.
        let wide = try Self.bindSocket(at: socketURL, listen: true, mode: 0o666)
        defer { Darwin.close(wide) }
        try await Self.assertHardValidationFailure(socketURL: socketURL, "world-writable socket")
    }

    // MARK: - Helpers

    private static func scratchDirectoryURL() -> URL {
        // Short /tmp paths keep socket paths within sockaddr_un.sun_path.
        URL(fileURLWithPath: "/tmp/rpce-hs-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    private func makePrivateDirectory() throws -> URL {
        let directory = Self.scratchDirectoryURL()
        XCTAssertEqual(mkdir(directory.path, 0o700), 0, String(cString: strerror(errno)))
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private static func bindSocket(at url: URL, listen shouldListen: Bool, mode: mode_t = 0o600) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = url.path
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                _ = strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr)
            }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, mode) == 0, !shouldListen || Darwin.listen(fd, 4) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return fd
    }

    private static func handshakeError(
        socketURL: URL,
        afterConnect: @escaping @Sendable () -> Void = {}
    ) async -> InteractiveSessionError? {
        let session = InteractiveMCPClientSession(sessionToken: "test", clientName: "handshake-classification")
        do {
            let fd = try await session.performBootstrapHandshake(socketURL: socketURL, afterConnectForTesting: afterConnect)
            Darwin.close(fd)
            return nil
        } catch let error as InteractiveSessionError {
            return error
        } catch {
            XCTFail("unexpected error type: \(error)")
            return nil
        }
    }

    private static func assertHardValidationFailure(socketURL: URL, _ label: String) async throws {
        let session = InteractiveMCPClientSession(sessionToken: "test", clientName: "handshake-classification")
        do {
            let fd = try await session.performBootstrapHandshake(socketURL: socketURL)
            Darwin.close(fd)
            XCTFail("\(label) must be rejected")
        } catch let error as MCPBootstrapDirectory.DirectoryError {
            XCTAssertFalse(error.isMissing, label)
        } catch {
            XCTFail("\(label) must stay a hard validation failure, got \(error)")
        }
    }
}
