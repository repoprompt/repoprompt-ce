import Darwin
import Foundation
import RepoPromptDomainRuntime
@testable import RepoPromptMCPCore
import XCTest

final class DirectHeadlessFileReadTests: XCTestCase {
    func testStreamingSlicesMatchLegacyNewlineAndTailSemantics() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for text in ["", "a\n", "a\n\u{FEFF}b", "\u{FEFF}a\n\u{FEFF}b", "a\r\nb\u{85}c\u{2028}😀\u{2029}d\u{B}e\u{C}f", "😀日本語"] {
            try Data(text.utf8).write(to: fixture.file)
            let legacyText = try String(contentsOf: fixture.file, encoding: .utf8)
            let lines = legacyText.components(separatedBy: .newlines)
            for (start, limit) in [(nil, nil), (1, 2), (2, 1), (0, 0), (100, Int.max), (-2, 1), (Int.min, nil)] as [(Int?, Int?)] {
                let expected: String = if let start, start < 0 {
                    lines.suffix(Int(min(start.magnitude, UInt(lines.count)))).joined(separator: "\n")
                } else if let start {
                    lines.dropFirst(max(0, start - 1)).prefix(limit ?? Int.max).joined(separator: "\n")
                } else {
                    legacyText.components(separatedBy: .newlines).joined(separator: "\n")
                }
                let actual = try await MCPDomainHeadlessFileReader.read(
                    at: fixture.file, startLine: start, limit: limit, chunkSize: 1,
                    slotDirectory: fixture.slots, slotCount: 1
                )
                XCTAssertEqual(actual, expected, "start=\(String(describing: start)), text=\(text.debugDescription)")
            }
        }
    }

    func testPositiveSliceStopsBeforeReadingTheRemainder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data(("first\n" + String(repeating: "x", count: 100_000)).utf8).write(to: fixture.file)
        let count = Counter()
        let result = try await MCPDomainHeadlessFileReader.read(
            at: fixture.file, startLine: 1, limit: 1, chunkSize: 8,
            slotDirectory: fixture.slots, slotCount: 1, didReadChunk: { count.set($0) }
        )
        XCTAssertEqual(result, "first")
        XCTAssertEqual(count.value, 8)
    }

    func testBinaryInvalidUTF8AndNonRegularFilesFailWithoutLeakingSlots() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for bytes in [Data([65, 0, 66]), Data([0xFF])] {
            try bytes.write(to: fixture.file)
            do {
                _ = try await read(fixture)
                XCTFail("Non-text content must fail")
            } catch {
                XCTAssertEqual(error as? MCPDomainHeadlessFileReader.ReadError, .invalidText)
            }
        }
        do {
            _ = try await MCPDomainHeadlessFileReader.read(
                at: fixture.root, startLine: nil, limit: nil, slotDirectory: fixture.slots, slotCount: 1
            )
            XCTFail("A directory must fail")
        } catch {
            XCTAssertEqual(error as? MCPDomainHeadlessFileReader.ReadError, .notRegularFile)
        }
        try Data("recovered".utf8).write(to: fixture.file)
        let recovered = try await read(fixture)
        XCTAssertEqual(recovered, "recovered")
    }

    func testChangedFileFailsAndReleasesSlot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("before\nrest".utf8).write(to: fixture.file)
        do {
            _ = try await MCPDomainHeadlessFileReader.read(
                at: fixture.file, startLine: 1, limit: 1, chunkSize: 7,
                slotDirectory: fixture.slots, slotCount: 1,
                didReadChunk: { _ in try? Data("replacement".utf8).write(to: fixture.file, options: .atomic) }
            )
            XCTFail("Replacing a file during a read must not return stale content")
        } catch {
            XCTAssertEqual(error as? MCPDomainHeadlessFileReader.ReadError, .changedDuringRead)
        }
        let recovered = try await read(fixture)
        XCTAssertEqual(recovered, "replacement")
    }

    func testCancellationHoldsSlotUntilWorkerSettles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("content".utf8).write(to: fixture.file)
        let entered = expectation(description: "worker read chunk")
        let gate = DispatchSemaphore(value: 0)
        let task = Task {
            try await MCPDomainHeadlessFileReader.read(
                at: fixture.file, startLine: nil, limit: nil,
                slotDirectory: fixture.slots, slotCount: 1,
                didReadChunk: { _ in entered.fulfill()
                    gate.wait()
                }
            )
        }
        await fulfillment(of: [entered], timeout: 5)
        task.cancel()
        let fd = open(fixture.slots.appendingPathComponent("slot-0").path, O_RDWR)
        defer { if fd >= 0 { close(fd) } }
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), -1, "Cancellation must not release an executing worker's slot")
        gate.signal()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0, "Worker completion must release the slot")
    }

    func testOtherProcessSharesAggregateSlotAndCrashReleasesIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("content".utf8).write(to: fixture.file)
        try FileManager.default.createDirectory(at: fixture.slots, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import fcntl,os,sys; f=os.open(sys.argv[1],os.O_RDWR|os.O_CREAT,0o600); fcntl.flock(f,fcntl.LOCK_EX); print('ready',flush=True); sys.stdin.read()", fixture.slots.appendingPathComponent("slot-0").path]
        let output = Pipe()
        let input = Pipe()
        child.standardOutput = output
        child.standardInput = input
        try child.run()
        defer { if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        let ready = try output.fileHandleForReading.read(upToCount: 6)
        XCTAssertEqual(ready, Data("ready\n".utf8))
        let waiting = expectation(description: "reader waits on child process slot")
        waiting.assertForOverFulfill = false
        let task = Task {
            try await MCPDomainHeadlessFileReader.read(
                at: fixture.file, startLine: nil, limit: nil,
                slotDirectory: fixture.slots, slotCount: 1,
                didWaitForSlot: { waiting.fulfill() }
            )
        }
        await fulfillment(of: [waiting], timeout: 5)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A reader queued behind another process must honor cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        child.terminate()
        child.waitUntilExit()
        let recovered = try await read(fixture)
        XCTAssertEqual(recovered, "content", "Process exit must release its slot without deleting lock files")
    }

    func testCanonicalParentReplacedBySymlinkIsRejectedBeforeReading() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("authorized")
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let resolved = directory.appendingPathComponent("secret.txt")
        try Data("authorized".utf8).write(to: resolved)
        try Data("outside-secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        // This is the already-resolved canonical URL retained across admission. Replacing
        // a parent after resolution must not turn it into authority for the symlink target.
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
        do {
            _ = try await MCPDomainHeadlessFileReader.read(
                at: resolved, startLine: nil, limit: nil, slotDirectory: fixture.slots, slotCount: 1
            )
            XCTFail("A substituted parent symlink must not disclose target content")
        } catch {}
    }

    func testConnectionPermitReleasesWhenHostAdmissionIsCancelledOrClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .standalone, profileIdentifier: "file-read-admission", storageDirectory: fixture.root,
            eventDirectory: fixture.root, temporaryDirectory: fixture.root, externalReloadInterval: nil
        ))
        let connection = MCPDomainToolResourceAdmissionController(limit: 1)
        var blockers: [MCPDomainToolResourceAdmissionController.Lease] = []
        for _ in 0 ..< MCPDomainToolAdmissionLimits.fileReadPerWindow {
            try await blockers.append(runtime.domainHost.acquireFileReadResourceAdmission(windowID: 0))
        }
        let task = Task {
            try await DirectHeadlessMCPService.withFileReadAdmission(host: runtime.domainHost, connection: connection) {
                XCTFail("Physical read must not enter while the host budget is occupied")
                return 1
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while connection.snapshot().activeLeaseCount == 0, ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertEqual(connection.snapshot().activeLeaseCount, 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(connection.snapshot().activeLeaseCount, 0)
        for blocker in blockers {
            XCTAssertTrue(blocker.release())
            XCTAssertFalse(blocker.release())
        }
        _ = await runtime.shutdown()
        do {
            _ = try await DirectHeadlessMCPService.withFileReadAdmission(host: runtime.domainHost, connection: connection) { 1 }
            XCTFail("Closed host must reject admission")
        } catch {}
        XCTAssertEqual(connection.snapshot().activeLeaseCount, 0)
    }

    private func read(_ fixture: Fixture) async throws -> String {
        try await MCPDomainHeadlessFileReader.read(
            at: fixture.file, startLine: nil, limit: nil, slotDirectory: fixture.slots, slotCount: 1
        )
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("headless-file-read-\(UUID().uuidString)")
            .standardizedFileURL.resolvingSymlinksInPath()
        var file: URL {
            root.appendingPathComponent("file.txt")
        }

        var slots: URL {
            root.appendingPathComponent("slots")
        }

        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int {
            lock.withLock { count }
        }

        func set(_ count: Int) {
            lock.withLock { self.count = count }
        }
    }
}
