import Foundation

struct AlwaysReadableDirectory: Hashable {
    enum Source: Hashable {
        case globalAgentsSkills
        case globalAgentsSlash
        case globalClaudeSkills
        case globalClaudeCommands
        case userConfigured
    }

    let url: URL
    let source: Source

    var standardizedPath: String {
        AgentSupportDirectoryCatalog.normalizedPath(for: url.path)
    }
}

struct AgentSupportGlobalRootURLs {
    let agentsSkills: URL
    let agentsSlash: URL
    let claudeSkills: URL
    let claudeCommands: URL
    let codexPrompts: URL
}

enum AgentSupportDirectoryCatalog {
    static func globalRootURLs(homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> AgentSupportGlobalRootURLs {
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

    static func builtInAlwaysReadableDirectories(
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

    static func effectiveAlwaysReadableDirectories(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        additionalAbsolutePaths: [String] = []
    ) -> [AlwaysReadableDirectory] {
        let configured = additionalAbsolutePaths
            .map { normalizedPath(for: $0) }
            .filter { $0.hasPrefix("/") }
            .map { AlwaysReadableDirectory(url: URL(fileURLWithPath: $0, isDirectory: true), source: .userConfigured) }
        return dedupe(builtInAlwaysReadableDirectories(homeDirectoryURL: homeDirectoryURL) + configured)
    }

    static func displayPath(for absolutePath: String, homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let normalizedAbsolute = normalizedPath(for: absolutePath)
        let homePath = normalizedPath(for: homeDirectoryURL.path)
        guard normalizedAbsolute == homePath || normalizedAbsolute.hasPrefix(homePath + "/") else {
            return normalizedAbsolute
        }
        let suffix = String(normalizedAbsolute.dropFirst(homePath.count))
        return suffix.isEmpty ? "~" : "~" + suffix
    }

    static func contains(
        absolutePath: String,
        in directory: AlwaysReadableDirectory,
        fileManager: FileManager = .default
    ) -> Bool {
        contains(absolutePath: absolutePath, inDirectoryPath: directory.standardizedPath, fileManager: fileManager)
    }

    static func contains(
        absolutePath: String,
        inDirectoryPath directoryPath: String,
        fileManager: FileManager = .default
    ) -> Bool {
        let normalizedDirectory = normalizedPath(for: directoryPath)
        guard normalizedDirectory.hasPrefix("/") else { return false }
        let directoryCandidates = containmentCandidates(for: normalizedDirectory, fileManager: fileManager)
        let pathCandidates = containmentCandidates(for: absolutePath, fileManager: fileManager)
        for directoryCandidate in directoryCandidates {
            for pathCandidate in pathCandidates {
                if pathCandidate == directoryCandidate || pathCandidate.hasPrefix(directoryCandidate + "/") {
                    return true
                }
            }
        }
        return false
    }

    static func normalizedPath(for path: String) -> String {
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

    private static func containmentCandidates(for absolutePath: String, fileManager: FileManager) -> [String] {
        let normalized = normalizedPath(for: absolutePath)
        guard normalized.hasPrefix("/") else { return [] }

        var candidates: [String] = [normalized]
        if fileManager.fileExists(atPath: normalized) {
            let resolved = URL(fileURLWithPath: normalized).resolvingSymlinksInPath().standardizedFileURL.path
            let normalizedResolved = normalizedPath(for: resolved)
            if normalizedResolved != normalized {
                candidates.insert(normalizedResolved, at: 0)
            }
        }
        return candidates
    }
}
