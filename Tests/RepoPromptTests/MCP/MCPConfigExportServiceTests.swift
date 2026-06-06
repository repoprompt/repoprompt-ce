import Foundation
@testable import RepoPrompt
import RepoPromptShared
import XCTest

final class MCPConfigExportServiceTests: XCTestCase {
    func testStableWrapperConfigLivesUnderCEOwnedDirectory() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configDirectory = root.appendingPathComponent("RepoPrompt CE/MCP", isDirectory: true)
        let service = MCPConfigExportService(
            identity: .repoPromptCE(.debug),
            configDirectoryURL: configDirectory,
            renderServerConfig: { "{\"mcpServers\":{\"RepoPromptCE\":{\"command\":\"/tmp/repoprompt-mcp\"}}}" }
        )

        let url = try await service.prepareStableWrapperConfigFile()

        XCTAssertEqual(url, configDirectory.appendingPathComponent("discovery_debug.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(url.path.contains("Application Support/RepoPrompt/MCP"))
    }

    func testLaunchConfigsAreUniqueImmutableLeasesAndCleanupIsScoped() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = MCPConfigExportService(
            identity: .repoPromptCE(.release),
            configDirectoryURL: root.appendingPathComponent("MCP", isDirectory: true),
            renderServerConfig: { "{\"mcpServers\":{}}" }
        )

        let first = try await service.prepareLaunchConfig()
        let second = try await service.prepareLaunchConfig()
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertEqual(try String(contentsOf: first.url), try String(contentsOf: second.url))
        let attributes = try FileManager.default.attributesOfItem(atPath: first.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o400)

        first.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
        second.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.url.path))
    }

    func testLeaseNeverRemovesAReplacementAtItsPath() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = MCPConfigExportService(
            identity: .repoPromptCE(.debug),
            configDirectoryURL: root.appendingPathComponent("MCP", isDirectory: true),
            renderServerConfig: { "{\"mcpServers\":{}}" }
        )
        let lease = try await service.prepareLaunchConfig()
        try FileManager.default.removeItem(at: lease.url)
        try "replacement".write(to: lease.url, atomically: true, encoding: .utf8)

        lease.release()

        XCTAssertEqual(try String(contentsOf: lease.url), "replacement")
    }

    func testLeaseRetriesCleanupAfterTransientRemovalFailure() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        defer { try? FileManager.default.removeItem(at: root) }
        let configDirectory = root.appendingPathComponent("MCP", isDirectory: true)
        let service = MCPConfigExportService(
            identity: .repoPromptCE(.debug),
            configDirectoryURL: configDirectory,
            renderServerConfig: { "{\"mcpServers\":{}}" }
        )
        let lease = try await service.prepareLaunchConfig()
        let launchDirectory = lease.url.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: launchDirectory.path)

        lease.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.url.path))

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launchDirectory.path)
        lease.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.url.path))
    }

    func testStableConfigRejectsSymlinkedExistingPathComponent() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let redirectedDirectory = root.appendingPathComponent("redirected", isDirectory: true)
        try FileManager.default.createDirectory(at: redirectedDirectory, withIntermediateDirectories: false)
        let productDirectory = root.appendingPathComponent("RepoPrompt CE", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: productDirectory, withDestinationURL: redirectedDirectory)
        let configDirectory = productDirectory.appendingPathComponent("MCP", isDirectory: true)
        let service = MCPConfigExportService(
            identity: .repoPromptCE(.debug),
            configDirectoryURL: configDirectory,
            renderServerConfig: { "{\"mcpServers\":{}}" }
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await service.prepareStableWrapperConfigFile()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: redirectedDirectory.appendingPathComponent("MCP").path))
    }

    func testLaunchConfigRejectsSymlinkedLeaseDirectory() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configDirectory = root.appendingPathComponent("MCP", isDirectory: true)
        let redirectedDirectory = root.appendingPathComponent("redirected", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: redirectedDirectory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: configDirectory.appendingPathComponent("LaunchConfigs", isDirectory: true),
            withDestinationURL: redirectedDirectory
        )
        let service = MCPConfigExportService(
            identity: .repoPromptCE(.debug),
            configDirectoryURL: configDirectory,
            renderServerConfig: { "{\"mcpServers\":{}}" }
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await service.prepareLaunchConfig()
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: redirectedDirectory.path), [])
    }

    func testExistingConfigAndLeaseDirectoryComponentsAreRestrictedToOwnerOnly() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configDirectory = root.appendingPathComponent("MCP", isDirectory: true)
        let launchDirectory = configDirectory.appendingPathComponent("LaunchConfigs", isDirectory: true)
        try FileManager.default.createDirectory(at: launchDirectory, withIntermediateDirectories: true)
        for directory in [root, configDirectory, launchDirectory] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }
        let service = MCPConfigExportService(
            identity: .repoPromptCE(.release),
            configDirectoryURL: configDirectory,
            renderServerConfig: { "{\"mcpServers\":{}}" }
        )

        let lease = try await service.prepareLaunchConfig()
        defer { lease.release() }

        for directory in [root, configDirectory, launchDirectory] {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
    }

    func testEmptyConfigUsesSameUniqueLeaseLifecycle() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = MCPConfigExportService(
            identity: .repoPromptCE(.debug),
            configDirectoryURL: root.appendingPathComponent("MCP", isDirectory: true),
            renderServerConfig: { "unused" }
        )

        let first = try await service.prepareEmptyLaunchConfig()
        let second = try await service.prepareEmptyLaunchConfig()
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertTrue(try String(contentsOf: first.url).contains("\"mcpServers\": {}"))
        first.release()
        second.release()
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPConfigExportServiceTests-\(UUID().uuidString)", isDirectory: true)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
