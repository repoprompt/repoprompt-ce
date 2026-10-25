import Darwin
import Foundation
import RepoPromptDomainRuntime
import XCTest

final class MCPDomainHeadlessFileReaderTests: XCTestCase {
    func testStreamingSlicesMatchLegacyNewlineAndTailSemantics() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for text in ["", "a\n", "a\0b", "a\n\u{FEFF}b", "\u{FEFF}a\n\u{FEFF}b", "a\r\nb\u{85}c\u{2028}😀\u{2029}d\u{B}e\u{C}f", "😀日本語"] {
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

    func testReadableFileUnderExecuteOnlyParent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let parent = fixture.root.appendingPathComponent("execute-only")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let file = parent.appendingPathComponent("readable.txt")
        try Data("readable".utf8).write(to: file)
        XCTAssertEqual(chmod(parent.path, 0o300), 0)
        defer { chmod(parent.path, 0o700) }
        let result = try await MCPDomainHeadlessFileReader.read(
            at: file, startLine: nil, limit: nil, slotDirectory: fixture.slots, slotCount: 1
        )
        XCTAssertEqual(result, "readable")
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
        for bytes in [Data([0xFF]), Data([0xC0, 0xAF])] {
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
        defer {
            if fd >= 0 {
                close(fd)
            }
        }
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
        try await withChildProcess(child) { child in
            let ready = try child.readReadyLine(from: output)
            XCTAssertEqual(ready, "ready")
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
            await child.crash()
            let recovered = try await read(fixture)
            XCTAssertEqual(recovered, "content", "Process exit must release its slot without deleting lock files")
        }
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
        } catch {
            guard let code = (error as? POSIXError)?.code else { return XCTFail("Unexpected error: \(error)") }
            // Darwin SDKs report a no-follow search-only parent as ENOTDIR or ELOOP.
            XCTAssertTrue(code == .ELOOP || code == .ENOTDIR, "Unexpected error: \(error)")
        }
    }

