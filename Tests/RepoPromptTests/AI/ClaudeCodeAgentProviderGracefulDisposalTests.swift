import Foundation
@testable import RepoPromptApp
import XCTest

final class ClaudeCodeAgentProviderGracefulDisposalTests: XCTestCase {
    func testDisposeWaitsForExactStreamCleanupAndReleasesOnlyOwnedLease() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCodeAgentProviderGracefulDisposalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = root.appendingPathComponent("claude-stub")
        try """
        #!/bin/sh
        printf '%s\\n' '{"type":"system","subtype":"init"}'
        trap '' TERM
        sleep 600
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let configDirectory = root.appendingPathComponent("MCP", isDirectory: true)
        let configService = MCPConfigExportService(
            identity: .repoPromptCE(.debug),
            configDirectoryURL: configDirectory,
            renderServerConfig: { "{\"mcpServers\":{}}" }
        )
        let stableConfig = try await configService.prepareStableWrapperConfigFile()
        let siblingLease = try await configService.prepareLaunchConfig()
        defer { siblingLease.release() }

        let cleanupGate = AsyncTestGate()
        let processStarted = AsyncTestSignal()
        let runner = CLIProcessRunner(config: CLIProcessConfiguration(
            command: executable.path,
            workingDirectory: root.path,
            environment: ProcessInfo.processInfo.environment,
            additionalPaths: [],
            shellLookupMode: .disabled
        ))
        let provider = ClaudeCodeAgentProvider(
            runner: runner,
            config: .discovery(commandName: executable.path),
            configService: configService,
            serverReadiness: { true },
            processStarted: { _ in await processStarted.signal() },
            cleanupStarted: { await cleanupGate.wait() }
        )

        let stream = try await provider.streamAgentMessage(AgentMessage(userMessage: "test"), runID: UUID())
        let consumer = Task {
            do {
                for try await _ in stream {}
            } catch {}
        }
        await processStarted.wait()

        let launchDirectory = configDirectory.appendingPathComponent("LaunchConfigs", isDirectory: true)
        let launchFilesBeforeDispose = try FileManager.default.contentsOfDirectory(at: launchDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(launchFilesBeforeDispose.count, 2)

        let disposeFinished = AsyncTestFlag()
        let disposal = Task {
            await provider.dispose()
            await disposeFinished.set()
        }
        await cleanupGate.waitUntilEntered()

        let didDisposeBeforeCleanup = await disposeFinished.value
        XCTAssertFalse(didDisposeBeforeCleanup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stableConfig.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingLease.url.path))

        await cleanupGate.open()
        await disposal.value
        await consumer.value

        let didDisposeAfterCleanup = await disposeFinished.value
        XCTAssertTrue(didDisposeAfterCleanup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stableConfig.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingLease.url.path))
        let launchFilesAfterDispose = try FileManager.default.contentsOfDirectory(at: launchDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(launchFilesAfterDispose.count, 1)
        XCTAssertEqual(launchFilesAfterDispose.first?.lastPathComponent, siblingLease.url.lastPathComponent)
    }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let waitingForEntry = entryWaiters
        entryWaiters.removeAll()
        waitingForEntry.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor AsyncTestSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !signaled else { return }
        signaled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor AsyncTestFlag {
    private(set) var value = false

    func set() {
        value = true
    }
}
