import Foundation

/// Location derivation only. Does not provision directories, follow symlinks, or authorize launches.
package struct ManagedSubscriptionStateLayout {
    package enum BuildChannel: String {
        case debug = "Debug"
        case release = "Release"
    }

    package struct CodexStatePaths: Equatable {
        package let codexHome: URL
        package let sqliteHome: URL
    }

    private let channelRoot: URL

    /// The caller must supply the canonical root of its own app profile, never an ambient provider home.
    package init?(applicationProfileRoot: URL, channel: BuildChannel) {
        guard applicationProfileRoot.isFileURL,
              applicationProfileRoot.baseURL == nil,
              applicationProfileRoot.path.hasPrefix("/")
        else { return nil }
        channelRoot = applicationProfileRoot.standardizedFileURL
            .appendingPathComponent("ManagedSubscriptionProfiles", isDirectory: true)
            .appendingPathComponent(channel.rawValue, isDirectory: true)
    }

    package func codex(profileID: UUID) -> CodexStatePaths {
        let root = profileDirectory(backend: "Codex", profileID: profileID)
        return CodexStatePaths(
            codexHome: root.appendingPathComponent("home", isDirectory: true),
            sqliteHome: root.appendingPathComponent("sqlite", isDirectory: true)
        )
    }

    package func claudeCodeConfigDirectory(profileID: UUID) -> URL {
        profileDirectory(backend: "ClaudeCode", profileID: profileID)
            .appendingPathComponent("config", isDirectory: true)
    }

    private func profileDirectory(backend: String, profileID: UUID) -> URL {
        channelRoot
            .appendingPathComponent(backend, isDirectory: true)
            .appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
    }
}
