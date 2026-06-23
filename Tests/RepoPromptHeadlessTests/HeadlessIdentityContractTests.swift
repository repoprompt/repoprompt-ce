import Foundation
@testable import RepoPromptHeadless
import XCTest

final class HeadlessIdentityContractTests: XCTestCase {
    func testDefaultStateRootUsesIsolatedHomeAndVersionOneNamespace() throws {
        let home = HeadlessTestTemporaryDirectory.baseURL
            .appendingPathComponent("rpce-headless-home-\(UUID().uuidString)", isDirectory: true)
        let paths = try HeadlessStatePaths.resolve(cliOverride: nil, environment: ["HOME": home.path])
        XCTAssertEqual(
            paths.rootDirectory,
            home
                .appendingPathComponent("Library/Application Support/RepoPrompt CE/Headless/v1", isDirectory: true)
        )
    }

    func testStateOverrideIsCompleteVersionRootAndRejectsRelativeFallback() throws {
        let root = HeadlessTestTemporaryDirectory.baseURL
            .appendingPathComponent("rpce-headless-state-v1-\(UUID().uuidString)", isDirectory: true)
        let paths = try HeadlessStatePaths.resolve(
            cliOverride: root.path,
            environment: ["HOME": HeadlessTestTemporaryDirectory.baseURL.path]
        )
        XCTAssertEqual(paths.rootDirectory, root)
        XCTAssertThrowsError(try HeadlessStatePaths.resolve(
            cliOverride: "relative-state",
            environment: ["HOME": HeadlessTestTemporaryDirectory.baseURL.path]
        ))
    }

    func testVersionAndSecureStorageNamespaceMatchFrozenReleaseIdentity() throws {
        let metadata = try String(
            contentsOf: HeadlessTestRepoRoot.url().appendingPathComponent("version.env"),
            encoding: .utf8
        )
        XCTAssertTrue(metadata.contains("MARKETING_VERSION=\(HeadlessVersion.marketingVersion)"))
        XCTAssertTrue(metadata.contains("BUILD_NUMBER=\(HeadlessVersion.buildNumber)"))
        XCTAssertEqual(HeadlessVersion.mcpProtocolVersion, "2024-11-05")
        XCTAssertEqual(HeadlessVersion.displayName, "RepoPrompt Headless")
        XCTAssertEqual(HeadlessSecureStorage.namespace, "com.pvncher.repoprompt.ce.headless.keychain")
        XCTAssertEqual(HeadlessSecureStorage.makeService().serviceName, HeadlessSecureStorage.namespace)
    }
}
