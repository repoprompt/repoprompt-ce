import Foundation

enum ClaudeEffectiveContextWindowResolver {
    static let environmentKey = "CLAUDE_CODE_AUTO_COMPACT_WINDOW"

    static func resolveConfiguredContextWindow(
        launchEnvironment: [String: String],
        workingDirectory: String?,
        fileManager: FileManager = .default
    ) -> Int? {
        if let envValue = positiveInteger(from: launchEnvironment[environmentKey]) {
            return envValue
        }

        let projectDirectory = workingDirectory.flatMap { nonEmptyURL(path: $0) }
        let projectSettingsURLs: [URL] = projectDirectory.map {
            [
                $0.appendingPathComponent(".claude/settings.local.json", isDirectory: false),
                $0.appendingPathComponent(".claude/settings.json", isDirectory: false)
            ]
        } ?? []

        for settingsURL in projectSettingsURLs {
            if let value = configuredContextWindow(inSettingsAt: settingsURL, fileManager: fileManager) {
                return value
            }
        }

        guard let userSettingsURL = userSettingsURL(launchEnvironment: launchEnvironment) else {
            return nil
        }
        return configuredContextWindow(inSettingsAt: userSettingsURL, fileManager: fileManager)
    }

    private static func userSettingsURL(launchEnvironment: [String: String]) -> URL? {
        if let configDir = nonEmptyURL(path: launchEnvironment["CLAUDE_CONFIG_DIR"]) {
            return configDir.appendingPathComponent("settings.json", isDirectory: false)
        }
        guard let home = nonEmptyURL(path: launchEnvironment["HOME"]) else { return nil }
        return home.appendingPathComponent(".claude/settings.json", isDirectory: false)
    }

    private static func configuredContextWindow(
        inSettingsAt url: URL,
        fileManager: FileManager
    ) -> Int? {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = object["env"] as? [String: Any]
        else {
            return nil
        }
        return positiveInteger(from: env[environmentKey])
    }

    private static func positiveInteger(from value: Any?) -> Int? {
        switch value {
        case let raw as String:
            let normalized = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "_", with: "")
            guard let parsed = Int(normalized), parsed > 0 else { return nil }
            return parsed
        case let raw as NSNumber:
            let parsed = raw.intValue
            return parsed > 0 ? parsed : nil
        default:
            return nil
        }
    }

    private static func nonEmptyURL(path: String?) -> URL? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
