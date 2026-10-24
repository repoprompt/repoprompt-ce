import Darwin
import Foundation
@testable import RepoPromptMCPCore
import XCTest

final class MCPBackendSelectionTests: XCTestCase {
    func testAvailabilityProbeRequiresPrivateDirectoryAndSocket() throws {
        let directory = URL(fileURLWithPath: "/tmp/rpca-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("probe.sock")
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = socketURL.path.utf8CString
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in
                for (index, byte) in bytes.enumerated() {
                    destination[index] = byte
                }
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(result, 0)
        XCTAssertEqual(listen(fd, 8), 0)
        XCTAssertEqual(chmod(socketURL.path, 0o600), 0)
        XCTAssertTrue(MCPAppSocketAvailabilityProbe.isAvailable(at: socketURL))
        XCTAssertEqual(chmod(socketURL.path, 0o666), 0)
        XCTAssertFalse(MCPAppSocketAvailabilityProbe.isAvailable(at: socketURL))
        XCTAssertEqual(chmod(socketURL.path, 0o600), 0)
        XCTAssertEqual(chmod(directory.path, 0o755), 0)
        XCTAssertFalse(MCPAppSocketAvailabilityProbe.isAvailable(at: socketURL))
    }

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
}
