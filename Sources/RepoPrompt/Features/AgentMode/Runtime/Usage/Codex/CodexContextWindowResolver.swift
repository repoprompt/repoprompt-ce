import Foundation

struct CodexContextWindowConfiguration: Equatable {
    var configuredContextWindow: Int?
    var autoCompactTokenLimit: Int?
}

enum CodexContextWindowResolver {
    static func resolve(
        launchEnvironment: [String: String],
        workingDirectory: String?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> CodexContextWindowConfiguration {
        let userConfig = configuration(
            at: userConfigURL(launchEnvironment: launchEnvironment, homeDirectory: homeDirectory),
            fileManager: fileManager
        )
        let projectConfig = projectConfigURL(workingDirectory: workingDirectory).flatMap {
            configuration(at: $0, fileManager: fileManager)
        }

        return CodexContextWindowConfiguration(
            configuredContextWindow: projectConfig?.configuredContextWindow ?? userConfig?.configuredContextWindow,
            autoCompactTokenLimit: projectConfig?.autoCompactTokenLimit ?? userConfig?.autoCompactTokenLimit
        )
    }

    static func configuration(fromRootTableTOML content: String) -> CodexContextWindowConfiguration {
        CodexContextWindowConfiguration(
            configuredContextWindow: positiveRootTableInteger(forKey: "model_context_window", in: content),
            autoCompactTokenLimit: positiveRootTableInteger(forKey: "model_auto_compact_token_limit", in: content)
        )
    }

    private static func configuration(
        at url: URL,
        fileManager: FileManager
    ) -> CodexContextWindowConfiguration? {
        guard fileManager.fileExists(atPath: url.path),
              let content = try? String(contentsOf: url, encoding: .utf8)
        else {
            return nil
        }
        return configuration(fromRootTableTOML: content)
    }

    private static func userConfigURL(
        launchEnvironment: [String: String],
        homeDirectory: URL
    ) -> URL {
        let codexHome = launchEnvironment["CODEX_HOME"]
            .flatMap { nonEmptyURL(path: $0) }
            ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        return codexHome.appendingPathComponent("config.toml", isDirectory: false)
    }

    private static func projectConfigURL(workingDirectory: String?) -> URL? {
        nonEmptyURL(path: workingDirectory)?
            .appendingPathComponent(".codex/config.toml", isDirectory: false)
    }

    private static func positiveRootTableInteger(forKey key: String, in content: String) -> Int? {
        guard let value = CodexIntegrationConfiguration.rootTableIntegerValue(forKey: key, in: content), value > 0 else {
            return nil
        }
        return value
    }

    private static func nonEmptyURL(path: String?) -> URL? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