    func testChangingFileRetriesOnceAndReturnsFreshContent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("old\n".utf8).write(to: fixture.file)
        let calls = Counter()
        let result = try await MCPDomainHeadlessFileReader.read(
            at: fixture.file, startLine: 1, limit: 1, slotDirectory: fixture.slots, slotCount: 1,
            didReadChunk: { _ in
                if calls.value == 0 {
                    calls.set(1)
                    try? Data("fresh\n".utf8).write(to: fixture.file, options: .atomic)
                }
            }
        )
        XCTAssertEqual(result, "fresh")
    }

    func testZeroLimitValidatesUTF8ButRetainsNoContent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data([65, 0, 66]).write(to: fixture.file)
        let text = try await MCPDomainHeadlessFileReader.read(
            at: fixture.file, startLine: 1, limit: 0, slotDirectory: fixture.slots, slotCount: 1
        )
        XCTAssertEqual(text, "")
        try Data([65, 10, 0xFF]).write(to: fixture.file)
        do {
            _ = try await MCPDomainHeadlessFileReader.read(
                at: fixture.file, startLine: 1, limit: 0, slotDirectory: fixture.slots, slotCount: 1
            )
            XCTFail("An empty slice still validates UTF-8 as the old reader did")
        } catch { XCTAssertEqual(error as? MCPDomainHeadlessFileReader.ReadError, .invalidText) }
    }

    func testAdmissionDeadlineExpiresAndCleansItsQueueClaim() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("content".utf8).write(to: fixture.file)
        try FileManager.default.createDirectory(at: fixture.slots, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(fixture.slots.appendingPathComponent("slot-0").path, O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let time = Counter()
        let deadline = MCPDomainAdmissionDeadline(instant: .seconds(1), now: { .seconds(time.value) }, sleep: { _ in })
        do {
            _ = try await MCPDomainHeadlessFileReader.read(
                at: fixture.file, startLine: nil, limit: nil, slotDirectory: fixture.slots, slotCount: 1,
                didWaitForSlot: { time.set(1) }, admissionDeadline: deadline
            )
            XCTFail("Hung physical holders must not cause an unbounded admission wait")
        } catch { XCTAssertEqual(error as? MCPDomainHeadlessFileReader.ReadError, .admissionTimedOut) }
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.slots.path)
        XCTAssertFalse(names.contains { $0.hasPrefix("wait-") })
        flock(fd, LOCK_UN)
        let recovered = try await read(fixture)
        XCTAssertEqual(recovered, "content")
    }

    func testRegisteredQueueOrderIsFIFOAndPrunesUnlockedCrashClaims() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("content\n".utf8).write(to: fixture.file)
        try FileManager.default.createDirectory(at: fixture.slots, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stale = fixture.slots.appendingPathComponent("wait-00000000000000000000-crashed")
        try Data().write(to: stale)
        XCTAssertEqual(chmod(stale.path, 0o600), 0)
        let fd = open(fixture.slots.appendingPathComponent("slot-0").path, O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let firstQueued = expectation(description: "first registered")
        let secondQueued = expectation(description: "second registered")
        firstQueued.assertForOverFulfill = false
        secondQueued.assertForOverFulfill = false
        let order = Trace()
        let first = Task {
            try await MCPDomainHeadlessFileReader.read(
                at: fixture.file, startLine: 1, limit: 1, slotDirectory: fixture.slots, slotCount: 1,
                didReadChunk: { _ in order.append(1) }, didWaitForSlot: { firstQueued.fulfill() }
            )
        }
        await fulfillment(of: [firstQueued], timeout: 5)
        let second = Task {
            try await MCPDomainHeadlessFileReader.read(
                at: fixture.file, startLine: 1, limit: 1, slotDirectory: fixture.slots, slotCount: 1,
                didReadChunk: { _ in order.append(2) }, didWaitForSlot: { secondQueued.fulfill() }
            )
        }
        await fulfillment(of: [secondQueued], timeout: 5)
        flock(fd, LOCK_UN)
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(order.values, [1, 2])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testQueuedProcessClaimBlocksLaterReaderUntilCrash() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("content".utf8).write(to: fixture.file)
        try FileManager.default.createDirectory(at: fixture.slots, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        // A separate process participates in the shared coordinator protocol: register a
        // monotonic FIFO ticket under the turnstile, then retain the claim lock while queued.
        child.arguments = ["-c", """
        import fcntl, os, struct, sys, uuid
        directory = sys.argv[1]
        t = os.open(directory + '/turnstile', os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(t, fcntl.LOCK_EX)
        previous = os.pread(t, 8, 0)
        ticket = (struct.unpack('@Q', previous)[0] if previous else 0) + 1
        os.pwrite(t, struct.pack('@Q', ticket), 0)
        name = 'wait-%020d-%s' % (ticket, uuid.uuid4())
        claim = os.open(directory + '/' + name, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600)
        fcntl.flock(claim, fcntl.LOCK_EX)
        fcntl.flock(t, fcntl.LOCK_UN)
        os.close(t)
        print(name, flush=True)
        sys.stdin.read()
        """, fixture.slots.path]
        let output = Pipe()
        let input = Pipe()
        child.standardOutput = output
        child.standardInput = input
        try await withChildProcess(child) { child in
            let name = try child.readReadyLine(from: output)
            XCTAssertTrue(name.hasPrefix("wait-00000000000000000001-"), name)
            let queued = expectation(description: "later reader waits despite an available slot")
            queued.assertForOverFulfill = false
            let read = Task {
                try await MCPDomainHeadlessFileReader.read(
                    at: fixture.file, startLine: nil, limit: nil, slotDirectory: fixture.slots, slotCount: 1,
                    didWaitForSlot: { queued.fulfill() }
                )
            }
            await fulfillment(of: [queued], timeout: 5)
            await child.crash()
            let result = try await read.value
            XCTAssertEqual(result, "content")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.slots.appendingPathComponent(name).path))
        }
    }

    func testMoreThanNSimultaneousReadersNeverExceedPhysicalBound() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("content\n".utf8).write(to: fixture.file)
        let bound = min(2, MCPDomainToolAdmissionLimits.fileReadPerWindow - 1)
        let entered = expectation(description: "physical readers fill the bound")
        entered.expectedFulfillmentCount = bound
        entered.assertForOverFulfill = false
        let waiting = expectation(description: "extra readers queued")
        waiting.assertForOverFulfill = false
        let gate = DispatchSemaphore(value: 0)
        let overlap = Overlap()
        let tasks = (0 ..< bound + 3).map { _ in Task {
            try await MCPDomainHeadlessFileReader.read(
                at: fixture.file, startLine: 1, limit: 1, slotDirectory: fixture.slots, slotCount: bound,
                didReadChunk: { _ in
                    overlap.enter()
                    entered.fulfill()
                    gate.wait()
                    overlap.leave()
                }, didWaitForSlot: { waiting.fulfill() }
            )
        } }
        await fulfillment(of: [entered, waiting], timeout: 5)
        XCTAssertEqual(overlap.active, bound)
        for _ in tasks {
            gate.signal()
        }
        // Always settle every worker before fixture cleanup, even after one fails.
        for task in tasks {
            do {
                let result = try await task.value
                XCTAssertEqual(result, "content")
            } catch { XCTFail("Concurrent reader failed: \(error)") }
        }
        XCTAssertEqual(overlap.peak, bound)
        XCTAssertEqual(overlap.active, 0)
    }

    func testUnavailablePrivateDirectoryWarnsAndUsesInProcessBound() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("content".utf8).write(to: fixture.file)
        try FileManager.default.createDirectory(at: fixture.slots, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(fixture.slots.path, 0), 0)
        defer { chmod(fixture.slots.path, 0o700) }
        let warning = Counter()
        let result = try await MCPDomainHeadlessFileReader.read(
            at: fixture.file, startLine: nil, limit: nil, slotDirectory: fixture.slots,
            onAdmissionWarning: { warning.set(Int($0)) }
        )
        XCTAssertEqual(result, "content")
        XCTAssertEqual(warning.value, Int(EACCES))
    }

    func testUnsafeSlotMetadataNeverFallsBack() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("content".utf8).write(to: fixture.file)
        try FileManager.default.createDirectory(at: fixture.slots, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let slot = fixture.slots.appendingPathComponent("slot-0")
        try Data().write(to: slot)
        XCTAssertEqual(chmod(slot.path, 0o444), 0)
        let warning = Counter()
        do {
            _ = try await MCPDomainHeadlessFileReader.read(
                at: fixture.file, startLine: nil, limit: nil, slotDirectory: fixture.slots, slotCount: 1,
                onAdmissionWarning: { warning.set(Int($0)) }
            )
            XCTFail("Unsafe mode must not degrade to process-only admission")
        } catch { XCTAssertEqual(error as? MCPDomainHeadlessFileReader.ReadError, .unsafeAdmissionDirectory) }
        XCTAssertEqual(warning.value, 0)
    }

    private func withChildProcess(_ process: Process, body: (ChildProcess) async throws -> Void) async throws {
        let child = ChildProcess(process)
        try process.run()
        do {
            try await body(child)
        } catch {
            await child.cleanup()
            throw error
        }
        await child.cleanup()
    }

    private final class ChildProcess {
        let process: Process
        private let exit = ExitSignal()

        init(_ process: Process) {
            self.process = process
            // Install before launch: waitUntilExit can lose its run-loop wakeup on a
            // cooperative thread after an await, even after the child has been reaped.
            process.terminationHandler = { [exit] _ in exit.fire() }
        }

        func readReadyLine(from pipe: Pipe) throws -> String {
            let fd = pipe.fileHandleForReading.fileDescriptor
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            var bytes = Data()
            while bytes.count < 128 {
                let remaining = clock.now.duration(to: deadline)
                guard remaining > .zero else { break }
                let milliseconds = max(1, Int32(remaining.components.seconds * 1000 + remaining.components.attoseconds / 1_000_000_000_000_000))
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let status = poll(&descriptor, 1, milliseconds)
                if status < 0, errno == EINTR {
                    continue
                }
                if status < 0 {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard status > 0 else { break }
                var byte: UInt8 = 0
                let count = Darwin.read(fd, &byte, 1)
                if count < 0, errno == EINTR {
                    continue
                }
                if count < 0 {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard count > 0 else { break }
                if byte == 10 {
                    return String(decoding: bytes, as: UTF8.self)
                }
                bytes.append(byte)
            }
            throw NSError(domain: "ChildProcessReadiness", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Child \(process.processIdentifier) did not emit a readiness line within 5s: \(String(decoding: bytes, as: UTF8.self))"
            ])
        }

        func crash() async {
            XCTAssertEqual(kill(process.processIdentifier, SIGKILL), 0)
            let exited = await exit.wait(timeout: .seconds(5))
            XCTAssertTrue(exited, "Child \(process.processIdentifier) did not exit after SIGKILL")
            if exited {
                XCTAssertEqual(process.terminationReason, .uncaughtSignal)
                XCTAssertEqual(process.terminationStatus, SIGKILL)
            }
        }

        func cleanup() async {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            let exited = await exit.wait(timeout: .seconds(5))
            XCTAssertTrue(exited, "Cleanup timed out for child \(process.processIdentifier)")
        }
    }

    private final class ExitSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var exited = false
        private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

        func fire() {
            let pending = lock.withLock {
                exited = true
                defer { waiters.removeAll() }
                return Array(waiters.values)
            }
            for waiter in pending {
                waiter.resume(returning: true)
            }
        }

        private func wait() async -> Bool {
            let id = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let result: Bool? = lock.withLock {
                        if exited {
                            return true
                        }
                        if Task.isCancelled {
                            return false
                        }
                        waiters[id] = continuation
                        return nil
                    }
                    if let result {
                        continuation.resume(returning: result)
                    }
                }
            } onCancel: {
                let waiter = self.lock.withLock { self.waiters.removeValue(forKey: id) }
                waiter?.resume(returning: false)
            }
        }

        func wait(timeout: Duration) async -> Bool {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask { await self.wait() }
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    return false
                }
                let result = await group.next() ?? false
                group.cancelAll()
                return result
            }
        }
    }

    private final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Int] = []
        var values: [Int] {
            lock.withLock { storage }
        }

        func append(_ value: Int) {
            lock.withLock { storage.append(value) }
        }
    }

    private final class Overlap: @unchecked Sendable {
        private let lock = NSLock()
        private var current = 0
        private var maximum = 0
        var active: Int {
            lock.withLock { current }
        }

        var peak: Int {
            lock.withLock { maximum }
        }

        func enter() {
            lock.withLock { current += 1
                maximum = max(maximum, current)
            }
        }

        func leave() {
            lock.withLock { current -= 1 }
        }
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
