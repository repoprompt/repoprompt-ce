import Foundation

package struct AlwaysReadableDirectory: Hashable {
    package enum Source: Hashable {
        case globalAgentsSkills
        case globalAgentsSlash
        case globalClaudeSkills
        case globalClaudeCommands
        case userConfigured
    }

    package let url: URL
    package let source: Source

    package var standardizedPath: String {
        AgentSupportDirectoryCatalog.normalizedPath(for: url.path)
    }
}

package struct AgentSupportGlobalRootURLs {
    package let agentsSkills: URL
    package let agentsSlash: URL
    package let claudeSkills: URL
    package let claudeCommands: URL
    package let codexPrompts: URL
}

package enum AgentSupportDirectoryCatalog {
    package static func globalRootURLs(homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> AgentSupportGlobalRootURLs {
        let home = homeDirectoryURL.standardizedFileURL
        let agentsDir = home.appendingPathComponent(".agents", isDirectory: true)
        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
        return AgentSupportGlobalRootURLs(
            agentsSkills: agentsDir.appendingPathComponent("skills", isDirectory: true),
            agentsSlash: agentsDir.appendingPathComponent("slash", isDirectory: true),
            claudeSkills: claudeDir.appendingPathComponent("skills", isDirectory: true),
            claudeCommands: claudeDir.appendingPathComponent("commands", isDirectory: true),
            codexPrompts: codexDir.appendingPathComponent("prompts", isDirectory: true)
        )
    }

    package static func builtInAlwaysReadableDirectories(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [AlwaysReadableDirectory] {
        let roots = globalRootURLs(homeDirectoryURL: homeDirectoryURL)
        return dedupe([
            AlwaysReadableDirectory(url: roots.agentsSkills, source: .globalAgentsSkills),
            AlwaysReadableDirectory(url: roots.agentsSlash, source: .globalAgentsSlash),
            AlwaysReadableDirectory(url: roots.claudeSkills, source: .globalClaudeSkills),
            AlwaysReadableDirectory(url: roots.claudeCommands, source: .globalClaudeCommands)
        ])
    }

    package static func effectiveAlwaysReadableDirectories(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        additionalAbsolutePaths: [String] = []
    ) -> [AlwaysReadableDirectory] {
        let configured = additionalAbsolutePaths
            .map { normalizedPath(for: $0) }
            .filter { $0.hasPrefix("/") }
            .map { AlwaysReadableDirectory(url: URL(fileURLWithPath: $0, isDirectory: true), source: .userConfigured) }
        return dedupe(builtInAlwaysReadableDirectories(homeDirectoryURL: homeDirectoryURL) + configured)
    }

    package static func displayPath(for absolutePath: String, homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let normalizedAbsolute = normalizedPath(for: absolutePath)
        let homePath = normalizedPath(for: homeDirectoryURL.path)
        guard normalizedAbsolute == homePath || normalizedAbsolute.hasPrefix(homePath + "/") else {
            return normalizedAbsolute
        }
        let suffix = String(normalizedAbsolute.dropFirst(homePath.count))
        return suffix.isEmpty ? "~" : "~" + suffix
    }

    package static func contains(
        absolutePath: String,
        in directory: AlwaysReadableDirectory,
        fileManager: FileManager = .default
    ) -> Bool {
        contains(absolutePath: absolutePath, inDirectoryPath: directory.standardizedPath, fileManager: fileManager)
    }

    package static func contains(
        absolutePath: String,
        inDirectoryPath directoryPath: String,
        fileManager: FileManager = .default
    ) -> Bool {
        let normalizedDirectory = normalizedPath(for: directoryPath)
        let normalizedCandidate = normalizedPath(for: absolutePath)
        guard normalizedDirectory.hasPrefix("/"), normalizedCandidate.hasPrefix("/") else { return false }

        if fileManager.fileExists(atPath: normalizedCandidate) {
            guard fileManager.fileExists(atPath: normalizedDirectory) else { return false }
            let resolvedDirectory = normalizedPath(
                for: URL(fileURLWithPath: normalizedDirectory).resolvingSymlinksInPath().standardizedFileURL.path
            )
            let resolvedCandidate = normalizedPath(
                for: URL(fileURLWithPath: normalizedCandidate).resolvingSymlinksInPath().standardizedFileURL.path
            )
            return resolvedCandidate == resolvedDirectory || resolvedCandidate.hasPrefix(resolvedDirectory + "/")
        }

        return normalizedCandidate == normalizedDirectory || normalizedCandidate.hasPrefix(normalizedDirectory + "/")
    }

    package static func normalizedPath(for path: String) -> String {
        var normalized = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private static func dedupe(_ directories: [AlwaysReadableDirectory]) -> [AlwaysReadableDirectory] {
        var seen = Set<String>()
        return directories.filter { directory in
            seen.insert(directory.standardizedPath).inserted
        }
    }
}
