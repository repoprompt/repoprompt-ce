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
        XCTAssertEqual(runtime.version, .init(major: 0, minor: 149, patch: 0))
        XCTAssertEqual(runtime.source, .bundled(target: "aarch64-apple-darwin"))
        XCTAssertTrue(runtime.statePaths.codexHome.path.hasPrefix(support.path))
        XCTAssertTrue(runtime.statePaths.sqliteHome.path.hasPrefix(support.path))
        XCTAssertNotEqual(runtime.statePaths.codexHome.path, ("~/.codex" as NSString).expandingTildeInPath)
        XCTAssertEqual(runtime.statePaths.environment["CODEX_HOME"], runtime.statePaths.codexHome.path)
        XCTAssertEqual(runtime.statePaths.environment["CODEX_SQLITE_HOME"], runtime.statePaths.sqliteHome.path)
        try runtime.prepareState(
            ordinaryCodexHomeURL: temporaryDirectory.appendingPathComponent("empty-ordinary-home")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.statePaths.codexHome.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.statePaths.sqliteHome.path))
        XCTAssertTrue(runtime.redactedDiagnosticSummary.contains("provenance=bundled:aarch64-apple-darwin"))
        XCTAssertTrue(runtime.redactedDiagnosticSummary.contains("version=0.149.0"))
        XCTAssertFalse(runtime.redactedDiagnosticSummary.contains(temporaryDirectory.path))
    }

    func testRuntimePrepareStateProjectsGlobalInstructionsIntoManagedCodexHome() throws {
        let resources = temporaryDirectory.appendingPathComponent("Resources", isDirectory: true)
        let support = temporaryDirectory.appendingPathComponent("Support", isDirectory: true)
        let ordinaryHome = temporaryDirectory.appendingPathComponent("ordinary", isDirectory: true)
        try FileManager.default.createDirectory(at: ordinaryHome, withIntermediateDirectories: true)
        try Data().write(to: ordinaryHome.appendingPathComponent("AGENTS.override.md"))
        try Data("global".utf8).write(to: ordinaryHome.appendingPathComponent("AGENTS.md"))
        _ = try makePackage(in: resources, target: "aarch64-apple-darwin")

        let runtime = try CodexRuntimeAuthority.resolve(
            resourcesURL: resources,
            architectureTarget: "aarch64-apple-darwin",
            applicationSupportURL: support
        ).get()

        try runtime.prepareState(ordinaryCodexHomeURL: ordinaryHome)

        XCTAssertEqual(
            try Data(contentsOf: runtime.statePaths.codexHome.appendingPathComponent("AGENTS.override.md")),
            Data()
        )
        XCTAssertEqual(
            try Data(contentsOf: runtime.statePaths.codexHome.appendingPathComponent("AGENTS.md")),
            Data("global".utf8)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: runtime.statePaths.codexHome.appendingPathComponent(".repoprompt-agents-projection.json").path
            )
        )
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

    func testVersionParserRejectsMalformedTokensAndInvalidNumericPrereleaseIdentifiers() {
        XCTAssertNil(CodexRuntimeAuthority.Version.parse("codex-cli 0.149.0.1"))
        XCTAssertNil(CodexRuntimeAuthority.Version.parse("codex-cli 0.149.0-rc.01"))
        XCTAssertEqual(
            CodexRuntimeAuthority.Version.parse("codex-cli 0.149.0-rc.1"),
            .init(major: 0, minor: 149, patch: 0, prerelease: "rc.1")
        )
    }

    func testExplicitExternalOverrideIsAbsoluteVersionGatedAndObservable() throws {
        let override = temporaryDirectory.appendingPathComponent("external/codex")
        try makeExecutable(at: override)

        let accepted = try CodexRuntimeAuthority.resolve(
            resourcesURL: nil,
            applicationSupportURL: temporaryDirectory,
            explicitExecutableOverride: override.path,
            externalVersionReader: { _ in "codex-cli 0.149.0" }
        ).get()
        XCTAssertEqual(accepted.source, .externalOverride)
        XCTAssertEqual(accepted.version, .init(major: 0, minor: 149, patch: 0))
        XCTAssertTrue(accepted.redactedDiagnosticSummary.contains("provenance=external-override:codex"))
        XCTAssertFalse(accepted.redactedDiagnosticSummary.contains(temporaryDirectory.path))

        let old = CodexRuntimeAuthority.resolve(
            resourcesURL: nil,
            applicationSupportURL: temporaryDirectory,
            explicitExecutableOverride: override.path,
            externalVersionReader: { _ in "codex-cli 0.144.6" }
        )
        XCTAssertEqual(
            failure(from: old),
            .externalOverrideTooOld(
                actual: .init(major: 0, minor: 144, patch: 6),
                minimum: .init(major: 0, minor: 149, patch: 0)
            )
        )

        let prerelease = CodexRuntimeAuthority.resolve(
            resourcesURL: nil,
            applicationSupportURL: temporaryDirectory,
            explicitExecutableOverride: override.path,
            externalVersionReader: { _ in "codex-cli 0.149.0-rc.1" }
        )
        XCTAssertEqual(
            failure(from: prerelease),
            .externalOverrideTooOld(
                actual: .init(major: 0, minor: 149, patch: 0, prerelease: "rc.1"),
                minimum: .init(major: 0, minor: 149, patch: 0)
            )
        )

        XCTAssertEqual(
            failure(
                from: CodexRuntimeAuthority.resolve(
                    resourcesURL: nil,
                    applicationSupportURL: temporaryDirectory,
                    explicitExecutableOverride: "codex",
                    externalVersionReader: { _ in "codex-cli 0.149.0" }
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
                    externalVersionReader: { _ in "codex-cli 0.149.0" }
                )
            ),
            .externalOverrideMissing(missing.path)
        )
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
            externalVersionReader: { _ in "codex 0.149.0" }
        ).get()

        XCTAssertEqual(runtime.executableURL, override)
        XCTAssertEqual(runtime.source, .externalOverride)
    }

    func testConfiguredRuntimePrefersAndClearsPersistedExecutable() throws {
        let suiteName = "CodexRuntimePreferencesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let selected = temporaryDirectory.appendingPathComponent("selected/codex")
        let environment = temporaryDirectory.appendingPathComponent("environment/codex")
        try makeExecutable(at: selected)
        try makeExecutable(at: environment)

        CodexRuntimePreferences.setSelection(.external(path: "   "), defaults: defaults)
        XCTAssertEqual(CodexRuntimePreferences.selection(defaults: defaults), .inherited)
        CodexRuntimePreferences.setSelection(.external(path: "  \(selected.path)  "), defaults: defaults)

        let configured = try CodexRuntimeAuthority.resolveConfigured(
            environment: [CodexRuntimeAuthority.externalExecutableOverrideEnvironmentKey: environment.path],
            resourcesURL: nil,
            applicationSupportURL: temporaryDirectory,
            selection: CodexRuntimePreferences.selection(defaults: defaults),
            externalVersionReader: { _ in "codex 0.153.3" }
        ).get()
        XCTAssertEqual(configured.executableURL, selected)

        CodexRuntimePreferences.setSelection(.bundled, defaults: defaults)
        let resources = temporaryDirectory.appendingPathComponent("Resources", isDirectory: true)
        let bundledExecutable = try makePackage(in: resources, target: "aarch64-apple-darwin")
        let bundled = try CodexRuntimeAuthority.resolveConfigured(
            environment: [CodexRuntimeAuthority.externalExecutableOverrideEnvironmentKey: environment.path],
            resourcesURL: resources,
            architectureTarget: "aarch64-apple-darwin",
            applicationSupportURL: temporaryDirectory,
            selection: CodexRuntimePreferences.selection(defaults: defaults),
            externalVersionReader: { _ in "codex 0.153.3" }
        ).get()
        XCTAssertEqual(bundled.executableURL, bundledExecutable)

        CodexRuntimePreferences.setSelection(.inherited, defaults: defaults)
        let fallback = try CodexRuntimeAuthority.resolveConfigured(
            environment: [CodexRuntimeAuthority.externalExecutableOverrideEnvironmentKey: environment.path],
            resourcesURL: nil,
            applicationSupportURL: temporaryDirectory,
            selection: CodexRuntimePreferences.selection(defaults: defaults),
            externalVersionReader: { _ in "codex 0.153.3" }
        ).get()
        XCTAssertEqual(fallback.executableURL, environment)
    }

    func testCodexPreflightUsesCapturedLoginShellOverrideInsteadOfInheritedAppEnvironment() async throws {
        let inheritedOverride = temporaryDirectory.appendingPathComponent("inherited/codex")
        let loginShellOverride = temporaryDirectory.appendingPathComponent("login-shell/codex")
        try makeExecutable(at: inheritedOverride, content: "#!/bin/sh\necho 'codex 0.142.0'\n")
        try makeExecutable(at: loginShellOverride, content: "#!/bin/sh\necho 'codex 0.149.0'\n")

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
        XCTAssertEqual(resolution.runtime?.version, .init(major: 0, minor: 149, patch: 0))
        XCTAssertEqual(resolution.displayDescription, "Local Codex 0.149.0 (codex)")
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

    func testSettingsPreflightPreservesVersionManagerSymlinkAndRejectsOldSystemCodex() async throws {
        let bin = temporaryDirectory.appendingPathComponent("bin", isDirectory: true)
        let shim = bin.appendingPathComponent("volta-shim")
        let codex = bin.appendingPathComponent("codex")
        try makeExecutable(
            at: shim,
            content: "#!/bin/sh\n[ \"${0##*/}\" = codex ] || exit 126\necho 'codex-cli 0.153.3'\n"
        )
        try FileManager.default.createSymbolicLink(at: codex, withDestinationURL: shim)

        let temporaryPath = temporaryDirectory.path
        let shellEnvironmentProvider: ProcessEnvironmentBuilder.ShellEnvironmentProvider = { _, _ in
            CLIEnvironmentSnapshot(
                environment: ["HOME": temporaryPath, "PATH": bin.path],
                source: .capturedLoginShell
            )
        }
        let accepted = await CodexProviderHelpers.preflightCodexRuntimeSettings(
            inheritedEnvironment: ["HOME": temporaryPath],
            shellEnvironmentProvider: shellEnvironmentProvider
        )

        XCTAssertEqual(accepted.systemCandidate?.resolvedCommand, codex.path)
        XCTAssertEqual(accepted.systemCandidate?.runtime?.executableURL.path, codex.path)
        XCTAssertEqual(accepted.systemCandidate?.runtime?.source, .externalOverride)
        XCTAssertEqual(accepted.systemCandidate?.runtime?.version, .init(major: 0, minor: 153, patch: 3))

        let oldShim = bin.appendingPathComponent("volta-shim-old")
        try makeExecutable(
            at: oldShim,
            content: "#!/bin/sh\n[ \"${0##*/}\" = codex ] || exit 126\necho 'codex-cli 0.142.0 (too old)'\n"
        )
        try FileManager.default.removeItem(at: codex)
        try FileManager.default.createSymbolicLink(at: codex, withDestinationURL: oldShim)
        let rejected = await CodexProviderHelpers.preflightCodexRuntimeSettings(
            inheritedEnvironment: ["HOME": temporaryPath],
            shellEnvironmentProvider: shellEnvironmentProvider
        )

        XCTAssertNil(rejected.systemCandidate)
    }

    func testExternalVersionProbeUsesEnvironmentAndSeparatesCachedResults() throws {
        let bin = temporaryDirectory.appendingPathComponent("interpreter-bin", isDirectory: true)
        let interpreter = bin.appendingPathComponent("rpce-test-codex-interpreter")
        let codex = temporaryDirectory.appendingPathComponent("launcher/codex")
        try makeExecutable(at: interpreter, content: "#!/bin/sh\necho codex-cli 0.153.3\n")
        try makeExecutable(at: codex, content: "#!/usr/bin/env rpce-test-codex-interpreter\n")
        let absentEnvironment = ["PATH": "/usr/bin:/bin"]
        let capturedEnvironment = ["PATH": bin.path + ":/usr/bin:/bin"]

        func resolve(_ environment: [String: String]) -> Result<CodexRuntimeAuthority.Runtime, CodexRuntimeAuthority.Failure> {
            CodexRuntimeAuthority.resolve(
                environment: environment,
                applicationSupportURL: temporaryDirectory,
                explicitExecutableOverride: codex.path
            )
        }

        XCTAssertEqual(failure(from: resolve(absentEnvironment)), .externalOverrideVersionUnreadable(codex.path))
        XCTAssertEqual(try resolve(capturedEnvironment).get().version, .init(major: 0, minor: 153, patch: 3))
        XCTAssertEqual(failure(from: resolve(absentEnvironment)), .externalOverrideVersionUnreadable(codex.path))
    }

    func testPendingSelectionDoesNotChangeRuntimeUntilNextProcess() throws {
        let original = CodexRuntimePreferences.selection()
        defer { CodexRuntimePreferences.setSelection(original) }
        let pending = temporaryDirectory.appendingPathComponent("pending/codex")
        try makeExecutable(at: pending)
        let active = CodexRuntimePreferences.activeSelection
        let before = CodexRuntimeAuthority.resolveConfigured(externalVersionReader: { _ in "codex-cli 0.153.3" })

        CodexRuntimePreferences.setSelection(.external(path: pending.path))

        XCTAssertEqual(CodexRuntimePreferences.selection(), .external(path: pending.path))
        XCTAssertEqual(CodexRuntimePreferences.activeSelection, active)
        XCTAssertEqual(
            CodexRuntimeAuthority.resolveConfigured(externalVersionReader: { _ in "codex-cli 0.153.3" }),
            before
        )
        let preview = try CodexRuntimeAuthority.resolveConfigured(
            selection: CodexRuntimePreferences.selection(),
            externalVersionReader: { _ in "codex-cli 0.153.3" }
        ).get()
        XCTAssertEqual(preview.executableURL.path, pending.path)
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
            "version": "0.149.0",
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
