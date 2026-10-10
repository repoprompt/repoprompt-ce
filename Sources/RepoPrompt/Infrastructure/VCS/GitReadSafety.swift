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

    static func needsDriverCheck(_ arguments: [String]) -> Bool {
        guard isRead(arguments), let index = commandIndex(in: arguments) else { return false }
        return ["status", "ls-files", "diff", "log", "show", "blame", "cat-file", "merge-tree"]
            .contains(arguments[index])
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
        // A config read must report the real configuration, not our overrides.
        if command == "config" { return arguments }
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
        let existingOptions = Set(result[(index + 1) ..< insertionIndex])
        result.insert(contentsOf: options.filter { !existingOptions.contains($0) }, at: insertionIndex)
        if Array(result.prefix(configurationArguments.count)) == configurationArguments { return result }
        return configurationArguments + result
    }

    /// `git config --null --show-scope` emits scope NUL key LF value NUL.
    /// Refuse repository-defined executable drivers instead of silently
    /// producing incorrect status/diffs (notably for locally installed LFS).
    /// Includes inherit their including file's scope. System/global-only
    /// drivers remain user-managed. Malformed output fails closed.
    static func validateDriverConfiguration(_ data: Data, for arguments: [String]? = nil) throws {
        let command = arguments.flatMap { args in commandIndex(in: args).map { args[$0] } }
        let checksFilters = command.map { ["status", "ls-files", "diff", "blame", "cat-file"].contains($0) } ?? true
        let checksMergeDrivers = command.map { ["log", "show", "merge-tree"].contains($0) } ?? true
        guard data.isEmpty || data.last == 0,
              let text = String(data: data, encoding: .utf8)
        else { throw GitError(message: "Git inspection could not validate driver configuration") }
        if text.isEmpty { return }
        let fields = text.split(separator: "\0", omittingEmptySubsequences: false)
        guard fields.count % 2 == 1, fields.last?.isEmpty == true else {
            throw GitError(message: "Git inspection could not validate driver configuration")
        }
        for index in stride(from: 0, to: fields.count - 1, by: 2) {
            let scope = fields[index]
            guard ["system", "global", "local", "worktree", "command"].contains(String(scope)) else {
                throw GitError(message: "Git inspection could not validate driver configuration")
            }
            let entry = fields[index + 1].split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard !entry[0].isEmpty else {
                throw GitError(message: "Git inspection could not validate driver configuration")
            }
            let key = String(entry[0]).lowercased()
            let relevant = (checksFilters && key.hasPrefix("filter."))
                || (checksMergeDrivers && key.hasPrefix("merge."))
            if relevant && (scope == "local" || scope == "worktree") {
                guard entry.count == 2, entry[1].isEmpty else {
                    throw GitError(message: "Passive Git inspection is unavailable for repository-configured executable filters or merge drivers. Use an explicitly trusted Git workflow for this repository.")
                }
            }
        }
    }
}
