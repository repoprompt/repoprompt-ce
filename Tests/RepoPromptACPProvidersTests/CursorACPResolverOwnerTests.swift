import Darwin
import Foundation
@testable import RepoPromptACPProviders
import RepoPromptAIContracts
import RepoPromptFileSystem
import RepoPromptFoundation
@testable import RepoPromptProcess
import XCTest

final class CursorACPResolverOwnerTests: XCTestCase {
    func testInjectedFailureRecorderReceivesSourceAndCandidateCount() async throws {
        let directory = try makeTemporaryDirectory()
        let failures = CursorResolutionFailures()
        let resolver = makeTestResolver(
            launchEnvironmentProvider: { _ in
                ACPLaunchEnvironment(environment: ["PATH": directory.path, "SHELL": "/bin/false"], shellEnvironmentSource: .enrichedFallback)
            },
            supplementalPathProvider: { $0 },
            failureRecorder: { source, count in failures.record(source: source, count: count) }
        )
        let config = CursorAgentConfig(commandName: directory.appendingPathComponent("cursor-agent").path, additionalPathHints: [])

        let result = try await resolver.probeSupport(for: config)
        guard case .unsupported = result else { return XCTFail("Expected missing executable") }
        XCTAssertEqual(failures.snapshot().map(\.source), [.enrichedFallback])
        XCTAssertEqual(failures.snapshot().map(\.count), [1])
    }

