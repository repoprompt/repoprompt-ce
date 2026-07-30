import Foundation
import RepoPromptRegexCore

enum RepoPromptSearchRegexRuntime {
    static var pcre2SearchMatchLimitsEnabled: Bool {
        let rawValue = ProcessInfo.processInfo.environment["REPOPROMPT_PCRE2_MATCH_LIMITS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch rawValue {
        case "0", "false", "off", "no", "disable", "disabled":
            return false
        default:
            return true
        }
    }
}

enum RepoPromptPCRE2MatchPolicy {
    static var fileSearchFullBuffer: PCRE2MatchLimits? {
        guard RepoPromptSearchRegexRuntime.pcre2SearchMatchLimitsEnabled else { return nil }
        return PCRE2MatchLimits(matchLimit: 10_000_000, depthLimit: 100_000, heapLimitKiB: 64 * 1024)
    }

    static var fileSearchLine: PCRE2MatchLimits? {
        guard RepoPromptSearchRegexRuntime.pcre2SearchMatchLimitsEnabled else { return nil }
        return PCRE2MatchLimits(matchLimit: 1_000_000, depthLimit: 10000, heapLimitKiB: 16 * 1024)
    }

    static var pathSearchShortSubject: PCRE2MatchLimits? {
        guard RepoPromptSearchRegexRuntime.pcre2SearchMatchLimitsEnabled else { return nil }
        return PCRE2MatchLimits(matchLimit: 100_000, depthLimit: 1000, heapLimitKiB: 4 * 1024)
    }
}

struct RepoPromptPCRE2CompileResult {
    let regex: PCRE2Regex
    let compiledPattern: String
    let wasRepaired: Bool
}

struct RepoPromptPCRE2CompileRequest {
    let pattern: String
    let caseInsensitive: Bool
    let multilineAnchors: Bool
    let jitMode: PCRE2JITMode

    init(
        pattern: String,
        caseInsensitive: Bool,
        multilineAnchors: Bool,
        jitMode: PCRE2JITMode? = nil
    ) {
        self.pattern = pattern
        self.caseInsensitive = caseInsensitive
        self.multilineAnchors = multilineAnchors
        self.jitMode = jitMode ?? RepoPromptRegexRuntime.pcre2JITMode
    }
}

enum RepoPromptPCRE2Adapter {
    static func compile(_ request: RepoPromptPCRE2CompileRequest) throws -> PCRE2Regex {
        var options = PCRE2CompileOptions.defaultRegex
        if request.caseInsensitive {
            options.insert(.caseless)
        }
        if request.multilineAnchors {
            options.insert(.multiline)
        }
        return try PCRE2Regex(request.pattern, options: options, jit: request.jitMode)
    }

    static func searchPatternError(from error: Error, pattern: String) -> RegexPatternFailure {
        if let failure = error as? RegexPatternFailure {
            return failure
        }
        if let pcreError = error as? PCRE2Error {
            switch pcreError {
            case let .compile(_, offset, code, message):
                return SearchPatternError.invalidRegex(
                    pattern,
                    compileErrorDetails(pattern: pattern, offset: offset, code: code, message: message)
                )
            case .match:
                return SearchPatternError.invalidRegex(pattern, "Regex matching failed. Try simplifying the pattern or narrowing the search.")
            case .matchLimitExceeded:
                return SearchPatternError.invalidRegex(pattern, "Regex matching took too long; simplify the pattern or narrow the search.")
            case .jitRequiredButUnavailable:
                return SearchPatternError.invalidRegex(pattern, "Regex matching is unavailable for this pattern; try simplifying it or using a literal search.")
            case .internalInvariant:
                return SearchPatternError.invalidRegex(pattern, "Regex processing failed. Try simplifying the pattern or using a literal search.")
            }
        }
        return SearchPatternError.invalidRegex(pattern, error.localizedDescription)
    }

    static func isVariableLengthLookbehindError(pattern: String, details: String) -> Bool {
        guard pattern.contains("(?<=") || pattern.contains("(?<!") else { return false }
        let normalized = details.lowercased()
        return normalized.contains("lookbehind") && (
            normalized.contains("fixed length") ||
                normalized.contains("not fixed") ||
                normalized.contains("variable") ||
                normalized.contains("bounded") ||
                normalized.contains("not limited") ||
                normalized.contains("maximum length")
        )
    }

    static func variableLengthLookbehindSuggestion(pattern: String) -> String? {
        guard pattern.contains("(?<=") || pattern.contains("(?<!") else { return nil }
        return "Use a fixed-width lookbehind, or rewrite the search as a line-level lookahead. For example, to find GetComponent only on lines that do not contain //, use `(?m)^(?!.*\\/\\/).*GetComponent`."
    }

