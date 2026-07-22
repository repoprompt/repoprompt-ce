import Foundation

/// The single source of truth for RepoPrompt-managed Codex runtime selection and state.
///
/// Production defaults to the verified bundled package for the running architecture. The
/// only user-configurable external fallback is an absolute path supplied through
/// `REPOPROMPT_CODEX_EXECUTABLE`; ordinary PATH lookup is intentionally not consulted.
enum CodexRuntimeAuthority {
    static let bundledVersion = Version(major: 0, minor: 144, patch: 6)
    static let minimumExternalVersion = Version(major: 0, minor: 142, patch: 0)
    static let externalExecutableOverrideEnvironmentKey = "REPOPROMPT_CODEX_EXECUTABLE"

    enum Source: Equatable {
        case bundled(target: String)
        case externalOverride
    }

    struct StatePaths: Equatable {
        let codexHome: URL
        let sqliteHome: URL

        var environment: [String: String] {
            [
                "CODEX_HOME": codexHome.path,
                "CODEX_SQLITE_HOME": sqliteHome.path
            ]
        }
    }

    struct Runtime: Equatable {
        let executableURL: URL
        let version: Version
        let source: Source
        let statePaths: StatePaths

        func prepareState(fileManager: FileManager = .default) throws {
            try fileManager.createDirectory(at: statePaths.codexHome, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: statePaths.sqliteHome, withIntermediateDirectories: true)
        }

        var redactedDiagnosticSummary: String {
            let provenance = switch source {
            case let .bundled(target):
                "bundled:\(target)"
            case .externalOverride:
                "external-override:\(executableURL.lastPathComponent)"
            }
            return "Codex runtime authority: provenance=\(provenance), version=\(version), state=\(CodexRuntimeAuthority.redactedStateDescription(statePaths))"
        }
    }

    enum Failure: Error, Equatable, LocalizedError {
        case unsupportedArchitecture(String)
        case bundledResourcesUnavailable
        case bundledPackageMissing(target: String)
        case bundledMetadataUnreadable(target: String)
        case bundledMetadataMismatch(expectedTarget: String, actualTarget: String?, actualVersion: String?)
        case bundledLayoutIncomplete(target: String, missingComponent: String)
        case externalOverrideMustBeAbsolute
        case externalOverrideMissing(String)
        case externalOverrideNotExecutable(String)
        case externalOverrideVersionUnreadable(String)
        case externalOverrideTooOld(actual: Version, minimum: Version)

        var errorDescription: String? {
            switch self {
            case let .unsupportedArchitecture(architecture):
                "RepoPrompt could not start Codex: architecture `\(architecture)` is unsupported. Supported macOS architectures are arm64 and x86_64."
            case .bundledResourcesUnavailable:
                "RepoPrompt could not start Codex: the app's bundled runtime resources are unavailable. Reinstall RepoPrompt CE."
            case let .bundledPackageMissing(target):
                "RepoPrompt could not start Codex: the bundled \(target) package is missing. Reinstall RepoPrompt CE; RepoPrompt will not fall back to PATH."
            case let .bundledMetadataUnreadable(target):
                "RepoPrompt could not start Codex: the bundled \(target) package metadata is missing or corrupt. Reinstall RepoPrompt CE; RepoPrompt will not fall back to PATH."
            case let .bundledMetadataMismatch(expectedTarget, actualTarget, actualVersion):
                "RepoPrompt could not start Codex: bundled package identity mismatch (expected target \(expectedTarget), version \(bundledVersion); found target \(actualTarget ?? "unknown"), version \(actualVersion ?? "unknown")). Reinstall RepoPrompt CE."
            case let .bundledLayoutIncomplete(target, component):
                "RepoPrompt could not start Codex: the bundled \(target) package is incomplete at `\(component)`. Reinstall RepoPrompt CE."
            case .externalOverrideMustBeAbsolute:
                "RepoPrompt could not start Codex: \(externalExecutableOverrideEnvironmentKey) must be an absolute executable path. PATH lookup is not used."
            case let .externalOverrideMissing(path):
                "RepoPrompt could not start Codex: the configured external override does not exist at `\(path)`. Fix or remove \(externalExecutableOverrideEnvironmentKey)."
            case let .externalOverrideNotExecutable(path):
                "RepoPrompt could not start Codex: the configured external override is not an executable file at `\(path)`. Fix or remove \(externalExecutableOverrideEnvironmentKey)."
            case let .externalOverrideVersionUnreadable(path):
                "RepoPrompt could not start Codex: the external override at `\(path)` did not report a compatible Codex version. Version \(minimumExternalVersion) or newer is required for RepoPrompt's direct-only tool policy."
            case let .externalOverrideTooOld(actual, minimum):
                "RepoPrompt could not start Codex: external override version \(actual) is too old. Version \(minimum) or newer is required for direct_only_tool_namespaces; update the override or remove \(externalExecutableOverrideEnvironmentKey) to use bundled Codex \(bundledVersion)."
            }
        }
    }

