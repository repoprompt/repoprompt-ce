import Foundation

/// Deliberately not a shell parser: only literal, single native `gh pr create` commands qualify.
/// External MCP tool names and persisted/transcript projections never enter this observer.
enum AgentSessionNativePullRequestObserver {
    enum Outcome: Equatable {
        case ignored
        case association(AgentSessionPullRequestAssociation)
        case notice(String)
    }

    static func observe(_ event: AgentNativeCommandCompletion, trustedHosts: @autoclosure () -> Set<String> = ["github.com"]) -> Outcome {
        let tokens: [String]? = if let argv = event.argv { argv }
        else if let command = event.command { literalTokens(command) }
        else { nil }
        guard let tokens else {
            let prefix = event.command?.split(whereSeparator: { $0.isWhitespace }).prefix(3).map(String.init)
            return prefix == ["gh", "pr", "create"] && !event.isError && event.exitCode == 0
                ? .notice("unsupported_command_shape") : .ignored
        }
        guard tokens.count >= 3, Array(tokens.prefix(3)) == ["gh", "pr", "create"] else { return .ignored }
        guard !event.isError, event.exitCode == 0 else {
            return event.isError || event.exitCode.map { $0 != 0 } == true ? .ignored : .notice("missing_exit_status")
        }
        guard !tokens.contains(where: { $0 == "--dry-run" || $0.hasPrefix("--dry-run=") || $0 == "--help" || $0 == "-h" }) else { return .notice("non_creating_command") }
        guard !event.isTruncated, let output = event.output, output.utf8.count <= 8192,
              !output.lowercased().contains("truncated"),
              let last = output.components(separatedBy: .newlines).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              !last.contains(" "), !last.contains("\t"),
              output.components(separatedBy: "https://").count == 2,
              let identity = try? AgentSessionPullRequestIdentity(url: last, trustedHosts: trustedHosts())
        else { return .notice("missing_or_ambiguous_pr_url") }
        for (index, token) in tokens.enumerated() {
            let repo: String?
            if token == "--repo" || token == "-R" {
                guard index + 1 < tokens.count else { return .notice("missing_repository") }
                repo = tokens[index + 1]
            } else if token.hasPrefix("--repo=") { repo = String(token.dropFirst(7)) }
            else if token.hasPrefix("-R"), token.count > 2 { repo = String(token.dropFirst(2)) }
            else { repo = nil }
            if let repo {
                let qualified = repo.lowercased().split(separator: "/").map(String.init)
                guard qualified == [identity.owner, identity.repository] || qualified == [identity.host, identity.owner, identity.repository] else { return .notice("repository_conflict") }
            }
        }
        return .association(.init(identity: identity, provenance: "observedShellCreation", firstAssociatedAt: Date(), executionID: event.invocationID.uuidString))
    }

    static func literalTokens(_ command: String) -> [String]? {
        guard command.utf8.count <= 32768, !command.contains(where: { "\n\r;&|<>$`\\".contains($0) }) else { return nil }
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        for character in command {
            if let active = quote {
                if character == active { quote = nil } else { current.append(character) }
                hasToken = true
            } else if character == "\"" || character == "'" {
                quote = character
                hasToken = true
            } else if character.isWhitespace {
                if hasToken { tokens.append(current)
                    current = ""
                    hasToken = false
                }
            } else { current.append(character)
                hasToken = true
            }
        }
        guard quote == nil else { return nil }
        if hasToken { tokens.append(current) }
        return tokens
    }
}
