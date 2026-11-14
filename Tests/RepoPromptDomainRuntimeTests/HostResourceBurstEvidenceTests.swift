import Foundation
import RepoPromptDomainRuntime
import XCTest

/// A reproducible real headless-read workload, not a live-app latency benchmark.
final class HostResourceBurstEvidenceTests: XCTestCase {
    func testConcurrentPhysicalReadBurst() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = String(repeating: "host capacity evidence line\n", count: 8192)
        let files = try (0 ..< 24).map { index in
            let file = root.appendingPathComponent("file-\(index).txt")
            try Data(text.utf8).write(to: file)
            return file
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let totalBytes = try await withThrowingTaskGroup(of: Int.self) { group in
            for file in files {
                group.addTask {
                    let result = try await MCPDomainHeadlessFileReader.read(
                        at: file, startLine: nil, limit: nil,
                        slotDirectory: root.appendingPathComponent("slots")
                    )
                    XCTAssertEqual(result, text)
                    return result.utf8.count
                }
            }
            var bytes = 0
            for try await count in group {
                bytes += count
            }
            return bytes
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        XCTAssertEqual(totalBytes, files.count * text.utf8.count)
        let snapshot = HostResourceBudget.shared.snapshot()
        XCTAssertEqual(snapshot.active, 0)
        XCTAssertEqual(snapshot.waiting, 0)
        XCTAssertGreaterThanOrEqual(snapshot.granted, 24)
        XCTAssertLessThanOrEqual(snapshot.peakActive, HostResourceCapacity.baseline.total)
        print("HOST_CAPACITY_EVIDENCE total=\(snapshot.capacity.total) cpu=\(snapshot.capacity.cpu) io=\(snapshot.capacity.io) peak_active=\(snapshot.peakActive) grants=\(snapshot.granted) wait_ns=\(snapshot.waitNanoseconds)")
        print("HOST_READ_EVIDENCE files=\(files.count) bytes=\(totalBytes) elapsed_ms=\(elapsed) connection_read_limit=\(MCPDomainToolAdmissionLimits.fileReadConnection)")
    }
}
