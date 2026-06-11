import Foundation
@testable import RepoPromptShared
import XCTest
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

final class MCPDiagnosticStderrSafetyTests: XCTestCase {
    func testMCPDiagnosticStderrPathsUseBestEffortRawFDWriter() throws {
        let rootURL = try RepoRoot.url()
        let diagnosticSourcePaths = [
            "Sources/RepoPromptShared/MCP/JSONRPCBridgeLedger.swift",
            "Sources/RepoPromptMCP/main.swift"
        ]

        for relativePath in diagnosticSourcePaths {
            let sourceURL = rootURL.appendingPathComponent(relativePath)
            let source = try String(contentsOf: sourceURL, encoding: .utf8)

            XCTAssertFalse(
                source.contains("FileHandle.standardError.write"),
                "\(relativePath) must not use FileHandle.standardError.write for MCP diagnostics; ObjC exceptions from closed stderr bypass Swift error handling."
            )
            XCTAssertTrue(
                source.contains("MCPBestEffortRawFDWriter.write"),
                "\(relativePath) should route MCP diagnostic stderr output through the best-effort raw FD writer."
            )
        }
    }

    func testClosedDiagnosticDescriptorIsDropped() {
        var pipeFDs = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(pipe(&pipeFDs), 0)
        defer { closeIfOpen(pipeFDs[0]) }

        closeIfOpen(pipeFDs[1])

        MCPBestEffortRawFDWriter.write(Data("dropped diagnostic\n".utf8), to: pipeFDs[1])
    }

    func testPartialDiagnosticWritesAreLooped() {
        let payload = Data([1, 2, 3, 4, 5])
        var observedFirstBytes: [UInt8] = []
        var observedCounts: [Int] = []
        let scriptedWrites = [2, 2, 1]

        MCPBestEffortRawFDWriter.write(payload, to: 42) { _, pointer, count in
            let callIndex = observedFirstBytes.count
            guard callIndex < scriptedWrites.count else {
                XCTFail("Writer should stop after scripted partial writes")
                return -1
            }
            guard let pointer else {
                XCTFail("Expected a non-nil write pointer")
                return -1
            }
            let bytePointer = pointer.assumingMemoryBound(to: UInt8.self)
            observedFirstBytes.append(bytePointer.pointee)
            observedCounts.append(count)
            return scriptedWrites[callIndex]
        }

        XCTAssertEqual(observedFirstBytes, [1, 3, 5])
        XCTAssertEqual(observedCounts, [5, 3, 1])
    }

    func testDiagnosticWriterRetriesEINTRThenDropsOnEPIPE() {
        let payload = Data([1, 2, 3, 4, 5, 6])
        var callKinds: [String] = []

        MCPBestEffortRawFDWriter.write(payload, to: 42) { _, _, _ in
            switch callKinds.count {
            case 0:
                callKinds.append("partial")
                return 2
            case 1:
                callKinds.append("eintr")
                errno = EINTR
                return -1
            case 2:
                callKinds.append("success-after-eintr")
                return 2
            case 3:
                callKinds.append("epipe")
                errno = EPIPE
                return -1
            default:
                XCTFail("Writer should stop after EPIPE")
                return -1
            }
        }

        XCTAssertEqual(callKinds, ["partial", "eintr", "success-after-eintr", "epipe"])
    }

    private func closeIfOpen(_ fd: Int32) {
        guard fd >= 0 else { return }
        _ = close(fd)
    }
}
