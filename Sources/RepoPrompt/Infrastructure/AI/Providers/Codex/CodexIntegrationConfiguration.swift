import Foundation
import RepoPromptShared

/// Codex-specific integration configuration helpers.
///
/// This namespace owns Codex CLI config.toml parsing/mutation, RepoPrompt MCP
/// installation/repair, and Codex runtime override construction.
enum CodexIntegrationConfiguration {
    static let toolTimeoutDefaultsKey = "CodexToolTimeoutMigratedV5"
    // Codex applies this timeout to every tool on the MCP server. Preserve the existing
    // multi-hour budget because Oracle and Context Builder remain synchronous and have no
    // per-tool timeout exemption.
    static let desiredToolTimeoutSeconds = MCPTimeoutPolicy.codexServerActiveTimeoutSeconds
    static let desiredSupportsParallelToolCalls = true
    static let desiredToolOutputTokenLimit = 25000

    private static let tomlBareKeyCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
    private static let repoPromptMCPConfiguration = RepoPromptMCPServerConfiguration.repoPrompt
    private static let repoPromptMCPServerName = RepoPromptMCPServerConfiguration.defaultServerName
    private static var serverCommand: String {
        repoPromptMCPConfiguration.command
    }

    struct ServerEntry {
        let rawName: String
        let normalizedName: String
        let cliPathComponent: String
    }

    struct PersistentMCPConfigMutationResult {
        let content: String
        let changed: Bool
        let wasRepoPromptServerPresent: Bool
    }

    private struct BlockRange {
        var start: Int
        var end: Int
    }

    private struct TOMLKeyComponent {
        let raw: String
        let normalized: String
    }

    private struct TOMLHeader {
        let keyPath: [TOMLKeyComponent]
        let isArrayTable: Bool
    }

    private struct TOMLAssignment {
        let keyPath: [TOMLKeyComponent]
        let valueText: Substring

        func isSingleKey(_ key: String) -> Bool {
            keyPath.count == 1 && keyPath[0].normalized == key
        }
    }

    struct ToolTimeoutMutationResult {
        let content: String
        let changed: Bool
        let foundTarget: Bool
    }

    /// Codex config overrides for headless agent runs.
    /// Returns array of "-c" flag arguments.
    static func configOverrides(for context: AgentCLIToolContext) -> [String] {
        let toolPolicy = switch context {
        case .agentRun, .discoverRun, .promptOnly:
            CodexOverrides.ToolPolicy(
                toolOutputTokenLimit: desiredToolOutputTokenLimit,
                shellToolEnabled: false,
                webSearchRequestEnabled: false,
                viewImageToolEnabled: false,
                includeApplyPatchTool: false,
                parallelToolCallsEnabled: nil
            )
        case .terminal:
            CodexOverrides.ToolPolicy(
                toolOutputTokenLimit: desiredToolOutputTokenLimit,
                shellToolEnabled: nil,
                webSearchRequestEnabled: nil,
                viewImageToolEnabled: nil,
                includeApplyPatchTool: false,
                parallelToolCallsEnabled: nil
            )
        }

        return CodexOverrides.cliConfigArgs(toolPolicy: toolPolicy)
    }

