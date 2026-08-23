import Foundation
import RepoPromptAuthorityAPI
import RepoPromptMCPAdapter
import RepoPromptRuntimeModel
import XCTest

@testable import RepoPromptMCPHeadlessExecutable
@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
@testable import RepoPromptHeadlessRuntime
final class HeadlessMCPLauncherIntegrationTests: XCTestCase {
    func testPrivateHelperExecutionComposesHostServingCapabilityThroughStateFreeAdapter() async throws {
        let serving = HeadlessHelperServingProbe()
        let binding = RepoPromptMCPBinding(
            sessionID: UUID(),
            actor: .init(userID: "helper-test", username: "helper-test", displayName: "Helper Test")
        )
        let host = HeadlessHelperHostProbe(serving: serving, binding: binding)

        try await RepoPromptMCPHeadlessBootstrap.run(host: host) { adapter, observedBinding, isRoot in
            XCTAssertEqual(observedBinding.sessionID, binding.sessionID)
            XCTAssertTrue(isRoot)
            let toolNames = try await adapter.advertisedToolNames(isRootSession: true)
            XCTAssertEqual(toolNames, ["app_settings"])
            let result = try await adapter.invoke(
                toolName: "app_settings",
                argumentsJSON: Data("{}".utf8),
                binding: observedBinding
            )
            XCTAssertEqual(String(decoding: result, as: UTF8.self), "{\"composed\":true}")
        }

        let invocationCount = await serving.invocationCount()
        let didShutdown = await host.didShutdown()
        XCTAssertEqual(invocationCount, 1)
        XCTAssertTrue(didShutdown)
    }

    func testPrivateHelperReusesItsPrivateSessionAcrossRestarts() async throws {
        let directory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(".build/rp-helper-restart-\(UUID().uuidString)", isDirectory: true)
        let workingDirectory = directory.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = [
            "REPOPROMPT_MCP_HEADLESS_PROFILE": "restart-test",
            "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": directory.path,
            "REPOPROMPT_MCP_WORKING_DIRS": workingDirectory.path
        ]

        let first = try await RepoPromptDirectHeadlessComposition.start(
            environment: environment,
            currentDirectory: workingDirectory
        )
        let firstSessionID = first.binding.sessionID
        await first.shutdown()

        let second = try await RepoPromptDirectHeadlessComposition.start(
            environment: environment,
            currentDirectory: workingDirectory
        )
        XCTAssertEqual(second.binding.sessionID, firstSessionID)
        await second.shutdown()
    }

    func testPrivateHelperPublishesContractAndRejectsStandaloneLaunch() throws {
        let helper = try helperExecutable()
        let contract = try run(helper, arguments: ["--print-launcher-contract-version"])
        XCTAssertEqual(contract.status, 0)
        XCTAssertEqual(contract.stdout, "1\n")
        XCTAssertEqual(contract.stderr, "")

        let standalone = try run(helper, arguments: [])
        XCTAssertEqual(standalone.status, 64)
        XCTAssertEqual(standalone.stdout, "")
        XCTAssertTrue(standalone.stderr.contains("incompatible or missing launcher contract"))

        let incompatible = try run(
            helper,
            arguments: ["--launcher-contract-version", "999"]
        )
        XCTAssertEqual(incompatible.status, 64)
        XCTAssertTrue(incompatible.stderr.contains("incompatible or missing launcher contract"))
    }

    private func helperExecutable() throws -> URL {
        var cursor = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        for _ in 0 ..< 8 {
            let candidate = cursor.appendingPathComponent("repoprompt-mcp-headless-runtime")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            cursor.deleteLastPathComponent()
        }
        throw XCTSkip("private helper product is not present beside the Server test bundle")
    }

    private func run(
        _ executable: URL,
        arguments: [String]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}

private actor HeadlessHelperServingProbe: RepoPromptMCPServing {
    private var invocations = 0

    func invocationCount() -> Int { invocations }

    func projectSnapshot(id _: UUID) async throws -> ProjectSnapshot {
        throw ServiceAPIError(code: .capabilityMissing, message: "unused")
    }

    func sessionSnapshot(id _: UUID) async throws -> SessionSnapshot {
        throw ServiceAPIError(code: .capabilityMissing, message: "unused")
    }

    func events(after _: ServiceCursor?, limit _: Int) async throws -> EventPage {
        throw ServiceAPIError(code: .capabilityMissing, message: "unused")
    }

    func advertisedToolNames(isRootSession _: Bool) async throws -> Set<String> { ["app_settings"] }

    func invoke(
        toolName: String,
        argumentsJSON _: Data,
        binding _: AuthorityMCPBinding
    ) async throws -> Data {
        XCTAssertEqual(toolName, "app_settings")
        invocations += 1
        return Data("{\"composed\":true}".utf8)
    }
}

private actor HeadlessHelperHostProbe: RepoPromptMCPHeadlessHosting {
    nonisolated let serving: any RepoPromptMCPServingCapability
    nonisolated let binding: RepoPromptMCPBinding
    nonisolated let isRootSession = true
    private var shutdownObserved = false

    init(serving: any RepoPromptMCPServingCapability, binding: RepoPromptMCPBinding) {
        self.serving = serving
        self.binding = binding
    }

    func shutdown() {
        shutdownObserved = true
    }

    func didShutdown() -> Bool { shutdownObserved }
}