    struct Version: Comparable, CustomStringConvertible, Equatable {
        let major: Int
        let minor: Int
        let patch: Int

        var description: String {
            "\(major).\(minor).\(patch)"
        }

        static func < (lhs: Version, rhs: Version) -> Bool {
            (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }

        static func parse(_ text: String) -> Version? {
            let pattern = #"(?<![0-9])([0-9]+)\.([0-9]+)\.([0-9]+)(?![0-9])"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  match.numberOfRanges == 4,
                  let majorRange = Range(match.range(at: 1), in: text),
                  let minorRange = Range(match.range(at: 2), in: text),
                  let patchRange = Range(match.range(at: 3), in: text),
                  let major = Int(text[majorRange]),
                  let minor = Int(text[minorRange]),
                  let patch = Int(text[patchRange])
            else {
                return nil
            }
            return Version(major: major, minor: minor, patch: patch)
        }
    }

    private struct PackageMetadata: Decodable {
        let layoutVersion: Int
        let version: String
        let target: String
        let variant: String
        let entrypoint: String
        let resourcesDir: String
        let pathDir: String
    }

    private struct ExternalVersionCacheKey: Hashable {
        let path: String
        let modificationDate: Date?
        let fileSize: UInt64?
    }

    private static let externalVersionCacheLock = NSLock()
    private static var externalVersionCache: [ExternalVersionCacheKey: Version] = [:]

    static var currentArchitectureTarget: String? {
        #if arch(arm64)
            "aarch64-apple-darwin"
        #elseif arch(x86_64)
            "x86_64-apple-darwin"
        #else
            nil
        #endif
    }

    static func statePaths(applicationSupportURL: URL? = nil) -> StatePaths {
        let support = applicationSupportURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        #if DEBUG
            let buildChannel = "Debug"
        #else
            let buildChannel = "Release"
        #endif
        let root = support
            .appendingPathComponent("RepoPrompt CE", isDirectory: true)
            .appendingPathComponent("Codex", isDirectory: true)
            .appendingPathComponent(buildChannel, isDirectory: true)
        return StatePaths(
            codexHome: root.appendingPathComponent("home", isDirectory: true),
            sqliteHome: root.appendingPathComponent("sqlite", isDirectory: true)
        )
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resourcesURL: URL? = Bundle.main.resourceURL,
        architectureTarget: String? = currentArchitectureTarget,
        applicationSupportURL: URL? = nil,
        explicitExecutableOverride: String? = nil,
        externalVersionReader: ((URL) -> String?)? = nil
    ) -> Result<Runtime, Failure> {
        let state = statePaths(applicationSupportURL: applicationSupportURL)
        let configuredOverride = explicitExecutableOverride ?? environment[externalExecutableOverrideEnvironmentKey]
        if let configuredOverride = configuredOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredOverride.isEmpty
        {
            return resolveExternalOverride(
                configuredOverride,
                statePaths: state,
                versionReader: externalVersionReader
            )
        }

        guard let architectureTarget else {
            return .failure(.unsupportedArchitecture("unknown"))
        }
        guard architectureTarget == "aarch64-apple-darwin" || architectureTarget == "x86_64-apple-darwin" else {
            return .failure(.unsupportedArchitecture(architectureTarget))
        }
        guard let resourcesURL else {
            return .failure(.bundledResourcesUnavailable)
        }

        let packageRoot = resourcesURL
            .appendingPathComponent("BundledRuntimes", isDirectory: true)
            .appendingPathComponent("Codex", isDirectory: true)
            .appendingPathComponent(architectureTarget, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: packageRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(.bundledPackageMissing(target: architectureTarget))
        }

        let metadataURL = packageRoot.appendingPathComponent("codex-package.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(PackageMetadata.self, from: data)
        else {
            return .failure(.bundledMetadataUnreadable(target: architectureTarget))
        }
        guard metadata.layoutVersion == 1,
              metadata.version == bundledVersion.description,
              metadata.target == architectureTarget,
              metadata.variant == "codex",
              metadata.entrypoint == "bin/codex",
              metadata.resourcesDir == "codex-resources",
              metadata.pathDir == "codex-path"
        else {
            return .failure(
                .bundledMetadataMismatch(
                    expectedTarget: architectureTarget,
                    actualTarget: metadata.target,
                    actualVersion: metadata.version
                )
            )
        }

        let requiredDirectories = [metadata.resourcesDir, metadata.pathDir]
        for relative in requiredDirectories {
            let url = packageRoot.appendingPathComponent(relative, isDirectory: true)
            var componentIsDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &componentIsDirectory), componentIsDirectory.boolValue else {
                return .failure(.bundledLayoutIncomplete(target: architectureTarget, missingComponent: relative))
            }
        }
        let executableURL = packageRoot.appendingPathComponent(metadata.entrypoint)
        let codeModeHostURL = packageRoot.appendingPathComponent("bin/codex-code-mode-host")
        for url in [executableURL, codeModeHostURL] where !FileManager.default.isExecutableFile(atPath: url.path) {
            return .failure(
                .bundledLayoutIncomplete(
                    target: architectureTarget,
                    missingComponent: url.path.replacingOccurrences(of: packageRoot.path + "/", with: "")
                )
            )
        }

        return .success(
            Runtime(
                executableURL: executableURL,
                version: bundledVersion,
                source: .bundled(target: architectureTarget),
                statePaths: state
            )
        )
    }