    static func configDirectoryURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".codex", isDirectory: true)
    }

    static func configURL() -> URL {
        configDirectoryURL().appendingPathComponent("config.toml")
    }

    static func cliPathComponent(forNormalizedServerName name: String) -> String {
        guard !name.isEmpty else { return "\"\"" }
        if name.unicodeScalars.allSatisfy({ tomlBareKeyCharacters.contains($0) }) {
            return name
        }

        var escaped = ""
        escaped.reserveCapacity(name.count)
        for scalar in name.unicodeScalars {
            let character = Character(scalar)
            switch character {
            case "\"":
                escaped.append("\\\"")
            case "\\":
                escaped.append("\\\\")
            case "\n":
                escaped.append("\\n")
            case "\r":
                escaped.append("\\r")
            case "\t":
                escaped.append("\\t")
            default:
                escaped.append(character)
            }
        }

        return "\"\(escaped)\""
    }

    static func mcpServerEntries() -> [ServerEntry] {
        let fm = FileManager.default
        let configURL = configURL()
        guard fm.fileExists(atPath: configURL.path) else { return [] }
        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else { return [] }
        return mcpServerEntries(fromConfigContent: content)
    }

    static func mcpServerEntries(from content: String) -> [ServerEntry] {
        mcpServerEntries(fromConfigContent: content)
    }

    static func mcpServerEntries(fromConfigContent content: String) -> [ServerEntry] {
        var seenNormalizedNames = Set<String>()
        var ordered: [ServerEntry] = []

        for line in splitTOMLLines(content) {
            guard let serverName = mcpServerName(fromHeaderLine: line) else { continue }
            guard !serverName.normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard seenNormalizedNames.insert(serverName.normalized).inserted else { continue }

            let cliPath = cliPathComponent(forNormalizedServerName: serverName.normalized)
            ordered.append(ServerEntry(rawName: serverName.raw, normalizedName: serverName.normalized, cliPathComponent: cliPath))
        }

        return ordered
    }

    static func mcpServerNames() -> [String] {
        mcpServerEntries().map(\.normalizedName)
    }

    /// Installs the RepoPrompt MCP server into Codex CLI (`~/.codex/config.toml`).
    ///
    /// Invoked from the UI when users opt-in to the integration. Ensures our MCP server exists and is
    /// enabled globally so Codex can use it outside of discovery runs.
    @discardableResult
    static func installPersistentMCPConfig() -> (success: Bool, wasAlreadyPresent: Bool) {
        let fm = FileManager.default
        let codexDir = configDirectoryURL()
        let configURL = configURL()

        do {
            try fm.createDirectory(at: codexDir, withIntermediateDirectories: true, attributes: nil)

            let content: String = if fm.fileExists(atPath: configURL.path) {
                (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
            } else {
                ""
            }

            let mutation = mutatedPersistentMCPConfigContent(
                from: content,
                defaultEnabledIfMissing: true,
                forceEnabled: true
            )
            if mutation.changed {
                try mutation.content.write(to: configURL, atomically: true, encoding: .utf8)
            }

            UserDefaults.standard.set(true, forKey: toolTimeoutDefaultsKey)
            return (true, mutation.wasRepoPromptServerPresent)
        } catch {
            print("CodexIntegrationConfiguration – Codex install failed: \(error)")
            return (false, false)
        }
    }

    /// Ensures the RepoPrompt MCP server exists for discovery runs. Newly created entries default to
    /// `enabled = false` so normal Codex usage stays opt-in, while the agent enables it at runtime via
    /// `-c` overrides.
    @discardableResult
    static func ensureServerForDiscovery() -> (success: Bool, wasAlreadyPresent: Bool) {
        let fm = FileManager.default
        let codexDir = configDirectoryURL()
        let configURL = configURL()

        do {
            try fm.createDirectory(at: codexDir, withIntermediateDirectories: true, attributes: nil)

            let content: String = if fm.fileExists(atPath: configURL.path) {
                (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
            } else {
                ""
            }

            let mutation = mutatedPersistentMCPConfigContent(
                from: content,
                defaultEnabledIfMissing: false,
                forceEnabled: nil
            )
            if mutation.changed {
                try mutation.content.write(to: configURL, atomically: true, encoding: .utf8)
            }
            UserDefaults.standard.set(true, forKey: toolTimeoutDefaultsKey)

            return (true, mutation.wasRepoPromptServerPresent)
        } catch {
            print("CodexIntegrationConfiguration – Codex discovery ensure failed: \(error)")
            return (false, false)
        }
    }

    static func mutatedPersistentMCPConfigContent(
        from content: String,
        defaultEnabledIfMissing: Bool,
        forceEnabled: Bool?
    ) -> PersistentMCPConfigMutationResult {
        var lines = splitTOMLLines(content)
        let ensureResult = ensureRepoPromptServer(
            in: &lines,
            defaultEnabledIfMissing: defaultEnabledIfMissing,
            forceEnabled: forceEnabled
        )

        _ = stripToolOutputLimitFromRepoPromptBlocks(in: &lines)
        _ = ensureGlobalToolOutputLimit(in: &lines)

        let final = lines.joined(separator: "\n")
        return PersistentMCPConfigMutationResult(
            content: final,
            changed: final != content,
            wasRepoPromptServerPresent: ensureResult.wasPresent
        )
    }

    static func configContainsRepoPrompt() -> Bool {
        mcpServerEntries().contains {
            $0.normalizedName == repoPromptMCPServerName
        }
    }

    static func removeInstallEntry() {
        let fm = FileManager.default
        let configURL = configURL()
        guard fm.fileExists(atPath: configURL.path) else { return }
        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else { return }

        var lines = splitTOMLLines(content)
        let blocks = blockRanges(in: lines, whereHeaderMatches: isRepoPromptMCPServerHeader)
        guard !blocks.isEmpty else { return }

        removeBlockRanges(blocks, from: &lines)

        while lines.last?.isEmpty == true {
            lines.removeLast()
        }

        let final = lines.joined(separator: "\n")
        do {
            try final.write(to: configURL, atomically: true, encoding: .utf8)
        } catch {
            print("CodexIntegrationConfiguration – Failed to remove Codex entry: \(error)")
        }
    }

    /// Ensures existing Codex CLI configs include the RepoPrompt MCP policy required by V5:
    /// the preserved 10,000-active-second server timeout and enabled parallel tool calls.
    ///
    /// Codex has no per-tool timeout exemption, so lowering this server-wide value would also
    /// truncate synchronous Oracle and Context Builder operations that can legitimately run for hours.
    /// - Parameter force: When true, bypasses the once-per-install guard and rechecks the file.
    /// - Returns: `true` if the RepoPrompt entry was located and now has the desired policy.
    @discardableResult
    static func ensureToolTimeout(force: Bool = false) -> Bool {
        let defaults = UserDefaults.standard
        if !force, defaults.bool(forKey: toolTimeoutDefaultsKey) {
            return true
        }

        let fm = FileManager.default
        let configURL = configURL()
        guard fm.fileExists(atPath: configURL.path) else { return false }
        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else { return false }

        let mutation = mutatedToolTimeoutConfigContent(from: content)
        guard mutation.foundTarget else { return false }

        if mutation.changed {
            do {
                try mutation.content.write(to: configURL, atomically: true, encoding: .utf8)
            } catch {
                return false
            }
        }

        defaults.set(true, forKey: toolTimeoutDefaultsKey)
        return true
    }

    static func mutatedToolTimeoutConfigContent(from content: String) -> ToolTimeoutMutationResult {
        var lines = content.components(separatedBy: "\n")
        let desiredCommand = canonicalizedPath(for: serverCommand)

        var sectionStart: Int?
        var isRepoPromptSection = false
        var commandMatches = false
        var foundTarget = false
        var needsWrite = false
        var completed = false

        func resetSectionState(at index: Int, isRepoPrompt: Bool) {
            sectionStart = index
            isRepoPromptSection = isRepoPrompt
            commandMatches = false
        }

        func finalizeSection(before index: Int) {
            guard isRepoPromptSection, commandMatches, !completed else { return }
            foundTarget = true

            if let sectionStart {
                var block = BlockRange(start: sectionStart, end: index)
                if ensureRepoPromptPolicyKeys(in: &lines, blockRange: &block) {
                    needsWrite = true
                }
            }

            completed = true
        }

        var idx = 0
        while idx < lines.count {
            let line = lines[idx]

            if isTOMLHeaderLine(line) {
                finalizeSection(before: idx)
                if completed { break }
                resetSectionState(at: idx, isRepoPrompt: isRepoPromptMCPServerHeader(line))
                idx += 1
                continue
            }

            if isRepoPromptSection,
               let assignment = parseTOMLAssignment(line),
               assignment.isSingleKey("command"),
               let value = parseTOMLStringValue(assignment.valueText)
            {
                if canonicalizedPath(for: value) == desiredCommand {
                    commandMatches = true
                }
            }

            idx += 1
        }

        if !completed {
            finalizeSection(before: lines.count)
        }

        if foundTarget {
            if stripToolOutputLimitFromRepoPromptBlocks(in: &lines) {
                needsWrite = true
            }

            if ensureGlobalToolOutputLimit(in: &lines) {
                needsWrite = true
            }
        }

        let final = lines.joined(separator: "\n")
        return ToolTimeoutMutationResult(content: final, changed: final != content || needsWrite, foundTarget: foundTarget)
    }

    static func ensureToolTimeout(in lines: inout [String]) -> (foundTarget: Bool, changed: Bool) {
        let content = lines.joined(separator: "\n")
        let mutation = mutatedToolTimeoutConfigContent(from: content)
        if mutation.changed {
            lines = mutation.content.components(separatedBy: "\n")
        }
        return (mutation.foundTarget, mutation.changed)
    }

    private static func splitTOMLLines(_ content: String) -> [String] {
        guard !content.isEmpty else { return [] }
        return content.components(separatedBy: "\n")
    }

    private static func parseTOMLHeader(_ line: String) -> TOMLHeader? {
        let text = stripLeadingBOM(from: line)
        var index = text.startIndex
        skipWhitespace(in: text, from: &index)
        guard index < text.endIndex, text[index] == "[" else { return nil }

        let afterOpen = text.index(after: index)
        let isArrayTable = afterOpen < text.endIndex && text[afterOpen] == "["
        let contentStart = isArrayTable ? text.index(after: afterOpen) : afterOpen
        var cursor = contentStart
        var closingStart: String.Index?
        var closingEnd: String.Index?
        var quote: Character?
        var escaped = false

        while cursor < text.endIndex {
            let ch = text[cursor]
            if let activeQuote = quote {
                if activeQuote == "\"", escaped {
                    escaped = false
                } else if activeQuote == "\"", ch == "\\" {
                    escaped = true
                } else if ch == activeQuote {
                    quote = nil
                }
                cursor = text.index(after: cursor)
                continue
            }

            if ch == "\"" || ch == "'" {
                quote = ch
                cursor = text.index(after: cursor)
                continue
            }

            if ch == "]" {
                let next = text.index(after: cursor)
                if isArrayTable {
                    if next < text.endIndex, text[next] == "]" {
                        closingStart = cursor
                        closingEnd = text.index(after: next)
                        break
                    }
                } else {
                    closingStart = cursor
                    closingEnd = next
                    break
                }
            }

            cursor = text.index(after: cursor)
        }

        guard let closingStart, let closingEnd else { return nil }
        let trailing = text[closingEnd...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard trailing.isEmpty || trailing.hasPrefix("#") else { return nil }

        let keyText = String(text[contentStart ..< closingStart])
        guard let keyPath = parseTOMLKeyPath(keyText), !keyPath.isEmpty else { return nil }
        return TOMLHeader(keyPath: keyPath, isArrayTable: isArrayTable)
    }

    private static func isTOMLHeaderLine(_ line: String) -> Bool {
        parseTOMLHeader(line) != nil
    }

    private static func mcpServerName(fromHeaderLine line: String) -> TOMLKeyComponent? {
        guard let header = parseTOMLHeader(line), !header.isArrayTable else { return nil }
        guard header.keyPath.count == 2, header.keyPath[0].normalized == "mcp_servers" else { return nil }
        return header.keyPath[1]
    }

    private static func isRepoPromptMCPServerHeader(_ line: String) -> Bool {
        mcpServerName(fromHeaderLine: line)?.normalized == repoPromptMCPServerName
    }

    private static func parseTOMLAssignment(_ line: String) -> TOMLAssignment? {
        let text = stripLeadingBOM(from: line)
        var index = text.startIndex
        skipWhitespace(in: text, from: &index)
        guard index < text.endIndex, text[index] != "#" else { return nil }

        var cursor = index
        var quote: Character?
        var escaped = false
        while cursor < text.endIndex {
            let ch = text[cursor]
            if let activeQuote = quote {
                if activeQuote == "\"", escaped {
                    escaped = false
                } else if activeQuote == "\"", ch == "\\" {
                    escaped = true
                } else if ch == activeQuote {
                    quote = nil
                }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "#" {
                return nil
            } else if ch == "=" {
                let keyText = String(text[..<cursor])
                guard let keyPath = parseTOMLKeyPath(keyText), !keyPath.isEmpty else { return nil }
                return TOMLAssignment(keyPath: keyPath, valueText: text[text.index(after: cursor)...])
            }
            cursor = text.index(after: cursor)
        }

        return nil
    }

    private static func parseTOMLKeyPath(_ text: String) -> [TOMLKeyComponent]? {
        let text = stripLeadingBOM(from: text)
        var index = text.startIndex
        var components: [TOMLKeyComponent] = []
        var expectingComponent = true

        while true {
            skipWhitespace(in: text, from: &index)
            guard index < text.endIndex else {
                return (!components.isEmpty && !expectingComponent) ? components : nil
            }

            let component: TOMLKeyComponent
            if text[index] == "\"" {
                guard let parsed = parseQuotedTOMLKeyComponent(in: text, from: index, quote: "\"") else { return nil }
                component = parsed.component
                index = parsed.endIndex
            } else if text[index] == "'" {
                guard let parsed = parseQuotedTOMLKeyComponent(in: text, from: index, quote: "'") else { return nil }
                component = parsed.component
                index = parsed.endIndex
            } else {
                let start = index
                while index < text.endIndex,
                      let scalar = text[index].unicodeScalars.first,
                      tomlBareKeyCharacters.contains(scalar)
                {
                    index = text.index(after: index)
                }
                guard start < index else { return nil }
                let raw = String(text[start ..< index])
                component = TOMLKeyComponent(raw: raw, normalized: raw)
            }

            components.append(component)
            expectingComponent = false
            skipWhitespace(in: text, from: &index)
            if index == text.endIndex { return components }
            guard text[index] == "." else { return nil }
            index = text.index(after: index)
            expectingComponent = true
        }
    }

    private static func parseQuotedTOMLKeyComponent(
        in text: String,
        from start: String.Index,
        quote: Character
    ) -> (component: TOMLKeyComponent, endIndex: String.Index)? {
        var cursor = text.index(after: start)
        var escaped = false
        var inner = ""

        while cursor < text.endIndex {
            let ch = text[cursor]
            if quote == "\"", escaped {
                inner.append("\\")
                inner.append(ch)
                escaped = false
                cursor = text.index(after: cursor)
                continue
            }
            if quote == "\"", ch == "\\" {
                escaped = true
                cursor = text.index(after: cursor)
                continue
            }
            if ch == quote {
                let end = text.index(after: cursor)
                let raw = String(text[start ..< end])
                let normalized = quote == "\""
                    ? decodeDoubleQuotedTomlKey(inner)
                    : inner.replacingOccurrences(of: "''", with: "'")
                return (TOMLKeyComponent(raw: raw, normalized: normalized), end)
            }
            inner.append(ch)
            cursor = text.index(after: cursor)
        }

        return nil
    }

    private static func isKeyLine(_ line: String, singleKey key: String) -> Bool {
        parseTOMLAssignment(line)?.isSingleKey(key) == true
    }

    private static func isToolOutputTokenLimitAssignment(_ line: String) -> Bool {
        guard let assignment = parseTOMLAssignment(line), assignment.isSingleKey("tool_output_token_limit") else { return false }
        return parseTOMLIntegerValue(assignment.valueText) != nil
    }

    private static func parseTOMLStringValue(_ valueText: Substring) -> String? {
        let text = String(valueText)
        var index = text.startIndex
        skipWhitespace(in: text, from: &index)
        guard index < text.endIndex else { return nil }
        let quote = text[index]
        guard quote == "\"" || quote == "'" else { return nil }

        var cursor = text.index(after: index)
        var escaped = false
        var inner = ""
        while cursor < text.endIndex {
            let ch = text[cursor]
            if quote == "\"", escaped {
                inner.append("\\")
                inner.append(ch)
                escaped = false
                cursor = text.index(after: cursor)
                continue
            }
            if quote == "\"", ch == "\\" {
                escaped = true
                cursor = text.index(after: cursor)
                continue
            }
            if ch == quote {
                let trailing = text[text.index(after: cursor)...].trimmingCharacters(in: .whitespacesAndNewlines)
                guard trailing.isEmpty || trailing.hasPrefix("#") else { return nil }
                return quote == "\"" ? decodeDoubleQuotedTomlKey(inner) : inner
            }
            inner.append(ch)
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private static func parseTOMLBooleanValue(_ valueText: Substring) -> Bool? {
        let stripped = stripComment(fromValueText: String(valueText))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch stripped {
        case "true":
            return true
        case "false":
            return false
        default:
            return nil
        }
    }

    private static func parseTOMLIntegerValue(_ valueText: Substring) -> Int? {
        let stripped = stripComment(fromValueText: String(valueText)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty, !stripped.hasPrefix("\""), !stripped.hasPrefix("'") else { return nil }

        let sign: Int
        let digitsStart: String.Index
        if stripped.hasPrefix("+") {
            sign = 1
            digitsStart = stripped.index(after: stripped.startIndex)
        } else if stripped.hasPrefix("-") {
            sign = -1
            digitsStart = stripped.index(after: stripped.startIndex)
        } else {
            sign = 1
            digitsStart = stripped.startIndex
        }

        guard digitsStart < stripped.endIndex else { return nil }
        let unsignedText = String(stripped[digitsStart...])
        let radix: Int
        let digitText: String
        if unsignedText.hasPrefix("0x") || unsignedText.hasPrefix("0X") {
            radix = 16
            digitText = String(unsignedText.dropFirst(2))
        } else if unsignedText.hasPrefix("0o") || unsignedText.hasPrefix("0O") {
            radix = 8
            digitText = String(unsignedText.dropFirst(2))
        } else if unsignedText.hasPrefix("0b") || unsignedText.hasPrefix("0B") {
            radix = 2
            digitText = String(unsignedText.dropFirst(2))
        } else {
            radix = 10
            digitText = unsignedText
            let digitsOnly = digitText.replacingOccurrences(of: "_", with: "")
            if digitsOnly.count > 1, digitsOnly.first == "0" { return nil }
        }

        guard isValidTOMLIntegerDigits(digitText, radix: radix) else { return nil }
        guard let value = Int(digitText.replacingOccurrences(of: "_", with: ""), radix: radix) else { return nil }
        return sign * value
    }

    private static func isValidTOMLIntegerDigits(_ text: String, radix: Int) -> Bool {
        guard !text.isEmpty else { return false }
        var previousWasUnderscore = false
        var sawDigit = false

        for ch in text {
            if ch == "_" {
                guard sawDigit, !previousWasUnderscore else { return false }
                previousWasUnderscore = true
                continue
            }

            guard ch.wholeNumberValue != nil || (radix == 16 && ("a" ... "f").contains(ch.lowercased())) else { return false }
            if let value = ch.wholeNumberValue {
                guard value < radix else { return false }
            }
            sawDigit = true
            previousWasUnderscore = false
        }

        return sawDigit && !previousWasUnderscore
    }

    private static func stripComment(fromValueText text: String) -> String {
        var cursor = text.startIndex
        var quote: Character?
        var escaped = false
        while cursor < text.endIndex {
            let ch = text[cursor]
            if let activeQuote = quote {
                if activeQuote == "\"", escaped {
                    escaped = false
                } else if activeQuote == "\"", ch == "\\" {
                    escaped = true
                } else if ch == activeQuote {
                    quote = nil
                }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "#" {
                return String(text[..<cursor])
            }
            cursor = text.index(after: cursor)
        }
        return text
    }

    private static func stripLeadingBOM(from text: String) -> String {
        var text = text
        var index = text.startIndex
        skipWhitespace(in: text, from: &index)
        if index < text.endIndex, text[index] == "\u{FEFF}" {
            text.remove(at: index)
        }
        return text
    }

    private static func skipWhitespace(in text: String, from index: inout String.Index) {
        while index < text.endIndex, text[index].unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
            index = text.index(after: index)
        }
    }

    private static func decodeDoubleQuotedTomlKey(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)

        var iterator = value.makeIterator()
        while let ch = iterator.next() {
            if ch == "\\" {
                guard let next = iterator.next() else {
                    result.append("\\")
                    break
                }
                switch next {
                case "\"":
                    result.append("\"")
                case "\\":
                    result.append("\\")
                case "b":
                    result.append("\u{08}")
                case "t":
                    result.append("\t")
                case "n":
                    result.append("\n")
                case "f":
                    result.append("\u{0C}")
                case "r":
                    result.append("\r")
                case "u":
                    var hex = ""
                    for _ in 0 ..< 4 {
                        if let digit = iterator.next() {
                            hex.append(digit)
                        } else {
                            break
                        }
                    }
                    if hex.count == 4,
                       let scalar = UInt32(hex, radix: 16),
                       let unicode = UnicodeScalar(scalar)
                    {
                        result.append(Character(unicode))
                    } else {
                        result.append("\\u")
                        result.append(hex)
                    }
                default:
                    result.append(next)
                }
            } else {
                result.append(ch)
            }
        }

        return result
    }

    static func ensureRepoPromptServer(
        in lines: inout [String],
        defaultEnabledIfMissing: Bool,
        forceEnabled: Bool?
    ) -> (changed: Bool, wasPresent: Bool) {
        var changed = false
        var blocks = blockRanges(in: lines, whereHeaderMatches: isRepoPromptMCPServerHeader)
        let wasPresent = !blocks.isEmpty
        var addedBlock = false

        if blocks.count > 1 {
            removeBlockRanges(Array(blocks.dropFirst()), from: &lines)
            changed = true
            blocks = blockRanges(in: lines, whereHeaderMatches: isRepoPromptMCPServerHeader)
        }

        if blocks.isEmpty {
            addedBlock = true
            appendBlock(
                repoPromptSnippetLines(
                    enabled: defaultEnabledIfMissing,
                    includeEnabled: true // newly created entries always specify enabled state
                ),
                to: &lines
            )
            changed = true
            blocks = blockRanges(in: lines, whereHeaderMatches: isRepoPromptMCPServerHeader)
        }

        guard var block = blocks.first else {
            return (changed, wasPresent)
        }

        let shouldIncludeEnabledKey = (forceEnabled != nil) || defaultEnabledIfMissing || addedBlock

        if ensureKey("command", value: "\"\(serverCommand)\"", in: &lines, blockRange: &block, force: true) {
            changed = true
        }
        if ensureKey("args", value: "[]", in: &lines, blockRange: &block, afterKey: "command", force: true) {
            changed = true
        }
        if ensureRepoPromptPolicyKeys(in: &lines, blockRange: &block) {
            changed = true
        }

        if shouldIncludeEnabledKey {
            let desiredEnabled = (forceEnabled ?? defaultEnabledIfMissing) ? "true" : "false"
            let forceFlag = forceEnabled != nil
            if ensureKey("enabled", value: desiredEnabled, in: &lines, blockRange: &block, afterKey: "supports_parallel_tool_calls", force: forceFlag) {
                changed = true
            }
        }

        return (changed, wasPresent)
    }

    private static func blockRanges(
        in lines: [String],
        whereHeaderMatches predicate: (String) -> Bool
    ) -> [BlockRange] {
        var ranges: [BlockRange] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            if isTOMLHeaderLine(line) {
                let blockEnd = nextHeaderIndex(after: index + 1, in: lines)
                if predicate(line) {
                    ranges.append(BlockRange(start: index, end: blockEnd))
                }
                index = blockEnd
            } else {
                index += 1
            }
        }

        return ranges
    }

    private static func nextHeaderIndex(after start: Int, in lines: [String]) -> Int {
        var idx = start
        while idx < lines.count {
            if isTOMLHeaderLine(lines[idx]) {
                return idx
            }
            idx += 1
        }
        return lines.count
    }

    private static func removeBlockRanges(_ ranges: [BlockRange], from lines: inout [String]) {
        for range in ranges.sorted(by: { $0.start > $1.start }) {
            lines.removeSubrange(range.start ..< range.end)
        }
    }

    private static func appendBlock(_ blockLines: [String], to lines: inout [String]) {
        if lines.isEmpty {
            lines.append(contentsOf: blockLines)
            return
        }

        if let last = lines.last, !last.isEmpty {
            lines.append("")
        }

        lines.append(contentsOf: blockLines)
    }

    private static func ensureGlobalToolOutputLimit(in lines: inout [String]) -> Bool {
        let firstHeaderIndex = lines.firstIndex(where: isTOMLHeaderLine) ?? lines.count

        var limitLineIndices: [Int] = []
        for idx in 0 ..< firstHeaderIndex where isToolOutputTokenLimitAssignment(lines[idx]) {
            limitLineIndices.append(idx)
        }

        if !limitLineIndices.isEmpty {
            // Respect the first user-defined global value exactly as written, but repair duplicates.
            for duplicateIndex in limitLineIndices.dropFirst().reversed() {
                lines.remove(at: duplicateIndex)
            }
            return limitLineIndices.count > 1
        }

        // No valid global limit found; insert the desired default.
        lines.insert("tool_output_token_limit = \(desiredToolOutputTokenLimit)", at: firstHeaderIndex)
        return true
    }

    @discardableResult
    private static func stripToolOutputLimitFromRepoPromptBlocks(in lines: inout [String]) -> Bool {
        var changed = false

        for block in blockRanges(in: lines, whereHeaderMatches: isRepoPromptMCPServerHeader).sorted(by: { $0.start > $1.start }) {
            let indices = keyLineIndices(for: "tool_output_token_limit", in: lines, within: block)
            guard !indices.isEmpty else { continue }
            for idx in indices.reversed() {
                lines.remove(at: idx)
            }
            changed = true
        }

        return changed
    }

    private static func ensureRepoPromptPolicyKeys(
        in lines: inout [String],
        blockRange: inout BlockRange
    ) -> Bool {
        var changed = false
        let timeoutInsertionKey = firstIndex(ofKey: "args", in: lines, within: blockRange) == nil
            ? "command"
            : "args"

        if ensureKey(
            "tool_timeout_sec",
            value: "\(desiredToolTimeoutSeconds)",
            in: &lines,
            blockRange: &blockRange,
            afterKey: timeoutInsertionKey,
            force: true,
            isSemanticallyEquivalent: { parseTOMLIntegerValue($0) == desiredToolTimeoutSeconds }
        ) {
            changed = true
        }
        if ensureKey(
            "supports_parallel_tool_calls",
            value: "\(desiredSupportsParallelToolCalls)",
            in: &lines,
            blockRange: &blockRange,
            afterKey: "tool_timeout_sec",
            force: true,
            isSemanticallyEquivalent: { parseTOMLBooleanValue($0) == desiredSupportsParallelToolCalls }
        ) {
            changed = true
        }

        return changed
    }

    private static func ensureKey(
        _ key: String,
        value: String,
        in lines: inout [String],
        blockRange: inout BlockRange,
        afterKey: String? = nil,
        force: Bool = false,
        isSemanticallyEquivalent: ((Substring) -> Bool)? = nil
    ) -> Bool {
        var changed = false
        let desiredLine = "\(key) = \(value)"
        let indices = keyLineIndices(for: key, in: lines, within: blockRange)

        if let first = indices.first {
            let preferred = if let isSemanticallyEquivalent {
                indices.first { index in
                    parseTOMLAssignment(lines[index]).map { assignment in
                        isSemanticallyEquivalent(assignment.valueText)
                    } ?? false
                } ?? first
            } else {
                first
            }
            let trimmed = lines[preferred].trimmingCharacters(in: .whitespacesAndNewlines)
            let equivalent = parseTOMLAssignment(lines[preferred]).map { assignment in
                isSemanticallyEquivalent?(assignment.valueText) ?? false
            } ?? false
            if force, !equivalent, trimmed != desiredLine {
                lines[preferred] = desiredLine
                changed = true
            }

            for extra in indices.filter({ $0 != preferred }).reversed() {
                lines.remove(at: extra)
                blockRange.end -= 1
                changed = true
            }
        } else {
            let insertionIndex: Int = if let afterKey,
                                         let afterIndex = firstIndex(ofKey: afterKey, in: lines, within: blockRange)
            {
                afterIndex + 1
            } else {
                blockRange.start + 1
            }

            lines.insert(desiredLine, at: insertionIndex)
            blockRange.end += 1
            changed = true
        }

        return changed
    }

    private static func keyLineIndices(
        for key: String,
        in lines: [String],
        within blockRange: BlockRange
    ) -> [Int] {
        var indices: [Int] = []
        if blockRange.start + 1 >= blockRange.end { return indices }
        for idx in (blockRange.start + 1) ..< blockRange.end {
            if isKeyLine(lines[idx], singleKey: key) {
                indices.append(idx)
            }
        }
        return indices
    }

    private static func firstIndex(
        ofKey key: String,
        in lines: [String],
        within blockRange: BlockRange
    ) -> Int? {
        keyLineIndices(for: key, in: lines, within: blockRange).first
    }

    private static func repoPromptSnippetLines(enabled: Bool, includeEnabled: Bool) -> [String] {
        var lines = [
            "[mcp_servers.\(cliPathComponent(forNormalizedServerName: repoPromptMCPServerName))]",
            "command = \"\(serverCommand)\"",
            "args = []",
            "tool_timeout_sec = \(desiredToolTimeoutSeconds)",
            "supports_parallel_tool_calls = \(desiredSupportsParallelToolCalls)"
        ]
        if includeEnabled {
            lines.append("enabled = \(enabled ? "true" : "false")")
        }
        return lines
    }

    private static func canonicalizedPath(for path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
