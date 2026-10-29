import Foundation

package struct RepoPromptMCPServerConfiguration: Equatable, Hashable {
    package struct EnvironmentEntry: Equatable, Hashable {
        package let name: String
        package let value: String

        package init(name: String, value: String) {
            self.name = name
            self.value = value
        }

        package var acpJSONObject: [String: String] {
            [
                "name": name,
                "value": value
            ]
        }
    }

    package static let defaultServerName = "RepoPromptCE"
    /// Stable Grok-only name avoids the common imported `RepoPromptCE` collision: Grok
    /// drops client servers matching disabled Claude/Cursor imports, even on session/load.
    package static let grokBuildRuntimeServerName = "RepoPromptCEGrokRuntime"

    package let name: String
    package let command: String
    package let args: [String]
    package let env: [EnvironmentEntry]

    package init(
        name: String = Self.defaultServerName,
        command: String,
        args: [String] = [],
        env: [EnvironmentEntry] = []
    ) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
    }

    package var environmentDictionary: [String: String] {
        Dictionary(uniqueKeysWithValues: env.map { ($0.name, $0.value) })
    }

    package var settingsJSONObject: [String: Any] {
        var object: [String: Any] = [
            "command": command,
            "args": args
        ]
        if !env.isEmpty {
            object["env"] = environmentDictionary
        }
        return object
    }

    package var wrappedSettingsJSONObject: [String: Any] {
        [
            "mcpServers": [
                name: settingsJSONObject
            ]
        ]
    }

    package var acpJSONObject: [String: Any] {
        [
            "type": "stdio",
            "name": name,
            "command": command,
            "args": args,
            "env": env.map(\.acpJSONObject)
        ]
    }

    package func prettyPrintedWrappedSettingsJSON() throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: wrappedSettingsJSONObject,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        guard let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return string
    }
}