    private static func compileErrorDetails(pattern: String, offset: Int, code: Int32, message: String) -> String {
        let rawDetails = "\(message) code=\(code) offset=\(offset)"
        if isVariableLengthLookbehindError(pattern: pattern, details: rawDetails) {
            return "Variable-length lookbehinds are not supported in file_search regex patterns. Lookbehind assertions must have a fixed or bounded length, so constructs like `.*`, `.+`, or `{n,}` inside `(?<=...)` / `(?<!...)` cannot compile."
        }

        return "The regular expression could not be compiled. \(friendlyCompileFailureHint(message))"
    }

    private static func friendlyCompileFailureHint(_ message: String) -> String {
        let normalized = message.lowercased()
        if normalized.contains("missing terminating ]") || normalized.contains("missing terminating ] for character class") {
            return "A character class is missing its closing `]`."
        }
        if normalized.contains("parentheses") || normalized.contains("parenthesis") {
            return "Check that all groups have matching parentheses, or escape literal parentheses as `\\(` and `\\)`."
        }
        if normalized.contains("quantifier") {
            return "Check quantifier syntax such as `*`, `+`, `?`, or `{n,m}`."
        }
        return "Check the regex syntax, remove unsupported constructs, or simplify the pattern."
    }

    static func escapedLiteral(_ literal: String) -> String {
        PCRE2Literal.escapedPattern(for: literal)
    }

    static func compressDoubleEscapesBeforeMeta(_ pattern: String) -> String {
        let regexMeta: Set<Character> = ["(", ")", "[", "]", "{", "}", ".", "*", "+", "?", "|", "^", "$"]
        let chars = Array(pattern)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var index = 0
        while index < chars.count {
            if index < chars.count - 2,
               chars[index] == "\\",
               chars[index + 1] == "\\",
               regexMeta.contains(chars[index + 2])
            {
                out.append("\\")
                out.append(chars[index + 2])
                index += 3
            } else {
                out.append(chars[index])
                index += 1
            }
        }
        return String(out)
    }

