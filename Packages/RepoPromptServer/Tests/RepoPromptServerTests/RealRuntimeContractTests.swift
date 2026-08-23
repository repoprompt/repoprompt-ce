import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptHeadlessRuntime
import RepoPromptServiceProtocol
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
@testable import RepoPromptHeadlessRuntime
/// Opt-in contracts for the actual binaries and delegated cgroup available to
/// a developer host or CI runner. The deterministic protocol fixtures remain
/// in ProviderSupervisorTests; these checks deliberately exercise installed
/// provider transports rather than substituting shell fixtures.
final class RealRuntimeContractTests: XCTestCase {
    func testConfiguredRealProviderProtocolsPreflight() async throws {
        let environment = ProcessInfo.processInfo.environment
        let configured: [(String, ProviderKind)] = [
            ("REPOPROMPT_TEST_CODEX_EXECUTABLE", .codex),
            ("REPOPROMPT_TEST_CLAUDE_EXECUTABLE", .claudeCompatible),
            ("REPOPROMPT_TEST_OPENCODE_EXECUTABLE", .openCodeACP),
            ("REPOPROMPT_TEST_CURSOR_EXECUTABLE", .cursorACP),
            ("REPOPROMPT_TEST_HEADLESS_EXECUTABLE", .headlessAdapter),
            ("REPOPROMPT_TEST_MCP_EXECUTABLE", .mcp)
        ].compactMap { variable, kind in
            guard let path = environment[variable], !path.isEmpty else { return nil }
            return (path, kind)
        }
        guard !configured.isEmpty else {
            throw XCTSkip("Set one or more REPOPROMPT_TEST_*_EXECUTABLE variables to run real provider protocol preflights")
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = try ProviderCLIAdapter(
            configurations: configured.map { ProviderCLIConfiguration(kind: $0.1, executable: $0.0) },
            processPort: PortableProcessSupervisionPort(),
            outputDirectory: directory.appendingPathComponent("output").path,
            ephemeralHomeRoot: directory.appendingPathComponent("homes").path
        )

        let capabilities = await adapter.preflight()
        for (path, kind) in configured {
            let capability = try XCTUnwrap(capabilities.first { $0.kind == kind })
            XCTAssertTrue(capability.enabled, "\(kind.rawValue) failed real protocol preflight at \(path): \(capability.reasonUnavailable ?? "unknown failure")")
            XCTAssertNotNil(capability.version)
        }
    }

    #if os(Linux)
        func testDelegatedCgroupKillsTheProviderFamilyWhenAvailable() async throws {
            let environment = ProcessInfo.processInfo.environment
            guard let root = environment["REPOPROMPT_TEST_CGROUP_ROOT"], !root.isEmpty else {
                throw XCTSkip("Set REPOPROMPT_TEST_CGROUP_ROOT to a delegated cgroup v2 directory")
            }
            guard FileManager.default.fileExists(atPath: URL(fileURLWithPath: root).appendingPathComponent("cgroup.controllers").path) else {
                throw XCTSkip("Configured root is not a cgroup v2 delegation")
            }
            let shell = ["/bin/sh", "/usr/bin/sh"].first { FileManager.default.isExecutableFile(atPath: $0) }
            let executable = try XCTUnwrap(shell)
            let token = "contract-\(UUID().uuidString)"
            let port = try PortableProcessSupervisionPort(cgroupRoot: root)
            let supervisor = ProviderProcessSupervisor(processPort: port)
            let runID = UUID()
            let leader = try await port.launch(
                executable: executable,
                arguments: ["-c", "while :; do sleep 1; done"],
                environment: ["PATH": "/usr/bin:/bin"],
                workingDirectory: FileManager.default.temporaryDirectory.path,
                helperToken: token
            )
            try await supervisor.register(runID: runID, leader: leader)

            do {
                let cgroup = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("run-\(token)", isDirectory: true)
                let membership = try String(contentsOf: cgroup.appendingPathComponent("cgroup.procs"), encoding: .utf8)
                XCTAssertTrue(membership.split(whereSeparator: \.isWhitespace).contains(Substring(String(leader.pid))))
                guard FileManager.default.isWritableFile(atPath: cgroup.appendingPathComponent("cgroup.kill").path) else {
                    throw XCTSkip("Delegated cgroup does not expose writable cgroup.kill")
                }
                let terminated = try await port.terminateContainedFamily(leader: leader)
                XCTAssertTrue(terminated)
                for _ in 0 ..< 100 {
                    if try await port.inspect(pid: leader.pid) == nil { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                let remainingIdentity = try await port.inspect(pid: leader.pid)
                XCTAssertNil(remainingIdentity)
                try await port.reap(pid: leader.pid)
            } catch {
                try? await supervisor.cancel(runID: runID, graceScans: 5)
                throw error
            }
        }
    #endif
}
