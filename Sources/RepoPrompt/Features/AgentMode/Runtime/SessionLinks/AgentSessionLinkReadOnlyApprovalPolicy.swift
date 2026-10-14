import Foundation

/// Conservative command-shape allowlist, not a shell parser. Quoting, expansion, pipelines,
/// redirects, wrappers, environment assignments and unknown options always stay manual.
/// Git's external diff/textconv/pager hooks must be explicitly disabled by the command itself.
enum AgentSessionLinkReadOnlyApprovalPolicy {
    static func allows(_ approval: AgentApprovalRequest) -> Bool {
        guard approval.kind == .commandExecution, let command = approval.command else { return false }
        switch approval.requestID {
        case .codex:
            guard approval.method == "item/commandExecution/requestApproval" else { return false }
        case .claudeControl:
            guard approval.method == "control/can_use_tool",
                  approval.details.first(where: { $0.label == "Tool" })?.value == "Bash" else { return false }
        case .acp:
            // ACP currently supplies provider-specific rawInput JSON, not an attested command.
            return false
        }
        return allows(command)
    }

    static func allows(_ command: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _./-:=,@%+~")
        guard !command.isEmpty, command.utf8.count <= 8192,
              command.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        let words = command.split(separator: " ").map(String.init)
        guard let executable = words.first else { return false }
        var args = Array(words.dropFirst())
        switch executable {
        case "git":
            guard args.first == "--no-pager" else { return false }
            args.removeFirst()
            guard let op = args.first, ["log", "status", "diff"].contains(op) else { return false }
            args.removeFirst()
            if op != "status" {
                guard args.contains("--no-ext-diff"), args.contains("--no-textconv") else { return false }
            }
            let flags: Set = [
                "--no-ext-diff", "--no-textconv", "--oneline", "--stat", "--shortstat", "--numstat",
                "--name-only", "--name-status", "--no-renames", "--no-color", "--color=never",
                "--short", "--branch", "--porcelain", "--porcelain=v1", "--porcelain=v2",
                "--graph", "--all", "--decorate", "--no-decorate", "--patch", "--no-patch",
                "--raw", "--summary", "--cached", "--staged", "--check", "--relative", "--",
                "-p", "-s", "-b", "-u", "-w"
            ]
            return args.allSatisfy { arg in
                !arg.hasPrefix("-") || flags.contains(arg)
                    || ["--max-count=", "--since=", "--until="].contains { arg.hasPrefix($0) }
                    || (arg.hasPrefix("-n") && Int(arg.dropFirst(2)) != nil)
            }
        case "gh":
            guard args.starts(with: ["run", "view"]) else { return false }
            return args.dropFirst(2).allSatisfy { arg in
                !arg.hasPrefix("-") || ["--log", "--log-failed", "--exit-status", "--verbose", "--job", "-j", "--repo", "-R", "--json", "--jq", "-q"].contains(arg)
            }
        case "conductor", "./conductor":
            guard args.count >= 2, args[0] == "job", ["list", "status", "wait"].contains(args[1]) else { return false }
            return args.dropFirst(2).allSatisfy { !$0.hasPrefix("-") || ["--request-key", "--full-log"].contains($0) }
        case "grep":
            return !args.isEmpty
        default:
            return false
        }
    }
}