    static func anchoredDeclarationLinePlan(
        for pattern: String,
        caseInsensitive: Bool
    ) -> PCRE2AnchoredDeclarationLinePattern? {
        guard pattern == #"^\s*(?:final\s+)?(?:class|struct|func)\s+[A-Za-z_][A-Za-z0-9_]*"# else {
            return nil
        }
        return PCRE2AnchoredDeclarationLinePattern(caseInsensitive: caseInsensitive)
    }

    static func linePrefilterForAnchoredPattern(
        _ pattern: String,
        caseInsensitive: Bool
    ) -> PCRE2LinePrefilter? {
        let requiredAlternatives: [String]
        switch pattern {
        case #"^\s*(?:final\s+)?(?:class|struct|func)\s+[A-Za-z_][A-Za-z0-9_]*"#:
            requiredAlternatives = ["class", "struct", "func"]
        case #"^\s*(?:class|struct|func)\b"#,
             #"^\s*(class|struct|func)\b"#:
            requiredAlternatives = ["class", "struct", "func"]
        case #"^import\b"#:
            requiredAlternatives = ["import"]
        default:
            return nil
        }
        return PCRE2LinePrefilter(asciiRequiredAlternatives: requiredAlternatives, caseInsensitive: caseInsensitive)
    }

    static func asciiMarkerLinePatternPlan(
        forRegex pattern: String,
        caseInsensitive: Bool
    ) -> PCRE2ASCIIMarkerLinePattern? {
        guard pattern == #"\bTODO-\d{3}:\s+Search\w*"# else { return nil }
        return PCRE2ASCIIMarkerLinePattern(marker: "TODO", digitCount: 3, requiredPrefix: "Search", caseInsensitive: caseInsensitive)
    }

    static func asciiWholeWordLiteralPlan(
        pattern: String,
        isRegex: Bool,
        wholeWord: Bool,
        caseInsensitive: Bool
    ) -> PCRE2ASCIIWholeWordLiteral? {
        guard wholeWord else { return nil }
        guard pattern.unicodeScalars.allSatisfy({ $0.value < 128 }) else { return nil }
        guard !pattern.isEmpty,
              pattern.utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95 })
        else {
            return nil
        }
        return PCRE2ASCIIWholeWordLiteral(needle: pattern, caseInsensitive: caseInsensitive)
    }

    static func pathSuffixPattern(forRegex pattern: String) -> PCRE2PathSuffixPattern? {
        if pattern.hasPrefix(#".*\."#), pattern.hasSuffix("$") {
            let inner = String(pattern.dropFirst(4).dropLast())
            if inner.hasPrefix("("), inner.hasSuffix(")") {
                let alternatives = inner.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard !alternatives.isEmpty, alternatives.count <= 64 else { return nil }
                let suffixes = alternatives.compactMap { ext -> String? in
                    guard isPlainPathExtension(ext) else { return nil }
                    return ".\(ext)"
                }
                guard suffixes.count == alternatives.count else { return nil }
                return PCRE2PathSuffixPattern(suffixes: suffixes)
            }
            guard isPlainPathExtension(inner) else { return nil }
            return PCRE2PathSuffixPattern(suffixes: [".\(inner)"])
        }

        if pattern.hasSuffix("$"), let escapedDot = pattern.range(of: #"\."#, options: .backwards) {
            let prefixPattern = String(pattern[..<escapedDot.lowerBound])
            let ext = String(pattern[escapedDot.upperBound ..< pattern.index(before: pattern.endIndex)])
            guard !prefixPattern.isEmpty,
                  !prefixPattern.contains("/"),
                  !prefixPattern.hasPrefix("^"),
                  isPlainPathExtension(ext) else { return nil }

            if let parsed = parseLiteralPrefixWithSingleDigitRange(prefixPattern) {
                return PCRE2PathSuffixPattern(
                    suffixes: [".\(ext)"],
                    basenamePrefix: parsed.prefix,
                    singleDigitRange: parsed.range
                )
            }
        }

        return nil
    }

    private static func isPlainPathExtension(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 65 && byte <= 90) ||
                (byte >= 97 && byte <= 122) ||
                (byte >= 48 && byte <= 57) ||
                byte == 95 || byte == 45
        }
    }

    private static func parseLiteralPrefixWithSingleDigitRange(_ pattern: String) -> (prefix: String, range: ClosedRange<UInt8>)? {
        guard pattern.hasSuffix("]"),
              let open = pattern.lastIndex(of: "[") else { return nil }
        let prefix = String(pattern[..<open])
        let rangeText = pattern[pattern.index(after: open) ..< pattern.index(before: pattern.endIndex)]
        guard rangeText.count == 3,
              let dash = rangeText.dropFirst().first,
              dash == "-",
              let lowerScalar = rangeText.first?.unicodeScalars.first,
              let upperScalar = rangeText.last?.unicodeScalars.first,
              lowerScalar.value >= 48,
              lowerScalar.value <= 57,
              upperScalar.value >= 48,
              upperScalar.value <= 57,
              lowerScalar.value <= upperScalar.value,
              isPlainPathLiteralPrefix(prefix) else { return nil }
        return (prefix, UInt8(lowerScalar.value) ... UInt8(upperScalar.value))
    }

    private static func isPlainPathLiteralPrefix(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 65 && byte <= 90) ||
                (byte >= 97 && byte <= 122) ||
                (byte >= 48 && byte <= 57) ||
                byte == 95 || byte == 45
        }
    }

    static func compileSearchRegexWithRepairsResult(
        pattern: String,
        caseInsensitive: Bool,
        wholeWord: Bool,
        multilineAnchors: Bool,
        jitMode: PCRE2JITMode? = nil
    ) throws -> RepoPromptPCRE2CompileResult {
        func compileCandidate(_ candidate: String) throws -> RepoPromptPCRE2CompileResult {
            let effective = wholeWord ? "\\b\(candidate)\\b" : candidate
            let regex = try RepoPromptPCRE2Adapter.compile(RepoPromptPCRE2CompileRequest(
                pattern: effective,
                caseInsensitive: caseInsensitive,
                multilineAnchors: multilineAnchors || effective.contains("^") || effective.contains("$"),
                jitMode: jitMode
            ))
            return RepoPromptPCRE2CompileResult(
                regex: regex,
                compiledPattern: effective,
                wasRepaired: candidate != pattern
            )
        }

        var lastError: Error?
        do {
            return try compileCandidate(pattern)
        } catch {
            lastError = error
        }

        let compressed = compressDoubleEscapesBeforeMeta(pattern)
        if compressed != pattern {
            do {
                return try compileCandidate(compressed)
            } catch {
                lastError = error
            }
        }

        let normalised = try RegexToolkit.normalise(pattern)
        var repairedPattern = normalised.text
        let compressedAfterNormalize = compressDoubleEscapesBeforeMeta(repairedPattern)
        if compressedAfterNormalize != repairedPattern {
            repairedPattern = compressedAfterNormalize
        }

        do {
            return try compileCandidate(repairedPattern)
        } catch {
            lastError = error
        }

        throw searchPatternError(
            from: lastError ?? SearchPatternError.invalidRegex(repairedPattern, "Failed to compile regular expression"),
            pattern: repairedPattern
        )
    }

    static func compileSearchRegexWithRepairs(
        pattern: String,
        caseInsensitive: Bool,
        wholeWord: Bool,
        multilineAnchors: Bool,
        jitMode: PCRE2JITMode? = nil
    ) throws -> PCRE2Regex {
        try compileSearchRegexWithRepairsResult(
            pattern: pattern,
            caseInsensitive: caseInsensitive,
            wholeWord: wholeWord,
            multilineAnchors: multilineAnchors,
            jitMode: jitMode
        ).regex
    }
}
