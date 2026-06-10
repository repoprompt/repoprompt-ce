import Darwin
import Foundation

#if DEBUG
    private var commandPathResolverDebugLoggingEnabled = false
#endif

private func commandPathResolverLog(_ message: @autoclosure () -> String) {
    #if DEBUG
        ProcessDebugLogging.log(
            prefix: "PathResolver",
            message(),
            enabled: commandPathResolverDebugLoggingEnabled
        )
    #endif
}

enum CLIExecutableLaunchability: Equatable {
    case launchable
    case bareCommandFallback
    case missingPath
    case directory
    case notExecutable
}

enum CommandPathResolver {
    /// Heuristic: a basename matches an expected program name if it is equal, or if it
    /// is a versioned variant (e.g., "python3.11" matches "python").
    private static func basenameMatches(_ basename: String, expected: Set<String>) -> Bool {
        if expected.contains(basename) { return true }
        return expected.contains { basename.hasPrefix($0) && basename.dropFirst($0.count).range(of: #"^[0-9._-]+"#, options: .regularExpression) != nil }
    }

    /// Resolves a command to its full executable path using a prioritized search strategy:
    /// 1. If command contains "/" and is executable, use it directly
    /// 2. Query the user's interactive shell (respects PATH, aliases, nvm, etc.)
    /// 3. Search additionalPaths as fallback (e.g., ~/.claude/local)
    /// 4. Return original command and let the system resolve it
    ///
    /// IMPORTANT: The environment passed here should NOT have additionalPaths merged into PATH.
    /// This ensures the interactive shell uses the user's actual PATH configuration,
    /// allowing version managers like nvm to work correctly.
    static func resolve(
        _ command: String,
        environment: [String: String],
        additionalPaths: [String],
        logger: ((String) -> Void)? = nil,
        preferredBasenames: [String]? = nil
    ) -> String {
        let expanded = expandPath(command, environment: environment)
        // Honor explicit paths only when they already point to a runnable executable file.
        if expanded.contains("/"), isExecutableRegularFile(expanded) {
            commandPathResolverLog("Command '\(command)' -> '\(expanded)' (explicit path)")
            return expanded
        }
        // Prefer the user shell so aliases/functions take precedence.
        if let shellResult = lookupViaInteractiveShell(expanded, environment: environment, preferredBasenames: preferredBasenames) {
            let shellPath = shellResult.path
            let isAliasTarget = shellResult.isAliasTarget

            // Trust the shell's resolution if it returns a path - command -v/which are reliable
            if shellPath.contains("/") {
                logger?("Interactive shell resolved \(expanded) to \(shellPath)")
                commandPathResolverLog("Command '\(command)' -> '\(shellPath)' (via shell)")
                return shellPath
            }

            if !shellPath.contains("/"),
               let located = locateInSearchPaths(shellPath, environment: environment, additionalPaths: additionalPaths)
            {
                logger?("Interactive shell target \(shellPath) located at \(located)")
                commandPathResolverLog("Command '\(command)' -> '\(located)' (shell target in search paths)")
                return located
            }

            if isAliasTarget {
                logger?("Interactive shell resolved alias \(expanded) to \(shellPath)")
                commandPathResolverLog("Command '\(command)' -> '\(shellPath)' (alias)")
                return shellPath
            }
        }
        if let located = locateInSearchPaths(expanded, environment: environment, additionalPaths: additionalPaths) {
            logger?("Resolved \(expanded) to \(located)")
            commandPathResolverLog("Command '\(command)' -> '\(located)' (search paths)")
            return located
        }
        logger?("Falling back to original command \(expanded)")
        commandPathResolverLog("Command '\(command)' -> '\(expanded)' (fallback, will let system resolve)")
        return expanded
    }

    static func expandPath(_ path: String, environment: [String: String]) -> String {
        let tildeExpanded: String = if let home = environment["HOME"], !home.isEmpty, path == "~" {
            home
        } else if let home = environment["HOME"], !home.isEmpty, path.hasPrefix("~/") {
            home + path.dropFirst()
        } else {
            (path as NSString).expandingTildeInPath
        }
        guard tildeExpanded.contains("$") else { return tildeExpanded }
        return expandEnvironmentVariables(in: tildeExpanded, environment: environment)
    }

    static func launchability(of resolvedCommand: String) -> CLIExecutableLaunchability {
        guard resolvedCommand.contains("/") else {
            return .bareCommandFallback
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedCommand, isDirectory: &isDirectory) else {
            return .missingPath
        }
        if isDirectory.boolValue {
            return .directory
        }
        guard access(resolvedCommand, X_OK) == 0 else {
            return .notExecutable
        }
        return .launchable
    }

    static func mergedPathComponents(environment: [String: String], additionalPaths: [String]) -> [String] {
        var components: [String] = []
        var seen = Set<String>()
        func append(path: String) {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let expanded = expandPath(trimmed, environment: environment)
            if seen.insert(expanded).inserted {
                components.append(expanded)
            }
        }
        if let pathValue = environment["PATH"], !pathValue.isEmpty {
            for component in pathValue.split(separator: ":") {
                append(path: String(component))
            }
        }
        for rawPath in additionalPaths {
            for component in rawPath.split(separator: ":") {
                append(path: String(component))
            }
        }
        return components
    }

    private static func locateInSearchPaths(_ command: String, environment: [String: String], additionalPaths: [String]) -> String? {
        // Search both the user's PATH and caller-provided additional paths (deduped).
        let searchPaths = mergedPathComponents(environment: environment, additionalPaths: additionalPaths)
        for path in searchPaths {
            let candidate = (path as NSString).appendingPathComponent(command)
            if isExecutableRegularFile(candidate) {
                return candidate
            }
        }
        return nil
    }

    /// True only when the path exists, is not a directory, and has execute permission.
    private static func isExecutableRegularFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        return access(path, X_OK) == 0
    }

    private static func expandEnvironmentVariables(in path: String, environment: [String: String]) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)"#)
        else { return path }
        let nsPath = path as NSString
        let mutable = NSMutableString(string: path)
        let matches = regex.matches(in: path, range: NSRange(location: 0, length: nsPath.length)).reversed()
        for match in matches {
            let keyRange: NSRange = if match.range(at: 1).location != NSNotFound {
                match.range(at: 1)
            } else {
                match.range(at: 2)
            }
            let key = nsPath.substring(with: keyRange)
            guard let value = environment[key] else { continue }
            mutable.replaceCharacters(in: match.range, with: value)
        }
        return mutable as String
    }

    private static func lookupViaInteractiveShell(
        _ command: String,
        environment: [String: String],
        preferredBasenames: [String]?
    ) -> (path: String, isAliasTarget: Bool)? {
        let shellPath = environment["SHELL"] ?? userLoginShell()
        guard let shellPath else { return nil }
        let escapedCommand = command.replacingOccurrences(of: "\"", with: "\\\"")
        let sentinelBegin = "__RP_BEGIN__"
        let sentinelEnd = "__RP_END__"
        let expectedBasenames = Set((preferredBasenames ?? [command]).filter { !$0.isEmpty })

        // Prefer quoted (robust in real shells), but also include a safe, unquoted fallback.
        // Some lightweight/fake shells (like our test rig) pattern-match on the query text
        // and expect `command -v foo` without quotes.
        var queries: [String] = [
            "printf '%s\\n' '\(sentinelBegin)'; command -v \"\(escapedCommand)\" 2>/dev/null; printf '%s\\n' '\(sentinelEnd)'",
            "printf '%s\\n' '\(sentinelBegin)'; which -a \"\(escapedCommand)\" 2>/dev/null; printf '%s\\n' '\(sentinelEnd)'"
        ]
        if isSafeUnquotedCommandName(command) {
            queries.append("printf '%s\\n' '\(sentinelBegin)'; command -v \(command) 2>/dev/null; printf '%s\\n' '\(sentinelEnd)'")
            queries.append("printf '%s\\n' '\(sentinelBegin)'; which -a \(command) 2>/dev/null; printf '%s\\n' '\(sentinelEnd)'")
        }

        for query in queries {
            let (status, stdoutData, _) = runShellQuery(
                shellPath: shellPath,
                arguments: ["-l", "-i", "-c", query],
                environment: environment
            )
            guard status == 0, let output = String(data: stdoutData, encoding: .utf8) else { continue }

            let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            var betweenSentinels = false
            var fallbackCandidate: (String, Bool)?
            for rawLine in lines {
                let line = String(rawLine)
                if line == sentinelBegin { betweenSentinels = true
                    continue
                }
                if line == sentinelEnd { betweenSentinels = false
                    break
                }
                guard betweenSentinels else { continue }
                let candidate = sanitizedExecutableOutput(line, originalCommand: command, preferredBasenames: preferredBasenames)
                guard let candidate else { continue }
                let expanded = expandPath(candidate.path, environment: environment)
                let isPathLike = expanded.contains("/") || expanded.hasPrefix("~")
                let isPreferred = expectedBasenames.isEmpty || basenameMatches((expanded as NSString).lastPathComponent, expected: expectedBasenames)

                let shouldAcceptImmediately: Bool
                if candidate.isAliasTarget || isPathLike || isPreferred {
                    shouldAcceptImmediately = true
                } else {
                    if fallbackCandidate == nil {
                        fallbackCandidate = (expanded, candidate.isAliasTarget)
                    }
                    shouldAcceptImmediately = false
                }

                if shouldAcceptImmediately {
                    if isExecutableRegularFile(expanded) { return (expanded, candidate.isAliasTarget) }
                    return (expanded, candidate.isAliasTarget)
                }
            }
            if let fallbackCandidate {
                return fallbackCandidate
            }
        }
        return nil
    }

    private static func isSafeUnquotedCommandName(_ s: String) -> Bool {
        // Typical POSIX command names; avoid whitespace and shell metacharacters.
        s.range(of: #"^[A-Za-z0-9._+-]+$"#, options: .regularExpression) != nil
    }

    /// Spawn a shell command and drain stdout/stderr concurrently to avoid pipe back-pressure deadlocks.
    /// Uses DispatchQueue to move blocking I/O off the caller's thread.
    private static func runShellQuery(
        shellPath: String,
        arguments: [String],
        environment: [String: String]
    ) -> (status: Int32, stdout: Data, stderr: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = arguments
        // Don't let an interactive shell try to read from us
        process.standardInput = FileHandle.nullDevice
        var env = environment
        env["RP_SHELL_LOOKUP"] = "1" // lets rc files suppress banners if they want
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let out = stdoutPipe.fileHandleForReading
        let err = stderrPipe.fileHandleForReading

        var stdoutAccum = Data()
        var stderrAccum = Data()

        let group = DispatchGroup()
        let chunkSize = 64 * 1024

        // Drain stdout concurrently to avoid blocking the child on pipe buffer fills
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            while true {
                guard let chunk = try? out.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                stdoutAccum.append(chunk)
            }
        }

        // Drain stderr concurrently (even if we don't use it) to prevent deadlock
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            while true {
                guard let chunk = try? err.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                stderrAccum.append(chunk)
            }
        }

        let terminationGroup = DispatchGroup()
        terminationGroup.enter()
        process.terminationHandler = { _ in
            terminationGroup.leave()
        }

        do {
            try process.run()
        } catch {
            terminationGroup.leave()
            out.closeFile()
            err.closeFile()
            group.wait()
            return (127, stdoutAccum, stderrAccum)
        }

        var timedOut = false
        if terminationGroup.wait(timeout: .now() + shellLookupTimeout) == .timedOut {
            timedOut = true
            if process.isRunning {
                process.terminate()
            }
            if terminationGroup.wait(timeout: .now() + shellLookupTerminationGraceInterval) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                terminationGroup.wait()
            }
        }

        // Wait for exit, then close to unblock readers and join them
        process.waitUntilExit()
        out.closeFile()
        err.closeFile()
        group.wait()
        if timedOut {
            return (124, stdoutAccum, stderrAccum)
        }
        return (process.terminationStatus, stdoutAccum, stderrAccum)
    }

    static func sanitizedExecutableOutput(_ rawLine: String, originalCommand: String, preferredBasenames: [String]? = nil) -> (path: String, isAliasTarget: Bool)? {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        var payload = line[...]
        var isAliasTarget = false

        // Normalize common "alias reveals" formats to the right-hand payload we care about.
        if let aliasRangeColon = line.range(of: ": aliased to ") {
            payload = line[aliasRangeColon.upperBound...]
            isAliasTarget = true
        } else if let aliasRange = line.range(of: " is aliased to ") {
            payload = line[aliasRange.upperBound...]
            isAliasTarget = true
        } else if line.hasPrefix("alias ") {
            let afterAlias = line.dropFirst("alias ".count)
            if let eqIndex = afterAlias.firstIndex(of: "=") {
                payload = afterAlias[afterAlias.index(after: eqIndex)...]
                isAliasTarget = true
            }
        } else if let arrowRange = line.range(of: " -> ") {
            payload = line[arrowRange.upperBound...]
            isAliasTarget = true
        }

        // alias -p/zsh prints the value quoted; strip the *display* quotes/backticks.
        payload = stripOuterQuotesOrBackticks(payload)
        payload = trimWhitespace(payload)

        // If the alias value included trailing command substitution, drop it.
        payload = stripTrailingCommandSubstitutions(payload)

        // Tokenize the unquoted payload so wrappers/env-assignments can be filtered.
        let tokens = shellTokens(payload)
        guard !tokens.isEmpty,
              var candidate = selectExecutableToken(from: tokens, originalCommand: originalCommand, isAliasTarget: isAliasTarget, preferredBasenames: Set((preferredBasenames ?? [originalCommand]).filter { !$0.isEmpty }))
        else {
            return nil
        }

        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }

        // Some shell outputs wrap in parentheses: ( /path/to/prog )
        if candidate.hasPrefix("("), candidate.hasSuffix(")") {
            let inner = candidate.dropFirst().dropLast()
            if inner.contains("/") { candidate = String(inner) }
        }

        let expanded = (candidate as NSString).expandingTildeInPath
        return expanded.isEmpty ? nil : (expanded, isAliasTarget)
    }

    private static let shellLookupTimeout: TimeInterval = 5
    private static let shellLookupTerminationGraceInterval: TimeInterval = 2

    private static let wrapperCommands: Set<String> = [
        "command",
        "env",
        "/usr/bin/env",
        "sudo",
        "exec",
        "noglob",
        "time",
        "nice",
        "nohup",
        "builtin"
    ]

    private static func shellTokens(_ input: Substring) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var escape = false

        func flush() {
            if !current.isEmpty {
                tokens.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }

        var index = input.startIndex
        while index < input.endIndex {
            let ch = input[index]
            if escape {
                current.append(ch)
                escape = false
            } else if ch == "\\" {
                if inSingle {
                    current.append(ch)
                } else {
                    escape = true
                }
            } else if ch == "'" {
                if inDouble {
                    current.append(ch)
                } else {
                    inSingle.toggle()
                }
            } else if ch == "\"" {
                if inSingle {
                    current.append(ch)
                } else {
                    inDouble.toggle()
                }
            } else if ch.isWhitespace, !inSingle, !inDouble {
                flush()
            } else {
                current.append(ch)
            }
            index = input.index(after: index)
        }
        flush()
        return tokens
    }

    private static func selectExecutableToken(from tokens: [String], originalCommand: String, isAliasTarget: Bool, preferredBasenames: Set<String>) -> String? {
        // 1) Filter wrappers and env assignments (same behavior as before)
        var filtered: [String] = []
        var skipEnvAssignments = false
        for token in tokens {
            if token.isEmpty { continue }
            if wrapperCommands.contains(token) {
                skipEnvAssignments = token == "env" || token.hasSuffix("/env")
                continue
            }
            // Drop KEY=VAL anywhere (env inline assignments). Keep rare paths with '=' (very unlikely).
            if isEnvAssignment(token) { continue }
            if token == "is" || token == "=" { continue }
            if token.hasPrefix("$") { continue } // $@, $*, $1, etc.
            if !isAliasTarget, token == originalCommand { continue }
            filtered.append(token)
        }
        guard !filtered.isEmpty else { return nil }

        // 2) If we have a path (alias or direct output), merge path segments that were
        //    split by unquoted spaces, but stop at arguments or operators.
        if let first = filtered.first, first.contains("/") || first.hasPrefix("~") {
            var merged = first
            var i = 1

            // Find the last token that contains a slash - everything up to that is part of the path
            var lastSlashIndex = 0
            for (idx, token) in filtered.enumerated() {
                if token.contains("/") {
                    lastSlashIndex = idx
                }
            }

            while i < filtered.count {
                let t = filtered[i]
                // Stop at arguments and shell metacharacters
                if t.hasPrefix("$") || t.hasPrefix("-") { break }
                if t == "|" || t == "||" || t == "&&" || t == ";" || t == "&" { break }
                if wrapperCommands.contains(t) { break }
                // Stop at env assignments
                if isEnvAssignment(t) { break }

                // Merge tokens up to and including the last token with a slash
                // This handles paths like "/My Dev Tools/claude" -> ["/My", "Dev", "Tools/claude"]
                if i <= lastSlashIndex {
                    merged += " " + t
                    i += 1
                } else {
                    // We're past the last slash - these are arguments
                    break
                }
            }
            // Prefer a basename match if available.
            let base = (merged as NSString).lastPathComponent
            if !preferredBasenames.isEmpty, basenameMatches(base, expected: preferredBasenames) {
                return merged
            }
            return merged
        }

        // 3) Otherwise, pick the first path-like token with a preferred basename; then any path-like token; fallback to the first token.
        if let match = filtered.first(where: { ($0.contains("/") || $0.hasPrefix("~")) && (!preferredBasenames.isEmpty && basenameMatches(($0 as NSString).lastPathComponent, expected: preferredBasenames)) }) {
            return match
        }
        if let withSlash = filtered.first(where: { $0.contains("/") || $0.hasPrefix("~") }) {
            return withSlash
        }
        return filtered.first
    }

    /// NAME=VALUE assignment (outside or inside 'env')
    private static func isEnvAssignment(_ token: String) -> Bool {
        guard let eq = token.firstIndex(of: "=") else { return false }
        let name = token[..<eq]
        return name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    // MARK: - Helpers for alias-display cleanup

    private static func trimWhitespace(_ s: Substring) -> Substring {
        var s = s
        while let f = s.first, f.isWhitespace {
            s = s.dropFirst()
        }
        while let l = s.last, l.isWhitespace {
            s = s.dropLast()
        }
        return s
    }

    private static func stripOuterQuotesOrBackticks(_ input: Substring) -> Substring {
        var s = trimWhitespace(input)
        guard s.count >= 2 else { return s }
        let first = s.first!, last = s.last!
        // Standard pairs: '...', "..."
        if (first == "'" && last == "'") || (first == "\"" && last == "\"") { return s.dropFirst().dropLast() }
        // Backtick pairs: `...`  and zsh's odd `...'
        if first == "`", last == "`" || last == "'" { return s.dropFirst().dropLast() }
        return s
    }

    private static func stripTrailingCommandSubstitutions(_ input: Substring) -> Substring {
        var s = input
        // Cut at first unescaped backtick
        if let idx = firstUnescapedIndex(of: "`", in: s) {
            s = s[..<idx]
            s = trimWhitespace(s)
        }
        // Cut at first $(
        if let r = s.range(of: "$(") {
            s = s[..<r.lowerBound]
            s = trimWhitespace(s)
        }
        return s
    }

    private static func firstUnescapedIndex(of target: Character, in s: Substring) -> String.Index? {
        var inSingle = false, inDouble = false, escape = false
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if escape {
                escape = false
            } else if ch == "\\" {
                if !inSingle { escape = true }
            } else if ch == "'" {
                if !inDouble { inSingle.toggle() }
            } else if ch == "\"" {
                if !inSingle { inDouble.toggle() }
            } else if ch == target, !inSingle, !inDouble {
                return i
            }
            i = s.index(after: i)
        }
        return nil
    }

    private static func userLoginShell() -> String? {
        guard let passwdPointer = getpwuid(getuid()), let shellPointer = passwdPointer.pointee.pw_shell else { return nil }
        return String(cString: shellPointer)
    }
}
