import Foundation
@testable import RepoPromptApp
import XCTest

final class CodexRuntimeAuthorityTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexRuntimeAuthorityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testBundledRuntimeResolvesRequestedArchitectureAndOwnedState() throws {
        let resources = temporaryDirectory.appendingPathComponent("Resources", isDirectory: true)
        let support = temporaryDirectory.appendingPathComponent("Support", isDirectory: true)
        let armExecutable = try makePackage(in: resources, target: "aarch64-apple-darwin")
        _ = try makePackage(in: resources, target: "x86_64-apple-darwin")

        let runtime = try CodexRuntimeAuthority.resolve(
            environment: ["PATH": "/tmp/untrusted-path"],
            resourcesURL: resources,
            architectureTarget: "aarch64-apple-darwin",
            applicationSupportURL: support
        ).get()

        XCTAssertEqual(runtime.executableURL, armExecutable)
        XCTAssertEqual(runtime.version, .init(major: 0, minor: 144, patch: 6))
        XCTAssertEqual(runtime.source, .bundled(target: "aarch64-apple-darwin"))
        XCTAssertTrue(runtime.statePaths.codexHome.path.hasPrefix(support.path))
        XCTAssertTrue(runtime.statePaths.sqliteHome.path.hasPrefix(support.path))
        XCTAssertNotEqual(runtime.statePaths.codexHome.path, ("~/.codex" as NSString).expandingTildeInPath)
        XCTAssertEqual(runtime.statePaths.environment["CODEX_HOME"], runtime.statePaths.codexHome.path)
        XCTAssertEqual(runtime.statePaths.environment["CODEX_SQLITE_HOME"], runtime.statePaths.sqliteHome.path)
        try runtime.prepareState()
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.statePaths.codexHome.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.statePaths.sqliteHome.path))
        XCTAssertTrue(runtime.redactedDiagnosticSummary.contains("provenance=bundled:aarch64-apple-darwin"))
        XCTAssertTrue(runtime.redactedDiagnosticSummary.contains("version=0.144.6"))
        XCTAssertFalse(runtime.redactedDiagnosticSummary.contains(temporaryDirectory.path))
    }

    func testBundledRuntimeResolvesIntelPackageIndependently() throws {
        let resources = temporaryDirectory.appendingPathComponent("Resources", isDirectory: true)
        _ = try makePackage(in: resources, target: "aarch64-apple-darwin")
        let intelExecutable = try makePackage(in: resources, target: "x86_64-apple-darwin")

        let runtime = try CodexRuntimeAuthority.resolve(
            resourcesURL: resources,
            architectureTarget: "x86_64-apple-darwin",
            applicationSupportURL: temporaryDirectory
        ).get()

        XCTAssertEqual(runtime.executableURL, intelExecutable)
        XCTAssertEqual(runtime.source, .bundled(target: "x86_64-apple-darwin"))
    }

    func testMissingOrCorruptBundledRuntimeFailsClosedWithoutPATHFallback() throws {
        let resources = temporaryDirectory.appendingPathComponent("Resources", isDirectory: true)
        XCTAssertEqual(
            failure(
                from: CodexRuntimeAuthority.resolve(
                    environment: ["PATH": "/usr/local/bin:/opt/homebrew/bin"],
                    resourcesURL: resources,
                    architectureTarget: "aarch64-apple-darwin",
                    applicationSupportURL: temporaryDirectory
                )
            ),
            .bundledPackageMissing(target: "aarch64-apple-darwin")
        )

        let executable = try makePackage(in: resources, target: "aarch64-apple-darwin")
        let packageRoot = executable.deletingLastPathComponent().deletingLastPathComponent()
        try Data("{not-json".utf8).write(to: packageRoot.appendingPathComponent("codex-package.json"))
        XCTAssertEqual(
            failure(
                from: CodexRuntimeAuthority.resolve(
                    resourcesURL: resources,
                    architectureTarget: "aarch64-apple-darwin",
                    applicationSupportURL: temporaryDirectory
                )
            ),
            .bundledMetadataUnreadable(target: "aarch64-apple-darwin")
        )
    }

    func testExplicitExternalOverrideIsAbsoluteVersionGatedAndObservable() async throws {
        let override = temporaryDirectory.appendingPathComponent("external/codex")
        try makeExecutable(at: override)

        let accepted = try CodexRuntimeAuthority.resolve(
            resourcesURL: nil,
            applicationSupportURL: temporaryDirectory,
            explicitExecutableOverride: override.path,
            externalVersionReader: { _ in "codex-cli 0.144.6" }
        ).get()
        XCTAssertEqual(accepted.source, .externalOverride)
        XCTAssertEqual(accepted.version, .init(major: 0, minor: 144, patch: 6))
        XCTAssertTrue(accepted.redactedDiagnosticSummary.contains("provenance=external-override:codex"))
        XCTAssertFalse(accepted.redactedDiagnosticSummary.contains(temporaryDirectory.path))

        let old = CodexRuntimeAuthority.resolve(
            resourcesURL: nil,
            applicationSupportURL: temporaryDirectory,
            explicitExecutableOverride: override.path,
            externalVersionReader: { _ in "codex-cli 0.144.5" }
        )
        XCTAssertEqual(
            failure(from: old),
            .externalOverrideTooOld(
                actual: .init(major: 0, minor: 144, patch: 5),
                minimum: .init(major: 0, minor: 144, patch: 6)
            )
        )

        XCTAssertEqual(
            failure(
                from: CodexRuntimeAuthority.resolve(
                    resourcesURL: nil,
                    applicationSupportURL: temporaryDirectory,
                    explicitExecutableOverride: "codex",
                    externalVersionReader: { _ in "codex-cli 0.144.6" }
                )
            ),
            .externalOverrideMustBeAbsolute
        )

        let missing = temporaryDirectory.appendingPathComponent("external/missing-codex")
        XCTAssertEqual(
            failure(
                from: CodexRuntimeAuthority.resolve(
                    resourcesURL: nil,
                    applicationSupportURL: temporaryDirectory,
                    explicitExecutableOverride: missing.path,
                    externalVersionReader: { _ in "codex-cli 0.144.6" }
                )
            ),
            .externalOverrideMissing(missing.path)
        )

        let counter = temporaryDirectory.appendingPathComponent("external/version-probes")
        let cachedOverride = temporaryDirectory.appendingPathComponent("external/cached-codex")
        try makeExecutable(
            at: cachedOverride,
            content: "#!/bin/sh\necho probe >> \(counter.path)\necho 'codex 0.144.6'\n"
        )
        for _ in 0 ..< 2 {
            _ = try CodexRuntimeAuthority.resolve(
                resourcesURL: nil,
                applicationSupportURL: temporaryDirectory,
                explicitExecutableOverride: cachedOverride.path
            ).get()
        }
        let probes = try String(contentsOf: counter, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(probes.count, 1)

        let slowProbeStarted = temporaryDirectory.appendingPathComponent("external/slow-probe-started")
        let slowOverride = temporaryDirectory.appendingPathComponent("external/slow-codex")
        try makeExecutable(
            at: slowOverride,
            content: "#!/bin/sh\necho started > \(slowProbeStarted.path)\nsleep 2\necho 'not-a-version'\n"
        )
        let fastOverride = temporaryDirectory.appendingPathComponent("external/fast-codex")
        try makeExecutable(at: fastOverride, content: "#!/bin/sh\necho 'codex 0.144.6'\n")
        let supportURL = try XCTUnwrap(temporaryDirectory)
        let slowResolution = Task.detached {
            CodexRuntimeAuthority.resolve(
                resourcesURL: nil,
                applicationSupportURL: supportURL,
                explicitExecutableOverride: slowOverride.path
            )
        }
        for _ in 0 ..< 100 where !FileManager.default.fileExists(atPath: slowProbeStarted.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: slowProbeStarted.path))
        let fastProbeStarted = Date()
        _ = try CodexRuntimeAuthority.resolve(
            resourcesURL: nil,
            applicationSupportURL: temporaryDirectory,
            explicitExecutableOverride: fastOverride.path
        ).get()
        XCTAssertLessThan(Date().timeIntervalSince(fastProbeStarted), 1.25)
        let slowResult = await slowResolution.value
        XCTAssertEqual(
            failure(from: slowResult),
            .externalOverrideVersionUnreadable(slowOverride.path)
        )

        let invalidCounter = temporaryDirectory.appendingPathComponent("external/invalid-version-probes")
        let invalidOverride = temporaryDirectory.appendingPathComponent("external/invalid-codex")
        try makeExecutable(
            at: invalidOverride,
            content: "#!/bin/sh\necho probe >> \(invalidCounter.path)\necho 'not-a-version'\n"
        )
        for _ in 0 ..< 2 {
            XCTAssertEqual(
                failure(
                    from: CodexRuntimeAuthority.resolve(
                        resourcesURL: nil,
                        applicationSupportURL: temporaryDirectory,
                        explicitExecutableOverride: invalidOverride.path
                    )
                ),
                .externalOverrideVersionUnreadable(invalidOverride.path)
            )
        }
        let invalidProbes = try String(contentsOf: invalidCounter, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(invalidProbes.count, 1)
    }

    func testOverrideEnvironmentIsTheOnlyFallbackWhenBundleIsMissing() throws {
        let override = temporaryDirectory.appendingPathComponent("external/codex")
        try makeExecutable(at: override)

        let runtime = try CodexRuntimeAuthority.resolve(
            environment: [
                "PATH": "/tmp/arbitrary",
                CodexRuntimeAuthority.externalExecutableOverrideEnvironmentKey: override.path
            ],
            resourcesURL: nil,
            applicationSupportURL: temporaryDirectory,
            externalVersionReader: { _ in "codex 0.144.6" }
        ).get()

        XCTAssertEqual(runtime.executableURL, override)
        XCTAssertEqual(runtime.source, .externalOverride)
    }

    func testCodexPreflightUsesCapturedLoginShellOverrideInsteadOfInheritedAppEnvironment() async throws {
        let inheritedOverride = temporaryDirectory.appendingPathComponent("inherited/codex")
        let loginShellOverride = temporaryDirectory.appendingPathComponent("login-shell/codex")
        try makeExecutable(at: inheritedOverride, content: "#!/bin/sh\necho 'codex 0.142.0'\n")
        try makeExecutable(at: loginShellOverride, content: "#!/bin/sh\necho 'codex 0.144.6'\n")

        let temporaryPath = temporaryDirectory.path
        let resolution = await CodexProviderHelpers.preflightCodexExecutable(
            inheritedEnvironment: [
                "HOME": temporaryPath,
                CodexRuntimeAuthority.externalExecutableOverrideEnvironmentKey: inheritedOverride.path
            ],
            shellEnvironmentProvider: { _, _ in
                CLIEnvironmentSnapshot(
                    environment: [
                        "HOME": temporaryPath,
                        CodexRuntimeAuthority.externalExecutableOverrideEnvironmentKey: loginShellOverride.path
                    ],
                    source: .capturedLoginShell
                )
            }
        )

        XCTAssertEqual(resolution.status, .available)
        XCTAssertEqual(resolution.resolvedCommand, loginShellOverride.path)
        XCTAssertEqual(resolution.runtime?.source, .externalOverride)
        XCTAssertEqual(resolution.runtime?.version, .init(major: 0, minor: 144, patch: 6))
        XCTAssertEqual(resolution.displayDescription, "External Codex override 0.144.6 (codex)")
        XCTAssertFalse(resolution.displayDescription?.contains(temporaryDirectory.path) == true)

        let execProcessConfiguration = CodexExecAgentProvider.processConfiguration(
            for: resolution,
            enableDebugLogging: false
        )
        XCTAssertEqual(
            execProcessConfiguration.environment["CODEX_HOME"],
            resolution.runtime?.statePaths.codexHome.path
        )
        XCTAssertEqual(
            execProcessConfiguration.environment["CODEX_SQLITE_HOME"],
            resolution.runtime?.statePaths.sqliteHome.path
        )
    }

    func testManagedAuthGuidanceUsesRepoPromptOwnedLoginFlow() {
        let guidance = CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage

        XCTAssertTrue(guidance.contains("Login with ChatGPT"))
        XCTAssertFalse(guidance.localizedCaseInsensitiveContains("codex login"))
    }

    private func failure(
        from result: Result<CodexRuntimeAuthority.Runtime, CodexRuntimeAuthority.Failure>
    ) -> CodexRuntimeAuthority.Failure? {
        guard case let .failure(failure) = result else { return nil }
        return failure
    }

    @discardableResult
    private func makePackage(in resources: URL, target: String) throws -> URL {
        let root = resources
            .appendingPathComponent("BundledRuntimes/Codex", isDirectory: true)
            .appendingPathComponent(target, isDirectory: true)
        let executable = root.appendingPathComponent("bin/codex")
        try makeExecutable(at: executable)
        try makeExecutable(at: root.appendingPathComponent("bin/codex-code-mode-host"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("codex-resources", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("codex-path", isDirectory: true),
            withIntermediateDirectories: true
        )
        let metadata: [String: Any] = [
            "layoutVersion": 1,
            "version": "0.144.6",
            "target": target,
            "variant": "codex",
            "entrypoint": "bin/codex",
            "resourcesDir": "codex-resources",
            "pathDir": "codex-path"
        ]
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        try data.write(to: root.appendingPathComponent("codex-package.json"))
        return executable
    }

    private func makeExecutable(at url: URL, content: String = "#!/bin/sh\nexit 0\n") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(content.utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
