import Foundation

/// Config-directory identity only. Never reads credentials or establishes account identity.
struct ClaudeUsageCredentialProfile: Equatable {
    let directory: URL
    let isDefault: Bool
    var id: String {
        directory.path
    }

    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Self {
        let defaultDirectory = home.appendingPathComponent(".claude", isDirectory: true).standardizedFileURL
        let override = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory: URL = if let override, !override.isEmpty {
            URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true).standardizedFileURL
        } else { defaultDirectory }
        return Self(directory: directory, isDefault: directory == defaultDirectory)
    }
}
