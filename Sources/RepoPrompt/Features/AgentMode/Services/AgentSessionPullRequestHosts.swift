import Foundation

/// Enterprise hosts are opt-in through local repository remotes, never inferred from a PR URL.
/// Reads only bounded local configuration; does not execute Git, resolve includes, or use the network.
enum AgentSessionPullRequestHosts {
    static func configured(repositoryPaths: [String]) -> Set<String> {
        var hosts: Set = ["github.com"]
        for path in repositoryPaths {
            let root = URL(fileURLWithPath: path, isDirectory: true)
            var git = root.appendingPathComponent(".git")
            if let pointer = boundedText(git), pointer.hasPrefix("gitdir:") {
                git = URL(fileURLWithPath: String(pointer.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true, relativeTo: root).standardizedFileURL
            } else {
                git = root.appendingPathComponent(".git", isDirectory: true)
            }
            if let common = boundedText(git.appendingPathComponent("commondir")) {
                git = URL(fileURLWithPath: common.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true, relativeTo: git).standardizedFileURL
            }
            guard let config = boundedText(git.appendingPathComponent("config")) else { continue }
            hosts.formUnion(remoteHosts(config: config))
        }
        return hosts
    }

    static func remoteHosts(config: String) -> Set<String> {
        var inRemote = false
        var hosts: Set<String> = []
        for raw in config.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inRemote = line.hasPrefix("[remote \"") && line.hasSuffix("\"]")
                continue
            }
            guard inRemote, let equals = line.firstIndex(of: "="), line[..<equals].trimmingCharacters(in: .whitespaces).lowercased() == "url" else { continue }
            let remote = line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let host: String? = if remote.contains("://") { URLComponents(string: remote)?.host }
            else if let at = remote.firstIndex(of: "@"), let colon = remote[remote.index(after: at)...].firstIndex(of: ":") {
                String(remote[remote.index(after: at) ..< colon])
            } else { nil }
            if let host = host?.lowercased(), !host.isEmpty, !host.contains(where: \.isWhitespace), host != "localhost" { hosts.insert(host) }
        }
        return hosts
    }

    private static func boundedText(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
              let size = values.fileSize, size <= 524_288, let data = try? Data(contentsOf: url), data.count <= 524_288 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
