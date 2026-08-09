import Darwin
import Foundation
@testable import RepoPromptMCP
import XCTest

final class MCPBackendSelectionTests: XCTestCase {
    func testExplicitBackendsNeverProbeAppSocket() {
        var probeCount = 0
        let probe: () -> Bool = {
            probeCount += 1
            return false
        }

        XCTAssertEqual(MCPBackendSelection.resolve(requested: .app, appIsAvailable: probe), .app)
        XCTAssertEqual(MCPBackendSelection.resolve(requested: .headless, appIsAvailable: probe), .headless)
        XCTAssertEqual(probeCount, 0)
    }

    func testAutoSelectsExactlyOnceBeforeSessionComposition() {
        var probeCount = 0
        let selected = MCPBackendSelection.resolve(requested: .auto) {
            probeCount += 1
            return true
        }

        XCTAssertEqual(selected, .app)
        XCTAssertEqual(probeCount, 1)
    }

    func testAutoFallsBackToHeadlessWhenAppSocketIsUnavailable() {
        XCTAssertEqual(
            MCPBackendSelection.resolve(requested: .auto, appIsAvailable: { false }),
            .headless
        )
    }

    func testAvailabilityProbeConnectsWithoutSendingProtocolBytes() throws {
        let directory = URL(
            fileURLWithPath: "/tmp/rpce-auto-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("app.sock")

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer {
            Darwin.close(listener)
            unlink(socketURL.path)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        XCTAssertLessThan(socketURL.path.utf8.count, MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            socketURL.path.withCString { source in
                _ = strcpy(
                    UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self),
                    source
                )
            }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bindResult, 0)
        XCTAssertEqual(Darwin.listen(listener, 1), 0)

        guard MCPAppSocketAvailabilityProbe.isAvailable(at: socketURL) else {
            return XCTFail("Expected the listening app socket to be available")
        }

        var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 1000) > 0 else {
            return XCTFail("Availability probe did not establish a bounded socket connection")
        }
        let accepted = Darwin.accept(listener, nil, nil)
        XCTAssertGreaterThanOrEqual(accepted, 0)
        defer { Darwin.close(accepted) }
        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.read(accepted, &byte, 1), 0)
    }
}