    private static func resolveExternalOverride(
        _ rawPath: String,
        statePaths: StatePaths,
        versionReader: ((URL) -> String?)?
    ) -> Result<Runtime, Failure> {
        let expandedPath = (rawPath as NSString).expandingTildeInPath
        guard expandedPath.hasPrefix("/") else {
            return .failure(.externalOverrideMustBeAbsolute)
        }
        let url = URL(fileURLWithPath: expandedPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .failure(.externalOverrideMissing(url.path))
        }
        guard !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: url.path) else {
            return .failure(.externalOverrideNotExecutable(url.path))
        }
        let version: Version? = if let versionReader {
            versionReader(url).flatMap(Version.parse)
        } else {
            cachedExternalVersion(executableURL: url)
        }
        guard let version else {
            return .failure(.externalOverrideVersionUnreadable(url.path))
        }
        guard version >= minimumExternalVersion else {
            return .failure(.externalOverrideTooOld(actual: version, minimum: minimumExternalVersion))
        }
        return .success(
            Runtime(
                executableURL: url,
                version: version,
                source: .externalOverride,
                statePaths: statePaths
            )
        )
    }

    private static func cachedExternalVersion(executableURL: URL) -> Version? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: executableURL.path)
        let key = ExternalVersionCacheKey(
            path: executableURL.path,
            modificationDate: attributes?[.modificationDate] as? Date,
            fileSize: (attributes?[.size] as? NSNumber)?.uint64Value
        )

        externalVersionCacheLock.lock()
        defer { externalVersionCacheLock.unlock() }
        if let cached = externalVersionCache[key] {
            return cached
        }

        let version = readExternalVersion(executableURL: executableURL).flatMap(Version.parse)
        if let version {
            externalVersionCache[key] = version
        }
        return version
    }

    private static func readExternalVersion(executableURL: URL) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--version"]
        process.standardOutput = output
        process.standardError = output
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        if completed.wait(timeout: .now() + 3) == .timedOut {
            process.terminate()
            _ = completed.wait(timeout: .now() + 1)
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    private static func redactedStateDescription(_ paths: StatePaths) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        func redact(_ path: String) -> String {
            path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : "<application-support>/" + URL(fileURLWithPath: path).lastPathComponent
        }
        return "CODEX_HOME=\(redact(paths.codexHome.path)), CODEX_SQLITE_HOME=\(redact(paths.sqliteHome.path))"
    }
}
