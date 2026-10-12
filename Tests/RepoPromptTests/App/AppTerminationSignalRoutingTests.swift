import CryptoKit
import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

final class AppTerminationSignalRoutingTests: XCTestCase {
    func testInstallSuppressesDefaultDispositionBeforeObservationAndRoutesDeliveryExactlyOnce() {
        let observer = RecordingTerminationSignalObserver()
        var terminationRequestCount = 0
        let router = AppTerminationSignalRouter(observer: observer) {
            terminationRequestCount += 1
        }

        router.install()
        router.install()

        XCTAssertEqual(observer.events, [
            .ignoredDefaultDisposition(SIGTERM),
            .observed(SIGTERM)
        ])
        XCTAssertEqual(terminationRequestCount, 0)

        observer.recordedHandler?()
        observer.recordedHandler?()

        XCTAssertEqual(terminationRequestCount, 1)
    }

    /// Run through conductor dev-test: its heavy admission owns this bounded helper compile.
    /// The helper opens no windows and uses .prohibited activation policy. Only child processes
    /// created here are signaled; the installed/live RepoPrompt applications are never addressed.
    func testRealSIGTERMAllowsTerminateLaterAsyncReplyWithoutMainDispatchStarvation() throws {
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let router = checkout.appendingPathComponent("Sources/RepoPrompt/App/AppTerminationSignalRouter.swift")
        let sourceBefore = try Data(contentsOf: router)
        let sourceHash = SHA256.hash(data: sourceBefore).map { String(format: "%02x", $0) }.joined()
        print("TERMINATION_ROUTER_SUBPROCESS source=\(router.path) sha256=\(sourceHash)")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("termination-router-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = directory.appendingPathComponent("TerminationHarness.swift")
        let executable = directory.appendingPathComponent("termination-harness")
        try Self.subprocessSource.write(to: harness, atomically: true, encoding: .utf8)

        // Compile the actual checkout source, never a copied/duplicated implementation.
        // Both baselines and repaired checkouts therefore exercise their own production router.
        let compiler = Process()
        let launcher = directory.appendingPathComponent("compiler-owner.py")
        let ownership = directory.appendingPathComponent("compiler-group-owner")
        try Self.compilerLauncherSource.write(to: launcher, atomically: true, encoding: .utf8)
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        compiler.arguments = [
            launcher.path,
            ownership.path,
            "/usr/bin/xcrun",
            "swiftc",
            "-swift-version",
            "5",
            "-parse-as-library",
            "-framework",
            "AppKit",
            router.path,
            harness.path,
            "-o",
            executable.path
        ]
        let diagnostics = directory.appendingPathComponent("compiler.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: diagnostics.path, contents: nil))
        let diagnosticHandle = try FileHandle(forWritingTo: diagnostics)
        defer { try? diagnosticHandle.close() }
        compiler.standardOutput = diagnosticHandle
        compiler.standardError = diagnosticHandle
        let compiled = DispatchSemaphore(value: 0)
        compiler.terminationHandler = { _ in compiled.signal() }
        try compiler.run()
        let compilerCompleted = compiled.wait(timeout: .now() + 30) == .success
        var compilerJoined = compilerCompleted
        var validatedGroup: Int32?
        func readOwnedGroupForCleanup() -> Int32? {
            do {
                if let group = try Self.compilerOwnedGroup(ownership, expectedPID: compiler.processIdentifier) {
                    validatedGroup = group
                }
            } catch {
                // A marker IO/validation failure is always a test failure, never a reason
                // to unwind past disposal. Independently verify the still-live owned PID's
                // kernel group, or retain a group validated earlier in this launch.
                XCTFail("Compiler group marker could not be validated: \(error)")
                if compiler.isRunning {
                    let pid = compiler.processIdentifier
                    let group = Darwin.getpgid(pid)
                    if group == pid, group > 1,
                       group != Darwin.getpgrp(), group != Darwin.getpid()
                    {
                        validatedGroup = group
                    }
                }
            }
            return validatedGroup
        }
        if !compilerCompleted {
            // Before the marker exists the launcher has not exec'd/spawned the compiler.
            // Kill the owned leader and join, then read the marker again to cover publication
            // racing the deadline. Any compiler descendants retain the dedicated group.
            if let group = readOwnedGroupForCleanup() {
                _ = Darwin.kill(-group, SIGKILL)
            } else {
                Self.killOwnedChildIfRunning(compiler)
            }
            compilerJoined = compiled.wait(timeout: .now() + 3) == .success
        }
        let ownedGroup = readOwnedGroupForCleanup()
        var groupCleaned = true
        if let group = ownedGroup, Self.groupExists(group) {
            // Also clean descendants after a leader exits naturally. Remaining descendants
            // are a test failure, not successful compilation or permission to leak work.
            _ = Darwin.kill(-group, SIGKILL)
            groupCleaned = Self.awaitOwnedGroupExit(group, timeout: 3)
            XCTAssertFalse(compilerCompleted, "Compiler leader exited with owned descendants still running")
        }
        XCTAssertTrue(compilerJoined, "Compiler leader did not join after owned cleanup")
        XCTAssertTrue(groupCleaned, "Dedicated compiler process group did not disappear after cleanup")
        XCTAssertNotNil(ownedGroup, "Launcher failed to publish its dedicated compiler group")
        guard compilerJoined, groupCleaned else { return }
        let diagnosticText = try String(data: Data(contentsOf: diagnostics), encoding: .utf8) ?? ""
        XCTAssertTrue(compilerCompleted, "Bounded helper compiler did not complete: \(diagnosticText)")
        guard compilerCompleted else { return }
        XCTAssertEqual(compiler.terminationStatus, 0, diagnosticText)
        guard compiler.terminationStatus == 0 else { return }
        XCTAssertEqual(try Data(contentsOf: router), sourceBefore, "Checkout router changed during helper compilation")

        // Validate the AppKit/WindowServer environment independently. A failing control is a
        // failure, not a skip, and makes the signal outcome unsuitable for causal attribution.
        let control = try Self.runTerminationChild(executable, control: true)
        assertTerminationChild(control, expectedRequests: 0)
        guard control.passed(expectedRequests: 0) else { return }
        let signaled = try Self.runTerminationChild(executable, control: false)
        assertTerminationChild(signaled, expectedRequests: 1)
    }

    private func assertTerminationChild(_ result: TerminationChildResult, expectedRequests: Int) {
        XCTAssertFalse(result.watchdogCleanup, "Child-only watchdog is failure, never success: \(result.events)")
        XCTAssertTrue(result.joined, "Owned child or output reader did not finish: \(result.events)")
        XCTAssertEqual(result.exitStatus, 0, "Child stderr: \(result.stderr); events: \(result.events)")
        XCTAssertEqual(result.events.count(where: { $0 == "TASK_ENTER" }), 1, "\(result.events)")
        XCTAssertEqual(result.events.count(where: { $0 == "TASK_RESUMED" }), 1, "\(result.events)")
        XCTAssertEqual(result.events.count(where: { $0 == "REPLY" }), 1, "\(result.events)")
        XCTAssertEqual(result.events.count(where: { $0 == "SHOULD:1" }), 1, "\(result.events)")
        XCTAssertEqual(result.events.count(where: { $0.hasPrefix("SHOULD:") }), 1, "\(result.events)")
        XCTAssertEqual(result.events.count(where: { $0.hasPrefix("ROUTED:") }), expectedRequests, "\(result.events)")
        XCTAssertEqual(result.events.count(where: { $0 == "WILL:requests=\(expectedRequests):should=1" }), 1, "\(result.events)")
    }

    private struct TerminationChildResult {
        let events: [String]
        let exitStatus: Int32
        let watchdogCleanup: Bool
        let joined: Bool
        let stderr: String

        func passed(expectedRequests: Int) -> Bool {
            !watchdogCleanup && joined && exitStatus == 0
                && events.count(where: { $0 == "TASK_ENTER" }) == 1
                && events.count(where: { $0 == "TASK_RESUMED" }) == 1
                && events.count(where: { $0 == "REPLY" }) == 1
                && events.count(where: { $0.hasPrefix("SHOULD:") }) == 1
                && events.count(where: { $0.hasPrefix("ROUTED:") }) == expectedRequests
                && events.count(where: { $0 == "WILL:requests=\(expectedRequests):should=1" }) == 1
        }
    }

    /// Locked because stdout arrives on Foundation's readability queue, not XCTest's thread.
    private final class ChildOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = Data()
        private var events: [String] = []

        func append(_ data: Data) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            pending.append(data)
            var delivered: [String] = []
            while let newline = pending.firstIndex(of: 10) {
                let event = String(decoding: pending[..<newline], as: UTF8.self)
                pending.removeSubrange(...newline)
                events.append(event)
                delivered.append(event)
            }
            return delivered
        }

        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }

