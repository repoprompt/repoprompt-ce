import Foundation
@testable import RepoPromptApp
import XCTest

final class CursorACPLaunchResolverTests: XCTestCase {
    func testProductionDefaultFallsBackToVerifiedAgentAlias() async throws {
        let rootDirectory = try makeTemporaryDirectory()
        let packageDirectory = rootDirectory.appendingPathComponent("cursor-package", isDirectory: true)
        let binDirectory = rootDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let cursorExecutable = try makeExecutable(named: "cursor-agent", in: packageDirectory)
        try FileManager.default.createSymbolicLink(
            at: binDirectory.appendingPathComponent("agent"),
            withDestinationURL: cursorExecutable
        )
        let resolver = makeResolver(path: binDirectory.path)
        let config = CursorAgentConfig(additionalPathHints: [], includeRepoPromptMCPServer: false)

        let support = try await resolver.probeSupport(for: config)
        let launch = try resolver.resolvedLaunch(for: config)

        XCTAssertEqual(support, .supported)
        XCTAssertEqual(launch.command, try canonicalExecutablePath(cursorExecutable))
    }

    func testProductionDefaultRejectsUnverifiedGenericAgentBeforeProbe() async throws {
        let directory = try makeTemporaryDirectory()
        let probeMarker = directory.appendingPathComponent("generic-agent-probed")
        _ = try makeExecutable(
            named: "agent",
            in: directory,
            marker: probeMarker,
            output: "Usage: agent acp\nStart the Cursor Agent as an ACP (Agent Client Protocol) server"
        )
        let resolver = makeResolver(path: directory.path)
        let config = CursorAgentConfig(additionalPathHints: [], includeRepoPromptMCPServer: false)

        let support = try await resolver.probeSupport(for: config)

        guard case .unsupported = support else {
            return XCTFail("Expected an unverified generic agent executable to be unsupported")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: probeMarker.path))
        XCTAssertThrowsError(try resolver.resolvedLaunch(for: config))
    }

    func testProductionDefaultRejectsCursorAgentSymlinkToGenericAgentBeforeProbe() async throws {
        let rootDirectory = try makeTemporaryDirectory()
        let packageDirectory = rootDirectory.appendingPathComponent("unrelated-package", isDirectory: true)
        let binDirectory = rootDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let probeMarker = rootDirectory.appendingPathComponent("generic-agent-probed")
        let genericAgent = try makeExecutable(
            named: "agent",
            in: packageDirectory,
            marker: probeMarker,
            output: "Usage: agent acp\nStart the Cursor Agent as an ACP (Agent Client Protocol) server"
        )
        try FileManager.default.createSymbolicLink(
            at: binDirectory.appendingPathComponent("cursor-agent"),
            withDestinationURL: genericAgent
        )
        let resolver = makeResolver(path: binDirectory.path)
        let config = CursorAgentConfig(additionalPathHints: [], includeRepoPromptMCPServer: false)

        let support = try await resolver.probeSupport(for: config)

        guard case .unsupported = support else {
            return XCTFail("Expected cursor-agent resolving to a generic agent executable to be unsupported")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: probeMarker.path))
        XCTAssertThrowsError(try resolver.resolvedLaunch(for: config))
    }

    func testProductionDefaultFallsThroughStaleCursorAgentToVerifiedAgentAlias() async throws {
        let rootDirectory = try makeTemporaryDirectory()
        let legacyDirectory = rootDirectory.appendingPathComponent("legacy", isDirectory: true)
        let currentDirectory = rootDirectory.appendingPathComponent("current", isDirectory: true)
        let binDirectory = rootDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let legacyProbeMarker = rootDirectory.appendingPathComponent("legacy-probed")
        let legacyExecutable = try makeExecutable(
            named: "cursor-agent",
            in: legacyDirectory,
            marker: legacyProbeMarker,
            output: "Usage: cursor-agent [OPTIONS]"
        )
        let currentExecutable = try makeExecutable(named: "cursor-agent", in: currentDirectory)
        try FileManager.default.createSymbolicLink(
            at: binDirectory.appendingPathComponent("cursor-agent"),
            withDestinationURL: legacyExecutable
        )
        try FileManager.default.createSymbolicLink(
            at: binDirectory.appendingPathComponent("agent"),
            withDestinationURL: currentExecutable
        )
        let resolver = makeResolver(path: binDirectory.path)
        let config = CursorAgentConfig(additionalPathHints: [])

        let support = try await resolver.probeSupport(for: config)
        let launch = try resolver.resolvedLaunch(for: config)

        XCTAssertEqual(support, .supported)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyProbeMarker.path))
        XCTAssertEqual(launch.command, try canonicalExecutablePath(currentExecutable))
    }

    func testCapabilityProbeRejectsTimedOutZeroStatusAndDoesNotCacheLaunch() async throws {
        let directory = try makeTemporaryDirectory()
        _ = try makeExecutable(named: "cursor-agent", in: directory)
        let resolver = CursorACPLaunchResolver(
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

        let support = try await resolver.probeSupport(for: config)

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
        let timeline = CursorProbeTimeline(nowValues: [0, 1, 10])
        let resolver = CursorACPLaunchResolver(
            environmentProvider: { _ in ["PATH": binDirectory.path, "SHELL": "/bin/false"] },
            supplementalPathProvider: { $0 },
            probeRunner: { _, _, timeout, timeoutCleanupPolicy in
                timeline.record(timeout: timeout, cleanupAllowance: timeoutCleanupPolicy.maximumDuration)
                return CLIProcessRunner.Result(stdout: Data(), stderr: Data(), status: 2, timedOut: false)
            },
            nowProvider: { timeline.nextNow() },
            aggregateProbeTimeout: 10
        )

        let support = try await resolver.probeSupport(for: CursorAgentConfig(additionalPathHints: []))

        guard case .unsupported = support else {
            return XCTFail("Expected aggregate deadline exhaustion to be unsupported")
        }
        XCTAssertEqual(timeline.recordedTimeouts(), [6])
        XCTAssertEqual(timeline.recordedCleanupAllowances(), [3])
    }

    private func makeResolver(path: String) -> CursorACPLaunchResolver {
        CursorACPLaunchResolver(
            environmentProvider: { _ in ["PATH": path, "SHELL": "/bin/false"] },
            supplementalPathProvider: { $0 }
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        try makeTestDirectory(name: "CursorACPLaunchResolverTests")
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