    func testInjectedFilterReachesPhysicalProbeAndRemovesCredentials() async throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(named: "cursor-agent", in: directory)
        try """
        #!/bin/sh
        if [ "$FILTER_WITNESS" = injected ] && [ -z "$CURSOR_API_KEY" ] && [ -z "$CURSOR_AUTH_TOKEN" ]; then
          printf 'Cursor Agent ACP support\\n'
        else
          exit 1
        fi
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let resolver = makeTestResolver(
            environmentProvider: { _ in ["PATH": directory.path, "CURSOR_API_KEY": "secret", "CURSOR_AUTH_TOKEN": "secret"] },
            supplementalPathProvider: { $0 },
            environmentFilter: { environment, _ in
                var filtered = environment
                filtered["FILTER_WITNESS"] = "injected"
                return filtered
            }
        )
        let config = CursorAgentConfig(additionalPathHints: [], includeRepoPromptMCPServer: false)
        let result = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) {
            try await resolver.probeSupport(for: config)
        }
        XCTAssertEqual(result, .supported)
    }

    func testHealthyLegacyDoesNotDiscoverSecondaryEntrypoint() async throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(named: "cursor-agent", in: directory)
        let shellMarker = directory.appendingPathComponent("secondary-shell-lookup")
        let shell = try makeExecutable(named: "shell", in: directory, marker: shellMarker, output: "")
        let resolver = makeTestResolver(
            environmentProvider: { _ in ["PATH": directory.path, "SHELL": shell.path] },
            supplementalPathProvider: { $0 }
        )
        let config = CursorAgentConfig(additionalPathHints: [], includeRepoPromptMCPServer: false)

        let support = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await resolver.probeSupport(for: config) }

        XCTAssertEqual(support, .supported)
        XCTAssertEqual(try resolver.resolvedLaunch(for: config).command, try canonicalExecutablePath(executable))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shellMarker.path))
    }

    func testDuplicateCanonicalLegacyIsProbedOnceBeforeDistinctFallback() async throws {
        let root = try makeTemporaryDirectory()
        let directories = try ["legacy", "current", "first", "second"].map { name in
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        let legacy = try makeExecutable(named: "cursor-agent", in: directories[0])
        let current = try makeExecutable(named: "cursor-agent", in: directories[1])
        for directory in directories.suffix(2) {
            try FileManager.default.createSymbolicLink(
                at: directory.appendingPathComponent("cursor-agent"), withDestinationURL: legacy
            )
        }
        // The same target also appears under the fallback name: deduplication spans stages.
        try FileManager.default.createSymbolicLink(
            at: directories[2].appendingPathComponent("agent"), withDestinationURL: legacy
        )
        try FileManager.default.createSymbolicLink(
            at: directories[3].appendingPathComponent("agent"), withDestinationURL: current
        )
        let path = directories.suffix(2).map(\.path).joined(separator: ":")
        let legacyPath = try canonicalExecutablePath(legacy)
        let currentPath = try canonicalExecutablePath(current)
        let probes = CursorProbeCommands()
        let resolver = makeTestResolver(
            environmentProvider: { _ in ["PATH": path, "SHELL": "/bin/false"] },
            supplementalPathProvider: { $0 },
            probeRunner: { launch, _, _, _ in
                await probes.record(launch.command)
                return CLIProcessRunner.Result(
                    stdout: Data("Cursor Agent ACP support".utf8), stderr: Data(),
                    status: launch.command == legacyPath ? 2 : 0, timedOut: false
                )
            }
        )
        let config = CursorAgentConfig(additionalPathHints: [], includeRepoPromptMCPServer: false)

        let support = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await resolver.probeSupport(for: config) }

        XCTAssertEqual(support, .supported)
        XCTAssertEqual(try resolver.resolvedLaunch(for: config).command, currentPath)
        let commands = await probes.commands
        XCTAssertEqual(commands, [legacyPath, currentPath])
    }

    func testInitialDiscoveryDoesNotConsumeCapabilityProbeBudget() async throws {
        try await assertDiscoveryPreservesProbeBudget(staleLegacy: false)
    }

    func testFallbackDiscoveryDoesNotConsumeCapabilityProbeBudget() async throws {
        try await assertDiscoveryPreservesProbeBudget(staleLegacy: true)
    }

    func testCancellationDuringDiscoveryDoesNotAdmitProducer() async throws {
        let root = try makeTemporaryDirectory()
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = try makeExecutable(named: "cursor-agent", in: root)
        let enteredFIFO = root.appendingPathComponent("lookup-entered")
        let releaseFIFO = root.appendingPathComponent("lookup-release")
        for fifo in [enteredFIFO, releaseFIFO] {
            guard mkfifo(fifo.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        }
        let enteredDescriptor = open(enteredFIFO.path, O_RDWR | O_NONBLOCK)
        guard enteredDescriptor >= 0 else { throw POSIXError(.EIO) }
        let entered = expectation(description: "Shell lookup reached the release barrier")
        let reader = DispatchSource.makeReadSource(fileDescriptor: enteredDescriptor, queue: .global())
        reader.setEventHandler {
            var byte: UInt8 = 0
            if Darwin.read(enteredDescriptor, &byte, 1) == 1 {
                entered.fulfill()
            }
        }
        reader.setCancelHandler { close(enteredDescriptor) }
        reader.resume()
        defer { reader.cancel() }
        let releaseDescriptor = open(releaseFIFO.path, O_RDWR | O_NONBLOCK)
        guard releaseDescriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(releaseDescriptor) }
        let completedMarker = root.appendingPathComponent("lookup-completed")
        let shell = try makeExecutable(named: "shell", in: root)
        try """
        #!/bin/sh
        printf '1' > '\(enteredFIFO.path)'
        IFS= read -r release < '\(releaseFIFO.path)'
        printf '1' > '\(completedMarker.path)'
        printf '%s\\n' '__RP_BEGIN__' '\(executable.path)' '__RP_END__'
        """.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        let calls = CursorProbeCallCounter()
        let resolver = makeTestResolver(
            environmentProvider: { _ in ["PATH": bin.path, "SHELL": shell.path] },
            supplementalPathProvider: { $0 },
            probeRunner: { _, _, _, _ in
                _ = await calls.nextCall()
                return CLIProcessRunner.Result(
                    stdout: Data("Cursor Agent ACP support".utf8), stderr: Data(), status: 0, timedOut: false
                )
            }
        )
        let config = CursorAgentConfig(commandName: "cursor-agent", additionalPathHints: [])
        let supportTask = Task { try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await resolver.probeSupport(for: config) } }

        // This timeout is a deadlock guard, not a performance oracle.
        await fulfillment(of: [entered], timeout: 30)
        supportTask.cancel()
        var releaseByte: UInt8 = 10
        XCTAssertEqual(Darwin.write(releaseDescriptor, &releaseByte, 1), 1)
        do {
            _ = try await supportTask.value
            XCTFail("Expected cancellation after shell discovery")
        } catch is CancellationError {
            // Expected.
        }
        await resolver.waitForProbeAttemptSettlementForTesting()

        XCTAssertTrue(FileManager.default.fileExists(atPath: completedMarker.path))
        let callCount = await calls.count()
        XCTAssertEqual(callCount, 0)
        XCTAssertThrowsError(try resolver.resolvedLaunch(for: config))
    }

    func testCapabilityProbeRejectsTimedOutZeroStatusAndDoesNotCacheLaunch() async throws {
        let directory = try makeTemporaryDirectory()
        _ = try makeExecutable(named: "cursor-agent", in: directory)
        let resolver = makeTestResolver(
            environmentProvider: { _ in ["PATH": directory.path, "SHELL": "/bin/false"] },
            supplementalPathProvider: { $0 },
            probeRunner: { _, _, _, _ in
                CLIProcessRunner.Result(
                    stdout: Data("Cursor Agent ACP support".utf8),
                    stderr: Data(),
                    status: 0,
                    timedOut: true
                )
            }
        )
        let config = CursorAgentConfig(commandName: "cursor-agent", additionalPathHints: [])

        let support = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await resolver.probeSupport(for: config) }

        guard case .unsupported = support else {
            return XCTFail("Expected a timed-out probe to be unsupported")
        }
        XCTAssertThrowsError(try resolver.resolvedLaunch(for: config)) { error in
            guard case CursorACPLaunchResolutionError.environmentDiscoveryRequired = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCapabilityProbeReservesTimeoutCleanupWithinAggregateDeadline() async throws {
        let rootDirectory = try makeTemporaryDirectory()
        let legacyDirectory = rootDirectory.appendingPathComponent("legacy", isDirectory: true)
        let currentDirectory = rootDirectory.appendingPathComponent("current", isDirectory: true)
        let binDirectory = rootDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let legacyExecutable = try makeExecutable(named: "cursor-agent", in: legacyDirectory)
        let currentExecutable = try makeExecutable(named: "cursor-agent", in: currentDirectory)
        try FileManager.default.createSymbolicLink(
            at: binDirectory.appendingPathComponent("cursor-agent"),
            withDestinationURL: legacyExecutable
        )
        try FileManager.default.createSymbolicLink(
            at: binDirectory.appendingPathComponent("agent"),
            withDestinationURL: currentExecutable
        )
        let timeline = CursorProbeTimeline(nowValues: [0, 1, 10, 10, 10])
        let deadline = CursorProbeDeadlineBarrier()
        let resolver = makeTestResolver(
            environmentProvider: { _ in ["PATH": binDirectory.path, "SHELL": "/bin/false"] },
            supplementalPathProvider: { $0 },
            probeRunner: { _, _, timeout, timeoutCleanupPolicy in
                timeline.record(timeout: timeout, cleanupAllowance: timeoutCleanupPolicy.maximumDuration)
                return CLIProcessRunner.Result(stdout: Data(), stderr: Data(), status: 2, timedOut: false)
            },
            nowProvider: { timeline.nextNow() },
            deadlineWaiter: { _ in await deadline.wait() },
            aggregateProbeTimeout: 10
        )

        let support = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await resolver.probeSupport(for: CursorAgentConfig(additionalPathHints: [])) }

        guard case .unsupported = support else {
            return XCTFail("Expected aggregate deadline exhaustion to be unsupported")
        }
        XCTAssertEqual(timeline.recordedTimeouts(), [6])
        XCTAssertEqual(timeline.recordedCleanupAllowances(), [3])
    }

    func testCapabilityProbeDoesNotCacheSuccessAfterClockDeadlineBeforeTimerFires() async throws {
        let directory = try makeTemporaryDirectory()
        _ = try makeExecutable(named: "cursor-agent", in: directory)
        let timeline = CursorProbeTimeline(nowValues: [0, 0, 10])
        let deadline = CursorProbeDeadlineBarrier()
        let resolver = makeTestResolver(
            environmentProvider: { _ in ["PATH": directory.path, "SHELL": "/bin/false"] },
            supplementalPathProvider: { $0 },
            probeRunner: { _, _, _, _ in
                CLIProcessRunner.Result(
                    stdout: Data("Cursor Agent ACP support".utf8),
                    stderr: Data(),
                    status: 0,
                    timedOut: false
                )
            },
            nowProvider: { timeline.nextNow() },
            deadlineWaiter: { _ in await deadline.wait() },
            aggregateProbeTimeout: 10
        )
        let config = CursorAgentConfig(commandName: "cursor-agent", additionalPathHints: [])

        let support = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await resolver.probeSupport(for: config) }

        guard case let .unsupported(reason) = support else {
            return XCTFail("Expected an expired clock to reject the successful producer result")
        }
        XCTAssertTrue(reason.contains("aggregate timeout"))
        let timerWasSignaled = await deadline.wasSignaled()
        XCTAssertFalse(timerWasSignaled)
        XCTAssertThrowsError(try resolver.resolvedLaunch(for: config))
    }

    func testCapabilityProbeTimeoutRejectsNewResolverUntilLateProducerSettles() async throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(named: "cursor-agent", in: directory)
        let producer = CursorProbeProducerBarrier()
        let firstCalls = CursorProbeCallCounter()
        let secondCalls = CursorProbeCallCounter()
        let firstDeadline = CursorProbeDeadlineBarrier()
        let secondDeadline = CursorProbeDeadlineBarrier()
        let firstResolver = makeTestResolver(
            environmentProvider: { _ in ["PATH": directory.path, "SHELL": "/bin/false"] },
            supplementalPathProvider: { $0 },
            probeRunner: { _, _, _, _ in
                let call = await firstCalls.nextCall()
                if call == 1 {
                    await producer.enter()
                    await withTaskCancellationHandler(operation: {
                        await producer.waitForRelease()
                    }, onCancel: {
                        Task { await producer.recordCancellation() }
                    })
                    await producer.recordReturned()
                }
                return CLIProcessRunner.Result(
                    stdout: Data("Cursor Agent ACP support".utf8),
                    stderr: Data(),
                    status: 0,
                    timedOut: false
                )
            },
            nowProvider: { 0 },
            deadlineWaiter: { _ in await firstDeadline.wait() },
            aggregateProbeTimeout: 10
        )
        let secondResolver = makeTestResolver(
            environmentProvider: { _ in ["PATH": directory.path, "SHELL": "/bin/false"] },
            supplementalPathProvider: { $0 },
            probeRunner: { _, _, _, _ in
                await secondCalls.nextCall()
                return CLIProcessRunner.Result(
                    stdout: Data("Cursor Agent ACP support".utf8),
                    stderr: Data(),
                    status: 0,
                    timedOut: false
                )
            },
            nowProvider: { 0 },
            deadlineWaiter: { _ in await secondDeadline.wait() },
            aggregateProbeTimeout: 10,
            sharingProbeOwnershipWith: firstResolver
        )
        let config = CursorAgentConfig(commandName: "cursor-agent", additionalPathHints: [])
        let firstProbe = Task { try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await firstResolver.probeSupport(for: config) } }

        await producer.waitUntilEntered()
        await firstDeadline.waitUntilEntered()
        await firstDeadline.signal()

        let firstSupport = try await firstProbe.value
        guard case let .unsupported(reason) = firstSupport else {
            return XCTFail("Expected the aggregate deadline to retire the logical probe")
        }
        XCTAssertTrue(reason.contains("aggregate timeout"))
        await producer.waitUntilCancellation()

        let pendingSupport = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await secondResolver.probeSupport(for: config) }
        guard case let .unsupported(pendingReason) = pendingSupport else {
            return XCTFail("Expected a retry to be rejected while the producer drains")
        }
        XCTAssertTrue(pendingReason.contains("cleanup is still pending"))
        let firstCallCount = await firstCalls.count()
        XCTAssertEqual(firstCallCount, 1)
        let pendingCallCount = await secondCalls.count()
        XCTAssertEqual(pendingCallCount, 0)

        await producer.release()
        await producer.waitUntilReturned()
        await firstResolver.waitForProbeAttemptSettlementForTesting()
        XCTAssertThrowsError(try secondResolver.resolvedLaunch(for: config))

        let recoveredSupport = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await secondResolver.probeSupport(for: config) }
        XCTAssertEqual(recoveredSupport, .supported)
        let recoveredCallCount = await secondCalls.count()
        XCTAssertEqual(recoveredCallCount, 1)
        let recoveredLaunch = try secondResolver.resolvedLaunch(for: config)
        XCTAssertEqual(recoveredLaunch.command, try canonicalExecutablePath(executable))
    }

    func testCapabilityProbeCancellationDrainsProducerBeforeRecovery() async throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(named: "cursor-agent", in: directory)
        let producer = CursorProbeProducerBarrier()
        let calls = CursorProbeCallCounter()
        let firstDeadline = CursorProbeDeadlineBarrier()
        let secondDeadline = CursorProbeDeadlineBarrier()
        let deadlines = CursorProbeDeadlineRouter([firstDeadline, secondDeadline])
        let resolver = makeTestResolver(
            environmentProvider: { _ in ["PATH": directory.path, "SHELL": "/bin/false"] },
            supplementalPathProvider: { $0 },
            probeRunner: { _, _, _, _ in
                let call = await calls.nextCall()
                if call == 1 {
                    await producer.enter()
                    await withTaskCancellationHandler(operation: {
                        await producer.waitForRelease()
                    }, onCancel: {
                        Task { await producer.recordCancellation() }
                    })
                    await producer.recordReturned()
                }
                return CLIProcessRunner.Result(
                    stdout: Data("Cursor Agent ACP support".utf8),
                    stderr: Data(),
                    status: 0,
                    timedOut: false
                )
            },
            nowProvider: { 0 },
            deadlineWaiter: { _ in await deadlines.wait() },
            aggregateProbeTimeout: 10
        )
        let config = CursorAgentConfig(commandName: "cursor-agent", additionalPathHints: [])
        let firstProbe = Task { try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await resolver.probeSupport(for: config) } }

        await producer.waitUntilEntered()
        firstProbe.cancel()
        do {
            _ = try await firstProbe.value
            XCTFail("Expected cancellation to propagate from the logical probe")
        } catch is CancellationError {
            // Expected: the producer remains owned independently of this task.
        }
        await producer.waitUntilCancellation()

        let pendingSupport = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await resolver.probeSupport(for: config) }
        guard case let .unsupported(pendingReason) = pendingSupport else {
            return XCTFail("Expected a retry to be rejected while the canceled producer drains")
        }
        XCTAssertTrue(pendingReason.contains("cleanup is still pending"))
        let pendingCallCount = await calls.count()
        XCTAssertEqual(pendingCallCount, 1)

        await producer.release()
        await producer.waitUntilReturned()
        await resolver.waitForProbeAttemptSettlementForTesting()
        XCTAssertThrowsError(try resolver.resolvedLaunch(for: config))

        let recoveredSupport = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await resolver.probeSupport(for: config) }
        XCTAssertEqual(recoveredSupport, .supported)
        let recoveredCallCount = await calls.count()
        XCTAssertEqual(recoveredCallCount, 2)
        let recoveredLaunch = try resolver.resolvedLaunch(for: config)
        XCTAssertEqual(recoveredLaunch.command, try canonicalExecutablePath(executable))
    }

    private func assertDiscoveryPreservesProbeBudget(staleLegacy: Bool) async throws {
        let root = try makeTemporaryDirectory()
        let legacyDirectory = root.appendingPathComponent("legacy", isDirectory: true)
        let currentDirectory = root.appendingPathComponent("current", isDirectory: true)
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        for directory in [legacyDirectory, currentDirectory, binDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let legacy = try makeExecutable(named: "cursor-agent", in: legacyDirectory)
        let current = try makeExecutable(named: "cursor-agent", in: currentDirectory)
        let alias = (staleLegacy ? root : binDirectory).appendingPathComponent("agent")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: current)
        if staleLegacy {
            try FileManager.default.createSymbolicLink(
                at: binDirectory.appendingPathComponent("cursor-agent"), withDestinationURL: legacy
            )
        }
        let lookupMarker = root.appendingPathComponent("shell-lookup")
        let shell = try makeExecutable(
            named: "shell", in: root, marker: lookupMarker,
            output: staleLegacy ? "__RP_BEGIN__\n\(alias.path)\n__RP_END__" : ""
        )
        let legacyPath = try canonicalExecutablePath(legacy)
        let currentPath = try canonicalExecutablePath(current)
        let probes = CursorProbeCommands()
        let clock = CursorDiscoveryClock(lookupMarker: lookupMarker)
        let resolver = makeTestResolver(
            environmentProvider: { _ in ["PATH": binDirectory.path, "SHELL": shell.path] },
            supplementalPathProvider: { $0 },
            probeRunner: { launch, _, timeout, _ in
                await probes.record(launch.command, timeout: timeout)
                if launch.command == legacyPath {
                    clock.advance(by: 6)
                }
                return CLIProcessRunner.Result(
                    stdout: Data("Cursor Agent ACP support".utf8), stderr: Data(),
                    status: launch.command == legacyPath ? 2 : 0, timedOut: false
                )
            },
            // Model slow discovery without sleeps or a host-dependent duration assertion.
            nowProvider: { clock.now() },
            deadlineWaiter: { _ in await CursorProbeDeadlineBarrier().wait() },
            aggregateProbeTimeout: 10
        )
        let config = CursorAgentConfig(additionalPathHints: [], includeRepoPromptMCPServer: false)

        let support = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await resolver.probeSupport(for: config) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: lookupMarker.path))
        XCTAssertEqual(support, .supported)
        let commands = await probes.commands
        XCTAssertEqual(commands, staleLegacy ? [legacyPath, currentPath] : [currentPath])
        let timeouts = await probes.timeouts
        XCTAssertEqual(timeouts, staleLegacy ? [7, 1] : [7])
        XCTAssertEqual(try resolver.resolvedLaunch(for: config).command, currentPath)
    }

    private func makeTemporaryDirectory() throws -> URL {
        try makeOwnerTestDirectory()
    }

    private func canonicalExecutablePath(_ url: URL) throws -> String {
        try XCTUnwrap(FileSystemService.realpathString(url.path))
    }

    @discardableResult
    private func makeExecutable(
        named name: String,
        in directory: URL,
        marker: URL? = nil,
        output: String = "Cursor Agent ACP support"
    ) throws -> URL {
        let executable = directory.appendingPathComponent(name)
        var lines = ["#!/bin/sh"]
        if let marker {
            lines.append("printf '%s' \"$0\" > '\(marker.path)'")
        }
        lines.append("printf '%s\\n' '\(output)'")
        try lines.joined(separator: "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }
}

private final class CursorResolutionFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(source: ShellEnvironmentSource?, count: Int)] = []

    func record(source: ShellEnvironmentSource?, count: Int) {
        lock.lock()
        entries.append((source, count))
        lock.unlock()
    }

    func snapshot() -> [(source: ShellEnvironmentSource?, count: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

private final class CursorProbeTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var nowValues: [TimeInterval]
    private var timeouts: [TimeInterval] = []
    private var cleanupAllowances: [TimeInterval] = []

    init(nowValues: [TimeInterval]) {
        self.nowValues = nowValues
    }

    func nextNow() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return nowValues.removeFirst()
    }

    func record(timeout: TimeInterval, cleanupAllowance: TimeInterval) {
        lock.lock()
        timeouts.append(timeout)
        cleanupAllowances.append(cleanupAllowance)
        lock.unlock()
    }

    func recordedTimeouts() -> [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return timeouts
    }

    func recordedCleanupAllowances() -> [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return cleanupAllowances
    }
}

private actor CursorProbeCallCounter {
    private var callCount = 0

    func nextCall() -> Int {
        callCount += 1
        return callCount
    }

    func count() -> Int {
        callCount
    }
}

private actor CursorProbeProducerBarrier {
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var cancellationContinuation: CheckedContinuation<Void, Never>?
    private var returnedContinuation: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    private var isReleased = false
    private var cancellationRequested = false
    private var hasReturned = false

    func enter() {
        guard !hasEntered else { return }
        hasEntered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { continuation in
            if hasEntered {
                continuation.resume()
            } else {
                enteredContinuation = continuation
            }
        }
    }

    func waitForRelease() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                releaseContinuation = continuation
            }
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func recordCancellation() {
        guard !cancellationRequested else { return }
        cancellationRequested = true
        cancellationContinuation?.resume()
        cancellationContinuation = nil
    }

    func waitUntilCancellation() async {
        guard !cancellationRequested else { return }
        await withCheckedContinuation { continuation in
            if cancellationRequested {
                continuation.resume()
            } else {
                cancellationContinuation = continuation
            }
        }
    }

    func recordReturned() {
        guard !hasReturned else { return }
        hasReturned = true
        returnedContinuation?.resume()
        returnedContinuation = nil
    }

    func waitUntilReturned() async {
        guard !hasReturned else { return }
        await withCheckedContinuation { continuation in
            if hasReturned {
                continuation.resume()
            } else {
                returnedContinuation = continuation
            }
        }
    }
}

private actor CursorProbeDeadlineBarrier {
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var waitContinuation: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    private var isOpen = false

    func wait() async {
        if !hasEntered {
            hasEntered = true
            enteredContinuation?.resume()
            enteredContinuation = nil
        }
        guard !isOpen else { return }
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if isOpen || Task.isCancelled {
                    continuation.resume()
                } else {
                    waitContinuation = continuation
                }
            }
        }, onCancel: {
            Task { await self.cancelWaiter() }
        })
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { continuation in
            if hasEntered {
                continuation.resume()
            } else {
                enteredContinuation = continuation
            }
        }
    }

    func signal() {
        guard !isOpen else { return }
        isOpen = true
        waitContinuation?.resume()
        waitContinuation = nil
    }

    func wasSignaled() -> Bool {
        isOpen
    }

    private func cancelWaiter() {
        waitContinuation?.resume()
        waitContinuation = nil
    }
}

private actor CursorProbeDeadlineRouter {
    private var barriers: [CursorProbeDeadlineBarrier]

    init(_ barriers: [CursorProbeDeadlineBarrier]) {
        self.barriers = barriers
    }

    func wait() async {
        guard !barriers.isEmpty else { return }
        let barrier = barriers.removeFirst()
        await barrier.wait()
    }
}

private actor CursorProbeCommands {
    private(set) var commands: [String] = []
    private(set) var timeouts: [TimeInterval] = []

    func record(_ command: String, timeout: TimeInterval? = nil) {
        commands.append(command)
        if let timeout {
            timeouts.append(timeout)
        }
    }
}

private final class CursorDiscoveryClock: @unchecked Sendable {
    private let lock = NSLock()
    private let lookupMarker: URL
    private var elapsedProbeTime: TimeInterval = 0

    init(lookupMarker: URL) {
        self.lookupMarker = lookupMarker
    }

    func advance(by duration: TimeInterval) {
        lock.lock()
        elapsedProbeTime += duration
        lock.unlock()
    }

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return elapsedProbeTime + (FileManager.default.fileExists(atPath: lookupMarker.path) ? 20 : 0)
    }
}

// Cross-provider final launch-boundary witnesses share the existing launch test import seam.

/// Test-local assembly supplies explicit collaborators; it is not an application composition root.
private func makeTestResolver(
    environmentProvider: @escaping @Sendable (Bool) async -> [String: String],
    supplementalPathProvider: @escaping CursorACPLaunchResolver.SupplementalPathProvider,
    probeRunner: CursorACPLaunchResolver.ProbeRunner? = nil,
    environmentFilter: @escaping CLIProcessConfiguration.EnvironmentFilter = { environment, _ in environment },
    failureRecorder: @escaping CursorACPLaunchResolver.FailureRecorder = { _, _ in },
    nowProvider: @escaping CursorACPLaunchResolver.NowProvider = { ProcessInfo.processInfo.systemUptime },
    deadlineWaiter: @escaping CursorACPLaunchResolver.DeadlineWaiter = CursorACPLaunchResolver.defaultDeadlineWaiter,
    aggregateProbeTimeout: TimeInterval = 10,
    sharingProbeOwnershipWith shared: CursorACPLaunchResolver? = nil
) -> CursorACPLaunchResolver {
    makeTestResolver(
        launchEnvironmentProvider: { await ACPLaunchEnvironment(environment: environmentProvider($0)) },
        supplementalPathProvider: supplementalPathProvider,
        probeRunner: probeRunner,
        environmentFilter: environmentFilter,
        failureRecorder: failureRecorder,
        nowProvider: nowProvider,
        deadlineWaiter: deadlineWaiter,
        aggregateProbeTimeout: aggregateProbeTimeout,
        sharingProbeOwnershipWith: shared
    )
}

private func makeTestResolver(
    launchEnvironmentProvider: @escaping CursorACPLaunchResolver.EnvironmentProvider,
    supplementalPathProvider: @escaping CursorACPLaunchResolver.SupplementalPathProvider,
    probeRunner: CursorACPLaunchResolver.ProbeRunner? = nil,
    environmentFilter: @escaping CLIProcessConfiguration.EnvironmentFilter = { environment, _ in environment },
    failureRecorder: @escaping CursorACPLaunchResolver.FailureRecorder = { _, _ in },
    nowProvider: @escaping CursorACPLaunchResolver.NowProvider = { ProcessInfo.processInfo.systemUptime },
    deadlineWaiter: @escaping CursorACPLaunchResolver.DeadlineWaiter = CursorACPLaunchResolver.defaultDeadlineWaiter,
    aggregateProbeTimeout: TimeInterval = 10,
    sharingProbeOwnershipWith shared: CursorACPLaunchResolver? = nil
) -> CursorACPLaunchResolver {
    let runner: CursorACPLaunchResolver.ProbeRunner = probeRunner ?? { launch, config, timeout, cleanup in
        try await CursorACPLaunchResolver.runProbe(
            launch: launch, config: config, timeout: timeout,
            timeoutCleanupPolicy: cleanup, environmentFilter: environmentFilter
        )
    }
    if let shared {
        return CursorACPLaunchResolver(
            launchEnvironmentProvider: launchEnvironmentProvider, supplementalPathProvider: supplementalPathProvider,
            probeRunner: runner, failureRecorder: failureRecorder, nowProvider: nowProvider,
            deadlineWaiter: deadlineWaiter, aggregateProbeTimeout: aggregateProbeTimeout,
            sharingProbeOwnershipWith: shared
        )
    }
    return CursorACPLaunchResolver(
        launchEnvironmentProvider: launchEnvironmentProvider, supplementalPathProvider: supplementalPathProvider,
        probeRunner: runner, failureRecorder: failureRecorder, nowProvider: nowProvider,
        deadlineWaiter: deadlineWaiter, aggregateProbeTimeout: aggregateProbeTimeout
    )
}

private extension XCTestCase {
    func makeOwnerTestDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CursorACPResolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
