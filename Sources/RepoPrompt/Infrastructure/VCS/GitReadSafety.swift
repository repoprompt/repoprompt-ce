import Foundation

/// Passive inspection must not opt into programs supplied by a checkout.
/// Deliberate network operations and mutations do not use this policy.
enum GitReadSafety {
    static let configurationArguments = [
        "-c", "core.fsmonitor=false",
        "-c", "core.hooksPath=/dev/null",
        "-c", "core.untrackedCache=false",
        "-c", "log.showSignature=false",
        "-c", "diff.submodule=short",
        "-c", "status.submoduleSummary=false",
        "-c", "gc.auto=0",
        "-c", "maintenance.auto=false"
    ]

    static let driverQuery = [
        "config", "--null", "--show-scope", "--get-regexp",
        "^(filter\\..*\\.(clean|smudge|process)|merge\\..*\\.driver)$"
    ]

    /// Only skip global options used by our command builders. This is not a
    /// parser for arbitrary user commands or an authorization check.
    static func commandIndex(in arguments: [String]) -> Int? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if ["-c", "--git-dir", "--work-tree"].contains(argument) {
                guard index + 1 < arguments.count else { return nil }
                index += 2
            } else if argument.hasPrefix("--git-dir=") || argument.hasPrefix("--work-tree=") {
                index += 1
            } else {
                return argument.hasPrefix("-") ? nil : index
            }
        }
        return nil
    }

    static func isRead(_ arguments: [String]) -> Bool {
        guard let index = commandIndex(in: arguments) else { return false }
        let args = Array(arguments[index...])
        switch args[0] {
        case "rev-parse", "status", "ls-files", "ls-tree", "diff", "diff-tree", "check-attr", "merge-base", "merge-tree",
             "show-ref", "for-each-ref", "log", "rev-list", "show", "blame", "cat-file":
            return true
        case "worktree":
            return args.dropFirst().first == "list"
        case "symbolic-ref":
            return args.contains("--short") && args.last == "HEAD"
        case "branch":
            return args == ["branch", "--show-current"]
        case "config":
            return args.contains("--get") || args.contains("--get-regexp")
        default:
            return false
        }
    }

    /// Classify the capabilities of our builders, not just the command verb.
    /// Only options before the path/end-of-options separator participate.
    private static func driverCapabilities(_ arguments: [String]) -> (filters: Bool, merge: Bool) {
        guard isRead(arguments), let index = commandIndex(in: arguments) else { return (false, false) }
        let options = arguments.dropFirst(index + 1).prefix { $0 != "--" && $0 != "--end-of-options" }
        switch arguments[index] {
        case "status", "diff", "blame": return (true, false)
        case "merge-tree": return (true, true)
        case "ls-files":
            // Plain index/untracked listings and --eol do not convert content.
            // --modified can hash worktree content through clean/process filters.
            let modified = options.contains("--modified") || options.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.dropFirst().contains("m") }
            return (modified, false)
        case "cat-file": return (options.contains("--filters"), false)
        case "log", "show":
            // Metadata and ordinary diffs cannot execute merge drivers. Remerge
            // diffs can also run conversion filters through merge.renormalize.
            let remerge = options.contains("--remerge-diff") || options.contains("-m")
                || options.contains("--diff-merges")
                || options.contains { ["--diff-merges=remerge", "--diff-merges=r", "--diff-merges=m", "--diff-merges=on"].contains($0) }
            return (remerge, remerge)
        default: return (false, false)
        }
    }

    static func needsDriverCheck(_ arguments: [String]) -> Bool {
        let capabilities = driverCapabilities(arguments)
        return capabilities.filters || capabilities.merge
    }

    static func validateSupportedRead(_ arguments: [String]) throws {
        guard let index = commandIndex(in: arguments), arguments[index] == "cat-file" else { return }
        let options = arguments.dropFirst(index + 1).prefix { $0 != "--" && $0 != "--end-of-options" }
        if options.contains("--textconv") {
            throw GitService.GitError(message: "Passive Git inspection does not run cat-file text conversion. Read the raw object instead.")
        }
    }

    /// Git config errors may echo arbitrary config values and paths. Preserve
    /// known failure categories/line numbers, never those untrusted payloads.
    static func driverQueryFailure(exitCode: Int32, stderr: Data) -> String {
        let detail = redactedFailureDetail(stderr)
        return "Git inspection could not validate driver configuration (git config exit \(exitCode)): \(detail). Check the repository's Git configuration with Git outside RepoPrompt."
    }

    static func ownershipProbeFailure(exitCode: Int32, stderr: Data) -> String {
        let detail = redactedFailureDetail(stderr)
        return "Git inspection could not validate repository ownership (Git ownership probe exit \(exitCode)): \(detail). Check the repository with Git outside RepoPrompt."
    }

    private static func redactedFailureDetail(_ stderr: Data) -> String {
        let input = String(decoding: stderr.prefix(4096), as: UTF8.self)
        let diagnostics = input.split(whereSeparator: \.isNewline).prefix(4).map { line -> String in
            let text = String(line)
            if let range = text.range(of: #"bad config line [0-9]+"#, options: .regularExpression) {
                return String(text[range]) + " in file <redacted>"
            }
            for category in ["unable to read config file", "exceeded maximum include depth", "invalid key", "invalid config", "detected dubious ownership"] where text.contains(category) {
                return category + " <redacted>"
            }
            return "<redacted Git diagnostic>"
        }
        return diagnostics.isEmpty ? "no diagnostic output" : diagnostics.joined(separator: "; ")
    }

    static func environment(_ environment: [String: String]) -> [String: String] {
        var result = environment
        result["GIT_OPTIONAL_LOCKS"] = "0"
        result["GIT_NO_LAZY_FETCH"] = "1"
        result["GIT_ALLOW_PROTOCOL"] = ""
        result["GIT_PROTOCOL_FROM_USER"] = "0"
        result["GIT_TERMINAL_PROMPT"] = "0"
        result.removeValue(forKey: "GIT_EXTERNAL_DIFF")
        return result
    }

    static func arguments(_ arguments: [String]) -> [String] {
        guard isRead(arguments), let index = commandIndex(in: arguments) else { return arguments }
        let command = arguments[index]
        // Config and path reads must report the real configuration, not our
        // overrides. In particular, hooksPath must not hide a post-checkout
        // hook from the tracked-checkout clone eligibility probe. These
        // metadata-only commands do not execute the configured hooks.
        if command == "config" || (command == "rev-parse" && arguments[(index + 1)...].contains("--git-path")) { return arguments }
        let options: [String] = switch command {
        case "status": ["--ignore-submodules=dirty"]
        case "diff": ["--no-ext-diff", "--no-textconv", "--ignore-submodules=dirty"]
        case "log", "show": ["--no-ext-diff", "--no-textconv"]
        case "blame": ["--no-textconv"]
        default: []
        }
        var result = arguments
        // Put safety flags after the builder's options, but before its path
        // or end-of-options separator. A later --textconv/--ext-diff must not undo this fence.
        let insertionIndex = result[(index + 1)...].firstIndex { $0 == "--" || $0 == "--end-of-options" } ?? result.endIndex
        // Presence alone is insufficient: an earlier disabling option can be
        // overridden by a later enabling option. Keep the safety options last,
        // while recognizing our own suffix so repeated fencing is idempotent.
        if !result[(index + 1) ..< insertionIndex].suffix(options.count).elementsEqual(options) {
            result.insert(contentsOf: options, at: insertionIndex)
        }
        if Array(result.prefix(configurationArguments.count)) == configurationArguments { return result }
        return configurationArguments + result
    }

    /// `git config --null --show-scope` emits scope NUL key LF value NUL.
    /// Refuse repository-defined executable drivers instead of silently
    /// producing incorrect status/diffs (notably for locally installed LFS).
    /// Includes inherit their including file's scope. System/global-only
    /// drivers remain user-managed. Malformed output fails closed.
    static func validateDriverConfiguration(_ data: Data, for arguments: [String]? = nil) throws {
        let capabilities = arguments.map(driverCapabilities) ?? (filters: true, merge: true)
        let checksFilters = capabilities.filters
        let checksMergeDrivers = capabilities.merge
        guard data.isEmpty || data.last == 0,
              let text = String(data: data, encoding: .utf8)
        else { throw GitService.GitError(message: "Git inspection could not validate driver configuration") }
        if text.isEmpty { return }
        let fields = text.split(separator: "\0", omittingEmptySubsequences: false)
        guard fields.count % 2 == 1, fields.last?.isEmpty == true else {
            throw GitService.GitError(message: "Git inspection could not validate driver configuration")
        }
        for index in stride(from: 0, to: fields.count - 1, by: 2) {
            let scope = fields[index]
            guard ["system", "global", "local", "worktree", "command"].contains(String(scope)) else {
                throw GitService.GitError(message: "Git inspection could not validate driver configuration")
            }
            let entry = fields[index + 1].split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard !entry[0].isEmpty else {
                throw GitService.GitError(message: "Git inspection could not validate driver configuration")
            }
            let key = String(entry[0]).lowercased()
            let relevant = (checksFilters && key.hasPrefix("filter."))
                || (checksMergeDrivers && key.hasPrefix("merge."))
            if relevant, scope == "local" || scope == "worktree" {
                guard entry.count == 2, entry[1].isEmpty else {
                    throw GitService.GitError(message: "Passive Git inspection is unavailable for repository-configured executable filters or merge drivers. RepoPrompt has no trust override for these programs. Inspect and run the required Git operation outside RepoPrompt only after reviewing the repository configuration.")
                }
            }
        }
    }
}