    private static func runTerminationChild(_ executable: URL, control: Bool) throws -> TerminationChildResult {
        let child = Process()
        child.executableURL = executable
        child.arguments = control ? ["--control"] : []
        let input = Pipe()
        let output = Pipe()
        let errorURL = executable.deletingLastPathComponent().appendingPathComponent("stderr-\(UUID()).log")
        guard FileManager.default.createFile(atPath: errorURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer { try? errorHandle.close() }
        child.standardInput = input
        child.standardOutput = output
        child.standardError = errorHandle
        let state = ChildOutput()
        let finished = DispatchSemaphore(value: 0)
        let outputFinished = DispatchSemaphore(value: 0)
        child.terminationHandler = { _ in finished.signal() }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                outputFinished.signal()
                return
            }
            for event in state.append(data) {
                if event == "READY", !control {
                    if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGTERM) }
                } else if event == "SHOULD:1", !control {
                    // Separate delivery after entry; original router's once guard must survive it.
                    if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGTERM) }
                } else if event == "TASK_ENTER" {
                    try? input.fileHandleForWriting.write(contentsOf: Data("REPLY\n".utf8))
                    try? input.fileHandleForWriting.close()
                }
            }
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            killOwnedChildIfRunning(child)
        }
        try child.run()
        // No sleeps or retries. This watchdog only bounds a failed subprocess regression.
        let completed = finished.wait(timeout: .now() + 8) == .success
        var joined = completed
        if !completed {
            killOwnedChildIfRunning(child)
            joined = finished.wait(timeout: .now() + 3) == .success
        }
        let outputJoined = outputFinished.wait(timeout: .now() + 3) == .success
        let stderr = try String(data: Data(contentsOf: errorURL), encoding: .utf8) ?? ""
        return TerminationChildResult(
            events: state.snapshot(), exitStatus: joined ? child.terminationStatus : -1,
            watchdogCleanup: !completed, joined: joined && outputJoined, stderr: stderr
        )
    }

    private static func killOwnedChildIfRunning(_ child: Process) {
        guard child.isRunning else { return }
        // Never resolve an application by name or PID: this Process was created by this test.
        _ = Darwin.kill(child.processIdentifier, SIGKILL)
    }

    /// Marker is written only after dedicated group ownership is verified and before exec. The recorded PID must
    /// match our Process and cannot be XCTest's inherited process group.
    private static func compilerOwnedGroup(_ marker: URL, expectedPID: Int32) throws -> Int32? {
        guard FileManager.default.fileExists(atPath: marker.path) else { return nil }
        let text = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let group = Int32(text), group == expectedPID, group > 1,
              group != Darwin.getpgrp(), group != Darwin.getpid()
        else { throw CocoaError(.fileReadCorruptFile) }
        return group
    }

    private static func groupExists(_ group: Int32) -> Bool {
        if Darwin.kill(-group, 0) == 0 { return true }
        // EPERM/any unexpected error is not evidence of cleanup.
        return errno != ESRCH
    }

    private static func awaitOwnedGroupExit(_ group: Int32, timeout: TimeInterval) -> Bool {
        if !groupExists(group) { return true }
        let gone = DispatchSemaphore(value: 0)
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler {
            if !groupExists(group) { gone.signal() }
        }
        timer.resume()
        defer { timer.cancel() }
        return gone.wait(timeout: .now() + timeout) == .success
    }

    private static let compilerLauncherSource = #"""
    import os
    import sys

    # No compiler or child can exist before ownership is published. Failure is fatal.
    # Foundation may already make its child a group leader. Otherwise establish a new
    # session/group. Never continue in an inherited group.
    if os.getpgrp() != os.getpid():
        os.setsid()
    assert os.getpgrp() == os.getpid()
    marker = sys.argv[1]
    temporary = marker + ".pending"
    with open(temporary, "x", encoding="ascii") as output:
        output.write(str(os.getpid()) + "\n")
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, marker)
    os.execv(sys.argv[2], sys.argv[2:])
    """#

    private static let subprocessSource = #"""
    import AppKit
    import Foundation

    private func record(_ value: String) {
        FileHandle.standardOutput.write(Data((value + "\n").utf8))
    }

    @MainActor
    private final class HarnessDelegate: NSObject, NSApplicationDelegate {
        private var router: AppTerminationSignalRouter!
        private var requestCount = 0
        private var shouldCount = 0
        private let control: Bool

        init(control: Bool) {
            self.control = control
            super.init()
            router = AppTerminationSignalRouter(observer: DispatchTerminationSignalObserver()) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.requestCount += 1
                    record("ROUTED:\(self.requestCount)")
                    NSApplication.shared.terminate(nil)
                }
            }
            router.install()
            router.install()
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            record("READY")
            if control {
                RunLoop.main.perform(inModes: [.common]) {
                    NSApplication.shared.terminate(nil)
                }
            }
        }

        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            shouldCount += 1
            record("SHOULD:\(shouldCount)")
            guard shouldCount == 1 else { return .terminateLater }
            Task { @MainActor in
                record("TASK_ENTER")
                let released: Bool = await withCheckedContinuation { continuation in
                    // Subprocess-only gate: no timeout/delay and no blocking of MainActor.
                    DispatchQueue.global().async {
                        let input = FileHandle.standardInput.availableData
                        continuation.resume(returning: String(data: input, encoding: .utf8)?.contains("REPLY") == true)
                    }
                }
                guard released else { record("BAD_RELEASE"); return }
                await Task.yield()
                record("TASK_RESUMED")
                record("REPLY")
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }

        func applicationWillTerminate(_ notification: Notification) {
            record("WILL:requests=\(requestCount):should=\(shouldCount)")
        }
    }

    @main
    private enum TerminationHarness {
        @MainActor static func main() {
            let app = NSApplication.shared
            // No windows, Dock entry, foreground activation or real app singleton interaction.
            app.setActivationPolicy(.prohibited)
            let delegate = HarnessDelegate(control: CommandLine.arguments.contains("--control"))
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        }
    }
    """#
}

private final class RecordingTerminationSignalObserver: TerminationSignalObserving {
    enum Event: Equatable {
        case ignoredDefaultDisposition(Int32)
        case observed(Int32)
    }

    private(set) var events: [Event] = []
    private(set) var recordedHandler: (() -> Void)?

    func ignoreDefaultDisposition(for signal: Int32) {
        events.append(.ignoredDefaultDisposition(signal))
    }

    func observe(_ signal: Int32, handler: @escaping () -> Void) {
        events.append(.observed(signal))
        recordedHandler = handler
    }
}
